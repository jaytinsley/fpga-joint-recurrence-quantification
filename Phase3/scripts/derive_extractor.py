"""Derive rtl/jrp_rqa_extractor.v (and the AXI wrapper) from the released RQA extractor.

The histogram update path changes, and the two state RAMs use jrp_tdp_bram_fw: the released 4-state read-modify-write FSMs with 2-entry
queues are replaced by a pipelined update that accepts one DET and one LAM event per cycle with
forwarding. Everything else (run trackers, counters, finalisation sweeps, AXI-Lite map) is the
released code. Every replaced block is asserted by line number and content, so the script fails
loudly if the released source ever differs.
Usage: python derive_extractor.py
"""
from pathlib import Path

P3 = Path(__file__).resolve().parents[1]
REL = P3 / "released" / "rtl"
OUT = P3 / "rtl"

src = (REL / "RQA_extractor_nobitmap.v").read_text(encoding="utf8", errors="replace").split("\n")


def block(a, b):  # 1-based inclusive
    return src[a - 1:b]


def expect(line_no, startswith):
    got = src[line_no - 1].strip()
    assert got.startswith(startswith), f"line {line_no}: expected {startswith!r}, found {got!r}"


# ---- check anchors in the released file ----
expect(235, "// -------------------- Histogram RMW FSMs")
expect(261, "assign hist_ready")
expect(273, "hdet_raddr_b_mux = ext_rd_det")
expect(274, "hlam_raddr_b_mux = ext_rd_lam")
expect(347, "task automatic det_enqueue")
expect(360, "endtask")
expect(364, "localparam integer ADDW")
expect(397, "endtask")
expect(399, "wire [HIST_W:0] sum_w")
expect(400, "{{(HIST_W-ADDW+1")
expect(446, "// Hist FSMs & pending")
expect(455, "lam_add_hold <=")
expect(461, "hdet_we_a<=1'b0; hlam_we_a<=1'b0;")
expect(702, "lam_waddr_a <= finalize_j_prev;")
expect(508, "det_q0_v <= 1'b0; det_q1_v")
expect(510, "det_hst_st <= HST_IDLE; lam_hst_st")
expect(825, "if (ENABLE_HIST!=0) begin")
expect(882, "end")
expect(883, "end")

new_decl = """    // -------------------- Histogram update pipeline (Phase 3 change) --------------------
    // The released design updates a histogram bin with a 4-cycle read-modify-write FSM fed by a
    // 2-entry queue. When both entries are full a new event overwrites the second one, and the
    // overflow counters are never incremented, so bursts of closing lines at one cell per cycle
    // lose histogram events silently (counters det_lines / lam_lines stay correct). Here each
    // event goes through a pipeline that accepts one DET and one LAM event per cycle:
    //   e0: event register; its bin is the BRAM read address (read latency 1)
    //   e1: BRAM data available; take the newest value for this bin (forward from the write
    //       presented this cycle, or from the previous cycle's write), add one (saturating at
    //       HIST_W bits as released), present the write
    reg                 det_e0_v, lam_e0_v, det_e1_v, lam_e1_v, det_w2_v, lam_w2_v;
    reg [AW_H-1:0]      det_e0_idx, lam_e0_idx, det_e1_idx, lam_e1_idx, det_w2_idx, lam_w2_idx;
    reg [HIST_MEMW-1:0] det_w2_data, lam_w2_data;
    reg [AW_J-1:0]      lam_raddr_d;   // address whose data the LAM state RAM returns this cycle
    wire hist_pipe_busy = det_e0_v | det_e1_v | hdet_we_a | det_w2_v |
                          lam_e0_v | lam_e1_v | hlam_we_a | lam_w2_v;
    wire hst_idle_all = !hist_pipe_busy;
    wire q_empty_all  = 1'b1;
    assign hist_ready = hst_idle_all && q_empty_all;

    function [HIST_MEMW-1:0] hist_inc;
        input [HIST_MEMW-1:0] v;
        begin
            hist_inc = (&v[HIST_W-1:0]) ? v : (v + {{(HIST_MEMW-1){1'b0}}, 1'b1});
        end
    endfunction
    wire [HIST_MEMW-1:0] det_fwd = (hdet_we_a && hdet_waddr_a == det_e1_idx) ? hdet_wdata_a :
                                   (det_w2_v  && det_w2_idx   == det_e1_idx) ? det_w2_data  : hdet_rdata_b;
    wire [HIST_MEMW-1:0] lam_fwd = (hlam_we_a && hlam_waddr_a == lam_e1_idx) ? hlam_wdata_a :
                                   (lam_w2_v  && lam_w2_idx   == lam_e1_idx) ? lam_w2_data  : hlam_rdata_b;""".split("\n")

new_det_enq = """    task automatic det_enqueue(input [AW_H-1:0] idx);
    begin
      det_e0_v   <= 1'b1;
      det_e0_idx <= idx;
    end
    endtask""".split("\n")

new_lam_enq = """    task automatic lam_enqueue(input [AW_H-1:0] idx);
    begin
      lam_e0_v   <= 1'b1;
      lam_e0_idx <= idx;
    end
    endtask""".split("\n")

