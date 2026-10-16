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
- **Status:** Fixed in 0.1.0-alpha.13. `thumbv7em-freestanding-dp` emits `vmul.f64 d0, d0, d1` for an
  `f64` multiply (`Tag_FP_arch: FPv5/FP-D16`). The boot test builds the MPS2 program for it and boots
  it on QEMU's AN500 (Cortex-M7, whose model has the double-precision FPU), and builds it for
  `thumbv7em-freestanding` for the AN386 (M4). The board's `doubles` check
  (`(1 + 2^-40)^2 - 1 == 2^-39`) runs on both, in the FPU on the M7 and in the library's soft-float
  routines on the M4.
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
- **Status:** Fixed in 0.1.0-alpha.13. The standard library supplies `__aeabi_uldivmod` (weak) and
  `__aeabi_mem*` on every Thumb target. The three boards no longer have `@link("gcc")`, and
  `scripts/boot-test.sh` no longer passes libgcc's directory through `SYSL_EXTRA_CFLAGS`;
  `arm-none-eabi-nm -u` finds nothing undefined in any of the four images.

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
- **Status:** Fixed in 0.1.0-alpha.13. The MPS2 board's root file now holds the `Board` the kernel and
  the fault reports share (`private var machine`), where it used to build one in each export.
- **What skiff did:** the board's code that needs storage moved into its own module directory
  (`boards/qemu-mps2/board/`), where `var` is plainly the module's. That layout stands on its own and
  stays.

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
- **Status:** Fixed in 0.1.0-alpha.13. `mask` is back to `out old : reg` and `in level : reg`, and
  compiles to `movs r1, #128; mrs r0, BASEPRI; msr BASEPRI, r1` (r0 out, r1 in, at the default
  optimisation and at -O0). The control that caught it (SVC leaves BASEPRI raised) still fails.

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
- **Status:** Fixed in 0.1.0-alpha.13 for a `val` over a constructor. The kernel's `scheduler` is
  `Scheduler([NO_TASK; MAX_TASKS], 0, 0)` again and lies in `.data`, with no initializer run. A `val`
  over `ptr_cast` of a constant is still not substituted (finding 7).

## 6. A trait object made from module storage's address, and `Some` of an address, are not constant data

- **What was being written:** milestone 5's link between the AN521's cores. A core's end, a
  `Link[u32, 64]`, names its doorbell as a `*Doorbell`, and the first draft declared it whole as module
  storage: `Link(null, null, &bell, Flags(0))`.
- **The shortest input**, built for `thumbv7em-freestanding` with entry `_start` from a program that
  calls `fold.read()`:

  ```sysl
  module lib.fold

  trait Ring
      ring(*self) -> u32

  struct Bell
      to: u32

  impl Ring for Bell
      ring(*self) -> u32 = self.to

  private var bell: Bell = Bell(1)
  private var target: u32 = 7

  private var null_pointer: *u32 = null               // folds
  private var address_of: *u32 = &target              // folds
  private var trait_object: *Ring = &bell             // does not
  private var some_address: Option[*u32] = Some(&target)  // does not

  read() -> u32 = …                                   // reads all four
  ```

  ```
  error: 'start' starts the image and reaches 'lib.fold.some_address', 'lib.fold.trait_object', which is
  module storage an initializer fills before the program's own statements run. …
  ```
- **What the reference says:** ffi.md § "What constant data is" makes the address of module storage
  constant data (a relocation the linker fills in) and a variant carrying nothing constant data. It is
  silent on a trait object built from such an address and on a variant carrying one. Both are made only
  of link-time constants: an address and a vtable's address, or a tag and an address. C lays down
  `static struct link l = { 0, 0, &bell_ops, &bell }` without a constructor.
