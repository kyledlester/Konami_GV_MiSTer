# MAME reference

**Pinned revision: MAME 0.289 (`mame0289`).** Local executable: `mame.exe -version` → `0.289 (mame0289)`.
Specification sources (fetched from the `mame0289` tag):

| File | Used for |
|---|---|
| `src/mame/konami/konamigv.cpp` | board map, machine config, inputs, ROM sets |
| `src/devices/machine/ncr53c90.cpp/.h` | NCR 53CF96 register/command/state machine → `gv_ncr53cf96` |
| `src/devices/machine/nscsi_hle.cpp/.h`, `nscsi_bus.h` | SCSI target bus protocol → `gv_scsi_cdrom` |
| `src/devices/bus/nscsi/cd.cpp` | XM-5401 command set → `gv_scsi_cdrom` |
| `src/lib/util/cdrom.cpp/.h` | TOC / ADR-control / track lookup semantics |
| `src/devices/sound/cdda.cpp` | Red Book playback semantics → `gv_cdda` |
| `src/devices/machine/eepromser.cpp`, `eeprom.cpp` | 93C46 protocol and timing → `gv_eeprom93c46` |
| `src/devices/machine/mb89371.cpp` | MB89371 (two 8251s + BRG/mode regs) |

Do not confuse with `ksys573.cpp` (System 573: ATAPI, security carts) — a different platform.

## Machine configuration (konamigv)

* CXD8530BQ CPU @ 67.7376 MHz (PSX), 2 MB RAM; CXD8514Q GPU @ 53.693175 MHz, 1 MB VRAM; SPU @ 33.8688 MHz.
* NCR53CF96 @ 16 MHz (32 MHz / 2), SCSI ID 7; IRQ → PSX IRQ10; DRQ → DMA channel 5.
* NSCSI_XM5401 CD-ROM at SCSI ID 4; its CDDA routed to the speaker at gain 1.0 (L→L, R→R).
* SPU routed at 0.75: SPU output 1 → left, SPU output 0 → right (MAME comment: verified with btchamp's sound test).
* EEPROM_93C46_16BIT; MB89371 @ 4 MHz.

## Tracing (differential reference)

`tools/mame_trace/` holds the Lua instrumentation (`susume_trace.lua`), the launcher (`run_trace.sh`,
which isolates nvram/cfg/snapshot dirs so the user's MAME setup is untouched) and the analyser
(`analyze.py`). Reproduction (from the traces directory):

```
sh scripts/run_trace.sh A_boot 120 none nv_A2_boot
TRACE_PLAY=1 TRACE_PLAY_T=120 sh scripts/run_trace.sh B_play 195 none nv_B4_play
```

MAME runs ~7× real time headless; runs are deterministic (A is an exact prefix of B). Lua API notes for
this build: use `emu.add_machine_stop_notifier`, PC is `cpu.state["CURPC"]`, tap callbacks swallow errors.

## What Susume does (MAME 0.289, 195 s boot + attract + 1P game)

### NCR53CF96
* Byte accesses only (lane 0 even registers, lane 2 odd registers). Reads: FIFO, STATUS, ISTATUS, SEQSTEP, CONF1.
* Controller commands: NOP, RESET CHIP, RESET BUS, ENABLE SELECTION (0x44), SELECT WITH ATN (0x42),
  DMA TRANSFER INFORMATION (0x90), INITIATOR COMMAND COMPLETE (0x11), MESSAGE ACCEPTED (0x12).
  Never: non-DMA transfer, select without ATN, target mode.
* Init: NOP, RESET, NOP, CONF1 walking test 00..FF, NOP, RESET, NOP, BUSID 4, CONF2 48 (24-bit counter),
  CONF3 E7, CONF4 00, CLOCK 4, TIMEOUT 7A, SYNC 0/5, RESET BUS → IRQ (ISTATUS 80).
* Per command: 0x44, BUSID 4, FIFO ← 80 + CDB, 0x42 → IRQ (ST 9x, SS 04, IS 18); data phases always by DMA
  (TC, DMA ch5 setup, 0x90 → IRQ IS 10); 0x11 → IRQ IS 08, FIFO = status 00, message 00; 0x12 → polled
  DISCONNECT (IS 20); the DISCONNECT also latched I_STAT bit 10, so one more (empty) ISR run follows.
* CDBs: TEST UNIT READY, REQUEST SENSE(12), READ(10) (1–125 blocks), INQUIRY(32), MODE SENSE page 0E,
  READ TOC (alloc 12), MODE SELECT(28 bytes, page 0E volume), PAUSE, PLAY AUDIO TRACK/INDEX (start=end),
  READ SUB-CHANNEL (current position, 16 bytes). Every command returned GOOD.

### DMA ch5
CHCR 0x01000200 (to RAM) / 0x01000201 (from RAM, MODE SELECT); sync mode 1, block size 1 word, block
count = bytes/4 (up to 0xFA00). Started *before* command 0x90. ch5 DMA interrupt never enabled.

### EEPROM, inputs, other devices
* 93C46: 49 READ transactions only (no write/erase/EWEN ever); all values equal `susume.25c`.
  EEPROMOUT bit 3 pulses as a coin counter; bits 5/7 are also written (unmodelled in MAME).
* P1: 16-bit reads plus 8-bit reads of 0x1F100001 (coin/start byte) → true byte-lane semantics needed.
  P2 16-bit. P3_P4 never read.
* MB89371 written once (ch0 BAUD 08, MODE 03, 8251 reset/mode/command), never read.
* 0x1F680010: 16-bit writes (sound/debug latch?), unmapped in MAME. Watchdog: byte writes, once per frame.
* No flash, trackball or other expansion access.

### Video / audio
GP1 display mode 08000001: 320×240, NTSC, 15 bpp, non-interlaced, 60 Hz. SPU never enables CD audio
input; CD-DA volume is set only through SCSI MODE SELECT page 0Eh.

### MEMCTRL
EXP1 delay/size final 0x00173F47 (16-bit, 8 MB); EXP1_BASE written as 0x1F080000 just before each NCR
init — the core decodes EXP1 at the fixed 0x1F000000–0x1F7FFFFF window, as the board does.

## Differential results against this reference

`sim_gv/tb_gv_replay.vhd` replays the full B_play trace into `gv_board`:
6950/6950 register reads identical, 80/80 non-positional DMA payloads CRC32-identical (every READ(10),
INQUIRY, REQUEST SENSE, MODE SENSE, READ TOC). READ SUB-CHANNEL payloads differ only in the play position
(real-time CD-DA). The EEPROM bit-bang replay gives 5684/5684 identical DO reads.
