# Instrumentation specification

This document is the harness-generation handoff for private WAIT, WAKE and
REQUEUE at Asterinas `0c60537098f4c2949ad2d382aaf499de72263d76`.
Produce short, complete attempts with proved enrollment and SMP >= 2. The
reference specification is Category B and replays per-thread timeboxes.
The revision validates synthetic fixtures only. Kernel instrumentation and
implementation trace collection remain unexecuted.

## 1. Trace event schema

Store normalized attempts in `../traces/trace.ndjson`, relative to this file.
`Trace.tla` uses that default and accepts an `IOEnv.JSON` override. The first
NDJSON record is a manifest. Subsequent records are events in each thread's
sequence order. Their inter-thread file order has no semantics. `Trace.tla`
groups them into per-thread arrays before replay.

A manifest has the following fields. The identity example is a schema example,
not captured evidence. The harness must fill it from the running kernel.

```json
{"tag":"manifest","schema":"private-futex-v3","source":"0c60537098f4c2949ad2d382aaf499de72263d76","tree":"4693fdec88cd7da14bed4f1541eba593f123059c","cpu_count":2,"complete_attempt":true,"wait_ids":[1,2],"call_ids":[1],"controllers":["p"],"keys":["A","B"],"buckets":[17,93],"bucket_of":{"A":17,"B":93},"initial_words":{"A":0,"B":0},"values":[0,1],"quotas":[0,1,2],"durations":[{"timed":false,"ticks":0},{"timed":true,"ticks":0},{"timed":true,"ticks":1}],"wait_pids":{"1":"waiter-1","2":"waiter-2"},"call_pids":{"1":"controller-1"},"call_actors":{"1":"p"},"timer_pids":["timer-cpu-0","timer-cpu-1"]}
```

The manifest must also retain evidence metadata outside the model domains:
actual kernel image/source identity, VMAR identity, the aligned address for each
key label, actual CPU and bucket counts, monotonic clock unit, raw-to-normalized
ID mapping, trace-loss counters, and build/instrumentation identity. Validate
that metadata in preprocessing. Do not claim that SANY or `Trace.tla` verifies
the kernel image or hash calculation. The TLA+ manifest checks the source pin,
schema, declared domains, and SMP floor. `bucket_of` must come from actual
lookup/enqueue probes. Distinct addresses do not establish distinct buckets.

Each event uses this envelope:

```json
{"tag":"trace","event":"FutexWaitLoad","pid":"waiter-1","seq":3,"cpu":0,"start":10,"end":12,"deps":[],"args":{"g":1},"state":{"pc":"compare","observed":0}}
```

| Field | Meaning and required check |
|---|---|
| `event` | Exact base action name from section 2. Each has one trace wrapper. |
| `pid`, `seq` | Logical execution stream and contiguous sequence starting at 1. A user thread retains one stream through all of its calls. Timer contexts use separately identified streams. |
| `cpu` | Actual CPU, checked against the manifest's CPU count. SMP >= 2 is mandatory for admitted campaign traces. |
| `start`, `end` | Closed timebox around the semantic step. Include the atomic operation or protected branch that supplies the captured result. Compress order, not protocol time arithmetic. |
| `deps` | Sequence of `[pid,seq]` predecessors proved by lock handoff, timer publication, or explicit harness synchronization. All references must resolve. |
| `args` | Exactly the parameters listed for that action. Extra visit arguments constrain entry identity or the attempted branch. Missing and extra argument fields are rejected. |
| `state` | Exactly the post-state record defined by `WaitPost`, `CallPost`, or `PostState`. Equality checks its values and its complete field domain. No field is optional. |

The common action arguments are `g` for a unique WAIT generation and `c` for
a unique control-call generation. `a` is a reusable controller actor. `k,v,d`
are private key, expected/stored word, and relative duration. A control call
uses `kind,src,dst,nw,nm` with raw syscall quotas. `kind` is `wake` or
`requeue`. A WAKE record uses `dst=src` and `nm=0`. Identity must not come
from a reused waker pointer alone. Assign a new generation for each attempt.

