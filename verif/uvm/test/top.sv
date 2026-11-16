// top.sv - the Ascon core with its UVM testbench
//
// Rounds per cycle of the core: +define+ASCON_RPC=<1, 2 or 4> (default 1).

`ifndef ASCON_RPC
`define ASCON_RPC 1
`endif

module top;

    import uvm_pkg::*;
    import ascon_pkg::*;
    `include "uvm_macros.svh"

    bit clk = 0;
    always #5 clk = ~clk;

    ascon_if aif (clk);

    ascon_core #(.RPC(`ASCON_RPC)) dut (
        .clk(clk), .reset(aif.reset),
        .start(aif.start), .mode(aif.mode), .key(aif.key), .nonce(aif.nonce),
        .out_len(aif.out_len), .ready(aif.ready),
        .din_valid(aif.din_valid), .din_ready(aif.din_ready), .din_data(aif.din_data),
        .din_bytes(aif.din_bytes), .din_last(aif.din_last),
        .dout_valid(aif.dout_valid), .dout_ready(aif.dout_ready), .dout_data(aif.dout_data),
        .dout_bytes(aif.dout_bytes), .dout_last(aif.dout_last),
        .tag_in(aif.tag_in), .done(aif.done), .tag(aif.tag), .tag_ok(aif.tag_ok)
    );

    // the state and the key copy are internal; the a_wiped check in ascon_if needs them
    assign aif.state_clear = ~|{dut.x0, dut.x1, dut.x2, dut.x3, dut.x4, dut.k0, dut.k1};

`ifdef DUMP
    // waveforms without a GUI licence: +define+DUMP, then open waves.vcd in GTKWave
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, top);
    end
`endif

    initial begin
        uvm_config_db #(virtual ascon_if)::set(null, "*", "vif", aif);
        uvm_config_db #(int unsigned)::set(null, "*", "rpc", `ASCON_RPC);
        run_test();
    end

endmodule