- **Proposed fix:** extend constant data to a `*Trait` coerced from a constant address (the address plus
  the impl's vtable symbol), and to a variant whose payload is constant data. Tests: the probe above
  builds for `thumbv7em-freestanding`, and both variables sit in `.data` with relocations.
- **Status:** Fixed in 0.1.0-alpha.13. The probe above builds. `tools/portable` declares its `Link`
  with an initializer (`Link(&ring_out, &ring_in, &bell, Flags(0))`) and a `Some(&ring_out)`, where it
  used to build the link in `main`. `build-c` for a freestanding target refuses storage an initializer
  would fill, so the gate's four builds prove both fold.
- **What skiff does:** the AN521 board still builds its `Link` at start-up. Declaring both cores' ends
  as data needs the rings' address, `&RINGS.to_core1` with `val RINGS: *Shared = ptr_cast(SHARED)`,
  and that does not fold (finding 7).

## 7. A `val` over `ptr_cast` of a constant is not substituted into an initializer

- **What was being written:** the AN521 board's two link ends as constant data, once finding 6 was
  fixed. The rings sit at a fixed address, so the board names them with a `val`.
- **Shortest input**, built with `sysl build-c . --target thumbv7em-freestanding` from a program whose
  export calls `fold.read()`:

  ```sysl
  module lib.fold

  struct Pair
      a: u32
      b: u32

  private const AT: usize = 0x3000_0000
  private val PAIR: *Pair = ptr_cast(AT)

  private var whole: *Pair = ptr_cast(AT)   // folds
  private var named: *Pair = PAIR           // does not

  read() -> u32 = whole.a + named.a
  ```

  ```
  error: 'probe' is exported and reaches 'lib.fold.named', which is module storage an initializer fills
  before the program's own statements run. This artifact has no entry point to fill it in, and
  'thumbv7em-freestanding' is freestanding — there is no loader to run a constructor either, so the
  function would read whatever the image left. Build for a hosted target, where the storage is filled
  before any export can run, or make the initializer constant data, which is laid straight into the
  object file. 'named' cannot be computed while compiling: 'lib.fold.PAIR' is filled when the program
  runs (fold.sysl:10:28)
  ```

  `private var fixed_field: *u32 = &PAIR.b` is refused the same way.
- **What the reference says:** ffi.md § "What constant data is": "A pointer written as `ptr_cast` of
  such an integer is one too", and the alpha.13 fix for finding 5 substitutes a module `val` whose own
  initializer folds. `whole` shows that `PAIR`'s initializer folds, so `named` should too, and so should
  the address of a field through it (the address of a field "at an index the compiler can fold").
- **Status:** Fixed in 0.1.1. `&RINGS.to_core1` through the `val` folds.
- **What skiff does:** the AN521 board declares both cores' link ends as constant data,
  `Link(&RINGS.to_core1, &RINGS.to_core0, &bell0, Flags(0))` and its mirror, and builds nothing at
  start-up.

## 8. A function's address is not constant data

- **What was being written:** software timers, FreeRTOS-style. A timer is a struct in the program's
  storage, written as a constructor over constants like `Queue` and `Semaphore`, and it names the
  function to call when it expires: `Timer("blink", 10, true, &blink, …)`. On a bare-metal image that
  storage must be laid in as data, so the callback's address has to be.
- **Shortest input**, built with `sysl build-c . --target thumbv7em-freestanding` (alpha.13):

  ```sysl
  private fired(n: u32) -> u32 = n + 1

  private var callback: *extern(u32) -> u32 = &fired

  @export("main")
  probe() -> i32 = i32(callback(1))
  ```

  ```
  error: 'probe' is exported and reaches 'callback', which is module storage an initializer fills
  before the program's own statements run. This artifact has no entry point to fill it in, and
  'thumbv7em-freestanding' is freestanding — there is no loader to run a constructor either, so the
  function would read whatever the image left. Build for a hosted target, where the storage is filled
  before any export can run, or make the initializer constant data, which is laid straight into the
  object file
  ```

  The same happens with `fired` marked `@export("fired")`, and with the address as a field of a struct
  (`Timer(5, &fired, None)`). A hosted `build-c` of the same program succeeds. Unlike finding 7, the
  diagnostic names no reason the initializer cannot be computed.
- **What the reference says:** ffi.md § "What constant data is" lists the address of module storage
  (a `var`, a `val` or an `extern` variable) and a trait object over one as constant data, and says
  nothing of a function's address either way. A function's address is a relocation exactly as a
  variable's is: C's `int (*callback)(int) = fired;` is laid into `.data` with an `R_ARM_ABS32` and runs
  nothing, on a bare machine as anywhere. A gap, then, rather than a bug against the page.
- **The workarounds, neither taken:** set each timer's callback at start-up (storage the program fills
  before the service runs, as the AN521 board does for finding 7); or make the callback a trait object
  (`*Expiry` over the address of a zero-sized struct per callback, which folds since finding 6), so that
  every callback needs a struct and an `impl` where C needs a function.
