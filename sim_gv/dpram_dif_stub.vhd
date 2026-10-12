library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Behavioral stub of the Quartus altsyncram-based dpram_dif (rtl/dpram.vhd) for GHDL sim.
-- Mirrors the real entity's generics/ports exactly so konami573's `entity work.dpram_dif`
-- binds to this instead of the unsimulatable altsyncram megafunction.
--
-- Real megafunction config (BIDIR_DUAL_PORT): registered read ADDRESS, UNREGISTERED output
--   => q(T) = mem[address(T-1)] : a 1-cycle read latency (the "address-ahead" trick in
--      konami573 / memcard depends on exactly this).
-- read_during_write = NEW_DATA: a write updates mem the same edge the addr registers, so the
--   freshly written value is visible on the next cycle's read (sufficient for this design).
--
-- The "dif" = different A/B widths sharing one bit space (e.g. sector buf: A 512x32 / B 1024x16,
-- EEPROM: A 128x8 / B 64x16). Modeled as a shared byte array, little-endian word packing, which
-- is the altsyncram convention. In konami573 BOTH ports use clk1x, so one clocked process suffices.
-- NOTE: dpram_dif is NOT in the SCSI-register path, so its exact behaviour does not affect the
-- pre-READ(10) handshake; correct packing only matters for the (secondary) DMA-drain check.

entity dpram_dif is
   generic (
      addr_width_a  : integer := 8;
      data_width_a  : integer := 8;
      addr_width_b  : integer := 8;
      data_width_b  : integer := 8
   );
   port (
      clock_a   : in  std_logic;
      address_a : in  std_logic_vector(addr_width_a-1 downto 0);
      data_a    : in  std_logic_vector(data_width_a-1 downto 0) := (others => '0');
      clken_a   : in  std_logic := '1';
      wren_a    : in  std_logic := '0';
      q_a       : out std_logic_vector(data_width_a-1 downto 0);
      cs_a      : in  std_logic := '1';

      clock_b   : in  std_logic;
      address_b : in  std_logic_vector(addr_width_b-1 downto 0) := (others => '0');
      data_b    : in  std_logic_vector(data_width_b-1 downto 0) := (others => '0');
      clken_b   : in  std_logic := '1';
      wren_b    : in  std_logic := '0';
      q_b       : out std_logic_vector(data_width_b-1 downto 0);
      cs_b      : in  std_logic := '1'
   );
end entity;

architecture stub of dpram_dif is
   constant WA        : integer := data_width_a/8;                 -- bytes per A-word
   constant WB        : integer := data_width_b/8;                 -- bytes per B-word
   constant TOTBYTES  : integer := (2**addr_width_a) * WA;         -- == (2**addr_width_b)*WB
   type t_mem is array(0 to TOTBYTES-1) of std_logic_vector(7 downto 0);
   shared variable mem : t_mem := (others => (others => '0'));

   signal a_addr_q : integer := 0;
   signal b_addr_q : integer := 0;
begin

   process (clock_a)
      variable base : integer;
   begin
      if rising_edge(clock_a) then
         if clken_a = '1' then
            base := to_integer(unsigned(address_a)) * WA;
            if wren_a = '1' and cs_a = '1' then
               for i in 0 to WA-1 loop
                  mem(base + i) := data_a(8*i+7 downto 8*i);
               end loop;
            end if;
            a_addr_q <= to_integer(unsigned(address_a));
         end if;
      end if;
   end process;

   process (clock_b)
      variable base : integer;
   begin
      if rising_edge(clock_b) then
         if clken_b = '1' then
            base := to_integer(unsigned(address_b)) * WB;
            if wren_b = '1' and cs_b = '1' then
               for i in 0 to WB-1 loop
                  mem(base + i) := data_b(8*i+7 downto 8*i);
               end loop;
            end if;
            b_addr_q <= to_integer(unsigned(address_b));
         end if;
      end if;
   end process;

   -- Unregistered outputs: combinational read from the registered address.
   process (a_addr_q)
      variable base : integer;
      variable w    : std_logic_vector(data_width_a-1 downto 0);
   begin
      base := a_addr_q * WA;
      for i in 0 to WA-1 loop
         w(8*i+7 downto 8*i) := mem(base + i);
      end loop;
      q_a <= w when cs_a = '1' else (others => '1');
   end process;

   process (b_addr_q)
      variable base : integer;
      variable w    : std_logic_vector(data_width_b-1 downto 0);
   begin
      base := b_addr_q * WB;
      for i in 0 to WB-1 loop
         w(8*i+7 downto 8*i) := mem(base + i);
      end loop;
      q_b <= w when cs_b = '1' else (others => '1');
   end process;

end architecture;
