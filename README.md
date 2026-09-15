# Proteus

**An open-source, firmware-defined protocol emulator ASIC — a tiny RISC-V
micro-core that becomes any hardware protocol.**

Proteus is an entry to the [Jane Street protocol emulator ASIC
competition](https://blog.janestreet.com/protocol-emulator-asic-competition/).
Instead of hardwiring a UART, SPI and I2C block onto one die, Proteus puts a
small RISC-V core with protocol-oriented instructions at the centre and
implements protocols as *firmware*. The chip is reprogrammable **after
fabrication**, so new protocols can be supported within its timing and I/O
constraints.

The name comes from the Greek sea-god Proteus, who could change shape at will —
the hard part of this competition is exactly that: one die, many forms.

## What it is

```
firmware  ──►  RV32 micro-core  ──►  memory-mapped I/O  ──►  24 pins
              (pin/timing ISA)       GPIO/timers/IRQ        (UART, SPI, I2C,
                                                             JTAG, CAN, ...)
```

- **Core** — a custom RV32E/RV32I micro-core with cycle counter, fast
  interrupts and protocol-oriented instructions (`PIN_WAIT`, `DELAY`, ...).
- **Memories** — small instruction and data SRAMs (dense, per Jane Street's
  guidance).
- **I/O** — all 24 Tiny Tapeout pins, memory-mapped with atomic set/clear/
  toggle, edge detection and capture.
- **Accelerators** — added only where firmware misses timing: shift engine,
  FIFOs, DMA, CRC32, 10 Mbit Ethernet via MII to an external PHY, and a
  hardware CAN 2.0B controller.

Protocols are programs. UART, SPI, I2C, PS/2, SWD, JTAG and low-speed CAN are
all firmware; full-rate Ethernet and CAN get area-gated hardware assist.

## Current status

**Phase 1 complete — First Light.**

A custom RV32I micro-core (`lib/cpu.ml`) executes firmware from a
combinational instruction ROM. The firmware bit-bangs a complete 8N1 UART
frame out of a GPIO pin, and the simulator decodes the byte back and checks
the timing against the model — no protocol hardware involved.

Implemented so far: full RV32I base, a two-pass assembler, a 64-word
byte-writable data RAM, memory-mapped GPIO, and directed CPU + firmware
tests. Generated Verilog is Verilator-lint clean.

See [`docs/roadmap.md`](docs/roadmap.md) for the phased plan,
[`docs/architecture.md`](docs/architecture.md) for the architecture,
[`docs/protocols.md`](docs/protocols.md) for protocol targets, and
[`docs/isa.md`](docs/isa.md) for the implemented instruction set.

## Quickstart

Requires [opam](https://opam.ocaml.org/). The repository carries a local
switch pinned to OCaml 5.3.0.

```sh
opam switch create . ocaml-base-compiler.5.3.0   # first time only
eval $(opam env --switch=. --set-switch)

make test          # build and run all tests
make verilog       # emit rtl/*.v
make lint          # Verilator lint of the generated Verilog
```

Expected Phase 1 exit test output:

```
decoded byte = 0xA5 (start at cycle 7, period 32 cycles)
UART firmware test PASSED
```

## Repository layout

```
.
├── lib/                 # Hardcaml design library (the chip)
│   ├── isa.ml           #   opcodes, encoders, instruction helpers
│   ├── alu.ml           #   RV32I ALU
│   ├── regfile.ml       #   32x32 register file
│   ├── cpu.ml           #   single-cycle RV32I core
│   ├── soc.ml           #   instruction ROM, data RAM, GPIO
│   ├── asm.ml           #   two-pass assembler
│   ├── firmware.ml      #   firmware images (bit-banged UART)
│   └── uart_tx.ml       #   Phase 0 standalone design
├── bin/
│   └── generate_verilog.ml
├── test/
│   ├── test_cpu.ml      #   directed RV32I tests
│   ├── test_uart_fw.ml  #   Phase 1 exit test (firmware UART)
│   └── test_uart_tx.ml
├── rtl/                 # generated Verilog (synthesizable)
└── docs/
    ├── roadmap.md       # phased plan with exit gates
    ├── architecture.md  # architecture and memory map
    ├── protocols.md     # protocol targets and verification approach
    └── isa.md           # implemented instruction set
```

## Roadmap at a glance

| Phase | Goal |
|---|---|
| 0. Foundations ✓ | Toolchain + first verified design |
| 1. First Light | Minimal core drives a pin from firmware |
| 2. Voice | Full CPU + firmware toolchain + bootloader |
| 3. Reflexes | UART/SPI/I2C in firmware, precise timing |
| 4. The Watcher | JTAG (TAP target and/or host) |
| 5. Conduits | Shift/FIFO/DMA/CRC + early synthesis checkpoint |
| 6. The Ether and the Wire | 10 Mbit Ethernet (MII) + CAN 2.0B controller (stretch) |
| 7. Silicon | Tiny Tapeout hardening → GDSII |
| 8. Legacy | Reproducible verification evidence + docs |

## Design constraints

- **Process:** IHP 130 nm CMOS5L via Tiny Tapeout (`ttihp-verilog-template`,
  `cmos5l` branch)
- **Area:** 6×4 tiles ≈ 0.7 mm², ~24K logic cells
- **Pins:** 24 signals (`ui_in` ×8, `uo_out` ×8, `uio` ×8)
- **Deadline:** 18 January 2027

## Design philosophy

> **Never add several major unverified subsystems at once.**

Every phase must boot, execute its tests and pass regressions before the next
architectural feature is introduced. Verification evidence is a first-class
deliverable, not a cleanup step — the competition explicitly rewards novel
verification methodology.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
