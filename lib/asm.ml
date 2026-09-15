(* A tiny two-pass assembler for Proteus firmware.

   Firmware is written as a list of items. Labels are resolved in a first
   pass, then branch/jump offsets are patched in a second pass. [Halt] expands
   to a store to the SoC's HALT register (which freezes the core) so that
   EBREAK is free to trap. *)

type item =
  | Insn of int (* an already-encoded instruction *)
  | Label of string
  | Branch of (int -> int) * string (* given a byte offset, build the branch *)
  | Jump of (int -> int) * string
  | La of int * string (* load the address of a label into a register *)
  | Halt

(* x31 is used as scratch here; it is only touched at program termination. *)
let halt_words () = [ Isa.lui 31 0x70000000; Isa.sw Isa.x0 31 0 ]

let size_of = function
  | Halt -> 8
  | La _ -> 8
  | _ -> 4
;;

(* auipc/addi pair computing the address of a label within +/-2KiB *)
let la_words rd target addr =
  let delta = target - addr in
  let hi = (delta + 0x800) asr 12 in
  let lo = delta - (hi lsl 12) in
  [ Isa.auipc rd (hi lsl 12); Isa.addi rd rd lo ]
;;

let assemble (items : item list) : int array =
  let labels = Hashtbl.create 16 in
  let addr = ref 0 in
  List.iter
    (function
      | Label name -> Hashtbl.replace labels name !addr
      | item -> addr := !addr + size_of item)
    items;
  let out = ref [] in
  let addr = ref 0 in
  let emit w =
    out := w :: !out;
    addr := !addr + 4
  in
  let patch f name =
    let off = Hashtbl.find labels name - !addr in
    emit (f off)
  in
  List.iter
    (function
      | Insn w -> emit w
      | Label _ -> ()
      | Branch (f, name) -> patch f name
      | Jump (f, name) -> patch f name
      | La (rd, name) -> List.iter emit (la_words rd (Hashtbl.find labels name) !addr)
      | Halt -> List.iter emit (halt_words ()))
    items;
  Array.of_list (List.rev !out)
;;
