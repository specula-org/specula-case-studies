# Instrumentation for local flock ownership

This document specifies the events needed to replay the pinned Asterinas flock
implementation with `Trace.tla`. It is a handoff to harness generation. No source
instrumentation, runtime trace, Linux control or kernel execution was performed
by spec generation. Instrument the same ordinary ramfs/tmpfs inode throughout a
case. Use the source pin `0c60537098f4c2949ad2d382aaf499de72263d76`.

## 1. Trace event schema

Collect separate per-thread NDJSON streams. Preserve each thread's program
order and bracket each modeled step with a comparable `[start, end]` interval.
Do not use a globally locked logger or a global per-event sequence counter.
Compress timestamps by one monotone mapping over all streams. Preserve equal
timestamps, all interval ordering and every event. Do not sort overlapping
operations into a fabricated global execution order.

The default `../traces/trace.ndjson` is the preprocessed artifact: one JSON
object on one NDJSON line, containing the per-thread arrays below. This is
compatible with `JsonDeserialize`. Raw streams are separate retained evidence.
`IOEnv.JSON` overrides the preprocessed input path. Trace files are siblings of
`spec/`, under `traces/`. The following is a schema illustration, not a trace or
a claim of execution:

```json
{
  "schema": 1,
  "source": "0c60537098f4c2949ad2d382aaf499de72263d76",
  "inode": "fixture-inode",
  "threads": [1, 2, 3],
  "ofds": [11, 12, 13],
  "fds": [1, 2, 3, 4],
  "tokens": [1, 2, 3, 4, 5, 6, 7, 8],
  "sharedTable": true,
  "concurrent": true,
  "smp": 2,
  "traces": {"1": [], "2": [], "3": []}
}
```

Each array entry has the envelope below. `args` and `state` are required even
when `args` is empty. The action name is the event name, exactly as spelled in
the mapping table. `Trace.tla` dispatches to the complete corresponding base
action, then compares `state` with `PostState(t, event)` by exact equality.
There are no optional state-field checks and no silent state-changing actions.

```text
{
  "tag": "trace",
  "event": ACTION_NAME,
  "tid": THREAD_ID,
  "inode": "fixture-inode",
  "start": COMPRESSED_START,
  "end": COMPRESSED_END,
  "args": ACTION_ARGUMENTS,
  "state": {"thread": LOCAL_THREAD_RECORD, ...ACTION_FIELDS}
}
```

`ViablePIDs` permits a next event only when no other pending event finished
strictly before it started. Overlapping intervals allow either order. Each
thread has its own cursor `l[t]`. There is no global file-order cursor.
`TraceNoWitness == ~(ThreadsWithEvents = {})` is enabled as a search invariant
in `Trace.cfg`. Its violation supplies a behavior consuming every event under
the full base guards and exact post-state checks. A stalled candidate does not
reject a trace. Only exhaustive search without a witness rejects it. No fairness
assumption or silent kernel action participates in this finite reachability search.

This follows the installed Specula 1.2.0
`tla-trace-workflow/references/validation.md`, “Category B: Validation Behavior”:
accept a complete interleaving and reject only when none exists. The generic
`PROPERTIES TraceMatched` prerequisite in that guide and `validation-workflow`
would instead require every candidate to finish. R3 replaces that prerequisite.
The installed `tools/trace_debugger/src/tla_mcp/handlers/trace_validation.py`
also interprets raw TLC no-error output as success. It must not parse this
witness search directly. Use the executable adapter, which emits the same
Phase 3 `success`, `trace_mismatch`, and `error` JSON statuses without manual
reinterpretation:

```sh
cd spec
python3 generation-checks/validate_trace.py generation-checks/fixtures/r3-overlapping-acquires.json
```

The exact underlying command, also saved in each adapter result, is:

```sh
JSON=generation-checks/fixtures/r3-overlapping-acquires.json timeout 1800 /nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java -Xmx3g -XX:+UseParallelGC -DTLA-Library=. -cp /home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 2 -noGenerateSpecTE -metadir ../states/trace-r3-overlapping-acquires -config Trace.cfg Trace.tla
```

