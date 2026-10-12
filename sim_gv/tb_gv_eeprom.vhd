-- 93C46 write-path checks (MAME eepromser semantics), not exercised by Susume itself:
--   locked at power-on: WRITE ignored; EWEN; WRITE -> DO busy (0) while waiting for the next start
--   bit, ready (1) after ~1.75 ms; READ returns the new word; dirty pulses; ERASE -> FFFF; EWDS
--   locks again; host port sees the new contents (what MRA nvram upload saves).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_gv_eeprom is end entity;

architecture sim of tb_gv_eeprom is
   signal clk : std_logic := '0';
   signal done : boolean := false;
   signal reset : std_logic := '1';
   signal wr, di, cs, ck, do_o : std_logic := '0';
   signal haddr : unsigned(5 downto 0) := (others => '0');
   signal hdata : std_logic_vector(15 downto 0) := (others => '0');
   signal hwe   : std_logic := '0';
   signal hq    : std_logic_vector(15 downto 0);
   signal dirty : std_logic;
   signal ndirty : integer := 0;
begin
   clk <= not clk after 14.76 ns when not done;

   dut : entity work.gv_eeprom93c46
   port map (clk => clk, reset => reset, port_wr => wr, port_di => di, port_cs => cs, port_clk => ck,
             do_out => do_o, host_addr => haddr, host_wdata => hdata, host_we => hwe, host_rdata => hq, dirty => dirty);

   process(clk) begin if rising_edge(clk) and dirty = '1' then ndirty <= ndirty + 1; end if; end process;

   process
      variable errs : integer := 0;
      variable w : integer;
      procedure tick(n : integer) is begin for i in 1 to n loop wait until rising_edge(clk); end loop; end procedure;
      procedure lines(d, c, k : std_logic) is
      begin
         di <= d; cs <= c; ck <= k; wr <= '1'; tick(1); wr <= '0'; tick(30);   -- CPU-paced writes
      end procedure;
      procedure bitout(b : integer) is
         variable d : std_logic;
      begin
         if b = 1 then d := '1'; else d := '0'; end if;
         lines(d, '1', '0'); lines(d, '1', '1');
      end procedure;
      procedure cmd(op : integer; addr : integer) is      -- start bit + 2-bit opcode + 6-bit address
      begin
         lines('0', '0', '0'); lines('0', '1', '0');
         bitout(1);
         bitout(op / 2); bitout(op mod 2);
         for i in 5 downto 0 loop bitout((addr / (2 ** i)) mod 2); end loop;
      end procedure;
      procedure write_word(addr : integer; v : integer) is
      begin
         cmd(1, addr);
         for i in 15 downto 0 loop bitout((v / (2 ** i)) mod 2); end loop;
         lines('0', '0', '0');                              -- CS low
      end procedure;
      procedure read_word(addr : integer; v : out integer) is
         variable r : integer := 0;
      begin
         cmd(2, addr);
         for i in 0 to 15 loop
            lines('0', '1', '0'); lines('0', '1', '1');
            if do_o = '1' then r := r * 2 + 1; else r := r * 2; end if;
         end loop;
         lines('0', '0', '0');
         v := r;
      end procedure;
      procedure check(cond : boolean; msg : string) is
      begin
         if cond then report "PASS " & msg; else report "FAIL " & msg severity warning; errs := errs + 1; end if;
      end procedure;
      variable busy_seen, ready_seen : boolean;
   begin
      tick(4);
      haddr <= to_unsigned(5, 6); hdata <= x"AAAA"; hwe <= '1'; tick(1); hwe <= '0';
      reset <= '0'; tick(4);

      write_word(5, 16#1234#);                              -- locked: ignored
      read_word(5, w);  check(w = 16#AAAA#, "WRITE ignored while locked (power-on EWDS)");

      cmd(0, 16#30#); lines('0', '0', '0');                 -- EWEN (00 11xxxx)
      write_word(5, 16#1234#);
      lines('0', '1', '0');                                 -- CS high: DO = READY/BUSY
      busy_seen := (do_o = '0');
      for i in 1 to 70000 loop tick(1); exit when do_o = '1'; end loop;
      ready_seen := (do_o = '1');
      lines('0', '0', '0');
      check(busy_seen and ready_seen, "DO reports busy then ready after WRITE (MAME 1.75 ms)");
      read_word(5, w);  check(w = 16#1234#, "READ returns written word");
      check(ndirty >= 1, "dirty pulse -> MRA nvram upload request");
      haddr <= to_unsigned(5, 6); tick(2);
      check(hq = x"1234", "host port sees new contents (nvram save)");

      cmd(3, 5); lines('0', '0', '0');                      -- ERASE word 5
      for i in 1 to 40000 loop tick(1); end loop;
      read_word(5, w);  check(w = 16#FFFF#, "ERASE -> FFFF");

      cmd(0, 0); lines('0', '0', '0');                      -- EWDS
      write_word(5, 16#0000#);
      read_word(5, w);  check(w = 16#FFFF#, "WRITE ignored after EWDS");

      if errs = 0 then report "RESULT: PASS"; else report "RESULT: FAIL"; end if;
      done <= true; wait;
   end process;
end architecture;
