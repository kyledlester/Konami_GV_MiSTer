-- Konami GV: optical media backend.
--
-- Source of truth is the original CHD (or CUE/BIN) mounted through MiSTer Main's standard
-- PSX CD path (core name "PSX", OSD slot S1 "CUECHD"):
--   * Main parses the image and sends a TOC (struct disk_t, ioctl index 251, 32-bit words)
--     before mounting; track 1 starts at HPS LBA 150, later tracks are contiguous.
--   * sd_rd[1] with sd_lba1 = HPS LBA returns one raw 2352-byte frame (1176 16-bit words);
--     audio frames are delivered as little-endian 16-bit samples (Main byte-swaps CHD audio).
--
-- This block only knows frames.  It converts to MAME logical frames (LBA = HPS LBA - 150),
-- keeps the TOC, serves Mode 1 user data to the SCSI target from a two-sector cache with
-- read-ahead, and streams audio frames to the CD-DA player.  It knows nothing about SCSI.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gv_cd_media is
   port (
      clk            : in  std_logic;
      reset          : in  std_logic;

      -- TOC download (ioctl index 251 assembled to 32-bit words, word address)
      toc_wr         : in  std_logic;
      toc_waddr      : in  unsigned(8 downto 0);
      toc_wdata      : in  std_logic_vector(31 downto 0);
      img_mounted    : in  std_logic;                 -- slot 1 mount state (size > 0)
      reset_request  : out std_logic := '0';          -- TOC metadata bit 2 (level): Main asks for a reset

      -- TOC read port (SCSI target)
      disc_present   : out std_logic;
      toc_last       : out unsigned(6 downto 0);
      toc_addr       : in  unsigned(6 downto 0);
      toc_start      : out unsigned(19 downto 0);
      toc_audio      : out std_logic;
      first_audio    : out unsigned(19 downto 0);    -- frames below are data (CD-DA plays silence)

      -- Mode 1 user data port
      sec_lba        : in  unsigned(19 downto 0);
      sec_want       : in  std_logic;
      sec_next       : in  std_logic;
      sec_ready      : out std_logic;
      sec_addr       : in  unsigned(10 downto 0);
      sec_data       : out std_logic_vector(7 downto 0);

      -- audio frame port (CD-DA player)
      aud_req        : in  std_logic;                 -- level: fetch aud_lba
      aud_ack        : out std_logic := '0';          -- request accepted (pulse)
      aud_lba        : in  unsigned(19 downto 0);
      aud_wr         : out std_logic := '0';          -- one 16-bit sample word
      aud_wdata      : out std_logic_vector(15 downto 0);
      aud_done       : out std_logic := '0';          -- frame complete (pulse)

      -- MiSTer HPS block device (sd slot 1, 2352-byte blocks)
      hps_req        : out std_logic := '0';
      hps_lba        : out std_logic_vector(31 downto 0) := (others => '0');
      hps_ack        : in  std_logic;
      hps_wr         : in  std_logic;
      hps_data       : in  std_logic_vector(15 downto 0)
   );
end entity;

architecture rtl of gv_cd_media is

   -- TOC: entry i = track i+1, entry ntracks = lead-out
   type t_toc is array(0 to 127) of std_logic_vector(20 downto 0);
   signal toc        : t_toc := (others => (others => '0'));
   signal toc_q      : std_logic_vector(20 downto 0) := (others => '0');
   signal ntracks    : unsigned(6 downto 0) := (others => '0');
   signal total_lba  : unsigned(19 downto 0) := (others => '0');
   signal toc_ok     : std_logic := '0';
   signal first_aud  : unsigned(19 downto 0) := (others => '1');
   signal toc_we     : std_logic := '0';
   signal toc_wa     : unsigned(6 downto 0) := (others => '0');
   signal toc_wd     : std_logic_vector(20 downto 0) := (others => '0');
   signal pend_start : unsigned(19 downto 0) := (others => '0');

   -- data sector cache: 2 x 2048 words (1176 used)
   type t_buf is array(0 to 4095) of std_logic_vector(15 downto 0);
   signal buf        : t_buf;
   signal buf_wa     : unsigned(11 downto 0) := (others => '0');
   signal buf_we     : std_logic := '0';
   signal buf_wd     : std_logic_vector(15 downto 0) := (others => '0');
   signal buf_ra     : unsigned(11 downto 0);
   signal buf_q      : std_logic_vector(15 downto 0) := (others => '0');
   signal rd_hi      : std_logic := '0';
   signal rd_audio   : std_logic := '0';

   signal tag0, tag1 : unsigned(19 downto 0) := (others => '0');
   -- frame layout per buffer = word offset of the 2048 user-data bytes (MAME cdrom_file::read_data
   -- with datatype MODE1): 8 = raw Mode 1 frame (MODE1_RAW, CUE MODE1/2352: byte 16), 12 = raw Mode 2
   -- frame (MODE2_RAW, e.g. Simpsons Bowling: byte 24, after the XA subheader), 0 = cooked Mode 1
   -- (CHD track type MODE1: byte 0). Main passes CHD frames through unchanged and does not report the
   -- track format, so each arriving frame's 12-byte sync pattern (00 FF x10 00) and header mode byte
   -- (byte 15) decide.
   signal off0, off1 : unsigned(3 downto 0) := to_unsigned(8, 4);
   signal f_sync     : std_logic := '1';
   signal f_mode2    : std_logic := '0';
   signal hit_off    : unsigned(3 downto 0);
   signal frame_off  : unsigned(3 downto 0);
   signal val0, val1 : std_logic := '0';
   signal hit0, hit1 : std_logic;

   type t_fetch is (F_IDLE, F_REQ, F_ACK, F_DONE);
   signal fst        : t_fetch := F_IDLE;
   signal f_audio    : std_logic := '0';
   signal f_buf      : std_logic := '0';
   signal f_lba      : unsigned(19 downto 0) := (others => '0');
   signal f_word     : unsigned(10 downto 0) := (others => '0');

