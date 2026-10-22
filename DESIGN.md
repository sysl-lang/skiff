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
```

- `here()` answers the running core's `Core` through `Port.core_id()`. With one core it is a constant
  and the lookup folds away.
- **The kernel is generic over the port** (`[P: Port]`, `p: *P` on every call), so a `Core` holds no
  `*Port`: the board passes its port to each kernel call, and its tick, switch and fault handlers do the
  same. `Port` is `write`, `cores`, `core_id`, `start_ticks`, `idle`, `new_context`, `request_switch`,
  `start_first`, `mask`, `restore`, `spin_lock`, `spin_try_lock` and `spin_unlock`; the arch package
  supplies the last eight. The idle task's body is the board's (`kernel.run(p, idle_stack, idle)`),
  since a task entry takes no port.
- **One image is built for the weakest core it runs on**: the AN521's core 0 has no FP registers, so its
  image is built for `thumb-freestanding-soft`, and no core of it saves or uses them.
- Each core's start-up fills its own `Core`; core 0 zeroes `.bss` and `.shared` before releasing the
  others. A core announces itself ready in `.shared`; a message to a core not yet ready is a panic.

## Tasks and handles

- **A `Task` handle is (core, slot, generation)** packed in a `u32` (8, 12 and 12 bits). The slot indexes
  the owner's `tasks`, `option_tasks` slots (default 16, range 2 to 4096, the idle task's among them).
  The generation runs 1 to 4095 and is bumped every time the slot is freed, wrapping to 1, so the
  handle 0 never names a task.
- **Every operation that takes a handle checks it**: the core exists, the slot is in use, the generation
  matches. A stale handle is refused (`Err(Stale)`), never acted on: it named a task that is gone, and
  the slot may hold another. The other refusals are `Full`, `Priority` (outside 1 to 31), `NoCore`,
  `Idle` (the idle task is never deleted) and `Remote`.
- **Tasks are created on a named core.** A core creates on itself at any time; on another core only
  before that core starts (`core_state` still offline), which is how core 0 gives every core its first
  tasks at boot. Once the target runs, creating or deleting there is `Err(Remote)`: it would edit that
  core's private state, and becomes a message (milestone 4).
- A task ends by `exit`, which deletes it. The running task's freed slot is not handed out again until
  the switch away from it, which still saves its stack pointer there.
- A `Tcb` is private: saved stack pointer, base and effective priority, state, suspended, the stack's
  bounds, statistics, the MPU map. Nothing in `.shared` points at one.

## Scheduling

- **Priorities are 0..31** (0 is idle). Each core's ready set is a `u32` bitmap of non-empty priorities
  plus a FIFO list per priority, so choosing is one count-leading-zeros and switching is O(1).
- Equal priorities take turns on the owner's tick. A task made ready that outranks the running one asks
  for a switch at once (PendSV on Arm).
- The running task stays in its FIFO, at the front until its turn ends; a turn moves it to the back.
  The owner's tick first wakes the sleepers whose deadline has come, then ends the running task's turn.
- A sleeper waits in the owner's timeout list, sorted by deadline (equal deadlines in the order they
  slept), and wakes on the owner's first tick at or after its deadline in the shared time base. On a
  core other than core 0 that tick falls anywhere in core 0's period.
- The ready set is private, so it is guarded by masking that core's interrupts, never by a spinlock.
- The scheduler (`Scheduler`: the table, the bitmap, the FIFOs, the timeout list) holds no hardware
  state, so the host tests drive one directly.

## Waiting: one primitive

**Every object waits through a `WaitQueue`**, and nothing in the kernel scans a task table to find a
waiter.

- A task waits on at most one thing at a time, so each task has exactly one **`Waiter`** record, in
  `.shared` at `waiters[core][slot]`. It holds the handle, the effective priority, a link (the next
  waiter's index, `core * option_tasks + slot`, not a pointer), the wait's `outcome` (`Idle`,
  `Waiting`, `Woken`, `Given`, `TimedOut`) and the value the wait carries (the bits that ended a flags
  wait, a notification's value).
- A `WaitQueue` is a head index and a count, in the object, ordered by priority and first-come within a
  priority. Insertion walks the queue (bounded by the number of tasks); waking the best waiter is O(1).
  The count alone says whether anyone waits, so a zeroed queue is empty.
- An object holds a `Waitable`: its `KernelLock` and its `WaitQueue`. A blocked task's private `Tcb.on`
  names it, which is how a timeout, a priority change or a delete reaches the queue under the lock.
- A change of a waiter's priority while it waits (inheritance, `set_priority`) re-inserts it, under the
  object's lock.

### A wait, step by step

1. The task takes the object's lock. If the object can answer at once (a count above zero, a message
   waiting), it does, releases the lock and returns.
2. Otherwise it fills its `Waiter` (`outcome = Waiting`), enqueues it, and blocks on its own core: the
   scheduler marks it not ready and, if it has a timeout, puts it in its core's timeout list (private).
   It asks for a switch and releases the lock. **The block is made under the lock**, which masks the
   core: released first, an interrupt handler on the same core could give the object and wake a task
   that was not yet blocked. The switch happens as the release unmasks.
3. It runs again when its `outcome` is no longer `Waiting`, and answers from it.

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

The owner's tick works through its timeout list with only its own mask up; a blocked task whose
deadline has come is not woken there but moved to the core's `expiring` list. After the ready set is
let go, the tick takes each expiring waiter's object lock in turn and ends the wait if it is still
`Waiting`. So the order of the locks stays object, then ready set. A wake that lands in between (an
interrupt handler's give, which may preempt the tick) has already made the task ready, and the timeout
finds the outcome settled and does nothing.

Deleting a waiting task first withdraws its wait under the object's lock (`outcome = Idle`), so no
wake can find it.

## Locks

- **Each object holds its own lock**: a `KernelLock`, chosen by the build. With one core it masks the
  core's kernel interrupts through the port and does nothing more; the spin is not in the image. With
  several it masks them and then spins on the chip's lock through the port (`spin_lock`,
  `spin_try_lock`, `spin_unlock` on the lock's word): LDREX/STREX on Armv7-M and Armv8-M (an atomic
  exchange, which compiles to the pair, in `arch/armv7m`), the SIO spinlocks on an RP2040 (whose M0+ has
  no exclusives; sysl refuses an atomic read-modify-write there), HSEM on the STM32H7. The kernel names
  no instruction.
- **The single-core lock is not `sysl.sync.IrqLock`**, as this file first said: `IrqLock` masks
  everything through PRIMASK, where the kernel's mask is BASEPRI and leaves the interrupts above it
  alone, and a program reaching it on any machine but a Cortex-M is refused, which would refuse the
  kernel's own host tests. The mask is the port's either way.
- **`Locking[P]`, the lock taken through a port (`lock.on(p)`), is what implements `sysl.sync.Lock`**:
  the mask and the spin are the port's, and `Lock`'s members take no port, so the pair is what is
  locked. The holder's mask state is kept in the lock, written once the spin is held and read before it
  is let go.
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
- Inheritance is one level deep, as before: a boosted owner blocked on another object moves up that
  object's queue, but does not pass the boost on to that object's owner. The boost is dropped when the
  owner holds no mutex (`Tcb.held` counts them).
- The locker raises a same-core owner after releasing the mutex's lock but before unmasking its core, so
  the raise never holds two object locks (a blocked owner's re-insertion takes the other object's).
- An unlock hands the mutex to the best waiter (`Given`), and the new owner inherits at once from the
  best of those still waiting.
- Until the inboxes carry `Wake` and `Boost`, a wait on a mutex another core's task holds, and a wake for
  another core's task, stop the kernel with a panic that says so.

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
- The check lives in the object's lock: the lock records the first core to take it, and the first take
  by another core, with the spin held, checks the lock's address against the bounds the board gave
  `kernel.shared_bounds` (core 0, before it releases the others) and panics naming the object
  (`Semaphore.new(name, …)`, `Mutex.new(name)`). With one core there is no check.
- **An object in `.shared` is filled in at run time**, before another core starts: start-up zeroes the
  section rather than loading it. The kernel's own `.shared` structure takes its zero value, which is
  what start-up writes (an `Outcome` zeroes to `Idle`). An object only one core uses is constant data:
  `Semaphore.new` and `Mutex.new` are `const`.
- On a core with a data cache (the M7), the board maps `.shared` uncached.
- A `Queue[T, N]`'s items cross cores by value. A `T` that holds a pointer into one core's private memory
  is the application's mistake, and in a two-image build an impossible one to make work.

## One core

With `option_cores == 1`: `here()` is a constant, `KernelLock` is the mask alone, the inbox array is empty,
every "is it another core" test is a constant `false`, and the cross-core paths are not in the image.
The single-core boots stay in the gate so that stays true.

## Open questions

- **32 priorities, settled with no option.** The bitmap is one `u32` and the FIFOs cost two `u16` a
  priority, so an `option_priorities` would save at most 120 bytes a core.
- **A suspended task's wait.** skiff-old let it carry on (unlike FreeRTOS, which drops it); this design
  keeps that, since the outcome rule makes it safe.
- **The H7's time base** in a two-image build: core 0's tick counter in `.shared` works; a shared
  hardware timer may be better.
