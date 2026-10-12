-- Konami GV: SCSI CD-ROM target (Toshiba XM-5401, SCSI ID 4).
--
-- Bus behaviour ports MAME 0.289 src/devices/machine/nscsi_hle.cpp (nscsi_full_device):
-- selection, MESSAGE OUT (IDENTIFY), COMMAND, optional DATA IN/OUT, STATUS, MESSAGE IN
-- (COMMAND COMPLETE), BUS FREE, with zero data-byte period / command delay like the XM-5401.
--
-- Command semantics port src/devices/bus/nscsi/cd.cpp (nscsi_cdrom_device) for the commands
-- a GV board can issue: TEST UNIT READY, REZERO, REQUEST SENSE, READ(6), INQUIRY,
-- MODE SELECT(6), MODE SENSE(6), START/STOP, RECEIVE/SEND DIAGNOSTIC, PREVENT/ALLOW,
-- READ CAPACITY, READ(10), READ SUB-CHANNEL, READ TOC, PLAY AUDIO TRACK/INDEX,
-- PAUSE/RESUME, READ DISC INFORMATION.  Anything else -> CHECK CONDITION / ILLEGAL REQUEST.
--
-- Addresses are MAME logical frames: LBA 0 = first frame of track 1 (MiSTer HPS LBA - 150).
-- Data reads deliver 2048-byte Mode 1 user data (cdrom_file::read_data(.., MODE1)).
-- Red Book playback is delegated to gv_cdda (MAME cdda_device equivalent).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.gv_scsi_pkg.all;

entity gv_scsi_cdrom is
   generic (
      SCSI_ID : integer := 4
   );
   port (
      clk            : in  std_logic;
      ce             : in  std_logic;
      reset          : in  std_logic;

      bus_init       : in  t_scsi_init;      -- OR of all initiators
      bus_out        : out t_scsi_targ;

      disc_present   : in  std_logic;

      -- TOC (gv_cd_media): entry n = track n+1 (0-based), entry 'last' = lead-out
      toc_last       : in  unsigned(6 downto 0);       -- number of tracks
      toc_addr       : out unsigned(6 downto 0);
      toc_start      : in  unsigned(19 downto 0);      -- logical start frame (1-cycle latency)
      toc_audio      : in  std_logic;                  -- entry is an audio track

      -- Mode 1 user data port (gv_cd_media)
      sec_lba        : out unsigned(19 downto 0);      -- sector wanted
      sec_want       : out std_logic;                  -- level: sec_lba is wanted now
      sec_next       : out std_logic;                  -- hint: sec_lba+1 will follow
      sec_ready      : in  std_logic;                  -- buffer for sec_lba valid
      sec_addr       : out unsigned(10 downto 0);      -- user data byte 0..2047
      sec_data       : in  std_logic_vector(7 downto 0); -- 1-cycle latency

      -- CD-DA player (gv_cdda)
      cdda_start     : out std_logic := '0';
      cdda_start_lba : out unsigned(19 downto 0);
      cdda_blocks    : out unsigned(19 downto 0);
      cdda_pause     : out std_logic := '0';           -- pulse
      cdda_pause_val : out std_logic;
      cdda_active    : in  std_logic;
      cdda_paused    : in  std_logic;
      cdda_ended     : in  std_logic;
      cdda_cur_lba   : in  unsigned(19 downto 0);      -- MAME cdda get_audio_lba()
      cdda_vol_l     : out unsigned(7 downto 0);       -- MODE SELECT page 0x0E output gain
      cdda_vol_r     : out unsigned(7 downto 0)
   );
end entity;

