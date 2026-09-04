# Severity Classification — nanvix (pm)

## Summary

- Total entries: 13
- Reproduced bugs: 6
- Severity-bearing findings: 1
- Critical: 1
- High: 5
- Medium: 1
- Low: 0
- No-severity dispositions: 6

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1     | MC-1  | FALSE POSITIVE | — | Phase 4a disposition is not severity-bearing; the deferred-reap live-count leak was rejected (real `has_other_threads` guard forbids the CE ordering). Recorded as-is, not reclassified. |
| 2     | MC-2  | REPRODUCED | High | Userspace `join()` (join_thread.rs:72) returns `NoSuchProcess`/ThreadNotFound instead of the target's exit status when a concurrent reap/detach consumes the zombie between wake and resume; the exit status is permanently lost. Externally observable via the real join kcall but bounded to a single join call. |
| 3     | MC-3  | REPRODUCED | Critical | A mutex owned by a joinable, never-joined zombie is released only at harvest, so every later `Mutex::lock` waiter — including the kernel's own unconditional `wait_cond` reacquire — sleeps forever with no owner alive to unlock. Permanent lost-wakeup deadlock reachable via real `lock_mutex` + thread `exit`, no automatic recovery. |
| 4     | MC-4  | REPRODUCED | High | The `Default` arm of `ProcessManager::kill` acts on a masked default-action signal (e.g. blocked SIGTERM) without reading the thread's `blocked()` mask, terminating/stopping the process immediately instead of leaving it pending. Externally observable improper process termination via the real `kill` kcall, contrary to POSIX; bounded to one process. |
| 5     | MC-5  | REPRODUCED | High | `interrupt_signal_candidate` scans only `suspended`, so a process-directed caught signal whose sole unmasked recipient is a sleeping thread in a runnable process is never delivered and stays pending forever; the registered handler never runs. Permanent lost-signal / liveness failure reachable via real sigaction+kill on a non-suspended process. |
| 6     | MC-6  | REPRODUCED | High | Nested handler `sigreturn` consumes the single `saved_blocked` slot, so when `sigsuspend()` unwinds the thread's blocked mask is permanently wrong (0x0 vs 0x1) and a signal it had blocked becomes wrongly deliverable. Signal-mask corruption propagating to incorrect delivery, reachable via a legal POSIX sigaction/kill/sigsuspend sequence. |
| 7     | MC-7  | REPRODUCED | High | `sigaction()` to `SIG_IGN`/`SIG_DFL` never reconciles the pending set, so an already-pending caught signal is stranded — never delivered and never discarded (POSIX requires SIG_IGN to discard) — and `sigpending()` reports it forever. Permanent, externally observable mis-handling reachable via pure Level-0 public API (sigaction+kill+delivery checkpoint). |
| 8     | MC-8  | MASKED | Medium | `kill`'s post path enqueues a caught signal into a zombie process with no runnability guard (`NoSignalToZombie` invariant violation). Mask: the zombie's pending set is discarded at reap and no live consumer reads it today, so no external effect is demonstrated; becomes a wasted/misrepresented pending slot once the planned zombie-pending reader lands. Internal invariant break with downstream risk. |
| 9     | MC-9  | FALSE POSITIVE | — | Phase 4a disposition is not severity-bearing; the "execv spuriously refused at MAX_THREADS" claim was rejected. Recorded without reclassification. |
| 10    | MC-10 | FALSE POSITIVE | — | Phase 4a disposition is not severity-bearing; the `put_mutex` mutual-exclusion split-brain claim was rejected. Recorded without reclassification. |
| 11    | MC-11 | FALSE POSITIVE | — | Phase 4a disposition is not severity-bearing; the `put_cond`/`CondvarInner::drop` panic claim was rejected. Recorded without reclassification. |
| 12    | CR-1  | FALSE POSITIVE | — | Phase 4a disposition is not severity-bearing; the location/state-machine integrity concern was rejected. Recorded without reclassification. |
| 13    | CR-2  | FALSE POSITIVE | — | Phase 4a disposition is not severity-bearing; the fork/exec/address-space rollback-completeness concern was rejected. Recorded without reclassification. |
