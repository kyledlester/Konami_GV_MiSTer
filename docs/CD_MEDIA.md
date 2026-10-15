# CD media: original CHD (or CUE/BIN) on MiSTer

**Source of truth is the original MAME CHD.** No conversion is needed: MiSTer Main already decodes CHD
(and single/multi-file CUE+BIN) for cores named `PSX`, and this core keeps that name.

## Path

```
gv027j1.chd ─ Main support/psx/psx.cpp + support/chd/mister_chd.cpp
   ├─ TOC   : struct disk_t over ioctl index 251 (32-bit words)            → gv_cd_media TOC RAM
   │          word0 track count, word1 end LBA (+150), word3 bit18 reset request,
   │          word 4+4i: start (track 1 reported as 0), end, MSF | audio<<16
   ├─ mount : sd slot 1 size = end*2352                                      → hasCD / disc present
   └─ read  : sd_rd[1] at HPS LBA → 2352 bytes (1176 words) on sd_buff_*     → gv_cd_media
              data frames raw (sync/header/2048 data/EDC), audio frames little-endian samples
              (Main byte-swaps CHD audio, which is stored big-endian)
```

`gv_cd_media` converts HPS LBA → MAME logical LBA (−150), stores per track `{audio, start}` plus a
lead-out entry, and serves:

* **Mode 1 user data**: two 2352-byte frame buffers with tags; a miss fetches the wanted frame, then
  the next frame is read ahead while the current one streams to SCSI. Main passes CHD frames through
  unchanged and does not report the track format, so each arriving frame is classified by its 12-byte
  sync pattern and header mode byte (MAME `read_data` with datatype MODE1): raw Mode 1 (MODE1_RAW, CUE
  MODE1/2352) -> user data at byte 16; raw Mode 2 (MODE2_RAW, as in MAME's simpbowl 829uaa02) -> byte 24
  (after the XA subheader); cooked (CHD TYPE:MODE1, as in MAME's lacrazyc / powyak96 / weddingr /
  nagano98 sets) -> byte 0.
* **Audio frames** for `gv_cdda` (ack/done handshake), interleaved with data fetches
  (priority: data miss > audio > read-ahead).

Main itself caches one CHD hunk (4 frames) per request, so sequential frames are served quickly.

## Disc change / no disc

* No disc: TEST UNIT READY etc. return CHECK CONDITION / NOT READY 3Ah (MAME `return_no_cd`).
* Mounting a disc from a new folder makes Main request a reset (TOC metadata bit) → the board reboots
  with the disc present. MAME's UNIT ATTENTION after a media change is therefore never needed.

## Supported image formats

| Format | Status |
|---|---|
| CHD v5 (`chdman createcd`), as in the MAME set, data track MODE1_RAW, cooked MODE1 or MODE2_RAW | primary, direct |
| CUE + BIN (MODE1/2352 + AUDIO, single or multi file) | supported by Main |
| ISO / 2048-byte images | not supported (no audio tracks; use the CHD) |

## Pregaps the CHD does not store

Some discs have pregaps that chdman records as `PREGAP:n PGTYPE:<type>` without a leading `V`
(not stored in the CHD): kdeadeye, tmosh, hyperath and naganoj (track 2: 150 frames) and lacrazyc
(track 2: 150, tracks 3-35: 149). Main (`mister_load_chd`, `psx.cpp load_chd`) lays such discs out with
later track starts than MAME's logical numbering. The core uses Main's track starts as delivered. A remap
to MAME's numbering was built and tested on hardware: with it, Crazy Cross music started ~2 s late,
while Main's starts sound right, so it was removed.

## Rejected alternatives

* Flat 2048-byte ISO (what the Simpsons Bowling build used): loses Red Book audio and the TOC.
* Decompressing into SDRAM: unnecessary — HPS streaming is fast enough and avoids 300+ MB of memory.
* CHD inside an MRA ROM stream: impossible size-wise and not how MiSTer mounts discs.
