(* UART parity and flow-control tests.

   TX: the firmware waits for CTS low, then sends 'A' with even parity. The
   testbench holds CTS high, checks the line stays idle, releases CTS and
   decodes the frame (data + parity + stop).
   RX: the testbench sends a byte with even parity; the firmware receives it
   and reports any parity/framing error. *)

open Hardcaml
open Proteus

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let ram = 0x10000700
let popcount b =
  let r = ref 0 in
  for i = 0 to 7 do if b lsr i land 1 = 1 then incr r done;
  !r
;;

(* --- TX --- *)
let run_tx () =
  let sim = Sim.create (Soc.create ~program:Uart_tx_p_firmware.uart_tx_p) in
  let (inputs : Bits.t ref Soc.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Soc.O.t) = Cyclesim.outputs sim in
  inputs.uio_in := Bits.of_int ~width:8 0;
  inputs.uart_rx := Bits.vdd;
  inputs.dbg_addr := Bits.of_int ~width:32 0;
  inputs.reset := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  inputs.reset := Bits.gnd;
  let cts_high = 300 in
  let captured = ref [] in
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 5000 do
    (* CTS = ui_in[1]: high = not clear to send *)
    inputs.ui_in := Bits.of_int ~width:8 (if !c < cts_high then 2 else 0);
    Cyclesim.cycle sim;
    captured := (Bits.to_int !(outputs.uo_out) land 1) :: !captured;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  Array.of_list (List.rev !captured), cts_high
;;

let () =
  let tx, cts_high = run_tx () in
  let n = Array.length tx in
  let first_falling () =
    let r = ref (-1) in
    for k = 1 to n - 1 do
      if !r < 0 && tx.(k - 1) = 1 && tx.(k) = 0 then r := k
    done;
    !r
  in
  let start = first_falling () in
  if start < 0 then failwith "no start bit";
  let first_rising from =
    let r = ref (-1) in
    for k = from to n - 1 do
      if !r < 0 && tx.(k) = 1 then r := k
    done;
    !r
  in
  let period = first_rising (start + 1) - start in
  Printf.printf "TX: n=%d start=%d period=%d\n" n start period;
  let sample k = tx.(start + (period * k) + (period / 2)) in
  let data = ref 0 in
  for k = 0 to 7 do
    if sample (k + 1) = 1 then data := !data lor (1 lsl k)
  done;
  let par = sample 9 in
  let stop = sample 10 in
  Printf.printf
    "TX: start=%d period=%d data=0x%02X parity=%d stop=%d (cts released at %d)\n"
    start period !data par stop cts_high;
  let failures = ref 0 in
  let check name got expected =
    if got <> expected
    then (
      incr failures;
      Printf.printf "FAIL %s: got %d expected %d\n" name got expected)
  in
  if start < cts_high
  then (
    incr failures;
    Printf.printf "FAIL flow control: sent before CTS released\n");
  check "tx_data" !data 0x41;
  check "tx_parity" par (popcount 0x41 mod 2);
  check "tx_stop" stop 1;
  (* --- RX --- *)
  let byte = 0x53 in
  let rx_period = period in
  let frame =
    let f = ref [ 0 ] in
    for i = 0 to 7 do
      f := ((byte lsr i land 1) :: !f)
    done;
    f := (popcount byte mod 2) :: !f;
    f := 1 :: !f;
    List.rev !f
  in
  let sim = Sim.create (Soc.create ~program:Uart_rx_p_firmware.uart_rx_p) in
  let (inputs : Bits.t ref Soc.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Soc.O.t) = Cyclesim.outputs sim in
  inputs.uio_in := Bits.of_int ~width:8 0;
  inputs.uart_rx := Bits.vdd;
  inputs.dbg_addr := Bits.of_int ~width:32 0;
  inputs.reset := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  inputs.reset := Bits.gnd;
  let start_cycle = 20 in
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 5000 do
    let lvl =
      if !c < start_cycle
      then 1
      else (
        let idx = (!c - start_cycle) / rx_period in
        if idx >= List.length frame then 1 else List.nth frame idx)
    in
    inputs.ui_in := Bits.of_int ~width:8 lvl;
    Cyclesim.cycle sim;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "RX program did not halt";
  let read addr =
    inputs.dbg_addr := Bits.of_int ~width:32 addr;
    Cyclesim.cycle sim;
    Bits.to_int !(outputs.dbg_rdata)
  in
  let got = read ram in
  let err = read (ram + 4) in
  Printf.printf "RX: byte=0x%02X err=%d\n" got err;
  check "rx_data" got byte;
  check "rx_err" err 0;
  if !failures = 0
  then Printf.printf "UART parity/flow-control tests PASSED\n"
  else exit 1
;;
