# Makefile -- open-source flow for mkMultBuff (SPEC.md Section 7).
# Usage: make <synth|check|sim|timing|power|all> RUN=<400|800>
# Toolchain: bash submission/scripts/install.sh

RUN      ?= 400
ifeq ($(RUN),400)
  PERIOD  ?= 2.5
  HALF    := 1.25
  ABC_D   ?= 2200
  BOOTH   ?= 1
  ADDER   ?= kogge-stone
  # ABC mapping knobs: as for 800 MHz (round 3 measurements, notes/WORKLOG.md)
  ABC_DRIVER ?= BUF_X1
  ABC_LOAD   ?= 1.0
  DONT_USE   ?= OAI33_* NOR3_* NOR4_* OR3_* OR4_* AND4_* NAND4_* AOI211_* AOI221_* AOI222_* OAI211_* OAI221_* OAI222_* MUX2_*
else ifeq ($(RUN),800)
  PERIOD  ?= 1.25
  HALF    := 0.625
  ABC_D   ?= 1050
  BOOTH   ?= 1
  ADDER   ?= kogge-stone
  # ABC mapping knobs: BUF_X1 input driver, 1 fF load (ABC outputs are mostly
  # flip-flop D pins), and no cells with 3- or 4-high stacks or MUX2 (slow at
  # the slow corner) during mapping
  ABC_DRIVER ?= BUF_X1
  ABC_LOAD   ?= 1.0
  DONT_USE   ?= OAI33_* NOR3_* NOR4_* OR3_* OR4_* AND4_* NAND4_* AOI211_* AOI221_* AOI222_* OAI211_* OAI221_* OAI222_* MUX2_*
else
  $(error RUN must be 400 or 800)
endif

