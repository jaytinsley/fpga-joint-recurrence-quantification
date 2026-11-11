`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// jrp_run_cell.v
//   Combinational run tracker for one cell, used for both the vertical (column) and the diagonal
//   state of the K = 2 extractor. It is the per-cell logic of the released
//   RQA_extractor_nobitmap.v (Li, Lai and Oberst 2026, Zenodo 10.5281/zenodo.20406392, MIT),
//   written as a module so the two lanes share one definition. Behaviour per cell, with
//   (opn, last, run) the stored state of the line this cell can extend:
//     - open run and i != last + 1  : the run ended earlier, it is closed (counted if run >= minlen)
//     - flag set                    : start a run (run = 1) or extend the open one
//     - flag clear, open, i == last+1: the run ends here, it is closed (counted if run >= minlen)
//   State word: {frame_id, open, last, run}. A stored frame_id other than cur_fid means "empty".
//   `im1` is i - 1, supplied by the caller so no adder sits in front of the comparison.
// -----------------------------------------------------------------------------
module jrp_run_cell #(
    parameter integer IW   = 14,
    parameter integer RUNW = 16
)(
    input  wire [IW+RUNW+1:0] st_in,
    input  wire               cur_fid,
    input  wire [IW-1:0]      i,
    input  wire [IW-1:0]      im1,
    input  wire               f,
    input  wire [RUNW-1:0]    minlen,
    output wire [IW+RUNW+1:0] st_out,
    output wire               close_v,     // a run of length close_run ended and is counted
    output wire [RUNW-1:0]    close_run
);
    localparam integer SW = IW + RUNW + 2;
    wire             fid  = st_in[SW-1];
    wire             opn  = st_in[SW-2] & (fid === cur_fid);   // === : a memory not yet written reads as empty in simulation
    wire [IW-1:0]    last = st_in[RUNW+IW-1:RUNW];
    wire [RUNW-1:0]  run  = st_in[RUNW-1:0];

    wire cont = opn & (im1 == last);         // open and i is the next cell of the line
    wire gap  = opn & ~cont;                 // open but a cell was skipped: the run ended earlier
    wire endr = opn & cont & ~f;             // open, flag clear at the next cell: the run ends here

    assign close_v   = (gap | endr) & (run >= minlen);
    assign close_run = run;

    wire [RUNW-1:0] run_n = f ? (cont ? run + {{(RUNW-1){1'b0}}, 1'b1} : {{(RUNW-1){1'b0}}, 1'b1})
                              : {RUNW{1'b0}};
    assign st_out = {cur_fid, f, f ? i : last, run_n};
endmodule
