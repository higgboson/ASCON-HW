// ascon_agent.sv - sequencer, driver and monitor for ascon_core
//
// The driver plays the part of whatever uses the core: it starts an operation, feeds the
// input streams beat by beat and takes the output, stalling both sides as the item asks.
// The monitor only watches the pins and rebuilds each operation from them, so the
// scoreboard checks what really happened, not what the driver meant to do.

typedef uvm_sequencer #(ascon_xtn) ascon_sequencer;

class ascon_driver extends uvm_driver #(ascon_xtn);
    `uvm_component_utils(ascon_driver)

    virtual ascon_if vif;
    int unsigned ops, kills;
    int unsigned out_stall;             // % of cycles the output side refuses a beat
    int unsigned beat;                  // input beats sent in the current operation
    bit          killed, poke_done;
    bit          running;            // input sent, done not seen yet

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db #(virtual ascon_if)::get(this, "", "vif", vif))
            `uvm_fatal("CFG", "no ascon_if in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        vif.drv_cb.start      <= 1'b0;
        vif.drv_cb.din_valid  <= 1'b0;
        vif.drv_cb.dout_ready <= 1'b0;
        vif.drv_cb.mode       <= '0;
        vif.drv_cb.key        <= '0;
        vif.drv_cb.nonce      <= '0;
        vif.drv_cb.tag_in     <= '0;
        vif.drv_cb.out_len    <= '0;
        vif.drv_cb.din_data   <= '0;
        vif.drv_cb.din_bytes  <= '0;
        vif.drv_cb.din_last   <= 1'b0;
        do_reset(4);

        fork
            take_output();
        join_none

        forever begin
            seq_item_port.get_next_item(req);
            // get_next_item can return anywhere inside a time step. Clocking-block drives
            // are only safe right after a clock edge, so get back in step with the clock.
            @(vif.drv_cb);
            wait_done();
            drive_op(req);
            seq_item_port.item_done();
            ops++;
        end
    endtask

    // Wait until the operation whose input has been sent has finished. The next item is
    // fetched while the core is still working on the previous one (see run_phase), which is
    // what makes a start in the very next cycle after done possible.
    task wait_done();
        int unsigned guard;
        while (running && !vif.drv_cb.done) begin
            @(vif.drv_cb);
            if (++guard > 20000)
                `uvm_fatal("DRV", "the core never raised done")
        end
        running = 0;
    endtask

    // called by the test when its sequences are over: let the last operation finish and
    // its output be taken
    task drain();
        @(vif.drv_cb);
        wait_done();
        out_stall = 0;
        repeat (4) @(vif.drv_cb);
    endtask

    task do_reset(int unsigned n);
        vif.drv_cb.reset     <= 1'b1;
        vif.drv_cb.start     <= 1'b0;
        vif.drv_cb.din_valid <= 1'b0;
        repeat (n) @(vif.drv_cb);
        vif.drv_cb.reset <= 1'b0;
        @(vif.drv_cb);
    endtask

    // the output side: ready or not, decided again every cycle
    task take_output();
        forever begin
            vif.drv_cb.dout_ready <= ($urandom_range(99) >= out_stall);
            @(vif.drv_cb);
        end
    endtask

    task pulse_start(bit [2:0] mode, bit [127:0] key, bit [127:0] nonce, bit [31:0] out_len);
        vif.drv_cb.start   <= 1'b1;
        vif.drv_cb.mode    <= mode;
        vif.drv_cb.key     <= key;
        vif.drv_cb.nonce   <= nonce;
        vif.drv_cb.out_len <= out_len;
        @(vif.drv_cb);
        vif.drv_cb.start   <= 1'b0;
    endtask

    // Send one stream as beats of up to `rate` bytes. A stream that ends exactly on a full
    // block can finish in two legal ways (see ascon_xtn.ad_split).
    task send_stream(ascon_xtn t, byte unsigned data [$], int rate, bit split, bit final_stream);
        int         pos, nb;
        bit         last, now;
        bit [127:0] d;
        int unsigned guard;

        while (!last) begin
            nb = data.size() - pos;
            if (nb > rate) nb = rate;
            if (nb < rate) last = 1;
            else           last = (pos + nb == data.size()) && !split;

            // The core is waiting for this beat, so it cannot finish under us: a safe moment
            // to try a second start (must be ignored) or to pull reset. If the operation has
            // fewer beats than kill_at / poke_at, do it before the very last beat.
            now = final_stream && last;
            if (t.kill && (beat == t.kill_at || now)) begin
                do_reset(2);
                killed = 1;
                return;
            end
            if (t.poke && !poke_done && (beat == t.poke_at || now)) begin
                pulse_start(3'($urandom_range(4)), {$urandom, $urandom, $urandom, $urandom},
                            {$urandom, $urandom, $urandom, $urandom}, $urandom_range(40));
                poke_done = 1;
            end

            while ($urandom_range(99) < t.in_stall)
                @(vif.drv_cb);

            // unused bytes of a beat are random: the core must ignore them
            d = {$urandom, $urandom, $urandom, $urandom};
            for (int i = 0; i < nb; i++)
                d[8*i +: 8] = data[pos + i];

            vif.drv_cb.din_valid <= 1'b1;
            vif.drv_cb.din_data  <= d;
            vif.drv_cb.din_bytes <= 5'(nb);
            vif.drv_cb.din_last  <= last;
            guard = 0;
            @(vif.drv_cb);
            while (!vif.drv_cb.din_ready) begin
                @(vif.drv_cb);
                if (++guard > 20000)
                    `uvm_fatal("DRV", "the core never took an input beat")
            end
            vif.drv_cb.din_valid <= 1'b0;
            `uvm_info("DRV", $sformatf("  beat %0d: %0d bytes%s", beat, nb, last ? ", last" : ""), UVM_DEBUG)
            pos += nb;
            beat++;
        end
    endtask

    // start the operation and send its input; the end is awaited by wait_done()
    task drive_op(ascon_xtn t);
        byte unsigned first [$];

        repeat (t.gap) @(vif.drv_cb);
        while (!vif.drv_cb.ready) @(vif.drv_cb);

        out_stall = t.out_stall;
        beat      = 0;
        killed    = 0;
        poke_done = 0;
        vif.drv_cb.tag_in <= t.tag_in;
        `uvm_info("DRV", $sformatf("start: mode %0d, ad %0d bytes, msg %0d bytes", t.mode, t.ad.size(),
                  t.msg.size()), UVM_DEBUG)
        pulse_start(t.mode, t.key, t.nonce, t.out_len);

        if (t.is_aead())
            send_stream(t, t.ad, 16, t.ad_split, 0);
        else if (t.mode == `ASCON_CXOF) begin
            // CXOF: the bit length of the customization string (8 bytes, low byte first)
            // goes in front of the string, as one stream
            bit [63:0] bits = 64'(t.ad.size()) * 8;
            for (int i = 0; i < 8; i++) first.push_back(bits[8*i +: 8]);
            foreach (t.ad[i]) first.push_back(t.ad[i]);
            send_stream(t, first, 8, t.ad_split, 0);
        end
        if (!killed)
            send_stream(t, t.msg, t.rate(), t.msg_split, 1);

        if (killed) kills++;
        else        running = 1;
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info("DRV", $sformatf("%0d operations driven, %0d of them cut short by reset", ops, kills),
                  UVM_LOW)
    endfunction

endclass

class ascon_monitor extends uvm_monitor;
    `uvm_component_utils(ascon_monitor)

    virtual ascon_if vif;
    uvm_analysis_port #(ascon_xtn) ap;
    int unsigned dropped;               // operations a reset cut off before they finished

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db #(virtual ascon_if)::get(this, "", "vif", vif))
            `uvm_fatal("CFG", "no ascon_if in config_db")
    endfunction

    // has the operation given all the output it owes?
    function bit out_complete(ascon_xtn t);
        if (t.is_aead())            return t.out_beats == t.msg_beats;
        if (t.mode == `ASCON_HASH)  return t.out.size() == 32;
        return t.out.size() == t.out_len;
    endfunction

    task run_phase(uvm_phase phase);
        // An operation can start while the last output beat of the one before is still
        // waiting to be taken, so up to two are in flight: input and done belong to the
        // newest (cur), output beats to the oldest (pend[0]).
        ascon_xtn    pend [$];
        ascon_xtn    cur;
        bit          in_msg;            // the next input beat belongs to the message stream
        int unsigned since_done = 1000;
        int unsigned n;

        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.reset) begin
                dropped += pend.size();
                pend.delete();
                cur = null;
                since_done = 1000;
                continue;
            end

            if (cur != null && !cur.done_seen) begin
                cur.cycles++;
                if (vif.mon_cb.din_ready && !vif.mon_cb.din_valid) cur.in_wait++;
            end
            if (vif.mon_cb.dout_valid && !vif.mon_cb.dout_ready)
                foreach (pend[i]) pend[i].out_stalled = 1;

            if (vif.mon_cb.start) begin
                if (vif.mon_cb.ready) begin
                    cur = ascon_xtn::type_id::create("mon_xtn");
                    cur.mode        = vif.mon_cb.mode;
                    cur.key         = vif.mon_cb.key;
                    cur.nonce       = vif.mon_cb.nonce;
                    cur.out_len     = vif.mon_cb.out_len;
                    cur.b2b         = (since_done == 0);
                    cur.out_pending = vif.mon_cb.dout_valid;
                    in_msg = (cur.mode == `ASCON_HASH || cur.mode == `ASCON_XOF);
                    pend.push_back(cur);
                end
                else if (cur != null)
                    cur.poked = 1;
            end

            if (vif.mon_cb.din_valid && vif.mon_cb.din_ready && cur != null) begin
                n = vif.mon_cb.din_bytes;
                for (int i = 0; i < n; i++)
                    if (in_msg) cur.msg.push_back(vif.mon_cb.din_data[8*i +: 8]);
                    else        cur.ad.push_back(vif.mon_cb.din_data[8*i +: 8]);
                if (in_msg) begin
                    cur.msg_beats++;
                    if (vif.mon_cb.din_last) cur.msg_last_full = (n == cur.rate());
                end else begin
                    cur.ad_beats++;
                    if (vif.mon_cb.din_last) begin
                        cur.ad_last_full = (n == cur.rate());
                        cur.ad_skipped   = cur.is_aead() && cur.ad.size() == 0;
                        in_msg = 1;
                    end
                end
            end

            if (vif.mon_cb.dout_valid && vif.mon_cb.dout_ready && pend.size() > 0) begin
                n = vif.mon_cb.dout_bytes;
                for (int i = 0; i < n; i++)
                    pend[0].out.push_back(vif.mon_cb.dout_data[8*i +: 8]);
                pend[0].out_beats++;
            end

            if (vif.mon_cb.done && cur != null) begin
                cur.done_seen = 1;
                cur.tag       = vif.mon_cb.tag;
                cur.tag_ok    = vif.mon_cb.tag_ok;
                cur.tag_in    = vif.mon_cb.tag_in;
                since_done    = 0;
            end else if (since_done < 1000)
                since_done++;

            while (pend.size() > 0 && pend[0].done_seen && out_complete(pend[0])) begin
                ascon_xtn t = pend.pop_front();
                finish(t);
                ap.write(t);
            end
        end
    endtask

    // tidy up the lengths; for CXOF take the length word off the front of the first stream
    function void finish(ascon_xtn t);
        if (t.mode == `ASCON_CXOF) begin
            for (int i = 0; i < 8 && t.ad.size() > 0; i++)
                t.cx_bits[8*i +: 8] = t.ad.pop_front();
        end
        t.ad_len  = t.ad.size();
        t.msg_len = t.msg.size();
        `uvm_info("MON", $sformatf("mode %0d: ad %0d, msg %0d, out %0d bytes, %0d cycles",
                  t.mode, t.ad_len, t.msg_len, t.out.size(), t.cycles), UVM_HIGH)
    endfunction

endclass

class ascon_agent extends uvm_agent;
    `uvm_component_utils(ascon_agent)

    ascon_sequencer seqr;
    ascon_driver    drv;
    ascon_monitor   mon;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        mon = ascon_monitor::type_id::create("mon", this);
        if (get_is_active() == UVM_ACTIVE) begin
            seqr = ascon_sequencer::type_id::create("seqr", this);
            drv  = ascon_driver::type_id::create("drv", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        if (get_is_active() == UVM_ACTIVE)
            drv.seq_item_port.connect(seqr.seq_item_export);
    endfunction

endclass
