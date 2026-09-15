(* Programmable pin subsystem (Phase 3).

   A unified 24-pin view. Pin numbering (bit position in the 24-bit registers):

     0..7   uo_out[0..7]   output pins (output-enable forced on)
     8..15  ui_in[0..7]    input pins  (output-enable forced off)
     16..23 uio[0..7]      bidirectional pins (output-enable controlled)

   Registers (word offsets), all 24 bits wide:
     0  OUT      output value (write)
     1  OE       output enable for uio
     2  IN       current pin levels (read)
     3  SET      write 1s to set output bits
     4  CLR      write 1s to clear output bits
     5  TOGGLE   write 1s to toggle output bits
     6  RISE     latched rising edges, write 1 to clear
     7  FALL     latched falling edges, write 1 to clear
     8  IRQ_EN   per-pin interrupt enable
     9  IRQ_PEND pending enabled edges, write 1 to clear *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; reset : 'a
    ; sel : 'a
    ; we : 'a
    ; addr : 'a [@bits 4]
    ; wdata : 'a [@bits 32]
    ; pin_in : 'a [@bits 24]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { rdata : 'a [@bits 32]
    ; out : 'a [@bits 24]
    ; oe : 'a [@bits 24]
    ; irq : 'a
    }
  [@@deriving hardcaml]
end

let create (i : Signal.t I.t) : Signal.t O.t =
  let reg_spec = Reg_spec.create ~clock:i.clock ~clear:i.reset () in
  let open Always in
  let out = Variable.reg ~width:24 reg_spec in
  let oe = Variable.reg ~width:24 reg_spec in
  let prev = Variable.reg ~width:24 reg_spec in
  let rise = Variable.reg ~width:24 reg_spec in
  let fall = Variable.reg ~width:24 reg_spec in
  let irq_en = Variable.reg ~width:24 reg_spec in
  let pend = Variable.reg ~width:24 reg_spec in
  let wd = Signal.select i.wdata 23 0 in
  let wr a = i.sel &: i.we &: (i.addr ==:. a) in
  let pin = i.pin_in in
  let rise_e = pin &: ~:(prev.value) in
  let fall_e = ~:(pin) &: prev.value in
  (* write-1-to-clear masks: clear bits are zeroed, others kept *)
  let clear a = Signal.mux2 (wr a) (~:wd) (Signal.ones 24) in
  compile
    [ when_ (wr 0) [ out <-- wd ]
    ; when_ (wr 3) [ out <-- (out.value |: wd) ]
    ; when_ (wr 4) [ out <-- (out.value &: ~:wd) ]
    ; when_ (wr 5) [ out <-- (out.value ^: wd) ]
    ; when_ (wr 1) [ oe <-- wd ]
    ; when_ (wr 8) [ irq_en <-- wd ]
    ; rise <-- ((rise.value &: clear 6) |: rise_e)
    ; fall <-- ((fall.value &: clear 7) |: fall_e)
    ; pend <-- ((pend.value &: clear 9) |: ((rise_e |: fall_e) &: irq_en.value))
    ; prev <-- pin
    ];
  let zero = Signal.zero 32 in
  let u s = Signal.uresize s 32 in
  let rdata =
    Signal.mux
      i.addr
      [ u out.value
      ; u oe.value
      ; u pin
      ; u out.value
      ; u out.value
      ; u out.value
      ; u rise.value
      ; u fall.value
      ; u irq_en.value
      ; u pend.value
      ; zero
      ; zero
      ; zero
      ; zero
      ; zero
      ; zero
      ]
  in
  { O.rdata; out = out.value; oe = oe.value; irq = pend.value <>:. 0 }
;;
