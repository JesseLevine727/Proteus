(* Phase 2 exit test: compiled C firmware prints over the UART.

   The same image is run two ways: loaded directly into instruction memory,
   and streamed in through the hardware bootloader. *)

open Hardcaml
open Proteus

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let clk_div = 16
let expected = "Hello from Proteus C!\n"

let decode_all tx =
  let n = Array.length tx in
  let bytes = ref [] in
  let i = ref 0 in
  while !i < n do
    if !i > 0 && tx.(!i - 1) = 1 && tx.(!i) = 0
    then (
      let v = ref 0 in
      for k = 0 to 7 do
        let idx = !i + (clk_div * (k + 1)) + (clk_div / 2) in
        if idx < n && tx.(idx) = 1 then v := !v lor (1 lsl k)
      done;
      bytes := !v :: !bytes;
      i := !i + (10 * clk_div))
    else incr i
  done;
  let b = Array.of_list (List.rev !bytes) in
  let s = Bytes.create (Array.length b) in
  Array.iteri (fun k v -> Bytes.set s k (Char.chr (v land 0xff))) b;
  Bytes.to_string s
;;

let capture sim =
  let (inputs : Bits.t ref Soc.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Soc.O.t) = Cyclesim.outputs sim in
  inputs.ui_in := Bits.of_int ~width:8 0;
  inputs.uio_in := Bits.of_int ~width:8 0;
  inputs.uart_rx := Bits.vdd;
  inputs.dbg_addr := Bits.of_int ~width:32 0;
  inputs.reset := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  inputs.reset := Bits.gnd;
  let captured = ref [] in
  let halted = ref false in
  let n = ref 0 in
  while (not !halted) && !n < 200_000 do
    Cyclesim.cycle sim;
    captured := Bits.to_int !(outputs.uart_tx) :: !captured;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr n
  done;
  if not !halted then failwith "C firmware did not halt";
  for _ = 1 to 1000 do
    Cyclesim.cycle sim;
    captured := Bits.to_int !(outputs.uart_tx) :: !captured
  done;
  Array.of_list (List.rev !captured)
;;

let serialize (words : int array) =
  let out = ref [] in
  let add b = out := b :: !out in
  let n = Array.length words in
  for k = 3 downto 0 do
    add (n lsr (8 * k) land 0xff)
  done;
  Array.iter
    (fun w ->
      for k = 3 downto 0 do
        add (w lsr (8 * k) land 0xff)
      done)
    words;
  List.rev !out
;;

let run_booted image =
  let bytes = serialize image in
  let idle = 20 in
  let stream =
    Array.of_list
      (List.init idle (fun _ -> 1)
       @ List.concat_map
           (fun byte ->
             let frame =
               List.init 10 (fun k ->
                 if k = 0 then 0 else if k = 9 then 1 else byte lsr (k - 1) land 1)
             in
             List.concat_map (fun b -> List.init clk_div (fun _ -> b)) frame)
           bytes
       @ List.init 20 (fun _ -> 1))
  in
  let sim = Sim.create (Soc.create ~boot:true ~program:[||]) in
  let (inputs : Bits.t ref Soc.I.t) = Cyclesim.inputs sim in
  let (outputs : Bits.t ref Soc.O.t) = Cyclesim.outputs sim in
  inputs.ui_in := Bits.of_int ~width:8 0;
  inputs.uio_in := Bits.of_int ~width:8 0;
  inputs.dbg_addr := Bits.of_int ~width:32 0;
  inputs.uart_rx := Bits.vdd;
  inputs.reset := Bits.vdd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  inputs.reset := Bits.gnd;
  let captured = ref [] in
  let halted = ref false in
  let c = ref 0 in
  while (not !halted) && !c < 400_000 do
    let b = if !c < Array.length stream then stream.(!c) else 1 in
    inputs.uart_rx := (if b = 1 then Bits.vdd else Bits.gnd);
    Cyclesim.cycle sim;
    captured := Bits.to_int !(outputs.uart_tx) :: !captured;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "booted C firmware did not halt";
  for _ = 1 to 1000 do
    Cyclesim.cycle sim;
    captured := Bits.to_int !(outputs.uart_tx) :: !captured
  done;
  Array.of_list (List.rev !captured)
;;

let check name got =
  if got <> expected
  then (
    Printf.printf "FAIL %s: got %S expected %S\n" name got expected;
    exit 1)
;;

let () =
  let image = C_firmware.hello in
  Printf.printf "C image: %d words\n" (Array.length image);
  check "direct" (decode_all (capture (Sim.create (Soc.create ~program:image))));
  check "bootloader" (decode_all (run_booted image));
  Printf.printf "C firmware test PASSED\n"
;;
