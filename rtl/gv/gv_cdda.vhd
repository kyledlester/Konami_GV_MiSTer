-- Konami GV: Red Book CD-DA player, behaviour of MAME 0.289 src/devices/sound/cdda.cpp as
-- driven by the XM-5401 SCSI model (PLAY AUDIO TRACK/INDEX, PAUSE/RESUME, READ SUB-CHANNEL).
--
-- On the board the drive's analog audio goes straight to the amplifier (CN8); it never passes
-- through the PSX SPU or a PSX CD controller.  This block produces the drive's 44.1 kHz stereo
-- stream; the top level mixes it with the SPU like MAME's speaker (SPU 0.75, CD-DA 1.0).
--
-- MAME semantics kept:
--   start(lba, blocks): playing, not paused, not ended; position = lba; cache flushed
--   pause(p)          : output silence and freeze while paused
--   end of range      : playing <= 0, ended <= 1 once the last sample has been played
--   get_audio_lba     : next frame to read - frames still buffered (rounded up)
--   frames inside a data track play as silence (adr_control bit 2)
--
-- clk1x = 33.8688 MHz = 768 * 44100 Hz, so the sample clock is exact.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gv_cdda is
   port (
      clk          : in  std_logic;
      ce           : in  std_logic;
      reset        : in  std_logic;

      -- control (SCSI target)
      start        : in  std_logic;
      start_lba    : in  unsigned(19 downto 0);
      blocks       : in  unsigned(19 downto 0);
      pause        : in  std_logic;
      pause_val    : in  std_logic;
      active       : out std_logic;
      paused       : out std_logic;
      ended        : out std_logic;
      cur_lba      : out unsigned(19 downto 0);
      vol_l        : in  unsigned(7 downto 0);
      vol_r        : in  unsigned(7 downto 0);

      first_audio  : in  unsigned(19 downto 0);      -- frames below this are data

      -- frame fetch (gv_cd_media)
      aud_req      : out std_logic;
      aud_ack      : in  std_logic;                 -- media accepted aud_lba this cycle
      aud_lba      : out unsigned(19 downto 0);
      aud_wr       : in  std_logic;
      aud_wdata    : in  std_logic_vector(15 downto 0);
      aud_done     : in  std_logic;

      -- 44.1 kHz output
      sample_l     : out signed(15 downto 0) := (others => '0');
      sample_r     : out signed(15 downto 0) := (others => '0');
      sample_tick  : out std_logic := '0';
      sample_new   : out std_logic := '0'              -- a disc sample was output (verification)
   );
end entity;

architecture rtl of gv_cdda is

   constant FRAME_WORDS : integer := 1176;          -- 588 stereo samples
   constant FIFO_WORDS  : integer := 4096;

   type t_fifo is array(0 to FIFO_WORDS-1) of std_logic_vector(15 downto 0);
   signal fifo      : t_fifo;
   signal wptr      : unsigned(11 downto 0) := (others => '0');
   signal rptr      : unsigned(11 downto 0) := (others => '0');
   signal fifo_q    : std_logic_vector(15 downto 0) := (others => '0');
   signal fifo_we   : std_logic := '0';
   signal fifo_wa   : unsigned(11 downto 0) := (others => '0');
   signal fifo_wd   : std_logic_vector(15 downto 0) := (others => '0');

   signal avail     : unsigned(11 downto 0);                     -- words readable now
   signal count     : unsigned(12 downto 0) := (others => '0');  -- words buffered + frames pending

   signal playing   : std_logic := '0';
   signal pausedr   : std_logic := '0';
   signal endedr    : std_logic := '0';
   signal pos       : unsigned(19 downto 0) := (others => '0');  -- next frame to read (m_audio_lba)
   signal remain    : unsigned(19 downto 0) := (others => '0');  -- frames left to read (m_audio_length)

   signal inflight  : std_logic := '0';                          -- disc frame requested, words arriving
   signal discard   : std_logic := '0';                          -- in-flight frame belongs to a cancelled play
   signal zfilling  : std_logic := '0';
   signal stale_ack : std_logic := '0';                          -- an ack due next cycle belongs to a cancelled play
   signal zcnt      : unsigned(10 downto 0) := (others => '0');

   signal req_s     : std_logic;
   signal want      : std_logic;
   signal div       : unsigned(9 downto 0) := (others => '0');
   signal phase     : unsigned(1 downto 0) := (others => '0');
   signal smp_l     : std_logic_vector(15 downto 0) := (others => '0');

   function scale(s : std_logic_vector(15 downto 0); v : unsigned(7 downto 0)) return signed is
      variable p : signed(24 downto 0);
   begin
      if v = x"FF" then return signed(s); end if;
      p := signed(s) * signed('0' & v);
      return p(23 downto 8);
   end function;

