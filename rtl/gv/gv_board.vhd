-- Konami GV (ZV610 / GV999) base board devices on the PSX EXP1 bus, per MAME 0.289
-- src/mame/konami/konamigv.cpp konamigv_map():
--
--   0x1F000000-1F       NCR 53CF96, 8-bit device on D0-D7: umask16(0x00ff) -> register n at
--                       byte offset 2n, odd bytes are not connected
--   0x1F100000-03       P1     (32-bit input port, active low; bit 13 = 93C46 DO, active high)
--   0x1F100004-07       P2
--   0x1F100008-0B       P3_P4
--   0x1F180000-03       EEPROMOUT (write): bit0 DI, bit1 CS, bit2 CLK
--   0x1F680000-0F       MB89371 dual UART, umask32(0x00ff00ff): ch0 regs at 0,2,4,6, ch1 at 8,A,C,E
--   0x1F780000-03       watchdog (write ignored)
--
-- The EXP1 bus is presented byte-stepped by memorymux: bus_addr is the true byte address
-- (offset from 0x1F000000) of each lane of a CPU access, so MAME's umask lane semantics are
-- reproduced exactly by decoding the byte address.  Read data is registered (valid the cycle
-- after bus_read), which is what memorymux samples.
--
-- DMA channel 5 is bridged to the NCR's byte DMA port (MAME konamigv scsi_dma_read/write:
-- 4 bytes per 32-bit word, little-endian).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.gv_scsi_pkg.all;

entity gv_board is
   port (
      clk1x          : in  std_logic;
      ce             : in  std_logic;
      reset          : in  std_logic;

      -- EXP1 (byte-stepped)
      bus_addr       : in  unsigned(22 downto 0);
      bus_read       : in  std_logic;
      bus_write      : in  std_logic;
      bus_dataWrite  : in  std_logic_vector(7 downto 0);
      bus_dataRead   : out std_logic_vector(7 downto 0);

      irq10          : out std_logic := '0';                 -- one-cycle pulse per NCR IRQ assertion

      -- DMA channel 5
      dma_request    : out std_logic;
      dma_rd_ena     : in  std_logic;                        -- engine waits for / takes a word (to RAM)
      dma_rd_data    : out std_logic_vector(31 downto 0);
      dma_rd_valid   : out std_logic;
      dma_wr_ena     : in  std_logic;                        -- engine delivers a word (from RAM)
      dma_wr_data    : in  std_logic_vector(31 downto 0);

      -- inputs (active low, MAME port layout; P1 bit 13 is replaced by the EEPROM DO line)
      in_p1          : in  std_logic_vector(31 downto 0);
      in_p2          : in  std_logic_vector(31 downto 0);
      in_p3p4        : in  std_logic_vector(31 downto 0);
      coin_counter   : out std_logic;                        -- EEPROMOUT bit 3
      eepromout      : out std_logic_vector(7 downto 0);     -- whole EEPROMOUT register (expansion boards)

      -- EEPROM host port (ioctl load/save)
      ee_addr        : in  unsigned(5 downto 0);
      ee_wdata       : in  std_logic_vector(15 downto 0);
      ee_we          : in  std_logic;
      ee_rdata       : out std_logic_vector(15 downto 0);
      ee_dirty       : out std_logic;

      -- optical media (MiSTer Main PSX CD protocol, sd slot 1)
      toc_wr         : in  std_logic;
      toc_waddr      : in  unsigned(8 downto 0);
      toc_wdata      : in  std_logic_vector(31 downto 0);
      img_mounted    : in  std_logic;
      cd_reset_req   : out std_logic;
      hps_req        : out std_logic;
      hps_lba        : out std_logic_vector(31 downto 0);
      hps_ack        : in  std_logic;
      hps_wr         : in  std_logic;
      hps_data       : in  std_logic_vector(15 downto 0);

      -- CD-DA output (drive analog out on the real board)
      cdda_l         : out signed(15 downto 0);
      cdda_r         : out signed(15 downto 0);

      -- status for diagnostics / OSD
      disc_present   : out std_logic
   );
end entity;

