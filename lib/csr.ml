(* RISC-V machine-mode control and status registers (Phase 2 subset).

   Implemented: mstatus, misa, mie, mtvec, mscratch, mepc, mcause, mtval,
   mip, mcycle(h), minstret(h), and the read-only id registers. Traps update
   mepc/mcause/mtval/mstatus; MRET restores mstatus and returns to mepc.

   Interrupts: machine software, timer and external. The core takes the
   highest-priority pending, enabled interrupt (MEI > MSI > MTI). *)

open Hardcaml
open Signal

let addr_mstatus = 0x300
let addr_misa = 0x301
let addr_mie = 0x304
let addr_mtvec = 0x305
let addr_mscratch = 0x340
let addr_mepc = 0x341
let addr_mcause = 0x342
let addr_mtval = 0x343
let addr_mip = 0x344
let addr_mcycle = 0xB00
let addr_minstret = 0xB02
let addr_mcycleh = 0xB80
let addr_minstreth = 0xB82
let addr_mvendorid = 0xF11
let addr_marchid = 0xF12
let addr_mimpid = 0xF13
let addr_mhartid = 0xF14

module I = struct
  type 'a t =
    { clock : 'a
    ; reset : 'a
    ; addr : 'a [@bits 12]
    ; op : 'a [@bits 2] (* 0 = read/write, 1 = read/set, 2 = read/clear *)
    ; src : 'a [@bits 32]
    ; wr : 'a
    ; retire : 'a
    ; trap : 'a
    ; trap_cause : 'a [@bits 32]
    ; trap_pc : 'a [@bits 32]
    ; trap_val : 'a [@bits 32]
    ; mret : 'a
    ; irq_sw : 'a
    ; irq_timer : 'a
    ; irq_ext : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { rdata : 'a [@bits 32]
    ; mepc : 'a [@bits 32]
    ; mtvec : 'a [@bits 32]
    ; interrupt : 'a
    ; interrupt_cause : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

let create (i : Signal.t I.t) : Signal.t O.t =
  let reg_spec = Reg_spec.create ~clock:i.clock ~clear:i.reset () in
  let c v = Signal.of_int ~width:32 v in
  let bit s n = Signal.select s n n in
  (* the value a CSR instruction would write, given the current value *)
  let csr_op cur =
    Signal.mux i.op [ i.src; cur |: i.src; cur &: ~:(i.src); Signal.zero 32 ]
  in
  let wr_reg cur addr =
    Signal.mux2 ((i.addr ==:. addr) &: i.wr) (csr_op cur) cur
  in
  (* mstatus: MIE[3], MPIE[7], MPP[12:11] *)
  let mstatus =
    Signal.reg_fb reg_spec ~width:32 ~f:(fun cur ->
      let mie = bit cur 3 in
      let mpie = bit cur 7 in
      let trap_v =
        (cur &: c 0xFFFFE777)
        |: Signal.uresize (Signal.sll mie 7) 32
        |: c 0x1800
      in
      let mret_v =
        (cur &: c 0xFFFFE777)
        |: Signal.uresize (Signal.sll mpie 3) 32
        |: c 0x80
      in
      Signal.mux2 i.trap trap_v (Signal.mux2 i.mret mret_v (wr_reg cur addr_mstatus)))
  in
  let mie = Signal.reg_fb reg_spec ~width:32 ~f:(fun cur -> wr_reg cur addr_mie) in
  let mtvec = Signal.reg_fb reg_spec ~width:32 ~f:(fun cur -> wr_reg cur addr_mtvec) in
  let mscratch =
    Signal.reg_fb reg_spec ~width:32 ~f:(fun cur -> wr_reg cur addr_mscratch)
  in
  let mepc =
    Signal.reg_fb reg_spec ~width:32 ~f:(fun cur ->
      Signal.mux2 i.trap i.trap_pc (wr_reg cur addr_mepc))
  in
  let mcause =
    Signal.reg_fb reg_spec ~width:32 ~f:(fun cur ->
      Signal.mux2 i.trap i.trap_cause (wr_reg cur addr_mcause))
  in
  let mtval =
    Signal.reg_fb reg_spec ~width:32 ~f:(fun cur ->
      Signal.mux2 i.trap i.trap_val (wr_reg cur addr_mtval))
  in
  (* mip reflects the hardware interrupt inputs *)
  let mip =
    Signal.uresize (Signal.sll i.irq_sw 3) 32
    |: Signal.uresize (Signal.sll i.irq_timer 7) 32
    |: Signal.uresize (Signal.sll i.irq_ext 11) 32
  in
  (* counters *)
  let mcycle = Signal.reg_fb reg_spec ~width:64 ~f:(fun cy -> cy +:. 1) in
  let minstret =
    Signal.reg_fb reg_spec ~width:64 ~f:(fun n ->
      Signal.mux2 i.retire (n +:. 1) n)
  in
  let misa = c 0x40000100 in
  (* read port *)
  let zero = Signal.zero 32 in
  let entries =
    [ addr_mstatus, mstatus
    ; addr_misa, misa
    ; addr_mie, mie
    ; addr_mtvec, mtvec
    ; addr_mscratch, mscratch
    ; addr_mepc, mepc
    ; addr_mcause, mcause
    ; addr_mtval, mtval
    ; addr_mip, mip
    ; addr_mcycle, Signal.select mcycle 31 0
    ; addr_minstret, Signal.select minstret 31 0
    ; addr_mcycleh, Signal.select mcycle 63 32
    ; addr_minstreth, Signal.select minstret 63 32
    ; 0xC00, Signal.select mcycle 31 0
    ; 0xC02, Signal.select minstret 31 0
    ; 0xC80, Signal.select mcycle 63 32
    ; 0xC82, Signal.select minstret 63 32
    ; addr_mvendorid, zero
    ; addr_marchid, zero
    ; addr_mimpid, zero
    ; addr_mhartid, zero
    ]
  in
  let rdata =
    List.fold_left
      (fun acc (a, v) -> acc |: Signal.mux2 (i.addr ==:. a) v zero)
      zero
      entries
  in
  (* interrupt arbitration: MEI > MSI > MTI *)
  let global = bit mstatus 3 in
  let ie n = bit mie n in
  let ip n = bit mip n in
  let ext_p = global &: ie 11 &: ip 11 in
  let sw_p = global &: ie 3 &: ip 3 in
  let timer_p = global &: ie 7 &: ip 7 in
  let interrupt = ext_p |: sw_p |: timer_p in
  let interrupt_cause =
    Signal.mux2
      ext_p
      (c 0x8000000B)
      (Signal.mux2 sw_p (c 0x80000003) (c 0x80000007))
  in
  { O.rdata; mepc; mtvec; interrupt; interrupt_cause }
;;
