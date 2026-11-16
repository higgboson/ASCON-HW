// ascon_xtn.sv - one operation of the core: an encryption, a decryption or a hash
//
// The driver uses the rand fields as stimulus. The monitor builds its own ascon_xtn from
// what it saw on the pins (the bytes that really went in and came out, the tag, how long it
// took), and that one goes to the scoreboard and to coverage.

typedef enum { TAMPER_NONE, TAMPER_TAG, TAMPER_CT, TAMPER_AD, TAMPER_KEY, TAMPER_NONCE } tamper_e;

// how busy the handshakes are: the default mix, nothing ever waits, or both sides slow
typedef enum { FLOW_MIX, FLOW_QUIET, FLOW_SLOW } flow_e;

class ascon_xtn extends uvm_sequence_item;

    rand bit [2:0]     mode;
    rand bit [127:0]   key, nonce;          // byte 0 = bits 7:0
    rand int unsigned  ad_len;              // associated data, or the CXOF customization string
    rand int unsigned  msg_len;
    rand int unsigned  out_len;             // XOF / CXOF output bytes
    rand bit           damaged;             // decrypt only: corrupt one bit before decrypting
    rand tamper_e      tamper;              // ... and where
    rand bit           zero_data;           // all-zero key, nonce and data instead of random

    // how the operation is driven
    rand bit           ad_split, msg_split; // a stream ending on a full block: 0 = that beat
                                            // carries last, 1 = an empty last beat follows
    rand int unsigned  gap;                 // idle cycles before start; 0 = back to back
    rand int unsigned  in_stall, out_stall; // % of cycles the input / output side stalls
    rand bit           poke;                // pulse start again while busy; must be ignored
    rand int unsigned  poke_at;             // before which input beat
    rand bit           kill;                // reset the core in the middle of the operation
    rand int unsigned  kill_at;             // before which input beat

    byte unsigned      ad  [$];
    byte unsigned      msg [$];             // plaintext (encrypt), ciphertext (decrypt), message
    bit [127:0]        tag_in;              // decrypt: the tag to check against

    // filled in by the monitor
    byte unsigned      out [$];
    bit [127:0]        tag;
    bit                tag_ok;
    bit [63:0]         cx_bits;             // CXOF: the length word sent before the string
    int unsigned       cycles;              // start accepted -> done seen
    int unsigned       in_wait;             // cycles the core waited for an input beat
    bit                out_stalled;         // the output side made the core wait at least once
    int unsigned       ad_beats, msg_beats, out_beats;
    bit                ad_last_full, msg_last_full;   // the last beat of the stream was a full block
    bit                ad_skipped;          // AEAD with no associated data at all
    bit                poked;
    bit                b2b;                 // started right after the previous done
    bit                out_pending;         // started while the previous output was still waiting
    bit                done_seen;

    // Knobs: plain variables a sequence sets BEFORE randomize() to steer the constraints
    // below (weights, fixed lengths, how busy the handshakes are). The defaults give the
    // general random mix.
    int unsigned w_enc = 30, w_dec = 30, w_hash = 15, w_xof = 10, w_cxof = 15;   // mode weights
    int          fix_ad = -1, fix_msg = -1, fix_out = -1;   // exact length, -1 = random
    int          fix_split = -1;                // 0 / 1 = force both split bits, -1 = random
    int unsigned damage_pct = 40;               // decrypt: % of them damaged in one bit
    flow_e       flow = FLOW_MIX;
    int unsigned poke_pct = 10;
    bit          do_kill;

    constraint c_mode { mode dist { `ASCON_ENC := w_enc, `ASCON_DEC := w_dec, `ASCON_HASH := w_hash,
                                    `ASCON_XOF := w_xof, `ASCON_CXOF := w_cxof }; }

    // lengths around the block boundaries (16 bytes for AEAD, 8 for the hash modes) matter most
    constraint c_ad_len {
        if (mode == `ASCON_HASH || mode == `ASCON_XOF) ad_len == 0;
        else if (fix_ad >= 0) ad_len == fix_ad;
        else ad_len dist { 0 := 12, [1:7] :/ 10, 8 := 6, [9:15] :/ 10, 16 := 12, [17:31] :/ 12,
                           32 := 10, [33:47] :/ 8, 48 := 5, [49:90] :/ 15 };
    }
    constraint c_msg_len {
        if (fix_msg >= 0) msg_len == fix_msg;
        else msg_len dist { 0 := 12, [1:7] :/ 10, 8 := 6, [9:15] :/ 10, 16 := 12, [17:31] :/ 12,
                            32 := 10, [33:47] :/ 8, 48 := 5, [49:120] :/ 15 };
    }
    // the reference XOF128 stops at 64 bytes; CXOF128 takes any length and uses the same logic
    constraint c_out_len {
        if (mode != `ASCON_XOF && mode != `ASCON_CXOF) out_len == 0;
        else if (fix_out >= 0) out_len == fix_out;
        else if (mode == `ASCON_XOF) out_len dist { 0 := 5, [1:7] :/ 15, 8 := 10, [9:15] :/ 15,
                                                    16 := 10, [17:63] :/ 35, 64 := 10 };
        else out_len dist { 0 := 5, [1:7] :/ 15, 8 := 10, [9:15] :/ 15, 16 := 10, [17:63] :/ 25,
                            64 := 5, [65:150] :/ 15 };
    }
    constraint c_tamper {
        damaged dist { 0 := 100 - damage_pct, 1 := damage_pct };
        if (mode == `ASCON_DEC && damaged) tamper != TAMPER_NONE;      // any kind, equally likely
        else tamper == TAMPER_NONE;
    }
    constraint c_split {
        if (fix_split >= 0) { ad_split == (fix_split != 0); msg_split == (fix_split != 0); }
    }
    constraint c_data  { zero_data dist { 0 := 95, 1 := 5 }; }
    constraint c_flow {
        if (flow == FLOW_QUIET) { gap == 0; in_stall == 0; out_stall == 0; }
        else if (flow == FLOW_SLOW) {
            gap inside {[0:1]};
            in_stall  dist { 0 := 20, [40:90] :/ 80 };
            out_stall dist { 0 := 10, [50:95] :/ 90 };
        } else {
            gap dist { 0 := 35, [1:3] :/ 45, [4:20] :/ 20 };
            in_stall  dist { 0 := 40, [1:30] :/ 30, [31:80] :/ 30 };
            out_stall dist { 0 := 40, [1:30] :/ 30, [31:80] :/ 30 };
        }
    }
    constraint c_poke  { poke dist { 0 := 100 - poke_pct, 1 := poke_pct }; poke_at inside {[0:6]}; }
    constraint c_kill  { kill == do_kill; kill_at inside {[0:6]}; }

    `uvm_object_utils_begin(ascon_xtn)
        `uvm_field_int(mode,    UVM_ALL_ON | UVM_DEC)
        `uvm_field_int(ad_len,  UVM_ALL_ON | UVM_DEC)
        `uvm_field_int(msg_len, UVM_ALL_ON | UVM_DEC)
        `uvm_field_int(out_len, UVM_ALL_ON | UVM_DEC)
        `uvm_field_int(cycles,  UVM_ALL_ON | UVM_DEC)
        `uvm_field_int(tag_ok,  UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "ascon_xtn");
        super.new(name);
    endfunction

    // only this mode
    function void only_mode(bit [2:0] m);
        w_enc  = (m == `ASCON_ENC);
        w_dec  = (m == `ASCON_DEC);
        w_hash = (m == `ASCON_HASH);
        w_xof  = (m == `ASCON_XOF);
        w_cxof = (m == `ASCON_CXOF);
    endfunction

    function bit is_aead();
        return mode == `ASCON_ENC || mode == `ASCON_DEC;
    endfunction

    // bytes per block
    function int rate();
        return is_aead() ? 16 : 8;
    endfunction

    // The data bytes are filled in here, not by the constraint solver: they only need to be
    // random, and this is much faster for long messages.
    function void post_randomize();
        if (zero_data) begin key = '0; nonce = '0; end
        ad.delete();
        msg.delete();
        repeat (ad_len)  ad.push_back(zero_data ? 8'h00 : $urandom);
        repeat (msg_len) msg.push_back(zero_data ? 8'h00 : $urandom);
        if (mode == `ASCON_DEC)
            make_decrypt();
    endfunction

    // A decryption needs a ciphertext and tag that belong together. Take msg as the
    // plaintext, encrypt it with the reference model, then damage one thing if asked.
    function void make_decrypt();
        byte unsigned k [16], n [16], t [16];
        byte unsigned a [`ASCON_MAXB], m [`ASCON_MAXB], c [`ASCON_MAXB];
        int unsigned  bit_n, byte_n;

        for (int i = 0; i < 16; i++) begin k[i] = key[8*i +: 8]; n[i] = nonce[8*i +: 8]; end
        foreach (ad[i])  a[i] = ad[i];
        foreach (msg[i]) m[i] = msg[i];
        ascon_dpi_aead_enc(k, n, a, ad.size(), m, msg.size(), c, t);
        foreach (msg[i]) msg[i] = c[i];
        for (int i = 0; i < 16; i++) tag_in[8*i +: 8] = t[i];

        // nothing to damage in an empty stream: damage the tag instead
        if (tamper == TAMPER_CT && msg.size() == 0) tamper = TAMPER_TAG;
        if (tamper == TAMPER_AD && ad.size()  == 0) tamper = TAMPER_TAG;
        // flip one bit
        bit_n = $urandom_range(127);
        case (tamper)
            TAMPER_TAG:   tag_in[bit_n] = !tag_in[bit_n];
            TAMPER_KEY:   key[bit_n]    = !key[bit_n];
            TAMPER_NONCE: nonce[bit_n]  = !nonce[bit_n];
            TAMPER_CT: begin
                byte_n = $urandom_range(msg.size() - 1);
                msg[byte_n] = msg[byte_n] ^ (8'h01 << bit_n[2:0]);
            end
            TAMPER_AD: begin
                byte_n = $urandom_range(ad.size() - 1);
                ad[byte_n] = ad[byte_n] ^ (8'h01 << bit_n[2:0]);
            end
            default: ;
        endcase
    endfunction

endclass
