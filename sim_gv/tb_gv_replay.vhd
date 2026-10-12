-- Differential replay of MAME's Susume SCSI traffic against gv_board.
--
-- Vectors come from tools/gv_trace_replay.py (MAME 0.289 trace + chdman-extracted test image;
-- never committed).  Every EXP1 register read is compared with the value MAME returned and
-- every DMA ch5 to-RAM payload is CRC32-compared with MAME's.  READ SUB-CHANNEL payloads carry
-- the CD-DA play position, which depends on real time, so only their status bytes are judged.
--
--   VEC directory generic: replay.txt, toc.txt, sectors.txt, expect.txt

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_gv_replay is
   generic (
      VEC      : string  := "../replay/";
      MAX_OPS  : integer := 1000000;
      EE_INIT  : boolean := false             -- preload ee_init.txt (64 big-endian words) first
   );
end entity;

architecture sim of tb_gv_replay is

   signal clk        : std_logic := '0';
   signal reset      : std_logic := '1';
   signal done       : boolean := false;

   signal bus_addr   : unsigned(22 downto 0) := (others => '0');
   signal bus_read   : std_logic := '0';
   signal bus_write  : std_logic := '0';
   signal bus_dw     : std_logic_vector(7 downto 0) := (others => '0');
   signal bus_dr     : std_logic_vector(7 downto 0);
   signal irq10      : std_logic;

   signal dma_req    : std_logic;
   signal dma_rd_ena : std_logic := '0';
   signal dma_rd     : std_logic_vector(31 downto 0);
   signal dma_valid  : std_logic;
   signal dma_wr_ena : std_logic := '0';
   signal dma_wr     : std_logic_vector(31 downto 0) := (others => '0');

   signal toc_wr     : std_logic := '0';
   signal toc_wa     : unsigned(8 downto 0) := (others => '0');
   signal toc_wd     : std_logic_vector(31 downto 0) := (others => '0');
   signal mounted    : std_logic := '0';
   signal hps_req    : std_logic;
   signal hps_lba    : std_logic_vector(31 downto 0);
   signal hps_ack    : std_logic := '0';
   signal hps_wr     : std_logic := '0';
   signal hps_data   : std_logic_vector(15 downto 0) := (others => '0');
   signal cdda_l, cdda_r : signed(15 downto 0);
   signal ee_addr    : unsigned(5 downto 0) := (others => '0');
   signal ee_wdata   : std_logic_vector(15 downto 0) := (others => '0');
   signal ee_we      : std_logic := '0';

   -- DMA job handoff
   signal job_go     : std_logic := '0';
   signal job_busy   : std_logic := '0';
   signal job_xfer   : integer := 0;
   signal job_dir    : integer := 0;
   signal job_words  : integer := 0;
   type t_words is array(0 to 63) of std_logic_vector(31 downto 0);
   signal job_pl     : t_words;

   signal irq_flag   : std_logic := '0';
   signal irq_clr    : std_logic := '0';

   -- results of to-RAM transfers
   type t_res is array(0 to 4095) of std_logic_vector(31 downto 0);
   signal res_crc    : t_res := (others => (others => '0'));
   signal res_len    : t_res := (others => (others => '0'));

   -- sector store for the HPS model
   type t_map  is array(0 to 230000) of integer;
   type t_data is array(natural range <>) of integer;

   function crc32_byte(crc : std_logic_vector(31 downto 0); b : std_logic_vector(7 downto 0)) return std_logic_vector is
      variable c : std_logic_vector(31 downto 0) := crc;
   begin
      c(7 downto 0) := c(7 downto 0) xor b;
      for i in 0 to 7 loop
         if c(0) = '1' then c := ('0' & c(31 downto 1)) xor x"EDB88320";
         else c := '0' & c(31 downto 1); end if;
      end loop;
      return c;
   end function;

