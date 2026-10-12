# SCSI: NCR 53CF96 + XM-5401

## Controller (`rtl/gv/gv_ncr53cf96.vhd`)

Port of MAME 0.289 `ncr53c90.cpp` as instantiated for GV (`ncr53cf96_device`: 53C90A status register
with the interrupt bit, 53C90A command validity, 53CF94 24-bit transfer counter and chip ID in TCOUNT,
busmode 0 so DRQ follows the plain 53C90 rule).

* Registers: 0/1/E transfer counter (write tcount, read tcounter), 2 FIFO (16 deep, shift on pop),
  3 command (2-entry queue, gross error on overflow, RESET/RESET BUS jump the queue), 4 status (read) /
  bus ID (write), 5 interrupt status (read clears it, clears seq, pops the next queued command) /
  timeout, 6 sequence step / sync period, 7 FIFO count / sync offset, 8 CONF1 (own ID), 9 clock
  conversion, B/C/D CONF2/3/4. CONF2 bit 3 (S2FE) selects the 24-bit counter.
* Commands: NOP, FLUSH, RESET, RESET BUS, SELECT (w/o ATN, w/ ATN, w/ ATN and stop), ENABLE/DISABLE
  SELECTION, TRANSFER INFORMATION, INITIATOR COMMAND COMPLETE, MESSAGE ACCEPTED, TRANSFER PAD, SET/RESET ATN,
  each with the DMA bit. Target-mode commands are accepted as valid but not modelled (never used on GV).
* MAME's event-driven `step()` is evaluated only when MAME would call it: a change of BSY/REQ from the
  target, a FIFO write, a DMA byte, an expired delay, or an immediate re-step. Delays scale MAME's
  16 MHz SCSI clocks to clk1x (×2). The selection timeout uses MAME's `DELAY_HACK` values.
* IRQ = interrupt status ≠ 0 (level). `gv_board` turns its rising edge into the IRQ10 pulse, which
  reproduces the extra "empty" ISR entry after the polled DISCONNECT seen in MAME.

## Target (`rtl/gv/gv_scsi_cdrom.vhd`)

Bus side ports `nscsi_full_device`: selection (bus-settle delay), MESSAGE OUT (IDENTIFY sets the LUN),
COMMAND (length by group), then the phase plan DATA IN/OUT → STATUS → MESSAGE IN (COMMAND COMPLETE) →
BUS FREE. Zero data-byte period and command delay, like MAME's XM-5401.

Command semantics port `nscsi_cdrom_device` (inquiry "TOSHIBA CD-ROM XM-5401TA 3605", data 0x98):

| CDB | Behaviour |
|---|---|
| 00 TEST UNIT READY | GOOD, or CHECK CONDITION / NOT READY 3Ah without a disc |
| 01 REZERO, 1B START/STOP, 1E PREVENT/ALLOW | GOOD |
| 03 REQUEST SENSE | min(18, alloc) bytes: F0 00 key 00…0A…ASC ASCQ; reserved fields set → ILLEGAL REQUEST 24h |
| 08 READ(6), 28 READ(10) | Mode 1 user data, block size from MODE SELECT (2048 default; 1024/512/256 supported) |
| 12 INQUIRY | page 0 only, `alloc` bytes of the 36-byte template |
| 15 MODE SELECT(6) | DATA OUT `cdb[4]` bytes; block descriptor sets block size; page 0Eh sets SOTC and CD-DA volume (ports 0/1) |
| 1A MODE SENSE(6) | header + optional block descriptor + pages 31h,30h,0Eh,02h,01h,00h in MAME's order |
| 1C/1D DIAGNOSTIC | MAME's 7/8-byte "all OK" replies, self-test GOOD |
| 25 READ CAPACITY | lead-out − 1, block size |
| 42 READ SUB-CHANNEL | audio status 11/12/13/15h; Q current position with MAME's quirks (index 0, MSF without +150) |
| 43 READ TOC | formats 0 and 1, LBA or MSF (+150), lead-out uses the last track's ADR/control |
| 48 PLAY AUDIO TRACK/INDEX | plays start track … min(end, last) (or start only with SOTC); index ignored like MAME |
| 4B PAUSE/RESUME | pause = !cdb[8].0 |
| 51 READ DISC INFORMATION | 34-byte MAME reply |
| other | CHECK CONDITION, ILLEGAL REQUEST |

Response bytes are built into a 1 KB RAM (SBUF_MAIN); sense bytes are generated on the fly; sector data
comes from `gv_cd_media`. MSF conversion is sequential (`gv_lba2msf`) to avoid dividers.

## Verification

`sim_gv/tb_gv_replay.vhd` + `tools/gv_trace_replay.py` replay MAME's complete Susume session (13,850
register operations, 325 SCSI commands, 308 DMA transfers) and compare every register read and every
DMA payload with MAME. Result: all reads identical, all non-positional payloads CRC-identical.

```
python tools/gv_trace_replay.py --trace <traces>/logs/B_play --cue <media>/susume.cue --out <vec>
nvc --std=2008 --work=gv -a rtl/gv/*.vhd sim_gv/tb_gv_replay.vhd
nvc --std=2008 --work=gv -H 2g -e tb_gv_replay -gVEC=<vec>/ -r      # ~2.5 min, prints RESULT
```
