# Asterinas FD lifecycle and epoll code-analysis report

## Executive result

- Snapshot: `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`, detached HEAD, analyzed 2026-08-12.
- Category: **B, Concurrent / Lock-Free**. Syscall threads, timer callbacks, signal producers, file-table users, and synchronous observer callbacks interleave over shared state.
- Confirmation result: **0 confirmed findings under the task's required evidence bar**.
- Six current-source mechanisms warrant model checking: timerfd cache invalidation, signalfd mask-change notification, cross-thread signalfd/epoll registration, terminal readiness arbitration, epoll copyout commit, and final-close epoll cleanup.
- Two additional model-checking questions establish FD/OFD identity and close-on-exec correctness; static inspection found compensating locks and captured `Arc` references rather than a concrete violation.
- Four implementation-specific behaviors belong in regression tests, not TLA+: existing-signalfd flag handling, duplicate resource limits, known nested-epoll cycle handling, and temporary-mask restoration across every terminal result.
- No TLA+ model, minimized counterexample, Asterinas test, or VM run was produced in Code Analysis. Consequently, all current-source observations below are candidates, not confirmed bugs.

The required confirmation bar is intentionally strict. A later confirmed finding must combine the violated invariant, minimized TLA+ trace, concrete Rust event sequence, FD-slot/OFD explanation, local `SMP=2` regression, Linux comparison, and supported-versus-unsupported classification. This report supplies the source hypotheses and test plans but does not claim the missing dynamic evidence.

## 1. Scope and coverage

### 1.1 Primary source

All requested primary files were read in full:

| Area | Files | Lines |
|---|---:|---:|
| Syscall handlers | `close.rs`, `dup.rs`, `fcntl.rs`, `epoll.rs`, `poll.rs`, `ppoll.rs`, `select.rs`, `pselect6.rs`, `eventfd.rs`, `signalfd.rs`, `timerfd_{create,gettime,settime}.rs`, `execve.rs` | 2,254 |
| Descriptor table | `fs/file/file_table.rs` | 412 |
| Epoll | `events/epoll/{mod,file,entry}.rs` | 795 |
| Observer layer | `events/{observer,subject}.rs` | 197 |
| **Primary total** | **20 files** | **3,658** |

Supporting files were read only to establish concrete contracts:

| Supporting area | Files | Lines |
|---|---:|---:|
| Poll/cache and pause | `process/signal/{poll,pause}.rs` | 854 |
| Signal queues/readiness | `process/signal/{sig_queues,pending}.rs` | 453 |
| Thread context | `process/posix_thread/mod.rs` | 453 |
| Process exec | `process/execve.rs` | 396 |
| File-table unshare | `process/namespace/unshare.rs` | 77 |
| Timerfd object | `time/timerfd.rs` | 282 |
| **Supporting total** | **8 files** | **2,515** |

The analysis also inspected `fs/file/{file_common,file_handle}.rs`, clone behavior, procfs fdinfo generation, existing regression tests, conformance blocklists, and the root Makefile where needed to resolve ownership, identity, and test contracts.

### 1.2 Archaeology coverage

- Repository history: 156 commits touching current or predecessor paths were screened; 30 semantically significant patches were inspected by patch/stat and linked discussion.
- Bug tracker: 284 issues carrying the `C-bug` label were inventoried. Thirty-five relevant issue bodies and all 85 comments on those issues were read in full.
- Issue disposition: 28 discussions substantiated a fixed/current defect or accepted design change, one documented known unsupported behavior, and six were stale, artifacts, contradicted, or unconfirmed. None meets this task's current-finding confirmation bar.
- Open changes: titles for all 137 open PRs were screened. Twelve path- or semantics-relevant PRs were inspected more closely.
- Reference behavior: current Linux `eventpoll.c`, `select.c`, `signalfd.c`, and `timerfd.c`, plus the relevant man pages, were used as primary references.
- Existing tests: epoll, eventfd, signalfd, and multithreaded exec regressions and gVisor blocklists were inspected. They were not executed.

### 1.3 Method and confidence labels

The analysis followed the Category B workflow: map owned state, identify synchronization and linearization points, trace callback lock chains, enumerate hazardous and compensating interleavings, compare Linux-visible results, then route each unresolved question to model checking, testing, or code review.

| Skill phase | Completion evidence |
|---|---|
| Step 0, classification | Category B recorded here and in the brief; concurrent-analysis rules applied |
| Phase 1, reconnaissance | 20 primary and 8 supporting files mapped with state, locks, and atomic boundaries |
| Phase 2, archaeology | 156 commits, 284 issue inventory/35 full discussions, and 137 open PRs screened; issue batches were read in parallel |
| Phase 3, deep analysis | Exact source paths re-read for every candidate and compensating control; an independent epoll slice was cross-checked |
| Phase 4, modeling brief | Six mechanism scenarios, extensions, invariants, exclusions, and MC/test/review routing written in 199 lines |

Labels used below:

- **Current candidate**: reachable current-source mechanism with an externally distinguishable result, but missing TLA+ and/or Asterinas reproduction.
- **Baseline/control**: current code contains a compensating mechanism and is modeled to reject false positives.
- **Fixed history**: useful evidence of a bug-prone mechanism, never a model-checking target.
- **Known unsupported**: explicitly warned, TODO-marked, or blocklisted behavior; separated from incorrect behavior on a supported path.
- **Excluded/unrelated**: outside the requested model or contradicted by evidence.

## 2. Implementation model

### 2.1 Descriptor slots versus open file descriptions

`FileTable` is a slot vector (`file_table.rs:100-107`). Each occupied slot contains one `Arc<dyn FileLike>` and an independent atomic `FdFlags` value (`file_table.rs:372-395`). Cloning a table entry clones the `Arc` but copies the descriptor flags into a new atomic (`file_table.rs:398-403`). Therefore:

- the numeric slot can be closed and reused;
- duplicated slots share file status, readiness source, offset, owner, and other OFD state;
- `CLOEXEC` remains per descriptor slot;
- an operation that captured an `Arc` can outlive removal of the slot without redirecting to a later occupant.

`FileCommon` explicitly holds status flags and asynchronous-I/O owner as file-description state (`file_common.rs:18-35,43-80`). `fcntl(F_GETFL/F_SETFL)` operates through the file object (`fcntl.rs:76-94`), whereas `F_GETFD/F_SETFD` reads and writes the table entry (`fcntl.rs:53-73`). This matches the model split required by Linux.

On a shared file table, `get_file_fast!` clones the `Arc` under the table read lock and releases that lock before operating on the file (`file_table.rs:326-367`). On an unshared table it borrows directly, which is safe because no other thread can mutate that table. This is the principal control against “captured old number operates on new file” counterexamples.

### 2.2 Close and duplication linearization

`close` removes the slot under the table write lock, then runs VFS notification and `ClosedFile` cleanup outside the lock (`close.rs:22-40`). `ClosedFile` represents per-descriptor cleanup that may block (`file_table.rs:274-302`); final OFD destruction remains governed by the last strong `Arc`.

