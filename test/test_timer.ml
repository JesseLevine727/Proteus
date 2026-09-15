(* Machine timer interrupt test.

   Firmware enables the machine timer interrupt, arms mtimecmp, then spins.
   The handler increments a counter in RAM and disarms the timer; the main
   loop observes the counter and halts. *)

open Hardcaml
open Proteus
open Isa

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)

let run program =
  let sim = Sim.create (Soc.create ~program) in
  let (inputs : Bits.t ref Soc.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Soc.O.t) = Cyclesim.outputs sim in
  inputs.ui_in := Bits.of_int ~width:8 0;
  inputs.uart_rx := Bits.vdd;
  inputs.dbg_addr := Bits.of_int ~width:32 0;
  inputs.reset := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  inputs.reset := Bits.gnd;
  let halted = ref false in
  let n = ref 0 in
  while (not !halted) && !n < 100_000 do
    Cyclesim.cycle sim;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr n
  done;
  if not !halted then failwith "program did not halt";
  fun addr ->
    inputs.dbg_addr := Bits.of_int ~width:32 addr;
    Cyclesim.cycle sim;
    Bits.to_int !(outputs.dbg_rdata)
;;

let failures = ref 0

let check name got expected =
  if got <> expected
  then (
    incr failures;
    Printf.printf "FAIL %s: got 0x%X, expected 0x%X\n" name got expected)
;;

let ram = 0x10000000
let i n = Asm.Insn n
let timer_base = 0x30000000

let () =
  let mem =
    run
      (Asm.assemble
         [ i (lui s0 0x10000000)
         ; Asm.La (t0, "handler")
         ; i (csrrw x0 csr_mtvec t0)
         (* enable machine timer interrupt: mie.MTIE and mstatus.MIE *)
         ; i (addi t0 x0 0x80)
         ; i (csrrs x0 csr_mie t0)
         ; i (addi t0 x0 0x8)
         ; i (csrrs x0 csr_mstatus t0)
         (* mtimecmp = mtime + 50 *)
         ; i (lui t1 0x30000000)
         ; i (lw t2 t1 0)
         ; i (addi t2 t2 50)
         ; i (sw t2 t1 8)
         ; i (sw x0 t1 12)
         (* spin until the handler bumps mem[0] *)
         ; Asm.Label "loop"
         ; i (lw t3 s0 0)
         ; Asm.Branch ((fun off -> beq t3 x0 off), "loop")
         ; i (sw t3 s0 4)
         ; Asm.Halt
         ; Asm.Label "handler"
         ; i (lw t4 s0 0)
         ; i (addi t4 t4 1)
         ; i (sw t4 s0 0)
         (* disarm the timer *)
         ; i (lui t5 0x30000000)
         ; i (addi t6 x0 (-1))
         ; i (sw t6 t5 8)
         ; i (sw t6 t5 12)
         ; i mret
         ])
  in
  check "timer_irq_count" (mem ram) 1;
  check "timer_loop_exit" (mem (ram + 4)) 1;
  ignore timer_base;
  if !failures = 0
  then Printf.printf "timer interrupt test PASSED\n"
  else (
    Printf.printf "timer interrupt test FAILED (%d)\n" !failures;
    exit 1)
;;
