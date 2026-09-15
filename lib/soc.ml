(* Proteus Phase 2 SoC.

   Wires the CPU to:
   - a combinational instruction ROM (loaded from a program image)
   - a small byte-writable data RAM (combinational read)
   - a memory-mapped GPIO output register
   - a HALT register used by simulation to terminate a program

   Memory map (address bits [31:28]):
     0x1.......  data RAM
     0x2.......  GPIO
     0x3.......  machine timer (mtime/mtimecmp)
     0x7.......  HALT (write-only)

   The instruction ROM and data RAM are deliberately simple; Phase 5 replaces
   them with SRAM macros and pipelines the fetch path. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; reset : 'a
    ; ui_in : 'a [@bits 8]
    ; dbg_addr : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { uo_out : 'a [@bits 8]
    ; halted : 'a
    ; pc : 'a [@bits 32]
    ; trap : 'a
    ; dbg_rdata : 'a [@bits 32] (* test-only data RAM read port *)
    }
  [@@deriving hardcaml]
end

let clog2 n =
  let rec go b = if 1 lsl b >= n then b else go (b + 1) in
  go 0
;;

let data_ram_words = 64

let create ~(program : int array) (i : Signal.t I.t) : Signal.t O.t =
  let reg_spec = Reg_spec.create ~clock:i.clock ~clear:i.reset () in
  let imem_rdata_w = Signal.wire 32 in
  let dmem_rdata_w = Signal.wire 32 in
  let halt_wire = Signal.wire 1 in
  let irq_timer_wire = Signal.wire 1 in
  let cpu_i : Signal.t Cpu.I.t =
    { clock = i.clock
    ; reset = i.reset
    ; imem_rdata = imem_rdata_w
    ; dmem_rdata = dmem_rdata_w
    ; irq_sw = Signal.gnd
    ; irq_timer = irq_timer_wire
    ; irq_ext = Signal.gnd
    ; halt_req = halt_wire
    }
  in
  let cpu = Cpu.create cpu_i in
  let pc = cpu.Cpu.O.pc in
  let dmem_addr = cpu.Cpu.O.dmem_addr in
  (* instruction ROM (combinational) *)
  let n = Array.length program in
  let abits = max 1 (clog2 n) in
  let size = 1 lsl abits in
  let words =
    Array.init size (fun k ->
      if k < n then Signal.of_int ~width:32 program.(k) else Signal.zero 32)
  in
  let iaddr = Signal.select pc (2 + abits - 1) 2 in
  let imem_rdata = Signal.mux iaddr (Array.to_list words) in
  (* data RAM *)
  let rabits = clog2 data_ram_words in
  let ram_sel = Signal.select dmem_addr 31 28 ==:. 0x1 in
  let ram_addr = Signal.select dmem_addr (2 + rabits - 1) 2 in
  let ram_we = cpu.Cpu.O.dmem_we &: ram_sel in
  let merge_bytes cur wdata wstrb =
    let byte k =
      let c = Signal.select cur ((8 * k) + 7) (8 * k) in
      let d = Signal.select wdata ((8 * k) + 7) (8 * k) in
      Signal.mux2 (Signal.select wstrb k k) d c
    in
    Signal.concat_msb [ byte 3; byte 2; byte 1; byte 0 ]
  in
  let ram_words =
    Array.init data_ram_words (fun idx ->
      let addr_s = Signal.of_int ~width:rabits idx in
      let enable = ram_we &: (ram_addr ==: addr_s) in
      Signal.reg_fb reg_spec ~enable ~width:32 ~f:(fun cur ->
        merge_bytes cur cpu.Cpu.O.dmem_wdata cpu.Cpu.O.dmem_wstrb))
  in
  let ram_read addr =
    Signal.mux (Signal.select addr (2 + rabits - 1) 2) (Array.to_list ram_words)
  in
  let ram_rdata = ram_read dmem_addr in
  (* GPIO output register *)
  let gpio_sel = Signal.select dmem_addr 31 28 ==:. 0x2 in
  let gpio_we = cpu.Cpu.O.dmem_we &: gpio_sel in
  let gpio_out =
    Signal.reg_fb reg_spec ~width:8 ~enable:gpio_we ~f:(fun _ ->
      Signal.select cpu.Cpu.O.dmem_wdata 7 0)
  in
  (* machine timer *)
  let timer_sel = Signal.select dmem_addr 31 28 ==:. 0x3 in
  let timer =
    Timer.create
      { clock = i.clock
      ; reset = i.reset
      ; sel = timer_sel
      ; we = cpu.Cpu.O.dmem_we
      ; addr = Signal.select dmem_addr 5 2
      ; wdata = cpu.Cpu.O.dmem_wdata
      }
  in
  Signal.assign irq_timer_wire timer.Timer.O.irq;
  let dmem_rdata =
    Signal.mux2
      timer_sel
      timer.Timer.O.rdata
      (Signal.mux2 gpio_sel (Signal.uresize gpio_out 32) ram_rdata)
  in
  (* HALT register: a store anywhere in the 0x7 region halts the core *)
  let halt_sel = Signal.select dmem_addr 31 28 ==:. 0x7 in
  Signal.assign halt_wire (cpu.Cpu.O.dmem_we &: halt_sel);
  Signal.assign imem_rdata_w imem_rdata;
  Signal.assign dmem_rdata_w dmem_rdata;
  { O.uo_out = gpio_out
  ; halted = cpu.Cpu.O.halted
  ; pc
  ; trap = cpu.Cpu.O.trap
  ; dbg_rdata = ram_read i.dbg_addr
  }
;;
