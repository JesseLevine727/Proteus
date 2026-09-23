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

## Phasing principle

Phases 0–3 answered *"can firmware emulate protocols?"* — **yes**. Phases 4–8
answer *"can we actually make a chip?"* — and that is where the remaining risk
and the deadline live. So the plan is **risk-first**:

> **Fit → Flow → features → submit.**

Concretely: make the design fit the area budget (Phase 4), prove the ASIC flow
end-to-end on the target process (Phase 5), *then* add breadth (Phase 6) and
stretch goals (Phase 7), and finish with evidence and submission (Phase 8).
Feature work is deliberately gated on area and on the flow working.

## Design constraints

| Constraint | Value | Consequence |
|---|---|---|
| Process | IHP SG13G2 / CMOS5L via Tiny Tapeout | `ttihp-verilog-template` (`cmos5l`) |
| Area | 6×4 tiles ≈ 0.72 mm² (8×4 may become available, +30 %) | **Measured: the current SoC is 2.16× over** — see below |
| Pins | 24 signals: `ui_in[7:0]`, `uo_out[7:0]`, `uio[7:0]` | Ethernet needs MII-to-PHY; CAN needs an external transceiver (2 pins) |
| Clock | ~25–100 MHz achievable at this node | MII at 10 Mbit (2.5 MHz) is comfortable |
| Deadline | 18 January 2027 | Risk-weighted schedule below |

**Area reality (measured, IHP SG13G2):** 90,492 cells, 18,193 flip-flops,
**1.555 mm²** — 2.16× the budget. The register-array data RAM alone is
~0.80 mm². IHP **SRAM macros are ~10× denser** (2 KiB = 0.080 mm²), so the
memories must move to SRAM macros. Full numbers:
[`synthesis-check.md`](synthesis-check.md).

## Architecture at a glance

```
                       PROTEUS
   +---------------------------------------------------+
   |  RV32E core  (custom pin/timing instructions)      |
   |  - cycle counter CSR, fast IRQ                     |
   +-------------------------+-------------------------+
                             |
                    +--------+--------+
                    |  Memory system  |   <-- IHP SRAM macros (Phase 4)
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
   |   Protocol-agnostic primitives (only if they fit) |
   |   DMA | configurable CRC | shift/FIFO | Manchester|
   +---------------------------------------------------+
```

Protocols are firmware: UART, SPI, I2C, CAN, 1-Wire and JTAG are programs.
There is **no hardware protocol block** on the emulation path. Accelerators
are generic primitives that firmware *composes* into high-speed protocols —
added only where timing demands **and** area allows.

## Cross-cutting tracks

1. **Verification** — a first-class deliverable, gated at every phase, never
   retrofitted. The competition explicitly rewards verification methodology.
   - Cycle-accurate Hardcaml unit tests; **21 self-checking tests today**
   - **Golden models** in OCaml for every protocol (UART/SPI/I2C/CAN/1-Wire)
   - **Two-node** wired-AND simulations (CAN arbitration, bit stuffing)
   - **Formal** properties (`hardcaml_verify` / SymbiYosys) for state
     machines and protocol invariants
   - RTL co-simulation (Hardcaml vs Verilator) before hardening
2. **Generality** — evidence that protocols the chip was never designed for
   run in firmware with no RTL change (1-Wire; see below).
3. **Tooling** — assembler/loader, firmware build, Tiny Tapeout hardening flow.
4. **Documentation** — architecture, ISA reference, verification records.

## Phases

Each phase must **boot, execute its tests and pass regressions** before the
next begins. A smaller system that is fully understood beats a larger one
whose failures cannot be isolated.

### Phase 0 — Foundations ✓

Reproducible OCaml/Hardcaml toolchain; first verified design (UART TX,
decoded back to a byte in simulation).

### Phase 1 — First Light ✓

A minimal RV32I core executes hand-assembled firmware and drives a pin; the
firmware bit-bangs an 8N1 UART frame, decoded back in cycle-accurate
simulation.

### Phase 2 — Voice ✓

Full RV32I + Zicsr + machine traps + MRET; `mcycle`/`minstret`; machine
software/timer/external interrupts; a debug UART; a **hardware bootloader**
that loads the writable instruction RAM at run time; and a
`riscv32-unknown-elf-gcc` toolchain. Compiled C prints over the UART, direct
and booted.

### Phase 3 — Reflexes ✓

Programmable I/O and precise timing; protocols in firmware.

- **Pin subsystem** — 24-pin GPIO with atomic set/clear/toggle, output-enable,
  latched edges and per-pin interrupts (`lib/pins.ml`).
- **Timing ISA** — `DELAY`, `PIN_WAIT`, `PIN_EDGE` custom instructions with a
  stall mechanism (`lib/cpu.ml`).
