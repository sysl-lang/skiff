#!/bin/sh
# skiff's boot test: build each board image and boot it on every machine it serves (QEMU, and benchtop
# for the Pico 2). A boot passes only if each console's output has its expected lines, in order, and the
# emulator exits with the expected status (the machine stops itself through semihosting). A hang is killed by PID after SKIFF_TIMEOUT
# seconds (QEMU ignores SIGALRM, so the watchdog kills it).
#
#   SKIFF_SYSL      the compiler (default: sysl)
#   SKIFF_OPT       passed to the build (e.g. -O0)
#   SKIFF_TIMEOUT   seconds per boot (default 10)
#   SKIFF_BENCHTOP  the benchtop emulator that boots the Pico 2 (default: ../benchtop/benchtop beside
#                   the repository)
#   SKIFF_BOARD_TIME  the Pico 2's boot limit in the board's own emulated time (default 300s: through the
#                   boot ROM the two cores' hammers alone take 90-120 s of it, a few seconds of wall time)

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${SKIFF_SYSL:-sysl}
opt=${SKIFF_OPT:-}
limit=${SKIFF_TIMEOUT:-10}
benchtop=${SKIFF_BENCHTOP:-$root/../benchtop/benchtop}
board_time=${SKIFF_BOARD_TIME:-300s}
scratch="$root/scratch"
mkdir -p "$scratch"

. "$root/scripts/expected.sh"

failed=0


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

# build <target> <board> <image> [<features>]. The standard library supplies the runtime helpers a freestanding link
# needs (the 64-bit divide, `__aeabi_mem*`, soft floating point), so nothing else is linked.
build() {
    if ! "$compiler" build $opt --target "$1" ${4:+--features "$4"} -o "$3" "$root/boards/$2"; then
        echo "FAIL: $2 ${4:-} did not build"
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
verdict mps2-an500 98
run "$scratch/mps2-an386.log" -M mps2-an386 -kernel "$m4_image"
check mps2-an386 "$scratch/mps2-an386.log" "$mps2_expected"
verdict mps2-an386 98

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
if [ -z "$missing" ]; then
    check_forwarded "mps2-an521" "$scratch/an521-core0.log"
fi
verdict mps2-an521 0

# The AN521 as two images: core 0's is the kernel QEMU starts, and core 1's is loaded beside it, where
# core 0 points core 1 when it releases it.
core0_image="$scratch/qemu-an521-core0.elf"
core1_image="$scratch/qemu-an521-core1.elf"
build thumb-freestanding-soft qemu-an521 "$core0_image" core0
build thumb-freestanding qemu-an521 "$core1_image" core1
rm -f "$scratch/an521-split-core1.log"
run "$scratch/an521-split-core0.log" -M mps2-an521 -accel tcg,thread=multi -kernel "$core0_image" \
    -device loader,file="$core1_image" -serial mon:stdio -serial file:"$scratch/an521-split-core1.log"
check "mps2-an521 two images, core 0" "$scratch/an521-split-core0.log" "$split_core0_expected"
if [ -z "$missing" ]; then
    check "mps2-an521 two images, core 1" "$scratch/an521-split-core1.log" "$split_core1_expected"
fi
if [ -z "$missing" ]; then
    check_forwarded "mps2-an521 two images" "$scratch/an521-split-core0.log"
fi
verdict "mps2-an521 two images" 0

# Two images that disagree: core 1's is built with one more field in `.shared` (the `skewed` feature).
# Each core says it stops at the handshake, before either creates a task, and core 0 stops the machine
# with status 3.
skewed_image="$scratch/qemu-an521-core1-skewed.elf"
build thumb-freestanding qemu-an521 "$skewed_image" core1,skewed
rm -f "$scratch/an521-skewed-core1.log"
run "$scratch/an521-skewed-core0.log" -M mps2-an521 -accel tcg,thread=multi -kernel "$core0_image" \
    -device loader,file="$skewed_image" -serial mon:stdio -serial file:"$scratch/an521-skewed-core1.log"
check "mps2-an521 two images that disagree, core 0" "$scratch/an521-skewed-core0.log" "skiff: hello from core 0
skiff: core 0 stops at the handshake: core 1's image lays out .shared otherwise"
if [ -z "$missing" ]; then
    check "mps2-an521 two images that disagree, core 1" "$scratch/an521-skewed-core1.log" "skiff: hello from core 1
skiff: core 1 stops at the handshake: core 0's image lays out .shared otherwise"
fi
if [ -z "$missing" ] && grep -q "tick 1" "$scratch/an521-skewed-core0.log" "$scratch/an521-skewed-core1.log"; then
    missing="mps2-an521 two images that disagree: a core ran on past the handshake"
fi
verdict "mps2-an521 two images that disagree" 3

# The Raspberry Pi Pico 2 on benchtop: the image built for the board itself, both of the RP2350's cores
# running it, each with an FPU, so core 0's floating-point tasks run too. It boots twice: once entered at
# the image's entry as a debug probe enters it, and once from reset through Raspberry Pi's boot ROM, which
# runs the image only for its IMAGE_DEF block. Either way core 1 waits in the ROM until core 0 launches
# it. `--deterministic` runs the cores in reproducible turns, and the limit is the board's own time, not
# the host's: benchtop ends a run that is not over by then with status 124. Core 0's console, UART0, is
# benchtop's output, and core 1's, UART1, goes to a file of its own. With `--semihosting` the image's
# SYS_EXIT_EXTENDED is benchtop's exit status, as QEMU's is. The run is the AN521's one image, with both
# cores' floating-point tasks, but for the sleep with the tick stopped: the board leaves tickless idle off.
pico2_image="$scratch/pico2.elf"
build thumb-freestanding pico2 "$pico2_image"
if [ ! -x "$benchtop" ]; then
    echo "FAIL pico2: no benchtop at $benchtop (set SKIFF_BENCHTOP)"
    failed=1
else
    for entry in debugger rom; do
        start=$(date +%s)
        rm -f "$scratch/pico2-$entry-core1.log"
        "$benchtop" run --board pico2 --boot "$entry" --deterministic --semihosting \
            --serial uart1=file:"$scratch/pico2-$entry-core1.log" --timeout "$board_time" "$pico2_image" \
            > "$scratch/pico2-$entry-core0.log" 2>&1 < /dev/null
        code=$?
        took=$(( $(date +%s) - start ))
        check "pico2 ($entry entry) core 0" "$scratch/pico2-$entry-core0.log" "$pico2_core0_expected"
        if [ -z "$missing" ]; then
            check "pico2 ($entry entry) core 1" "$scratch/pico2-$entry-core1.log" "$pico2_core1_expected"
        fi
        if [ -z "$missing" ]; then
            check_forwarded "pico2 ($entry entry)" "$scratch/pico2-$entry-core0.log"
        fi
        verdict "pico2 ($entry entry)" 0
    done
fi

exit $failed
