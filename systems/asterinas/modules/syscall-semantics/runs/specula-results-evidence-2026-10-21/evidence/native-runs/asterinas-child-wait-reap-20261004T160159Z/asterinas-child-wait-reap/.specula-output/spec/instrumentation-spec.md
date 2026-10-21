# Instrumentation specification

This document is the harness-generation handoff for the one-child wait/reap fixture at Asterinas commit `0c60537098f4c2949ad2d382aaf499de72263d76`. It specifies how to collect the 41 events consumed by `Trace.tla`. No kernel instrumentation or runtime trace was produced during spec generation.

Use the established single-threaded child, a live parent with two waiting threads, its positive PID, normal exit, fixed credentials, independent valid stable outputs of at least 128 bytes, and null rusage. Both parent threads must inherit blocked SIGCHLD, SIG_DFL, and no SA_NOCLDWAIT. Fork and thread creation finish before recording begins. Each invocation reinitializes its output: wait4 status is -999 and waitid's relevant fields are zero. Excluded signals, tracing, reparenting, PID reuse, exec, resource exhaustion, and copyout faults must not enter a primary trace.

Paths beginning `process/`, `syscall/`, `time/`, or `sched/` below are relative to `kernel/core/src/`. OSTD paths start at the source root. Verify the pin and source hashes before applying instrumentation.

## 1. Trace event schema

Collect events into preallocated per-task or per-CPU rings without a shared logging lock. Merge by the stable executing actor and per-actor order after the run. The two waiter actors are strings such as `w1` and `w2`. The exiting child actor is `child` and executes both notification paths. A wake event belongs to the notifier's stream, not to the target waiter's stream.

Every event has exactly these envelope fields:

| Field | Meaning and check |
| --- | --- |
| `tag` | The literal `trace`. Unknown or missing tags fail schema checks. |
| `actor` | The owner of the per-actor stream. It must agree with the containing array. |
| `event` | One base action name from the mapping table. |
| `start`, `end` | Nonnegative compressed timestamps bracketing the represented operation. `start <= end`. Events within an actor do not overlap. |
| `args` | The exact action-specific argument record described below. |
| `post` | The exact fields listed in the mapping table. `ValidatePostState` compares the entire record with `ExpectedPost`, including atomic return values. Missing, extra, or unequal fields fail. |

Every `args` record contains `call`. A waiter invocation is the pair `[actor, generation]`, with generation starting at 1 and increasing on each invocation by that actor. This is also its waker identity if a waiter is created. No-waker calls still have an invocation ID. For child events without a target use `[]`. Old queue entries retain their original pair even after the parent thread begins another call.

| Events | Additional argument fields |
| --- | --- |
| `SysWaitBegin` | `request` is exactly `{api, nohang, nowait}`. `pid` is the actual positive child PID. `which` is 1 for waitid P_PID and the normalization value 0 for wait4. Capture `options`, `rusage`, `buffer`, `initial` directly. Options are wait4 0/1 or waitid 4/5/16777220/16777221. The trace checks the bits against the request, rusage against 0, the pointer against metadata, and the initial output against the primary fixture. |
| `ProcessStoreExitCode` | `value` is the child's normal exit value, 0 through 255, agreeing with metadata. `call=[]`. |
| `WakeSignalledWakerGet`, `WakeSignalledWakerNone` | `thread` identifies the parent task being visited. Get captures the registered generation pair in `call`. None uses `[]`. |
| `WakerWakeUp`, `SchedulerUnparkTarget`, `WakerWakeFinish` | Only `call`, identifying the currently selected target generation. This remains the old target in WakeFinish even though its post-state clears the target. |
| `WaitQueueWakeAllPop` | Only `call`, identifying the entry actually popped. |
| Other waiter events | Only `call`, equal to that actor's current generation. |
| Other child events | Only `call=[]`. |

