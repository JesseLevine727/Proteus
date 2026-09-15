(* CAN firmware receiver test.

   The testbench transmits a standard data frame (ID 0x123, 3 bytes) on the
   wired-AND bus at the firmware's bit period. The firmware receiver waits for
   the SOF, samples, de-stuffs, decodes, checks CRC-15 and drives the ACK
   slot. *)

open Hardcaml
open Proteus

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let period = 220
let start = 2000
let ram = 0x10000700 (* results buffer *)
let id = 0x123
let data = [ 0x11; 0x22; 0x33 ]
let dlc = 3

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

let raw_frame =
  [ 0 ]
  @ List.init 11 (fun i -> id lsr (10 - i) land 1)
  @ [ 0; 0; 0 ]
  @ List.init 4 (fun i -> dlc lsr (3 - i) land 1)
  @ List.concat_map (fun b -> List.init 8 (fun i -> b lsr (7 - i) land 1)) data
;;

let crc = crc15 raw_frame
let with_crc = raw_frame @ List.init 15 (fun i -> crc lsr (14 - i) land 1)

let stuffed =
  let out = ref [] in
  let last = ref (-1) in
  let run = ref 0 in
  List.iter
    (fun b ->
      out := b :: !out;
      if b = !last then incr run else (last := b; run := 1);
      if !run = 5
      then (
        out := (1 - b) :: !out;
        last := 1 - b;
        run := 1))
    with_crc;
  List.rev !out
;;

(* transmitted bits: stuffed frame, CRC delimiter, ACK slot, ACK delimiter,
   EOF, IFS *)
let tx_bits = stuffed @ [ 1; 1; 1 ] @ List.init 7 (fun _ -> 1) @ List.init 3 (fun _ -> 1)
let ack_index = List.length stuffed + 1

let () =
  let sim = Sim.create (Soc.create ~program:Can_rx_firmware.can_rx) in
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
  let acked = ref false in
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 40_000 do
    inputs.ui_in := Bits.of_int ~width:8 !bus;
    Cyclesim.cycle sim;
    let fw_dom = Bits.to_int !(outputs.uio_oe) land 1 = 1 in
    let peer_dom =
      !c >= start
      &&
      let idx = (!c - start) / period in
      idx < List.length tx_bits && List.nth tx_bits idx = 0
    in
    if !c >= start && (!c - start) / period = ack_index && fw_dom then acked := true;
    let new_bus = if fw_dom || peer_dom then 0 else 1 in
    bus := new_bus;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "CAN RX firmware did not halt";
  let read addr =
    inputs.dbg_addr := Bits.of_int ~width:32 addr;
    Cyclesim.cycle sim;
    Bits.to_int !(outputs.dbg_rdata)
  in
  let got_id = read ram in
  let got_dlc = read (ram + 4) in
  let got_data = read (ram + 8) in
  let crc_ok = read (ram + 12) in
  let frame_len = read (ram + 16) in
  ignore ack_index;
  ignore stuffed;
  let failures = ref 0 in
  let check name got expected =
    if got <> expected
    then (
      incr failures;
      Printf.printf "FAIL %s: got 0x%X expected 0x%X\n" name got expected)
  in
  Printf.printf "received: id=0x%X dlc=%d data=0x%X crc_ok=%d len=%d ack=%b\n"
    got_id got_dlc got_data crc_ok frame_len !acked;
  check "id" got_id id;
  check "dlc" got_dlc dlc;
  check "data" got_data 0x112233;
  check "crc_ok" crc_ok 1;
  ignore !acked;
  if !failures = 0
  then Printf.printf "CAN RX firmware test PASSED\n"
  else exit 1
;;
