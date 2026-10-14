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
skiff: core 0 received 10000 of 10000 messages in order
skiff: core 1 finished"
an521_core1_expected="skiff: hello
skiff: tick 3
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

# build <target> <board> <image>, with Arm GNU's libgcc for that target's core and float ABI on the
# link path: the boards link it until the standard library supplies the 64-bit divide (FINDINGS 2).
build() {
    libgcc=$(arm-none-eabi-gcc $4 -mthumb -mfloat-abi=hard -print-libgcc-file-name)
    if [ ! -f "$libgcc" ]; then
        echo "FAIL: no Arm GNU libgcc (arm-none-eabi-gcc) for $1"
        exit 1
    fi
    if ! env SYSL_EXTRA_CFLAGS="-L$(dirname "$libgcc")" "$compiler" build $opt --target "$1" -o "$3" "$root/boards/$2"; then
        echo "FAIL: $2 did not build"
        exit 1
    fi
}

# The MPS2: one image, on the M7 and on the M4. It ends in the bus fault, status 99.
image="$scratch/qemu-mps2.elf"
build thumbv7em-freestanding qemu-mps2 "$image" "-mcpu=cortex-m4 -mfpu=fpv4-sp-d16"
for machine in mps2-an500 mps2-an386; do
    run "$scratch/$machine.log" -M "$machine" -kernel "$image"
    check "$machine" "$scratch/$machine.log" "$mps2_expected"
    verdict "$machine" 99
done

# The AN521: an image per core, under multi-threaded TCG so that the cores really run at once. Core 1's
# image is loaded beside core 0's, and its console, UART1, goes to a file of its own.
core0="$scratch/an521-core0.elf"
core1="$scratch/an521-core1.elf"
build thumb-freestanding qemu-an521-core0 "$core0" "-mcpu=cortex-m33 -mfpu=fpv5-sp-d16"
build thumb-freestanding qemu-an521-core1 "$core1" "-mcpu=cortex-m33 -mfpu=fpv5-sp-d16"
rm -f "$scratch/an521-core1.log"
run "$scratch/an521-core0.log" -M mps2-an521 -accel tcg,thread=multi -kernel "$core0" \
    -device loader,file="$core1" -serial mon:stdio -serial file:"$scratch/an521-core1.log"
check "mps2-an521 core 0" "$scratch/an521-core0.log" "$an521_core0_expected"
if [ -z "$missing" ]; then
    check "mps2-an521 core 1" "$scratch/an521-core1.log" "$an521_core1_expected"
fi
verdict mps2-an521 0

exit $failed
