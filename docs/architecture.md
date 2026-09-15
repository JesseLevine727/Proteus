# Proteus Architecture (v1 working specification)

This document is the working contract for the Proteus design. It is expected
to change as phases close, but changes should be deliberate and reflected in
the phase gates.

## 1. Overview

Proteus is a small System-on-Chip whose purpose is to **emulate hardware
protocols in firmware**. The central component is a custom RISC-V micro-core
with an instruction set tuned for pin access and cycle-accurate timing. Around
it sit small memories, a memory-mapped I/O subsystem, and (from Phase 5) a set
of composable hardware accelerators for the cases where firmware cannot meet
timing.

## 2. Core

### 2.1 Base ISA

- **RV32I** integer base, implemented incrementally (Phase 1 subset → Phase 2
  complete).
- Register file: **16 registers (RV32E)** as the area baseline; the decode and
  register file are parameterised so we can widen to 32 if area allows.
- No M extension initially; multiply/divide are added only if firmware needs
  them (most protocols are shifts, masks and compares).
- Little-endian, byte-addressable memory.

### 2.2 Protocol-oriented extensions

Custom instructions use RISC-V custom opcodes and are added only where they
remove a real bottleneck.

| Instruction | Purpose |
|---|---|
| `DELAY rd, rs1` | Busy-wait exactly `rs1` cycles (deterministic timing) |
| `PIN_WAIT rd, rs1, rs2` | Wait for a pin condition (mask in `rs1`, timeout in `rs2`); `rd` returns status |
| `PIN_EDGE rd, rs1, rs2` | Wait for a level/edge on a pin mask with timeout |

Baseline GPIO reads/writes stay **memory-mapped** so the common case needs no
new opcodes. Accelerator access (shift engine, FIFO, DMA, CRC) is also
memory-mapped.

### 2.3 CSRs and interrupts

- `mcycle` / `mcycleh` — free-running cycle counter for measurement and timing
- `minstret` — retired instruction counter
- Fast interrupt entry with a small vector table; sources are pin edges and
  timer compares

## 3. Memory map (proposed)

| Region | Base | Size | Notes |
|---|---|---|---|
| Instruction SRAM | `0x0000_0000` | 4 KiB | Loaded at boot |
| Data SRAM | `0x1000_0000` | 2 KiB | Stack + buffers |
| GPIO | `0x2000_0000` | 4 KiB | set / clear / toggle / read / capture |
| Timers & dividers | `0x3000_0000` | 4 KiB | compare + baud/symbol generators |
| Interrupt controller | `0x4000_0000` | 4 KiB | enable / pending / ack |
| Accelerators | `0x5000_0000` | 16 KiB | shift / FIFO / DMA / CRC (Phase 5+) |
| UART (debug) | `0x6000_0000` | 4 KiB | firmware console |

Exact sizes are provisional; the goal is a clean, decodable map with room for
accelerators to appear in later phases without disturbing earlier addresses.

## 4. I/O subsystem

- **24 pins**: `ui_in[7:0]` (inputs), `uo_out[7:0]` (outputs), `uio[7:0]`
  (bidirectional with output-enable).
- Per-pin capabilities: read, atomic set/clear/toggle, output-enable control,
  edge detection, and timestamped capture (Phase 4 analyzer mode).
- Open-drain emulation for I2C by driving low and reading back.
- All I/O is memory-mapped; no protocol is hardwired.

## 5. Accelerators (planned, Phase 5+)

Introduced only when firmware misses timing:

- **Shift engine** — bit-serial TX/RX with programmable clock division
- **FIFOs** — decouple firmware from wire timing
- **DMA** — memory-to-memory and memory-to-peripheral
- **CRC32** — Ethernet FCS and general checksums
- **Manchester** — only if we choose the PHY-less Ethernet path

## 6. Boot and program loading

An ASIC has no way to preload SRAM, so Proteus boots by loading a program at
run time.

- A small hardwired **serial bootloader** shifts a program image in over a
  dedicated pin pair (or reuses a protocol port) after reset.
- When the image is complete and verified (length + checksum), the core is
  released from reset.
- A debug UART provides a second loading and console path.

## 7. Clocking and reset

- Single clock domain (`clk`); target frequency chosen after the Phase 5
  synthesis checkpoint (provisionally 50 MHz).
- `rst_n` is asynchronous-assert, synchronous-release.
- `ena` gates activity for Tiny Tapeout.

## 8. Tiny Tapeout interface

| Port | Direction | Use |
|---|---|---|
| `clk`, `rst_n`, `ena` | in | clock, reset, enable |
| `ui_in[7:0]` | in | protocol inputs / boot |
| `uo_out[7:0]` | out | protocol outputs |
| `uio_in/out/oe[7:0]` | bidir | bidirectional protocol lines |

Ethernet (Phase 6) uses MII to an external PHY and will consume a large share
of these pins; the pin allocation per protocol is a Phase 3–6 design task.

## 9. Open questions

- RV32E (16 regs) vs RV32I (32 regs) — decide after the Phase 5 area report.
- Bootloader pin assignment vs reusing protocol pins.
- Whether JTAG is a hardware TAP, firmware host, or both (Phase 4).
- MII pin budget vs other protocols (Phase 6).
