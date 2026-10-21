# skiff

A small real-time operating system for microcontrollers without an MMU, written in
[sysl](https://github.com/sysl-lang/sysl). It runs on one core or on several: each core has its own
scheduler, every task belongs to one core, and the kernel's objects (semaphores, mutexes, queues,
notifications) work across cores. A multicore program is one image, whether on the two Cortex-M33s of
an RP2350 or the STM32H747's Cortex-M7 and Cortex-M4; a two-image build is an option for when the M7's
double-precision FPU and caches matter. The same kernel serves a single core as a count of one.

It is the microcontroller sibling of [keel](https://github.com/sysl-lang/keel). See `ROADMAP.md` for the
design and the milestones, and `FINDINGS.md` for the language gaps it has found.
