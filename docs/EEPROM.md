# 93C46 serial EEPROM

## Hardware model (`rtl/gv/gv_eeprom93c46.vhd`)

MAME 0.289 `eeprom_serial_93cxx_device` (16-bit organisation, 64 words, streaming disabled):

* Lines from writes to 0x1F180000 (bit0 DI, bit1 CS, bit2 CLK), applied in MAME's order DI, CS, CLK.
* DO on P1 bit 13 (active high): READY/BUSY while waiting for a start bit, the shift register MSB while
  reading, otherwise the pull-up (1).
* Start bit ignored if CLK rises in the same write as CS (MAME `m_last_cs_rising_edge_time`).
* READ: dummy 0, then the word MSB first, then 1s. WRITE / ERASE / ERAL / WRAL honour the EWEN/EWDS lock
  (locked at power-on; lock survives core resets, as on the board). WRAL ANDs like MAME.
* Busy times like MAME: write 1.75 ms, erase 1 ms, erase/write all 8 ms.

## Contents and persistence

* Byte layout = MAME's: word n = byte[2n] << 8 | byte[2n+1] (`ROM_REGION16_BE`, MAME nvram file).
* MRA: `<rom index="3">` delivers `susume.25c` (CRC 52f17df7) as the default; `<nvram index="3" size="128"/>`
  makes Main store the EEPROM in `/media/fat/config/nvram/<mra name>.nvm` and send it back on later
  launches (it overrides the default). The core requests a save (`ioctl_upload_req`) whenever the game
  changes the EEPROM; Main uploads it the next time the OSD opens.
* The core is held in reset while the EEPROM downloads, so the BIOS always sees the final contents.
* MAME's nvram file (`nvram/<set>/eeprom`) stores each 16-bit word little-endian, i.e. byte-swapped
  relative to the `.25c` ROM image and the `.nvm` (verified: MAME's file after a fresh `lacrazyc` boot
  is exactly the byte-swapped `lacrazyc.25c`). Swap byte pairs before using one as a `.nvm`.

## Susume behaviour

MAME trace: 49 READ transactions (addresses 0Ah–1Dh, 02h–1Dh, 00h) at boot, no writes during boot,
attract, coin-up or gameplay. Values read equal `susume.25c` (w0 C12F, w2 9527, w3 414A, w4 0041 …).
A wrong or blank EEPROM gives the board's `25C MBAD` error.

## Verification

`tb_gv_replay` with the EEPROM vectors (MAME's bit-bang sequence + `susume.25c`): 5684/5684 DO reads
identical to MAME.
