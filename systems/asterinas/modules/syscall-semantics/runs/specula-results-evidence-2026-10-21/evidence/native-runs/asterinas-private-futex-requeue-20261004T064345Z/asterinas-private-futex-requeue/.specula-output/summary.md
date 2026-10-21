# Specula Summary

## Result

- Run status: **Complete**

Four bugs were reproduced, with no masked or environment-limited findings and one other disposition. The reproduced defects can strand waiting threads, wake a thread despite a zero wake quota, and return incorrect futex results.

## Findings

- **MC-1 — A timed-out waiter moved to another bucket leaves its entry behind** — Status: `REPRODUCED`. Impact: A timed-out wait reports success and leaves a stale entry that can keep a later untimed waiter blocked indefinitely despite the intended wake. Evidence: Public futex calls reproduced the bug in three guest boots, using read-only setup probes and a Linux control.
- **MC-2 — Ordinary REQUEUE with a zero wake quota wakes a waiter** — Status: `REPRODUCED`. Impact: A waiter wakes unexpectedly and the caller receives an incorrect count despite requesting no wakes. Evidence: Ordinary futex calls reproduced this in two guest runs, while the same binary on Linux woke no waiters.
- **MC-3 — A same-bucket REQUEUE with a zero migration quota moves one waiter** — Status: `REPRODUCED`. Impact: An unintended migration makes wakes on the source futex miss the waiter, which can remain blocked indefinitely if it has no timeout. Evidence: Public futex calls reproduced the behavior in two guest boots, with a separate read-only bucket check and a Linux control.
- **MC-4 — REQUEUE returns only the number of woken waiters** — Status: `REPRODUCED`. Impact: Callers receive a count that omits requeued waiters, including when the source and destination addresses are identical. Evidence: Public futex calls reproduced the wrong count for different-bucket, same-bucket, and identical-address cases, while the Linux control returned the full count.
- Other dispositions: 1.

## Validation limits

- The tests coordinated waiter enrollment through timing, cooperative scheduling, or read-only probes.
- MC-1 used read-only probes to select words in different buckets. Its retained kernel memory was inferred from code and was not measured.
- MC-3 required words sharing a bucket. Its test used a five-second timeout and an explicit destination wake to release the misplaced waiter.


## Run coverage

- Stage coverage details are unavailable because this run resumed after an interruption.

## Run details

| Item | Value |
|---|---|
| Target | asterinas-private-futex-requeue |
| Original source commit | 0c60537098f4c2949ad2d382aaf499de72263d76 |
| Current attempt source commit | 0c60537098f4c2949ad2d382aaf499de72263d76 |
| Agent / model | Varies by task / Varies by task |
| Reasoning effort | max |

## Detailed reports

- [Confirmation report](confirmed-bugs.md)
- [Severity report](bug-severity.md)

## Resource usage

| Phase | Runtime | Tokens | Estimated cost |
|---|---:|---:|---:|
| Phase 1 | 20m 18s | 21.2M total (20.3M cached) | $33.59 |
| Phase 2 | 42m 21s | 4.2M total (3.8M cached) | $10.43 |
| Phase 2.5 | 40m 55s | 7.3M total (7.1M cached) | $12.22 |
| Phase 3 | 5h 32m | 74.5M total (73.2M cached) | $58.10 |
| Phase 4a | 3h 36m | 42.7M total (37.7M cached) | $0.00 |
| Phase 4b | 4m 20s | 451.2K total (388.0K cached) | $1.40 |
| **Total (incomplete)** | 10h 56m | 150.3M total (142.4M cached) | $115.75 |

- Configured maximum parallelism: 1
- Configured TLC limits: 4G memory; 2 workers
