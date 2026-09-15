(* CAN firmware node tests.

   The firmware transmits a standard data frame (ID 0x123, 3 data bytes) with
   bit stuffing and CRC-15. The testbench samples the wired-AND bus at bit
   centres, de-stuffs the result and decodes the frame with an OCaml golden
   model, including the CRC. A second run has the peer pull the bus dominant
   while the firmware sends a recessive bit, so the firmware must lose
   arbitration. *)

open Hardcaml
open Proteus

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let period = 220
let half = 110
let ram = 0x10000700 (* results buffer *)

let destuff bits =
  let out = ref [] in
  let run = ref 0 in
  let last = ref (-1) in
  List.iter
    (fun b ->
      if !run = 5
      then (
        last := b;
        run := 1)
      else (
        out := b :: !out;
        if b = !last then incr run else (last := b; run := 1)))
    bits;
  List.rev !out
;;

let bits_to_int bits = List.fold_left (fun a b -> (a lsl 1) lor b) 0 bits

let crc15 bits =
  let crc = ref 0 in
  List.iter
    (fun b ->
      let top = !crc lsr 14 land 1 in
      crc := !crc lsl 1 land 0x7FFF;
      if top lxor b = 1 then crc := !crc lxor 0x4599)
    bits;
  !crc
;;

(* run the node; [peer_dom c] reports whether the peer pulls the bus dominant
   at cycle [c]. Returns (de-stuffed bits, firmware ok, firmware frame bits). *)
let run ?(peer_dom = fun _ -> false) () =
  let sim = Sim.create (Soc.create ~program:Can_firmware.can) in
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
  let prev = ref 1 in
  let timer = ref (-1) in
  let sampled = ref [] in
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 60_000 do
    inputs.ui_in := Bits.of_int ~width:8 !bus;
    Cyclesim.cycle sim;
    let fw_dom = Bits.to_int !(outputs.uio_oe) land 1 = 1 in
    let pd = peer_dom !c in
    let new_bus = if fw_dom || pd then 0 else 1 in
    if !timer < 0
    then (if new_bus = 0 && !prev = 1 then timer := 0)
    else (
      incr timer;
      if new_bus <> !prev then timer := 0;
      if !timer >= half && (!timer - half) mod period = 0
      then sampled := new_bus :: !sampled);
    prev := new_bus;
    bus := new_bus;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "CAN firmware did not halt";
  let read addr =
    inputs.dbg_addr := Bits.of_int ~width:32 addr;
    Cyclesim.cycle sim;
    Bits.to_int !(outputs.dbg_rdata)
  in
  destuff (List.rev !sampled), read ram, read (ram + 8)
;;

let () =
  let failures = ref 0 in
  let check name got expected =
    if got <> expected
    then (
      incr failures;
      Printf.printf "FAIL %s: got 0x%X expected 0x%X\n" name got expected)
  in
  (* frame receive + decode *)
  let bits, ok, nbits = run () in
  let bit i = List.nth bits i in
  Printf.printf "frame: %d de-stuffed bits, firmware %d bits\n" (List.length bits) nbits;
  check "SOF" (bit 0) 0;
  check "ID" (bits_to_int (List.init 11 (fun i -> bit (1 + i)))) 0x123;
  check "RTR" (bit 12) 0;
  check "IDE" (bit 13) 0;
  check "DLC" (bits_to_int (List.init 4 (fun i -> bit (15 + i)))) 3;
  check "data0" (bits_to_int (List.init 8 (fun i -> bit (19 + i)))) 0x11;
  check "data1" (bits_to_int (List.init 8 (fun i -> bit (27 + i)))) 0x22;
  check "data2" (bits_to_int (List.init 8 (fun i -> bit (35 + i)))) 0x33;
  let computed = crc15 (List.init 43 (fun i -> bit i)) in
  let received = bits_to_int (List.init 15 (fun i -> bit (43 + i))) in
  check "crc15" received computed;
  check "firmware_ok" ok 1;
  (* arbitration: the peer pulls the bus dominant while the firmware sends a
     recessive bit, so the firmware must lose arbitration *)
  let _, ok_lost, _ = run ~peer_dom:(fun c -> c >= 1978 && c < 2198) () in
  check "arbitration_lost" ok_lost 0;
  if !failures = 0
  then Printf.printf "CAN firmware tests PASSED\n"
  else exit 1
;;
