# Native 15 kHz output and CRT Adjust

The analog output carries the GPU's native NTSC raster (Susume: 320×240 progressive, ~15.7 kHz, 60 Hz),
exactly like the arcade board's RGB output.

## CRT Adjust (OSD → CRT Adjust)

| Option | Values | Effect |
|---|---|---|
| CRT Adjust | Off (default) / On | Off = sync and pixels pass through untouched (combinational, zero latency) |
| CRT H-Size | −12 … +10 | picture width × (32 + n) / 32 (≈3 % per step), about the centre; 0 = untouched |
| CRT H-Position | −32 … +28 pixels, steps of 4 | + moves the picture right |
| CRT V-Shift | −8 … +7 lines | + moves the picture down |

Same menu style as the owner's other arcade cores (NA-1/NB-1). Implementation `rtl/gv/gv_crt_shift.sv`
re-times **only HSync and VSync**: it measures line length, frame length and pulse widths from the incoming
syncs and regenerates each pulse at a shifted position (modulo the period). Pixel data, HBlank/VBlank, DE,
the GPU, CPU, DMA and every game-visible signal are untouched, so:

* game speed and game-visible vblank never change;
* the HDMI scaler is unaffected (it frames by DE);
* every GPU mode (256…640 wide, 240p/480i) works without configuration.

### Loading screen on CRT

While the MRA downloads the BIOS, EEPROM, board record or the Simpsons Bowling nvram, the PSX core is held
in reset and its GPU produces no sync. During those downloads `PSX.sv` switches the video to a
free-running black 240p generator (3413 clk_vid per line, 263 lines: the PSX NTSC rates; standard NTSC
horizontal timing 4.7 / 4.7 / 52.6 / 1.5 µs), so MiSTer's loading screen is visible and stable on analog
outputs. The disc-TOC transfer at CHD mount does not switch. Same approach as the owner's ZN1 core.

### H-Size (`rtl/gv/gv_crt_hsize.sv`)

An independent GPL-2.0 implementation of the line-buffer idea used by the owner's other cores (their
GPL-3 `crt_adjust.sv` cannot be combined with this GPL-2.0-only code base, so no code was taken from it).
Each active line is written at the native pixel rate into a 2 × 1024-pixel buffer and read back during the
next line with a pixel period scaled by (32 + n) / 32 about the centre of the active area. HSync, VSync,
blanking and DE stay native, so the CRT never loses lock and game-visible timing is unchanged. The read
position is an exact integer accumulator restarted every line: every line uses the same pixel pattern (no
shimmer, no blending). Enlarging cuts the edges at the native blanking; shrinking adds black borders.
The pixel period and active width are measured from ce_pix / HBlank, so every GPU width works.

While H-Size ≠ 0 the picture is one line late; VSync is moved one line later to keep it in place.
H-Size changes the RGB that also feeds the HDMI scaler: keep CRT Adjust Off for an untouched HDMI image.

Verification (ModelSim): `sim_gv/tb_gv_crt_shift.sv`: Off = exact passthrough; On at 0/0 = identical
pulse positions; ±H/±V offsets land exactly where requested. `sim_gv/tb_gv_crt_hsize.sv`: every output
clock of the active area equals the expected source pixel (previous line, black outside) for H-Size
0 / +4 / +10 / −6 / −12 at 320 wide, +3 / −12 at 640 wide and +7 at 256 wide; Off and 0 are exact
passthrough (92,124 clocks, 0 mismatches).
