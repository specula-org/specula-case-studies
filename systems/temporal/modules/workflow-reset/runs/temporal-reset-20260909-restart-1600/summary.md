# Specula Summary

## Result

- Run status: **Complete**

The report records 3 REPRODUCED bugs, 0 MASKED findings, 0 ENV_LIMITED findings, and 3 other dispositions. The reproduced bugs expose permanent history loss under a short scanner age, replacement of the first reset run on an identical retry, and Reset failures when Update IDs collide across Continue-As-New runs.

## Findings

- **MC-1 — A short scanner age can remove history before execution publication** — Status: `REPRODUCED`. Impact: A scanner age shorter than the publication window can permanently remove history from a Start or Reset run that the API subsequently acknowledges. Evidence: Public Start and Reset handlers reproduced missing or incomplete history with controlled timing between history creation and metadata publication.
- **MC-2 — Identical Reset requests can create another run instead of returning the first result** — Status: `REPRODUCED`. Impact: An identical Reset retry creates a new current run and permanently terminates the first reset run instead of returning the original result. Evidence: Public-client tests reproduced immediate replay and retry after deliberately discarding a successful response.
- **CR-4 — Reset reapplication can combine Continue-As-New histories with colliding Update IDs** — Status: `REPRODUCED`. Impact: Reset fails with an Internal error when it combines Continue-As-New histories that validly reuse the same Update ID in different runs. Evidence: A public-API test reproduced the failure without state injection or source patches.
- Other dispositions: 3.

## Validation limits

- MC-1 used a zero scanner minimum age and controlled publication timing; the default 60-day controls preserved history. The report records nonzero underlying Go-test exits for both reproduction and control cases.
- MC-2 used an existing compatible Temporal test binary because a direct compile attempt hit local disk quota limits.


## Run details

| Item | Value |
|---|---|
| Target | temporal-reset |
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
| Phase 1 | 1h 5m | 49.7M total (48.4M cached) | $67.60 |
| Phase 2 | 49m 26s | 10.3M total (9.8M cached) | $17.78 |
| Phase 2.5 | 48m 10s | 18.0M total (17.6M cached) | $24.70 |
| Phase 3 | 1h 50m | 53.1M total (52.5M cached) | $64.09 |
| Phase 4a | 42m 41s | 29.7M total (27.8M cached) | $29.41 |
| Phase 4b | 4m 7s | 303.4K total (267.0K cached) | $0.90 |
| **Total** | 5h 20m | 161.1M total (156.3M cached) | $204.48 |

- Configured maximum parallelism: 4
- Configured TLC limits: 224G memory; 64 workers
