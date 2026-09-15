(* Directed tests for the Phase 3 pin subsystem.

   Program 1 exercises OUT / SET / CLR / TOGGLE / OE through firmware.
   Program 2 exercises edge detection and pin interrupts by driving uio_in
   from the testbench. *)

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

let run_to_halt sim outputs =
  let halted = ref false in
  let n = ref 0 in
  while (not !halted) && !n < 100_000 do
    Cyclesim.cycle sim;
    halted := Bits.to_int !(outputs.Soc.O.halted) = 1;
    incr n
  done;
  if not !halted then failwith "program did not halt"
;;

let () =
  (* Program 1: output registers *)
  let program =
    Asm.assemble
      [ i (lui s0 0x20000000) (* pin base *)
      ; i (lui s1 0x10000000) (* data RAM *)
      ; i (addi t0 x0 0x5A)
      ; i (sw t0 s0 0) (* OUT = 0x5A *)
      ; i (lw t1 s0 8); i (sw t1 s1 0) (* IN *)
      ; i (addi t0 x0 0x80); i (sw t0 s0 12) (* SET *)
      ; i (lw t1 s0 0); i (sw t1 s1 4) (* OUT = 0xDA *)
      ; i (addi t0 x0 0x02); i (sw t0 s0 16) (* CLR *)
      ; i (lw t1 s0 0); i (sw t1 s1 8) (* OUT = 0xD8 *)
      ; i (addi t0 x0 0xFF); i (sw t0 s0 20) (* TOGGLE *)
      ; i (lw t1 s0 0); i (sw t1 s1 12) (* OUT = 0x27 *)
      ; i (addi t0 x0 1); i (slli t0 t0 16)
      ; i (sw t0 s0 4) (* OE bit16 *)
      ; i (lw t1 s0 4); i (sw t1 s1 16) (* OE = 0x10000 *)
      ; Asm.Halt
      ]
  in
  let sim, inputs, outputs = setup ~program in
  run_to_halt sim outputs;
  let read addr =
    inputs.Soc.I.dbg_addr := Bits.of_int ~width:32 addr;
    Cyclesim.cycle sim;
    Bits.to_int !(outputs.Soc.O.dbg_rdata)
  in
  check "pin_IN" (read ram) 0x5A;
  check "pin_SET" (read (ram + 4)) 0xDA;
  check "pin_CLR" (read (ram + 8)) 0xD8;
  check "pin_TOGGLE" (read (ram + 12)) 0x27;
  check "pin_OE" (read (ram + 16)) 0x10000;
  (* Program 2: edge detection and interrupt pending *)
  let program =
    Asm.assemble
      [ i (lui s0 0x20000000)
      ; i (lui s1 0x10000000)
      ; i (addi t0 x0 1); i (slli t0 t0 16)
      ; i (sw t0 s0 32) (* IRQ_EN bit16 *)
      ; Asm.Label "poll"
      ; i (lw t1 s0 24) (* RISE *)
      ; Asm.Branch ((fun off -> beq t1 x0 off), "poll")
      ; i (sw t1 s1 0) (* mem[0] = RISE *)
      ; i (lw t1 s0 36); i (sw t1 s1 4) (* mem[1] = IRQ_PEND *)
      ; Asm.Halt
      ]
  in
  let sim, inputs, outputs = setup ~program in
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 100_000 do
    (* drive a rising edge on uio[0] after a few cycles *)
    inputs.Soc.I.uio_in := Bits.of_int ~width:8 (if !c >= 20 then 1 else 0);
    Cyclesim.cycle sim;
    halted := Bits.to_int !(outputs.Soc.O.halted) = 1;
    incr c
  done;
  if not !halted then failwith "edge program did not halt";
  let read addr =
    inputs.Soc.I.dbg_addr := Bits.of_int ~width:32 addr;
    Cyclesim.cycle sim;
    Bits.to_int !(outputs.Soc.O.dbg_rdata)
  in
  check "pin_RISE" (read ram) 0x10000;
  check "pin_IRQ_PEND" (read (ram + 4)) 0x10000;
  (* Program 3: a pin-edge interrupt is taken as a machine external interrupt *)
  let program =
    Asm.assemble
      [ i (lui s0 0x10000000) (* data RAM *)
      ; i (lui s1 0x20000000) (* pin base *)
      ; Asm.La (t0, "handler")
      ; i (csrrw x0 csr_mtvec t0)
      ; i (addi t0 x0 1); i (slli t0 t0 16)
      ; i (sw t0 s1 32) (* IRQ_EN uio[0] *)
      ; i (addi t0 x0 0x800); i (csrrs x0 csr_mie t0) (* MEIE *)
      ; i (addi t0 x0 0x8); i (csrrs x0 csr_mstatus t0) (* MIE *)
      ; Asm.Label "poll"
      ; i (lw t1 s0 0)
      ; Asm.Branch ((fun off -> beq t1 x0 off), "poll")
      ; i (sw t1 s0 4)
      ; Asm.Halt
      ; Asm.Label "handler"
      ; i (lw t2 s0 0); i (addi t2 t2 1); i (sw t2 s0 0)
      ; i (addi t3 x0 1); i (slli t3 t3 16)
      ; i (sw t3 s1 36) (* clear IRQ_PEND *)
      ; i mret
      ]
  in
  let sim, inputs, outputs = setup ~program in
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 100_000 do
    inputs.Soc.I.uio_in := Bits.of_int ~width:8 (if !c >= 50 then 1 else 0);
    Cyclesim.cycle sim;
    halted := Bits.to_int !(outputs.Soc.O.halted) = 1;
    incr c
  done;
  if not !halted then failwith "pin IRQ program did not halt";
  let read addr =
    inputs.Soc.I.dbg_addr := Bits.of_int ~width:32 addr;
    Cyclesim.cycle sim;
    Bits.to_int !(outputs.Soc.O.dbg_rdata)
  in
  check "pin_irq_count" (read ram) 1;
  check "pin_irq_loop" (read (ram + 4)) 1;
  if !failures = 0
  then Printf.printf "pin subsystem tests PASSED\n"
  else (
    Printf.printf "pin subsystem tests FAILED (%d)\n" !failures;
    exit 1)
;;
