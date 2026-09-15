(* Emit synthesizable Verilog for the Hardcaml designs.

   Usage: dune exec bin/generate_verilog.exe
   Output lands in ./rtl/<circuit>.v *)

open Hardcaml
open Proteus

let () =
  let out_dir = "rtl" in
  if not (Sys.file_exists out_dir) then Unix.mkdir out_dir 0o755;
  let write circuit =
    Rtl.output
      ~output_mode:(Rtl.Output_mode.In_directory out_dir)
      Rtl.Language.Verilog
      circuit;
    Stdio.printf "Wrote %s/%s.v\n" out_dir (Circuit.name circuit)
  in
  let module Uart_tx_circuit = Circuit.With_interface (Uart_tx.I) (Uart_tx.O) in
  write (Uart_tx_circuit.create_exn ~name:"uart_tx" Uart_tx.create);
  (* Phase 2 SoC running the compiled C firmware image *)
  let module Soc_circuit = Circuit.With_interface (Soc.I) (Soc.O) in
  write
    (Soc_circuit.create_exn
       ~name:"proteus_soc"
       (Soc.create ~program:C_firmware.hello))
;;
