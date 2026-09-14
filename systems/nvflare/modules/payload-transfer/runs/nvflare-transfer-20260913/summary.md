# Specula Summary

## Result

- Run status: **Complete**

The final report records 4 REPRODUCED bugs, 0 MASKED findings, 0 ENV_LIMITED findings, and 1 other disposition. Transfers can repeat settlement effects or report success despite incomplete or failed delivery; one reproduced bug affects only configuration diagnostics.

## Findings

- **MC-1 — Post-enqueue submission failure duplicates settlement effects and permits callbacks after receipt** — Status: `REPRODUCED`. Impact: Application callbacks and source release attempts can run twice, with further callbacks occurring after receipt delivery. Evidence: Reproduced with a controlled executor failure after work was queued and a later worker resumption.
- **MC-2 — A pipelined EOF can publish COMPLETED progress after cancellation finalized FAILED** — Status: `REPRODUCED`. Impact: Source progress can remain completed for a cancelled transfer even though receiver status and the final transfer outcome are failed. Evidence: Exercised through public download and cancel handling with controlled callback and event timing.
- **CR-2 — Caller receiver declarations can diverge from complete-payload outcome semantics** — Status: `REPRODUCED`. Impact: A multi-target send can report completion and release its payload after the first receiver, causing a later receiver's download to fail. Evidence: Reproduced through public send and download APIs with in-process network transport.
- **CR-4 — Receiver budget diagnostics and activity clocks remain review-only** — Status: `REPRODUCED`. Impact: Callers receive a warning that the receiver idle budget cannot fire even though it can still fail a stalled receiver. Evidence: Normal transaction creation emitted the warning; controlled timing demonstrated budget enforcement while another receiver stayed active.
- Other dispositions: 1.

## Validation limits

- MC-1 required a controlled executor failure after enqueueing; normal flow and timing-only delayed callbacks each settled once. The receipt guard masks duplicate stored outcomes but does not prevent duplicate callback or release effects.
- MC-2 required controlled callback and event timing in this run. Its final transfer outcome remained failed; the incorrect success indication was on the source progress surface.
- CR-2 used in-process network transport. The missing receiver's delivery failure was permanent for that transfer attempt, with no later resend, synchronization, or guard resolving it in the report.
- CR-4 used controlled timing to demonstrate the warning was false. Budget enforcement and the final transfer outcome were correct; transfer-semantic harm was not reproduced.


## Run details

| Item | Value |
|---|---|
| Target | nvflare-transfer |
| Original source commit | 53ba7ee567468ea7971dad4faccef13c6cb35dc2 |
| Current attempt source commit | 53ba7ee567468ea7971dad4faccef13c6cb35dc2 |
| Agent / model | codex / Varies by task |
| Reasoning effort | xhigh |

## Detailed reports

- [Confirmation report](confirmed-bugs.md)
- [Severity report](bug-severity.md)

## Resource usage

| Phase | Runtime | Tokens | Estimated cost |
|---|---:|---:|---:|
| Phase 1 | 1h 1m | 35.5M total (34.4M cached) | $49.21 |
| Phase 2 | 52m 37s | 6.4M total (5.9M cached) | $13.85 |
| Phase 2.5 | 35m 39s | 8.3M total (7.8M cached) | $14.76 |
| Phase 3 | 1h 44m | 20.3M total (19.2M cached) | $34.14 |
| Phase 4a | 21m 34s | 18.6M total (17.4M cached) | $18.99 |
| Phase 4b | 4m 48s | 325.3K total (284.3K cached) | $1.03 |
| **Total** | 4h 40m | 89.5M total (85.0M cached) | $131.98 |

- Configured maximum parallelism: 4
- Configured TLC limits: 128G memory; 40 workers