ROOT     := $(CURDIR)
LIB      := tech/NangateOpenCellLibrary_slow.lib
CELLS    := tech/NangateOpenCellLibrary.v
RTL_DIR  ?= submission/rtl_$(RUN)
RTL      := $(wildcard $(RTL_DIR)/*.sv)
MEM      := starter/rtl/memory_wrapper_2port.sv starter/rtl/registerArray.sv
TB       := submission/testbench
OUT      := submission/outputs
REP      ?= submission/syn_reports/$(RUN)
BUILD    ?= build/$(RUN)
NETLIST  ?= $(OUT)/mkMultBuff_$(RUN)_map.v
SDF      ?= $(OUT)/mkMultBuff_$(RUN)_map.sdf
SEED     ?= 402
SETUP_MARGIN ?= 0.15

YOSYS_IMAGE := openroad/orfs@sha256:d3505fd5f930fcd20d3d25a41f3047230b7db7b7797e3448561c9e556cca3774
STA_IMAGE   := openroad/opensta@sha256:4162b4be70ee69eaa42e5eb3c830433393ff46cf0370f9b6c5b814b48a221a7a
DOCKER      := docker run --rm -v $(ROOT):$(ROOT) -w $(ROOT)
YOSYS       := $(DOCKER) -e RUN=$(RUN) -e RTL_DIR=$(RTL_DIR) -e LIB=$(LIB) -e ABC_D=$(ABC_D) -e BOOTH=$(BOOTH) -e ADDER=$(ADDER) -e OUT=$(BUILD)/syn.v \
               -e ABC_DRIVER=$(ABC_DRIVER) -e ABC_LOAD=$(ABC_LOAD) -e MAPLIB=$(if $(strip $(DONT_USE)),$(BUILD)/maplib.lib,) \
               $(YOSYS_IMAGE) /OpenROAD-flow-scripts/tools/install/yosys/bin/yosys
OPENROAD    := $(DOCKER) -e LIB=$(LIB) -e NETLIST_IN=$(BUILD)/syn.v -e NETLIST=$(NETLIST) -e PERIOD=$(PERIOD) \
               -e SETUP_MARGIN=$(SETUP_MARGIN) -e PDK_LEF_DIR=/OpenROAD-flow-scripts/flow/platforms/nangate45/lef \
               $(YOSYS_IMAGE) /OpenROAD-flow-scripts/tools/install/OpenROAD/bin/openroad -no_init -exit
STA         := $(DOCKER) -e RUN=$(RUN) -e LIB=$(LIB) -e NETLIST=$(NETLIST) -e SDF=$(SDF) -e PERIOD=$(PERIOD) \
               --entrypoint /OpenSTA/build/sta $(STA_IMAGE) -no_init -no_splash -exit

.PHONY: synth check sim timing power all clean timing_fail sta_only f14

$(REP) $(BUILD) $(OUT):
	mkdir -p $@

# ---- synthesis + static timing (netlist, SDF, area/timing/power-estimate reports)
synth: | $(REP) $(OUT) $(BUILD)
	$(if $(strip $(DONT_USE)),python3 submission/scripts/lib_dont_use.py $(LIB) $(BUILD)/maplib.lib $(foreach c,$(DONT_USE),'$(c)'),)
	$(YOSYS) -q -l $(REP)/synth.log -c submission/scripts/synth.tcl
	mv -f $(BUILD)/syn.stat.rpt $(REP)/yosys_area.rpt
	$(OPENROAD) submission/scripts/resize.tcl > $(REP)/resize.log 2>&1
	$(STA) submission/scripts/sta.tcl > $(REP)/sta.rpt 2>&1
	python3 submission/scripts/sdf_typmax.py $(SDF).sta $(SDF) && rm -f $(SDF).sta
	@grep -E "^(worst slack|tns|Total|cell area)" $(REP)/sta.rpt

# ---- RTL simulation with the RTL checker
check: | $(REP) $(BUILD)
	iverilog -g2012 -s mkMultBuff_tb -P mkMultBuff_tb.CLK_HALF_NS=$(HALF) -o $(BUILD)/check.vvp \
	    $(TB)/rtl_checker.sv $(MEM) $(RTL)
	vvp -n $(BUILD)/check.vvp +seed=$(SEED) | tee $(REP)/check.log | tail -25
	@grep -q "^ALL PASS" $(REP)/check.log || { echo "check FAILED"; exit 1; }

# simulation copy of the netlist: the harness instantiates mkMultBuff #(.N(32)),
# so an (unused) parameter N is declared in the netlist module
$(BUILD)/netlist_sim.v: $(NETLIST) | $(BUILD)
	sed -e '0,/^module mkMultBuff (/s//module mkMultBuff #(parameter N = 32) (/' $< > $@

# ---- gate-level simulation (zero delay, no back-annotation) with the RTL checker -> VCD
sim: $(BUILD)/netlist_sim.v | $(REP) $(BUILD)
	iverilog -g2012 -s mkMultBuff_tb -P mkMultBuff_tb.CLK_HALF_NS=$(HALF) -o $(BUILD)/sim.vvp \
	    $(TB)/rtl_checker.sv $(MEM) $(BUILD)/netlist_sim.v $(CELLS)
	vvp -n $(BUILD)/sim.vvp +seed=$(SEED) +vcd=$(BUILD)/gate.vcd | tee $(REP)/sim.log | tail -25
	@grep -q "^ALL PASS" $(REP)/sim.log || { echo "sim FAILED"; exit 1; }

# ---- gate-level simulation with SDF back-annotation and the gate-level checker
timing: $(BUILD)/netlist_sim.v | $(REP) $(BUILD)
	iverilog -g2012 -gspecify -s mkMultBuff_sdf_checker_$(RUN) -o $(BUILD)/timing.vvp \
	    $(TB)/sdf_checker_$(RUN).sv $(MEM) $(BUILD)/netlist_sim.v $(CELLS)
	vvp -n $(BUILD)/timing.vvp +sdf_file=$(SDF) +seed=$(SEED) > $(REP)/timing.log 2>&1 ; true
	@grep -v -i "sdf.*warning" $(REP)/timing.log | tail -12
	@grep -q "^ALL PASS" $(REP)/timing.log || { echo "timing FAILED"; exit 1; }

# ---- activity-based power from the gate-level VCD (whole run and the two 64-cycle windows)
power: | $(REP) $(BUILD)
	bash submission/scripts/power.sh $(REP) $(BUILD) $(NETLIST) $(PERIOD) $(LIB) $(STA_IMAGE)

# ---- demonstration that the gate-level checker fails a netlist that violates timing
#  RUN=400: the one-stage-multiplier variant in submission/testbench/timing_fail/rtl_onestage,
#           synthesized with the same flow at 2.5 ns (STA reports negative slack)
#  RUN=800: the 400 MHz netlist, timed by STA and back-annotated at 1.25 ns
FAIL_BUILD := build/fail_$(RUN)
FAIL_REP   := submission/syn_reports/$(RUN)/timing_fail
timing_fail:
	mkdir -p $(FAIL_BUILD) $(FAIL_REP)
ifeq ($(RUN),400)
	$(MAKE) synth RUN=400 RTL_DIR=submission/testbench/timing_fail/rtl_onestage BUILD=$(FAIL_BUILD) REP=$(FAIL_REP) \
	    NETLIST=$(FAIL_BUILD)/fail_map.v SDF=$(FAIL_BUILD)/fail_map.sdf
else
	$(MAKE) sta_only RUN=800 BUILD=$(FAIL_BUILD) REP=$(FAIL_REP) \
	    NETLIST=$(OUT)/mkMultBuff_400_map.v SDF=$(FAIL_BUILD)/fail_map.sdf
endif
	-$(MAKE) timing RUN=$(RUN) BUILD=$(FAIL_BUILD) REP=$(FAIL_REP) NETLIST=$(if $(filter 400,$(RUN)),$(FAIL_BUILD)/fail_map.v,$(OUT)/mkMultBuff_400_map.v) SDF=$(FAIL_BUILD)/fail_map.sdf
	@grep -q "TIMING FAIL" $(FAIL_REP)/timing.log && echo "timing_fail: checker reported TIMING FAIL as expected" \
	    || { echo "timing_fail: checker did NOT fail"; exit 1; }

sta_only: | $(REP)
	$(STA) submission/scripts/sta.tcl > $(REP)/sta.rpt 2>&1
	python3 submission/scripts/sdf_typmax.py $(SDF).sta $(SDF) && rm -f $(SDF).sta
	@grep -E "^(worst slack|tns)" $(REP)/sta.rpt

# ---- SPEC F14: formal (SAT) proof that every flip-flop of the netlist is reset by RST_N
f14: | $(REP) $(BUILD)
	bash submission/scripts/f14_check.sh $(NETLIST) $(BUILD)/f14 | tee $(REP)/f14.log

all: synth check sim timing power f14

clean:
	rm -rf build
