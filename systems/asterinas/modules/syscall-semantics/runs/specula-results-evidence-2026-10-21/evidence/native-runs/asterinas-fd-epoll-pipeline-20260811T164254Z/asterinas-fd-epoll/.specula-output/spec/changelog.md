# Validation Changelog

## Round 1 - Trace Validation

- [trace-pass] `close_reuse.ndjson`, `concurrent_fcntl.ndjson`, `dup_replace_flags.ndjson`, and `readiness_epoll.ndjson` matched `TraceMatched`.

## Round 1 - Model Checking

- [fix-spec] `MCSignalfdBindingCoversConsumer`: Case B. The model attached a signalfd poller binding to a later `epoll_wait` consumer. Source registers the poller during `EPOLL_CTL_ADD` or `EPOLL_CTL_MOD`; the model now records that registration-time binding and checks `SignalfdRegistrationHasBinding`.

## Round 2 - Trace Validation

- [trace-pass] Replayed all four captured traces after the signalfd registration correction; all matched.

## Round 2 - Model Checking

- [pass] `MC.cfg`: 519 generated states, 296 distinct states, depth 7. No standard invariant violation.

## Bug Hunting

- [bug] `MCDeliveryCommitOnCopyout`: an `epoll_wait` user-copy fault loses an edge-triggered ready entry.
- [bug] `MCOneShotDisabledIffDelivered`: the same user-copy fault disables a one-shot entry before a caller receives it.
- [bug] `MCNoDeadInterest`: final close leaves a dead epoll interest entry until a later ready-list scan.
- [bug] `MCCachedReadinessSound`: consuming a timerfd does not invalidate cached readiness.
- [bug] `MCRegisteredTransitionNotLost`: a signalfd mask update can make a pending signal readable without waking an epoll waiter.
- [bug] `MCVisibleReadyWinsTerminalRace`: `poll` can return timeout even though the timerfd has become readable.
- [confirm] `MCVisibleReadyWinsTerminalRace`: an observation-only SMP=2 run logged timer tick and the existing readiness notification before the timeout branch, then reproduced the public mismatch. The temporary markers and delay were removed after the run.

## Result

Converged in 2 rounds. All 4 traces pass against the final specification, the standard model check passes, and bug hunting found 6 model-checking findings. All six were reproduced through public syscall interfaces in the local Asterinas VM with `SMP=2`.
