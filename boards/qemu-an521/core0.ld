/* QEMU's MPS2 AN521, core 0's image of two (the board's `core0` feature). The images divide the first
 * 2 MiB of SSRAM1 through its Secure alias: core 0's image, core 1's, then `.shared`, which both scripts
 * place at one address, the system description's `SHARED_BASE` (system.sysl), and which core 0's reset
 * zeroes before it releases core 1. Core 0's stack is at the top of its own image's memory.
 */
ENTRY(_start)

MEMORY {
  CODE   (rwx) : ORIGIN = 0x10000000, LENGTH = 768K
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
  /* The code and its constants run from __code_start to __code_end, both on 32-byte boundaries: an
   * unprivileged task's code region is exactly that. */
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
  __core1_zero_start = __bss_end;
  __core1_zero_end = __bss_end;

  /* The board's structure first, the handshake at its head, so that each image finds the handshake at
   * `SHARED_BASE` whatever else it lays out; then the kernel's. */
  .shared (NOLOAD) : {
    __shared_start = .;
    KEEP(*(.shared.system))
    KEEP(*(.shared))
    . = ALIGN(4);
    __shared_end = .;
  } > SHARED :shared

  _stack_top0 = ORIGIN(CODE) + LENGTH(CODE);
  _stack_top1 = _stack_top0;
  _stack_top  = _stack_top0;
}
