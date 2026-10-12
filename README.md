# Konami GV for MiSTer

A MiSTer FPGA core for Konami's **GV** arcade board ("Baby Phoenix", 1995-2000), the PlayStation-based
system behind **Susume! Taisen Puzzle-Dama / Let's Attack Crazy Cross**, **Hyper Athlete**,
**Hyper Olympic in Nagano / Nagano Winter Olympics '98**, **Jikkyou Powerful Pro Yakyuu '96**,
**Wedding Rhapsody** and **The Simpsons Bowling**. One core (`KonamiGV`) runs the whole board; each game
has its own MRA, and every game boots from its **original, unconverted MAME CHD**.

I created this core because I wanted to play these games on my MiSTer FPGA. I am posting it here and open
sourcing it for everyone to enjoy and give feedback/make improvements. This core was created with the
assistance of AI tooling.

**Status: beta.** All eight supported games boot and play on real MiSTer hardware with music, CD audio
and sound effects, on HDMI and on 15 kHz CRTs. The Simpsons Bowling installs itself
from its disc and works with a trackball, mouse or analog stick.

## Quick start

1. Copy the core from [`Releases/`](Releases/) (`KonamiGV_YYYYMMDD.rbf`) to
   **`/media/fat/_Arcade/cores/`**.
2. Copy the MRA files from [`MRA/`](MRA/) to **`/media/fat/_Arcade/`**.
   For the alternative sets, copy the `_<Game>` folders from
   [`MRA/_alternatives/`](MRA/_alternatives/) to **`/media/fat/_Arcade/_alternatives/`**.
3. Put the MAME 0.289 ROM zips in **`/media/fat/games/mame/`**: the game's zip plus the GV BIOS zip
   **`konamigv.zip`** (BIOS `999a01.7e`). Each game's zip only holds its default EEPROM.
4. Put each game's **CHD** in **`/media/fat/games/<set name>/`**, unchanged from your MAME set, for
   example `/media/fat/games/susume/gv027j1.chd`. (When an MRA starts, MiSTer names the core after the
   set, and the disc browser opens that folder.)
5. Load the game from the **Arcade** menu, open the OSD, choose **Mount GV Disc** and select the CHD.
   The board resets and boots from the disc. Mount the disc every time you start a game.

ROMs, BIOS and CHDs are not included. You must supply your own. A CUE/BIN made from the same CHD also
works, but the CHD is the intended format.

## Supported games

| Game | MAME set | Year | Genre | CHD | Status |
| --- | --- | --- | --- | --- | --- |
| Susume! Taisen Puzzle-Dama (GV027 JAPAN 1.20) | `susume` | 1996 | Puzzle | `gv027j1.chd` | Full game playable |
| Hyper Athlete (GV021 JAPAN 1.00) | `hyperath` | 1996 | Sports | `gv021-j1.chd` | Full game playable |
| Jikkyou Powerful Pro Yakyuu '96 (GV017 JAPAN 1.03) | `powyak96` | 1996 | Baseball | `powyak96.chd` | Boots and plays, limited testing |
| Wedding Rhapsody (GX624 JAA) | `weddingr` | 1997 | Quiz | `weddingr.chd` | Boots and plays, limited testing |
| Hyper Olympic in Nagano (GX720 JAA) | `naganoj` | 1998 | Sports | `720jaa01.chd` | Full game playable |
| The Simpsons Bowling (GQ829 UAA) | `simpbowl` | 2000 | Bowling | `829uaa02.chd` | Full game playable (see below) |

### Alternatives

These use the same core and the same board as the main set, with a different ROM set and disc.

| Game | MAME set | Year | Parent game | CHD | Status |
| --- | --- | --- | --- | --- | --- |
| Let's Attack Crazy Cross (GV027 ASIA 1.10) | `lacrazyc` | 1996 | Susume! Taisen Puzzle-Dama | `gv027-a1.chd` | Full game playable |
| Nagano Winter Olympics '98 (GX720 EAA) | `nagano98` | 1998 | Hyper Olympic in Nagano | `nagano98.chd` | Boots and plays, limited testing |

