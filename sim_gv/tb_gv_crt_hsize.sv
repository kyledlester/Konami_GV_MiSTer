// gv_crt_hsize: every output clock of the active area is checked against the source pixel it must
// show (previous line, src = floor((c*32 + Wc*k/2) / ((32+k)*D)), black outside the line), for
// H-Size 0 (exact passthrough) and several sizes, in 320-wide (D=8) and 640-wide (D=4) timing.
`timescale 1ns/1ps
module tb_gv_crt_hsize;
	reg clk = 0;
	always #9.31 clk = ~clk;

	reg        ce = 0, hb = 1, en = 0;
	reg  signed [4:0] k = 0;
	reg  [7:0] r, g, b;
	wire [7:0] ro, go, bo;
	wire       act;
	integer    errs = 0, checks = 0;

	gv_crt_hsize dut(.clk(clk), .ce_pix(ce), .enable(en), .hsize(k), .hb(hb),
	                 .r_in(r), .g_in(g), .b_in(b), .r_out(ro), .g_out(go), .b_out(bo), .active(act));

	// one video line: active W pixels of D clocks each, then a blanking of B pixels.
	// Pixel x of line y carries r = x[7:0], g = {y[3:0], x[11:8]}, b = 8'hA5.
	task automatic line(input integer y, input integer W, input integer D, input integer B,
	                    input integer chk, input integer ky);
		integer c, x, src, Wc, a, num, den, er, eg, eb;
		begin
			Wc = W * D;
			a  = 32 + ky;
			for (c = 0; c < (W + B) * D; c = c + 1) begin
				x  = c / D;
				@(negedge clk);
				ce = (c % D) == 0;
				hb = (x >= W);
				r  = x[7:0];
				g  = {y[3:0], 4'(x >> 8)};
				b  = 8'hA5;
				@(posedge clk);
				#1;
				// output lags the input by 1 clock inside the active area
				if (chk && c >= 1 && c < Wc) begin
					if (!en || ky == 0) begin
						er = r; eg = g; eb = b;          // passthrough: same clock
					end else begin
						num = (c - 1) * 32 + (Wc * ky) / 2;
						den = a * D;
						src = (num >= 0) ? num / den : -((-num + den - 1) / den);
						if (src >= 0 && src < W) begin
							er = src & 8'hFF; eg = {4'(y - 1), 4'(src >> 8)}; eb = 8'hA5;
						end else begin
							er = 0; eg = 0; eb = 0;
						end
					end
					checks = checks + 1;
					if (ro !== er[7:0] || go !== eg[7:0] || bo !== eb[7:0]) begin
						errs = errs + 1;
						if (errs <= 10)
							$display("  MISMATCH k=%0d D=%0d line %0d clk %0d: got %02x %02x %02x exp %02x %02x %02x",
							         ky, D, y, c, ro, go, bo, er[7:0], eg[7:0], eb[7:0]);
					end
				end
			end
		end
	endtask

	task automatic run(input integer W, input integer D, input integer B, input integer kk, input integer enab);
		integer y, e0, c0;
		begin
			e0 = errs; c0 = checks;
			en = enab; k = kk;
			for (y = 0; y < 6; y = y + 1) line(y, W, D, B, (y >= 2), kk);
			$display("W=%0d D=%0d H-Size %0d enable %0d: %0d clocks checked, %0d mismatches",
			         W, D, kk, enab, checks - c0, errs - e0);
		end
	endtask

	initial begin
		run(320, 8, 106, 0, 1);
		run(320, 8, 106, 5, 0);
		run(320, 8, 106, 4, 1);
		run(320, 8, 106, 10, 1);
		run(320, 8, 106, -6, 1);
		run(320, 8, 106, -12, 1);
		run(640, 4, 212, 3, 1);
		run(640, 4, 212, -12, 1);
		run(256, 10, 85, 7, 1);
		if (errs == 0) $display("RESULT: PASS (%0d clocks)", checks);
		else           $display("RESULT: FAIL (%0d mismatches)", errs);
		$finish;
	end
endmodule
