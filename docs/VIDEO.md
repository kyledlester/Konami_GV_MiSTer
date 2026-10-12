# Video

The GV video path is the PlayStation's: the GPU (ZV610: CXD8514Q, GV999: CXD8561Q) scans VRAM out with
NTSC timing derived from the 53.693175 MHz video clock. The core keeps PSX_MiSTer's mature path
unchanged: `gpu_videoout` → `video_freak` (aspect / integer scaling) → `video_mixer`/gamma → MiSTer
scaler (HDMI) and analog output.

## Susume's modes (MAME trace)

| Time | GP1 08h display mode | Notes |
|---|---|---|
| 0.34–0.45 s | 256×240 | BIOS logo/init |
| from 0.45 s | 08000001: 320×240, NTSC, 15 bpp, progressive | everything else; H range 06C60260, V range 0703F00C (lines 12–252) in game |

Display start alternates 0/240 (double buffering). Nothing interlaced or 24 bpp was observed, but the
core supports every PSX mode, so other GV titles need no special handling.

## GPU revision

OSD *Hardware → GPU*: **CXD8514Q (ZV610)** (default, what MAME's `konamigv` instantiates and what
Susume's board has) or CXD8561Q (GV999 boards: Simpsons Bowling, Dead Eye …). This drives PSX_MiSTer's
existing `oldGPU` texture-blend behaviour.

## Outputs

* HDMI: MiSTer scaler; OSD aspect/scale/crop/deinterlace options as in PSX_MiSTer. CRT Adjust does not
  move the HDMI picture (the scaler frames by DE, which is untouched).
* Analog: native 15.7 kHz 240p (no scandoubler unless forced by `forced_scandoubler`/video settings),
  see `CRT.md`. Direct Video carries the same native stream over HDMI.

Game timing is never altered for HDMI; there is no frame-rate or blanking hack in the GV build.
