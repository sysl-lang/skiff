#!/bin/sh
# skiff's gate, run before every merge to dev:
#
#   1. the kernel's tests on the host, which work only because the kernel has no hardware in it: its own,
#      with one core, and skiff.cores, which builds the kernel for three and plays each core in turn;
#      then the MPU region encodings (arch/pmsa), which are arithmetic;
#   2. the kernel built for every CPU family skiff may ever run on, ported or not, through
#      tools/portable, which instantiates its generic parts: anything chip- or architecture-specific in
#      kernel/ fails here on the first target that cannot have it;
#   3. the boot test, at the default optimisation and at -O0.

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${SKIFF_SYSL:-sysl}
failed=0

step() {
    echo "== $*"
    if ! "$@"; then
        echo "FAIL: $*"
        failed=1
    fi
}

step "$compiler" test "$root/kernel" --filter skiff.kernel
step "$compiler" test "$root/kernel" --option cores=3 --filter skiff.cores
step "$compiler" test "$root/arch/pmsa"
mkdir -p "$root/scratch"
for target in thumbv6m-freestanding thumbv7em-freestanding thumb-freestanding riscv32-freestanding; do
    step "$compiler" build-c "$root/tools/portable" --target "$target" -o "$root/scratch/portable-$target.a"
done
step "$root/scripts/boot-test.sh"
step env SKIFF_OPT=-O0 "$root/scripts/boot-test.sh"

if [ "$failed" -eq 0 ]; then echo "GATE: green"; else echo "GATE: red"; fi
exit $failed
