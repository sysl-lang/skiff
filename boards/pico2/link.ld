/* The Raspberry Pi Pico 2: an RP2350 with 4 MiB of QSPI flash and 512 KiB of striped SRAM. Both cores run
 * the one image, in place from flash. The boot ROM runs it only if it finds the IMAGE_DEF block in the
 * first 4 KiB, which follows the vector table. `.data` is loaded into flash after the code and copied to
 * SRAM by core 0's reset; `.bss` and `.shared` are SRAM that core 0's reset zeroes. Each core's own stack
 * sits at the top of SRAM, where nothing clears it.
 */
ENTRY(_start)

MEMORY {
  FLASH (rx)  : ORIGIN = 0x10000000, LENGTH = 4M
  RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 512K - 32K
  STACKS (rw) : ORIGIN = 0x20078000, LENGTH = 32K
}

SECTIONS {
  /* The architecture's sixteen words, then the chip's interrupts, then the IMAGE_DEF block. */
  /* The code and its constants run from __code_start to __code_end, both on 32-byte boundaries: an
   * unprivileged task's code region is exactly that, one PMSAv8 region, holding nothing a task may not
   * read. */
  __code_start = ORIGIN(FLASH);
  .vectors : {
    __vectors_start = .;
    KEEP(*(.vectors)) KEEP(*(.vectors.irq))
    KEEP(*(.picobin))
  } > FLASH
  .text    : { *(.text*) *(.rodata*) . = ALIGN(32); } > FLASH
  __code_end = .;

  .data : ALIGN(4) {
    __data_start = .;
    *(.data*)
    . = ALIGN(4);
    __data_end = .;
  } > RAM AT > FLASH
  __data_load = LOADADDR(.data);

  /* Core 0's reset zeroes everything between these two symbols; core 1's, between the second pair, which
   * is empty in one image. */
  .bss (NOLOAD) : {
    __bss_start = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM
  __core1_zero_start = __bss_end;
  __core1_zero_end = __bss_end;

  /* Everything another core can reach (the kernel's DESIGN.md, "The rule everything follows"). Core 0
   * zeroes it with `.bss`, before it launches core 1. */
  .shared (NOLOAD) : ALIGN(16) {
    __shared_start = .;
    KEEP(*(.shared*))
    . = ALIGN(4);
    __shared_end = .;
  } > RAM

  /* 16 KiB each: core 0's below core 1's. The vector table's first word, the stack pointer the ROM
   * enters core 0 with, is core 0's. */
  _stack_top0 = ORIGIN(STACKS) + LENGTH(STACKS) / 2;
  _stack_top1 = ORIGIN(STACKS) + LENGTH(STACKS);
  _stack_top  = _stack_top0;
}
