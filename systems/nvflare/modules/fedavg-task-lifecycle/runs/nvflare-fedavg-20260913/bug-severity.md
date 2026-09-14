# Severity Classification — nvflare-fedavg

## Summary

- Total entries: 5
- Reproduced bugs: 2
- Severity-bearing findings: 2
- Critical: 1
- High: 0
- Medium: 1
- Low: 0
- No-severity dispositions: 3

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | Critical | A file-backed lazy tensor materialization failure during a client training-result callback leaves rejected parameters in the aggregate, which FedAvg applies and saves despite zero accepted contributions. The resulting corruption is permanent for the round output, with no downstream guard or automatic recovery recorded. |
| 2 | CR-1 | DROPPED | — | Phase 4a dropped this duplicate of a known fixed broadcast ownership defect; this disposition carries no severity. |
| 3 | CR-2 | REPRODUCED | Medium | After ordinary task submissions evict a completed receipt, a late duplicate remains in the controller context even after finalization and garbage collection, creating memory retention and a risk of stale data reaching later controller events. Aggregation is bypassed and no external wrong outcome is demonstrated; the established defect is internal result retention until context replacement. |
| 4 | CR-4 | FALSE POSITIVE | — | Ordinary handler exceptions are contained by production event dispatch; this disposition carries no severity. |
| 5 | CR-5 | FALSE POSITIVE | — | Phase 4a classified the distinction between received responses and accepted contributions as intentional behavior; FALSE POSITIVE is a non-severity disposition. |
