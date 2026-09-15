(* I2C master read path in firmware.

   The master issues START, sends the address with the read bit set, then
   releases SDA and reads eight data bits clocked out by the slave, sends a
   NACK and STOP. The testbench models a pull-up slave that ACKs the address
   and drives a data byte. *)

open Hardcaml
open Proteus
open Isa

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let i n = Asm.Insn n
let ram = 0x10000000
let addr_byte = 0xA1 (* 0x50 << 1 | read *)
let data_byte = 0x5C

let prog =
  Asm.assemble
    [ i (lui s0 0x20000000)
    ; i (lui s1 0x10000000)
    ; i (sw x0 s0 0) (* OUT = 0 *)
    ; i (addi t0 x0 0); i (sw t0 s0 4) (* OE = 0 *)
    ; i (addi s2 x0 1); i (slli s2 s2 16) (* SDA *)
    ; i (addi s3 x0 1); i (slli s3 s3 17) (* SCL *)
    ; i (addi s4 x0 (-1)); i (xor s4 s4 s2) (* ~SDA *)
    ; i (addi s5 x0 (-1)); i (xor s5 s5 s3) (* ~SCL *)
    ; i (addi a0 x0 8) (* delay *)
    (* START *)
    ; i (or_ t0 t0 s3); i (sw t0 s0 4); i (delay x0 a0)
    ; i (and_ t0 t0 s4); i (sw t0 s0 4); i (delay x0 a0)
    ; i (or_ t0 t0 s2); i (sw t0 s0 4); i (delay x0 a0)
    ; i (or_ t0 t0 s3); i (sw t0 s0 4); i (delay x0 a0)
    (* address + read *)
    ; i (addi t3 x0 addr_byte)
    ; Asm.Jump ((fun off -> jal ra off), "send_byte")
    ; i (sw a1 s1 0) (* address ACK *)
    (* read 8 bits *)
    ; i (addi t4 x0 0) (* accumulator *)
    ; i (addi t5 x0 8) (* bit count *)
    ; Asm.Label "read_loop"
    ; i (and_ t0 t0 s4) (* release SDA *)
    ; i (or_ t0 t0 s3); i (sw t0 s0 4); i (delay x0 a0)
    ; i (and_ t0 t0 s5); i (sw t0 s0 4); i (delay x0 a0)
    ; i (lw a2 s0 8); i (and_ a2 a2 s2); i (srli a2 a2 16)
    ; i (slli t4 t4 1); i (or_ t4 t4 a2)
    ; i (or_ t0 t0 s3); i (sw t0 s0 4); i (delay x0 a0)
    ; i (addi t5 t5 (-1))
    ; Asm.Branch ((fun off -> bne t5 x0 off), "read_loop")
    (* NACK: release SDA, pulse SCL *)
    ; i (and_ t0 t0 s4)
    ; i (or_ t0 t0 s3); i (sw t0 s0 4); i (delay x0 a0)
    ; i (and_ t0 t0 s5); i (sw t0 s0 4); i (delay x0 a0)
    ; i (or_ t0 t0 s3); i (sw t0 s0 4); i (delay x0 a0)
    (* STOP *)
    ; i (and_ t0 t0 s5); i (sw t0 s0 4); i (delay x0 a0)
    ; i (and_ t0 t0 s4); i (sw t0 s0 4); i (delay x0 a0)
    ; i (sw t4 s1 4) (* read byte *)
    ; Asm.Halt
    ; Asm.Label "send_byte"
    ; i (addi t6 x0 0x80)
    ; i (addi t5 x0 8)
    ; Asm.Label "sb_loop"
    ; i (and_ a2 t3 t6)
    ; Asm.Branch ((fun off -> beq a2 x0 off), "sb_zero")
    ; i (and_ t0 t0 s4)
    ; Asm.Jump ((fun off -> jal x0 off), "sb_set")
    ; Asm.Label "sb_zero"
    ; i (or_ t0 t0 s2)
    ; Asm.Label "sb_set"
    ; i (or_ t0 t0 s3); i (sw t0 s0 4); i (delay x0 a0)
    ; i (and_ t0 t0 s5); i (sw t0 s0 4); i (delay x0 a0)
    ; i (or_ t0 t0 s3); i (sw t0 s0 4); i (delay x0 a0)
    ; i (srli t6 t6 1)
    ; i (addi t5 t5 (-1))
    ; Asm.Branch ((fun off -> bne t5 x0 off), "sb_loop")
    ; i (and_ t0 t0 s4); i (sw t0 s0 4); i (delay x0 a0)
    ; i (and_ t0 t0 s5); i (sw t0 s0 4); i (delay x0 a0)
    ; i (lw a1 s0 8); i (and_ a1 a1 s2); i (srli a1 a1 16)
    ; i (or_ t0 t0 s3); i (sw t0 s0 4); i (delay x0 a0)
    ; i (jalr x0 ra 0)
    ]
