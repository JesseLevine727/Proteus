(* Synchronous single-port RAM, with two implementations behind a flag:

   - [Behavioral]  — a Hardcaml register array, used by [Cyclesim] so the
     whole test suite keeps running without a Verilog simulator.
   - [Ihp_256x32] / [Ihp_512x32] — a Hardcaml [Instantiation] of the IHP
     SG13G2 SRAM macro, used for synthesis (the macro is a foundry hard macro;
     Hardcaml emits the instantiation).

   Interface mirrors the IHP macro: [men] enables, [we]/[re] select write or
   read, [bm] is a per-byte write mask, and reads are registered (1-cycle
   latency). The controller must not assert [we] and [re] together. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; addr : 'a [@bits 32]
    ; din : 'a [@bits 32]
    ; bm : 'a [@bits 32]
    ; we : 'a
    ; re : 'a
    ; men : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { dout : 'a [@bits 32] } [@@deriving hardcaml]
end

type impl =
  | Behavioral
  | Ihp_256x32
  | Ihp_512x32

let clog2 n =
  let rec go b = if 1 lsl b >= n then b else go (b + 1) in
  go 0
;;

(* per-bit masked merge of [din] into [cur] where [bm] is high. [bm] matches
   the IHP macro's A_BM: bit i selects data bit i. *)
let merge_bytes cur din bm =
  let one i =
    Signal.mux2 (Signal.select bm i i) (Signal.select din i i) (Signal.select cur i i)
  in
  Signal.concat_msb (List.init 32 (fun k -> one (31 - k)))
;;

(* expand a 4-bit byte strobe into a 32-bit per-bit mask *)
let strobe_to_bm wstrb =
  Signal.concat_msb
    [ Signal.concat_msb [ Signal.select wstrb 3 3; Signal.select wstrb 3 3; Signal.select wstrb 3 3; Signal.select wstrb 3 3; Signal.select wstrb 3 3; Signal.select wstrb 3 3; Signal.select wstrb 3 3; Signal.select wstrb 3 3 ]
    ; Signal.concat_msb [ Signal.select wstrb 2 2; Signal.select wstrb 2 2; Signal.select wstrb 2 2; Signal.select wstrb 2 2; Signal.select wstrb 2 2; Signal.select wstrb 2 2; Signal.select wstrb 2 2; Signal.select wstrb 2 2 ]
    ; Signal.concat_msb [ Signal.select wstrb 1 1; Signal.select wstrb 1 1; Signal.select wstrb 1 1; Signal.select wstrb 1 1; Signal.select wstrb 1 1; Signal.select wstrb 1 1; Signal.select wstrb 1 1; Signal.select wstrb 1 1 ]
    ; Signal.concat_msb [ Signal.select wstrb 0 0; Signal.select wstrb 0 0; Signal.select wstrb 0 0; Signal.select wstrb 0 0; Signal.select wstrb 0 0; Signal.select wstrb 0 0; Signal.select wstrb 0 0; Signal.select wstrb 0 0 ]
    ]
;;

let behavioral ~abits ~size (i : Signal.t I.t) : Signal.t O.t =
  let reg_spec = Reg_spec.create ~clock:i.clock () in
  let a = Signal.select i.addr (abits - 1) 0 in
  let word idx =
    let enable = i.we &: i.men &: (a ==:. idx) in
    Signal.reg_fb reg_spec ~enable ~width:32 ~f:(fun cur ->
      merge_bytes cur i.din i.bm)
  in
  let words = Array.init size word in
  let rd = Signal.mux a (Array.to_list words) in
  let dout = Signal.reg reg_spec ~enable:(i.re &: i.men) rd in
  { O.dout }
;;

let ihp_macro ~name ~abits (i : Signal.t I.t) : Signal.t O.t =
  let gnd = Signal.gnd in
  let z n = Signal.zero n in
  let m =
    Instantiation.create
      ~name
      ~inputs:
        [ "A_CLK", i.clock
        ; "A_MEN", i.men
        ; "A_WEN", i.we
        ; "A_REN", i.re
        ; "A_ADDR", Signal.select i.addr (abits - 1) 0
        ; "A_DIN", i.din
        ; "A_DLY", gnd
        ; "A_BM", i.bm
        ; "A_BIST_CLK", gnd
        ; "A_BIST_EN", gnd
        ; "A_BIST_MEN", gnd
        ; "A_BIST_WEN", gnd
        ; "A_BIST_REN", gnd
        ; "A_BIST_ADDR", z abits
        ; "A_BIST_DIN", z 32
        ; "A_BIST_BM", z 32
        ]
      ~outputs:[ "A_DOUT", 32 ]
      ()
  in
  { O.dout = Base.Map.find_exn m "A_DOUT" }
;;

let create ~impl ~size (i : Signal.t I.t) : Signal.t O.t =
  let abits = clog2 size in
  match impl with
  | Behavioral -> behavioral ~abits ~size i
  | Ihp_256x32 -> ihp_macro ~name:"RM_IHPSG13_1P_256x32_c2_bm_bist" ~abits i
  | Ihp_512x32 -> ihp_macro ~name:"RM_IHPSG13_1P_512x32_c2_bm_bist" ~abits i
;;
