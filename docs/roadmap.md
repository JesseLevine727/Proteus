# Proteus Roadmap

Proteus is a **firmware-defined protocol engine**: a small, open-source ASIC
built around a tiny custom RISC-V micro-core whose instruction set is designed
for reading pins, writing pins, counting cycles and hitting timing precisely
enough that real hardware protocols are implemented as *programs* rather than
fixed logic blocks.

The chip is reprogrammable **after fabrication**, so protocols that did not
exist when the die was taped out can be supported within its timing and I/O
constraints.

> **Research question:** How much of a general-purpose protocol emulator can be
> built as firmware on a tiny RISC-V core, and where must hardware
> acceleration be introduced to meet timing?

## Design constraints

| Constraint | Value | Consequence |
|---|---|---|
| Process | IHP 130 nm CMOS5L via Tiny Tapeout | Open flow, `ttihp-verilog-template` (`cmos5l`) |
| Area | 6×4 tiles ≈ 0.7 mm², ~24K logic cells | Instruction/data memory should be SRAM, not flops |
| Pins | 24 signals: `ui_in[7:0]`, `uo_out[7:0]`, `uio[7:0]` | Ethernet needs MII-to-PHY (most pins); CAN needs an external transceiver (2 pins) |
| Clock | ~25–100 MHz achievable at this node | MII at 10 Mbit (2.5 MHz) is comfortable |
| Deadline | 18 January 2027 | Phases 0–7 must close with an early synthesis checkpoint |

## Architecture at a glance

```
                       PROTEUS
   +---------------------------------------------------+
   |  RV32 core  (custom pin/timing instructions)       |
   |  - 16/32 regs, cycle counter CSR, fast IRQ         |
   +-------------------------+-------------------------+
                             |
                    +--------+--------+
                    |  Memory system  |
                    |  I-SRAM | D-SRAM |
                    +--------+--------+
                             |
   +-------------------------+-------------------------+
   |                  I/O subsystem                    |
   |  GPIO (24 pins, atomic set/clr/toggle, wait/edge) |
   |  Timers / clock dividers / interrupt controller   |
   +-------------------------+-------------------------+
                             |
    +-------------------------+-------------------------+
    |        Hardware accelerators (added in phases)    |
    |  shift engine | FIFO | DMA | CRC | Manchester     |
    |  Ethernet MAC (MII) | CAN 2.0B controller          |
    +---------------------------------------------------+
```

Protocols are firmware: UART, SPI, I2C, PS/2, SWD, JTAG and low-speed CAN are
programs. Hardware accelerators are introduced only where firmware cannot meet
timing (notably 10 Mbit Ethernet and high-speed CAN).

## Cross-cutting tracks

1. **Verification** — every phase adds evidence, never retrofits it.
   - Hardcaml unit tests with cycle-accurate simulation
   - Formal properties (`hardcaml_verify`, SymbiYosys) for state machines,
     arbiters and protocol invariants
   - Constrained-random tests against OCaml golden models
   - RTL co-simulation (Hardcaml vs Verilator) before ASIC hardening
2. **Tooling** — assembler/loader, firmware build, TT hardening flow.
3. **Documentation** — architecture, ISA reference, verification records.

## Phases

Each phase must **boot, execute its tests and pass regressions** before the
next begins. A smaller system that is fully understood beats a larger one
whose failures cannot be isolated.

### Phase 0 — Foundations ✓

**Goal:** Reproducible OCaml/Hardcaml toolchain and a first verified design.

- Local opam switch (OCaml 5.3.0) with Hardcaml + verification backends
- Dune project, Verilog generation, self-checking simulation
- First design: UART transmitter, decoded back to a byte in simulation

**Exit:** `dune build` clean; sim test passes; generated Verilog is
Verilator-lint clean. *(complete)*

### Phase 1 — First Light ✓

**Goal:** A minimal core executes hand-assembled code and drives a pin.

- ISA reference in [`docs/isa.md`](isa.md); full RV32I base implemented in
  `lib/cpu.ml`
- Assembler (`lib/asm.ml`) and instruction encoders (`lib/isa.ml`)
- SoC (`lib/soc.ml`): combinational instruction ROM, 64-word byte-writable
  data RAM, memory-mapped GPIO
- Firmware (`lib/firmware.ml`) bit-bangs an 8N1 UART frame

**Exit:** firmware drives GPIO bit 0 with a 10-bit UART frame; the simulator
decodes `0xA5` back and confirms the measured bit period matches the timing
model. *(complete)*

