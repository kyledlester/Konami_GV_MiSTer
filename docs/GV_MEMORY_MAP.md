# Konami GV memory map (base board, ZV610 / GV999)

PlayStation memory map (RAM, BIOS at 0x1FC00000, I/O at 0x1F801000…) is unchanged and handled by
the PSX_MiSTer core. The GV board adds devices on EXP1 (0x1F000000–0x1F7FFFFF), decoded by the
board at fixed addresses (the BIOS programs EXP1_BASE to 0x1F080000, which the core ignores, as the
board does).

| Address | Device | MAME map | Width / lanes | Core |
|---|---|---|---|---|
| 0x1F000000–1F | NCR 53CF96 | `.m(ncr).umask16(0x00ff)` | register n at byte 2n (even bytes); odd bytes unconnected (read 0) | `gv_ncr53cf96` |
| 0x1F100000–03 | P1 | `portr("P1")` | 32-bit port, any byte lane | `gv_board` |
| 0x1F100004–07 | P2 | `portr("P2")` | 32-bit | `gv_board` |
| 0x1F100008–0B | P3_P4 | `portr("P3_P4")` | 32-bit | `gv_board` |
| 0x1F180000–03 | EEPROMOUT | `portw` | byte lane 0: bit0 DI, bit1 CS, bit2 CLK (bit3 coin counter, bits 5/7 unknown) | `gv_eeprom93c46` |
| 0x1F680000–07 | MB89371 ch0 | `umask32(0x00ff00ff)` | regs 0..3 at bytes 0,2,4,6: data, status/control, baud, mode | `gv_board` (registers) |
| 0x1F680008–0F | MB89371 ch1 | idem | bytes 8,A,C,E | `gv_board` |
| 0x1F780000–03 | watchdog | `nopw` | write ignored | `gv_board` |
| anything else | unmapped | — | reads 0, writes ignored | `gv_board` |

Expansion titles add (not part of the base board, not instantiated in this build):
Simpsons Bowling flash 0x1F680080–8F + µPD4701 0x1F6800C0–C9 (`gv_simpbowl`, docs/SIMPBOWL.md); Beat the Champ / Dead Eye 28F400 flash at
0x1F380000 and trackball/gun ports at 0x1F680080–C3; Tokimeki serial/printer at 0x1F680080/90.

## Input ports (MAME `INPUT_PORTS_START(konamigv)`, active low unless noted)

| Bit | P1 | P2 | P3_P4 |
|---|---|---|---|
| 0 | P1 Left | P2 Left | P3 Left |
| 1 | P1 Right | P2 Right | P3 Right |
| 2 | P1 Up | P2 Up | P3 Up |
| 3 | P1 Down | P2 Down | P3 Down |
| 4–6 | P1 Button 1–3 | P2 Button 1–3 | P3 Button 1–3 |
| 7 | — | — | Start 3 |
| 8 | — | — | P4 Left |
| 9 | Start 1 | Start 2 | P4 Right |
| 10 | Coin 1 | Coin 2 | P4 Up |
| 11 | Service 1 | — | P4 Down |
| 12 | Test (service switch, momentary) | — | P4 Button 1 |
| 13 | **93C46 DO (active high)** | — | P4 Button 2 |
| 14 | — | — | P4 Button 3 |
| 15 | — | — | Start 4 |
| 16–31 | 1 | 1 | 1 |

MiSTer mapping (`PSX.sv`): each player's joystick → that player's bits; MiSTer buttons
`Button 1, Button 2, Button 3, Start, Coin, Service, Test` (default pad: A, B, X, Start, Select, R, L).
Coin 2 is player 2's Coin; Service and Test come from player 1 (plus the OSD "Test Switch").

## Interrupts and DMA

* IRQ10 (I_STAT bit 10) ← rising edge of the NCR interrupt line.
* DMA channel 5 ↔ NCR DMA port; 4 bytes per 32-bit word, little-endian, both directions.
