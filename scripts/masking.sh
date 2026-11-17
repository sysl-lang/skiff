#!/bin/sh
# skiff's bound on masked time, measured: the Pico 2 image boots on benchtop with its masking report
# (benchtop's README, "The masking report"), and each core's report is held to the bounds below. The boot
# is the boot test's pico2 run entered as a debugger enters it, at the default optimisation (the bounds
# are for the code that ships; -O0 holds longer). The ROM entry adds nothing here: the same kernel code
# runs the same scenarios, and its numbers differ from the debugger entry's only by the interleaving.
# `--deterministic` makes the numbers the same on every run. Cycles are benchtop's `timing=unit`, one per
# instruction executed.
#
#   SKIFF_SYSL       the compiler (default: sysl)
#   SKIFF_BENCHTOP   the benchtop emulator (default: ../benchtop/benchtop beside the repository)
#   SKIFF_ADDR2LINE  what names the function at an address (default: arm-none-eabi-addr2line)
#
# What is bounded, per core:
#
#   - The longest masked interval the kernel makes, from the instruction that masked to the one that
#     unmasked, the chip lock's ticket wait inside it. Measured on dev 8b41e89: core 0 1360, core 1 1524.
#     What dominates: a StreamBuffer[64] or MessageBuffer[64] send or receive copying up to 64 bytes
#     under its object's lock (stream.sysl `fill`/`drain`, a loop per byte), behind the other core's hold
#     of the same lock (the scenarios pour 3000 bytes and 200 messages between the cores, both blocking).
#     Next come `add_task` (~1146: `free_slot`, `set_map`, the first frame and the note's renewal) and a
#     semaphore's give behind the other core's hammer (~1114). The bound leaves about 30% over the worst.
#   - How many masked intervals reach 1024 cycles: measured 1573 on core 0, 158 on core 1, of ~667,000
#     each. Almost every hold is under 1024 (the hammers' 267,000 gives and takes per core, behind each
#     other's, are 512-1023; the ~2,800 ticks and ~10,000 switches are shorter). A path the boot takes
#     often that grows past 1024 cycles, as a scan over the tasks or the waiters would make it, moves
#     thousands of intervals past it, though its longest may stay under the first bound.
#   - The worst latency of the interrupts at the kernel's priority (KERNEL_IRQ_PRIORITY, below the mask):
#     the doorbell (irq26) and the software-raised interrupt (irq46). Such an interrupt waits for the
#     masked remainder and for any handler above it, so its bound is the masked one. Measured: irq26 214
#     on core 0, 206 on core 1; irq46 2 on each.
#
# Not bounded, reported: SysTick's and PendSV's latencies. They sit at the lowest priority, so they wait
# for every other handler's whole run, not for a mask: on both cores the scenarios' deliberate task
# faults report on the console from a fault handler (~56,000-64,000 cycles), and on core 0 the time
# scenario's own mask (below) holds the tick off ~500,000.
#
# Left out of the bound: the one interval a scenario masks on purpose, core 0's in `time_alone`
# (boards/scenarios/.../time.sysl), which masks its core while core 1 keeps the time base (~621,000
# cycles). Only an interval that both begins and ends in that function is left out, and it is named.

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${SKIFF_SYSL:-sysl}
benchtop=${SKIFF_BENCHTOP:-$root/../benchtop/benchtop}
addr2line=${SKIFF_ADDR2LINE:-arm-none-eabi-addr2line}
scratch="$root/scratch"
mkdir -p "$scratch"

masked_bound=2000
tail_from=1024
tail_bound=2500
irq_bound=$masked_bound
irqs="irq26 irq46"
deliberate='scenarios$time_alone.'

image="$scratch/pico2-masking.elf"
report="$scratch/pico2-masking.txt"
failed=0

fail() {
    echo "FAIL masking: $*"
    failed=1
}

if [ ! -x "$benchtop" ]; then
    echo "FAIL masking: no benchtop at $benchtop (set SKIFF_BENCHTOP)"
    exit 1
fi
if ! command -v "$addr2line" > /dev/null 2>&1; then
    echo "FAIL masking: no $addr2line to name the intervals' functions (set SKIFF_ADDR2LINE)"
    exit 1
