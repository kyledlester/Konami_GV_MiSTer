# Known issues and open questions

## Tested on real hardware

* All seven base-board games boot from their original MAME CHDs and play with music and sound effects:
  Susume! Taisen Puzzle-Dama, Let's Attack Crazy Cross, Hyper Athlete, Hyper Olympic in Nagano,
  Nagano Winter Olympics '98, Jikkyou Powerful Pro Yakyuu '96, Wedding Rhapsody.
* The Simpsons Bowling installs itself into flash from its disc, boots from the saved flash afterwards,
  and plays with the analog stick as the trackball.
* Beat the Champ initialises its blank flash on the first boot and plays with a mouse as the trackball.
* Dead Eye plays with a GunCon 2 on a CRT, including off-screen reload (Gun Flash for dark scenes).
* Tokimeki Memorial Oshiete Your Heart and its three Seal versions play through with the simulated
  heart-rate and GSR sensors.
* HDMI and native 15 kHz analog output (component and RGB) on three MiSTer setups.

A game that shows HARDWARE ERROR or PROGRAM LOADING / FILE ERROR right after the BIOS checks almost
always has no disc mounted: mount the CHD with OSD → Mount GV Disc.

## Behavioural differences from MAME (intentional or harmless)
* SCSI/DMA throughput is ~1.7 MB/s plus HPS frame latency instead of MAME's instantaneous transfers
  (the real 4× drive is ~0.6 MB/s). Software is interrupt driven; only load times differ.
* READ SUB-CHANNEL positions advance in real time (MAME: emulated time) — identical semantics.
* If a DMA ch5 block count exceeds the SCSI data phase, the remaining words are written with stale data
  so the PSX engine cannot hang (MAME leaves RAM untouched). Susume never does this.
* MB89371: mode/baud registers are kept, data/status read as 00/05 (TxRDY|TxEMPTY); no serial traffic
  is modelled. Susume only initialises it.
* 0x1F680010 writes (Susume writes a value per music change; unmapped in MAME) are ignored.
* EEPROMOUT bit 3 (coin counter) is decoded but not used; bits 5/7 are ignored like MAME.
* MAME quirks kept on purpose: READ SUB-CHANNEL index 0 and MSF without +150; MODE SENSE page 3Fh
  includes MAME's Apple/BlueSCSI pages; SCSI select timeout uses MAME's `DELAY_HACK`.

## Core naming
* The core must keep the CONF_STR name `PSX` to get MiSTer Main's CHD support. Main therefore treats it
  as a PSX core: it may load a `cd_bios.rom` found next to the disc (harmless: the GV BIOS slot is
  pinned) and region detection is skipped. PSX memory-card automount is forced off.

## Not in this build
* Tokimeki Memorial: the printed card or sticker sheet is not shown (MAME draws it on a second
  screen).
* Unused PlayStation parts (MDEC, memory cards, controller devices, cheat engine, savestates) stay in
  the build but are disabled. None of the supported games touches MDEC (checked in MAME).

## Timing closure
* The design uses 98 % of the ALMs (all 112 DSP blocks are taken by the PSX), and the HDMI-clock domain
  (MiSTer `ascal` scaler, 148.5 MHz) is placement-sensitive: with identical RTL, different seeds range
  from clean to about -1 ns. Releases use only clean builds (setup and
  hold >= 0 on every clock); after RTL changes, run a few seeds in parallel and keep a clean one.
* Already applied: MISTER_DISABLE_ADAPTIVE, no MISTER_FB, all-path/multi-corner hold optimization,
  placement effort 2.0. Next levers if needed: shrink the NCR/target logic, trim more PSX-only blocks.

## Tooling
* Quartus 17.0.0 (not 17.0.2) is what is installed locally; builds are clean with it.
* `PSX.qsf` is touched by Quartus (LAST_QUARTUS_VERSION); revert before committing.