- **Status:** Fixed in 0.1.0. The reduction builds for `thumbv7em-freestanding`, and a function's
  address is laid in as data.
- **What skiff does:** software timers hold their callback's address in static storage.

## 9. A slice of a field of indexed module storage, passed through a trait object, is refused as frame-owned

- **What was being written:** the kernel loading an unprivileged task's MPU map on a switch
  (kernel isolation.sysl, `isolate_running`). The maps are module storage, `maps: [MAX_TASKS]Map`, and
  the unit is a `*Isolation` trait object: `iso.load(maps[i].slots[0..<maps[i].len])`.
- **Shortest input** (`sysl run main.sysl`, host):

  ```sysl
  trait Sink
      take(*self, words: []const u32)

  struct Count
      n: usize

  impl Sink for Count
      take(*self, words: []const u32) = self.n += words.len

  struct Row
      words: [4]u32
      len: usize

  var rows: [2]Row = [Row([0; 4], 0); 2]
  var sink: Count = Count(0)

  feed(s: *Sink, i: usize)
      s.take(rows[i].words[0..<rows[i].len])

  main()
      rows[1].len = 3
      feed(&sink, 1)
      print(sink.n)
  ```

  ```
  error: a slice of an array this frame owns is passed through a trait object, which may hold on to it,
  so it would outlive the array, and the storage is not this body's to move — it is a field of a value,
  an array a caller passed by value, or part of an array literal, which has no declaration to move.
  Declare it as a '[]T', which makes a buffer of its own and owns it, or as a '&[N]T' where the length
  is fixed
    --> main.sysl:18:25
  ```

  The same slice passed to an ordinary function compiles, a slice of a plain module array (`flat[0..<2]`)
  passed through the trait object compiles, and so does `val r = &rows[i]` then `s.take(r.words[0..<r.len])`.
- **What the reference says:** memory.md § "What happens when a slice escapes" promotes "a slice of an
  array **this frame owns**" and a temporary the frame computed. `rows[i].words` is neither: it is module
  storage, which lasts the whole run, so nothing outlives it and nothing needs to move.
- **Status:** Fixed in 0.1.1.
- **What skiff does:** `isolate_running` passes `maps[i].slots[0..<maps[i].len]` directly. The
  `val m = &maps[i]` form was dropped: for one use on one line it read no better.

## 10. An enum's bare variant is not found through the expected type when the enum is another module's

- **What was being written:** the PMSA region encoders (arch/pmsa), which answer
  `Result[Slot, RegionError]` where `RegionError` is the kernel's: `return Err(Empty)`.
- **Shortest input:** a library root `root/lib/m/m.sysl` and a program, `sysl run main.sysl --lib root`:

  ```sysl
  module lib.m

  enum Why
      Empty
      Full
  ```

  ```sysl
  import lib.m.Why

  annotated() -> Why
      val w: Why = Empty
      w

  returned() -> Why = Full

  main()
      print(annotated() == Why.Empty, returned() == Why.Full)
  ```

  ```
  error: undefined name 'Empty'
   --> main.sysl:4:18
  error: undefined name 'Full'
   --> main.sysl:7:21
  ```

  `return Err(Empty)` inside a function answering `Result[Slot, RegionError]` gives
  `error: undefined name 'skiff.arch.pmsa.Empty'`. Within the enum's own module the bare names work.
