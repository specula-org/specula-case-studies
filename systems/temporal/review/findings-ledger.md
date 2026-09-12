# Temporal cross-run findings ledger

## Accounting

The original six-run reports contain 14 pipeline entries. Update CR-2 and Update CR-3 each contain two independent mechanisms, producing 16 mechanisms for cross-run review. The independent History Queue review rejected CR-4 because deletion occurs only after the queue obligation has already been accepted, persisted, or intentionally classified as complete. The retained total is therefore 15.

The retained set consists of 11 reproduced Temporal product mechanisms, one environment-limited product finding, one masked product finding, one executor-level guard gap that needs end-to-end evidence, and one reproduced but masked test-observer issue. The last item is outside the production server.

## Findings

| Reference | Evidence | Severity assessment | Mechanism | Consequence and limit |
| --- | --- | --- | --- | --- |
| Update CR-1 | ENV_LIMITED | High consequence, medium confidence | A stale host-local event-cache entry can be returned as the durable result of a different Update after ownership and event-ID reuse. | A caller could receive another Update's terminal result. The cache mismatch is reproduced at the component boundary, but the complete multi-host route has not been reproduced. |
| Update CR-2A | MASKED | Low | A rejected stale speculative workflow-task completion can clear the replacement task's sticky state. | The replacement can be rejected and redelivered on the normal queue, adding retries and delay. The public Update outcome recovered in the executed test. |
| Update CR-2B | NEEDS MORE INFO | Medium | An old speculative timer can time out a replacement workflow task after that replacement has converted to a normal task. | The executor emits a premature timeout before the replacement deadline. An end-to-end caller consequence or complete recovery proof is still missing. |
| Update CR-3A | REPRODUCED | Low to Medium | An accepted Update whose handler returns a failure is labeled as rejected in the public response link. | Durable history says accepted and completed while the API metadata says rejected, giving callers contradictory lifecycle information. |
| Update CR-3B | REPRODUCED | Critical | A failed workflow-close fallback can publish a terminal Update failure even though the close write did not commit, after which the same Update ID can succeed. | The same logical Update can produce contradictory terminal outcomes across recovery. |
| Update CR-4 | REPRODUCED | High | A duplicate request with a completion callback can prevent an unprocessed sent Update from reaching a terminal rejection. | The Update remains admitted across retries and redeliveries until shard or cache state is manually cleared. |
| Reset MC-1 | REPRODUCED, configuration-sensitive | Critical consequence, low reachability | An unsafe history-scanner minimum age can delete a new history branch before execution metadata is published. | The API can acknowledge a run whose history is permanently missing or incomplete. The default 60-day age prevents the demonstrated schedule. |
| Reset MC-2 | REPRODUCED, REPORTED | High | Retrying an identical Reset request can create a second run instead of returning the first Reset result. | The retry terminates the first Reset-created run and replaces its durable identity. See temporalio/temporal#12042. |
| Reset CR-4 | REPRODUCED | High | Reset reapplication merges Continue-As-New histories into one run and rejects Update IDs that were validly reused in different source runs. | The public Reset request fails with an internal error and has no automatic recovery path. |
| Activity CR-5 | REPRODUCED observer issue, MASKED | Medium observer impact | The test history-task recorder omits tasks when persistence commits a mutation but returns a timeout. | A recorder-only trace can be incomplete. This is not a Temporal production-server defect, and the Specula harness masks it with independent readbacks and incomplete-trace markers. |
| Matching CR-5 | REPRODUCED, conditional | Critical | Concurrent fair-reader replacement and eviction can advance the durable acknowledgement past a still-eligible task. | The task remains in persistence but restart reads permanently skip it. The path requires the optional fairness implementation. |
| History Queue CR-2 | REPRODUCED | High | Checkpoint slice shrinking can detach the live reader cursor while a later slice still contains work. | Repeated notifications and polls do not submit the retained task; reader reconstruction restores it. |
| Nexus CR-1 | REPRODUCED | Critical | After a start retry persists a new operation token, a callback carrying the older token is still accepted when the request ID matches. | A stale remote operation can permanently supply the workflow's terminal result. The trigger depends on the endpoint accepting distinct operations for one retried request ID. |
| Nexus CR-2 | REPRODUCED, REPORTED | Critical | Cancellation requested before a delayed start response can omit the independent start-to-close timeout task. | The operation can remain pending past its deadline without timing out. See temporalio/temporal#12043. |
| Nexus CR-4 | REPRODUCED, configuration-sensitive | High | Omitting the operation timeout bypasses a configured maximum instead of applying that maximum. | No timeout task is generated, so the caller can wait indefinitely when no workflow-run timeout exists. The maximum is disabled by default. |

## Rejected mechanism

History Queue CR-4 showed that an old owner can delete an already acknowledged transfer row before a subsequent shard-state write fails its ownership fence. Independent source and execution review found no supported path for the old owner to acknowledge the task before Matching accepted it, persisted it, or the task was classified as an intentional duplicate or obsolete task. The observed delete is cleanup of completed queue work, so this mechanism is excluded from the 15-finding count.

## Upstream reports

- [temporalio/temporal#12042](https://github.com/temporalio/temporal/pull/12042) proposes a fix and regression coverage for Reset MC-2.
- [temporalio/temporal#12043](https://github.com/temporalio/temporal/pull/12043) proposes a fix and regression coverage for Nexus CR-2.
