# Temporal

## Scope

Specula analyzed and tested Temporal's durable execution across Workflow Update, Workflow Reset, Activity execution, Matching queues, History task queues, and Nexus operations, including persistence, retries, request identity, timers, callbacks, cancellation, and Continue-As-New history reconstruction.

## Bugs

Specula recorded 15 new findings: 13 product findings, 1 executor guard gap, and 1 test-observer issue:

- **Environment-limited:** A stale host-local event-cache entry can supply another Update's terminal result after ownership and event-ID reuse; the complete multi-host trigger remains unconfirmed.
- **Masked:** A rejected stale speculative workflow-task completion can clear a replacement task's sticky state, causing rejection and redelivery before the Update recovers.
- **Needs more info:** An old speculative timer can time out a replacement workflow task after it becomes normal; the executor guard gap lacks end-to-end product evidence.
- An accepted Update whose handler fails is labeled as rejected in the public response link, contradicting its durable lifecycle.
- A failed workflow-close fallback can publish terminal Update failure before the close write commits, allowing the same Update ID to succeed later.
- A duplicate request with a completion callback can prevent an unprocessed sent Update from reaching terminal rejection.
- An unsafe history-scanner minimum age can delete a new history branch before execution metadata is published, leaving an acknowledged run without its history; the default 60-day age prevents this schedule.
- **Reported:** Retrying an identical Reset request can create a second run and terminate the first Reset-created run; see [PR #12042](https://github.com/temporalio/temporal/pull/12042).
- Reset reapplication merges Continue-As-New histories into one run and rejects Update IDs legitimately reused in different source runs.
- **Test observer, masked:** The test history-task recorder omits tasks when persistence commits but returns a timeout; independent readbacks compensate for the missing observations.
- With optional fairness enabled, concurrent Matching reader replacement and eviction can advance the durable acknowledgement past a task that restart reads then skip.
- History queue checkpoint shrinking can detach the live reader cursor while a later slice still contains work, preventing submission until reader reconstruction.
- A Nexus callback carrying an older operation token is accepted after a retry persists a new token, allowing a stale remote operation to supply the workflow result when endpoint retries create distinct operations.
- **Reported:** Cancellation before a delayed Nexus start response can omit the independent start-to-close timeout task, leaving the operation pending past its deadline; see [PR #12043](https://github.com/temporalio/temporal/pull/12043).
- Omitting a Nexus operation timeout bypasses a configured maximum and creates no timeout task, allowing an indefinite wait when no workflow-run timeout exists.
