// ascon_coverage.sv - functional coverage of the operations the monitor saw
//
// What matters for this design is not the data values (the permutation scrambles them the
// same way whatever they are) but the SHAPE of an operation: which mode, how each stream's
// length sits against the block size, how the stream ended, where the padding byte landed,
// and what the handshakes were doing meanwhile. write() first reduces an operation to those
// few small numbers, then the covergroups sample them.
//
// The same numbers also go into a plain table of named bins (need / hit below). That table
// is printed at the end of every run, so the holes are visible even on a simulator without
// covergroups (Verilator), and it must agree with what IMC shows.

class ascon_coverage extends uvm_subscriber #(ascon_xtn);
    `uvm_component_utils(ascon_coverage)

    // how a length sits against the block size
    typedef enum { L_ZERO, L_PART, L_ONE, L_MULTI_PART, L_MULTI_FULL } len_e;
    // how a stream ended
    typedef enum { E_EMPTY, E_PARTIAL, E_FULL_LAST, E_SPLIT } end_e;

    // one operation, reduced (set by write, sampled by the covergroups)
    bit [2:0]    mode;
    bit          dir;                   // AEAD: 0 = encrypt, 1 = decrypt
    len_e        ad_cls, msg_cls, out_cls;
    end_e        ad_end, msg_end;
    int unsigned ad_tail, msg_tail, out_tail;   // length modulo the block size
    bit          verdict;               // decrypt: tag accepted
    bit          in_waited, out_stalled, poked, b2b, out_pending;

    covergroup cg_aead;
        option.per_instance = 1;
        DIR:      coverpoint dir      { bins enc = {0}; bins dec = {1}; }
        AD_CLS:   coverpoint ad_cls;
        MSG_CLS:  coverpoint msg_cls;
        AD_END:   coverpoint ad_end;
        MSG_END:  coverpoint msg_end;
        // every position of the padding byte inside a block
        AD_TAIL:  coverpoint ad_tail  { bins pos [16] = {[0:15]}; }
        MSG_TAIL: coverpoint msg_tail { bins pos [16] = {[0:15]}; }
        DIR_X_AD_X_MSG: cross DIR, AD_CLS, MSG_CLS;
        DIR_X_AD_END:   cross DIR, AD_END;
        DIR_X_MSG_END:  cross DIR, MSG_END;
        DIR_X_MSG_TAIL: cross DIR, MSG_TAIL;
    endgroup

    covergroup cg_decrypt;
        option.per_instance = 1;
        VERDICT: coverpoint verdict { bins rejected = {0}; bins accepted = {1}; }
        AD_CLS:  coverpoint ad_cls;
        MSG_CLS: coverpoint msg_cls;
        VERDICT_X_AD:  cross VERDICT, AD_CLS;
        VERDICT_X_MSG: cross VERDICT, MSG_CLS;
    endgroup

    covergroup cg_hash;
        option.per_instance = 1;
        HMODE:    coverpoint mode     { bins hash = {`ASCON_HASH}; bins xof = {`ASCON_XOF};
                                        bins cxof = {`ASCON_CXOF}; }
        MSG_CLS:  coverpoint msg_cls;
        MSG_END:  coverpoint msg_end;
        MSG_TAIL: coverpoint msg_tail { bins pos [8] = {[0:7]}; }
        HMODE_X_MSG:     cross HMODE, MSG_CLS;
        HMODE_X_MSG_END: cross HMODE, MSG_END;
    endgroup

    covergroup cg_xof;
        option.per_instance = 1;
        XMODE:    coverpoint mode     { bins xof = {`ASCON_XOF}; bins cxof = {`ASCON_CXOF}; }
        OUT_CLS:  coverpoint out_cls;
        OUT_TAIL: coverpoint out_tail { bins pos [8] = {[0:7]}; }
        XMODE_X_OUT: cross XMODE, OUT_CLS;
    endgroup

    // CXOF: the customization string (its stream always starts with the 8-byte length word,
    // so it is never empty)
    covergroup cg_cxof;
        option.per_instance = 1;
        Z_CLS:   coverpoint ad_cls;
        Z_END:   coverpoint ad_end    { bins partial = {E_PARTIAL}; bins full_last = {E_FULL_LAST};
                                        bins split = {E_SPLIT}; }
        MSG_CLS: coverpoint msg_cls;
        Z_X_MSG: cross Z_CLS, MSG_CLS;
    endgroup

    covergroup cg_flow;
        option.per_instance = 1;
        MODE:        coverpoint mode  { bins m [5] = {[0:4]}; }
        IN_WAIT:     coverpoint in_waited;
        OUT_STALL:   coverpoint out_stalled;
        POKED:       coverpoint poked;
        B2B:         coverpoint b2b;
        OUT_PENDING: coverpoint out_pending;
        MODE_X_IN_WAIT:   cross MODE, IN_WAIT;
        MODE_X_OUT_STALL: cross MODE, OUT_STALL;
        MODE_X_POKED:     cross MODE, POKED;
        MODE_X_B2B:       cross MODE, B2B;
    endgroup

    // the plain table: name of every bin -> times hit
    int unsigned hits [string];

    function void need(string name);
        hits[name] = 0;
    endfunction

    function void hit(string name);
        if (!hits.exists(name))
            `uvm_error("COV", $sformatf("bin %s is not in the table", name))
        else
            hits[name]++;
    endfunction

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_aead    = new();
        cg_decrypt = new();
        cg_hash    = new();
        cg_xof     = new();
        cg_cxof    = new();
        cg_flow    = new();

        // the same bins as the covergroups above, by name
        for (int d = 0; d < 2; d++) begin
            for (int a = 0; a < 5; a++)
                for (int m = 0; m < 5; m++) need($sformatf("aead.dir%0d.ad%0d.msg%0d", d, a, m));
            for (int e = 0; e < 4; e++) begin
                need($sformatf("aead.dir%0d.ad_end%0d", d, e));
                need($sformatf("aead.dir%0d.msg_end%0d", d, e));
            end
            for (int p = 0; p < 16; p++) need($sformatf("aead.dir%0d.msg_tail%0d", d, p));
        end
        for (int p = 0; p < 16; p++) need($sformatf("aead.ad_tail%0d", p));
        for (int v = 0; v < 2; v++)
            for (int c = 0; c < 5; c++) begin
                need($sformatf("dec.verdict%0d.ad%0d", v, c));
                need($sformatf("dec.verdict%0d.msg%0d", v, c));
            end
        for (int h = `ASCON_HASH; h <= `ASCON_CXOF; h++) begin
            for (int m = 0; m < 5; m++) need($sformatf("hash.mode%0d.msg%0d", h, m));
            for (int e = 0; e < 4; e++) need($sformatf("hash.mode%0d.msg_end%0d", h, e));
        end
        for (int p = 0; p < 8; p++) need($sformatf("hash.msg_tail%0d", p));
        for (int x = `ASCON_XOF; x <= `ASCON_CXOF; x++)
            for (int o = 0; o < 5; o++) need($sformatf("xof.mode%0d.out%0d", x, o));
        for (int p = 0; p < 8; p++) need($sformatf("xof.out_tail%0d", p));
        for (int z = 0; z < 5; z++)
            for (int m = 0; m < 5; m++) need($sformatf("cxof.z%0d.msg%0d", z, m));
        for (int e = 1; e < 4; e++) need($sformatf("cxof.z_end%0d", e));
        for (int m = 0; m < 5; m++)
            for (int f = 0; f < 2; f++) begin
                need($sformatf("flow.mode%0d.in_wait%0d", m, f));
                need($sformatf("flow.mode%0d.out_stall%0d", m, f));
                need($sformatf("flow.mode%0d.poked%0d", m, f));
                need($sformatf("flow.mode%0d.b2b%0d", m, f));
            end
        need("flow.out_pending0");
        need("flow.out_pending1");
    endfunction

    function len_e len_class(int unsigned len, int unsigned rate);
        if (len == 0)        return L_ZERO;
        if (len <  rate)     return L_PART;
        if (len == rate)     return L_ONE;
        if (len % rate != 0) return L_MULTI_PART;
        return L_MULTI_FULL;
    endfunction

    // len = bytes in the stream as it went over the pins
    function end_e end_class(int unsigned len, int unsigned rate, bit last_full);
        if (len == 0)        return E_EMPTY;
        if (last_full)       return E_FULL_LAST;
        if (len % rate != 0) return E_PARTIAL;
        return E_SPLIT;
    endfunction

    function void write(ascon_xtn t);
        int unsigned rate = t.rate();

        mode        = t.mode;
        dir         = (t.mode == `ASCON_DEC);
        ad_cls      = len_class(t.ad.size(), rate);
        msg_cls     = len_class(t.msg.size(), rate);
        out_cls     = len_class(t.out.size(), 8);
        // for CXOF the stream on the pins is 8 bytes longer than the string: same length
        // modulo 8, and never empty
        ad_end      = end_class(t.mode == `ASCON_CXOF ? t.ad.size() + 8 : t.ad.size(), rate,
                                t.ad_last_full);
        msg_end     = end_class(t.msg.size(), rate, t.msg_last_full);
        ad_tail     = t.ad.size()  % rate;
        msg_tail    = t.msg.size() % rate;
        out_tail    = t.out.size() % 8;
        verdict     = t.tag_ok;
        in_waited   = (t.in_wait != 0);
        out_stalled = t.out_stalled;
        poked       = t.poked;
        b2b         = t.b2b;
        out_pending = t.out_pending;

        if (t.is_aead()) begin
            cg_aead.sample();
            hit($sformatf("aead.dir%0d.ad%0d.msg%0d", dir, ad_cls, msg_cls));
            hit($sformatf("aead.dir%0d.ad_end%0d", dir, ad_end));
            hit($sformatf("aead.dir%0d.msg_end%0d", dir, msg_end));
            hit($sformatf("aead.dir%0d.msg_tail%0d", dir, msg_tail));
            hit($sformatf("aead.ad_tail%0d", ad_tail));
            if (dir) begin
                cg_decrypt.sample();
                hit($sformatf("dec.verdict%0d.ad%0d", verdict, ad_cls));
                hit($sformatf("dec.verdict%0d.msg%0d", verdict, msg_cls));
            end
        end else begin
            cg_hash.sample();
            hit($sformatf("hash.mode%0d.msg%0d", mode, msg_cls));
            hit($sformatf("hash.mode%0d.msg_end%0d", mode, msg_end));
            hit($sformatf("hash.msg_tail%0d", msg_tail));
            if (t.mode != `ASCON_HASH) begin
                cg_xof.sample();
                hit($sformatf("xof.mode%0d.out%0d", mode, out_cls));
                hit($sformatf("xof.out_tail%0d", out_tail));
            end
            if (t.mode == `ASCON_CXOF) begin
                cg_cxof.sample();
                hit($sformatf("cxof.z%0d.msg%0d", ad_cls, msg_cls));
                hit($sformatf("cxof.z_end%0d", ad_end));
            end
        end

        cg_flow.sample();
        hit($sformatf("flow.mode%0d.in_wait%0d", mode, in_waited));
        hit($sformatf("flow.mode%0d.out_stall%0d", mode, out_stalled));
        hit($sformatf("flow.mode%0d.poked%0d", mode, poked));
        hit($sformatf("flow.mode%0d.b2b%0d", mode, b2b));
        hit($sformatf("flow.out_pending%0d", out_pending));
    endfunction

    function void report_phase(uvm_phase phase);
        int unsigned total, covered;
        string       holes = "";

        foreach (hits[name]) begin
            total++;
            if (hits[name] != 0) covered++;
            else holes = {holes, " ", name};
        end
        `uvm_info("COV", $sformatf("bins hit: %0d of %0d", covered, total), UVM_LOW)
        if (covered != total)
            `uvm_info("COV", {"not hit:", holes}, UVM_LOW)
`ifndef VERILATOR
        `uvm_info("COV", $sformatf("covergroups: aead %.1f%%  decrypt %.1f%%  hash %.1f%%  xof %.1f%%  cxof %.1f%%  flow %.1f%%",
                  cg_aead.get_inst_coverage(), cg_decrypt.get_inst_coverage(),
                  cg_hash.get_inst_coverage(), cg_xof.get_inst_coverage(),
                  cg_cxof.get_inst_coverage(), cg_flow.get_inst_coverage()), UVM_LOW)
`endif
    endfunction

endclass
