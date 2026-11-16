# Makefile - quick checks with free tools (Verilator 5 or Icarus Verilog), no UVM needed
#
#   make kat                 all 4,228 official NIST SP 800-232 test vectors on the core
#   make kat RPC=4           the same with 4 rounds per clock cycle (RPC = 1, 2 or 4)
#   make mmio                the register wrapper, driven like the C driver drives it
#   make ref                 the C reference model against its own known answers
#   make all                 kat for RPC = 1, 2, 4, then mmio and ref
#   make lint                Verilator lint of the RTL
#   make kat SIM=iverilog    use Icarus Verilog instead of Verilator (slower)
#   make clean
#
# The UVM environment is in uvm/ (Xcelium: uvm/sim/Makefile, Verilator: uvm/run_verilator.sh).

SIM ?= verilator
RPC ?= 1
RTL  = ../rtl/ascon_round.v ../rtl/ascon_core.v
WORK = work

.PHONY: kat mmio ref all lint clean

$(WORK)/vectors.txt: gen_vectors.py $(wildcard ../kat/*.txt)
	@mkdir -p $(WORK)
	python3 gen_vectors.py ../kat $@

kat: $(WORK)/vectors.txt
ifeq ($(SIM),iverilog)
	iverilog -g2012 -Ptb_kat.RPC=$(RPC) -o $(WORK)/kat_rpc$(RPC) tb_kat.sv $(RTL)
	vvp -n $(WORK)/kat_rpc$(RPC) +VEC=$(WORK)/vectors.txt
else
	verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -GRPC=$(RPC) \
	    --Mdir $(WORK)/obj_kat_rpc$(RPC) tb_kat.sv $(RTL) --top-module tb_kat > $(WORK)/build_kat.log 2>&1 \
	    || (cat $(WORK)/build_kat.log; false)
	$(WORK)/obj_kat_rpc$(RPC)/Vtb_kat +VEC=$(WORK)/vectors.txt
endif

mmio: $(WORK)/vectors.txt
ifeq ($(SIM),iverilog)
	iverilog -g2012 -Ptb_mmio.RPC=$(RPC) -o $(WORK)/mmio_rpc$(RPC) tb_mmio.sv ../rtl/ascon_mmio.v $(RTL)
	vvp -n $(WORK)/mmio_rpc$(RPC) +VEC=$(WORK)/vectors.txt
else
	verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -GRPC=$(RPC) \
	    --Mdir $(WORK)/obj_mmio_rpc$(RPC) tb_mmio.sv ../rtl/ascon_mmio.v $(RTL) --top-module tb_mmio \
	    > $(WORK)/build_mmio.log 2>&1 || (cat $(WORK)/build_mmio.log; false)
	$(WORK)/obj_mmio_rpc$(RPC)/Vtb_mmio +VEC=$(WORK)/vectors.txt
endif

ref:
	@mkdir -p $(WORK)
	gcc -O2 -Wall -o $(WORK)/selftest ../ref/selftest.c ../ref/ascon_dpi.c ../ref/ref_*.c
	$(WORK)/selftest

all:
	$(MAKE) kat RPC=1
	$(MAKE) kat RPC=2
	$(MAKE) kat RPC=4
	$(MAKE) mmio
	$(MAKE) ref

# UNUSEDSIGNAL is off: the wrapper decodes only bits 7:2 of the bus address
lint:
	verilator --lint-only -Wall -Wno-UNUSEDSIGNAL ../rtl/ascon_mmio.v $(RTL) --top-module ascon_mmio

clean:
	rm -rf $(WORK)
