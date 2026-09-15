(* Hardware bootloader test.

   The SoC is created in boot mode with an empty instruction RAM. The test
   streams a program image (length + words, big-endian) into the UART as 8N1
   frames; the bootloader writes it into instruction RAM and releases the CPU.
   The loaded program prints 'B' on the UART, which the test decodes. *)

open Hardcaml
open Proteus
open Isa

module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)
let i n = Asm.Insn n
let clk_div = 16

(* program the bootloader will load: print 'B' then halt *)
let image =
  Asm.assemble
    [ i (lui s0 0x60000000)
    ; i (addi t0 x0 0x42)
    ; i (sw t0 s0 0)
    ; Asm.Halt
    ]
;;

(* serialise an image as the bootloader expects: big-endian length, then
   big-endian words *)
let serialize (words : int array) =
  let out = ref [] in
  let add_byte b = out := b :: !out in
  let n = Array.length words in
  for k = 3 downto 0 do
    add_byte (n lsr (8 * k) land 0xff)
  done;
  Array.iter
    (fun w ->
      for k = 3 downto 0 do
        add_byte (w lsr (8 * k) land 0xff)
      done)
    words;
  List.rev !out
;;

let () =
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
  while (not !halted) && !c < 60_000 do
    let b = if !c < Array.length stream then stream.(!c) else 1 in
    inputs.uart_rx := (if b = 1 then Bits.vdd else Bits.gnd);
    Cyclesim.cycle sim;
    captured := Bits.to_int !(outputs.uart_tx) :: !captured;
    halted := Bits.to_int !(outputs.halted) = 1;
    incr c
  done;
  if not !halted then failwith "booted program did not halt";
  (* let the UART finish shifting out *)
  for _ = 1 to 200 do
    Cyclesim.cycle sim;
    captured := Bits.to_int !(outputs.uart_tx) :: !captured
  done;
  let tx = Array.of_list (List.rev !captured) in
  let start = ref (-1) in
  for k = 1 to Array.length tx - 1 do
    if !start < 0 && tx.(k - 1) = 1 && tx.(k) = 0 then start := k
  done;
  if !start < 0 then failwith "booted program produced no UART output";
  let v = ref 0 in
  for k = 0 to 7 do
    let idx = !start + (clk_div * (k + 1)) + (clk_div / 2) in
    if idx < Array.length tx && tx.(idx) = 1 then v := !v lor (1 lsl k)
  done;
  Printf.printf "bootloader loaded image (%d words), decoded 0x%02X\n" (Array.length image) !v;
  if !v <> 0x42
  then (
    Printf.printf "FAIL bootloader: expected 0x42\n";
    exit 1);
  Printf.printf "bootloader test PASSED\n"
;;
