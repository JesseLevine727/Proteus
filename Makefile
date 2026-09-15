# Proteus build entry points.
#
# The toolchain lives in the local opam switch, so first run:
#   eval $(opam env --switch=. --set-switch)

VERILATOR ?= verilator

.PHONY: all build test verilog lint firmware clean

all: build

build:
	dune build

test:
	dune runtest

# Requires riscv32-unknown-elf-gcc (e.g. on PATH or RISCV_CC set).
firmware:
	cd firmware && ./build.sh

verilog:
	dune exec bin/generate_verilog.exe

# Hardcaml emits combinational case muxes using non-blocking assignments,
# which Verilator reports as COMBDLY. They are single-driver and
# combinational, so the warning is benign; the other two are cosmetic.
lint: verilog
	@for f in rtl/*.v; do \
		echo "lint $$f"; \
		$(VERILATOR) --lint-only \
			-Wno-COMBDLY -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
			$$f || exit 1; \
	done
	@echo "Verilator lint clean"

clean:
	dune clean
