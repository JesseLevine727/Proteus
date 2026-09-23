# Early synthesis / area check

An early synthesis pass to see whether the current SoC can fit the Tiny
Tapeout budget, **before** adding more features.

## Method

- Tool: `yosys` 0.62 (from the LibreLane Docker image).
- Input: the generated `rtl/proteus_soc.v`.
- Flow: `proc; opt; fsm; opt; memory; opt; techmap; dfflibmap; abc`.
- Library: **SkyWater SKY130** `sky130_fd_sc_hd__tt_025C_1v80` as a **proxy**
  for the target IHP SG13G2 130 nm process (the IHP PDK is not installed
  locally; both are ~130 nm standard-cell processes, so the comparison is
  indicative, not exact).

## Result

| Metric | Value |
|---|---|
| Mapped standard cells | 77,299 |
| Flip-flops | **18,193** |
| Total area (SKY130 proxy) | **0.649 mm²** |
| Flip-flop area | 0.364 mm² (56 %) |
| Combinational logic | 0.285 mm² |
| 6×4 tile budget | ~0.72 mm² nominal |

The design sits at roughly **90 % of the nominal tile area**, and that is
**before** place-and-route overhead (routing, clock tree, tap cells, antenna
diodes), which typically adds 30–50 %. **As-is, it will not fit.**

## What dominates

The **register-array memories**. The data RAM alone (512 × 32 = 16 K flops) is
about 0.33 mm², and the instruction memory — currently constant-folded to a
combinational ROM because the bootloader is disabled in this build — accounts
for much of the remaining logic. The core and peripherals are comparatively
small.

A note on SRAM: the SKY130 1 KiB / 2 KiB SRAM macros are **190,713 µm²** and
**284,538 µm²** (0.19 / 0.28 mm²). For these small sizes SRAM is only
*marginally* denser than flops, so SRAM alone is not a silver bullet — the
memories have to be **right-sized** first.

## Actions for Phase 5

1. **Right-size the data RAM.** 2 KiB is generous; the largest firmware (CAN)
   needs < 1 KiB. Halving or quartering it saves 0.16–0.25 mm².
2. **Decide the instruction memory.** The bootloader (runtime
   reprogrammability, which the competition requires) needs it writable.
   Compare flops vs an SRAM macro at the final size.
3. **Shrink the core.** RV32E (16 registers) trims the register file and the
   read muxes.
4. **Re-run this check** after each change, and only then attempt the full
   LibreLane place-and-route.

## Takeaway

The architecture is sound, but the **memories must be right-sized and the
core trimmed** before tape-out. This is exactly the Phase 5 checkpoint the
roadmap called for, and it is better to learn it now than at the deadline.
