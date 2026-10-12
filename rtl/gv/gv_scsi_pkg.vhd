-- Konami GV: shared definitions for the internal SCSI bus between the NCR 53CF96
-- controller model and the CD-ROM target model.
--
-- The bus is modelled at signal level exactly like MAME's nscsi_bus: every device drives
-- control lines and data that are OR-ed together; REQ/ACK handshakes move the bytes.

library ieee;
use ieee.std_logic_1164.all;

package gv_scsi_pkg is

   -- information transfer phase = MSG & C/D & I/O  (MAME S_MSG, S_CTL, S_INP)
   constant PH_DATA_OUT : std_logic_vector(2 downto 0) := "000";
   constant PH_DATA_IN  : std_logic_vector(2 downto 0) := "001";
   constant PH_COMMAND  : std_logic_vector(2 downto 0) := "010";
   constant PH_STATUS   : std_logic_vector(2 downto 0) := "011";
   constant PH_MSG_OUT  : std_logic_vector(2 downto 0) := "110";
   constant PH_MSG_IN   : std_logic_vector(2 downto 0) := "111";

   -- initiator-driven lines
   type t_scsi_init is record
      sel  : std_logic;
      bsy  : std_logic;
      atn  : std_logic;
      ack  : std_logic;
      rst  : std_logic;
      data : std_logic_vector(7 downto 0);
   end record;

   -- target-driven lines
   type t_scsi_targ is record
      bsy   : std_logic;
      req   : std_logic;
      phase : std_logic_vector(2 downto 0);
      data  : std_logic_vector(7 downto 0);
   end record;

   constant SCSI_INIT_IDLE : t_scsi_init := ('0', '0', '0', '0', '0', x"00");
   constant SCSI_TARG_IDLE : t_scsi_targ := ('0', '0', "000", x"00");

end package;
