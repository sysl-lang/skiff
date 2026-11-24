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
#     unmasked, the chip lock's ticket wait inside it. Measured on dev b642345 + streamcopy: 1257 on
#     core 0 (a MessageBuffer[64] send behind the other core's hold of its lock) and 1158 on core 1 (a
#     StreamBuffer[64] receive) under sysl 0.13.5, 1251 and 1206 under 0.11.12. Almost every long hold
#     opens at `Locking.acquire`: the object lock's own constant work plus the wait for the other core's
#     hold of the same lock, so its length moves with the interleaving by tens of cycles from one build
#     to the next. The bound is about 20% over the worst; what catches a hold that grows is the next two
#     checks, by its site.
#   - Every site (benchtop's `--masking-sites`: a pair of the instruction that masked and the one that
#     unmasked) that closes 10,000 intervals or more, its longest. Those are the paths every scenario
#     leans on, the hammers' semaphore gives and takes (~200,000 and ~100,000 per core, 1032-1053
#     longest) and the context switch (~10,000, 754-822): measured 1053 at most, bound 1200. A scan
#     added to one of them (control mk2: every slot looked at in each give, 1326 and 1404) shows on that
#     site. This replaces a count of the intervals of 1024 cycles or more, which the hammers' holds sit
#     right at: sysl 0.13.5 inlined a 27-cycle trace emit into `Semaphore.take`, its longest went from
#     1008 to 1032 with nothing grown, and ~2,800 of its ~100,000 holds crossed the line. A site's
#     longest moves with such an inlining by the cycles it adds, a count by however many holds sat
#     below the line.
#   - The tick handler's site (`board_tick`, ~2,900 a core), its longest: measured 762-843, bound 960.
#     It runs no lock (it masks its core alone), so its length is its own work; a scan over the task
#     slots in the tick (control mk1, ~290 cycles more, 1074 and 1136) shows on it. The bound is about
#     14% over the worst and 12% under mk1's.
#
# What it cannot see: a path neither frequent nor the tick that grows but stays under the first bound.
# Whether a stream copies its bytes under the lock is not judged here (a 64-byte copy adds ~200 cycles,
# within the interleaving's spread of the lock holds): the host test `sc_no_byte_copied_while_masked`
# checks that no byte of the ring is written while the core is masked (control m7sc1).
#   - The worst latency of the interrupts at the kernel's priority (KERNEL_IRQ_PRIORITY, below the mask):
#     the doorbell (irq26) and the software-raised interrupt (irq46). Such an interrupt waits for the
#     masked remainder and for any handler above it, so its bound is the masked one. Measured: irq26 214
#     on core 0, 206 on core 1; irq46 2 on each.
#
#   - The worst latency of PendSV on both cores and of SysTick on core 1. They sit at the lowest
#     priority, so they wait for the masked remainder and for every other handler's whole run: the
#     doorbell's drain, the tick's own supervision, a fault handler's report. A fault handler no longer
#     writes its report (DESIGN "The console service": it records it, and a task writes it), so that run
#     is short. Measured: PendSV 2101 on each core, SysTick 928 on core 1 (each ~56,000-64,000 when a
#     task fault's report was written from the handler). The bound leaves about twice the worst, since a
#     handler's run is longer than a masked hold.
#
# Not bounded, reported: core 0's SysTick latency, which the time scenario's own mask (below) holds off
# ~510,000 cycles; benchtop's latency report has no interval to leave out.
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

masked_bound=1500
frequent_from=10000
frequent_bound=1200
tick_site='board_tick$$sysl'
tick_bound=960
irq_bound=$masked_bound
irqs="irq26 irq46"
lowest_bound=4000
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
    --serial uart1=file:"$scratch/pico2-masking-core1.log" --timeout 300s --report-masking "$report" --masking-sites \
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

    # The sites: each line read as "longest count from to", the names without their offsets.
    sites=$(grep -E "^masking core=$core site " "$report" |
        sed -E 's/.* from=[^ ]+( \(([^)+]*)[^)]*\))? to=([^ ]+)( \(([^)+]*)[^)]*\))? longest=([0-9]+) count=([0-9]+).*/\6 \7 \2 \5/')
    if [ -z "$sites" ]; then
        fail "core $core: the report has no site table"
    fi
    worst_frequent=0
    frequent_where=""
    tick_longest=""
    IFS='
'
    for line in $sites; do
        IFS=' ' read -r cycles count from to <<EOF
$line
EOF
        if [ "$count" -ge "$frequent_from" ] && [ "$cycles" -gt "$worst_frequent" ]; then
            worst_frequent=$cycles
            frequent_where="$from -> $to, $count intervals"
        fi
        if [ "$from" = "$tick_site" ] && [ -z "$tick_longest" ]; then tick_longest=$cycles; fi
    done
    IFS=$old_ifs
    if [ -z "$frequent_where" ]; then
        fail "core $core: no site closed $frequent_from intervals, so the hammers' paths were not measured"
    elif [ "$worst_frequent" -gt "$frequent_bound" ]; then
        fail "core $core: a site of $frequent_from intervals or more masked for $worst_frequent cycles, over the bound of $frequent_bound ($frequent_where)"
    else
        echo "  longest of a site of $frequent_from intervals or more: $worst_frequent cycles (bound $frequent_bound), $frequent_where"
    fi
    if [ -z "$tick_longest" ]; then
        fail "core $core: no site begins in $tick_site, so the tick was not measured"
    elif [ "$tick_longest" -gt "$tick_bound" ]; then
        fail "core $core: the tick masked for $tick_longest cycles, over the bound of $tick_bound"
    else
        echo "  longest tick: $tick_longest cycles (bound $tick_bound)"
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
        if [ "$core" -eq 0 ] && [ "$exception" = systick ]; then
            if [ -n "$line" ]; then echo "  $exception latency: worst $(field "$line" max), mean $(field "$line" mean) (not bounded: the time scenario's mask)"; fi
            continue
        fi
        if [ -z "$line" ]; then
            fail "core $core: $exception was never taken, so its latency was not measured"
            continue
        fi
        worst=$(field "$line" max)
        if [ "$worst" -gt "$lowest_bound" ]; then
            fail "core $core: $exception waited $worst cycles, over the bound of $lowest_bound"
        else
            echo "  $exception latency: worst $worst, mean $(field "$line" mean) (bound $lowest_bound)"
        fi
    done
done

if [ "$failed" -eq 0 ]; then echo "PASS masking"; fi
exit $failed