`dup_exact` clones the source entry, removes the previous target, and installs the replacement while one table write lock is held (`file_table.rs:169-187`). The syscall drops the replaced `ClosedFile` only after releasing the lock (`dup.rs:73-78`). `dup2(old, old)` verifies that the slot exists and returns it, while `dup3(old, old)` returns `EINVAL` (`dup.rs:21-30,50-61`). These are sound linearization points for the initial model.

One non-concurrent gap remains test-verifiable: `dup3` checks `RLIMIT_NOFILE` (`dup.rs:63-70`), but `dup` and `fcntl(F_DUPFD*)` call `dup_ceil` without a visible limit check (`dup.rs:10-18`; `fcntl.rs:43-50`; `file_table.rs:139-165`). No other `RLIMIT_NOFILE` reference protects those paths.

### 2.3 Epoll state

An epoll instance has an interest `BTreeSet` under a mutex and a separate `ReadySet` (`epoll/file.rs:55-61`). Each interest key is `(FileDesc, KeyableWeak<FileLike>)` (`epoll/entry.rs:46-67`), which correctly distinguishes:

- the same OFD registered through two numeric descriptors;
- an old OFD and a newly installed OFD reusing the same number;
- the registered FD value returned in procfs metadata from the file identity used for lookup.

`EpollFile::control` resolves and captures the target `Arc`, drops the file-table borrow, then applies ADD/DEL/MOD using that captured identity (`epoll/file.rs:64-84`). Thus a close/reuse after capture cannot silently retarget the operation. A close/reuse before capture legitimately changes what the syscall observes at its lookup linearization point.

The ready queue holds weak entries and uses an `is_ready` bit under its spin lock to deduplicate callbacks (`epoll/entry.rs:221-245,286-330`). A pop clears the ready bit; LT entries are requeued after live polling, ET entries are not, and one-shot entries are disabled until MOD (`epoll/entry.rs:116-166`; `epoll/file.rs:210-245`). This is internally consistent except when userspace delivery later fails.

### 2.4 Poller registration and cache contract

`Pollee::poll_with` registers an observer before checking live state, uses an invalid marker while checking, and caches only if no concurrent invalidation intervened (`process/signal/poll.rs:90-151`). `notify` invalidates the whole cache before broadcasting; `invalidate` is required when old readiness disappears without a new event (`process/signal/poll.rs:167-189`). This compensates for the ordinary register-versus-produce race.

The important model boundary is therefore not generic “registration can race.” It is whether each concrete producer and consumer honors the cache contract. Eventfd does: reads mutate the counter only after successful copyout and then call `notify(OUT)`; writes update the counter and call `notify(IN)` (`eventfd.rs:124-159`). Timerfd does not visibly invalidate after consuming or clearing expiration ticks.

### 2.5 Wait, signal, and exec state

`Poller::wait` delegates to `pause_timeout` (`process/signal/poll.rs:290-315`). The pause path installs a signal waker, checks pending signals after registration, blocks, then checks timeout before pending signal (`process/signal/pause.rs:171-221`). `do_poll` returns zero or an error immediately from that result and only scans descriptors after `Ok(())` (`syscall/poll.rs:103-121`). Epoll uses the same primitive through `wait_events` (`process/signal/poll.rs:341-390`; `events/epoll/file.rs:191-207`).

`ppoll`, `pselect6`, and `epoll_pwait*` save and install a temporary mask before waiting (`ppoll.rs:31-40`; `pselect6.rs:33-52`; `epoll.rs:114-129`). Restoration is intentionally deferred to syscall-return signal handling: `save_and_set_sig_mask` records the old mask (`posix_thread/mod.rs:355-387`), and `RestoreSigMaskGuard` restores it whether or not a signal is delivered (`signal/mod.rs:64-85,208-230`). This compensation must be represented in the model; looking only for a restore in the syscall handler would be a false positive.

Exec first serializes against another exec/exit, kills sibling threads, and waits for their termination (`process/execve.rs:66-79,161-164`). It then unshares the file table and closes only entries whose copied per-slot flag contains `CLOEXEC` (`process/execve.rs:186-187,378-386`; `file_table.rs:208-234`). `unshare_files` clones the table under a read lock and swaps the current thread/process references (`namespace/unshare.rs:18-27`). This provides a plausible linearizable cutover for model checking.

## 3. Current model-checking candidates

### CA-1: Timerfd can retain cached readable state after ticks are consumed

**Status**: current candidate; strong static evidence; MC-1 in the brief.

**Precise invariant**: in a quiescent timerfd with no concurrent expiry, `poll(IN)` and LT epoll delivery must not report `IN` when `ticks == 0`. Any transition from nonzero ticks to zero must invalidate cached `IN` before a later readiness check can return it.

**Concrete Rust sequence**:

1. `TimerfdFile::new` creates `ticks = 0` and a `Pollee` (`time/timerfd.rs:92-123`).
2. The timer callback increments ticks and calls `pollee.notify(IN)`, invalidating prior cache state and queuing epoll observers (`time/timerfd.rs:102-105`).
3. LT `epoll_wait` calls `Entry::poll`; `TimerfdFile::poll` computes and caches `IN` because ticks are nonzero (`epoll/entry.rs:116-149`; `time/timerfd.rs:189-204`). The LT entry is requeued (`epoll/file.rs:241-244`).
4. `TimerfdFile::try_read` executes `ticks.fetch_and(0)` and returns the count, but calls neither `Pollee::invalidate` nor `notify` (`time/timerfd.rs:177-186`). `set_time` has the same omission when canceling and clearing ticks (`time/timerfd.rs:136-145`).
5. A later LT epoll scan calls `TimerfdFile::poll`; `Pollee::poll_with` returns its cached nonnegative `IN` without invoking `check_io_events` (`process/signal/poll.rs:106-110`). The entry is returned and requeued again.

**Hazardous ordering**: expiry -> LT delivery/cache `IN` -> read consumes ticks -> next wait reports `IN` repeatedly.

**Controls**:

- read before any readiness check leaves the cache invalid and the next poll recomputes zero;
- a later timer expiry calls `notify` and refreshes state;
- eventfd's read path calls `notify(OUT)`, invalidating its cache after consumption.

**FD/OFD identity**: the timer ticks and cache belong to the shared timerfd OFD. Duplicating or renumbering the descriptor must not create independent readiness state; closing one slot does not cure stale cache on another slot.

**Linux comparison**: Linux `timerfd_poll` registers its wait queue and checks live `ctx->ticks` under the queue lock on every call (`fs/timerfd.c:266-280`). After read or disarm clears ticks, a quiescent poll no longer reports `EPOLLIN`.

**Support classification**: timerfd read, settime, poll, and LT epoll are implemented supported paths. `TFD_TIMER_CANCEL_ON_SET` is separately TODO-marked and is not involved.

**Required regression**: arm a nonblocking timerfd, register LT `EPOLLIN`, await one expiration, read the 64-bit count, then require two zero-timeout `epoll_wait` calls and direct `poll` to report no readiness. Add a second-thread consume/disarm variant and run `make run_kernel AUTO_TEST=regression SMP=2`.

**Missing confirmation evidence**: minimized TLC trace and local Asterinas regression result.

### CA-2: Updating a signalfd mask may not wake an existing epoll registration

**Status**: current candidate; strong static evidence; MC-2 in the brief.

**Precise invariant**: if an existing signalfd mask update changes an already-pending signal from excluded to included, every completed persistent readiness registration must either be notified or observe readiness without blocking.

