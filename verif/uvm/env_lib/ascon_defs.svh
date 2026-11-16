// ascon_defs.svh - constants shared by the interface and the testbench classes

`ifndef ASCON_DEFS_SVH
`define ASCON_DEFS_SVH

// modes of ascon_core (rtl/ascon_core.v)
`define ASCON_ENC   3'd0
`define ASCON_DEC   3'd1
`define ASCON_HASH  3'd2
`define ASCON_XOF   3'd3
`define ASCON_CXOF  3'd4

// longest stream the testbench sends or collects, in bytes (ref/ascon_dpi.c uses the same)
`define ASCON_MAXB  256

`endif
