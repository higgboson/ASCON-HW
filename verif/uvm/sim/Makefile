# Makefile - UVM verification of the Ascon core with Cadence Xcelium + IMC
#
#   make compile                      compile and elaborate once
#   make run TEST=ascon_corner_test   run one test (SEED=, NOPS=, VERB= optional)
#   make gui TEST=ascon_rand_test     same, with SimVision waveforms
#   make regress                      every test in regress.list, then a pass / fail summary
#   make cov_merge cov_report         merge all coverage runs, write reports/ (IMC)
#   make cov_gui                      open the merged coverage in IMC
#   make clean
#
# RPC=1 (default), 2 or 4: rounds per clock cycle of the core under test. Each value is
# a different circuit, so each gets its own compiled snapshot and its own coverage scope:
#   make regress RPC=4  &&  make cov_merge cov_report RPC=4
#
# UVMHOME: CDNS-1.2 (UVM 1.2, default) or CDNS-IEEE (IEEE 1800.2), both ship with Xcelium.

TEST    ?= ascon_rand_test
SEED    ?= 1
NOPS    ?= 200
VERB    ?= UVM_LOW
RPC     ?= 1
UVMHOME ?= CDNS-1.2

LIB   = xcelium_rpc$(RPC).d
SCOPE = rpc$(RPC)

# ref.f: the C reference model. xrun compiles it and links it in for the DPI calls.
# -coverage all: code coverage (block, expression, toggle, FSM) on the DUT, functional
# coverage (covergroups) and assertion coverage; -covdut top keeps the DUT and the
# interface (its SVA lives there)
COMPILE_OPTS = -64bit -sv -uvm -uvmhome $(UVMHOME) -timescale 1ns/1ps -access +rwc \
               -xmlibdirname $(LIB) -define ASCON_RPC=$(RPC) \
               -f rtl.f -f tb.f -f ref.f -top top \
               -coverage all -covdut top

RUN_OPTS = -R -64bit -xmlibdirname $(LIB) +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) \
           +NOPS=$(NOPS) -svseed $(SEED) -covworkdir cov_work -covscope $(SCOPE) \
           -covtest $(TEST)_s$(SEED) -covoverwrite

.PHONY: help compile run gui regress cov_merge cov_report cov_gui clean

help:
	@sed -n '3,15p' Makefile

compile:
	mkdir -p logs
	xrun -elaborate $(COMPILE_OPTS) -l logs/compile_rpc$(RPC).log

run: compile
	xrun $(RUN_OPTS) -l logs/$(TEST)_s$(SEED).log
	@grep -E "TEST (PASSED|FAILED)" logs/$(TEST)_s$(SEED).log || echo "no result line: check logs/$(TEST)_s$(SEED).log"

gui: compile
	xrun $(RUN_OPTS) -gui -l logs/$(TEST)_s$(SEED)_gui.log

# regress.list: one "test seed nops" per line
regress: compile
	@rm -f logs/regress_summary.txt
	@while read t s n; do \
	    case "$$t" in ""|\#*) continue ;; esac; \
	    echo "== $$t seed $$s"; \
	    xrun -R -64bit -xmlibdirname $(LIB) +UVM_TESTNAME=$$t +UVM_VERBOSITY=UVM_LOW +NOPS=$$n -svseed $$s \
	         -covworkdir cov_work -covscope $(SCOPE) -covtest $${t}_s$$s -covoverwrite \
	         -l logs/$${t}_s$$s.log > /dev/null; \
	    r=$$(grep -hoE "TEST (PASSED|FAILED)" logs/$${t}_s$$s.log | head -1); \
	    printf "%-22s seed %-10s %s\n" "$$t" "$$s" "$${r:-NO RESULT (crash?)}" | tee -a logs/regress_summary.txt; \
	done < regress.list
	@echo; echo "passed: $$(grep -c PASSED logs/regress_summary.txt)  failed: $$(grep -vc PASSED logs/regress_summary.txt)"

cov_merge:
	SCOPE=$(SCOPE) imc -exec imc_merge.tcl -nocopyright

cov_report:
	mkdir -p reports
	SCOPE=$(SCOPE) imc -exec imc_report.tcl -nocopyright
	@echo "reports written to reports/"

cov_gui:
	imc -load cov_work/scope/merged &

clean:
	rm -rf xcelium*.d xrun.* cov_work logs reports waves.shm .simvision *.history *.log *.key INCA_libs obj_vl* obj_ref