TLC exit 12 with only `Invariant TraceNoWitness is violated` means **accepted**.
The counterexample is the complete matching witness. The adapter returns
`success` and exits 0. TLC exit 0 with `Model checking completed. No error has
been found.` means **rejected**, because every candidate was explored without
finding a witness. The adapter returns `trace_mismatch` and exits 1. Any other
invariant violation, parser/evaluation failure or timeout returns `error`
(adapter exit 2). A timeout is `INCOMPLETE`, never an acceptance or rejection.
`CHECK_DEADLOCK FALSE` remains necessary so one dead-end candidate cannot stop
the search. Keep every existing safety invariant and post-state check enabled.

### Identity, bootstrap and endpoints

Normalize thread, OFD, FD and token identities to positive integers, preserving
the original identity map. JSON object keys are strings, so `traces` uses the
decimal thread name as its key, while `tid` and all identity values are integers.
`Trace.tla` checks the exact key domain and uses `ToString(t)` only for that
lookup. This avoids TLC comparing a JSON string identity with the base's integer
zero sentinel. No event or post-state field is dropped by this normalization.

The trace starts before the fixture's opens. `Init` has no descriptors, live
OFDs, queues or lock context. The stable ordinary inode already exists. Remap
only the fixture's numeric descriptors to ordered integer slots, preserving
lowest-free allocation and reuse of the same numeric descriptor. Distinguish
an OFD allocation from both its inode and its FD number. Dup retains the OFD
identity. Give each new request item a fresh queue token. Its installed clone
uses that same token. A blocking request's waker also uses the request token
as its stable name, including stale entries after closure. Never reuse a token
inside a trace. Include all domains in the header, including initially unused
OFDs/FDs/tokens, so subsequent allocations do not change the model's domains.

Store raw-to-normalized identity mappings, source/build hashes, actual Rust
build toolchain, kernel/filesystem identity, guest command line and observed
CPU count with the raw trace evidence. `smp` is an observed guest property,
not merely a requested QEMU option. Concurrent C04/C06–C12 claims require
SMP >= 2 and the actual registration/reference windows. Sequential C01–C05
controls can set `concurrent` to false. A borrowed-table control sets
`sharedTable` to false and declares exactly one participating thread. The base
states this domain assumption separately from syscall entry. The shared-table
entry events `SysOpen` and `SysFlock` do not test `tableOwner`. Serialization
is at `FileTableInsert`, `SysDup`, `SysClose`, and the two `GetFileFast` outcomes.

Record in a separate case manifest whether the file is a complete case or a
preserved prefix, the syscall returns that were observed, the last captured
boundary and any dropped-buffer count. An accepted witness means all supplied
events match. It does not mean a pending syscall completed or a watchdog established
deadlock. A C11 prefix ending after `FlockListUnlockEnter` can be a valid replay
while still needing the independent source/runtime disposition.

### State fields

The `thread` field is mandatory for **every** event. It is the full local record
in `BlankThread` / `s.th[tid]`, not a shared-memory snapshot. Maintain this
projection in a per-thread trace buffer from local values and observed control
flow. Fields that are merely control labels or continuations are trace-local
shadows. Owner/queue identities, return outcomes and reference primitive
outcomes must come from the real operation. Do not obtain them by running the
TLA+ model in the preprocessor.

| Local fields | Implementation observation |
|---|---|
| `pc`, `kind`, `fd`, `mode`, `nb`, `result` | Exact before/after hook, syscall input and result. `WAIT` denotes an internal blocking EAGAIN, not a userspace return. `OK`, `EAGAIN`, `EBADF` are otherwise unambiguous. |
| `request`, `captured`, `callRef` | The captured file allocation and whether `get_file_fast!` owns a cloned Arc. `captured` remains immutable until the next admission resets the local record. |
| `pending`, `temp` | The original open-local Arc, the reference transferred to ClosedFile, or the successful Weak upgrade's temporary owner. Open keeps `pending` through insertion and `on_open` until `ArcPutOpen`. Close clears it at `ClosedFileDrop`. |
| `rid`, `target`, `scan`, `remove`, `replace` | Request queue identity, current unlock target, one-based retain index, retain result and same-owner replacement index. Removal keeps the scan index. Retention advances it. |
| `drainQ`, `drainTo`, `popped` | Current synchronous `wake_all` queue, its caller's continuation, and the popped waker whose wake/enqueue has not finished. Clear the pending waker only at the base action's boundary. |
| `dtor`, `stack` | Actual destructor object and synchronous caller frames. Each frame is `{resume,target,scan,dtor}`. Save before a last put and resume only after destructor return. Do not infer an entered destructor from a timeout. |

