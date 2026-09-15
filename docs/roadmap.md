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
| Pins | 24 signals: `ui_in[7:0]`, `uo_out[7:0]`, `uio[7:0]` | Ethernet needs MII-to-PHY; full MII uses most pins |
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
   |  shift engine | FIFO | DMA | CRC32 | Manchester   |
   +---------------------------------------------------+
```

Protocols are firmware: UART, SPI, I2C, PS/2, SWD and JTAG are programs.
Hardware accelerators are introduced only where firmware cannot meet timing
(notably 10 Mbit Ethernet).

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

### Phase 1 — First Light

**Goal:** A minimal core executes hand-assembled code and drives a pin.

- ISA specification (`docs/architecture.md`): register set, encodings,
  custom I/O/timing instructions
- Minimal core: fetch/decode/execute, small instruction SRAM, GPIO
- Assembler (or hand-encoded program) and a simulation testbench

**Exit:** a hand-written program emits UART TX on a GPIO pin entirely in
firmware, verified in cycle-accurate simulation with waveform evidence.

**Verification:** directed instruction tests; trace comparison against a
reference execution model.

### Phase 2 — Voice

**Goal:** A complete CPU and a real firmware toolchain.

- Full RV32I(-E) datapath, branches/jumps, loads/stores, CSRs
- `mcycle`/`minstret` counters, traps and interrupts
- RISC-V GCC/clang assembles firmware; a bootloader loads code over UART

**Exit:** compiled C prints over UART in simulation and the same image is
loaded by the bootloader.

**Verification:** RISC-V ISA test vectors; bootloader protocol tests.

### Phase 3 — Reflexes

**Goal:** Programmable I/O and precise timing, protocols in firmware.

- Memory-mapped GPIO with atomic set/clear/toggle and input capture
- `PIN_WAIT` (level/edge with timeout), `DELAY`, cycle-accurate scheduling
- Interrupt controller: pin edges and timer compare

**Exit:** UART, SPI and I2C are all implemented **in firmware** and pass
loopback tests against OCaml golden models.

**Verification:** protocol golden models; timing-accuracy assertions.

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

### Phase 6 — The Ether (stretch)

**Goal:** 10 Mbit Ethernet.

- Digital 10BASE-T MAC: preamble/SFD, FCS (CRC32), address filtering
- **MII to an external PHY** (2.5 MHz TX/RX clock), PHY does Manchester
- RX/TX buffering via DMA/FIFO from Phase 5

**Exit:** real Ethernet frames transmitted and received (loopback or via an
MII PHY), verified against a reference.

**Fallback:** if area/timing do not allow a MAC, demonstrate a Manchester
PMA on 2–4 pins, or defer Ethernet and ship a fully verified JTAG + multi-
protocol emulator.

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
| Oct 2026 | 2–3 | Real CPU + UART/SPI/I2C in firmware |
| Nov 2026 | 4 | JTAG target/host |
| Nov–Dec 2026 | 5 | Accelerators + **early synthesis checkpoint** |
| Dec 2026 | 6 | Ethernet (stretch) |
| Dec 2026–Jan 2027 | 7 | ASIC hardening, timing closure |
| Jan 2027 | 8 | Verification evidence + submission |

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Design too large to fit | SRAM memories; early synthesis checkpoint; accelerators gated on area |
| Timing closure at target clock | Keep critical paths in hardware; pipeline the core; MII (2.5 MHz) not Manchester |
| Ethernet does not fit | Fallback to Manchester PMA or defer; JTAG + multi-protocol is already novel |
| Verification debt | Evidence required at every phase exit, not retrofitted |
| Schedule slip | Stretch goals (Ethernet) explicitly separable from the core deliverable |
