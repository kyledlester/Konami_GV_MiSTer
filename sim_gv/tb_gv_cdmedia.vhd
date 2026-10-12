-- gv_cd_media frame layouts (MAME cdrom_file::read_data, datatype MODE1): the 2048 user bytes of a
-- frame delivered by MiSTer Main are at byte 0 (cooked MODE1 CHD), byte 16 (raw Mode 1:
-- MODE1_RAW / CUE MODE1/2352) or byte 24 (raw Mode 2: MODE2_RAW, e.g. Simpsons Bowling 829uaa02).
-- Each layout is fed through the HPS port and all 2048 bytes are read back on the sector port.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_gv_cdmedia is
end entity;

architecture sim of tb_gv_cdmedia is
   signal clk : std_logic := '0';
   signal done : boolean := false;
   signal toc_wr : std_logic := '0';
   signal toc_waddr : unsigned(8 downto 0) := (others => '0');
   signal toc_wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal sec_lba : unsigned(19 downto 0) := (others => '0');
   signal sec_want, sec_next : std_logic := '0';
   signal sec_ready : std_logic;
   signal sec_addr : unsigned(10 downto 0) := (others => '0');
   signal sec_data : std_logic_vector(7 downto 0);
   signal hps_req, hps_ack, hps_wr : std_logic := '0';
   signal hps_lba : std_logic_vector(31 downto 0);
   signal hps_data : std_logic_vector(15 downto 0) := (others => '0');
   signal kind : integer := 0;          -- 0 cooked, 1 raw mode 1, 2 raw mode 2

   function ubyte(lba, i : integer) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned((i * 7 + lba * 13 + i / 256) mod 256, 8));
   end function;

   -- byte n of the 2352-byte frame for logical LBA lba in layout k
   function fbyte(k, lba, n : integer) return std_logic_vector is
      variable off : integer;
   begin
      if k = 0 then
         if n < 2048 then return ubyte(lba, n); else return x"00"; end if;
      end if;
      if n = 0 or n = 11 then return x"00"; end if;
      if n < 11 then return x"FF"; end if;
      if n < 15 then return x"01"; end if;                      -- MSF (not checked)
      if n = 15 then
         if k = 1 then return x"01"; else return x"02"; end if;   -- header mode byte
      end if;
      if k = 1 then off := 16; else off := 24; end if;
      if k = 2 and n < 24 then
         if n = 18 or n = 22 then return x"08"; else return x"00"; end if;   -- XA subheader, Form 1
      end if;
      if n >= off and n < off + 2048 then return ubyte(lba, n - off); end if;
      return x"5A";                                             -- EDC/ECC filler
   end function;
begin
   clk <= not clk after 14763 ps when not done;

   dut : entity work.gv_cd_media
   port map (
      clk => clk, reset => '0',
      toc_wr => toc_wr, toc_waddr => toc_waddr, toc_wdata => toc_wdata,
      img_mounted => '1', reset_request => open,
      disc_present => open, toc_last => open, toc_addr => (others => '0'), toc_start => open,
      toc_audio => open, first_audio => open,
      sec_lba => sec_lba, sec_want => sec_want, sec_next => sec_next, sec_ready => sec_ready,
      sec_addr => sec_addr, sec_data => sec_data,
      aud_req => '0', aud_ack => open, aud_lba => (others => '0'), aud_wr => open, aud_wdata => open,
      aud_done => open,
      hps_req => hps_req, hps_lba => hps_lba, hps_ack => hps_ack, hps_wr => hps_wr, hps_data => hps_data);

   -- MiSTer Main: on a request, ack and stream 1176 little-endian words of the frame
   hps : process
      variable lba : integer;
   begin
      wait until rising_edge(clk);
      if hps_req = '1' then
         lba := to_integer(unsigned(hps_lba)) - 150;
         for i in 1 to 5 loop wait until rising_edge(clk); end loop;
         hps_ack <= '1';
         wait until rising_edge(clk);
         for w in 0 to 1175 loop
            hps_data <= fbyte(kind, lba, 2 * w + 1) & fbyte(kind, lba, 2 * w);
            hps_wr   <= '1';
            wait until rising_edge(clk);
            hps_wr   <= '0';
            wait until rising_edge(clk);
         end loop;
         hps_ack <= '0';
         wait until rising_edge(clk);
      end if;
   end process;

   stim : process
      variable errs, nchk : integer := 0;
      procedure tocw(a : integer; d : std_logic_vector(31 downto 0)) is
      begin
         toc_waddr <= to_unsigned(a, 9); toc_wdata <= d; toc_wr <= '1';
         wait until rising_edge(clk);
         toc_wr <= '0';
         wait until rising_edge(clk);
      end procedure;
      procedure check(k, lba : integer; name : string) is
         variable bad : integer := 0;
      begin
         kind    <= k;
         sec_lba <= to_unsigned(lba, 20);
         sec_want <= '1';
         wait until rising_edge(clk);
         sec_want <= '0';
         for i in 0 to 100000 loop
            wait until rising_edge(clk);
            exit when sec_ready = '1';
         end loop;
         for i in 0 to 2047 loop
            sec_addr <= to_unsigned(i, 11);
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            nchk := nchk + 1;
            if sec_data /= ubyte(lba, i) then
               if bad < 5 then
                  report name & " byte " & integer'image(i) & " got " & to_hstring(sec_data) &
                         " exp " & to_hstring(ubyte(lba, i));
               end if;
               bad := bad + 1;
            end if;
         end loop;
         if bad = 0 then report name & ": 2048/2048 user bytes OK";
         else report name & ": " & integer'image(bad) & " bytes wrong"; errs := errs + 1; end if;
         -- let the read-ahead of the next frame finish before switching layouts
         for i in 0 to 4000 loop wait until rising_edge(clk); end loop;
      end procedure;
   begin
      wait until rising_edge(clk);
      tocw(0, x"00000001");                  -- one track
      tocw(1, x"00002800");                  -- end
      tocw(4, x"00000096");                  -- track 1 start (reported as 0)
      tocw(5, x"00002800");
      tocw(6, x"00000200");                  -- MSF, data track
      for i in 0 to 20 loop wait until rising_edge(clk); end loop;
      check(1, 100,  "raw Mode 1 frame (MODE1_RAW)");
      check(0, 300,  "cooked Mode 1 frame (CHD MODE1)");
      check(2, 500,  "raw Mode 2 frame (MODE2_RAW, user data at byte 24)");
      check(1, 700,  "raw Mode 1 frame again");
      if errs = 0 then report "RESULT: PASS"; else report "RESULT: FAIL"; end if;
      done <= true;
      wait;
   end process;
end architecture;
