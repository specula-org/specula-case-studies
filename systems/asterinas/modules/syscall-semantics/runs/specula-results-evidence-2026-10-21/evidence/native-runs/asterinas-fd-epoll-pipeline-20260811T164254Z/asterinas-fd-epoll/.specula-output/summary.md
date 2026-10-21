# Specula Summary

## Result

- Run status: **Complete**

Eight bugs were reproduced, none were masked or environment-limited, and two entries received other dispositions. The reproduced results show missed readiness notifications, stale readiness or lifecycle state, and incorrect timeout arbitration across epoll, poll, signalfd, and timerfd interfaces.

## Findings

- **MC-1 — epoll EFAULT loses edge-triggered readiness** — Status: `REPRODUCED`. Impact: A failed epoll copyout consumes an edge-triggered readiness epoch, so a later valid wait misses the still-ready descriptor. Evidence: An SMP=2 Asterinas public-API test returned `EFAULT` and then missed the unread event on a valid retry, while the Linux control retained it.
- **MC-2 — epoll EFAULT disables one-shot interest before delivery** — Status: `REPRODUCED`. Impact: A failed epoll copyout disables one-shot interest before delivery, leaving valid retries unable to observe the still-readable descriptor until explicit rearm. Evidence: The SMP=2 guest test observed `EFAULT` followed by a missing event on the valid-buffer retry, while the Linux control delivered it.
- **MC-3 — final close leaves a dead epoll interest entry** — Status: `REPRODUCED`. Impact: Closing the final watched descriptor leaves a dead watch visible in the epoll instance's fdinfo for its remaining lifetime. Evidence: An SMP=2 public-API guest test parsed the stale fdinfo record after final close, while the Linux control omitted it.
- **MC-4 — consumed timerfd remains ready through the poll cache** — Status: `REPRODUCED`. Impact: A consumed one-shot timerfd continues reporting `POLLIN` even though the next nonblocking read returns `EAGAIN`. Evidence: The SMP=2 guest returned stale readiness on three post-consumption polls, while the Linux control timed out.
- **MC-5 — signalfd mask update does not publish readiness** — Status: `REPRODUCED`. Impact: Expanding a signalfd mask to include an already pending signal makes the descriptor readable without notifying its existing epoll registration. Evidence: Two SMP=2 runs timed out after the mask update even though direct poll and read observed the signal, while a newly queued signal woke epoll.
- **MC-6 — poll returns timeout after timerfd becomes readable** — Status: `REPRODUCED`. Impact: Poll can return a timeout at the deadline boundary even though the timerfd has already become readable. Evidence: An SMP=2 public-API test returned zero from poll and immediately read a complete timerfd expiration count.
- **CR-4 — signalfd epoll registration may bind readiness to the wrong thread** — Status: `REPRODUCED`. Impact: A shared signalfd registered from one thread can miss a directed signal consumed by another thread, leaving that consumer's epoll wait without notification. Evidence: The SMP=2 two-thread test timed out twice before the consuming thread directly read its pending signal, while the Linux control reported readiness.
- **CR-5 — epoll and mask-taking waits may bypass terminal readiness arbitration** — Status: `REPRODUCED`. Impact: Delayed epoll and mask-taking waits can return a timeout despite pipe readiness occurring before the deadline. Evidence: A public-API FIFO test returned zero across four wait interfaces on Asterinas and found readiness on immediate retries, while Linux returned readiness on the original waits.
- Other dispositions: 2.

## Validation limits

- A fresh independent MC-2 guest rerun was blocked by a TLS failure while fetching `inherit-methods-macro`; the report relies on the previously completed SMP=2 guest execution and does not treat the blocked rerun as evidence.
- MC-6 exercises a natural timer-expiration and timeout boundary; the report records a stronger witness that observed timerfd readiness while the polling thread remained asleep before the timeout return.
- CR-5 requires controlled CPU-priority scheduling to delay the waiter past its deadline; the report resolved the affinity concern with a one-vCPU run because Asterinas does not migrate threads for `sched_setaffinity`.


## Run coverage

- Source analysis was skipped.
- Formal model generation was skipped.
- Execution trace collection was skipped.
- Trace validation and model checking were skipped.

## Run details

| Item | Value |
|---|---|
| Target | asterinas-fd-epoll |
| Original source commit | 4ba4abbe8cb3f2892129d67b0301cf247bbdda0f |
| Current attempt source commit | 4ba4abbe8cb3f2892129d67b0301cf247bbdda0f |
| Agent / model | codex / Varies by task |
| Reasoning effort | max |

## Detailed reports

- [Confirmation report](confirmed-bugs.md)
- [Severity report](bug-severity.md)

## Resource usage

| Phase | Runtime | Tokens | Estimated cost |
|---|---:|---:|---:|
| Phase 1 | 1h 4m | 46.0M total (44.1M cached) | $37.13 |
| Phase 2 | 1h 27m | 33.1M total (32.2M cached) | $24.75 |
| Phase 2.5 | 2h 15m | 54.3M total (53.2M cached) | $35.73 |
| Phase 3 | 3h 6m | 79.7M total (77.2M cached) | $42.97 |
| Phase 4a | - | 28.1M total (26.7M cached) | $12.21 |
| Phase 4b | 9m 17s | 1.5M total (1.4M cached) | $1.78 |
| **Total (incomplete)** | 8h 2m | 242.8M total (234.8M cached) | $154.58 |

- Configured maximum parallelism: 1
- Configured TLC limits: auto memory; unbounded (report only) workers