- **What the reference says:** types.md § "A variant belongs to its enum": "What a bare name means is
  settled where it is used, by the type expected there — an argument, an annotated binding, a `return`
  and a field all supply one", and "**The expected type reaches across modules too**".
- **Status:** Fixed in 0.1.1.
- **What skiff does:** arch/pmsa writes the bare variants, `Err(Empty)`.

## 11. An array literal passed where a slice is expected is heap-allocated even when the slice stays put

- **What was being written:** the boards' unprivileged-task scenarios, which name each task's grants
  and objects as literals: `kernel.spawn_unprivileged(port, stack, &entry, 4, "worker", regions,
  [h1, h2])`. On a freestanding target the image no longer links:

  ```
  ld.lld: error: undefined symbol: memcpy
  ld.lld: error: undefined symbol: memset
  ld.lld: error: undefined symbol: free
  ld.lld: error: undefined symbol: malloc
  ```

- **Shortest input**, `sysl build-c . --target thumbv7em-freestanding -o p.a`, then
  `arm-none-eabi-objdump -dr p.a`:

  ```sysl
  var g: usize = 3

  sum(xs: []const usize) -> usize
      var s: usize = 0
      for x in xs
          s += x
      s

  @export("probe_literal")
  probe_literal() -> usize = sum([g, g + 1])          // calls malloc

  @export("probe_named")
  probe_named() -> usize
      val xs: [2]usize = [g, g + 1]
      sum(xs)                                         // allocates nothing
  ```

  `probe_literal` calls `malloc`; `probe_named` does not. `sum` keeps nothing of `xs`.
- **What the reference says:** memory.md § "What happens when a slice escapes": a literal that must
  outlive the frame "costs an allocation there and **nothing at a call whose slice stays put**". And
  "Without an allocator it is always a compile error", not a call to a `malloc` the link cannot find.
- **Status:** Fixed in 0.1.1: `probe_literal` allocates nothing, and the images no longer reference
  `malloc` or `free`. (The `memcpy` and `memset` in the link errors above are a different matter: the
  standard library's `__aeabi_memcpy`/`__aeabi_memclr` call them, a structure copy reaches those, and
  ffi.md and types.md say a freestanding board supplies both. The boards now do.)
- **What skiff does:** the board scenarios and `tools/portable` pass their lists as literals, as
  written: `spawn_unprivileged(…, [code, shared], [to_echo, from_echo])`.

## 12. A module-level name private to one file stops a pattern binding that name in another

- **What was being written:** the software timers' host tests, whose timers were first named `a`, `b`,
  `c` at module level in `timer_tests.sysl`.
- **Shortest input** (`sysl test p2`, 0.1.1 candidate), a package with module `x.m` in two files:

  ```sysl
  module x.m                       // one.sysl

  pick(o: Option[u32]) -> u32 = o match
      Some(a) -> a
      None -> 0
  ```

  ```sysl
  module x.m                       // two.sysl

  private val a: u32 = 3

  three() -> u32 = a
  ```

  ```
  error: 'a' is a 'val', which is read while the program runs, so a bare name here would bind rather
  than match — write it as '`a`' to test the value it holds, or bind a different name
   --> one.sysl:4:10
  ```

  `one.sysl` cannot name that `a` at all: `four() -> u32 = a + 1` there is refused with "'x.m.a' is
  private to '…/two.sysl', the file that declares it". The same happens with a `private var a` in a
  `@tests` file, which the diagnostic also calls a 'val'. A `for b in xs` binding is not affected.
- **What the reference says:** modules.md § "A file-private name is scoped to its file": a bare
  `private` "restricts the namespace as well as the reach". The rule that a bare module `val` in a
  pattern is an error (modules.md, the `static val limit` example) is about a name the pattern's file
  can see; patterns.md says a bare name that is neither a nullary variant nor a constant binds. A name
  out of scope in `one.sysl` should leave `Some(a)` a binding.
- **Status:** open, reported for 0.1.1.
- **What skiff does:** the timer tests name their timers `ta`, `tb`, `tc`.
