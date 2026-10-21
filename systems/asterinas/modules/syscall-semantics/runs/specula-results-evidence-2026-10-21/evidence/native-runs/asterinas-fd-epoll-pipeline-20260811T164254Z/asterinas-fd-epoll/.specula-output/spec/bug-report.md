# Bug Report — Asterinas FD Lifecycle and Epoll

## Summary

- Scenarios tested: 20
- Bugs found: 6
- Configs run: all `MC_hunt_*.cfg` configurations in this run
- Convergence evidence: 4/4 trace validations passed after the Case B signalfd-registration correction; `MC.cfg` completed with 519 generated / 296 distinct states at depth 7.
- Confirmation: every finding below was reproduced by its standalone public-syscall test in the local `SMP=2` Asterinas VM. The same sources pass on the host Linux control.

## Bug 1: epoll EFAULT loses edge-triggered readiness

- **Scenario**: S2 copyout atomicity
- **Severity**: High
- **Invariant violated**: `MCDeliveryCommitOnCopyout`
- **Config**: `MC_hunt_s2_copyout.cfg`
- **Counterexample**: 9-state BFS-minimized bounded counterexample; [output](output/MC_hunt_s2_copyout_round2_bfs.out) and [JSON trace](output/MC_hunt_s2_copyout_round2_bfs_cex.json)

### Trace Summary

1. `EPOLL_CTL_ADD` records an edge-triggered timerfd interest.
2. The timerfd becomes ready and the entry is queued.
3. `EpollFile::wait` pops the queued entry before the syscall writes the event to user memory.
4. The copyout fault occurs. The model records an undelivered ready epoch with no queued entry.

### Root Cause

