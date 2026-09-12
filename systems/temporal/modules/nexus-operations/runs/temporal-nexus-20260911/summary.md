# Specula Summary

## Result

- Run status: **Complete**

The final report contains 5 entries: 3 REPRODUCED, 0 MASKED, 0 ENV_LIMITED, and 2 other dispositions. The reproduced issues allow stale Nexus results to become permanent and leave operation deadlines unenforced.

## Findings

- **CR-1 — Remote acceptance and local knowledge can advance independently** — Status: `REPRODUCED`. Impact: A stale callback can permanently set the Nexus completion result consumed by the workflow despite a different persisted operation token. Evidence: A state-machine component test recorded the stale callback result after a start retry.
- **CR-2 — Deferred cancellation can omit an independently required timer** — Status: `REPRODUCED`. Impact: Deferred cancellation can omit the independent start-to-close timer, leaving a workflow running beyond the operation deadline. Evidence: Public workflow APIs and a deliberately delayed Nexus handler reproduced the missed deadline without state injection or a source patch.
- **CR-4 — Deadline selection, queued work and stale references interact** — Status: `REPRODUCED`. Impact: Omitting both the operation's schedule-to-close timeout and the workflow run timeout bypasses the configured operation maximum, leaving it unenforced. Evidence: Normal scheduling-command handling persisted a zero timeout, and task regeneration produced no timeout task.
- Other dispositions: 2.

## Validation limits

- CR-1 was reproduced in a state-machine component test with a lost-response and retry precondition; duplicate remote operations depend on whether the endpoint deduplicates retried starts.
- CR-2 required controlled start-response timing. Explicit administrator task refresh restored the missing timeout, but the report identifies this as a repair path rather than an automatic safeguard.
- CR-4 was validated through scheduling-command handling and task regeneration. A configured workflow run timeout can mask the missing operation timeout.


## Run details

| Item | Value |
|---|---|
| Target | temporal-nexus |
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
| Phase 1 | 44m 2s | 61.6M total (59.6M cached) | $84.96 |
| Phase 2 | 49m 18s | 9.6M total (9.1M cached) | $17.63 |
| Phase 2.5 | 44m 48s | 16.8M total (16.4M cached) | $23.28 |
| Phase 3 | 26m 34s | 8.4M total (8.1M cached) | $13.03 |
| Phase 4a | 24m 44s | 20.4M total (18.9M cached) | $21.00 |
| Phase 4b | 3m 33s | 254.0K total (220.8K cached) | $0.79 |
| **Total** | 3h 12m | 116.9M total (112.3M cached) | $160.70 |

- Configured maximum parallelism: 4
- Configured TLC limits: 112G memory; 32 workers
