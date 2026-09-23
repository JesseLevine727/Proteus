# Verification Methodology

The competition says it is *"particularly interested in projects with unique
functionality, as well as those that demonstrate novel approaches to design
and verification methodologies."* Verification is therefore a **first-class
deliverable**, not a cleanup step.

This document is the contract for how Proteus is verified, at every layer,
with evidence gated at each phase.

## Principles

1. **Every claim has evidence.** A feature is "done" only when a test,
   property or measurement proves it, and the evidence is retained.
2. **Independent references.** Protocols are checked against **independently
   written golden models**, not against themselves.
3. **Layers, not one big test.** Small blocks are proven in isolation before
   they are composed.
4. **Reproducible.** Every result is regenerable from the repository with
   fixed seeds and recorded tool versions.

## Layers

| # | Layer | What it proves | Status |
|---|---|---|---|
| 1 | **Unit tests** (Hardcaml `Cyclesim`) | Each RTL block behaves as specified | ✅ 21 tests |
| 2 | **Golden models** (OCaml) | Protocols match an independent reference | ✅ UART/SPI/I2C/CAN/1-Wire |
| 3 | **Two-node / differential** | Real bus interaction (CAN wired-AND, I2C pull-ups, SPI master↔slave) | ✅ |
| 4 | **RTL co-simulation** | Hardcaml and Verilator agree on every vector | ⬜ planned |
| 5 | **Formal properties** | Invariants hold for *all* inputs, not samples | ⬜ planned |
| 6 | **Constrained-random fuzzing** | Robustness to random traffic and timing | ⬜ planned |
| 7 | **AI-assisted verification** | LLM-generated tests/invariants, human-reviewed | ⬜ planned |
| 8 | **FPGA-to-ASIC validation** | Works on real pins before the ASIC flow | ⬜ planned |
| 9 | **Post-synthesis equivalence** | The netlist matches the RTL | ⬜ planned |
| 10 | **Evidence bundle** | Hash-checked, reproducible | ⬜ planned |

## Layer detail

### 5. Formal properties

Target the small, safety-critical blocks first:

| Block | Property |
|---|---|
| ALU | output matches a reference function for **all** operand pairs |
| Register file | `x0` reads zero; writes are single-cycle and conflict-free |
| Pin fabric | atomic set/clear/toggle commute correctly; edge latches never drop a single-cycle pulse |
| Stall logic (`DELAY`/`PIN_WAIT`/`PIN_EDGE`) | the stall always terminates within the timeout; the instruction retires **exactly once**; no register/memory write occurs while stalled |
| Trap logic | `mepc`/`mcause`/`mstatus` update per spec; `MRET` restores exactly |
| Capture FSM | no event is lost within the documented rate; buffer bounds respected |
| JTAG TAP FSM | the 16-state machine matches the IEEE 1149.1 state diagram |

Tools: `hardcaml_verify` and/or SymbiYosys on the generated Verilog.

### 6. Constrained-random fuzzing

Seeded generators feed random bytes, random bit timing and random bus
contention into the firmware/peer models; results are checked against the
golden models. Seeds are recorded so failures reproduce.

### 7. AI-assisted verification

An LLM is used to propose test cases, invariants and protocol edge cases
(e.g. framing errors, arbitration loss, clock stretching, stuff-bit runs).
Every proposal is **human-reviewed** and only kept if it adds real coverage.
The method — including what it got wrong — is documented, so the claim is
honest rather than hand-wavy.

### 8. FPGA-to-ASIC

The synthesized design is brought up on a **PYNQ-Z1** and exercised with real
pins and real peripherals *before* the ASIC flow. This retires the "never ran
on hardware" risk and produces physical evidence.

### 9. Post-synthesis equivalence

After synthesis, the gate-level netlist is simulated against the same vectors
as the RTL (or checked with a sequential equivalence tool) so the ASIC flow
cannot silently change behaviour.

### 10. Evidence bundle

A tagged, hash-checked directory containing raw records, tool versions, seeds
and reports, such that a third party can rebuild the GDSII and re-run the
whole suite from the repository alone.

## Generality as verification

The 1-Wire implementation is verification of the *thesis*: a protocol the
chip was never designed for runs in firmware with **no RTL change**. It is
kept as a permanent regression so generality cannot silently regress.