**Concrete Rust sequence**:

1. A signal is blocked and pending in the current thread or process queue, but the current signalfd mask excludes it.
2. `epoll_ctl(ADD)` calls `SignalFile::poll`, which registers the epoll entry against the current thread and process signal queues, then checks the old mask and returns empty (`signalfd.rs:205-215`; `posix_thread/mod.rs:266-270`).
3. `signalfd4(existing_fd, new_mask, flags)` stores a mask that now includes the pending signal (`signalfd.rs:103-117,155-160`).
4. No signal is newly enqueued, and mask update performs no notification. The epoll ready queue remains empty.
5. `epoll_wait` can block or time out, although `SignalFile::check_io_events` and `read` under the same consuming thread would find the signal (`signalfd.rs:171-201`).

**Hazardous ordering**: pending-but-excluded signal -> epoll registration/check -> mask expands -> wait.

**Controls**:

- expanding the mask before ADD makes the registration-time live check return readiness;
- enqueuing another matching signal after the mask update notifies the registered queue;
- direct poll performs a fresh mask-dependent check.

**FD/OFD identity**: the signalfd mask is OFD state and is shared by duplicates. The epoll interest still belongs to the registered `(slot, OFD)` pair; changing the mask through any duplicate must wake observers of that OFD rather than only the numeric updating slot.

**Linux comparison**: Linux updates `ctx->sigmask` and explicitly calls `wake_up(&current->sighand->signalfd_wqh)` on the existing-fd path (`fs/signalfd.c:268-279`).

**Support classification**: updating an existing signalfd is implemented and documented by the syscall handler. This is distinct from blocklisted signalfd conformance cases involving RT payloads and maximum signal numbers.

**Required regression**: block `SIGUSR1`, leave it pending, create a signalfd whose initial mask excludes it, add that OFD to epoll, update the existing signalfd to include it, and require a bounded epoll wait plus read to succeed. Repeat with a duplicated updating FD and `SMP=2`.

**Missing confirmation evidence**: minimized TLC trace and local Asterinas regression result.

### CA-3: A signalfd epoll observer may be bound to the wrong consuming thread

**Status**: current candidate; strong static evidence; MC-3 in the brief.

**Precise invariant**: after persistent epoll registration, a thread-directed signal that is readable by the thread executing `epoll_wait` must reach that epoll interest, regardless of which same-process thread executed `epoll_ctl`.

**Concrete Rust sequence**:

1. Threads A and B share the signalfd and epoll OFDs.
2. A executes `epoll_ctl(ADD, signalfd)`. `SignalFile::poll` evaluates `current_thread!()` as A and stores the entry's `PollHandle` in A's queue Pollee plus the process queue (`signalfd.rs:205-215`; `posix_thread/mod.rs:266-270`).
3. B enters `epoll_wait`; no signalfd re-registration occurs because the interest is persistent and its ready list is empty.
4. A producer sends a thread-directed matching signal to B. `PosixThread::enqueue_signal` enqueues into B's `SigQueues`; that queue drops its mutex and notifies only its own `signalfd_pollee` (`posix_thread/mod.rs:256-264`; `sig_queues.rs:38-45`).
5. The epoll entry is registered with A's queue, not B's, so no ready token is added. B's direct signalfd readiness check would include B's pending queue plus the process queue (`pending.rs:103-128`).

**Hazardous ordering**: A registers -> B waits -> B-directed enqueue.

**Controls**:

- A-directed signal notifies A's registered queue;
- process-directed signal notifies the process queue registered by A;
- B performing the original ADD binds the entry to B and avoids this trace.

**FD/OFD identity**: the file object and mask are shared OFD state, but readiness is intentionally a function of the current consuming thread. The model cannot collapse signalfd readiness to one OFD Boolean or infer consumer identity from the FD slot.

**Linux comparison**: Linux `signalfd_poll` registers the shared `current->sighand->signalfd_wqh` and checks current-thread plus shared pending queues (`fs/signalfd.c:48-61`). Same-thread-group producers wake that shared signalfd queue, so registration is not permanently tied to A's private queue.

**Support classification**: thread-directed signals, signalfd, and epoll are supported. Historical issue #2252 intentionally introduced caller-relative readiness, making this an architectural interaction rather than a request to restore an obsolete file-global Boolean.

**Required regression**: A adds the shared signalfd to epoll; B communicates its TID, enters a finite epoll wait, and receives `tgkill(..., B, SIGUSR1)` from another CPU. Require B to receive one epoll event and read its signal. Pin or synchronize both threads sufficiently to establish the order and run with `SMP=2`.

**Missing confirmation evidence**: minimized TLC trace and local Asterinas regression result.

### CA-4: Timeout or signal may bypass a terminal readiness scan

**Status**: current candidate; medium-to-strong static evidence; MC-4 in the brief.

**Precise invariant**: for nonfatal signals, if a source is ready at the syscall's terminal scan, poll/select/epoll must return that readiness rather than zero or `EINTR`. A timeout with no ready source must still return zero, and a signal with no ready source must interrupt.

**Concrete Rust sequence**:

1. A poller registers all file observers and blocks through `Poller::wait` (`syscall/poll.rs:103-109`; `process/signal/poll.rs:307-315`).
2. A readiness producer makes state persistently ready and wakes the waiter.
3. Before the task resumes, the timeout timer also expires, or a nonfatal signal becomes pending and wakes the same waiter.
4. `pause_timeout` checks an expired timer first, then pending signals, and returns `ETIME`/`EINTR` without examining I/O state (`process/signal/pause.rs:202-219`).
5. `do_poll` converts `ETIME` directly to zero or propagates the error before `count_events` (`syscall/poll.rs:109-120`). `EpollFile::wait` propagates the same early result through `wait_events` (`process/signal/poll.rs:375-390`; `events/epoll/file.rs:191-207`).

**Hazardous orderings**:

- ready notify -> timeout expiry -> task resume -> zero;
- ready notify -> nonfatal signal -> task resume -> `EINTR`;
- timeout wake -> readiness becomes visible before resume -> zero without a final scan.

**Controls**:

- readiness found in the initial registration scan returns before blocking;
- timeout with no source ready correctly becomes zero at the syscall boundary;
- signal with no source ready correctly interrupts and restoration remains deferred to return handling.

**FD/OFD identity**: poll/select snapshots captured OFD references for shared tables (`syscall/poll.rs:93-101,143-156`). A concurrent close and reuse should not change which object the terminal scan checks. The candidate is missing scan arbitration, not FD retargeting.

**Linux comparison**: Linux `do_poll` loops back to scan all descriptors after a wake, then applies pending-signal and `timed_out` termination only if no event was counted (`fs/select.c:826-907`). Fatal-signal short-circuit behavior is outside this invariant.

**Support classification**: ordinary timeouts, nonfatal interruption, poll/select, and epoll wait are supported. Jiffy-level timeout precision and timeout-argument writeback are separately documented limitations and are excluded.

**Required regression**: first derive a minimized ordering with TLC. Encode it in an internal controllable-waker test or a barrier-based eventfd/pipe test that makes readiness persistent before releasing the waiter while timeout/signal is also pending. Assert readiness, then verify the temporary-mask cases under `SMP=2`.

