#!/usr/bin/env python3
"""Build the KonamiGV core's Simpsons Bowling save file from a MAME nvram directory.

MAME (after the game has installed itself into flash) leaves in nvram/simpbowl/:
    eeprom          128 bytes, 16-bit words little-endian (byte-swapped relative to simpbowl.25c)
    flash0..flash3  2 MB each, the four 29F016A chips (pair 0 = flash0/flash1, pair 1 = flash2/flash3)

The core's nvram (MRA <nvram index="3" size="8388736"/>) is
    bytes 0..127        EEPROM in .25c order (word n = byte[2n] << 8 | byte[2n+1])
    bytes 128..         flash as 16-bit words {chip 2p+1, chip 2p}, little-endian:
                        offset 128 + 2 * (p * 0x200000 + a) + 0 = chip 2p   [a]
                        offset 128 + 2 * (p * 0x200000 + a) + 1 = chip 2p+1 [a]

usage: make_simpbowl_nvm.py <mame nvram/simpbowl dir> "The Simpsons Bowling (GQ829 UAA).nvm"
Copy the result to /media/fat/config/nvram/ on the MiSTer.
"""
import os
import sys

CHIP = 0x200000


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    ee = open(os.path.join(src, "eeprom"), "rb").read()
    if len(ee) != 128:
        sys.exit("eeprom: expected 128 bytes, got %d" % len(ee))
    chips = []
    for i in range(4):
        d = open(os.path.join(src, "flash%d" % i), "rb").read()
        if len(d) != CHIP:
            sys.exit("flash%d: expected %d bytes, got %d" % (i, CHIP, len(d)))
        chips.append(d)

    out = bytearray(128 + 4 * CHIP)
    out[0:128] = bytes(b for i in range(0, 128, 2) for b in (ee[i + 1], ee[i]))
    for p in range(2):
        base = 128 + 2 * p * CHIP
        out[base:base + 2 * CHIP:2] = chips[2 * p]
        out[base + 1:base + 2 * CHIP:2] = chips[2 * p + 1]
    open(dst, "wb").write(out)
    blank = all(c.count(0xFF) == CHIP for c in chips)
    print("wrote %s (%d bytes)%s" % (dst, len(out), "  WARNING: flash is blank (not installed)" if blank else ""))


if __name__ == "__main__":
    main()