| Captured state | Implementation evidence and TLA+ mapping |
|---|---|
| `pc`, `callback`, `waiterPC` when applicable | The reached branch/milestone of the named function, encoded with the exact strings in `base.tla`. These are instrumentation labels, not kernel fields. Emit the branch actually taken. |
| `key`, `entryKey`, `original`, `bucket` | Actual private identity and bucket lookup. `original` maps the immutable saved bucket. Entry keys follow updates even when the generation remains unchanged. |
| `observed`, `expected`, `word` | Values returned by the atomic load or written by the user store. Do not reload user memory to manufacture a snapshot under a bucket lock. |
| `queue`, `sourceQueue`, `destQueue` | Ordered generation sequence of logical bucket entries, reconstructed from the protected vector view and iterator progress. See the retain/extract note below. |
| `owner`, `transfer` | The bucket, extracted local item, or removal path observed at that event. Encode owners as `["bucket",index]`, `["transfer",call_id]`, `["local",0]`, or `["none",0]`. `transfer` is a positive generation ID or integer `0` for absence. A cleanup miss does not read a remote bucket's owner. |
| `lockOwner` | Acquisition/release evidence encoded as `["wait",g]`, `["call",c]`, or `["none",0]`. Sample/update the probe record at the handoff, not later. |
| `rawWake`, `rawMove`, `effective`, `wakes`, `moves`, `index` | Actual dispatch inputs and loop locals. Loop index is normalized to 1-based logical surviving-vector position, not the vector's transient compaction offset. |
| `accepted`, `flagWritten` | The return and written value of the particular atomic swap. Acceptance is the negation of the old flag. Never infer acceptance from a later load of `has_woken`. |
| `duration`, `deadline`, `now`, `timerState` | Relative input, actual timer deadline and monotonic samples. `timerState` reflects none/armed/expired/cancelled milestones. Encode duration as `{"timed":false,"ticks":0}` or `{"timed":true,"ticks":n}`. Positive duration begins at the `TimerSetClock` read, independently of later publication. `sample` is the saved integer clock read. |
| `timerLock`, `localRef`, `callbackRef`, `cancelled` | Timer guard ownership, local Arc lifetime, weak-upgrade result/strong callback lifetime, and cancellation store. Do not equate canceled weak heap nodes with strong Waker ownership. |
| `pause`, `cleanup`, `result`, `closed`, `returns` | Result paths and explicit return/drop markers. `cleanup` is found/miss by Arc identity. Normalize ETIME to ETIMEDOUT at the syscall boundary. Retain the restart branch as a model inconsistency in this signal-free scope. |
| `actor`, `activeCall`, `stores` | Per-controller active call and user-store sequence derived from actual invocation/return/store events. `actor` is a singleton array containing the controller label, or an empty array before admission. `activeCall`, `waiter` and `transfer` are positive integer IDs or integer `0` for absence. These counters cannot be inferred from ready flags. |

Derived observers such as registration/removal counts, notification history,
noise epochs, Linux same-address processed count, and cohort/moved sets are
computed by the base actions from the recorded events. They are not claimed
to be kernel fields. The trace post-state projections check the actual changed
implementation fields and branch locals that establish those observers.

## 2. Action-to-code mapping

Source aliases below resolve within the pinned source checkout:

| Alias | File |
|---|---|
| F | [private futex implementation](../../source/kernel/core/src/process/posix_thread/futex.rs) |
| S | [syscall dispatch](../../source/kernel/core/src/syscall/futex.rs) |
| P | [pause_timeout](../../source/kernel/core/src/process/signal/pause.rs) |
| W | [Waiter and Waker](../../source/ostd/src/sync/wait.rs) |
| Q | [scheduler parking contract](../../source/ostd/src/task/scheduler/mod.rs) |
| T | [timer implementation](../../source/kernel/core/src/time/core/timer.rs) |
| TW | [timeout wrapper](../../source/kernel/core/src/time/wait.rs) |
| thread_local.rs | [recoverable fault bridge](../../source/kernel/core/src/process/posix_thread/thread_local.rs) |

