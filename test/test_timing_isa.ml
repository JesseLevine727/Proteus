(* Tests for the Phase 3 custom timing instructions:
   DELAY, PIN_WAIT and PIN_EDGE. *)

open Hardcaml
open Proteus
open Isa

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let i n = Asm.Insn n
let ram = 0x10000000
let failures = ref 0

let check name got expected =
  if got <> expected
  then (
    incr failures;
    Printf.printf "FAIL %s: got 0x%X, expected 0x%X\n" name got expected)
;;

let run ?(drive = fun _ (_ : Bits.t ref Soc.I.t) -> ()) program =
  let sim = Sim.create (Soc.create ~program) in
  let (inputs : Bits.t ref Soc.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Soc.O.t) = Cyclesim.outputs sim in
  inputs.ui_in := Bits.of_int ~width:8 0;
  inputs.uio_in := Bits.of_int ~width:8 0;
  inputs.uart_rx := Bits.vdd;
  inputs.dbg_addr := Bits.of_int ~width:32 0;
  inputs.reset := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  inputs.reset := Bits.gnd;
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 200_000 do
    drive !c inputs;
    Cyclesim.cycle sim;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "program did not halt";
  fun addr ->
    inputs.dbg_addr := Bits.of_int ~width:32 addr;
    Cyclesim.cycle sim;
    Bits.to_int !(outputs.dbg_rdata)
;;

let delay_prog n =
  Asm.assemble
    [ i (lui s0 0x10000000)
    ; i (csrrs t0 csr_mcycle x0)
    ; i (addi t1 x0 n)
    ; i (delay x0 t1)
    ; i (csrrs t2 csr_mcycle x0)
    ; i (sub t3 t2 t0)
    ; i (sw t3 s0 0)
    ; Asm.Halt
    ]
;;

let wait_prog kind =
  Asm.assemble
    [ i (lui s0 0x10000000)
    ; i (lui s1 0x20000000)
    ; i (sw x0 s1 4) (* OE = 0: uio are inputs *)
    ; i (addi t0 x0 1); i (slli t0 t0 16) (* mask = uio[0] *)
    ; i (addi t1 x0 2000) (* timeout *)
    ; i (kind t2 t0 t1)
    ; i (sw t2 s0 0)
    ; Asm.Halt
    ]
;;

let () =
  (* DELAY is linear: 100 vs 50 cycles differ by exactly 50 *)
  let a = (run (delay_prog 100)) ram in
  let b = (run (delay_prog 50)) ram in
  check "delay_delta" (a - b) 50;
  if a < 100 || a > 110 then (
    incr failures;
    Printf.printf "FAIL delay_abs: %d not near 100\n" a);
  (* PIN_WAIT satisfied by a level *)
  let m =
    run
      ~drive:(fun c inputs ->
        inputs.Soc.I.uio_in := Bits.of_int ~width:8 (if c >= 100 then 1 else 0))
      (wait_prog pin_wait)
  in
  check "pin_wait_level" (m ram) 0;
  (* PIN_WAIT times out when the level never arrives *)
  let m = run (wait_prog pin_wait) in
  check "pin_wait_timeout" (m ram) 1;
  (* PIN_EDGE satisfied by a rising edge *)
  let m =
    run
      ~drive:(fun c inputs ->
        inputs.Soc.I.uio_in := Bits.of_int ~width:8 (if c >= 100 then 1 else 0))
      (wait_prog pin_edge)
  in
  check "pin_edge" (m ram) 0;
  if !failures = 0
  then Printf.printf "timing ISA tests PASSED\n"
  else (
    Printf.printf "timing ISA tests FAILED (%d)\n" !failures;
    exit 1)
;;
