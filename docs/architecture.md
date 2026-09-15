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

- **RV32I** integer base — **implemented in Phase 1** (see
  [`isa.md`](isa.md) for the authoritative list).
- Register file: **32 registers** in the Phase 1 core. RV32E (16 registers) is
  a possible area optimisation once the Phase 5 synthesis report is available.
- No M extension initially; multiply/divide are added only if firmware needs
  them (most protocols are shifts, masks and compares).
- Little-endian, byte-addressable memory.
- CSRs, traps and interrupts are **not yet implemented** (Phase 2).

### 2.2 Protocol-oriented extensions (Phase 3)

Custom instructions use RISC-V custom opcodes and are added only where they
remove a real bottleneck. **None are implemented yet.**

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
| CAN controller | `0x5800_0000` | 4 KiB | CAN 2.0B registers (Phase 6) |
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
- **CAN 2.0B controller** — bit timing, bit stuffing, CRC-15, error states and
  mailboxes, for full-rate CAN (see below)

## 5.1 CAN bus

CAN is a differential, multi-master bus with dominant/recessive signalling.
Proteus supports it in two tiers, consistent with the firmware-first thesis:

- **Firmware CAN (Phase 3)** — up to ~250 kbit/s, built from the programmable
  I/O and timing primitives. No dedicated hardware, so it works on any pin
  pair and demonstrates the reconfigurability claim.
- **Hardware CAN 2.0B controller (Phase 6)** — full rate (≤1 Mbit/s), with
  prescaler/bit-timing, bit stuffing, CRC-15, ACK, error counters and states
  (error-active/passive/bus-off), acceptance filtering and TX/RX mailboxes.

The analog layer is external: 2 pins (`CAN_TX`, `CAN_RX`) connect to a
transceiver (SN65HVD230, TJA1050 or MCP2551) driving the differential pair.
CAN FD is out of scope. Verification uses a two-node simulation with a
wired-AND bus model, which exercises arbitration and bit stuffing.

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
of these pins; CAN needs 2 pins (`CAN_TX`/`CAN_RX`) to a transceiver. The pin
allocation per protocol is a Phase 3–6 design task.

## 9. Open questions

- RV32E (16 regs) vs RV32I (32 regs) — decide after the Phase 5 area report.
- Bootloader pin assignment vs reusing protocol pins.
- Whether JTAG is a hardware TAP, firmware host, or both (Phase 4).
- MII pin budget vs other protocols (Phase 6).
- CAN: firmware-only, hardware controller, or both — depends on the Phase 5
  area report. Firmware CAN (≤250 kbit/s) is the guaranteed deliverable.
