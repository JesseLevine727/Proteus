(* A tiny two-pass assembler for Proteus firmware.

   Firmware is written as a list of items. Labels are resolved in a first
   pass, then branch/jump offsets are patched in a second pass. This is enough
   for Phase 1; a real assembler/linker arrives in Phase 2. *)

type item =
  | Insn of int (* an already-encoded instruction *)
  | Label of string
  | Branch of (int -> int) * string (* given a byte offset, build the branch *)
  | Jump of (int -> int) * string

let assemble (items : item list) : int array =
  let labels = Hashtbl.create 16 in
  let addr = ref 0 in
  List.iter
    (function
      | Label name -> Hashtbl.replace labels name !addr
      | _ -> addr := !addr + 4)
    items;
  let out = ref [] in
  let addr = ref 0 in
  let patch f name =
    let off = Hashtbl.find labels name - !addr in
    out := f off :: !out;
    addr := !addr + 4
  in
  List.iter
    (function
      | Insn w ->
        out := w :: !out;
        addr := !addr + 4
      | Label _ -> ()
      | Branch (f, name) -> patch f name
      | Jump (f, name) -> patch f name)
    items;
  Array.of_list (List.rev !out)
;;
