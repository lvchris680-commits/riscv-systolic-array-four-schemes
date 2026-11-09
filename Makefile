# ============================================================================
# Makefile for a RISC-V CPU + systolic-array matrix-multiply SoC, with four
# integration schemes and a baseline comparison. Requires Verilator >= 5
# (with --timing support).
#
# Schemes:
#   scheme1  pure software matmul (no accelerator)
#   scheme2  memory-mapped accelerator, CPU-driven data movement
#   scheme3  PCPI co-processor
#   scheme4  DMA + shared BRAM + 2-master arbiter (autonomous data movement)
#
# Usage:
#   make all          - run all testbenches
#   make tb_sa        - systolic-array standalone test
#   make tb_software  - scheme 1
#   make tb_baseline  - scheme 2
#   make tb_pcpi      - scheme 3
#   make tb_soc       - scheme 4 interconnect (BFM) test
#   make tb_cpu       - scheme 4 full CPU-system test
#   make clean
#
# Note: the source directory contains spaces/non-ASCII characters, so
# Verilator's make cannot build in-place; -Mdir redirects the build to /tmp.
# ============================================================================

VERILATOR ?= verilator
MROOT := /tmp

COMMON = rtl/common/soc_pkg.sv rtl/common/systolic_array.sv rtl/common/pe.sv \
         rtl/common/bram_ctrl_axi_lite.sv
SCHEME1 = rtl/scheme1_software/top_software.sv
SCHEME2 = rtl/scheme2_mmio/systolic_ip_axi_lite.sv rtl/scheme2_mmio/axi_lite_addr_decode.sv \
          rtl/scheme2_mmio/top_baseline.sv
SCHEME3 = rtl/scheme3_pcpi/pcpi_sys_array_wrapper.sv rtl/scheme3_pcpi/top_pcpi.sv
SCHEME4 = rtl/scheme4_dma/axi_lite_arbiter_2m1s.sv rtl/scheme4_dma/sys_array_dma.sv \
          rtl/scheme4_dma/soc_top.sv rtl/scheme4_dma/top_cpu.sv

VFLAGS = --binary --timing \
  -Wno-fatal -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
  -Wno-UNUSEDPARAM -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-IMPLICITSTATIC \
  -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-DECLFILENAME -Wno-VARHIDDEN

.PHONY: all clean tb_sa tb_software tb_baseline tb_pcpi tb_soc tb_cpu

all: tb_sa tb_software tb_baseline tb_pcpi tb_soc tb_cpu

prog.hex: tools/gen_prog.py
	python3 tools/gen_prog.py
prog_software.hex: tools/gen_prog_software.py
	python3 tools/gen_prog_software.py
prog_baseline.hex: tools/gen_prog_baseline.py
	python3 tools/gen_prog_baseline.py
prog_pcpi.hex: tools/gen_prog_pcpi.py
	python3 tools/gen_prog_pcpi.py

tb_sa:
	rm -rf $(MROOT)/vbuild_sa
	$(VERILATOR) $(VFLAGS) --top-module tb_sa -o tb_sa -Mdir $(MROOT)/vbuild_sa \
	  rtl/common/systolic_array.sv rtl/common/pe.sv tb/tb_sa.sv
	$(MROOT)/vbuild_sa/tb_sa

tb_software: prog_software.hex
	rm -rf $(MROOT)/vbuild_software
	$(VERILATOR) $(VFLAGS) --top-module tb_software -o tb_software -Mdir $(MROOT)/vbuild_software \
	  $(COMMON) $(SCHEME1) third_party/picorv32.v tb/tb_software.sv
	$(MROOT)/vbuild_software/tb_software

tb_baseline: prog_baseline.hex
	rm -rf $(MROOT)/vbuild_baseline
	$(VERILATOR) $(VFLAGS) --top-module tb_baseline -o tb_baseline -Mdir $(MROOT)/vbuild_baseline \
	  $(COMMON) $(SCHEME2) third_party/picorv32.v tb/tb_baseline.sv
	$(MROOT)/vbuild_baseline/tb_baseline

tb_pcpi: prog_pcpi.hex
	rm -rf $(MROOT)/vbuild_pcpi
	$(VERILATOR) $(VFLAGS) --top-module tb_pcpi -o tb_pcpi -Mdir $(MROOT)/vbuild_pcpi \
	  $(COMMON) $(SCHEME3) third_party/picorv32.v tb/tb_pcpi.sv
	$(MROOT)/vbuild_pcpi/tb_pcpi

tb_soc:
	rm -rf $(MROOT)/vbuild_soc
	$(VERILATOR) $(VFLAGS) --top-module tb_soc -o tb_soc -Mdir $(MROOT)/vbuild_soc \
	  $(COMMON) rtl/scheme4_dma/axi_lite_arbiter_2m1s.sv rtl/scheme4_dma/sys_array_dma.sv \
	  rtl/scheme4_dma/soc_top.sv tb/tb_soc.sv
	$(MROOT)/vbuild_soc/tb_soc

tb_cpu: prog.hex
	rm -rf $(MROOT)/vbuild_cpu
	$(VERILATOR) $(VFLAGS) --top-module tb_cpu -o tb_cpu -Mdir $(MROOT)/vbuild_cpu \
	  $(COMMON) $(SCHEME4) third_party/picorv32.v tb/tb_cpu.sv
	$(MROOT)/vbuild_cpu/tb_cpu

clean:
	rm -rf $(MROOT)/vbuild_sa $(MROOT)/vbuild_software $(MROOT)/vbuild_baseline \
	       $(MROOT)/vbuild_pcpi $(MROOT)/vbuild_soc $(MROOT)/vbuild_cpu \
	       prog.hex prog_software.hex prog_baseline.hex prog_pcpi.hex