`out` and `initial` use the record `{pid, uid, signo, siCode, status}`. For wait4 only status corresponds to a user buffer field. The other four fields are normalization zeros and child identity is checked through the selected PID and return. For waitid these are the actual `si_pid`, `si_uid`, `si_signo`, `si_code`, `si_status` fields. Do not compare padding or unrelated union bytes. Normal-exit output has SIGCHLD 17 and CLD_EXITED 1 in the selected ABI. wait4 receives the encoded value shifted by eight bits. waitid receives the unshifted exit value.

`SysWaitReturn.post.ret` is the direct kernel ABI result: PID, 0, or -10 for ECHILD. Also capture the actual direct-libc-syscall return in `libcRet` and errno in `errno`. The fixture clears errno before every invocation. The validator requires -1/10 for ECHILD and the success result/0 otherwise. Pin and verify this libc convention before using it. Correlate the kernel return and the caller's observation by invocation ID. Do not derive both records from one expected value. This merged return event spans kernel completion to user observation and must end before the next invocation event on that actor.

Before return, the model stores `PendingRet = -9999` in `NewCall.ret`. It is an internal numeric marker outside the fixture's result set `{ChildPid, 0, -10}`, so TLC can compare pending and completed calls. The separate string `outcome = "pending"` remains unchanged. `SysWaitBegin` does not capture `ret`. `SysWaitReturn` replaces the marker with the actual numeric result, and its exact post-state, libc conversion, and output checks remain unchanged. The MC and trace wrappers inherit this representation from `base.tla` and identify completion by `pc = "done"`.

The model's `pc` and `exitPc` are local control labels. Instrumentation records which code boundary was actually reached, then maps it to the corresponding post-action label. The mapping must use the observed branch and atomic return value. It must not advance an expected-model shadow independently of kernel execution. `current` is the actor's invocation counter. `scan` records matched, absent, live, or zombie from the actual lookup/load. `acquired` is the actual Acquire zombie-load result.

The `retained`, `created`, `closed`, `selected`, `selectedPresent`, `claimed`, `outputWritten`, `signalHeld`, `rqHeld` fields describe concrete construction, ownership, operation success, or lock boundaries. Record them from their own hooks or protected local values. No new runtime guard is added. `rqHeld` means that the target waiter's park check/dequeue critical section owns its runqueue lock. It does not mean that no other scheduler operation holds any runqueue lock. `closed` is recorded by the closing waiter, not read by a concurrent notifier. The implementation has one token bit, not a second physical closed bit.

History fields such as `beganAfterConsume`, `readHadRef`, `copyHadRef` and the accumulated claim set are computed by base actions from the traced selection, invocation, read, and drop boundaries. Do not add racy global reads to capture those ghosts. `remaining` is the notifier's locally tracked unvisited parent actors, serialized in the order of metadata `waiters`. That canonical representation does not impose an order on which parent is notified first. `queue` is a JSON array of generation pairs, preserving duplicate and closed entries. `queueCount` is the relevant actual count/RMW result. `oldToken` is the actual swap return, and `observedToken` is the actual park-check load result.

Raw streams remain per-actor NDJSON. The harness preprocessor must preserve local order, all fields, operation outcomes, and interval ordering. Compress timestamps by an order-preserving map. Write a single JSON object, optionally on one line, to the conventional `../traces/trace.ndjson` path. Despite this filename, the validator calls `JsonDeserialize` on that grouped object, not `ndJsonDeserialize` on raw events. Set environment variable `JSON` to choose another grouped trace file.

The grouped object has the following fields:

| Field | Required value or meaning |
| --- | --- |
| `schema` | `asterinas-wait-reap-timebox-v1`. |
| `source` | The exact Asterinas commit above. |
| `waiters` | An array of the two distinct waiter actor names, excluding child and none. |
| `child_pid`, `child_uid`, `exit_value` | Actual fixture values. They override the base constants in both trace configurations. |
| `smp`, `concurrent` | Actual guest CPU count and whether the run makes a concurrency claim. Concurrent traces require SMP >= 2. |
| `sigchld`, `sa_nocldwait`, `sigchld_blocked` | Respectively SIG_DFL, false, and true, established and checked before recording. |
| `valid_buffers`, `rusage_null` | Both true under this primary fixture. The manifest must establish buffer validity/stability. |
| `buffers` | A map from the two waiter names to their independent nonzero output addresses. Their 128-byte regions must not overlap. |
| `traces` | A map from both waiter names and child to their ordered event arrays. At least one event is required. |