- **Protocols in firmware** — UART (TX/RX, parity, CTS flow control), SPI
  (master + slave), I2C (master write/read + slave), CAN (TX with stuffing,
  CRC-15, arbitration, error confinement; RX with de-stuffing, CRC, ACK —
  timing loop in hand-written assembly).
- **Generality proof** — **1-Wire** (`firmware/onewire.c`): single-wire,
  open-drain, microsecond timing, nothing like the named protocols, running
  on the same pin subsystem and timing ISA with no RTL change.

**Exit met:** all of the above verified against independent OCaml golden
models. **21 self-checking tests.** Simulation-only; no FPGA required.

### Phase 4 — Fit *(critical path)*

**Goal:** make the design fit the IHP 6×4 area budget with headroom.

- Move instruction and data memories to **IHP SRAM macros** (`RM_IHPSG13_*`),
  synchronous, and **pipeline the fetch path** (also removes the large
  combinational ROM mux).
- **Right-size the data RAM** — the largest firmware (CAN) needs < 1 KiB.
- **Trim the core to RV32E** (16 registers).
- Re-run the area check after each change.

**Exit:** the mapped area has **≥ 20 % headroom** under 0.72 mm², and all 21
simulation tests still pass. **Evidence:** `synthesis-check.md` updated.

### Phase 5 — Flow *(critical path)*

**Goal:** prove the end-to-end ASIC flow on the real process.

- Integrate the Tiny Tapeout **`cmos5l`** template: `info.yaml`, tile size,
  the 24-pin mapping, the GDS GitHub Action.
- Run **LibreLane**: synthesis → floorplan → placement → CTS → routing → STA
  → DRC/LVS, using the locally installed IHP PDK.
- **De-risk by running a minimal configuration end-to-end first**, then the
  full design.

**Exit:** a **GDSII** produced, DRC/LVS clean, and the GDS Action passing in
CI. Never having run the flow is itself a top risk — this phase retires it.

### Phase 6 — Breadth

**Goal:** the remaining named protocol and any primitives that fit.

- **JTAG** — TAP target (16-state FSM, IR/DR, IDCODE/BYPASS/BSR) and/or host;
  **formal verification** of the TAP FSM.
- **Protocol-agnostic primitives** — DMA, configurable CRC, shift/FIFO —
  **only if Phase 4/5 leave area**.

**Exit:** JTAG verified (formal + state traces); area still fits.

### Phase 7 — Stretch: the Ether

**Goal:** 10 Mbit Ethernet, built as firmware on the primitives.

- Preamble/SFD, FCS via the CRC unit, address filtering, MII framing, DMA
  moving frames. **No hardware MAC.**
- Optional Manchester line code as a generic primitive.

**Exit:** frames transmitted and received (loopback or via an MII PHY),
verified against a reference.

**Fallback:** the primitives stand alone as the acceleration story; Ethernet
stays a firmware target.

### Phase 8 — Legacy

**Goal:** reproducible, open, submitted.

- Reproducible **verification bundle** (simulation, formal, physical evidence)
- README, ISA reference, design writeups, waveform captures
- Public repo, tagged and hash-checked, matching the submission

**Exit:** a third party can rebuild the GDSII and re-run the verification
suite from the repository alone; **submitted before 18 January 2027**.

## Schedule (risk-weighted)

| Window | Phase | Milestone |
|---|---|---|
| Sep 2026 | 0–3 ✓ | Toolchain, core, protocols in firmware, generality proof |
| Sep–Oct 2026 | **4 — Fit** | SRAM memories, pipelined fetch, RV32E, area headroom |
| Oct 2026 | **5 — Flow** | Minimal GDSII end-to-end, then the full design |
| Nov 2026 | 6 — Breadth | JTAG (+ primitives if they fit) |
| Nov–Dec 2026 | 7 — Stretch | Ethernet on the primitives |
| Dec 2026 | 5/4 | Hardening: timing closure, final GDS, re-run area check |
| Jan 2027 | 8 — Legacy | Verification evidence + submission |

The ASIC flow starts **now** (on a minimal configuration, in parallel with
Phase 4) rather than after all features — the flow is the biggest unknown.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| **Design 2.16× over area** | Phase 4: SRAM macros (~10× denser), pipelined fetch, RV32E, right-sizing |
| **ASIC flow never run** | Phase 5 starts a minimal end-to-end LibreLane run immediately |
| Timing closure at target clock | Pipeline the fetch; keep critical paths in hardware; MII at 2.5 MHz |
| JTAG/accelerators do not fit | Area-gated: JTAG firmware first, primitives only with headroom |
| Ethernet does not fit | Explicitly separable stretch; primitives still ship |
| Verification debt | Evidence required at every phase exit, not retrofitted |
| Schedule slip | Stretch goals separable; the core deliverable (fit + flow + submission) is protected |
| 8×4 tiles unavailable | Design to 6×4; treat 8×4 as headroom if it lands |
