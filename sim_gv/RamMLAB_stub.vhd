library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Behavioral stub of RamMLAB (rtl/RamMLAB.vhd, an Altera altdpram) for GHDL sim.
-- altdpram config: wraddress/wrcontrol/indata reg = INCLOCK (write synchronous),
-- rdaddress_reg/outdata_reg = UNREGISTERED  =>  ASYNCHRONOUS read (q = mem[rdaddress]).
-- Used only by SyncFifoFallThroughMLAB (the memorymux write FIFO).
entity RamMLAB is
   generic (
      width         : natural;
      width_byteena : natural := 1;
      widthad       : natural
   );
   port (
      inclock   : in  std_logic;
      wren      : in  std_logic;
      data      : in  std_logic_vector(width-1 downto 0);
      wraddress : in  std_logic_vector(widthad-1 downto 0);
      rdaddress : in  std_logic_vector(widthad-1 downto 0);
      q         : out std_logic_vector(width-1 downto 0)
   );
end entity;

architecture stub of RamMLAB is
   type mem_t is array(0 to (2**widthad)-1) of std_logic_vector(width-1 downto 0);
   signal mem : mem_t := (others => (others => '0'));
begin
   process (inclock) begin
      if rising_edge(inclock) then
         if wren = '1' then
            mem(to_integer(unsigned(wraddress))) <= data;
         end if;
      end if;
   end process;
   q <= mem(to_integer(unsigned(rdaddress)));   -- asynchronous read
end architecture;
