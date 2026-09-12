# Temporal

## Scope

Specula analyzed and tested [Temporal](https://github.com/temporalio/temporal) durable execution across six bounded slices: Workflow Update, Workflow Reset, Activity execution, Matching task queues, History task queues, and Nexus operations. The runs cover persistence commit and response loss, cache and shard recovery, request identity, timers, callbacks, task admission and acknowledgement, queue checkpoints, cancellation, and Continue-As-New history reconstruction.

All six runs target [`temporalio/temporal@0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`](https://github.com/temporalio/temporal/tree/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025). The final independent review also checked the implicated paths against upstream `main@9ab3a9f770da20df7d94bcc0030f28eec7b0b947`; no relevant intervening fix was found at that review boundary.

## Findings

The six runs produced 14 pipeline entries that split into 16 independent mechanisms. Independent review rejected History Queue CR-4 as a false positive, leaving **15 retained findings**:

- **13 Temporal product findings:** 11 reproduced, one environment-limited, and one masked.
- **1 executor-level guard gap** that still needs end-to-end product evidence.
- **1 test-observer issue** in Temporal's test support code; it is not a production-server defect.

All 15 were classified as new at the reviewed source boundary. Two have open upstream fix PRs. Internal reproduction alone does not mean that Temporal maintainers have confirmed the remaining findings.

| Reference | Area | Evidence | Finding | Observed or bounded impact |
| --- | --- | --- | --- | --- |
| Update CR-1 | Workflow Update | ENV_LIMITED | A stale host-local event-cache entry can be returned as the durable result of a different Update after ownership and event-ID reuse. | A caller could receive another Update's terminal result. The cache mismatch is reproduced at the component boundary, but the complete multi-host route has not been reproduced. |
| Update CR-2A | Workflow Update | MASKED | A rejected stale speculative workflow-task completion can clear the replacement task's sticky state. | The replacement can be rejected and redelivered on the normal queue, adding retries and delay. The public Update outcome recovered in the executed test. |
| Update CR-2B | Workflow Update | NEEDS MORE INFO | An old speculative timer can time out a replacement workflow task after that replacement has converted to a normal task. | The executor emits a premature timeout before the replacement deadline. An end-to-end caller consequence or complete recovery proof is still missing. |
| Update CR-3A | Workflow Update | REPRODUCED | An accepted Update whose handler returns a failure is labeled as rejected in the public response link. | Durable history says accepted and completed while the API metadata says rejected, giving callers contradictory lifecycle information. |
| Update CR-3B | Workflow Update | REPRODUCED | A failed workflow-close fallback can publish a terminal Update failure even though the close write did not commit, after which the same Update ID can succeed. | The same logical Update can produce contradictory terminal outcomes across recovery. |
| Update CR-4 | Workflow Update | REPRODUCED | A duplicate request with a completion callback can prevent an unprocessed sent Update from reaching a terminal rejection. | The Update remains admitted across retries and redeliveries until shard or cache state is manually cleared. |
| Reset MC-1 | Workflow Reset | REPRODUCED, configuration-sensitive | An unsafe history-scanner minimum age can delete a new history branch before execution metadata is published. | The API can acknowledge a run whose history is permanently missing or incomplete. The default 60-day age prevents the demonstrated schedule. |
| [Reset MC-2](https://github.com/temporalio/temporal/pull/12042) | Workflow Reset | REPRODUCED, REPORTED | Retrying an identical Reset request can create a second run instead of returning the first Reset result. | The retry terminates the first Reset-created run and replaces its durable identity. See temporalio/temporal#12042. |
| Reset CR-4 | Workflow Reset | REPRODUCED | Reset reapplication merges Continue-As-New histories into one run and rejects Update IDs that were validly reused in different source runs. | The public Reset request fails with an internal error and has no automatic recovery path. |
| Activity CR-5 | Activity test observation | REPRODUCED observer issue, MASKED | The test history-task recorder omits tasks when persistence commits a mutation but returns a timeout. | A recorder-only trace can be incomplete. This is not a Temporal production-server defect, and the Specula harness masks it with independent readbacks and incomplete-trace markers. |
| Matching CR-5 | Matching fair queue | REPRODUCED, conditional | Concurrent fair-reader replacement and eviction can advance the durable acknowledgement past a still-eligible task. | The task remains in persistence but restart reads permanently skip it. The path requires the optional fairness implementation. |
| History Queue CR-2 | History task queue | REPRODUCED | Checkpoint slice shrinking can detach the live reader cursor while a later slice still contains work. | Repeated notifications and polls do not submit the retained task; reader reconstruction restores it. |
| Nexus CR-1 | Nexus operations | REPRODUCED | After a start retry persists a new operation token, a callback carrying the older token is still accepted when the request ID matches. | A stale remote operation can permanently supply the workflow's terminal result. The trigger depends on the endpoint accepting distinct operations for one retried request ID. |
| [Nexus CR-2](https://github.com/temporalio/temporal/pull/12043) | Nexus operations | REPRODUCED, REPORTED | Cancellation requested before a delayed start response can omit the independent start-to-close timeout task. | The operation can remain pending past its deadline without timing out. See temporalio/temporal#12043. |
| Nexus CR-4 | Nexus operations | REPRODUCED, configuration-sensitive | Omitting the operation timeout bypasses a configured maximum instead of applying that maximum. | No timeout task is generated, so the caller can wait indefinitely when no workflow-run timeout exists. The maximum is disabled by default. |

The detailed [cross-run findings ledger](review/findings-ledger.md) records the count correction, evidence categories, and the rejected History Queue candidate.

## Runs

- [workflow-update](modules/workflow-update/runs/temporal-update-20260909-restart-1600/README.md)
- [workflow-reset](modules/workflow-reset/runs/temporal-reset-20260909-restart-1600/README.md)
- [activity-execution](modules/activity-execution/runs/temporal-activity-20260910/README.md)
- [matching-queue](modules/matching-queue/runs/temporal-matching-20260910/README.md)
- [history-queue](modules/history-queue/runs/temporal-history-queue-20260911/README.md)
- [nexus-operations](modules/nexus-operations/runs/temporal-nexus-20260911/README.md)

The run records preserve final reports, models, configurations, harness and reproduction sources, traces, and selected confirmation evidence. They exclude roughly 37 GB of generated build caches, temporary databases, nested source trees, and model-checker scratch state.

## Evidence boundary

Reset MC-1 and MC-2 have model-counterexample provenance; the other retained mechanisms came from code review followed by implementation validation. Several broad model-checking searches did not converge, and the Nexus model did not complete full trace replay and model checking. The archive therefore supports the listed bounded findings, not a proof of Temporal's overall correctness or a claim that every finding was discovered by model checking.