begin

   ---------------------------------------------------------------------------
   -- TOC
   ---------------------------------------------------------------------------
   process(clk)
   begin
      if rising_edge(clk) then
         if toc_we = '1' then
            toc(to_integer(toc_wa)) <= toc_wd;
         end if;
         toc_q <= toc(to_integer(toc_addr));
      end if;
   end process;

   toc_start    <= unsigned(toc_q(19 downto 0));
   toc_audio    <= toc_q(20);
   toc_last     <= ntracks;
   disc_present <= toc_ok and img_mounted;
   first_audio  <= first_aud;

   process(clk)
      variable w   : integer;
      variable trk : integer;
      variable s   : unsigned(19 downto 0);
   begin
      if rising_edge(clk) then
         toc_we        <= '0';
         if toc_wr = '1' then
            w := to_integer(toc_waddr);
            if w = 0 then
               ntracks   <= unsigned(toc_wdata(6 downto 0));
               toc_ok    <= '0';
               first_aud <= (others => '1');
            elsif w = 1 then
               -- total_lba = table->end (HPS frames incl. the 150 offset) -> lead-out
               total_lba <= resize(unsigned(toc_wdata(19 downto 0)) - 150, 20);
            elsif w = 3 then
               reset_request <= toc_wdata(18);
            elsif w >= 4 then
               trk := (w - 4) / 4;
               if trk < 99 then
                  case (w - 4) mod 4 is
                     when 0 =>
                        -- track 1 is reported as 0 (it really starts at HPS 150)
                        if trk = 0 then s := (others => '0');
                        else s := resize(unsigned(toc_wdata(19 downto 0)) - 150, 20); end if;
                        pend_start <= s;
                     when 2 =>
                        -- bit 16 set = audio track
                        toc_we <= '1';
                        toc_wa <= to_unsigned(trk, 7);
                        toc_wd <= toc_wdata(16) & std_logic_vector(pend_start);
                        if toc_wdata(16) = '1' and first_aud = x"FFFFF" then
                           first_aud <= pend_start;
                        end if;
                        if trk = to_integer(ntracks) - 1 then
                           toc_ok <= '1';
                        end if;
                     when others => null;
                  end case;
               end if;
            end if;
         end if;
         -- lead-out entry (after the last track's start is written)
         if toc_ok = '1' and toc_we = '0' and toc_wr = '0' then
            toc_we <= '1';
            toc_wa <= ntracks;
            toc_wd <= '1' & std_logic_vector(total_lba);
         end if;
      end if;
   end process;

   ---------------------------------------------------------------------------
   -- data sector cache
   ---------------------------------------------------------------------------
   hit0 <= '1' when val0 = '1' and tag0 = sec_lba else '0';
   hit1 <= '1' when val1 = '1' and tag1 = sec_lba else '0';
   sec_ready <= hit0 or hit1;

   -- user data: word 8 (raw Mode 1), word 12 (raw Mode 2), word 0 (cooked)
   hit_off <= off1 when hit1 = '1' else off0;
   frame_off <= to_unsigned(0, 4)  when f_sync = '0' else
                to_unsigned(12, 4) when f_mode2 = '1' else
                to_unsigned(8, 4);
   buf_ra  <= hit1 & (resize(sec_addr(10 downto 1), 11) + hit_off);

   process(clk)
   begin
      if rising_edge(clk) then
         if buf_we = '1' then
            buf(to_integer(buf_wa)) <= buf_wd;
         end if;
         buf_q <= buf(to_integer(buf_ra));
         rd_hi <= sec_addr(0);
         if sec_lba >= first_aud then rd_audio <= '1'; else rd_audio <= '0'; end if;
      end if;
   end process;
   -- MAME cdrom_file::read_data(.., CD_TRACK_MODE1) fails for audio-track frames -> zeros
   sec_data <= x"00"               when rd_audio = '1' else
               buf_q(15 downto 8)  when rd_hi = '1' else
               buf_q(7 downto 0);

   ---------------------------------------------------------------------------
   -- HPS fetch sequencer: data miss > audio > data read-ahead
   ---------------------------------------------------------------------------
   aud_wdata <= hps_data;

   process(clk)
      variable nxt : unsigned(19 downto 0);
   begin
      if rising_edge(clk) then
         buf_we   <= '0';
         aud_wr   <= '0';
         aud_done <= '0';
         aud_ack  <= '0';

         if reset = '1' or disc_present = '0' then
            fst     <= F_IDLE;
            hps_req <= '0';
            val0    <= '0';
            val1    <= '0';
         else
            case fst is
               when F_IDLE =>
                  nxt := sec_lba + 1;
                  if sec_want = '1' and hit0 = '0' and hit1 = '0' then
                     -- miss: keep a buffer that already holds the read-ahead sector
                     f_audio <= '0';
                     f_lba   <= sec_lba;
                     if val0 = '1' and tag0 = nxt then
                        f_buf <= '1'; val1 <= '0'; tag1 <= sec_lba;
                     else
                        f_buf <= '0'; val0 <= '0'; tag0 <= sec_lba;
                     end if;
                     fst <= F_REQ;
                  elsif aud_req = '1' then
                     aud_ack <= '1';
                     f_audio <= '1';
                     f_lba   <= aud_lba;
                     fst     <= F_REQ;
                  elsif sec_want = '1' and sec_next = '1' and
                        not ((val0 = '1' and tag0 = nxt) or (val1 = '1' and tag1 = nxt)) then
                     f_audio <= '0';
                     f_lba   <= nxt;
                     if hit0 = '1' then
                        f_buf <= '1'; val1 <= '0'; tag1 <= nxt;
                     else
                        f_buf <= '0'; val0 <= '0'; tag0 <= nxt;
                     end if;
                     fst <= F_REQ;
                  end if;

               when F_REQ =>
                  hps_lba <= std_logic_vector(resize(f_lba, 32) + 150);
                  hps_req <= '1';
                  f_word  <= (others => '0');
                  f_sync  <= '1';
                  f_mode2 <= '0';
                  fst     <= F_ACK;

               when F_ACK =>
                  if hps_ack = '1' then
                     hps_req <= '0';
                  end if;
                  if hps_wr = '1' and hps_ack = '1' then
                     -- sync check on words 0..5 (little-endian pairs: FF00, FFFF x4, 00FF)
                     if (f_word = 0 and hps_data /= x"FF00") or
                        (f_word >= 1 and f_word <= 4 and hps_data /= x"FFFF") or
                        (f_word = 5 and hps_data /= x"00FF") then
                        f_sync <= '0';
                     end if;
                     -- header bytes 14/15 = word 7 (little-endian): byte 15 = mode
                     if f_word = 7 then
                        if hps_data(15 downto 8) = x"02" then f_mode2 <= '1'; else f_mode2 <= '0'; end if;
                     end if;
                     if f_word < 1176 then
                        if f_audio = '1' then
                           aud_wr <= '1';
                        else
                           buf_we <= '1';
                           buf_wa <= f_buf & f_word;
                           buf_wd <= hps_data;
                        end if;
                     end if;
                     f_word <= f_word + 1;
                  end if;
                  if hps_req = '0' and hps_ack = '0' then
                     fst <= F_DONE;
                  end if;

               when F_DONE =>
                  if f_audio = '1' then
                     aud_done <= '1';
                  elsif f_buf = '0' then
                     if tag0 = f_lba then val0 <= '1'; off0 <= frame_off; end if;
                  else
                     if tag1 = f_lba then val1 <= '1'; off1 <= frame_off; end if;
                  end if;
                  fst <= F_IDLE;
            end case;
         end if;
      end if;
   end process;

end architecture;
