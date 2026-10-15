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

# The lines every MPS2 boot must print, in this order. The tasks' lines are explained in
# boards/qemu-mps2/board/tasks.sysl. The run ends in a deliberate bus fault, so a boot that passes stops
# with the fault status (armv7m.FAULT_STATUS), and its report must name the fault and the address.
mps2_expected="skiff: hello
skiff: tick 1
skiff: tick 2
skiff: tick 3
skiff: interrupt from timer 0
skiff: f64 arithmetic kept 2^-39
skiff: task A 1
skiff: task B 1
skiff: task A 2
skiff: task B 2
skiff: task A 3
skiff: task B 3
skiff: f32 registers survived the switches
skiff: high priority task woke on its tick
skiff: the high task had the mutex before the middle task finished
skiff: a timed wait timed out after 5 ticks
skiff: timer 0's interrupt woke a waiting task
skiff: a queue of two carried 1 to 5 in order
skiff: event flags woke the task on both bits
skiff: an interrupt's notifications woke the counting task at once, 5 times
skiff: the counting task took every notification once
skiff: notified bits woke a task, and its next wait timed out after 5 ticks
skiff: a pending notification was not overwritten
skiff: an interrupt streamed 20 bytes to a task, 4 at a time in order, waking it at once
skiff: 40 framed messages arrived whole and in order across the ring's end
skiff: a receive buffer too short for a message left it whole
skiff: a give by a task not holding the recursive mutex was refused
skiff: a timed take of a held recursive mutex timed out after 2 ticks
skiff: a recursive mutex held 3 deep went to the waiter on the third give, before the busy task finished
skiff: a suspended task did not run for 5 ticks, and ran again once resumed
skiff: an interrupt resumed a task that suspended itself at once, 3 times
skiff: a lowered priority kept the inherited boost, and the lowered task yielded at once
skiff: a stopped waiter left its wait list, a task stopped itself, and a new task took a stopped task's row
skiff: a task spinning for 3 of 6 ticks was charged its share, and idle the rest
skiff: a task recursing 8 deep lowered its stack high-water mark by its frames
skiff: a reload timer fired every 3 ticks, and a late call did not move the ticks after it
skiff: a one-shot timer fired once, and a timer stopped before its expiry never fired
skiff: a timer started from an interrupt was active at once and fired 2 ticks later
skiff: every timer callback ran in the timer service
skiff: task deep overflowed its stack
skiff: task null broke its memory protection
skiff: mmfar 0x00000000
skiff: a pool of four came back whole after 400 allocations
skiff: a heap carved six ways came back whole
skiff: both faulting tasks were stopped, and the rest ran on
skiff: provoking a bus fault
skiff: fault BusFault
skiff: cfsr 0x00008200
skiff: bfar 0xf0000000"

# The AN521's two cores, each on its own console (boards/qemu-an521/skiff/board/pair/board.sysl). Core 0
# stops the machine with status 0 once both have received everything.
an521_core0_expected="skiff: hello
skiff: tick 3
skiff: task deep overflowed its stack
skiff: core 0 received 10000 of 10000 messages in order
skiff: core 1 finished"
an521_core1_expected="skiff: hello
skiff: tick 3
skiff: task deep overflowed its stack
skiff: core 1 received 10000 of 10000 messages in order"

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
# and the M4's single-precision fpv4-sp-d16 on the AN386. Each ends in the bus fault, status 99.
m7_image="$scratch/qemu-mps2-m7.elf"
m4_image="$scratch/qemu-mps2-m4.elf"
build thumbv7em-freestanding-dp qemu-mps2 "$m7_image"
build thumbv7em-freestanding qemu-mps2 "$m4_image"
run "$scratch/mps2-an500.log" -M mps2-an500 -kernel "$m7_image"
check mps2-an500 "$scratch/mps2-an500.log" "$mps2_expected"
verdict mps2-an500 99
run "$scratch/mps2-an386.log" -M mps2-an386 -kernel "$m4_image"
check mps2-an386 "$scratch/mps2-an386.log" "$mps2_expected"
verdict mps2-an386 99

# The AN521: an image per core, under multi-threaded TCG so that the cores really run at once. Core 1's
# image is loaded beside core 0's, and its console, UART1, goes to a file of its own.
core0="$scratch/an521-core0.elf"
core1="$scratch/an521-core1.elf"
build thumb-freestanding qemu-an521-core0 "$core0"
build thumb-freestanding qemu-an521-core1 "$core1"
rm -f "$scratch/an521-core1.log"
run "$scratch/an521-core0.log" -M mps2-an521 -accel tcg,thread=multi -kernel "$core0" \
    -device loader,file="$core1" -serial mon:stdio -serial file:"$scratch/an521-core1.log"
check "mps2-an521 core 0" "$scratch/an521-core0.log" "$an521_core0_expected"
if [ -z "$missing" ]; then
    check "mps2-an521 core 1" "$scratch/an521-core1.log" "$an521_core1_expected"
fi
verdict mps2-an521 0

exit $failed
