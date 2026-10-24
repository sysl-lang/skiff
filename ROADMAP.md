# skiff — roadmap

skiff is a small real-time operating system for microcontrollers without an MMU, written in sysl: tasks
compiled into one image, static memory, deterministic latency. It runs on one core or several. Like keel,
it exists to force refinements to sysl: every place sysl cannot express what skiff needs is recorded in
`FINDINGS.md` and fixed in the language, never worked around here.

`sysl-lang/skiff-old` is the first attempt: a single-core kernel with a two-core message link beside it.
Its architecture, chip and board packages, and the facts its notes record, are what this one starts from.
Its kernel is not.

## What the kernel is

- **An RTOS, not a smaller keel.** Tasks, not processes: no system-call ABI, no ELF loading, no `fork`.
  The kernel and the application are one sysl program per image.
- **Static first.** Tasks, stacks, queues and pools are declared and sized at build time. The
  application sizes them through the kernel's `options` (the task table, queue lengths, the MPU map, the
  number of cores); the kernel fixes no capacity for everyone. A heap is optional and no kernel path
  needs one.
- **Preemptive and priority-based**, with priority inheritance on mutexes and bounded interrupt latency.
- **The MPU protects, without translating**: stack guards, a null guard, unprivileged tasks with a map
  of their own, regions marked shared or non-cacheable. One address space per image.
- **Written in sysl.** No vendor HAL, no CMSIS, no C. Registers are `@packed` bitfield structs written
  from the reference manual.

## Many cores: partitioned, not global

**Each core runs its own scheduler, and every task belongs to one core** (partitioned fixed-priority
scheduling). There is no run queue shared by all cores. It suits cores that differ (the STM32H747's M7
and M4 differ in FPU and cache), and on identical cores it is still the better real-time model: each core's worst case is analysed
alone, nothing migrates, and no lock is held across the whole kernel. A task pinned to core 1 to feed a
PIO or an I2S stream is the ordinary case, not a special one. Explicit migration may come later; a global
run queue is not planned.

**One core is a count of one, not a different kernel.** With one core, finding the current core is a
constant, the per-object lock is interrupt masking, and the cross-core path is never reached. The
single-core images are booted by every gate.

What that asks of the kernel:

- **No singletons.** A `Core` holds a core's scheduler, its port, its statistics and its idle task;
  the kernel finds the running core's through `core_id()` on the port.
- **Task handles are (core, slot, generation).** A slot is reused after a task stops, so a handle kept
  from before is refused rather than reaching the new task.
- **One wait-queue primitive.** Every object (semaphore, mutex, queue, flags, notification, stream,
  timer service) waits through it, so waking never scans a task table and the waiting logic exists once.
- **A lock per object, behind a trait** the chip supplies: interrupt masking on one core; masking plus
  LDREX/STREX on Armv7-M/v8-M with coherent shared memory; the SIO spinlocks on the RP2040 (the M0+ has
  no exclusives, and sysl refuses atomic read-modify-write there, pointing at `Guarded[L, T]`); HSEM on
  the STM32H7. `sysl.sync`'s `Lock`, `IrqLock` and `Guarded` are the base.
- **A wake on another core goes through that core's inbox.** The waker posts to the target core's
  lock-free inbox and rings its doorbell; a core never edits another core's ready set. The same path
  serves one image and two.
- **The `.shared` rule (from milestone 1): anything another core can reach lives in `.shared` and names
  tasks by handle, never by pointer.** That is the inboxes, every object usable from more than one core,
  and its waiter records; a wake on another core always goes through that core's inbox. In one image
  `.shared` is an ordinary section the board maps uncached on a core with a data cache (the M7). In two
  images both link scripts place it at the same address, so the kernel's code is the same in both builds
  and the two-image option stays a build setting. A pointer from `.shared` into a core's own memory
  would make the option a rewrite; the review of every kernel change checks for one.
- **One time base.** Timeouts that cross cores need one clock: a timer every core can read, or the tick
  from one core.

## One image, everywhere by default

**A multicore program is one image**: one program, one `sysl build`, one binary. Every core enters the same
reset handler, reads its core number and starts its own scheduler, and every kernel object may be used
from any core.

That holds on the STM32H747 as well. Its M7 and M4 are both Armv7E-M and run the same Thumb-2 code; an
image built for the M4 (`thumbv7em-freestanding`, single-precision FPU) runs on the M7 unchanged. One image
costs the M7 two things: `f64` arithmetic becomes library calls, and memory both cores touch must be
memory the M7 does not cache (the M7 still caches code and the data only it uses, placed explicitly).

**Two images are an option for when the M7's extras matter** (hardware doubles, the cache everywhere),
as a build setting rather than a different program design. Then an object used from both is declared in
a **system description**, one sysl module both images import. It holds:
  - the shared memory's layout, and which objects live there;
  - which core owns each peripheral and each interrupt (EXTI has a mask per core, RCC an enable per
    core); owning one from both is a build error;
  - which core owns the clocks and the power supply, and releases the other.

  Its **layout fingerprint** (sizes and offsets over `T::Fields`, worked out while compiling) is
  compared in the boot handshake, so two images built apart that disagree stop at boot.
- **Bulk data moves by ownership, not by copy**: a buffer pool in shared memory, a buffer handed over
  through a channel. Caches sit behind a trait (clean before giving, invalidate after taking); making the
  whole region non-cacheable suits control data, not audio.

