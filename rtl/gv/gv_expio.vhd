-- Konami GV expansion I/O ports at 0x1F680080-0x1F6800FF, per MAME 0.289 konamigv.cpp:
--
-- Beat the Champ (btchamp_map):
--   0x80-0x87  two uPD4701A read_xy: trackball 0 on the odd lanes (umask32 0xFF00FF00: 81 X lo, 83 X hi,
--              85 Y lo, 87 Y hi), trackball 1 on the even lanes (umask32 0x00FF00FF: 80, 82, 84, 86)
--   0x88       btc_trackball_w: bit 1 -> CS of both chips, bit 0 = 0 -> X/Y counter reset of both chips
--   0xE0-0xE3  write ignored
--   uPD4701A (upd4701.cpp): 12-bit counters; CS falling latches (count - origin); read_xy pulses CS low
--   for the access (so with CS high every read sees the live count, with CS held low the latch);
--   a reset line going active sets origin := count and blocks counting while active.
--
-- Dead Eye (kdeadeye_map): 0x80 GUNX1, 0x90 GUNY1, 0xA0 GUNX2, 0xB0 GUNY2 (16-bit values), 0xC0 BUTTONS
--   (bit 0 player 1 trigger, bit 1 player 2 trigger, active low; other bits 1), 0xE0-0xE3 write ignored.
--
-- Tokimeki Memorial Oshiete Your Heart (tmosh_map):
--   0x80 read  tokimeki_serial_r: bit2 heartbeat pulse (0 = beat seen; the read re-arms it to 1),
--              bit3 sensor serial data (bit 8 of the shift register once a sensor ID was sent),
--              bit5 no paper, bit6 printing, bit7 printer malfunction
--   0x90 write tokimeki_serial_w: bit1 sensor reset, bit5 sensor clock, bit4 sensor data (5-bit sensor ID,
--              ID 1Ah = GSR), bit0 printer data (pulse widths: >=9000 ticks start, 4000..5600 one, else
--              zero, ticks = CPU clock / 16 = clk1x / 8; 3 x {7-bit command, F9h}; command 11h = print ->
--              printing for 1 s, 17h / 10h = page / memory handling, no visible output here)
--   device check (P2 bit 10): bit 15 of a 16-bit word rotated left on each rising EEPROMOUT bit 4,
--              starting at dc_start (0 for tmosh).
--
-- Reads are registered (valid the cycle after bus_read), like gv_board. bus_sel marks this module's reads.
--
-- GPL-2.0 (part of Konami_GV_MiSTer).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gv_expio is
   port (
      clk1x          : in  std_logic;
      ce             : in  std_logic;
      reset          : in  std_logic;
      en_btc         : in  std_logic;
      en_gun         : in  std_logic;
      en_tmo         : in  std_logic;

      bus_addr       : in  unsigned(22 downto 0);
      bus_read       : in  std_logic;
      bus_write      : in  std_logic;
      bus_dataWrite  : in  std_logic_vector(7 downto 0);
      bus_dataRead   : out std_logic_vector(7 downto 0);
      bus_sel        : out std_logic;

      -- Beat the Champ trackballs: counts to add (clk1x strobe), uPD4701 counting direction
      tb0_strobe     : in  std_logic;
      tb0_dx, tb0_dy : in  signed(9 downto 0);
      tb1_strobe     : in  std_logic;
      tb1_dx, tb1_dy : in  signed(9 downto 0);

      -- Dead Eye guns
      gun_x1, gun_y1 : in  unsigned(15 downto 0);
      gun_x2, gun_y2 : in  unsigned(15 downto 0);
      gun_trig1      : in  std_logic;                       -- '1' = pulled
      gun_trig2      : in  std_logic;

      -- Tokimeki
      heartbeat      : in  std_logic;                       -- one clk1x pulse per beat
      gsr            : in  std_logic_vector(7 downto 0);
      paper_empty    : in  std_logic;
      printer_fault  : in  std_logic;
      eep_bit4       : in  std_logic;                       -- EEPROMOUT bit 4
      dc_start       : in  std_logic_vector(15 downto 0);
      dc_bit         : out std_logic                        -- P2 bit 10 (active high)
   );
end entity;

