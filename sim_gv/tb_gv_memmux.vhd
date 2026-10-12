library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;
use std.textio.all;

-- GV: CPU accesses of every size through the REAL memorymux into gv_board (MAME lane semantics).
-- (derived from t-dollaz's tb_memmux)
-- END-TO-END EXP1 DELIVERY TEST: drives the 573 SCSI handshake as CPU byte accesses through
-- the REAL memorymux.vhd (with the byte-lane fix) into the REAL konami573.vhd. This is the gap
-- the konami573-only sim could not cover: it proves the CPU->memctrl->memorymux->EXP1 chain
-- actually delivers byte WRITES (SCSI commands/FIFO) and byte READS (STATUS/IRQSTATE) to konami573
-- with the right register/byte, and that konami573 then reaches disc_req.
--
-- CPU model: drive mem_in_* (addressData=0x1F0000xx, reqsize=00 byte). Writes processed directly
-- from IDLE; reads complete on mem_done with the addressed byte in mem_dataRead(7:0).

entity tb_gv_memmux is end entity;

architecture sim of tb_gv_memmux is
   signal clk1x, clk2x, ce, reset : std_logic := '0';
   signal sim_done : std_logic := '0';

   -- CPU-side bus
   signal mem_in_request, mem_in_rnw, mem_in_isData, mem_in_isCache : std_logic := '0';
   signal mem_in_oldtagvalids : std_logic_vector(3 downto 0) := "0000";
   signal mem_in_addressInstr : unsigned(31 downto 0) := (others => '0');
   signal mem_in_addressData  : unsigned(31 downto 0) := (others => '0');
   signal mem_in_reqsize      : unsigned(1 downto 0) := "00";
   signal mem_in_writeMask    : std_logic_vector(3 downto 0) := "0000";
   signal mem_in_dataWrite    : std_logic_vector(31 downto 0) := (others => '0');
   signal mem_dataRead        : std_logic_vector(31 downto 0);
   signal mem_done            : std_logic;
   signal mem_fifofull        : std_logic;
   signal mem_tagvalids       : std_logic_vector(3 downto 0);
   signal isIdle              : std_logic;

   -- EXP1 wires between memorymux and konami573
   signal bus_exp1_addr      : unsigned(22 downto 0);
   signal bus_exp1_dataWrite : std_logic_vector(7 downto 0);
   signal bus_exp1_read      : std_logic;
   signal bus_exp1_write     : std_logic;
   signal bus_exp1_dataRead  : std_logic_vector(7 downto 0);
   signal bus_exp1_wait      : std_logic;   -- fix-A device stall (flash + EEPROM read latency)
   signal bus_exp1_bstep     : std_logic_vector(1 downto 0);  -- CPU-access byte-step (konami.cpp lane semantics)
   signal bus_exp1_a10       : std_logic_vector(1 downto 0);

   -- konami573 extra ports
   signal irq10_set        : std_logic;
   signal DMA_EXP_read     : std_logic_vector(31 downto 0);
   signal exp_dmaRequest   : std_logic;
   signal exp_dmaDataValid : std_logic;
   signal disc_req         : std_logic;
   signal disc_lba         : std_logic_vector(31 downto 0);
   signal disc_ack_s       : std_logic := '0';
   signal seen_lba20       : std_logic := '0';   -- real READ(10) lba16 fetch observed (lba*2 = 0x20/0x21)
   signal flash_word_addr  : std_logic_vector(23 downto 0);
   signal flash_fetch      : std_logic;
   signal eeprom_rd, eeprom_wr : std_logic;
   signal eeprom_dataOut   : std_logic_vector(15 downto 0);

   -- tie-offs for the many unused memorymux buses (outputs left open)
   signal z32 : std_logic_vector(31 downto 0) := (others => '0');
   signal z16 : std_logic_vector(15 downto 0) := (others => '0');
   signal z8  : std_logic_vector(7 downto 0)  := (others => '0');
   constant MEMCTRL_EXP1 : unsigned(13 downto 0) := to_unsigned(16#263F#, 14); -- =0x0013243F low14: width=0 (8-bit), Float/Hold set
   -- the GAME's EXP1 reconfig value: MEMCTRL write 0x173F47 at pc 0x80064E80; low 14 bits,
   -- bit12 SET = 16-bit bus width (the security-check era configuration)
   constant MEMCTRL_EXP1_W16 : unsigned(13 downto 0) := to_unsigned(16#3F47#, 14);
   signal ex1_memctrl_s : unsigned(13 downto 0) := MEMCTRL_EXP1;
   constant COMD : unsigned(3 downto 0) := to_unsigned(1, 4);

   -- SCSI byte offsets within EXP1 (0x1F000000 base)
   constant BASE     : unsigned(31 downto 0) := x"1F000000";
   constant OFF_FIFO : integer := 16#04#;
   constant OFF_CMD  : integer := 16#06#;
   constant OFF_STAT : integer := 16#08#;
   constant OFF_IRQ  : integer := 16#0A#;
   constant OFF_INT  : integer := 16#0C#;

   signal p1 : std_logic_vector(31 downto 0) := x"FFFFFDFE";   -- Left + Start1 pressed
   signal p2 : std_logic_vector(31 downto 0) := x"FFFFFBFF";   -- Coin 2 pressed
   signal ee_a : unsigned(5 downto 0) := (others => '0');
   signal ee_d : std_logic_vector(15 downto 0) := (others => '0');
   signal ee_we : std_logic := '0';

   -- Simpsons Bowling daughtercard + DDR3 model
   signal brd_dataRead, simp_dataRead : std_logic_vector(7 downto 0);
   signal simp_sel : std_logic;
   signal tb_strobe : std_logic := '0';
   signal tb_dx, tb_dy : signed(9 downto 0) := (others => '0');
   signal ddr_request, ddr_ack, ddr_we, ddr_rd, ddr_ready : std_logic := '0';
   signal ddr_addr : std_logic_vector(23 downto 0);
   signal ddr_din, ddr_dout : std_logic_vector(63 downto 0) := (others => '0');
   signal ddr_be : std_logic_vector(7 downto 0);
begin
   clk1x <= not clk1x after 5 ns when sim_done = '0' else '0';
   clk2x <= not clk2x after 2500 ps when sim_done = '0' else '0';
   ce    <= '1';

   imux : entity work.memorymux
      port map (
         clk1x => clk1x, clk2x => clk2x, ce => ce, reset => reset,
         pauseNext => '0', isIdle => isIdle,
         loadExe => '0', exe_initial_pc => (others=>'0'), exe_initial_gp => (others=>'0'),
         exe_load_address => (others=>'0'), exe_file_size => (others=>'0'), exe_stackpointer => (others=>'0'),
         reset_exe => open,
         fastboot => '0', PATCHSERIAL => '0', TURBO => '0', region_in => "00",
         ram_dataWrite => open, ram_dataRead => z32, ram_Adr => open, ram_be => open,
         ram_rnw => open, ram_ena => open, ram_cache => open, ram_done => '1',
         mem_in_request => mem_in_request, mem_in_rnw => mem_in_rnw, mem_in_isData => mem_in_isData,
         mem_in_isCache => mem_in_isCache, mem_in_oldtagvalids => mem_in_oldtagvalids,
         mem_in_addressInstr => mem_in_addressInstr, mem_in_addressData => mem_in_addressData,
         mem_in_reqsize => mem_in_reqsize, mem_in_writeMask => mem_in_writeMask,
         mem_in_dataWrite => mem_in_dataWrite, mem_dataRead => mem_dataRead, mem_done => mem_done,
         mem_fifofull => mem_fifofull, mem_tagvalids => mem_tagvalids,
         bios_memctrl => MEMCTRL_EXP1,
         ex1_memctrl => ex1_memctrl_s,
         bus_exp1_addr => bus_exp1_addr, bus_exp1_dataWrite => bus_exp1_dataWrite,
         bus_exp1_read => bus_exp1_read, bus_exp1_write => bus_exp1_write, bus_exp1_dataRead => bus_exp1_dataRead,
         bus_exp1_wait => bus_exp1_wait, bus_exp1_bstep => bus_exp1_bstep, bus_exp1_a10 => bus_exp1_a10,
         bus_memc_addr => open, bus_memc_dataWrite => open, bus_memc_read => open, bus_memc_write => open, bus_memc_dataRead => z32,
         bus_pad_addr => open, bus_pad_dataWrite => open, bus_pad_read => open, bus_pad_write => open, bus_pad_writeMask => open, bus_pad_dataRead => z32,
         bus_sio_addr => open, bus_sio_dataWrite => open, bus_sio_read => open, bus_sio_write => open, bus_sio_writeMask => open, bus_sio_dataRead => z32,
         bus_memc2_addr => open, bus_memc2_dataWrite => open, bus_memc2_read => open, bus_memc2_write => open, bus_memc2_dataRead => z32,
         bus_irq_addr => open, bus_irq_dataWrite => open, bus_irq_read => open, bus_irq_write => open, bus_irq_dataRead => z32,
         bus_dma_addr => open, bus_dma_dataWrite => open, bus_dma_read => open, bus_dma_write => open, bus_dma_dataRead => z32,
         bus_tmr_addr => open, bus_tmr_dataWrite => open, bus_tmr_read => open, bus_tmr_write => open, bus_tmr_dataRead => z32,
         cd_memctrl => MEMCTRL_EXP1,
         bus_cd_addr => open, bus_cd_dataWrite => open, bus_cd_read => open, bus_cd_write => open, bus_cd_dataRead => z8,
         bus_gpu_addr => open, bus_gpu_dataWrite => open, bus_gpu_read => open, bus_gpu_write => open, bus_gpu_dataRead => z32, bus_gpu_stall => '0',
         bus_mdec_addr => open, bus_mdec_dataWrite => open, bus_mdec_read => open, bus_mdec_write => open, bus_mdec_dataRead => z32,
         spu_memctrl => MEMCTRL_EXP1,
         bus_spu_addr => open, bus_spu_dataWrite => open, bus_spu_read => open, bus_spu_write => open, bus_spu_dataRead => z16,
         ex2_memctrl => MEMCTRL_EXP1,
         bus_exp2_addr => open, bus_exp2_dataWrite => open, bus_exp2_read => open, bus_exp2_write => open, bus_exp2_dataRead => z8,
         ex3_memctrl => MEMCTRL_EXP1,
         bus_exp3_read => open, bus_exp3_dataRead => z16,
         com0_delay => COMD, com1_delay => COMD, com2_delay => COMD, com3_delay => COMD,
         loading_savestate => '0', SS_reset => '0', SS_DataWrite => (others=>'0'),
         SS_Adr => (others=>'0'), SS_wren_SDRam => '0', SS_rden_SDRam => '0'
      );


   igv : entity work.gv_board
      port map (
         clk1x => clk1x, ce => ce, reset => reset,
         bus_addr => bus_exp1_addr, bus_read => bus_exp1_read, bus_write => bus_exp1_write,
         bus_dataWrite => bus_exp1_dataWrite, bus_dataRead => brd_dataRead,
         irq10 => irq10_set,
         dma_request => open, dma_rd_ena => '0', dma_rd_data => open, dma_rd_valid => open,
         dma_wr_ena => '0', dma_wr_data => (others => '0'),
         in_p1 => p1, in_p2 => p2, in_p3p4 => x"FFFFFFFF", coin_counter => open,
         ee_addr => ee_a, ee_wdata => ee_d, ee_we => ee_we, ee_rdata => open, ee_dirty => open,
         toc_wr => '0', toc_waddr => (others => '0'), toc_wdata => (others => '0'), img_mounted => '0',
         cd_reset_req => open, hps_req => open, hps_lba => open, hps_ack => '0', hps_wr => '0',
         hps_data => (others => '0'), cdda_l => open, cdda_r => open, disc_present => open
      );
   isimp : entity work.gv_simpbowl
      port map (
         clk1x => clk1x, clk2x => clk2x, ce => ce, enable => '1', time_ck => (others => '0'),
         bus_addr => bus_exp1_addr, bus_read => bus_exp1_read, bus_write => bus_exp1_write,
         bus_dataWrite => bus_exp1_dataWrite, bus_dataRead => simp_dataRead, bus_sel => simp_sel,
         bus_wait => bus_exp1_wait,
         tb_strobe => tb_strobe, tb_dx => tb_dx, tb_dy => tb_dy,
         host_addr => (others => '0'), host_we => '0', host_wdata => (others => '0'), host_rd => '0',
         host_rdata => open, host_wait => open, dirty => open, dirty_clr => '0', fill_active => open,
         ddr_request => ddr_request, ddr_ack => ddr_ack, ddr_addr => ddr_addr, ddr_din => ddr_din,
         ddr_be => ddr_be, ddr_we => ddr_we, ddr_rd => ddr_rd, ddr_dout => ddr_dout, ddr_dout_ready => ddr_ready);
   bus_exp1_dataRead <= simp_dataRead when simp_sel = '1' else brd_dataRead;

   -- DDR3 behind the arbiter: grant latency, ack, read data later; flash word k preset to 0x1000+k
   ddr : process
      type t_mem is array(0 to 4095) of std_logic_vector(63 downto 0);
      variable mem : t_mem;
      variable w   : integer;
      variable v   : std_logic_vector(63 downto 0);
   begin
      for i in 0 to 4095 loop
         for k in 0 to 3 loop
            mem(i)(16*k+15 downto 16*k) := std_logic_vector(to_unsigned(16#1000# + 4*i + k, 16));
         end loop;
      end loop;
      loop
         wait until rising_edge(clk2x);
         if ddr_request = '1' then
            for i in 1 to 7 loop wait until rising_edge(clk2x); end loop;
            w := to_integer(unsigned(ddr_addr(14 downto 3)));
            ddr_ack <= '1';
            if ddr_we = '1' then
               v := mem(w);
               for b in 0 to 7 loop
                  if ddr_be(b) = '1' then v(8*b+7 downto 8*b) := ddr_din(8*b+7 downto 8*b); end if;
               end loop;
               mem(w) := v;
            end if;
            wait until rising_edge(clk2x);
            ddr_ack <= '0';
            if ddr_rd = '1' then
               for i in 1 to 9 loop wait until rising_edge(clk2x); end loop;
               ddr_dout  <= mem(w);
               ddr_ready <= '1';
               wait until rising_edge(clk2x);
               ddr_ready <= '0';
            end if;
            while ddr_request = '1' loop wait until rising_edge(clk2x); end loop;
         end if;
      end loop;
   end process;

   stim : process
      variable nfail, nchk : integer := 0;
      variable l : line;

      procedure tick(n : integer) is begin
         for i in 1 to n loop wait until rising_edge(clk1x); end loop;
      end procedure;

      -- CPU byte WRITE of val to EXP1 offset off
      procedure cwr(off : integer; val : integer) is
         variable lane : integer := off mod 4;
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= BASE + to_unsigned(off, 32);
         mem_in_dataWrite   <= std_logic_vector(to_unsigned(val, 8)) & std_logic_vector(to_unsigned(val,8)) &
                               std_logic_vector(to_unsigned(val,8)) & std_logic_vector(to_unsigned(val,8)); -- val in every lane (mux picks by byteStep)
         mem_in_writeMask   <= std_logic_vector(to_unsigned(2**lane, 4));
         mem_in_reqsize     <= "00";
         mem_in_rnw         <= '0';
         mem_in_isData      <= '1';
         mem_in_request     <= '1';
         wait until rising_edge(clk1x);   -- IDLE captures + goes to BUSWRITEEXTERNAL
         wait until falling_edge(clk1x);
         mem_in_request     <= '0';
         -- wait for the access to complete (FSM leaves IDLE, then returns)
         for i in 0 to 60 loop wait until rising_edge(clk1x); exit when isIdle = '0'; end loop;
         for i in 0 to 200 loop wait until rising_edge(clk1x); exit when isIdle = '1'; end loop;
      end procedure;

      -- CPU byte READ of EXP1 offset off; check low byte against exp
      procedure crd_chk(off : integer; exp : integer; name : string) is
         variable r : std_logic_vector(7 downto 0);
         variable ll : line;
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= BASE + to_unsigned(off, 32);
         mem_in_reqsize     <= "00";
         mem_in_rnw         <= '1';
         mem_in_isData      <= '1';
         mem_in_request     <= '1';
         wait until rising_edge(clk1x);   -- IDLE latches read into mem_save
         wait until falling_edge(clk1x);
         mem_in_request     <= '0';
         r := (others => 'U');
         for i in 0 to 200 loop
            wait until rising_edge(clk1x);
            if mem_done = '1' then r := mem_dataRead(7 downto 0); exit; end if;
         end loop;
         nchk := nchk + 1;
         if to_integer(unsigned(r)) = exp then
            write(ll, string'("  PASS ") & name & string'(" = 0x")); hwrite(ll, r); writeline(output, ll);
         else
            nfail := nfail + 1;
            write(ll, string'("  **FAIL** ") & name & string'(" : got 0x")); hwrite(ll, r);
            write(ll, string'(" exp 0x")); hwrite(ll, std_logic_vector(to_unsigned(exp,8))); writeline(output, ll);
         end if;
      end procedure;

      -- CPU 16-bit READ of EXP1 offset off; check low 16 bits against exp
      procedure crd16_chk(off : integer; exp : integer; name : string) is
         variable r : std_logic_vector(15 downto 0);
         variable ll : line;
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= BASE + to_unsigned(off, 32);
         mem_in_reqsize     <= "01";
         mem_in_rnw         <= '1';
         mem_in_isData      <= '1';
         mem_in_request     <= '1';
         wait until rising_edge(clk1x);
         wait until falling_edge(clk1x);
         mem_in_request     <= '0';
         r := (others => 'U');
         for i in 0 to 300 loop
            wait until rising_edge(clk1x);
            if mem_done = '1' then r := mem_dataRead(15 downto 0); exit; end if;
         end loop;
         nchk := nchk + 1;
         if to_integer(unsigned(r)) = exp then
            write(ll, string'("  PASS ") & name & string'(" = 0x")); hwrite(ll, r); writeline(output, ll);
         else
            nfail := nfail + 1;
            write(ll, string'("  **FAIL** ") & name & string'(" : got 0x")); hwrite(ll, r);
            write(ll, string'(" exp 0x")); hwrite(ll, std_logic_vector(to_unsigned(exp,16))); writeline(output, ll);
         end if;
      end procedure;

      -- CPU 32-bit READ of EXP1 offset off; check all 32 bits against exp
      procedure crd32_chk(off : integer; exp : integer; name : string) is
         variable r : std_logic_vector(31 downto 0);
         variable ll : line;
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= BASE + to_unsigned(off, 32);
         mem_in_reqsize     <= "10";
         mem_in_rnw         <= '1';
         mem_in_isData      <= '1';
         mem_in_request     <= '1';
         wait until rising_edge(clk1x);
         wait until falling_edge(clk1x);
         mem_in_request     <= '0';
         r := (others => 'U');
         for i in 0 to 500 loop
            wait until rising_edge(clk1x);
            if mem_done = '1' then r := mem_dataRead; exit; end if;
         end loop;
         nchk := nchk + 1;
         if r = std_logic_vector(to_unsigned(exp, 32)) then
            write(ll, string'("  PASS ") & name & string'(" = 0x")); hwrite(ll, r); writeline(output, ll);
         else
            nfail := nfail + 1;
            write(ll, string'("  **FAIL** ") & name & string'(" : got 0x")); hwrite(ll, r);
            write(ll, string'(" exp 0x")); hwrite(ll, std_logic_vector(to_unsigned(exp,32))); writeline(output, ll);
         end if;
      end procedure;

      -- CPU 16-bit WRITE of val to EXP1 offset off (must be 2-byte aligned)
      procedure cwr16(off : integer; val : integer) is
         variable lane : integer := off mod 4;
      begin
         wait until falling_edge(clk1x);
         mem_in_addressData <= BASE + to_unsigned(off, 32);
         mem_in_dataWrite   <= std_logic_vector(to_unsigned(val, 16)) & std_logic_vector(to_unsigned(val, 16));
         mem_in_writeMask   <= std_logic_vector(to_unsigned(3 * (2**lane), 4));
         mem_in_reqsize     <= "01";
         mem_in_rnw         <= '0';
         mem_in_isData      <= '1';
         mem_in_request     <= '1';
         wait until rising_edge(clk1x);
         wait until falling_edge(clk1x);
         mem_in_request     <= '0';
         for i in 0 to 60 loop wait until rising_edge(clk1x); exit when isIdle = '0'; end loop;
         for i in 0 to 300 loop wait until rising_edge(clk1x); exit when isIdle = '1'; end loop;
      end procedure;

      -- 93C46 serial helpers (byte writes to 0x1F180000: bit0 DI, bit1 CS, bit2 CLK)
      procedure ee_bit(di : integer) is begin
         cwr(16#180000#, 2 + di); cwr(16#180000#, 6 + di);
      end procedure;
      procedure step(s : string) is variable ll : line; begin
         write(ll, string'("--- ") & s); writeline(output, ll); end procedure;
      variable word : integer;
      variable r16 : std_logic_vector(15 downto 0);
   begin
      reset <= '1'; tick(5);
      -- preload the EEPROM (host port), word 2 = 0x9527 like susume.25c
      ee_a <= to_unsigned(2, 6); ee_d <= x"9527"; ee_we <= '1'; tick(1); ee_we <= '0';
      reset <= '0'; tick(5);

      step("NCR registers, 8-bit EXP1 bus (BIOS configuration)");
      cwr(16#06#, 16#02#);                        -- RESET CHIP (register 3 at byte 6)
      cwr(16#10#, 16#5A#); crd_chk(16#10#, 16#5A#, "CONF1 write/read (reg 8 at byte 0x10)");
      crd_chk(16#11#, 0, "odd byte 0x11 is unconnected (MAME umask16 0x00ff)");
      crd16_chk(16#10#, 16#005A#, "16-bit read of CONF1: high byte 0");
      crd32_chk(16#10#, 16#0000005A#, "32-bit read at 0x10: reg 8 lane 0, reg 9 (write-only) lane 2 = 0");
      cwr(16#16#, 16#48#); crd_chk(16#16#, 16#48#, "CONF2 (reg B at byte 0x16)");
      cwr(16#06#, 16#02#);                        -- RESET CHIP: CONF1 &= 7 (bit 6 would mask the reset IRQ)
      cwr(16#06#, 16#03#);                        -- RESET SCSI BUS
      for i in 0 to 20000 loop wait until rising_edge(clk1x); exit when irq10_set = '1'; end loop;
      tick(10);
      crd_chk(16#0A#, 16#80#, "ISTATUS after RESET BUS = SCSI RESET (0x80)");
      crd_chk(16#0A#, 16#00#, "ISTATUS cleared by the read");

      step("P1 / P2 input byte lanes (MAME semantics)");
      crd16_chk(16#100000#, 16#FDFE#, "P1 16-bit (Left + Start pressed, DO=1)");
      crd_chk(16#100001#, 16#FD#, "P1 8-bit at 0x1F100001 = bits 15:8 (coin/start byte)");
      crd_chk(16#100000#, 16#FE#, "P1 8-bit at 0x1F100000 = bits 7:0");
      crd16_chk(16#100004#, 16#FBFF#, "P2 16-bit (Coin 2 pressed)");
      crd16_chk(16#100006#, 16#FFFF#, "P2 upper half (MAME: unknown bits = 1)");

      step("16-bit EXP1 bus width (game configuration 0x173F47)");
      ex1_memctrl_s <= MEMCTRL_EXP1_W16; tick(2);
      crd16_chk(16#100000#, 16#FDFE#, "P1 16-bit with 16-bit bus config");
      cwr(16#10#, 16#A5#); crd_chk(16#10#, 16#A5#, "CONF1 with 16-bit bus config");

      step("93C46 READ word 2 by bit-banging (DO on P1 bit 13)");
      cwr(16#180000#, 0); cwr(16#180000#, 2);     -- CS low, CS high
      ee_bit(1);                                  -- start bit
      ee_bit(1); ee_bit(0);                       -- READ opcode 10
      for i in 5 downto 0 loop ee_bit((2 / (2**i)) mod 2); end loop;   -- address 000010
      word := 0;
      for i in 0 to 15 loop
         ee_bit(0);
         wait until falling_edge(clk1x);
         mem_in_addressData <= BASE + to_unsigned(16#100000#, 32); mem_in_reqsize <= "01";
         mem_in_rnw <= '1'; mem_in_isData <= '1'; mem_in_request <= '1';
         wait until rising_edge(clk1x); wait until falling_edge(clk1x); mem_in_request <= '0';
         for k in 0 to 300 loop wait until rising_edge(clk1x); if mem_done = '1' then r16 := mem_dataRead(15 downto 0); exit; end if; end loop;
         word := word * 2 + to_integer(unsigned'("" & r16(13)));
      end loop;
      cwr(16#180000#, 0);
      nchk := nchk + 1;
      if word = 16#9527# then
         write(l, string'("  PASS 93C46 READ word 2 = 0x9527")); writeline(output, l);
      else
         nfail := nfail + 1;
         write(l, string'("  **FAIL** 93C46 READ word 2 = ") & integer'image(word)); writeline(output, l);
      end if;

      for cfg in 0 to 1 loop
         if cfg = 0 then
            step("Simpsons Bowling flash glue + uPD4701, 8-bit EXP1 bus");
            ex1_memctrl_s <= MEMCTRL_EXP1;
         else
            step("Simpsons Bowling flash glue + uPD4701, 16-bit EXP1 bus (game configuration)");
            ex1_memctrl_s <= MEMCTRL_EXP1_W16;
         end if;
         tick(2);
         -- FA = 0x10: 0x82 <= 8 (FA = data << 1), 0x84 <= 0, 0x86 <= 0
         cwr16(16#680082#, 8); cwr16(16#680084#, 0); cwr16(16#680086#, 0);
         crd16_chk(16#680080#, 16#1010#, "flash word FA=0x10 (DDR3 fetch behind bus_wait)");
         crd16_chk(16#680080#, 16#1011#, "next read: FA incremented once per 16-bit read");
         crd32_chk(16#680080#, 16#00001012#, "32-bit read at 0x80: word in lanes 0-1, offset 1 reads 0");
         crd16_chk(16#680080#, 16#1013#, "32-bit read incremented FA once");
         cwr16(16#680082#, 8); crd16_chk(16#680088#, 0, "read 0x88 returns 0 (sets FA bit 0)");
         crd16_chk(16#680080#, 16#1011#, "FA = 0x11 after the 0x88 read");
         -- AMD autoselect: FA 0x555 <- AAAA, FA 0x2AA <- 5555, FA 0x555 <- 9090
         cwr16(16#680082#, 16#2AA#); crd16_chk(16#680088#, 0, "set odd FA"); cwr16(16#680080#, 16#AAAA#);
         cwr16(16#680082#, 16#155#); cwr16(16#680080#, 16#5555#);
         cwr16(16#680082#, 16#2AA#); crd16_chk(16#680088#, 0, "set odd FA"); cwr16(16#680080#, 16#9090#);
         cwr16(16#680082#, 0);
         crd16_chk(16#680080#, 16#0404#, "autoselect: maker 04h on both chips");
         crd16_chk(16#680080#, 16#ADAD#, "autoselect: device ADh on both chips");
         cwr16(16#680080#, 16#F0F0#);
         -- program 0xBEEF at FA 0x40, read back
         cwr16(16#680082#, 16#2AA#); crd16_chk(16#680088#, 0, "set odd FA"); cwr16(16#680080#, 16#AAAA#);
         cwr16(16#680082#, 16#155#); cwr16(16#680080#, 16#5555#);
         cwr16(16#680082#, 16#2AA#); crd16_chk(16#680088#, 0, "set odd FA"); cwr16(16#680080#, 16#A0A0#);
         cwr16(16#680082#, 16#20#);  cwr16(16#680080#, 16#BEEF# + cfg);
         cwr16(16#680082#, 16#20#);
         crd16_chk(16#680080#, 16#BEEF# + cfg, "program + read back FA 0x40");
         crd16_chk(16#680080#, 16#1041#, "neighbour word untouched");
         -- trackball: counts in C1/C3 (X), C5/C7 (Y); read of C9 resets
         wait until rising_edge(clk1x);
         tb_dx <= to_signed(5, 10); tb_dy <= to_signed(-3, 10); tb_strobe <= '1';
         wait until rising_edge(clk1x);
         tb_strobe <= '0';
         crd16_chk(16#6800C0#, 16#0500#, "uPD4701 X lo on the odd lane");
         crd16_chk(16#6800C2#, 16#0000#, "uPD4701 X hi");
         crd16_chk(16#6800C4#, 16#FD00#, "uPD4701 Y lo (-3 = 0xFFD)");
         crd16_chk(16#6800C6#, 16#0F00#, "uPD4701 Y hi nibble");
         crd16_chk(16#6800C8#, 16#0000#, "reset_xy_r");
         crd16_chk(16#6800C0#, 16#0000#, "X counter relative to the new origin");
      end loop;

      write(l, string'("RESULT: ") & integer'image(nchk - nfail) & "/" & integer'image(nchk) & " checks");
      writeline(output, l);
      if nfail = 0 then write(l, string'("RESULT: PASS")); else write(l, string'("RESULT: FAIL")); end if;
      writeline(output, l);
      sim_done <= '1';
      wait;
   end process;
end architecture;