The event name equals the base action name. Each row identifies the trigger
and required state fields. The exact expression is in `Trace.tla`. `none`
and all PC strings use the spelling in `base.tla`.

### Waiter and timer steps

| Action and event | Code and trigger | Arguments | Required post-state fields |
|---|---|---|---|
| `SysFutexWait` | `F:78-80; S:55-83; W:181-189`. After private-key and waiter creation, before bucket acquisition. | `g`, `k`, `v`, `d` | `pc`, `key`, `original`, `expected`, `duration`, `entryKey`, `owner` |
| `FutexWaitLock` | `F:83-88`. Immediately after bucket lock acquisition. | `g` | `pc`, `bucket`, `lockOwner` |
| `FutexWaitLoad` | `F:86-90`. After successful atomic_load, using its returned word. | `g` | `pc`, `observed` |
| `FutexWaitFault` | `F:86-93; thread_local.rs:116-135`. After the load reports a recoverable fault, before dropping the guard. | `g` | `pc` |
| `FutexWaitFaultUnlock` | `F:93`. At guard release on the retry path. | `g` | `pc`, `bucket`, `lockOwner` |
| `HandlePageFault` | `F:95-104`. After successful fault resolution, before reacquiring the bucket. | `g` | `pc` |
| `FutexWaitCompare` | `F:107-112`. At the branch using the previously loaded value. | `g` | `pc`, `observed`, `result` |
| `FutexWaitMismatchUnlock` | `F:107-112`. At bucket guard and unregistered local-item drop on EAGAIN. | `g` | `pc`, `bucket`, `lockOwner`, `owner` |
| `FutexBucketAddItem` | `F:114,473-475`. After Vec push while the original bucket remains locked. | `g` | `pc`, `bucket`, `queue`, `owner` |
| `FutexWaitUnlock` | `F:116-119`. At release after publication, before pause_timeout. | `g` | `pc`, `bucket`, `lockOwner` |
| `PauseTimeoutCheck` | `P:171-177; TW:72-79; T:178-184`. After check_expired chooses never, zero, or positive relative timeout. | `g` | `pc`, `pause`, `timerState`, `deadline` |
| `TimerSetClock` | `T:67-68`. Capture the local read used by this WAIT generation's deadline calculation. | `g`, `t` | `pc`, `sample`, `now` |
| `TimerSetTimeout` | `TW:160-166; T:68-82,188-192; P:172-176`. At timer publication after acquiring the heap lock. Use this generation's saved read, even if publication was delayed. | `g` | `pc`, `timerState`, `deadline`, `localRef`, `sample` |
| `WakerDoWait` | `W:273`. After the Acquire swap, preserving its old value as the branch evidence. | `g` | `pc`, `flagWritten` |
| `WaiterPark` | `W:274; Q:441-486`. At the scheduler closure's flag recheck and park decision. | `g` | `pc` |
| `WaiterSpuriousReturn` | `Q:441-444; W:272-275`. On return from parking without a modeled unpark transition. This changes only the waiter PC. The next swap is still a separate `WakerDoWait` event. | `g` | `pc` |
| `PauseTimeoutTimerLock` | `P:202-204`. After acquiring the timer guard. | `g` | `pc`, `timerLock` |
| `PauseTimeoutNoTimer` | `P:202-221`. On the no-timer, no-signal completion branch. | `g` | `pc`, `pause` |
| `PauseTimeoutClock` | `T:106`. Capture the local read in this generation's remain invocation, while the timer guard is held. | `g`, `t` | `pc`, `sample`, `now` |
| `PauseTimeoutRemain` | `P:204-208; T:107-112`. At remain().is_zero(), using the saved read rather than the newest global observation. | `g` | `pc`, `pause`, `sample` |
| `TimerCancel` | `P:207-208; T:87-90,253-255`. After the cancellation store, still holding the timer lock. | `g` | `pc`, `cancelled`, `timerState` |
| `PauseTimeoutTimerUnlock` | `P:202-221`. At timer-guard release on both return paths. | `g` | `pc`, `timerLock` |
| `PauseTimeoutTimerDrop` | `P:202-221`. At dropping pause_timeout's local Arc<Timer>. | `g` | `pc`, `localRef` |
| `TimerCollectClock` | `T:200-206`. Capture `current_time` once after taking the heap lock for a nonempty collection batch. | `t`, `batch` | `active`, `sample`, `now`, `ready` |
| `TimerCollect` | `T:207-215`. At `peek`/`pop` of a minimum-deadline pending node (`T:299-304`), including cancellation removal. Cancellation retains the original deadline (`T:253-255`). Bind expiry to the saved `current_time`. | `g`, `batch` | `callback`, `timerState`, `sample`, `ready` |
| `TimerCollectEnd` | `T:213-218`. On loop exit and heap-guard release. Retain this invocation's vector and execution identity until its callbacks drain. | `batch` | `active`, `sample`, `ready`, `callbackStates`, `pending` |
| `TimerCallbackUpgrade` | `T:220-221,262-265`. Start only the next callback from this invocation. A failed weak upgrade returns immediately and advances `pending`. | `g`, `batch` | `callback`, `callbackRef`, `pending` |
| `TimerCallbackLock` | `T:267`. After callback acquires the timer lock. | `g`, `batch` | `callback`, `timerLock`, `pending` |
| `TimerCallbackCheck` | `T:269-272`. After testing cancellation under the timer guard. | `g`, `batch` | `callback`, `pending` |
| `TimerCallbackWake` | `P:174-175; W:262-265`. Immediately after the callback's wake flag swap. | `g`, `batch` | `callback`, `accepted`, `flagWritten`, `pending` |
| `TimerCallbackUnpark` | `W:266; P:174-175`. At scheduler unpark-target processing for an accepted timer wake. | `g`, `batch` | `callback`, `pending` |
| `TimerCallbackFinish` | `T:220-221,262-281`. After invocation/cancel branch, releasing guard and strong callback reference before advancing `pending`. | `g`, `batch` | `callback`, `callbackRef`, `timerLock`, `pending` |
| `FutexCleanupLock` | `F:124`. After acquiring the saved original bucket for cleanup. | `g` | `pc`, `bucket`, `lockOwner` |
| `FutexRemoveByWaker` | `F:124,477-482`. After identity lookup and optional swap_remove, under the original lock. | `g` | `pc`, `bucket`, `queue`, `cleanup` |
| `FutexCleanupUnlock` | `F:124`. At the temporary cleanup guard's release. | `g` | `pc`, `bucket`, `lockOwner` |
| `FutexWaitDecide` | `F:125-139; S:136-139`. After cleanup-result selection, before waiter drop. Normalize ETIME to ETIMEDOUT. | `g` | `pc`, `result` |
| `WaiterDrop` | `W:244-248,278-281`. After the closure swap. Capture the written value, not a later atomic load. | `g` | `pc`, `closed`, `flagWritten` |
| `SysFutexWaitReturn` | `S:81-83,136-143`. At the syscall exit for this generation. | `g` | `pc`, `result`, `returns` |

