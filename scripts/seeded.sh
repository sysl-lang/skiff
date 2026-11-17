#!/bin/sh
# Seeded boots: the Pico 2 image (debugger entry) booted on benchtop under many seeds and fault-injection
# mixes, to shake out races that the one fixed interleaving of boot-test.sh never visits. Each run is held
# to the boot test's expected lines (scripts/expected.sh) and to exit status 0, and benchtop's `--seed`
# makes a failure recur: the command line printed for a failed seed reproduces it exactly.
#
#   seeded.sh [N [FIRST]]   N runs (default 10), run i using seed FIRST+i (default 1) and knob mix i mod 6
#
#   SKIFF_SYSL      the compiler (default: sysl)
#   SKIFF_OPT       passed to the build (e.g. -O0)
#   SKIFF_BENCHTOP  the benchtop binary (default: ../benchtop/benchtop beside the repository)
#   SKIFF_PICO2_IMAGE  a Pico 2 image already built (default: built into scratch/pico2-seeded.elf)
#   SKIFF_BOARD_TIME  the board's own time limit per run (default 300s)
#   SKIFF_WALL      seconds of wall time before a run is killed as a HANG (default 120)
#   SKIFF_JOBS      runs in flight at once (default 1)
#   SKIFF_MIX       run only the mix with this number (0-5)
#
# The mixes (cycles are the core's clock; a tick is 100 Hz of 150 MHz, so 2000 is a small slip):
#   0  seed only                      3  --late-irq 2000
#   1  --late-systick 2000            4  --strex-fail 5
#   2  --bunch-systick 3 --late-systick 2000   5  all four together

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${SKIFF_SYSL:-sysl}
opt=${SKIFF_OPT:-}
benchtop=${SKIFF_BENCHTOP:-$root/../benchtop/benchtop}
board_time=${SKIFF_BOARD_TIME:-300s}
wall=${SKIFF_WALL:-120}
jobs=${SKIFF_JOBS:-1}
count=${1:-10}
first=${2:-1}
scratch="$root/scratch/seeded"
mkdir -p "$scratch"
. "$root/scripts/expected.sh"

mix_options() {
    case $1 in
        0) echo "" ;;
        1) echo "--late-systick 2000" ;;
        2) echo "--bunch-systick 3 --late-systick 2000" ;;
        3) echo "--late-irq 2000" ;;
        4) echo "--strex-fail 5" ;;
        5) echo "--late-systick 2000 --bunch-systick 3 --late-irq 2000 --strex-fail 5" ;;
    esac
}

if [ ! -x "$benchtop" ]; then
    echo "FAIL seeded: no benchtop at $benchtop (set SKIFF_BENCHTOP)"
    exit 1
fi
image=${SKIFF_PICO2_IMAGE:-}
if [ -z "$image" ]; then
    image="$root/scratch/pico2-seeded.elf"
    if ! "$compiler" build $opt --target thumb-freestanding -o "$image" "$root/boards/pico2"; then
        echo "FAIL seeded: boards/pico2 did not build"
        exit 1
    fi
fi

# one <index>: boot once; writes the verdict to $scratch/<seed>.result (PASS line, or the failure's lines).
one() {
    seed=$(( first + $1 ))
    mix=${SKIFF_MIX:-$(( $1 % 6 ))}
    knobs=$(mix_options "$mix")
    core0="$scratch/$seed-core0.log"
    core1="$scratch/$seed-core1.log"
    report="$scratch/$seed-report.json"
    result="$scratch/$seed.result"
    rm -f "$core1" "$report"
    cmd="$benchtop run --board pico2 --boot debugger --seed $seed ${knobs:+$knobs }--semihosting --serial uart1=file:$core1 --timeout $board_time --report $report $image"
    start=$(date +%s)
    $cmd > "$core0" 2>&1 < /dev/null &
    bpid=$!
    ( sleep "$wall"; kill -9 "$bpid" 2> /dev/null && echo hung > "$scratch/$seed.hung" ) &
    wpid=$!
    rm -f "$scratch/$seed.hung"
    wait "$bpid"
    code=$?
    kill "$wpid" 2> /dev/null
    wait "$wpid" 2> /dev/null
    took=$(( $(date +%s) - start ))
    check "core 0" "$core0" "$pico2_core0_expected"
    if [ -z "$missing" ]; then
        check "core 1" "$core1" "$pico2_core1_expected"
    fi
    if [ -f "$scratch/$seed.hung" ]; then
        why="HANG: killed after ${wall}s of wall time"
    elif [ -n "$missing" ]; then
        why="missing $missing (exit $code)"
    elif [ "$code" -ne 0 ]; then
        why="exit $code, not 0"
    else
        echo "PASS seed $seed mix $mix (${took}s)" > "$result"
        return
    fi
    {
        echo "FAIL seed $seed mix $mix (${took}s): $why"
        echo "  command: $cmd"
        if [ -f "$report" ]; then
            echo "  report: $(grep -o '"exit":"[^"]*"' "$report" | head -1) $(grep -o '"status":[0-9]*' "$report" | head -1) $(grep -o '"message":"[^"]*"' "$report" | head -1)"
            fault=$(grep -o '"fault":.*' "$report" | cut -c1-600)
            if [ -n "$fault" ]; then echo "  fault: $fault"; fi
        else
            echo "  report: none written"
        fi
        echo "  logs: $core0 $core1"
    } > "$result"
}

failed=0
total_start=$(date +%s)
i=0
while [ "$i" -lt "$count" ]; do
    batch_start=$i
    while [ "$i" -lt "$count" ] && [ $(( i - batch_start )) -lt "$jobs" ]; do
        one "$i" &
        i=$(( i + 1 ))
    done
    wait
    j=$batch_start
    while [ "$j" -lt "$i" ]; do
        r="$scratch/$(( first + j )).result"
        if [ -f "$r" ]; then
            cat "$r"
            if ! grep -q '^PASS' "$r"; then failed=1; fi
        else
            echo "FAIL seed $(( first + j )): no verdict written"
            failed=1
        fi
        j=$(( j + 1 ))
    done
done
echo "seeded: $count runs from seed $first in $(( $(date +%s) - total_start ))s"
if [ "$failed" -eq 0 ]; then echo "seeded: all passed"; fi
exit $failed
