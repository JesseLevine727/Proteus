/* Proteus firmware linker script.
   Instruction memory at 0x0, data memory at 0x1000_0000.
   .rodata and .data have their load address (LMA) in IMEM and their virtual
   address (VMA) in DMEM; crt0 copies them at startup. */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 1K
  DMEM (rw) : ORIGIN = 0x10000000, LENGTH = 2K
}

SECTIONS
{
  .text : {
    *(.text*)
  } > IMEM

  .data : AT(ADDR(.text) + SIZEOF(.text)) {
    _sdata = .;
    *(.rodata*)
    *(.data*)
    . = ALIGN(4);
    _edata = .;
  } > DMEM
  _sidata = LOADADDR(.data);

  .bss : {
    _sbss = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
  } > DMEM

  /* results buffer for testbenches, at a fixed address */
  .result 0x10000700 (NOLOAD) : {
    KEEP(*(.result))
  }

  _stack_top = 0x10000700;
}
