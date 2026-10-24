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

# The messages every core runs (boards/scenarios, messages.sysl): a message an interrupt sent, a queue
# passing five messages in order while it fills and empties, a timed receive, a wait for all of two event
# flags woken only by the last, a timed flags wait, a notification kept from before the wait and one
# that wakes it, a buffer handed to another task and back, in place, eight times, and stream and
# message buffers (an interrupt's bytes woken at the trigger level, partial writes and reads round a
# ring, whole messages through a full buffer, and timed receives).
messages_expected() {
    echo "skiff: core $1 a message an interrupt sent was waiting
skiff: core $1 a queue carried 5 messages in order through a full queue and an empty one
skiff: core $1 a timed receive timed out after 3 ticks
skiff: core $1 event flags woke a wait for all only once all its bits were set
skiff: core $1 a flags wait timed out after 4 ticks
skiff: core $1 a notification sent before the wait was kept, and one sent during it woke the task
skiff: core $1 a buffer went to another task and back 8 times in place, and every buffer is back in the pool
skiff: core $1 a stream an interrupt wrote woke its reader only at the trigger level, every byte in order
skiff: core $1 a stream carried 40 bytes in order through a ring of 16, written 7 and read 5 at a time
skiff: core $1 a message buffer carried 30 messages whole and in order through a full buffer
skiff: core $1 a timed stream receive took the 2 bytes there after 3 ticks
skiff: core $1 a timed message receive timed out after 3 ticks"
}
# Task control, every core (boards/scenarios, control.sysl): a suspended task held back until resumed;
# suspended waits that time out and are given, run only once resumed; a waiter resumed while it waits
# waiting on; a waiter raised by set_priority given first; a mutex holder's inherited priority kept
# through changes of its base; a stopped waiter out of its queue; a stale handle refused.
control_expected() {
    echo "skiff: core $1 a suspended task did not run until it was resumed
skiff: core $1 a suspended task's waits timed out and were given, and it ran only once resumed
skiff: core $1 a task resumed while it waited went on waiting until it was given
skiff: core $1 a waiter raised by set_priority was given before one queued ahead of it
skiff: core $1 a mutex holder kept the priority it inherited through two changes of its own, and gave it up with the mutex
skiff: core $1 a stopped waiter left its queue, and the unit given after it stayed
skiff: core $1 task control refuses a stale handle"
}
# Statistics, every core (boards/scenarios, stats.sysl), each judged by relations between measurements:
# a spinning task charged more than a sleeping one, and the idle task more at rest than while it spun; a
# deep task's stack high-water mark below a shallow one's, and both handles refused once deleted.
stats_expected() {
    echo "skiff: core $1 a busy task ran more than a sleeping one, and the idle task ran most once neither did
skiff: core $1 a task recursing 8 deep left less of its stack untouched than a shallow one, and both handles went stale"
}
# Software timers, every core (boards/scenarios, timers.sysl): a periodic timer called a period apart
# with no drift though one call ran late, a one-shot called once, a timer stopped before its expiry never
# called, a reset and a changed period counting from their commands, and every callback in its own core's
# timer service.
timers_expected() {
    echo "skiff: core $1 a periodic timer was called 5 times a period apart, once late behind a busier task, with no drift
skiff: core $1 a one-shot timer was called once and went inactive
skiff: core $1 a timer stopped before it expired was never called
skiff: core $1 a reset timer and one whose period changed each counted from its command
skiff: core $1 every timer callback ran in its own core's timer service"
}
# Error traces, every core (boards/scenarios, traces.sysl): an interrupt's failure kept to the core's
# handlers' trace, the interrupted task's untouched; two unprivileged tasks failing in turn, each finding
# only its own sites in its trace.
traces_expected() {
    echo "skiff: core $1 an interrupt's failure kept to its own error trace and left the task's as it was
skiff: core $1 two unprivileged tasks took turns failing 20 times, each keeping its own error trace"
}
# Protection, every core (boards/scenarios, protection.sysl): a map the MPU cannot hold refused at
# creation; an unprivileged task's round trips with a privileged one; a task reading kernel memory, a
# stack overflow and a null load each stopped alone and reported; calls with buffers, grants or handles
# outside the caller's refused, touching nothing; a granted UART written by its task, an ungranted one
# stopping its task; a trap the kernel does not take stopping its task; BASEPRI and PRIMASK out of an
# unprivileged task's reach; and every task stopped that should be, the rest running on.
protection_expected() {
    echo "skiff: core $1 refused a map its MPU cannot hold exactly when its task was created
skiff: core $1 an unprivileged task made 5 round trips with a privileged task through a semaphore and notifications
skiff: core $1 stopped a task that broke its memory protection
skiff: core $1 stopped a task that overflowed its stack
skiff: core $1 stopped a task that broke its memory protection
skiff: core $1 kernel calls with buffers, grants or handles outside the caller's were refused, and touched nothing
skiff: core $1 an unprivileged task granted the UART wrote this line itself
skiff: core $1 stopped a task that broke its memory protection
skiff: core $1 stopped a task that made a trap the kernel does not take
skiff: core $1 an unprivileged task's writes to BASEPRI and PRIMASK held off nothing
skiff: core $1 the tasks their protection stopped are stopped, and the rest ran on"
}
mps2_expected="skiff: hello
skiff: .shared holds the shared state
skiff: core 0 tick 1
skiff: core 0 tick 2
skiff: core 0 tick 3
skiff: core 0 time base agrees
$(tasks_expected 0 "f32 registers survived the switches")
$(waits_expected 0)
$(messages_expected 0)
$(timers_expected 0)
$(control_expected 0)
$(stats_expected 0)
$(traces_expected 0)
$(protection_expected 0)"

