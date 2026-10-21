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
