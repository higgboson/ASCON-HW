// ascon_if.sv - the pins of ascon_core, the clocking blocks and the protocol checks (SVA)
//
// state_clear is not a pin: top.sv ties it to "the core's state and key registers are all
// zero", so the check that secrets are wiped can live here with the others.

interface ascon_if (input bit clk);

    import uvm_pkg::*;
    `include "uvm_macros.svh"
    `include "ascon_defs.svh"

    logic         reset = 1'b1;         // known from time 0, before the driver starts
    logic         start = 1'b0;
    logic [  2:0] mode;
    logic [127:0] key, nonce, tag_in;
    logic [ 31:0] out_len;
    logic         ready;
    logic         din_valid = 1'b0, din_ready;
    logic [127:0] din_data;
    logic [  4:0] din_bytes;
    logic         din_last;
    logic         dout_valid, dout_ready = 1'b0;
    logic [127:0] dout_data;
    logic [  4:0] dout_bytes;
    logic         dout_last;
    logic         done;
    logic [127:0] tag;
    logic         tag_ok;
    logic         state_clear;

    // drive 1 ns after the edge, so every value is stable long before the DUT samples it
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output reset, start, mode, key, nonce, tag_in, out_len;
        output din_valid, din_data, din_bytes, din_last, dout_ready;
        input  ready, din_ready, dout_valid, done;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input reset, start, mode, key, nonce, tag_in, out_len, ready;
        input din_valid, din_ready, din_data, din_bytes, din_last;
        input dout_valid, dout_ready, dout_data, dout_bytes, dout_last;
        input done, tag, tag_ok;
    endclocking

    modport DRV (clocking drv_cb);
    modport MON (clocking mon_cb);

    // What the checks need to remember: the mode of the running operation and whether the
    // next input beat belongs to the message (the last stream) or to the stream before it.
    logic [2:0] cur_mode;
    logic       in_msg;

    always @(posedge clk) begin
        if (start && ready) begin
            cur_mode <= mode;
            in_msg   <= (mode == `ASCON_HASH || mode == `ASCON_XOF);
        end else if (din_valid && din_ready && din_last)
            in_msg <= 1'b1;
    end

    wire       aead_m   = (cur_mode == `ASCON_ENC || cur_mode == `ASCON_DEC);
    wire [4:0] rate     = aead_m ? 5'd16 : 5'd8;
    wire       din_beat = din_valid && din_ready;

    // bit mask of the bytes that carry data in an output beat
    function automatic logic [127:0] byte_mask(input logic [4:0] n);
        for (int i = 0; i < 16; i++)
            byte_mask[8*i +: 8] = (i < n) ? 8'hff : 8'h00;
    endfunction

    // Checks on the core. They hold for any sequence, so they run in every test.

    a_reset_idle: assert property (@(posedge clk) reset |=> ready && !dout_valid && !done)
        else `uvm_error("SVA", "not idle right after reset")

    a_done_pulse: assert property (@(posedge clk) disable iff (reset) done |=> !done)
        else `uvm_error("SVA", "done stayed high for more than one cycle")

    a_done_idle: assert property (@(posedge clk) disable iff (reset) done |-> ready)
        else `uvm_error("SVA", "done while the core is not idle")

    a_idle_no_input: assert property (@(posedge clk) disable iff (reset) ready |-> !din_ready)
        else `uvm_error("SVA", "input accepted while idle")

    // an output beat must wait, unchanged, until it is taken
    a_dout_hold: assert property (@(posedge clk) disable iff (reset)
        dout_valid && !dout_ready |=> dout_valid && $stable({dout_data, dout_bytes, dout_last}))
        else `uvm_error("SVA", "output beat changed or vanished before it was taken")

    a_dout_bytes: assert property (@(posedge clk) disable iff (reset)
        dout_valid |-> dout_bytes <= 5'd16)
        else `uvm_error("SVA", "output beat with more than 16 bytes")

    // bytes past dout_bytes must be zero: they would be bits of the secret state
    a_dout_no_leak: assert property (@(posedge clk) disable iff (reset)
        dout_valid |-> (dout_data & ~byte_mask(dout_bytes)) == 128'b0)
        else `uvm_error("SVA", "output beat shows bits outside its valid bytes")

    // the result stays until the next operation starts
    a_result_hold: assert property (@(posedge clk) disable iff (reset)
        ready && !start |=> $stable({tag, tag_ok}))
        else `uvm_error("SVA", "tag / tag_ok changed while idle")

    // decrypt gives a yes / no only: showing the computed tag would let anyone forge messages
    a_dec_hides_tag: assert property (@(posedge clk) disable iff (reset)
        done && cur_mode == `ASCON_DEC |-> tag == 128'b0)
        else `uvm_error("SVA", "decrypt showed the computed tag")

    a_tag_ok_dec_only: assert property (@(posedge clk) disable iff (reset)
        done && cur_mode != `ASCON_DEC |-> !tag_ok)
        else `uvm_error("SVA", "tag_ok set by something that is not a decrypt")

    // nothing secret is left in the core between operations
    a_wiped: assert property (@(posedge clk) disable iff (reset) ready |-> state_clear)
        else `uvm_error("SVA", "state or key not cleared while idle")

    // After the last message beat of an AEAD operation nothing can hold the core up:
    // at most 8 rounds for that block, 12 final rounds and the done cycle.
`ifndef VERILATOR
    a_aead_finishes: assert property (@(posedge clk) disable iff (reset)
        din_beat && din_last && in_msg && aead_m |-> ##[1:22] done)
        else `uvm_error("SVA", "no done within 22 cycles of the last message beat")
`else
    // (no ##[m:n] in that simulator) count the cycles since the last message beat instead
    logic [5:0] fin_n;
    logic       fin_run = 1'b0;
    always @(posedge clk) begin
        if (reset || done) fin_run <= 1'b0;
        else if (din_beat && din_last && in_msg && aead_m) begin fin_run <= 1'b1; fin_n <= 0; end
        else if (fin_run) fin_n <= fin_n + 1'b1;
    end
    a_aead_finishes: assert property (@(posedge clk) disable iff (reset) fin_run |-> fin_n < 6'd21)
        else `uvm_error("SVA", "no done within 22 cycles of the last message beat")
`endif

    a_out_known: assert property (@(posedge clk) disable iff (reset)
        !$isunknown({ready, din_ready, dout_valid, done}) &&
        (!dout_valid || !$isunknown({dout_data, dout_bytes, dout_last})) &&
        (!done || !$isunknown({tag, tag_ok})))
        else `uvm_error("SVA", "X on an output")

    // Checks on the testbench: stimulus that breaks these rules would prove nothing.

    a_tb_din_hold: assert property (@(posedge clk) disable iff (reset)
        din_valid && !din_ready |=> din_valid && $stable({din_data, din_bytes, din_last}))
        else `uvm_error("SVA", "testbench changed an input beat before it was taken")

    a_tb_din_bytes: assert property (@(posedge clk) disable iff (reset)
        din_beat |-> din_bytes <= rate && (din_last || din_bytes == rate))
        else `uvm_error("SVA", "testbench sent a short beat that is not the last one")

    a_tb_mode: assert property (@(posedge clk) disable iff (reset)
        start && ready |-> mode <= `ASCON_CXOF)
        else `uvm_error("SVA", "testbench started a reserved mode")

    // interesting situations, reported in the assertion coverage
    c_start_while_busy:    cover property (@(posedge clk) start && !ready);
    c_back_to_back:        cover property (@(posedge clk) done ##1 (start && ready));
    c_start_out_pending:   cover property (@(posedge clk) start && ready && dout_valid);
    c_out_stall:           cover property (@(posedge clk) dout_valid && !dout_ready);
    c_in_wait:             cover property (@(posedge clk) din_ready && !din_valid);
    c_empty_stream:        cover property (@(posedge clk) din_beat && din_last && din_bytes == 0);
    c_full_last_beat:      cover property (@(posedge clk) din_beat && din_last && din_bytes == rate);
    c_forgery_rejected:    cover property (@(posedge clk) done && cur_mode == `ASCON_DEC && !tag_ok);
    c_tag_accepted:        cover property (@(posedge clk) done && tag_ok);

endinterface
