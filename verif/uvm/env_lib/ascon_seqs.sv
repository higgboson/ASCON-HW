// ascon_seqs.sv - sequences of operations
//
// A sequence shapes its operations by setting the knobs of ascon_xtn (weights, fixed
// lengths, flow) before randomize(), see ascon_xtn.sv.

class ascon_base_seq extends uvm_sequence #(ascon_xtn);
    `uvm_object_utils(ascon_base_seq)

    int unsigned n_ops = 100;

    function new(string name = "ascon_base_seq");
        super.new(name);
    endfunction

    task send(ascon_xtn t);
        start_item(t);
        if (!t.randomize()) `uvm_fatal("SEQ", "randomize failed")
        finish_item(t);
    endtask
endclass

// fully random operations with the default distributions
class ascon_rand_seq extends ascon_base_seq;
    `uvm_object_utils(ascon_rand_seq)
    function new(string name = "ascon_rand_seq"); super.new(name); endfunction

    task body();
        repeat (n_ops) begin
            ascon_xtn t = ascon_xtn::type_id::create("t");
            send(t);
        end
    endtask
endclass

// Every length around the block boundaries, one by one. Nothing stalls and nothing waits,
// so the scoreboard also checks the exact cycle count of every one of these.
//   AEAD: associated data x message, each from the list below, encrypt and decrypt
//   hash modes: every message length 0..33, and for XOF / CXOF a sweep of output lengths
//   and customization strings
class ascon_corner_seq extends ascon_base_seq;
    `uvm_object_utils(ascon_corner_seq)
    function new(string name = "ascon_corner_seq"); super.new(name); endfunction

    task one(bit [2:0] m, int adl, int ml, int ol, int split);
        ascon_xtn t = ascon_xtn::type_id::create("t");
        t.only_mode(m);
        t.fix_ad    = adl;
        t.fix_msg   = ml;
        t.fix_out   = ol;
        t.fix_split = split;
        t.flow      = FLOW_QUIET;
        t.poke_pct  = 0;
        t.damage_pct = 0;
        send(t);
    endtask

    task body();
        int aead_len [12] = '{0, 1, 7, 8, 15, 16, 17, 31, 32, 33, 47, 48};
        int out_lens [10] = '{0, 1, 7, 8, 9, 16, 17, 32, 33, 64};
        int z_lens   [8]  = '{0, 1, 7, 8, 9, 16, 17, 24};
        int cx_len   [5]  = '{0, 3, 8, 21, 24};

        foreach (aead_len[a])
            foreach (aead_len[m]) begin
                one(`ASCON_ENC, aead_len[a], aead_len[m], 0, (a + m) % 2);
                one(`ASCON_DEC, aead_len[a], aead_len[m], 0, (a + m + 1) % 2);
            end
        // every position of the padding byte: 0..15 bytes over a block, both streams
        for (int n = 0; n < 34; n++) begin
            one(`ASCON_ENC, n, 33 - n, 0, n % 2);
            one(`ASCON_DEC, 33 - n, n, 0, n % 2);
        end

        for (int n = 0; n < 34; n++) begin
            one(`ASCON_HASH, 0, n, 0, n % 2);
            one(`ASCON_XOF,  0, n, out_lens[n % 10], (n + 1) % 2);
            one(`ASCON_CXOF, z_lens[n % 8], n, out_lens[(n + 3) % 10], n % 2);
        end
        foreach (z_lens[z])
            foreach (out_lens[o])
                one(`ASCON_CXOF, z_lens[z], 8 * (o % 4), out_lens[o], (z + o) % 2);
        // customization string x message: empty, short, one block, several blocks
        foreach (cx_len[z])
            foreach (cx_len[m])
                one(`ASCON_CXOF, cx_len[z], cx_len[m], 16, (z + m) % 2);
        // long outputs, past the 64 bytes the XOF128 reference can give
        one(`ASCON_CXOF, 5, 20, 150, 0);
        one(`ASCON_CXOF, 0, 0, 97, 1);
    endtask
endclass

// decrypts only, most of them damaged in one bit: tag, ciphertext, associated data, key
// or nonce. The core must reject every one of them (and still accept the clean ones).
class ascon_tamper_seq extends ascon_base_seq;
    `uvm_object_utils(ascon_tamper_seq)
    function new(string name = "ascon_tamper_seq"); super.new(name); endfunction

    task body();
        repeat (n_ops) begin
            ascon_xtn t = ascon_xtn::type_id::create("t");
            t.only_mode(`ASCON_DEC);
            t.damage_pct = 80;
            send(t);
        end
    endtask
endclass

// back to back: no gap between operations and nothing stalls, so every run length is checked
class ascon_b2b_seq extends ascon_base_seq;
    `uvm_object_utils(ascon_b2b_seq)
    function new(string name = "ascon_b2b_seq"); super.new(name); endfunction

    task body();
        repeat (n_ops) begin
            ascon_xtn t = ascon_xtn::type_id::create("t");
            t.flow     = FLOW_QUIET;
            t.poke_pct = 0;
            send(t);
        end
    endtask
endclass

// both sides stall most of the time, and the next operation starts as soon as it can:
// output beats pile up behind a slow reader while the core is already working again
class ascon_stall_seq extends ascon_base_seq;
    `uvm_object_utils(ascon_stall_seq)
    function new(string name = "ascon_stall_seq"); super.new(name); endfunction

    task body();
        repeat (n_ops) begin
            ascon_xtn t = ascon_xtn::type_id::create("t");
            t.flow = FLOW_SLOW;
            send(t);
        end
    endtask
endclass

// a second start in the middle of every operation: it must change nothing
class ascon_poke_seq extends ascon_base_seq;
    `uvm_object_utils(ascon_poke_seq)
    function new(string name = "ascon_poke_seq"); super.new(name); endfunction

    task body();
        repeat (n_ops) begin
            ascon_xtn t = ascon_xtn::type_id::create("t");
            t.poke_pct = 100;
            send(t);
        end
    endtask
endclass

// reset in the middle of every second operation. The operation after a reset must come out
// right, and the core must be wiped (checked by a_wiped in ascon_if).
class ascon_reset_seq extends ascon_base_seq;
    `uvm_object_utils(ascon_reset_seq)
    function new(string name = "ascon_reset_seq"); super.new(name); endfunction

    task body();
        for (int unsigned i = 0; i < n_ops; i++) begin
            ascon_xtn t = ascon_xtn::type_id::create("t");
            t.do_kill  = (i % 2 == 0);
            t.poke_pct = 0;
            send(t);
        end
    endtask
endclass
