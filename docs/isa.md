# Proteus ISA Reference

This document records the instruction set actually implemented by the Proteus
core. It is a working reference, not a ratified specification.

## Implemented: RV32I base integer instruction set

- **Register-register:** `ADD SUB SLL SLT SLTU XOR SRL SRA OR AND`
- **Register-immediate:** `ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI`
- **Loads:** `LB LH LW LBU LHU`
- **Stores:** `SB SH SW`
- **Branches:** `BEQ BNE BLT BGE BLTU BGEU`
- **Jumps:** `JAL JALR`
- **Upper immediate:** `LUI AUIPC`
- **FENCE** (no-op)

## Implemented: Zicsr and machine mode (Phase 2)

- **CSR:** `CSRRW CSRRS CSRRC CSRRWI CSRRSI CSRRCI`
- **Privileged:** `ECALL` (cause 11), `EBREAK` (cause 3), `MRET`, `WFI`
  (no-op)

### CSRs

| CSR | Address | Notes |
|---|---|---|
| `mstatus` | `0x300` | MIE[3], MPIE[7], MPP[12:11] |
| `misa` | `0x301` | read-only, `0x40000100` (RV32I) |
| `mie` | `0x304` | MSIE[3], MTIE[7], MEIE[11] |
| `mtvec` | `0x305` | direct mode |
| `mscratch` | `0x340` | |
| `mepc` | `0x341` | |
| `mcause` | `0x342` | |
| `mtval` | `0x343` | |
| `mip` | `0x344` | reflects the hardware interrupt inputs |
| `mcycle` / `mcycleh` | `0xB00` / `0xB80` | free-running 64-bit counter |
| `minstret` / `minstreth` | `0xB02` / `0xB82` | retired instructions |
| `mvendorid`..`mhartid` | `0xF11`..`0xF14` | read-only zero |

The user read aliases `cycle`/`instret` (`0xC00`/`0xC02`) are also decoded.

### Traps and interrupts

On a trap the core writes `mepc`/`mcause`/`mtval`, saves `MIE` into `MPIE`,
clears `MIE`, sets `MPP=M`, and jumps to `mtvec`. `MRET` restores `mstatus`
and returns to `mepc`.

- **Exceptions:** illegal instruction (2), breakpoint (3), environment call
  from M-mode (11). An illegal instruction is any unknown opcode or an
  invalid `funct3`/`funct7` combination.
- **Interrupts:** machine software (3), timer (7) and external (11), taken
  when `mstatus.MIE`, the matching `mie` bit and the matching `mip` bit are
  set. Priority is external > software > timer. The timer interrupt is driven
  by `mtime`/`mtimecmp`.

## Not yet implemented

The `M`/`A` extensions, compressed instructions, load/store misalignment
traps, user mode, and the protocol-oriented custom instructions (`DELAY`,
`PIN_WAIT`) planned for Phase 3.

## Register conventions

| Register | ABI name | Use |
|---|---|---|
| x0 | zero | hardwired zero |
| x1 | ra | return address |
| x2 | sp | stack pointer |
| x5–x7 | t0–t2 | temporaries |
| x8–x9 | s0–s1 | saved / peripheral base |
| x10–x17 | a0–a7 | arguments |
| x28–x31 | t3–t6 | temporaries |

## Memory map

| Region | Base | Selection | Notes |
|---|---|---|---|
| Instruction RAM | `0x0000_0000` | PC | 256 words, writable (bootloader) |
| Instruction RAM (data view) | `0x0000_0000` | `addr[31:28] == 0` | lets firmware copy initialised data |
| Data RAM | `0x1000_0000` | `addr[31:28] == 1` | 64 words, byte-writable |
| GPIO | `0x2000_0000` | `addr[31:28] == 2` | 8-bit output register |
| Machine timer | `0x3000_0000` | `addr[31:28] == 3` | mtime / mtimecmp |
| Debug UART | `0x6000_0000` | `addr[31:28] == 6` | 8N1, TX/RX |
| HALT | `0x7000_0000` | `addr[31:28] == 7` | write-only; freezes the core |

The UART page: offset 0 TX data, 4 RX data (read clears valid), 8 status
(bit 0 TX busy, bit 1 RX valid), 12 baud divisor.

## Microarchitecture

- Single cycle: every instruction retires in one cycle.
- Combinational instruction fetch and data access.
- 32 × 32-bit register file, two combinational read ports, one synchronous
  write port; `x0` hardwired to zero.
- Deterministic timing, which is what makes firmware bit-banging practical.

The register-array memories are a simulation stand-in; Phase 5 replaces them
with SRAM macros and pipelines the fetch path.

## Toolchain

Two ways to build firmware:

1. **Hand-assembled** — the two-pass assembler in `lib/asm.ml`, driven by the
   instruction constructors in `lib/isa.ml` (used by the directed tests and
   the Phase 1 bit-banged UART).
2. **C** — `riscv32-unknown-elf-gcc` with `firmware/link.ld`, `crt0.S` and
   `main.c`; `firmware/build.sh` emits `lib/c_firmware.ml` (an OCaml image).

## Verification

- `test/test_cpu.ml` — directed ALU, branch, jump and load/store tests.
- `test/test_csr.ml` — CSR read/write/set/clear, ECALL and illegal-instruction
  traps with MRET return.
- `test/test_timer.ml` — machine timer interrupt end to end.
- `test/test_uart_periph.ml` — hardware UART TX and RX.
- `test/test_bootloader.ml` — the bootloader loads an image over UART.
- `test/test_c_firmware.ml` — compiled C prints over UART, direct and booted.
