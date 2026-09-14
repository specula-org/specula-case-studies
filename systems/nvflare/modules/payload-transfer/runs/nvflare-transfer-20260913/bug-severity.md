# Severity Classification — nvflare-transfer

## Summary

- Total entries: 5
- Reproduced bugs: 4
- Severity-bearing findings: 0
- Critical: 1
- High: 2
- Medium: 0
- Low: 1
- No-severity dispositions: 1

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | High | When callback-pool submission raises after enqueueing and a worker later resumes, a receiver-confirmed transfer runs application callbacks and source release attempts twice, including callbacks after receipt delivery. This is an externally visible settlement failure for the affected transfer; the receipt guard suppresses only duplicate stored outcomes and does not undo the duplicate side effects. |
| 2 | MC-2 | REPRODUCED | High | On a pipelined receiver-confirmed transfer, consumer failure and cancellation can race an admitted EOF request, causing the source progress callback to publish terminal COMPLETED after the receiver has finalized FAILED. The progress latch prevents a later correction, exposing false success to progress consumers, while the final TransferOutcome correctly remains failed. |
| 3 | CR-2 | REPRODUCED | Critical | Direct multi-target stream Cell.fire_and_forget can declare COMPLETED and release the source after one receiver succeeds, leaving another intended receiver permanently unable to materialize that transfer's payload. Although scoped to one transfer attempt, the false success and retired ref have no automatic resend or recovery in the report, so the persistent delivery loss warrants the higher tier. |
| 4 | CR-4 | REPRODUCED | Low | ObjectDownloader construction or direct DownloadService.new_transaction calls can incorrectly warn that a receiver idle budget is disabled when another receiver's activity allows it to fire. The reproduced consequence is a misleading configuration diagnostic in logs; budget enforcement and the final transfer outcome remain correct, with no demonstrated transfer-semantic harm. |
| 5 | CR-5 | FALSE POSITIVE | — | The Phase 4 FALSE POSITIVE disposition is not severity-bearing; the report records no live wrong outcome for a high-level caller. |
