(* 1-Wire generality test.

   The firmware is a 1-Wire master (reset, presence detect, read byte). The
   testbench models a 1-Wire device: it answers a long reset pulse with a
   presence pulse and then drives a byte during the read slots. 1-Wire is not
   one of the competition's named protocols, so this shows the chip supports a
   protocol it was never designed for, purely in firmware. *)

open Hardcaml
open Proteus

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let ram = 0x10000700
let t_reset = 480
let t_presence = 120
let read_byte = 0x5A

let () =
  let sim = Sim.create (Soc.create ~program:Onewire_firmware.onewire) in
  let (inputs : Bits.t ref Soc.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Soc.O.t) = Cyclesim.outputs sim in
  inputs.ui_in := Bits.of_int ~width:8 0;
  inputs.uart_rx := Bits.vdd;
  inputs.dbg_addr := Bits.of_int ~width:32 0;
  inputs.reset := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  inputs.reset := Bits.gnd;
  let prev_master = ref false in
  let low_start = ref 0 in
  let presence_until = ref 0 in
  let after_reset = ref false in
  let slot_count = ref 0 in
  let slot_drive_until = ref 0 in
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 20_000 do
    let master_dom = Bits.to_int !(outputs.uio_oe) land 1 = 1 in
    let device_dom = !c < !presence_until || !c < !slot_drive_until in
    let _line = if master_dom || device_dom then 0 else 1 in
    inputs.uio_in := Bits.of_int ~width:8 (if device_dom then 0 else 1);
    Cyclesim.cycle sim;
    (* key off the master's drive transitions, not the bus (the device's own
       presence pulse would otherwise look like a slot) *)
    if master_dom && not !prev_master
    then (
      low_start := !c;
      (* a read slot: after the reset, drive the next data bit *)
      if !after_reset
      then (
        (* slots 0..15 are writes, 16..23 are the read phase *)
        if !slot_count >= 16 && !slot_count < 24
        then (
          if read_byte lsr (!slot_count - 16) land 1 = 0
          then slot_drive_until := !c + 40);
        incr slot_count))
    else if (not master_dom) && !prev_master
    then (
      let low_dur = !c - !low_start in
      if low_dur > t_reset / 2
      then (
        (* reset detected: answer with a presence pulse *)
        presence_until := !c + t_presence;
        after_reset := true;
        slot_count := 0));
    prev_master := master_dom;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "1-Wire program did not halt";
  let read addr =
    inputs.dbg_addr := Bits.of_int ~width:32 addr;
    Cyclesim.cycle sim;
    Bits.to_int !(outputs.dbg_rdata)
  in
  let presence = read ram in
  let got = read (ram + 4) in
  Printf.printf "presence=%d read=0x%02X (want 0x%02X)\n" presence got read_byte;
  let failures = ref 0 in
  if presence <> 0
  then (
    incr failures;
    Printf.printf "FAIL presence not detected\n");
  if got <> read_byte
  then (
    incr failures;
    Printf.printf "FAIL read byte\n");
  if !failures = 0
  then Printf.printf "1-Wire generality test PASSED\n"
  else exit 1
;;