architecture rtl of gv_board is

   signal region      : unsigned(6 downto 0);
   signal sel_ncr     : std_logic;

   -- NCR
   signal ncr_rd, ncr_wr : std_logic;
   signal ncr_dout    : std_logic_vector(7 downto 0);
   signal ncr_dma_rd, ncr_dma_wr : std_logic := '0';
   signal ncr_dma_din : std_logic_vector(7 downto 0) := (others => '0');
   signal ncr_dma_dout: std_logic_vector(7 downto 0);
   signal ncr_drq     : std_logic;
   signal ncr_busy    : std_logic;
   signal ncr_fifo    : unsigned(4 downto 0);
   signal ncr_irq     : std_logic;
   signal ncr_irq_q   : std_logic := '0';
   signal ncr_dir_out : std_logic;
   signal bus_i       : t_scsi_init;
   signal bus_t       : t_scsi_targ;

   -- target <-> media <-> cdda
   signal toc_addr    : unsigned(6 downto 0);
   signal toc_start   : unsigned(19 downto 0);
   signal toc_audio   : std_logic;
   signal toc_last    : unsigned(6 downto 0);
   signal first_audio : unsigned(19 downto 0);
   signal disc_ok     : std_logic;
   signal sec_lba     : unsigned(19 downto 0);
   signal sec_want, sec_next, sec_ready : std_logic;
   signal sec_addr    : unsigned(10 downto 0);
   signal sec_data    : std_logic_vector(7 downto 0);
   signal c_start, c_pause, c_pause_val : std_logic;
   signal c_start_lba, c_blocks, c_cur : unsigned(19 downto 0);
   signal c_active, c_paused, c_ended : std_logic;
   signal c_vol_l, c_vol_r : unsigned(7 downto 0);
   signal aud_req, aud_ack, aud_wr, aud_done : std_logic;
   signal aud_lba     : unsigned(19 downto 0);
   signal aud_wdata   : std_logic_vector(15 downto 0);

   -- EEPROM
   signal ee_port_wr  : std_logic;
   signal ee_do       : std_logic;
   signal eep_out     : std_logic_vector(7 downto 0) := (others => '0');

   -- MB89371 mode/baud registers (two 8251s are not otherwise used by GV software)
   type t_u8x2 is array(0 to 1) of std_logic_vector(7 downto 0);
   signal mb_mode     : t_u8x2 := (others => x"F0");
   signal mb_baud     : t_u8x2 := (others => x"00");

   -- read mux
   signal rd_from_ncr : std_logic := '0';
   signal rd_reg      : std_logic_vector(7 downto 0) := (others => '0');

   -- DMA bridge
   signal ib_word     : std_logic_vector(31 downto 0) := (others => '0');
   signal ib_cnt      : unsigned(2 downto 0) := (others => '0');
   signal ob_word     : std_logic_vector(31 downto 0) := (others => '0');
   signal ob_cnt      : unsigned(2 downto 0) := (others => '0');   -- bytes left to push
   signal busy_q      : std_logic := '0';
   signal xfer_ended  : std_logic := '0';   -- an NCR DMA transfer ran and ended; release a waiting engine

   function lane(v : std_logic_vector(31 downto 0); a : unsigned(1 downto 0)) return std_logic_vector is
   begin
      case a is
         when "00"   => return v(7 downto 0);
         when "01"   => return v(15 downto 8);
         when "10"   => return v(23 downto 16);
         when others => return v(31 downto 24);
      end case;
   end function;