**Not supported:** Beat the Champ and Dead Eye (MAME itself marks both as not working, so there is no
trustworthy reference to build against), and the Tokimeki Memorial Oshiete Your Heart series (it needs
the cabinet's sensors and sticker printer).

## The Simpsons Bowling: first run

The Simpsons Bowling keeps its program in 8 MB of flash on an add-on board, and MAME's set does not
include a flash dump: the game copies itself from the disc into the flash, as on the real cabinet. You
only do this once.

1. Start **The Simpsons Bowling**, open the OSD, set **Test Switch: On**, then **Mount GV Disc** →
   `829uaa02.chd`.
2. The game shows *EEPROM INITIALIZED* and *NOW WRITING*. As soon as *NOW WRITING* appears, set
   **Test Switch: Off**.
3. Wait for the erase (about 16 s) and the progress bar (1-2 minutes). The game reboots, the check screen
   shows everything *OK*, and the game starts.
4. **Open the OSD once.** MiSTer then saves the EEPROM and the installed flash to
   `/media/fat/config/nvram/` (an 8 MB `.nvm` file; it can take a few seconds). From then on the game
   boots normally: start the MRA and mount the disc, without Test.

**Trackball:** a USB trackball or USB mouse, and/or the left analog stick. The
OSD page *Trackball (Simpsons Bowling)* has speed, invert X / Y and an analog-stick on/off switch.

More detail: [docs/SIMPBOWL.md](docs/SIMPBOWL.md).

## Controls

Up to four players, each with an 8-way joystick and three buttons, wired as in MAME's driver:

| MiSTer button | Default pad button | Function |
| --- | --- | --- |
| Button 1 / 2 / 3 | A / B / X | Game buttons |
| Start | Start | Start (P1-P4) |
| Coin | Select | Coin (P1 / P2) |
| Service | R | Service credit |
| Test | L | Test switch (also in the OSD) |

Wedding Rhapsody's service menu has a *Control Type* setting: "4 Buttons" reads its four answer buttons
from the joystick directions (Up, Down, Left, Right).

## OSD

* **Mount GV Disc**: the game's CHD (or a CUE/BIN of it).
* **Test Switch**: the board's test/service switch.
* **Video & Audio**: aspect ratio, scaling, crop, deinterlacing, dithering, stereo mix, SPU channel order.
* **CRT Adjust** for the native 15 kHz analog output:
  * **CRT H-Size** (-12 to +10, about 3 % per step): resizes the picture about the centre through a line
    buffer, while the sync stays native, so the CRT never loses lock.
  * **CRT H-Position** and **CRT V-Shift**: move the picture by re-timing the sync only.
  * H-Position and V-Shift never touch the HDMI picture. H-Size also resizes the HDMI picture, so leave
    CRT Adjust **Off** if you only use HDMI.
* **Trackball (Simpsons Bowling)**: speed, invert X / Y, analog stick on/off.
* **Hardware → GPU**: CXD8514Q (ZV610, the default, as in MAME) or CXD8561Q (GV999).

## Saves

Each game's 93C46 EEPROM (operator settings, high scores) is saved to the SD card as a `.nvm` file in
`/media/fat/config/nvram/`. MiSTer writes it when you open the OSD after the game has changed it. On a
first start the MRA loads MAME's default EEPROM for the game. The Simpsons Bowling's `.nvm` also holds
its 8 MB flash.

## How the core relates to MAME

MAME 0.289's `konamigv` driver is the behavioural reference. During development every new piece of
hardware was checked against MAME in simulation:

* **SCSI CD-ROM**: complete MAME SCSI sessions (Susume, and The Simpsons Bowling's boot from its Mode 2
  disc) replayed into the core's NCR 53CF96 controller and CD drive: every register read and every sector
  transferred into RAM identical to MAME.
* **CD audio**: Red Book playback bit-identical to the disc.
* **EEPROM**: MAME's 93C46 bit-banging replayed with identical results.
* **Simpsons Bowling flash**: 5.5 million flash accesses from MAME (chip ID, erases, the blank check,
  46,548 program-and-verify sequences) replayed with every byte read back identical.
* **Video**: the picture is read from video memory exactly as MAME and the real GPU do.

The benches are in [`sim_gv/`](sim_gv/); the MAME tracing and replay tools are in [`tools/`](tools/).
They need your own MAME set and are not run as part of the build.

## About the hardware

Konami GV is a PlayStation (PSX) mainboard turned into an arcade board:

* Sony **R3000A** CPU with the GTE, **GPU** (CXD8514Q on ZV610 boards, CXD8561Q on GV999) and **SPU**.
* An **NCR 53CF96 SCSI** controller with a **Toshiba XM-5401** CD-ROM drive in place of the PlayStation's
  CD system; the drive's CD audio is mixed with the SPU.
* A **93C46** serial EEPROM, an **MB89371** dual UART and JAMMA inputs for up to four players.
* The Simpsons Bowling adds a daughtercard with four **Fujitsu 29F016A** flash chips (8 MB) and an
  **NEC uPD4701A** trackball counter.

## About the core

* Built on Robert Peip's [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) (CPU, GTE, GPU, SPU,
  DMA) and on [t-dollaz/KonamiGV_MiSTer](https://github.com/t-dollaz/KonamiGV_MiSTer), the first Simpsons
  Bowling bring-up. The GV board itself (SCSI controller and CD drive, CD audio, EEPROM, inputs, the
  Simpsons daughtercard) is new and follows MAME.
* **Original MAME CHDs, no conversion.** MiSTer Main's PSX CD support streams the disc. Raw Mode 1,
  cooked Mode 1 and raw Mode 2 data tracks are all handled, plus Red Book audio tracks.
* One RBF for the platform. The Simpsons Bowling hardware is switched on by a small board record in its
  MRA and is invisible to the other games.
* Native 15 kHz output for CRTs with CRT Adjust (H-Size, H-Position, V-Shift), and the MiSTer scaler for
  HDMI.
* Timing closes on every clock domain.

### Known issues

* The core keeps the internal name `PSX` (MiSTer Main's CHD support depends on it), so Main treats it as a
  PlayStation core in a few places. This is harmless; see [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md).
* A game that stops at *HARDWARE ERROR* or *PROGRAM LOADING / FILE ERROR* right after the BIOS checks
  almost always has no disc mounted; ensure you mount the CHD file via the menu after loading the core.

## Releases

Builds are in [`Releases/`](Releases/) as `KonamiGV_YYYYMMDD.rbf`. The MRAs name the core without the date
(`<rbf>KonamiGV</rbf>`), and MiSTer loads the newest dated file in `_Arcade/cores/`. You are welcome to
run your own build if you'd prefer.

## Building

Quartus Prime Lite 17.0. Open `PSX.qpf` and compile (or run `quartus_sh --flow compile PSX`), then copy
`output_files/PSX.rbf` to `Releases/KonamiGV_YYYYMMDD.rbf`. The project is named `PSX` on purpose: the
core's name must stay `PSX` for MiSTer Main's CHD support.

## Documentation

* [Architecture](docs/ARCHITECTURE.md)
* [MAME reference](docs/MAME_REFERENCE.md) and [memory map](docs/GV_MEMORY_MAP.md)
* [SCSI](docs/SCSI.md) and [CD media](docs/CD_MEDIA.md)
* [EEPROM](docs/EEPROM.md), [audio](docs/AUDIO.md), [video](docs/VIDEO.md), [CRT](docs/CRT.md)
* [The Simpsons Bowling](docs/SIMPBOWL.md)
* [Known issues](docs/KNOWN_ISSUES.md)
* [Credits and licences](docs/REUSE_AND_LICENSES.md)

## License

GPL-2.0 (see [LICENSE](LICENSE)), like PSX_MiSTer and t-dollaz/KonamiGV_MiSTer it is built on. The MiSTer
framework in `sys/` keeps its own notices. CRT H-Size is an independent GPL-2.0 implementation (the
GPL-3.0 MiSTer-CRT-Adjust module used by other cores cannot be combined with this GPL-2.0-only code base).
See [docs/REUSE_AND_LICENSES.md](docs/REUSE_AND_LICENSES.md).

No ROMs, BIOS images, EEPROM images, CHDs or other game data are included in this repository.