`do_epoll_pwait2` calls `EpollFile::wait` before `user_space.write_val` ([`kernel/core/src/syscall/epoll.rs:129`](../../source/kernel/core/src/syscall/epoll.rs#L129), [`:145-152`](../../source/kernel/core/src/syscall/epoll.rs#L145-L152)). `pop_multi_ready` removes the entry and only requeues level-triggered entries ([`kernel/core/src/events/epoll/file.rs:244-278`](../../source/kernel/core/src/events/epoll/file.rs#L244-L278)). A failed user copy therefore returns `EFAULT` after the edge has been consumed. This uses supported `EPOLLET`; only `EPOLLEXCLUSIVE` and `EPOLLWAKEUP` are warned as unsupported ([`file.rs:282-285`](../../source/kernel/core/src/events/epoll/file.rs#L282-L285)).

### Affected Code

- `kernel/core/src/syscall/epoll.rs:129-152`: mutates ready state before user copyout.
- `kernel/core/src/events/epoll/file.rs:244-278`: pops the ready entry and does not restore an edge-triggered entry.

### Linux-visible Comparison

Linux reinserts an event on a user-copy failure before reporting that failure, and `epoll_wait(2)` documents `EFAULT` for an inaccessible event buffer. The host-Linux control retained and redelivered the event. This is not an unsupported flag or a delayed file-system close error.

### Recommendation

Make delivery transactional with respect to copyout: retain or reinsert every popped ready entry on copyout failure, and commit edge delivery only after all selected events are written successfully.

---

## Bug 2: epoll EFAULT disables one-shot interest before delivery

- **Scenario**: S2 one-shot delivery
- **Severity**: High
- **Invariant violated**: `MCOneShotDisabledIffDelivered`
- **Config**: `MC_hunt_s2_oneshot.cfg`
- **Counterexample**: 10-state BFS-minimized bounded counterexample; [output](output/MC_hunt_s2_oneshot_round2_bfs.out) and [JSON trace](output/MC_hunt_s2_oneshot_round2_bfs_cex.json)

### Trace Summary

1. A one-shot timerfd interest is added and then becomes ready.
2. `Entry::poll` selects the event and disables the observer.
3. The subsequent event-buffer copy faults.
4. The ready event was never delivered, but the entry remains disabled until an explicit `EPOLL_CTL_MOD`.

### Root Cause

`Entry::poll` resets the one-shot observer as soon as it observes readiness ([`kernel/core/src/events/epoll/entry.rs:136-147`](../../source/kernel/core/src/events/epoll/entry.rs#L136-L147)). That happens inside `EpollFile::wait`, before the syscall loop that can fail while copying events to user space. The ready state and the one-shot state therefore commit at different times from the caller-visible result.

### Affected Code

- `kernel/core/src/events/epoll/entry.rs:136-147`: disables `EPOLLONESHOT` before copyout commits.
- `kernel/core/src/syscall/epoll.rs:129-152`: reports `EFAULT` after the disable has occurred.

### Linux-visible Comparison

Linux applies one-shot disable after successful event delivery; the host-Linux control redelivered the event after `EFAULT`. The scenario uses supported `EPOLLONESHOT` and ordinary `eventfd` operations.

### Recommendation

Defer the one-shot disable until successful copyout, or carry a rollback record that restores both the ready entry and enabled state on every copyout failure.

---

## Bug 3: final close leaves a dead epoll interest entry

- **Scenario**: S2 epoll lifecycle
- **Severity**: Medium
- **Invariant violated**: `MCNoDeadInterest`
- **Config**: `MC_hunt_s2_epoll_delivery.cfg`
- **Counterexample**: 7-state BFS-minimized bounded counterexample; [output](output/MC_hunt_s2_epoll_delivery_round2_bfs.out) and [JSON trace](output/MC_hunt_s2_epoll_delivery_round2_bfs_cex.json)

### Trace Summary

1. Add a nonblocking eventfd to an epoll instance.
2. Close the final descriptor for that file object.
3. The entry retains only a weak file reference but remains in the interest set.
4. It is removed only if a later `epoll_wait` scans the ready list and notices the dead weak reference.

### Root Cause

An `EntryKey` contains both the descriptor number and a weak file-object identity ([`kernel/core/src/events/epoll/entry.rs:46-67`](../../source/kernel/core/src/events/epoll/entry.rs#L46-L67)), so descriptor reuse does not retarget the entry. However, `FileTable::close_file` merely removes the table entry ([`kernel/core/src/fs/file/file_table.rs:196-205`](../../source/kernel/core/src/fs/file/file_table.rs#L196-L205)); it has no epoll cleanup path. `EpollFile` removes a dead entry only while `pop_multi_ready` happens to scan it ([`kernel/core/src/events/epoll/file.rs:259-267`](../../source/kernel/core/src/events/epoll/file.rs#L259-L267)). The reproduced `/proc/self/fdinfo` entry remains visible after final close.

### Affected Code

- `kernel/core/src/fs/file/file_table.rs:196-205`: final descriptor removal has no epoll-interest release hook.
- `kernel/core/src/events/epoll/file.rs:164-178`: explicit `EPOLL_CTL_DEL` is the only immediate interest removal path.
- `kernel/core/src/events/epoll/file.rs:259-267`: delayed weak-reference cleanup occurs only during wait scanning.

### FD Slot Identity Versus File Object Identity

This is not a numeric-FD reuse misdelivery. The `(fd, weak-file)` key preserves the old file-object identity, so a new file installed at the same slot cannot silently become the watched object. The defect is that the old, dead identity remains in the interest list after its final reference is gone.

### Linux-visible Comparison

Linux ties epoll watches to an open file description and removes the watch after all descriptors for that description close. The host-Linux control no longer showed the target in `fdinfo` after close. The prior Asterinas PR #1277 fixed the distinct numeric-FD-only key problem; it did not report this final-close cleanup path.

### Recommendation

Add a final-file-release cleanup path that shuts down and removes matching entries when the last file-object reference is released. Keep the file-table, epoll, subject, and observer lock order explicit so cleanup cannot introduce a cycle.

---

## Bug 4: consumed timerfd remains ready through the poll cache

- **Scenario**: S3 readiness cache
- **Severity**: High
- **Invariant violated**: `MCCachedReadinessSound`
- **Config**: `MC_hunt_s3_cache.cfg`
- **Counterexample**: 9-state BFS-minimized bounded counterexample; [output](output/MC_hunt_s3_cache_round2_bfs.out) and [JSON trace](output/MC_hunt_s3_cache_round2_bfs_cex.json)

### Trace Summary

1. Register a poller for a timerfd.
2. Expiration increments `ticks` and notifies the shared `Pollee`; `POLLIN` is cached.
3. A timerfd read clears `ticks`.
4. A later zero-timeout poll returns the stale cached `POLLIN` although a new read would return `EAGAIN`.

### Root Cause

The expiration callback calls `pollee.notify`, which invalidates the cache ([`kernel/core/src/time/timerfd.rs:102-105`](../../source/kernel/core/src/time/timerfd.rs#L102-L105)). `try_read` clears the tick counter with `fetch_and(0)` but never calls `pollee.invalidate` ([`timerfd.rs:177-186`](../../source/kernel/core/src/time/timerfd.rs#L177-L186)). `Pollee::poll_with` is therefore allowed to return the cached value ([`kernel/core/src/process/signal/poll.rs:106-151`](../../source/kernel/core/src/process/signal/poll.rs#L106-L151)), contrary to its stated rule that disappearing events require invalidation ([`poll.rs:25-28`](../../source/kernel/core/src/process/signal/poll.rs#L25-L28)).

### Affected Code

- `kernel/core/src/time/timerfd.rs:177-186`: consumes ticks without invalidating readiness.
- `kernel/core/src/time/timerfd.rs:200-204`: serves timerfd poll from `Pollee`.
- `kernel/core/src/process/signal/poll.rs:25-28`: documents the violated cache contract.

### Linux-visible Comparison

After a successful timerfd read consumes the expiration count, the host-Linux control's immediate `poll(..., 0)` returned no readiness. The tested `timerfd_create`, `timerfd_settime`, `read`, and `poll` operations are all supported paths.

### Recommendation

Invalidate the timerfd `Pollee` after a successful transition from nonzero ticks to zero, including the timer-reset path that clears ticks. Preserve the existing notify-on-expiration behavior.

---

## Bug 5: signalfd mask update does not publish readiness

- **Scenario**: S4 signal-mask transition
- **Severity**: High
- **Invariant violated**: `MCRegisteredTransitionNotLost` (temporal property)
- **Config**: `MC_hunt_s4_mask_transition.cfg`
- **Counterexample**: 8-state BFS-minimized bounded counterexample; [output](output/MC_hunt_s4_mask_transition_round2_bfs.out) and [JSON trace](output/MC_hunt_s4_mask_transition_round2_bfs_cex.json)

### Trace Summary

1. Queue a blocked `SIGUSR1` while a signalfd mask excludes it.
2. Add that signalfd to epoll, completing normal poller registration.
3. Update the signalfd mask to include `SIGUSR1`.
4. The already pending signal becomes readable by the file's predicate, but no readiness notification reaches the epoll waiter.

### Root Cause

The update syscall invokes only `SignalFile::update_signal_mask` and changes nonblocking state ([`kernel/core/src/syscall/signalfd.rs:103-119`](../../source/kernel/core/src/syscall/signalfd.rs#L103-L119)). `update_signal_mask` is only a relaxed atomic store ([`signalfd.rs:157-163`](../../source/kernel/core/src/syscall/signalfd.rs#L157-L163)). Poller registration attaches to the thread and process signal queues ([`signalfd.rs:207-216`](../../source/kernel/core/src/syscall/signalfd.rs#L207-L216), [`kernel/core/src/process/posix_thread/mod.rs:266-270`](../../source/kernel/core/src/process/posix_thread/mod.rs#L266-L270)), but a mask transition neither invalidates nor notifies that registration.

### Affected Code

- `kernel/core/src/syscall/signalfd.rs:103-119`: update path publishes no readiness change.
- `kernel/core/src/syscall/signalfd.rs:157-163`: mask storage lacks a wakeup or cache invalidation.
- `kernel/core/src/syscall/signalfd.rs:207-216`: readiness depends on the updated mask and registered queue poller.

### Linux-visible Comparison

The host-Linux control reports the already pending signal after the mask update. Linux's signalfd implementation wakes the signalfd wait queue after updating the mask. This is a supported signalfd update, not an unsupported signal-mask flag.

### Recommendation

Publish a reevaluation wakeup for existing signalfd registrations whenever an updated mask can change the readable predicate. The implementation should make that notification compatible with thread and process signal queues and avoid holding their locks across epoll callbacks.

---

## Bug 6: poll returns timeout after timerfd becomes readable

- **Scenario**: S5 timeout arbitration
- **Severity**: High
- **Invariant violated**: `MCVisibleReadyWinsTerminalRace`
- **Config**: `MC_hunt_s5_arbitration.cfg`
- **Counterexample**: 6-state BFS-minimized bounded counterexample; [output](output/MC_hunt_s5_arbitration_round2_bfs.out) and [JSON trace](output/MC_hunt_s5_arbitration_round2_bfs_cex.json)

### Trace Summary

1. `poll` registers a timerfd and starts a bounded wait.
2. The timerfd expiration makes its tick counter readable at the timeout boundary.
3. The waiter takes the timeout terminal path.
4. `do_poll` returns zero before rescanning the descriptors, even though an immediate timerfd read succeeds.

### Root Cause

`do_poll` returns `Ok(0)` as soon as `poller.wait()` returns `ETIME` ([`kernel/core/src/syscall/poll.rs:108-120`](../../source/kernel/core/src/syscall/poll.rs#L108-L120)). `WaitQueue::pause_timeout` checks the timeout after the wakeup and returns `ETIME` when the timer has elapsed ([`kernel/core/src/process/signal/pause.rs:171-209`](../../source/kernel/core/src/process/signal/pause.rs#L171-L209)). The terminal path has no final `count_events()` arbitration. In three independent `SMP=2` VM runs, the standalone test observed 5/2000, 2/2000, and 2/2000 zero returns for which the immediate read succeeded; the exact source test reproduced 4/2000. A temporary, reverted timing-observation run logged the existing timer tick and readiness notification before the timeout branch, then observed the same caller-visible mismatch.

### Affected Code

- `kernel/core/src/syscall/poll.rs:108-120`: returns timeout before a terminal rescan.
- `kernel/core/src/process/signal/pause.rs:171-209`: timeout can win after a readiness-producing wakeup.

### Linux-visible Comparison

The host-Linux control did not observe a zero result followed by an immediately readable timerfd in the same 2,000-iteration test. Linux's polling path rescans descriptors before it settles the terminal result. This test uses ordinary `poll` and `timerfd` syscalls with no unsupported flags.

### Recommendation

When `poller.wait()` returns timeout, perform one terminal `count_events()` scan and return its nonzero result when readiness is visible. Preserve signal interruption and timeout semantics when the scan is empty.

---

## Not Reproduced

| Scenario | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Eventfd mutex | `MC_hunt_eventfd_mutex.cfg` | 301 generated / 178 distinct, depth 19 | No violation; 30-minute simulation reached 33,197 traces. |
| Lifetime | `MC_hunt_lifetime.cfg` | 135 / 71, depth 9 | No violation; simulation reached 9,953 traces. |
| Exec | `MC_hunt_s1_exec.cfg` | 169 / 151, depth 5 | No violation; simulation reached 9,268 traces. |
| FD exec | `MC_hunt_s1_fd_exec.cfg` | 288 / 156, depth 7 | No violation; simulation reached 91,849 traces. |
| FD flags | `MC_hunt_s1_flags.cfg` | 10,593 / 3,308, depth 9 | No violation; simulation reached 91,193 traces. |
| Replacement | `MC_hunt_s1_replacement.cfg` | 397 / 247, depth 7 | No violation; simulation reached 85,575 traces. |
| Slot map | `MC_hunt_s1_slot_map.cfg` | 16 / 11, depth 4 | No violation; simulation reached 118,799 traces. |
| Cross-reuse | `MC_hunt_s2_cross_reuse.cfg` | 3,810 / 1,395, depth 26 | No violation; BFS exceeded the simulation threshold. |
| Key identity | `MC_hunt_s2_key_identity.cfg` | 124 / 75, depth 8 | No violation; simulation reached 64,478 traces. |
| Level trigger | `MC_hunt_s2_level.cfg` | 8,897 / 2,794, depth 21 | No violation; simulation reached 41 traces at depth 100. |
| Registered delivery | `MC_hunt_s3_registered_delivery.cfg` | 1,487 / 669, depth 17 | No violation; simulation reached 435 traces. |
| Signalfd binding | `MC_hunt_s4_binding.cfg` | 625 / 329, depth 8 | No violation; simulation reached 73,182 traces. |
| Signal-mask restoration | `MC_hunt_s5_mask_restore.cfg` | 205 / 104, depth 11 | No violation; simulation reached 86,811 traces. |
| Nested epoll | `MC_hunt_s6_nested.cfg` | 1,889 / 874, depth 13 | No violation; simulation reached 2,432 traces. |

All simulation runs used `-S -n 999999999 -p 100 -t 30`; TLC stopped at the configured time budget without an error. They are additional randomized coverage, not exhaustive proofs beyond their bounded BFS models.
