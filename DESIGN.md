# skiff — kernel design

How the kernel is built: the structures, who may touch them, and the protocols between cores. `ROADMAP.md`
says what skiff is and in what order it is built; this file says how the kernel works, and every kernel
change is checked against it. Where the code and this file disagree, one of them is wrong.

## The words

- **Core**: one processor running a scheduler. `option_cores` of them, numbered from 0.
- **Owner**: the core a task belongs to. A task never runs anywhere else.
- **Object**: a kernel object a task can wait on: semaphore, mutex, queue, flags, buffer pool, channel,
  stream, timer service. A task's notification value is an object too.
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
  supplies the last eight. `Port` extends **`Doorbell`** (`ring(core)`), which the chip supplies: MHU0
  on the AN521; and **`Cache`** (`clean`, `invalidate`), the running core's data cache, which does
  nothing on a core without one (see "Channels and the buffer pool"); and **`Watchdog`**, the
  core's hardware watchdog, if it has one of its own (see "Supervision"). The idle task's body is the board's (`kernel.run(p, idle_stack, idle)`), since a task
  entry takes no port.
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
  `Idle` (the idle task is never deleted, suspended, re-prioritized or stopped) and `Remote`.
- **Tasks are created on a named core.** A core creates on itself at any time; on another core only
  before that core starts (`core_state` still offline), which is how core 0 gives every core its first
  tasks at boot. Once the target runs, creating or deleting there is `Err(Remote)`: it would edit that
  core's private state, and becomes a message (milestone 4).
- A task ends by `exit`, which deletes it. The running task's freed slot is not handed out again until
  the switch away from it, which still saves its stack pointer there.
- A `Tcb` is private: saved stack pointer, base, inherited and effective priority, state, suspended, the stack's
  bounds, its run time ("Statistics"), the MPU map. Nothing in `.shared` points at one.

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
  `.shared` at `waiters[core][slot]`. It holds the handle, the effective priority, two links (the
  previous and next waiter's index, `core * option_tasks + slot`, not a pointer), whether it is queued,
  the wait's `outcome` (`Idle`, `Waiting`, `Woken`, `Given`, `TimedOut`), its `side` (which of its
  object's two lists it waits in: a queue's senders or receivers, a stream's writers or readers; every
  other object uses side 0), its `mode` (the wait's terms as its object reads them: a flags wait's) and
  its `value`: what the wait asks for going in (the bits a flags wait names) and what it carries back
  (the bits that ended it).