Record source/tree identity, instrumentation patch hash, model/config hashes, kernel image hash, guest identity, actual CPU count, compiler, libc/headers, harness binary, direct syscall numbers/arguments, signal setup, buffer allocation, schedule controls, clock source/calibration, dropped-event counters, and Linux control identity in a separate collection manifest. Metadata declarations alone are not proof that these assumptions held.

## 2. Action-to-code mapping

Each row is one base action and one event name. `ThreadStep`, `ExitStep`, `Reactive`, `Next` and the MC wrappers are dispatch or admission operators, not additional instrumented operations. The listed `post` fields are mandatory and are checked by the same-name arm of `ExpectedPost`.

| Action / event | Source | Exact trigger | Required post fields |
| --- | --- | --- | --- |
| `SysWaitBegin` | `syscall/wait4.rs:18-36; syscall/waitid.rs:29-43` | After argument decoding, before do_wait's first condition check. | `pc, current, api, nohang, nowait, out` |
| `TryWaitChildrenLock` | `process/wait.rs:293; ostd/src/sync/mutex.rs:62-65` | After successful children-mutex acquisition. | `pc, childrenOwner` |
| `TryWaitChildrenMatch` | `process/wait.rs:296-304,335` | After the fixed PID lookup, before the zombie load. | `pc, scan, childPresent` |
| `TryWaitChildrenZombie` | `process/wait.rs:310; process/status.rs:41-43` | Immediately after the Acquire zombie load. Preserve its actual returned value. | `pc, scan, acquired` |
| `TryWaitChildrenRetain` | `process/wait.rs:311-319` | After cloning the selected Arc and deciding WNOWAIT, before consuming removal. | `pc, selected, selectedPid, selectedPresent, retained` |
| `ReapZombieChildRemove` | `process/wait.rs:344-345` | After children-map remove, while its mutex remains held. | `pc, childPresent, claimed` |
| `ReapZombieChildPidRemove` | `process/wait.rs:363; process/pid_table.rs:148-166` | After clearing this process and main-thread PID slots, before dropping the PID guard. | `pc, pidPresent` |
| `ReapZombieChildFinish` | `process/wait.rs:365-374` | After group/session/accounting cleanup and the final code read, before returning. | `pc` |
| `TryWaitChildrenUnlock` | `process/wait.rs:319,335; ostd/src/sync/mutex.rs:56-69` | At release of this children guard. Capture the release operand, not a later owner read. | `pc, childrenOwner` |
| `DoWaitFound` | `process/wait.rs:75-76` | When Found is translated to Some(Ok(Some(status))). | `pc, outcome` |
| `DoWaitNoMatch` | `process/wait.rs:78-85` | When NoMatch is translated to ECHILD. | `pc, outcome` |
| `DoWaitNoHang` | `process/wait.rs:77,88-89` | When a live matched scan is translated to Ok(None). | `pc, outcome` |
| `DoWaitPending` | `process/wait.rs:99-100; process/signal/pause.rs:235-245` | When the condition returns None. Distinguish initial failure from a recheck. | `pc` |
| `WaiterNewPair` | `process/signal/pause.rs:240; ostd/src/sync/wait.rs:181-189` | After constructing this invocation's waiter/waker pair. | `pc, created, token, closed` |
| `SetSignalledWaker` | `process/signal/pause.rs:164; process/posix_thread/mod.rs:177-180` | After installing the signalled waker, while the existing slot lock protects the captured ID. | `pc, signalReg` |
| `WaitQueueEnqueue` | `process/signal/pause.rs:241-244; ostd/src/sync/wait.rs:145-149` | After push_back and the Acquire count RMW, before releasing the existing queue lock. | `pc, queue, queueCount` |
| `PauseCheckCancellation` | `process/signal/pause.rs:149-161; time/wait.rs:184-206` | After the untimed cancellation check returns Ok. | `pc, pendingUnblocked, timerActive` |
| `WakerConsumeToken` | `ostd/src/sync/wait.rs:273-275` | At the Acquire swap(false), recording its returned old value. | `pc, token, oldToken` |
| `ParkCurrentCheck` | `ostd/src/task/scheduler/mod.rs:453-470,485,577-584; sched/sched_class/mod.rs:255-259; ostd/src/sync/wait.rs:273-275` | Save the actual has_unparked Acquire load result. If false, capture post-state and end immediately after the load, while the runqueue lock remains held and before update_current/dequeue_current. If true, capture post-state and end only after the callback returns, mut_local_rq_with releases its guard, and reschedule returns to park_current. See the branch timing below. | `pc, rqHeld, observedToken` |
| `ParkCurrentDequeue` | `ostd/src/task/scheduler/mod.rs:469-484; sched/sched_class/mod.rs:410-414` | After dequeue_current and release of that runqueue critical section. | `pc, runnable, rqHeld` |
| `ParkCurrentResume` | `ostd/src/task/scheduler/mod.rs:469-485; ostd/src/sync/wait.rs:273-275` | Only on the dequeued path, when park_current returns to the token loop after the task can execute. Do not emit this event for a true ParkCurrentCheck, which returns directly to that loop. | `pc, runnable` |
| `ParkCurrentSpurious` | `ostd/src/task/scheduler/mod.rs:441-444` | At a scheduler-evidenced spurious return, before ParkCurrentResume. Never infer this from a timeout. | `runnable` |
| `ClearSignalledWaker` | `process/signal/pause.rs:166; process/posix_thread/mod.rs:183-185` | After clearing the signal slot under its existing lock. | `pc, signalReg` |
| `WaiterClose` | `ostd/src/sync/wait.rs:244-248,278-281` | After the Acquire close swap(true) during Waiter drop. | `pc, token, closed` |
| `SysWait4ReadStatus` | `syscall/wait4.rs:45,63-65; process/status.rs:71-72` | After reading the selected PID and relaxed exit code through the live WaitStatus. | `pc, readCode, selectedPid, retained` |
| `SysWaitidReadStatus` | `syscall/waitid.rs:55-63,88-90; process/wait.rs:129-143` | After reading status, PID and fixed UID from the retained process/main task. | `pc, readCode, selectedPid, uid, retained` |
| `SysWaitCopyout` | `syscall/wait4.rs:46-47; syscall/waitid.rs:66` | After successful write_val, recording the actual payload and private output contents. | `pc, out, outputWritten, retained` |
| `WaitStatusDrop` | `process/wait.rs:120-164; syscall/wait4.rs:60; syscall/waitid.rs:69` | At destruction of the selected WaitStatus after its last output read. | `pc, retained` |
| `SysWaitReturn` | `syscall/wait4.rs:36-43,60; syscall/waitid.rs:43-50,69` | Correlate kernel return and direct-libc-syscall completion by invocation ID. Include caller-observed output. | `pc, ret, libcRet, errno, out` |
| `ProcessStoreExitCode` | `process/posix_thread/exit.rs:53,63-89; process/status.rs:75-77` | At the relaxed store of the single child's encoded normal exit code. | `exitPc, exitValue, storedCode` |
| `ProcessPublishZombie` | `process/exit.rs:36; process/status.rs:51-53` | At the Release zombie store, before any signal or children-queue wake. | `exitPc, zombie` |
| `ProcessEnqueueSignal` | `process/exit.rs:183-184; process/process/mod.rs:646-648` | After enqueueing SIGCHLD and before iterating the fixed parent tasks. | `exitPc, pendingSignal, remaining` |
| `WakeSignalledWakerNone` | `process/process/mod.rs:648-655; process/posix_thread/mod.rs:250-253` | While checking an empty target signal slot under its existing lock. | `exitPc, remaining` |
| `WakeSignalledWakerGet` | `process/posix_thread/mod.rs:250-253` | After selecting the registered waker, retaining the signal-slot lock through wake_up. | `exitPc, remaining, signalHeld, wakeTarget, wakeChannel` |
| `ProcessSignalLoopDone` | `process/process/mod.rs:648-656; process/exit.rs:184-186` | After all fixed parent tasks have been visited, before children wake_all. | `exitPc` |
| `WakerWakeUp` | `ostd/src/sync/wait.rs:262-268` | At the Release swap(true), before a possible scheduler unpark. | `exitPc, token, oldToken` |
| `SchedulerUnparkTarget` | `ostd/src/task/scheduler/mod.rs:488-494; sched/sched_class/mod.rs:223-250` | After the enqueue assignment retry under the target runqueue lock succeeds or confirms runnable. | `exitPc, runnable, rqHeld` |
| `WakerWakeFinish` | `process/posix_thread/mod.rs:250-253; ostd/src/sync/wait.rs:128-131` | When wake_up returns, releasing the signal-slot lock if on the signal path. | `exitPc, signalHeld, wakeTarget, wakeChannel` |
| `WaitQueueWakeAllCheck` | `ostd/src/sync/wait.rs:111-115,136-140` | At the Release fetch_add(0), recording the count returned by that RMW. | `exitPc, queueCount` |
| `WaitQueueWakeAllPop` | `ostd/src/sync/wait.rs:119-126` | After pop_front/count decrement and queue-lock release, before wake_up. | `exitPc, queue, queueCount, wakeTarget, wakeChannel` |
| `WaitQueueWakeAllDone` | `ostd/src/sync/wait.rs:120-123` | When the locked pop observes an empty queue and the wake loop ends. | `exitPc, queueCount` |