begin

   active  <= playing;
   paused  <= pausedr;
   ended   <= endedr;
   aud_lba <= pos;
   avail   <= wptr - rptr;

   -- room for one more frame, nothing outstanding
   want  <= '1' when playing = '1' and pausedr = '0' and remain /= 0 and inflight = '0' and zfilling = '0'
                     and count <= FIFO_WORDS - FRAME_WORDS else '0';
   req_s <= want when pos >= first_audio else '0';
   aud_req <= req_s;

   -- get_audio_lba(): position minus buffered frames, rounded up
   cur_lba <= pos                       when count = 0 else
              pos - 1                   when count <= FRAME_WORDS else
              pos - 2                   when count <= 2 * FRAME_WORDS else
              pos - 3                   when count <= 3 * FRAME_WORDS else
              pos - 4;

   process(clk)
   begin
      if rising_edge(clk) then
         if fifo_we = '1' then
            fifo(to_integer(fifo_wa)) <= fifo_wd;
         end if;
         fifo_q <= fifo(to_integer(rptr));
      end if;
   end process;

   process(clk)
      variable v_cnt : unsigned(12 downto 0);
      variable v_wp  : unsigned(11 downto 0);
   begin
      if rising_edge(clk) then
         fifo_we     <= '0';
         sample_tick <= '0';
         sample_new  <= '0';
         v_cnt       := count;
         v_wp        := wptr;

         -- in-flight frame bookkeeping (independent of reset so the media handshake stays aligned)
         if aud_done = '1' then
            inflight <= '0';
            discard  <= '0';
         end if;

         if reset = '1' then
            playing  <= '0';
            pausedr  <= '0';
            endedr   <= '0';
            remain   <= (others => '0');
            rptr     <= wptr;
            v_cnt    := (others => '0');
            zfilling <= '0';
            phase    <= "00";
            sample_l <= (others => '0');
            sample_r <= (others => '0');
            div      <= (others => '0');
            if inflight = '1' and aud_done = '0' then discard <= '1'; end if;
         else
            -- disc frame words
            if aud_wr = '1' and inflight = '1' and discard = '0' then
               fifo_we <= '1';
               fifo_wa <= wptr;
               fifo_wd <= aud_wdata;
               v_wp    := wptr + 1;
            elsif zfilling = '1' then
               -- data-track frame: silence without a disc access
               fifo_we <= '1';
               fifo_wa <= wptr;
               fifo_wd <= (others => '0');
               v_wp    := wptr + 1;
               zcnt    <= zcnt + 1;
               if zcnt = FRAME_WORDS - 1 then zfilling <= '0'; end if;
            end if;

            -- issue the next frame (disc frame when the media accepts it, data frame -> silence)
            stale_ack <= '0';
            if aud_ack = '1' and stale_ack = '1' then
               inflight <= '1';                -- old play's frame: receive and drop it
               discard  <= '1';
            elsif (req_s = '1' and aud_ack = '1') or (want = '1' and req_s = '0') then
               if req_s = '1' then
                  inflight <= '1';
               else
                  zfilling <= '1';
                  zcnt     <= (others => '0');
               end if;
               pos    <= pos + 1;
               remain <= remain - 1;
               v_cnt  := v_cnt + FRAME_WORDS;
            end if;

            -- 44.1 kHz sample clock
            if ce = '1' then
               if div = 767 then
                  div <= (others => '0');
                  sample_tick <= '1';
                  if playing = '1' and pausedr = '0' then
                     if remain = 0 and count = 0 then
                        playing  <= '0';     -- natural end (m_audio_ended_normally)
                        endedr   <= '1';
                        sample_l <= (others => '0');
                        sample_r <= (others => '0');
                     elsif avail >= 2 then
                        phase <= "01";
                     end if;
                  else
                     sample_l <= (others => '0');
                     sample_r <= (others => '0');
                  end if;
               else
                  div <= div + 1;
               end if;
            end if;

            -- read L, R (RAM read latency 1)
            case phase is
               when "01" =>
                  rptr  <= rptr + 1;
                  phase <= "10";
               when "10" =>
                  smp_l <= fifo_q;
                  rptr  <= rptr + 1;
                  phase <= "11";
               when "11" =>
                  sample_l <= scale(smp_l, vol_l);
                  sample_r <= scale(fifo_q, vol_r);
                  sample_new <= '1';
                  v_cnt    := v_cnt - 2;
                  phase    <= "00";
               when others => null;
            end case;

            if pause = '1' then
               pausedr <= pause_val;
            end if;

            if start = '1' then
               playing  <= '1';
               pausedr  <= '0';
               endedr   <= '0';
               pos      <= start_lba;
               remain   <= blocks;
               rptr     <= v_wp;               -- flush the cache (incl. a word written this cycle)
               v_cnt    := (others => '0');
               zfilling <= '0';
               phase    <= "00";
               if (inflight = '1' and aud_done = '0') or (req_s = '1' and aud_ack = '1') then
                  discard <= '1';              -- frame still arriving belongs to the old play
               end if;
               if req_s = '1' and aud_ack = '0' then
                  stale_ack <= '1';            -- media may have latched the old position this cycle
               end if;
            end if;
         end if;

         count <= v_cnt;
         wptr  <= v_wp;
      end if;
   end process;

end architecture;
