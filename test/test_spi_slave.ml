(* SPI slave test (mode 0, MSB first).

   The testbench acts as the SPI master: it drives CS/SCK/MOSI and samples
   MISO. The firmware slave receives a byte and sends a fixed one. *)

open Hardcaml
open Proteus

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let ram = 0x10000700
let half = 20
let master_tx = 0x3C
let slave_tx = 0x5A

let () =
  let seq = ref [] in
  let add cs sck mosi = seq := (cs, sck, mosi, false) :: !seq in
  let sample cs sck mosi = seq := (cs, sck, mosi, true) :: !seq in
  add 1 0 0;
  add 0 0 0; (* CS low *)
  for i = 7 downto 0 do
    let b = master_tx lsr i land 1 in
    add 0 0 b; (* set MOSI while SCK low *)
    sample 0 1 b; (* SCK high: slave samples MOSI, master samples MISO *)
    add 0 0 b (* SCK low: slave shifts MISO *)
  done;
  add 1 0 0;
  let seq = List.rev !seq in
  let sim = Sim.create (Soc.create ~program:Spi_slave_firmware.spi_slave) in
  let (inputs : Bits.t ref Soc.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Soc.O.t) = Cyclesim.outputs sim in
  inputs.uio_in := Bits.of_int ~width:8 0;
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
  while (not !halted) && !c < (n * half) + 2000 do
    let idx = min (!c / half) (n - 1) in
    let cs, sck, mosi, smp = List.nth seq idx in
    inputs.ui_in := Bits.of_int ~width:8 ((cs lsl 2) lor (mosi lsl 1) lor sck);
    Cyclesim.cycle sim;
    if smp && !c mod half = half - 1
    then samples := (Bits.to_int !(outputs.uo_out) land 1) :: !samples;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "SPI slave program did not halt";
  let read addr =
    inputs.dbg_addr := Bits.of_int ~width:32 addr;
    Cyclesim.cycle sim;
    Bits.to_int !(outputs.dbg_rdata)
  in
  let slave_rx = read ram in
  let mst =
    List.fold_left (fun a b -> (a lsl 1) lor b) 0 (List.rev !samples)
  in
  Printf.printf "slave received 0x%02X, master received 0x%02X\n" slave_rx mst;
  let failures = ref 0 in
  if slave_rx <> master_tx
  then (
    incr failures;
    Printf.printf "FAIL slave rx\n");
  if mst <> slave_tx
  then (
    incr failures;
    Printf.printf "FAIL master rx\n");
  if !failures = 0
  then Printf.printf "SPI slave test PASSED\n"
  else exit 1
;;