## 3. Special considerations

Preserve the selection/removal/output split. Do not emit only syscall start/end and silently simulate internal scans. Acquire the children lock before matching the PID, load zombie separately, then retain the Arc. A consuming call removes children membership before PID cleanup and before releasing that same children guard. A WNOWAIT call skips these destructive steps. Read and copy output while the selected WaitStatus still owns the Process Arc. Removing PID membership does not destroy that Arc or the retained main task. A previously selected observer can legally complete after a consumer. A new post-consumption call must fail its own lookup.

Preserve a live/no-event scan result even when publication occurs before return. The no-event branch writes no output on either API. Do not turn waitid return 0 into an exit event unless its selected fields and selection history establish one. Reinitialize output on every primary invocation, including repeated calls on the same thread.

Signal registration remains active through all queue retries, then clears before waiter close. Enqueue happens before every slow-path scan. Record each duplicate entry. `WaiterClose` performs the real Acquire swap(true) and leaves any queue residue. A later `WakerWakeUp` observes that token or the token of a prior wake. Never retarget an old generation to a new waiter on the same task.

The notifier visits both parent tasks even though SIGCHLD is blocked. It keeps the signalled-waker lock across a selected signal wake and its possible delayed unpark. The queue path starts only after signal iteration returns. The queue lock is released between pop and wake_up. Do not combine their two events, remove the signal path, or stop notification because a consumer already removed the child. Reap itself does not add a children-queue wake.

