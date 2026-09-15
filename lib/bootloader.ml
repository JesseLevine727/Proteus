(* Hardwired serial bootloader.

   While [enable] is high the CPU is held in reset and this FSM consumes a
   program image from the UART receiver, writing it into the instruction RAM.
   When the image is complete it raises [done_] and the CPU is released.

   Wire format (big-endian):
     4 bytes  word count N
     N words, 4 bytes each (big-endian)

   This is intentionally tiny and dependency-free; a checksum and richer
   framing can be added later. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; reset : 'a
    ; enable : 'a
    ; rx_valid : 'a
    ; rx_data : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { wr_en : 'a
    ; wr_addr : 'a [@bits 16]
    ; wr_data : 'a [@bits 32]
    ; ack : 'a
    ; done_ : 'a
    }
  [@@deriving hardcaml]
end

let create (i : Signal.t I.t) : Signal.t O.t =
  let reg_spec = Reg_spec.create ~clock:i.clock ~clear:i.reset () in
  let open Always in
  let state = Variable.reg ~width:2 reg_spec in
  let byte_idx = Variable.reg ~width:2 reg_spec in
  let count = Variable.reg ~width:32 reg_spec in
  let word_idx = Variable.reg ~width:16 reg_spec in
  let buf = Variable.reg ~width:32 reg_spec in
  let in_len = state.value ==:. 0 in
  let in_data = state.value ==:. 1 in
  let done_ = (~:(i.enable)) |: (state.value ==:. 2) in
  let shifted =
    Signal.concat_msb [ Signal.select buf.value 23 0; i.rx_data ]
  in
  let last = byte_idx.value ==:. 3 in
  let wr_en = i.enable &: in_data &: i.rx_valid &: last in
  compile
    [ when_ (i.enable &: i.rx_valid &: in_len)
        [ count <-- shifted
        ; if_ last
            [ state <--. 1; byte_idx <--. 0; word_idx <--. 0; buf <--. 0 ]
            [ byte_idx <-- byte_idx.value +:. 1 ]
        ]
    ; when_ (i.enable &: i.rx_valid &: in_data)
        [ buf <-- shifted
        ; if_ last
            [ byte_idx <--. 0
            ; buf <--. 0
            ; if_ (word_idx.value +:. 1 ==: Signal.select count.value 15 0)
                [ state <--. 2 ]
                [ word_idx <-- word_idx.value +:. 1 ]
            ]
            [ byte_idx <-- byte_idx.value +:. 1 ]
        ]
    ];
  { O.wr_en
  ; wr_addr = word_idx.value
  ; wr_data = shifted
  ; ack = i.enable &: i.rx_valid &: ~:done_
  ; done_
  }
;;
