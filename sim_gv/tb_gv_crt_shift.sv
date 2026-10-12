`timescale 1ns/1ps
module tb_crt;
  reg clk=0; always #5 clk=~clk;
  reg ce=0; reg [1:0] cd=0; always @(posedge clk) begin cd<=cd+1; ce<=(cd==0); end
  reg [9:0] hc=0, vc=0;
  wire hs = (hc>=350 && hc<380);
  wire vs = (vc>=240 && vc<243);
  always @(posedge clk) if (ce) begin
    if (hc==399) begin hc<=0; vc <= (vc==261)?0:vc+1; end else hc<=hc+1;
  end
  reg en=0; reg [3:0] hp=0, vp=0;
  wire hso, vso;
  gv_crt_shift dut(.clk(clk),.ce_pix(ce),.enable(en),.hpos(hp),.vpos(vp),.hs_in(hs),.vs_in(vs),.hs_out(hso),.vs_out(vso));
  integer hstart, vstart, errs=0; reg hso_d, vso_d;
  task measure(output integer hst, output integer vst);
    integer frames; begin
      frames=0; hst=-1; vst=-1;
      while (frames<4) begin
        @(posedge clk); if (ce) begin 
          if (hso & ~hso_d) hst = hc;
          if (vso & ~vso_d) begin vst = vc; frames=frames+1; end
          hso_d=hso; vso_d=vso;
        end
      end
    end endtask
  initial begin #100000000 $display("TIMEOUT hs=%0d vs=%0d", hstart, vstart); $finish; end
  initial begin
    hso_d=0; vso_d=0;
    en=0; measure(hstart,vstart); $display("off: hs@%0d vs@%0d", hstart, vstart); if (hstart!=350 || vstart!=240) errs=errs+1;
    en=1; hp=0; vp=0; measure(hstart,vstart); $display("on 0/0: hs@%0d vs@%0d", hstart, vstart); if (hstart<349 || hstart>351 || vstart<239 || vstart>241) errs=errs+1;
    hp=4'd2; vp=4'd3; measure(hstart,vstart); $display("on +2/+3: hs@%0d (exp ~342) vs@%0d (exp ~237)", hstart, vstart); if (hstart<341||hstart>343||vstart<236||vstart>238) errs=errs+1;
    hp=4'hE; vp=4'hD; measure(hstart,vstart); $display("on -2/-3: hs@%0d (exp ~358) vs@%0d (exp ~243)", hstart, vstart); if (hstart<357||hstart>359||vstart<242||vstart>244) errs=errs+1;
    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL %0d", errs);
    $finish;
  end
endmodule
