(* 32 x 32-bit register file: two combinational read ports, one synchronous
   write port. Register x0 is hardwired to zero. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; reset : 'a
    ; rs1 : 'a [@bits 5]
    ; rs2 : 'a [@bits 5]
    ; rd : 'a [@bits 5]
    ; wdata : 'a [@bits 32]
    ; we : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { rs1_data : 'a [@bits 32]
    ; rs2_data : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

let create (i : Signal.t I.t) : Signal.t O.t =
  let reg_spec = Reg_spec.create ~clock:i.clock ~clear:i.reset () in
  let regs =
    Array.init 32 (fun idx ->
      let idx_s = Signal.of_int ~width:5 idx in
      let enable = i.we &: (i.rd ==: idx_s) &: (i.rd <>:. 0) in
      Signal.reg_fb reg_spec ~enable ~width:32 ~f:(fun _ -> i.wdata))
  in
  let read r = Signal.mux r (Array.to_list regs) in
  { O.rs1_data = read i.rs1; O.rs2_data = read i.rs2 }
;;
