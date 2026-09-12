# Severity Classification — temporal-update

## Summary

- Total entries: 4
- Reproduced bugs: 2
- Severity-bearing findings: 2
- Critical: 3
- High: 1
- Medium: 0
- Low: 0
- No-severity dispositions: 0

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | CR-1 | ENV_LIMITED | Critical | The argued cross-host stale-cache sequence can make public `PollWorkflowExecutionUpdate` return Update A's result for Update B, corrupting the caller-visible terminal outcome. The higher tier is preferred for that safety consequence despite uncertainty about its persistence; the one-node-per-service harness could not exercise the multi-host production-routing precondition. |
| 2 | CR-2 | MASKED | High | After cache loss, a stale public workflow-task completion can reject the replacement sticky completion, and an old speculative timer can prematurely time out replacement work. Readmission/retry and normal-queue delivery mask the Update-level consequence by recovering the caller's final outcome; the exposed replacement-task failures are externally observable, recoverable harm. |
| 3 | CR-3 | REPRODUCED | Critical | Public Update calls combined with a transaction-size termination fallback and a failed termination write can deliver a terminal failure while durable state remains running, after which the same Update ID completes successfully. These contradictory terminal outcomes violate caller-visible consistency, and later durable recovery does not correct the already-delivered failure; normal mixed-outcome batches also return an incorrect rejection link for an accepted handler failure. |
| 4 | CR-4 | REPRODUCED | Critical | A same-ID public Update request with a completion callback, followed by a worker completing its task without processing the Update, can leave callers receiving `ADMITTED` without an outcome across repeated retries and redelivery. The Update does not self-heal through the normal unprocessed-update path, and recovery required manual shard/cache clearing, establishing persistent client-visible loss of progress. |
