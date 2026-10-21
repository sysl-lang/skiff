# skiff — kernel design

How the kernel is built: the structures, who may touch them, and the protocols between cores. `ROADMAP.md`
says what skiff is and in what order it is built; this file says how the kernel works, and every kernel
change is checked against it. Where the code and this file disagree, one of them is wrong.

## The words

- **Core**: one processor running a scheduler. `option_cores` of them, numbered from 0.
- **Owner**: the core a task belongs to. A task never runs anywhere else.
- **Object**: a kernel object a task can wait on: semaphore, mutex, queue, flags, stream, timer service.
  A task's notification value is an object too.
- **`.shared`**: the section holding everything another core can reach. Everything else a core keeps is
  **private**: read and written only by that core, so on a core with a data cache it may be cached.

## The rule everything follows

**Anything another core can reach lives in `.shared` and names tasks by handle, never by pointer.** A
core's private memory is touched by that core alone. Two consequences carry the whole design:

- In one image, `.shared` is an ordinary section. In two images, both link scripts place it at one
  address, so the kernel's code is the same in both builds.
- A core never edits another core's private state. When core A must change something of core B's (wake
  a task, raise its priority, suspend it), A posts a **message** to B's inbox and rings B's doorbell;
  B applies it.

## Cores

```
Core (private, one per core)          .shared
  scheduler: ready set, running         inboxes:  [cores][cores] Ring of Message
  tasks:     [option_tasks]Tcb          waiters:  [cores][option_tasks] Waiter
  timeouts:  sorted list of slots       objects:  wherever the application declares them
  port:      *Port
```

- `here()` answers the running core's `Core` through `Port.core_id()`. With one core it is a constant
  and the lookup folds away.
- Each core's start-up fills its own `Core`; core 0 zeroes `.bss` and `.shared` before releasing the
  others. A core announces itself ready in `.shared`; a message to a core not yet ready is a panic.

## Tasks and handles

- **A `Task` handle is (core, slot, generation)** packed in a `u32` (8, 12 and 12 bits). The slot indexes
  the owner's `tasks`; the generation is bumped every time the slot is reused.
- **Every operation that takes a handle checks it**: the core exists, the slot is in use, the generation
  matches. A stale handle is refused (`Err(Stale)`), never acted on: it named a task that is gone, and
  the slot may hold another.
- A `Tcb` is private: saved stack pointer, base and effective priority, state, suspended, the stack's
  bounds, statistics, the MPU map. Nothing in `.shared` points at one.

## Scheduling

- **Priorities are 0..31** (0 is idle). Each core's ready set is a `u32` bitmap of non-empty priorities
  plus a FIFO list per priority, so choosing is one count-leading-zeros and switching is O(1).
- Equal priorities take turns on the owner's tick. A task made ready that outranks the running one asks
  for a switch at once (PendSV on Arm).
- The ready set is private, so it is guarded by masking that core's interrupts, never by a spinlock.

## Waiting: one primitive

**Every object waits through a `WaitQueue`**, and nothing in the kernel scans a task table to find a
waiter.

- A task waits on at most one thing at a time, so each task has exactly one **`Waiter`** record, in
  `.shared` at `waiters[core][slot]`. It holds the handle, the effective priority, a link (the next
  waiter's index, not a pointer), the wait's `outcome` and the value the wait carries (the bits that
  ended a flags wait, a notification's value).
- A `WaitQueue` is a head index and a count, in the object, ordered by priority and first-come within a
  priority. Insertion walks the queue (bounded by the number of tasks); waking the best waiter is O(1).
- A change of a waiter's priority while it waits (inheritance, `set_priority`) re-inserts it, under the
  object's lock.

### A wait, step by step

1. The task takes the object's lock. If the object can answer at once (a count above zero, a message
   waiting), it does, releases the lock and returns.
2. Otherwise it fills its `Waiter` (`outcome = Waiting`), enqueues it, and releases the lock. If it has a
   timeout, it enters its own core's timeout list (private).
3. It blocks: its core's scheduler marks it not ready and switches.
4. It runs again when its `outcome` is no longer `Waiting`, and answers from it.

### A wake, step by step

Under the object's lock, the waker takes the best waiter, sets its `outcome` (`Woken`, or `Given` when
the object hands itself over, as a semaphore or a mutex does), and releases the lock. Then:

- **the waiter's owner is the waker's core**: make it ready locally, and ask for a switch if it outranks
  the running task;
