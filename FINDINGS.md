# skiff — findings

Every place sysl cannot express what skiff needs. Each entry records:
- what was being written;
- the shortest input that shows the gap;
- the exact diagnostic;
- what the reference says should have happened;
- the workaround, if one was needed.

A finding is fixed in sysl, and the entry then says which release fixed it.

## 1. No target for the Cortex-M7's double-precision FPU

- **What was wanted:** an M7 build that uses the M7's FPU.
- **The gap:**
  - `thumbv7em-freestanding` builds for the Cortex-M4F (`-mfpu=fpv4-sp-d16`).
  - sysl has no target with `fpv5-d16`, and no manifest key that chooses an FPU.
- **The effect:** an M7 build runs, because fpv4-sp-d16 is a subset of the M7's FPU and the
  hard-float calling convention is the same, but every `f64` operation becomes a call to a
  compiler-rt routine (`__aeabi_dmul` and the rest). Nothing in a freestanding link defines those, so
  an `f64` program does not link at all (finding 2).
- **Status:** accepted by `sysl` for the release after alpha.12, as `thumbv7em-freestanding-dp`.
- **Proposed fix:** a `thumbv7em-freestanding-dp` row in `target.sysl`:
  - triple `thumbv7em-none-eabihf`, `-mfpu=fpv5-d16`;
  - checked against clang like every other row;
  - with a disassembly test that an `f64` multiply is a `vmul.f64` under it and a library call under
    `thumbv7em-freestanding`.

## 2. A freestanding Arm program that can panic does not link

- **What was being written:** milestone 1, whose SysTick setup panics on a period outside 1 to 2^24
  cycles (`arch/armv7m/.../systick.sysl`, `systick_start`).
- **Shortest input:** any program built for `thumbv7em-freestanding` (or another 32-bit freestanding
  target) that can reach `panic`. The board supplies `putchar` and `exit`, as a freestanding program
  must. The link still fails:

  ```
  ld.lld: error: undefined symbol: __aeabi_uldivmod
  >>> referenced by sysl.code.o.ll
  >>>               sysl.code.o:(sysl$digits_ulong) in archive …/std.syslib
  ```

  `panic` formats integers, `digits_ulong` divides a `u64` by ten, and a Cortex-M has no 64-bit
  divide, so LLVM calls the EABI helper. On RISC-V it is `__divdi3`/`__udivdi3`.
- **What the library says:** `library/sysl/softfloat/quad.sysl` supplies compiler-rt's `f128`
  routines itself, exported weak, "so an `f128` program links on all three without asking anything of
  the machine". The 64-bit integer helpers on 32-bit freestanding targets have no such supplier. The
  compiler's own QEMU tests supply them in C (`testdata/qemu/bsp_thumb.c`, `divmod64.h`). The same
  holds for soft `f64` (`__aeabi_dadd`, `__aeabi_dmul`, …) on every Cortex-M target with a
  single-precision FPU or none, which is every one sysl has today.
- **Proposed fix:** the library supplies the compiler-rt integer division helpers for 32-bit
  freestanding targets, weak, as it does for `f128`. On Arm that means `__aeabi_uldivmod` and
  `__aeabi_ldivmod`, naked wrappers since they answer in r0-r3; on RISC-V, `__udivdi3`, `__divdi3`,
  `__umoddi3`, `__moddi3`. The same treatment applies to the soft-double routines, so an `f64` program
  links on a Cortex-M.
- **What skiff would otherwise do:** link Arm GNU's `libgcc.a`, or write the helpers itself.
