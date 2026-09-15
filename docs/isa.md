# Proteus ISA Reference (Phase 1)

This document records the instruction set actually implemented by the Proteus
core. It is a working reference, not a ratified specification.

## Implemented: RV32I base integer instruction set

The Phase 1 core implements the full **RV32I** base:

- **Register-register:** `ADD SUB SLL SLT SLTU XOR SRL SRA OR AND`
- **Register-immediate:** `ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI`
- **Loads:** `LB LH LW LBU LHU`
- **Stores:** `SB SH SW`
- **Branches:** `BEQ BNE BLT BGE BLTU BGEU`
- **Jumps:** `JAL JALR`
- **Upper immediate:** `LUI AUIPC`
- **System:** `EBREAK` (halts the core), `FENCE` (no-op)

Not yet implemented (later phases): CSRs and `mcycle`, traps and interrupts,
the `M`/`A` extensions, compressed instructions, and the protocol-oriented
custom instructions.

## Custom protocol instructions (planned, Phase 3)

| Instruction | Purpose |
|---|---|
| `DELAY rd, rs1` | Busy-wait exactly `rs1` cycles |
| `PIN_WAIT rd, rs1, rs2` | Wait for a pin condition (mask, timeout) |
| `PIN_EDGE rd, rs1, rs2` | Wait for a level/edge with timeout |

Baseline GPIO and peripheral access is **memory-mapped**, so no new opcodes
are required for the common case.

## Register conventions

| Register | ABI name | Use in firmware |
|---|---|---|
| x0 | zero | hardwired zero |
| x1 | ra | return address |
| x2 | sp | stack pointer |
| x5–x7 | t0–t2 | temporaries |
| x8–x9 | s0–s1 | saved / peripheral base, loop counters |
| x10–x17 | a0–a7 | arguments |

## Memory map

| Region | Base | Selection | Notes |
|---|---|---|---|
| Instruction ROM | `0x0000_0000` | PC | combinational, loaded from a program image |
| Data RAM | `0x1000_0000` | `addr[31:28] == 1` | 64 words, byte-writable |
| GPIO | `0x2000_0000` | `addr[31:28] == 2` | 8-bit output register at offset 0 |

Data RAM and the instruction ROM are deliberately simple for Phase 1. Phase 5
replaces them with SRAM macros and pipelines the fetch path.

## Microarchitecture

- Single cycle: every instruction retires in one cycle.
- Combinational instruction fetch (ROM lives in the SoC).
- 32 × 32-bit register file, two combinational read ports, one synchronous
  write port; `x0` hardwired to zero.
- Deterministic timing, which is what makes firmware bit-banging practical and
  verifiable.

## Assembler

Firmware is assembled by the small two-pass assembler in `lib/asm.ml`, driven
by the instruction constructors in `lib/isa.ml`. A real assembler/linker
(`riscv-gnu-toolchain`) arrives in Phase 2.

## Verification

- `test/test_cpu.ml` — directed tests for ALU, branches, jumps, and
  byte/half load-store semantics, checked through the data RAM.
- `test/test_uart_fw.ml` — the Phase 1 exit test: firmware bit-bangs an 8N1
  frame out of GPIO bit 0, and the simulator decodes the byte back.
