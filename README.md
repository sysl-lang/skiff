# skiff

A small real-time operating system for microcontrollers without an MMU, written in
[sysl](https://github.com/sysl-lang/sysl). Its first machine is the STM32H747: a Cortex-M7 and a Cortex-M4 in one
chip, each core running its own skiff kernel, with message passing between them.

It is the microcontroller sibling of [keel](https://github.com/sysl-lang/keel). See `ROADMAP.md` for the
design and the milestones, and `FINDINGS.md` for the language gaps it has found.