### WAKE and REQUEUE steps

| Action and event | Code and trigger | Arguments | Required post-state fields |
|---|---|---|---|
| `SysFutexControl` | `S:97-117,146-150; F:353-366`. After dispatch conversion and key lookup, before the first lock. | `c`, `a`, `kind`, `src`, `dst`, `nw`, `nm` | `pc`, `actor`, `kind`, `src`, `dst`, `rawWake`, `rawMove`, `effective`, `activeCall` |
| `LockBucketPairsFirst` | `F:398-427; F:165-168`. After the lower-index acquisition, or the single WAKE/same-bucket acquisition. | `c` | `pc`, `bucket`, `lockOwner` |
| `LockBucketPairsSecond` | `F:416-424`. After higher-index acquisition while still holding the lower lock. | `c` | `pc`, `bucket`, `lockOwner` |
| `FutexWakeStart` | `F:368,485-488`. Before retain begins, with all operation buckets locked. The cohort observer is derived from enrollment and notification events. | `c` | `pc`, `sourceQueue` |
| `FutexItemWake` | `F:488-495; W:262-265`. One retain visit. For matching entries below quota, capture wake swap's return before unpark. | `c`, `g`, `attempted` | `pc`, `index`, `waiter`, `accepted`, `flagWritten` |
| `FutexWakeUnpark` | `W:266-268; F:489`. At scheduler unpark-target processing for an accepted futex wake. | `c`, `g` | `pc` |
| `FutexWakeRetain` | `F:489-495`. After retain's keep/remove decision and count update. Queue is the logical survivor sequence while retain compacts storage. | `c`, `g` | `pc`, `index`, `wakes`, `queue`, `owner` |
| `FutexWakeEnd` | `F:353-354,368-379`. After retain finishes and dispatch selects shortcut/same/cross migration. | `c` | `pc`, `index`, `wakes` |
| `FutexUpdateItemKey` | `F:500-511`. After each item visit and the post-visit quota comparison. | `c`, `g` | `pc`, `index`, `moves`, `entryKey` |
| `FutexExtractItem` | `F:520-529`. After an extract_if visit. On extraction, keep a generation token for the yielded item. | `c`, `g` | `pc`, `index`, `moves`, `transfer`, `queue`, `owner` |
| `FutexExtractedKey` | `F:530-531`. After changing the extracted item's key, before destination append. | `c`, `g` | `pc`, `entryKey`, `owner` |
| `FutexAppendExtracted` | `F:532,473-475`. After destination append, while both locks remain held. | `c`, `g` | `pc`, `transfer`, `queue`, `owner` |
| `FutexMoveEnd` | `F:502,521-533`. At iterator exhaustion. A post-visit quota break uses FutexUpdateItemKey instead. | `c` | `pc` |
| `FutexRequeueFinish` | `F:368-381`. After locked work finishes, before releasing either bucket. The exhaustion observer is derived here. | `c` | `pc`, `wakes`, `moves`, `sourceQueue`, `destQueue` |
| `FutexReleaseDest` | `F:370-381`. At destination guard release, which precedes source guard release. | `c` | `pc`, `bucket`, `lockOwner` |
| `FutexReleaseSource` | `F:170,381`. At source guard release. | `c` | `pc`, `bucket`, `lockOwner` |
| `SysFutexControlReturn` | `F:170,381; S:142-143`. At syscall exit. Record the raw kernel return. | `c` | `pc`, `result`, `activeCall` |

