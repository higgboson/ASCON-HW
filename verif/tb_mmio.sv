// tb_mmio.sv - the register wrapper (rtl/ascon_mmio.v), driven the way the C driver does it
//
// Runs the official test vectors through the registers (encrypt, decrypt, a
// tampered decrypt, Hash256, XOF128, CXOF128), with random pauses between bus accesses so
// the core sees a CPU of any speed. Also checks what must NOT be possible from software:
// reading the key back, reading the tag of a decrypt, and that a soft reset really stops
// an operation.
//
//   +VEC=<file>   vector file (default vectors.txt, made by gen_vectors.py)
//   +STEP=<n>     use every n-th vector (default 1 = all of them)

`timescale 1ns/1ps

module tb_mmio;

parameter RPC  = 1;
localparam MAXB = 1024;
localparam FW   = 8 * MAXB;

localparam [31:0] CTRL = 32'h00, OUT_LEN = 32'h04, KEY = 32'h10, NONCE = 32'h20, DIN = 32'h30,
                  DIN_CTRL = 32'h40, DOUT = 32'h50, DOUT_ACK = 32'h60, TAG = 32'h70;
localparam [31:0] BASE = 32'h3000_0000;

reg clk = 0;
always #5 clk = ~clk;

reg         reset = 1, wr_en = 0;
reg  [31:0] addr = 0, wr_data = 0;
wire [31:0] rd_data;

ascon_mmio #(.RPC(RPC)) dut (.clk(clk), .reset(reset), .wr_en(wr_en), .addr(addr),
                             .wr_data(wr_data), .rd_data(rd_data));

integer errors = 0, ops = 0, vec = 0;

// one store, as the CPU does it: address and data for one clock edge
task wr(input [31:0] a, input [31:0] d);
    begin
        @(negedge clk);
        if ($urandom % 4 == 0) repeat ($urandom % 3) @(negedge clk);
        wr_en = 1; addr = BASE + a; wr_data = d;
        @(negedge clk);
        wr_en = 0;
    end
endtask

// one load: the data follows the address, nothing changes in the peripheral
task rd(input [31:0] a, output [31:0] d);
    begin
        @(negedge clk);
        addr = BASE + a;
        #1 d = rd_data;
    end
endtask

task wait_status(input [31:0] mask, input [31:0] want);
    reg [31:0] s;
    integer    guard;
    begin
        guard = 0;
        rd(CTRL, s);
        while ((s & mask) != want && guard < 5000) begin
            rd(CTRL, s);
            guard = guard + 1;
        end
        if (guard >= 5000) begin
            errors = errors + 1;
            $display("vector %0d: status never became %h (mask %h), it is %h", vec, want, mask, s);
        end
    end
endtask

task wr128(input [31:0] a, input [127:0] v);
    integer i;
    for (i = 0; i < 4; i = i + 1) wr(a + 4 * i, v[32*i +: 32]);
endtask

reg [7:0] s1_b [0:MAXB+7];              // first stream (associated data / customization)
reg [7:0] in_b [0:MAXB-1];              // message stream
reg [7:0] exp_b [0:MAXB-1];
reg [7:0] out_b [0:MAXB+15];
integer   out_n;

// send bytes [pos, pos + n) of a stream as one beat
task beat(input integer which, input integer pos, input integer n, input last);
    integer     i;
    reg [127:0] d;
    begin
        wait_status(32'h2, 32'h0);                      // DIN free
        d = {$urandom, $urandom, $urandom, $urandom};   // unused bytes: anything
        for (i = 0; i < n; i = i + 1)
            d[8*i +: 8] = (which == 0) ? s1_b[pos + i] : in_b[pos + i];
        for (i = 0; i < (n + 3) / 4; i = i + 1)
            wr(DIN + 4 * i, d[32*i +: 32]);
        wr(DIN_CTRL, n | (last ? 32'h100 : 0));
    end
endtask

// take one output beat into out_b
task take;
    reg [31:0] s, w;
    integer    i, n;
    begin
        wait_status(32'h4, 32'h4);                      // DOUT valid
        rd(CTRL, s);
        n = s[12:8];
        for (i = 0; i < n; i = i + 1) begin
            if (i % 4 == 0) rd(DOUT + i, w);
            out_b[out_n + i] = w[8*(i % 4) +: 8];
        end
        out_n = out_n + n;
        wr(DOUT_ACK, 0);
    end
endtask

task stream(input integer which, input integer len, input integer rate, input with_output);
    integer pos, n;
    begin
        pos = 0;
        while (len - pos > rate) begin
            beat(which, pos, rate, 1'b0);
            if (with_output) take;
            pos = pos + rate;
        end
        n = len - pos;
        beat(which, pos, n, 1'b1);
        if (with_output) take;
    end
endtask

task run_op(input [2:0] m, input [127:0] k, input [127:0] nn, input [127:0] t_exp,
            input integer s1len, input integer mlen, input integer outlen);
    integer got;
    begin
        out_n = 0;
        wait_status(32'h1, 32'h0);                      // idle
        if (m <= 3'd1) begin
            wr128(KEY, k);
            wr128(NONCE, nn);
            if (m == 3'd1) wr128(TAG, t_exp);
        end else
            wr(OUT_LEN, outlen);
        wr(CTRL, 32'h100 | m);

        if (m <= 3'd1) begin
            stream(0, s1len, 16, 1'b0);
            stream(1, mlen, 16, 1'b1);
        end else begin
            if (m == 3'd4) stream(0, s1len, 8, 1'b0);
            stream(1, mlen, 8, 1'b0);
            got = 0;
            while (got < outlen) begin
                take;
                got = out_n;
            end
        end
        wait_status(32'h8, 32'h8);                      // done
        ops = ops + 1;
    end
endtask

integer       v_mode, v_adlen, v_mlen, v_outlen;
reg [127:0]   v_key, v_nonce, v_tag;
reg [FW-1:0]  v_ad, v_msg, v_out;

function [7:0] field_byte(input [FW-1:0] f, input integer len, input integer i);
    field_byte = f[8 * (len - 1 - i) +: 8];
endfunction

function [127:0] swap16(input [127:0] f);
    integer i;
    for (i = 0; i < 16; i = i + 1)
        swap16[8*i +: 8] = f[8 * (15 - i) +: 8];
endfunction

task check_out(input integer len, input [8*12-1:0] what);
    integer i;
    reg     bad;
    begin
        bad = (out_n != len);
        for (i = 0; i < len && !bad; i = i + 1)
            if (out_b[i] !== exp_b[i]) bad = 1;
        if (bad) begin
            errors = errors + 1;
            $display("vector %0d: %0s wrong (%0d bytes, expected %0d)", vec, what, out_n, len);
        end
    end
endtask

task check(input ok, input [8*40-1:0] what);
    if (!ok) begin
        errors = errors + 1;
        $display("vector %0d: %0s", vec, what);
    end
endtask

integer     fd, code, i, step, used;
reg [1023:0] vec_file;
reg [31:0]  s, w;
reg [127:0] t;
reg [63:0]  len_bits;

initial begin
    if (!$value$plusargs("VEC=%s", vec_file)) vec_file = "vectors.txt";
    if (!$value$plusargs("STEP=%d", step)) step = 1;
    fd = $fopen(vec_file, "r");
    if (fd == 0) begin
        $display("cannot open the vector file (run gen_vectors.py first)");
        $finish;
    end
    repeat (4) @(negedge clk);
    reset = 0;

    used = 0;
    code = $fscanf(fd, "%d %d %d %d %h %h %h %h %h %h", v_mode, v_adlen, v_mlen, v_outlen,
                   v_key, v_nonce, v_ad, v_msg, v_out, v_tag);
    while (code == 10) begin
        vec = vec + 1;
        if (vec % step == 0) begin
            used = used + 1;
            if (v_mode == 0) begin
                for (i = 0; i < v_adlen; i = i + 1) s1_b[i] = field_byte(v_ad, v_adlen, i);

                // encrypt: ciphertext and tag
                for (i = 0; i < v_mlen; i = i + 1) begin
                    in_b[i]  = field_byte(v_msg, v_mlen, i);
                    exp_b[i] = field_byte(v_out, v_mlen, i);
                end
                run_op(3'd0, swap16(v_key), swap16(v_nonce), 0, v_adlen, v_mlen, 0);
                check_out(v_mlen, "ciphertext");
                for (i = 0; i < 4; i = i + 1) begin
                    rd(TAG + 4 * i, w);
                    t[32*i +: 32] = w;
                end
                rd(CTRL, s);
                check(t === swap16(v_tag) && !s[4], "encrypt: wrong tag");

                // decrypt: plaintext, tag accepted, tag register shows nothing
                for (i = 0; i < v_mlen; i = i + 1) begin
                    in_b[i]  = field_byte(v_out, v_mlen, i);
                    exp_b[i] = field_byte(v_msg, v_mlen, i);
                end
                run_op(3'd1, swap16(v_key), swap16(v_nonce), swap16(v_tag), v_adlen, v_mlen, 0);
                check_out(v_mlen, "plaintext");
                rd(CTRL, s);
                rd(TAG + 4 * (vec % 4), w);
                check(s[4] && w === 32'b0, "decrypt: tag not accepted, or tag readable");

                // one bit of the expected tag flipped: must be refused
                run_op(3'd1, swap16(v_key), swap16(v_nonce),
                       swap16(v_tag) ^ (128'b1 << ($urandom % 128)), v_adlen, v_mlen, 0);
                rd(CTRL, s);
                check(!s[4], "a forged tag was accepted");

                // the secrets are write-only
                rd(KEY + 4 * (vec % 4), w);
                check(w === 32'b0, "the key can be read back");
                rd(NONCE + 4 * (vec % 4), w);
                check(w === 32'b0, "the nonce can be read back");
            end else begin
                if (v_mode == 4) begin
                    len_bits = 8 * v_adlen;
                    for (i = 0; i < 8; i = i + 1) s1_b[i] = len_bits[8*i +: 8];
                    for (i = 0; i < v_adlen; i = i + 1) s1_b[8 + i] = field_byte(v_ad, v_adlen, i);
                end
                for (i = 0; i < v_mlen; i = i + 1)   in_b[i]  = field_byte(v_msg, v_mlen, i);
                for (i = 0; i < v_outlen; i = i + 1) exp_b[i] = field_byte(v_out, v_outlen, i);
                run_op(v_mode[2:0], 0, 0, 0, v_adlen + 8, v_mlen, v_outlen);
                check_out(v_outlen, "hash output");
            end
        end
        code = $fscanf(fd, "%d %d %d %d %h %h %h %h %h %h", v_mode, v_adlen, v_mlen, v_outlen,
                       v_key, v_nonce, v_ad, v_msg, v_out, v_tag);
    end
    $fclose(fd);

    // Soft reset in the middle of an operation: the core must go idle at once, drop the
    // beat that was waiting, and the next operation must come out right (a hash of nothing).
    vec = 0;
    wr128(KEY, 128'h0123456789abcdef_0011223344556677);
    wr(CTRL, 32'h100);                                  // start an encryption
    wr(DIN + 0, 32'hdeadbeef);
    wr(DIN_CTRL, 32'd16);                               // one AD beat, more to come
    wr(CTRL, 32'h8000_0000);                            // ... but reset instead
    rd(CTRL, s);
    check(s[4:0] === 5'b0, "soft reset: the core is not idle and clean");
    out_n = 0;
    wr(CTRL, 32'h100 | 3'd2);
    stream(1, 0, 8, 1'b0);
    repeat (4) take;
    wait_status(32'h8, 32'h8);
    // Ascon-Hash256 of the empty message (kat/hash256.txt, Count = 1), first 8 bytes
    check({out_b[0], out_b[1], out_b[2], out_b[3], out_b[4], out_b[5], out_b[6], out_b[7]}
          === 64'h0B3BE5850F2F6B98 && out_n == 32, "wrong hash after a soft reset");

    $display("%0d vectors, %0d operations through the registers", used, ops);
    if (used == 0) begin
        errors = errors + 1;
        $display("no vectors were used");
    end
    if (errors == 0) $display("MMIO PASSED");
    else             $display("MMIO FAILED (%0d errors)", errors);
    $finish;
end

endmodule
