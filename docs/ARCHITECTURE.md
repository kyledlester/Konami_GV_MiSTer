# Architecture

```
 MiSTer HPS (Main_MiSTer, core name "PSX")
   ├─ MRA: BIOS → ioctl 0, EEPROM default → ioctl 3, nvram ↔ ioctl 3 (upload on OSD open)
   ├─ OSD S1 "Mount GV Disc": CHD / CUE+BIN → support/psx: TOC (ioctl 251) + 2352-byte frames (sd slot 1)
   └─ joysticks, OSD status
          │
 PSX.sv (emu)  ── GV input mapping, EEPROM ioctl port, CRT Adjust (gv_crt_shift), OSD
   └─ psx_mister → psx_top (PSX_MiSTer: CPU, GTE, GPU, SPU, DMA, IRQ, timers, MDEC, SIO…)
         ├─ memorymux: EXP1 0x1F000000–0x1F7FFFFF, byte-stepped, true byte addresses
         ├─ dma: channel 5 ↔ gv_board (to RAM and from RAM)
         ├─ irq: IRQ10 ← gv_board
         ├─ audio mix: 0.75·SPU (MAME channel order) + CD-DA, saturated
         └─ gv_board  (normal GV / ZV610 base board)
              ├─ gv_ncr53cf96     NCR 53CF96 initiator (MAME ncr53c90.cpp port)
              │      ║ internal SCSI bus (REQ/ACK, phases, OR-ed lines)
              ├─ gv_scsi_cdrom    XM-5401 target, SCSI ID 4 (MAME nscsi_hle + nscsi/cd)
              │      ├─ data:  Mode 1 user bytes by logical LBA
              │      └─ audio: PLAY/PAUSE/position → gv_cdda
              ├─ gv_cd_media      image backend: TOC RAM, 2-sector data cache + read-ahead,
              │                   HPS frame fetch arbitration (data miss > audio > read-ahead)
              ├─ gv_cdda          Red Book player, 44.1 kHz (clk1x / 768), 4 KB-word FIFO
              ├─ gv_eeprom93c46   93C46 (MAME eepromser), host port for ioctl load/save
              ├─ inputs P1/P2/P3_P4, MB89371 registers, watchdog
              └─ DMA ch5 bridge   bytes ⇄ 32-bit words (little-endian)
```

## Boundaries (debug them separately)

1. **Image backend** (`gv_cd_media`): "is frame N correct?" — HPS LBA = logical LBA + 150; Mode 1 user
   data at byte 16; audio words little-endian. Verified by `tb_gv_cdda` (bit-exact audio) and the replay
   (bit-exact READ data).
2. **SCSI device** (`gv_ncr53cf96` + `gv_scsi_cdrom`): "does software see the right registers?" —
   verified register-by-register against MAME by `tb_gv_replay`.
3. **Consumers**: DMA ch5 into RAM (`dma.vhd`), CD-DA into the mixer (`psx_top`).

## Why the core is still called "PSX"

MiSTer Main enables its CUE/CHD CD support (TOC, CHD decompression, 2352-byte frames on slot 1) only
for cores whose CONF_STR name is `PSX` (`is_psx()`). Keeping the name gives GV direct CHD support with
no Main changes. Side effects handled in `PSX.sv`: PSX memory-card automount forced off (status[63]),
PSX info popups disabled, PSX-only options (turbo, 8 MB RAM, fast boot BIOS patch, pads, multitap,
cheats, PAL) hard-wired off. When Main mounts a new disc it sets the TOC "reset" flag, so the board
reboots with the disc present (`resetFromCD` → `cdDownloadReset`).

Users must not keep a PlayStation `cd_bios.rom` in the GV disc folder or its parent: Main would load it
over the GV BIOS on mount (see README).

## Timing model

MAME's SCSI and DMA are instantaneous; this core moves real bytes through a REQ/ACK handshake
(~1.7 MB/s burst, HPS frame fetch latency on top), still faster than the real 4× XM-5401. GV software is
interrupt driven, so only load times change. CD-DA runs at exactly 44.1 kHz.

## Expansion hardware (future)

Game-specific daughter boards should be separate entities instantiated beside `gv_board` behind a
generic, selected per game (MRA config): Simpsons Bowling flash + µPD4701 (the old `konami573.vhd` and
flash FSM in git history are the starting point), Beat the Champ trackballs + 28F400, Dead Eye guns,
Tokimeki printer/sensors. None of them is needed by Susume.