# The AN521's two cores run one image, each greeting and ticking on the UART of its own number, then
# running its own tasks at once with the other. Core 0 has no FPU (the SSE-200's CPU0, in QEMU as on
# the FPGA image), and one image serves both cores, so the image is built with no FPU registers and
# neither core checks them; core 0 may not create a task on core 1 once
# it runs. Both cores then hammer one semaphore in `.shared` at once, and core 0 finds the count exact;
# core 0 gives units one at a time that core 1 takes without waiting, then sends it numbered messages
# and notifications that it takes without waiting, and the two pass an event flag back and forth, each
# polling for the other's. Then core 1 waits, blocking, on a semaphore, a mutex, a queue, event flags and
# its notification, each given by core 0 through core 1's inbox and doorbell; the two pass a unit back and
# forth through two semaphores, each waiting for the other; core 0 fills buffers that core 1 receives,
# finds in place and as written, and gives back to the pool, from which core 0 takes every one again;
# core 0 writes bytes into a stream and messages into a message buffer that core 1 reads, both blocking;
# and a task on core 0 waits on a mutex a task
# of core 1 holds while a task of middling priority works on core 1, and must have it within a bound
# through the boost core 1's inbox carries, which the owner gives up with the mutex. Each core runs its own
# software timers, and core 0 may not command one of core 1's. Core 0 suspends, resumes, re-prioritizes
# and stops a task of core 1 through core 1's inbox, and core 1 checks each step. Each core measures its
# own tasks on its own counter, and core 0 is refused core 1's. Core 1 then faults
# on purpose: it
# reports the fault on its own console and stops. Core 0 sees it stopped, takes more ticks, finds that
# the time base counted its own ticks and none of core 1's, and stops the machine with status 0.
an521_core0_greeting="skiff: hello from core 0
skiff: .shared holds the shared state"
an521_core0_run="skiff: core 0 tick 1
skiff: core 0 tick 2
skiff: core 0 tick 3
$(tasks_expected 0)
skiff: core 0 may not create a task on core 1, which runs
$(waits_expected 0)
$(messages_expected 0)
skiff: core 0 two cores' gives and takes left the shared count exact
skiff: core 0 two cores passed event flags back and forth 1000 times
skiff: core 0 two cores woke each other through semaphores 1000 times
skiff: core 0 had every buffer it sent core 1 back in the pool
skiff: core 0 the high task had the mutex a task on core 1 held within 10 ticks
$(timers_expected 0)
skiff: core 0 may not command a timer of core 1
$(control_expected 0)
skiff: core 0 asked core 1 to suspend, resume, re-prioritize and stop a task of its own, and core 1 did
$(stats_expected 0)
skiff: core 0 is refused another core's task statistics and high-water marks
$(traces_expected 0)
$(protection_expected 0)
skiff: core 0 an unprivileged task on core 1 took a unit core 0 gave and set flags core 0 waited on, through its grants
skiff: core 0 sees core 1 stopped
skiff: core 0 ticks on
skiff: core 0 time base agrees"
an521_core0_expected="$an521_core0_greeting
$an521_core0_run"
an521_core1_ticks="skiff: core 1 tick 1
skiff: core 1 tick 2
skiff: core 1 tick 3"
an521_core1_run="$(waits_expected 1)
$(messages_expected 1)
skiff: core 1 took every unit core 0 gave
skiff: core 1 received every message core 0 sent, in order
skiff: core 1 took every notification core 0 gave
skiff: core 1 took a semaphore core 0 gave while it waited
skiff: core 1 locked a mutex core 0 unlocked while it waited
skiff: core 1 received a message core 0 sent while it waited
skiff: core 1 woke on an event flag core 0 set while it waited
skiff: core 1 woke on a notification core 0 sent while it waited
skiff: core 1 received 100 buffers core 0 filled, in place and every byte as written
skiff: core 1 read 3000 bytes core 0 wrote into a stream, every byte in order
skiff: core 1 received 200 messages core 0 sent, each whole and in order
skiff: core 1 the low task gave up the priority core 0's task lent it with the mutex
$(timers_expected 1)
$(control_expected 1)
skiff: core 1 core 0 suspended, resumed, re-prioritized and stopped a task of core 1 through its inbox
$(stats_expected 1)
$(traces_expected 1)
$(protection_expected 1)
skiff: core 1 an unprivileged task took a unit core 0 gave, through its grant
skiff: core 1 fault BusFault"
an521_core1_expected="skiff: hello from core 1
$an521_core1_ticks
$(tasks_expected 1)
$an521_core1_run"

# The AN521 as two images (boards/qemu-an521 with `--features core0` and `--features core1`): each core
# runs its own, built from the one board program, and the two meet at the handshake, agreeing on the
# layout of `.shared`, before either creates a task. Then the run is the one image's, except that core
# 1's image uses its FPU, so its floating-point tasks run too, and that core 0 cannot name core 1's
# timers at all, which are core 1's own.
split_core0_expected="$an521_core0_greeting
skiff: core 0 and core 1 agree on the layout of .shared
$(echo "$an521_core0_run" | grep -v -x -F "skiff: core 0 may not command a timer of core 1")"
split_core1_expected="skiff: hello from core 1
skiff: core 1 agrees with core 0 on the layout of .shared
$an521_core1_ticks
$(tasks_expected 1 "f32 registers survived the switches")
$an521_core1_run"

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

exit $failed
