(* I2C slave test.

   The testbench acts as the I2C master, driving SCL/SDA and reading the
   wired-AND bus. The firmware is an I2C slave at address 0x50. A write
   transaction sends one data byte; a read transaction clocks one byte out of
   the slave. Both are checked. *)

open Hardcaml
open Proteus

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let ram = 0x10000700 (* results section *)
let half = 30

(* build a master waveform: (scl, sda, sample) *)
let write_seq addr_byte data_byte =
  let seq = ref [] in
  let add scl sda = seq := (scl, sda, false) :: !seq in
  let sample scl sda = seq := (scl, sda, true) :: !seq in
  add 1 1;
  add 1 0; add 0 0; (* START *)
  for i = 7 downto 0 do
    let b = addr_byte lsr i land 1 in
    add 0 b; add 1 b
  done;
  add 0 1; sample 1 1; add 0 1; (* address ACK *)
  for i = 7 downto 0 do
    let b = data_byte lsr i land 1 in
    add 0 b; add 1 b
  done;
  add 0 1; sample 1 1; add 0 1; (* data ACK *)
  add 0 0; add 1 0; add 1 1 (* STOP *)
  ;
  List.rev !seq
;;

let read_seq addr_byte =
  let seq = ref [] in
  let add scl sda = seq := (scl, sda, false) :: !seq in
  let sample scl sda = seq := (scl, sda, true) :: !seq in
  add 1 1;
  add 1 0; add 0 0; (* START *)
  for i = 7 downto 0 do
    let b = addr_byte lsr i land 1 in
    add 0 b; add 1 b
  done;
  add 0 1; sample 1 1; add 0 1; (* address ACK *)
  for _ = 1 to 8 do
    add 0 1; sample 1 1 (* release SDA, read the slave's data bit *)
  done;
  add 0 1; add 1 1; add 0 1; (* NACK *)
  add 0 0; add 1 0; add 1 1 (* STOP *)
  ;
  List.rev !seq
;;

let run seq =
  let sim = Sim.create (Soc.create ~program:I2c_slave_firmware.i2c_slave) in
  let (inputs : Bits.t ref Soc.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Soc.O.t) = Cyclesim.outputs sim in
  inputs.ui_in := Bits.of_int ~width:8 0;
  inputs.uart_rx := Bits.vdd;
  inputs.dbg_addr := Bits.of_int ~width:32 0;
  inputs.reset := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  inputs.reset := Bits.gnd;
  let n = List.length seq in
  let samples = ref [] in
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < n * half + 2000 do
    let idx = min (!c / half) (n - 1) in
    let scl, sda, smp = List.nth seq idx in
    inputs.uio_in := Bits.of_int ~width:8 ((scl lsl 1) lor sda);
    Cyclesim.cycle sim;
    let slave_sda_low = Bits.to_int !(outputs.uio_oe) land 1 = 1 in
    let bus_sda = if slave_sda_low then 0 else sda in
    if smp && !c mod half = half - 1 then samples := bus_sda :: !samples;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "I2C slave program did not halt";
  let read addr =
    inputs.dbg_addr := Bits.of_int ~width:32 addr;
    Cyclesim.cycle sim;
    Bits.to_int !(outputs.dbg_rdata)
  in
  List.rev !samples, read ram, read (ram + 4), read (ram + 8), read (ram + 12)
;;

let failures = ref 0

let check name got expected =
  if got <> expected
  then (
    incr failures;
    Printf.printf "FAIL %s: got 0x%X expected 0x%X\n" name got expected)
;;

let () =
  (* write transaction: address 0xA0, data 0x3C *)
  let samples, got, rw, addr_byte, _ = run (write_seq 0xA0 0x3C) in
  Printf.printf "write: samples=%s got=0x%02X rw=%d addr=0x%02X\n"
    (String.concat "," (List.map string_of_int samples))
    got rw addr_byte;
  check "write_addr_ack" (List.nth samples 0) 0;
  check "write_data_ack" (List.nth samples 1) 0;
  check "write_data" got 0x3C;
  check "write_addr_byte" addr_byte 0xA0;
  (* read transaction: address 0xA1, slave sends 0x42 *)
  let samples, _, rw, addr_byte, ack = run (read_seq 0xA1) in
  let bits = List.filteri (fun i _ -> i >= 1) samples in
  let data =
    List.fold_left (fun a b -> (a lsl 1) lor b) 0 (List.filteri (fun i _ -> i < 8) bits)
  in
  Printf.printf "read: data=0x%02X rw=%d addr=0x%02X master_ack=%d\n" data rw addr_byte ack;
  check "read_data" data 0x42;
  check "read_addr_byte" addr_byte 0xA1;
  check "read_rw" rw 1;
  if !failures = 0
  then Printf.printf "I2C slave tests PASSED\n"
  else exit 1
;;
