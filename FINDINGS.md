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
- **The effect:** an M7 build works, because fpv4-sp-d16 is a subset of the M7's FPU and the
  hard-float calling convention is the same, but every `f64` operation becomes a library call.
- **Proposed fix:** a `thumbv7em-freestanding-dp` row in `target.sysl`:
  - triple `thumbv7em-none-eabihf`, `-mfpu=fpv5-d16`;
  - checked against clang like every other row;
  - with a disassembly test that an `f64` multiply is a `vmul.f64` under it and a library call under
    `thumbv7em-freestanding`.
