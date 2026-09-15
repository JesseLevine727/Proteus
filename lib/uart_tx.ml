(* A minimal, self-contained UART transmitter.

   This is the "hello world" of the protocol emulator: the first design we
   generate with Hardcaml and push through simulation. It is deliberately
   simple and parameterised by a runtime baud divisor so the same RTL can be
   driven at any bit rate.

   Frame format: 1 start bit (low), 8 data bits LSB-first, 1 stop bit (high). *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; reset : 'a
    ; start : 'a (* one-cycle pulse to begin a transmission *)
    ; data : 'a [@bits 8]
    ; baud_div : 'a [@bits 16] (* cycles per bit *)
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { tx : 'a
    ; busy : 'a
    ; done_ : 'a [@bits 1] (* one-cycle pulse when a frame completes *)
    }
  [@@deriving hardcaml]
end

module State = struct
  type t =
    | Idle
    | Start
    | Data
    | Stop
  [@@deriving compare, enumerate, sexp_of]
end

let create (i : Signal.t I.t) : Signal.t O.t =
  let reg_spec = Reg_spec.create ~clock:i.clock ~clear:i.reset () in
  let sm = Always.State_machine.create (module State) reg_spec in
  let open Always in
  let counter = Variable.reg ~width:16 reg_spec in
  let bit_index = Variable.reg ~width:3 reg_spec in
  let shift = Variable.reg ~width:8 reg_spec in
  let tx = Variable.reg ~width:1 reg_spec in
  let busy = Variable.reg ~width:1 reg_spec in
  let done_ = Variable.reg ~width:1 reg_spec in
  let last = i.baud_div -:. 1 in
  let tick = counter.value ==: last in
  compile
    [ tx <--. 1
    ; busy <--. 0
    ; done_ <--. 0
    ; sm.switch
        [ ( State.Idle
          , [ if_ i.start
                [ shift <-- i.data
                ; bit_index <--. 0
                ; counter <--. 0
                ; busy <--. 1
                ; sm.set_next State.Start
                ]
                []
            ] )
        ; ( State.Start
          , [ tx <--. 0
            ; if_ tick
                [ counter <--. 0; sm.set_next State.Data ]
                [ counter <-- counter.value +:. 1 ]
            ] )
        ; ( State.Data
          , [ tx <-- shift.value.:(0)
            ; if_ tick
                [ counter <--. 0
                ; shift <-- srl shift.value 1
                ; if_ (bit_index.value ==:. 7)
                    [ sm.set_next State.Stop ]
                    [ bit_index <-- bit_index.value +:. 1 ]
                ]
                [ counter <-- counter.value +:. 1 ]
            ] )
        ; ( State.Stop
          , [ tx <--. 1
            ; if_ tick
                [ counter <--. 0
                ; done_ <--. 1
                ; busy <--. 0
                ; sm.set_next State.Idle
                ]
                [ counter <-- counter.value +:. 1 ]
            ] )
        ]
    ];
  { O.tx = tx.value; busy = busy.value; done_ = done_.value }
;;
