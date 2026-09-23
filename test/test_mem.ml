(* Memory abstraction test.

   - Behavioral: cycle-accurate read/write, including byte-masked writes.
   - Macro: generates Verilog that instantiates the IHP SRAM macro. *)

open Hardcaml
open Proteus

module Sim = Cyclesim.With_interface (Mem.I) (Mem.O)
module Mc = Circuit.With_interface (Mem.I) (Mem.O)

let failures = ref 0

let check name got expected =
  if got <> expected
  then (
    incr failures;
    Printf.printf "FAIL %s: got 0x%X expected 0x%X\n" name got expected)
;;

let () =
  let size = 256 in
  let circuit = Mc.create_exn ~name:"mem" (Mem.create ~impl:Mem.Behavioral ~size) in
  let sim = Sim.create (Mem.create ~impl:Mem.Behavioral ~size) in
  let (i : Bits.t ref Mem.I.t) = Cyclesim.inputs sim in
  let (o : Bits.t ref Mem.O.t) = Cyclesim.outputs sim in
  i.men := Bits.vdd;
  i.we := Bits.gnd;
  i.re := Bits.gnd;
  i.addr := Bits.of_int ~width:32 0;
  i.din := Bits.of_int ~width:32 0;
  i.bm := Bits.of_int ~width:32 0xFFFFFFFF;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  (* write a full word to address 5 *)
  i.addr := Bits.of_int ~width:32 5;
  i.din := Bits.of_int ~width:32 0xDEADBEEF;
  i.we := Bits.vdd;
  Cyclesim.cycle sim;
  i.we := Bits.gnd;
  (* read it back *)
  i.re := Bits.vdd;
  Cyclesim.cycle sim;
  check "word_read" (Bits.to_int !(o.dout)) 0xDEADBEEF;
  (* byte-masked write: zero byte 0 only *)
  i.re := Bits.gnd;
  i.addr := Bits.of_int ~width:32 5;
  i.din := Bits.of_int ~width:32 0;
  i.bm := Bits.of_int ~width:32 0x000000FF;
  i.we := Bits.vdd;
  Cyclesim.cycle sim;
  i.we := Bits.gnd;
  i.re := Bits.vdd;
  Cyclesim.cycle sim;
  check "byte_write" (Bits.to_int !(o.dout)) 0xDEADBE00;
  ignore circuit;
  (* macro implementation generates an instantiation *)
  let macro = Mc.create_exn ~name:"mem_macro" (Mem.create ~impl:Mem.Ihp_256x32 ~size) in
  let buf = Buffer.create 1024 in
  Rtl.output
    ~output_mode:(Rtl.Output_mode.To_buffer buf)
    Rtl.Language.Verilog
    macro;
  let v = Buffer.contents buf in
  let contains hay needle =
    let n = String.length needle and h = String.length hay in
    let rec go k = k + n <= h && (String.sub hay k n = needle || go (k + 1)) in
    go 0
  in
  if not (contains v "RM_IHPSG13_1P_256x32_c2_bm_bist")
  then (
    incr failures;
    Printf.printf "FAIL: macro instantiation not found in Verilog\n");
  if !failures = 0
  then Printf.printf "memory abstraction test PASSED\n"
  else exit 1
;;
