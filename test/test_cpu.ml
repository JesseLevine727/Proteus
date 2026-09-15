(* Directed tests for the RV32I core.

   Each test loads a small program that computes results and writes them to
   data RAM, runs it to completion (EBREAK), then reads RAM back through the
   SoC debug port and checks the values. *)

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
  (* load/store path *)
  let mem = run (Firmware.ram_pattern ()) in
  check "ram_pattern[0]" (mem ram) 0x123;
  check "ram_pattern[1]" (mem (ram + 4)) 0x456;
  check "ram_pattern[2]" (mem (ram + 8)) 0x579;
  (* ALU operations *)
  let mem =
    run
      (Asm.assemble
         [ i (lui s0 0x10000000)
         ; i (addi t0 x0 10)
         ; i (addi t1 x0 3)
         ; i (sub t2 t0 t1); i (sw t2 s0 0)
         ; i (and_ t2 t0 t1); i (sw t2 s0 4)
         ; i (or_ t2 t0 t1); i (sw t2 s0 8)
         ; i (xor t2 t0 t1); i (sw t2 s0 12)
         ; i (sll t2 t0 t1); i (sw t2 s0 16)
         ; i (srl t2 t0 t1); i (sw t2 s0 20)
         ; i (sra t2 t0 t1); i (sw t2 s0 24)
         ; i (slt t2 t0 t1); i (sw t2 s0 28)
         ; i (sltu t2 t0 t1); i (sw t2 s0 32)
         ; i (addi s1 x0 (-1))
         ; i (slt t2 s1 t1); i (sw t2 s0 36)
         ; i (sltu t2 s1 t1); i (sw t2 s0 40)
         ; Asm.Halt
         ])
  in
  check "sub" (mem ram) 7;
  check "and" (mem (ram + 4)) 2;
  check "or" (mem (ram + 8)) 11;
  check "xor" (mem (ram + 12)) 9;
  check "sll" (mem (ram + 16)) 80;
  check "srl" (mem (ram + 20)) 1;
  check "sra" (mem (ram + 24)) 1;
  check "slt" (mem (ram + 28)) 0;
  check "sltu" (mem (ram + 32)) 0;
  check "slt_neg" (mem (ram + 36)) 1;
  check "sltu_neg" (mem (ram + 40)) 0;
  (* branches *)
  let mem =
    run
      (Asm.assemble
         [ i (lui s0 0x10000000)
         ; i (addi t0 x0 5)
         ; i (addi t1 x0 5)
         ; Asm.Branch ((fun off -> beq t0 t1 off), "L1")
         ; i (addi t2 x0 0xBAD)
         ; Asm.Label "L1"
         ; i (addi t2 x0 1); i (sw t2 s0 0)
         ; Asm.Branch ((fun off -> bne t0 t1 off), "L2")
         ; i (addi t2 x0 2); i (sw t2 s0 4)
         ; Asm.Label "L2"
         ; Asm.Branch ((fun off -> blt t0 t1 off), "L3")
         ; i (addi t2 x0 3); i (sw t2 s0 8)
         ; Asm.Label "L3"
         ; Asm.Branch ((fun off -> bge t0 t1 off), "L4")
         ; i (addi t2 x0 0xBAD)
         ; Asm.Label "L4"
         ; i (addi t2 x0 4); i (sw t2 s0 12)
         ; Asm.Halt
         ])
  in
  check "beq" (mem ram) 1;
  check "bne" (mem (ram + 4)) 2;
  check "blt" (mem (ram + 8)) 3;
  check "bge" (mem (ram + 12)) 4;
  (* jumps *)
  let mem =
    run
      (Asm.assemble
         [ i (lui s0 0x10000000)
         ; Asm.Jump ((fun off -> jal ra off), "func")
         ; Asm.Label "after"
         ; i (sw t2 s0 0)
         ; Asm.Halt
         ; Asm.Label "func"
         ; i (addi t2 x0 0x77)
         ; i (jalr x0 ra 0)
         ])
  in
  check "jal_jalr" (mem ram) 0x77;
  (* byte and half load/store semantics *)
  let mem =
    run
      (Asm.assemble
         [ i (lui s0 0x10000000)
         ; i (addi t0 x0 0x1AB)
         ; i (sw t0 s0 0)
         ; i (lbu t1 s0 0); i (sw t1 s0 4)
         ; i (lb t1 s0 0); i (sw t1 s0 8)
         ; i (lhu t1 s0 0); i (sw t1 s0 12)
         ; i (lh t1 s0 0); i (sw t1 s0 16)
         ; i (addi t2 x0 0x123); i (sb t2 s0 0)
         ; i (lw t1 s0 0); i (sw t1 s0 20)
         ; i (lui t2 0x4000); i (addi t2 t2 0x567); i (sh t2 s0 0)
         ; i (lw t1 s0 0); i (sw t1 s0 24)
         ; Asm.Halt
         ])
  in
  check "lbu" (mem (ram + 4)) 0xAB;
  check "lb" (mem (ram + 8)) 0xFFFFFFAB;
  check "lhu" (mem (ram + 12)) 0x1AB;
  check "lh" (mem (ram + 16)) 0x1AB;
  check "sb" (mem (ram + 20)) 0x123;
  check "sh" (mem (ram + 24)) 0x4567;
  (* lui / auipc *)
  let mem =
    run
      (Asm.assemble
         [ i (lui s0 0x10000000)
         ; i (lui t0 0x12345000)
         ; i (sw t0 s0 0)
         ; i (auipc t1 0)
         ; i (sw t1 s0 4)
         ; Asm.Halt
         ])
  in
  check "lui" (mem ram) 0x12345000;
  check "auipc" (mem (ram + 4)) 12;
  (* immediate ALU operations *)
  let mem =
    run
      (Asm.assemble
         [ i (lui s0 0x10000000)
         ; i (addi t0 x0 0x1F)
         ; i (slti t2 t0 0x20); i (sw t2 s0 0)
         ; i (sltiu t2 t0 0x20); i (sw t2 s0 4)
         ; i (xori t2 t0 0xFF); i (sw t2 s0 8)
         ; i (ori t2 t0 0x100); i (sw t2 s0 12)
         ; i (andi t2 t0 0x0F); i (sw t2 s0 16)
         ; i (slli t2 t0 2); i (sw t2 s0 20)
         ; i (srli t2 t0 1); i (sw t2 s0 24)
         ; i (srai t2 t0 1); i (sw t2 s0 28)
         ; i (addi t2 x0 (-16))
         ; i (srai s1 t2 2); i (sw s1 s0 32)
         ; Asm.Halt
         ])
  in
  check "slti" (mem ram) 1;
  check "sltiu" (mem (ram + 4)) 1;
  check "xori" (mem (ram + 8)) 224;
  check "ori" (mem (ram + 12)) 287;
  check "andi" (mem (ram + 16)) 15;
  check "slli" (mem (ram + 20)) 124;
  check "srli" (mem (ram + 24)) 15;
  check "srai" (mem (ram + 28)) 15;
  check "srai_neg" (mem (ram + 32)) 0xFFFFFFFC;
  (* unsigned branches *)
  let mem =
    run
      (Asm.assemble
         [ i (lui s0 0x10000000)
         ; i (addi t0 x0 (-1))
         ; i (addi t1 x0 1)
         ; Asm.Branch ((fun off -> bltu t1 t0 off), "U1")
         ; i (addi t2 x0 0xBAD)
         ; Asm.Label "U1"
         ; i (addi t2 x0 1); i (sw t2 s0 0)
         ; Asm.Branch ((fun off -> bgeu t0 t1 off), "U2")
         ; i (addi t2 x0 0xBAD)
         ; Asm.Label "U2"
         ; i (addi t2 x0 2); i (sw t2 s0 4)
         ; Asm.Halt
         ])
  in
  check "bltu" (mem ram) 1;
  check "bgeu" (mem (ram + 4)) 2;
  (* JALR with an immediate offset and link *)
  let mem =
    run
      (Asm.assemble
         [ i (lui s0 0x10000000)
         ; i (auipc t0 0) (* t0 = 4 *)
         ; i (addi t0 t0 8) (* t0 = 12 *)
         ; i (jalr t1 t0 4) (* target = 16, t1 = 16 *)
         ; i (addi t2 x0 1)
         ; i (sw t2 s0 0)
         ; i (sw t1 s0 4)
         ; Asm.Halt
         ])
  in
  check "jalr_target" (mem ram) 1;
  check "jalr_link" (mem (ram + 4)) 16;
  if !failures = 0
  then Printf.printf "CPU directed tests PASSED\n"
  else (
    Printf.printf "CPU directed tests FAILED (%d)\n" !failures;
    exit 1)
;;
