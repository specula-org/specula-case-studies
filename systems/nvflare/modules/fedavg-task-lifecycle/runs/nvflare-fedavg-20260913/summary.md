# Specula Summary

## Result

- Run status: **Complete**

The final report records 2 reproduced bugs, 2 false positives, and 1 dropped known-fixed candidate. Rejected contributions can affect saved global-model outputs, while late duplicate results can remain retained in controller state.

## Findings

- **MC-1 — Rejected contributions retain aggregation values or statistics after consumer failure** — Status: `REPRODUCED`. Impact: A rejected contribution can still alter the global model that FedAvg applies and saves. Evidence: The normal FedAvg round path was exercised with a real lazy tensor reference whose file-backed materialization was made to fail.
- **CR-2 — Task identity, retry receipt, and finite completed history** — Status: `REPRODUCED`. Impact: A late duplicate whose completed-task receipt has been evicted leaves its raw training result reachable in the controller context after finalization. Evidence: Public task submission APIs reproduced retention after garbage collection without invoking the aggregation callback or contribution-accept events.
- Other dispositions: CR-1 `DROPPED`; CR-4 and CR-5 `FALSE POSITIVE`.

## Validation limits

- MC-1 required an injected lazy tensor reference with a file-backed materialization failure; the report did not demonstrate the failure without that controlled precondition.
- CR-2 depends on eviction from the 10,000-entry completed-task history; the result bypasses aggregation and remains retained until controller-context replacement.


## Run details

| Item | Value |
|---|---|
| Target | nvflare-fedavg |
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
| Phase 1 | 54m 12s | 45.6M total (44.1M cached) | $64.85 |
| Phase 2 | 45m 39s | 6.8M total (6.4M cached) | $14.04 |
| Phase 2.5 | 28m 17s | 6.4M total (6.2M cached) | $10.36 |
| Phase 3 | 1h 12m | 19.4M total (18.9M cached) | $27.16 |
| Phase 4a | 19m 49s | 17.1M total (16.0M cached) | $17.00 |
| Phase 4b | 4m 11s | 307.4K total (263.9K cached) | $0.97 |
| **Total** | 3h 44m | 95.6M total (91.8M cached) | $134.38 |

- Configured maximum parallelism: 4
- Configured TLC limits: 128G memory; 40 workers