The scheduler projection retains the race between the park token check and dequeue. After a false check, `rqHeld` stays true until dequeue/release. The Release wake-token swap can happen in that window, but unpark completion waits for the runqueue lock. The actual CPU-selection/assignment retry must remain in the instrumentation. Its intermediate CPU identity is projected away because the locked retry determines the final runnable state. This projection and nested-lock progress need independent source review before model acceptance.

For both `ParkCurrentCheck` branches, begin the interval before acquiring the first park runqueue critical section, and save the actual Acquire load result from `has_unparked()` in local scratch (`ostd/src/sync/wait.rs:274`; `ostd/src/task/scheduler/mod.rs:453-455`). Use that saved result to distinguish the branches:

- If false, capture `{pc: "dequeue", rqHeld: TRUE, observedToken: FALSE}` and the interval end immediately after the load, before `update_current` and `dequeue_current` (`ostd/src/task/scheduler/mod.rs:455-470`). Keep the existing guard held. A notifier may set the token before the separate `ParkCurrentDequeue` event without changing the saved false result.
- If true, the callback returns `ReschedAction::DoNothing` at `ostd/src/task/scheduler/mod.rs:455-456`. `ClassScheduler::mut_local_rq_with` keeps its guard through the callback and drops it on return (`sched/sched_class/mod.rs:255-259`). `reschedule` receives that return at `ostd/src/task/scheduler/mod.rs:577-579` and returns at lines 581-584. Capture `{pc: "token", rqHeld: FALSE, observedToken: TRUE}` and the interval end after this return to `park_current` at line 485, before the next token swap in `ostd/src/sync/wait.rs:273`. The true branch's represented operation includes this lock release. Do not record its post-state or interval end at the load, and do not reread the token or infer lock ownership from another CPU's later acquisition.

