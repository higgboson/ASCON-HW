// ascon_test_lib.sv - the tests. Pick one with +UVM_TESTNAME=<name> (see sim/Makefile).
//
//   ascon_rand_test     random operations, default mix of modes, lengths and stalls
//   ascon_corner_test   every length around the block boundaries, exact cycle counts
//   ascon_tamper_test   decrypts with one bit damaged: all must be rejected
//   ascon_b2b_test      back-to-back operations, nothing stalls
//   ascon_stall_test    slow input and slow output
//   ascon_poke_test     a second start during every operation, which must be ignored
//   ascon_reset_test    reset in the middle of every second operation
//   ascon_full_test     all of the above in one run, for coverage closure
//
// Number of operations per sequence: +NOPS=<n> (default 200).

class ascon_base_test extends uvm_test;
    `uvm_component_utils(ascon_base_test)

    ascon_env    env;
    int unsigned n_ops = 200;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        void'($value$plusargs("NOPS=%d", n_ops));
        env = ascon_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
        uvm_root::get().print_topology();
    endfunction

    // start one sequence on the agent
    task run_seq(ascon_base_seq seq);
        seq.n_ops = n_ops;
        seq.start(env.agt.seqr);
    endtask

    virtual task run_seqs();
        run_seq(ascon_rand_seq::type_id::create("rand_seq"));
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        run_seqs();
        env.agt.drv.drain();               // the last operation ends, its output is taken
        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server svr = uvm_report_server::get_server();
        int errors = svr.get_severity_count(UVM_ERROR) + svr.get_severity_count(UVM_FATAL);
        if (errors == 0)
            `uvm_info("RESULT", $sformatf("TEST PASSED: %s", get_type_name()), UVM_NONE)
        else
            `uvm_info("RESULT", $sformatf("TEST FAILED: %s (%0d errors)", get_type_name(), errors), UVM_NONE)
    endfunction

endclass

class ascon_rand_test extends ascon_base_test;
    `uvm_component_utils(ascon_rand_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

class ascon_corner_test extends ascon_base_test;
    `uvm_component_utils(ascon_corner_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
        run_seq(ascon_corner_seq::type_id::create("corner_seq"));
    endtask
endclass

class ascon_tamper_test extends ascon_base_test;
    `uvm_component_utils(ascon_tamper_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
        run_seq(ascon_tamper_seq::type_id::create("tamper_seq"));
    endtask
endclass

class ascon_b2b_test extends ascon_base_test;
    `uvm_component_utils(ascon_b2b_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
        run_seq(ascon_b2b_seq::type_id::create("b2b_seq"));
    endtask
endclass

class ascon_stall_test extends ascon_base_test;
    `uvm_component_utils(ascon_stall_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
        run_seq(ascon_stall_seq::type_id::create("stall_seq"));
    endtask
endclass

class ascon_poke_test extends ascon_base_test;
    `uvm_component_utils(ascon_poke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
        run_seq(ascon_poke_seq::type_id::create("poke_seq"));
    endtask
endclass

class ascon_reset_test extends ascon_base_test;
    `uvm_component_utils(ascon_reset_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
        run_seq(ascon_reset_seq::type_id::create("reset_seq"));
    endtask
endclass

class ascon_full_test extends ascon_base_test;
    `uvm_component_utils(ascon_full_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
        run_seq(ascon_corner_seq::type_id::create("corner_seq"));
        run_seq(ascon_rand_seq::type_id::create("rand_seq"));
        run_seq(ascon_tamper_seq::type_id::create("tamper_seq"));
        run_seq(ascon_b2b_seq::type_id::create("b2b_seq"));
        run_seq(ascon_stall_seq::type_id::create("stall_seq"));
        run_seq(ascon_poke_seq::type_id::create("poke_seq"));
        run_seq(ascon_reset_seq::type_id::create("reset_seq"));
    endtask
endclass
