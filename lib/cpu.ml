(* Proteus RV32I core (Phase 2).

   Microarchitecture: single cycle, combinational instruction fetch (the
   instruction memory lives in [Soc]) and a synchronous register file. Every
   instruction retires in one cycle, which makes firmware timing deterministic
   and easy to verify.

   Implemented: the full RV32I base integer instruction set, the Zicsr CSR
   instructions, machine-mode traps (illegal instruction, ECALL, EBREAK) and
   MRET, and machine software/timer/external interrupts.

   Termination: rather than overloading EBREAK (which now traps), the SoC
   asserts [halt_req] on a store to the HALT register; the core then freezes. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; reset : 'a
    ; imem_rdata : 'a [@bits 32]
    ; dmem_rdata : 'a [@bits 32]
    ; pins_in : 'a [@bits 24]
    ; irq_sw : 'a
    ; irq_timer : 'a
    ; irq_ext : 'a
    ; halt_req : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { imem_addr : 'a [@bits 32]
    ; dmem_addr : 'a [@bits 32]
    ; dmem_wdata : 'a [@bits 32]
    ; dmem_wstrb : 'a [@bits 4]
    ; dmem_we : 'a
    ; dmem_re : 'a
    ; pc : 'a [@bits 32]
    ; halted : 'a
    ; trap : 'a
    }
  [@@deriving hardcaml]
end

let create (i : Signal.t I.t) : Signal.t O.t =
  let reg_spec = Reg_spec.create ~clock:i.clock ~clear:i.reset () in
  let c v = Signal.of_int ~width:32 v in
  let c2 v = Signal.of_int ~width:2 v in
  let instr = i.imem_rdata in
  let opcode = Signal.select instr 6 0 in
  let rd = Signal.select instr 11 7 in
  let funct3 = Signal.select instr 14 12 in
  let rs1 = Signal.select instr 19 15 in
  let rs2 = Signal.select instr 24 20 in
  let funct7 = Signal.select instr 31 25 in
  (* immediates *)
  let imm_i = Signal.sresize (Signal.select instr 31 20) 32 in
  let imm_s =
    Signal.sresize
      (Signal.concat_msb [ Signal.select instr 31 25; Signal.select instr 11 7 ])
      32
  in
  let imm_b =
    Signal.sresize
      (Signal.concat_msb
         [ Signal.select instr 31 31
         ; Signal.select instr 7 7
         ; Signal.select instr 30 25
         ; Signal.select instr 11 8
         ; Signal.zero 1
         ])
      32
  in
  let imm_u = Signal.concat_msb [ Signal.select instr 31 12; Signal.zero 12 ] in
  let imm_j =
    Signal.sresize
      (Signal.concat_msb
         [ Signal.select instr 31 31
         ; Signal.select instr 19 12
         ; Signal.select instr 20 20
         ; Signal.select instr 30 21
         ; Signal.zero 1
         ])
      32
  in
  (* instruction class *)
  let is_lui = opcode ==:. Isa.op_lui in
  let is_auipc = opcode ==:. Isa.op_auipc in
  let is_jal = opcode ==:. Isa.op_jal in
  let is_jalr = opcode ==:. Isa.op_jalr in
  let is_branch = opcode ==:. Isa.op_branch in
  let is_load = opcode ==:. Isa.op_load in
  let is_store = opcode ==:. Isa.op_store in
  let is_imm = opcode ==:. Isa.op_imm in
  let is_reg = opcode ==:. Isa.op_reg in
  let is_system = opcode ==:. Isa.op_system in
  (* privileged and CSR instructions *)
  let is_ecall = instr ==:. 0x00000073 in
  let is_ebreak = instr ==:. 0x00100073 in
  let is_mret = instr ==:. 0x30200073 in
  let is_wfi = instr ==:. 0x10500073 in
  let is_csr = is_system &: (funct3 <>:. 0) in
  let csr_rw = (funct3 ==:. 1) |: (funct3 ==:. 5) in
  let csr_rs = (funct3 ==:. 2) |: (funct3 ==:. 6) in
  let csr_rc = (funct3 ==:. 3) |: (funct3 ==:. 7) in
  let csr_imm = (funct3 ==:. 5) |: (funct3 ==:. 6) |: (funct3 ==:. 7) in
  (* custom timing instructions (opcode custom-0) *)
  let is_custom = opcode ==:. 0x0B in
  let is_delay = is_custom &: (funct3 ==:. 0) in
  let is_pin_wait = is_custom &: (funct3 ==:. 1) in
  let is_pin_edge = is_custom &: (funct3 ==:. 2) in
  let is_wait = is_delay |: is_pin_wait |: is_pin_edge in
  (* legality *)
  let f3_in ns = List.fold_left (fun acc n -> acc |: (funct3 ==:. n)) Signal.gnd ns in
  let reg_ok =
    ((funct3 ==:. 0) |: (funct3 ==:. 5))
    &: ((funct7 ==:. 0) |: (funct7 ==:. 0x20))
    |: ((funct3 <>:. 0) &: (funct3 <>:. 5))
  in
  let legal =
    is_lui |: is_auipc |: is_jal |: is_jalr
    |: (is_branch &: f3_in [ 0; 1; 4; 5; 6; 7 ])
    |: (is_load &: f3_in [ 0; 1; 2; 4; 5 ])
    |: (is_store &: f3_in [ 0; 1; 2 ])
    |: is_imm
    |: (is_reg &: reg_ok)
    |: ((funct3 ==:. 0) &: is_system &: (is_ecall |: is_ebreak |: is_mret |: is_wfi))
    |: (is_system &: f3_in [ 1; 2; 3; 5; 6; 7 ])
    |: is_wait
  in
  let illegal = ~:legal in
  (* exceptions *)
  let exception_ = illegal |: is_ecall |: is_ebreak in
  let exc_cause = Signal.mux2 illegal (c 2) (Signal.mux2 is_ecall (c 11) (c 3)) in
  let exc_val = Signal.mux2 illegal instr (c 0) in
  (* halt latch *)
  let halted =
    Signal.reg_fb reg_spec ~width:1 ~f:(fun h -> h |: i.halt_req)
  in
  (* register file via forward references *)
  let wdata_wire = Signal.wire 32 in
  let we_wire = Signal.wire 1 in
  let rf_i : Signal.t Regfile.I.t =
    { clock = i.clock
    ; reset = i.reset
    ; rs1
    ; rs2
    ; rd
    ; wdata = wdata_wire
    ; we = we_wire
    }
  in
  let rf_o = Regfile.create rf_i in
  let rs1_data = rf_o.Regfile.O.rs1_data in
  let rs2_data = rf_o.Regfile.O.rs2_data in
  (* ALU control *)
  let op4 n = Signal.of_int ~width:4 n in
  let f7_20 = funct7 ==:. 0x20 in
  let add_sub = Signal.mux2 f7_20 (op4 Alu.Op.sub) (op4 Alu.Op.add) in
  let srl_sra = Signal.mux2 f7_20 (op4 Alu.Op.sra) (op4 Alu.Op.srl) in
  let r_alu =
    Signal.mux
      funct3
      [ add_sub
      ; op4 Alu.Op.sll
      ; op4 Alu.Op.slt
      ; op4 Alu.Op.sltu
      ; op4 Alu.Op.xor
      ; srl_sra
      ; op4 Alu.Op.or_
      ; op4 Alu.Op.and_
      ]
  in
  let i_alu =
    Signal.mux
      funct3
      [ op4 Alu.Op.add
      ; op4 Alu.Op.sll
      ; op4 Alu.Op.slt
      ; op4 Alu.Op.sltu
      ; op4 Alu.Op.xor
      ; srl_sra
      ; op4 Alu.Op.or_
      ; op4 Alu.Op.and_
      ]
  in
  let alu_op = Signal.mux2 is_reg r_alu (Signal.mux2 is_imm i_alu (op4 Alu.Op.add)) in
  let alu_src_imm =
    is_imm |: is_load |: is_store |: is_jalr |: is_lui |: is_auipc
  in
  let imm =
    Signal.mux2
      is_store
      imm_s
      (Signal.mux2
         is_branch
         imm_b
         (Signal.mux2
            is_jal
            imm_j
            (Signal.mux2 is_lui imm_u (Signal.mux2 is_auipc imm_u imm_i))))
  in
  let branch_taken =
    Signal.mux
      funct3
      [ rs1_data ==: rs2_data
      ; rs1_data <>: rs2_data
      ; Signal.gnd
      ; Signal.gnd
      ; rs1_data <+ rs2_data
      ; rs1_data >=+ rs2_data
      ; rs1_data <: rs2_data
      ; rs1_data >=: rs2_data
      ]
  in
  (* custom timing instructions: DELAY / PIN_WAIT / PIN_EDGE.
     These stall the core until a condition is met or a timeout expires. *)
  let pin_mask = Signal.select rs1_data 23 0 in
  let pins = i.pins_in in
  let prev_pins = Signal.reg_fb reg_spec ~width:24 ~f:(fun _ -> pins) in
  let level_cond = (pins &: pin_mask) <>:. 0 in
  let edge_cond = ((pins &: pin_mask) &: ~:(prev_pins &: pin_mask)) <>:. 0 in
  let cond =
    Signal.mux2 is_delay Signal.gnd (Signal.mux2 is_pin_wait level_cond edge_cond)
  in
  let timeout_val = Signal.mux2 is_delay rs1_data rs2_data in
  let busy_wire = Signal.wire 1 in
  let count_wire = Signal.wire 32 in
  let first = is_wait &: ~:busy_wire in
  let count_zero = count_wire ==:. 0 in
  let active = is_wait |: busy_wire in
  let retire_wait = active &: (cond |: (busy_wire &: count_zero)) in
  let stall = active &: ~:retire_wait in
  let count_next =
    Signal.mux2
      (first &: ~:cond)
      timeout_val
      (Signal.mux2
         (busy_wire &: ~:cond &: ~:count_zero)
         (count_wire -:. 1)
         count_wire)
  in
  let busy = Signal.reg_fb reg_spec ~width:1 ~f:(fun _ -> stall) in
  let count = Signal.reg_fb reg_spec ~width:32 ~f:(fun _ -> count_next) in
  Signal.assign busy_wire busy;
  Signal.assign count_wire count;
  let wait_rd =
    Signal.mux2 is_delay (Signal.zero 32) (Signal.mux2 cond (Signal.zero 32) (c 1))
  in
  (* program counter and control-flow target *)
  let pc_wire = Signal.wire 32 in
  let mepc_wire = Signal.wire 32 in
  let mtvec_wire = Signal.wire 32 in
  let next_pc_normal =
    let branch_target = pc_wire +: imm_b in
    let jal_target = pc_wire +: imm_j in
    let jalr_target = (rs1_data +: imm_i) &: c (lnot 1) in
    Signal.mux2
      is_jal
      jal_target
      (Signal.mux2
         is_jalr
         jalr_target
         (Signal.mux2 (is_branch &: branch_taken) branch_target (pc_wire +:. 4)))
  in
  (* CSR file, with forward references for the trap inputs *)
  let trap_wire = Signal.wire 1 in
  let trap_cause_wire = Signal.wire 32 in
  let trap_pc_wire = Signal.wire 32 in
  let trap_val_wire = Signal.wire 32 in
  let csr_i : Signal.t Csr.I.t =
    { clock = i.clock
    ; reset = i.reset
    ; addr = Signal.select instr 31 20
    ; op = Signal.mux2 csr_rw (c2 0) (Signal.mux2 csr_rs (c2 1) (c2 2))
    ; src = Signal.mux2 csr_imm (Signal.uresize rs1 32) rs1_data
    ; wr = is_csr &: (csr_rw |: ((csr_rs |: csr_rc) &: (rs1 <>:. 0)))
    ; retire = ~:illegal &: ~:halted &: ~:stall
    ; trap = trap_wire
    ; trap_cause = trap_cause_wire
    ; trap_pc = trap_pc_wire
    ; trap_val = trap_val_wire
    ; mret = is_mret
    ; irq_sw = i.irq_sw
    ; irq_timer = i.irq_timer
    ; irq_ext = i.irq_ext
    }
  in
  let csr = Csr.create csr_i in
  let interrupt_taken = csr.Csr.O.interrupt &: ~:exception_ &: ~:stall in
  let trap_taken = exception_ |: interrupt_taken in
  let pc =
    Signal.reg_fb reg_spec ~width:32 ~f:(fun _ ->
      Signal.mux2
        (halted |: stall)
        pc_wire
        (Signal.mux2
           is_mret
           mepc_wire
           (Signal.mux2 trap_taken mtvec_wire next_pc_normal)))
  in
  Signal.assign pc_wire pc;
  Signal.assign mepc_wire csr.Csr.O.mepc;
  Signal.assign mtvec_wire (csr.Csr.O.mtvec &: c (lnot 3));
  Signal.assign trap_wire trap_taken;
  Signal.assign
    trap_cause_wire
    (Signal.mux2 exception_ exc_cause csr.Csr.O.interrupt_cause);
  Signal.assign trap_pc_wire (Signal.mux2 exception_ pc_wire next_pc_normal);
  Signal.assign trap_val_wire (Signal.mux2 exception_ exc_val (c 0));
  let pc4 = pc_wire +:. 4 in
  (* ALU *)
  let alu_a =
    Signal.mux2 is_auipc pc_wire (Signal.mux2 is_lui (Signal.zero 32) rs1_data)
  in
  let alu_b = Signal.mux2 alu_src_imm imm rs2_data in
  let alu_result = Alu.create ~op:alu_op ~a:alu_a ~b:alu_b in
  (* loads and stores *)
  let addr_lo = Signal.select alu_result 1 0 in
  let word = i.dmem_rdata in
  let byte =
    Signal.mux
      addr_lo
      [ Signal.select word 7 0
      ; Signal.select word 15 8
      ; Signal.select word 23 16
      ; Signal.select word 31 24
      ]
  in
  let half =
    Signal.mux
      (Signal.select addr_lo 1 1)
      [ Signal.select word 15 0; Signal.select word 31 16 ]
  in
  let load_data =
    Signal.mux2
      (funct3 ==:. 0)
      (Signal.sresize byte 32)
      (Signal.mux2
         (funct3 ==:. 1)
         (Signal.sresize half 32)
         (Signal.mux2
            (funct3 ==:. 4)
            (Signal.uresize byte 32)
            (Signal.mux2 (funct3 ==:. 5) (Signal.uresize half 32) word)))
  in
  let one4 = Signal.of_int ~width:4 1 in
  let sb_strb = Signal.log_shift Signal.sll one4 addr_lo in
  let sh_strb =
    Signal.log_shift Signal.sll (Signal.of_int ~width:4 3) (Signal.select addr_lo 1 1)
  in
  let store_byte = Signal.select rs2_data 7 0 in
  let byte_rep = Signal.concat_msb [ store_byte; store_byte; store_byte; store_byte ] in
  let half_rep =
    let h = Signal.select rs2_data 15 0 in
    Signal.concat_msb [ h; h ]
  in
  let store_data =
    Signal.mux2 (funct3 ==:. 0) byte_rep (Signal.mux2 (funct3 ==:. 1) half_rep rs2_data)
  in
  let store_strb =
    Signal.mux2
      (funct3 ==:. 0)
      sb_strb
      (Signal.mux2 (funct3 ==:. 1) sh_strb (Signal.of_int ~width:4 0xf))
  in
  (* write back *)
  let link = is_jal |: is_jalr in
  let wb_data =
    Signal.mux2
      is_load
      load_data
      (Signal.mux2
         is_wait
         wait_rd
         (Signal.mux2 link pc4 (Signal.mux2 is_csr csr.Csr.O.rdata alu_result)))
  in
  let reg_write =
    is_reg |: is_imm |: is_load |: is_lui |: is_auipc |: is_jal |: is_jalr |: is_csr
    |: is_wait
  in
  Signal.assign wdata_wire wb_data;
  Signal.assign we_wire (reg_write &: ~:halted &: ~:exception_ &: ~:stall);
  let dmem_we = is_store &: ~:halted &: ~:exception_ &: ~:stall in
  { O.imem_addr = pc_wire
  ; dmem_addr = alu_result
  ; dmem_wdata = store_data
  ; dmem_wstrb = store_strb
  ; dmem_we
  ; dmem_re = is_load
  ; pc = pc_wire
  ; halted
  ; trap = trap_taken
  }
;;
