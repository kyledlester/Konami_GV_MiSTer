-- gv_expio (Beat the Champ trackballs, Dead Eye guns, Tokimeki sensors/printer/device check) and
-- gv_sio_host (Beat the Champ factory host), checked against the MAME 0.289 behaviour they model
-- (konamigv.cpp, upd4701.cpp): counter latch on CS falling, reset origin, live read with CS high, gun
-- ports, GSR serial readout of sensor 1Ah, printer "print" command timing, device-check rotation and the
-- SIO1 "S" / "EN" / challenge-echo exchange.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_gv_expio is
end entity;

architecture sim of tb_gv_expio is
   signal clk : std_logic := '0';
   signal done : boolean := false;
   signal en_btc, en_gun, en_tmo : std_logic := '0';
   signal addr : unsigned(22 downto 0) := (others => '0');
   signal rd, wr : std_logic := '0';
   signal wdata, rdata : std_logic_vector(7 downto 0) := (others => '0');
   signal sel : std_logic;
   signal tb0s, tb1s : std_logic := '0';
   signal tb0x, tb0y, tb1x, tb1y : signed(9 downto 0) := (others => '0');
   signal gx1, gy1, gx2, gy2 : unsigned(15 downto 0) := (others => '0');
   signal gt1, gt2 : std_logic := '0';
   signal hb : std_logic := '0';
   signal gsr : std_logic_vector(7 downto 0) := x"5A";
   signal eep4 : std_logic := '0';
   signal dcb : std_logic;
   -- SIO host
   signal h_en, h_tx, h_pop, h_dsr, h_rxv, h_done : std_logic := '0';
   signal h_txd, h_rxd : std_logic_vector(7 downto 0) := (others => '0');