architecture rtl of gv_expio is

   type t_u16x2 is array(0 to 1) of unsigned(15 downto 0);
   type t_u12x2 is array(0 to 1) of unsigned(11 downto 0);
   signal tbx, tby, tbsx, tbsy : t_u16x2 := (others => (others => '0'));
   signal latx, laty : t_u12x2 := (others => (others => '0'));
   signal tb_cs      : std_logic := '1';
   signal tb_rst     : std_logic := '0';

   signal rd_q       : std_logic_vector(7 downto 0) := (others => '0');
   signal sel_q      : std_logic := '0';
   signal sel        : std_logic;

   -- Tokimeki
   signal hb_sig     : std_logic := '1';
   signal ser_clk    : std_logic := '0';
   signal ser_len    : unsigned(3 downto 0) := (others => '0');
   signal ser_val    : std_logic_vector(4 downto 0) := (others => '0');
   signal ser_id     : std_logic_vector(4 downto 0) := (others => '0');
   signal ser_data   : std_logic_vector(15 downto 0) := (others => '0');
   signal pr_bit     : std_logic := '0';
   signal pr_ticks   : unsigned(19 downto 0) := (others => '0');
   signal pr_div     : unsigned(2 downto 0) := (others => '0');
   signal pr_acc     : std_logic_vector(7 downto 0) := (others => '0');   -- byte being received
   signal pr_hist    : std_logic_vector(47 downto 0) := (others => '0');  -- received bytes, oldest at the top
   signal pr_curbit  : unsigned(3 downto 0) := (others => '0');
   signal pr_curbyte : unsigned(2 downto 0) := (others => '0');
   signal printing   : std_logic := '0';
   signal print_left : unsigned(25 downto 0) := (others => '0');
   signal dc_val     : std_logic_vector(15 downto 0) := (others => '0');
   signal eep4_q     : std_logic := '0';
   signal dc_loaded  : std_logic := '0';

   function cnt(x, sx : unsigned(15 downto 0)) return unsigned is
   begin
      return resize(x - sx, 12);
   end function;

