# skiff — roadmap

skiff is a small real-time operating system for microcontrollers without an MMU, written in sysl. Its
kernel is portable; its first machine is the STM32H747, two cores in one chip: a Cortex-M7 at 480 MHz and a Cortex-M4 at
240 MHz. keel is its larger sibling: a Unix-like kernel for aarch64 with processes and address spaces.
skiff is the other kind of system, built for a microcontroller: tasks compiled into one image, static
memory, deterministic latency.

Like keel, it exists to force refinements to sysl. Every place sysl cannot express what skiff needs
is recorded in `FINDINGS.md` and fixed in the language rather than worked around here.

## The target (decided 2026-10-13)

- **An RTOS, not a smaller keel.** Tasks, not processes:
  - no system-call ABI and no ELF loading;
  - no `fork`;
  - everything is linked into the image at build time.
  The kernel and the application are one sysl program.
- **Static first.** Tasks, stacks, queues and pools are declared and sized at build time. A general
  heap is optional, so `&T`, `Buf` and `string` are available, but no kernel path depends on one.
- **Preemptive and priority-based**, with priority inheritance on mutexes and bounded interrupt
  latency.
- **The MPU protects, without translating.** It guards stacks, catches null pointers and marks
  regions shared or non-cacheable. There is one address space.
- **Written in sysl.** No vendor HAL, no CMSIS headers and no C files. Registers are declared in sysl
  from the reference manual (RM0399 for the H747). A `.S` file only when sysl cannot express
  something, with a finding recorded first.
- **The recorder is the first application.** It is the digital audio recorder planned on the
  H747I-DISCO: the M4 records audio and the M7 stores it.

## Two cores, two kernels (decided 2026-10-13)

The H747's cores are **asymmetric**, so there is no shared run queue.

- **The cores differ:** different FPUs (double precision on the M7, single precision on the M4). The
  M7 has caches and the M4 has none.
- **Each core is configured separately:** its own vector table, its own NVIC, and its own boot
  address set by option bytes.
- **Their memory views disagree:** the M7's data cache does not see what the M4 writes.

So skiff is **one kernel built twice**, and the two images talk by message passing.

## Layers: the kernel knows no chip (decided 2026-10-13)

The STM32H747 is the first machine, not the design. skiff is three layers of packages, and a
dependency only ever points down the list:

```
skiff/
  kernel/          the portable kernel: the scheduler, tasks, timers, synchronisation, IPC rings, pools,
                   and the traits below. Knows no architecture, chip or board.
  arch/armv7m/     one package per CPU family: context switch (PendSV), SysTick, the NVIC, fault decoding,
  arch/armv8m/     the MPU, the FPU context, atomics. armv6m (M0+) and riscv32 later, as boards need them.
  chips/stm32h747/ one package per chip: clocks, the interrupt numbers, the memory map, the IPC hardware
  chips/mps2/      (HSEM / MHU), drivers for its peripherals. Built on the generated register packages.
  boards/h747i-disco/  one program per board and core: pins, the codec, the link script, main
  boards/qemu-an500/ …
```

- **The kernel is written against traits**, and an arch or chip package implements them:
  - `Port`: switch context, start the first task, mask interrupts, an atomic compare-and-swap, sleep
    until an interrupt;
  - `Clock`: a monotonic time and one-shot wake-up;
  - `Protection`: an MPU's regions, or nothing;
  - `Doorbell` + `HardwareLock`: the other core.
  The kernel never names a register, an IRQ number or an address.
- **Drivers are not in the kernel either.** They are written against the traits other packages use
  (a block device for KFS and FAT, a serial stream, an audio stream). Chip packages implement them.
- **The rule is checked, not trusted.** Every gate:
  - runs `sysl test kernel` on the host, which only works because the kernel has no hardware in it;
  - builds the kernel package for `thumbv6m`, `thumbv7em`, `thumb-freestanding` (v8-M) and
    `riscv32-freestanding`, including the families that have no port yet.

  A chip-specific import into `kernel/` fails the gate on the first build that cannot see that chip.
- **Bringing up a new microcontroller** means writing a chip package plus a board program, and an
  arch package only when the CPU family is new. QEMU's mps2 machines are themselves a second "chip",
  so the portable boundary is exercised from milestone 0, before the H747 is involved.
- Should the layers prove useful outside skiff, `kernel/` can be split into its own repo the way KFS
  is leaving keel.

- **The M7 boots first.** It sets up clocks and shared memory, then releases the M4.
- **IPC** uses single-producer, single-consumer rings in a shared SRAM region:
  - the region sits at one fixed address that both link scripts name;
  - its layout is defined once, in the kernel package;
  - the MPU marks it non-cacheable on the M7.
  A doorbell interrupt tells the other core to look.
