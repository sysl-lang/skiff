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
- **Status:** accepted by `sysl` for the release after alpha.12. Until it ships, the qemu-mps2 board
  links Arm GNU's `libgcc.a` (`@link("gcc")`, with `-L` from `scripts/boot-test.sh`).

## 3. A bare-metal program's file can hold no module storage

- **What was being written:** milestone 2's board, whose tasks need storage of their own: their
  stacks and the counters two tasks meet on.
- **Shortest input:** a program of one headerless file that runs no statements. Its entry is an
  exported function, as a bare-metal image's is.

  ```sysl
  private var kept: [2]u32 = [0, 0]

  private bump() -> u32 = kept[0]

  @export("main")
  probe() -> i32 = i32(bump())
  ```

  ```
  error: 'bump' is declared inside a function body, so nothing outside can name it and there is
  nothing for a visibility modifier to restrict
  ```

  So the file is treated as a body, its `var` as a local and `bump` as a nested function. But writing
  `private static var kept` to make the storage the module's is refused for the opposite reason:

  ```
  error: 'static' says a declaration belongs to the module rather than to the body of the file the
  program starts in — and this file has no such body, so everything it declares is the module's already
  ```

  Neither spelling compiles, and a `module` header is refused because the file sits at the project
  root.
- **What the reference says:** `reference/modules.md` says both things.
  - Line 1420: "a headerless file carrying no statements, everything is the module's already and the
    modifier is refused".
  - Lines 1459-1460: "a single headerless file of bindings is still a body".

  The two checks implement one sentence each. A build whose entry is not `main` (`targets.*.entry`)
  never runs a body, so its storage can only be the module's, as for `build-c` and `build-lib` (line
  1467).
- **Proposed fix:** one ruling for the file, used by both checks. Where the build's entry is not
  `main`, or the file runs no statement, the file is not a body: `var` is the module's and `static` is
  refused, as the `static` diagnostic already says. The first error's anchor is also wrong: it names
  `bump` but points at the `var`, which in the board was 12 lines away.
- **Status:** accepted by `sysl` as a bug for the release after alpha.12. Both checks will follow one
  ruling, and the reference will be reconciled.
- **What skiff did:** the board's code that needs storage moved into its own module directory
  (`boards/qemu-mps2/board/`), where `var` is plainly the module's. That layout stands on its own, so
  nothing changes when this is fixed.

## 4. An `asm` output may be given the register an input is in

- **What was being written:** milestone 2's interrupt mask, which reads BASEPRI and then writes it.

  ```sysl
  mask(*self) -> u32
      var old: u32 = 0
      val level = MASK_PRIORITY
      asm
          [thumb]
              "mrs {old}, basepri"
              "msr basepri, {level}"
              out old : reg
              in level : reg
  ```

  compiles to `movs r0, #128; mrs r0, BASEPRI; msr BASEPRI, r0`. The read overwrote `level`, so the
  mask wrote back what was there and masked nothing. The boot test still passed. It was found only
  because a control that should have failed did not.
- **Shortest input**, on the host (aarch64):

  ```sysl
  seven_plus(level: int) -> int
      var old: int = 0
      asm
          [aarch64]
              "mov {old}, #7"
              "add {old}, {old}, {level}"
              in level : reg
              out old : reg
          [x86_64, riscv64, riscv32, thumb, craft, wasm32] unavailable "aarch64 only"
      old

  print(seven_plus(1))
  ```

  It prints `14`; it should print `8`.
- **What the reference says:** `reference/inline-assembly.md` § What the compiler owns: "The
  constraint string, which you never write, because a constraint that disagrees with the instruction
  text is not detectable by reading either one." The compiler writes `=r` for an output. LLVM reads
  that as "written only after every input is read", so it may share a register with one. Nothing
  in sysl can say otherwise, and nothing in the text says the output is written last.
- **Proposed fix:** emit every output as early-clobber (`=&r`). It is the conservative direction the
  page already takes for memory and the flags, and it costs at most a register per output. A test
  pins `seven_plus(1) == 8`.
- **Status:** accepted by `sysl` as a bug for the release after alpha.12. Every output will be emitted
  early-clobber, an `inout` will keep its tied operand, and tests will pin `seven_plus(1) == 8` and the
  BASEPRI disassembly on thumb.
- **What skiff does until then:** `mask` names its registers (`out old : "r0"`, `in level : "r1"`), with
  a comment pointing here. Remove that once the fix ships.

## 5. Naming a constant `val` keeps an initializer from being laid in as data

- **What was being written:** milestone 3's task table. A task row grew to twelve fields, and an empty
  one is needed both for the kernel's table and wherever a row is reset.
- **The first wall:** `const NO_TASK: Task = Task(…)` is refused: "a constant is a scalar, and Task is
  storage — write 'NO_TASK' as a 'val', which is laid into the object file as constant data".
- **The second wall:** the `val` it asks for cannot be named in another module's storage on bare metal.

  ```sysl
  module lib.fold

  struct P
      a: u32

  val ZERO: P = P(0)

  private var table: [4]P = [ZERO; 4]

  read() -> u32 = table[0].a
  ```

  built for `thumbv7em-freestanding` with entry `_start`, from a program that calls `fold.read()`:

  ```
  error: 'start' starts the image and reaches 'lib.fold.table', which is module storage an initializer
  fills before the program's own statements run. … or make the initializer constant data, which is
  laid straight into the image
  ```

  `[P(0); 4]` in its place builds.
- **What the reference and the compiler say:** the diagnostic for `const` calls a `val` over a
  constructor "constant data", and the diagnostic for the table asks for an initializer that is
  constant data. An initializer made only of constant data is one. So the table's initializer should
  fold whether its element is written out or named.
- **Proposed fix:** when the folder meets a module `val` whose own initializer folds, it substitutes
  that value, just as it already does for a `const`. A test: the probe above builds for
  `thumbv7em-freestanding`, and the image holds the table in `.data`/`.bss` with no initializer call.
- **Status:** accepted by `sysl` as a bug for the release after alpha.12. The folder will substitute a
  module `val` whose own initializer folds, with a check against a `val` that names itself.
- **What skiff does until then:** the kernel's `scheduler` writes the empty row out in full instead of
  naming `NO_TASK`, with a comment pointing here. Remove that once the fix ships.
