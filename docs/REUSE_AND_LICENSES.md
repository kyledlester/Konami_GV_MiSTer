# Reuse, provenance and licenses

This repository is GPL-2.0 (see `LICENSE`), like the projects it is built from.

## Lineage

```
MiSTer-devel/PSX_MiSTer  (Robert Peip / FPGAzumSpass and contributors, GPL-2.0)
   │  fork point d8209d3 (2026-06-11, "Merge pull request #360 from Kuba-J/main")
   ▼
t-dollaz/KonamiGV_MiSTer (GPL-2.0)  @ 2b64163 (2026-07-03)  — Simpsons Bowling GV bring-up
   │  imported with full history into the development repository (not part of this public tree)
   ▼
kyledlester/Konami_GV_MiSTer (this repo) — normal GV board + Simpsons Bowling daughtercard
```

Upstream sources: https://github.com/MiSTer-devel/PSX_MiSTer and https://github.com/t-dollaz/KonamiGV_MiSTer.
Their full commit history (with original authors) is kept in the development repository; this public tree
starts from a clean snapshot.

## What is reused unchanged or nearly unchanged

| Component | Origin | Notes |
|---|---|---|
| R3000A CPU, GTE, GPU, SPU, DMA, IRQ, timers, MDEC, memory system, video output | PSX_MiSTer | untouched except as listed below |
| CPU icache-redirect / BIOS-uncached fixes | t-dollaz (adopted from fabricore System573 work) | kept |
| EXP1 bus integration in memorymux (8-bit byte-stepped, width forced) | t-dollaz | kept; hardware-proven |
| DMA ch5 request/read-stall hook | t-dollaz | kept, extended with a RAM→device path |
| IRQ10 path into irq.vhd | t-dollaz | kept |
| MiSTer framework `sys/` | MiSTer-devel | untouched |
| CD image backend (CUE/CHD parsing, TOC, raw frame delivery) | MiSTer Main (`support/psx/psx.cpp`, `support/chd/mister_chd.cpp`) | used as-is via the core name `PSX` and OSD slot S1 |

## What is new in this repo (rtl/gv, tools, sim_gv)

`gv_ncr53cf96`, `gv_scsi_cdrom`, `gv_cd_media`, `gv_cdda`, `gv_eeprom93c46`, `gv_board`,
`gv_lba2msf`, `gv_crt_shift`, `gv_crt_hsize`, `gv_simpbowl`, `tools/gv_trace_replay.py`, `tools/make_simpbowl_nvm.py`,
the `tb_gv_*` benches, the GV integration in
`psx_top.vhd`, `dma.vhd`, `psx_mister.vhd`, `PSX.sv`, the MRAs. Behaviour is derived from MAME
(BSD-3-Clause, used as a specification only — no MAME code is copied into the RTL).

## Removed from the build (kept in history)

`rtl/konami573.vhd` (t-dollaz's DuckStation-SB-style model: fake SCSI register FSM, Simpsons flash
window, trackball, 128-byte EEPROM window) and the DDR3 flash FSM in `psx_top`. They model Simpsons
Bowling expansion hardware and Arcade1Up-specific semantics, not the base GV board; see
`docs/ARCHITECTURE.md` for how such expansions should return as optional modules.

## Considered and not imported

* `crt_adjust.sv` (MiSTer-CRT-Adjust by rmonic79, used in the owner's other cores) is
  **GPL-3.0-or-later**. The PSX_MiSTer sources do not carry an "or any later version" grant, so mixing
  it into this GPL-2.0 core could not be distributed cleanly. `rtl/gv/gv_crt_shift.sv` is an
  independent, simpler implementation (sync re-timing; same OSD conventions).
* Arcade1Up `duckstation-sb` `konami.cpp`: used by t-dollaz as a behavioural reference for Simpsons
  Bowling; not used for the base GV board because its bus semantics (size-agnostic EXP1 handlers,
  fake SCSI) differ from MAME's and from the board.

## Reference revisions

| Reference | Revision |
|---|---|
| MAME | 0.289 (tag `mame0289`), sources fetched from that tag |
| MiSTer Main_MiSTer | 738cb7a (2026-10-10) |
| PSX_MiSTer upstream main | cd17b5a (2026-08-21) — not merged; fork point d8209d3 |
| t-dollaz/KonamiGV_MiSTer | 2b64163 (2026-07-03) |

## Never distributed here

BIOS, game EEPROM images, CHD/CUE/BIN, extracted audio, MAME traces of copyrighted programs, generated
test vectors (`simwork/`, `media_work/`, `traces/` live outside the repository).
