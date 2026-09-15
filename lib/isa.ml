(* RISC-V RV32I instruction encoding.

   Two consumers:
   - the hardware decoder in [Cpu], which uses the field/opcode constants
   - firmware, which uses the instruction constructors to assemble programs *)

let mask n = (1 lsl n) - 1
let field n v = v land mask n
let ( << ) v n = v lsl n

(* major opcodes *)
let op_lui = 0x37
let op_auipc = 0x17
let op_jal = 0x6f
let op_jalr = 0x67
let op_branch = 0x63
let op_load = 0x03
let op_store = 0x23
let op_imm = 0x13
let op_reg = 0x33
let op_system = 0x73

(* instruction formats *)
let r_type opcode rd funct3 rs1 rs2 funct7 =
  field 7 opcode
  lor (field 5 rd << 7)
  lor (field 3 funct3 << 12)
  lor (field 5 rs1 << 15)
  lor (field 5 rs2 << 20)
  lor (field 7 funct7 << 25)
;;

let i_type opcode rd funct3 rs1 imm =
  field 7 opcode
  lor (field 5 rd << 7)
  lor (field 3 funct3 << 12)
  lor (field 5 rs1 << 15)
  lor (field 12 imm << 20)
;;

let s_type opcode funct3 rs1 rs2 imm =
  field 7 opcode
  lor (field 5 imm << 7)
  lor (field 3 funct3 << 12)
  lor (field 5 rs1 << 15)
  lor (field 5 rs2 << 20)
  lor (field 7 (imm lsr 5) << 25)
;;

let b_type opcode funct3 rs1 rs2 imm =
  let imm = field 13 imm in
  let b12 = imm lsr 12 land 1 in
  let b11 = imm lsr 11 land 1 in
  let b10_5 = imm lsr 5 land 0x3f in
  let b4_1 = imm lsr 1 land 0xf in
  field 7 opcode
  lor (b11 << 7)
  lor (b4_1 << 8)
  lor (field 3 funct3 << 12)
  lor (field 5 rs1 << 15)
  lor (field 5 rs2 << 20)
  lor (b10_5 << 25)
  lor (b12 << 31)
;;

let u_type opcode rd imm =
  field 7 opcode lor (field 5 rd << 7) lor (field 20 (imm lsr 12) << 12)
;;

let j_type opcode rd imm =
  let imm = field 21 imm in
  let b20 = imm lsr 20 land 1 in
  let b10_1 = imm lsr 1 land 0x3ff in
  let b11 = imm lsr 11 land 1 in
  let b19_12 = imm lsr 12 land 0xff in
  field 7 opcode
  lor (field 5 rd << 7)
  lor (b19_12 << 12)
  lor (b11 << 20)
  lor (b10_1 << 21)
  lor (b20 << 31)
;;

(* register aliases *)
let x0 = 0
let ra = 1
let sp = 2
let gp = 3
let tp = 4
let t0 = 5
let t1 = 6
let t2 = 7
let s0 = 8
let s1 = 9
let a0 = 10
let a1 = 11
let a2 = 12
let a3 = 13
let a4 = 14
let a5 = 15

(* U-type *)
let lui rd imm = u_type op_lui rd imm
let auipc rd imm = u_type op_auipc rd imm

(* jumps *)
let jal rd imm = j_type op_jal rd imm
let jalr rd rs1 imm = i_type op_jalr rd 0 rs1 imm

(* branches *)
let beq rs1 rs2 imm = b_type op_branch 0 rs1 rs2 imm
let bne rs1 rs2 imm = b_type op_branch 1 rs1 rs2 imm
let blt rs1 rs2 imm = b_type op_branch 4 rs1 rs2 imm
let bge rs1 rs2 imm = b_type op_branch 5 rs1 rs2 imm
let bltu rs1 rs2 imm = b_type op_branch 6 rs1 rs2 imm
let bgeu rs1 rs2 imm = b_type op_branch 7 rs1 rs2 imm

(* loads *)
let lb rd rs1 imm = i_type op_load rd 0 rs1 imm
let lh rd rs1 imm = i_type op_load rd 1 rs1 imm
let lw rd rs1 imm = i_type op_load rd 2 rs1 imm
let lbu rd rs1 imm = i_type op_load rd 4 rs1 imm
let lhu rd rs1 imm = i_type op_load rd 5 rs1 imm

(* stores *)
let sb rs2 rs1 imm = s_type op_store 0 rs1 rs2 imm
let sh rs2 rs1 imm = s_type op_store 1 rs1 rs2 imm
let sw rs2 rs1 imm = s_type op_store 2 rs1 rs2 imm

(* immediate ALU *)
let addi rd rs1 imm = i_type op_imm rd 0 rs1 imm
let slti rd rs1 imm = i_type op_imm rd 2 rs1 imm
let sltiu rd rs1 imm = i_type op_imm rd 3 rs1 imm
let xori rd rs1 imm = i_type op_imm rd 4 rs1 imm
let ori rd rs1 imm = i_type op_imm rd 6 rs1 imm
let andi rd rs1 imm = i_type op_imm rd 7 rs1 imm
let slli rd rs1 sh = i_type op_imm rd 1 rs1 (field 5 sh)
let srli rd rs1 sh = i_type op_imm rd 5 rs1 (field 5 sh)
let srai rd rs1 sh = i_type op_imm rd 5 rs1 (field 5 sh lor 0x400)

(* register-register ALU *)
let add rd rs1 rs2 = r_type op_reg rd 0 rs1 rs2 0x00
let sub rd rs1 rs2 = r_type op_reg rd 0 rs1 rs2 0x20
let sll rd rs1 rs2 = r_type op_reg rd 1 rs1 rs2 0x00
let slt rd rs1 rs2 = r_type op_reg rd 2 rs1 rs2 0x00
let sltu rd rs1 rs2 = r_type op_reg rd 3 rs1 rs2 0x00
let xor rd rs1 rs2 = r_type op_reg rd 4 rs1 rs2 0x00
let srl rd rs1 rs2 = r_type op_reg rd 5 rs1 rs2 0x00
let sra rd rs1 rs2 = r_type op_reg rd 5 rs1 rs2 0x20
let or_ rd rs1 rs2 = r_type op_reg rd 6 rs1 rs2 0x00
let and_ rd rs1 rs2 = r_type op_reg rd 7 rs1 rs2 0x00

(* system *)
let nop = addi x0 x0 0
let ebreak = 0x00100073
let ecall = 0x00000073
