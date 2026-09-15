(* Hardware UART peripheral test.

   TX: firmware writes bytes to the UART; the simulator decodes the serial
   line. RX: the simulator drives a serial byte into the UART; firmware polls
   the status register, reads the byte and stores it to RAM. *)

open Hardcaml
open Proteus
open Isa

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let i n = Asm.Insn n
let clk_div = 16
let ram = 0x10000000
let failures = ref 0

let check name got expected =
  if got <> expected
  then (
    incr failures;
    Printf.printf "FAIL %s: got 0x%X, expected 0x%X\n" name got expected)
;;

let setup ~program =
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
  sim, inputs, outputs
;;

let () =
  (* ---- TX ---- *)
  let program =
    Asm.assemble
      [ i (lui s0 0x60000000) (* UART base *)
      ; i (addi t0 x0 0x48) (* 'H' *)
      ; i (sw t0 s0 0)
      ; Asm.Label "wait1"
      ; i (lw t1 s0 8)
      ; i (andi t1 t1 1)
      ; Asm.Branch ((fun off -> bne t1 x0 off), "wait1")
      ; i (addi t0 x0 0x69) (* 'i' *)
      ; i (sw t0 s0 0)
      ; Asm.Halt
      ]
  in
  let sim, inputs, outputs = setup ~program in
  ignore inputs;
  let captured = ref [] in
  let halted = ref false in
  let n = ref 0 in
  while (not !halted) && !n < 5000 do
    Cyclesim.cycle sim;
    captured := Bits.to_int !(outputs.uart_tx) :: !captured;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr n
  done;
  if not !halted then failwith "UART TX program did not halt";
  (* the peripheral keeps shifting after the core halts; capture the tail *)
  for _ = 1 to 200 do
    Cyclesim.cycle sim;
    captured := Bits.to_int !(outputs.uart_tx) :: !captured
  done;
  let tx = Array.of_list (List.rev !captured) in
  let decode start =
    let v = ref 0 in
    for k = 0 to 7 do
      let idx = start + (clk_div * (k + 1)) + (clk_div / 2) in
      if idx < Array.length tx && tx.(idx) = 1 then v := !v lor (1 lsl k)
    done;
    !v
  in
  let falling_after from =
    let r = ref (-1) in
    for k = from to Array.length tx - 1 do
      if !r < 0 && k > 0 && tx.(k - 1) = 1 && tx.(k) = 0 then r := k
    done;
    !r
  in
  let s1 = falling_after 1 in
  if s1 < 0 then failwith "no start bit on uart_tx";
  check "uart_tx_byte0" (decode s1) 0x48;
  let s2 = falling_after (s1 + (10 * clk_div)) in
  if s2 < 0 then failwith "no second start bit on uart_tx";
  check "uart_tx_byte1" (decode s2) 0x69;
  (* ---- RX ---- *)
  let byte = 0x41 (* 'A' *) in
  let program =
    Asm.assemble
      [ i (lui s0 0x60000000) (* UART base *)
      ; i (lui s1 0x10000000) (* data RAM *)
      ; Asm.Label "poll"
      ; i (lw t1 s0 8)
      ; i (andi t1 t1 2)
      ; Asm.Branch ((fun off -> beq t1 x0 off), "poll")
      ; i (lw t2 s0 4)
      ; i (sw t2 s1 0)
      ; Asm.Halt
      ]
  in
  let sim, inputs, outputs = setup ~program in
  let frame = Array.init 10 (fun k -> if k = 0 then 0 else if k = 9 then 1 else byte lsr (k - 1) land 1) in
  let start_cycle = 8 in
  let cyc = ref 0 in
  let halted = ref false in
  while (not !halted) && !cyc < 5000 do
    let c = !cyc in
    let b =
      if c < start_cycle
      then 1
      else (
        let idx = (c - start_cycle) / clk_div in
        if idx > 9 then 1 else frame.(idx))
    in
    inputs.uart_rx := (if b = 1 then Bits.vdd else Bits.gnd);
    Cyclesim.cycle sim;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr cyc
  done;
  if not !halted then failwith "UART RX program did not halt";
  inputs.dbg_addr := Bits.of_int ~width:32 ram;
  Cyclesim.cycle sim;
  check "uart_rx_byte" (Bits.to_int !(outputs.dbg_rdata)) byte;
  if !failures = 0
  then Printf.printf "UART peripheral tests PASSED\n"
  else (
    Printf.printf "UART peripheral tests FAILED (%d)\n" !failures;
    exit 1)
;;
