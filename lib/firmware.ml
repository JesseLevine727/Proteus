(* Firmware images for the Proteus SoC.

   These are assembled here in OCaml rather than by an external toolchain so
   that Phase 1 stays self-contained. A real assembler/linker arrives in
   Phase 2.

   Register conventions used below:
     x1  ra   return address
     x5  t0   frame / shift register
     x6  t1   bit counter
     x7  t2   scratch bit
     x8  s0   peripheral base address
     x9  s1   delay loop counter
     x10 a0   delay loop reload value *)

open Isa

(* Bit period, in cycles, of the bit-banged UART transmitter produced by
   [uart_tx] below. Each bit runs the same code path, so the period is exact
   and uniform:
     andi, sb, jal, (addi + delay*(addi+bne)), jalr, srli, addi, bne
   = 8 + 2*delay cycles. *)
let uart_tx_period ~delay = 8 + (2 * delay)

(* Transmit one byte over GPIO bit 0 as 8N1, LSB first, then halt.
   The 10-bit frame is shifted out LSB first: start(0), data[7:0], stop(1). *)
let uart_tx ~(byte : int) ~(delay : int) () : int array =
  let frame = (1 lsl 9) lor ((byte land 0xff) lsl 1) in
  Asm.assemble
    [ Asm.Insn (lui s0 0x20000000) (* x8 = 0x2000_0000, GPIO *)
    ; Asm.Insn (addi t0 x0 frame) (* x5 = 10-bit frame *)
    ; Asm.Insn (addi t1 x0 10) (* x6 = 10 bits to send *)
    ; Asm.Insn (addi a0 x0 delay) (* x10 = delay reload *)
    ; Asm.Insn (addi t2 x0 1) (* idle line high *)
    ; Asm.Insn (sb t2 s0 0)
    ; Asm.Label "send_loop"
    ; Asm.Insn (andi t2 t0 1) (* bit = frame & 1 *)
    ; Asm.Insn (sb t2 s0 0) (* drive GPIO *)
    ; Asm.Jump ((fun off -> jal ra off), "bit_delay")
    ; Asm.Insn (srli t0 t0 1) (* shift frame *)
    ; Asm.Insn (addi t1 t1 (-1)) (* one fewer bit *)
    ; Asm.Branch ((fun off -> bne t1 x0 off), "send_loop")
    ; Asm.Halt
    ; Asm.Label "bit_delay"
    ; Asm.Insn (addi s1 a0 0) (* x9 = delay *)
    ; Asm.Label "bd_loop"
    ; Asm.Insn (addi s1 s1 (-1)) (* decrement *)
    ; Asm.Branch ((fun off -> bne s1 x0 off), "bd_loop")
    ; Asm.Insn (jalr x0 ra 0) (* return *)
    ]
;;

(* A small program that exercises the load/store path, used by directed CPU
   tests. Writes 0x123 and 0x456 to RAM, then their sum to mem[2]. *)
let ram_pattern () : int array =
  Asm.assemble
    [ Asm.Insn (lui s0 0x10000000) (* x8 = 0x1000_0000, data RAM *)
    ; Asm.Insn (addi t0 x0 0x123)
    ; Asm.Insn (sw t0 s0 0)
    ; Asm.Insn (addi t0 x0 0x456)
    ; Asm.Insn (sw t0 s0 4)
    ; Asm.Insn (lw t1 s0 0)
    ; Asm.Insn (add t1 t1 t0)
    ; Asm.Insn (sw t1 s0 8)
    ; Asm.Halt
    ]
;;
