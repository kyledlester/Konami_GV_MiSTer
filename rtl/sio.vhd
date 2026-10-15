library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all; 

entity sio is
   port 
   (
      clk1x                : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic; 
      
      bus_addr             : in  unsigned(3 downto 0); 
      bus_dataWrite        : in  std_logic_vector(31 downto 0);
      bus_read             : in  std_logic;
      bus_write            : in  std_logic;
      bus_writeMask        : in  std_logic_vector(3 downto 0);
      bus_dataRead         : out std_logic_vector(31 downto 0);

      -- GV: external serial device on SIO1 (Beat the Champ factory host). Unconnected = previous stub.
      ext_dsr              : in  std_logic := '0';             -- SIO_STAT bit 7
      ext_rx_valid         : in  std_logic := '0';             -- SIO_STAT bit 1 (RX FIFO not empty)
      ext_rx_data          : in  std_logic_vector(7 downto 0) := (others => '0');
      ext_rx_pop           : out std_logic := '0';             -- CPU read SIO_DATA
      ext_tx_strobe        : out std_logic := '0';             -- CPU wrote SIO_DATA
      ext_tx_data          : out std_logic_vector(7 downto 0) := (others => '0');
      
      loading_savestate    : in  std_logic;
      SS_reset             : in  std_logic;
      SS_DataWrite         : in  std_logic_vector(31 downto 0);
      SS_Adr               : in  unsigned(2 downto 0);
      SS_wren              : in  std_logic;
      SS_rden              : in  std_logic;
      SS_DataRead          : out std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of sio is

   signal SIO_STAT : std_logic_vector(31 downto 0);
   signal SIO_MODE : std_logic_vector( 7 downto 0);
   signal SIO_CTRL : std_logic_vector(15 downto 0);
   signal SIO_BAUD : std_logic_vector(15 downto 0);
   
   -- savestates
   type t_ssarray is array(0 to 7) of std_logic_vector(31 downto 0); 
   signal ss_out : t_ssarray := (others => (others => '0')); 
  
begin 

   ss_out(0)              <= SIO_STAT;
   ss_out(1)( 7 downto 0) <= SIO_MODE;
   ss_out(2)(15 downto 0) <= SIO_CTRL;
   ss_out(3)(15 downto 0) <= SIO_BAUD;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
      
         if (reset = '1' and loading_savestate = '0') then
         
            SIO_STAT <= x"00000005";
            SIO_MODE <= x"00";
            SIO_CTRL <= x"0000";
            SIO_BAUD <= x"00DC";
            
         elsif (SS_wren = '1') then
         
            if (to_integer(SS_Adr) = 0) then SIO_STAT <= SS_DataWrite;              end if;
            if (to_integer(SS_Adr) = 1) then SIO_MODE <= SS_DataWrite( 7 downto 0); end if;
            if (to_integer(SS_Adr) = 2) then SIO_CTRL <= SS_DataWrite(15 downto 0); end if;
            if (to_integer(SS_Adr) = 3) then SIO_BAUD <= SS_DataWrite(15 downto 0); end if;
            
         elsif (ce = '1') then
         
            bus_dataRead  <= (others => '0');
            ext_rx_pop    <= '0';
            ext_tx_strobe <= '0';

            -- bus read
            if (bus_read = '1') then
               case (bus_addr(3 downto 1) & '0') is
                  when x"0" =>
                     if (ext_rx_valid = '1') then
                        bus_dataRead <= x"000000" & ext_rx_data;
                        ext_rx_pop   <= '1';
                     else
                        bus_dataRead <= (others => '1');
                     end if;
                  when x"4" =>
                     bus_dataRead    <= SIO_STAT;
                     bus_dataRead(1) <= SIO_STAT(1) or ext_rx_valid;
                     bus_dataRead(7) <= SIO_STAT(7) or ext_dsr;
                  when x"8" => bus_dataRead <= SIO_CTRL & x"00" & SIO_MODE;
                  when x"A" => bus_dataRead <= x"0000" & SIO_CTRL;                    
                  when x"E" => bus_dataRead <= x"0000" & SIO_BAUD;  
                  when others => bus_dataRead <= (others => '1');
               end case;
            end if;

            -- bus write
            if (bus_write = '1') then
               if (bus_addr(3 downto 0) = x"0" and bus_writeMask(0) = '1') then
                  ext_tx_strobe <= '1';
                  ext_tx_data   <= bus_dataWrite(7 downto 0);
               end if;
               case (bus_addr(3 downto 0)) is
                  when x"8" =>
                     if (bus_writeMask(1 downto 0) /= "00") then
                        SIO_MODE <= bus_dataWrite(7 downto 0);
                     elsif (bus_writeMask(3 downto 2) /= "00") then
                        SIO_CTRL <= "000" & bus_dataWrite(28 downto 23) & "0" & bus_dataWrite(21) & "0" & bus_dataWrite(19 downto 16);
                        if (bus_dataWrite(22) = '1') then -- reset
                           SIO_STAT <= x"00000005";
                           SIO_MODE <= x"00";
                           SIO_CTRL <= x"0000";
                           SIO_BAUD <= x"00DC";
                        end if; 
                     end if;
                     
                  when x"C" =>
                     if (bus_writeMask(3 downto 2) /= "00") then
                        SIO_BAUD <= bus_dataWrite(31 downto 16);
                     end if;
                  
                  when others => null;
               end case;
            end if;

         end if;
      end if;
   end process;

--##############################################################
--############################### savestates
--##############################################################
   
   process (clk1x)
   begin
      if (rising_edge(clk1x)) then
         
         if (SS_rden = '1') then
            SS_DataRead <= ss_out(to_integer(SS_Adr));
         end if;
      
      end if;
   end process;

end architecture;





