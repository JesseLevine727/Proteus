# Early synthesis / area check

An early synthesis pass to see whether the current SoC can fit the Tiny
Tapeout budget, **before** adding more features.

## Method

- Tool: `yosys` 0.62 (from the LibreLane 3.0.14 Docker image).
- Input: the generated `rtl/proteus_soc.v`.
- Flow: `proc; opt; fsm; opt; memory; opt; techmap; opt; dfflibmap; abc; opt`.
- Library: **IHP SG13G2** `sg13g2_stdcell_typ_1p20V_25C` (the target process),
  fetched with `ciel` (`ihp-sg13g2`, also carrying the `ihp-sg13cmos5l`
  variant). A SKY130 run was done first as a cross-check.

## Result (IHP SG13G2, the real target)

| Metric | Value |
|---|---|
| Mapped standard cells | 90,492 |
| Flip-flops | **18,193** (`sg13g2_dfrbpq_1`, 48.99 µm² each) |
| Flip-flop area | **0.891 mm²** |
| Combinational logic | 0.664 mm² |
| **Total area** | **1.555 mm²** |
| 6×4 tile budget | ~0.72 mm² nominal |
| **Ratio** | **2.16× the budget** |

(SKY130 mapped to 0.649 mm²; its cells are ~2.5× smaller, so IHP is the
binding constraint. The design is over budget either way.)

## What dominates, and the way out

1. **The register-array data RAM** (512 × 32 = 16 K flops) is ~0.80 mm² of
   the 1.56 mm² — over half.
2. **The instruction memory** is a combinational ROM in this build (the
   bootloader is disabled), so it is a large mux in the 0.66 mm² of logic.

The IHP **SRAM macros are ~10× denser than flops** at these sizes:

| Macro | Size | Area |
|---|---|---|
| `RM_IHPSG13_1P_512x32_c2` | 2 KiB | 0.080 mm² |
| `RM_IHPSG13_1P_256x32_c2` | 1 KiB | 0.049 mm² |

So moving the data RAM to a 2 KiB SRAM saves **~0.72 mm²** by itself, and a
synchronous instruction SRAM removes both the ROM mux and the fetch-critical
path. That is the Phase 5 plan.

## Actions for Phase 5

1. **Move the memories to IHP SRAM macros** (synchronous), and pipeline the
   fetch path. This is the single biggest win.
2. **Right-size the data RAM** — the largest firmware (CAN) needs < 1 KiB.
3. **Trim the core to RV32E** (16 registers) to shrink the register file and
   read muxes.
4. **Re-run this check** after each change, then attempt full place-and-route.

## Takeaway

The architecture is sound, but at ~2.2× the IHP area budget the **register-
array memories must become SRAM macros** and the core should be trimmed before
tape-out. Finding this now, at the Phase 5 checkpoint, is exactly why the
check exists.
