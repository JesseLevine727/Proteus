(* I2C master in firmware.

   SDA = uio[0], SCL = uio[1], both open-drain (drive low / release to a
   pull-up). Firmware issues START, sends an address byte and a data byte,
   reads the ACK bits, then STOP. The testbench models an I2C slave with
   pull-ups that samples on SCL rising edges and pulls SDA low for ACK. *)

open Hardcaml
open Proteus
open Isa

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let i n = Asm.Insn n
let ram = 0x10000000
let addr_byte = 0xA0
let data_byte = 0xA5

let i2c_prog =
  Asm.assemble
    [ i (lui s0 0x20000000) (* pin base *)
    ; i (lui s1 0x10000000) (* data RAM *)
    ; i (sw x0 s0 0) (* OUT = 0: we only drive low *)
    ; i (addi t0 x0 0)
    ; i (sw t0 s0 4) (* OE = 0: both released *)
    ; i (addi s2 x0 1); i (slli s2 s2 16) (* SDA = bit16 *)
    ; i (addi s3 x0 1); i (slli s3 s3 17) (* SCL = bit17 *)
    ; i (addi s4 x0 (-1)); i (xor s4 s4 s2) (* ~SDA *)
    ; i (addi s5 x0 (-1)); i (xor s5 s5 s3) (* ~SCL *)
    ; i (addi a0 x0 8) (* delay *)
    (* START: SCL low, SDA high -> SDA low -> SCL low *)
    ; i (or_ t0 t0 s3); i (sw t0 s0 4); i (delay x0 a0)
    ; i (and_ t0 t0 s4); i (sw t0 s0 4); i (delay x0 a0)
    ; i (or_ t0 t0 s2); i (sw t0 s0 4); i (delay x0 a0)
    ; i (or_ t0 t0 s3); i (sw t0 s0 4); i (delay x0 a0)
    (* address byte *)
    ; i (addi t3 x0 addr_byte)
    ; Asm.Jump ((fun off -> jal ra off), "send_byte")
    ; i (sw a1 s1 0) (* ACK for address *)
    (* data byte *)
    ; i (addi t3 x0 data_byte)
    ; Asm.Jump ((fun off -> jal ra off), "send_byte")
    ; i (sw a1 s1 4) (* ACK for data *)
    (* STOP: SCL high, then SDA high *)
    ; i (and_ t0 t0 s5); i (sw t0 s0 4); i (delay x0 a0)
    ; i (and_ t0 t0 s4); i (sw t0 s0 4); i (delay x0 a0)
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
    (* ACK bit: release SDA, pulse SCL, read SDA *)
    ; i (and_ t0 t0 s4); i (sw t0 s0 4); i (delay x0 a0)
    ; i (and_ t0 t0 s5); i (sw t0 s0 4); i (delay x0 a0)
    ; i (lw a1 s0 8); i (and_ a1 a1 s2); i (srli a1 a1 16)
    ; i (or_ t0 t0 s3); i (sw t0 s0 4); i (delay x0 a0)
    ; i (jalr x0 ra 0)
    ]
;;

let () =
  let sim = Sim.create (Soc.create ~program:i2c_prog) in
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
  let clk_count = ref 0 in
  let ack_hold = ref false in
  let shift = ref 0 in
  let received = ref [] in
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 200_000 do
    (* compute the bus levels from the master's drives and the slave's ACK *)
    let uo_out = Bits.to_int !(outputs.uio_out) in
    let uo_oe = Bits.to_int !(outputs.uio_oe) in
    let master_sda_low = uo_oe land 1 = 1 && uo_out land 1 = 0 in
    let master_scl_low = uo_oe lsr 1 land 1 = 1 && uo_out lsr 1 land 1 = 0 in
    let slave_ack = !clk_count = 8 || !ack_hold in
    let sda = if master_sda_low || slave_ack then 0 else 1 in
    let scl = if master_scl_low then 0 else 1 in
    inputs.uio_in := Bits.of_int ~width:8 ((scl lsl 1) lor sda);
    Cyclesim.cycle sim;
    if !prev_scl = 0 && scl = 1
    then (
      if !clk_count < 8
      then (
        shift := ((!shift lsl 1) lor sda) land 0xff;
        incr clk_count;
        if !clk_count = 8
        then (
          received := !shift :: !received;
          shift := 0))
      else (
        ack_hold := true;
        clk_count := 0))
    else if !prev_scl = 1 && scl = 0
    then ack_hold := false;
    prev_scl := scl;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "I2C program did not halt";
  inputs.dbg_addr := Bits.of_int ~width:32 ram;
  Cyclesim.cycle sim;
  let ack_addr = Bits.to_int !(outputs.dbg_rdata) in
  inputs.dbg_addr := Bits.of_int ~width:32 (ram + 4);
  Cyclesim.cycle sim;
  let ack_data = Bits.to_int !(outputs.dbg_rdata) in
  let got = List.rev !received in
  let failures = ref 0 in
  if got <> [ addr_byte; data_byte ]
  then (
    incr failures;
    Printf.printf
      "FAIL slave received %s\n"
      (String.concat "," (List.map (Printf.sprintf "0x%02X") got)));
  if ack_addr <> 0
  then (
    incr failures;
    Printf.printf "FAIL address ACK: got %d\n" ack_addr);
  if ack_data <> 0
  then (
    incr failures;
    Printf.printf "FAIL data ACK: got %d\n" ack_data);
  if !failures = 0
  then Printf.printf "I2C firmware test PASSED\n"
  else exit 1
;;
