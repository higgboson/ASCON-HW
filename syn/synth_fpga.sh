#!/bin/bash
# synth_fpga.sh - resource estimate for a Xilinx 7-series FPGA (Basys 3 = Artix-7) with Yosys
#
#   ./synth_fpga.sh          RPC = 1, 2 and 4, one after the other
#   ./synth_fpga.sh 2        only RPC = 2
#   TOP=ascon_core ./synth_fpga.sh     the core without the register wrapper
#
# This counts LUTs and flip-flops only. For the real clock speed run Vivado:
# place and route decides the wire delays, which Yosys does not know.
set -e
cd "$(dirname "$0")"
RTL=${RTL:-../rtl}
TOP=${TOP:-ascon_mmio}
mkdir -p logs
for rpc in ${@:-1 2 4}; do
    yosys -q -l logs/fpga_${TOP}_rpc$rpc.log -p "
        read_verilog $RTL/ascon_round.v $RTL/ascon_core.v $RTL/ascon_mmio.v
        chparam -set RPC $rpc $TOP
        synth_xilinx -top $TOP -family xc7 -flatten
        stat" > /dev/null 2>&1
    # the log holds several cell tables: count in the last one only
    last=$(awk '/[Nn]umber of cells|^ +[0-9]+ +cells$/ {n = NR} END {print n}' logs/fpga_${TOP}_rpc$rpc.log)
    luts=$(tail -n +$last logs/fpga_${TOP}_rpc$rpc.log | grep -E "^\s+[0-9]+ +LUT[1-6]" | awk '{s+=$1} END {print s}')
    ffs=$(tail -n +$last logs/fpga_${TOP}_rpc$rpc.log | grep -E "^\s+[0-9]+ +FD[A-Z]+" | awk '{s+=$1} END {print s}')
    echo "$TOP RPC=$rpc: $luts LUTs, $ffs flip-flops"
done
