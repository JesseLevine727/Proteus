/* Proteus C runtime startup.
   Sets up the stack, copies .data/.rodata from IMEM to DMEM, zeroes .bss,
   calls main, then halts via the SoC HALT register. */

  .section .text
  .globl _start
_start:
  la    sp, _stack_top

  /* copy .data (LMA in IMEM) to DMEM */
  la    a0, _sdata
  la    a1, _edata
  la    a2, _sidata
1:
  bgeu  a0, a1, 2f
  lw    t0, 0(a2)
  sw    t0, 0(a0)
  addi  a0, a0, 4
  addi  a2, a2, 4
  j     1b
2:
  /* zero .bss */
  la    a0, _sbss
  la    a1, _ebss
3:
  bgeu  a0, a1, 4f
  sw    zero, 0(a0)
  addi  a0, a0, 4
  j     3b
4:
  call  main

  /* halt */
  li    t0, 0x70000000
  sw    zero, 0(t0)
5:
  j     5b
