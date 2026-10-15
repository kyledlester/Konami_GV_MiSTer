-- Konami GV: The Simpsons Bowling daughtercard (PWB402610), per MAME 0.289
--   src/mame/konami/konamigv.cpp  simpbowl_state (flash_r / flash_w, simpbowl_map)
--   src/devices/machine/intelfsh.cpp  fujitsu_29f016a_device (8-bit, 2 MB, maker 04h, device ADh)
--   src/devices/machine/upd4701.cpp   uPD4701A (read_xy, reset_xy_r)
--
--   0x1F680080-8F  flash glue, 16-bit handler:
--                  W 80  data port: lo byte -> chip(2p), hi byte -> chip(2p+1), p = (FA >= 0x200000)
--                  W 82  FA = data << 1
--                  W 84  FA = (FA & 0xFF00FF) | data << 8
--                  W 86  FA = (FA & 0x00FFFF) | data << 15
--                  R 80  {chip(2p+1)[FA], chip(2p)[FA]}, then FA++     (chip address = FA & 0x1FFFFF)
--                  R 88  FA |= 1, returns 0;  other offsets read 0
--   0x1F6800C0-C7  uPD4701A read_xy, umask32(0xFF00FF00): C1 X lo, C3 X hi, C5 Y lo, C7 Y hi
--   0x1F6800C9     uPD4701A reset_xy_r (counter origin := current count)
--
-- The EXP1 bus is byte-stepped (see gv_board). A 16-bit handler call is reproduced per CPU access:
-- reads fire on the even lane (both chip bytes latched, side effects applied once), the odd lane
-- returns the latched high byte; writes fire on the odd lane with {odd, even} lanes.
--
-- Flash array: 8 MB in DDR3 (arbiter port memFlash), byte address {pair, chip address(20:0), hi},
-- i.e. the 16-bit words the glue reads, pair 0 then pair 1. CPU reads that need array data wait
-- (bus_wait) until the word is fetched; the following word is prefetched. Program/erase writes go
-- through a write queue; erase fills (0xFF with per-chip byte enables) run between other requests.
-- Erase/status timers follow MAME (chip erase 16 s, sector/block erase 1 s), measured on time_ck,
-- a free-running clk1x (33.8688 MHz) cycle count.
--
-- host_* : MiSTer nvram load/save of the whole 8 MB (16-bit words, same layout).
--
-- 16-bit personality (f16_en, Beat the Champ / Dead Eye, MAME btchamp_map / kdeadeye_map):
--   0x1F380000-0x1F3FFFFF  Sharp LH28F400 (intelfsh16: 512 KB, maker B0h, device EDh), read/write as a
--                          16-bit device: word address = (offset >> 1), chip 0 of the same FSM with 16-bit
--                          program data and 64 KB block erase (MAME: base & ~0xFFFF). Reads have no side
--                          effects, so every lane is served from the fetched word.
--   The array is the first 512 KB of the same DDR3 window; blank_fill erases it to 0xFF (a never-saved
--   flash reads blank, as in MAME without an nvram file).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gv_simpbowl is
   generic (
      CHIP_ERASE_CK : natural := 16 * 33868800;   -- MAME intelfsh: chip erase timer 16 s
      BLOCK_ERASE_CK: natural := 33868800;        -- sector / block erase timer 1 s
      WQ_BITS       : natural := 4
   );
   port (
      clk1x          : in  std_logic;
      clk2x          : in  std_logic;
      ce             : in  std_logic;
      enable         : in  std_logic;
      f16_en         : in  std_logic := '0';                -- Sharp LH28F400 at 0x1F380000
      blank_fill     : in  std_logic := '0';                -- pulse: erase the 16-bit flash array to 0xFF
      time_ck        : in  unsigned(31 downto 0);

      -- EXP1 (byte-stepped)
      bus_addr       : in  unsigned(22 downto 0);
      bus_read       : in  std_logic;
      bus_write      : in  std_logic;
      bus_dataWrite  : in  std_logic_vector(7 downto 0);
      bus_dataRead   : out std_logic_vector(7 downto 0);
      bus_sel        : out std_logic;                       -- registered: the last read was served here
      bus_wait       : out std_logic;

      -- trackball counts (clk1x strobe, signed deltas already in uPD4701 counting direction)
      tb_strobe      : in  std_logic;
      tb_dx          : in  signed(9 downto 0);
      tb_dy          : in  signed(9 downto 0);

      -- nvram host port (16-bit words, word index into the 8 MB array)
      host_addr      : in  unsigned(21 downto 0);
      host_we        : in  std_logic;
      host_wdata     : in  std_logic_vector(15 downto 0);
      host_rd        : in  std_logic;
      host_rdata     : out std_logic_vector(15 downto 0);
      host_wait      : out std_logic;
      dirty          : out std_logic;
      dirty_clr      : in  std_logic;
      fill_active    : out std_logic;                       -- an erase fill is pending / running

      -- DDR3 arbiter port (clk2x): byte address within the 8 MB window
      ddr_request    : out std_logic := '0';
      ddr_ack        : in  std_logic;
      ddr_addr       : out std_logic_vector(23 downto 0) := (others => '0');
      ddr_din        : out std_logic_vector(63 downto 0) := (others => '0');
      ddr_be         : out std_logic_vector(7 downto 0) := (others => '0');
      ddr_we         : out std_logic := '0';
      ddr_rd         : out std_logic := '0';
      ddr_dout       : in  std_logic_vector(63 downto 0);
      ddr_dout_ready : in  std_logic
   );
