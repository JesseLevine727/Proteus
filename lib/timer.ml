(* RISC-V machine timer (mtime / mtimecmp).

   Memory-mapped within a 16-word page:
     offset 0  mtime low
     offset 4  mtime high
     offset 8  mtimecmp low
     offset 12 mtimecmp high

   [mtime] is a free-running 64-bit counter; the machine timer interrupt is
   asserted while [mtime >= mtimecmp]. Writes are full-word. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; reset : 'a
    ; sel : 'a
    ; we : 'a
    ; addr : 'a [@bits 4] (* word offset *)
    ; wdata : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { rdata : 'a [@bits 32]
    ; irq : 'a
    }
  [@@deriving hardcaml]
end

let create (i : Signal.t I.t) : Signal.t O.t =
  let reg_spec = Reg_spec.create ~clock:i.clock ~clear:i.reset () in
  let is a = i.addr ==:. a in
  let mtime =
    Signal.reg_fb reg_spec ~width:64 ~f:(fun cur ->
      let low_we = i.we &: i.sel &: is 0 in
      let high_we = i.we &: i.sel &: is 1 in
      let inc = cur +:. 1 in
      Signal.mux2
        low_we
        (Signal.concat_msb [ Signal.select cur 63 32; Signal.select i.wdata 31 0 ])
        (Signal.mux2
           high_we
           (Signal.concat_msb [ Signal.select i.wdata 31 0; Signal.select cur 31 0 ])
           inc))
  in
  let mtimecmp =
    Signal.reg_fb reg_spec ~width:64 ~f:(fun cur ->
      let low_we = i.we &: i.sel &: is 2 in
      let high_we = i.we &: i.sel &: is 3 in
      Signal.mux2
        low_we
        (Signal.concat_msb [ Signal.select cur 63 32; Signal.select i.wdata 31 0 ])
        (Signal.mux2
           high_we
           (Signal.concat_msb [ Signal.select i.wdata 31 0; Signal.select cur 31 0 ])
           cur))
  in
  let rdata =
    Signal.mux
      i.addr
      [ Signal.select mtime 31 0
      ; Signal.select mtime 63 32
      ; Signal.select mtimecmp 31 0
      ; Signal.select mtimecmp 63 32
      ; Signal.zero 32
      ; Signal.zero 32
      ; Signal.zero 32
      ; Signal.zero 32
      ; Signal.zero 32
      ; Signal.zero 32
      ; Signal.zero 32
      ; Signal.zero 32
      ; Signal.zero 32
      ; Signal.zero 32
      ; Signal.zero 32
      ; Signal.zero 32
      ]
  in
  let irq = mtime >=: mtimecmp in
  { O.rdata; irq }
;;