This branch-specific interval follows the existing `ParkCurrentCheck` action without adding a release action. The true branch skips `update_current` and `dequeue_current`, leaves the task runnable, and returns directly to the token loop. No intervening operation by this waiter changes the token. Other wake swaps can only leave the observed true token set, and a concurrent unpark completes under the same runqueue lock. The false branch still exposes the source's check/dequeue race as separate events. Emit `ParkCurrentResume` only after an actual dequeue, including when the scheduler subsequently picks the same task. A true check emits neither `ParkCurrentDequeue` nor `ParkCurrentResume`. All 41 actions, event names, dispatch arms, and exact post-state checks remain unchanged.

`ParkCurrentSpurious` is optional environmental behavior permitted by the scheduler API. It only makes the task runnable and cannot set a token or manufacture a successful scan. Emit it only with evidence of a real scheduler return that is not caused by the recorded in-scope unpark. If such a return cannot be distinguished, preserve that limitation for review rather than labeling a delayed normal wake spurious. The primary completion claim must not depend on this optional event.

For atomics, save the operation's actual returned value or store operand in local scratch, take the interval end timestamp at the represented operation's completion, and serialize the saved values outside the interval. The true `ParkCurrentCheck` branch ends after the lock release and return described above, not at its load. Do not reread an atomic later and call that value the operation's result. For map/queue snapshots, use the already-held source lock and copy into preallocated scratch after the operation, before releasing that lock. Serialization happens later. Do not add a global trace mutex, blocking I/O, allocation, an extra acquisition of the modeled locks, or cross-thread sequence counters to the hot path. Use safe kernel interfaces outside OSTD. Any timestamp implementation that needs unsafe access belongs in OSTD.

Calibrate cross-CPU timestamps and account for migration. Use a clock whose ordering assumptions are documented. Do not copy a tracing recipe that adds a new fence across the ordering bridge being investigated. Reject dropped, reordered, or clock-incomparable events instead of repairing them with expected-model values. Timeboxes preserve possible interleavings but do not eliminate probe effects or prove weak-memory correctness.

`ViablePIDs` allows an actor's next event only when no other pending event ended before it started. Overlap permits either order. All 41 wrappers call the full base action and check the required captured state. There are no silent actions. The final trace must include all admitted call returns and completion of the exit notifier. `TraceEndOK` rejects an exhausted but truncated trace. Closed queue residue is allowed.

