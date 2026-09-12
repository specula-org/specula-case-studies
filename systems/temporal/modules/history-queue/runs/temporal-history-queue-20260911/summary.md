# Specula Summary

## Result

- Run status: **Complete**

Final results: 1 REPRODUCED bug, 1 MASKED finding, 0 ENV_LIMITED findings, and 3 other dispositions. Readable transfer work can remain stranded in a live reader until reload or another cursor-resetting mutation; stale-owner cleanup was observed without a demonstrated wrong workflow or activity outcome.

## Findings

- **CR-2 — Logical scope survives but the live reader cursor disappears** — Status: `REPRODUCED`. Impact: Later transfer tasks can stop reaching the scheduler during live ownership even though their readable scopes remain. Evidence: A test using normal reader operations demonstrated missed scheduler submission and successful recovery after reader reconstruction.
- **CR-4 — An old owner can finish effects after durable ownership changes** — Status: `MASKED`. Impact: An old owner's checkpoint can delete transfer rows after shard ownership changes, but no incorrect workflow or activity outcome was observed. Evidence: A test with controlled ownership and acknowledgement state observed row deletion followed by rejection of the stale queue-state update.
- Other dispositions: 3.

## Validation limits

- CR-2 was exercised in a queue-reader test; repeated notification, checkpointing, and polling did not repair the live cursor, while reconstruction restored task submission without physical data loss.
- CR-4 required controlled ownership and local acknowledgement state because ordinary public operations and available timing hooks did not trigger the window. The advanced local acknowledgement boundary and downstream stale/duplicate-start guards mask the correctness impact.


## Run details

| Item | Value |
|---|---|
| Target | temporal-history-queue |
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
| Phase 1 | 44m 25s | 67.7M total (65.0M cached) | $98.42 |
| Phase 2 | 49m 13s | 9.4M total (9.0M cached) | $17.04 |
| Phase 2.5 | 40m 54s | 12.1M total (11.8M cached) | $17.93 |
| Phase 3 | 51m 10s | 19.3M total (18.9M cached) | $26.33 |
| Phase 4a | 24m 16s | 22.8M total (21.5M cached) | $21.71 |
| Phase 4b | 4m 25s | 286.5K total (250.9K cached) | $0.92 |
| **Total** | 3h 34m | 131.7M total (126.4M cached) | $182.34 |

- Configured maximum parallelism: 4
- Configured TLC limits: 112G memory; 32 workers