begin

   region  <= bus_addr(22 downto 16);
   sel_ncr <= '1' when region = 0 and bus_addr(15 downto 5) = 0 and bus_addr(0) = '0' else '0';
   ncr_rd  <= bus_read  and ce and sel_ncr;
   ncr_wr  <= bus_write and ce and sel_ncr;

   ee_port_wr   <= '1' when bus_write = '1' and ce = '1' and region = 16#18# and bus_addr(15 downto 0) = 0 else '0';
   coin_counter <= eep_out(3);
   eepromout    <= eep_out;
   disc_present <= disc_ok;

   bus_dataRead <= ncr_dout when rd_from_ncr = '1' else rd_reg;

   ---------------------------------------------------------------------------
   -- register reads / writes other than the NCR
   ---------------------------------------------------------------------------
   process(clk1x)
      variable p : std_logic_vector(31 downto 0);
      variable r : integer range 0 to 3;
   begin
      if rising_edge(clk1x) then
         if reset = '1' then
            rd_from_ncr <= '0';
            rd_reg      <= (others => '0');
            eep_out     <= (others => '0');
            mb_mode     <= (others => x"F0");
            mb_baud     <= (others => x"00");
         elsif ce = '1' then
            if bus_read = '1' then
               rd_from_ncr <= sel_ncr;
               rd_reg      <= x"00";                                    -- unmapped / unconnected lanes
               if region = 16#10# and bus_addr(15 downto 4) = 0 then
                  case bus_addr(3 downto 2) is
                     when "00"   => p := in_p1; p(13) := ee_do;
                     when "01"   => p := in_p2;
                     when "10"   => p := in_p3p4;
                     when others => p := (others => '0');
                  end case;
                  if bus_addr(3 downto 2) /= "11" then
                     rd_reg <= lane(p, bus_addr(1 downto 0));
                  end if;
               elsif region = 16#68# and bus_addr(15 downto 4) = 0 and bus_addr(0) = '0' then
                  r := to_integer(bus_addr(2 downto 1));
                  case r is
                     when 0      => rd_reg <= x"00";                        -- 8251 data
                     when 1      => rd_reg <= x"05";                        -- 8251 status: TxRDY | TxEMPTY
                     when 2      => rd_reg <= mb_baud(to_integer(bus_addr(3 downto 3)));
                     when others => rd_reg <= mb_mode(to_integer(bus_addr(3 downto 3)));
                  end case;
               end if;
            end if;

            if bus_write = '1' then
               if ee_port_wr = '1' then
                  eep_out <= bus_dataWrite;
               end if;
               if region = 16#68# and bus_addr(15 downto 4) = 0 and bus_addr(0) = '0' then
                  case to_integer(bus_addr(2 downto 1)) is
                     when 2      => mb_baud(to_integer(bus_addr(3 downto 3))) <= bus_dataWrite;
                     when 3      => mb_mode(to_integer(bus_addr(3 downto 3))) <= bus_dataWrite;
                     when others => null;
                  end case;
               end if;
            end if;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------------------
   -- IRQ10: the PSX interrupt controller latches rising edges of the NCR IRQ line
   ---------------------------------------------------------------------------
   process(clk1x)
   begin
      if rising_edge(clk1x) then
         ncr_irq_q <= ncr_irq;
         irq10     <= ncr_irq and not ncr_irq_q;
      end if;
   end process;

   ---------------------------------------------------------------------------
   -- DMA channel 5 bridge
   ---------------------------------------------------------------------------
   dma_rd_data  <= ib_word;
   -- The PSX engine starts channel 5 when CHCR is written, before the NCR transfer command, and then
   -- waits (read stall) for words. If the SCSI data phase ends before the programmed block count,
   -- MAME simply stops transferring; here the remaining words are released with stale data so the
   -- engine (and the paused CPU) cannot hang. Never seen with Susume (counts always match).
   dma_rd_valid <= '1' when ib_cnt = 4 or (xfer_ended = '1' and ncr_fifo = 0) else '0';
   dma_request  <= (ncr_drq or (ib_cnt(2) and not ncr_dir_out)) when ncr_dir_out = '0' else
                   '1' when ob_cnt = 0 and ncr_drq = '1' and ncr_fifo <= 12 else '0';

   process(clk1x)
   begin
      if rising_edge(clk1x) then
         ncr_dma_rd <= '0';
         ncr_dma_wr <= '0';
         busy_q     <= ncr_busy;
         -- armed when a DMA transfer command ends; cleared by the next NCR command (the CPU, which
         -- writes commands, is paused while the engine waits, so it cannot clear it too early)
         if ncr_wr = '1' and bus_addr(4 downto 1) = 3 then
            xfer_ended <= '0';
         elsif busy_q = '1' and ncr_busy = '0' then
            xfer_ended <= '1';
         end if;
         if reset = '1' then
            xfer_ended <= '0';
            ib_cnt <= (others => '0');
            ob_cnt <= (others => '0');
         else
            -- to RAM: pop exactly the 4 bytes of the word the engine is waiting for.
            -- A pop issued last cycle completes this cycle (NCR samples dma_rd, dma_dout = fifo[0]).
            if ncr_dma_rd = '1' and ce = '1' then
               case ib_cnt(1 downto 0) is
                  when "00"   => ib_word(7 downto 0)   <= ncr_dma_dout;
                  when "01"   => ib_word(15 downto 8)  <= ncr_dma_dout;
                  when "10"   => ib_word(23 downto 16) <= ncr_dma_dout;
                  when others => ib_word(31 downto 24) <= ncr_dma_dout;
               end case;
               ib_cnt <= ib_cnt + 1;
            elsif ce = '1' and dma_rd_ena = '1' and (ib_cnt = 4 or (xfer_ended = '1' and ncr_fifo = 0)) then
               ib_cnt <= (others => '0');                           -- word taken by the engine
            elsif dma_rd_ena = '1' and ib_cnt < 4 and ncr_fifo /= 0 then
               ncr_dma_rd <= '1';
            end if;

            -- from RAM: accept a word, push it LSB first
            if ce = '1' and dma_wr_ena = '1' and ob_cnt = 0 then
               ob_word <= dma_wr_data;
               ob_cnt  <= to_unsigned(4, 3);
            elsif ob_cnt /= 0 and ncr_dma_wr = '0' then
               ncr_dma_wr  <= '1';
               ncr_dma_din <= ob_word(7 downto 0);
               ob_word     <= x"00" & ob_word(31 downto 8);
               ob_cnt      <= ob_cnt - 1;
            end if;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------------------
   -- devices
   ---------------------------------------------------------------------------
   incr : entity work.gv_ncr53cf96
   port map (
      clk       => clk1x,
      ce        => ce,
      reset     => reset,
      reg_addr  => bus_addr(4 downto 1),
      reg_rd    => ncr_rd,
      reg_wr    => ncr_wr,
      reg_din   => bus_dataWrite,
      reg_dout  => ncr_dout,
      dma_rd    => ncr_dma_rd,
      dma_wr    => ncr_dma_wr,
      dma_din   => ncr_dma_din,
      dma_dout  => ncr_dma_dout,
      drq       => ncr_drq,
      dma_busy  => ncr_busy,
      dma_dir_out => ncr_dir_out,
      fifo_cnt  => ncr_fifo,
      irq       => ncr_irq,
      bus_out   => bus_i,
      bus_targ  => bus_t
   );

   icdrom : entity work.gv_scsi_cdrom
   generic map (SCSI_ID => 4)
   port map (
      clk            => clk1x,
      ce             => ce,
      reset          => reset,
      bus_init       => bus_i,
      bus_out        => bus_t,
      disc_present   => disc_ok,
      toc_last       => toc_last,
      toc_addr       => toc_addr,
      toc_start      => toc_start,
      toc_audio      => toc_audio,
      sec_lba        => sec_lba,
      sec_want       => sec_want,
      sec_next       => sec_next,
      sec_ready      => sec_ready,
      sec_addr       => sec_addr,
      sec_data       => sec_data,
      cdda_start     => c_start,
      cdda_start_lba => c_start_lba,
      cdda_blocks    => c_blocks,
      cdda_pause     => c_pause,
      cdda_pause_val => c_pause_val,
      cdda_active    => c_active,
      cdda_paused    => c_paused,
      cdda_ended     => c_ended,
      cdda_cur_lba   => c_cur,
      cdda_vol_l     => c_vol_l,
      cdda_vol_r     => c_vol_r
   );

   imedia : entity work.gv_cd_media
   port map (
      clk           => clk1x,
      reset         => reset,
      toc_wr        => toc_wr,
      toc_waddr     => toc_waddr,
      toc_wdata     => toc_wdata,
      img_mounted   => img_mounted,
      reset_request => cd_reset_req,
      disc_present  => disc_ok,
      toc_last      => toc_last,
      toc_addr      => toc_addr,
      toc_start     => toc_start,
      toc_audio     => toc_audio,
      first_audio   => first_audio,
      sec_lba       => sec_lba,
      sec_want      => sec_want,
      sec_next      => sec_next,
      sec_ready     => sec_ready,
      sec_addr      => sec_addr,
      sec_data      => sec_data,
      aud_req       => aud_req,
      aud_ack       => aud_ack,
      aud_lba       => aud_lba,
      aud_wr        => aud_wr,
      aud_wdata     => aud_wdata,
      aud_done      => aud_done,
      hps_req       => hps_req,
      hps_lba       => hps_lba,
      hps_ack       => hps_ack,
      hps_wr        => hps_wr,
      hps_data      => hps_data
   );

   icdda : entity work.gv_cdda
   port map (
      clk         => clk1x,
      ce          => ce,
      reset       => reset,
      start       => c_start,
      start_lba   => c_start_lba,
      blocks      => c_blocks,
      pause       => c_pause,
      pause_val   => c_pause_val,
      active      => c_active,
      paused      => c_paused,
      ended       => c_ended,
      cur_lba     => c_cur,
      vol_l       => c_vol_l,
      vol_r       => c_vol_r,
      first_audio => first_audio,
      aud_req     => aud_req,
      aud_ack     => aud_ack,
      aud_lba     => aud_lba,
      aud_wr      => aud_wr,
      aud_wdata   => aud_wdata,
      aud_done    => aud_done,
      sample_l    => cdda_l,
      sample_r    => cdda_r,
      sample_tick => open
   );

   ieeprom : entity work.gv_eeprom93c46
   port map (
      clk        => clk1x,
      reset      => reset,
      port_wr    => ee_port_wr,
      port_di    => bus_dataWrite(0),
      port_cs    => bus_dataWrite(1),
      port_clk   => bus_dataWrite(2),
      do_out     => ee_do,
      host_addr  => ee_addr,
      host_wdata => ee_wdata,
      host_we    => ee_we,
      host_rdata => ee_rdata,
      dirty      => ee_dirty
   );

end architecture;