- **The IPC hardware is behind a trait** (doorbell, hardware lock, releasing the second core). Each
  board implements it:

  | | `mps2-an521` (QEMU) | STM32H747 |
  |---|---|---|
  | release the second core | SSE-200 CPUWAIT | `BOOT_CM4` / HSEM |
  | doorbell | MHU | HSEM interrupt |
  | hardware lock | LDREX/STREX on shared SRAM | HSEM |

## Compilers and targets

| core | sysl target | FPU |
|---|---|---|
| M4 | `thumbv7em-freestanding` | `fpv4-sp-d16`, the M4F's own |
| M7 | `thumbv7em-freestanding-dp` (to add to sysl) | `fpv5-d16`, double precision in hardware |
| QEMU two-core | `thumb-freestanding` | `fpv5-sp-d16` (Cortex-M33) |

Until sysl gains the M7 target, the M7 image builds with `thumbv7em-freestanding`. That code runs on
the M7 unchanged, but every `f64` operation becomes a library call.

## Testing

Every milestone has a test that runs by itself and passes or fails on what the machine prints. Each
test has controls: a deliberate defect that must make it fail.

| machine | runs | proves |
|---|---|---|
| QEMU `mps2-an500` | the M7 image alone | the kernel on a Cortex-M7 |
| QEMU `mps2-an386` | the M4 image alone | the kernel on a Cortex-M4 |
| QEMU `mps2-an521` | both images, one per M33 core, built from the same source | release, handshake and IPC under true concurrency (multi-threaded TCG) |
| `sysl test kernel` on the host | the portable logic: scheduler decisions, rings, timers | edge cases no boot reaches |
| H747I-DISCO | both images, flashed together | everything, including the M7's cache, which QEMU does not model |

QEMU exits through semihosting, and a watchdog kills it by PID, as keel's script does. The board test
is run by hand until a flashing-and-serial harness exists.

## Milestones

| # | Milestone | Done when |
|---|---|---|
| 0 | Boot, UART, exit: vector table, reset handler, `.data`/`.bss`, the CMSDK UART | `skiff: hello` on `mps2-an500` and `mps2-an386`, QEMU exits 0 |
| 1 | Exceptions and interrupts: NVIC, SysTick, fault handlers that report CFSR/HFSR/MMFAR | `skiff: tick 3`, and a deliberate bus fault is reported, not hung on |
| 2 | Tasks: static task table, PendSV context switch, preemptive priority scheduler, FPU context with lazy stacking | two tasks at one priority interleave on the tick; a higher-priority task preempts at once; FP registers survive a switch |
| 3 | Synchronisation: mutex with priority inheritance, semaphores, message queues, event flags; timeouts; giving from an interrupt | a priority-inversion scenario completes in bounded time; a timed wait times out; interrupt-to-task latency measured |
| 4 | Memory and protection: the MPU (stack guards, null guard, peripheral regions), static pools, the optional heap | a task overflowing its stack is caught by the MPU and reported; pools reclaim exactly |
| 5 | Two cores on `mps2-an521`: the second image, release, the shared region, the MHU doorbell, IPC rings | messages both ways under load, every count exact; the second core's hello |
| 6 | The H747I-DISCO: clocks (PLLs to 480/240 MHz), USART through the ST-LINK's virtual COM port, flashing both images, HSEM release and IPC | `skiff: hello` from both cores on the board; milestone 5's IPC test passes there |
| 7 | Caches: M7 I- and D-cache on, the shared region non-cacheable through the MPU, cache maintenance for DMA buffers | the IPC test passes with caches on; the control (shared region cacheable) fails |
| 8 | Storage: the SDMMC driver behind a block-device trait; FAT (`sh.sysl.fat`) and KFS on the card | a file written survives a power cycle; the card reads on a PC |
| 9 | Audio: SAI and DMA on the M4 with the board's codec, double-buffered; samples to the M7 through IPC | a WAV file recorded to the SD card plays back correctly on a PC: the recorder's first slice |
| 10 | Low power: tickless idle, stop mode with a wake source | the idle current drops, measured on the board; timers stay correct across stop |

## What skiff reuses rather than writes

- **KFS** (`sysl-lang/kfs` once it leaves keel) and **FAT** (`sh.sysl.fat`): both freestanding, over
  a block-device trait. KFS already builds for `thumbv7em-freestanding`.
- **Fixed point** (`q15`/`q31`, sysl alpha.11), for audio on the M4.
- **kairos**, the async library: skiff can be one of its board drivers.
- **cstd**, if a ported C library is ever wanted on the board.
