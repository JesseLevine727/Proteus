/* CAN receiver sampling loop, hand-written so the bit period is exactly
   constant: C compilers hoist the de-stuff out of the sampling loop, which
   makes the sample point drift and breaks the ACK timing.

   can_sample() waits for the SOF, samples MAXBITS raw bits one per RX_BIT
   cycles, de-stuffs them into the global dbit[] (branchless), tracks the
   frame length from the DLC and drives the ACK slot. Returns the de-stuffed
   frame length (SOF..CRC), or -1 on a bad SOF.

   CAN_RX = ui_in[0] (IN bit 8);  CAN_TX = uio[0] (OE bit 16). */

  .equ PINS,       0x20000000
  .equ PIN_OE_OFF, 4
  .equ PIN_IN_OFF, 8
  .equ RX_MASK,    0x100
  .equ TX_OE,      0x10000
  .equ RX_SAMPLE,  104
  .equ RX_BIT,     191
  .equ MAXBITS,    100

  .section .text
  .globl can_sample
  .type can_sample, @function
can_sample:
  li    s0, PINS
  la    s1, dbit

  /* wait for the SOF (bus dominant) */
1:
  lw    a0, PIN_IN_OFF(s0)
  andi  a0, a0, RX_MASK
  bnez  a0, 1b

  /* delay to the SOF sample point */
  li    a0, RX_SAMPLE
  .insn r 0x0B, 0, 0, x0, a0, x0

  lw    a0, PIN_IN_OFF(s0)
  andi  a0, a0, RX_MASK
  bnez  a0, 9f

  /* state: nd=t0, last=t1, run=t2, skip=t3, frame_len=t4, after=t5 */
  li    t0, 1
  li    t1, 0
  li    t2, 1
  li    t3, 0
  li    t4, -1
  li    t5, 0
  sb    zero, 0(s1) /* dbit[0] = SOF */

  li    t6, 1 /* loop counter */

2: /* --- sample one bit --- */
  li    a0, RX_BIT
  .insn r 0x0B, 0, 0, x0, a0, x0

  lw    a0, PIN_IN_OFF(s0)
  andi  a0, a0, RX_MASK
  snez  a0, a0 /* raw bit */

  /* --- branchless de-stuff --- */
  xori  a1, t3, 1      /* keep = 1 - skip */
  add   a2, s1, t0
  sb    a0, 0(a2)      /* dbit[nd] = raw */
  add   t0, t0, a1     /* nd += keep */
  xor   a2, a0, t1
  seqz  a2, a2         /* eq = (raw == last) */
  and   a2, a2, a1     /* eq & keep */
  neg   a3, a2         /* m */
  and   t2, t2, a3
  addi  t2, t2, 1      /* run = 1 + (run & m) */
  and   t1, t1, a3
  not   a3, a3
  and   a3, a3, a0
  or    t1, t1, a3     /* last = (last & m) | (raw & ~m) */
  li    a3, 5
  sub   a3, t2, a3
  seqz  t3, a3         /* skip = (run == 5) */

  /* --- frame length once we have the DLC --- */
  bgez  t4, 3f
  li    a3, 19
  blt   t0, a3, 4f
  lbu   a3, 15(s1)
  slli  a3, a3, 3
  lbu   a4, 16(s1)
  slli  a4, a4, 2
  or    a3, a3, a4
  lbu   a4, 17(s1)
  slli  a4, a4, 1
  or    a3, a3, a4
  lbu   a4, 18(s1)
  or    a3, a3, a4
  slli  a3, a3, 3
  addi  a3, a3, 34     /* 19 + 8*dlc + 15 */
  mv    t4, a3

3: /* --- ACK slot --- */
  blez  t4, 4f
  blt   t0, t4, 4f
  addi  t5, t5, 1
  li    a3, 3
  bne   t5, a3, 5f
  lw    a3, PIN_OE_OFF(s0)
  li    a4, TX_OE
  or    a3, a3, a4
  sw    a3, PIN_OE_OFF(s0) /* drive dominant */
  j     4f
5:
  li    a3, 4
  bne   t5, a3, 4f
  lw    a3, PIN_OE_OFF(s0)
  li    a4, TX_OE
  not   a4, a4
  and   a3, a3, a4
  sw    a3, PIN_OE_OFF(s0) /* release */

4:
  addi  t6, t6, 1
  li    a3, MAXBITS
  blt   t6, a3, 2b

  mv    a0, t4
  ret

9:
  li    a0, -1
  ret
  .size can_sample, .-can_sample
