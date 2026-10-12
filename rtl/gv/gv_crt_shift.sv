// Konami GV MiSTer core: CRT picture position for native 15 kHz analog output.
//
// Moves the picture on a CRT by re-timing HSync / VSync relative to the unchanged video
// stream.  Pixel data, blanking and DE are never touched, so emulation timing, game-visible
// blanking and the MiSTer scaler (which frames the picture by DE) are unaffected; only the
// sync pulses the monitor locks to move.
//
//   enable : 0 = exact combinational passthrough
//   hpos   : signed steps of 4 pixels, + moves the picture right (HSync earlier)
//   vpos   : signed lines, + moves the picture down (VSync earlier)
//
// Line length, frame length and pulse widths are measured from the incoming syncs, so every
// PSX/GV display mode (256..640 wide, 240p/480i) is handled without configuration.  The
// shifted pulses are windows [start, start + width) taken modulo the measured period.
//
// GPL-2.0 (part of Konami_GV_MiSTer).

module gv_crt_shift
(
	input        clk,
	input        ce_pix,
	input        enable,
	input  [3:0] hpos,
	input  [3:0] vpos,
	input        hs_in,
	input        vs_in,
	output       hs_out,
	output       vs_out
);

reg        hs_d, vs_seen;
reg [11:0] x, llen, hsw, hsw_c;
reg [9:0]  y, flen, vsw, vsw_c;
reg        hs_n, vs_n;

// start offsets (picture right/down = sync earlier)
wire [11:0] hstep  = {{6{hpos[3]}}, hpos, 2'b00};             // hpos * 4, sign extended
wire [11:0] hstart = (hstep == 0) ? 12'd0 : (llen - hstep);     // (-hpos*4) mod llen ... see below
wire [9:0]  vstep  = {{6{vpos[3]}}, vpos};
wire [9:0]  vstart = (vstep == 0) ? 10'd0 : (flen - vstep);

// modular distance from the window start; x leads by the 2-pixel pipeline (rise detect + output reg)
wire [11:0] xl  = (x + 12'd2 >= llen) ? (x + 12'd2 - llen) : (x + 12'd2);
wire [11:0] hd  = (xl >= hstart) ? (xl - hstart) : (xl + llen - hstart);
// the VSync window is evaluated on the shifted HSync, which precedes the native line increment
// (unless H-Position is negative: then the shifted HSync follows the native one)
wire [9:0]  yl  = hpos[3] ? y : ((y + 10'd1 >= flen) ? 10'd0 : (y + 10'd1));
wire [9:0]  vd  = (yl >= vstart) ? (yl - vstart) : (yl + flen - vstart);

wire hs_rise = hs_in & ~hs_d;

always @(posedge clk) begin
	if (ce_pix) begin
		hs_d <= hs_in;

		// horizontal: pixel index since the native HSync rise
		if (hs_rise) begin
			x    <= 12'd0;
			llen <= x + 1'd1;
		end else begin
			x <= x + 1'd1;
		end
		if (hs_in) hsw_c <= hs_rise ? 12'd1 : hsw_c + 1'd1;
		else if (hs_d) hsw <= hsw_c;

		// vertical: line index since the first HSync after the native VSync rise
		if (hs_rise) begin
			if (vs_in & ~vs_seen) begin
				y    <= 10'd0;
				flen <= y + 1'd1;
				vsw_c <= 10'd1;
			end else begin
				y <= y + 1'd1;
				if (vs_in) vsw_c <= vsw_c + 1'd1;
				else if (vs_seen) vsw <= vsw_c;
			end
			vs_seen <= vs_in;
		end

		hs_n <= (hd < hsw);
		if ((hd == 0) | (llen == 0)) vs_n <= (vd < vsw);
	end
end

// hstart above implements (llen - 4*hpos) mod llen for both signs because the 12-bit
// subtraction wraps; clamp is unnecessary for the +-32 pixel range used here.

assign hs_out = enable ? hs_n : hs_in;
assign vs_out = enable ? vs_n : vs_in;

endmodule