;;

let () =
  let sim = Sim.create (Soc.create ~program:prog) in
  let (inputs : Bits.t ref Soc.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Soc.O.t) = Cyclesim.outputs sim in
  inputs.ui_in := Bits.of_int ~width:8 0;
  inputs.uart_rx := Bits.vdd;
  inputs.dbg_addr := Bits.of_int ~width:32 0;
  inputs.reset := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  inputs.reset := Bits.gnd;
  let prev_scl = ref 1 in
  let byte_idx = ref 0 (* 0 = address, 1 = data *) in
  let bit_count = ref 0 in
  let shift = ref 0 in
  let tx_shift = ref data_byte in
  let driving = ref false in
  let slave_sda_low = ref false in
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 100_000 do
    let uo_out = Bits.to_int !(outputs.uio_out) in
    let uo_oe = Bits.to_int !(outputs.uio_oe) in
    let master_sda_low = uo_oe land 1 = 1 && uo_out land 1 = 0 in
    let master_scl_low = uo_oe lsr 1 land 1 = 1 && uo_out lsr 1 land 1 = 0 in
    let sda_low = master_sda_low || !slave_sda_low in
    let sda = if sda_low then 0 else 1 in
    let scl = if master_scl_low then 0 else 1 in
    inputs.uio_in := Bits.of_int ~width:8 ((scl lsl 1) lor sda);
    Cyclesim.cycle sim;
    if !prev_scl = 0 && scl = 1
    then (
      if !bit_count < 8
      then (
        if !byte_idx = 0 then shift := ((!shift lsl 1) lor sda) land 0xff;
        incr bit_count)
      else (
        bit_count := 0;
        if !byte_idx = 0
        then (
          byte_idx := 1;
          driving := !shift land 1 = 1)
        else (
          byte_idx := 0;
          driving := false)))
    else if !prev_scl = 1 && scl = 0
    then (
      if !byte_idx = 0 && !bit_count = 8
      then slave_sda_low := true (* ACK the address *)
      else if !byte_idx = 1 && !driving
      then (
        slave_sda_low := !tx_shift lsr 7 land 1 = 0;
        tx_shift := !tx_shift lsl 1 land 0xff)
      else slave_sda_low := false);
    prev_scl := scl;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "I2C read program did not halt";
  inputs.dbg_addr := Bits.of_int ~width:32 ram;
  Cyclesim.cycle sim;
  let ack_addr = Bits.to_int !(outputs.dbg_rdata) in
  inputs.dbg_addr := Bits.of_int ~width:32 (ram + 4);
  Cyclesim.cycle sim;
  let got = Bits.to_int !(outputs.dbg_rdata) in
  Printf.printf "read byte = 0x%02X (want 0x%02X), addr ack = %d\n" got data_byte ack_addr;
  let failures = ref 0 in
  if got <> data_byte
  then (
    incr failures;
    Printf.printf "FAIL read byte\n");
  if ack_addr <> 0
  then (
    incr failures;
    Printf.printf "FAIL address ACK\n");
  if !failures = 0
  then Printf.printf "I2C read test PASSED\n"
  else exit 1
;;