Use `TraceSearch.cfg` for acceptance. It searches the unchanged `TraceInit` and `TraceNext` relation with every existing safety, cursor, and final-state invariant enabled. Its last invariant, `TraceNoCompleteMatch`, is the negation of `TraceComplete`: every event has been consumed and `TraceEndOK` holds. Each consumed event still calls its base action and passes exact argument and post-state checks. Deadlock checking stays disabled so a stuck speculative prefix does not stop exploration of other prefixes. No fairness, symmetry, state constraint, or silent action is added to this finite reachability search.

Interpret the search as follows:

| Result | Acceptance decision |
| --- | --- |
| TLC violates exactly `TraceNoCompleteMatch` and produces the full counterexample after the other invariants pass. | **ACCEPTED.** The counterexample is a complete matching interleaving. Retain it and verify all actor cursors are one past their event arrays. |
| TLC exhausts a nonempty initialized state graph without any invariant violation or evaluation error, with no states left on the queue. | **REJECTED.** No complete matching interleaving exists for this input and model. This alone does not identify a kernel defect. |
| The run reaches its time/resource limit, is interrupted, fails initialization/parsing/evaluation, violates another invariant, or does not retain a complete witness. | **INCONCLUSIVE.** Report the reason and explored state counts. An empty initial-state set is never rejection or acceptance. |

`Trace.cfg` remains an optional stricter universal check. It enables `TraceMatched` under cursor fairness, which excludes artificial stuttering on a matchable prefix. A valid trace can fail this check when one overlapping order becomes stuck although another order completes. Such a temporal counterexample does not overturn an accepted existential witness. Neither configuration assumes protocol completion fairness for the recorded execution.

From the workspace root, `python3 spec/generation-checks/generate_fixtures.py` regenerates the five synthetic fixtures and `python3 spec/generation-checks/run_checks.py traces` runs their existential searches and the overlapping fixture's universal check. The driver records commands, exit codes, counts, input hashes, logs, and decisions in `generation-checks/results.json`. For a collected trace, run TLC on `Trace.tla` with `-config TraceSearch.cfg`, set `JSON` to the grouped input, retain the counterexample with `-dumpTrace json`, and apply the three outcomes above. Synthetic fixtures test the checker and do not establish an implementation trace or runtime result.

The R4 fixtures add a true park check after a wake-token swap and a false check with a wake-token swap before dequeue, followed by unpark and resume. Both complete their calls and notifier. The revision checks accept these two fixtures and the existing overlap and sequential fixtures with complete witnesses, and reject the unchanged corrupted fixture by exhaustion. The universal overlap check still fails `TraceMatched` as predicted by R2. See [generation-checks/results.md](generation-checks/results.md) for counts, commands, logs, and the source-based interpretation.

Collect short traces across WR-01 through WR-10, recording event coverage and the decisive interleavings. WR-04/05 need two nonconsuming observations and a later consumer. WR-08 needs selection before removal and delayed observer output. WR-09 needs exit between first failure and registration/recheck. WR-10 needs registration/park overlap and two consumer completions, including ECHILD. Record genuine cross-thread interval overlap and exercise both notification channels. Preserve actual schedule evidence instead of interpreting sleep durations or watchdog expiry as a lost wakeup.

WR-SQ is a separate poisoned-output control and remains SOURCE LEAD / NOT_RUN. Run raw waitid WNOHANG with zeroed and poisoned valid siginfo on independently identified Linux and Asterinas systems. Compare relevant fields and error decoding. Successful prezeroed primary traces do not validate Linux-style clearing. WR-CF is a separate sequential calibration and remains NOT_RUN: consuming output faults may leave ECHILD for the next call, whereas WNOWAIT should preserve availability. Neither control is inserted into the primary valid-buffer model.

The controller owns stage invocation and the resource lock. Harness generation must not recursively launch other pipeline phases or reacquire that lock. Before any later semantic correction is verified again, preserve prior/proposed content, diff, rationale, triggering evidence, and exact hashes. Obtain independent review under `corrective_review_gate` in the supplied resource policy. If review is unresolved, return incomplete with the evidence for the controller to arrange continuation of this campaign.
