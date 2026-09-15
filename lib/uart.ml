(* Memory-mapped UART (8N1) used as the debug console and bootloader channel.

   Registers (word offsets):
     0  TX data (write starts a transmission)
     1  RX data (read clears the valid flag)
     2  status  bit 0 = TX busy, bit 1 = RX valid
     3  baud divisor (cycles per bit, read-only; set at elaboration)

   [clk_div] is the number of core clock cycles per bit. *)

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
    ; rx : 'a
    ; rx_ack : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { rdata : 'a [@bits 32]
    ; tx : 'a
    ; irq : 'a
    ; rx_data : 'a [@bits 8]
    ; rx_valid : 'a
    }
  [@@deriving hardcaml]
end

let create ~(clk_div : int) (i : Signal.t I.t) : Signal.t O.t =
  let reg_spec = Reg_spec.create ~clock:i.clock ~clear:i.reset () in
  let open Always in
  let tx_shift = Variable.reg ~width:10 reg_spec in
  let tx_bit = Variable.reg ~width:4 reg_spec in
  let tx_cnt = Variable.reg ~width:16 reg_spec in
  let tx_active = Variable.reg ~width:1 reg_spec in
  let rx_sync = Variable.reg ~width:2 reg_spec in
  let rx_shift = Variable.reg ~width:8 reg_spec in
  let rx_data = Variable.reg ~width:8 reg_spec in
  let rx_valid = Variable.reg ~width:1 reg_spec in
  let rx_bit = Variable.reg ~width:4 reg_spec in
  let rx_cnt = Variable.reg ~width:16 reg_spec in
  let rx_active = Variable.reg ~width:1 reg_spec in
  let tx_we = i.sel &: i.we &: (i.addr ==:. 0) in
  let rx_read = i.sel &: (i.addr ==:. 1) &: ~:(i.we) in
  let div = Signal.of_int ~width:16 (clk_div - 1) in
  let half = Signal.of_int ~width:16 ((clk_div / 2) - 1) in
  let tx_tick = tx_cnt.value ==: div in
  let rx_mid = rx_cnt.value ==: half in
  let rx_end = rx_cnt.value ==: div in
  let rx_in = Signal.select rx_sync.value 1 1 in
  let in_range lo hi s = (s >=:. lo) &: (s <=:. hi) in
  compile
    [ (* transmitter *)
      when_ tx_we
        [ tx_active <--. 1
        ; tx_shift
          <-- Signal.concat_msb
                [ Signal.of_int ~width:1 1
                ; Signal.select i.wdata 7 0
                ; Signal.of_int ~width:1 0
                ]
        ; tx_bit <--. 0
        ; tx_cnt <--. 0
        ]
    ; when_ (tx_active.value &: tx_tick)
        [ tx_cnt <--. 0
        ; if_ (tx_bit.value ==:. 9) [ tx_active <--. 0 ]
            [ tx_bit <-- tx_bit.value +:. 1
            ; tx_shift <-- Signal.srl tx_shift.value 1
            ]
        ]
    ; when_ (tx_active.value &: ~:tx_tick) [ tx_cnt <-- tx_cnt.value +:. 1 ]
    ; (* receiver input synchroniser *)
      rx_sync <-- Signal.concat_msb [ Signal.select rx_sync.value 0 0; i.rx ]
    ; when_ (rx_read |: i.rx_ack) [ rx_valid <--. 0 ]
    ; (* receiver *)
      when_ (~:(rx_active.value) &: ~:rx_in)
        [ rx_active <--. 1; rx_cnt <--. 0; rx_bit <--. 0 ]
    ; when_ rx_active.value
        [ when_ rx_mid
            [ when_ (rx_bit.value ==:. 0)
                [ (* start bit must still be low *) when_ rx_in [ rx_active <--. 0 ] ]
            ; when_ (in_range 1 8 rx_bit.value)
                [ rx_shift
                  <-- Signal.concat_msb [ rx_in; Signal.select rx_shift.value 7 1 ]
                ]
            ; when_ (rx_bit.value ==:. 9)
                [ when_ rx_in [ rx_data <-- rx_shift.value; rx_valid <--. 1 ]
                ; rx_active <--. 0
                ]
            ]
        ; when_ rx_end
            [ rx_cnt <--. 0
            ; if_ (rx_bit.value ==:. 9) [ rx_active <--. 0 ]
                [ rx_bit <-- rx_bit.value +:. 1 ]
            ]
        ; when_ (~:rx_end) [ rx_cnt <-- rx_cnt.value +:. 1 ]
        ]
    ];
  let status =
    Signal.concat_msb
      [ Signal.zero 30; rx_valid.value; tx_active.value ]
  in
  let rdata =
    Signal.mux
      i.addr
      [ Signal.zero 32 (* 0: TX data, write-only *)
      ; Signal.uresize rx_data.value 32 (* 1: RX data *)
      ; status (* 2: status *)
      ; Signal.uresize div 32 (* 3: baud divisor *)
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
  let tx =
    Signal.mux2 tx_active.value (Signal.select tx_shift.value 0 0) (Signal.vdd)
  in
  { O.rdata
  ; tx
  ; irq = rx_valid.value
  ; rx_data = rx_data.value
  ; rx_valid = rx_valid.value
  }
;;
