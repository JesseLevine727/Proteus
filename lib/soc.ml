(* Proteus Phase 2 SoC.

   Wires the CPU to:
   - a writable instruction RAM (combinational read), initialised from a
     program image and/or loaded by the hardware bootloader
   - a small byte-writable data RAM (combinational read)
   - a memory-mapped GPIO output register
   - a machine timer (mtime/mtimecmp)
   - a memory-mapped debug UART
   - a HALT register used by simulation to terminate a program

   Memory map (address bits [31:28]):
     0x1.......  data RAM
     0x2.......  GPIO
     0x3.......  machine timer
     0x6.......  debug UART
     0x7.......  HALT (write-only)

   The memories are register arrays for now; Phase 5 replaces them with SRAM
   macros and pipelines the fetch path. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; reset : 'a
    ; ui_in : 'a [@bits 8]
    ; uio_in : 'a [@bits 8]
    ; uart_rx : 'a
    ; dbg_addr : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { uo_out : 'a [@bits 8]
    ; uio_out : 'a [@bits 8]
    ; uio_oe : 'a [@bits 8]
    ; halted : 'a
    ; pc : 'a [@bits 32]
    ; trap : 'a
    ; uart_tx : 'a
    ; dbg_rdata : 'a [@bits 32] (* test-only data RAM read port *)
    }
  [@@deriving hardcaml]
end

let clog2 n =
  let rec go b = if 1 lsl b >= n then b else go (b + 1) in
  go 0
;;

let imem_words = 256
let data_ram_words = 512

let create ?(boot = false) ~(program : int array) (i : Signal.t I.t) : Signal.t O.t =
  let reg_spec = Reg_spec.create ~clock:i.clock ~clear:i.reset () in
  let imem_reg_spec = Reg_spec.create ~clock:i.clock () in
  let imem_rdata_w = Signal.wire 32 in
  let dmem_rdata_w = Signal.wire 32 in
  let pins_in_wire = Signal.wire 24 in
  let halt_wire = Signal.wire 1 in
  let irq_timer_wire = Signal.wire 1 in
  let irq_ext_wire = Signal.wire 1 in
  let boot_wr_en_w = Signal.wire 1 in
  let boot_wr_addr_w = Signal.wire 16 in
  let boot_wr_data_w = Signal.wire 32 in
  let boot_done_w = Signal.wire 1 in
  let boot_ack_w = Signal.wire 1 in
  let uart_rx_ack_w = Signal.wire 1 in
  let cpu_reset = i.reset |: ~:boot_done_w in
  let cpu_i : Signal.t Cpu.I.t =
    { clock = i.clock
    ; reset = cpu_reset
    ; imem_rdata = imem_rdata_w
    ; dmem_rdata = dmem_rdata_w
    ; pins_in = pins_in_wire
    ; irq_sw = Signal.gnd
    ; irq_timer = irq_timer_wire
    ; irq_ext = irq_ext_wire
    ; halt_req = halt_wire
    }
  in
  let cpu = Cpu.create cpu_i in
  let pc = cpu.Cpu.O.pc in
  let dmem_addr = cpu.Cpu.O.dmem_addr in
  (* writable instruction memory, initialised from [program] while reset *)
  let iabits = clog2 imem_words in
  let imem =
    Array.init imem_words (fun idx ->
      let addr_s = Signal.of_int ~width:16 idx in
      let init =
        if idx < Array.length program
        then Signal.of_int ~width:32 program.(idx)
        else Signal.zero 32
      in
      Signal.reg_fb imem_reg_spec ~width:32 ~f:(fun cur ->
        Signal.mux2
          (boot_wr_en_w &: (boot_wr_addr_w ==: addr_s))
          boot_wr_data_w
          (Signal.mux2 i.reset init cur)))
  in
  let iaddr = Signal.select pc (2 + iabits - 1) 2 in
  let imem_rdata = Signal.mux iaddr (Array.to_list imem) in
  (* low addresses on the data bus also read instruction memory, so firmware
     can copy initialised data (LMA in IMEM) into data RAM *)
  let imem_data_sel = Signal.select dmem_addr 31 28 ==:. 0x0 in
  let imem_data_rdata =
    Signal.mux (Signal.select dmem_addr (2 + iabits - 1) 2) (Array.to_list imem)
  in
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
  (* pin subsystem *)
  let out_w = Signal.wire 24 in
  let oe_w = Signal.wire 24 in
  let uio_out = Signal.select out_w 23 16 in
  let uio_oe = Signal.select oe_w 23 16 in
  (* a uio pin reads its driven value when the output is enabled, else the
     external level *)
  let uio_actual = (uio_out &: uio_oe) |: (i.uio_in &: ~:uio_oe) in
  let pin_in =
    Signal.concat_msb [ uio_actual; i.ui_in; Signal.select out_w 7 0 ]
  in
  Signal.assign pins_in_wire pin_in;
  let pins_sel = Signal.select dmem_addr 31 28 ==:. 0x2 in
  let pins =
    Pins.create
      { clock = i.clock
      ; reset = i.reset
      ; sel = pins_sel
      ; we = cpu.Cpu.O.dmem_we
      ; addr = Signal.select dmem_addr 5 2
      ; wdata = cpu.Cpu.O.dmem_wdata
      ; pin_in
      }
  in
  Signal.assign out_w pins.Pins.O.out;
  Signal.assign oe_w pins.Pins.O.oe;
  Signal.assign irq_ext_wire pins.Pins.O.irq;
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
  (* debug UART *)
  let uart_sel = Signal.select dmem_addr 31 28 ==:. 0x6 in
  let uart_addr = Signal.select dmem_addr 5 2 in
  let uart =
    Uart.create
      ~clk_div:16
      { clock = i.clock
      ; reset = i.reset
      ; sel = uart_sel
      ; we = cpu.Cpu.O.dmem_we
      ; addr = uart_addr
      ; wdata = cpu.Cpu.O.dmem_wdata
      ; rx = i.uart_rx
      ; rx_ack = uart_rx_ack_w
      }
  in
  (* bootloader *)
  let bootloader =
    Bootloader.create
      { clock = i.clock
      ; reset = i.reset
      ; enable = Signal.of_int ~width:1 (if boot then 1 else 0)
      ; rx_valid = uart.Uart.O.rx_valid
      ; rx_data = uart.Uart.O.rx_data
      }
  in
  Signal.assign boot_wr_en_w bootloader.Bootloader.O.wr_en;
  Signal.assign boot_wr_addr_w bootloader.Bootloader.O.wr_addr;
  Signal.assign boot_wr_data_w bootloader.Bootloader.O.wr_data;
  Signal.assign boot_done_w bootloader.Bootloader.O.done_;
  Signal.assign boot_ack_w bootloader.Bootloader.O.ack;
  let cpu_uart_read = uart_sel &: (uart_addr ==:. 1) &: ~:(cpu.Cpu.O.dmem_we) in
  Signal.assign uart_rx_ack_w (cpu_uart_read |: boot_ack_w);
  let dmem_rdata =
    Signal.mux2
      imem_data_sel
      imem_data_rdata
      (Signal.mux2
         uart_sel
         uart.Uart.O.rdata
         (Signal.mux2
            timer_sel
            timer.Timer.O.rdata
            (Signal.mux2 pins_sel pins.Pins.O.rdata ram_rdata)))
  in
  (* HALT register: a store anywhere in the 0x7 region halts the core *)
  let halt_sel = Signal.select dmem_addr 31 28 ==:. 0x7 in
  Signal.assign halt_wire (cpu.Cpu.O.dmem_we &: halt_sel);
  Signal.assign imem_rdata_w imem_rdata;
  Signal.assign dmem_rdata_w dmem_rdata;
  { O.uo_out = Signal.select pins.Pins.O.out 7 0
  ; uio_out = Signal.select pins.Pins.O.out 23 16
  ; uio_oe = Signal.select pins.Pins.O.oe 23 16
  ; halted = cpu.Cpu.O.halted
  ; pc
  ; trap = cpu.Cpu.O.trap
  ; uart_tx = uart.Uart.O.tx
  ; dbg_rdata = ram_read i.dbg_addr
  }
;;