Use `0` for absent identities, JSON booleans for flags and JSON arrays for
sequences, including empty stacks and queues. Fields cannot be omitted when
zero or false. Preserve all local fields unchanged unless the matching base
action changes them. Admission actions reset the local record as specified in
`base.tla`. Retain captured identity and result through `SysFlockReturn`.

The following packets appear only on the actions listed in the table below.
Their spelling and shape are enforced by `PostState`:

| Packet | Exact fields and capture requirements |
|---|---|
| `ref` | `{ofd,strong,life}`. `strong` is the count at the relevant Arc/Weak primitive's linearization point. `life` is `live`, `destroying` after the actual last decrement, or `dead` after payload cleanup returns. For `FlockOwnerExpired` only, the packet is `{ofd,strong}`: Weak upgrade observes zero but cannot distinguish a pending destructor from a finished one. That event changes no lifecycle state. Never dereference expired payload memory to invent that distinction. |
| `fd` | `{fd,owner}` after the table mutation. Capture while the original table guard still protects the mutation, or retain its assigned value in the local event buffer. |
| `tableOwner`, `listOwner` | Guard holder after acquisition/release, or `0`. These are instrumentation shadows of actual successful acquisition and guard release, not an extra Mutex. A release records its own write outcome rather than rereading a later contender's ownership. |
| `items` | Ordered `{owner,mode,q}` entries after append, install or removal. Capture under the existing list guard. |
| `blocker` | The exact first conflicting `{owner,mode,q}` read under the list guard. |
| `queue` | `{id,entries}` after enqueue/pop, preserving duplicate waker tokens and order. Copy under the queue's existing spinlock, then serialize outside it. |
| `waker` | `{id,tid,notified,closed}`. Capture the atomic swap outcome and recorded close state for that waker identity. `closed` is a trace shadow, since production represents closure by setting `has_woken`. |
| `rq` | `{id,owner,runnable}` for the targeted waker/task. `owner` denotes the guard protecting this task's check/dequeue bridge. It is a per-target projection of the real CPU runqueue lock, not a new lock. |
| `consumed`, `accepted`, `sawNotification` | Boolean values returned/read by the exact wait swap, wake swap or park recheck. They must not be replaced by a later load. |
| `context`, `token`, `fresh`, `selfHeld` | Context presence, new queue ID, successful fresh allocation, and whether this thread still holds its own outer list guard at an unlock attempt. `selfHeld` can be captured from local guard depth without reading another thread's state. |

Arc counts cannot be reconstructed from FD count alone or obtained by cloning
the owner for logging. For exact reference packets, use narrowly filtered hooks
at the installed Rust Arc/Weak primitives: preserve the old value returned by
the real fetch-add/fetch-sub/successful upgrade CAS, record the resulting count,
and attach that observation to the relevant owner event. A `strong_count()`
load made later is insufficient under concurrency. The pinned installed source
is `alloc/src/sync.rs:2132-2143,2850-2855,2896-2898,3299-3327`; locate and pin
the corresponding clone primitive in the actual build toolchain as well.

Place such low-level hooks in the allowed runtime/OSTD boundary. Keep `kernel/`
safe Rust. They must record stable scalar identity and primitive outcomes into
preallocated per-thread storage, with no extra Arc, Weak upgrade, shared logger
lock or allocation. Capture the last-decrement event before invoking the payload
destructor, then record the real `InodeHandleDropEnter` and return. The source
model does not authorize replacing the production put with a deferred put.
A harness unable to observe these counts and destructor boundaries must preserve
that limitation and return for a reviewed instrumentation/TraceSpec revision.
It must not synthesize fields from the expected model or remove their checks.

Take the operation's end timestamp before serialization. Retain atomic result
values and local continuation data rather than rereading mutable fields later.
Where a protected aggregate must be copied after the interval, keep its existing
production guard until the copy is captured. Do not acquire a new lock or extend
the interval across an entire blocking syscall. Sampling multiple racy loads
cannot create a coherent post-state merely by assigning them one timestamp.

## 2. Action-to-code mapping

Paths without a prefix are relative to `kernel/core/src/`. Every row has exactly
one event type with the same name as its spec action. All rows require `thread`.
The last column lists additional mandatory `state` fields. Rows without extra
fields still validate the full local record. Function helpers such as `DropRef`
and `StartDrain` do not introduce extra event types.

