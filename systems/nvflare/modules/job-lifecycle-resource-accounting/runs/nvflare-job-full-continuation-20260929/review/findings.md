# Cross-run finding reconciliation

Original findings retain their run-local IDs. Source REPRODUCED means the original confirmation result; it does not imply upstream confirmation. Four explicit overlap groups leave 34 provisional full-run mechanism units, including three direct matches to the earlier archive. Further same-family merging and admission review are unfinished.

| Full ID | Finding | Archive treatment | Evidence limit |
|---|---|---|---|
| MC-1 | Queued cancellation can be overwritten by concurrent lifecycle writes | existing finding; evidence supplement: 20260914 Job MC-3 | Controlled component timing; Lite adds public POC evidence. Reuses the earlier queued-abort finding. |
| MC-2 | Deleting a listed job can terminate the only scheduling thread | candidate for review | Lite adds public admin API and restart-recovery evidence. Related to the earlier status-store failure family; independent root-cause count remains unsettled. |
| MC-3 | A late RUNNING write can replace an already-published terminal outcome | existing finding; evidence supplement: 20260914 Job MC-4 | Deliberate timing assistance; upstream confirms validity but has not shown natural occurrence. |
| MC-4 | An early authoritative client failure can make START collection raise KeyError | candidate for review | Failure classification and diagnostics change; no extra resource leak or service loss demonstrated. |
| MC-5 | A metadata refresh can restore SUBMITTED after a successful abort | candidate for review | A different metadata writer in the queued-abort family; independent counting remains unsettled. |
| MC-6 | Competing cleanup paths can terminate the completion thread with KeyError | candidate for review | Controlled competing cleanup schedule; no full deployment trigger retained. |
| MC-7 | Concurrent process removal can terminate dead-client cleanup | merge into CR-6 | Covered by CR-6; retain this specific dead-client cleanup branch. |
| MC-8 | Client resources can be freed while same-group descendants remain alive | candidate for review | Real child-process evidence; descendant lifecycle and physical GPU contention are not established. |
| MC-9 | Running-job abort can succeed while the final status is COMPLETED | candidate for review | Controlled abort/completion window. Same final mechanism as CR-32, despite conflicting original novelty labels. |
| MC-10 | An authoritative client failure recorded after the completion outcome read can be published as success | candidate for review | Seeded component state and controlled failure/finalization ordering; production message timing unproven. |
| MC-11 | A client failure accepted in the startup tracking gap can be lost before success is published | candidate for review | Startup tracking-gap component evidence; a complete fast-start/client-failure process schedule is still needed. |
| MC-12 | Stale delete authorization can strand a running job and its admission slot | candidate for review | Controlled authorize/start/delete ordering; no complete admin interaction replay retained. |
| MC-13 | Accepted noncanonical min_clients can repeatedly starve a later eligible job | merge into CR-4 | Included in CR-4; validator, store and scheduler are real components, not a network submission test. |
| CR-4 | Malformed job metadata variants can block later jobs beyond the modeled numeric-string case | candidate for review | Includes MC-13 and additional malformed metadata variants. Component validation; portable runner provided. |
| CR-6 | Live dictionary iteration disrupts lifecycle services | candidate for review | Includes MC-7 and related iteration sites; do not count the aggregate and its branch twice. |
| CR-7 | Fractional GPU accounting fails to restore eligible capacity | candidate for review | Fractional accounting loses exact boundary capacity; not permanent loss of the whole GPU. Portable component runner provided. |
| CR-9 | Parent death leaves a child in notification retry | candidate for review | Real local processes and CellNet, with a minimal parent/child environment; full worker bootstrap not exercised. |
| CR-10 | Disable leaves pending outcomes and slots until the grace expires | candidate for review | Pending outcome retention has a grace/timeout bound; contract and impact require review. |
| CR-11 | Overlapping resource consumption changes another job's launch environment | existing finding; evidence supplement: 20260914 Job CR-1 | Matches the earlier shared environment finding; physical GPU probing was stubbed. |
| CR-12 | Later empty-resource jobs inherit a stale device binding | candidate for review | Sequential empty-resource variant of shared environment state; isolation contract and counting remain unsettled. |
| CR-14 | Best-effort SJ status arrival loses an execution error | candidate for review | Seeded component state; needs a real zero-exit process plus sufficiently late status message. |
| CR-15 | Ordinary local restart leaves persisted lifecycle state inconsistent | candidate for review | Seeded persisted state; complete shutdown/restart reproduction is not retained. |
| CR-16 | Cleanup pop races the waiter's return-code observation | candidate for review | Controlled cleanup/return-code observation; depends on startup marker state and interacts with CR-17. |
| CR-17 | Unsafe client failure during startup does not mark the job aborted | candidate for review | Unsafe-component startup stop differs from ordinary live abort; actual typed failure and registration timing need review. |
| CR-19 | Empty participants alias the live registered-client dictionary | candidate for review | Wrong participant membership/notification shown; no final job hang or failure demonstrated. |
| CR-20 | Abort before client registration is dropped before a late start | candidate for review | A normal launch hook can widen the window; later heartbeat handling may mitigate the late child. |
| CR-21 | Client shutdown and restart lose ownership before child cleanup | candidate for review | Includes state injection; complete client restart and resource-ownership closure still needed. |
| CR-22 | Re-registration replaces tokens still used by running-job participants | candidate for review | Notification omission shown; concrete job hang not demonstrated. |
| CR-23 | Typed process failures change meaning across normalization and status mapping | candidate for review | Real child with custom launch/notification harness; failure classification changes without greater demonstrated harm. |
| CR-24 | Fast SJ engine completion is overwritten by STARTED | candidate for review | Same final mechanism as CR-31. Deterministic Thread.start shim; portable component runner does not establish natural timing. |
| CR-25 | Delayed SJ heartbeat marks normal completion aborted | candidate for review | Controlled heartbeat/completion order; terminal outcome classification, not training-data corruption. |
| CR-26 | Post-spawn setup or cleanup exceptions break resource ownership | hold | Hold: custom free_resources unconditionally raises; default-path exception producer unproven. Does not re-confirm the earlier post-spawn handoff finding. |
| CR-27 | A pending restart or shutdown marker is removed by worker bootstrap | candidate for review | Marker/PID state injection; complete worker/lifecycle-wrapper race remains unproven. |
| CR-28 | Partial deployment leaves workspace state relevant to later operations | candidate for review | Partial-deployment workspace retention is distinct from Lite TTL reservations; download contract needs review. |
| CR-29 | CAN_NOT_SCHEDULE overwrites an acknowledged abort | candidate for review | Same broad queued-abort family, but job stays stopped and only the terminal reason changes. |
| CR-30 | An ordinary cleanup exception escapes completion's narrow catch | excluded | Excluded by the source report: no admissible default-path exception producer was found. |
| CR-31 | Global machine status differs from concurrent job state | merge into CR-24 | Merge with CR-24; its original global-status concern resolved to the same STARTED/STOPPED mechanism. |
| CR-32 | Lock/RPC ordering or late notifications affect cleanup progress | merge into MC-9 | Merge with MC-9; conflicting original known-fixed/unfixed labels are not independent findings. |
| CR-33 | Retained SJ status reference can replace a newer failure record | candidate for review | Outcome remains failure; only its classification changes. Severity needs separate review. |

## Lite mapping

| Lite ID | Full / earlier counterpart | Treatment |
|---|---|---|
| MC-1 | Full MC-1 / earlier Job MC-3 | Public POC evidence supplement; do not recount |
| MC-2 | Full MC-2 | Same delete/scheduling mechanism; review overlap with earlier Job CR-5 |
| MC-4a | Full MC-3 / earlier Job MC-4 | Timing-assisted deployment evidence supplement |
| MC-4b | Full MC-9 / CR-32 | Same abort/completion mechanism |
| CR-4 | Full MC-4 | Same START-collection KeyError / failure-classification mechanism |
| T-1 | No direct final full entry | Reservation retention until TTL; contract and bounded impact need review |
| CR-3 | No direct final full entry | expiration_period validation mismatch; low-impact configuration behavior |

The earlier [job lifecycle archive](../../nvflare-job-lifecycle-20260914/README.md) remains the reference for prior findings. The original full [confirmation report](../confirmed-bugs.md) and [severity report](../bug-severity.md) are retained without rewriting their conclusions.
