# Expansion-board games: Beat the Champ, Dead Eye, Tokimeki Memorial Oshiete Your Heart

All three use MAME 0.289 `konamigv.cpp` as the
specification. The MRA's board-config byte (ioctl index 4, byte 0) selects the board:

| bit | board | MAME machine |
|---|---|---|
| 0 | Simpsons Bowling: 4× 29F016A flash + uPD4701A trackball | `simpbowl` |
| 1 | Beat the Champ: Sharp LH28F400 flash + 2× uPD4701A trackballs | `btchamp` |
| 2 | Dead Eye: Sharp LH28F400 flash + light-gun interface | `kdeadeye` |
| 3 | Tokimeki: heart-rate / GSR sensors, video printer, device check on P2 bit 10 | `tmosh` |

The same bits select the OSD page "Expansion Board" and its options, so each game shows only its own
(trackball for Simpsons Bowling and Beat the Champ, Factory Reset for Beat the Champ, guns for Dead Eye,
Heart Rate for Tokimeki).

## Shared pieces

* `rtl/gv/gv_simpbowl.vhd` also implements the 16-bit **Sharp LH28F400** (MAME `intelfsh16`, maker B0h,
  device EDh, 512 KB, 64 KB block erase, 1 s erase/program timers) at 0x1F380000–0x1F3FFFFF when
  `f16_en` is set. The array lives in DDR3 (arbiter port `memFlash`); reads stall EXP1 with
  `bus_exp1_wait`. Verified by replaying 16,746,280 flash bus events captured from MAME `btchamp`
  (`tb_gv_simpbowl -gF16=true`): 27,195,660 read bytes identical.
* Persistence: MRA nvram index 3 = 128-byte EEPROM followed by the 512 KB flash, kept in MAME byte order
  (big-endian words, the same bytes as MAME's `nvram/<set>/flash`).
* `rtl/gv/gv_expio.vhd`: the expansion ports at 0x1F680080–FF for all three boards.

## Beat the Champ (`btchamp`, GV053 UAA01)

**MAME: not working** — it stops at "FLASH ROM CORRUPT" because the flash ships blank. The game's
power-up code (PSX.EXE 0x8001D01C) looks for a factory host on the **PSX serial port SIO1**: with DSR
asserted it sends `S\n`, expects `EN\n`, sends a 12-character encoded challenge and reads 12 characters
back; if they decode to a zero payload it sets its factory flag (`[0x800B469C]`), runs its own flash test
and writes the factory defaults ("SETTINGS INITIALIZED"). MAME connects nothing to SIO1. Echoing the
challenge decodes to the zero payload; this was proven in MAME with a Lua host, after which btchamp passes the check, tests and
initialises its flash ("FLASH ROM CHECK:OK", "SETTINGS INITIALIZED") and reaches attract mode.

The core does the same in hardware (`rtl/gv/gv_sio_host.vhd`, `rtl/sio.vhd` external port): the host is
active on a boot without saved flash data, or when OSD "Expansion Board -> Factory Reset" = Next Boot, and
only until it has answered once. **No game code or data is modified**: the game initialises its own flash.

Inputs: P1–P4 joystick + 3 buttons (MAME `btchamp` ports); trackball 0 = USB trackball / mouse and/or the
P1 left analog stick (same path as Simpsons Bowling, MAME's X axis is not reversed for this game);
trackball 1 = the P2 left analog stick. uPD4701A semantics (`upd4701.cpp`): CS falling latches,
reads with CS high see the live count, reset sets the origin and blocks counting.

## Dead Eye (`kdeadeye`, GV054 UAA01)

**MAME: not working** (listed), but with the set's factory flash image (`kdeadeye.flash`) it boots, runs
attract and plays in MAME. The MRA loads that image after the EEPROM; saved nvram replaces it later.

Guns (`kdeadeye_map`): 0x80/0x90 GUNX1/GUNY1, 0xA0/0xB0 GUNX2/GUNY2 (16-bit), 0xC0 triggers (active
low). MAME's range is X 0x4C–0x1BB, Y 0x00–0xEF across the visible screen; the core maps each
player's left analog stick (−128..127) linearly onto it. MiSTer Main presents light guns (GunCon 2,
Sinden, Gun4IR, Wiimote) as analog-stick positions, so these work directly, as on the Namco NB-1 core's
Point Blank. P1 can also aim with the mouse (OSD "Gun Aim P1"). Trigger = Button 1. OSD "Crosshair"
draws both aim points (MAME draws its own crosshairs; a real cabinet has none); it is hidden while the
gun is off the screen.

**Reload (shoot off the screen).** The game reloads when a shot reads a position outside its window
(checked in MAME with forced port values: X = Y = 0 or FFFFh reload, X = 4Ch / Y = 0 does not). MiSTer's
off-screen convention, used by the PSX core's GunCon too, is an aim axis at its limit (0x00 or 0xFF after
+128): Main clamps a CRT gun that has lost the picture for 50 ms to the stick limits, and the mouse does
the same at an edge. Such an aim reads X = Y = 0.

