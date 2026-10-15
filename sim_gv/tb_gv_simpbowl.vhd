-- Replays MAME's Simpsons Bowling flash-port accesses (tools/mame_trace/simp_flashlog.lua output:
-- "R|W off mask data time", off = 32-bit word offset from 0x1F680080) through gv_simpbowl on the
-- byte-stepped EXP1 bus, with MAME's timestamps as the erase-timer time base, a DDR3/arbiter model
-- with latency on the memFlash port, and checks every read byte against MAME.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_gv_simpbowl is
   generic (
      EVENTS : string  := "flash_events.txt";
      MAXEV  : natural := 100000000;
      F16    : boolean := false              -- Sharp LH28F400 personality: offsets from 0x1F380000
   );
end entity;

architecture sim of tb_gv_simpbowl is
   function to_sl(b : boolean) return std_logic is begin if b then return '1'; else return '0'; end if; end function;
   signal clk1x, clk2x : std_logic := '1';
   signal time_ck      : unsigned(31 downto 0) := (others => '0');
   signal bus_addr     : unsigned(22 downto 0) := (others => '0');
   signal bus_read, bus_write : std_logic := '0';
   signal bus_wdata, bus_rdata : std_logic_vector(7 downto 0);
   signal bus_sel, bus_wait : std_logic;

   signal ddr_request, ddr_ack, ddr_we, ddr_rd, ddr_ready : std_logic := '0';
   signal ddr_addr     : std_logic_vector(23 downto 0);
   signal ddr_din, ddr_dout : std_logic_vector(63 downto 0) := (others => '0');
   signal ddr_be       : std_logic_vector(7 downto 0);
   signal host_rdata   : std_logic_vector(15 downto 0);
   signal host_wait, dirty, fill_active : std_logic;
   signal done         : boolean := false;
