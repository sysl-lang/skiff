#!/bin/sh
# What each board's consoles must print, and `check`, which judges a log against it. Sourced by boot-test.sh
# and seeded.sh, so a boot and a seeded boot of the same image are held to the same lines.

# What each console must print. The MPS2 boots are one core: it finds the kernel's shared state inside
# the link script's `.shared`, takes three ticks, finds the time base agreeing with its own count, then
# runs the scenarios' tasks (boards/scenarios): two equal tasks taking turns on the tick, two keeping
# their FPU registers across switches, a high-priority task running on the tick its sleep ends, and a
# stale handle refused. Its last scenario hangs the core with its interrupts masked, after a watched
# task kept the core's watchdog fed for 60 ticks: the tick stops, and the hardware watchdog's NMI reports
# it and ends the run through semihosting with status 98 (WATCHDOG_STATUS), not 0.
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
# The mutex options, every core (boards/scenarios, mutexes.sysl): a recursive mutex handed to its waiter
# only at the last of its unlocks, locked once; a ceiling holding off a task below it until the unlock,
# and refusing a task above it.
mutexes_expected() {
    echo "skiff: core $1 a recursive mutex locked 3 times went to its waiter only at the third unlock, locked once
skiff: core $1 a mutex of ceiling 6 kept a task of priority 5 out until it was unlocked, and one of ceiling 3 refused a task of priority 4"
}
# The queue sets, every core (boards/scenarios, sets.sysl): a task waiting on a set alone hears one
# member of each kind in turn, and a notice another task beat it to leaves it waiting again.
sets_expected() {
    echo "skiff: core $1 a task waiting on a queue set heard a semaphore, a queue, event flags, a stream at its trigger level, a message buffer and a channel in turn, and a notice another task beat it to left it waiting again"
}
# The kernel's trace, every core (boards/scenarios, tracing.sysl): a task's take, block, wake by a give,
# timeout and switches found in the core's trace ring in order, every reported interrupt entered and left.
tracing_expected() {
    echo "skiff: core $1 traced a task blocking, woken by a give, timing out and switching back, every step in order"
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
# Deferred work, every core (boards/scenarios, deferred.sysl): an interrupt posts work once more than the
# queue holds; the last post is refused and counted, and the core's work service runs the rest in order.
deferred_expected() {
    echo "skiff: core $1 work an interrupt deferred ran in the core's work service, in the order posted, and a full queue refused one post"
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

# Grants, every core (boards/scenarios, grants.sysl): notes through a granted queue between two
# unprivileged tasks; a pool buffer bounced between two through granted channels, each writing it while
# it is lent to its map; a task writing a buffer it passed on stopped, the buffer still delivered.
grants_expected() {
    echo "skiff: core $1 an unprivileged task received 6 notes another sent through a granted queue, both blocking, in order
skiff: core $1 two unprivileged tasks passed a pool buffer back and forth 4 times through granted channels, each writing it while it held it
skiff: core $1 stopped a task that broke its memory protection
skiff: core $1 an unprivileged task that wrote a buffer it had passed on was stopped, and the buffer reached its receiver"
}
# The watchdog, every core (boards/scenarios, watchdog.sysl): a watched task checking in every tick keeps
# its core's watchdog from biting for longer than its timeout.
watchdog_expected() {
    echo "skiff: core $1 a watched task checked in for 60 ticks, and its core's watchdog held off"
}
# Tickless idle, every core (boards/scenarios, tickless.sysl): with only its idle task to run, the core
# stops its tick, and a timed wait and a sleep still end on their deadlines.
tickless_expected() {
    echo "skiff: core $1 slept with its tick stopped, and a timed wait and a sleep still ended on their deadlines"
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
$(deferred_expected 0)
$(control_expected 0)
$(stats_expected 0)
$(mutexes_expected 0)
$(sets_expected 0)
$(tracing_expected 0)
$(traces_expected 0)
$(protection_expected 0)
$(grants_expected 0)
$(tickless_expected 0)
$(watchdog_expected 0)
skiff: core 0 fault watchdog"

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
# software timers and deferred work, and core 0 may not command a timer of core 1's nor post its work. Core 0 suspends, resumes, re-prioritizes
# and stops a task of core 1 through core 1's inbox, and core 1 checks each step. Each core measures its
# own tasks on its own counter, and core 0 is refused core 1's. Core 0 then masks its interrupts, taking
# no tick, while core 1 alone moves the time base on and sleeps on it. Each core's watchdog holds off
# while a watched task checks in; then a task on core 1 spins above it, and core 1's watchdog, checked
# on its own tick, reports on core 1's console and stops core 1 alone. Core 0 sees it stopped, takes
# more ticks, finds that the time base moves a period for each of its own ticks without core 1, and
# stops the machine with status 0.
an521_core0_greeting="skiff: hello from core 0
skiff: .shared holds the shared state"
# dual_core0_run [<line the FPU tasks print>]: core 0's run on a machine of two cores in one image.
dual_core0_run() {
    echo "skiff: core 0 tick 1
skiff: core 0 tick 2
skiff: core 0 tick 3
$(tasks_expected 0 "${1:-}")
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
$(deferred_expected 0)
skiff: core 0 may not post work of core 1
$(control_expected 0)
skiff: core 0 asked core 1 to suspend, resume, re-prioritize and stop a task of its own, and core 1 did
$(stats_expected 0)
skiff: core 0 is refused another core's task statistics and high-water marks
$(mutexes_expected 0)
$(sets_expected 0)
skiff: core 0 heard a semaphore and a queue core 1 filled, through a queue set in .shared, in the order they came
$(tracing_expected 0)
$(traces_expected 0)
$(protection_expected 0)
skiff: core 0 an unprivileged task on core 1 took a unit core 0 gave and set flags core 0 waited on, through its grants
$(grants_expected 0)
skiff: core 0 had the pool buffer an unprivileged task sent core 1 through granted objects back
skiff: core 0 took no tick while masked, and the time base moved on without it
$(tickless_expected 0)
$(watchdog_expected 0)
skiff: core 0 sees core 1 stopped
skiff: core 0 ticks on
skiff: core 0 keeps the time base alone"
}
an521_core0_run=$(dual_core0_run)
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
$(deferred_expected 1)
$(control_expected 1)
skiff: core 1 core 0 suspended, resumed, re-prioritized and stopped a task of core 1 through its inbox
$(stats_expected 1)
$(mutexes_expected 1)
$(sets_expected 1)
skiff: core 1 gave a semaphore and sent a message that a task of core 0 heard through a queue set in .shared
$(tracing_expected 1)
$(traces_expected 1)
$(protection_expected 1)
skiff: core 1 an unprivileged task took a unit core 0 gave, through its grant
$(grants_expected 1)
skiff: core 1 an unprivileged task received notes and a filled buffer an unprivileged task of core 0 sent, through its grants
skiff: core 1 kept the time base moving while core 0 took no tick
$(tickless_expected 1)
$(watchdog_expected 1)
skiff: core 1 fault watchdog"
an521_core1_expected="skiff: hello from core 1
$an521_core1_ticks
$(tasks_expected 1)
$an521_core1_run"

# The AN521 as two images (boards/qemu-an521 with `--features core0` and `--features core1`): each core
# runs its own, built from the one board program, and the two meet at the handshake, agreeing on the
# layout of `.shared`, before either creates a task. Then the run is the one image's, except that core
# 1's image uses its FPU, so its floating-point tasks run too, and that core 0 cannot name core 1's
# timers or work at all, which are core 1's own.
split_core0_expected="$an521_core0_greeting
skiff: core 0 and core 1 agree on the layout of .shared
$(echo "$an521_core0_run" | grep -v -x -F -e "skiff: core 0 may not command a timer of core 1" -e "skiff: core 0 may not post work of core 1")"
split_core1_expected="skiff: hello from core 1
skiff: core 1 agrees with core 0 on the layout of .shared
$an521_core1_ticks
$(tasks_expected 1 "f32 registers survived the switches")
$an521_core1_run"


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

pico2_core0_expected="$an521_core0_greeting
$(dual_core0_run "f32 registers survived the switches" | grep -v -x -F "$(tickless_expected 0)")"
pico2_core1_expected="skiff: hello from core 1
$an521_core1_ticks
$(tasks_expected 1 "f32 registers survived the switches")
$(echo "$an521_core1_run" | grep -v -x -F "$(tickless_expected 1)")"