**Missing confirmation evidence**: a counterexample proving that the proposed real-time ordering is outside allowed race nondeterminism, plus a deterministic Asterinas reproduction.

### CA-5: Epoll ET/one-shot state is committed before event copyout

**Status**: current candidate; strong static evidence; MC-5 in the brief.

**Precise invariant**: if copying a prepared epoll event to userspace fails, the failing event must remain eligible for a valid retry. In particular, ET must not be consumed and one-shot must not be disabled until its event is successfully delivered.

**Concrete Rust sequence**:

1. A persistently ready source has one ET or one-shot entry in the ready queue.
2. `EpollFile::wait` calls `pop_multi_ready`; the iterator removes the ready token and clears its `is_ready` bit (`epoll/entry.rs:367-397`; `epoll/file.rs:210-245`).
3. `Entry::poll` creates the result. ET is left off the queue; one-shot calls `reset_enabled` immediately (`epoll/entry.rs:116-149`).
4. `EpollFile::wait` returns an in-kernel `Vec<EpollEvent>` with those state mutations already complete (`epoll/file.rs:191-207`).
5. Only then does `do_epoll_pwait2` write each event to the user address. `write_val` may return `EFAULT`, and no rollback/requeue path exists (`syscall/epoll.rs:145-154`).
6. A retry with a valid address can return no event even though the source remains ready.

**Hazardous ordering**: prepare one ET/one-shot event -> bad copyout -> valid retry.

**Controls**:

- successful copyout makes the earlier state transition appropriate;
- plain LT is requeued before copyout and remains discoverable;
- a later new edge or explicit one-shot MOD can make the entry eligible again, but neither repairs the lost original delivery.

**FD/OFD identity**: the lost readiness remains associated with the same epoll interest and OFD. Reusing the numeric source FD is unnecessary and must not be introduced into the minimized trace.

**Linux comparison**: Linux `ep_deliver_event` re-inserts the failing item into the scan batch on `copy_to_user` failure and applies one-shot disable or LT requeue only after successful copyout (`fs/eventpoll.c:1932-2001`).

**Support classification**: ET, one-shot, and `EFAULT` from a bad userspace result buffer are supported behavior. This does not depend on unsupported epoll flags.

**Required regression**: make a pipe or eventfd persistently readable, register ET and then one-shot variants, call raw `epoll_wait` with an inaccessible event buffer and require `EFAULT`, then retry with a valid buffer and require the event. Run the deterministic regression in an `SMP=2` Asterinas VM.

**Missing confirmation evidence**: minimized TLC trace and local Asterinas regression result.

### CA-6: Final close of a non-ready watched OFD can leave a dead interest

**Status**: current candidate; strong static evidence for stale metadata/resource state; MC-6 in the brief.

**Precise invariant**: when the final strong reference to a watched OFD is destroyed, each epoll interest in that OFD must be removed exactly once, whether or not it is currently ready. Reusing the old numeric slot must not make the dead interest addressable as the new file.

**Concrete Rust sequence**:

1. Add a non-ready file to an epoll instance. Its `EntryKey` stores the numeric FD and only a weak file reference (`epoll/entry.rs:46-67,103-109`).
2. Close every descriptor referring to that OFD and allow captured operations to release their strong `Arc`s. There is no callback from file destruction into epoll interest removal.
3. Because the entry is not on the ready queue, `pop_multi_ready` never reaches the dead-file cleanup at `epoll/file.rs:225-233`.
4. The `EntryHolder` remains in `interest`. Procfs fdinfo prints all holders without upgrading their file references (`epoll/file.rs:276-305`).
5. Reuse the old FD for a new OFD. DEL/MOD resolves the new file and constructs `(old number, new OFD)`, so it cannot address the dead `(old number, old OFD)` key (`epoll/file.rs:64-84,130-164`).

**Hazardous ordering**: ADD non-ready old OFD -> final close/destruction -> reuse slot -> inspect fdinfo or operate on new key.

**Controls**:

- explicit DEL before final close removes the holder and runs `Entry::shutdown` through `EntryHolder::drop` (`epoll/file.rs:130-145,340-343`);
- if the dead entry was queued ready, the next ready scan observes failed weak upgrade and attempts removal;
- dead weak identity prevents stale readiness from being relabeled as the new OFD, so this is not a cross-reuse delivery bug.

**FD/OFD identity**: cleanup is tied to final OFD destruction, not the first numeric close. If a duplicate or captured operation still holds the old OFD, Linux permits the interest to remain. Only after all such references are gone should cleanup occur.

**Linux comparison**: Linux records reverse links from watched files and calls `eventpoll_release_file` from final `__fput`, explicitly removing watches for files closed without `EPOLL_CTL_DEL` (`fs/eventpoll.c:159-167,1312-1351`). Its key comparison also includes file identity and FD (`fs/eventpoll.c:526-530`).

**Support classification**: ordinary file close, epoll registration, and procfs fdinfo are supported. This is separate from unsupported delayed filesystem close errors.

**Required regression**: add a non-ready pipe end, close every duplicate of that end, read `/proc/self/fdinfo/<epfd>`, and require its `tfd` line to disappear. Reuse the same slot for a new pipe, add/delete the new interest, and verify no old line remains. Run with `SMP=2` and a concurrent close/inspection variant.

**Missing confirmation evidence**: minimized TLC trace and local Asterinas regression result.

## 4. Baseline lifecycle explorations and rejected false positives

### 4.1 Close, control, and reuse should not retarget captured operations

The initial model must still explore close/dup/epoll interleavings, but current source contains the key protections:

| Ordering | Expected model result | Source basis |
|---|---|---|
| control captures old OFD; close/reuse follows | Control applies to old identity or returns according to that old key | `epoll/file.rs:64-84`; captured `Arc` |
| close/reuse completes before control lookup | Control resolves new OFD and cannot find old key | `epoll/file.rs:72-83,130-164` |
| blocking operation captures old OFD; another thread closes slot | Operation may continue on old OFD; later lookup sees reused slot | `file_table.rs:326-367`; `close.rs:35-40` |
| `dup2/dup3` replaces target | Source capture, target removal, and install occur under one write lock | `file_table.rs:169-187`; `dup.rs:73-78` |
| old epoll ready token survives slot reuse | Token upgrades old OFD or is discarded; it never resolves through current table slot | `epoll/entry.rs:103-109,116-149` |

The existing `epoll_add_del` regression already exercises duplicate/close/reuse identity, including old number/new file and old number/old file cases (`test/.../epoll/epoll_err.c:10-53`). It is useful coverage but was not run here and does not cover concurrent lookup boundaries.

Historical issue #3178 is a warning for future tests: its low numeric FD was reused by unrelated procfs work, so `close(old_number)` successfully closed a new object and the test misdiagnosed a `CLONE_FILES` failure. Model traces and regressions must carry an expected OFD token or stable high descriptor, never assert identity from a number alone.

### 4.2 Duplication flags and shared status

`duplicate_entry` always constructs a fresh `FileTableEntry` with caller-selected `FdFlags` but the same file `Arc` (`file_table.rs:181-187`). Therefore plain dup clears CLOEXEC, `F_DUPFD_CLOEXEC` and `dup3(O_CLOEXEC)` set it only on the new slot, and status flags remain shared through `FileCommon`. Model invariant `FdFlagsPerSlot` should detect either accidental propagation direction.