begin
   clk1x <= not clk1x after 14763 ps when not done;
   clk2x <= not clk2x after 7381 ps when not done;

   dut : entity work.gv_simpbowl
   port map (
      clk1x => clk1x, clk2x => clk2x, ce => '1', enable => to_sl(not F16), f16_en => to_sl(F16),
      blank_fill => '0', time_ck => time_ck,
      bus_addr => bus_addr, bus_read => bus_read, bus_write => bus_write,
      bus_dataWrite => bus_wdata, bus_dataRead => bus_rdata, bus_sel => bus_sel, bus_wait => bus_wait,
      tb_strobe => '0', tb_dx => (others => '0'), tb_dy => (others => '0'),
      host_addr => (others => '0'), host_we => '0', host_wdata => (others => '0'), host_rd => '0',
      host_rdata => host_rdata, host_wait => host_wait, dirty => dirty, dirty_clr => '0', fill_active => fill_active,
      ddr_request => ddr_request, ddr_ack => ddr_ack, ddr_addr => ddr_addr, ddr_din => ddr_din,
      ddr_be => ddr_be, ddr_we => ddr_we, ddr_rd => ddr_rd, ddr_dout => ddr_dout, ddr_dout_ready => ddr_ready);

   -- arbiter + DDR3: grant after a few cycles (GPU pause handshake), ack, read data later
   ddr : process
      type t_mem is array(0 to 2**20 - 1) of std_logic_vector(63 downto 0);
      variable mem : t_mem := (others => (others => '1'));    -- MAME intelfsh nvram_default: 0xFF
      variable w   : integer;
      variable v   : std_logic_vector(63 downto 0);
      variable lat : integer := 3;
   begin
      wait until rising_edge(clk2x);
      if ddr_request = '1' then
         for i in 1 to lat loop wait until rising_edge(clk2x); end loop;
         lat := (lat * 7 + 3) mod 11 + 2;                      -- vary 2..12 cycles
         w := to_integer(unsigned(ddr_addr(22 downto 3)));
         ddr_ack <= '1';
         if ddr_we = '1' then
            v := mem(w);
            for b in 0 to 7 loop
               if ddr_be(b) = '1' then v(8*b+7 downto 8*b) := ddr_din(8*b+7 downto 8*b); end if;
            end loop;
            mem(w) := v;
         end if;
         wait until rising_edge(clk2x);
         ddr_ack <= '0';
         if ddr_rd = '1' then
            for i in 1 to 4 loop wait until rising_edge(clk2x); end loop;
            ddr_dout  <= mem(w);
            ddr_ready <= '1';
            wait until rising_edge(clk2x);
            ddr_ready <= '0';
         end if;
         while ddr_request = '1' loop wait until rising_edge(clk2x); end loop;
      end if;
   end process;

   stim : process
      file f        : text open read_mode is EVENTS;
      variable l    : line;
      variable rw   : character;
      variable sp   : character;
      variable off, msk, dat : std_logic_vector(31 downto 0);
      variable tr   : real;
      variable n, nerr, nrd, nwait : natural := 0;
      variable lane0: integer;
      variable exp  : std_logic_vector(7 downto 0);
      variable o8   : std_logic_vector(7 downto 0);
      variable o24  : std_logic_vector(23 downto 0);
      variable base : natural;
      variable fill_t : real := -1.0;    -- MAME time at which the running fill started
      variable tk     : real;
      variable thi    : integer;
   begin
      wait for 100 ns;
      wait until rising_edge(clk1x);
      while not endfile(f) and n < MAXEV loop
         readline(f, l);
         read(l, rw); read(l, sp);
         if F16 then
            hread(l, o24); read(l, sp);
            base := 16#380000# + to_integer(unsigned(o24));
         else
            hread(l, o8); read(l, sp);
            base := 16#680080# + to_integer(unsigned(o8));
         end if;
         hread(l, msk); read(l, sp);
         hread(l, dat); read(l, sp);
         read(l, tr);
         -- real time: an 8 MB fill takes ~0.1 s on hardware; the replay compresses MAME time, so an
         -- event more than 0.2 s (MAME time) after a fill started waits for the fill to finish
         if fill_active = '1' and fill_t >= 0.0 and tr >= fill_t + 0.2 then
            while fill_active = '1' loop wait until rising_edge(clk1x); end loop;
         end if;
         if fill_active = '0' then fill_t := -1.0; end if;
         -- clk1x cycles modulo 2**32 (the hardware counter wraps every ~127 s)
         tk  := tr * 33868800.0;
         tk  := tk - floor(tk / 4294967296.0) * 4294967296.0;
         thi := integer(floor(tk / 65536.0));
         time_ck <= to_unsigned(thi, 16) & to_unsigned(integer(floor(tk - real(thi) * 65536.0)), 16);
         wait until rising_edge(clk1x);     -- let timers see the new time before the access (MAME: timer first)
         if msk(15 downto 0) = x"FFFF" then lane0 := 0; else lane0 := 2; end if;
         for ln in lane0 to lane0 + 1 loop
            bus_addr <= to_unsigned(base + ln, 23);
            if rw = 'W' then
               bus_wdata <= dat(8*ln+7 downto 8*ln);
               bus_write <= '1';
               wait until rising_edge(clk1x);
               bus_write <= '0';
            else
               bus_read <= '1';
               wait until rising_edge(clk1x);
               while bus_wait = '1' loop
                  nwait := nwait + 1;
                  wait until rising_edge(clk1x);
               end loop;
               bus_read <= '0';
               wait until rising_edge(clk1x);
               exp := dat(8*ln+7 downto 8*ln);
               nrd := nrd + 1;
               if bus_rdata /= exp then
                  nerr := nerr + 1;
                  if nerr <= 20 then
                     report "MISMATCH ev " & integer'image(n + 1) & " t=" & real'image(tr) &
                            " addr " & to_hstring(std_logic_vector(bus_addr)) &
                            " got " & to_hstring(bus_rdata) & " exp " & to_hstring(exp);
                  end if;
               end if;
            end if;
         end loop;
         wait until rising_edge(clk1x);
         if fill_active = '1' and fill_t < 0.0 then fill_t := tr; end if;
         n := n + 1;
         if n mod 500000 = 0 then
            report "progress " & integer'image(n) & " events, " & integer'image(nerr) & " mismatches";
         end if;
      end loop;
      report "SUMMARY: events " & integer'image(n) & ", read bytes checked " & integer'image(nrd) &
             ", mismatches " & integer'image(nerr) & ", wait cycles " & integer'image(nwait);
      if nerr = 0 then report "RESULT: PASS"; else report "RESULT: FAIL"; end if;
      done <= true;
      wait;
   end process;
end architecture;
