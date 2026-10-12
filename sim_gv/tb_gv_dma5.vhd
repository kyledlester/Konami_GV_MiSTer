-- Integration check of the real PSX DMA engine (rtl/dma.vhd) with gv_board on channel 5,
-- programmed exactly like Susume does (MAME trace): sync mode 1, block size 1 word,
-- CHCR 0x01000200 (to RAM) / 0x01000201 (from RAM), DMA started before NCR command 0x90.
--
--  1. READ(10) LBA 16 x1 into 0x010000           -> RAM must equal the sector's user data
--  2. READ(10) LBA 25 x3 into unaligned 0x01F728  -> multi-sector stream, RAM = user data
--  3. MODE SELECT 28 bytes from RAM 0x0A0998     -> target volume registers = payload (0xAE)
-- Uses VEC/sectors.txt (frames incl. LBA 16, 25..27) and VEC/toc.txt from gv_trace_replay.py.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_gv_dma5 is
   generic (VEC : string := "../replay/"; COOKED : boolean := false);   -- COOKED: CHD track type MODE1 (user data at frame byte 0)
end entity;

architecture sim of tb_gv_dma5 is
   signal clk, clk3x : std_logic := '0';
   signal c3   : integer range 0 to 2 := 0;
   signal idx3 : std_logic := '0';
   signal done : boolean := false;
   signal reset : std_logic := '1';

   -- dma <-> "SDRAM"
   signal cpuPaused   : std_logic := '0';
   signal dmaRequest, dmaOn, dmaStall : std_logic;
   signal ram_Adr     : std_logic_vector(22 downto 0);
   signal ram_ena     : std_logic;
   signal ram_cnt     : std_logic_vector(1 downto 0);
   signal dma_wr, dma_reqprocessed : std_logic := '0';
   signal dma_data    : std_logic_vector(31 downto 0) := (others => '0');
   signal fifo_adr    : std_logic_vector(22 downto 0);
   signal fifo_data   : std_logic_vector(31 downto 0);
   signal fifo_empty  : std_logic;
   signal fifo_read   : std_logic := '0';

   -- dma CPU bus
   signal dbus_addr   : unsigned(6 downto 0) := (others => '0');
   signal dbus_dw     : std_logic_vector(31 downto 0) := (others => '0');
   signal dbus_rd, dbus_wr : std_logic := '0';
   signal dbus_dr     : std_logic_vector(31 downto 0);

   -- ch5
   signal exp_req, exp_valid, exp_rena, exp_wena : std_logic;
   signal exp_rd, exp_wd : std_logic_vector(31 downto 0);

   -- gv EXP1 bus
   signal bus_addr   : unsigned(22 downto 0) := (others => '0');
   signal bus_read, bus_write : std_logic := '0';
   signal bus_dw     : std_logic_vector(7 downto 0) := (others => '0');
   signal bus_dr     : std_logic_vector(7 downto 0);
   signal irq10      : std_logic;
   signal irq_flag, irq_clr : std_logic := '0';

   signal toc_wr     : std_logic := '0';
   signal toc_wa     : unsigned(8 downto 0) := (others => '0');
   signal toc_wd     : std_logic_vector(31 downto 0) := (others => '0');
   signal mounted    : std_logic := '0';
   signal hps_req, hps_ack, hps_wr : std_logic := '0';
   signal hps_lba    : std_logic_vector(31 downto 0);
   signal hps_data   : std_logic_vector(15 downto 0) := (others => '0');

   type t_ram is array(0 to 2**19 - 1) of std_logic_vector(31 downto 0);   -- 2 MB
   signal ram : t_ram := (others => (others => '0'));
   signal ram_init_we : std_logic := '0';
   signal fifo_wr3    : std_logic := '0';
   signal fifo_wa3    : integer := 0;
   signal fifo_wd3    : std_logic_vector(31 downto 0) := (others => '0');
   signal ram_init_a  : integer := 0;
   signal ram_init_d  : std_logic_vector(31 downto 0);

   type t_map  is array(0 to 230000) of integer;
   type t_data is array(natural range <>) of integer;
