#!/bin/sh
# skiff's boot test: build each QEMU board image and boot it on every machine it serves. A boot passes
# only if its output has the expected lines, in order, and QEMU exits with status 0 (the machine
# stopped through semihosting with success). A fault stops it with 99; a hang is killed by PID after
# SKIFF_TIMEOUT seconds (QEMU ignores SIGALRM, so the watchdog kills it).
#
#   SKIFF_SYSL      the compiler (default: sysl)
#   SKIFF_OPT       passed to the build (e.g. -O0)
#   SKIFF_TIMEOUT   seconds per boot (default 10)

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${SKIFF_SYSL:-sysl}
opt=${SKIFF_OPT:-}
limit=${SKIFF_TIMEOUT:-10}
scratch="$root/scratch"
mkdir -p "$scratch"

# The lines every boot must print, in this order.
expected="skiff: hello"

failed=0

# boot <image> <machine>: boot once and check the transcript.
boot() {
    image=$1
    machine=$2
    log="$scratch/$machine.log"
    start=$(date +%s)
    qemu-system-arm -M "$machine" -nographic -semihosting-config enable=on,target=native \
        -kernel "$image" > "$log" 2>&1 < /dev/null &
    qpid=$!
    ( sleep "$limit"; kill -9 "$qpid" 2> /dev/null ) &
    wpid=$!
    wait "$qpid"
    code=$?
    kill "$wpid" 2> /dev/null
    wait "$wpid" 2> /dev/null
    took=$(( $(date +%s) - start ))

    # Every expected line must appear after the one before it.
    after=0
    missing=""
    old_ifs=$IFS
    IFS='
'
    for want in $expected; do
        at=$(grep -n -x -F -- "$want" "$log" | cut -d: -f1 | while read -r n; do
            if [ "$n" -gt "$after" ]; then echo "$n"; break; fi
        done)
        if [ -z "$at" ]; then
            missing=$want
            break
        fi
        after=$at
    done
    IFS=$old_ifs

    if [ -n "$missing" ]; then
        echo "FAIL $machine: missing \"$missing\" (exit $code, ${took}s); log $log"
        failed=1
    elif [ "$code" -ne 0 ]; then
        echo "FAIL $machine: QEMU exited $code (${took}s); log $log"
        failed=1
    else
        echo "PASS $machine (${took}s)"
    fi
}

image="$scratch/qemu-mps2.elf"
if ! "$compiler" build $opt --target thumbv7em-freestanding -o "$image" "$root/boards/qemu-mps2"; then
    echo "FAIL: qemu-mps2 did not build"
    exit 1
fi
boot "$image" mps2-an500
boot "$image" mps2-an386

exit $failed