begin
   clk <= not clk after 14763 ps when not done;

   dut : entity work.gv_expio
   port map (
      clk1x => clk, ce => '1', reset => '0', en_btc => en_btc, en_gun => en_gun, en_tmo => en_tmo,
      bus_addr => addr, bus_read => rd, bus_write => wr, bus_dataWrite => wdata, bus_dataRead => rdata,
      bus_sel => sel,
      tb0_strobe => tb0s, tb0_dx => tb0x, tb0_dy => tb0y, tb1_strobe => tb1s, tb1_dx => tb1x, tb1_dy => tb1y,
      gun_x1 => gx1, gun_y1 => gy1, gun_x2 => gx2, gun_y2 => gy2, gun_trig1 => gt1, gun_trig2 => gt2,
      heartbeat => hb, gsr => gsr, paper_empty => '0', printer_fault => '0', eep_bit4 => eep4,
      dc_start => x"F073", dc_bit => dcb);

   host : entity work.gv_sio_host
   port map (
      clk1x => clk, enable => h_en, tx_strobe => h_tx, tx_data => h_txd, rx_pop => h_pop,
      dsr => h_dsr, rx_valid => h_rxv, rx_data => h_rxd, done => h_done);

   stim : process
      variable errs, nchk : integer := 0;
      variable v : std_logic_vector(7 downto 0);
      variable dc : std_logic_vector(15 downto 0);

      procedure tick(n : integer := 1) is
      begin
         for i in 1 to n loop wait until rising_edge(clk); end loop;
      end procedure;
      procedure bw(a : integer; d : std_logic_vector(7 downto 0)) is
      begin
         addr <= to_unsigned(16#680000# + a, 23); wdata <= d; wr <= '1'; tick; wr <= '0'; tick;
      end procedure;
      procedure br(a : integer; d : out std_logic_vector(7 downto 0)) is
      begin
         addr <= to_unsigned(16#680000# + a, 23); rd <= '1'; tick; rd <= '0'; tick;
         d := rdata;
      end procedure;
      procedure expect(a : integer; e : std_logic_vector(7 downto 0); what : string) is
         variable d : std_logic_vector(7 downto 0);
      begin
         br(a, d);
         nchk := nchk + 1;
         if d /= e then
            report what & ": read " & to_hstring(d) & " exp " & to_hstring(e);
            errs := errs + 1;
         end if;
      end procedure;
      procedure move(c : integer; dx, dy : integer) is
      begin
         if c = 0 then tb0x <= to_signed(dx, 10); tb0y <= to_signed(dy, 10); tb0s <= '1';
         else          tb1x <= to_signed(dx, 10); tb1y <= to_signed(dy, 10); tb1s <= '1'; end if;
         tick; tb0s <= '0'; tb1s <= '0'; tick;
      end procedure;
      -- printer: bit 0 of 0x90 held high for n ticks (clk1x / 8), then low
      procedure pulse(ticks : integer) is
      begin
         bw(16#90#, x"01"); tick(ticks * 8 - 2); bw(16#90#, x"00"); tick(200);
      end procedure;
      procedure send_cmd(c : integer) is
         variable b : unsigned(7 downto 0);
      begin
         for k in 1 to 3 loop
            pulse(9600);                                   -- start of transfer
            b := to_unsigned(c, 8);
            for i in 0 to 6 loop
               if b(i) = '1' then pulse(4800); else pulse(2400); end if;
            end loop;
            b := x"F9";
            for i in 0 to 7 loop
               if b(i) = '1' then pulse(4800); else pulse(2400); end if;
            end loop;
         end loop;
      end procedure;
      procedure host_send(s : string) is
      begin
         for i in s'range loop
            h_txd <= std_logic_vector(to_unsigned(character'pos(s(i)), 8)); h_tx <= '1'; tick; h_tx <= '0'; tick;
         end loop;
      end procedure;
      procedure host_expect(s : string; what : string) is
      begin
         for i in s'range loop
            nchk := nchk + 1;
            if h_rxv /= '1' or h_rxd /= std_logic_vector(to_unsigned(character'pos(s(i)), 8)) then
               report what & " byte " & integer'image(i) & ": valid " & std_logic'image(h_rxv) & " data " &
                      to_hstring(h_rxd);
               errs := errs + 1;
            end if;
            h_pop <= '1'; tick; h_pop <= '0'; tick;
         end loop;
         nchk := nchk + 1;
         if h_rxv = '1' then report what & ": extra bytes queued"; errs := errs + 1; end if;
      end procedure;
   begin
      tick(4);
      ---------------------------------------------------------------- Beat the Champ
      en_btc <= '1';
      tick;
      bw(16#88#, x"03");                                   -- CS high, reset inactive
      move(0, 100, -5);                                    -- trackball 0: X +100, Y -5
      move(1, -3, 300);                                    -- trackball 1: X -3, Y +300
      expect(16#81#, x"64", "tb0 X lo (live, CS high)");
      expect(16#83#, x"00", "tb0 X hi");
      expect(16#85#, x"FB", "tb0 Y lo (12-bit -5)");
      expect(16#87#, x"0F", "tb0 Y hi");
      expect(16#80#, x"FD", "tb1 X lo");
      expect(16#82#, x"0F", "tb1 X hi");
      expect(16#84#, x"2C", "tb1 Y lo");
      expect(16#86#, x"01", "tb1 Y hi");
      bw(16#88#, x"01");                                   -- CS falls: latch both chips
      move(0, 20, 20);
      expect(16#81#, x"64", "tb0 X latched while CS low");
      bw(16#88#, x"03");
      expect(16#81#, x"78", "tb0 X live again (100 + 20)");
      bw(16#88#, x"02");                                   -- reset active: origin = count, counting blocked
      move(0, 7, 7);
      expect(16#81#, x"00", "tb0 X after reset");
      bw(16#88#, x"03");
      move(0, 9, 0);
      expect(16#81#, x"09", "tb0 X counts from the reset origin");
      en_btc <= '0';
      ---------------------------------------------------------------- Dead Eye
      en_gun <= '1';
      gx1 <= x"014C"; gy1 <= x"0077"; gx2 <= x"01BB"; gy2 <= x"00EF"; gt1 <= '1'; gt2 <= '0';
      tick;
      expect(16#80#, x"4C", "GUNX1 lo"); expect(16#81#, x"01", "GUNX1 hi");
      expect(16#90#, x"77", "GUNY1 lo"); expect(16#A0#, x"BB", "GUNX2 lo");
      expect(16#A1#, x"01", "GUNX2 hi"); expect(16#B0#, x"EF", "GUNY2 lo");
      expect(16#C0#, x"FE", "BUTTONS (P1 trigger pulled, active low)");
      gt1 <= '0'; gt2 <= '1'; tick;
      expect(16#C0#, x"FD", "BUTTONS (P2 trigger pulled)");
      en_gun <= '0';
      ---------------------------------------------------------------- Tokimeki
      en_tmo <= '1';
      tick;
      expect(16#80#, x"04", "serial_r idle (heartbeat line high, paper, no fault)");
      hb <= '1'; tick; hb <= '0'; tick;
      expect(16#80#, x"00", "serial_r after a beat (bit 2 low)");
      expect(16#80#, x"04", "serial_r re-armed by the read");
      -- GSR: reset, 5-bit ID 1Ah MSB first, then clocks shift the 16-bit register; bit 8 is read
      bw(16#90#, x"02"); bw(16#90#, x"00");
      for i in 4 downto 0 loop
         if i = 4 or i = 3 or i = 1 then v := x"10"; else v := x"00"; end if;   -- 11010b
         bw(16#90#, v); bw(16#90#, v or x"20");
      end loop;
      bw(16#90#, x"00"); bw(16#90#, x"20");                -- 6th clock: no shift (MAME: len 5 -> 6)
      for i in 7 downto 0 loop
         bw(16#90#, x"00"); bw(16#90#, x"20");             -- shift left once
         br(16#80#, v);
         nchk := nchk + 1;
         if v(3) /= gsr(i) then
            report "GSR bit " & integer'image(i) & " read " & std_logic'image(v(3)); errs := errs + 1;
         end if;
      end loop;
      -- printer: a page command (17h) does not print, the print command (11h) sets bit 6 for one second
      send_cmd(16#17#);
      expect(16#80#, x"04", "serial_r after page command (not printing)");
      send_cmd(16#11#);
      expect(16#80#, x"44", "serial_r after print command (printing)");
      -- device check: P2 bit 10 = bit 15 of dc_start rotated left on each rising EEPROMOUT bit 4
      dc := x"F073";
      for i in 0 to 20 loop
         nchk := nchk + 1;
         if dcb /= dc(15) then report "device check step " & integer'image(i); errs := errs + 1; end if;
         eep4 <= '1'; tick(2); eep4 <= '0'; tick(2);
         dc := dc(14 downto 0) & dc(15);
      end loop;
      en_tmo <= '0';
      ---------------------------------------------------------------- factory host
      nchk := nchk + 1;
      if h_dsr /= '0' or h_rxv /= '0' then report "host idle while disabled"; errs := errs + 1; end if;
      h_en <= '1'; tick;
      nchk := nchk + 1;
      if h_dsr /= '1' then report "host DSR"; errs := errs + 1; end if;
      host_send("S" & LF);
      host_expect("EN" & LF, "host reply to S");
      host_send("A1B2C3D4E5F6" & LF);
      nchk := nchk + 1;
      if h_done /= '0' then report "host done before the echo was read"; errs := errs + 1; end if;
      host_expect("A1B2C3D4E5F6", "host echo");
      nchk := nchk + 1;
      if h_done /= '1' then report "host done after the echo"; errs := errs + 1; end if;

      report "SUMMARY: " & integer'image(nchk) & " checks, " & integer'image(errs) & " errors";
      if errs = 0 then report "RESULT: PASS"; else report "RESULT: FAIL"; end if;
      done <= true;
      wait;
   end process;
end architecture;