fi
if ! "$compiler" build --target thumb-freestanding -o "$image" "$root/boards/pico2"; then
    echo "FAIL masking: pico2 did not build"
    exit 1
fi
rm -f "$report"
"$benchtop" run --board pico2 --boot debugger --deterministic --semihosting \
    --serial uart1=file:"$scratch/pico2-masking-core1.log" --timeout 300s --report-masking "$report" \
    "$image" > "$scratch/pico2-masking-core0.log" 2>&1 < /dev/null
code=$?
if [ "$code" -ne 0 ]; then
    fail "the boot exited $code, not 0, so the report covers only part of it; logs in $scratch"
fi
if [ ! -s "$report" ]; then
    echo "FAIL masking: benchtop wrote no report at $report"
    exit 1
fi

# field <line> <key>: the value of `key=` in a report line.
field() {
    echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"
}

# function_at <address>: the function holding it, or the address itself where none does.
function_at() {
    case "$1" in
        0x*) name=$("$addr2line" -f -e "$image" "$1" | head -1) ;;
        *) name="" ;;
    esac
    if [ -z "$name" ] || [ "$name" = "??" ]; then echo "$1"; else echo "$name"; fi
}

for core in 0 1; do
    summary=$(grep -E "^masking core=$core timing=" "$report")
    if [ -z "$summary" ]; then
        fail "core $core: no summary line in $report"
        continue
    fi
    echo "masking core $core: $(field "$summary" intervals) intervals, $(field "$summary" masked) of $(field "$summary" cycles) cycles masked"

    # The longest interval the kernel makes: the first of the ranked eight not left out.
    longest=""
    left_out_tail=0
    ranks=$(grep -E "^masking core=$core rank=" "$report")
    old_ifs=$IFS
    IFS='
'
    for line in $ranks; do
        cycles=$(field "$line" cycles)
        from=$(function_at "$(field "$line" from)")
        to=$(function_at "$(field "$line" to)")
        case "$from" in *"$deliberate"*)
            case "$to" in *"$deliberate"*)
                echo "  left out: $cycles cycles in $from, the time scenario's own mask"
                if [ "$cycles" -ge "$tail_from" ]; then left_out_tail=$((left_out_tail + 1)); fi
                continue ;;
            esac ;;
        esac
        longest=$cycles
        where="$from -> $to"
        break
    done
    IFS=$old_ifs
    if [ -z "$longest" ]; then
        fail "core $core: every ranked interval was left out, so the kernel's longest is not known"
    elif [ "$longest" -gt "$masked_bound" ]; then
        fail "core $core: the kernel masked for $longest cycles, over the bound of $masked_bound ($where)"
    else
        echo "  longest kernel interval: $longest cycles (bound $masked_bound), $where"
    fi

    # Intervals of `tail_from` cycles or more, from the histogram's buckets.
    tail=$(grep -E "^masking core=$core bucket=" "$report" | sed 's/.*bucket=\([0-9]*\)-[0-9]* count=\([0-9]*\)/\1 \2/' |
        awk -v from="$tail_from" '$1 >= from { n += $2 } END { print n + 0 }')
    tail=$((tail - left_out_tail))
    if [ "$tail" -gt "$tail_bound" ]; then
        fail "core $core: $tail intervals of $tail_from cycles or more, over the bound of $tail_bound"
    else
        echo "  intervals of $tail_from cycles or more: $tail (bound $tail_bound)"
    fi

    for irq in $irqs; do
        line=$(grep -E "^latency core=$core exception=$irq taken=" "$report")
        if [ -z "$line" ]; then
            fail "core $core: $irq was never taken, so its latency was not measured"
            continue
        fi
        worst=$(field "$line" max)
        if [ "$worst" -gt "$irq_bound" ]; then
            fail "core $core: $irq waited $worst cycles, over the bound of $irq_bound"
        else
            echo "  $irq latency: worst $worst cycles of $(field "$line" taken) (bound $irq_bound)"
        fi
    done
    for exception in systick pendsv; do
        line=$(grep -E "^latency core=$core exception=$exception taken=" "$report")
        if [ -n "$line" ]; then echo "  $exception latency: worst $(field "$line" max), mean $(field "$line" mean) (not bounded)"; fi
    done
done

if [ "$failed" -eq 0 ]; then echo "PASS masking"; fi
exit $failed
