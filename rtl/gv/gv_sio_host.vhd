-- Konami GV: Beat the Champ factory host on the PSX SIO1 port.
--
-- Beat the Champ's power-up code (PSX.EXE 0x8001D01C) looks for a host on SIO1: with DSR asserted it sends
-- "S\n", expects the 3-character reply "EN\n", sends a 12-character encoded challenge and a newline, and
-- reads 12 characters back. If those decode to a zero payload the game sets its factory flag and runs its
-- own flash test and factory initialisation ("FACTORY RESET ... SETTINGS INITIALIZED"). That is how a new
-- board's blank flash was prepared; MAME connects nothing to SIO1, so its btchamp stops at
-- "FLASH ROM CORRUPT". Echoing the challenge decodes to the zero payload (verified in MAME with a Lua host).
--
-- While 'enable' is high the host asserts DSR and answers; 'done' rises once the echo has been read by the
-- game. Nothing in the game is modified.
--
-- The reply is never longer than the received line, so the host keeps only the line (12 bytes) and a read
-- pointer: "EN\n" comes from constants, the echo from the line buffer.
--
-- GPL-2.0 (part of Konami_GV_MiSTer).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gv_sio_host is
   port (
      clk1x       : in  std_logic;
      enable      : in  std_logic;
      tx_strobe   : in  std_logic;                        -- byte from the game
      tx_data     : in  std_logic_vector(7 downto 0);
      rx_pop      : in  std_logic;                        -- the game read a byte
      dsr         : out std_logic;
      rx_valid    : out std_logic;
      rx_data     : out std_logic_vector(7 downto 0);
      done        : out std_logic
   );
end entity;

architecture rtl of gv_sio_host is
   type t_buf is array(0 to 15) of std_logic_vector(7 downto 0);
   signal line     : t_buf := (others => (others => '0'));
   signal line_len : unsigned(4 downto 0) := (others => '0');
   signal first    : std_logic_vector(7 downto 0) := (others => '0');
   signal mode     : unsigned(1 downto 0) := (others => '0');   -- 0 idle, 1 sending "EN\n", 2 sending echo
   signal rd_ptr   : unsigned(3 downto 0) := (others => '0');
   signal rd_end   : unsigned(3 downto 0) := (others => '0');
   signal echoed   : std_logic := '0';                          -- "EN" sent: the next 12-byte line is echoed
   signal done_r   : std_logic := '0';
begin
   dsr      <= enable;
   rx_valid <= '1' when enable = '1' and mode /= 0 else '0';
   rx_data  <= x"45" when mode = 1 and rd_ptr = 0 else
               x"4E" when mode = 1 and rd_ptr = 1 else
               x"0A" when mode = 1 else
               line(to_integer(rd_ptr));
   done     <= done_r;

   process(clk1x)
   begin
      if rising_edge(clk1x) then
         if enable = '0' then
            line_len <= (others => '0');
            mode     <= (others => '0');
            echoed   <= '0';
         else
            if rx_pop = '1' and mode /= 0 then
               if rd_ptr = rd_end then
                  if mode = 2 then done_r <= '1'; end if;          -- last echo byte taken
                  mode <= (others => '0');
               end if;
               rd_ptr <= rd_ptr + 1;
            end if;
            if tx_strobe = '1' then
               if tx_data = x"0A" then
                  if line_len = 1 and first = x"53" then            -- "S" -> "EN\n"
                     mode   <= to_unsigned(1, 2);
                     rd_ptr <= (others => '0');
                     rd_end <= to_unsigned(2, 4);
                     echoed <= '1';
                  elsif echoed = '1' and line_len = 12 then         -- echo the challenge
                     mode   <= to_unsigned(2, 2);
                     rd_ptr <= (others => '0');
                     rd_end <= to_unsigned(11, 4);
                  end if;
                  line_len <= (others => '0');
               elsif line_len < 16 then
                  line(to_integer(line_len(3 downto 0))) <= tx_data;
                  if line_len = 0 then first <= tx_data; end if;
                  line_len <= line_len + 1;
               end if;
            end if;
         end if;
      end if;
   end process;
end architecture;