begin

   sel <= '1' when bus_addr(22 downto 16) = 16#68# and bus_addr(15 downto 7) = "000000001" and
                   (en_btc = '1' or en_gun = '1' or en_tmo = '1') else '0';   -- 0x80-0xFF

   bus_dataRead <= rd_q;
   bus_sel      <= sel_q;
   dc_bit       <= dc_val(15);

   process(clk1x)
      variable o     : unsigned(7 downto 0);
      variable chip  : integer range 0 to 1;
      variable v12   : unsigned(11 downto 0);
      variable w16   : unsigned(15 downto 0);
      variable st    : std_logic_vector(7 downto 0);
      variable bit1v : std_logic;
      variable tk    : unsigned(19 downto 0);
      variable nb    : std_logic_vector(7 downto 0);
      variable acc   : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk1x) then
         o := bus_addr(7 downto 0);

         ------------------------------------------------------------------ trackball counting
         if tb_rst = '0' then
            if tb0_strobe = '1' then
               tbx(0) <= tbx(0) + unsigned(resize(tb0_dx, 16));
               tby(0) <= tby(0) + unsigned(resize(tb0_dy, 16));
            end if;
            if tb1_strobe = '1' then
               tbx(1) <= tbx(1) + unsigned(resize(tb1_dx, 16));
               tby(1) <= tby(1) + unsigned(resize(tb1_dy, 16));
            end if;
         end if;

         ------------------------------------------------------------------ reads
         if ce = '1' and bus_read = '1' then
            sel_q <= sel;
            rd_q  <= x"00";
            if sel = '1' then
               if en_btc = '1' and o(7 downto 3) = "10000" then              -- 0x80-0x87
                  if o(0) = '1' then chip := 0; else chip := 1; end if;
                  if tb_cs = '1' then                                       -- read_xy latches now
                     if o(2) = '0' then v12 := cnt(tbx(chip), tbsx(chip)); else v12 := cnt(tby(chip), tbsy(chip)); end if;
                  else
                     if o(2) = '0' then v12 := latx(chip); else v12 := laty(chip); end if;
                  end if;
                  if o(1) = '0' then rd_q <= std_logic_vector(v12(7 downto 0));
                  else rd_q <= x"0" & std_logic_vector(v12(11 downto 8)); end if;
               elsif en_gun = '1' and o(3 downto 2) = "00" and o(7) = '1' and o(6 downto 4) <= "100" then
                  case o(6 downto 4) is                                     -- 0x80/90/A0/B0/C0
                     when "000"  => w16 := gun_x1;
                     when "001"  => w16 := gun_y1;
                     when "010"  => w16 := gun_x2;
                     when "011"  => w16 := gun_y2;
                     when others => w16 := x"FFFC" or (x"000" & "00" & (not gun_trig2) & (not gun_trig1));
                  end case;
                  case o(1 downto 0) is
                     when "00"   => rd_q <= std_logic_vector(w16(7 downto 0));
                     when "01"   => rd_q <= std_logic_vector(w16(15 downto 8));
                     when others => rd_q <= x"00";
                  end case;
               elsif en_tmo = '1' and o = x"80" then
                  st := (others => '0');
                  st(2) := hb_sig;
                  if ser_id /= "00000" then st(3) := ser_data(8); end if;
                  st(5) := paper_empty;
                  st(6) := printing;
                  st(7) := printer_fault;
                  rd_q   <= st;
                  hb_sig <= '1';
               end if;
            end if;
         end if;
         if heartbeat = '1' then hb_sig <= '0'; end if;

         ------------------------------------------------------------------ writes
         if ce = '1' and bus_write = '1' and sel = '1' then
            if en_btc = '1' and o = x"88" then                              -- btc_trackball_w (bits 1:0)
               if tb_cs = '1' and bus_dataWrite(1) = '0' then               -- CS falls: latch
                  for c in 0 to 1 loop
                     latx(c) <= cnt(tbx(c), tbsx(c));
                     laty(c) <= cnt(tby(c), tbsy(c));
                  end loop;
               end if;
               tb_cs <= bus_dataWrite(1);
               if tb_rst = '0' and bus_dataWrite(0) = '0' then              -- reset becomes active
                  tbsx <= tbx;
                  tbsy <= tby;
               end if;
               tb_rst <= not bus_dataWrite(0);
            end if;
            if en_tmo = '1' and o = x"90" then                              -- tokimeki_serial_w
               -- sensors
               if bus_dataWrite(1) = '1' then
                  ser_data <= (others => '0'); ser_id <= (others => '0');
                  ser_val  <= (others => '0'); ser_len <= (others => '0');
               elsif ser_clk = '0' and bus_dataWrite(5) = '1' then
                  if ser_len < 5 then
                     nb := "000" & ser_val;
                     nb(4 - to_integer(ser_len)) := bus_dataWrite(4);
                     ser_val <= nb(4 downto 0);
                     if ser_len = 4 then
                        ser_id <= nb(4 downto 0);
                        if nb(4 downto 0) = "11010" then ser_data <= x"00" & gsr;  -- 1Ah: GSR
                        else ser_data <= (others => '0'); end if;
                     end if;
                  elsif ser_len >= 6 then
                     ser_data <= ser_data(14 downto 0) & '0';
                  end if;
                  if ser_len /= 15 then ser_len <= ser_len + 1; end if;
               end if;
               ser_clk <= bus_dataWrite(5);
               -- printer
               bit1v := bus_dataWrite(0);
               if bit1v = '1' and pr_bit = '0' then
                  pr_ticks <= (others => '0');
               elsif bit1v = '0' and pr_bit = '1' then
                  tk := pr_ticks;
                  if tk >= 9000 then
                     pr_curbit <= (others => '0');
                  else
                     if pr_curbit = 0 then acc := (others => '0'); else acc := pr_acc; end if;
                     if tk >= 4000 and tk <= 5600 then acc(to_integer(pr_curbit(2 downto 0))) := '1'; end if;
                     pr_acc <= acc;
                     if (pr_curbyte(0) = '0' and pr_curbit = 6) or (pr_curbyte(0) = '1' and pr_curbit = 7) then
                        pr_hist    <= pr_hist(39 downto 0) & acc;
                        pr_curbyte <= pr_curbyte + 1; pr_curbit <= (others => '0');
                     else
                        pr_curbit <= pr_curbit + 1;
                     end if;
                  end if;
               end if;
               pr_bit <= bit1v;
            end if;
         end if;

         -- printer: tick counter (CPU clock / 16 = clk1x / 8), command completion
         pr_div <= pr_div + 1;
         if pr_div = 7 and pr_ticks /= x"FFFFF" then pr_ticks <= pr_ticks + 1; end if;
         if pr_curbyte = 6 then
            if pr_hist = x"11F911F911F9" then                                -- 3 x {print command 11h, F9h}
               printing   <= '1';
               print_left <= to_unsigned(33868800, 26);                    -- 1 s
            end if;
            pr_curbyte <= (others => '0');
            pr_curbit  <= (others => '0');
         end if;
         if printing = '1' then
            if print_left = 0 then printing <= '0'; else print_left <= print_left - 1; end if;
         end if;

         -- device check
         eep4_q <= eep_bit4;
         if dc_loaded = '0' then
            dc_val    <= dc_start;
            dc_loaded <= '1';
         elsif eep_bit4 = '1' and eep4_q = '0' then
            dc_val <= dc_val(14 downto 0) & dc_val(15);
         end if;

         if reset = '1' then
            tb_cs <= '1'; tb_rst <= '0';
            hb_sig <= '1'; ser_clk <= '0'; ser_len <= (others => '0'); ser_id <= (others => '0');
            ser_val <= (others => '0'); ser_data <= (others => '0');
            pr_bit <= '0'; pr_curbit <= (others => '0'); pr_curbyte <= (others => '0'); printing <= '0';
            dc_loaded <= '0';
         end if;
      end if;
   end process;

end architecture;
