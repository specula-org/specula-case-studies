# Severity Classification — asterinas-fd-epoll

## Summary

- Total entries: 10
- Reproduced bugs: 8
- Severity-bearing findings: 0
- Critical: 4
- High: 4
- Medium: 0
- Low: 0
- No-severity dispositions: 2

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | Critical | A public `epoll_wait` with an invalid output buffer permanently consumes an edge-triggered readiness epoch, so later valid waits cannot observe the still-ready descriptor and an event-driven client can remain blocked without automatic recovery. |
| 2 | MC-2 | REPRODUCED | Critical | A public `epoll_wait` copyout fault disables one-shot interest before delivery, causing valid retries to miss the still-readable descriptor and stranding the client until an explicit `EPOLL_CTL_MOD`. |
| 3 | MC-3 | REPRODUCED | High | Final close through the public FD lifecycle leaves a dead watch visible in `/proc/self/fdinfo` for the epoll instance, exposing persistent but bounded stale lifecycle metadata without demonstrated stale-event delivery or FD retargeting. |
| 4 | MC-4 | REPRODUCED | High | Public timerfd and poll calls repeatedly report `POLLIN` after the one-shot expiration was consumed, while the corresponding read returns `EAGAIN`; the false readiness persists while the timer remains unarmed. |
| 5 | MC-5 | REPRODUCED | Critical | Updating a public signalfd mask can make an already queued signal readable without waking its existing epoll registration, so waits continue to time out until a direct read or later signal creates a new notification. |
| 6 | MC-6 | REPRODUCED | High | At the public poll timeout boundary, `poll` can return zero after a timerfd is already readable; the caller receives an irrevocably wrong terminal result, although the retained tick permits a separate retry. |
| 7 | CR-1 | FALSE POSITIVE | — | Phase 4 classified the suspected OFD-identity failure as a false positive, which is not a severity-bearing disposition. |
| 8 | CR-4 | REPRODUCED | Critical | A shared signalfd registered from one thread is not notified for another thread's directed signal, so the consuming thread's epoll waits can remain blocked even while its direct signalfd read succeeds. |
| 9 | CR-5 | REPRODUCED | High | Public epoll and mask-taking waits can return a timeout despite pre-deadline pipe readiness when scheduling delays the waiter; an immediate retry sees the event, making this a bounded incorrect terminal response. |
| 10 | CR-6 | DROPPED | — | Phase 4 marked the unsupported cyclic-epoll report as dropped, which is not a severity-bearing disposition. |
