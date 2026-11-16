// ascon_pkg.sv - the class-based testbench, in dependency order

package ascon_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    `include "ascon_defs.svh"
    `include "ascon_ref_dpi.svh"
    `include "ascon_xtn.sv"
    `include "ascon_agent.sv"
    `include "ascon_sb.sv"
    `include "ascon_coverage.sv"
    `include "ascon_seqs.sv"
    `include "ascon_env.sv"
    `include "ascon_test_lib.sv"

endpackage
