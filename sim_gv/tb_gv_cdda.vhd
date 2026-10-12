-- CD-DA path check: gv_cd_media + gv_cdda play real Red Book frames (track 6 of the test image)
-- and every output sample must equal the disc sample; play must end naturally (ended=1,
-- active=0) after the requested block count; pause must freeze output; get_audio_lba must
-- report the frame currently being played.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_gv_cdda is
   generic (VEC : string := "../cdda/"; START : integer := 71073; BLOCKS : integer := 6);
end entity;

architecture sim of tb_gv_cdda is
   signal clk : std_logic := '0';
   signal done : boolean := false;
   signal reset : std_logic := '1';
   signal toc_wr : std_logic := '0';
   signal toc_wa : unsigned(8 downto 0) := (others => '0');
   signal toc_wd : std_logic_vector(31 downto 0);
   signal mounted : std_logic := '0';
   signal hps_req, hps_ack, hps_wr : std_logic := '0';
   signal hps_lba : std_logic_vector(31 downto 0);
   signal hps_data : std_logic_vector(15 downto 0);
   signal aud_req, aud_ack, aud_wr, aud_done : std_logic;
   signal aud_lba : unsigned(19 downto 0);
   signal aud_wdata : std_logic_vector(15 downto 0);
   signal first_audio : unsigned(19 downto 0);
   signal start_s, pause_s, pause_v : std_logic := '0';
   signal active, paused, ended, newsmp : std_logic;
   signal cur : unsigned(19 downto 0);
   signal sl, sr : signed(15 downto 0);
   type t_map  is array(0 to 230000) of integer;
   type t_data is array(natural range <>) of integer;
begin
   clk <= not clk after 14.76 ns when not done;

   imedia : entity work.gv_cd_media port map (
      clk => clk, reset => reset, toc_wr => toc_wr, toc_waddr => toc_wa, toc_wdata => toc_wd,
      img_mounted => mounted, reset_request => open, disc_present => open, toc_last => open,
      toc_addr => (others => '0'), toc_start => open, toc_audio => open, first_audio => first_audio,
      sec_lba => (others => '0'), sec_want => '0', sec_next => '0', sec_ready => open,
      sec_addr => (others => '0'), sec_data => open,
      aud_req => aud_req, aud_ack => aud_ack, aud_lba => aud_lba, aud_wr => aud_wr,
      aud_wdata => aud_wdata, aud_done => aud_done,
      hps_req => hps_req, hps_lba => hps_lba, hps_ack => hps_ack, hps_wr => hps_wr, hps_data => hps_data);

   icdda : entity work.gv_cdda port map (
      clk => clk, ce => '1', reset => reset, start => start_s, start_lba => to_unsigned(START, 20),
      blocks => to_unsigned(BLOCKS, 20), pause => pause_s, pause_val => pause_v,
      active => active, paused => paused, ended => ended, cur_lba => cur, vol_l => x"FF", vol_r => x"FF",
      first_audio => first_audio, aud_req => aud_req, aud_ack => aud_ack, aud_lba => aud_lba,
      aud_wr => aud_wr, aud_wdata => aud_wdata, aud_done => aud_done,
      sample_l => sl, sample_r => sr, sample_tick => open, sample_new => newsmp);

   hps : process
      variable smap  : t_map := (others => -1);
      variable sdata : t_data(0 to 16 * 1176 - 1);
      file f : text; variable l : line; variable c : character;
      variable slot, lba : integer; variable w : std_logic_vector(15 downto 0);
   begin
      file_open(f, VEC & "sectors.txt", read_mode);
      slot := 0;
      while not endfile(f) loop
         readline(f, l);
         if l'length > 0 and l(l'low) = 'S' then
            read(l, c); read(l, lba); smap(lba) := slot;
            for k in 0 to 48 loop
               readline(f, l);
               for j in 0 to 23 loop hread(l, w); sdata(slot * 1176 + k * 24 + j) := to_integer(unsigned(w)); end loop;
            end loop;
            slot := slot + 1;
         end if;
      end loop;
      loop
         wait until rising_edge(clk) and hps_req = '1';
         lba := to_integer(unsigned(hps_lba));
         for i in 1 to 300 loop wait until rising_edge(clk); end loop;
         hps_ack <= '1'; wait until rising_edge(clk);
         slot := smap(lba);
         assert slot >= 0 report "HPS request outside test frames: " & integer'image(lba) severity error;
         for i in 0 to 1175 loop
            if slot >= 0 then hps_data <= std_logic_vector(to_unsigned(sdata(slot * 1176 + i), 16)); end if;
            hps_wr <= '1'; wait until rising_edge(clk); hps_wr <= '0'; wait until rising_edge(clk);
         end loop;
         hps_ack <= '0'; wait until rising_edge(clk);
      end loop;
   end process;

   stim : process
      file f : text; variable l : line; variable wv : std_logic_vector(31 downto 0);
      variable el, er : std_logic_vector(15 downto 0);
      variable a, nsmp, bad : integer := 0;
      variable cur_at_1000 : integer := -1;
      procedure tick(n : integer) is begin for i in 1 to n loop wait until rising_edge(clk); end loop; end procedure;
   begin
      tick(5); reset <= '0'; tick(5);
      file_open(f, VEC & "toc.txt", read_mode);
      while not endfile(f) loop
         readline(f, l); hread(l, wv);
         toc_wd <= wv; toc_wa <= to_unsigned(a, 9); toc_wr <= '1'; tick(1); toc_wr <= '0'; tick(1); a := a + 1;
      end loop;
      file_close(f);
      mounted <= '1'; tick(50);
      assert first_audio = 8073 report "first audio frame " & integer'image(to_integer(first_audio)) severity error;

      start_s <= '1'; tick(1); start_s <= '0';
      file_open(f, VEC & "expect_samples.txt", read_mode);
      while active = '1' or nsmp = 0 loop
         wait until rising_edge(clk);
         if newsmp = '1' then
            readline(f, l); hread(l, el); hread(l, er);
            if std_logic_vector(sl) /= el or std_logic_vector(sr) /= er then
               bad := bad + 1;
               if bad < 10 then
                  report "sample " & integer'image(nsmp) & " got " & to_hstring(sl) & "," & to_hstring(sr) &
                         " disc " & to_hstring(el) & "," & to_hstring(er) severity warning;
               end if;
            end if;
            nsmp := nsmp + 1;
            if nsmp = 1000 then
               cur_at_1000 := to_integer(cur);
               pause_v <= '1'; pause_s <= '1'; tick(1); pause_s <= '0';
               for i in 1 to 50 * 768 loop
                  wait until rising_edge(clk);
                  assert newsmp = '0' report "sample produced while paused" severity error;
               end loop;
               pause_v <= '0'; pause_s <= '1'; tick(1); pause_s <= '0';
            end if;
         end if;
      end loop;
      report "CDDA SUMMARY: samples=" & integer'image(nsmp) & " expected=" & integer'image(588 * BLOCKS) &
             " mismatches=" & integer'image(bad) & " ended=" & std_logic'image(ended) &
             " cur_lba@1000=" & integer'image(cur_at_1000) & " (playing frame " & integer'image(START + 1000 / 588) & ")";
      if bad = 0 and nsmp = 588 * BLOCKS and ended = '1' and active = '0' then
         report "RESULT: PASS";
      else
         report "RESULT: FAIL";
      end if;
      done <= true; wait;
   end process;
end architecture;
