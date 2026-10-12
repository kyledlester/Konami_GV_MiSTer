-- Konami GV: NCR 53CF96-2 SCSI controller (initiator role), register-accurate port of
-- MAME 0.289 src/devices/machine/ncr53c90.cpp (ncr53cf96_device, which inherits the
-- 53C90A status register and command validity rules and the 53CF94 tcount/ID extensions).
--
-- MAME's event-driven step() is reproduced as an event-gated FSM: the FSM is evaluated in a
-- cycle only when MAME would have called step() - a SCSI obus line it watches changed, a FIFO
-- write or DMA byte access happened, the delay timer expired, or the previous evaluation
-- recursed (step(false)/step(true) inside step()).  This keeps the software-visible register
-- sequence identical to MAME while timing becomes real hardware cycles.
--
-- Delays: MAME delay(n) = n * clock_conv SCSI clocks (16 MHz board clock), delay_cycles(n)
-- = n SCSI clocks.  clk is the PSX clk1x (33.8688 MHz) so one SCSI clock ~= 2 cycles.
--
-- Target-mode (reselection) commands are not used by GV software and are not modelled.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.gv_scsi_pkg.all;

entity gv_ncr53cf96 is
   port (
      clk        : in  std_logic;
      ce         : in  std_logic;
      reset      : in  std_logic;

      -- CPU register port: one byte register access per strobe
      reg_addr   : in  unsigned(3 downto 0);
      reg_rd     : in  std_logic;
      reg_wr     : in  std_logic;
      reg_din    : in  std_logic_vector(7 downto 0);
      reg_dout   : out std_logic_vector(7 downto 0);   -- valid the cycle after reg_rd

      -- DMA byte port (MAME dma_r / dma_w)
      dma_rd     : in  std_logic;
      dma_wr     : in  std_logic;
      dma_din    : in  std_logic_vector(7 downto 0);
      dma_dout   : out std_logic_vector(7 downto 0);   -- = fifo[0], sample together with dma_rd
      drq        : out std_logic;
      dma_busy   : out std_logic;                      -- a DMA command is still transferring
      dma_dir_out: out std_logic;                      -- current DMA direction is memory -> SCSI
      fifo_cnt   : out unsigned(4 downto 0);

      irq        : out std_logic;

      -- SCSI bus
      bus_out    : out t_scsi_init;
      bus_targ   : in  t_scsi_targ                     -- OR of all targets
   );
end entity;

