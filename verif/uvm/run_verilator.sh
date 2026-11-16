#!/bin/bash
# run_verilator.sh - run the UVM environment on the free Verilator simulator (5.036 or newer)
# Use it when Xcelium is not available (laptop, GitHub Actions). No coverage database here,
# but the testbench prints its own table of functional bins (see ascon_coverage.sv).
#
#   UVM_HOME=/path/to/uvm-core/src ./run_verilator.sh ascon_full_test
#   UVM_HOME=/path/to/uvm-core/src ./run_verilator.sh ascon_rand_test +NOPS=500 +verilator+seed+7
#   UVM_HOME=/path/to/uvm-core/src ./run_verilator.sh regress        every line of sim/regress.list
#   RPC=4 ...                        the core with 4 rounds per clock cycle (1, 2 or 4)
#   NOBUILD=1 ...                    reuse the last build
#
# uvm-core: git clone https://github.com/accellera-official/uvm-core
# Random constraints need the z3 solver on the PATH (apt install z3).
set -e
TEST=$1; shift
RPC=${RPC:-1}
cd "$(dirname "$0")/sim"
mkdir -p obj_ref logs

if [ -z "$NOBUILD" ]; then
    # The reference model is C, and Verilator would compile it as C++: build it with gcc first
    for f in ascon_dpi ref_aead128 ref_hash256 ref_xof128 ref_cxof128; do
        gcc -O2 -c ../../../ref/$f.c -o obj_ref/$f.o
    done
    # UVM_NO_DPI: the UVM library's own C helpers are not compiled in this flow
    verilator --binary --timing --assert -j 0 --Mdir obj_vl_rpc$RPC -Wno-fatal -Wno-lint -Wno-style \
        -Wno-COVERIGN +define+UVM_NO_DPI +define+UVM_REGEX_NO_DPI +define+ASCON_RPC=$RPC \
        --timescale 1ns/1ps +incdir+$UVM_HOME $UVM_HOME/uvm_pkg.sv -f rtl.f -f tb.f \
        $PWD/obj_ref/*.o --top-module top > logs/vl_build_rpc$RPC.log 2>&1 \
        || { grep -A5 "%Error" logs/vl_build_rpc$RPC.log; exit 1; }
fi

# one test: full log in logs/, the lines that matter on the screen
run_one() {
    local t=$1 log=$2; shift 2
    ./obj_vl_rpc$RPC/Vtop +UVM_TESTNAME=$t +UVM_NO_RELNOTES "$@" > $log 2>&1 || true
}

if [ "$TEST" = regress ]; then
    rm -f logs/vl_regress_summary_rpc$RPC.txt
    while read t s n; do
        case "$t" in ""|\#*) continue ;; esac
        log=logs/vl_${t}_s${s}_rpc$RPC.log
        run_one $t $log +NOPS=$n +verilator+seed+$s
        r=$(grep -hoE "TEST (PASSED|FAILED)" $log | head -1)
        ops=$(grep -hoE "\[SB\] checked [0-9]+" $log | grep -oE "[0-9]+$")
        printf "%-20s seed %-4s %6s operations checked   %s\n" "$t" "$s" "$ops" "${r:-NO RESULT (crash?)}" \
            | tee -a logs/vl_regress_summary_rpc$RPC.txt
    done < regress.list
    echo
    echo "passed: $(grep -c PASSED logs/vl_regress_summary_rpc$RPC.txt)  failed: $(grep -vc PASSED logs/vl_regress_summary_rpc$RPC.txt)"
else
    log=logs/vl_${TEST}_rpc$RPC.log
    run_one $TEST $log "$@"
    grep -E "^UVM_(ERROR|FATAL) [^:]|\[(SB|COV|DRV|ENV|RESULT)\] " $log | cut -c1-400 | head -40
fi
