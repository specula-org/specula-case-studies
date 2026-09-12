# Specula Summary

## Result

- Run status: **Complete**

The report records 1 REPRODUCED bug, 0 MASKED findings, 0 ENV_LIMITED findings, and 4 other dispositions. The reproduced fairness-reader defect can leave a still-eligible task stored but permanently skipped by restart reads.

## Findings

- **CR-5 — Fairness eviction during unlocked replacement** — Status: `REPRODUCED`. Impact: The reader can persist an acknowledgement past a still-eligible task, making restart reads skip it even though it remains stored. Evidence: The reproduction used controlled timing during task replacement and exercised the real reader restart/read path against SQLite.
- Other dispositions: 4.

## Validation limits

- Reproduction required controlled timing at the unlocked replacement window; the control run did not reproduce the defect.
- The demonstrated permanent loss of task visibility is at the fair reader's restart/read boundary; no downstream recovery or masking was observed in the reproduction.


## Run coverage

- Stage coverage details are unavailable because this run resumed after an interruption.

## Run details

| Item | Value |
|---|---|
| Target | temporal-matching |
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
| Phase 1 | 35m 0s | 44.8M total (43.4M cached) | $62.84 |
| Phase 2 | 52m 52s | 8.7M total (8.0M cached) | $18.85 |
| Phase 2.5 | 2h 3m | 30.3M total (29.5M cached) | $44.43 |
| Phase 3 | 4h 10m | 61.8M total (60.0M cached) | $91.71 |
| Phase 4a | 1h 2m | 49.0M total (46.2M cached) | $46.01 |
| Phase 4b | 6m 54s | 517.7K total (455.0K cached) | $1.54 |
| **Total** | 8h 51m | 195.1M total (187.7M cached) | $265.39 |

- Configured maximum parallelism: 4
- Configured TLC limits: 112G memory; 32 workers