| Action/event | Code location and precise trigger | `args` | Extra `state` fields |
|---|---|---|---|
| `SysOpen` | `syscall/open.rs:34-56,102-103`, `fs/vfs/path/mod.rs:169-207`. After the new file Arc exists, before acquiring the insertion guard. Another thread may hold the table guard. | `ofd` | `ref` |
| `FileTableInsert` | `syscall/open.rs:54-64`, `fs/file/file_table.rs:190-193`. Bracket clone, insertion and table-guard release. Capture the clone count and FD assignment under the guard. The original Arc stays in `pending`. | `fd` | `fd,ref` |
| `ArcPutOpen` | `syscall/open.rs:65-67`, Rust Arc drop. After `on_open` and the original Arc's decrement, before any synchronous payload destructor. | `{}` | `ref` |
| `SysOpenReturn` | `syscall/open.rs:66-67`. At syscall exit after the original Arc and any final destructor have finished. | `{}` | None |
| `SysDup` | `syscall/dup.rs:13-18`, `fs/file/file_table.rs:145-165,181-187`. Bracket clone plus installation within the existing table critical section. Capture the clone's count outcome. | `fd,newfd` | `fd,ref` |
| `SysClose` | `syscall/close.rs:22-27`, `fs/file/file_table.rs:196-205`. After removal into ClosedFile, before releasing the table guard. | `fd` | `fd,tableOwner` |
| `CloseFileTableUnlock` | `syscall/close.rs:28`. After dropping the table write guard, before ClosedFile drop. | `{}` | `tableOwner` |
| `ClosedFileDrop` | `fs/file/file_table.rs:292-298`, Rust Arc drop. After range-lock cleanup's empty fixture work and the file field's atomic decrement, before entering any payload destructor. | `{}` | `ref` |
| `SysCloseReturn` | `syscall/close.rs:35-44`. After ClosedFile and any synchronous final destructor finish. | `{}` | None |
| `SysFlock` | `syscall/flock.rs:12-16`. At entry, before lookup, even while another thread holds the table guard. | `fd,mode,nb` | None |
| `GetFileFast` | `fs/file/file_table.rs:355-360`, `syscall/flock.rs:16`. After borrow/clone capture and read-guard release. Retain the actual clone count outcome. | `{}` | `ref` |
| `GetFileFastBadFd` | `fs/file/file_table.rs:237-243`, `syscall/flock.rs:16`. Lookup returned EBADF, with no file reference. | `{}` | None |
| `UnlockFlock` | `syscall/flock.rs:19-20`, `fs/file/inode_handle.rs:242-251`. After determining whether the context exists, before an actual list lock attempt. | `{}` | None |
| `FlockItemNew` | `syscall/flock.rs:23-26`, `fs/file/flock.rs:29-36`. After creating the request's Weak owner and new queue. | `q` | `token,fresh` |
| `FsLockContextOrInit` | `fs/file/inode_handle.rs:233`, `fs/vfs/fs_apis/inode_ext.rs:73-78`. After obtaining the inode's once-initialized context. | `{}` | `context` |
| `WaiterNewPair` | `fs/file/flock.rs:147-148`, `ostd/src/sync/wait.rs:181-189`. After waker creation. Signal-hook setup is inert in this signal-free fixture. | `{}` | `waker` |
| `TrySetLockEnter` | `fs/file/flock.rs:115`, `ostd/src/sync/mutex.rs:35-36`. Immediately before attempting the Mutex, whether it will block or succeed. | `{}` | None |
| `TrySetLockAcquire` | Same sites, `ostd/src/sync/mutex.rs:62-65`. After actual successful acquisition, before list inspection. | `{}` | `listOwner` |
| `TrySetLockNonblockingConflict` | `fs/file/flock.rs:116-120`. After finding the first conflict without a supplied waker. Capture internal EAGAIN before guard release. | `{}` | `blocker` |
| `TrySetLockRegister` | `fs/file/flock.rs:116-120`, `ostd/src/sync/wait.rs:145-148`. After enqueue on the actual first blocker, while the list guard is still held. | `{}` | `blocker,queue` |
| `TrySetLockReplace` | `fs/file/flock.rs:122-124,78-81`. After selecting the same-owner slot and entering the old item's Drop, before draining it. | `{}` | None |
| `TrySetLockAppend` | `fs/file/flock.rs:126-127`. After storing the request clone, before guard release. | `{}` | `items` |
| `TrySetLockInstall` | `fs/file/flock.rs:124`. After the old-item Drop returns and assignment installs the new clone. | `{}` | `items` |
| `TrySetLockUnlock` | `fs/file/flock.rs:120,130-131`, `ostd/src/sync/mutex.rs:113-116`. After releasing the list guard, before wait preparation or return cleanup. | `{}` | `listOwner` |
| `WakerDoWait` | `ostd/src/sync/wait.rs:272-274`. Around the acquire swap to false. Capture its returned value, before invoking park or retrying. | `{}` | `waker,consumed` |
| `SchedulerParkCheck` | `ostd/src/task/scheduler/mod.rs:453-458`, `sched/sched_class/mod.rs:255-258`. After acquiring the existing runqueue guard and reading the notification. Retain the guard for the next boundary. | `{}` | `rq,sawNotification` |
| `SchedulerParkCommit` | `ostd/src/task/scheduler/mod.rs:469-485`, `sched/sched_class/mod.rs:410-414`. After dequeue and release of the runqueue guard. Record in preallocated storage before the task stops executing. | `{}` | `rq` |
| `SchedulerParkAbort` | `ostd/src/task/scheduler/mod.rs:455-456`. The recheck saw notification. After dropping the runqueue guard without dequeue. | `{}` | `rq` |
| `SchedulerResume` | `ostd/src/task/scheduler/mod.rs:476-480`, `ostd/src/sync/wait.rs:273`. On the real task's return from park, before the next wait swap. | `{}` | None |
| `WaiterClose` | `ostd/src/sync/wait.rs:244-249,278-281`. At the actual close swap to true after successful blocking acquisition. | `{}` | `waker` |
| `FlockItemDropRequest` | `fs/file/flock.rs:139-157,78-81`. At local request destruction, after the list guard is gone, before draining its shared queue. | `{}` | None |
| `WaitQueuePop` | `ostd/src/sync/wait.rs:119-126`. After removing one waker and releasing the queue spinlock, before its wake swap. Capture the post-pop sequence while protected. | `{}` | `queue` |
| `WakerWakeUp` | `ostd/src/sync/wait.rs:262-266`. At the release swap to true. Capture acceptance before scheduler enqueue. A closed/notified waker is a no-op outcome. | `{}` | `waker,accepted` |
| `SchedulerUnpark` | `ostd/src/task/scheduler/mod.rs:488-493`, `sched/sched_class/mod.rs:223-250`. After enqueue or the existing-runnable recheck under the real runqueue guard. | `{}` | `rq` |
| `WaitQueueFinish` | `ostd/src/sync/wait.rs:113-115,121-123,133`. The actual empty check ends this drain. Return to its saved caller. | `{}` | None |
| `FlockListUnlockEnter` | `fs/file/flock.rs:166`, `ostd/src/sync/mutex.rs:35-36`. Immediately before the unlock scan attempts its Mutex. Emit even if it never acquires it. | `{}` | `selfHeld` |
| `FlockListUnlockAcquire` | Same sites, `ostd/src/sync/mutex.rs:62-65`. After successful acquisition, before retain starts. | `{}` | `listOwner` |
| `FlockOwnerUpgrade` | `fs/file/flock.rs:40-41,168`, Rust Weak upgrade at `alloc/src/sync.rs:3299-3327`. After the successful atomic increment, before comparing or dropping the temporary. | `{}` | `ref` |
| `FlockOwnerExpired` | `fs/file/flock.rs:178-179`, same Weak primitive. After the upgrade observes zero, before removing the expired item. | `{}` | `ref` |
| `FlockOwnerMatch` | `fs/file/flock.rs:169-174`. After pointer equality, before the explicit wake. The temporary Arc is still held. | `{}` | None |
| `FlockOwnerKeep` | `fs/file/flock.rs:175-176`. After pointer inequality, before temporary Arc drop. | `{}` | None |
| `ArcPutTemporary` | `fs/file/flock.rs:168-181`, Rust `alloc/src/sync.rs:2850-2855`. Around the temporary's atomic decrement, before any synchronous destructor entry. Preserve the outer guard and caller frame. | `{}` | `ref` |
| `FlockRetainContinue` | `fs/file/flock.rs:174-181`. Only after the temporary drop and any destructor have returned. Advance on retain or prepare removal. | `{}` | None |
| `FlockItemDropRemoved` | `fs/file/flock.rs:174,179,78-81`. After retain removes the item, at its Drop entry before queue drain. Both matching and expired branches emit it. | `{}` | `items` |
| `FlockListUnlockRelease` | `fs/file/flock.rs:181-182`, `ostd/src/sync/mutex.rs:113-116`. After the completed scan releases its list guard. | `{}` | `listOwner` |
| `ArcPutSyscall` | `syscall/flock.rs:16-34`, `fs/file/file_table.rs:355-360`, Rust Arc drop. After the owned syscall reference's decrement and before its possible destructor. The borrowed variant records no decrement. | `{}` | `ref` |
| `InodeHandleDropEnter` | `fs/file/inode_handle.rs:537-539`. At real payload Drop entry, before `unlock_flock` dispatch. Preserve a nested outer frame. | `{}` | None |
| `InodeHandleDropFinish` | `fs/file/inode_handle.rs:539-541`, Rust `alloc/src/sync.rs:2143`. After actual cleanup returns, before returning to the suspended caller. Use saved scalar identity, never dereference freed payload memory. | `{}` | `ref` |
| `SysFlockReturn` | `syscall/flock.rs:29-34`. At actual syscall exit, after local cleanup and any synchronous destructor. | `{}` | None |