**Verification:** directed CPU tests (ALU, branches, jumps, byte/half
load-store semantics) plus the firmware UART exit test, all in
cycle-accurate simulation. Generated Verilog is Verilator-lint clean.

### Phase 2 — Voice ✓

**Goal:** A complete CPU and a real firmware toolchain.

- Full RV32I base plus the **Zicsr** CSR instructions and machine traps
  (illegal instruction, ECALL, EBREAK) with MRET (`lib/csr.ml`, `lib/cpu.ml`)
- `mcycle`/`mcycleh`, `minstret`/`minstreth`, `mstatus`, `mtvec`, `mepc`,
  `mcause`, `mtval`, `mscratch`, `mie`, `mip`, `misa` and the id registers
- Machine software/timer/external interrupts; a memory-mapped
  `mtime`/`mtimecmp` timer drives the timer interrupt (`lib/timer.ml`)
- A memory-mapped **debug UART** (8N1, TX + RX) at `0x6000_0000`
  (`lib/uart.ml`), used for the console and the boot channel
- A **hardware bootloader** (`lib/bootloader.ml`) that holds the CPU in reset,
  streams a program image into the writable instruction RAM, then releases it
- RISC-V `riscv32-unknown-elf-gcc` toolchain: linker script, C startup, and a
  C firmware that prints over the UART (`firmware/`)

**Exit:** compiled C prints `Hello from Proteus C!` over the UART in
simulation, both when loaded directly and when streamed in through the
bootloader. *(complete)*

**Verification:** directed CSR/trap tests, a timer-interrupt test, UART TX/RX
tests, a bootloader test, and the C firmware test (direct + booted). The full
RISC-V ISA test suite is a Phase 3 addition.

### Phase 3 — Reflexes

**Goal:** Programmable I/O and precise timing, protocols in firmware.

Decisions: timing primitives are **custom instructions** (`DELAY`, `PIN_WAIT`,
`PIN_EDGE`); pin-edge interrupts are **simple** (enable/pending ORed into
`mip.MEIP`); protocols are built **UART → SPI → I2C → CAN**; CAN targets full
low-speed operation (≤250 kbit/s) with a two-node wired-AND simulation.

Sub-phases, each with its own gate:

- **3a Pin subsystem ✓** — 24-pin GPIO: output value, output-enable, input,
  atomic set/clear/toggle, latched rising/falling edges, per-pin IRQ enable
  and pending (`lib/pins.ml`).
- **3b Timing ISA ✓** — `DELAY`, `PIN_WAIT`, `PIN_EDGE` as custom instructions
  with a stall mechanism.
- **3c Interrupts ✓** — pin-edge interrupts into `mip.MEIP`.
- **3d UART firmware ✓** — TX (Phase 1) + a firmware RX using `DELAY`,
  against a golden 8N1 model; plus a parity-checking TX/RX and CTS
  flow-control demo.
- **3e SPI firmware ✓** — mode-0 master and slave, each checked both
  directions against a model of the other side.
- **3f I2C firmware ✓** — an open-drain master (write and read paths, with
  START/STOP and ACK/NACK) and a slave at address 0x50 (address decode, ACK,
  write receive and read transmit), each verified against a model of the
  other side.
- **3g CAN firmware ✓** — CAN 2.0A nodes in C: a transmitter
  (`firmware/can.c`) with bit stuffing, CRC-15, arbitration and bit-error
  detection, and a receiver (`firmware/can_rx.c`) that waits for the SOF,
  samples, de-stuffs, decodes, CRC-checks and ACKs a standard data frame. Its
  timing-critical loop is hand-written assembly (`firmware/can_rx_asm.S`) so
  the bit period is exactly constant. Both nodes are verified on a wired-AND
  bus with a peer model. Error handling is demonstrated too: ACK errors grow
  the transmit error counter by 8, an active error frame (6 dominant bits) is
  emitted, and the error-active / error-passive / bus-off thresholds are
  checked.
- **3h Verification ✓** — 15 self-checking tests; protocol golden models;
  generated Verilog is Verilator-lint clean.

**Exit met:** UART, SPI, I2C **and low-speed CAN** are implemented **in
firmware** and verified against independent OCaml golden models.

**Verification:** CAN is verified on a two-node wired-AND bus, exercising
bit stuffing, CRC-15 and arbitration.