## Layers

```
kernel/          the portable kernel: cores, tasks, waits, objects, channels, the traits below
arch/<family>/   armv7m, armv8m, pmsa (MPU encoders), armv6m later: context switch, faults, the MPU
chips/<chip>/    mps2, an521, rp2350, stm32h747: memory map, clocks, IRQ numbers, doorbell, lock
boards/<board>/  one program per board (two only for a two-image build): link script, entry
tools/portable/  the gate's proof that the kernel builds for every CPU family
```

A dependency only points down the list. `kernel/` names no register, interrupt number, address or
`asm`. It reaches hardware through traits: `Port` (switch, mask, start, idle, `core_id`), `Clock`,
`Protection`/`Isolation`, `Doorbell`, `Lock`, `Cache`. Every new generic in the kernel gets a call in
`tools/portable`, built for thumbv6m, thumbv7em, thumb (v8-M) and riscv32.

## Machines

| machine | runs | proves |
|---|---|---|
| host, `sysl test kernel` | the kernel's decisions over fake ports, with N fake cores | edge cases no boot reaches |
| QEMU `mps2-an500` / `mps2-an386` | one core, M7 and M4 | the single-core kernel |
| QEMU `mps2-an521` | one image on both M33s; two images for the option | cross-core waits, the inbox, locks, the handshake, under multi-threaded TCG |
| Pico 2 (RP2350) | one image, two M33s | real silicon, the SIO FIFO doorbell, the spinlocks (erratum E2) |
| H747I-DISCO | one image on M7 + M4, then two | HSEM, clocks and power, the M7's caches, uncached shared state |

Every milestone has a test that passes or fails on what the machine prints, and controls: a deliberate
defect that must make it fail.

## Milestones

| # | Milestone | Done when |
|---|---|---|
| 0 | The workspace, the gate, and boot on every QEMU machine: the arch and chip packages ported from skiff-old, an AN521 image that boots both cores and tells them apart | `skiff: hello` from the AN500, the AN386 and both AN521 cores; the controls fail |
| 1 | Cores: the `Core` instance, ticks and faults per core, one time base, the `.shared` section and its rule | ticks on every core; a fault on one core is reported and the other runs on; the inboxes are in `.shared` |
| 2 | Tasks: per-core schedulers, generation handles, tables sized by `options` (sysl 0.3.7) | interleave, preempt and FP-survival scenarios on every core; a stale handle is refused |
| 3 | Waits and locks: the wait queue, the lock trait, semaphore, mutex with inheritance, queue, flags, notifications | the skiff-old scenarios pass on every core; on the AN521 both cores contend for one object's lock, and one core gives what the other takes without blocking (a blocking take across cores needs milestone 4's wake) |
| 4 | Cross-core wakes: inboxes and doorbells; channels and the buffer pool | each object is given on one core and taken, blocking, on the other; a priority-inversion scenario across cores completes in bounded time; buffers round-trip without a copy |
| 5 | Pico 2, the first real silicon: `chips/rp2350`, `boards/pico2` (one image, both M33s), the SIO FIFO doorbell, the lock (spinlocks or exclusives, per erratum E2), UF2 | milestones 1–4's scenarios pass on the board |
| 6 | Protection: stack and null guards, unprivileged tasks with their own maps and kernel calls | the skiff-old protection scenarios, on every core, the Pico 2 included. **Done on every QEMU core** (AN500, AN386, both AN521 cores, at both optimisations); the Pico 2 waits on milestone 5, and granting queues, channels and pool buffers waits on FINDINGS 9 |
| 7 | The rest of the kernel on the wait queue: software timers, stream and message buffers, task control, statistics and stack high-water marks | skiff-old's scenarios for each. **Software timers done** on every QEMU core (a service task per core, commands through its queue; another core's commands refused, DESIGN "Software timers"). **Task control done** on every QEMU core, both optimisations: suspend, resume, `set_priority` (a boost kept apart from the base), stop (wait withdrawn, slot reused), another core's task through its inbox (DESIGN "Task control"). **Stream and message buffers done** on every QEMU core (an interrupt's bytes at the trigger level, partial writes and reads, whole messages, timeouts), and across the AN521's cores, both blocking |
| 8 | Two images, the option: board features (`split`, one per image) with `#if feature_…` choosing each image's tasks, a link script per image with `.shared` at one address, the system description, ownership checked at build, the fingerprint handshake | the AN521 boots two images from one board program; mismatched layouts stop at the handshake. First check that a link script can differ by feature; if not, that is a sysl finding. **Done on the AN521** (both optimisations; core 1's image uses its FPU): DESIGN "Two images"; the H747I's two images are milestone 9's |
| 9 | The H747I-DISCO (needs the board): clocks and power, HSEM, one image on both cores with shared state uncached on the M7, then the two-image build with the cache trait | milestone 4's scenarios on the board in both builds, caches on |
| 10 | Supervision and power: a watchdog per core, faults forwarded, one console, tickless idle, coordinated stop | a hung core is noticed; both cores enter Stop and wake |

skiff needs sysl 0.3.9 or later: milestone 1 on uses `options` and an `if` as a constant, 3 a `const new`
as data and an enum's zero, and 8 uses the
explicit type-argument fix and a link script per feature.