## 3. Special considerations

One stored `FlockItem` and its local request clone share a queue. Replacement,
explicit wake, removed-item Drop and request Drop are distinct synchronous
calls. Preserve repeated drains and duplicate entries. A local request Drop
outside the list Mutex can wake a contender that immediately re-enqueues on
that still-installed item. The drain can pop that new entry. Do not replace a
drain with a one-time snapshot of its initial members.

Rust assignment drops the old slot value before installing the replacement.
The base retains the old list entry as a protected projection until install.
Capture the old queue ID before its destructor and the new ordered list after
assignment. Do not publish a synthetic new grant at old-item Drop entry.
During retain, the temporary Arc's drop precedes removal of a rejected item.
A last temporary drop can therefore suspend the retain closure indefinitely.
Do not emit `FlockRetainContinue` or guard-release events unless they occurred.

The base abstracts the list Mutex's internal waiter queue. Its acquisition is
still conditional on a free guard, including recursive requests. Do not map
those internal mutex wakers into flock item queues. Emit actual lock attempt,
success and release. The flock waiter's scheduler bridge remains explicit:
a wake swap may occur between a false park check and dequeue, but its enqueue
cannot pass the held runqueue guard. Capture those boundaries rather than
inventing a lost wake or merging notification with resume. Runqueue state is
keyed by task/thread, not waker allocation. An accepted wake delayed past an
old waiter close can make the same task runnable during a later wait. The new
waiter still checks its own notification and may park again.

