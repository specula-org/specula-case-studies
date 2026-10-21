# Specula Summary

## Result

- Run status: **Complete**

The report records 2 `REPRODUCED` bugs, 0 `MASKED` findings, 0 `ENV_LIMITED` findings, and 4 other dispositions. The reproduced bugs can leave applications permanently blocked during flock conversion or cleanup, with no automatic recovery.

## Findings

- **MC-1 — Conflicting conversions retain the old shared flock** — Status: `REPRODUCED`. Impact: Failed shared-to-exclusive conversions can leave the old shared lock blocking other callers, and two blocking converters can deadlock until external intervention. Evidence: Both outcomes were reproduced twice through ordinary `flock(2)` calls in an Asterinas guest and compared with Linux controls.
- **MC-2 — A final temporary reference can deadlock flock cleanup** — Status: `REPRODUCED`. Impact: A cleanup race can permanently hang flock and close cleanup on the affected file, even when later flock calls request nonblocking operation. Evidence: Real `flock` and `close` calls reproduced the hang with controlled timing and also with timing gates disabled while tracing remained enabled.
- Other dispositions: 4.

## Validation limits

- MC-1's conversion-deadlock test observed zero completions for five seconds before external unlocks drained the blocked calls.
- MC-2 was reproduced on an instrumented kernel. With all hooks disabled, 128 rounds did not reproduce this defect, and a separate hang ended the run.


## Run coverage

- Stage coverage details are unavailable because this run resumed after an interruption.

## Run details

| Item | Value |
|---|---|
| Target | asterinas-local-flock-ownership |
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
| Phase 1 | 38m 37s | 39.4M total (38.1M cached) | $56.57 |
| Phase 2 | 39m 8s | 3.8M total (3.5M cached) | $10.20 |
| Phase 2.5 | 2h 15m | 46.0M total (45.1M cached) | $61.98 |
| Phase 3 | 1h 3m | 25.4M total (24.9M cached) | $32.91 |
| Phase 4a | 4h 9m | 71.1M total (62.3M cached) | $0.00 |
| Phase 4b | 5m 28s | 512.6K total (441.1K cached) | $1.58 |
| **Total (incomplete)** | 8h 52m | 186.3M total (174.3M cached) | $163.23 |

- Configured maximum parallelism: 1
- Configured TLC limits: 4G memory; 2 workers
