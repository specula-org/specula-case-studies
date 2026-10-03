# Specula Summary

## Result

- Run status: **Complete**

Phase 4 recorded 0 reproduced bugs, 0 masked findings, 0 environment-limited findings, and 3 other dispositions. All three candidates were false positives; the exercised parameter-update and startup-recovery paths produced no incorrect externally observable state.

## Findings

- No reproduced, masked, or environment-limited findings were recorded.
- Other dispositions: 3.

## Validation limits

- No finding-specific validation limits were recorded.


## Run coverage

- Stage coverage details are unavailable because this run resumed after an interruption.
- Independent reviews were not run.

## Run details

| Item | Value |
|---|---|
| Target | cometbft |
| Original source commit | af998de26e82b796590b14fb2417864fc3c31202 |
| Current attempt source commit | af998de26e82b796590b14fb2417864fc3c31202 |
| Agent / model | codex / gpt-5.6-sol |
| Reasoning effort | xhigh |

## Detailed reports

- [Confirmation report](confirmed-bugs.md)
- [Severity report](bug-severity.md)

## Resource usage

| Phase | Runtime | Tokens | Estimated cost |
|---|---:|---:|---:|
| Phase 1 | - | - | - |
| Phase 2 | 15m 52s | 2.8M total (2.6M cached) | $2.21 |
| Phase 2.5 | 19m 27s | 2.6M total (2.4M cached) | $2.12 |
| Phase 3 | 47m 5s | 13.1M total (12.9M cached) | $6.51 |
| Phase 4a | 52m 21s | 15.5M total (14.6M cached) | $10.88 |
| Phase 4b | 10m 20s | 1.3M total (1.3M cached) | $1.12 |
| **Total (incomplete)** | 2h 25m | 35.3M total (33.8M cached) | $22.85 |

- Configured maximum parallelism: phase defaults (ordinary phases 1 at a time; per-finding confirmation 4 at a time)
- Configured TLC limits: 32G memory; 8 workers
