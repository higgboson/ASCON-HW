// ascon_sb.sv - scoreboard: every operation the monitor saw is recomputed by the reference
//
// The reference is the Ascon team's C code (ref/), called through DPI. Three things are
// compared: the output bytes, the tag (or the accept / reject answer of a decrypt), and how
// many clock cycles the operation took.
//
// Why the cycle count: the core is meant to take a time that depends only on the lengths,
// never on the key or the data (otherwise timing would leak secrets). So for every operation
// that was not held up by the output side, the count must equal a formula of the lengths.

class ascon_sb extends uvm_scoreboard;
    `uvm_component_utils(ascon_sb)

    uvm_analysis_imp #(ascon_xtn, ascon_sb) imp;

    int unsigned rpc = 1;               // rounds per cycle of the core under test
    int unsigned ops [5];               // operations checked, per mode
    int unsigned mismatches, timing_checked, timing_errors;
    int unsigned accepted, rejected;    // decrypts: tag right / tag wrong

    function new(string name, uvm_component parent);
        super.new(name, parent);
        imp = new("imp", this);
    endfunction

    function void build_phase(uvm_phase phase);
        void'(uvm_config_db #(int unsigned)::get(this, "", "rpc", rpc));
    endfunction

    // Cycles from the accepted start to the cycle done is seen, for an operation that never
    // had to wait: 1 cycle to take each beat, then the permutation.
    function int unsigned expected_cycles(ascon_xtn t);
        int unsigned p12 = 12 / rpc;
        int unsigned pb  = t.is_aead() ? 8 / rpc : p12;
        int unsigned c   = p12;                                     // start value
        int unsigned blocks;

        if (t.is_aead() || t.mode == `ASCON_CXOF) begin
            if (t.ad_skipped) c += 1;
            else              c += t.ad_beats * (1 + pb) + (t.ad_last_full ? pb : 0);
        end
        if (t.is_aead()) begin
            // the last block is not permuted on its own, unless it was full (then its
            // padding block is what is left unpermuted)
            c += (t.msg_beats - 1) * (1 + pb) + (t.msg_last_full ? 1 + pb : 1);
            c += p12;                                               // final permutation
        end else begin
            c += t.msg_beats * (1 + p12) + (t.msg_last_full ? p12 : 0);
            blocks = (t.out.size() + 7) / 8;
            c += (blocks == 0) ? 1 : blocks + (blocks - 1) * p12;   // output blocks
        end
        return c + 1;                                               // the done cycle
    endfunction

    function void write(ascon_xtn t);
        byte unsigned k [16], n [16], tg [16];
        byte unsigned a [`ASCON_MAXB], m [`ASCON_MAXB], o [`ASCON_MAXB];
        bit [127:0]   exp_tag;
        bit           exp_ok, bad;
        int           exp_len, exp_c;
        string        what = "";

        if (t.mode > `ASCON_CXOF || t.ad.size() > `ASCON_MAXB || t.msg.size() > `ASCON_MAXB) begin
            `uvm_error("SB", "operation outside what the testbench can check")
            return;
        end
        ops[t.mode]++;

        for (int i = 0; i < 16; i++) begin
            k[i] = t.key[8*i +: 8];
            n[i] = t.nonce[8*i +: 8];
            tg[i] = t.tag_in[8*i +: 8];
        end
        foreach (t.ad[i])  a[i] = t.ad[i];
        foreach (t.msg[i]) m[i] = t.msg[i];

        case (t.mode)
            `ASCON_ENC: begin
                ascon_dpi_aead_enc(k, n, a, t.ad.size(), m, t.msg.size(), o, tg);
                for (int i = 0; i < 16; i++) exp_tag[8*i +: 8] = tg[i];
                exp_len = t.msg.size();
            end
            `ASCON_DEC: begin
                exp_ok  = ascon_dpi_aead_dec(k, n, a, t.ad.size(), m, t.msg.size(), tg, o) != 0;
                exp_len = t.msg.size();
                if (exp_ok) accepted++; else rejected++;
            end
            default: begin
                exp_len = ascon_dpi_hash(t.mode, a, t.ad.size(), m, t.msg.size(), o,
                                         t.mode == `ASCON_HASH ? 32 : t.out_len);
                if (exp_len < 0) begin
                    `uvm_error("SB", $sformatf("the reference cannot do mode %0d with %0d output bytes",
                               t.mode, t.out_len))
                    return;
                end
                if (t.mode == `ASCON_CXOF && t.cx_bits != 64'(t.ad.size()) * 8)
                    `uvm_error("SB", "CXOF: the length word does not match the customization string")
            end
        endcase

        // output bytes
        if (t.out.size() != exp_len) begin
            bad  = 1;
            what = $sformatf("%0d output bytes, expected %0d", t.out.size(), exp_len);
        end else
            foreach (t.out[i])
                if (t.out[i] != o[i]) begin
                    bad  = 1;
                    what = $sformatf("output byte %0d = %02h, expected %02h", i, t.out[i], o[i]);
                    break;
                end

        // tag and verdict (exp_tag and exp_ok are 0 where they do not apply, like the core's)
        if (t.tag !== exp_tag) begin
            bad  = 1;
            what = {what, $sformatf(" tag = %032h, expected %032h", t.tag, exp_tag)};
        end
        if (t.tag_ok !== exp_ok) begin
            bad  = 1;
            what = {what, $sformatf(" tag_ok = %0b, expected %0b", t.tag_ok, exp_ok)};
        end

        if (bad) begin
            mismatches++;
            `uvm_error("SB", $sformatf("mode %0d, ad %0d bytes, msg %0d bytes: %s",
                       t.mode, t.ad.size(), t.msg.size(), what))
        end

        // run length
        if (!t.out_stalled) begin
            timing_checked++;
            exp_c = expected_cycles(t);
            if (t.cycles - t.in_wait != exp_c) begin
                timing_errors++;
                `uvm_error("SB", $sformatf("mode %0d, ad %0d bytes, msg %0d bytes: took %0d cycles (%0d waiting for input), expected %0d",
                           t.mode, t.ad.size(), t.msg.size(), t.cycles, t.in_wait, exp_c))
            end
        end
    endfunction

    function int unsigned total();
        return ops[0] + ops[1] + ops[2] + ops[3] + ops[4];
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("SB", $sformatf("checked %0d operations: %0d encrypt, %0d decrypt (%0d accepted, %0d forgeries rejected), %0d hash, %0d XOF, %0d CXOF",
                  total(), ops[0], ops[1], accepted, rejected, ops[2], ops[3], ops[4]), UVM_LOW)
        `uvm_info("SB", $sformatf("wrong results %0d, run lengths checked %0d, wrong run lengths %0d",
                  mismatches, timing_checked, timing_errors), UVM_LOW)
        if (total() == 0)
            `uvm_error("SB", "no operations were checked")
    endfunction

endclass