begin
   -- phase-locked clk3x / clk1x; clk3xIndex marks one clk3x cycle per clk1x period
   clk3x <= not clk3x after 4.92 ns when not done;
   process(clk3x)
   begin
      if rising_edge(clk3x) then
         if c3 = 2 then c3 <= 0; else c3 <= c3 + 1; end if;
         if c3 = 2 then clk <= '1'; elsif c3 = 0 then clk <= '1'; else clk <= '0'; end if;
         if c3 = 2 then idx3 <= '1'; else idx3 <= '0'; end if;
      end if;
   end process;

   idma : entity work.dma
   port map (
      clk1x => clk, clk3x => clk3x, clk3xIndex => idx3, ce => '1', reset => reset,
      errorCHOP => open, errorDMACPU => open, errorDMAFIFO => open,
      TURBO => '0', TURBO_CACHE => '0', ram8mb => '0', ignoreCDTiming => '0',
      canDMA => '1', cpuPaused => cpuPaused, dmaRequest => dmaRequest, dmaStallCPU => dmaStall, dmaOn => dmaOn,
      irqOut => open,
      ram_Adr => ram_Adr, ram_cnt => ram_cnt, ram_ena => ram_ena,
      dma_wr => dma_wr, dma_reqprocessed => dma_reqprocessed, dma_data => dma_data,
      ram_dmafifo_adr => fifo_adr, ram_dmafifo_data => fifo_data, ram_dmafifo_empty => fifo_empty,
      ram_dmafifo_read => fifo_read,
      dma_cache_Adr => open, dma_cache_data => open, dma_cache_write => open,
      gpu_dmaRequest => '0', DMA_GPU_waiting => open, DMA_GPU_writeEna => open, DMA_GPU_readEna => open,
      DMA_GPU_write => open, DMA_GPU_read => (others => '0'),
      mdec_dmaWriteRequest => '0', mdec_dmaReadRequest => '0', DMA_MDEC_writeEna => open, DMA_MDEC_readEna => open,
      DMA_MDEC_write => open, DMA_MDEC_read => (others => '0'),
      cd_memctrl => (others => '0'), com0_delay => (others => '0'),
      DMA_CD_readEna => open, DMA_CD_read => (others => '0'),
      exp_dmaRequest => exp_req, DMA_EXP_readEna => exp_rena, DMA_EXP_read => exp_rd, exp_dmaDataValid => exp_valid,
      DMA_EXP_writeEna => exp_wena, DMA_EXP_write => exp_wd, dma5_done => open,
      spu_timing_on => '0', spu_timing_value => (others => '0'), spu_dmaRequest => '0',
      DMA_SPU_writeEna => open, DMA_SPU_readEna => open, DMA_SPU_write => open, DMA_SPU_read => (others => '0'),
      bus_addr => dbus_addr, bus_dataWrite => dbus_dw, bus_read => dbus_rd, bus_write => dbus_wr, bus_dataRead => dbus_dr,
      loading_savestate => '0', SS_reset => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren => '0', SS_rden => '0', SS_DataRead => open, SS_idle => open
   );

   dut : entity work.gv_board
   port map (
      clk1x => clk, ce => '1', reset => reset,
      bus_addr => bus_addr, bus_read => bus_read, bus_write => bus_write, bus_dataWrite => bus_dw, bus_dataRead => bus_dr,
      irq10 => irq10,
      dma_request => exp_req, dma_rd_ena => exp_rena, dma_rd_data => exp_rd, dma_rd_valid => exp_valid,
      dma_wr_ena => exp_wena, dma_wr_data => exp_wd,
      in_p1 => x"FFFFFFFF", in_p2 => x"FFFFFFFF", in_p3p4 => x"FFFFFFFF", coin_counter => open,
      ee_addr => (others => '0'), ee_wdata => (others => '0'), ee_we => '0', ee_rdata => open, ee_dirty => open,
      toc_wr => toc_wr, toc_waddr => toc_wa, toc_wdata => toc_wd, img_mounted => mounted, cd_reset_req => open,
      hps_req => hps_req, hps_lba => hps_lba, hps_ack => hps_ack, hps_wr => hps_wr, hps_data => hps_data,
      cdda_l => open, cdda_r => open, disc_present => open
   );

   -- CPU pause arbitration as in psx_top (canDMA = 1)
   process(clk)
   begin
      if rising_edge(clk) then
         if (cpuPaused = '1' and dmaOn = '1') or dmaRequest = '1' then cpuPaused <= '1'; else cpuPaused <= '0'; end if;
         if irq10 = '1' then irq_flag <= '1'; elsif irq_clr = '1' then irq_flag <= '0'; end if;
      end if;
   end process;

   -- SDRAM model, write side: drain the DMA output fifo in the clk3x domain (like sdram.sv)
   process(clk3x)
   begin
      if rising_edge(clk3x) then
         fifo_read <= '0';
         fifo_wr3  <= '0';
         if fifo_empty = '0' and fifo_read = '0' then
            ram(to_integer(unsigned(fifo_adr(20 downto 2)))) <= fifo_data;
            fifo_read <= '1';
         end if;
         if ram_init_we = '1' then ram(ram_init_a) <= ram_init_d; end if;
      end if;
   end process;

   -- SDRAM model: DMA reads (ram_ena: 1 + ram_cnt words) and the DMA write fifo
   process(clk)
      variable pend : integer := 0;
      variable addr : integer := 0;
      variable cnt  : integer := 0;
      variable dly  : integer := 0;
      variable nlog, nlog2 : integer := 0;
   begin
      if rising_edge(clk) then
         dma_reqprocessed <= '0';
         dma_wr <= '0';


         if exp_rena = '1' and exp_valid = '1' and nlog2 < 6 then
            report "bridge word " & to_hstring(exp_rd); nlog2 := nlog2 + 1;
         end if;
         if pend = 0 and ram_ena = '1' and cpuPaused = '1' then
            addr := to_integer(unsigned(ram_Adr(20 downto 2)));
            cnt  := 1 + to_integer(unsigned(ram_cnt));
            pend := cnt; dly := 4;
            dma_reqprocessed <= '1';
         elsif pend > 0 then
            if dly > 0 then dly := dly - 1;
            else
               dma_wr   <= '1';
               dma_data <= ram(addr);
               addr := addr + 1; pend := pend - 1;
            end if;
         end if;
      end if;
   end process;

   -- HPS model
   hps : process
      variable smap  : t_map := (others => -1);
      variable sdata : t_data(0 to 1600 * 1176 - 1);
      file f : text; variable l : line; variable c : character;
      variable slot, lba : integer; variable w : std_logic_vector(15 downto 0);
   begin
      file_open(f, VEC & "sectors.txt", read_mode);
      slot := 0;
      while not endfile(f) loop
         readline(f, l);
         if l'length > 0 and l(l'low) = 'S' then
            read(l, c); read(l, lba); smap(lba) := slot;
            for k in 0 to 48 loop
               readline(f, l);
               for j in 0 to 23 loop hread(l, w); sdata(slot * 1176 + k * 24 + j) := to_integer(unsigned(w)); end loop;
            end loop;
            slot := slot + 1;
         end if;
      end loop;
      loop
         wait until rising_edge(clk) and hps_req = '1';
         lba := to_integer(unsigned(hps_lba));
         for i in 1 to 60 loop wait until rising_edge(clk); end loop;
         hps_ack <= '1'; wait until rising_edge(clk);
         slot := smap(lba);
         for i in 0 to 1175 loop
            if slot >= 0 then hps_data <= std_logic_vector(to_unsigned(sdata(slot * 1176 + i), 16)); else hps_data <= x"0000"; end if;
            hps_wr <= '1'; wait until rising_edge(clk); hps_wr <= '0'; wait until rising_edge(clk);
         end loop;
         hps_ack <= '0'; wait until rising_edge(clk);
      end loop;
   end process;

   stim : process
      file f : text; variable l : line; variable c : character;
      variable wv : std_logic_vector(31 downto 0);
      variable a, errs, n, lba, slotw : integer := 0;
      variable v8 : std_logic_vector(7 downto 0);
      type t_sec is array(0 to 1175) of std_logic_vector(15 downto 0);
      variable sec : t_sec;
      variable w : std_logic_vector(15 downto 0);
      variable b0, b1 : std_logic_vector(7 downto 0);

      procedure tick(k : integer) is begin for i in 1 to k loop wait until rising_edge(clk); end loop; end procedure;
      procedure ncr_w(r : integer; v : std_logic_vector(7 downto 0)) is
      begin
         bus_addr <= to_unsigned(r * 2, 23); bus_dw <= v; bus_write <= '1'; tick(1); bus_write <= '0'; tick(4);
      end procedure;
      procedure ncr_r(r : integer; v : out std_logic_vector(7 downto 0)) is
      begin
         bus_addr <= to_unsigned(r * 2, 23); bus_read <= '1'; tick(1); bus_read <= '0'; tick(1); v := bus_dr; tick(3);
      end procedure;
      procedure dma_w(ch_reg : integer; v : std_logic_vector(31 downto 0)) is
      begin
         dbus_addr <= to_unsigned(ch_reg, 7); dbus_dw <= v; dbus_wr <= '1'; tick(1); dbus_wr <= '0'; tick(2);
      end procedure;
      procedure wait_irq(expect_is : std_logic_vector(7 downto 0)) is
         variable t : integer := 0; variable st, ss, is_v : std_logic_vector(7 downto 0);
      begin
         while irq_flag = '0' and t < 20000000 loop tick(1); t := t + 1; end loop;
         irq_clr <= '1'; tick(1); irq_clr <= '0';
         ncr_r(4, st); ncr_r(6, ss); ncr_r(5, is_v);
         if is_v /= expect_is then
            report "IRQ: IS=" & to_hstring(is_v) & " expected " & to_hstring(expect_is) & " ST=" & to_hstring(st) severity warning;
            errs := errs + 1;
         end if;
      end procedure;
      procedure command(cdb : std_logic_vector; tc : integer; madr : integer; words : integer; to_ram : boolean) is
         variable v : std_logic_vector(7 downto 0);
         variable cv : std_logic_vector(cdb'length - 1 downto 0) := cdb;
      begin
         ncr_w(3, x"44"); ncr_w(4, x"04");
         ncr_w(2, x"80");
         for i in 0 to cv'length / 8 - 1 loop ncr_w(2, cv(cv'high - i*8 downto cv'high - i*8 - 7)); end loop;
         ncr_w(3, x"42");
         wait_irq(x"18");
         if tc > 0 then
            ncr_w(14, std_logic_vector(to_unsigned(tc / 65536, 8)));
            ncr_w(1, std_logic_vector(to_unsigned((tc / 256) mod 256, 8)));
            ncr_w(0, std_logic_vector(to_unsigned(tc mod 256, 8)));
            dma_w(16#70#, x"33BB3B33");                                     -- DPCR
            dma_w(16#50#, std_logic_vector(to_unsigned(madr, 32)));         -- ch5 MADR
            dma_w(16#54#, std_logic_vector(to_unsigned(words * 65536 + 1, 32)));   -- BCR (N<<16)|1
            if to_ram then dma_w(16#58#, x"01000200"); else dma_w(16#58#, x"01000201"); end if;
            ncr_w(3, x"90");
            wait_irq(x"10");
         end if;
         ncr_w(3, x"11");
         wait_irq(x"08");
         ncr_r(2, v); if v /= x"00" then errs := errs + 1; report "status byte " & to_hstring(v) severity warning; end if;
         ncr_r(2, v); if v /= x"00" then errs := errs + 1; report "message byte " & to_hstring(v) severity warning; end if;
         ncr_w(3, x"12");
         wait_irq(x"20");
         tick(200);
      end procedure;

      procedure check_sector(hlba : integer; madr_byte : integer) is
         file sf : text; variable sl : line; variable sc : character; variable got_lba : integer;
         variable found : boolean := false; variable ramw : std_logic_vector(31 downto 0); variable b : integer;
         variable exp_b, got_b : std_logic_vector(7 downto 0); variable bad : integer := 0;
      begin
         file_open(sf, VEC & "sectors.txt", read_mode);
         while not endfile(sf) and not found loop
            readline(sf, sl);
            if sl'length > 0 and sl(sl'low) = 'S' then
               read(sl, sc); read(sl, got_lba);
               if got_lba = hlba then
                  for k in 0 to 48 loop
                     readline(sf, sl);
                     for j in 0 to 23 loop hread(sl, w); sec(k * 24 + j) := w; end loop;
                  end loop;
                  found := true;
               end if;
            end if;
         end loop;
         file_close(sf);
         assert found report "frame not in vectors" severity failure;
         for i in 0 to 2047 loop
            if COOKED then w := sec(i / 2); else w := sec(8 + i / 2); end if;
            if i mod 2 = 0 then exp_b := w(7 downto 0); else exp_b := w(15 downto 8); end if;
            b := madr_byte + i;
            ramw := ram(b / 4);
            got_b := ramw((b mod 4) * 8 + 7 downto (b mod 4) * 8);
            if got_b /= exp_b then
               if bad < 12 then report "  byte " & integer'image(i) & " got " & to_hstring(got_b) & " exp " & to_hstring(exp_b); end if;
               bad := bad + 1;
            end if;
         end loop;
         if bad /= 0 then
            report "sector HPS LBA " & integer'image(hlba) & " at " & integer'image(madr_byte) & ": " & integer'image(bad) & " bytes wrong" severity warning;
            errs := errs + 1;
         else
            report "sector HPS LBA " & integer'image(hlba) & " OK in RAM at 0x" & to_hstring(to_unsigned(madr_byte, 24));
         end if;
      end procedure;
   begin
      tick(10); reset <= '0'; tick(10);
      file_open(f, VEC & "toc.txt", read_mode);
      while not endfile(f) loop
         readline(f, l); hread(l, wv);
         toc_wd <= wv; toc_wa <= to_unsigned(a, 9); toc_wr <= '1'; tick(1); toc_wr <= '0'; tick(1); a := a + 1;
      end loop;
      file_close(f);
      mounted <= '1'; tick(50);

      -- NCR init like the BIOS
      ncr_w(3, x"02"); ncr_w(3, x"00");
      ncr_w(4, x"04"); ncr_w(11, x"48"); ncr_w(12, x"E7"); ncr_w(13, x"00"); ncr_w(9, x"04"); ncr_w(5, x"7A");
      ncr_w(7, x"00"); ncr_w(6, x"05");
      ncr_w(3, x"03"); wait_irq(x"80");

      -- 1. READ(10) LBA 16 x1 -> 0x010000
      command(x"28000000001000000100", 2048, 16#010000#, 512, true);
      check_sector(16 + 150, 16#010000#);

      -- 2. READ(10) LBA 25 x3 -> 0x01F728 (unaligned to sectors, word aligned)
      command(x"28000000001900000300", 3 * 2048, 16#01F728#, 3 * 512, true);
      check_sector(25 + 150, 16#01F728#);
      check_sector(26 + 150, 16#01F728# + 2048);
      check_sector(27 + 150, 16#01F728# + 4096);

      -- 3. MODE SELECT, 28 bytes from RAM 0x0A0998 (Susume's volume AE payload)
      ram_init_a <= 16#0A0998# / 4 + 0; ram_init_d <= x"08800000"; ram_init_we <= '1'; tick(1);
      ram_init_a <= 16#0A0998# / 4 + 1; ram_init_d <= x"D9580300"; tick(1);
      ram_init_a <= 16#0A0998# / 4 + 2; ram_init_d <= x"00080000"; tick(1);
      ram_init_a <= 16#0A0998# / 4 + 3; ram_init_d <= x"00040E8E"; tick(1);
      ram_init_a <= 16#0A0998# / 4 + 4; ram_init_d <= x"00000000"; tick(1);
      ram_init_a <= 16#0A0998# / 4 + 5; ram_init_d <= x"AE02AE01"; tick(1);
      ram_init_a <= 16#0A0998# / 4 + 6; ram_init_d <= x"FF08FF04"; tick(1);
      ram_init_we <= '0'; tick(2);
      command(x"151000001C00", 28, 16#0A0998#, 7, false);
      if << signal .tb_gv_dma5.dut.icdrom.vol_l : unsigned(7 downto 0) >> /= x"AE" or
         << signal .tb_gv_dma5.dut.icdrom.vol_r : unsigned(7 downto 0) >> /= x"AE" then
         report "MODE SELECT volume not applied" severity warning;
         errs := errs + 1;
      else
         report "MODE SELECT via DMA from RAM: CD-DA volume = AE/AE";
      end if;

      -- 4. READ TOC, MSF format, starting at track 2, 20 bytes -> header + T2 + T3 descriptors
      --    MAME: len = 2 + (35-2+2)*8 = 0x011A, first 1, last 0x23; T2 starts LBA 8073 -> MSF(8223) = 01:49:48
      --    (audio, ADR/ctl 0x10); T3 LBA 23007 -> MSF(23157) = 05:08:57
      if not COOKED then
      command(x"43020000000002001400", 20, 16#030000#, 5, true);
      if ram(16#030000# / 4 + 0) = x"23011A01" and ram(16#030000# / 4 + 1) = x"00021000" and
         ram(16#030000# / 4 + 2) = x"30310100" and ram(16#030000# / 4 + 3) = x"00031000" and
         ram(16#030000# / 4 + 4) = x"39080500" then
         report "READ TOC (MSF) bytes match MAME";
      else
         report "READ TOC (MSF) mismatch: " & to_hstring(ram(16#030000# / 4)) & " " & to_hstring(ram(16#030000# / 4 + 1)) & " " &
                to_hstring(ram(16#030000# / 4 + 2)) & " " & to_hstring(ram(16#030000# / 4 + 3)) & " " & to_hstring(ram(16#030000# / 4 + 4)) severity warning;
         errs := errs + 1;
      end if;
      end if;

      if errs = 0 then report "RESULT: PASS"; else report "RESULT: FAIL (" & integer'image(errs) & ")"; end if;
      done <= true;
      wait;
   end process;
end architecture;
