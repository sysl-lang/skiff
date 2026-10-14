#!/bin/sh
# skiff's boot test: build each QEMU board image and boot it on every machine it serves. A boot passes
# only if its output has the expected lines, in order, and QEMU exits with the expected status (the
# machine stops itself through semihosting). A hang is killed by PID after SKIFF_TIMEOUT seconds
# (QEMU ignores SIGALRM, so the watchdog kills it).
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

# The lines every boot must print, in this order. The tasks' lines are explained in
# boards/qemu-mps2/board/tasks.sysl. The run ends in a deliberate bus fault, so a boot that passes stops
# with the fault status (armv7m.FAULT_STATUS), and its report must name the fault and the address.
expected="skiff: hello
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
skiff: provoking a bus fault
skiff: fault BusFault
skiff: cfsr 0x00008200
skiff: bfar 0xf0000000"
expected_status=99

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
    elif [ "$code" -ne "$expected_status" ]; then
        echo "FAIL $machine: QEMU exited $code, not $expected_status (${took}s); log $log"
        failed=1
    else
        echo "PASS $machine (${took}s)"
    fi
}

# Arm GNU's libgcc for this core and float ABI, which the board links until the standard library
# supplies the 64-bit divide itself (FINDINGS 2).
libgcc=$(arm-none-eabi-gcc -mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16 -print-libgcc-file-name)
if [ ! -f "$libgcc" ]; then
    echo "FAIL: no Arm GNU libgcc (arm-none-eabi-gcc) for thumbv7em hard-float"
    exit 1
fi
SYSL_EXTRA_CFLAGS="-L$(dirname "$libgcc")"
export SYSL_EXTRA_CFLAGS

image="$scratch/qemu-mps2.elf"
if ! "$compiler" build $opt --target thumbv7em-freestanding -o "$image" "$root/boards/qemu-mps2"; then
    echo "FAIL: qemu-mps2 did not build"
    exit 1
fi
boot "$image" mps2-an500
boot "$image" mps2-an386

exit $failed
