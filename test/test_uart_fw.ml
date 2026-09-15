(* Phase 1 exit test.

   Loads a firmware image that bit-bangs a UART frame out of GPIO bit 0,
   runs it in the cycle-accurate simulator, captures the serial line and
   decodes the byte back. No protocol hardware is involved: the frame is
   produced entirely by the RV32I core executing firmware. *)

open Hardcaml
open Proteus

let byte = 0xA5
let delay = 12
let period = Firmware.uart_tx_period ~delay
let program = Firmware.uart_tx ~byte ~delay ()

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)

let () =
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
  let captured = ref [] in
  let halted = ref false in
  let n = ref 0 in
  while (not !halted) && !n < 5000 do
    Cyclesim.cycle sim;
    captured := (Bits.to_int !(outputs.uo_out) land 1) :: !captured;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr n
  done;
  if not !halted then failwith "firmware did not halt";
  let tx = Array.of_list (List.rev !captured) in
  let len = Array.length tx in
  (* find the first high level (idle), then the falling edge that starts the
     frame *)
  let rec nth_one k = if k >= len then None else if tx.(k) = 1 then Some k else nth_one (k + 1) in
  let rec nth_zero k = if k >= len then None else if tx.(k) = 0 then Some k else nth_zero (k + 1) in
  (match nth_one 0 with
   | None -> failwith "line never idled high"
   | Some idle ->
     (match nth_zero (idle + 1) with
      | None -> failwith "no start bit observed on the serial line"
      | Some s ->
        (* the start bit ends at the first rising edge; its width is the bit
           period and must match the firmware timing model *)
        let rec first_one k =
          if k >= len then failwith "no rising edge after start bit"
          else if tx.(k) = 1 then k
          else first_one (k + 1)
        in
        let measured = first_one (s + 1) - s in
        if measured <> period
        then
          failwith
            (Printf.sprintf "bit period %d does not match model %d" measured period);
        let sample k = tx.(s + (period * (k + 1)) + (period / 2)) in
        let value = ref 0 in
        for k = 0 to 7 do
          if sample k = 1 then value := !value lor (1 lsl k)
        done;
        if sample 8 <> 1 then failwith "stop bit was not high";
        Printf.printf
          "decoded byte = 0x%02X (start at cycle %d, period %d cycles)\n"
          !value
          s
          period;
        if !value <> byte
        then failwith (Printf.sprintf "expected 0x%02X, got 0x%02X" byte !value)));
  Printf.printf "UART firmware test PASSED\n"
;;
