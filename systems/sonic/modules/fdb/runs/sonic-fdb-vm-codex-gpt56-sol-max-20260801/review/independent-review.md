# Independent review

The original pipeline produced seven candidate dispositions. This review controls the case-study ledger and the tracker decision for this run.

## New bugs included in the tracker batch

| ID | Finding | Evidence |
| --- | --- | --- |
| MC-2 | A delayed AGE event deletes a newer FDB incarnation. | Reproduced through the public FdbOrch notification handler; no incarnation guard or automatic repair exists. |
| MC-5 | A delayed LEARN event reclassifies a newer MCLAG remote entry as local. | Reproduced at Level 1 through serialized notification and table-consumer interfaces with timing assistance only. |
| MC-6 | Deferred SET replay applies an obsolete destination. | Reproduced through the normal ProducerStateTable path. |
| MC-7 | Startup discards the one-shot kernel NHG dump before NVO readiness. | Source ordering and model evidence establish the lost-input path; accepted for the tracker after review. |

## Retained but not written to the tracker

| ID | Disposition | Finding | Reason |
| --- | --- | --- | --- |
| MC-1 | Known, unfixed | A delayed FLUSHED callback deletes a post-flush relearn. | Matches [sonic-swss PR #2136](https://github.com/sonic-net/sonic-swss/pull/2136); this batch writes only New bugs. |
| MC-3 | Known, unfixed | VTEP replacement credits the new member to the old endpoint. | Matches [sonic-swss PR #4262 review discussion](https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4347971135); this batch writes only New bugs. |
| MC-4 | Known, masked | Bridge-port teardown continues after its FDB flush fails. | Matches [sonic-buildimage issue #27835](https://github.com/sonic-net/sonic-buildimage/issues/27835), while the current SAI reference guard blocks the claimed destructive removal. |

The original [confirmed-bugs.md](../confirmed-bugs.md) and [bug-severity.md](../bug-severity.md) remain unchanged as run evidence. Intermediate classifications inside the pipeline report do not override this final ledger.
