(* CAN error handling test.

   The peer never ACKs, so each transmit attempt raises an ACK error: the
   transmit error counter grows by 8 and an active error frame (6 dominant
   bits) is emitted. The testbench checks the error frames on the bus and the
   counters/state the firmware reports. *)

open Hardcaml
open Proteus

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let ram = 0x10000700

let () =
  let sim = Sim.create (Soc.create ~program:Can_err_firmware.can_err) in
  let (inputs : Bits.t ref Soc.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Soc.O.t) = Cyclesim.outputs sim in
  inputs.ui_in := Bits.of_int ~width:8 1;
  inputs.uio_in := Bits.of_int ~width:8 0;
  inputs.uart_rx := Bits.vdd;
  inputs.dbg_addr := Bits.of_int ~width:32 0;
  inputs.reset := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  inputs.reset := Bits.gnd;
  let bus = ref 1 in
  let captured = ref [] in
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 200_000 do
    inputs.ui_in := Bits.of_int ~width:8 !bus;
    Cyclesim.cycle sim;
    let fw_dom = Bits.to_int !(outputs.uio_oe) land 1 = 1 in
    let lvl = if fw_dom then 0 else 1 in
    bus := lvl;
    captured := lvl :: !captured;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "CAN error program did not halt";
  let tx = Array.of_list (List.rev !captured) in
  (* count maximal runs of 6+ dominant bits: those are error frames *)
  let runs = ref 0 in
  let run = ref 0 in
  let maxrun = ref 0 in
  let bigruns = ref [] in
  Array.iter
    (fun b ->
      if b = 0
      then (
        incr run;
        if !run > !maxrun then maxrun := !run)
      else (
        if !run >= 620 then (incr runs; bigruns := !run :: !bigruns);
        run := 0))
    tx;
  if !run >= 620 then (incr runs; bigruns := !run :: !bigruns);
  Printf.printf "big runs: %s\n" (String.concat "," (List.map string_of_int (List.rev !bigruns)));
  let read addr =
    inputs.dbg_addr := Bits.of_int ~width:32 addr;
    Cyclesim.cycle sim;
    Bits.to_int !(outputs.dbg_rdata)
  in
  let tec = read ram in
  let state = read (ram + 4) in
  let st128 = read (ram + 8) in
  let st256 = read (ram + 12) in
  let st127 = read (ram + 16) in
  let errors = read (ram + 20) in
  Printf.printf
    "TEC=%d state=%d errors=%d error_frames=%d max_run=%d | st(128)=%d st(256)=%d st(127)=%d\n"
    tec state errors !runs !maxrun st128 st256 st127;
  let failures = ref 0 in
  let check name got expected =
    if got <> expected
    then (
      incr failures;
      Printf.printf "FAIL %s: got %d expected %d\n" name got expected)
  in
  check "tec" tec 32;
  check "state" state 0; (* error-active *)
  check "errors" errors 4;
  check "error_frames" !runs 4;
  check "st128" st128 1; (* error-passive *)
  check "st256" st256 2; (* bus-off *)
  check "st127" st127 0;
  if !failures = 0
  then Printf.printf "CAN error handling test PASSED\n"
  else exit 1
;;