**Gun Flash (OSD).** A CRT light gun (GunCon) only sees lit parts of the picture; Dead Eye has many dark
scenes and does not flash the screen on a shot (MAME: frame brightness unchanged around trigger pulls), so
the gun drops to "off-screen" there. With Gun Flash on, a trigger pull shows two white frames and reaches
the game two frames (~33 ms) later, after the gun has read the lit screen. Off-screen shots still reload.
Not needed for Sinden or other guns that track a border.

## Tokimeki Memorial Oshiete Your Heart (`tmosh`, GQ673 JAA)

**Playable without the real sensors and printer.** MAME (sensors simulated) plays through a whole game:
name and birthday entry, dates with the heart-rate meter, continue, and the print-card ending. The core
implements the same model:

* Heart rate: a heartbeat pulse at the OSD "Heart Rate" setting (80 = MAME's default, 60/100/120/150) or
  Hand Off (no pulse: the game treats the hand as off the sensor). Read as bit 2 of 0x80, re-armed by the
  read, exactly as `tokimeki_serial_r`.
* GSR (skin response, sensor ID 1Ah over the 5-bit serial select, read MSB first on bit 3): the P1 left
  analog stick pulled down (0 at rest .. 0x7F fully down; MAME's usable range is 0x00–0x80).
* Printer: commands are decoded from the pulse widths (MAME's tick thresholds); the print command sets
  "printing" for one second, paper present, no fault. The printed card is not rendered (MAME draws it on
  a second screen; this core has no second screen).
* Device check: P2 bit 10 = bit 15 of a 16-bit value rotated on each rising EEPROMOUT bit 4, starting at
  0 for `tmosh` (F073h `tmoshs`, F0BAh `tmoshsp`, for later).

Inputs: P1 joystick + Button 1 (there is no start button: Button 1 starts); the factory EEPROM asks for
2 coins per credit.

## Disc audio positions

Dead Eye and Tokimeki start their music with PLAY AUDIO TRACK/INDEX. CD audio uses MiSTer Main's track
starts as delivered, as for the base games (see `CD_MEDIA.md`).

## Improvements over MAME 0.289

* Beat the Champ runs from a blank flash (factory host on SIO1); MAME stops at "FLASH ROM CORRUPT".
* Real light guns via Main's gun support; per-player crosshair option.

## Verification

| Test | Result |
|---|---|
| 16-bit flash replay from MAME btchamp (16.7 M events) | 27,195,660 read bytes identical |
| `tb_gv_expio`: uPD4701A latch/reset/live reads, gun ports, GSR serial readout, device-check rotation, factory-host exchange | 73/73 |
| MAME 0.289: btchamp with a Lua factory host; kdeadeye with its flash; tmosh with simulated sensors | btchamp: flash initialised, attract; kdeadeye: attract and gameplay; tmosh: full game to the print-card ending |
