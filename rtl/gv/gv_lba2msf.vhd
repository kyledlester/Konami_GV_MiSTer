-- Konami GV: frame count -> binary M:S:F (MAME nscsi_cdrom_device::to_msf, not BCD).
-- Sequential (repeated subtraction, <= 80 + 60 cycles) so no dividers are inferred.
-- Whenever 'lba' changes the conversion restarts; 'ok' is high once 'msf' matches 'lba'.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gv_lba2msf is
   port (
      clk : in  std_logic;
      lba : in  unsigned(19 downto 0);
      msf : out unsigned(23 downto 0) := (others => '0');    -- m << 16 | s << 8 | f
      ok  : out std_logic
   );
end entity;

architecture rtl of gv_lba2msf is
   signal cur  : unsigned(19 downto 0) := (others => '1');
   signal frm  : unsigned(19 downto 0) := (others => '0');
   signal m, s : unsigned(7 downto 0) := (others => '0');
   signal ph   : unsigned(1 downto 0) := (others => '0');
   signal ok_r : std_logic := '0';
begin
   ok <= ok_r when lba = cur else '0';

   process(clk)
   begin
      if rising_edge(clk) then
         if lba /= cur then
            cur <= lba;
            frm <= lba;
            m   <= (others => '0');
            s   <= (others => '0');
            ph  <= "01";
            ok_r <= '0';
         else
            case ph is
               when "01" =>                                -- minutes: 4500 frames
                  if frm >= 4500 then frm <= frm - 4500; m <= m + 1; else ph <= "10"; end if;
               when "10" =>                                -- seconds: 75 frames
                  if frm >= 75 then frm <= frm - 75; s <= s + 1; else ph <= "11"; end if;
               when "11" =>
                  msf <= m & s & frm(7 downto 0);
                  ok_r <= '1';
                  ph  <= "00";
               when others => null;
            end case;
         end if;
      end if;
   end process;
end architecture;