- **A `WaitQueue` is built as the ready set is**: for each of two sides, a circular FIFO per priority,
  linked through the records, and a `u32` bitmap of the priorities whose FIFO has a waiter. A waiter
  joins at the tail of its side's FIFO for its priority; the best waiter of a side is the head of the
  FIFO a count-leading-zeros of its bitmap names; a waiter leaves by unlinking itself, clearing its bit
  if its FIFO empties. **So queueing, waking, a timeout's or a stop's withdrawal and a priority change's
  re-queueing each take a fixed number of steps under the object's lock, however many tasks wait**, and
  a two-sided object finds the best waiter of the side it wants (`first_of(side)`) as directly as the
  best of all (`first`; on a tie of priorities, side 0's). The order is still priority first, first
  come within a priority, among waiters of every core alike. A head is read only when its bit is set,
  so a zeroed queue is empty. The price is size: a queue is 140 bytes (two bitmaps, 64 heads of 16
  bits, a count), in every object and in every task's note, so `.shared` holds
  `option_cores * option_tasks` of them besides the application's objects. One walk is left, a flags
  set's, since one set may satisfy every waiter; it takes the lock once per waiter (below, "Event flags:
  a set walks in steps").
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
- **it is another core**: post `Wake(handle)` to that core's inbox and ring its doorbell. The post is
  made under the object's lock; it never waits, so the lock is still held only for a few instructions.
  A mutex's hand-over to a task of another core posts `Hand(handle, priority)` instead (see "Mutexes
  across cores").

### What each object hands over

- **Semaphore, mutex**: the wake is `Given`, and being woken is having the unit or the mutex.
- **Message queue** (`Queue[T, N]`, the storage its own, so a queue in `.shared` carries messages with
  no pointer in them): a send to a waiting receiver puts the message in and keeps it for that receiver
  (`Given`), which takes the oldest message when it runs; a receive with a sender waiting keeps the
  freed slot for that sender (`Given`), which fills it when it runs. What is kept is out of reach of
  every other send and receive, so a woken receiver always has a message and a woken sender always has
  room. Messages leave in the order they came, whichever receiver takes them.
- **Event flags**: a set ends every wait it satisfies (`Woken`, the bits as the set left them in the
  record's `value`), and clears the bits each woken wait asked to clear as it is woken, judging every
  waiter by the bits as the set left them, so two waiters for one bit are both woken. It looks at them
  one per hold of the lock ("Event flags: a set walks in steps").
- **Task notifications**: each task's note (value, pending mark, `Waitable`) is in `.shared` at
  `notes[core][slot]`, so any core may send to any task. The note names its task by handle: it is
  renewed when a task is created in its slot (before the task can run) and cleared when the task is
  deleted (before it goes), and a send whose handle does not match it is refused as stale. Only the
  task waits on its own note; a send wakes it with `Woken`, and it takes the value when it runs.
- **Stream and message buffers** (`StreamBuffer[N]`, `MessageBuffer[N]`, a byte ring of their own, so
  either in `.shared` carries bytes between cores; a zeroed one is empty with a trigger level of 1):
  readers and writers wait on the two sides of the one `WaitQueue`, as a queue's do, and a writer's
  `value` is the room it needs (1 for a stream, the message and its 4-byte length prefix for a
  message). Nothing is kept: a change of bytes wakes the best reader with `Woken` once the trigger
  level is met, and the best writers in order while the room each needs is there (one needing more
  than there is holds back those behind it, so a long message is not starved); a woken task takes the
  lock again and looks, and waits again for what its deadline leaves if another got there first. A
  stream send writes what fits and waits for room for the rest; a receive whose timeout comes first
  takes whatever is there. A message goes in whole or not at all, and one longer than `N - 4`, or
  empty, is refused at once.

### Event flags: a set walks in steps

A flags set is the one wake that cannot be found in a fixed number of steps: one set may satisfy any
number of waiters, each on its own terms (any or all of the bits it names, clearing them or not), so
every waiter has to be looked at. **No bound on a set's whole length that does not grow with the waiters
exists without changing what a set means**, so the bound is put on what matters, the time the core is
masked: **a set masks its core for one waiter's worth of work at a time, and takes interrupts between.**

- **How the others do it.** Zephyr's `k_event_post` walks every waiter under its spinlock, masked
  throughout. FreeRTOS's `xEventGroupSetBits` walks with the scheduler suspended and interrupts open,
  and defers a set from an interrupt to its timer task. ThreadX's `tx_event_flags_set` walks with
  preemption off, opening interrupts between waiters, restarts the search when a handler set bits
  meanwhile, and delays a clear that comes during the search. skiff has no scheduler suspension, and on
  several cores another core may act on the object at any moment, so it takes ThreadX's shape, with the
  object's lock in place of the open window.
- **The set, masked once**: under the lock it ORs its bits in and, if anyone waits, begins a walk: it
  records the bits as they now are as what the walk judges by (`seen`) and flips the side waits join.
- **A step, masked once each**: under the lock, the best waiter on the side the walk has not passed
  (`first_of`, the queue's own order) has its wait ended with `Woken` and `seen` if `seen` satisfies it,
  its clear-on-exit bits cleared at once, or is moved to the other side. With none left the walk ends.
  The clear is made at the wake, not saved for the walk's end, because the woken task may run before the
  walk ends (a wake of a higher task switches as the step unmasks): it must find its own bits cleared,
  or a second wait of its own would be answered by the same set. A step is a lock acquisition, a count-leading-zeros, and either a wake (with a
  post to another core's inbox) or an unlink and a link; it does not depend on how many wait.
- **The sides swap with every walk.** Flags use only one side of their `WaitQueue` at a time; the walk
  moves the waiters it passes to the other, and a wait begun during a walk joins that other side. So a
  walk needs no cursor that a timeout, a stop or a priority change could pull out from under it (they
  unlink a waiter wherever it is), it looks only at the waiters that were waiting when its set came, and
  it ends.
- **Whoever sets, walks.** The set's caller steps until no walk is under way. A set that finds a walk
  under way ORs its bits in, keeps them from that walk's clearing (`kept`), asks for another walk (begun
  as this one ends, over every waiter then waiting, judged by the bits then), and steps too: the walk is
  the object's, and any caller may take the next step. So a set returns only once every wait it
  satisfies has ended, a set from a higher task or another core is never left behind a walker that was
  preempted, and a set from an interrupt handler finishes the walk itself.
- **What another caller sees during a walk.** A read, a clear or a wait sees the bits as they stand:
  the clear-on-exit bits of the waiters woken so far are cleared, those of the waiters the walk has yet
  to reach are not. That is the one thing a set is no longer atomic in. A clear during a walk takes effect after the set: the walk still judges by `seen`, and wakes
  the waiters the set satisfied. A wait during a walk that is satisfied at once is answered at once; one
  that waits is not looked at by that walk.
- **Order.** Within one walk the waiters are taken best first, as from any queue. A waiter the walk
  passes goes to the tail of its priority on the other side, behind any of its priority that began
  waiting during the walk; since a set wakes every waiter it satisfies whatever their order, this changes
  only which of one set's wakes is made first.
- **The bound.** Masked, per lock acquisition: a constant number of instructions plus the chip lock's
  wait, at most `cores - 1` holders ahead, each also holding for a constant (every other user of the
  object's lock holds it for a constant now too). Unmasked, a set's whole length is one step per waiter
  per walk, and one walk more for each set made during it.

### Timeouts race with wakes, and the outcome decides

A timeout fires on the owner's tick while another core may be waking the same waiter. **Only one
transition out of `Waiting` happens, and it happens under the object's lock**:

- the owner, on the timeout, takes the object's lock: if the waiter is still `Waiting`, it removes it and
  sets `TimedOut`; if not, a wake has already won, its message is on the way, and the timeout does
  nothing;
- the waker only ever takes a waiter that is `Waiting`.

So a wait ends exactly once, and a `Wake` message for a task that timed out cannot exist. The owner
applies a `Wake` or a `Hand` only to a task still blocked whose outcome is no longer `Waiting`; the
message may land before or after the deadline's tick moved the task to `expiring`, and either way the
timeout then finds the outcome settled.

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
  `spin_try_lock`, `spin_unlock` on the lock's word): a ticket lock on Armv7-M and Armv8-M (below; its
  atomic add and compare-and-swap compile to LDREX/STREX), the SIO spinlocks on an RP2040 (whose M0+ has
  no exclusives; sysl refuses an atomic read-modify-write there), HSEM on the STM32H7. The kernel names
  no instruction.
- **Where the chip has exclusives, the chip lock is a ticket lock, because it must be fair.** A
  test-and-set lock (what the first port had: an atomic exchange of 1) lets the core that just let it go
  take it again before a waiting core's exchange lands, so with two or more cores one can starve
  another for as long as it keeps asking. A ticket lock serves cores in the order they asked: a core
  waits for at most `cores - 1` holders ahead of it, each holding for a few instructions. It is its own
  package, `arch/ticket` (`lock`, `try_lock`, `unlock`, over `sysl.sync.Atomic` and nothing else), so
  its host tests run the code the boards run, and `arch/armv7m`'s port members call it. It is not in the
  kernel: the kernel is built for thumbv6m too, which refuses an atomic add or compare-and-swap even in
  a function nothing calls.
- **The ticket lock is the lock's one word**: the high half is the next ticket to hand out, the low half
  the ticket now served; equal halves are free, so zero is a free lock and `.shared`'s zeroing makes
  every lock in it free. Taking is an atomic add of `0x1_0000` (relaxed: it orders nothing), whose
  answer's high half is the core's ticket, then a spin on an acquiring load until the low half equals
  it. A try succeeds only on a free word, by compare-and-swap from (n, n) to (n + 1, n) with acquire: it
  never jumps a waiter. Releasing serves the next ticket with release ordering.
- **Each half wraps modulo 2^16 on its own.** The high half wrapping is the add's carry out of the word,
  which drops it. The low half must not carry: an add of 1 to the whole word when the low half is 0xffff
  would also advance the next ticket, handing out a ticket nobody holds, and every core would then wait
  for ever behind it. So the release is a compare-and-swap loop that rewrites the low half alone
  (`(w & 0xffff_0000) | ((w + 1) & 0xffff)`), retrying when another core took a ticket meanwhile. Only
  the holder writes the low half, so the loop retries only for tickets taken, at most `cores - 1` times.
  A busy lock passes the wrap often: the AN521's hammers take one lock 600,000 times.
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
- **A ring holds `3 * option_tasks` messages** (one slot more stays empty, so full and empty differ):
  one wake or hand-over for each task of the receiving core, of which there is at most one in flight
  per task (a task is woken once per wait, and waits again only after the message has made it ready),
  one control request for each task of the receiving core, of which there is at most one in flight per
  slot whichever core asks (see "Task control"), and one boost for each task of the sending core, which
  posts one each time it blocks on a mutex whose owner is on the receiving core.
- **A full ring stops the kernel; it never drops or overwrites a message.** A boost is bounded only
  between two drains: a sending task that times out and waits again posts another. So a ring fills
  only when the receiving core goes without taking its doorbell interrupt while the sender's tasks time
  out and wait over and over, and then the post reports `skiff: core <to>'s inbox from core <from> is
  full` and panics. A post never waits for room: it may be made under an object's lock that the
  receiving core's drain needs.
- **A message to a core a fault has stopped is dropped**, since none of its tasks runs again; one to a
  core not yet started is a panic.
- **The doorbell** interrupt drains every ring addressed to its core, in the order of the posting cores,
  each ring oldest first: for each message it checks the handle's generation (a stale one is dropped)
  and applies it to its own scheduler, then asks for one switch if anything now outranks the running
  task. The chip clears the doorbell before the drain, so a message posted while it drains rings again.
  The poster makes its writes visible before it rings (a `dsb` before the AN521's MHU write).
- Messages: `Wake(task)`, `Hand(task, priority, mutex)`, `Boost(task, priority, mutex)`, `Control(slot)`.

## Mutexes across cores

- A mutex records its owner as a handle. A waiter that outranks the owner raises the owner's effective
  priority: directly when the owner is on the waiter's core, by `Boost(owner, priority, mutex)` when it
  is not. Only the owner's core knows the owner's priority, so a waiter of another core always posts
  the boost, and the owner's core applies it only if it raises the task and the task still holds that
  mutex (read under the mutex's lock). A boost that arrives after the owner let the mutex go is
  dropped, so it can never outlive the mutex it was for.
- Inheritance is one level deep, as before: a boosted owner blocked on another object moves up that
  object's queue, but does not pass the boost on to that object's owner. The boost is dropped when the
  owner holds no mutex (`Tcb.held` counts them).
- The locker raises a same-core owner after releasing the mutex's lock but before unmasking its core, so
  the raise never holds two object locks (a blocked owner's re-insertion takes the other object's).
- An unlock hands the mutex to the best waiter (`Given`), and the new owner inherits at once from the
  best of those still waiting. A new owner on another core is told by `Hand(task, priority, mutex)`: its core
  counts the mutex in `Tcb.held`, raises the task to `priority` if that is higher, and makes it ready.
  The unlocking core never touches the new owner's `Tcb`.
- **What a task inherits is kept apart from its base**, as its boost: the highest priority a waiter lent
  it while it holds a mutex, recorded whether or not it raises the task (a waiter below a high base
  still lends). The task runs at the higher of base and boost; the boost goes when it holds no mutex.

### Recursive and ceiling mutexes

Two options, fixed at creation: `Mutex.new(name)` (neither), `Mutex.recursive(name)`,
`Mutex.with_ceiling(name, c)` and `Mutex.recursive_with_ceiling(name, c)`, all `const`. Each is plain
data (`locks: u16`, `ceiling: u8`, `reentrant: bool` beside the owner), zero is a free plain mutex, and
none holds a pointer, so any of them may lie in `.shared`. `lock(p, timeout) -> bool` is as before;
`enter(p, timeout) -> Result[unit, MutexError]` is the same lock saying why it was refused:
`Unavailable` (timeout 0, timed out, or the wait ended otherwise), `Ceiling`, `Depth`.

- **Recursive.** The holder may lock it again; the mutex counts the locks (`locks`, `depth()`), and the
  holder keeps it until it has unlocked once for each. A lock past `MAX_LOCKS` (65 535) is refused with
  `Depth`, the count unchanged: a refusal, not a panic. It counts once in `Tcb.held`, at the first lock
  and the last unlock, so a boost is dropped only at the last unlock of the last mutex. Unlocking once
  more than it was locked finds the mutex free or another's, which is an unlock by a non-holder: the
  same panic as on a plain mutex. A plain mutex locked again by its holder still panics.
- **Hand-over hands the whole mutex.** The last unlock gives it to the best waiter locked once (`locks`
  = 1), on its core or another: the count is the mutex's, reset by the unlocker under the mutex's lock,
  so a `Hand` carries nothing of it.
- **Immediate priority ceiling** (OSEK/AUTOSAR's resource priority, POSIX `PTHREAD_PRIO_PROTECT`). A
  mutex of ceiling c raises its holder to c at least from the moment it holds it, by a lock or by a
  hand-over, until it lets it go. A lock by a task whose **base** priority is above c is refused with
  `Ceiling`, before anything is touched; so is every lock of a ceiling outside 1 to 31. The check reads
  the base, not the effective priority: a boost or another ceiling is transient, and a refusal that
  depends on timing is no configuration check. `set_priority` may raise a holder's base above a ceiling
  it holds; it then runs at its base, and its next lock of that mutex is refused.
- **The effective priority is the highest of the base, the boost, and the ceilings of every mutex held.**
  `Tcb.ceilings[c]` counts the mutexes of ceiling c the task holds and `Tcb.ceiling_bits` has bit c set
  while that count is not 0, so the top ceiling is one count of leading zeros, and an unlock in any order
  takes away exactly its own ceiling: a task holding ceilings 5, 3 and 5 runs at 5 until both 5s are
  gone. A recursive mutex's ceiling counts once. A boost is unchanged by ceilings: kept until the task
  holds no mutex, as above.
- **Across cores the ceiling applies on the holder's own core only.** The holder's core counts it, at the
  lock or, for a hand-over to another core, when it applies the `Hand`, which now names the mutex (as
  `Boost` does) so that core reads the ceiling, fixed since creation, without the mutex's lock. A waiter
  of another core blocks and lends by `Boost` as on any mutex. There are no remote ceilings: a task of
  core 1 holding a mutex does not run at a ceiling on core 0, and the ceiling does not bound how long a
  task of another core waits (MPCP-style global ceilings, which raise the holder above every local
  priority, are out of scope). With one core and a holder that never blocks while holding, a task that
  might lock the mutex never runs while it is held, so no task waits on it.

## Task control

`suspend(p, t)`, `resume(p, t)`, `set_priority(p, t, priority)` and `stop(p, t)`, each answering
`Result[unit, TaskError]`; `suspended(p, t)` and `priority(p, t)` (effective) ask the owner, as
`state` does. Every one checks its handle (`Stale`), and refuses the idle task (`Idle`) and a priority
outside 1 to 31 (`Priority`).

- **Suspending** takes a task out of its priority's FIFO and keeps it out (`Tcb.suspended`, apart from
  its state) until it is resumed; a task suspending itself is switched away from at once. **A suspended
  task's sleep or wait carries on**: an object may still wake it or hand itself over, and its timeout
  still comes, which makes it `Ready` but not runnable; resumed, it runs and answers as its wait ended.
  This is skiff-old's choice, kept against FreeRTOS's (which drops the wait), because the outcome rule
  makes it safe: the wait's one transition out of `Waiting` happens under the object's lock whether or
  not the task is suspended, and a wake from another core arrives as an ordinary `Wake` or `Hand`.
- **Resuming** a ready task puts it at the back of its FIFO and asks for a switch if it outranks the
  running one. Resuming a task that sleeps or waits leaves it sleeping or waiting: only the end of the
  wait makes it ready. Resuming a task that was never suspended does nothing.
- **`set_priority` changes the base**; the task runs at the higher of base and boost ("Mutexes across
  cores"), so a change of base never takes away a boost in force, and a boost lent under a higher base
  shows once the base drops below it. A waiting task whose priority changes is re-inserted in its
  object's queue (`reprioritize`). A raised waiter does not raise the owner of the mutex it waits on:
  inheritance passes when the wait begins, one level deep. A switch is asked when afterwards a ready
  task outranks the running one, so a lowered running task gives way at once.
- **Stopping** marks a task `Stopped`: it leaves its FIFO and the timeout list and never runs again.
  **Its wait is withdrawn first**, under the object's lock: it leaves the queue (outcome `Idle`), so no
  wake or hand-over finds it. A wait another core had already ended stays ended; the message on its
  way finds the task not blocked and is dropped. **It keeps what it holds**: a mutex it owns stays owned
  (the kernel counts mutexes held, not which), and its waiters wait until their timeouts, as after a
  fault (skiff-old and FreeRTOS agree). **Its slot stays in use**, so its handle answers `Stopped`,
  until it is deleted or a task is created when no slot is free: then the first stopped slot is taken
  and its generation changes, so the old handle is stale. A running task stopping itself keeps its
  slot until the switch away from it.
- **Another core's task**: while that core is offline, the call acts on its table at once, as `create`
  does. Once it runs, the call is **a request through its inbox**, never `Remote`: the asking core takes
  the task's note's lock (`notes[core][slot]`, in `.shared`), checks the handle against the task the
  note is for (stale, deleted and never-created slots refused, and the idle task's note is for no task,
  so it is refused as `Stale` from another core), records the request in the note (`Request`: the last
  of a suspend and a resume, the last priority, a stop) and posts `Control(slot)` unless one is already
  on its way (`posted`). The owner's doorbell takes the request under the note's lock and applies it to
  the task the note is for **now**: priority, then suspend or resume, then stop. So requests made before
  the owner answers combine; a request whose task was deleted is dropped with its note; and a new task
  in the slot is asked only what was asked of it. One `Control` per slot is in flight at a time, which
  is the ring bound's third term. The call answers once the request is recorded, before it is applied.
- **Privileged only.** None of these is a kernel call (`calls.sysl`): an unprivileged task cannot
  suspend, re-prioritize or stop another task. Granting it would need a task grant, which the grant list
  does not have.

## Statistics

`task_stats(p, t) -> Result[TaskStats, TaskError]` (run time, state, suspended, effective priority),
`core_stats(p) -> CoreStats` (counts elapsed, of them idle, slots in use), `reset_stats(p)` and
`stack_high_water(p, t) -> Result[usize, TaskError]`.

- **Run time is counted in the core's own counter**, the port's `RunCounter` (`run_count`, free-running,
  wrapping at 2^32): the kernel names no timer. A chip with a cycle counter per core (DWT CYCCNT) uses it;
  QEMU models no DWT, so the MPS2 boards use CMSDK timer 1, and on the AN521 core 0 timer 1 and core 1 the
  dual timer, each core its own. The rates may differ: a count is only ever compared with counts of the
  same core.
- **A charge** is a counter read, a subtraction and adds: the running task is charged the counts since
  the core's last reading (`Core.counted_at`), and so is the core's total (`elapsed`), and its idle time
  when the idle task ran. It is made at every switch, before the next task is chosen, on every tick (so a
  counter that wraps no more than once a tick is enough) and at every query, so the running task is
  charged up to now. Counting starts when `run` starts the first task; `reset_stats` zeroes the core's
  counts and every task's and counts from then.
- **A slot's run time starts at 0 whenever a task is put in it**, a stopped task's slot included, so a
  handle never shows its slot's last task's. A stopped task keeps its count until its slot is reused.
- **Stack high-water marks**: every stack is filled with `STACK_PAINT` (0xa5a5_a5a5) when its task is
  created (before its first frame, outside the mask). The mark is the bytes still painted, counted from
  the bottom up from just above the stack's reserve (`Protection.reserved`: PMSAv7's guard and what lies
  below its boundary, everything below PSPLIM on Armv8-M): no task may use the reserve, the v8 switch may
  write into it, and reading the running task's v7 guard would fault. It is a lower bound on the room
  left. An unprivileged task's stack is scanned the same way: its kernel calls run on it, so they count.
  The scan runs unmasked; the handle is checked before and after it, and a task deleted or replaced
  meanwhile is `Stale`.
- **Another core's task is `Remote`, refused**, as `state` is, not asked through its inbox: an answer
  would need a reply carried back and the asking task blocked on it, for numbers that are already stale
  when they arrive. A core's statistics are read on that core: a monitoring task of its own reports them.
- **Privileged only**, like task control: no kernel call reads them.

## Channels and the buffer pool

Bulk data (an audio block, a frame, a packet) moves between tasks, on one core or across cores, by
handing over a buffer, never by copying it. A **pool** holds the buffers; a **channel** carries them.

### What a buffer is, and who owns it

- **A pool, `Pool[N, SIZE]`, is `N` buffers of `SIZE` bytes in the pool's own storage**, so a pool in
  `.shared` holds its buffers there. The application sizes it with the type's const arguments, as it
  sizes a `Queue[T, N]`; nothing about one pool is a kernel option. `N` is 1 to 4096.
- **Each buffer starts on a cache line and fills whole lines**, so cleaning or invalidating one buffer
  never touches another's bytes, or the pool's own records. The line is `option_cache_line` (default 32,
  the M7's): the one size here that is kernel-wide, since it is the machine's, not a pool's.
- **A buffer is named by a `Buffer` handle**: the pool's id (8 bits), the buffer's index (12) and a
  generation (12), packed in a `u32` as a task's handle is. The application gives each pool an id, 1 to
  255, in `Pool.new(name, id)`; pools whose handles can meet need ids of their own, and then each refuses
  the other's handles. A generation is never 0, so the handle 0 (`NO_BUFFER`) names
  nothing. **A channel carries handles, never pointers**, by the rule everything follows; the bytes are
  reached through the pool, `pool.bytes(p, b)`, which checks the handle first.
- **Holding the current handle is owning the buffer.** At every moment a buffer belongs to exactly one
  of: the pool (free), one holder (a task or an interrupt handler, which has its current handle), or
  one channel (in flight, its handle in the channel's slots).
- **Every hand-over issues a new generation**: a take from the pool, a give back to it, a send. So the
  handle a holder gave away no longer matches, and every later use of it (`bytes`, a give back, another
  send) is refused with `Err(Stale)`: a use after giving, a buffer given twice, a handle kept after its
  buffer went back to the pool. A handle of another pool fails the id, and one whose index is past `N`
  fails the index; both are refused the same way. A receive issues nothing: the handle in the channel
  was issued by the send for whoever receives it, and nobody else has it. The generation wraps after
  4095 hand-overs, as a task's does.
- **A give back takes the buffer from its holder in three steps**: under the pool's lock it checks the
  handle and issues the new generation, so that from then on nobody holds the buffer; with no lock held
  it cleans the buffer; under the lock again it puts the buffer in the pool, or keeps it for the best
  waiting taker. Only one object's lock is held at a time, and a second give of the same handle, racing
  the first, finds it already stale.
- **A send** issues the new generation the same way, cleans the buffer, and sends the handle through
  the channel's queue. If the queue refuses it (full, and the timeout passed), the send puts the old
  generation back, which nobody has seen the new one of, and answers `Err(Full)`: the buffer is still
  the sender's, under the handle it had.
- **A receive is told the pool its buffers come from**, as a send is: a send checks the handle against
  it, so a channel only ever holds handles of the pools its senders named. A receive given another pool
  than the one the handle names is the application's mistake, and stops the kernel naming the channel.

### Caches: clean before giving, invalidate after taking

- **`Cache` is part of `Port`** (`clean(bytes)`, `invalidate(bytes)`), since a data cache is the running
  core's. Cleaning writes the core's dirty lines over the bytes back to memory; invalidating drops its
  lines over them, so the next read comes from memory. On a core with no data cache (every QEMU machine
  here, the M33s, an M0+, an M4) both do nothing, and the board's port says so.
- **Every give cleans, before the buffer can be seen**: a send before the handle goes into the channel,
  a give back before the buffer is in the pool. **Every take invalidates, after the buffer is the
  taker's**: a receive once the handle has left the channel, a take once the buffer has left the pool,
  and a woken receiver or taker when it runs. So a receiver reads the bytes the sender wrote, and lines
  a core kept from an earlier turn of the same buffer are never read, or written back over a newer
  owner's data.
- Where the pool lies decides whether the operations do anything: in `.shared` mapped uncached (the M7
  of a one-image build) they are no-ops by the board's choice; where the buffers are cached, they are
  what keeps them coherent. Making the whole region non-cacheable suits control data, not audio.

### Empty pool, full channel

- The forms are the queue's. `take(p, timeout)` and `try_take(p)` answer `Option[Buffer]`: `None` when
  the pool stayed empty. `send(p, pool, b, timeout)` and `try_send(p, pool, b)` answer
  `Result[unit, BufferError]`: `Err(Full)` when the channel stayed full, `Err(Stale)` when the handle was
  not its holder's. `receive(p, pool, timeout)` and `try_receive(p, pool)` answer `Option[Buffer]`. A
  timeout of 0 never waits, so an interrupt handler may use the try forms; `FOREVER` waits for ever.
  `give(p, b)` never waits: there is always room in the pool for its own buffer.
- **A pool waits as a semaphore does**, through its `Waitable`: a give back with a taker waiting keeps
  the buffer for it (`Given`), out of every other take's reach, and the taker takes it when it runs. A
  free buffer is one the pool holds that is not kept for a woken taker.
- **A channel is a `Queue[Buffer, N]`** and hands over as a queue does. Its capacity is its const
  argument `N`, and it holds handles only, so a channel of eight buffers of 4 KiB is eight words.
- A timeout races a give or a send as every wait does, and the outcome decides: a taker or receiver
  woken `Given` has its buffer kept for it; one whose timeout ended the wait first leaves the buffer to
  the pool or the channel.
- **Placement**: a pool or a channel two cores use lives in `.shared`, and its lock's first use from a
  second core checks it ("Placement, checked"). A pool's buffers are inside the pool.

## Time

- **One time base**: `ticks()` is a single counter in `.shared`. Every core ticks its own scheduler at
  the same rate (time slices, its timeout list) and compares deadlines with that one counter, so a
  timeout means the same on every core: a deadline computed on one core and checked on another is the
  same instant, and every core reads the same `ticks()` at once.
- **Any core's tick may advance it; no core's tick must.** A core remembers the time base as its last
  tick left it (`Core.time_seen`). On a tick, if the time base still reads that, no core has advanced it
  since, and this tick is the period's first: the core advances it by one. If the time base has moved,
  another core took this period, and the core only records what it now reads. With several cores the
  read and the advance are made holding a spin word beside the counter in `.shared`, taken with the
  port's `spin_try_lock`, not a compare-and-swap: a thumbv6m core has none, and a port that has only
  a hardware lock (the RP2040's SIO) supplies the try. A core that finds the word held only counts
  its tick: the holder is taking the period. So:
  - time advances while any core ticks: a core alone advances it on every tick after its first;
  - cores ticking together advance it once a period, not once each, in whatever order their ticks land;
  - it only ever moves forward by one, so it is monotonic, and every core reads the one counter;
  - a tick does one try, one load and at most one store, and never waits for another core.
- **What it costs**: time runs at the rate of the fastest-ticking live core, which is the tick rate,
  since every core ticks at `tick_hz`. A core stopped, masked, or stalled for a while takes nothing
  from it; its first tick after resynchronizes. On hardware a tick held off is merged into the one
  pending bit, never delivered late, so a lagging core's count is lost, not owed, and resynchronizing is
  right. Under QEMU's multi-threaded TCG a core's ticks can come late and in a bunch; the bunch then
  advances time by up to its length minus one ahead of the clock, never backwards.
- **Why not the alternatives.** *Core 0 alone* (the rule before) stops time for every core when core 0
  stops, stalls or masks for long. *The largest of the cores' own counts* never double counts, but a core
  that lost ticks lags for good, so once the leader stops, time stands still for as long as the survivor
  is behind, and that lag grows with every masked stretch. *A counter every core reads* needs one on
  every chip (the AN521's timers are per core; `RunCounter` is per core by design), its rate, and the
  register in the chip, and is what tickless idle brings anyway.
- A deadline is `i32(deadline - now) <= 0`, so the counter may wrap.
- **A core may take several ticks at once**: one that slept through `n` periods with its tick stopped
  (below, "Tickless idle") brings the time base to `n` past where its last tick left it, unless other
  cores have moved it that far or further since, and records where it is. The rule above is the case
  `n = 1`: "no core has advanced it since" is "it has moved less than one". Taking `n` waits for the spin
  word (`spin_lock`) rather than trying it, since the holder is only taking one period of the `n`, and
  holds it for a load and a store. So a sleeping core does not slow the time base while another ticks
  (that core advances it every period it finds unmoved), a waking core adds only the periods nobody took
  while it slept, and with every core asleep the first to wake brings it on by its whole sleep. The time
  base still never moves back: a view far behind (a core that was stopped) has seen it move more than
  `n`, and only records.

## Tickless idle

A core with nothing to run but its idle task stops its periodic tick and sleeps until the next thing
that needs it, then takes every tick it slept through at once. `kernel/skiff/kernel/tickless.sysl` is the
kernel's side; the port's is two members of `Port` with defaults.

- **The port**: `tickless_limit()`, the most ticks one sleep can span (default 0), and
  `sleep_ticks(count)`, called with the kernel's interrupts masked: stop the tick, sleep until `count`
  ticks after the last one or until any interrupt is pending, restart the tick in step with its old
  period, and answer how many periods ended meanwhile. Their tick interrupts are never delivered; a tick
  already pending answers 0 and stays pending. **A port that implements neither keeps today's behaviour**:
  a limit under 2 makes the idle step `p.idle()`, a sleep to the next tick.
- **The idle task's body is `loop kernel.rest(p)`**. `rest` masks, asks how far the core may sleep
  (`skippable`), and sleeps only if that is 2 ticks or more: its running task is the idle task, nothing
  above priority 0 is ready, no expired wait is waiting to be ended, and the core is not stopped. The
  sleep is the fewest of the port's limit, the ticks to the head of the core's timeout list (every sleep
  and every timed wait, the timer service's wait for its soonest expiry and the work service's among
  them, so a software timer bounds it with no list of its own), and what the watch allows (below).
- **On waking it takes the ticks that passed, `n`, in one step** (`take_ticks`, the tick's own path with
  a count): the core's own count moves by `n`, the time base as "Time" says, the running task (the idle
  task) is charged the counter's difference, and the timeout list expires everything due at the new time,
  in deadline order. Then the mask is restored, the waits that expired are ended under their objects'
  locks as after any tick, and the interrupt that woke the core, if any, is taken. An interrupt that
  woke it early (a doorbell, a device) gets exactly the periods that ended before it, never the whole
  sleep; the next idle step sleeps the rest.
- **The watch** (DESIGN "Supervision") counts the core's own ticks, and no task checks in while the core
  sleeps. So a sleep lasts no longer than its verdict could stay unchanged: while every watched task is
  still within its period, until the last tick it would be fed on; once one is overdue, until the last
  tick before the bite, so the bite still comes from a real tick on the tick it always would. Waking, it
  is fed as of the last tick in the sleep on which every watched task was still within its period, and
  the hardware stage with it, which is started at twice the timeout and so outlasts any such sleep.
- **What is exact**: own ticks, the time base on a core alone, every deadline's tick, a timer's due tick,
  the watch's feeding and its bite, and the idle task's run time. **What is not**: the tick's phase after
  a sleep moves by the few cycles the port spends with the counter stopped; a wake later than the port
  can measure (QEMU stalling a core longer than the counter's span) loses the periods past it, as a tick
  held off under a mask loses them today.
- **Armv7-M** (`arch/armv7m/systick.sysl`): SysTick's reload is set to what remains of the current period
  plus `count - 1` whole ones, then WFI with PRIMASK set and BASEPRI open, so any enabled interrupt wakes
  the core (BASEPRI would keep the kernel's own from waking it) but none is taken until the kernel has
  taken the ticks. On waking, the cycles slept (the counter, and COUNTFLAG for one reload past the wake)
  give the periods ended and how far into the next the core is; SysTick's pending bit is cleared if a
  period ended, the counter is reloaded with the cycles left of the current period, and the reload is set
  back to the period once that is loaded. A restart under 64 cycles takes that tick early instead. The
  limit is the periods that fit the 24-bit counter, less one: 66 at 25 MHz and 100 Hz, 82 at 20 MHz.
- **Several cores**: each sleeps on its own; nothing is shared but the time base. A remote wake reaches a
  sleeping core as any message does, through its inbox and doorbell, which ends the sleep early.

## Software timers

A software timer calls a function once a period has passed (one-shot), or every period (periodic).

- **A `Timer` is a plain struct the application declares**, as every other object is; its zero is a timer
  not yet created. `create_timer(p, &t, name, period, periodic, callback)` creates it **on the running
  core, which owns it from then on**; a second creation is refused (`Created`). A period is 1 to
  2^31 - 1 ticks (`Period`), so an expiry always compares across the time base's wrap. A timer is never
  deleted.
- **Each core has a timer service**: its list of active timers (sorted by `i32(expiry - now)`, equal
  expiries in the order they were started) and a `Queue[TimerCommand, timer_commands]` (option, default
  8), both private to the core. The board creates the service task on each core that uses timers, at a
  priority it chooses, with the body `kernel.serve_timers(p)`. **Callbacks run in that task**, one after
  another: never in the tick, and never on another core. A callback is `*extern(*Timer, u32)`: the
  timer and the tick it was due on.
- **Start, stop, reset and change of period are commands**, sent through the queue with a timeout for
  room (0 from an interrupt handler, which never waits; a full queue then answers `Busy`). The service
  alone touches the list. A command carries the tick it was **sent** on, and a start expires a period
  after that tick however long the command waited. `is_active` answers what the service has done so far.
- **A periodic timer's next expiry is its last plus its period, never now plus its period**, so it does
  not drift: when the service falls behind (a busier task, a long callback), each missed expiry is still
  called, late and in deadline order among every timer due, in the same turn. A one-shot is inactive
  before its callback runs, and a periodic timer is already back in the list, so a callback may command
  its own timer.
- **A command a callback sends is the service's own, and takes effect before the callback returns**: the
  service owns the list, so it has no reason to queue to itself, and a queued stop would wait for the end
  of the turn while the turn went on calling the timer's overdue expiries (a late turn with six due and a
  stop at the third made six calls). This holds for start, stop, reset and change of period, for any
  timer of the core, and needs no room in the queue. The commands already queued are carried out first,
  so commands still take effect in the order they were sent. The service knows its own command by the
  running task being the one that called the callback; an interrupt handler arriving during the callback
  is indistinguishable from it and is carried out at once too, which is safe because the list is settled
  while a callback runs. One arriving while the service carries out a command of its own is queued.
- **Carrying out a command costs the same however many timers are active; only the service task walks
  the list, unmasked.** The list is linked both ways, so a stop or a restart takes the timer out in
  constant time, and a started timer is appended to the service's *pending* timers with the tick its
  expiry counts from. The service moves the pending timers into the list, oldest first, before each
  timer due is taken (`settle`): so equal expiries still keep the order they were started in, and a
  callback's start is in the list before the next timer due is taken. This matters because a command
  carried out at once may be an interrupt handler's arriving during a callback: before, its sorted
  insert walked the list inside the handler, which grows with the timers. Now, in a handler, under the
  mask or under a lock, a command costs one queue operation and at most `timer_commands + 1` constant
  carries-out (the queued ones, then its own), whatever the number of timers. The sorted insert is
  O(active timers), in the service task, unmasked and preemptible by every interrupt and higher task,
  holding no lock; a turn that expires k timers is O(k) callbacks and O(k × active) insert steps, which
  only the service's own priority pays for. A timing wheel would make the insert constant too, but costs
  a bucket array per core and a scan or spurious wakes to find the soonest expiry, and an overdue start
  (a command taken after its expiry) would still need a sorted place; the walk is not where a bound
  matters, since nothing waits on it but the service.
- **The service waits through the one `WaitQueue`**: it receives on its command queue with a timeout of
  the ticks to the soonest expiry (`FOREVER` with none active), so a command wakes it as any send wakes
  a receiver, and the expiry is the wait's timeout ending on the owner's tick. A turn is: carry out every
  command waiting, then call every timer due at `ticks()`.
- **Only the owner commands a timer; another core is refused (`Remote`)**, touching nothing. The list,
  the queue and the timer itself are the owner's private state, so a command from another core would
  have to be a message, and the inbox carries only wakes and boosts (its rings are sized for those, two
  per task). A task on another core that needs a timer started asks a task of the owner, by notification
  or queue, which is the same hop an inbox message would make. Reading `owner` from another core is a
  read of the owner's memory, written once at creation; on a core whose cache could hold a stale zero
  the answer is `NotCreated` instead of `Remote`, never an action.

## Deferred work

An interrupt handler hands a function and an argument to a task of its core, which calls it in task
context, so the handler stays short: FreeRTOS's pended function calls, Zephyr's work queues.

- **A `Work` is a plain struct the application declares**, as a `Timer` is; its zero is work not yet
  created. `create_work(p, &w, name, callback)` creates it **on the running core, which owns it from then
  on**; a second creation is refused (`Created`). A callback is `*extern(*Work, u32)`: the work and the
  argument of the post, for the same reason a timer's is (a stored code address is a C one, and a closure
  needs a heap). Work has no handle, so it cannot go stale; work never created is refused (`NotCreated`).
- **Each core has a work service**: a `Queue[WorkItem, work_items]` (option, default 8) private to the
  core, an item being the work and its argument. The board creates the service task on each core that
  uses deferred work, at a priority it chooses, with the body `kernel.serve_work(p)`. **Callbacks run in
  that task**, one at a time: never in the handler, and never on another core.
- **`defer_work(p, &w, argument)` never waits**, from a handler or a task. A full queue refuses the post
  (`Full`) and counts it (`deferred_refused(p)`, per core, wrapping); it never overwrites, so the items
  already queued are kept and still run.
- **Order is FIFO per core**: items run in the order their posts were accepted on that core, whoever
  posted them. A post from a callback goes behind every item already queued. There is no order between
  cores, since each core's items are its own.
- **How long a post masks**: the queue's send, which is the queue's lock (the mask, and the spin word with
  several cores, which no other core ever holds for this queue), a copy of two words, and, when the
  service waits, the end of that one waiter's wait and a switch asked. The service is the queue's only
  receiver, so its wait queue holds one waiter at most and the wake looks at one record. No loop over the
  items, so the masked part of a post is O(1) and does not grow with `work_items`. The refusal count is
  one more masked increment.
- **The service waits through the one `WaitQueue`**: it receives on its queue with `FOREVER`, so a post
  wakes it as any send wakes a receiver, and an item is kept for it until it runs.
- **Only the owner posts its work; another core is refused (`Remote`)**, touching nothing, for the reason
  a timer command is: the queue is the owner's private state, and the inbox carries only wakes, boosts and
  task control. A handler that needs another core's work done notifies a task of that core.

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

## Two images

One image is the default; two are an option, one board program built once per core (ROADMAP "One
image, everywhere by default"). On the AN521: `--features core0` and `--features core1`, each turning on
`split` and laying its image out by its own link script (`core0.ld`, `core1.ld`, a `features` block in
the board's manifest). Core 1's image may be built for its FPU (`thumb-freestanding`) where the one
image may not. The kernel's code is the same in both: what changes is the board's start-up.

- **`.shared` is at one address in both images**, so an address in it means one thing to either. Neither
  image's load segment covers it (`PT_NULL`): QEMU refuses two images loading one range, and core 0's
  reset zeroes it anyway. Core 1's reset zeroes its own image's `.bss` and never `.shared`.
- **The system description** is one module of the board program, so both images import it (the AN521's
  `boards/qemu-an521/system/system.sysl`). It holds where `.shared` and core 1's image lie (each image
  checks its link script agrees at boot), the one `System` structure placed first in `.shared` (section
  `.shared.system`, then the kernel's `.shared`), and which core owns each peripheral and interrupt
  (`OWNERS`). **A resource owned by two cores is a build error** (`@assert` over `OWNERS`); in two images
  each core takes what it owns and nothing else (its UART, its timers, its NVIC's doorbell: core 0 timer 0
  and timer 1, its run-time counter; core 1 the dual timer, its counter and the interrupt its scenarios
  raise; core 0 the security controller that releases core 1).
- **What two cores share is one structure, not loose objects.** The linker orders loose objects as it
  pleases and drops what an image does not use, so two images could place them differently with every
  type alike; a structure's layout is the compiler's alone. The scenarios' objects, counters and
  published handles are one `scenarios.Across`, a field of `System`; each image hands it over with
  `scenarios.share`.
- **The layout fingerprint** (`kernel.fingerprint[T]()`, layout.sysl) hashes, while compiling, the size
  of `T` and the offset and layout of every field, recursing into fields and array elements through
  `T::Fields`. `kernel.LAYOUT` is the kernel's `Shared`'s; a board combines it with its own `System`'s.
- **The handshake** (`kernel.Handshake`, first in `System`, so at `.shared`'s start whatever the rest is):
  core 0 fills `.shared`, creates its tasks, `offer`s its fingerprint and releases core 1, then
  `await_answer`s. Core 1 `await_offer`s, compares, says on its console whether the two agree, and
  `answer`s with its own. Disagreeing images stop there: core 1 stops itself, core 0 says so and stops
  the machine (status 3). No task has run on either.
- **Nothing in `.shared` holds a pointer**, checked at build: `kernel.holds_pointer[T]()` walks the same
  fields (a pointer, reference, string, slice, function or data-carrying enum anywhere is one), and the
  kernel asserts it of `Shared`, the board of `System`. So an object's name is kept in its lock
  (`KernelLock.name`, its first `NAME_BYTES` bytes), and a boost names its mutex by its **place** in
  `.shared` (`place_of`, an offset from `__shared_start`), not by address.
- **In two images a core creates only its own tasks.** Creating a task on another core edits that
  core's private state, which in two images is another image's memory: core 0's `create` on core 1
  before core 1 starts would fill core 0's own copy of core 1's `Core`, which nothing runs. The kernel
  cannot tell one image from two, so this is the board's rule.

## One core

With `option_cores == 1`: `here()` is a constant, `KernelLock` is the mask alone, the inbox array is empty,
every "is it another core" test is a constant `false`, and the cross-core paths are not in the image.
The single-core boots stay in the gate so that stays true.

## Protection

The MPU protects without translating: every address means the same thing to every task, and what
changes from task to task is only what may be touched. Each core has its own MPU, so **each core's
protection state is its own**: the map it has loaded, the stack it guards. Nothing about protection is
in `.shared`, and no core ever programs another's MPU.

### What is guarded

- **The null guard**: the first `NULL_GUARD_BYTES` (256) of the address space fault on any access,
  privileged or not, from every core, all the time. A vector fetch ignores the MPU, so a table may sit
  there. PMSAv7: the highest region, no access. PMSAv8 has no "no access" encoding, so the guard is two
  regions over the same bytes: an address two regions match always faults.
- **The stack guard**: the bottom of the running task's stack faults, so an overflow stops the task
  before it writes past its stack. PMSAv7: a 64-byte no-access region at the stack's first 64-byte
  boundary, moved on every switch. Armv8-M: PSPLIM, `SWITCH_RESERVE` above the base, which checks every
  push whatever the size of the frame and costs no region. The bytes below the guard's end are the
  stack's **reserve** (`Protection.reserved`): no task, and no call made for it, may use them.
- **What a fault stops**: a fault taken in thread mode on a task's stack that the protection raised (a
  MemManage, or an Armv8-M stack-limit UsageFault), or any MemManage, BusFault or UsageFault an
  unprivileged task takes outside a call, stops **that task alone**: `kernel.stop_running` marks it
  `Stopped` (its slot stays in use, so its handle answers `Stopped` until it is deleted or its slot is
  reused, as for `stop`, "Task control"), reports
  `skiff: core <n> stopped a task that <overflowed its stack | broke its memory protection | made a
  trap the kernel does not take>`, and asks for a switch. Every other fault stops the core, as before.
  A stopped task keeps what it held: a mutex it owned stays owned.

### The kernel's side: two traits on the port

`Port: Doorbell + Cache + Protection + Isolation`. The kernel names no register; the arch package
implements both traits and the board delegates.

- `Protection`: `guard(base, bytes)` guards the stack the core is about to run on; `reserved(base,
  bytes)` is that stack's reserve.
- `Isolation`: `capacity()` (regions a map may take on this unit), `encode(Region) -> Result[Slot,
  RegionError]` (how the unit holds a region, or why it cannot hold it **exactly**: never rounded),
  `load(map: []const Slot)` (hold this map; an empty one for a privileged task) and `privilege(bool)`
  (thread mode unprivileged or not, set in the switch, taking effect on the return to the task).
- **On every switch and at `run`**, the core guards the incoming task's stack, loads its map if it is
  unprivileged, empties the unit once for a privileged task after an unprivileged one (the core's
  `mapped` flag), and sets thread privilege: unprivileged exactly while an unprivileged task outside a
  call runs.

### Unprivileged tasks and their maps

- `create_unprivileged(p, core, stack, entry, priority, regions, grants) -> Result[Task, MapError]`
  creates a task under the same rules as `create` (on itself any time, on another core only before it
  starts), with a **map** beside its `Tcb` in the owner's `Core`: its stack (region 0, `ReadWrite`)
  and the creator's `Region(base, bytes, Access)`s, `Access` one of `Read`, `ReadWrite`, `Execute`,
  `Device`. At most `option_map_regions` regions (default 6, the stack included) and no more than the
  unit's `capacity`.
- **A map is checked at creation and refused, never rounded**: each region through `encode`; regions
  may not share a byte with one another or with the stack (PMSAv8 faults on an address two regions
  match). The refusal names the region (`MapError.Bad(k, why)`, `Overlap(j, k)`, `OverlapsStack(k)`,
  `TooManyRegions`, `Stack(why)`, `TooManyGrants`), and nothing is created. The encoded slots are kept,
  so a switch loads them with no arithmetic.
- A slot reused by any task, privileged or not, starts with an empty map: no grant outlives its task.

### Kernel calls

- **The trap**: `svc 1`, the call's number in r12 and four word arguments in r0-r3 (`skiff.kernel.user`
  is one plain function per call over `extern "skiff_trap"`, which the arch supplies). The arch hands
  the frame the processor pushed to `kernel.begin_call`, which checks it lies in the task's own stack
  above its reserve with room below it, and records the call; the arch then lays a fresh frame below it
  that starts the board's call thread, privileged, **on the task's own stack**: a call may block and be
  switched away from like any kernel code, and the switch keeps it privileged (`calling`). The thread
  runs `kernel.serve_call` and returns its answer with `svc 2`; `end_call` clears the record, the arch
  drops the privilege again and writes the answer over the r0 of the task's frame.
- **`dispatch` is one checked `match`, one function per call**: yield, sleep, ticks, current,
  notify, notify_wait (its value into a word of the caller's), take and give (a granted semaphore), set
  and wait (granted flags), write (bytes to the core's console), send and receive (a granted queue),
  take and give back a buffer (a granted pool), and pass and collect a buffer (a granted channel).
  **Everything a task passes is
  checked before anything is done**: a task handle as every handle is (stale, no such core); a grant
  index against the caller's own grant list and the kind the call needs; a buffer must lie wholly inside
  one region of the caller's map that allows the access (`may_reach`: `ReadWrite` for a write, `Read`,
  `Execute` or `ReadWrite` for a read, never `Device`, never in the stack's reserve, never straddling
  two regions, never wrapping). A call failing a check answers one of the `REFUSED_*` words (the top
  four values of a word), which `user` turns into `Err(Refusal)`: `NoSuchCall`, `BadHandle`,
  `BadArgument`, `BadBuffer`. **A refused call does nothing and touches nothing**; the task runs on.
- **A malformed trap stops the task**: an SVC number the kernel does not take, a call frame outside the
  task's own stack, a return with no call in flight, a call made inside a call.
- A privileged task may trap too, and every buffer check passes for it; it has no grants, and no need
  to trap: it calls the kernel directly.
- **An unprivileged task's code may touch nothing outside its map**, the runtime's included: its error
  return trace is in its own stack ("Error traces").

### Grants: how a task reaches objects, on its core or another

- **A task names objects by its own grant index**, never by address: the creator lists `Grant`s, and
  index k is the k-th of them, at most `option_grants` (default 4). An index past the list, or of another
  kind than the call needs, is `BadHandle`. There is no global object table, so no task can name an
  object nobody gave it. The kinds:
  - `Grant.Units(*Semaphore)`: take and give. `Grant.Bits(*Flags)`: set and wait.
  - `Grant.Messages(*Mailbox)`: send and receive through a queue, `Queue[T, N]` of any `T:
    sysl.encoding.Plain` (a `Mailbox`). A message crosses as its bytes: the task hands the kernel the
    address and length of a `T` of its own, the length must be the queue's `sizeof(T)` (else
    `BadArgument`), and the bytes must be the task's to read (else `BadBuffer`). The kernel decodes them,
    and bytes that are no `T` (a `bool` that is neither 0 nor 1, an enum's unknown number) are
    `BadArgument`, sending nothing. A receive encodes the message into bytes the task may write.
  - `Grant.Buffers(*BufferPool)`: take a buffer and give one back. `Grant.Carries(*Carrier,
    *BufferPool)`: send and receive buffers through a channel, with the pool its buffers belong to
    named by the creator, so a task cannot pair a channel with another pool than its buffers'.
- **Objects stay out of every map.** The kernel reaches a granted object privileged, under the object's
  own lock, exactly as for a privileged caller; the task's map grants it none of the object's bytes. So
  an object in `.shared` used from both cores is granted to an unprivileged task on each core through
  that core's private grant list (a pointer kept in private memory, never in `.shared`), and the
  `.shared` rule and the outcome rule hold unchanged: a cross-core wake from a call is the same inbox
  message a privileged caller's would be.
- **A grant is a trait object, and the kernel calls it with the running core's port as one too.**
  Queues, channels and pools are generic over their sizes and a grant list is one table of every kind,
  so `Mailbox`, `BufferPool` and `Carrier` are traits whose members take `p: *Port`; each forwards to
  the object's ordinary `[P: Port]` method, which an object of the port satisfies. A channel's methods
  take any `[Q: BufferPool]`, so a privileged caller's `*Pool[N, SIZE]` and a grant's `*BufferPool` go
  through the same code.
- **A buffer the task holds is lent to its map, and only for as long as it holds it.** A take or a
  receive puts the buffer into a free region of the task's map as `ReadWrite`, reloads the unit under
  the mask, and records the buffer's handle, address and length in three words of the task's own; a
  give back or a send that succeeds takes it out again (the map's last region moves into its place) and
  reloads. So the map allows exactly the buffers the task holds, never the pool's other buffers or its
  records, and a task that touches a buffer it has handed on faults and is stopped. **Only a lent handle
  is accepted** by a give back or a send (`BadHandle` otherwise, the loan kept); a send with no room
  answers 0 and leaves the buffer lent. A take or receive when the map has no free region is
  `BadBuffer`, checked before anything is taken. The record's words must be the task's to write, aligned.
- **A pool is checked as a grant at creation**: every buffer of a `Buffers` or `Carries` pool must be
  held by the unit exactly as one region (`MapError.Buffer(grant, why)`) and share no byte with the
  task's stack or regions (`MapError.BufferOverlaps(grant)`). A `Pool[N, 32]`'s buffers (32 bytes on a
  32-byte boundary) are held exactly on PMSAv7 and PMSAv8.
- **Tasks by handle**: `notify` takes any task's handle, on any core, checked like every handle.
- A call on a granted object runs on the caller's stack through the object's table: at -O0 the deepest
  takes more than 2 KiB, so such a task's stack is 4 KiB.

### Error traces

Every `?` whose failure arm is taken records its site in an error return trace, and every statement
handling a failure reads the trace and puts it back. On a freestanding target the runtime asks the hook
`sysl_error_trace_here` which trace that is, from wherever the `?` runs (a task, a handler, unprivileged
code), and the board supplies the hook. One image-wide word cannot answer: each core's switch would
overwrite the other's, and behind the MPU an unprivileged task cannot read the kernel's data.

- **Every task has a trace of its own, at the top of its own stack**: `TRACE_WORDS` words the kernel takes
  from the stack in `create`, `create_unprivileged` and `run` (the idle task), empties there before the
  task can run, and lays the task's frames below. A stack with no room below its trace is
  `TaskError.Stack`. The task's map holds its whole stack (region 0), so its trace is inside the map; no
  map holds another task's stack unless its creator grants it, so no task reaches another's trace. A
  stopped task's frame goes below its trace, which keeps what it held.
- **Each core has two traces of its own in kernel data**: one for its handlers and the kernel code they
  run, one for what it runs before its tasks. Only privileged code reaches them.
- **Which one is running is read from the processor**, never from a shared word (`running_trace(p)`,
  `handler_trace(p)`; the arch's `error_trace_here`): in handler mode, the core's handlers' trace; in
  privileged thread mode, the running task's (or the boot trace before the core runs its tasks), read
  from the kernel's data; in unprivileged thread mode, the running task's, which `svc 3` answers. On
  Armv7-M and Armv8-M an unprivileged MRS reads IPSR and CONTROL, and nothing that says which task runs:
  MSP, PSP, the masks and Armv8-M's stack limits read as zero. The trap costs a few dozen cycles, paid
  only on a failure path: a `?` that succeeds asks nothing.
- **An interrupt's failure never touches the interrupted task's trace**, and a task's failure is still in
  its trace when it is switched back in, however many others failed meanwhile.

### Options

`map_regions` (usize, default 6, [2, 16]): regions in an unprivileged task's map, its stack among
them. `grants` (usize, default 4, [0, 32]): objects one task may be granted.

## Supervision

A core that stops making progress is noticed and reported on its own console, and the other cores run
on, as after a fault. `kernel/skiff/kernel/watchdog.sysl` is the kernel's side.

- **A watch per core, in the core's private memory.** It holds the tasks the core watches (`watch(p, t,
  period)`, its own tasks only, `option_watched` of them, default 4), the tick each last checked in on
  (`check_in(p)`, by the running task), its timeout (`arm_watchdog(p, timeout)`) and the tick it was last
  fed on. Every count is of the core's **own** ticks, so a core whose ticks come late (QEMU's AN521 core
  1, under load) is judged by the ticks it took, never by another core's.
- **The core's tick feeds it, and only when every watched task has checked in within its period.** The
  board's tick handler calls `supervise(p)` after `tick`. No supervision task: it would need the highest
  priority, and its own liveness would rest on the tick anyway; in the tick the check costs one pass over
  the watched tasks under the core's mask, no stack, and proves both that the tick runs and that each
  watched task does. A watch unfed for its timeout **bites**: `bite(p)` stops the hardware stage (below),
  reports through the fault path (`fault(p, "watchdog")`: `skiff: core <n> fault watchdog`, the core
  marked stopped in `.shared`), and `supervise` answers true, on which the board stops the core as its
  fault handler would: `stop_core` on the AN521, the machine's halt on a one-core board. Only the owner
  touches its watch, so no core can feed another's, and a stopped core's verdict changes nothing of the
  others'.
- **The hardware watchdog is the second stage** (the port's `Watchdog`: `start_watchdog(ticks)`,
  `feed_watchdog`, `stop_watchdog`), started at `HARDWARE_STAGE` (2) times the timeout and fed with the
  watch. It is what notices a core whose tick no longer runs (its interrupts masked for good, a lockup),
  which no software watch can. Its warning reaches the board, which calls `bite` too; its reset, the
  chip's, is for when even the warning cannot run. A bite stops it, so a core stopped by its verdict never
  resets the machine.
- **What QEMU models.** The MPS2 (AN500, AN386): one CMSDK APB watchdog at 0x4000_8000 (25 MHz), its
  interrupt wired to the core's NMI; at a second expiry with the interrupt standing, with RESEN, it
  resets. One core, so it is that core's own: the board arms it, and the NMI (`skiff_nmi`, now the arch's
  NMI vector) reports `watchdog` and halts. The AN521 (SSE-200): three CMSDK watchdogs, the S32K one
  (0x5002_E000, 32 kHz) and the secure one (0x5008_1000, 20 MHz) both through an OR gate to **CPU 0's NMI
  alone**, and the non-secure one (0x4008_1000, 20 MHz) on interrupt 1, which a splitter delivers to
  **both** cores. None is a core's own, so the AN521's cores have no hardware stage yet: each core's watch
  is the kernel's, checked on its own SysTick (which each M33 has). A hardware stage there would give
  core 0 the secure watchdog's NMI and core 1 the non-secure one's interrupt 1, enabled in core 1's NVIC
  alone above the kernel's mask (it would see a core 1 masked by BASEPRI, not by PRIMASK), with either
  reset machine-wide.
- **Scenarios**: R's last on each core (`boards/scenarios/.../watchdog.sysl`): period 20, timeout 50, 60
  healthy ticks. On the MPS2 the hang masks the kernel's interrupts, so only the NMI sees it, and the run
  ends with `WATCHDOG_STATUS` (98). On the AN521 core 1's hang spins unmasked above its watched task, and
  its watch bites from its tick; core 0's watch stays fed while it waits to see core 1 stopped. This
  replaces the BusFault that ended core 1 before.

## Open questions

- **32 priorities, settled with no option.** The bitmap is one `u32` and the FIFOs cost two `u16` a
  priority, so an `option_priorities` would save at most 120 bytes a core.
- **A pool's records and its buffers in one structure.** A pool's lock, generations and free stack are
  control data that must not be cached where two cores use them; its buffers may be. With `.shared`
  uncached they share it; a board that caches the buffers will need the pool's storage in a region of
  its own. Settled with the H747I (milestone 9).
- **The H7's time base** in a two-image build: the shared tick counter in `.shared` works (either core
  advances it, "Time"); a shared hardware timer may be better.
