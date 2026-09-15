(* Emit synthesizable Verilog for the Hardcaml designs.

   Usage: dune exec bin/generate_verilog.exe
   Output lands in ./rtl/<circuit>.v *)

open Hardcaml
open Proteus

let () =
  let out_dir = "rtl" in
  if not (Sys.file_exists out_dir) then Unix.mkdir out_dir 0o755;
  let module Uart_tx_circuit = Circuit.With_interface (Uart_tx.I) (Uart_tx.O) in
  let uart_tx = Uart_tx_circuit.create_exn ~name:"uart_tx" Uart_tx.create in
  Rtl.output
    ~output_mode:(Rtl.Output_mode.In_directory out_dir)
    Rtl.Language.Verilog
    uart_tx;
  Stdio.printf "Wrote %s/uart_tx.v\n" out_dir
;;