The `F_SETOWN` history reinforces this boundary. Current code stores owner in `FileCommon` (`file_common.rs:18-35,78-102`) and resolves a captured file before `set_owner` (`fcntl.rs:168-199`), so duplicated descriptors share owner. Issue #2864 still tracks unsupported process-group owner and missing permission behavior (`fcntl.rs:176-181`); those are explicitly outside this initial FD/epoll model.

### 4.3 Close-on-exec cutover

`close_range(CLOEXEC)` takes the table write lock and marks only entries present in the requested range (`close.rs:76-100`). A later installation is intentionally unmarked. Exec waits for same-process sibling threads, clones any externally shared table, then removes marked entries from the private copy (`process/execve.rs:161-187,378-386`). This supports these model linearization choices:

- mark versus install linearizes at the table write lock;
- an exec snapshot contains a per-slot flag value, not an OFD-wide inherited bit;
- after unshare, another `CLONE_FILES` process can mutate the old table without changing the exec image;
- two slots referencing the same OFD can have different post-exec outcomes.

The existing multithreaded exec regression deliberately moves pipe ends to FDs 100 and 101, gives only FD 100 `O_CLOEXEC`, and exercises `CLONE_FILES` (`test/.../execve/execve_mt_parent.c:155-207`). It is good baseline coverage, not proof of all `close_range`/dup/exec orderings.

### 4.4 Generic lost-registration claims are rejected

The semi-stateless `Pollee` protocol registers before checking and prevents a concurrent invalidation from validating stale cache state (`process/signal/poll.rs:90-151`). `SyncSubject` pairs observer-count acquire/release operations so the fast no-observer path does not erase the registration/check guarantee (`events/subject.rs:95-100,123-149`). Historical #1356 and commits `fab61f5f6`/`ec2c6ab7a` explain this design.

Therefore, a report that merely places “event occurs” between “check” and “register” is a false positive. A valid candidate must identify a missing concrete invalidation/notification, a wrong observer binding, or a terminal path that skips the post-wake check. CA-1 through CA-4 satisfy that stronger requirement.

### 4.5 Forked epoll identity claim is not substantiated in current source

Open issue #200 states that epoll notification is incompatible with fork, but provides no reproduction or discussion. Current `FileTable::fork_from` clones entries (`file_table.rs:117-121`), entry clone preserves the same file `Arc` (`file_table.rs:398-403`), and `clone_files` either shares the table or copies those entries (`process/clone.rs:738-745`). A fork therefore retains the same `EpollFile` OFD rather than cloning an epoll object bound to a parent's numeric slot. Keep #200 as a test gap, not a current bug claim.

## 5. Lock and atomicity audit

### 5.1 Observed lock boundaries

| State | Synchronization | Important boundary |
|---|---|---|
| File table slots | `RwArc<FileTable>` read/write | Shared lookups clone `Arc`; blocking file operations occur after unlock |
| FD flags | `AtomicU8` in each entry | Per-slot updates can occur with table read access |
| Epoll interest | sleeping `Mutex<BTreeSet<...>>` | ADD/MOD may take `Entry.inner` and register observers while held |
| Epoll entry config | sleeping `Mutex<Inner>` | Protects event mask, trigger flags, poll handle, and enabled transitions |
| Ready tokens | IRQ-disabling `SpinLock<VecDeque<...>>` | `ReadySet::push` calls `pollee.notify` while held |
| Ready scanning | sleeping `Mutex<PopGuard>` | Serializes poppers; ready spin lock is released before source poll |
| Observer set | spin lock inside `SyncSubject` | `notify_observers` invokes callbacks synchronously while held |
| Signal queue | sleeping `Mutex<Queues>` | Enqueue drops queue lock before notifying signalfd pollers |
| Eventfd counter | sleeping `Mutex<u64>` | Current read writes user output before consuming; notification occurs while counter guard is live |
| Timerfd timer | timer guard plus atomic ticks | Expiry notifies; read/disarm clear ticks without cache invalidation |

The ordinary file-table/epoll ordering is improved by deliberate unlocks: `get_file_fast!` warns against operating while holding table locks (`file_table.rs:326-337`), and `EpollFile::control` drops the table before taking epoll locks (`epoll/file.rs:72-84`). Commit `c68302f70` historically removed a blocking epoll wait from the table-lock critical section.

### 5.2 Nested epoll callback cycle

Current code accepts an epoll file as a target because `EpollFile` implements `Pollable` (`epoll/file.rs:255-258`) and `add_interest` performs no self/cycle check (`epoll/file.rs:87-125`). The dangerous synchronous path is:

```text
A.ready.entries spin
  -> A.ready.pollee.subject spin
    -> observer for “B watches A”
      -> B.ready.entries spin
        -> B.ready.pollee.subject spin
          -> observer for “A watches B”
            -> A.ready.entries spin (recursive acquisition)
```

A self-watch plus any independently ready source collapses the same chain to `A.entries -> A.subject -> A.entries`. `ReadySet::push` explicitly retains the entries spin guard while calling `pollee.notify` (`epoll/entry.rs:307-330`), and `SyncSubject::notify_observers` retains the subject guard while invoking `on_events` (`events/subject.rs:126-149`).

Linux rejects self-add with `EINVAL`, rejects a cycle-forming back edge with `ELOOP`, and uses a global topology check/lock order (`fs/eventpoll.c:41-91,359-368`). Asterinas already blocklists `CycleOfOneDisallowed` and `CycleOfThreeDisallowed` (`test/.../blocklists/epoll_test:1-2`). This makes it a **known unsupported conformance gap**, not a new MC target. TV-3 should add the bounded two-instance case requested by the task.

### 5.3 Remaining code-review question

Observer callbacks are synchronous and can run in timer, signal, socket, and other producer contexts. Historical #1406 and #1483 show that sleeping locks under atomic guards and reentrant callback locks have occurred before. The bounded model should represent the two-epoll cycle, while CR-1 should complete a source-level lock graph for every scoped notifier. Do not infer a deadlock merely from nested lock names; require a reachable callback edge and an acquisition that can block or recursively reacquire.

## 6. Readiness behavior by source

| Source | State transition to ready | State transition from ready | Notification assessment | Initial-model treatment |
|---|---|---|---|---|
| Eventfd | Counter add (`eventfd.rs:151-159`) | Successful read decrement/zero (`eventfd.rs:124-142`) | `notify(IN)` and `notify(OUT)` both invalidate cache; baseline control | One shared counter OFD |
| Timerfd | Expiry increments ticks (`time/timerfd.rs:102-105`) | Read or settime clears ticks (`time/timerfd.rs:142-145,177-186`) | Missing visible invalidation on both clear paths; CA-1 | One ticks value plus cache |
| Signalfd | Thread/process queue enqueue (`sig_queues.rs:38-45`) | Dequeue from current thread/process (`pending.rs:89-99,118-127`) | Queue notification is mask-agnostic; registration identity and mask change are CA-2/CA-3 | Per-thread and process pending sets |
| Epoll file | ReadySet becomes nonempty (`epoll/entry.rs:307-330`) | Last token popped (`epoll/entry.rs:372-385`) | Push notifies, final pop invalidates; bounded nested callback risk | Queue plus per-entry bits |
| Generic pollable | Producer-specific | Consumer-specific | Correct only if producer follows `Pollee` contract | Abstract persistent-ready source |

