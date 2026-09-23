# Proteus Roadmap

Proteus is a **bidirectional, firmware-defined protocol engine**: a small,
open-source ASIC built around a tiny custom RISC-V micro-core whose
instruction set is designed for reading pins, writing pins, counting cycles
and hitting timing precisely enough that real hardware protocols are
implemented as *programs* rather than fixed logic blocks.

It works in **both directions**:

- **Emulate** — drive a bus, in firmware (UART, SPI, I2C, CAN, 1-Wire, JTAG).
- **Analyze** — capture a bus with timestamps and decode it, in firmware
  (the reverse-engineering half of the use case Jane Street describes).

The chip is reprogrammable **after fabrication**, so protocols that did not
exist when the die was taped out can be supported within its timing and I/O
constraints.

> **Research question:** How much of a general-purpose protocol tool —
> emulator *and* analyzer — can be built as firmware on a tiny RISC-V core,
> and where must hardware assist be introduced to meet timing and area?

## What makes this distinctive

1. **Bidirectional** — emulate **and** analyze on the same pins. The PIO/PRU
   references are transmit/receive engines; a timestamped capture subsystem
   makes Proteus a debugging and reverse-engineering tool, which is exactly
   the use case the competition names.
2. **Generality, proven** — 1-Wire (nothing like the named protocols) runs in
   firmware with no RTL change.
3. **Verification as a methodology** — formal, constrained-random,
   differential co-simulation, AI-assisted test generation and FPGA-to-ASIC
   validation, bundled reproducibly. The competition explicitly rewards
   novel verification approaches.

## Phasing principle

Phases 0–3 answered *"can firmware emulate protocols?"* — **yes**. Phases 4–8
answer *"can we build a bulletproof chip?"* — where the remaining risk lives.
The plan is **risk-first**:

> **Fit → Flow → Bidirectional → Verification → Stretch → Submit.**

Feature work is gated on area and on the flow working. Verification is a
**first-class, gated track at every phase**, not a cleanup step.

## Design constraints

| Constraint | Value | Consequence |
|---|---|---|
| Process | IHP SG13G2 / CMOS5L via Tiny Tapeout | `ttihp-verilog-template` (`cmos5l`) |
| Area | 6×4 tiles ≈ 0.72 mm² (8×4 may add ~30 %) | **Measured: current SoC is 2.16× over** |
| Pins | 24 signals: `ui_in[7:0]`, `uo_out[7:0]`, `uio[7:0]` | Ethernet needs MII-to-PHY; CAN needs a transceiver (2 pins) |
| Clock | ~25–100 MHz at this node | MII at 10 Mbit (2.5 MHz) is comfortable |
| Deadline | 18 January 2027 | Risk-weighted schedule below |

**Area reality (measured, IHP SG13G2):** 90,492 cells, 18,193 flip-flops,
**1.555 mm²** — 2.16× budget. IHP **SRAM macros are ~10× denser** (2 KiB =
0.080 mm²). Full numbers: [`synthesis-check.md`](synthesis-check.md).

## Architecture at a glance

```
                          PROTEUS
   +--------------------------------------------------------+
   |  RV32E core                                            |
   |   - RV32I subset + Zicsr + machine traps/MRET          |
   |   - custom-0 ISA:  DELAY | PIN_WAIT | PIN_EDGE         |
   |   - mcycle/minstret, timer & pin-edge interrupts       |
   +---------------------------+----------------------------+
                               |
                     +---------+---------+
                     |    Memories       |  I-SRAM (writable)
                     | (IHP SRAM macros) |  D-SRAM + capture buffer
                     +---------+---------+
                               |
   +---------------------------+----------------------------+
   |  Programmable pin fabric (24 pins)                     |
   |   atomic set/clr/toggle, output-enable, input,         |
   |   latched edges, per-pin IRQ, open-drain               |
   |   + CAPTURE: trigger | timestamp | transition log      |  <-- analyze
   +---------------------------+----------------------------+
                               |
   +---------------------------+----------------------------+
   |  Support: timer | debug UART | hardware bootloader     |
   +---------------------------+----------------------------+
   |  Protocol-agnostic primitives (Phase 7, area-gated):   |
   |   DMA | configurable CRC | shift/FIFO | Manchester     |
   +--------------------------------------------------------+
```