new_reset = """            // Histogram update pipeline
            det_e0_v <= 1'b0; det_e1_v <= 1'b0; det_w2_v <= 1'b0;
            lam_e0_v <= 1'b0; lam_e1_v <= 1'b0; lam_w2_v <= 1'b0;
            det_e0_idx <= 0; det_e1_idx <= 0; det_w2_idx <= 0; det_w2_data <= 0;
            lam_e0_idx <= 0; lam_e1_idx <= 0; lam_w2_idx <= 0; lam_w2_data <= 0;""".split("\n")

new_frame = """                det_e0_v <= 1'b0; det_e1_v <= 1'b0; det_w2_v <= 1'b0;
                lam_e0_v <= 1'b0; lam_e1_v <= 1'b0; lam_w2_v <= 1'b0;""".split("\n")

new_pipe = """            if (ENABLE_HIST!=0) begin
                det_e1_v <= det_e0_v; det_e1_idx <= det_e0_idx;
                lam_e1_v <= lam_e0_v; lam_e1_idx <= lam_e0_idx;
                det_w2_v <= hdet_we_a; det_w2_idx <= hdet_waddr_a; det_w2_data <= hdet_wdata_a;
                lam_w2_v <= hlam_we_a; lam_w2_idx <= hlam_waddr_a; lam_w2_data <= hlam_wdata_a;
                if (det_e1_v) begin
                    hdet_we_a    <= 1'b1;
                    hdet_waddr_a <= det_e1_idx;
                    hdet_wdata_a <= hist_inc(det_fwd);
                end
                if (lam_e1_v) begin
                    hlam_we_a    <= 1'b1;
                    hlam_waddr_a <= lam_e1_idx;
                    hlam_wdata_a <= hist_inc(lam_fwd);
                end
            end""".split("\n")

out = []
i = 1
n = len(src)
repl = {
    (235, 261): new_decl,
    (347, 360): new_det_enq,
    (364, 400): [],            # ADDW, lam queue helpers, lam_enqueue (re-added below), sum_w
    (446, 455): new_reset,
    (508, 510): new_frame,
    (825, 882): new_pipe,
}
# lam_enqueue replaces 375-397 region, which lies inside (364, 400): add it where the block was
inject_after = {400: new_lam_enq}
while i <= n:
    hit = next((k for k in repl if k[0] == i), None)
    if hit:
        out += repl[hit]
        if hit[1] in inject_after:
            out += inject_after[hit[1]]
        i = hit[1] + 1
        continue
    line = src[i - 1]
    if i == 273:
        line = line.replace("hdet_raddr_b_fsm", "det_e0_idx")
    if i == 274:
        line = line.replace("hlam_raddr_b_fsm", "lam_e0_idx")
    if i == 461:
        line = line + "\n            det_e0_v <= 1'b0; lam_e0_v <= 1'b0;\n            lam_raddr_d <= lam_raddr_b;"
    if i == 702:
        # The state RAM returns data one cycle after the address register is loaded, so the entry seen
        # in this cycle belongs to the address presented in the previous cycle (lam_raddr_d), not to
        # finalize_j_prev. The released code cleared finalize_j_prev: one column too late, leaving open
        # runs in the column state memory (found on the board, see docs/phase3_results.md finding 7).
        line = line.replace("finalize_j_prev", "lam_raddr_d")
    out.append(line)
    i += 1

text = "\n".join(out)
assert text.count("tdp_bram_fw #(") == 2, "expected the two state RAM instances"
text = text.replace("tdp_bram_fw #(", "jrp_tdp_bram_fw #(")   # block-RAM mappable replacement, see rtl/jrp_tdp_bram_fw.v
text = text.replace("module RQA_extractor_nobitmap", "module jrp_rqa_extractor", 1)
header = ("// jrp_rqa_extractor.v: derived from RQA_extractor_nobitmap.v (Li, Lai and Oberst 2026, Zenodo\n"
          "// 10.5281/zenodo.20406392, MIT). Only the histogram update path differs, see the comment above\n"
          "// 'Histogram update pipeline'. Generated by scripts/derive_extractor.py; do not edit by hand.\n")
(OUT / "jrp_rqa_extractor.v").write_text(header + text, encoding="utf8")

wrap = (REL / "RQA_extractor_axi.v").read_text(encoding="utf8", errors="replace")
assert wrap.count("RQA_extractor_nobitmap #(") == 1 and wrap.count("module RQA_extractor_axi") == 1
wrap = wrap.replace("RQA_extractor_nobitmap #(", "jrp_rqa_extractor #(").replace(
    "module RQA_extractor_axi", "module jrp_rqa_extractor_axi")
wh = ("// jrp_rqa_extractor_axi.v: the released RQA_extractor_axi.v (Li, Lai and Oberst 2026, MIT) with the\n"
      "// core instance renamed to jrp_rqa_extractor. Generated by scripts/derive_extractor.py.\n")
(OUT / "jrp_rqa_extractor_axi.v").write_text(wh + wrap, encoding="utf8")
print("wrote", OUT / "jrp_rqa_extractor.v", "and", OUT / "jrp_rqa_extractor_axi.v")
