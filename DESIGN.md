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
  nothing on a core without one (see "Channels and the buffer pool"). The idle task's body is the board's (`kernel.run(p, idle_stack, idle)`), since a task
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
  `Waiting`, `Woken`, `Given`, `TimedOut`), its `mode` (what kind of wait it is, as its object reads it:
  a queue's side, a flags wait's terms) and its `value`: what the wait asks for going in (the bits a
  flags wait names) and what it carries back (the bits that ended it).
- A `WaitQueue` is a head index and a count, in the object, ordered by priority and first-come within a
  priority. Insertion walks the queue (bounded by the number of tasks); waking the best waiter is O(1).
  The count alone says whether anyone waits, so a zeroed queue is empty. Two objects walk further: a
  message queue's senders and receivers share its one `WaitQueue`, so a wake takes the best waiter of
  the side it wants (`first_of(mode)`), walking past the other side, which waits only in the moment
  between a kept slot or message and its taker running; and a flags set looks at every waiter, since
  one set may satisfy several.
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
  record's `value`), and clears the bits the woken waits asked to clear once all have been seen.
- **Task notifications**: each task's note (value, pending mark, `Waitable`) is in `.shared` at
  `notes[core][slot]`, so any core may send to any task. The note names its task by handle: it is
  renewed when a task is created in its slot (before the task can run) and cleared when the task is
  deleted (before it goes), and a send whose handle does not match it is refused as stale. Only the
  task waits on its own note; a send wakes it with `Woken`, and it takes the value when it runs.
- **Stream and message buffers** (`StreamBuffer[N]`, `MessageBuffer[N]`, a byte ring of their own, so
  either in `.shared` carries bytes between cores; a zeroed one is empty with a trigger level of 1):
  readers and writers share the one `WaitQueue`, marked by mode as a queue's are, and a writer's
  `value` is the room it needs (1 for a stream, the message and its 4-byte length prefix for a
  message). Nothing is kept: a change of bytes wakes the best reader with `Woken` once the trigger
  level is met, and the best writers in order while the room each needs is there (one needing more
  than there is holds back those behind it, so a long message is not starved); a woken task takes the
  lock again and looks, and waits again for what its deadline leaves if another got there first. A
  stream send writes what fits and waits for room for the rest; a receive whose timeout comes first
  takes whatever is there. A message goes in whole or not at all, and one longer than `N - 4`, or
  empty, is refused at once.

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
- Messages: `Wake(task)`, `Hand(task, priority)`, `Boost(task, priority, mutex)`, `Control(slot)`.

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
  best of those still waiting. A new owner on another core is told by `Hand(task, priority)`: its core
  counts the mutex in `Tcb.held`, raises the task to `priority` if that is higher, and makes it ready.
  The unlocking core never touches the new owner's `Tcb`.
- **What a task inherits is kept apart from its base**, as its boost: the highest priority a waiter lent
  it while it holds a mutex, recorded whether or not it raises the task (a waiter below a high base
  still lends). The task runs at the higher of base and boost; the boost goes when it holds no mutex.

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

- **One time base**: `ticks()` is a single counter in `.shared`, advanced by core 0's tick. Every core
  ticks its own scheduler at the same rate (time slices, its timeout list) and compares deadlines with
  that one counter, so a timeout means the same on every core.
- A deadline is `i32(deadline - now) <= 0`, so the counter may wrap.
- Tickless idle (milestone 10) replaces the periodic tick with a one-shot wake at the next deadline; the
  counter then comes from a hardware timer every core can read.

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
  each core takes what it owns and nothing else (its UART, its timer interrupt, its NVIC's doorbell; core
  0 the security controller that releases core 1).
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
  and wait (granted flags), and write (bytes to the core's console). **Everything a task passes is
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
- **An unprivileged task's code may touch nothing outside its map**, the runtime's included: a board
  that runs unprivileged tasks builds with `error_traces = false`, since a freestanding image keeps one
  error return trace for the whole program, which every statement handling a failure reads and restores.

### Grants: how a task reaches objects, on its core or another

- **A task names objects by its own grant index**, never by address: the creator lists `Grant`s
  (`Grant.Units(*Semaphore)`, `Grant.Bits(*Flags)`), and index k is the k-th of them, at most
  `option_grants` (default 4). An index past the list, or of another kind than the call needs, is
  `BadHandle`. There is no global object table, so no task can name an object nobody gave it.
- **Objects stay out of every map.** The kernel reaches a granted object privileged, under the object's
  own lock, exactly as for a privileged caller; the task's map grants it none of the object's bytes. So
  an object in `.shared` used from both cores is granted to an unprivileged task on each core through
  that core's private grant list (a pointer kept in private memory, never in `.shared`), and the
  `.shared` rule and the outcome rule hold unchanged: a cross-core wake from a call is the same inbox
  message a privileged caller's would be.
- **Tasks by handle**: `notify` takes any task's handle, on any core, checked like every handle.
- **Queues, channels and pool buffers are not granted yet.** They are generic over their sizes, and a
  grant list is one table of every kind. The decided form is a grant per object whose call methods the
  kernel reaches through a trait object; it needs a trait object of the port, which a kernel generic
  over `p: *P` cannot pass on (FINDINGS 9). Once it can, a buffer a call hands the task (take,
  receive) is **loaned** into a free region of the task's map for as long as the task holds it, and
  taken out of the map by the give or send that hands it on: the map always allows exactly the buffers
  the task holds, never the pool's other buffers or its records. A pool is refused as a grant at
  creation if the unit cannot hold one of its buffers exactly.

### Options

`map_regions` (usize, default 6, [2, 16]): regions in an unprivileged task's map, its stack among
them. `grants` (usize, default 4, [0, 32]): objects one task may be granted.

## Open questions

- **32 priorities, settled with no option.** The bitmap is one `u32` and the FIFOs cost two `u16` a
  priority, so an `option_priorities` would save at most 120 bytes a core.
- **A pool's records and its buffers in one structure.** A pool's lock, generations and free stack are
  control data that must not be cached where two cores use them; its buffers may be. With `.shared`
  uncached they share it; a board that caches the buffers will need the pool's storage in a region of
  its own. Settled with the H747I (milestone 9).
- **The H7's time base** in a two-image build: core 0's tick counter in `.shared` works; a shared
  hardware timer may be better.