Existing epoll tests cover ADD/DEL identity, MOD, ET, one-shot rearm, and `epoll_pwait2` sigset size (`test/.../epoll/epoll_err.c:10-216`). Existing signalfd tests cover direct poll, ignored signals, reopen, same-thread `tgkill`, process/thread dequeue order, and one cross-thread blocking read (`test/.../signal/signal_fd.c:27-259`). They do not cover signalfd through epoll across different control/wait threads or mask-update wakeups. No scoped timerfd readiness regression was found.

## 7. Timeout and temporary-mask audit

### 7.1 Terminal outcomes

| Outcome | Current path | Required model result |
|---|---|---|
| Ready during initial scan | Registration function returns ready without blocking | Return ready set/count |
| Pure timeout | `pause_timeout -> ETIME`; syscall maps to zero | Return zero with empty readiness |
| Pure nonfatal signal | `pause_timeout -> EINTR` | Interrupt/restart according to syscall contract |
| Ready plus timeout before resume | Timer is checked before caller rescan | Explore CA-4; ready at final scan should win |
| Ready plus nonfatal signal before resume | Signal error returns before caller rescan | Explore CA-4; ready at final scan should win |
| Close while blocked | Shared-table poll uses captured `Arc` | Continue against old OFD; never poll reused slot |
| Bad result pointer | Poll/select/epoll copyout may fail | Preserve only state Linux preserves; epoll ET/one-shot is CA-5 |

Linux and Asterinas both allow races around the deadline. The model must not encode “readiness timestamp always wins.” It should encode the narrower observable rule: after wake, perform a final live scan, and if that scan finds readiness, return it before ordinary timeout or nonfatal signal termination. This formulation avoids treating readiness that vanished before the scan as a bug.

### 7.2 Mask restoration

Temporary masks are not restored lexically inside `ppoll`, `pselect6`, or `epoll_pwait*`. The saved mask is consumed by `handle_pending_signal`; if no signal is delivered, the guard is dropped after restoring before a second pending scan, and if a handler is built, the guard carries/restores the old mask on the appropriate return path (`signal/mod.rs:64-85,208-230`).

Static inspection found no terminal branch that clears the saved slot without constructing or dropping the restore guard. Nevertheless, TV-4 should cover:

- readiness without blocking;
- zero timeout;
- elapsed timeout;
- nonfatal interruption;
- input-pointer fault before mask install;
- output-pointer fault after mask install;
- descriptor close while blocked.

Each case must inspect the actual post-syscall mask. A return-code-only test is insufficient.

## 8. Supported behavior versus known exclusions

| Behavior | Evidence | Classification | Handling |
|---|---|---|---|
| Timerfd consume/disarm invalidation | Supported methods, no unsupported flag required | Current candidate CA-1 | MC + `SMP=2` regression |
| Existing signalfd mask wake | Supported update path | Current candidate CA-2 | MC + `SMP=2` regression |
| Cross-thread signalfd through epoll | Supported threads, signalfd, epoll | Current candidate CA-3 | MC + `SMP=2` regression |
| Ready/timeout/nonfatal-signal arbitration | Supported wait outcomes | Current candidate CA-4 | MC before deterministic test |
| Epoll ET/one-shot copy fault | Supported flags and normal `EFAULT` | Current candidate CA-5 | MC + deterministic regression |
| Final watched-OFD cleanup | Supported close and epoll | Current candidate CA-6 | MC + procfs regression |
| Existing signalfd flags mutate `O_NONBLOCK` | `signalfd.rs:103-117`; Linux ignores flags after validation on existing fd | Test-verifiable supported mismatch | TV-1 |
| `dup`/`F_DUPFD*` allocation limit | Limit enforced only by `dup3` in scoped code | Test-verifiable supported mismatch | TV-2 |
| Epoll self/cycles | Cycle conformance tests blocklisted | Known unsupported | TV-3; constrain initial model |
| Regular-file epoll | `EpollTest.RegularFiles` blocklisted | Known unsupported | Do not model |
| `EPOLLEXCLUSIVE`/`EPOLLWAKEUP` | `warn_unsupported_flags`, `epoll/file.rs:248-251` | Implementation-declared unsupported | Do not model |
| `TFD_TIMER_CANCEL_ON_SET` | TODO/warning, `time/timerfd.rs:147-151` | Implementation-declared unsupported | Do not model |
| Timeout precision/writeback | Blocklist and TODOs in epoll/select/ppoll | Known limitation | Do not model clock resolution |
| Delayed NFS-like close errors | Explicitly excluded in `close.rs:42-48` and task scope | Unsupported/excluded | Do not model |
| Process-group `F_SETOWN` and permission checks | Issue #2864; TODO in `fcntl.rs:176-181` | Open unsupported subset | Reference only |

This separation prevents a blocklisted Linux feature from being reported as a newly discovered current bug. Conversely, a missing callback or wrong state transition on a path the implementation exposes as supported remains eligible for confirmation.

## 9. Proposed local regression matrix

No regression source was added in this phase. The following tests are the minimum dynamic evidence for later confirmation:

| Test | Minimal observable assertion | Concurrency |
|---|---|---|
| R1 timerfd cache | After LT delivery and read/disarm, two zero-timeout waits and direct poll return no `IN` | Main plus consuming/rearming worker |
| R2 signalfd mask update | Existing mask expansion over a pending signal wakes epoll and read returns that signal | Main plus signal producer |
| R3 signalfd thread binding | A performs ADD; B waits; B-directed signal produces one event readable by B | Two threads, explicit barriers/TID |
| R4 terminal arbitration | Persistent readiness visible at controlled final scan is returned despite timeout/nonfatal signal wake | Internal controllable waiter preferred |
| R5 epoll copy fault | Bad result pointer returns `EFAULT`; valid retry returns original ET and one-shot event | Deterministic; VM still `SMP=2` |
| R6 final-close cleanup | Non-ready watch disappears from epoll fdinfo after final OFD close and slot reuse | Close/inspect workers |
| R7 FD capture/reuse | Operation captured on old OFD cannot affect a new occupant of the same slot | Two threads, three slots/OFDs |
| R8 CLOEXEC cutover | Only snapshot-marked slots close; duplicate sharing OFD but not flag survives; later old-table install is unaffected | Exec helper plus `CLONE_FILES` peer |
| R9 existing signalfd flags | Updating an existing fd does not change `F_GETFL(O_NONBLOCK)` relative to Linux | Direct test |
| R10 duplicate limits | `dup`/`F_DUPFD*` return correct limit errors and create no slot above soft limit | Direct test |
| R11 nested epoll | Self ADD returns `EINVAL`; two-node back edge returns `ELOOP`; no hang | Two epolls plus one ready source |
| R12 mask restoration | Old mask restored on all seven terminal outcomes listed in section 7.2 | Two threads for interrupt/close cases |

Suggested placement is alongside the existing epoll, signalfd, timerfd, and exec regression groups under `test/initramfs/src/regression`. The repository-supported run is:

