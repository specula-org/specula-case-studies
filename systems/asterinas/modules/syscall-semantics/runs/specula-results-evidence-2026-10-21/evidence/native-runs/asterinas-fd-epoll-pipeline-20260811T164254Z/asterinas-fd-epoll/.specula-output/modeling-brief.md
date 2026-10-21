# Asterinas FD lifecycle and epoll modeling brief

Analysis snapshot: Asterinas `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` (2026-08-12).

## 1. System Overview

Asterinas is a Rust Linux-compatible kernel. The scoped implementation is 3,658 lines in 20 primary files, plus 2,515 lines of signal, timer, process-exec, and namespace support.
This is **Category B (Concurrent / Lock-Free)**: multiple CPUs execute syscall, timer, signal, close, and synchronous observer-callback paths over shared file and readiness state.
FD tables map numeric descriptor slots to `Arc<dyn FileLike>` open file descriptions (OFDs); per-slot `FdFlags` are separate from shared file status and state.
Epoll keys interests by `(fd, weak OFD identity)`, keeps a deduplicated ready queue, and uses `Pollee`/`SyncSubject` callbacks instead of Linux wait queues.
Readiness caching is semi-stateless: registration precedes the live check, while producers must notify or invalidate whenever readiness changes.
Exec terminates sibling threads, clones a shared table, then removes `CLOEXEC` slots. Poll/select snapshot OFD references before blocking.
The initial model should use two threads, three FD slots, three OFDs, and at most two epoll instances.

## 2. Scenarios

### Scenario 1: Numeric slots, captured OFDs, and exec cutover