**Board:** Phase 3 is simulation-only; no FPGA required.

### Phase 4 — The Watcher (JTAG)

**Goal:** JTAG emulation, in whichever direction is most useful.

- JTAG **TAP target**: 16-state TAP FSM, IR/DR, IDCODE/BYPASS/BSR
- JTAG **host**: bit-banged TCK/TMS/TDI/TDO to program other devices
- Optional capture/analyzer mode (timestamped pin sampling)

**Exit:** emulates a JTAG TAP (IDCODE/BYPASS/BSR verified) and/or masters a
real TAP; TAP FSM formally verified.

**Verification:** formal TAP FSM properties; JTAG state-trace tests.

### Phase 5 — Conduits

**Goal:** Hardware primitives that remove firmware timing bottlenecks.

- Shift engine (bit-serial TX/RX), FIFOs, memory-to-memory DMA, CRC32
- Streaming paths for UART/SPI/JTAG

**Exit:** DMA-streamed transfers at high throughput; CRC matches reference.

**Checkpoint:** run the **first full synthesis** here. Measure mapped cell
area, leave room for clock-tree buffers and routing. *A design that
synthesizes small can still fail to route.*

### Phase 6 — The Ether and the Wire (stretch)

**Goal:** 10 Mbit Ethernet and a hardware CAN 2.0B controller.

Ethernet:
- Digital 10BASE-T MAC: preamble/SFD, FCS (CRC32), address filtering
- **MII to an external PHY** (2.5 MHz TX/RX clock), PHY does Manchester
- RX/TX buffering via DMA/FIFO from Phase 5

CAN:
- Hardware **CAN 2.0B controller** for full-rate (up to 1 Mbit/s) operation:
  bit-timing/prescaler, bit stuffing, CRC-15, ACK, error counters and states
  (error-active/passive/bus-off), acceptance filtering, TX/RX mailboxes
- 2 pins (`CAN_TX`/`CAN_RX`) to an external transceiver (e.g. SN65HVD230,
  TJA1050, MCP2551)

**Exit:** real Ethernet frames transmitted and received (loopback or via an
MII PHY) and real CAN frames exchanged on a bus, both verified against a
reference.

**Fallback:** these are **separable and area-gated**. If the Phase 5 synthesis
checkpoint shows insufficient room for both, ship whichever fits and keep the
other as verified firmware (low-speed CAN) or a Manchester PMA on 2–4 pins.

### Phase 7 — Silicon

**Goal:** Harden to GDSII and submit.

- Integrate with the Tiny Tapeout `cmos5l` template (6×4 tiles)
- Run LibreLane: synthesis, place-and-route, STA, DRC/LVS
- Fix timing and area; add clock-tree and routing headroom

**Exit:** timing-clean, DRC/LVS-clean GDSII; **submission before 18 Jan 2027**.

### Phase 8 — Legacy

**Goal:** Make the work reproducible and open.

- Reproducible verification bundle (simulation, formal, physical evidence)
- README, ISA reference, design writeups, waveform captures
- Tagged, hash-checked release matching the submission

**Exit:** a third party can rebuild the GDSII and re-run the verification
suite from the repository alone.

## Schedule

| Window | Phases | Milestone |
|---|---|---|
| Sep 2026 | 0–1 | Toolchain + first firmware-driven pin |
| Oct 2026 | 2–3 | Real CPU + UART/SPI/I2C/CAN in firmware |
| Nov 2026 | 4 | JTAG target/host |
| Nov–Dec 2026 | 5 | Accelerators + **early synthesis checkpoint** |
| Dec 2026 | 6 | Ethernet + CAN controller (stretch, area-gated) |
| Dec 2026–Jan 2027 | 7 | ASIC hardening, timing closure |
| Jan 2027 | 8 | Verification evidence + submission |

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Design too large to fit | SRAM memories; early synthesis checkpoint; accelerators gated on area |
| Timing closure at target clock | Keep critical paths in hardware; pipeline the core; MII (2.5 MHz) not Manchester |
| Ethernet/CAN controllers do not both fit | Area-gated and separable: firmware CAN (≤250 kbit/s) needs no area; ship whichever hardware controller fits |
| CAN at full rate needs real timing | Hardware controller (not firmware) for ≥500 kbit/s; firmware only for ≤250 kbit/s |
| Verification debt | Evidence required at every phase exit, not retrofitted |
| Schedule slip | Stretch goals (Ethernet) explicitly separable from the core deliverable |
