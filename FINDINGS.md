# skiff — findings

Places where sysl could not express what skiff needs. Each is fixed in sysl, never worked around here.

## FINDINGS 1 — a call with an explicit type argument is never a constant expression

`const one[T]() -> int = 1` then `const X = one[int]()` is refused ("the value of 'X' is not a constant
expression"), and so is the same call in an array length or an `@assert`. With the type inferred from an
argument the call is accepted. skiff needs it for the layout fingerprint two images compare at boot
(`fingerprint[Shared]()` over `Shared::Fields`), which has no argument to infer from.

Status: fixed in sysl 0.3.7.

## FINDINGS 2 — a consumer cannot set a value in a library

A library's capacities (the task table, queue lengths, a map's size, the number of cores) were fixed by
the library for every consumer: features are names, and `#if` reads only the target.

Status: fixed in sysl 0.3.7 by valued `options` (declared in the library's manifest with a type and a
default, set in the consumer's dependency entry, read as `const option_<name>`; the root's value wins).

## FINDINGS 3 — an unknown key inside a `targets` block is ignored silently

`targets { thumb-freestanding { linker_scrpt = "m4.ld" } }` builds with no warning, and the image is laid
out by the linker's defaults. A top-level unknown key is reported, as the packages reference says every
unknown key is.

Status: fixed in sysl 0.3.7; such a key is now warned about.

## FINDINGS 4 — a link script cannot differ by feature

`linker_script` is keyed only by target. The two-image build is one board program built once per image
(`--features split,m7`, `--features split,m4`), and each image needs its own layout; on the AN521 both
images share one target, so nothing can choose between the scripts. `--features m4` still links with the
target's one script.

Status: fixed in sysl 0.3.7. The spelling is a `features` block inside the target, provisional until
0.4.0's manifest syntax pass:
`thumb-freestanding { linker_script = "one.ld", features { m4 { linker_script = "m4.ld" } } }`. An enabled
feature's entry overrides the target's keys; two enabled features setting one key are refused; an
undeclared feature is refused. An OS is one program, never one workspace member per image.

## FINDINGS 5 — an `if` is never a constant expression

`const A = if N > 1 then N else 0` is refused ("the value of 'A' is not a constant expression"), and so is
the same `if` in an array length or an `@assert`. The same `if` as the body of a `const` function folds. The
inbox array is sized `option_cores` when there is more than one core and 0 otherwise.

Status: fixed in sysl 0.3.8 (`if`, `elif` and `match` over constants are constant); `INBOX_CORES` is the
`if` itself.

## FINDINGS 6 — a `const` member of a plain struct is never constant data on a freestanding target

```sysl
struct S
    n: u32
    const new(n: u32) -> S = S(n)

struct G[X]
    n: X
    const new(n: X) -> G[X] = G(n)

const mk(n: u32) -> S = S(n)

private var d: S = S.new(3)
private var f: G[u32] = G.new(3)
private var h: S = mk(3)

@export("main")
probe() -> i32 = i32(d.n + f.n + h.n)
```

`sysl build-c main.sysl --target thumbv7em-freestanding` refuses `d` alone: "'probe' is exported and reaches
'd', which is module storage an initializer fills before the program's own statements run. This artifact
has no entry point to fill it in…". `G.new` (a generic type's `const` member) and `mk` (a free `const`
function) fold to data; `S.new`, the same body as a member of a non-generic struct, does not, whether it is
declared in the struct or in an `impl`. `sysl.sync.Guarded.new` is documented as "`new` is `const`, so a
module table of them filled by `Guarded.new` calls is constant data even on a freestanding target", which
is the behaviour `S.new` should have. skiff does not depend on it: a kernel object (`Semaphore.new`,
`Mutex.new`) is filled in at run time, which an object in `.shared` needs anyway since start-up zeroes the
section. The workaround would have been free functions (`semaphore(name, count, max)`) in place of `new`.

Status: fixed in sysl 0.3.9. The scenarios' per-core objects are now constant data.

## FINDINGS 7 — a simple enum with a variant at 0 has no zero value

```sysl
enum Outcome: u8
    Idle = 0
    Waiting = 1

struct W
    o: Outcome

var w: W
```

is refused: "W has no zero value, so 'w' needs an initial value". The modules reference says an enum has no
zero "since a zeroed tag names no variant in particular", but this enum's zeroed tag names `Idle`. skiff's
`.shared` structure holds an `Outcome` per task, and the section is zeroed at start-up rather than loaded,
so its declaration now carries an initializer that is all zeros, spelled out
(`kernel/skiff/kernel/shared.sysl`). That is ordinary code rather than a contortion, but it repeats the
zero the section already holds. Whether an enum with a variant at 0 should zero to it is a design
question for sysl.

Status: fixed in sysl 0.3.9: an enum with an explicit field-less `= 0` variant zeroes to it. `Shared` takes
its zero value.

## FINDINGS 8 — a generic type's static member, reached through its module, is an undefined name

```sysl
module pk.m

struct Q[T, const N: usize]
    slots: [N]T

impl[T, const N: usize] Q[T, N]
    const new() -> Q[T, N]
        var s: [N]T
        Q(s)
```

```sysl
import pk.m

private var b: m.Q[u32, 2] = m.Q.new()
```

is refused with "undefined name 'm'" at the `m` of `m.Q.new()` (sysl 0.3.11), at module level and in a
function body alike. The type in the annotation resolves, and so do `m.Q[u32, 2].new()`, `Q.new()` after
`import pk.m.Q`, and `m.S.new()` for a plain struct `S`: only a generic type named through its module, with
its arguments left to the expected type, fails, and the diagnostic names the module rather than what went
wrong. skiff's `tools/portable` hit it with `kernel.Queue.new("mail")`. Importing `Queue` by name is the
ordinary spelling and is what skiff uses, so nothing here is contorted.

Status: open; reported to sysl.