### Environment observations

| Action and event | Code and trigger | Arguments | Required post-state fields |
|---|---|---|---|
| `UserStore` | `Brief scenario 1, user atomic store before S:97-100`. After the user atomic store, before that actor invokes WAKE. | `k`, `v` | `key`, `word`, `stores` |
| `ClockAdvance` | `TW:143-155` or an independent monotonic-clock probe. Record global time without consuming or overwriting an operation or batch sample. The three timer reads use their dedicated events above. | `t` | `now` |

For `FutexItemWake`, the `attempted` argument is the actual key-match and
remaining-quota branch. The wrapper checks it against the pre-state. An
attempted wake requires `pc,index,waiter,accepted,flagWritten`. A skipped
entry requires exactly `pc,index`. The `g` argument in each scan event must
match the current vector entry. For unpark, retain, extracted-key and append
events it must match the call's saved item. These are precondition checks in
addition to the post-state checks.

The two unpark wrappers deliberately check only their calling thread's phase.
The target's `pc` is a remote thread-local/scheduler abstraction, unavailable
through `Waker::wake_up`. They still call the full base unpark action. The
subsequent target-side park or consume event validates the target's branch.
This is the only weakened check of a changed implementation-related field.
It does not omit the wake swap, its acceptance result, consumption or closure.

