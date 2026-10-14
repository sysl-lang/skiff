/* QEMU's MPS2 AN521, core 1. Its image takes the second 2 MiB of SSRAM1 through the Secure alias
 * (0x1020_0000), after core 0's. Core 0 points INITSVTOR1 here before releasing this core, which then
 * reads its stack pointer and reset handler from the vector table at the start of this region.
 */
ENTRY(_start)

MEMORY {
  CODE (rwx) : ORIGIN = 0x10200000, LENGTH = 2M
}

SECTIONS {
  /* The architecture's sixteen words, then the chip's interrupts, in that order. */
  .vectors : { KEEP(*(.vectors)) KEEP(*(.vectors.irq)) } > CODE
  .text    : { *(.text*) *(.rodata*) } > CODE
  .data    : { *(.data*) } > CODE

  /* The reset handler zeroes everything between these two symbols. */
  .bss     : {
    __bss_start = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > CODE

  _stack_top = ORIGIN(CODE) + LENGTH(CODE);
}