For C11, finish B's earlier flock syscall before opening the temporary-reference
window. Retain no extra B alias or call reference unless it is the C12 alias
control. Logging must not clone B. Demonstrate the upgrade, FD removal,
ClosedFile put, last temporary put, held outer guard, real destructor entry and
nested attempt. Keep partial traces if that attempt never returns. The shared
resource policy requires bounded execution and SMP >= 2, but watchdog expiry
by itself is not this evidence.

Arbitrary signals, restart, cancellation, OOM, queue-overflow faults and process
exit are outside the fixture. A signal or spurious scheduler return that cannot
be explained by the modeled wake path is a trace-scope mismatch. Preserve it
and arrange a reviewed scope/model correction instead of inserting a silent
retry. No latency or FIFO claim follows from a matching trace.

Run sequential Linux controls C01–C05 against the fixed generic-local-flock
contract and record the actual runtime versions. `MC.LinuxStep` is only the
C05 source oracle. Asterinas TraceSpec always replays Asterinas retention on
failed conversion. It never rewrites the trace to match Linux.

Before any verification rerun after changing this schema, interpretation,
model/configuration semantics, oracle assumptions or harness behavior, follow
`resources.json.corrective_review_gate`: preserve old/new versions and hashes,
diff, reason and triggering evidence, obtain an independent exact-version
review, close material findings, and then renew affected verification/review.
If that review is unavailable, preserve the request and return incomplete to
the controller. Do not reacquire the controller-held heavy-stage lock.