**Mechanism**: A numeric FD is a reusable slot, while a captured operation, duplicated descriptor, epoll key, and shared file status refer to an OFD identity with an independent lifetime.
**Evidence**:
- Historical: [#3178](https://github.com/asterinas/asterinas/issues/3178) was a test false positive caused by low-FD reuse; [#506](https://github.com/asterinas/asterinas/issues/506) records the slot-close/OFD-lifetime distinction; [#194](https://github.com/asterinas/asterinas/issues/194) and [#2864](https://github.com/asterinas/asterinas/issues/2864) cover per-slot `CLOEXEC` and shared OFD owner state.
- Code analysis: `file_table.rs:169-187,196-205,326-367,372-403` captures an `Arc`, atomically replaces a slot under the table lock, and stores flags per entry; `dup.rs:21-30,50-78` handles equal descriptors and defers replaced-file cleanup; `execve.rs:161-187,378-386` establishes the exec barrier and close-on-exec cutover.
**Affected code paths**: `sys_close`, `sys_close_range`, `sys_dup*`, `fcntl(F_DUPFD*)`, `fcntl(F_GETFD/F_SETFD/F_GETFL/F_SETFL)`, `get_file_fast!`, `clone_files`, and `unshare_and_close_files`.
**Suggested modeling approach**:
- Variables: `slots`, `slotFlags`, `ofdState`, `ofdRefs`, `captured`, `sharedTable`, `execPhase`.
- Actions: capture an OFD, remove/replace/install a slot, duplicate, mark `CLOEXEC`, quiesce exec siblings, clone the table, and close marked slots.
- Granularity: split lookup/capture from file operation, and split duplicate validation/replacement from deferred cleanup.
**Priority**: High
**Rationale**: This identity split is the baseline for every candidate and prevents FD-number reuse from producing false counterexamples.

### Scenario 2: Epoll interest lifetime and delivery commit

**Mechanism**: Epoll separates an interest keyed by slot plus OFD identity from a ready-queue token, but readiness state is mutated before userspace delivery and dead weak interests lack a final-close hook.
**Evidence**:
- Historical: [#1296](https://github.com/asterinas/asterinas/issues/1296) fixed waiting while holding the file-table lock; [#1355](https://github.com/asterinas/asterinas/issues/1355) introduced RAII observer deregistration.
- Code analysis: `entry.rs:46-67,103-109` stores weak OFD identity; `file.rs:130-145,225-233` removes dead entries only on explicit delete or ready-list scan; `entry.rs:116-149` pops ET state and disables one-shot; `file.rs:210-245` performs that mutation before `syscall/epoll.rs:145-154` copies events out.
- Linux reference: `eventpoll.c:159-167,1312-1351` removes watches during final `__fput`; `eventpoll.c:1932-2001` requeues an item on copy fault and commits one-shot only after successful copyout.
**Affected code paths**: `EpollFile::control`, `add_interest`, `del_interest`, `mod_interest`, `wait`, `pop_multi_ready`, `Entry::poll`, `Entry::shutdown`, and `do_epoll_pwait2`.
**Suggested modeling approach**:
- Variables: `interest`, `readyQ`, `entryEnabled`, `triggerMode`, `delivery`, `copyoutOk`, `ofdAlive`.
- Actions: capture target, add/modify/delete, notify/deduplicate, prepare delivery, copyout success/fault, LT requeue, one-shot rearm, final OFD destruction.
- Granularity: split event preparation from copyout commit; distinguish slot close from final OFD destruction.
**Priority**: High
**Rationale**: Both mechanisms have small counterexamples and observable outcomes: lost ET/one-shot delivery and stale `/proc/.../fdinfo` interest state.

### Scenario 3: Cached readiness invalidation

**Mechanism**: A semi-stateless readiness cache is correct only if every state transition that removes readiness invalidates it and every transition that creates readiness notifies registered observers.
**Evidence**:
- Historical: [#1356](https://github.com/asterinas/asterinas/issues/1356) documents a stale `POLLOUT` race and motivated the current register-before-check cache protocol.
- Code analysis: `process/signal/poll.rs:90-151,167-189` states the cache contract; `time/timerfd.rs:102-105` notifies on expiry, but `time/timerfd.rs:142-145,177-186` clears ticks without invalidation; `eventfd.rs:124-159` is the compensating comparison that invalidates via notification after counter transitions.
- Linux reference: `timerfd.c:266-280` checks live ticks on each poll.
**Affected code paths**: `Pollee::poll_with`, `notify`, `invalidate`, `TimerfdFile::set_time`, `try_read`, `poll`, eventfd read/write, and epoll LT/ET requeue.
**Suggested modeling approach**:
- Variables: `sourceReady`, `cacheState`, `registered`, `notified`, `timerTicks`, `eventCounter`.
- Actions: register-before-check, cache, expire/produce, consume, disarm, invalidate, notify, and LT re-poll.
- Granularity: split source mutation from invalidation/notification so TLC can omit or delay the required second step.
**Priority**: High
**Rationale**: A single-thread timerfd trace can leave persistent false LT readiness, while two-thread traces cover consume/rearm races.

### Scenario 4: Thread-relative signalfd readiness

**Mechanism**: Signalfd readiness depends on the consuming thread, but persistent epoll registration is bound to the thread that executed `epoll_ctl` and mask updates do not issue a wakeup.
**Evidence**:
- Historical: [#2252](https://github.com/asterinas/asterinas/issues/2252) and fix PR [#2503](https://github.com/asterinas/asterinas/pull/2503) deliberately moved readiness from one file-global observer to caller-thread plus process queues.
- Code analysis: `signalfd.rs:103-117,155-160` updates a mask without notification; `signalfd.rs:205-215` registers using `current_thread`; `posix_thread/mod.rs:266-270` selects that thread and the process queue; `sig_queues.rs:38-45,86-92` notifies only the queue receiving the signal.
- Linux reference: `signalfd.c:48-61,268-279` registers a shared sighand wait queue and wakes it after changing an existing signalfd mask.
**Affected code paths**: `sys_signalfd4`, `update_existing_signalfd`, `SignalFile::poll`, `register_signalfd_poller`, thread/process signal enqueue, `epoll_ctl`, and `epoll_wait`.
**Suggested modeling approach**:
- Variables: `threadPending`, `processPending`, `signalMask`, `pollerBindings`, `ctlThread`, `waitThread`.
- Actions: enqueue thread/process signal, register from one thread, update mask, wait/read from another thread, notify bound queues.
- Granularity: keep registration identity, readiness evaluation identity, and signal delivery as separate actions.
**Priority**: High
**Rationale**: Two two-thread traces can leave an epoll waiter blocked while a direct read by that waiter would succeed.

### Scenario 5: Terminal wait arbitration and temporary masks

**Mechanism**: A wake has no retained cause, and timeout or signal is returned before the caller performs a final readiness scan; temporary signal masks are restored later through syscall-return signal handling.
**Evidence**:
- Historical: [#1048](https://github.com/asterinas/asterinas/issues/1048) fixed timeout-as-error at the syscall boundary; [#2122](https://github.com/asterinas/asterinas/issues/2122) fixed a ppoll registration/pending-signal race.
- Code analysis: `pause.rs:171-221` checks expired timer before pending signal; `poll.rs:103-121` returns timeout/error before `count_events`; `epoll/file.rs:191-207` has the same wait structure; `ppoll.rs:31-40`, `pselect6.rs:33-52`, and `epoll.rs:114-143` install masks; `signal/mod.rs:64-85,208-230` restores them by RAII at return/signal delivery.
- Linux reference: `select.c:826-907` rescans all descriptors before allowing signal or timeout to terminate the loop.
**Affected code paths**: `Poller::wait`, `Waiter::pause_timeout`, `do_poll`, `EpollFile::wait`, `ppoll`, `pselect6`, `epoll_pwait*`, and `handle_pending_signal`.
**Suggested modeling approach**:
- Variables: `waitState`, `wakeCause`, `deadlineExpired`, `signalPending`, `visibleReady`, `currentMask`, `savedMask`.
- Actions: register, block, readiness wake, timer wake, signal wake, terminal rescan, return, deliver signal, restore mask.
- Granularity: split wake from terminal selection and restoration; do not encode scheduler time or timeout precision.
**Priority**: High
**Rationale**: Bounded ordering exploration can distinguish a legitimate race from readiness that was already visible at the missing final scan.

### Scenario 6: Bounded nested epoll and synchronous callbacks

**Mechanism**: Epoll accepts self/nested registrations without topology validation, while readiness propagation invokes observers synchronously under ready-set and subject spin locks.
**Evidence**:
- Historical: [#1406](https://github.com/asterinas/asterinas/issues/1406) fixed earlier observer/atomic-context deadlocks; [#1483](https://github.com/asterinas/asterinas/issues/1483) remains the general atomic-mode audit.
- Code analysis: `epoll/file.rs:64-125,255-258` accepts an epoll target with no self/cycle check; `entry.rs:307-330` notifies while holding `ReadySet.entries`; `subject.rs:126-149` invokes callbacks while holding the observer set; `blocklists/epoll_test:1-2` explicitly disables cycle conformance tests.
- Linux reference: `eventpoll.c:41-91,359-368` rejects cycles and imposes a topology lock order.
**Affected code paths**: `EpollFile::add_interest`, nested `Pollable::poll`, `ReadySet::push`, `Pollee::notify`, and `SyncSubject::notify_observers`.
**Suggested modeling approach**:
- Variables: `epollGraph` and a small `heldLocks` relation for two epoll instances.
- Actions: only model supported acyclic insertion; represent self/back-edge attempts as rejected actions and audit the current unsupported path separately.
- Granularity: one action for topology validation; split synchronous callback hops only in a two-instance lock-order check.
**Priority**: Low
**Rationale**: The gap is already known and blocklisted, so it is not a new model-checking target; the initial model needs only an acyclic two-node constraint.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

- **Slot/OFD separation**: required by Scenario 1; retain captured OFD references across close and reuse.
- **Atomic replacement and deferred cleanup**: required by Scenarios 1-2; expose exactly-once slot removal and later OFD destruction.
- **Epoll prepared-versus-committed delivery**: required by Scenario 2; inject successful or failed copyout for one event.
- **Semi-stateless readiness cache**: required by Scenario 3; let mutation, invalidation, and notification interleave.
- **Thread/process signal queues**: required by Scenario 4; parameterize poll/read by current thread.
- **Wait terminal states and saved masks**: required by Scenario 5; make final readiness scan and mask restoration explicit.
- **Bounded configuration**: two threads, three slots, three OFDs, two epolls, one pending signal, and one timer/event source are sufficient for the proposed traces.

### 3.2 Do Not Model (with rationale)

- Delayed filesystem close errors, individual filesystem implementations, performance, wakeup fairness, or architectures beyond x86_64: excluded by target scope.
- Unsupported `EPOLLEXCLUSIVE`, `EPOLLWAKEUP`, `TFD_TIMER_CANCEL_ON_SET`, timeout writeback/resolution, regular-file epoll, or arbitrary nested depth: implementation-declared or blocklisted gaps.
- Numeric allocation limits and integer overflow: test directly; they do not exercise identity or readiness ordering.
- Fixed historical implementations from #194, #1048, #1296, #1356, #1406, #2122, #2252, or #2905: references only, never hunt targets.
- Unmerged PR behavior, including [#3500](https://github.com/asterinas/asterinas/pull/3500) and [#3686](https://github.com/asterinas/asterinas/pull/3686): outside pinned source state.

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Descriptor identities | `slots`, `slotFlags`, `ofdRefs`, `captured` | Separate reusable numbers from stable OFDs | 1 |
| Exec cutover | `sharedTable`, `execPhase`, `execSnapshot` | Model quiescence, unshare, and `CLOEXEC` closure | 1 |
| Epoll interests | `interest`, `ofdAlive`, `readyQ` | Key by slot+OFD and clean final-close state | 2 |
| Delivery transaction | `delivery`, `copyoutOk`, `entryEnabled` | Commit ET/one-shot state only with delivery | 2 |
| Readiness cache | `sourceReady`, `cacheState`, `notified` | Check producer/consumer invalidation contract | 3 |
| Signal topology | `threadPending`, `processPending`, `pollerBindings` | Represent thread-relative signalfd readiness | 4 |
| Wait arbitration | `deadlineExpired`, `signalPending`, `savedMask` | Order ready, timeout, signal, and restoration | 5 |
| Epoll topology | `epollGraph`, `heldLocks` | Bound nesting to two acyclic instances | 6 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| `SlotMapsOneOFD` | Safety | Each occupied slot names exactly one OFD | Scenario 1 |
| `CapturedReferenceStable` | Safety | A captured operation never retargets after slot reuse | Scenario 1 |
| `ReplacementExactlyOnce` | Safety | `dup2/dup3` removes at most one old target and installs the captured source atomically | Scenario 1 |
| `FdFlagsPerSlot` | Safety | Duplicates share OFD state but not descriptor flags | Scenario 1 |
| `ExecClosesExactlySnapshotMarked` | Safety | Post-exec slots equal the unshared snapshot minus its `CLOEXEC` slots | Scenario 1 |
| `EpollKeyIdentity` | Safety | An interest is keyed by both registered slot and OFD | Scenario 2 |
| `NoCrossReuseDelivery` | Safety | An old ready token is never labeled as readiness of a reused slot's new OFD | Scenario 2 |
| `NoDeadInterest` | Safety | Destroying the final watched OFD removes its interest exactly once | Scenario 2 |
| `DeliveryCommitOnCopyout` | Safety | Failed copyout preserves retryable ET/one-shot delivery state | Scenario 2 |
| `OneShotDisabledIffDelivered` | Safety | One-shot disables only after a successful event delivery | Scenario 2 |
| `LevelReadyEventuallyRedelivered` | Liveness | Persistently ready LT interest remains discoverable under weak fairness | Scenarios 2-3 |
| `CachedReadinessSound` | Safety | In a quiescent source, returned readiness implies live source readiness | Scenario 3 |
| `RegisteredTransitionNotLost` | Liveness | A post-registration transition to persistent readiness eventually wakes or is observed | Scenarios 3-4 |
| `SignalfdBindingCoversConsumer` | Safety | A pending signal readable by the wait thread can reach its epoll registration | Scenario 4 |
| `VisibleReadyWinsTerminalRace` | Safety | Ready at the terminal scan is not replaced by timeout or nonfatal signal | Scenario 5 |
| `TemporaryMaskRestored` | Safety | Every syscall terminal path restores the pre-wait mask | Scenario 5 |
| `AcyclicEpollGraph` | Safety | Supported nested interests contain no self-edge or two-node cycle | Scenario 6 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC-1 | Can timer expiry, LT delivery, then read/disarm leave cached `IN` after ticks become zero? | `CachedReadinessSound` | 3 |
| MC-2 | Can an existing signalfd mask begin matching an already-pending signal without waking its epoll observer? | `RegisteredTransitionNotLost` | 4 |
| MC-3 | Can thread A register signalfd with epoll while a B-directed signal is readable only by thread B waiting on that epoll? | `SignalfdBindingCoversConsumer` | 4 |
| MC-4 | Can readiness become visible before a waiter returns, yet an expired timer or nonfatal signal bypass the final scan? | `VisibleReadyWinsTerminalRace` | 5 |
| MC-5 | Can `epoll_wait` prepare one ET/one-shot event, fault copyout, and make a valid retry lose it? | `DeliveryCommitOnCopyout`, `OneShotDisabledIffDelivered` | 2 |
| MC-6 | Can final destruction of a non-ready watched OFD leave an unaddressable interest indefinitely? | `NoDeadInterest` | 2 |
| MC-7 | Can close/dup replacement and FD reuse redirect a captured syscall or epoll control operation to the wrong OFD? | `CapturedReferenceStable`, `NoCrossReuseDelivery` | 1-2 |
| MC-8 | Can concurrent duplication or `close_range(CLOEXEC)` cross exec's unshare boundary and close or preserve the wrong slot? | `ExecClosesExactlySnapshotMarked`, `FdFlagsPerSlot` | 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV-1 | Existing-fd `signalfd4` appears to change `O_NONBLOCK`, while Linux uses flags only at creation | Toggle flags on an existing signalfd and compare `F_GETFL` with Linux |
| TV-2 | `dup` and `F_DUPFD*` do not visibly enforce `RLIMIT_NOFILE`, unlike `dup3` | Lower the soft limit, fill allowed slots, and assert `EMFILE`/`EINVAL` without allocating above the limit |
| TV-3 | Self and two-node epoll cycles are accepted on a path whose conformance tests are blocklisted | Enable minimized cycle tests and require Linux's `EINVAL`/`ELOOP`; run with `SMP=2` |
| TV-4 | Temporary ppoll/pselect/epoll masks must restore after ready, zero timeout, timeout, `EINTR`, `EFAULT`, and close races | Add a table-driven regression that reads the mask after every terminal path under `SMP=2` |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | Synchronous observer callbacks can cross ready-set, subject, and arbitrary `Pollable` lock contexts | Complete a lock-order graph for every scoped notifier and reject callback paths that reacquire a held spin lock |
| CR-2 | File creation paths rely on a comment that resource limits bound `FileTable`, but enforcement is not centralized | Audit all `FileTable::insert`/`dup_ceil` callers and document the single allocation-limit contract |

## 7. Reference Pointers

- Detailed evidence and audit trail: [`analysis-report.md`](analysis-report.md).
- Key Asterinas sources: `kernel/core/src/fs/file/file_table.rs`; `kernel/core/src/events/epoll/{file,entry}.rs`; `kernel/core/src/process/signal/{poll,pause,sig_queues}.rs`; `kernel/core/src/syscall/{epoll,poll,signalfd,dup,close}.rs`; `kernel/core/src/time/timerfd.rs`; `kernel/core/src/process/execve.rs`.
- Existing regressions: `test/initramfs/src/regression/io/epoll/epoll_err.c`, `test/initramfs/src/regression/process/signal/signal_fd.c`, and `test/initramfs/src/regression/process/execve/execve_mt_parent.c`.
- Linux references: [`eventpoll.c`](https://github.com/torvalds/linux/blob/master/fs/eventpoll.c), [`select.c`](https://github.com/torvalds/linux/blob/master/fs/select.c), [`signalfd.c`](https://github.com/torvalds/linux/blob/master/fs/signalfd.c), [`timerfd.c`](https://github.com/torvalds/linux/blob/master/fs/timerfd.c), [`dup(2)`](https://man7.org/linux/man-pages/man2/dup.2.html), and [`close(2)`](https://man7.org/linux/man-pages/man2/close.2.html).
- High-value history: issues [#506](https://github.com/asterinas/asterinas/issues/506), [#1296](https://github.com/asterinas/asterinas/issues/1296), [#1356](https://github.com/asterinas/asterinas/issues/1356), [#1406](https://github.com/asterinas/asterinas/issues/1406), [#2122](https://github.com/asterinas/asterinas/issues/2122), [#2252](https://github.com/asterinas/asterinas/issues/2252), [#2864](https://github.com/asterinas/asterinas/issues/2864), and [#3178](https://github.com/asterinas/asterinas/issues/3178).
- Confirmation status: no finding is classified as confirmed in this phase; each current candidate still lacks both a minimized TLA+ counterexample and a local Asterinas `SMP=2` regression.
