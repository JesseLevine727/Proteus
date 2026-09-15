(* Firmware UART receiver.

   A firmware routine polls for the start bit, then samples eight data bits
   using the custom DELAY instruction, entirely in software. The testbench
   generates the serial waveform from an OCaml golden model and checks the
   byte the firmware recovers. *)

open Hardcaml
open Proteus
open Isa

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let i n = Asm.Insn n
let ram = 0x10000000

(* golden model: 8N1, LSB first, as a list of bit levels *)
let golden_frame byte =
  Array.init 10 (fun k ->
    if k = 0 then 0 else if k = 9 then 1 else byte lsr (k - 1) land 1)
;;

let bit_period = 64
let half = 30
let period = 50

let rx_prog =
  Asm.assemble
    [ i (lui s0 0x10000000) (* data RAM *)
    ; i (lui s1 0x20000000) (* pin base *)
    ; Asm.Label "wait_start"
    ; i (lw t0 s1 8) (* IN *)
    ; i (andi t0 t0 0x100) (* ui_in[0] *)
    ; Asm.Branch ((fun off -> bne t0 x0 off), "wait_start")
    ; i (addi t0 x0 half)
    ; i (delay x0 t0) (* align to mid start bit *)
    ; i (addi t1 x0 8) (* bit count *)
    ; i (addi t2 x0 0) (* accumulator *)
    ; Asm.Label "sample"
    ; i (addi t3 x0 period)
    ; i (delay x0 t3) (* one bit period *)
    ; i (lw t4 s1 8)
    ; i (andi t4 t4 0x100)
    ; i (srli t4 t4 8)
    ; i (srli t2 t2 1)
    ; i (slli t4 t4 7)
    ; i (or_ t2 t2 t4)
    ; i (addi t1 t1 (-1))
    ; Asm.Branch ((fun off -> bne t1 x0 off), "sample")
    ; i (sw t2 s0 0)
    ; Asm.Halt
    ]
;;

let run byte =
  let frame = golden_frame byte in
  let start_cycle = 20 in
  let sim = Sim.create (Soc.create ~program:rx_prog) in
  let (inputs : Bits.t ref Soc.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Soc.O.t) = Cyclesim.outputs sim in
  inputs.uio_in := Bits.of_int ~width:8 0;
  inputs.uart_rx := Bits.vdd;
  inputs.dbg_addr := Bits.of_int ~width:32 0;
  inputs.reset := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  inputs.reset := Bits.gnd;
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 100_000 do
    let lvl =
      if !c < start_cycle
      then 1
      else (
        let idx = (!c - start_cycle) / bit_period in
        if idx > 9 then 1 else frame.(idx))
    in
    inputs.ui_in := Bits.of_int ~width:8 lvl;
    Cyclesim.cycle sim;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "UART RX firmware did not halt";
  inputs.dbg_addr := Bits.of_int ~width:32 ram;
  Cyclesim.cycle sim;
  Bits.to_int !(outputs.dbg_rdata)
;;

let () =
  let failures = ref 0 in
  List.iter
    (fun byte ->
      let got = run byte in
      if got <> byte
      then (
        incr failures;
        Printf.printf "FAIL byte 0x%02X: got 0x%02X\n" byte got))
    [ 0x41; 0xA5; 0x00; 0xFF; 0x5A ];
  if !failures = 0
  then Printf.printf "UART firmware RX test PASSED\n"
  else (
    Printf.printf "UART firmware RX test FAILED (%d)\n" !failures;
    exit 1)
;;
