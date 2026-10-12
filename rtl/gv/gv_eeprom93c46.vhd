-- Konami GV: 93C46 serial EEPROM (64 x 16 bit), behavioural model of MAME
-- src/devices/machine/eepromser.cpp (eeprom_serial_93cxx_device, streaming disabled)
-- and src/devices/machine/eeprom.cpp (operation timing), MAME 0.289.
--
-- Board wiring (MAME konamigv.cpp):
--   write 0x1F180000 : bit0 = DI, bit1 = CS, bit2 = CLK  (one port write updates all three
--                      lines; MAME applies them in bit order DI, CS, CLK)
--   read  P1 bit 13  : DO (active high)
--
-- Storage layout matches MAME's nvram file and the ROM_REGION16_BE "susume.25c" image:
-- word n = byte[2n] << 8 | byte[2n+1].
--
-- The host port (ld_*) gives the HPS/ioctl side word access for initial load and save.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gv_eeprom93c46 is
   generic (
      CLK_HZ        : integer := 33868800
   );
   port (
      clk           : in  std_logic;
      reset         : in  std_logic;   -- core reset: serial state only (lock and contents persist, as on the board)

      -- serial port write (one CPU write to 0x1F180000)
      port_wr       : in  std_logic;
      port_di       : in  std_logic;
      port_cs       : in  std_logic;
      port_clk      : in  std_logic;
      do_out        : out std_logic;

      -- host word port (ioctl download / upload); has priority, serial access defers
      host_addr     : in  unsigned(5 downto 0);
      host_wdata    : in  std_logic_vector(15 downto 0);
      host_we       : in  std_logic;
      host_rdata    : out std_logic_vector(15 downto 0);

      dirty         : out std_logic       -- pulses when the array is modified by the game
   );
end entity;

architecture rtl of gv_eeprom93c46 is

   constant T_WRITE    : integer := CLK_HZ / 1000000 * 1750;  -- 1.75 ms
   constant T_ERASE    : integer := CLK_HZ / 1000000 * 1000;  -- 1.00 ms
   constant T_ALL      : integer := CLK_HZ / 1000000 * 8000;  -- 8.00 ms (erase all / write all)

   type t_mem is array(0 to 63) of std_logic_vector(15 downto 0);
   signal mem          : t_mem := (others => (others => '1'));

   type t_state is (S_IN_RESET, S_WAIT_START, S_WAIT_CMD, S_READING, S_WAIT_DATA, S_WAIT_DONE);
   signal state        : t_state := S_IN_RESET;

   signal di_s, cs_s, clk_s : std_logic := '0';
   signal locked       : std_logic := '1';            -- power-on locked (MAME device_start)
   signal bits         : unsigned(4 downto 0) := (others => '0');
   signal cmdacc       : std_logic_vector(7 downto 0) := (others => '0');
   signal addr         : unsigned(5 downto 0) := (others => '0');
   signal shreg        : std_logic_vector(15 downto 0) := (others => '0');
   signal busy_cnt     : unsigned(18 downto 0) := (others => '0');
   signal is_writeall  : std_logic := '0';

   -- array micro-ops issued by the serial FSM
   type t_op is (OP_NONE, OP_READ, OP_WRITE, OP_ERASE, OP_ERASEALL, OP_WRITEALL);
   signal op           : t_op := OP_NONE;
   signal op_addr      : unsigned(5 downto 0) := (others => '0');
   signal op_data      : std_logic_vector(15 downto 0) := (others => '0');
   signal bulk_idx     : unsigned(6 downto 0) := (others => '0');
   signal rd_word      : std_logic_vector(15 downto 0) := (others => '0');

   -- single-port RAM access mux
   signal ram_addr     : unsigned(5 downto 0);
   signal ram_wdata    : std_logic_vector(15 downto 0);
   signal ram_we       : std_logic;
   signal ram_q        : std_logic_vector(15 downto 0) := (others => '0');
   signal bulk_rd_ph   : std_logic := '0';
   signal rd_pending   : std_logic := '0';

