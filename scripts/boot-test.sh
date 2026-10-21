#!/bin/sh
# skiff's boot test: build each QEMU board image and boot it on every machine it serves. A boot passes
# only if each console's output has its expected lines, in order, and QEMU exits with the expected
# status (the machine stops itself through semihosting). A hang is killed by PID after SKIFF_TIMEOUT
# seconds (QEMU ignores SIGALRM, so the watchdog kills it).
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

# What each console must print. The MPS2 boots are one core: it finds the kernel's shared state inside
# the link script's `.shared`, takes three ticks, finds the time base agreeing with its own count, then
# runs the scenarios' tasks (boards/scenarios): two equal tasks taking turns on the tick, two keeping
# their FPU registers across switches, a high-priority task running on the tick its sleep ends, and a
# stale handle refused. It ends through semihosting with status 0.
# tasks_expected <core> [<line the FPU tasks print>]: a build with no FPU registers has no such line.
tasks_expected() {
    echo "skiff: core $1 task A 1
skiff: core $1 task B 1
skiff: core $1 task A 2
skiff: core $1 task B 2
skiff: core $1 task A 3
skiff: core $1 task B 3"
    if [ -n "${2:-}" ]; then echo "skiff: core $1 $2"; fi
    echo "skiff: core $1 high priority task ran on the tick that woke it
skiff: core $1 refuses a stale handle"
}

# The waits every core runs (boards/scenarios, waits.sysl): a mutex's owner inheriting its waiter's
# priority and giving it up with the mutex, a timed take that times out, and an interrupt's give waking
# a waiting task at once.
waits_expected() {
    echo "skiff: core $1 the high task had the mutex before the middle task finished
skiff: core $1 the low task gave up its inherited priority with the mutex
skiff: core $1 a timed take timed out after 5 ticks
skiff: core $1 an interrupt's give woke a waiting task at once"
}
mps2_expected="skiff: hello
skiff: .shared holds the shared state
skiff: core 0 tick 1
skiff: core 0 tick 2
skiff: core 0 tick 3
skiff: core 0 time base agrees
$(tasks_expected 0 "f32 registers survived the switches")
$(waits_expected 0)"

# The AN521's two cores run one image, each greeting and ticking on the UART of its own number, then
# running its own tasks at once with the other. Core 0 has no FPU (the SSE-200's CPU0, in QEMU as on
# the FPGA image), and one image serves both cores, so the image is built with no FPU registers and
# neither core checks them; core 0 may not create a task on core 1 once
# it runs. Both cores then hammer one semaphore in `.shared` at once, and core 0 finds the count exact;
# core 0 gives units one at a time that core 1 takes without waiting. Core 1 then faults on purpose: it
# reports the fault on its own console and stops. Core 0 sees it stopped, takes more ticks, finds that
# the time base counted its own ticks and none of core 1's, and stops the machine with status 0.
an521_core0_expected="skiff: hello from core 0
skiff: .shared holds the shared state
skiff: core 0 tick 1
skiff: core 0 tick 2
skiff: core 0 tick 3
$(tasks_expected 0)
skiff: core 0 may not create a task on core 1, which runs
$(waits_expected 0)
skiff: core 0 two cores' gives and takes left the shared count exact
skiff: core 0 sees core 1 stopped
skiff: core 0 ticks on
skiff: core 0 time base agrees"
an521_core1_expected="skiff: hello from core 1
skiff: core 1 tick 1
skiff: core 1 tick 2
skiff: core 1 tick 3
$(tasks_expected 1)
$(waits_expected 1)
skiff: core 1 took every unit core 0 gave
skiff: core 1 fault BusFault"

failed=0

# check <label> <log> <expected>: every expected line must appear in the log after the one before it.
# Sets `missing` to the first that does not.
check() {
    after=0
    missing=""
    old_ifs=$IFS
    IFS='
'
    for want in $3; do
        at=$(grep -n -x -F -- "$want" "$2" | cut -d: -f1 | while read -r n; do
            if [ "$n" -gt "$after" ]; then echo "$n"; break; fi
        done)
        if [ -z "$at" ]; then
            missing="$1: \"$want\""
            break
        fi
        after=$at
    done
    IFS=$old_ifs
}

# run <log> <qemu arguments…>: boot once under the watchdog; sets `code` and `took`.
run() {
    log=$1
    shift
    start=$(date +%s)
    qemu-system-arm "$@" -nographic -semihosting-config enable=on,target=native > "$log" 2>&1 < /dev/null &
    qpid=$!
    ( sleep "$limit"; kill -9 "$qpid" 2> /dev/null ) &
    wpid=$!
    wait "$qpid"
    code=$?
    kill "$wpid" 2> /dev/null
    wait "$wpid" 2> /dev/null
    took=$(( $(date +%s) - start ))
}

# verdict <name> <expected status>: report the boot `run` and `check` just judged.
verdict() {
    if [ -n "$missing" ]; then
        echo "FAIL $1: missing $missing (exit $code, ${took}s); logs in $scratch"
        failed=1
    elif [ "$code" -ne "$2" ]; then
        echo "FAIL $1: QEMU exited $code, not $2 (${took}s); logs in $scratch"
        failed=1
    else
        echo "PASS $1 (${took}s)"
    fi
}

# build <target> <board> <image>. The standard library supplies the runtime helpers a freestanding link
# needs (the 64-bit divide, `__aeabi_mem*`, soft floating point), so nothing else is linked.
build() {
    if ! "$compiler" build $opt --target "$1" -o "$3" "$root/boards/$2"; then
        echo "FAIL: $2 did not build"
        exit 1
    fi
}

# The MPS2: the same program built for each core's FPU, the M7's double-precision fpv5-d16 on the AN500
# and the M4's single-precision fpv4-sp-d16 on the AN386.
m7_image="$scratch/qemu-mps2-m7.elf"
m4_image="$scratch/qemu-mps2-m4.elf"
build thumbv7em-freestanding-dp qemu-mps2 "$m7_image"
build thumbv7em-freestanding qemu-mps2 "$m4_image"
run "$scratch/mps2-an500.log" -M mps2-an500 -kernel "$m7_image"
check mps2-an500 "$scratch/mps2-an500.log" "$mps2_expected"
verdict mps2-an500 0
run "$scratch/mps2-an386.log" -M mps2-an386 -kernel "$m4_image"
check mps2-an386 "$scratch/mps2-an386.log" "$mps2_expected"
verdict mps2-an386 0

# The AN521: one image run by both cores, under multi-threaded TCG so that the cores really run at once.
# Core 0's console, UART0, is QEMU's stdio; core 1's, UART1, goes to a file of its own.
image="$scratch/qemu-an521.elf"
build thumb-freestanding-soft qemu-an521 "$image"
rm -f "$scratch/an521-core1.log"
run "$scratch/an521-core0.log" -M mps2-an521 -accel tcg,thread=multi -kernel "$image" \
    -serial mon:stdio -serial file:"$scratch/an521-core1.log"
check "mps2-an521 core 0" "$scratch/an521-core0.log" "$an521_core0_expected"
if [ -z "$missing" ]; then
    check "mps2-an521 core 1" "$scratch/an521-core1.log" "$an521_core1_expected"
fi
verdict mps2-an521 0

exit $failed
