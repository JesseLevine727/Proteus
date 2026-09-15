(* RV32I arithmetic/logic unit.

   The operation is selected by a 4-bit control signal produced by the CPU
   decoder. The op codes below are the contract between decoder and ALU. *)

open Hardcaml
open Signal

module Op = struct
  let add = 0
  let sub = 1
  let sll = 2
  let slt = 3
  let sltu = 4
  let xor = 5
  let srl = 6
  let sra = 7
  let or_ = 8
  let and_ = 9
  let pass_b = 10
end

let width = 32

let create ~op ~a ~b =
  let shamt = Signal.select b 4 0 in
  let add = a +: b in
  let sub = a -: b in
  let sll = Signal.log_shift Signal.sll a shamt in
  let slt = Signal.uresize (a <+ b) width in
  let sltu = Signal.uresize (a <: b) width in
  let xor = a ^: b in
  let srl = Signal.log_shift Signal.srl a shamt in
  let sra = Signal.log_shift Signal.sra a shamt in
  let or_ = a |: b in
  let and_ = a &: b in
  let z = Signal.zero width in
  Signal.mux
    op
    [ add
    ; sub
    ; sll
    ; slt
    ; sltu
    ; xor
    ; srl
    ; sra
    ; or_
    ; and_
    ; b
    ; z
    ; z
    ; z
    ; z
    ; z
    ]
;;