There is **no hardware protocol block** on the emulation path. The only
protocol-ish hardware is the *debug* UART (console/boot channel).

## Cross-cutting tracks

### Track V — Verification (first-class, gated)

Every phase adds evidence; nothing is retrofitted. See
[`verification.md`](verification.md) for the full methodology.

- **Unit & golden models** — cycle-accurate Hardcaml tests; independent OCaml
  models for every protocol (**21 self-checking tests today**).
- **Differential co-simulation** — Hardcaml ↔ Verilator must agree on every
  test vector.
- **Formal** — `hardcaml_verify` / SymbiYosys properties for the pin fabric,
  the wait/delay stall logic, the capture FSM, the TAP FSM and CSR/trap
  logic.
- **Constrained-random** — protocol fuzzers against golden models; seeded and
  reproducible.
- **AI-assisted** — LLM-generated test cases, invariants and protocol models,
  with human review; the method and its limits documented.
- **FPGA-to-ASIC** — validate the synthesized design on a PYNQ-Z1 with real
  pins and real peripherals *before* the ASIC flow.
- **Evidence bundle** — hash-checked, reproducible from the repository alone.

### Track G — Generality

A protocol the chip was **not** designed for, in firmware, no RTL change.
**1-Wire done** (`firmware/onewire.c`).

### Track T — Tooling & docs

Assembler/loader, firmware build, Tiny Tapeout hardening, architecture/ISA
references.

## Phases

Each phase must **boot, execute its tests and pass regressions** before the
next begins. A smaller system that is fully understood beats a larger one
whose failures cannot be isolated.

### Phase 0 — Foundations ✓

Reproducible OCaml/Hardcaml toolchain; first verified design (UART TX).

### Phase 1 — First Light ✓

Minimal RV32I core drives a pin from firmware; bit-banged UART decoded back in
cycle-accurate simulation.

### Phase 2 — Voice ✓

Full RV32I + Zicsr + traps + MRET; counters and interrupts; debug UART;
hardware bootloader loading the writable instruction RAM; C toolchain.
Compiled C prints over the UART, direct and booted.

### Phase 3 — Reflexes ✓

Pin fabric (atomic ops, edges, per-pin IRQ), timing ISA (`DELAY`/`PIN_WAIT`/
`PIN_EDGE`), and protocols in firmware: UART (TX/RX, parity, flow control),
SPI (master + slave), I2C (master write/read + slave), CAN (TX with stuffing,
CRC-15, arbitration, error confinement; RX with de-stuff, CRC, ACK), and the
1-Wire generality proof. **21 self-checking tests.** Simulation-only.

### Phase 4 — Fit *(critical path)*

**Goal:** make the design fit the IHP 6×4 budget **including the capture
subsystem**, with headroom.

- Move instruction and data memories to **IHP SRAM macros**
  (`RM_IHPSG13_*`), synchronous, and **pipeline the fetch path** (removes the
  combinational ROM mux).
- Add the **capture buffer** to the memory budget.
- **Right-size the data RAM**; **trim the core to RV32E**.

**Exit:** ≥ 20 % area headroom under 0.72 mm²; all 21 tests pass.
**Verification gate:** area report + full regression.

### Phase 5 — Flow & silicon validation *(critical path)*

**Goal:** prove the end-to-end flow and validate on real silicon-like
hardware.

- **FPGA-to-ASIC:** synthesize the design onto a **PYNQ-Z1**, drive real pins,
  run UART/SPI/I2C on real hardware, measure achievable clock.
