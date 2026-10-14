/* QEMU's MPS2 AN521, core 0. Its image takes the first 2 MiB of SSRAM1 through the Secure alias
 * (0x1000_0000), which is RAM, so `.data` sits where the ELF loader puts it. Core 1's image starts at
 * 0x1020_0000, and the links between the cores are in the SSE-200's internal SRAM at 0x3000_0000.
 * The stack takes the top of this image's region.
 */
ENTRY(_start)

MEMORY {
  CODE (rwx) : ORIGIN = 0x10000000, LENGTH = 2M
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