- **it is another core**: post `Wake(handle)` to that core's inbox and ring its doorbell.

### Timeouts race with wakes, and the outcome decides

A timeout fires on the owner's tick while another core may be waking the same waiter. **Only one
transition out of `Waiting` happens, and it happens under the object's lock**:

- the owner, on the timeout, takes the object's lock: if the waiter is still `Waiting`, it removes it and
  sets `TimedOut`; if not, a wake has already won, its message is on the way, and the timeout does
  nothing;
- the waker only ever takes a waiter that is `Waiting`.

So a wait ends exactly once, and a `Wake` message for a task that timed out cannot exist.

## Locks

- **Each object holds its own lock**: a `KernelLock`, chosen by the build. With one core it is
  `sysl.sync.IrqLock` (mask the core's kernel interrupts). With several it masks them and then spins on
  the chip's lock: LDREX/STREX on Armv7-M and Armv8-M, the SIO spinlocks on an RP2040 (whose M0+ has no
  exclusives; sysl refuses an atomic read-modify-write there), HSEM on the STM32H7. It implements
  `sysl.sync.Lock`.
- **A lock is never held across a block or a switch**, and never more than one object's lock at a time.
  The order, where two are needed, is: object lock, then the core's own ready set (mask only).
- **An interrupt handler takes the same lock** a task does; the mask makes that safe on its own core and
  the spin makes it safe against the others. Kernel interrupts sit below the mask (BASEPRI on Arm), so
  interrupts above it never call the kernel.

## Inboxes

- **One single-producer, single-consumer ring per ordered pair of cores**: `inboxes[to][from]`. No ring
  needs a compare-and-swap, so the same code runs on an M0+.
- On the sending core, a task and an interrupt handler may both post to one ring; posting masks that
  core's kernel interrupts, which makes them one producer.
- **A ring can never overflow**: it holds `option_tasks` messages, and every message kind is bounded by
  one per target task in flight (a task is woken at most once per wait; a boost, a suspend and a resume
  replace a pending one of their kind through a per-task pending mask kept beside the waiters).
- **The doorbell** interrupt drains every ring addressed to its core: for each message it checks the
  handle's generation (a stale one is dropped) and applies it to its own scheduler, then asks for one
  switch if anything now outranks the running task.
- Messages: `Wake(task)`, `Boost(task, priority)`, `Suspend(task)`, `Resume(task)`, `Stop(task)`.

## Mutexes across cores

- A mutex records its owner as a handle. A waiter that outranks the owner raises the owner's effective
  priority: directly when the owner is on the waiter's core, by `Boost` when it is not.
- Inheritance is one level deep, as before: a boosted owner blocked on another mutex does not pass the
  boost on. The boost is dropped when the owner holds no mutex.

## Time

- **One time base**: `ticks()` is a single counter in `.shared`, advanced by core 0's tick. Every core
  ticks its own scheduler at the same rate (time slices, its timeout list) and compares deadlines with
  that one counter, so a timeout means the same on every core.
- A deadline is `i32(deadline - now) <= 0`, so the counter may wrap.
- Tickless idle (milestone 10) replaces the periodic tick with a one-shot wake at the next deadline; the
  counter then comes from a hardware timer every core can read.

## Placement, checked

- Kernel objects are declared by the application. **In a build with more than one core, an object used
  from a core other than the one that first used it must be in `.shared`**; the kernel checks the
  address against `__shared_start`/`__shared_end` on that first cross-core use and panics naming the
  object otherwise. On a core with a data cache the check is what stands between a misplaced object and
  a silent coherence bug.
- On a core with a data cache (the M7), the board maps `.shared` uncached.
- A `Queue[T, N]`'s items cross cores by value. A `T` that holds a pointer into one core's private memory
  is the application's mistake, and in a two-image build an impossible one to make work.

## One core

With `option_cores == 1`: `here()` is a constant, `KernelLock` is `IrqLock`, the inbox array is empty,
every "is it another core" test is a constant `false`, and the cross-core paths are not in the image.
The single-core boots stay in the gate so that stays true.

## Open questions

- **32 priorities.** Enough for every RTOS application seen so far (FreeRTOS's default is 5-32); an
  `option_priorities` up to 32 could shrink the lists.
- **A suspended task's wait.** skiff-old let it carry on (unlike FreeRTOS, which drops it); this design
  keeps that, since the outcome rule makes it safe.
- **The H7's time base** in a two-image build: core 0's tick counter in `.shared` works; a shared
  hardware timer may be better.