```sh
make run_kernel AUTO_TEST=regression SMP=2
```

`SMP` defaults to 1 (`Makefile:18`), `AUTO_TEST` is selected at `Makefile:41-46`, and `run_kernel` validates the regression completion marker (`Makefile:271-281`). Run inside the repository's documented Asterinas development container/VM. A host-Linux control should use the same C sequence before classifying a mismatch.

## 10. Bug archaeology

### 10.1 Fully read issues

The table records every issue whose body and all comments were read. Closed defects remain references, not MC targets.

| Issue | Disposition | Relevance |
|---|---|---|
| [#194](https://github.com/asterinas/asterinas/issues/194) | Fixed by PR #610 | Historical missing `O_CLOEXEC`; establishes per-slot flag importance |
| [#200](https://github.com/asterinas/asterinas/issues/200) | Open, one-sentence claim | Fork/epoll assertion lacks reproduction and appears obsolete under Arc-preserving table clone |
| [#506](https://github.com/asterinas/asterinas/issues/506) | Resolved design dispute | Strong reference for per-close cleanup versus last-OFD destruction; proposed strong-count design was rejected |
| [#868](https://github.com/asterinas/asterinas/issues/868) | Closed test artifact | gVisor signal test used a detached thread and stale stack pointer; not epoll evidence |
| [#960](https://github.com/asterinas/asterinas/issues/960) | Fixed support gap | UNIX-socket observer support landed; file-specific breadth is excluded |
| [#1048](https://github.com/asterinas/asterinas/issues/1048) | Fixed timeout bug | Epoll timeout once propagated as an error instead of zero |
| [#1146](https://github.com/asterinas/asterinas/issues/1146) | Closed design work | Raw/validated FD type split; its sample incorrectly excluded valid FD 0 |
| [#1296](https://github.com/asterinas/asterinas/issues/1296) | Fixed deadlock | Epoll wait held the file-table lock while blocking; fixed by capturing then unlocking |
| [#1304](https://github.com/asterinas/asterinas/issues/1304) | Fixed, unrelated | UNIX-socket sleeping lock in atomic context; epoll linkage was explicitly rejected |
| [#1355](https://github.com/asterinas/asterinas/issues/1355) | Fixed design | Observer APIs unified around PollHandle RAII |
| [#1356](https://github.com/asterinas/asterinas/issues/1356) | Fixed readiness race | Concrete stale cached `POLLOUT` trace led to semi-stateless Pollee |
| [#1406](https://github.com/asterinas/asterinas/issues/1406) | Fixed compound lock bugs | Epoll callback mutex and Subject IRQ/reentrancy fixes; lock-history evidence |
| [#1483](https://github.com/asterinas/asterinas/issues/1483) | Open general audit | Tracks Mutex/RwMutex misuse in atomic mode; CR-1 context, not a target-specific defect |
| [#1511](https://github.com/asterinas/asterinas/issues/1511) | Fixed, unrelated | Default metadata implementation panic; outside readiness protocol |
| [#1595](https://github.com/asterinas/asterinas/issues/1595) | Closed, unrelated | TDX/random syscall hang was traced to x86 direction-flag behavior, not FD/epoll logic |
| [#1603](https://github.com/asterinas/asterinas/issues/1603) | Closed/disputed | Wrong-process signal report did not establish the target readiness sequence |
| [#1607](https://github.com/asterinas/asterinas/issues/1607) | Closed, unrelated | Random syscall hang traced to x86 direction-flag behavior |
| [#1975](https://github.com/asterinas/asterinas/issues/1975) | Fixed, unrelated | Benchmark hangs involved process reaping rather than descriptors |
| [#1985](https://github.com/asterinas/asterinas/issues/1985) | Closed/unconfirmed | Generic timeout report supplied no target-level evidence |
| [#1987](https://github.com/asterinas/asterinas/issues/1987) | Fixed, unrelated | TCP benchmark timeouts involved process lifecycle/reaping |
| [#2122](https://github.com/asterinas/asterinas/issues/2122) | Fixed signal race | ppoll now registers before pending-signal check; historical reference only |
| [#2142](https://github.com/asterinas/asterinas/issues/2142) | Fixed validation bug | Invalid timerfd flags reached a panic; boundary history only |
| [#2179](https://github.com/asterinas/asterinas/issues/2179) | Fixed teardown race | Procfs access raced released process file table; not close/reuse redirection |
| [#2252](https://github.com/asterinas/asterinas/issues/2252) | Fixed signalfd bug/design | Ignored blocked signals plus per-consuming-thread readiness architecture |
| [#2256](https://github.com/asterinas/asterinas/issues/2256) | Fixed design | Pseudo-file inode association; metadata is outside model |
| [#2749](https://github.com/asterinas/asterinas/issues/2749) | Open unsupported | Stack growth after `RLIMIT_STACK`; unrelated to FD limits |
| [#2782](https://github.com/asterinas/asterinas/issues/2782) | Fixed input bug | Huge poll `nfds` allocation/OOM; numeric bound only |
| [#2826](https://github.com/asterinas/asterinas/issues/2826) | Fixed arithmetic bug | `fcntl` range-lock overflow; outside lifecycle state machine |
| [#2851](https://github.com/asterinas/asterinas/issues/2851) | Closed/unconfirmed | Concurrent `F_SETOWN` hang had no causal backtrace and #2864 did not explain it |
| [#2864](https://github.com/asterinas/asterinas/issues/2864) | Open, partially fixed | OFD owner placement/atomic-lock path fixed; process groups and permissions remain |
| [#2899](https://github.com/asterinas/asterinas/issues/2899) | Rejected false positive | Linux process name matched Asterinas; no CLOEXEC inheritance defect |
| [#2905](https://github.com/asterinas/asterinas/issues/2905) | Fixed boundary bug | Extreme `dup3` target overflow; not a concurrent identity target |
| [#3157](https://github.com/asterinas/asterinas/issues/3157) | Fixed lock bugs | Vsock and condvar atomic-mode violations; supports lock audit only |
| [#3178](https://github.com/asterinas/asterinas/issues/3178) | Fixed test false positive | Low FD reuse made a later close target an unrelated file |
| [#3283](https://github.com/asterinas/asterinas/issues/3283) | Open, outside model | Repeated restart leaves stale file-lock wakers; bounded FD/epoll model cannot expose proposed wraparound |

### 10.2 Significant source-history patches

| Commit | Historical contract learned |
|---|---|
| `e631da203` | Introduced `ClosedFile` so cleanup runs outside atomic file-table locking |
| `aa23e850c` | Corrected range-lock ownership |
| `fd2152413` | Moved eventfd flags to the correct ownership layer |
| `f0167940b` | Enforced `epoll_pwait2` sigset size |
| `23770dfd0` | Corrected eventfd init width and maximum write handling |
| `f6fb67e78` | Fixed poll invalid-entry behavior |
| `c707f0274` | Cleared poll `revents` on failure paths |
| `1c66e5f64` | Fixed pselect6 signal-mask handling |
| `7ade3b5dd` | Corrected per-close POSIX record-lock semantics |
| `ce4b59329` | Fixed dup2/dup3 error and replacement semantics |
| `43f570730` | Added `dup3` target validation against resource limits |
| `26ac77c37` | Fixed `fcntl` range arithmetic overflow |
| `7305d389f` | Refactored timer state to address races and fdinfo |
| `207bfe30e` | Added multithreaded exec quiescence |
| `ef099996f` | Fixed `close_range(UNSHARE)` behavior |
| `2a34a041c` | Fixed signalfd mask interpretation |
| `9109741e8` | Added timerfd settime flags and invalid-flag handling |
| `8600278a5` | Corrected file drop timing |
| `8187fa2f1` | Reworked `wait_events` timeout behavior |
| `7c249cf0c` | Corrected Subject observer-count memory ordering |
| `fab61f5f6` | Introduced stateless readiness recomputation |
| `ec2c6ab7a` | Settled on semi-stateless cached readiness |
| `e32fb2f91` | Introduced PollAdaptor/Poller RAII registration |
| `3461bd5de` | Added epoll wait boundary checks |
| `b5610f303` | Added `POLLNVAL` for invalid poll FDs |
| `8421046db` | Corrected signal-set size error handling |
| `c68302f70` | Released locks before blocking in `EpollFile` |
| `6e8dac0c3` | Made signalfd observe consuming-thread and process queues |
| `b9b09b814` | Removed sleeping mutex acquisition from epoll callback |
| `96efd6200` | Changed Subject locking for IRQ-safe notification |

Linked issue fixes inspected in addition to this core-path set include `3de5c42af` (#194), `c320552ae`/`fce5785af` (#506), `ac71234b8` (#1355), `2b34b1051` (#2864), and `1c7df8ef7` (#3178).

### 10.3 Open-PR screen

Open PRs are unmerged and are not modeled as current behavior.

| PR | Relevance to pinned source |
|---|---|
| [#3377](https://github.com/asterinas/asterinas/pull/3377) | Centralizes sigset-size validation; no current mask-restoration fix |
| [#3365](https://github.com/asterinas/asterinas/pull/3365) | File capabilities during exec; outside descriptor-table cutover |
| [#3481](https://github.com/asterinas/asterinas/pull/3481) | Inode append/memfd seal races; outside target state |
| [#3500](https://github.com/asterinas/asterinas/pull/3500) | Adds `F_SETSIG/F_GETSIG` and proposes per-entry storage; review against OFD ownership before merge |
| [#3534](https://github.com/asterinas/asterinas/pull/3534) | AppArmor exec transitions; unrelated to CLOEXEC table semantics |
| [#3572](https://github.com/asterinas/asterinas/pull/3572) | `O_PATH` fchown validation; unrelated |
| [#3576](https://github.com/asterinas/asterinas/pull/3576) | Refactors syscall restart across pause/poll/epoll; does not establish current terminal readiness correctness |
| [#3598](https://github.com/asterinas/asterinas/pull/3598) | Adds focused conformance selection; test infrastructure only |
| [#3611](https://github.com/asterinas/asterinas/pull/3611) | Earlier in-kernel eventfd reference proposal; unmerged architecture |
| [#3686](https://github.com/asterinas/asterinas/pull/3686) | Splits reusable eventfd counter from file wrapper and changes consume/copyout ordering; review separately |
| [#3689](https://github.com/asterinas/asterinas/pull/3689) | Shebang/execveat executable-FD handling; specialized exec path outside the generic table model |
| [#3699](https://github.com/asterinas/asterinas/pull/3699) | Vhost consumer of eventfd; depends on unmerged eventfd architecture |

None of these PRs resolves CA-1 through CA-6 in the pinned checkout. PR #3576 may change the wait/restart surface later, so Phase 4 confirmation must re-pin the source revision rather than silently testing a moving branch.

## 11. Modeling handoff

The companion [`modeling-brief.md`](modeling-brief.md) is the normative handoff to Spec Generation. The most important modeling choices are:

- represent FD slots and OFDs as different identities;
- retain captured references across close and slot reuse;
- split epoll preparation from userspace delivery commit;
- split source-state mutation from cache invalidation/notification;
- parameterize signalfd poll/read by current thread and retain process-wide pending state;
- split wakeup from terminal readiness/timeout/signal selection;
- represent temporary signal-mask restoration beyond the syscall handler;
- constrain the supported epoll graph to two acyclic instances while routing current cycle acceptance to testing.

Recommended state bound: two threads, three FD slots, three OFDs, two epolls, one signal number, one thread-directed pending signal, one process-directed pending signal, one timer/event source, and one in-flight syscall per thread. Use weak fairness only for enabled waiter and cleanup actions; do not use fairness to hide a permanently unnotified ready source.

## 12. Validation and artifact integrity

Performed in this phase:

- full read of every primary file and the listed supporting files;
- source ownership, synchronization, and interleaving audit;
- current Linux source/man-page comparison;
- repository commit, issue, comment, open-PR, regression, and blocklist archaeology;
- modeling-brief format and line-budget audit.

Not performed:

- no Asterinas source or test mutation;
- no build, QEMU boot, VM regression, or host behavioral test;
- no TLA+ generation, TLC run, trace validation, or minimized counterexample;
- no Phase 4 bug confirmation or severity classification.

Accordingly, this report intentionally contains no “confirmed finding.” A candidate may be promoted only after the later workflow supplies every required evidence item against a pinned revision and demonstrates the same observable divergence in a local `SMP=2` Asterinas VM.

## 13. Primary references

- Asterinas pinned source: [`file_table.rs`](../source/kernel/core/src/fs/file/file_table.rs), [`epoll/file.rs`](../source/kernel/core/src/events/epoll/file.rs), [`epoll/entry.rs`](../source/kernel/core/src/events/epoll/entry.rs), [`poll.rs`](../source/kernel/core/src/process/signal/poll.rs), [`pause.rs`](../source/kernel/core/src/process/signal/pause.rs), [`signalfd.rs`](../source/kernel/core/src/syscall/signalfd.rs), [`timerfd.rs`](../source/kernel/core/src/time/timerfd.rs), and [`execve.rs`](../source/kernel/core/src/process/execve.rs).
- Linux epoll implementation: [fs/eventpoll.c](https://github.com/torvalds/linux/blob/master/fs/eventpoll.c).
- Linux poll/select implementation: [fs/select.c](https://github.com/torvalds/linux/blob/master/fs/select.c).
- Linux signalfd implementation: [fs/signalfd.c](https://github.com/torvalds/linux/blob/master/fs/signalfd.c).
- Linux timerfd implementation: [fs/timerfd.c](https://github.com/torvalds/linux/blob/master/fs/timerfd.c).
- Linux API references: [close(2)](https://man7.org/linux/man-pages/man2/close.2.html), [dup(2)](https://man7.org/linux/man-pages/man2/dup.2.html), [epoll_ctl(2)](https://man7.org/linux/man-pages/man2/epoll_ctl.2.html), [epoll(7)](https://man7.org/linux/man-pages/man7/epoll.7.html), [poll(2)](https://man7.org/linux/man-pages/man2/poll.2.html), [signalfd(2)](https://man7.org/linux/man-pages/man2/signalfd.2.html), [execve(2)](https://man7.org/linux/man-pages/man2/execve.2.html), and [close_range(2)](https://man7.org/linux/man-pages/man2/close_range.2.html).
