# Specula Summary

## Result

- Run status: **Complete**

Final results: 2 `REPRODUCED`, 1 `MASKED`, 1 `ENV_LIMITED`, and 0 other dispositions. The reproduced bugs expose incorrect or conflicting Update responses and an Update that stays unresolved across repeated retries.

## Findings

- **CR-1 — A write result, published effect, and caller receipt are different events** — Status: `ENV_LIMITED`. Impact: A caller could receive another Update's terminal outcome under cross-host cache divergence. Evidence: A component test with controlled stale-cache state returned the wrong result; the public multi-host sequence could not be exercised.
- **CR-2 — Old work is fenced by identity, but error cleanup can affect current work** — Status: `MASKED`. Impact: Stale task completion and timer processing can disrupt replacement work, while existing recovery preserves the caller's final Update outcome. Evidence: Public API testing with forced cache loss showed replacement-task rejection followed by successful recovery.
- **CR-3 — Mixed Update outcomes and final Workflow closure share an effect batch** — Status: `REPRODUCED`. Impact: Callers can receive a rejection link for an accepted handler failure or a terminal failure followed by success for the same Update ID. Evidence: Both behaviors were exercised through public APIs, with a controlled persistence failure for the conflicting-outcome case.
- **CR-4 — Volatile deduplication must retain a delivery or retry path** — Status: `REPRODUCED`. Impact: An Update can remain admitted without an outcome across repeated retries and redelivery until manual cache clearing enables recovery. Evidence: Public API testing used controlled timing and configuration and observed repeated failure to reach a terminal outcome.
- Other dispositions: 0.

## Validation limits

- CR-1: The local harness permits only one node per service, leaving the multi-host public trigger unverified; same-host testing recovered because a later completion overwrote the cache entry.
- CR-2: The public completion test forced shard/cache loss, and the timer test used controlled component state; readmission/retry and normal-queue delivery recovered the final Update outcome.
- CR-3: The conflicting-outcome case used a transaction-size limit and a forced timeout on the termination write; durable recovery did not correct the earlier caller-visible failure.
- CR-4: Manual shard/cache clearing recovered the Update, while repeated retries and redelivery through the normal unprocessed-update path did not.


## Run details

| Item | Value |
|---|---|
| Target | temporal-update |
| Original source commit | 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025 |
| Current attempt source commit | 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025 |
| Agent / model | codex / Varies by task |
| Reasoning effort | xhigh |

## Detailed reports

- [Confirmation report](confirmed-bugs.md)
- [Severity report](bug-severity.md)

## Resource usage

| Phase | Runtime | Tokens | Estimated cost |
|---|---:|---:|---:|
| Phase 1 | 1h 8m | 91.1M total (88.9M cached) | $119.61 |
| Phase 2 | 1h 3m | 14.4M total (13.8M cached) | $23.79 |
| Phase 2.5 | 43m 25s | 9.8M total (9.4M cached) | $15.37 |
| Phase 3 | 28m 40s | 8.2M total (7.9M cached) | $13.24 |
| Phase 4a | 29m 39s | 26.2M total (24.2M cached) | $26.72 |
| Phase 4b | 4m 3s | 233.7K total (190.1K cached) | $0.89 |
| **Total** | 3h 58m | 150.0M total (144.4M cached) | $199.61 |

- Configured maximum parallelism: 4
- Configured TLC limits: 224G memory; 64 workers