architecture rtl of gv_ncr53cf96 is

   -- status bits
   constant S_GROSS_ERROR : std_logic_vector(7 downto 0) := x"40";
   constant S_PARITY      : std_logic_vector(7 downto 0) := x"20";
   constant S_TC0         : std_logic_vector(7 downto 0) := x"10";
   constant S_TCC         : std_logic_vector(7 downto 0) := x"08";
   -- interrupt status bits
   constant I_SCSI_RESET  : std_logic_vector(7 downto 0) := x"80";
   constant I_ILLEGAL     : std_logic_vector(7 downto 0) := x"40";
   constant I_DISCONNECT  : std_logic_vector(7 downto 0) := x"20";
   constant I_BUS         : std_logic_vector(7 downto 0) := x"10";
   constant I_FUNCTION    : std_logic_vector(7 downto 0) := x"08";

   type t_mode  is (MODE_D, MODE_T, MODE_I);
   type t_dmad  is (DMA_NONE, DMA_IN, DMA_OUT);

   type t_state is (
      ST_IDLE, ST_BUSRESET_WAIT_INT,
      ST_DISC_SEL_ARBITRATION_INIT, ST_DISC_SEL_ARBITRATION, ST_DISC_SEL_ATN_WAIT_REQ,
      ST_DISC_SEL_ATN_SEND_BYTE, ST_DISC_SEL_WAIT_REQ, ST_DISC_SEL_SEND_BYTE,
      ST_INIT_MSG_WAIT_REQ, ST_INIT_XFR, ST_INIT_XFR_SEND_BYTE, ST_INIT_XFR_SEND_PAD_WAIT_REQ,
      ST_INIT_XFR_SEND_PAD, ST_INIT_XFR_RECV_PAD_WAIT_REQ, ST_INIT_XFR_RECV_PAD,
      ST_INIT_XFR_RECV_BYTE_ACK, ST_INIT_XFR_RECV_BYTE_NACK, ST_INIT_XFR_FUNCTION_COMPLETE,
      ST_INIT_XFR_BUS_COMPLETE, ST_INIT_XFR_WAIT_REQ,
      ST_INIT_CPT_RECV_BYTE_ACK, ST_INIT_CPT_RECV_WAIT_REQ, ST_INIT_CPT_RECV_BYTE_NACK);

   type t_sub is (
      SUB_NONE,
      ARB_COMPLETE, ARB_ASSERT_SEL, ARB_SET_DEST, ARB_RELEASE_BUSY, ARB_TIMEOUT_BUSY,
      ARB_TIMEOUT_ABORT, ARB_DESKEW_WAIT,
      SEND_WAIT_SETTLE, SEND_WAIT_REQ_0, RECV_WAIT_REQ_1, RECV_WAIT_SETTLE, RECV_WAIT_REQ_0);

   type t_fifo is array(0 to 15) of std_logic_vector(7 downto 0);

   -- architectural state (MAME member variables)
   signal s_state      : t_state := ST_IDLE;
   signal s_sub        : t_sub   := SUB_NONE;
   signal s_mode       : t_mode  := MODE_D;
   signal s_dma_dir    : t_dmad  := DMA_NONE;
   signal s_fifo       : t_fifo  := (others => (others => '0'));
   signal s_fifo_pos   : integer range 0 to 16 := 0;
   signal s_fifo_rd    : unsigned(3 downto 0) := (others => '0');   -- circular buffer read index
   signal s_cmd0       : std_logic_vector(7 downto 0) := (others => '0');
   signal s_cmd1       : std_logic_vector(7 downto 0) := (others => '0');
   signal s_cmd_pos    : integer range 0 to 2 := 0;
   signal s_config     : std_logic_vector(7 downto 0) := (others => '0');
   signal s_config2    : std_logic_vector(7 downto 0) := (others => '0');
   signal s_config3    : std_logic_vector(7 downto 0) := (others => '0');
   signal s_config4    : std_logic_vector(7 downto 0) := (others => '0');
   signal s_status     : std_logic_vector(7 downto 0) := (others => '0');
   signal s_istatus    : std_logic_vector(7 downto 0) := (others => '0');
   signal s_seq        : unsigned(2 downto 0) := (others => '0');
   signal s_clock_conv : unsigned(2 downto 0) := "010";
   signal s_sync_per   : unsigned(4 downto 0) := to_unsigned(5, 5);
   signal s_sync_off   : unsigned(3 downto 0) := (others => '0');
   signal s_bus_id     : unsigned(2 downto 0) := (others => '0');
   signal s_tcount     : unsigned(23 downto 0) := (others => '0');
   signal s_tcounter   : unsigned(23 downto 0) := (others => '0');
   signal s_tc_mask24  : std_logic := '0';             -- tcounter_mask = 0xffffff when 1, else 0xffff
   signal s_xfr_phase  : std_logic_vector(2 downto 0) := (others => '0');
   signal s_dma_cmd    : std_logic := '0';
   signal s_irq        : std_logic := '0';
   signal s_drq        : std_logic := '0';
   signal s_dly        : unsigned(15 downto 0) := (others => '0');
   signal s_dly_run    : std_logic := '0';
   signal s_step_pend  : std_logic := '0';
   signal s_chain      : std_logic := '0';
   signal s_bus        : t_scsi_init := SCSI_INIT_IDLE;

   -- watched obus lines from the previous cycle (event detection)
   signal t_prev_bsy, t_prev_req : std_logic := '0';

