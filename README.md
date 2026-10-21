# skiff

A small real-time operating system for microcontrollers without an MMU, written in
[sysl](https://github.com/sysl-lang/sysl). It runs on one core or on several: each core has its own
scheduler, every task belongs to one core, and the kernel's objects (semaphores, mutexes, queues,
notifications) work across cores. The same kernel serves a single Cortex-M4, the two Cortex-M33s of an
RP2350 running one image, and the STM32H747's Cortex-M7 and Cortex-M4 running two.

It is the microcontroller sibling of [keel](https://github.com/sysl-lang/keel). See `ROADMAP.md` for the
design and the milestones, and `FINDINGS.md` for the language gaps it has found.