- Integrate the Tiny Tapeout **`cmos5l`** template (`info.yaml`, tile size,
  24-pin mapping, GDS Action).
- Run **LibreLane** end-to-end on the local IHP PDK: synth → floorplan →
  place → CTS → route → STA → DRC/LVS. **Minimal config first**, then full.

**Exit:** FPGA bring-up evidence **and** a DRC/LVS-clean **GDSII** with a
passing GDS Action.
**Verification gate:** co-simulation (Hardcaml ↔ Verilator) + post-synthesis
equivalence.

### Phase 6 — Bidirectional

**Goal:** Proteus captures and decodes, not just drives.

- **Capture/analyzer subsystem** — trigger (pin pattern/edge), cycle
  timestamp, transition log into the capture buffer, overflow handling.
- **Analyzer firmware** — decode captured traffic into protocols (start with
  UART/SPI/I2C, extend to CAN).
- **JTAG** — TAP target (16-state FSM, IR/DR, IDCODE/BYPASS/BSR) and/or host.

**Exit:** capture a live bus and decode it in firmware; JTAG verified.
**Verification gate:** **formal** proofs of the capture FSM and TAP FSM;
constrained-random capture tests.

### Phase 7 — Stretch: the Ether

**Goal:** 10 Mbit Ethernet, built as firmware on protocol-agnostic primitives.

- Preamble/SFD, FCS via the configurable CRC, address filtering, MII framing,
  DMA moving frames. **No hardware MAC.**
- Optional generic Manchester line code.

**Exit:** frames transmitted and received (loopback or MII PHY), verified
against a reference. **Fallback:** primitives stand alone; Ethernet stays a
firmware target.

### Phase 8 — Verification campaign & submission

**Goal:** bulletproof evidence and a submitted chip.

- Run the **full Track V campaign**: formal suite, constrained-random fuzz,
  differential co-simulation, AI-assisted tests, FPGA-to-ASIC evidence.
- Assemble the **hash-checked reproducible evidence bundle**.
- Public repo, tagged release, submission **before 18 January 2027**.

**Exit:** a third party can rebuild the GDSII and re-run the entire
verification suite from the repository alone; submission accepted.

## Schedule (risk-weighted)

| Window | Phase | Milestone |
|---|---|---|
| Sep 2026 | 0–3 ✓ | Toolchain, core, protocols in firmware, generality proof |
| Sep–Oct 2026 | **4 — Fit** | SRAM memories, pipelined fetch, RV32E, area headroom |
| Oct 2026 | **5 — Flow** | FPGA bring-up + minimal GDSII end-to-end, then full |
| Nov 2026 | 6 — Bidirectional | Capture/analyzer + JTAG, formally verified |
| Nov–Dec 2026 | 7 — Stretch | Ethernet on the primitives |
| Dec 2026 | 5/4 | Hardening: timing closure, final GDS, re-run area check |
| Jan 2027 | 8 — Campaign | Full verification campaign + submission |

The ASIC flow and FPGA bring-up start **immediately** (minimal config, in
parallel with Phase 4) rather than after all features.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| **Design 2.16× over area** | Phase 4: SRAM macros (~10× denser), pipelined fetch, RV32E, right-sizing |
| **ASIC flow never run** | Phase 5 starts a minimal LibreLane run immediately; FPGA bring-up first |
| Capture subsystem does not fit | Budgeted in Phase 4; capture is a small buffer + FSM |
| Timing closure at target clock | Pipeline the fetch; MII at 2.5 MHz |
| Formal properties too hard | Start with the small blocks (stall logic, capture FSM, TAP FSM) |
| Ethernet does not fit | Explicitly separable stretch |
| Verification debt | Gated at every phase; the campaign is a phase, not an afterthought |
| Schedule slip | Stretch separable; the core deliverable (fit + flow + submission) protected |
| 8×4 tiles unavailable | Design to 6×4; treat 8×4 as headroom if it lands |
