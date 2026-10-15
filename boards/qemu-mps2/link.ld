/* QEMU's MPS2 AN500 and AN386. There is no TrustZone on either core, so the reset vector is read from
 * address zero. The image goes in `mps.ssram1` (4 MiB at 0x0000_0000), which is RAM: `.data` sits where
 * the ELF loader puts it, and no flash-to-RAM copy is needed. A real part's link script differs here.
 * The stack takes the top of the first 512 KiB.
 */
ENTRY(_start)

MEMORY {
  CODE (rwx) : ORIGIN = 0x00000000, LENGTH = 512K
}

SECTIONS {
  /* The architecture's sixteen words, then the chip's interrupts, in that order. The MPU's null guard
   * takes the first 256 bytes from every access but the core's vector reads, so nothing else may sit
   * there: code placed in it faults the first time it runs with the MPU on. */
  .vectors : { KEEP(*(.vectors)) KEEP(*(.vectors.irq)) . = MAX(., 0x100); } > CODE
  .text    : { *(.text*) *(.rodata*) } > CODE

  /* The code and its constants end below 0x4_0000, and the data starts there: an unprivileged task's
   * code region is then [0, __code_end), a power of two from zero, as one PMSAv7 region must be, and
   * holds nothing a task may not read. */
  __code_end = 0x40000;
  ASSERT(. <= __code_end, "the code and constants no longer fit below 0x4_0000")
  .data __code_end : { *(.data*) } > CODE

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