architecture rtl of gv_scsi_cdrom is

   -- SCSI status / message / sense constants
   constant SS_GOOD            : std_logic_vector(7 downto 0) := x"00";
   constant SS_CHECK_CONDITION : std_logic_vector(7 downto 0) := x"02";
   constant SK_NO_SENSE        : std_logic_vector(3 downto 0) := x"0";
   constant SK_NOT_READY       : std_logic_vector(3 downto 0) := x"2";
   constant SK_ILLEGAL_REQUEST : std_logic_vector(3 downto 0) := x"5";

   type t_main is (T_IDLE, T_SEL_SETTLE, T_SEL_WAIT_SEL0, T_NEXT, T_MSG_BYTE, T_CMD_BYTE,
                   T_EXEC, T_DATA_IN, T_DATA_IN_FETCH, T_DATA_IN_WAIT, T_DATA_OUT);
   type t_sub  is (B_NONE, B_RECV_ACK1, B_RECV_ACK0, B_SEND_ACK1, B_SEND_ACK0);
   type t_dsrc is (D_MAIN, D_SENSE, D_SECTOR, D_MODE);       -- data buffer id (SBUF_MAIN / SENSE / 2)

   signal st         : t_main := T_IDLE;
   signal sub        : t_sub  := B_NONE;
   signal settle     : unsigned(3 downto 0) := (others => '0');
   signal ob         : t_scsi_targ := SCSI_TARG_IDLE;

   -- command buffer (CDB) and identify message
   type t_cdb is array(0 to 15) of std_logic_vector(7 downto 0);
   signal cdb        : t_cdb := (others => (others => '0'));
   signal cdb_pos    : unsigned(4 downto 0) := (others => '0');
   signal identify   : std_logic_vector(7 downto 0) := (others => '0');

   -- phase plan built by command execution (replaces MAME's control queue)
   signal plan_data  : std_logic := '0';        -- a data phase precedes status
   signal plan_in    : std_logic := '1';        -- data direction in
   signal plan_src   : t_dsrc := D_MAIN;
   signal plan_len   : unsigned(26 downto 0) := (others => '0');
   signal plan_stat  : std_logic_vector(7 downto 0) := SS_GOOD;
   signal plan_step  : unsigned(1 downto 0) := (others => '0');  -- 0 data, 1 status, 2 message, 3 free
   signal dpos       : unsigned(26 downto 0) := (others => '0');

   -- sense data (MAME set_sense_data with a sense_data struct -> byte0 = 0xF0)
   signal sense_key  : std_logic_vector(3 downto 0) := SK_NO_SENSE;
   signal sense_asc  : std_logic_vector(7 downto 0) := (others => '0');
   signal sense_ascq : std_logic_vector(7 downto 0) := (others => '0');

   -- drive state
   signal lba        : unsigned(19 downto 0) := (others => '0');
   signal bpb_log2   : unsigned(3 downto 0) := to_unsigned(11, 4);   -- bytes per block = 2^n (MODE SELECT)
   signal sotc       : std_logic := '0';
   signal vol_l      : unsigned(7 downto 0) := x"FF";
   signal vol_r      : unsigned(7 downto 0) := x"FF";
   type t_mode is array(0 to 31) of std_logic_vector(7 downto 0);
   signal mode_data  : t_mode := (others => (others => '0'));
   signal mode_size  : unsigned(7 downto 0) := to_unsigned(12, 8);

   -- response RAM (SBUF_MAIN), 1 KB
   type t_resp is array(0 to 1023) of std_logic_vector(7 downto 0);
   signal resp       : t_resp := (others => (others => '0'));
   signal resp_we    : std_logic := '0';
   signal resp_wa    : unsigned(9 downto 0) := (others => '0');
   signal resp_wd    : std_logic_vector(7 downto 0) := (others => '0');
   signal resp_ra    : unsigned(9 downto 0) := (others => '0');
   signal resp_q     : std_logic_vector(7 downto 0) := (others => '0');

   -- command execution micro-sequencer
   signal ex         : unsigned(4 downto 0) := (others => '0');
   signal ex_i       : unsigned(10 downto 0) := (others => '0');
   signal ex_n       : unsigned(10 downto 0) := (others => '0');
   signal ex_trk     : unsigned(7 downto 0) := (others => '0');
   signal ex_cnt     : unsigned(7 downto 0) := (others => '0');
   signal ex_val     : unsigned(31 downto 0) := (others => '0');
   signal ex_a, ex_b : unsigned(19 downto 0) := (others => '0');
   signal ex_flag    : std_logic := '0';
   signal ex_page    : integer range 0 to 7 := 0;

   signal toc_a      : unsigned(6 downto 0) := (others => '0');

   -- INQUIRY template bytes 0..35 (XM-5401: "TOSHIBA " "CD-ROM XM-5401TA" "3605", compliance 2, data 0x98)
   type t_rom is array(natural range <>) of std_logic_vector(7 downto 0);
   constant INQ : t_rom(0 to 35) := (
      x"05", x"80", x"02", x"02", x"20", x"00", x"00", x"98",
      x"54", x"4F", x"53", x"48", x"49", x"42", x"41", x"20",                  -- "TOSHIBA "
      x"43", x"44", x"2D", x"52", x"4F", x"4D", x"20", x"58",                  -- "CD-ROM X"
      x"4D", x"2D", x"35", x"34", x"30", x"31", x"54", x"41",                  -- "M-5401TA"
      x"33", x"36", x"30", x"35");                                             -- "3605"

   -- MODE SENSE pages in MAME emission order for page 0x3F (0x31, 0x30, 0x0E, 0x02, 0x01, 0x00)
   constant PG31 : t_rom(0 to 43) := (
      x"31", x"2A", x"42", x"6C", x"75", x"65", x"53", x"43", x"53", x"49", x"20", x"69", x"73", x"20",
      x"74", x"68", x"65", x"20", x"42", x"45", x"53", x"54", x"20", x"53", x"54", x"4F", x"4C", x"45",
      x"4E", x"20", x"46", x"52", x"4F", x"4D", x"20", x"42", x"4C", x"55", x"45", x"53", x"43", x"53",
      x"49", x"00");
   constant PG30 : t_rom(0 to 23) := (
      x"30", x"00", x"41", x"50", x"50", x"4C", x"45", x"20", x"43", x"4F", x"4D", x"50", x"55", x"54",
      x"45", x"52", x"2C", x"20", x"49", x"4E", x"43", x"20", x"20", x"20");
   constant PG0E : t_rom(0 to 15) := (
      x"8E", x"0E", x"04", x"00", x"00", x"00", x"00", x"00",
      x"01", x"FF", x"02", x"FF", x"04", x"FF", x"08", x"FF");
   constant PG02 : t_rom(0 to 15) := (
      x"82", x"0E", x"E6", x"1A", x"00", x"00", x"00", x"00",
      x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00");
   constant PG01 : t_rom(0 to 11) := (
      x"01", x"0A", x"01", x"01", x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00");
   constant PG00 : t_rom(0 to 3)  := (x"80", x"02", x"00", x"00");


   function adr_ctl(audio : std_logic) return std_logic_vector is
   begin
      if audio = '1' then return x"10"; else return x"14"; end if;
   end function;

   signal sec_abs    : unsigned(30 downto 0);
   signal ex_a_msf, ex_b_msf : unsigned(23 downto 0);
   signal msfa_ok, msfb_ok   : std_logic;
   signal msf_ok             : std_logic;

begin

   bus_out    <= ob;

   imsfa : entity work.gv_lba2msf port map (clk => clk, lba => ex_a, msf => ex_a_msf, ok => msfa_ok);
   imsfb : entity work.gv_lba2msf port map (clk => clk, lba => ex_b, msf => ex_b_msf, ok => msfb_ok);
   msf_ok <= msfa_ok and msfb_ok;
   toc_addr   <= toc_a;
   cdda_vol_l <= vol_l;
   cdda_vol_r <= vol_r;

   -- response RAM
   process(clk)
   begin
      if rising_edge(clk) then
         if resp_we = '1' then
            resp(to_integer(resp_wa)) <= resp_wd;
         end if;
         resp_q <= resp(to_integer(resp_ra));
      end if;
   end process;

   -- sector byte addressing for buffer id 2: abs = lba * bpb + pos
   sec_abs  <= shift_left(resize(lba, 31), to_integer(bpb_log2)) + resize(dpos, 31);
   sec_lba  <= resize(sec_abs(30 downto 11), 20);
   sec_addr <= sec_abs(10 downto 0);
   sec_want <= '1' when (st = T_DATA_IN or st = T_DATA_IN_FETCH or st = T_DATA_IN_WAIT) and plan_src = D_SECTOR else '0';
   sec_next <= '1' when plan_len - dpos > 2048 else '0';

   process(clk)
      variable c0      : std_logic_vector(7 downto 0);
      variable lun     : std_logic_vector(2 downto 0);
      variable v8      : std_logic_vector(7 downto 0);
      variable alloc   : unsigned(15 downto 0);
      variable tracks  : integer range 0 to 255;

      procedure set_sense(k : std_logic_vector(3 downto 0); asc : std_logic_vector(7 downto 0); ascq : std_logic_vector(7 downto 0)) is
      begin
         sense_key <= k; sense_asc <= asc; sense_ascq <= ascq;
      end procedure;

      procedure finish(stat : std_logic_vector(7 downto 0)) is
      begin
         plan_stat <= stat;
         plan_step <= (others => '0');
         st        <= T_NEXT;
      end procedure;

      procedure data_in(src : t_dsrc; len : unsigned) is
      begin
         plan_data <= '1'; plan_in <= '1'; plan_src <= src;
         plan_len  <= resize(len, 27);
      end procedure;

      procedure wr(a : unsigned; d : std_logic_vector(7 downto 0)) is
      begin
         resp_we <= '1'; resp_wa <= resize(a, 10); resp_wd <= d;
      end procedure;

      procedure target_send(v : std_logic_vector(7 downto 0)) is
      begin
         ob.data <= v;
         ob.req  <= '1';
         sub     <= B_SEND_ACK1;
      end procedure;

      procedure target_recv is
      begin
         ob.req <= '1';
         sub    <= B_RECV_ACK1;
      end procedure;
   begin
      if rising_edge(clk) then
         resp_we    <= '0';
         cdda_start <= '0';
         cdda_pause <= '0';

         if reset = '1' or bus_init.rst = '1' then
            st <= T_IDLE; sub <= B_NONE;
            ob <= SCSI_TARG_IDLE;
            identify <= (others => '0');
            plan_data <= '0';
            if reset = '1' then
               set_sense(SK_NO_SENSE, x"00", x"00");
               lba       <= (others => '0');
               mode_size <= to_unsigned(12, 8);
               bpb_log2  <= to_unsigned(11, 4);
               sotc      <= '0';
               vol_l     <= x"FF";
               vol_r     <= x"FF";
            end if;
         elsif ce = '1' then

            if sub /= B_NONE then
               -------------------------------------------------------------
               -- REQ/ACK byte handshakes (target side)
               -------------------------------------------------------------
               case sub is
                  when B_RECV_ACK1 =>
                     if bus_init.ack = '1' then
                        v8 := bus_init.data;
                        case st is
                           when T_MSG_BYTE | T_CMD_BYTE =>
                              if st = T_MSG_BYTE and cdb_pos = 0 then
                                 if v8(7) = '1' then identify <= v8; end if;   -- scsi_message()
                              elsif cdb_pos < 16 then
                                 cdb(to_integer(cdb_pos(3 downto 0))) <= v8;
                              end if;
                              if st = T_CMD_BYTE then cdb_pos <= cdb_pos + 1; end if;
                           when T_DATA_OUT =>
                              -- scsi_put_data(2, pos, data): mode parameter list
                              if dpos < 32 then mode_data(to_integer(dpos(4 downto 0))) <= v8; end if;
                              dpos <= dpos + 1;
                           when others => null;
                        end case;
                        ob.req <= '0';
                        sub    <= B_RECV_ACK0;
                     end if;
                  when B_RECV_ACK0 =>
                     if bus_init.ack = '0' then
                        sub <= B_NONE;
                     end if;
                  when B_SEND_ACK1 =>
                     if bus_init.ack = '1' then
                        ob.data <= x"00";
                        ob.req  <= '0';
                        sub     <= B_SEND_ACK0;
                     end if;
                  when B_SEND_ACK0 =>
                     if bus_init.ack = '0' then
                        sub <= B_NONE;
                     end if;
                  when others => null;
               end case;

            else
               case st is
                  ----------------------------------------------------------
                  -- selection
                  ----------------------------------------------------------
                  when T_IDLE =>
                     if bus_init.sel = '1' and bus_init.bsy = '0' and ob.bsy = '0' and bus_init.data(SCSI_ID) = '1' then
                        settle <= to_unsigned(13, 4);            -- bus settle delay (400 ns)
                        st     <= T_SEL_SETTLE;
                     end if;

                  when T_SEL_SETTLE =>
                     if settle /= 0 then
                        settle <= settle - 1;
                     elsif bus_init.sel = '1' and bus_init.bsy = '0' then
                        ob.bsy <= '1';
                        st     <= T_SEL_WAIT_SEL0;
                     else
                        st <= T_IDLE;
                     end if;

                  when T_SEL_WAIT_SEL0 =>
                     if bus_init.sel = '0' then
                        -- BC_MSG_OR_COMMAND
                        cdb_pos   <= (others => '0');
                        plan_data <= '0';
                        if bus_init.atn = '1' then
                           ob.phase <= PH_MSG_OUT;
                           st       <= T_MSG_BYTE;
                        else
                           ob.phase <= PH_COMMAND;
                           st       <= T_CMD_BYTE;
                        end if;
                        target_recv;
                     end if;

                  when T_MSG_BYTE =>
                     -- TARGET_WAIT_MSG_BYTE: more message bytes while ATN, then switch to COMMAND
                     if bus_init.sel = '0' then
                        if bus_init.atn = '0' then
                           cdb_pos  <= (others => '0');
                           ob.phase <= PH_COMMAND;
                           st       <= T_CMD_BYTE;
                        end if;
                        target_recv;
                     end if;

                  when T_CMD_BYTE =>
                     if bus_init.sel = '0' then
                        if bus_init.atn = '1' then
                           st <= T_IDLE;                         -- "parity error"
                        else
                           c0 := cdb(0);
                           -- scsi_command_done(): group length
                           if cdb_pos /= 0 and (
                                 (c0(7 downto 5) = "000" and cdb_pos = 6) or
                                 ((c0(7 downto 5) = "001" or c0(7 downto 5) = "010") and cdb_pos = 10) or
                                 (c0(7 downto 5) = "101" and cdb_pos = 12) or
                                 (c0(7 downto 5) = "011" or c0(7 downto 5) = "100" or c0(7 downto 5) = "110") or
                                 (c0(7 downto 5) = "111" and cdb_pos = 16)) then
                              ex <= (others => '0');
                              ex_i <= (others => '0');
                              st <= T_EXEC;
                           else
                              target_recv;
                           end if;
                        end if;
                     end if;

                  ----------------------------------------------------------
                  -- command execution (scsi_command)
                  ----------------------------------------------------------
                  when T_EXEC =>
                     c0 := cdb(0);
                     if identify(7) = '1' then lun := identify(2 downto 0); else lun := cdb(1)(7 downto 5); end if;

                     case c0 is
                        when x"00" =>                                       -- TEST UNIT READY
                           if disc_present = '1' then finish(SS_GOOD);
                           else set_sense(SK_NOT_READY, x"3A", x"00"); finish(SS_CHECK_CONDITION); end if;

                        when x"01" | x"1B" | x"1E" =>                       -- REZERO / START STOP / PREVENT ALLOW
                           finish(SS_GOOD);

                        when x"03" =>                                       -- REQUEST SENSE
                           if cdb(1)(4 downto 0) /= "00000" or cdb(2) /= x"00" or cdb(3) /= x"00" then
                              set_sense(SK_ILLEGAL_REQUEST, x"24", x"00"); finish(SS_CHECK_CONDITION);
                           else
                              if unsigned(cdb(4)) < 18 then
                                 data_in(D_SENSE, unsigned(cdb(4)));
                              else
                                 data_in(D_SENSE, to_unsigned(18, 8));
                              end if;
                              finish(SS_GOOD);
                           end if;

                        when x"08" | x"28" =>                               -- READ(6) / READ(10)
                           if disc_present = '0' then
                              set_sense(SK_NOT_READY, x"3A", x"00"); finish(SS_CHECK_CONDITION);
                           else
                              if c0 = x"08" then
                                 lba <= resize(unsigned(std_logic_vector'(cdb(1)(4 downto 0) & cdb(2) & cdb(3))), 20);
                                 if cdb(4) = x"00" then
                                    data_in(D_SECTOR, shift_left(to_unsigned(256, 27), to_integer(bpb_log2)));
                                 else
                                    data_in(D_SECTOR, shift_left(resize(unsigned(cdb(4)), 27), to_integer(bpb_log2)));
                                 end if;
                              else
                                 lba <= unsigned(std_logic_vector'(cdb(3)(3 downto 0) & cdb(4) & cdb(5)));
                                 data_in(D_SECTOR, shift_left(resize(unsigned(std_logic_vector'(cdb(7) & cdb(8))), 27), to_integer(bpb_log2)));
                              end if;
                              finish(SS_GOOD);
                           end if;

                        when x"12" =>                                       -- INQUIRY
                           -- build: bytes 0..size-1 of the 36-byte template (zeros beyond)
                           if ex = 0 then
                              if cdb(2) /= x"00" then
                                 finish(SS_GOOD);
                              else
                                 ex_n <= resize(unsigned(cdb(4)), 11);
                                 ex   <= to_unsigned(1, 5);
                              end if;
                           else
                              if ex_i < ex_n then
                                 if ex_i < 36 then
                                    v8 := INQ(to_integer(ex_i));
                                    if ex_i = 0 and lun /= "000" then v8 := x"7F"; end if;
                                 else
                                    v8 := x"00";
                                 end if;
                                 wr(ex_i, v8);
                                 ex_i <= ex_i + 1;
                              else
                                 data_in(D_MAIN, ex_n);
                                 finish(SS_GOOD);
                              end if;
                           end if;

                        when x"15" =>                                       -- MODE SELECT(6)
                           mode_size <= unsigned(cdb(4));
                           if cdb(4) /= x"00" then
                              plan_data <= '1'; plan_in <= '0'; plan_src <= D_MODE;
                              plan_len  <= resize(unsigned(cdb(4)), 27);
                           end if;
                           finish(SS_GOOD);

                        when x"1A" =>                                       -- MODE SENSE(6)
                           if lun /= "000" then
                              set_sense(SK_ILLEGAL_REQUEST, x"25", x"00"); finish(SS_CHECK_CONDITION);
                           else
                              case to_integer(ex) is
                                 when 0 =>
                                    toc_a <= toc_last;                     -- lead-out entry
                                    ex <= to_unsigned(6, 5);
                                 when 6 =>
                                    ex <= to_unsigned(7, 5);               -- TOC RAM latency
                                 when 7 =>
                                    -- header bytes 1..3 and optional block descriptor
                                    wr(to_unsigned(1, 10), x"00");
                                    ex_i <= to_unsigned(1, 11);
                                    -- last used block: leadout * (2048 / bpb) - 1
                                    ex_val <= shift_right(shift_left(resize(toc_start, 32), 11), to_integer(bpb_log2)) - 1;
                                    if disc_present = '0' then ex_val <= (others => '0'); end if;
                                    ex <= to_unsigned(1, 5);
                                 when 1 =>
                                    case to_integer(ex_i) is
                                       when 1 => wr(to_unsigned(2, 10), x"80");
                                       when 2 =>
                                          if cdb(1)(3) = '1' then wr(to_unsigned(3, 10), x"00"); else wr(to_unsigned(3, 10), x"08"); end if;
                                       when 3 => wr(to_unsigned(4, 10), x"00");
                                       when 4 => wr(to_unsigned(5, 10), std_logic_vector(ex_val(23 downto 16)));
                                       when 5 => wr(to_unsigned(6, 10), std_logic_vector(ex_val(15 downto 8)));
                                       when 6 => wr(to_unsigned(7, 10), std_logic_vector(ex_val(7 downto 0)));
                                       when 7 => wr(to_unsigned(8, 10), x"00");
                                       when 8 => wr(to_unsigned(9, 10), x"00");
                                       when 9 => wr(to_unsigned(10, 10), std_logic_vector(shift_left(to_unsigned(1, 16), to_integer(bpb_log2))(15 downto 8)));
                                       when others => wr(to_unsigned(11, 10), std_logic_vector(shift_left(to_unsigned(1, 16), to_integer(bpb_log2))(7 downto 0)));
                                    end case;
                                    if (cdb(1)(3) = '1' and ex_i = 2) or ex_i = 10 then
                                       -- pages follow at pos 4 or 12
                                       if cdb(1)(3) = '1' then ex_n <= to_unsigned(4, 11); else ex_n <= to_unsigned(12, 11); end if;
                                       ex_i    <= (others => '0');
                                       ex_page <= 0;
                                       ex_flag <= '0';                         -- fail flag
                                       ex      <= to_unsigned(2, 5);
                                    else
                                       ex_i <= ex_i + 1;
                                    end if;
                                 when 2 =>
                                    -- emit pages: ex_page 0..5 = 0x31,0x30,0x0E,0x02,0x01,0x00 (for 0x3F)
                                    -- or the single requested page
                                    if ex_page = 6 then
                                       ex <= to_unsigned(3, 5);
                                    else
                                       v8 := "00" & cdb(2)(5 downto 0);
                                       if (v8 = x"3F") or
                                          (ex_page = 0 and v8 = x"31") or (ex_page = 1 and v8 = x"30") or
                                          (ex_page = 2 and v8 = x"0E") or (ex_page = 3 and v8 = x"02") or
                                          (ex_page = 4 and v8 = x"01") or (ex_page = 5 and v8 = x"00") then
                                          case ex_page is
                                             when 0 => wr(ex_n, PG31(to_integer(ex_i)));
                                                       if ex_i = PG31'high then ex_i <= (others => '0'); ex_page <= 1; else ex_i <= ex_i + 1; end if;
                                             when 1 => wr(ex_n, PG30(to_integer(ex_i)));
                                                       if ex_i = PG30'high then ex_i <= (others => '0'); ex_page <= 2; else ex_i <= ex_i + 1; end if;
                                             when 2 =>
                                                       if ex_i = 2 then wr(ex_n, "00000" & '1' & sotc & '0');
                                                       else wr(ex_n, PG0E(to_integer(ex_i))); end if;
                                                       if ex_i = PG0E'high then ex_i <= (others => '0'); ex_page <= 3; else ex_i <= ex_i + 1; end if;
                                             when 3 => wr(ex_n, PG02(to_integer(ex_i)));
                                                       if ex_i = PG02'high then ex_i <= (others => '0'); ex_page <= 4; else ex_i <= ex_i + 1; end if;
                                             when 4 => wr(ex_n, PG01(to_integer(ex_i)));
                                                       if ex_i = PG01'high then ex_i <= (others => '0'); ex_page <= 5; else ex_i <= ex_i + 1; end if;
                                             when others => wr(ex_n, PG00(to_integer(ex_i)));
                                                       if ex_i = PG00'high then ex_i <= (others => '0'); ex_page <= 6; else ex_i <= ex_i + 1; end if;
                                          end case;
                                          ex_n <= ex_n + 1;
                                       else
                                          ex_page <= ex_page + 1;
                                       end if;
                                    end if;
                                 when 3 =>
                                    -- byte 0 = total length - 1; unknown single page -> fail
                                    v8 := "00" & cdb(2)(5 downto 0);
                                    if not (v8 = x"3F" or v8 = x"31" or v8 = x"30" or v8 = x"0E" or v8 = x"02" or v8 = x"01" or v8 = x"00") then
                                       set_sense(SK_ILLEGAL_REQUEST, x"24", x"00"); finish(SS_CHECK_CONDITION);
                                    else
                                       wr(to_unsigned(0, 10), std_logic_vector(resize(ex_n - 1, 8)));
                                       if unsigned(cdb(4)) < ex_n then
                                          data_in(D_MAIN, unsigned(cdb(4)));
                                       else
                                          data_in(D_MAIN, ex_n);
                                       end if;
                                       finish(SS_GOOD);
                                    end if;
                                 when others => null;
                              end case;
                           end if;

                        when x"1C" | x"1D" =>                               -- RECEIVE / SEND DIAGNOSTIC
                           if c0 = x"1D" and cdb(1)(2) = '1' then
                              finish(SS_GOOD);                              -- self-test
                           elsif ex = 0 then
                              ex_i <= (others => '0');
                              if c0 = x"1C" then ex_n <= to_unsigned(7, 11); else ex_n <= to_unsigned(8, 11); end if;
                              ex <= to_unsigned(1, 5);
                           elsif ex_i < ex_n then
                              if ex_i = 1 then wr(ex_i, x"06"); else wr(ex_i, x"00"); end if;
                              ex_i <= ex_i + 1;
                           else
                              alloc := unsigned(std_logic_vector'(cdb(3) & cdb(4)));
                              if alloc < ex_n then data_in(D_MAIN, alloc); else data_in(D_MAIN, ex_n); end if;
                              finish(SS_GOOD);
                           end if;

                        when x"25" =>                                       -- READ CAPACITY
                           if disc_present = '0' then
                              set_sense(SK_NOT_READY, x"3A", x"00"); finish(SS_CHECK_CONDITION);
                           else
                              case to_integer(ex) is
                                 when 0 =>
                                    toc_a <= toc_last;          -- lead-out entry
                                    ex <= to_unsigned(1, 5);
                                 when 1 =>
                                    ex <= to_unsigned(2, 5);   -- RAM latency
                                 when 2 =>
                                    -- (leadout * (2048 / bpb)) - 1
                                    ex_val <= shift_right(shift_left(resize(toc_start, 32), 11), to_integer(bpb_log2)) - 1;
                                    ex_i <= (others => '0');
                                    ex <= to_unsigned(3, 5);
                                 when others =>
                                    case to_integer(ex_i) is
                                       when 0 => wr(ex_i, std_logic_vector(ex_val(31 downto 24)));
                                       when 1 => wr(ex_i, std_logic_vector(ex_val(23 downto 16)));
                                       when 2 => wr(ex_i, std_logic_vector(ex_val(15 downto 8)));
                                       when 3 => wr(ex_i, std_logic_vector(ex_val(7 downto 0)));
                                       when 4 | 5 => wr(ex_i, x"00");
                                       when 6 => wr(ex_i, std_logic_vector(shift_left(to_unsigned(1, 16), to_integer(bpb_log2))(15 downto 8)));
                                       when others => wr(ex_i, std_logic_vector(shift_left(to_unsigned(1, 16), to_integer(bpb_log2))(7 downto 0)));
                                    end case;
                                    if ex_i = 7 then
                                       data_in(D_MAIN, to_unsigned(8, 4));
                                       finish(SS_GOOD);
                                    else
                                       ex_i <= ex_i + 1;
                                    end if;
                              end case;
                           end if;

                        when x"42" =>                                       -- READ SUB-CHANNEL
                           if disc_present = '0' then
                              set_sense(SK_NOT_READY, x"3A", x"00"); finish(SS_CHECK_CONDITION);
                           else
                              alloc := unsigned(std_logic_vector'(cdb(7) & cdb(8)));
                              case to_integer(ex) is
                                 when 0 =>
                                    -- latch position (m_last_lba) and find its track: get_track(lba)
                                    if cdda_active = '1' then ex_a <= cdda_cur_lba; else ex_a <= (others => '0'); end if;
                                    ex_trk <= (others => '0');
                                    toc_a  <= to_unsigned(1, 7);
                                    ex_i   <= (others => '0');
                                    ex     <= to_unsigned(1, 5);
                                 when 1 =>
                                    ex <= to_unsigned(2, 5);
                                 when 2 =>
                                    -- toc_start = start of entry toc_a; track = first index whose next start > lba
                                    if toc_a <= toc_last and ex_a >= toc_start then
                                       ex_trk <= resize(toc_a, 8);
                                       toc_a  <= toc_a + 1;
                                       ex     <= to_unsigned(1, 5);
                                    else
                                       toc_a <= resize(ex_trk, 7);   -- start of the found track
                                       ex    <= to_unsigned(3, 5);
                                    end if;
                                 when 3 =>
                                    ex <= to_unsigned(4, 5);
                                 when 4 =>
                                    ex_b <= ex_a - toc_start;        -- track-relative
                                    ex_n <= resize(alloc(10 downto 0), 11);
                                    if alloc > 1024 then ex_n <= to_unsigned(1024, 11); end if;
                                    ex_i <= (others => '0');
                                    ex   <= to_unsigned(5, 5);
                                 when others =>
                                    if msf_ok = '0' then
                                       null;                                  -- MSF conversion in progress
                                    elsif ex_i < ex_n then
                                       v8 := x"00";
                                       case to_integer(ex_i) is
                                          when 1 =>
                                             if cdda_active = '1' then
                                                if cdda_paused = '1' then v8 := x"12"; else v8 := x"11"; end if;
                                             elsif cdda_ended = '1' then v8 := x"13";
                                             else v8 := x"15"; end if;
                                          when others =>
                                             if cdb(2)(6) = '1' and cdb(3) = x"01" then
                                                case to_integer(ex_i) is
                                                   when 3 => v8 := x"0C";
                                                   when 4 => v8 := x"01";
                                                   when 5 => if cdda_active = '1' then v8 := x"10"; else v8 := x"14"; end if;
                                                   when 6 => v8 := std_logic_vector(ex_trk + 1);
                                                   when 8  => if cdb(1)(1) = '1' then v8 := x"00"; else v8 := x"00"; end if;
                                                   when 9  => if cdb(1)(1) = '1' then v8 := std_logic_vector(ex_a_msf(23 downto 16)); else v8 := x"0" & std_logic_vector(ex_a(19 downto 16)); end if;
                                                   when 10 => if cdb(1)(1) = '1' then v8 := std_logic_vector(ex_a_msf(15 downto 8));  else v8 := std_logic_vector(ex_a(15 downto 8)); end if;
                                                   when 11 => if cdb(1)(1) = '1' then v8 := std_logic_vector(ex_a_msf(7 downto 0));   else v8 := std_logic_vector(ex_a(7 downto 0)); end if;
                                                   when 13 => if cdb(1)(1) = '1' then v8 := std_logic_vector(ex_b_msf(23 downto 16)); else v8 := x"0" & std_logic_vector(ex_b(19 downto 16)); end if;
                                                   when 14 => if cdb(1)(1) = '1' then v8 := std_logic_vector(ex_b_msf(15 downto 8));  else v8 := std_logic_vector(ex_b(15 downto 8)); end if;
                                                   when 15 => if cdb(1)(1) = '1' then v8 := std_logic_vector(ex_b_msf(7 downto 0));   else v8 := std_logic_vector(ex_b(7 downto 0)); end if;
                                                   when others => null;
                                                end case;
                                             end if;
                                       end case;
                                       wr(ex_i, v8);
                                       ex_i <= ex_i + 1;
                                    else
                                       data_in(D_MAIN, alloc);
                                       finish(SS_GOOD);
                                    end if;
                              end case;
                           end if;

                        when x"43" =>                                       -- READ TOC
                           if disc_present = '0' then
                              set_sense(SK_NOT_READY, x"3A", x"00"); finish(SS_CHECK_CONDITION);
                           else
                              alloc := unsigned(std_logic_vector'(cdb(7) & cdb(8)));
                              v8 := x"0" & cdb(2)(3 downto 0);
                              if v8 = x"00" then v8 := "000000" & cdb(9)(7 downto 6); end if;
                              case to_integer(ex) is
                                 when 0 =>
                                    if v8 = x"00" then
                                       -- format 0: number of descriptors
                                       if cdb(6) = x"00" then
                                          tracks := to_integer(toc_last) + 1;
                                          ex_trk <= x"01";
                                       elsif unsigned(cdb(6)) <= toc_last then
                                          tracks := to_integer(toc_last) - to_integer(unsigned(cdb(6))) + 2;
                                          ex_trk <= unsigned(cdb(6));
                                       elsif unsigned(cdb(6)) <= x"AA" then
                                          tracks := 1;
                                          ex_trk <= unsigned(cdb(6));
                                       else
                                          tracks := 0;
                                          ex_trk <= unsigned(cdb(6));
                                       end if;
                                       ex_cnt <= to_unsigned(tracks, 8);
                                       ex_val <= to_unsigned(2 + tracks * 8, 32);
                                       ex <= to_unsigned(1, 5);
                                    elsif v8 = x"01" then
                                       ex_val <= to_unsigned(10, 32);
                                       toc_a  <= (others => '0');
                                       ex <= to_unsigned(10, 5);
                                    else
                                       set_sense(SK_ILLEGAL_REQUEST, x"00", x"00"); finish(SS_CHECK_CONDITION);
                                    end if;
                                 when 1 =>                                  -- header
                                    case to_integer(ex_i) is
                                       when 0 => wr(ex_i, std_logic_vector(ex_val(15 downto 8)));
                                       when 1 => wr(ex_i, std_logic_vector(ex_val(7 downto 0)));
                                       when 2 => wr(ex_i, x"01");
                                       when others => wr(ex_i, '0' & std_logic_vector(toc_last));
                                    end case;
                                    if ex_i = 3 then
                                       ex_i <= to_unsigned(4, 11);
                                       ex_b <= (others => '0');           -- descriptor index
                                       ex <= to_unsigned(2, 5);
                                    else
                                       ex_i <= ex_i + 1;
                                    end if;
                                 when 2 =>                                  -- next descriptor: fetch TOC entry
                                    if ex_b(7 downto 0) = ex_cnt then
                                       ex <= to_unsigned(9, 5);
                                    else
                                       if ex_b(7 downto 0) = ex_cnt - 1 then
                                          toc_a   <= toc_last;              -- lead-out
                                          ex_flag <= '1';
                                       else
                                          toc_a   <= resize(ex_trk + ex_b(7 downto 0) - 1, 7);
                                          ex_flag <= '0';
                                       end if;
                                       ex <= to_unsigned(3, 5);
                                    end if;
                                 when 3 =>
                                    ex <= to_unsigned(4, 5);
                                 when 4 =>
                                    -- latch start (LBA or MSF of lba+150) and control
                                    if cdb(1)(1) = '1' then
                                       ex_a <= toc_start + 150;
                                    else
                                       ex_a <= toc_start;
                                    end if;
                                    ex_page <= 0;
                                    ex <= to_unsigned(5, 5);
                                 when 5 =>
                                    case ex_page is
                                       when 0 => wr(ex_i, x"00");
                                       when 1 =>
                                          if ex_flag = '1' then
                                             -- lead-out uses the last track's flags
                                             toc_a <= toc_last - 1;
                                          end if;
                                          null;
                                       when others => null;
                                    end case;
                                    if ex_page = 0 then
                                       ex_page <= 1; ex_i <= ex_i + 1;
                                    else
                                       ex <= to_unsigned(6, 5);
                                    end if;
                                 when 6 =>
                                    ex <= to_unsigned(7, 5);              -- TOC RAM latency for flags
                                 when 7 =>
                                  if msf_ok = '1' then
                                    case ex_page is
                                       when 1 => wr(ex_i, adr_ctl(toc_audio));
                                       when 2 =>
                                          if ex_flag = '1' then wr(ex_i, x"AA"); else wr(ex_i, std_logic_vector(ex_trk + ex_b(7 downto 0))); end if;
                                       when 3 => wr(ex_i, x"00");
                                       when 4 => wr(ex_i, x"00");
                                       when 5 =>
                                          if cdb(1)(1) = '1' then wr(ex_i, std_logic_vector(ex_a_msf(23 downto 16)));
                                          else wr(ex_i, x"0" & std_logic_vector(ex_a(19 downto 16))); end if;
                                       when 6 =>
                                          if cdb(1)(1) = '1' then wr(ex_i, std_logic_vector(ex_a_msf(15 downto 8)));
                                          else wr(ex_i, std_logic_vector(ex_a(15 downto 8))); end if;
                                       when others =>
                                          if cdb(1)(1) = '1' then wr(ex_i, std_logic_vector(ex_a_msf(7 downto 0)));
                                          else wr(ex_i, std_logic_vector(ex_a(7 downto 0))); end if;
                                    end case;
                                    ex_i <= ex_i + 1;
                                    if ex_page = 7 then
                                       ex_b <= ex_b + 1;
                                       ex   <= to_unsigned(2, 5);
                                    else
                                       ex_page <= ex_page + 1;
                                    end if;
                                  end if;
                                 when 9 =>                                  -- done
                                    if ex_i(10 downto 0) > alloc then
                                       data_in(D_MAIN, alloc);
                                    else
                                       data_in(D_MAIN, ex_i);
                                    end if;
                                    finish(SS_GOOD);
                                 when 10 =>                                 -- format 1 (session info)
                                    ex <= to_unsigned(11, 5);
                                 when 11 =>
                                    ex <= to_unsigned(12, 5);
                                 when 12 =>
                                    if cdb(1)(1) = '1' then ex_a <= toc_start + 150; else ex_a <= toc_start; end if;
                                    ex_flag <= toc_audio;
                                    ex_i <= (others => '0');
                                    ex <= to_unsigned(13, 5);
                                 when others =>
                                  if msf_ok = '1' then
                                    case to_integer(ex_i) is
                                       when 0 => wr(ex_i, x"00");
                                       when 1 => wr(ex_i, x"0A");
                                       when 2 | 3 | 6 => wr(ex_i, x"01");
                                       when 5 => wr(ex_i, adr_ctl(ex_flag));
                                       when 8 => wr(ex_i, x"00");
                                       when 9 =>
                                          if cdb(1)(1) = '1' then wr(ex_i, std_logic_vector(ex_a_msf(23 downto 16)));
                                          else wr(ex_i, x"0" & std_logic_vector(ex_a(19 downto 16))); end if;
                                       when 10 =>
                                          if cdb(1)(1) = '1' then wr(ex_i, std_logic_vector(ex_a_msf(15 downto 8)));
                                          else wr(ex_i, std_logic_vector(ex_a(15 downto 8))); end if;
                                       when 11 =>
                                          if cdb(1)(1) = '1' then wr(ex_i, std_logic_vector(ex_a_msf(7 downto 0)));
                                          else wr(ex_i, std_logic_vector(ex_a(7 downto 0))); end if;
                                       when others => wr(ex_i, x"00");
                                    end case;
                                    if ex_i = 11 then
                                       ex_i <= to_unsigned(12, 11);
                                       ex <= to_unsigned(9, 5);
                                    else
                                       ex_i <= ex_i + 1;
                                    end if;
                                  end if;
                              end case;
                           end if;

                        when x"48" =>                                       -- PLAY AUDIO TRACK/INDEX
                           case to_integer(ex) is
                              when 0 =>
                                 if unsigned(cdb(4)) > unsigned(cdb(7)) or cdb(4) = x"00" then
                                    set_sense(SK_ILLEGAL_REQUEST, x"00", x"14"); finish(SS_CHECK_CONDITION);
                                 else
                                    -- end track: sotc ? start : min(last, cdb[7])
                                    if sotc = '1' then
                                       ex_trk <= unsigned(cdb(4));
                                    elsif unsigned(cdb(7)) > toc_last then
                                       ex_trk <= resize(toc_last, 8);
                                    else
                                       ex_trk <= unsigned(cdb(7));
                                    end if;
                                    toc_a <= resize(unsigned(cdb(4)) - 1, 7);
                                    ex <= to_unsigned(1, 5);
                                 end if;
                              when 1 =>
                                 ex <= to_unsigned(2, 5);
                              when 2 =>
                                 ex_a    <= toc_start;              -- lba = start of start track
                                 ex_flag <= toc_audio;              -- get_track(lba) == start track
                                 toc_a   <= resize(ex_trk, 7);      -- start of the track after end track
                                 ex <= to_unsigned(3, 5);
                              when 3 =>
                                 ex <= to_unsigned(4, 5);
                              when others =>
                                 if ex_flag = '1' then
                                    cdda_start     <= '1';
                                    cdda_start_lba <= ex_a;
                                    cdda_blocks    <= toc_start - ex_a;
                                    set_sense(SK_NO_SENSE, x"00", x"11");
                                    finish(SS_GOOD);
                                 else
                                    set_sense(SK_ILLEGAL_REQUEST, x"64", x"00"); finish(SS_CHECK_CONDITION);
                                 end if;
                           end case;

                        when x"4B" =>                                       -- PAUSE/RESUME
                           if disc_present = '1' then
                              cdda_pause     <= '1';
                              cdda_pause_val <= not cdb(8)(0);
                           end if;
                           finish(SS_GOOD);

                        when x"51" =>                                       -- READ DISC INFORMATION
                           if disc_present = '0' then
                              set_sense(SK_NOT_READY, x"3A", x"00"); finish(SS_CHECK_CONDITION);
                           else
                              case to_integer(ex) is
                                 when 0 =>
                                    toc_a <= (others => '0');
                                    ex <= to_unsigned(1, 5);
                                 when 1 =>
                                    ex <= to_unsigned(2, 5);
                                 when 2 =>
                                    ex_a  <= toc_start + 150;           -- track 1 start (MSF)
                                    toc_a <= toc_last;
                                    ex <= to_unsigned(3, 5);
                                 when 3 =>
                                    ex <= to_unsigned(4, 5);
                                 when 4 =>
                                    ex_b <= toc_start + 150;            -- lead-out (MSF)
                                    ex_i <= (others => '0');
                                    ex <= to_unsigned(5, 5);
                                 when others =>
                                  if msf_ok = '1' then
                                    v8 := x"00";
                                    case to_integer(ex_i) is
                                       when 1 => v8 := x"20";
                                       when 2 => v8 := x"02";
                                       when 3 | 4 | 5 => v8 := x"01";
                                       when 6 => v8 := '0' & std_logic_vector(toc_last);
                                       when 17 => v8 := std_logic_vector(ex_a_msf(23 downto 16));
                                       when 18 => v8 := std_logic_vector(ex_a_msf(15 downto 8));
                                       when 19 => v8 := std_logic_vector(ex_a_msf(7 downto 0));
                                       when 21 => v8 := std_logic_vector(ex_b_msf(23 downto 16));
                                       when 22 => v8 := std_logic_vector(ex_b_msf(15 downto 8));
                                       when 23 => v8 := std_logic_vector(ex_b_msf(7 downto 0));
                                       when others => null;
                                    end case;
                                    wr(ex_i, v8);
                                    if ex_i = 33 then
                                       data_in(D_MAIN, to_unsigned(34, 6));
                                       finish(SS_GOOD);
                                    else
                                       ex_i <= ex_i + 1;
                                    end if;
                                  end if;
                              end case;
                           end if;

                        when others =>                                      -- scsi_unknown_command
                           set_sense(SK_ILLEGAL_REQUEST, x"00", x"00");
                           finish(SS_CHECK_CONDITION);
                     end case;

                  ----------------------------------------------------------
                  -- phase sequencing (TARGET_NEXT_CONTROL)
                  ----------------------------------------------------------
                  when T_NEXT =>
                     case to_integer(plan_step) is
                        when 0 =>
                           plan_step <= to_unsigned(1, 2);
                           if plan_data = '1' then
                              dpos <= (others => '0');
                              if plan_in = '1' then
                                 ob.phase <= PH_DATA_IN;
                                 if plan_len /= 0 then st <= T_DATA_IN; end if;
                              else
                                 ob.phase <= PH_DATA_OUT;
                                 if plan_len /= 0 then st <= T_DATA_OUT; end if;
                              end if;
                           end if;
                        when 1 =>
                           plan_step <= to_unsigned(2, 2);
                           ob.phase  <= PH_STATUS;
                           target_send(plan_stat);
                        when 2 =>
                           plan_step <= to_unsigned(3, 2);
                           ob.phase  <= PH_MSG_IN;
                           target_send(x"00");               -- COMMAND COMPLETE
                        when others =>
                           ob <= SCSI_TARG_IDLE;             -- BUS FREE
                           identify <= (others => '0');
                           st <= T_IDLE;
                     end case;

                  when T_DATA_IN =>
                     if dpos = plan_len then
                        st <= T_NEXT;
                     else
                        case plan_src is
                           when D_MAIN =>
                              resp_ra <= dpos(9 downto 0);
                              st <= T_DATA_IN_FETCH;
                           when D_SENSE =>
                              case to_integer(dpos) is
                                 when 0 => v8 := x"F0";
                                 when 2 => v8 := "0000" & sense_key;
                                 when 7 => v8 := x"0A";
                                 when 12 => v8 := sense_asc;
                                 when 13 => v8 := sense_ascq;
                                 when others => v8 := x"00";
                              end case;
                              dpos <= dpos + 1;
                              target_send(v8);
                           when D_SECTOR =>
                              if sec_ready = '1' then
                                 st <= T_DATA_IN_FETCH;          -- sec_addr presented from dpos
                              end if;
                           when others =>
                              target_send(x"00");
                              dpos <= dpos + 1;
                        end case;
                     end if;

                  when T_DATA_IN_FETCH =>
                     st <= T_DATA_IN_WAIT;                       -- RAM read latency

                  when T_DATA_IN_WAIT =>
                     if plan_src = D_MAIN then
                        target_send(resp_q);
                     else
                        target_send(sec_data);
                     end if;
                     dpos <= dpos + 1;
                     st <= T_DATA_IN;

                  when T_DATA_OUT =>
                     if dpos = plan_len then
                        -- last mode-select byte received: apply (scsi_put_data, pos == mode_data_size-1)
                        if plan_src = D_MODE and dpos = resize(mode_size, 27) then
                           if mode_data(3) = x"08" then
                              -- set_block_size(get_u24be(mode_data+9)): must divide 2048
                              case std_logic_vector'(mode_data(10) & mode_data(11)) is
                                 when x"0800" => bpb_log2 <= to_unsigned(11, 4);
                                 when x"0400" => bpb_log2 <= to_unsigned(10, 4);
                                 when x"0200" => bpb_log2 <= to_unsigned(9, 4);
                                 when x"0100" => bpb_log2 <= to_unsigned(8, 4);
                                 when others => null;
                              end case;
                              if mode_data(12)(5 downto 0) = "001110" then   -- page 0x0E at offset 12
                                 sotc  <= mode_data(14)(1);
                                 vol_l <= unsigned(mode_data(21));
                                 vol_r <= unsigned(mode_data(23));
                              end if;
                           elsif mode_data(3) = x"00" then
                              if mode_data(4)(5 downto 0) = "001110" then    -- page 0x0E at offset 4
                                 sotc  <= mode_data(6)(1);
                                 vol_l <= unsigned(mode_data(13));
                                 vol_r <= unsigned(mode_data(15));
                              end if;
                           end if;
                        end if;
                        st <= T_NEXT;
                     else
                        target_recv;
                     end if;

                  when others =>
                     st <= T_IDLE;
               end case;
            end if;
         end if;
      end if;
   end process;

end architecture;
