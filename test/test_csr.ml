(* Directed tests for the CSR instructions and machine-mode traps.

   Programs write results to data RAM, run to the HALT register, and the
   simulator reads RAM back through the SoC debug port. *)

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

let () =
  (* CSR read/write/set/clear *)
  let mem =
    run
      (Asm.assemble
         [ i (lui s0 0x10000000)
         ; i (csrrs t0 csr_misa x0); i (sw t0 s0 0)
         ; i (addi t0 x0 0x123)
         ; i (csrrw x0 csr_mscratch t0)
         ; i (csrrs t1 csr_mscratch x0); i (sw t1 s0 4)
         ; i (csrrsi t1 csr_mscratch 0x8); i (sw t1 s0 8)
         ; i (csrrs t1 csr_mscratch x0); i (sw t1 s0 12)
         ; i (csrrci t1 csr_mscratch 0x8); i (sw t1 s0 16)
         ; i (csrrs t1 csr_mscratch x0); i (sw t1 s0 20)
         ; i (csrrs t0 csr_mcycle x0)
         ; i (csrrs t1 csr_mcycle x0)
         ; i (sub t2 t1 t0); i (sw t2 s0 24)
         ; Asm.Halt
         ])
  in
  check "misa" (mem ram) 0x40000100;
  check "mscratch_rw" (mem (ram + 4)) 0x123;
  check "csrrsi_old" (mem (ram + 8)) 0x123;
  check "csrrsi_new" (mem (ram + 12)) 0x12B;
  check "csrrci_old" (mem (ram + 16)) 0x12B;
  check "csrrci_new" (mem (ram + 20)) 0x123;
  if mem (ram + 24) < 1 then (
    incr failures;
    Printf.printf "FAIL mcycle did not advance\n");
  (* ECALL trap and MRET return *)
  let mem =
    run
      (Asm.assemble
         [ i (lui s0 0x10000000)
         ; Asm.La (t0, "handler")
         ; i (csrrw x0 csr_mtvec t0)
         ; i (addi t0 x0 5)
         ; i ecall
         ; i (addi t1 x0 0x77)
         ; i (sw t1 s0 0)
         ; Asm.Halt
         ; Asm.Label "handler"
         ; i (csrrs t2 csr_mcause x0); i (sw t2 s0 4)
         ; i (csrrs t2 csr_mepc x0); i (sw t2 s0 8)
         ; i (addi t2 t2 4)
         ; i (csrrw x0 csr_mepc t2)
         ; i mret
         ])
  in
  check "ecall_return" (mem ram) 0x77;
  check "ecall_cause" (mem (ram + 4)) 11;
  check "ecall_mepc" (mem (ram + 8)) 20;
  (* illegal instruction trap *)
  let mem =
    run
      (Asm.assemble
         [ i (lui s0 0x10000000)
         ; Asm.La (t0, "handler")
         ; i (csrrw x0 csr_mtvec t0)
         ; i (addi t0 x0 5)
         ; i 0x00000000
         ; i (addi t1 x0 0x99)
         ; i (sw t1 s0 0)
         ; Asm.Halt
         ; Asm.Label "handler"
         ; i (csrrs t2 csr_mcause x0); i (sw t2 s0 4)
         ; i (csrrs t2 csr_mepc x0); i (sw t2 s0 8)
         ; i (addi t2 t2 4)
         ; i (csrrw x0 csr_mepc t2)
         ; i mret
         ])
  in
  check "illegal_return" (mem ram) 0x99;
  check "illegal_cause" (mem (ram + 4)) 2;
  check "illegal_mepc" (mem (ram + 8)) 20;
  if !failures = 0
  then Printf.printf "CSR/trap tests PASSED\n"
  else (
    Printf.printf "CSR/trap tests FAILED (%d)\n" !failures;
    exit 1)
;;
