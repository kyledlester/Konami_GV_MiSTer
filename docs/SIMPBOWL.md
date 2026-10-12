# The Simpsons Bowling (GQ829 UAA)

GV999 board plus the PWB402610 daughtercard (MAME 0.289 `simpbowl_state`): four Fujitsu MBM29F016A
flash chips (8 MB, the game program and data) and one NEC uPD4701A trackball counter. The normal GV
hardware (SCSI CD-ROM, 93C46, inputs) is unchanged.

## Files

| File | Source | MiSTer location |
|---|---|---|
| `KonamiGV_YYYYMMDD.rbf` | `Releases/` | `/media/fat/_Arcade/cores/` |
| `The Simpsons Bowling (GQ829 UAA).mra` | `MRA/` | `/media/fat/_Arcade/` |
| `konamigv.zip` (BIOS `999a01.7e`, CRC ad498d2d) | MAME 0.289 set | `/media/fat/games/mame/` |
| `simpbowl.zip` (`simpbowl.25c`, CRC 2c61050c) | MAME set | `/media/fat/games/mame/` |
| `829uaa02.chd` (SHA1 2ec4cc60…) | MAME set, unchanged | `/media/fat/games/simpbowl/` |

No flash dump is needed: MAME's set has none, and neither does the real machine's disc-based setup.

## First run: installing the game into flash

The flash starts blank. A normal boot shows `25C: OK  3A/3B/7A/7B: BAD  SEE MANUAL` (MAME does the
same). The game installs itself from the disc when it boots with TEST held:

1. Start the MRA, open the OSD, set **Test Switch: On**, then **Mount GV Disc** → `829uaa02.chd`.
2. The board boots from the disc: `EEPROM INITIALIZED`, `FLASH-ROM CHECK: OK`, `NOW WRITING` with a
   progress bar. As soon as `NOW WRITING` appears, set **Test Switch: Off** (the switch is only read at
   boot; in MAME it was released 20 s before writing started). Leave it running (MAME: ~16 s erase,
   then ~1-2 min writing).
3. When the bar is full the game reboots; the check screen shows all `OK` and the game starts.
4. Open the OSD once: MiSTer saves EEPROM + flash to `/media/fat/config/nvram/The Simpsons Bowling
   (GQ829 UAA).nvm` (8,388,736 bytes). Later launches load it and boot straight into the game.

Already installed the game in MAME? `tools/make_simpbowl_nvm.py <mame>/nvram/simpbowl out.nvm` builds
the same `.nvm` from MAME's `eeprom` + `flash0..3`.

## Controls

| Input | Source |
|---|---|
| Trackball | USB trackball or USB mouse (MiSTer mouse input), and/or the left analog stick (rate control, ~2000 counts/s at full deflection; OSD can turn it off) |
| Buttons / Start / Coin / Service / Test | MiSTer pad as for the other GV games |

OSD page **Trackball (Simpsons Bowling)**: speed 1x/2x/4x/1/2, invert X, invert Y, analog stick on/off.
The default direction is MAME's (TRACK0_X reversed, Y counting downwards).

## Hardware model (`rtl/gv/gv_simpbowl.vhd`)

* Glue (`konamigv.cpp` flash_r/flash_w): FA registers at 0x82/0x84/0x86, data port 0x80 (read returns
  both chips of the pair selected by FA ≥ 0x200000 and increments FA; write sends one byte to each),
  read of 0x88 sets FA bit 0. Each 16-bit handler call is reproduced once per CPU access on the
  byte-stepped EXP1 bus.
* Chips (`intelfsh.cpp`, 8-bit Fujitsu, maker 04h / device ADh): reset, autoselect (AA/55/90), byte
  program (A0), chip erase (80/AA/55/10) and sector erase (…/30), Intel-style 10/40/20/D0/50/60/70
  paths, fast mode, status toggling DQ6|DQ2 on every read while erasing (all addresses, the Fujitsu
  ADh rule), erase timers 16 s (chip) / 1 s (sector/block) as in MAME.
* Array: 8 MB in DDR3 (arbiter port memFlash, DDR3 offset 0x1000000 of the core window); CPU reads
  that need array data wait on `bus_exp1_wait` (~0.5-1 µs), the next word is prefetched.
* uPD4701A: 12-bit X/Y counters, read_xy at 0xC1/0xC3/0xC5/0xC7 (umask 0xFF00FF00), reset_xy_r at 0xC9.
* Enabled only by the MRA board config byte (`<rom index="4"><part>01</part></rom>`); base-board games
  never see the module.

## Verification

* `tb_gv_simpbowl`: replay of 5,500,000 MAME flash-port accesses from power-on with TEST held
  (autoselect, chip erase of both pairs, 16 s status polling, blank check, 46,548 program/verify
  sequences) - 9,228,346 read bytes identical to MAME.
* `tb_gv_memmux`: CPU → real memorymux → gv_simpbowl on both EXP1 bus configurations: wait handshake,
  FA side effects once per access (16/32-bit), autoselect, program/read-back, trackball counters/reset.
* MAME observations used: blank flash → BAD/SEE MANUAL; TEST held → install → all OK → attract.
