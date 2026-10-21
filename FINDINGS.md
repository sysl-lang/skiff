# skiff — findings

Places where sysl could not express what skiff needs. Each is fixed in sysl, never worked around here.

## FINDINGS 1 — a call with an explicit type argument is never a constant expression

`const one[T]() -> int = 1` then `const X = one[int]()` is refused ("the value of 'X' is not a constant
expression"), and so is the same call in an array length or an `@assert`. With the type inferred from an
argument the call is accepted. skiff needs it for the layout fingerprint two images compare at boot
(`fingerprint[Shared]()` over `Shared::Fields`), which has no argument to infer from.

Status: accepted by `sysl` as a bug; ships in 0.3.7.

## FINDINGS 2 — a consumer cannot set a value in a library

A library's capacities (the task table, queue lengths, a map's size, the number of cores) were fixed by
the library for every consumer: features are names, and `#if` reads only the target.

Status: accepted; 0.3.7 ships valued `options` (declared in the library's manifest with a type and a
default, set in the consumer's dependency entry, read as `const option_<name>`; the root's value wins).
