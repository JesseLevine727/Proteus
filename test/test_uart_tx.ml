(* Self-checking test for the UART transmitter.

   Drives the design in Hardcaml's cycle-accurate simulator, captures the
   serial line, and decodes the frame back to a byte. This proves the whole
   toolchain (OCaml -> Hardcaml -> simulation) works end to end. *)

open Hardcaml
open Proteus

module Sim = Cyclesim.With_interface (Uart_tx.I) (Uart_tx.O)

let sim = Sim.create Uart_tx.create

let set_bits (r : Bits.t ref) (v : int) =
  r := Bits.of_int ~width:(Bits.width !r) v
;;

let () =
  let (inputs : Bits.t ref Uart_tx.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Uart_tx.O.t) = Cyclesim.outputs sim in
  set_bits inputs.baud_div 4;
  set_bits inputs.data 0xA5;
  inputs.start := Bits.gnd;
  inputs.reset := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  inputs.reset := Bits.gnd;
  Cyclesim.cycle sim;
  inputs.start := Bits.vdd;
  Cyclesim.cycle sim;
  inputs.start := Bits.gnd;
  let captured = ref [] in
  for _ = 1 to 80 do
    Cyclesim.cycle sim;
    captured := Bits.to_int !(outputs.tx) :: !captured
  done;
  let tx = Array.of_list (List.rev !captured) in
  let start = ref (-1) in
  Array.iteri (fun idx v -> if !start < 0 && v = 0 then start := idx) tx;
  if !start < 0
  then failwith "no start bit observed on tx";
  let s = !start in
  let bit k =
    let idx = s + 6 + (4 * k) in
    if idx >= Array.length tx then failwith "capture too short";
    tx.(idx)
  in
  let value = ref 0 in
  for k = 0 to 7 do
    if bit k = 1 then value := !value lor (1 lsl k)
  done;
  Printf.printf "decoded byte = 0x%02X\n" !value;
  if !value <> 0xA5
  then failwith (Printf.sprintf "expected 0xA5, got 0x%02X" !value);
  Printf.printf "UART TX test PASSED\n"
;;
