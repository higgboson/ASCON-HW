// tb_kat.sv - runs every official known-answer test (KAT) of NIST SP 800-232 on the core
//
// The vectors come from kat/*.txt (the Ascon team's reference package), flattened by
// gen_vectors.py. For each AEAD vector the core is run three times:
//   encrypt          ciphertext and tag must match the file
//   decrypt          plaintext must match, tag_ok must be 1, the tag output must stay 0
//   tampered decrypt one bit of the tag, the ciphertext or the associated data is flipped:
//                    tag_ok must be 0
// Hash256, XOF128 and CXOF128 vectors are run once each.
//
// The way the data is cut into beats and the stalls on both streams change from test to
// test, so the handshakes get exercised too, not only the maths.
//
//   +VEC=<file>   vector file (default vectors.txt)
//   -GRPC=<n> / -PRPC=<n>   rounds per cycle of the core under test

`timescale 1ns/1ps

module tb_kat;

parameter RPC  = 1;
localparam MAXB = 1024;                 // longest field in the KAT files, in bytes
localparam FW   = 8 * MAXB;

reg clk = 0;
always #5 clk = ~clk;

reg          reset = 1;
reg          start = 0;
reg  [  2:0] mode = 0;
reg  [127:0] key = 0, nonce = 0, tag_in = 0;
reg  [ 31:0] out_len = 0;
wire         ready;
reg          din_valid = 0;
wire         din_ready;
reg  [127:0] din_data = 0;
reg  [  4:0] din_bytes = 0;
reg          din_last = 0;
wire         dout_valid;
reg          dout_ready = 0;
wire [127:0] dout_data;
wire [  4:0] dout_bytes;
wire         dout_last;
wire         done;
wire [127:0] tag;
wire         tag_ok;

ascon_core #(.RPC(RPC)) dut (
    .clk(clk), .reset(reset),
    .start(start), .mode(mode), .key(key), .nonce(nonce), .out_len(out_len), .ready(ready),
    .din_valid(din_valid), .din_ready(din_ready), .din_data(din_data),
    .din_bytes(din_bytes), .din_last(din_last),
    .dout_valid(dout_valid), .dout_ready(dout_ready), .dout_data(dout_data),
    .dout_bytes(dout_bytes), .dout_last(dout_last),
    .tag_in(tag_in), .done(done), .tag(tag), .tag_ok(tag_ok)
);

// one vector, as read from the file
integer       v_mode, v_adlen, v_mlen, v_outlen;
reg [127:0]   v_key, v_nonce, v_tag;
reg [FW-1:0]  v_ad, v_msg, v_out;

// byte i of a field that holds len bytes, first byte first
function [7:0] field_byte(input [FW-1:0] f, input integer len, input integer i);
    field_byte = f[8 * (len - 1 - i) +: 8];
endfunction

// key, nonce and tag are 16 bytes, first byte first in the file; the core wants byte 0 in
// bits 7:0
function [127:0] swap16(input [127:0] f);
    integer i;
    for (i = 0; i < 16; i = i + 1)
        swap16[8*i +: 8] = f[8 * (15 - i) +: 8];
endfunction

reg [7:0] ad_b  [0:MAXB+7];             // stream 1 (associated data / customization)
reg [7:0] in_b  [0:MAXB-1];             // stream 2 (message)
reg [7:0] exp_b [0:MAXB-1];             // expected output
reg [7:0] out_b [0:MAXB+15];            // what the core gave

integer   out_n;
reg       done_seen;
reg       stall = 0;                    // 1 = stall both streams at random
integer   errors = 0, ops = 0;
integer   mi, vec, flip;

// The testbench changes the core's inputs on the falling clock edge and looks at its outputs
// on the rising edge, so nothing ever changes at the moment it is sampled.

// output side: take beats, sometimes after making the core wait
always @(posedge clk) begin
    if (dout_valid && dout_ready) begin
        for (mi = 0; mi < dout_bytes; mi = mi + 1)
            out_b[out_n + mi] = dout_data[8*mi +: 8];
        out_n = out_n + dout_bytes;
    end
    if (done) done_seen = 1;
end

// length of the last operation in clock cycles, from the accepted start to done
integer cyc = 0, start_cyc = 0, done_cyc = 0;
always @(posedge clk) begin
    cyc = cyc + 1;
    if (start && ready) start_cyc = cyc;
    if (done)           done_cyc  = cyc;
end

always @(negedge clk)
    dout_ready = !stall || ($urandom % 3 != 0);

// Send src[0 .. len-1] as beats of up to `rate` bytes. A stream that ends exactly on a full
// block can finish in two legal ways; split_last picks which:
//   0: the last full beat carries din_last
//   1: the full beat is sent as a normal one, then an empty beat carries din_last
task send_stream(input integer which, input integer len, input integer rate,
                 input reg split_last);
    integer pos, nb, j;
    reg     last;
    reg [127:0] d;
    begin
        pos  = 0;
        last = 0;
        while (!last) begin
            nb = len - pos;
            if (nb > rate) nb = rate;
            if (nb < rate) last = 1;
            else           last = (pos + nb == len) && (split_last == 0);

            // unused bytes of a beat are random: the core must ignore them
            d = {$urandom, $urandom, $urandom, $urandom};
            for (j = 0; j < nb; j = j + 1)
                d[8*j +: 8] = (which == 0) ? ad_b[pos + j] : in_b[pos + j];

            @(negedge clk);
            if (stall && ($urandom % 3 == 0)) begin
                din_valid = 0;
                repeat (1 + $urandom % 3) @(negedge clk);
            end
            din_valid = 1;
            din_data  = d;
            din_bytes = nb[4:0];
            din_last  = last;
            @(posedge clk);
            while (!din_ready) @(posedge clk);
            pos = pos + nb;
        end
        @(negedge clk);
        din_valid = 0;
    end
endtask

// Run one operation with the streams already in ad_b / in_b, then wait for the end.
task run_op(input [2:0] m, input integer adlen, input integer mlen, input integer outlen,
            input integer variant);
    integer guard;
    begin
        stall = variant[2];
        @(posedge clk);
        while (!ready) @(posedge clk);
        @(negedge clk);
        out_n     = 0;
        done_seen = 0;
        start   = 1;
        mode    = m;
        key     = swap16(v_key);
        nonce   = swap16(v_nonce);
        out_len = outlen;
        @(negedge clk);
        start   = 0;

        if (m == 3'd0 || m == 3'd1) begin
            send_stream(0, adlen, 16, variant[0]);
            send_stream(1, mlen,  16, variant[1]);
        end else begin
            if (m == 3'd4) send_stream(0, adlen, 8, variant[0]);
            send_stream(1, mlen, 8, variant[1]);
        end

        guard = 0;
        while (!(done_seen && !dout_valid) && guard < 100000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        // let the monitor take the last beat it may have just accepted
        @(posedge clk);
        if (guard >= 100000) begin
            errors = errors + 1;
            $display("test %0d: TIMEOUT (mode %0d)", ops, m);
        end
        ops = ops + 1;
    end
endtask

task check_out(input integer len, input [8*20-1:0] what);
    integer i;
    reg     bad;
    begin
        bad = (out_n != len);
        for (i = 0; i < len && !bad; i = i + 1)
            if (out_b[i] !== exp_b[i]) bad = 1;
        if (bad) begin
            errors = errors + 1;
            $display("vector %0d: %0s wrong (got %0d bytes, expected %0d)", vec, what, out_n, len);
        end
    end
endtask

integer fd, code, i, n_aead, n_hash;
reg [1023:0] vec_file;
integer t_cycles;
reg [63:0] len_bits;

initial begin
    if (!$value$plusargs("VEC=%s", vec_file)) vec_file = "vectors.txt";
    fd = $fopen(vec_file, "r");
    if (fd == 0) begin
        $display("cannot open the vector file (run gen_vectors.py first)");
        $finish;
    end

    repeat (4) @(negedge clk);
    reset = 0;

    vec = 0; n_aead = 0; n_hash = 0;
    code = $fscanf(fd, "%d %d %d %d %h %h %h %h %h %h", v_mode, v_adlen, v_mlen, v_outlen,
                   v_key, v_nonce, v_ad, v_msg, v_out, v_tag);
    while (code == 10) begin
        vec = vec + 1;

        if (v_mode == 0) begin
            n_aead = n_aead + 1;
            for (i = 0; i < v_adlen; i = i + 1) ad_b[i] = field_byte(v_ad, v_adlen, i);

            // encrypt
            for (i = 0; i < v_mlen; i = i + 1) begin
                in_b[i]  = field_byte(v_msg, v_mlen, i);
                exp_b[i] = field_byte(v_out, v_mlen, i);
            end
            tag_in = 0;
            run_op(3'd0, v_adlen, v_mlen, 0, vec);
            check_out(v_mlen, "ciphertext");
            if (tag !== swap16(v_tag) || tag_ok !== 1'b0) begin
                errors = errors + 1;
                $display("vector %0d: encrypt tag wrong", vec);
            end

            // decrypt
            for (i = 0; i < v_mlen; i = i + 1) begin
                in_b[i]  = field_byte(v_out, v_mlen, i);
                exp_b[i] = field_byte(v_msg, v_mlen, i);
            end
            tag_in = swap16(v_tag);
            run_op(3'd1, v_adlen, v_mlen, 0, vec + 3);
            check_out(v_mlen, "plaintext");
            if (tag_ok !== 1'b1 || tag !== 128'b0) begin
                errors = errors + 1;
                $display("vector %0d: decrypt tag_ok = %b, tag output = %h", vec, tag_ok, tag);
            end

            // tampered decrypt: flip one bit somewhere
            tag_in = swap16(v_tag);
            if (vec % 3 == 1 && v_mlen > 0) begin
                flip = $urandom % v_mlen;
                in_b[flip] = in_b[flip] ^ 8'h10;
            end else if (vec % 3 == 2 && v_adlen > 0)
                ad_b[v_adlen - 1] = ad_b[v_adlen - 1] ^ 8'h01;
            else
                tag_in = swap16(v_tag) ^ (128'b1 << ($urandom % 128));
            run_op(3'd1, v_adlen, v_mlen, 0, vec + 5);
            if (tag_ok !== 1'b0 || tag !== 128'b0) begin
                errors = errors + 1;
                $display("vector %0d: a tampered message was accepted", vec);
            end
        end else begin
            n_hash = n_hash + 1;
            // CXOF: the first stream is the bit length of the customization string (8 bytes,
            // low byte first) followed by the string
            if (v_mode == 4) begin
                len_bits = 8 * v_adlen;
                for (i = 0; i < 8; i = i + 1) ad_b[i] = len_bits[8*i +: 8];
                for (i = 0; i < v_adlen; i = i + 1) ad_b[8 + i] = field_byte(v_ad, v_adlen, i);
            end
            for (i = 0; i < v_mlen; i = i + 1)   in_b[i]  = field_byte(v_msg, v_mlen, i);
            for (i = 0; i < v_outlen; i = i + 1) exp_b[i] = field_byte(v_out, v_outlen, i);
            run_op(v_mode[2:0], v_adlen + 8, v_mlen, v_outlen, vec);
            check_out(v_outlen, "hash output");
        end

        code = $fscanf(fd, "%d %d %d %d %h %h %h %h %h %h", v_mode, v_adlen, v_mlen, v_outlen,
                       v_key, v_nonce, v_ad, v_msg, v_out, v_tag);
    end
    $fclose(fd);

    // Speed: encrypt 64 full blocks with nothing stalling and count the clock cycles
    for (i = 0; i < 1024; i = i + 1) in_b[i] = i[7:0];
    tag_in = 0;
    run_op(3'd0, 0, 1024, 0, 0);
    t_cycles = done_cyc - start_cyc;
    $display("speed: 1024 bytes encrypted in %0d cycles with RPC = %0d (%0d.%02d cycles per byte)",
             t_cycles, RPC, t_cycles / 1024, (t_cycles * 100 / 1024) % 100);

    $display("%0d AEAD vectors (x3 runs each) and %0d hash / XOF / CXOF vectors, %0d operations",
             n_aead, n_hash, ops);
    if (vec == 0) begin
        errors = errors + 1;
        $display("no vectors were read");
    end
    if (errors == 0) $display("KAT PASSED");
    else             $display("KAT FAILED (%0d errors)", errors);
    $finish;
end

endmodule