## 3. Special considerations

Capture into preallocated per-thread or per-CPU buffers. Do not add blocking
I/O, allocation, a global serialization lock, or user-memory copies under
bucket/timer locks. Flush and serialize after the attempt. Report and reject
buffer loss or missing event pairs. Kernel instrumentation must preserve the
safe/unsafe boundary: use existing OSTD facilities from safe kernel code.

Capture return values and immutable local copies adjacent to the operation.
For atomics, use the result and written value of that operation. Do not read
shared state later and label it as an atomic post-state. For protected queue
fields, copy the evidence while the production lock still protects it. A
nonblocking snapshot may follow the narrow timebox only if its consistency is
established. If snapshot collection can observe another transition, widen the
timebox to include that observation or capture the local mutation result.

`Vec::retain` and `extract_if` temporarily compact storage under exclusive
bucket ownership. The model sequence is the logical survivor list, with
unvisited items still present. The harness must reconstruct this sequence
from the captured original order, per-entry visits, removals and appends.
It must not read uninitialized/moved vector slots or assume a transient raw
vector length equals the model's logical length. `remove_by_waker` uses
`swap_remove`, so record the actual last-entry swap. These choices preserve
the subsequent migration order without promising FIFO to userspace.

Use actual enqueue markers to gate F01-F10 attempts. A userspace ready flag
before WAIT is insufficient. For F04, prove that the first remaining entry
is matching or unrelated as intended. For F07/F09, prove movement before
expiry/cleanup, preserve the original bucket separately, and observe closure.
The F09 live oracle requires two fresh, unwoken live waiters and no independent
expiry, notification or closure during the later (1,1) operation.

Clock observations and timebox timestamps serve different purposes. Dense
compression is allowed for `start/end` ordering only. For protocol `t`,
`duration`, and `deadline`, subtract one common time origin and use an exact
common unit so addition and deadline comparisons are preserved. Keep values
within the installed TLC integer range. Never round across an expiry boundary.
`TimerSetClock(g,t)` binds T:67 to that generation's `TimerSetTimeout`.
`PauseTimeoutClock(g,t)` binds T:106 to its `PauseTimeoutRemain`. Each read
advances the observed clock and saves a local sample. The consumer changes
neither the observed clock nor that sample. Equal samples are allowed.
`ClockAdvance(t)` records an independent observation and cannot substitute
for either required read. The v3 duration objects decode directly into TLA+
records. Arrays encode uniform string/integer owner tuples. No string sentinel
is compared with a numeric ID or duration.

`TimerCollectClock(t,batch)` binds T:206 to one heap-lock interval. `batch`
is the positive `seq` of that read event. Every pop, end, and callback event
carries that ID and the same execution `pid`. Here a timer `pid` identifies a
sequential execution context, not the waiter notified by the callback. The
trace retains the `(pid,batch)` association after heap release until the last
callback returns. A new collection on another context may overlap an
outstanding batch. The same sequential context cannot begin another collection
before its vector drains (`T:220-221`).

Every `TimerCollect` selects a minimum-deadline pending heap node before
checking cancellation or the saved sample (`T:207-215,299-304`). Equal deadlines
may be selected in either order. A cancelled node keeps its original deadline
and can be removed early only when it reaches the head. A future noncancelled
head ends the collection even if later nodes are cancelled. For example, after
sample 1 and a separate global observation of 2, the old batch may collect
deadline 1 but must leave a noncancelled deadline 2 for a new batch.