begin

   clk <= not clk after 14.76 ns when not done;      -- 33.8688 MHz

   dut : entity work.gv_board
   port map (
      clk1x => clk, ce => '1', reset => reset,
      bus_addr => bus_addr, bus_read => bus_read, bus_write => bus_write,
      bus_dataWrite => bus_dw, bus_dataRead => bus_dr,
      irq10 => irq10,
      dma_request => dma_req, dma_rd_ena => dma_rd_ena, dma_rd_data => dma_rd, dma_rd_valid => dma_valid,
      dma_wr_ena => dma_wr_ena, dma_wr_data => dma_wr,
      in_p1 => x"FFFFFFFF", in_p2 => x"FFFFFFFF", in_p3p4 => x"FFFFFFFF", coin_counter => open,
      ee_addr => ee_addr, ee_wdata => ee_wdata, ee_we => ee_we, ee_rdata => open, ee_dirty => open,
      toc_wr => toc_wr, toc_waddr => toc_wa, toc_wdata => toc_wd, img_mounted => mounted, cd_reset_req => open,
      hps_req => hps_req, hps_lba => hps_lba, hps_ack => hps_ack, hps_wr => hps_wr, hps_data => hps_data,
      cdda_l => cdda_l, cdda_r => cdda_r, disc_present => open
   );

   -- IRQ10 edge latch (stands in for I_STAT bit 10)
   process(clk)
   begin
      if rising_edge(clk) then
         if irq10 = '1' then irq_flag <= '1';
         elsif irq_clr = '1' then irq_flag <= '0'; end if;
      end if;
   end process;

   ----------------------------------------------------------------------------
   -- MiSTer HPS model: 2352-byte frames on request (Main psx_read_cd)
   ----------------------------------------------------------------------------
   hps : process
      variable smap  : t_map := (others => -1);
      variable sdata : t_data(0 to 6000 * 1176 - 1);
      file f     : text;
      variable l : line;
      variable c : character;
      variable n, slot, lba, v : integer;
      variable w : std_logic_vector(15 downto 0);
      variable good : boolean;
   begin
      file_open(f, VEC & "sectors.txt", read_mode);
      slot := 0;
      while not endfile(f) loop
         readline(f, l);
         if l'length > 0 and l(l'low) = 'S' then
            read(l, c); read(l, lba);
            smap(lba) := slot;
            for k in 0 to 48 loop
               readline(f, l);
               for j in 0 to 23 loop
                  hread(l, w, good);
                  sdata(slot * 1176 + k * 24 + j) := to_integer(unsigned(w));
               end loop;
            end loop;
            slot := slot + 1;
         end if;
      end loop;
      file_close(f);
      report "HPS model: " & integer'image(slot) & " frames loaded";

      loop
         wait until rising_edge(clk) and hps_req = '1';
         lba := to_integer(unsigned(hps_lba));
         for i in 1 to 40 loop wait until rising_edge(clk); end loop;
         hps_ack <= '1';
         wait until rising_edge(clk);
         slot := -1;
         if lba >= 0 and lba <= 230000 then slot := smap(lba); end if;
         for i in 0 to 1175 loop
            if slot >= 0 then
               hps_data <= std_logic_vector(to_unsigned(sdata(slot * 1176 + i), 16));
            else
               -- audio / unknown frame: deterministic pattern
               hps_data <= std_logic_vector(to_unsigned((lba * 7 + i) mod 65536, 16));
            end if;
            hps_wr <= '1';
            wait until rising_edge(clk);
            hps_wr <= '0';
            wait until rising_edge(clk);
         end loop;
         hps_ack <= '0';
         wait until rising_edge(clk);
      end loop;
   end process;

   ----------------------------------------------------------------------------
   -- DMA channel 5 model (sync mode 1, block size 1 word)
   ----------------------------------------------------------------------------
   dma : process
      variable crc : std_logic_vector(31 downto 0);
      variable wd  : std_logic_vector(31 downto 0);
      variable tmo : integer;
   begin
      wait until rising_edge(clk) and job_go = '1';
      job_busy <= '1';
      crc := x"FFFFFFFF";
      for w in 0 to job_words - 1 loop
         tmo := 0;
         while dma_req = '0' loop
            wait until rising_edge(clk);
            tmo := tmo + 1;
            exit when tmo > 40000000;
         end loop;
         if tmo > 40000000 then
            report "DMA xfer " & integer'image(job_xfer) & " stalled at word " & integer'image(w) severity error;
            exit;
         end if;
         if job_dir = 0 then
            dma_rd_ena <= '1';
            loop
               wait until rising_edge(clk);
               exit when dma_valid = '1';
            end loop;
            wd := dma_rd;
            dma_rd_ena <= '0';
            for b in 0 to 3 loop crc := crc32_byte(crc, wd(b*8+7 downto b*8)); end loop;
         else
            dma_wr     <= job_pl(w);
            dma_wr_ena <= '1';
            wait until rising_edge(clk);
            dma_wr_ena <= '0';
         end if;
         for i in 1 to 3 loop wait until rising_edge(clk); end loop;   -- block re-arm gap
      end loop;
      if job_dir = 0 then
         res_crc(job_xfer) <= crc xor x"FFFFFFFF";
         res_len(job_xfer) <= std_logic_vector(to_unsigned(job_words * 4, 32));
      end if;
      job_busy <= '0';
   end process;

   ----------------------------------------------------------------------------
   -- replay
   ----------------------------------------------------------------------------
   stim : process
      file f, fe   : text;
      variable l   : line;
      variable c   : character;
      variable a, d, e, wt, xf, dir, nw, nbytes : integer;
      variable av  : std_logic_vector(23 downto 0);
      variable dv  : std_logic_vector(7 downto 0);
      variable wv  : std_logic_vector(31 downto 0);
      variable good: boolean;
      variable lineno, nreads, nmis, nops : integer := 0;
      variable op  : string(1 to 2);
      variable ok_x, bad_x, sub_x : integer := 0;
      variable tmo : integer;
      variable max_xf : integer := 0;

      procedure tick(n : integer) is
      begin
         for i in 1 to n loop wait until rising_edge(clk); end loop;
      end procedure;
   begin
      tick(10);
      if EE_INIT then
         file_open(f, VEC & "ee_init.txt", read_mode);
         for i in 0 to 63 loop
            readline(f, l);
            hread(l, wv(15 downto 0));
            ee_addr <= to_unsigned(i, 6); ee_wdata <= wv(15 downto 0); ee_we <= '1';
            tick(1);
         end loop;
         ee_we <= '0';
         file_close(f);
      end if;
      reset <= '0';
      tick(10);

      -- TOC download then mount (Main: send_cue_and_metadata, then mount_cd)
      file_open(f, VEC & "toc.txt", read_mode);
      a := 0;
      while not endfile(f) loop
         readline(f, l);
         hread(l, wv, good);
         toc_wd <= wv; toc_wa <= to_unsigned(a, 9); toc_wr <= '1';
         tick(1);
         toc_wr <= '0';
         tick(1);
         a := a + 1;
      end loop;
      file_close(f);
      mounted <= '1';
      tick(100);

      file_open(f, VEC & "replay.txt", read_mode);
      while not endfile(f) and nops < MAX_OPS loop
         readline(f, l);
         lineno := lineno + 1;
         read(l, c);
         if c = 'W' then
            hread(l, av); hread(l, dv);
            bus_addr <= unsigned(av(22 downto 0)); bus_dw <= dv; bus_write <= '1';
            tick(1);
            bus_write <= '0';
            tick(6);
         elsif c = 'R' then
            hread(l, av); hread(l, dv); read(l, wt);
            if wt = 1 then
               tmo := 0;
               while irq_flag = '0' and tmo < 40000000 loop tick(1); tmo := tmo + 1; end loop;
               if tmo >= 40000000 then
                  report "line " & integer'image(lineno) & ": no IRQ10 before ISR read" severity warning;
               end if;
               irq_clr <= '1'; tick(1); irq_clr <= '0';
               tick(20);
            end if;
            bus_addr <= unsigned(av(22 downto 0)); bus_read <= '1';
            tick(1);
            bus_read <= '0';
            tick(1);
            nreads := nreads + 1;
            if bus_dr /= dv then
               nmis := nmis + 1;
               if nmis <= 40 then
                  report "MISMATCH line " & integer'image(lineno) & " addr " & to_hstring(av) &
                         " got " & to_hstring(bus_dr) & " MAME " & to_hstring(dv) severity warning;
               end if;
            end if;
            tick(5);
         elsif c = 'D' then
            read(l, xf); read(l, dir); read(l, nw);
            max_xf := xf;
            while job_busy = '1' loop tick(1); end loop;
            if dir = 1 then
               readline(f, l); lineno := lineno + 1;
               read(l, c);
               for i in 0 to nw - 1 loop
                  hread(l, wv); job_pl(i) <= wv;
               end loop;
            end if;
            job_xfer <= xf; job_dir <= dir; job_words <= nw; job_go <= '1';
            tick(1);
            job_go <= '0';
            tick(2);
         end if;
         nops := nops + 1;
      end loop;
      file_close(f);
      while job_busy = '1' loop tick(1); end loop;
      tick(100);

      -- DMA payload comparison
      file_open(fe, VEC & "expect.txt", read_mode);
      while not endfile(fe) loop
         readline(fe, l);
         read(l, xf); read(l, nbytes); hread(l, wv); read(l, c); read(l, op);
         if xf > max_xf then
            null;
         elsif to_integer(unsigned(res_len(xf))) = nbytes then
            if res_crc(xf) = wv then
               ok_x := ok_x + 1;
            elsif op = "42" then
               sub_x := sub_x + 1;                 -- play position differs (real-time CD-DA)
            else
               bad_x := bad_x + 1;
               if bad_x <= 20 then
                  report "DMA xfer " & integer'image(xf) & " op " & op & " CRC " & to_hstring(res_crc(xf)) &
                         " MAME " & to_hstring(wv) severity warning;
               end if;
            end if;
         else
            bad_x := bad_x + 1;
            if bad_x <= 20 then report "DMA xfer " & integer'image(xf) & " not performed" severity warning; end if;
         end if;
      end loop;
      file_close(fe);

      report "REPLAY SUMMARY: ops=" & integer'image(nops) & " reads=" & integer'image(nreads) &
             " read_mismatches=" & integer'image(nmis) &
             " dma_ok=" & integer'image(ok_x) & " dma_bad=" & integer'image(bad_x) &
             " subchannel_position_only=" & integer'image(sub_x);
      if nmis = 0 and bad_x = 0 then
         report "RESULT: PASS";
      else
         report "RESULT: FAIL";
      end if;
      done <= true;
      wait;
   end process;

end architecture;
