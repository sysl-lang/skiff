/* QEMU's MPS2 AN521, core 1's image of two (the board's `core1` feature): the 768 KiB after core 0's
 * image (core0.ld), its vector table at its start, which is where core 0 points core 1 (the system
 * description's `CORE1_VECTORS`), then `.shared` at the address core0.ld gives it. Core 1's reset zeroes
 * this image's `.bss`, never `.shared`, which core 0 has zeroed and filled in by then. Core 1's stack is
 * at the top of its own image's memory.
 */
ENTRY(_start)

MEMORY {
  CODE   (rwx) : ORIGIN = 0x100C0000, LENGTH = 768K
  SHARED (rw)  : ORIGIN = 0x10180000, LENGTH = 512K
}

/* `.shared` belongs to no image's load segment: two images each loading it would overlap. */
PHDRS {
  vectors PT_LOAD;
  code    PT_LOAD;
  data    PT_LOAD;
  shared  PT_NULL;
}

SECTIONS {
  __code_start = ORIGIN(CODE);
  .vectors : { KEEP(*(.vectors)) KEEP(*(.vectors.irq)) } > CODE :vectors
  .text    : { *(.text*) *(.rodata*) . = ALIGN(32); } > CODE :code
  __code_end = .;
  .data    : { *(.data*) } > CODE :data

  .bss     : {
    __bss_start = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > CODE :data
  __core1_zero_start = __bss_start;
  __core1_zero_end = __bss_end;

  .shared (NOLOAD) : {
    __shared_start = .;
    KEEP(*(.shared.system))
    KEEP(*(.shared))
    . = ALIGN(4);
    __shared_end = .;
  } > SHARED :shared

  _stack_top1 = ORIGIN(CODE) + LENGTH(CODE);
  _stack_top0 = _stack_top1;
  _stack_top  = _stack_top1;
}