`ready` is the ordered vector of noncancelled generations popped in this
collection. A pop sets the callback to `collected`. `TimerCollectEnd` changes
those callbacks to `due` after releasing the heap lock (`T:217-221`). Its
`callbackStates` checks every released callback in vector order. `pending`
starts as that same vector and includes the executing callback until it returns.
Capture or reconstruct this invocation-local suffix from its loop position.
Every callback event must supply it as a mandatory post-state field, in addition
to `args.batch` and the envelope's `pid`. A successful upgrade leaves the head
in place through lock, cancellation check, wake and unpark. `TimerCallbackFinish`
removes it after guard/reference release. A failed upgrade returns at T:264 and
removes it in `TimerCallbackUpgrade`. Neither path may skip a later callback.

The base keeps each outstanding invocation's vector in `s.callbacks`, in a
slot named by its first collected generation. This name remains stable as the
head advances. The trace binds that slot to the concrete execution context and
batch, and clears the association only when its vector is empty. Finite slots
add no admission bound: every nonempty vector owns at least one unique admitted
generation. Empty collection attempts allocate no slot. A later collection
can replace `collect.ready` without replacing outstanding callback vectors.
Publication and another collection wait only for the heap-lock interval to end,
not for every outstanding batch to finish. Each callback still waits for its
own predecessor's return, including cancellation and weak-upgrade failure.

`WaiterSpuriousReturn` supplies the permitted sleep-to-wait scheduler return.
It does not change `hasWoken`, `notified`, `futexAccepted`, noise, accepted
counts or completion counts. Only the existing Waker swaps can accept or
consume a notification. A false retry swap and subsequent park must each be
recorded. No retry is collapsed and no kernel action is silent.

Per-thread order is mandatory. Derive bucket handoff edges from an acquisition
sequence observed under each existing lock, and similarly record timer guard
handoffs. Add timer publication-before-collection and callback-local causal
edges. Do not sort all CPU events by unsynchronized timestamps. If clock
comparability is unproved, use overlapping cross-CPU timeboxes and retain the
proved dependency edges. `ViablePIDs` searches the permitted interleavings.

Start each admitted trace with fresh generation IDs, empty scoped queues, no
active scoped timers/calls, and measured initial words. Keep unrelated processes
out of the selected private keys. Include every admitted WAIT and control call
through its return. `TraceFinishedState` rejects a consumed file with an
unfinished declared call. Incomplete enrollment, trace loss, a watchdog firing,
or unfinished calls are uncovered attempts, not kernel progress defects.

`Trace.cfg` keeps `PROPERTIES TraceMatched` enabled and adds the deliberate
reachability sentinel `TraceIncomplete`. A counterexample specifically to
`TraceIncomplete`, with all events consumed and all other invariants satisfied,
is a positive replay witness. Keep the witness and verify its final cursors.
A dead branch or `TraceMatched` temporal failure alone does not disprove replay:
TLC checks universal temporal properties, while timebox matching asks whether
at least one interleaving exists. If the checker stops on a temporal failure
before exploring the remaining graph, the receiver must continue the bounded
reachability search before calling the trace invalid. Do not report the
sentinel failure as a kernel bug, and do not count an unrelated invariant
failure or process exit code as replay success.

Trace replay enables structural/core safety properties and leaves the candidate
resource, quota-compatibility and live-migration oracles to hunt configs. This
lets a real source behavior validate the implementation model even if a later
hunt property rejects that behavior. Empty findings remain a valid campaign
outcome. Linux compatibility still needs controls from an identified running
Linux kernel, separately from the pinned source oracle.

The user authorized this revision's TLC and synthetic replay checks at at most
2 GiB, two workers, one process at a time and 20 minutes per run. Logs are in
`generation-checks/` and metadata is in `../states/`. This authorization does
not extend to kernel instrumentation, builds, guests or confirmation.

