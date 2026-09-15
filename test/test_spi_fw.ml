(* SPI master in firmware (mode 0, MSB first).

   Firmware bit-bangs SCK/MOSI/CS using DELAY. The testbench runs an
   edge-triggered SPI slave golden model that samples MOSI on SCK rising
   edges and drives MISO with its own byte, so both directions are checked. *)

open Hardcaml
open Proteus
open Isa

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let i n = Asm.Insn n
let ram = 0x10000000
let master_tx = 0x5A
let slave_tx = 0xC3

(* uo_out bits: MOSI=1, SCK=2, CS=3.  MISO = ui_in[0]. *)
let spi_prog =
  Asm.assemble
    [ i (lui s0 0x20000000) (* pin base *)
    ; i (lui s1 0x10000000) (* data RAM *)
    ; i (addi t0 x0 master_tx)
    ; i (addi t1 x0 8) (* bits *)
    ; i (addi t2 x0 0x80) (* mask *)
    ; i (addi t3 x0 0) (* rx *)
    ; i (addi t6 x0 8) (* half period *)
    ; i (addi t4 x0 0)
    ; i (sw t4 s0 0) (* CS low *)
    ; Asm.Label "send_loop"
    ; i (and_ t5 t0 t2)
    ; Asm.Branch ((fun off -> beq t5 x0 off), "mosi0")
    ; i (addi t4 x0 2)
    ; Asm.Jump ((fun off -> jal x0 off), "mosi_done")
    ; Asm.Label "mosi0"
    ; i (addi t4 x0 0)
    ; Asm.Label "mosi_done"
    ; i (sw t4 s0 0) (* MOSI set, SCK low *)
    ; i (delay x0 t6) (* half period *)
    ; i (ori t5 t4 4) (* SCK high *)
    ; i (sw t5 s0 0)
    ; i (lw a0 s0 8) (* read IN *)
    ; i (andi a0 a0 0x100) (* MISO *)
    ; i (srli a0 a0 8)
    ; i (slli t3 t3 1)
    ; i (or_ t3 t3 a0)
    ; i (delay x0 t6) (* half period *)
    ; i (sw t4 s0 0) (* SCK low *)
    ; i (srli t2 t2 1)
    ; i (addi t1 t1 (-1))
    ; Asm.Branch ((fun off -> bne t1 x0 off), "send_loop")
    ; i (addi t4 x0 8) (* CS high *)
    ; i (sw t4 s0 0)
    ; i (sw t3 s1 0) (* store received byte *)
    ; Asm.Halt
    ]
;;

let () =
  let sim = Sim.create (Soc.create ~program:spi_prog) in
  let (inputs : Bits.t ref Soc.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Soc.O.t) = Cyclesim.outputs sim in
  inputs.uio_in := Bits.of_int ~width:8 0;
  inputs.uart_rx := Bits.vdd;
  inputs.dbg_addr := Bits.of_int ~width:32 0;
  inputs.reset := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  inputs.reset := Bits.gnd;
  let miso = ref 0 in
  let slave_shift = ref 0 in
  let slave_rx = ref 0 in
  let prev_sck = ref 0 in
  let prev_cs = ref 1 in
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 100_000 do
    inputs.ui_in := Bits.of_int ~width:8 !miso;
    Cyclesim.cycle sim;
    let uo = Bits.to_int !(outputs.uo_out) in
    let sck = uo lsr 2 land 1 in
    let mosi = uo lsr 1 land 1 in
    let cs = uo lsr 3 land 1 in
    if cs = 0 then (
      if !prev_cs = 1
      then (
        slave_shift := slave_tx;
        slave_rx := 0;
        miso := !slave_shift lsr 7 land 1);
      if !prev_sck = 0 && sck = 1
      then slave_rx := ((!slave_rx lsl 1) lor mosi) land 0xff;
      if !prev_sck = 1 && sck = 0
      then (
        slave_shift := !slave_shift lsl 1 land 0xff;
        miso := !slave_shift lsr 7 land 1));
    prev_sck := sck;
    prev_cs := cs;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "SPI program did not halt";
  inputs.dbg_addr := Bits.of_int ~width:32 ram;
  Cyclesim.cycle sim;
  let master_rx = Bits.to_int !(outputs.dbg_rdata) in
  let failures = ref 0 in
  if master_rx <> slave_tx
  then (
    incr failures;
    Printf.printf "FAIL master rx: got 0x%02X expected 0x%02X\n" master_rx slave_tx);
  if !slave_rx <> master_tx
  then (
    incr failures;
    Printf.printf "FAIL slave rx: got 0x%02X expected 0x%02X\n" !slave_rx master_tx);
  if !failures = 0
  then Printf.printf "SPI firmware test PASSED\n"
  else exit 1
;;
