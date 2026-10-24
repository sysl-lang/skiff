/* QEMU's MPS2 AN521, both cores from one image. It takes the first 2 MiB of SSRAM1 through the Secure
 * alias (0x1000_0000), which is RAM, so `.data` sits where the ELF loader puts it. Each core has a stack
 * of its own, above `.bss` where nothing clears it: core 0 runs `_start` first and clears `.bss` while
 * core 1 is still held in reset.
 */
ENTRY(_start)

MEMORY {
  CODE (rwx) : ORIGIN = 0x10000000, LENGTH = 2M
}

SECTIONS {
  /* The architecture's sixteen words, then the chip's interrupts, in that order. */
  /* The code and its constants run from __code_start to __code_end, both on 32-byte boundaries: an
   * unprivileged task's code region is exactly that, one PMSAv8 region, holding nothing a task may not
   * read. */
  __code_start = ORIGIN(CODE);
  .vectors : { KEEP(*(.vectors)) KEEP(*(.vectors.irq)) } > CODE
  .text    : { *(.text*) *(.rodata*) . = ALIGN(32); } > CODE
  __code_end = .;
  .data    : { *(.data*) } > CODE

  /* Core 0's reset zeroes everything between these two symbols; core 1's, between the second pair, which
   * is empty in one image. */
  .bss     : {
    __bss_start = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > CODE
  __core1_zero_start = __bss_end;
  __core1_zero_end = __bss_end;

  /* Everything another core can reach (the kernel's DESIGN.md, "The rule everything follows"). Core 0
   * zeroes it with `.bss`, before it releases core 1. */
  .shared (NOLOAD) : ALIGN(16) {
    __shared_start = .;
    KEEP(*(.shared*))
    . = ALIGN(4);
    __shared_end = .;
  } > CODE

  /* The top of 1 MiB for core 0 and the top of the 2 MiB for core 1. The vector table's first word,
   * the stack pointer a core reads from it, is core 0's. */
  _stack_top0 = ORIGIN(CODE) + LENGTH(CODE) / 2;
  _stack_top1 = ORIGIN(CODE) + LENGTH(CODE);
  _stack_top  = _stack_top0;
}
