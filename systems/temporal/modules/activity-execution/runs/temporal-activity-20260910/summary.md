# Specula Summary

## Result

- Run status: **Complete**

The final report contains 0 REPRODUCED bugs, 1 MASKED finding, 0 ENV_LIMITED findings, and 4 other dispositions. The task recorder can omit committed tasks after a persistence timeout, while the current Activity trace harness prevents that incomplete view from being accepted as complete evidence.

## Findings

- **CR-5 — Independent observations must cover the entire execution** — Status: `MASKED`. Impact: A consumer relying only on the task recorder can miss tasks from a committed mutation when persistence returns a timeout. Evidence: The test-cluster Activity path exercised a committed operation with a timeout response, and a focused recorder test observed one requested transfer task but none recorded.
- Other dispositions: 4.

## Validation limits

- The recorder gap was isolated in a component test under the committed-timeout precondition; healthy public Activity execution did not exercise that fault.
- The current Activity trace harness uses independent database, administrative, and public API readbacks and explicitly marks its trace evidence incomplete; this masks the recorder-only consequence.


## Run coverage

- Stage coverage details are unavailable because this run resumed after an interruption.

## Run details

| Item | Value |
|---|---|
| Target | temporal-activity |
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
| Phase 1 | 38m 18s | 57.1M total (55.0M cached) | $81.88 |
| Phase 2 | 1h 8m | 12.4M total (11.8M cached) | $21.95 |
| Phase 2.5 | 35m 58s | 9.9M total (9.6M cached) | $15.11 |
| Phase 3 | 4h 12m | 77.9M total (75.4M cached) | $114.19 |
| Phase 4a | 48m 33s | 42.0M total (39.6M cached) | $40.14 |
| Phase 4b | 6m 23s | 434.1K total (352.4K cached) | $1.58 |
| **Total** | 7h 30m | 199.7M total (191.6M cached) | $274.85 |

- Configured maximum parallelism: 4
- Configured TLC limits: 112G memory; 32 workers