end entity;

architecture rtl of gv_simpbowl is

   ---------------------------------------------------------------------------
   -- flash chips (intelfsh modes reachable on an 8-bit Fujitsu 29F016A)
   ---------------------------------------------------------------------------
   type t_mode is (FM_NORMAL, FM_READSTATUS, FM_READID, FM_READAMDID1, FM_READAMDID2, FM_READAMDID3,
                   FM_ERASEAMD1, FM_ERASEAMD2, FM_ERASEAMD3, FM_ERASEAMD4, FM_BYTEPROGRAM,
                   FM_WRITEPART1, FM_CLEARPART1, FM_SETMASTER, FM_FAST_RESET);
   type t_modes  is array(0 to 3) of t_mode;
   type t_u8x4   is array(0 to 3) of std_logic_vector(7 downto 0);
   type t_u32x4  is array(0 to 3) of unsigned(31 downto 0);

   signal mode       : t_modes := (others => FM_NORMAL);
   signal status     : t_u8x4  := (others => x"80");
   signal fast_mode  : std_logic_vector(3 downto 0) := (others => '0');
   signal mlock      : std_logic_vector(3 downto 0) := (others => '0');
   signal tmr_on     : std_logic_vector(3 downto 0) := (others => '0');
   signal tmr_start  : t_u32x4 := (others => (others => '0'));
   signal tmr_len    : t_u32x4 := (others => (others => '0'));
   signal fill_busy  : std_logic_vector(3 downto 0) := (others => '0');   -- erase fill not finished

   signal fa         : unsigned(31 downto 0) := (others => '0');          -- m_flash_address

   -- bus
   signal sel_flash, sel_tb : std_logic;
   signal lane_odd   : std_logic;
   signal wr_lo      : std_logic_vector(7 downto 0) := (others => '0');
   signal rd_hold_hi : std_logic_vector(7 downto 0) := (others => '0');
   signal rd_q       : std_logic_vector(7 downto 0) := (others => '0');
   signal sel_q      : std_logic := '0';
   signal need_word  : std_logic;
   signal word_hit   : std_logic;
   signal sel_f16    : std_logic;
   signal w16        : unsigned(17 downto 0);
   signal need16     : std_logic;
   signal hit16      : std_logic;

   -- uPD4701
   signal tb_x, tb_y, tb_sx, tb_sy : unsigned(15 downto 0) := (others => '0');

   ---------------------------------------------------------------------------
   -- DDR3 engine (clk1x) and transactor (clk2x)
   ---------------------------------------------------------------------------
   constant WQ_N : natural := 2**WQ_BITS;
   type t_wq_addr is array(0 to WQ_N-1) of unsigned(22 downto 0);
   type t_wq_be   is array(0 to WQ_N-1) of std_logic_vector(7 downto 0);
   type t_wq_dat  is array(0 to WQ_N-1) of std_logic_vector(63 downto 0);
   signal wq_addr    : t_wq_addr;
   signal wq_be      : t_wq_be;
   signal wq_dat     : t_wq_dat;
   signal wq_wp, wq_rp : unsigned(WQ_BITS-1 downto 0) := (others => '0');
   signal wq_cnt     : unsigned(WQ_BITS downto 0) := (others => '0');

   -- erase fills: one pending entry per chip (merged pair fills sit in the even chip's entry)
   type t_u19x4 is array(0 to 3) of unsigned(19 downto 0);
   signal fp_valid   : std_logic_vector(3 downto 0) := (others => '0');
   signal fp_start   : t_u19x4;                                -- 64-bit word index
   signal fp_count   : t_u19x4;
   signal fp_be      : t_u8x4;
   signal fp_chips   : t_u8x4;                                 -- chips cleared when done (bits 3..0)
   signal fl_active  : std_logic := '0';
   signal fl_word    : unsigned(19 downto 0) := (others => '0');
   signal fl_left    : unsigned(19 downto 0) := (others => '0');
   signal fl_be      : std_logic_vector(7 downto 0) := (others => '0');
   signal fl_chips   : std_logic_vector(3 downto 0) := (others => '0');

   -- word cache (prefetch): tag = 16-bit word index {pair, chip address}
   signal pf_valid   : std_logic := '0';
   signal pf_tag     : unsigned(21 downto 0) := (others => '0');
   signal pf_data    : std_logic_vector(15 downto 0) := (others => '0');
   signal gen        : unsigned(7 downto 0) := (others => '0');   -- bumps on every array write

   -- current engine op
   type t_op is (OP_NONE, OP_WRITE, OP_FILL, OP_CPU_RD, OP_HOST_RD);
   signal op         : t_op := OP_NONE;
   signal op_gen     : unsigned(7 downto 0) := (others => '0');
   signal op_tag     : unsigned(21 downto 0) := (others => '0');
   signal cpu_want   : std_logic := '0';                       -- a CPU read/prefetch is wanted
   signal cpu_tag    : unsigned(21 downto 0) := (others => '0');
   signal host_pend  : std_logic := '0';
   signal host_tag   : unsigned(21 downto 0) := (others => '0');
   signal host_q     : std_logic_vector(15 downto 0) := (others => '0');
   signal host_line  : std_logic_vector(63 downto 0) := (others => '0');   -- last host-read DDR3 word
   signal host_ltag  : unsigned(19 downto 0) := (others => '0');
   signal host_lval  : std_logic := '0';
   signal dirty_r    : std_logic := '0';

   -- transactor handshake (toggles)
   signal x_go, x_done_1x : std_logic := '0';
   signal x_addr     : unsigned(22 downto 0) := (others => '0');
   signal x_we       : std_logic := '0';
   signal x_be       : std_logic_vector(7 downto 0) := (others => '0');
   signal x_din      : std_logic_vector(63 downto 0) := (others => '0');
   signal x_done     : std_logic := '0';
   signal x_seen     : std_logic := '0';
   signal x_dout     : std_logic_vector(63 downto 0) := (others => '0');
   type t_xs is (XS_IDLE, XS_ACK, XS_DATA);
   signal xs         : t_xs := XS_IDLE;

   function is_array_mode(m : t_mode) return boolean is
   begin
      return not (m = FM_READSTATUS or m = FM_READID or m = FM_READAMDID3 or m = FM_ERASEAMD4);
   end function;

   function word16(d : std_logic_vector(63 downto 0); w : unsigned(1 downto 0)) return std_logic_vector is
   begin
      case w is
         when "00"   => return d(15 downto 0);
         when "01"   => return d(31 downto 16);
         when "10"   => return d(47 downto 32);
         when others => return d(63 downto 48);
      end case;
   end function;

begin

   lane_odd  <= bus_addr(0);
   sel_flash <= '1' when enable = '1' and bus_addr(22 downto 16) = 16#68# and bus_addr(15 downto 4) = 16#008# else '0';
   sel_tb    <= '1' when enable = '1' and bus_addr(22 downto 16) = 16#68# and bus_addr(15 downto 4) = 16#00C# else '0';

   -- a data-port read needs the array word if either chip of the selected pair is in an array mode
   need_word <= '1' when (fa >= 16#200000# and (is_array_mode(mode(2)) or is_array_mode(mode(3)))) or
                         (fa <  16#200000# and (is_array_mode(mode(0)) or is_array_mode(mode(1)))) else '0';
   word_hit  <= '1' when pf_valid = '1' and pf_tag = (fa(21) or fa(22) or fa(23) or fa(24) or fa(25) or fa(26) or
                                                      fa(27) or fa(28) or fa(29) or fa(30) or fa(31)) & fa(20 downto 0)
                         and wq_cnt = 0 else '0';

   sel_f16 <= '1' when f16_en = '1' and bus_addr(22 downto 19) = "0111" else '0';
   w16     <= bus_addr(18 downto 1);
   need16  <= '1' when is_array_mode(mode(0)) else '0';
   hit16   <= '1' when pf_valid = '1' and pf_tag = resize(w16, 22) and wq_cnt = 0 else '0';

   bus_wait <= '1' when (sel_flash = '1' and bus_read = '1' and bus_addr(3 downto 0) = 0 and
                         need_word = '1' and word_hit = '0') or
                        (sel_f16 = '1' and bus_read = '1' and need16 = '1' and hit16 = '0') else '0';

   bus_dataRead <= rd_q;
   bus_sel      <= sel_q;
   dirty        <= dirty_r;
   fill_active  <= '1' when fl_active = '1' or fp_valid /= "0000" else '0';
   host_rdata   <= host_q;
   host_wait    <= '1' when host_pend = '1' or wq_cnt >= WQ_N - 4 or fl_active = '1' or fp_valid /= "0000" else '0';

   ---------------------------------------------------------------------------
   -- bus side, chip FSMs, uPD4701, DDR3 engine (clk1x)
   ---------------------------------------------------------------------------
   process(clk1x)
      variable pair     : integer range 0 to 1;
      variable caddr    : unsigned(20 downto 0);
      variable d16      : std_logic_vector(15 downto 0);
      variable cb       : std_logic_vector(7 downto 0);
      variable a16, a12 : unsigned(15 downto 0);
      variable prog_be  : std_logic_vector(7 downto 0);
      variable prog_dat : std_logic_vector(63 downto 0);
      variable fill_req : std_logic_vector(3 downto 0);
      variable fill_blk : std_logic_vector(3 downto 0);          -- 64 KB block fill (else whole chip)
      variable wtag     : unsigned(21 downto 0);
      variable rbyte    : std_logic_vector(7 downto 0);
      variable bidx     : unsigned(2 downto 0);
      variable new_mode : t_mode;
      variable pushed   : std_logic;
      variable popped   : std_logic;
      variable mm       : t_mode;
      variable pv       : std_logic;
      variable el       : unsigned(31 downto 0);
      variable taken    : boolean;
      variable cnt12    : unsigned(11 downto 0);
      variable r16      : std_logic_vector(15 downto 0);
      variable wt16     : unsigned(21 downto 0);
      variable is16     : boolean;

      -- MAME intelfsh write_full for one chip (8-bit Fujitsu 29F016A: m_addrmask = 0)
      procedure chip_write(c : integer; a : unsigned(20 downto 0); d : std_logic_vector(7 downto 0);
                           dw : std_logic_vector(15 downto 0)) is
      begin
         a16 := resize(a(15 downto 0), 16);
         a12 := resize(a(11 downto 0), 16);
         case mode(c) is
            when FM_NORMAL | FM_READSTATUS | FM_READID | FM_READAMDID3 =>
               case d is
                  when x"F0" | x"FF" => mode(c) <= FM_NORMAL;
                  when x"90" =>
                     if fast_mode(c) = '1' then mode(c) <= FM_FAST_RESET; else mode(c) <= FM_READID; end if;
                  when x"40" | x"10" => mode(c) <= FM_WRITEPART1;
                  when x"50" => status(c) <= x"80"; mode(c) <= FM_READSTATUS;
                  when x"20" => mode(c) <= FM_CLEARPART1;
                  when x"60" => mode(c) <= FM_SETMASTER;
                  when x"70" => mode(c) <= FM_READSTATUS;
                  when x"A0" =>
                     if fast_mode(c) = '1' then mode(c) <= FM_BYTEPROGRAM; end if;
                  when x"AA" =>
                     if a12 = 16#555# or a12 = 16#AAA# then mode(c) <= FM_READAMDID1; end if;
                  when others => null;
               end case;
            when FM_READAMDID1 =>
               if (a16 = 16#2AA# or a16 = 16#2AAA# or a12 = 16#555#) and d = x"55" then
                  mode(c) <= FM_READAMDID2;
               else
                  mode(c) <= FM_NORMAL;
               end if;
            when FM_READAMDID2 =>
               if (a16 = 16#555# or a16 = 16#5555# or a12 = 16#AAA#) and d = x"90" then
                  mode(c) <= FM_READAMDID3;
               elsif (a16 = 16#555# or a16 = 16#5555# or a12 = 16#AAA#) and d = x"80" then
                  mode(c) <= FM_ERASEAMD1;
               elsif (a16 = 16#555# or a16 = 16#5555# or a12 = 16#AAA#) and d = x"A0" then
                  mode(c) <= FM_BYTEPROGRAM;
               elsif (a16 = 16#555# or a16 = 16#5555# or a12 = 16#AAA#) and d = x"F0" then
                  mode(c) <= FM_NORMAL;
               elsif (a12 = 16#AAA# or a12 = 16#555#) and d = x"20" then
                  mode(c) <= FM_NORMAL;
                  fast_mode(c) <= '1';
               else
                  mode(c) <= FM_NORMAL;
               end if;
            when FM_ERASEAMD1 =>
               if (a12 = 16#555# or a12 = 16#AAA#) and d = x"AA" then mode(c) <= FM_ERASEAMD2; end if;
            when FM_ERASEAMD2 =>
               if (a16 = 16#2AA# or a16 = 16#2AAA# or a12 = 16#555#) and d = x"55" then mode(c) <= FM_ERASEAMD3; end if;
            when FM_ERASEAMD3 =>
               if (a12 = 16#555# or a12 = 16#AAA#) and d = x"10" then          -- chip erase
                  fill_req(c) := '1'; fill_blk(c) := '0';
                  status(c) <= x"08"; mode(c) <= FM_ERASEAMD4;
                  tmr_on(c) <= '1'; tmr_start(c) <= time_ck; tmr_len(c) <= to_unsigned(CHIP_ERASE_CK, 32);
               elsif d = x"30" then                                              -- sector erase (64 KB)
                  fill_req(c) := '1'; fill_blk(c) := '1';
                  status(c) <= x"08"; mode(c) <= FM_ERASEAMD4;
                  tmr_on(c) <= '1'; tmr_start(c) <= time_ck; tmr_len(c) <= to_unsigned(BLOCK_ERASE_CK, 32);
               end if;
            when FM_ERASEAMD4 => null;                                           -- writes ignored
            when FM_BYTEPROGRAM =>
               if is16 then
                  prog_be(to_integer(bidx)) := '1'; prog_be(to_integer(bidx) + 1) := '1';
                  prog_dat(8*to_integer(bidx) + 15 downto 8*to_integer(bidx)) := dw;
               else
                  prog_be(to_integer(bidx) + (c mod 2)) := '1';
                  prog_dat(8*(to_integer(bidx) + (c mod 2)) + 7 downto 8*(to_integer(bidx) + (c mod 2))) := d;
               end if;
               mode(c) <= FM_NORMAL;
            when FM_WRITEPART1 =>
               if is16 then
                  prog_be(to_integer(bidx)) := '1'; prog_be(to_integer(bidx) + 1) := '1';
                  prog_dat(8*to_integer(bidx) + 15 downto 8*to_integer(bidx)) := dw;
               else
                  prog_be(to_integer(bidx) + (c mod 2)) := '1';
                  prog_dat(8*(to_integer(bidx) + (c mod 2)) + 7 downto 8*(to_integer(bidx) + (c mod 2))) := d;
               end if;
               status(c) <= x"80"; mode(c) <= FM_READSTATUS;
            when FM_CLEARPART1 =>
               if d = x"D0" then                                                 -- block erase (64 KB)
                  fill_req(c) := '1'; fill_blk(c) := '1';
                  status(c) <= x"00"; mode(c) <= FM_READSTATUS;
                  tmr_on(c) <= '1'; tmr_start(c) <= time_ck; tmr_len(c) <= to_unsigned(BLOCK_ERASE_CK, 32);
               end if;
            when FM_SETMASTER =>
               if d = x"F1" then mlock(c) <= '1'; elsif d = x"D0" then mlock(c) <= '0'; end if;
               mode(c) <= FM_READSTATUS;
            when FM_FAST_RESET =>
               if d = x"F0" or d = x"00" then fast_mode(c) <= '0'; mode(c) <= FM_NORMAL; end if;
         end case;
      end procedure;

      -- MAME intelfsh read_full for one chip; ERASEAMD4 toggles DQ6|DQ2 per read (Fujitsu ADh: always)
      procedure chip_read(c : integer; a : unsigned(20 downto 0); arr : std_logic_vector(7 downto 0);
                          r : out std_logic_vector(7 downto 0)) is
      begin
         case mode(c) is
            when FM_READSTATUS => r := status(c);
            when FM_READAMDID3 =>
               case to_integer(a(7 downto 0)) is
                  when 0      => if is16 then r := x"B0"; else r := x"04"; end if;
                  when 1      => if is16 then r := x"ED"; else r := x"AD"; end if;
                  when others => r := x"00";
               end case;
            when FM_READID =>
               case to_integer(a(7 downto 0)) is
                  when 0      => if is16 then r := x"B0"; else r := x"04"; end if;
                  when 1      => if is16 then r := x"ED"; else r := x"AD"; end if;
                  when 3      => r := "0000000" & mlock(c);
                  when others => r := x"00";
               end case;
            when FM_ERASEAMD4 =>
               r := status(c) xor x"44";
               status(c) <= status(c) xor x"44";
            when others => r := arr;
         end case;
      end procedure;

   begin
      if rising_edge(clk1x) then
         fill_req := (others => '0');
         fill_blk := (others => '0');
         prog_be  := (others => '0');
         prog_dat := (others => '0');
         pushed   := '0';
         popped   := '0';

         if dirty_clr = '1' then dirty_r <= '0'; end if;
         is16 := f16_en = '1';

         -- pair select / chip address of the current FA (konamigv flash_r / flash_w)
         if fa >= 16#200000# then pair := 1; else pair := 0; end if;
         caddr := fa(20 downto 0);
         wtag  := to_unsigned(pair, 1) & caddr;
         bidx  := caddr(1 downto 0) & '0';

         ------------------------------------------------------------------
         -- uPD4701 counting
         ------------------------------------------------------------------
         if tb_strobe = '1' then
            tb_x <= tb_x + unsigned(resize(tb_dx, 16));
            tb_y <= tb_y + unsigned(resize(tb_dy, 16));
         end if;

         ------------------------------------------------------------------
         -- bus
         ------------------------------------------------------------------
         if ce = '1' and bus_read = '1' then
            sel_q <= sel_flash or sel_tb;
            rd_q  <= x"00";
            if sel_flash = '1' then
               if bus_addr(3 downto 0) = 0 then
                  if need_word = '0' or word_hit = '1' then          -- (else: bus_wait holds the access)
                     chip_read(2*pair,     caddr, pf_data(7 downto 0),  rbyte);
                     rd_q <= rbyte;
                     chip_read(2*pair + 1, caddr, pf_data(15 downto 8), rbyte);
                     rd_hold_hi <= rbyte;
                     fa <= fa + 1;
                     -- prefetch the next word
                     cpu_want <= '1';
                     cpu_tag  <= wtag + 1;
                  end if;
               elsif bus_addr(3 downto 0) = 1 then
                  rd_q <= rd_hold_hi;
               elsif bus_addr(3 downto 0) = 8 then
                  fa(0) <= '1';
               end if;
            elsif sel_tb = '1' then
               if bus_addr(2) = '0' then cnt12 := resize(tb_x - tb_sx, 12); else cnt12 := resize(tb_y - tb_sy, 12); end if;
               case to_integer(bus_addr(3 downto 0)) is
                  when 1 | 5  => rd_q <= std_logic_vector(cnt12(7 downto 0));
                  when 3 | 7  => rd_q <= x"0" & std_logic_vector(cnt12(11 downto 8));
                  when 9      => tb_sx <= tb_x; tb_sy <= tb_y;            -- reset_xy_r
                  when others => null;
               end case;
            end if;
         end if;

         -- 16-bit flash (Sharp LH28F400): reads are side-effect free, every lane serves from the word
         if ce = '1' and bus_read = '1' and sel_f16 = '1' then
            sel_q <= '1';
            wt16  := resize(w16, 22);
            if need16 = '0' or hit16 = '1' then
               if is_array_mode(mode(0)) then
                  r16 := pf_data;
               else
                  chip_read(0, resize(w16, 21), x"00", rbyte);
                  r16 := x"00" & rbyte;
               end if;
               if bus_addr(0) = '0' then rd_q <= r16(7 downto 0); else rd_q <= r16(15 downto 8); end if;
               if bus_addr(0) = '1' and need16 = '1' then           -- prefetch the next word
                  cpu_want <= '1';
                  cpu_tag  <= wt16 + 1;
               end if;
            elsif not (op = OP_CPU_RD and op_tag = wt16) then
               cpu_want <= '1';
               cpu_tag  <= wt16;
            end if;
         end if;
         if ce = '1' and bus_write = '1' and sel_f16 = '1' then
            if bus_addr(0) = '0' then
               wr_lo <= bus_dataWrite;
            else
               d16  := bus_dataWrite & wr_lo;
               bidx := w16(1 downto 0) & '0';
               wtag := resize(w16, 22);
               chip_write(0, resize(w16, 21), d16(7 downto 0), d16);
            end if;
         end if;

         -- a read that has to wait: make sure its word is being fetched
         if ce = '1' and bus_read = '1' and sel_flash = '1' and bus_addr(3 downto 0) = 0 and
            need_word = '1' and word_hit = '0' and not (op = OP_CPU_RD and op_tag = wtag) then
            cpu_want <= '1';
            cpu_tag  <= wtag;
         end if;

         if ce = '1' and bus_write = '1' and sel_flash = '1' then
            if lane_odd = '0' then
               wr_lo <= bus_dataWrite;
            else
               d16 := bus_dataWrite & wr_lo;
               case to_integer(bus_addr(3 downto 1)) is
                  when 0 =>
                     chip_write(2*pair,     caddr, d16(7 downto 0),  x"0000");
                     chip_write(2*pair + 1, caddr, d16(15 downto 8), x"0000");
                  when 1 => fa <= resize(unsigned(d16), 31) & '0';
                  when 2 => fa <= (fa and x"00FF00FF") or shift_left(resize(unsigned(d16), 32), 8);
                  when 3 => fa <= (fa and x"0000FFFF") or shift_left(resize(unsigned(d16), 32), 15);
                  when others => null;
               end case;
            end if;
         end if;

         ------------------------------------------------------------------
         -- erase / status timers (MAME delay_tick), once the fill has landed
         ------------------------------------------------------------------
         for c in 0 to 3 loop
            el := time_ck - tmr_start(c);
            if tmr_on(c) = '1' and el >= tmr_len(c) and fill_busy(c) = '0' and fill_req(c) = '0' then
               tmr_on(c) <= '0';
               if mode(c) = FM_READSTATUS then
                  status(c) <= x"80";
               elsif mode(c) = FM_ERASEAMD4 then
                  mode(c)   <= FM_NORMAL;
                  status(c) <= x"80";
               end if;
            end if;
         end loop;

         ------------------------------------------------------------------
         -- queue program writes / host writes, register erase fills
         ------------------------------------------------------------------
         if prog_be /= x"00" and wq_cnt < WQ_N then
            wq_addr(to_integer(wq_wp)) <= wtag & '0';
            wq_be(to_integer(wq_wp))   <= prog_be;
            wq_dat(to_integer(wq_wp))  <= prog_dat;
            wq_wp  <= wq_wp + 1;
            pushed := '1';
            dirty_r <= '1';
         elsif host_we = '1' and wq_cnt < WQ_N then
            wq_addr(to_integer(wq_wp)) <= host_addr & '0';
            case host_addr(1 downto 0) is
               when "00"   => wq_be(to_integer(wq_wp)) <= x"03";
               when "01"   => wq_be(to_integer(wq_wp)) <= x"0C";
               when "10"   => wq_be(to_integer(wq_wp)) <= x"30";
               when others => wq_be(to_integer(wq_wp)) <= x"C0";
            end case;
            wq_dat(to_integer(wq_wp)) <= host_wdata & host_wdata & host_wdata & host_wdata;
            wq_wp  <= wq_wp + 1;
            pushed := '1';
         end if;
         if pushed = '1' then
            gen      <= gen + 1;
            pf_valid <= '0';
         end if;

         for c in 0 to 3 loop
            if fill_req(c) = '1' then
               fill_busy(c) <= '1';
               dirty_r      <= '1';
               gen          <= gen + 1;
               pf_valid     <= '0';
            end if;
         end loop;
         -- 16-bit personality: one chip, 64 KB block (MAME base & ~0xFFFF) or whole 512 KB, all lanes
         if is16 and fill_req(0) = '1' then
            fp_valid(0) <= '1';
            if fill_blk(0) = '1' then
               fp_start(0) <= "0000" & w16(17 downto 15) & "0000000000000";
               fp_count(0) <= to_unsigned(8192, 20);
            else
               fp_start(0) <= (others => '0');
               fp_count(0) <= to_unsigned(65536, 20);
            end if;
            fp_be(0)    <= x"FF";
            fp_chips(0) <= x"01";
         end if;
         if blank_fill = '1' and f16_en = '1' then
            fp_valid(0) <= '1';
            fp_start(0) <= (others => '0');
            fp_count(0) <= to_unsigned(65536, 20);
            fp_be(0)    <= x"FF";
            fp_chips(0) <= x"00";
            gen         <= gen + 1;
            pf_valid    <= '0';
         end if;
         -- pair fills issued by one 16-bit write merge into the even chip's entry
         for p in 0 to 1 loop
            if not is16 and (fill_req(2*p) = '1' or fill_req(2*p+1) = '1') then
               fp_valid(2*p) <= '1';
               if fill_blk(2*p) = '1' or fill_blk(2*p+1) = '1' then
                  fp_start(2*p) <= to_unsigned(p, 1) & caddr(20 downto 16) & "00000000000000";   -- 128 KB of words
                  fp_count(2*p) <= to_unsigned(16384, 20);
               else
                  fp_start(2*p) <= to_unsigned(p, 1) & "0000000000000000000";
                  fp_count(2*p) <= to_unsigned(524288, 20);
               end if;
               fp_be(2*p)    <= (fill_req(2*p+1) & fill_req(2*p) & fill_req(2*p+1) & fill_req(2*p) &
                                 fill_req(2*p+1) & fill_req(2*p) & fill_req(2*p+1) & fill_req(2*p));
               fp_chips(2*p) <= "0000" & "00" & fill_req(2*p+1) & fill_req(2*p);
               if p = 1 then fp_chips(2*p) <= "0000" & fill_req(3) & fill_req(2) & "00"; end if;
            end if;
         end loop;

         ------------------------------------------------------------------
         -- DDR3 engine: writes > host read > CPU read/prefetch > fill
         ------------------------------------------------------------------
         if host_rd = '1' then
            if host_lval = '1' and host_ltag = host_addr(21 downto 2) and pushed = '0' and wq_cnt = 0 then
               host_q <= word16(host_line, host_addr(1 downto 0));
            else
               host_pend <= '1';
               host_tag  <= host_addr;
            end if;
         end if;
         if pushed = '1' or fill_req /= "0000" or fl_active = '1' then
            host_lval <= '0';
         end if;

         if op = OP_NONE then
            if wq_cnt /= 0 then
               op     <= OP_WRITE;
               x_addr <= wq_addr(to_integer(wq_rp));
               x_be   <= wq_be(to_integer(wq_rp));
               x_din  <= wq_dat(to_integer(wq_rp));
               x_we   <= '1';
               x_go   <= not x_go;
               wq_rp  <= wq_rp + 1;
               popped := '1';
            elsif host_pend = '1' then
               op     <= OP_HOST_RD;
               x_addr <= host_tag & '0';
               x_we   <= '0';
               x_go   <= not x_go;
            elsif cpu_want = '1' then
               op       <= OP_CPU_RD;
               op_tag   <= cpu_tag;
               op_gen   <= gen;
               cpu_want <= '0';
               x_addr   <= cpu_tag & '0';
               x_we     <= '0';
               x_go     <= not x_go;
            elsif fl_active = '1' then
               op     <= OP_FILL;
               x_addr <= fl_word & "000";
               x_be   <= fl_be;
               x_din  <= (others => '1');
               x_we   <= '1';
               x_go   <= not x_go;
            else
               taken := false;
               for c in 0 to 3 loop
                  if fp_valid(c) = '1' and not taken then
                     taken       := true;
                     fp_valid(c) <= '0';
                     fl_active   <= '1';
                     fl_word     <= fp_start(c);
                     fl_left     <= fp_count(c);
                     fl_be       <= fp_be(c);
                     fl_chips    <= fp_chips(c)(3 downto 0);
                  end if;
               end loop;
            end if;
         elsif x_done_1x /= x_go then
            null;                                                   -- transaction in flight
         else
            case op is
               when OP_CPU_RD =>
                  if op_gen = gen and pushed = '0' and fill_req = "0000" then
                     pf_valid <= '1';
                     pf_tag   <= op_tag;
                     pf_data  <= word16(x_dout, op_tag(1 downto 0));
                  end if;
               when OP_HOST_RD =>
                  host_q    <= word16(x_dout, host_tag(1 downto 0));
                  host_pend <= '0';
                  host_line <= x_dout;
                  host_ltag <= host_tag(21 downto 2);
                  host_lval <= '1';
               when OP_FILL =>
                  fl_word <= fl_word + 1;
                  fl_left <= fl_left - 1;
                  if fl_left = 1 then
                     fl_active <= '0';
                     fill_busy <= fill_busy and not fl_chips;
                     gen       <= gen + 1;
                     pf_valid  <= '0';
                  end if;
               when others => null;
            end case;
            op <= OP_NONE;
         end if;

         if pushed = '1' and popped = '0' then
            wq_cnt <= wq_cnt + 1;
         elsif pushed = '0' and popped = '1' then
            wq_cnt <= wq_cnt - 1;
         end if;
      end if;
   end process;

   ---------------------------------------------------------------------------
   -- DDR3 transactor (clk2x): one single-beat access per x_go toggle
   ---------------------------------------------------------------------------
   process(clk2x)
   begin
      if rising_edge(clk2x) then
         case xs is
            when XS_IDLE =>
               if x_go /= x_seen then
                  x_seen      <= x_go;
                  ddr_addr    <= '0' & std_logic_vector(x_addr(22 downto 3)) & "000";
                  ddr_be      <= x_be;
                  ddr_din     <= x_din;
                  ddr_we      <= x_we;
                  ddr_rd      <= not x_we;
                  ddr_request <= '1';
                  xs          <= XS_ACK;
               end if;
            when XS_ACK =>
               if ddr_ack = '1' then
                  if x_we = '1' then
                     ddr_request <= '0';
                     x_done      <= not x_done;
                     xs          <= XS_IDLE;
                  else
                     xs          <= XS_DATA;
                  end if;
               end if;
            when XS_DATA =>
               if ddr_dout_ready = '1' then
                  x_dout      <= ddr_dout;
                  ddr_request <= '0';
                  x_done      <= not x_done;
                  xs          <= XS_IDLE;
               end if;
         end case;
      end if;
   end process;

   process(clk1x)
   begin
      if rising_edge(clk1x) then
         x_done_1x <= x_done;
      end if;
   end process;

end architecture;
