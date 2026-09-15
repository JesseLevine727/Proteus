(* Proteus RV32I core.

   Phase 1 microarchitecture: single cycle, combinational instruction fetch
   (the instruction memory lives in [Soc] and is read combinationally) and a
   synchronous register file. Every instruction retires in one cycle, which
   makes firmware timing deterministic and easy to verify.

   Implemented: the full RV32I base integer instruction set. EBREAK halts the
   core (used to terminate firmware in simulation). CSRs, traps and the
   protocol-oriented custom instructions arrive in later phases. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; reset : 'a
    ; imem_rdata : 'a [@bits 32]
    ; dmem_rdata : 'a [@bits 32]
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
    }
  [@@deriving hardcaml]
end

let create (i : Signal.t I.t) : Signal.t O.t =
  let reg_spec = Reg_spec.create ~clock:i.clock ~clear:i.reset () in
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
  let is_ebreak = instr ==:. Isa.ebreak in
  (* halt latch: set on EBREAK and never cleared until reset *)
  let halted = Signal.reg_fb reg_spec ~width:1 ~f:(fun h -> h |: is_ebreak) in
  (* register file, wired through forward references so the write data can
     depend on the read data without a construction-order cycle *)
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
  (* operand selection *)
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
  (* branch condition *)
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
  (* program counter *)
  let pc =
    Signal.reg_fb reg_spec ~width:32 ~f:(fun pc ->
      let pc4 = pc +:. 4 in
      let branch_target = pc +: imm_b in
      let jal_target = pc +: imm_j in
      let jalr_target = (rs1_data +: imm_i) &: Signal.of_int ~width:32 (lnot 1) in
      let next_pc =
        Signal.mux2
          is_jal
          jal_target
          (Signal.mux2
             is_jalr
             jalr_target
             (Signal.mux2 (is_branch &: branch_taken) branch_target pc4))
      in
      Signal.mux2 halted pc next_pc)
  in
  let pc4 = pc +:. 4 in
  (* ALU *)
  (* LUI ignores rs1: force operand A to zero so the result is the immediate *)
  let alu_a =
    Signal.mux2 is_auipc pc (Signal.mux2 is_lui (Signal.zero 32) rs1_data)
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
  let wb_data = Signal.mux2 is_load load_data (Signal.mux2 link pc4 alu_result) in
  let reg_write =
    is_reg |: is_imm |: is_load |: is_lui |: is_auipc |: is_jal |: is_jalr
  in
  Signal.assign wdata_wire wb_data;
  Signal.assign we_wire (reg_write &: ~:halted);
  let dmem_we = is_store &: ~:halted in
  { O.imem_addr = pc
  ; dmem_addr = alu_result
  ; dmem_wdata = store_data
  ; dmem_wstrb = store_strb
  ; dmem_we
  ; dmem_re = is_load
  ; pc
  ; halted
  }
;;
