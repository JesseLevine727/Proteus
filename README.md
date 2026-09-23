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
- **Accelerators** — **protocol-agnostic primitives** only: DMA, a
  configurable CRC unit, a generic shift/FIFO engine and a Manchester line
  code. There is no hardware UART/SPI/I2C/CAN/MAC block; firmware composes
  the primitives into protocols (including Ethernet).

Protocols are programs. UART, SPI, I2C, CAN, JTAG and anything else are all
firmware — including protocols the chip was never designed for, loaded at run
time through the bootloader.

## Current status

**Phase 3 complete — Reflexes.**

The chip now has a programmable 24-pin subsystem (output value, output-enable,
atomic set/clear/toggle, edge detection, pin interrupts), and the core gained
the protocol-oriented instructions `DELAY`, `PIN_WAIT` and `PIN_EDGE`.

With those, **UART, SPI, I2C and low-speed CAN are all implemented in
firmware** and verified against independent OCaml golden models. CAN is a
pair of CAN 2.0A nodes — transmit (stuffing, CRC-15, arbitration) and receive
(sample, de-stuff, decode, CRC check, ACK, with an assembly timing loop) —
checked on a two-node wired-AND bus. I2C includes an open-drain master (write
and read) and a slave at address 0x50.

Implemented so far: RV32I + Zicsr + traps, interrupts, timers, a debug UART, a
hardware bootloader, a C toolchain, the pin subsystem, the timing ISA, and the
four protocol stacks. 15 self-checking tests; generated Verilog is
Verilator-lint clean.

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
make firmware      # build firmware/ with riscv32-unknown-elf-gcc
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
│   ├── cpu.ml           #   single-cycle RV32I + Zicsr + traps core
│   ├── csr.ml           #   machine-mode CSRs, traps, interrupts
│   ├── soc.ml           #   instruction RAM, data RAM, GPIO, timer, UART
│   ├── timer.ml         #   mtime/mtimecmp machine timer
│   ├── uart.ml          #   memory-mapped debug UART (8N1)
│   ├── bootloader.ml    #   hardwired serial bootloader
│   ├── asm.ml           #   two-pass assembler
│   ├── firmware.ml      #   hand-assembled firmware images
│   ├── c_firmware.ml    #   generated: compiled C image
│   └── uart_tx.ml       #   Phase 0 standalone design
├── firmware/            # C toolchain (link.ld, crt0.S, main.c, build.sh)
├── bin/
│   └── generate_verilog.ml
├── test/                # self-checking simulations
│   ├── test_cpu.ml
│   ├── test_csr.ml
│   ├── test_timer.ml
│   ├── test_uart_periph.ml
│   ├── test_bootloader.ml
│   ├── test_c_firmware.ml
│   └── ...
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
| 1. First Light ✓ | Minimal core drives a pin from firmware |
| 2. Voice ✓ | Full CPU + CSRs/traps + UART + bootloader + C toolchain |
| 3. Reflexes ✓ | Pin subsystem, timing ISA, protocols in firmware, 1-Wire generality proof |
| 4. Fit *(critical)* | SRAM memories, pipelined fetch, RV32E → area headroom |
| 5. Flow *(critical)* | Tiny Tapeout cmos5l + LibreLane end-to-end → GDSII |
| 6. Breadth | JTAG (formal TAP FSM) + primitives if they fit |
| 7. Stretch | 10 Mbit Ethernet on the protocol-agnostic primitives |
| 8. Legacy | Reproducible verification evidence + submission |

The plan is **risk-first** (fit → flow → features → submit); see
[`docs/roadmap.md`](docs/roadmap.md) for the full phasing and schedule.

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
