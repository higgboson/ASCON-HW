// ascon_env.sv - agent, scoreboard and coverage for the Ascon core
//
//   sequence -> ascon_agent.drv -> pins -> ascon_core
//                                   |
//              ascon_agent.mon <----+   (watches the pins)
//                    | operations
//           +--------+---------+
//           v                  v
//        ascon_sb        ascon_coverage
//           |
//     C reference model (DPI)

class ascon_env extends uvm_env;
    `uvm_component_utils(ascon_env)

    ascon_agent    agt;
    ascon_sb       sb;
    ascon_coverage cov;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        agt = ascon_agent::type_id::create("agt", this);
        sb  = ascon_sb::type_id::create("sb", this);
        cov = ascon_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        agt.mon.ap.connect(sb.imp);
        agt.mon.ap.connect(cov.analysis_export);
    endfunction

    // Every operation the driver started must have reached the scoreboard, except the
    // ones a reset cut off. A monitor that silently loses operations would make any test pass.
    function void check_phase(uvm_phase phase);
        if (agt.get_is_active() == UVM_ACTIVE && agt.drv.ops != sb.total() + agt.mon.dropped)
            `uvm_error("ENV", $sformatf("%0d operations driven, but %0d checked and %0d cut off by reset",
                       agt.drv.ops, sb.total(), agt.mon.dropped))
        else
            `uvm_info("ENV", $sformatf("%0d operations driven = %0d checked + %0d cut off by reset",
                      agt.drv.ops, sb.total(), agt.mon.dropped), UVM_LOW)
    endfunction

endclass