begin

   -------------------------------------------------------------------------
   -- RAM (inferred). Host has priority; serial micro-ops stall while host_we.
   -------------------------------------------------------------------------
   process(clk)
   begin
      if rising_edge(clk) then
         if ram_we = '1' then
            mem(to_integer(ram_addr)) <= ram_wdata;
         end if;
         ram_q <= mem(to_integer(ram_addr));
      end if;
   end process;
   host_rdata <= ram_q;

   process(all)
   begin
      ram_addr  <= host_addr;
      ram_wdata <= host_wdata;
      ram_we    <= host_we;
      if host_we = '0' then
         case op is
            when OP_READ =>
               ram_addr <= op_addr;
            when OP_WRITE =>
               ram_addr <= op_addr; ram_wdata <= op_data; ram_we <= '1';
            when OP_ERASE =>
               ram_addr <= op_addr; ram_wdata <= x"FFFF"; ram_we <= '1';
            when OP_ERASEALL =>
               ram_addr <= bulk_idx(5 downto 0); ram_wdata <= x"FFFF"; ram_we <= '1';
            when OP_WRITEALL =>
               -- AND against present contents (MAME write_all); two-phase read/modify/write
               ram_addr <= bulk_idx(5 downto 0);
               if bulk_rd_ph = '1' then
                  ram_wdata <= ram_q and op_data; ram_we <= '1';
               end if;
            when others => null;
         end case;
      end if;
   end process;

   -------------------------------------------------------------------------
   -- DO line (MAME do_read): WAIT_FOR_START_BIT reports READY (busy -> 0);
   -- READING_DATA drives the shift register MSB; everything else is the
   -- tristated pull-up (1).
   -------------------------------------------------------------------------
   do_out <= '0'            when (state = S_WAIT_START and busy_cnt /= 0) else
             shreg(15)      when (state = S_READING) else
             '1';

   process(clk)
      variable v_cs_rose : boolean;
      variable v_acc     : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk) then
         dirty <= '0';

         if busy_cnt /= 0 then
            busy_cnt <= busy_cnt - 1;
         end if;

         -- array micro-op sequencing (defers while the host owns the RAM)
         if host_we = '0' then
            case op is
               when OP_READ =>
                  op <= OP_NONE;           -- ram_q valid next cycle -> captured below
               when OP_WRITE | OP_ERASE =>
                  op <= OP_NONE;
               when OP_ERASEALL =>
                  if bulk_idx = 63 then op <= OP_NONE; end if;
                  bulk_idx <= bulk_idx + 1;
               when OP_WRITEALL =>
                  if bulk_rd_ph = '0' then
                     bulk_rd_ph <= '1';
                  else
                     bulk_rd_ph <= '0';
                     if bulk_idx = 63 then op <= OP_NONE; end if;
                     bulk_idx <= bulk_idx + 1;
                  end if;
               when others => null;
            end case;
         end if;
         if reset = '1' then
            state <= S_IN_RESET;
            di_s  <= '0';
            cs_s  <= '0';
            clk_s <= '0';
            bits  <= (others => '0');
         elsif port_wr = '1' then
            -- MAME applies the three lines in bit order: DI, then CS, then CLK.
            di_s      <= port_di;
            v_cs_rose := false;

            if port_cs /= cs_s then
               cs_s <= port_cs;
               if port_cs = '1' then
                  v_cs_rose := true;
                  if state = S_IN_RESET then
                     state <= S_WAIT_START;
                  end if;
               else
                  state <= S_IN_RESET;     -- CS falling resets from every state
               end if;
            end if;

            if port_clk /= clk_s then
               clk_s <= port_clk;
               if port_clk = '1' and port_cs = '1' then
                  -- rising CLK while CS high. A CLK edge in the same write as the CS rising
                  -- edge sees the old state (IN_RESET) and is ignored, which matches MAME's
                  -- "time > m_last_cs_rising_edge_time" start-bit rule.
                  case state is
                     when S_WAIT_START =>
                        if port_di = '1' and busy_cnt = 0 and not v_cs_rose then
                           cmdacc <= (others => '0');
                           bits   <= (others => '0');
                           state  <= S_WAIT_CMD;
                        end if;

                     when S_WAIT_CMD =>
                        v_acc  := cmdacc(6 downto 0) & port_di;
                        cmdacc <= v_acc;
                        if bits = 7 then
                           bits <= (others => '0');
                           addr <= unsigned(v_acc(5 downto 0));
                           case v_acc(7 downto 6) is
                              when "10" =>                       -- READ
                                 shreg   <= (others => '0');      -- dummy 0 bit
                                 op      <= OP_READ;
                                 op_addr <= unsigned(v_acc(5 downto 0));
                                 state   <= S_READING;
                              when "01" =>                       -- WRITE
                                 shreg       <= (others => '0');
                                 is_writeall <= '0';
                                 state       <= S_WAIT_DATA;
                              when "11" =>                       -- ERASE
                                 if locked = '1' then
                                    state <= S_IN_RESET;
                                 else
                                    op       <= OP_ERASE;
                                    op_addr  <= unsigned(v_acc(5 downto 0));
                                    busy_cnt <= to_unsigned(T_ERASE, busy_cnt'length);
                                    dirty    <= '1';
                                    state    <= S_WAIT_DONE;
                                 end if;
                              when others =>                     -- 00: sub-op in A5:A4
                                 case v_acc(5 downto 4) is
                                    when "00" =>                 -- EWDS (lock)
                                       locked <= '1';
                                       state  <= S_IN_RESET;
                                    when "01" =>                 -- WRAL
                                       shreg       <= (others => '0');
                                       is_writeall <= '1';
                                       state       <= S_WAIT_DATA;
                                    when "10" =>                 -- ERAL
                                       if locked = '1' then
                                          state <= S_IN_RESET;
                                       else
                                          op       <= OP_ERASEALL;
                                          bulk_idx <= (others => '0');
                                          busy_cnt <= to_unsigned(T_ALL, busy_cnt'length);
                                          dirty    <= '1';
                                          state    <= S_WAIT_DONE;
                                       end if;
                                    when others =>               -- EWEN (unlock)
                                       locked <= '0';
                                       state  <= S_IN_RESET;
                                 end case;
                           end case;
                        else
                           bits <= bits + 1;
                        end if;

                     when S_READING =>
                        -- first clock loads the word (DO = MSB), then shift in ones
                        if bits = 0 then
                           shreg <= rd_word;
                        else
                           shreg <= shreg(14 downto 0) & '1';
                        end if;
                        if bits /= 31 then
                           bits <= bits + 1;
                        end if;

                     when S_WAIT_DATA =>
                        shreg <= shreg(14 downto 0) & port_di;
                        if bits = 15 then
                           bits <= (others => '0');
                           if locked = '1' then
                              state <= S_IN_RESET;
                           elsif is_writeall = '1' then
                              op         <= OP_WRITEALL;
                              op_data    <= shreg(14 downto 0) & port_di;
                              bulk_idx   <= (others => '0');
                              bulk_rd_ph <= '0';
                              busy_cnt   <= to_unsigned(T_ALL, busy_cnt'length);
                              dirty      <= '1';
                              state      <= S_WAIT_DONE;
                           else
                              op       <= OP_WRITE;
                              op_addr  <= addr;
                              op_data  <= shreg(14 downto 0) & port_di;
                              busy_cnt <= to_unsigned(T_WRITE, busy_cnt'length);
                              dirty    <= '1';
                              state    <= S_WAIT_DONE;
                           end if;
                        else
                           bits <= bits + 1;
                        end if;

                     when others => null;
                  end case;
               end if;
            end if;
         end if;
      end if;
   end process;

   -- capture the READ word one cycle after its address was presented
   process(clk)
   begin
      if rising_edge(clk) then
         if rd_pending = '1' then
            rd_word <= ram_q;
         end if;
         if op = OP_READ and host_we = '0' then
            rd_pending <= '1';
         else
            rd_pending <= '0';
         end if;
      end if;
   end process;

end architecture;
