# Audio: SPU + CD-DA

On the board the SPU (CXD2922/CXD2925) and the CD-ROM drive's analog audio (connector CN8) are mixed in
the analog domain; CD audio never passes through the SPU's CD input (the trace shows SPUCNT CD-enable
and CD volume never set). MAME mixes on its speaker:

```
left  = 0.75 · SPU[1] + 1.0 · CDDA[0]
right = 0.75 · SPU[0] + 1.0 · CDDA[1]
```

(MAME routes SPU output 1 to the left speaker, noting it was verified with Beat the Champ's sound test.)

## Core

* SPU: unchanged PSX_MiSTer SPU (`spu.vhd`), its CD input tied to 0.
* CD-DA: `gv_cdda` — MAME `cdda_device` behaviour driven by the SCSI model: start(LBA, frames),
  pause/resume, natural end (ended flag → READ SUB-CHANNEL status 13h), position for sub-channel Q,
  data-track frames play as silence, per-channel volume from MODE SELECT page 0Eh (gain = vol/255,
  255 = unity). 44.1 kHz exactly (clk1x / 768); frames fetched ahead into a 4096-word FIFO.
* Mix (`psx_top.vhd`): `sat16(3/4 · SPU + CDDA)` per channel. OSD "SPU Channels": MAME (GV wiring,
  default) or swapped. The PSX "Stereo Mix" OSD option still applies afterwards.

## Susume

Music is Red Book: PLAY AUDIO TRACK/INDEX with start = end track (T6 intro, T12 title/attract,
T16 mode select, T3 in-game, T21/T22 round end/continue), PAUSE between tracks, a one-step-per-frame
MODE SELECT volume fade (AE → 02), then volume AE again before the next PLAY. Sound effects are SPU.

## Verification

`sim_gv/tb_gv_cdda.vhd`: 6 frames of track 6 played through `gv_cd_media` + `gv_cdda`; 3528/3528 samples
bit-identical to the disc, pause produces no samples, play ends with ended=1, position correct.