begin

   bus_out  <= s_bus;
   irq      <= s_irq;
   drq      <= s_drq;
   dma_dout <= s_fifo(to_integer(s_fifo_rd));
   fifo_cnt <= to_unsigned(s_fifo_pos, 5);
   dma_busy <= '0' when s_dma_dir = DMA_NONE else '1';
   dma_dir_out <= '1' when s_dma_dir = DMA_OUT else '0';

   process(clk)
      -- working copies (MAME mutates these sequentially inside one call chain)
      variable state      : t_state;
      variable sub        : t_sub;
      variable mode       : t_mode;
      variable dma_dir    : t_dmad;
      variable fifo       : t_fifo;
      variable fifo_pos   : integer range 0 to 16;
      variable fifo_rd    : unsigned(3 downto 0);
      variable cmd0, cmd1 : std_logic_vector(7 downto 0);
      variable cmd_pos    : integer range 0 to 2;
      variable config     : std_logic_vector(7 downto 0);
      variable config2    : std_logic_vector(7 downto 0);
      variable config3    : std_logic_vector(7 downto 0);
      variable config4    : std_logic_vector(7 downto 0);
      variable status     : std_logic_vector(7 downto 0);
      variable istatus    : std_logic_vector(7 downto 0);
      variable seq        : unsigned(2 downto 0);
      variable clock_conv : unsigned(2 downto 0);
      variable sync_per   : unsigned(4 downto 0);
      variable sync_off   : unsigned(3 downto 0);
      variable bus_id     : unsigned(2 downto 0);
      variable tcount     : unsigned(23 downto 0);
      variable tcounter   : unsigned(23 downto 0);
      variable tc_mask24  : std_logic;
      variable xfr_phase  : std_logic_vector(2 downto 0);
      variable dma_cmd    : std_logic;
      variable irqv       : std_logic;
      variable drqv       : std_logic;
      variable dly        : unsigned(15 downto 0);
      variable dly_run    : std_logic;
      variable obus       : t_scsi_init;
      variable rdata      : std_logic_vector(7 downto 0);
      variable do_step    : boolean;
      variable timeout    : boolean;
      variable again      : boolean;     -- MAME recursion: evaluate again next cycle
      variable own_id     : integer range 0 to 7;
      variable chain      : boolean;

      -- obus as seen by this device (OR of all drivers)
      variable c_bsy, c_req, c_sel, c_atn : std_logic;
      variable c_phase    : std_logic_vector(2 downto 0);
      variable c_data     : std_logic_vector(7 downto 0);
      variable c          : std_logic_vector(6 downto 0);

      function tmask(m24 : std_logic) return unsigned is
      begin
         if m24 = '1' then return x"FFFFFF"; else return x"00FFFF"; end if;
      end function;

      procedure check_irq is
      begin
         if istatus /= x"00" then irqv := '1'; else irqv := '0'; end if;
      end procedure;

      procedure check_drq is
      begin
         case dma_dir is
            when DMA_NONE => drqv := '0';
            when DMA_IN =>
               if sync_off = 0 then
                  if fifo_pos > 0 then drqv := '1'; else drqv := '0'; end if;
               else
                  if (status and S_TC0) = x"00" and fifo_pos > 0 then drqv := '1'; else drqv := '0'; end if;
               end if;
            when DMA_OUT =>
               if (status and S_TC0) = x"00" and fifo_pos < 16 then drqv := '1'; else drqv := '0'; end if;
         end case;
      end procedure;

      procedure fifo_push(v : std_logic_vector(7 downto 0)) is
      begin
         if fifo_pos /= 16 then
            fifo(to_integer(fifo_rd + to_unsigned(fifo_pos mod 16, 4))) := v;
            fifo_pos := fifo_pos + 1;
         end if;
         check_drq;
      end procedure;

      procedure fifo_pop(r : out std_logic_vector(7 downto 0)) is
      begin
         r := fifo(to_integer(fifo_rd));
         if fifo_pos /= 0 then
            fifo_rd  := fifo_rd + 1;
            fifo_pos := fifo_pos - 1;
         end if;
         check_drq;
      end procedure;

      procedure decrement_tcounter is
      begin
         if dma_cmd = '1' then
            if (status and S_TC0) = x"00" then
               tcounter := (tcounter - 1) and tmask(tc_mask24);
            else
               tcounter := (others => '0');
            end if;
            if tcounter = 0 then status := status or S_TC0; end if;
            check_drq;
         end if;
      end procedure;

      -- delay(n): n * clock_conv SCSI clocks; delay_cycles(n): n SCSI clocks (x2 to clk1x)
      procedure delay(n : integer) is
         variable cc : integer;
      begin
         cc := to_integer(clock_conv);
         if cc = 0 then cc := 8; end if;
         dly := resize(to_unsigned(n, 11) * to_unsigned(cc, 4) & '0', 16);
         dly_run := '1';
      end procedure;

      procedure delay_cycles(n : integer) is
      begin
         dly := to_unsigned(n * 2 + 1, 16);
         dly_run := '1';
      end procedure;

      procedure reset_disconnect is
      begin
         obus.rst := '0';
         cmd_pos := 0;
         cmd0 := x"00";
         cmd1 := x"00";
         mode := MODE_D;
      end procedure;

      procedure dev_reset is
      begin
         fifo_pos   := 0;
         fifo_rd    := (others => '0');
         fifo       := (others => (others => '0'));
         clock_conv := "010";
         sync_per   := to_unsigned(5, 5);
         sync_off   := (others => '0');
         seq        := (others => '0');
         config     := "00000" & config(2 downto 0);
         config2    := (others => '0');
         config3    := (others => '0');
         config4    := (others => '0');
         status     := (others => '0');
         istatus    := (others => '0');
         irqv       := '0';
         state      := ST_IDLE;
         sub        := SUB_NONE;
         drqv       := '0';
         dma_dir    := DMA_NONE;
         obus        := SCSI_INIT_IDLE;
         tcount     := (others => '0');
         tcounter   := (others => '0');
         tc_mask24  := '0';
         dly_run    := '0';
         reset_disconnect;
      end procedure;

      procedure function_complete is
      begin
         state := ST_IDLE; sub := SUB_NONE;
         istatus := istatus or I_FUNCTION;
         dma_dir := DMA_NONE;
         check_drq; check_irq;
      end procedure;

      procedure bus_complete is
      begin
         state := ST_IDLE; sub := SUB_NONE;
         istatus := istatus or I_BUS;
         dma_dir := DMA_NONE;
         check_drq; check_irq;
      end procedure;

      procedure function_bus_complete is
      begin
         state := ST_IDLE; sub := SUB_NONE;
         istatus := istatus or I_FUNCTION or I_BUS;
         dma_dir := DMA_NONE;
         check_drq; check_irq;
      end procedure;

      procedure send_byte is
         variable b : std_logic_vector(7 downto 0);
      begin
         sub := SEND_WAIT_SETTLE;
         if state /= ST_INIT_XFR_SEND_PAD then
            fifo_pop(b);
            obus.data := b;
         else
            obus.data := x"00";
         end if;
         obus.ack := '1';
         delay_cycles(to_integer(sync_per));
      end procedure;

      procedure recv_byte is
      begin
         sub := RECV_WAIT_REQ_1;
         again := true;
      end procedure;

      procedure arbitrate is
      begin
         sub := ARB_COMPLETE;
         obus.data := (others => '0');
         obus.data(own_id) := '1';
         obus.bsy := '1';
         delay(11);
      end procedure;

      -- MAME command_pop_and_chain(): the chained start_command() runs on the next cycle
      procedure pop_and_chain is
      begin
         if cmd_pos /= 0 then
            cmd_pos := cmd_pos - 1;
            if cmd_pos /= 0 then
               cmd0  := cmd1;
               chain := true;
            end if;
         end if;
      end procedure;

      function valid_command(cm : std_logic_vector(7 downto 0); md : t_mode) return boolean is
         variable sc : integer;
      begin
         sc := to_integer(unsigned(cm(3 downto 0)));
         case cm(6 downto 4) is
            when "000" => return sc <= 3 or (md = MODE_T and sc = 4);
            when "100" => return md = MODE_D and sc <= 6;
            when "010" => return md = MODE_T and sc <= 11 and sc /= 6;
            when "001" => return md = MODE_I and (sc <= 2 or sc = 8 or sc = 10 or sc = 11);
            when others => return false;
         end case;
      end function;

      procedure start_command is
      begin
         c := cmd0(6 downto 0);
         if not valid_command(cmd0, mode) then
            istatus := istatus or I_ILLEGAL;
            check_irq;
            return;
         end if;

         dma_cmd := cmd0(7);
         if dma_cmd = '1' then
            -- load_tcounter (53CF94: the ID is exposed through tcount until S2FE is set)
            tcounter := tcount and tmask(tc_mask24);
            status := status and not S_TC0;
            if config2(3) = '0' then
               tcount := x"A2" & tcount(15 downto 0);   -- (1<<23)|(family 0x04<<19)|(rev 0x02<<16)
            end if;
         else
            tcounter := (others => '0');
         end if;

         case c is
            when "0000000" =>                                     -- NOP
               pop_and_chain;
            when "0000001" =>                                     -- FLUSH FIFO
               fifo_pos := 0;
               pop_and_chain;
            when "0000010" =>                                     -- RESET CHIP
               dev_reset;
            when "0000011" =>                                     -- RESET SCSI BUS
               state := ST_BUSRESET_WAIT_INT; sub := SUB_NONE;
               obus.rst := '1';
               delay(130);
            when "1000001" | "1000010" | "1000011" =>             -- SELECT (w/o ATN, w/ ATN, w/ ATN and stop)
               seq := (others => '0');
               state := ST_DISC_SEL_ARBITRATION_INIT;
               if dma_cmd = '1' then dma_dir := DMA_OUT; else dma_dir := DMA_NONE; end if;
               arbitrate;
            when "1000100" =>                                     -- ENABLE SELECTION
               pop_and_chain;
            when "1000101" =>                                     -- DISABLE SELECTION
               function_complete;
               pop_and_chain;
            when "0010000" =>                                     -- TRANSFER INFORMATION
               state := ST_INIT_XFR; sub := SUB_NONE;
               xfr_phase := c_phase;
               if dma_cmd = '1' then
                  if xfr_phase(0) = '1' then dma_dir := DMA_IN; else dma_dir := DMA_OUT; end if;
               else
                  dma_dir := DMA_NONE;
               end if;
               check_drq;
               again := true;
            when "0010001" =>                                     -- INITIATOR COMMAND COMPLETE
               state := ST_INIT_CPT_RECV_BYTE_ACK;
               if dma_cmd = '1' then dma_dir := DMA_IN; else dma_dir := DMA_NONE; end if;
               recv_byte;
            when "0010010" =>                                     -- MESSAGE ACCEPTED
               state := ST_INIT_MSG_WAIT_REQ; sub := SUB_NONE;
               seq := "010";
               obus.ack := '0';
               again := true;
            when "0011000" =>                                     -- TRANSFER PAD
               xfr_phase := c_phase;
               if xfr_phase(0) = '1' then
                  state := ST_INIT_XFR_RECV_PAD_WAIT_REQ;
               else
                  state := ST_INIT_XFR_SEND_PAD_WAIT_REQ;
               end if;
               sub := SUB_NONE;
               obus.ack := '0';
               again := true;
            when "0011010" =>                                     -- SET ATN
               obus.atn := '1';
               pop_and_chain;
            when "0011011" =>                                     -- RESET ATN
               obus.atn := '0';
               pop_and_chain;
            when others =>
               null;   -- valid but unmodelled (target-mode / select-ATN3): never issued by GV software
         end case;
      end procedure;

   begin
      if rising_edge(clk) then

         -- load working copies
         state := s_state; sub := s_sub; mode := s_mode; dma_dir := s_dma_dir;
         fifo := s_fifo; fifo_pos := s_fifo_pos; fifo_rd := s_fifo_rd; cmd0 := s_cmd0; cmd1 := s_cmd1; cmd_pos := s_cmd_pos;
         config := s_config; config2 := s_config2; config3 := s_config3; config4 := s_config4;
         status := s_status; istatus := s_istatus; seq := s_seq; clock_conv := s_clock_conv;
         sync_per := s_sync_per; sync_off := s_sync_off; bus_id := s_bus_id; tcount := s_tcount;
         tcounter := s_tcounter; tc_mask24 := s_tc_mask24; xfr_phase := s_xfr_phase;
         dma_cmd := s_dma_cmd; irqv := s_irq; drqv := s_drq; dly := s_dly; dly_run := s_dly_run;
         obus := s_bus;
         own_id := to_integer(unsigned(config(2 downto 0)));

         c_bsy   := obus.bsy or bus_targ.bsy;
         c_req   := bus_targ.req;
         c_sel   := obus.sel;
         c_atn   := obus.atn;
         c_phase := bus_targ.phase;
         c_data  := obus.data or bus_targ.data;

         do_step := false;
         timeout := false;
         again   := false;
         chain   := false;

         -- event detection: watched target lines changed
         if bus_targ.bsy /= t_prev_bsy or bus_targ.req /= t_prev_req then
            do_step := true;
         end if;
         t_prev_bsy   <= bus_targ.bsy;
         t_prev_req   <= bus_targ.req;

         if s_step_pend = '1' then do_step := true; end if;

         -- delay timer
         if dly_run = '1' then
            if dly = 0 then
               dly_run := '0';
               do_step := true;
               timeout := true;
            else
               dly := dly - 1;
            end if;
         end if;

         if reset = '1' then
            config := (others => '0');
            s_bus_id <= (others => '0');
            dev_reset;
            do_step := false;
            reg_dout <= x"00";
         elsif ce = '1' then

            if s_chain = '1' then
               start_command;
            end if;

            ------------------------------------------------------------------
            -- CPU register access
            ------------------------------------------------------------------
            if reg_rd = '1' then
               rdata := x"00";
               case to_integer(reg_addr) is
                  when 0  => rdata := std_logic_vector(tcounter(7 downto 0));
                  when 1  => rdata := std_logic_vector(tcounter(15 downto 8));
                  when 2  =>                                                     -- fifo_r
                     if fifo_pos /= 0 then
                        fifo_pop(rdata);
                     else
                        rdata := x"00";
                        check_drq;
                     end if;
                  when 3  => rdata := cmd0;
                  when 4  =>                                                     -- 53C90A status_r
                     rdata := status or ("0000" & '0' & c_phase);
                     if irqv = '1' then
                        rdata(7) := '1';
                        status := status and not (S_GROSS_ERROR or S_PARITY or S_TCC);
                     end if;
                  when 5  =>                                                     -- istatus_r
                     rdata := istatus;
                     if irqv = '1' then
                        status := status and not (S_GROSS_ERROR or S_PARITY or S_TCC);
                        istatus := (others => '0');
                        seq := (others => '0');
                     end if;
                     check_irq;
                     if rdata /= x"00" then pop_and_chain; end if;
                  when 6  => rdata := "00000" & std_logic_vector(seq);
                  when 7  => rdata := std_logic_vector(to_unsigned(fifo_pos, 8));
                  when 8  => rdata := config;
                  when 11 => rdata := config2;
                  when 12 => rdata := config3;
                  when 13 => rdata := config4;
                  when 14 => rdata := std_logic_vector(tcounter(23 downto 16));
                  when others => rdata := x"00";   -- write-only / unmapped
               end case;
               reg_dout <= rdata;
            end if;

            if reg_wr = '1' then
               case to_integer(reg_addr) is
                  when 0  => tcount(7 downto 0)   := unsigned(reg_din);
                  when 1  => tcount(15 downto 8)  := unsigned(reg_din);
                  when 2  =>                                                     -- fifo_w
                     if fifo_pos /= 16 then
                        fifo(to_integer(fifo_rd + to_unsigned(fifo_pos mod 16, 4))) := reg_din;
                        fifo_pos := fifo_pos + 1;
                     end if;
                     check_drq;
                     do_step := true;
                  when 3  =>                                                     -- command_w
                     if cmd_pos = 2 then
                        status := status or S_GROSS_ERROR;
                        check_irq;
                     else
                        if reg_din(6 downto 0) = "0000010" or reg_din(6 downto 0) = "0000011" then
                           cmd_pos := 0;
                        end if;
                        if cmd_pos = 0 then cmd0 := reg_din; else cmd1 := reg_din; end if;
                        cmd_pos := cmd_pos + 1;
                        if cmd_pos = 1 then
                           start_command;
                        end if;
                     end if;
                  when 4  => bus_id := unsigned(reg_din(2 downto 0));
                  when 5  => null;                                               -- select timeout (DELAY_HACK in MAME)
                  when 6  => sync_per := unsigned(reg_din(4 downto 0));
                  when 7  => sync_off := unsigned(reg_din(3 downto 0));
                  when 8  => config := reg_din;                                  -- scsi id = data & 7 (test mode ignored)
                  when 9  => clock_conv := unsigned(reg_din(2 downto 0));
                  when 11 =>
                     config2 := reg_din;
                     tc_mask24 := reg_din(3);
                  when 12 => config3 := reg_din;
                  when 13 => config4 := reg_din;
                  when 14 => tcount(23 downto 16) := unsigned(reg_din);
                  when others => null;                                           -- test / fifo align
               end case;
               own_id := to_integer(unsigned(config(2 downto 0)));
            end if;

            ------------------------------------------------------------------
            -- DMA byte access
            ------------------------------------------------------------------
            if dma_rd = '1' then
               fifo_pop(rdata);
               if sync_off /= 0 or c_phase /= PH_DATA_IN then
                  decrement_tcounter;
               end if;
               check_drq;
               do_step := true;
            end if;
            if dma_wr = '1' then
               fifo_push(dma_din);
               decrement_tcounter;
               check_drq;
               do_step := true;
            end if;

            ------------------------------------------------------------------
            -- step()
            ------------------------------------------------------------------
            if do_step then
               -- recompute obus view with this cycle's own outputs
               c_bsy  := obus.bsy or bus_targ.bsy;
               c_data := obus.data or bus_targ.data;

               if mode = MODE_I and c_bsy = '0' then
                  state := ST_IDLE; sub := SUB_NONE;
                  istatus := istatus or I_DISCONNECT;
                  reset_disconnect;
                  check_irq;
               end if;

               c := cmd0(6 downto 0);

               if sub /= SUB_NONE then
                  case sub is
                     when ARB_COMPLETE =>
                        if timeout then
                           sub := ARB_ASSERT_SEL;
                           obus.sel := '1';
                           delay(6);
                        end if;

                     when ARB_ASSERT_SEL =>
                        if timeout then
                           obus.data := (others => '0');
                           obus.data(own_id) := '1';
                           obus.data(to_integer(bus_id)) := '1';
                           sub := ARB_SET_DEST;
                           delay_cycles(4);
                        end if;

                     when ARB_SET_DEST =>
                        if timeout then
                           sub := ARB_RELEASE_BUSY;
                           if c = "1000010" or c = "1000011" then obus.atn := '1'; else obus.atn := '0'; end if;
                           obus.bsy := '0';
                           delay(2);
                        end if;

                     when ARB_RELEASE_BUSY =>
                        if timeout then
                           if bus_targ.bsy = '1' then
                              sub := ARB_DESKEW_WAIT;
                              delay_cycles(2);
                           else
                              sub := ARB_TIMEOUT_BUSY;
                              delay(1);            -- MAME DELAY_HACK
                           end if;
                        end if;

                     when ARB_DESKEW_WAIT =>
                        if timeout then
                           obus.data := (others => '0');
                           obus.sel := '0';
                           mode := MODE_I;
                           sub := SUB_NONE;
                           -- step(true): DISC_SEL_ARBITRATION_INIT continues immediately
                           if state = ST_DISC_SEL_ARBITRATION_INIT then
                              state := ST_DISC_SEL_ARBITRATION;
                           end if;
                           again := true;
                        end if;

                     when ARB_TIMEOUT_BUSY =>
                        if timeout then
                           obus.data := (others => '0');
                           sub := ARB_TIMEOUT_ABORT;
                           delay(1000);
                        elsif bus_targ.bsy = '1' then
                           sub := ARB_DESKEW_WAIT;
                           delay_cycles(2);
                        end if;

                     when ARB_TIMEOUT_ABORT =>
                        if timeout then
                           if bus_targ.bsy = '1' then
                              sub := ARB_DESKEW_WAIT;
                              delay_cycles(2);
                           else
                              obus := SCSI_INIT_IDLE;
                              state := ST_IDLE; sub := SUB_NONE;
                              istatus := istatus or I_DISCONNECT;
                              reset_disconnect;
                              check_irq;
                           end if;
                        end if;

                     when SEND_WAIT_SETTLE =>
                        if timeout then
                           sub := SEND_WAIT_REQ_0;
                           again := true;
                        end if;

                     when SEND_WAIT_REQ_0 =>
                        if c_req = '0' then
                           sub := SUB_NONE;
                           obus.data := x"00";
                           obus.ack := '0';
                           again := true;
                        end if;

                     when RECV_WAIT_REQ_1 =>
                        if c_req = '1' then
                           sub := RECV_WAIT_SETTLE;
                           delay_cycles(to_integer(sync_per));
                        end if;

                     when RECV_WAIT_SETTLE =>
                        if timeout then
                           if state /= ST_INIT_XFR_RECV_PAD then
                              fifo_push(c_data);
                              if mode = MODE_I and sync_off = 0 and c_phase = PH_DATA_IN then
                                 decrement_tcounter;
                                 check_drq;
                              end if;
                           end if;
                           obus.ack := '1';
                           sub := RECV_WAIT_REQ_0;
                           again := true;
                        end if;

                     when RECV_WAIT_REQ_0 =>
                        if c_req = '0' then
                           sub := SUB_NONE;
                           again := true;
                        end if;

                     when others => null;
                  end case;

               else
                  case state is
                     when ST_IDLE => null;

                     when ST_BUSRESET_WAIT_INT =>
                        if timeout then
                           state := ST_IDLE;
                           obus.rst := '0';
                           reset_disconnect;
                           if config(6) = '0' then
                              istatus := istatus or I_SCSI_RESET;
                              check_irq;
                           end if;
                        end if;

                     when ST_DISC_SEL_ARBITRATION_INIT =>
                        if timeout then
                           state := ST_DISC_SEL_ARBITRATION;
                           again := true;
                        end if;

                     when ST_DISC_SEL_ARBITRATION =>
                        if fifo_pos = 0 then
                           seq := "001";
                           check_drq;
                        else
                           if c = "1000001" then
                              state := ST_DISC_SEL_WAIT_REQ;
                           else
                              state := ST_DISC_SEL_ATN_WAIT_REQ;
                           end if;
                           again := true;
                        end if;

                     when ST_DISC_SEL_ATN_WAIT_REQ =>
                        if c_req = '1' then
                           if c_phase /= PH_MSG_OUT then
                              function_complete;
                           else
                              if c = "1000010" then obus.atn := '0'; end if;
                              state := ST_DISC_SEL_ATN_SEND_BYTE;
                              send_byte;
                           end if;
                        end if;

                     when ST_DISC_SEL_ATN_SEND_BYTE =>
                        if c = "1000011" then
                           seq := "010";
                           function_bus_complete;
                        else
                           state := ST_DISC_SEL_WAIT_REQ;
                           again := true;
                        end if;

                     when ST_DISC_SEL_WAIT_REQ =>
                        if c_req = '1' then
                           if c_phase /= PH_COMMAND then
                              if (dma_cmd = '0' or (status and S_TC0) /= x"00") and fifo_pos = 0 then
                                 seq := "100";
                              else
                                 seq := "010";
                              end if;
                              function_bus_complete;
                           elsif fifo_pos /= 0 then
                              if seq < 3 then seq := "011"; end if;
                              state := ST_DISC_SEL_SEND_BYTE;
                              send_byte;
                           end if;
                        end if;

                     when ST_DISC_SEL_SEND_BYTE =>
                        if (dma_cmd = '0' or (status and S_TC0) /= x"00") and fifo_pos = 0 then
                           seq := "100";
                        end if;
                        state := ST_DISC_SEL_WAIT_REQ;
                        again := true;

                     when ST_INIT_CPT_RECV_BYTE_ACK =>
                        state := ST_INIT_CPT_RECV_WAIT_REQ;
                        obus.ack := '0';
                        again := true;

                     when ST_INIT_CPT_RECV_WAIT_REQ =>
                        if c_req = '1' then
                           if c_phase /= PH_MSG_IN then
                              cmd_pos := 0;
                              bus_complete;
                           else
                              state := ST_INIT_CPT_RECV_BYTE_NACK;
                              recv_byte;
                           end if;
                        end if;

                     when ST_INIT_CPT_RECV_BYTE_NACK =>
                        function_complete;

                     when ST_INIT_MSG_WAIT_REQ =>
                        if not (c_req = '0' and c_bsy = '1') then
                           bus_complete;
                        end if;

                     when ST_INIT_XFR =>
                        case xfr_phase is
                           when PH_DATA_OUT | PH_COMMAND | PH_MSG_OUT =>
                              state := ST_INIT_XFR_SEND_BYTE;
                              if fifo_pos /= 0 then
                                 if xfr_phase = PH_MSG_OUT then
                                    if dma_cmd = '1' then
                                       if fifo_pos + to_integer(tcounter) = 1 then obus.atn := '0'; end if;
                                    elsif fifo_pos = 1 then
                                       obus.atn := '0';
                                    end if;
                                 end if;
                                 send_byte;
                              end if;
                           when PH_DATA_IN | PH_STATUS | PH_MSG_IN =>
                              if fifo_pos /= 16 then
                                 if xfr_phase = PH_MSG_IN and (dma_cmd = '0' or tcounter = 1) then
                                    state := ST_INIT_XFR_RECV_BYTE_NACK;
                                 else
                                    state := ST_INIT_XFR_RECV_BYTE_ACK;
                                 end if;
                                 recv_byte;
                              end if;
                           when others =>
                              function_complete;
                        end case;

                     when ST_INIT_XFR_WAIT_REQ =>
                        if c_req = '1' then
                           if (dma_cmd = '1' and (status and S_TC0) /= x"00" and (dma_dir = DMA_IN or fifo_pos = 0)) or
                              (dma_cmd = '0' and xfr_phase(0) = '0' and fifo_pos = 0) or
                              (dma_cmd = '0' and xfr_phase(0) = '1' and fifo_pos = 1) then
                              state := ST_INIT_XFR_BUS_COMPLETE;
                           elsif c_phase /= xfr_phase then
                              cmd_pos := 0;
                              state := ST_INIT_XFR_BUS_COMPLETE;
                           else
                              state := ST_INIT_XFR;
                           end if;
                           again := true;
                        end if;

                     when ST_INIT_XFR_SEND_BYTE =>
                        state := ST_INIT_XFR_WAIT_REQ;
                        again := true;

                     when ST_INIT_XFR_RECV_BYTE_ACK =>
                        state := ST_INIT_XFR_WAIT_REQ;
                        obus.ack := '0';
                        again := true;

                     when ST_INIT_XFR_RECV_BYTE_NACK =>
                        state := ST_INIT_XFR_FUNCTION_COMPLETE;
                        again := true;

                     when ST_INIT_XFR_FUNCTION_COMPLETE =>
                        if not (dma_cmd = '1' and ((status and S_TC0) = x"00" or fifo_pos /= 0)) then
                           function_complete;
                        end if;

                     when ST_INIT_XFR_BUS_COMPLETE =>
                        if not (dma_cmd = '1' and drqv = '1') then
                           bus_complete;
                        end if;

                     when ST_INIT_XFR_SEND_PAD_WAIT_REQ =>
                        if c_req = '1' then
                           if c_phase /= xfr_phase then
                              cmd_pos := 0;
                              bus_complete;
                           else
                              state := ST_INIT_XFR_SEND_PAD;
                              send_byte;
                           end if;
                        end if;

                     when ST_INIT_XFR_SEND_PAD =>
                        decrement_tcounter;
                        if (status and S_TC0) = x"00" then
                           state := ST_INIT_XFR_SEND_PAD_WAIT_REQ;
                           again := true;
                        else
                           function_complete;
                        end if;

                     when ST_INIT_XFR_RECV_PAD_WAIT_REQ =>
                        if c_req = '1' then
                           if c_phase /= xfr_phase then
                              cmd_pos := 0;
                              bus_complete;
                           else
                              state := ST_INIT_XFR_RECV_PAD;
                              recv_byte;
                           end if;
                        end if;

                     when ST_INIT_XFR_RECV_PAD =>
                        decrement_tcounter;
                        if (status and S_TC0) = x"00" then
                           state := ST_INIT_XFR_RECV_PAD_WAIT_REQ;
                           obus.ack := '0';
                           again := true;
                        else
                           function_complete;
                        end if;
                  end case;
               end if;
            end if;
         end if;

         -- commit
         s_state <= state; s_sub <= sub; s_mode <= mode; s_dma_dir <= dma_dir;
         s_fifo <= fifo; s_fifo_pos <= fifo_pos; s_fifo_rd <= fifo_rd; s_cmd0 <= cmd0; s_cmd1 <= cmd1; s_cmd_pos <= cmd_pos;
         s_config <= config; s_config2 <= config2; s_config3 <= config3; s_config4 <= config4;
         s_status <= status; s_istatus <= istatus; s_seq <= seq; s_clock_conv <= clock_conv;
         s_sync_per <= sync_per; s_sync_off <= sync_off; s_tcount <= tcount;
         s_tcounter <= tcounter; s_tc_mask24 <= tc_mask24; s_xfr_phase <= xfr_phase;
         s_dma_cmd <= dma_cmd; s_irq <= irqv; s_drq <= drqv; s_dly <= dly; s_dly_run <= dly_run;
         s_bus <= obus;
         if reset = '0' then s_bus_id <= bus_id; end if;
         if again then s_step_pend <= '1'; else s_step_pend <= '0'; end if;
         if chain then s_chain <= '1'; else s_chain <= '0'; end if;
      end if;
   end process;

end architecture;
