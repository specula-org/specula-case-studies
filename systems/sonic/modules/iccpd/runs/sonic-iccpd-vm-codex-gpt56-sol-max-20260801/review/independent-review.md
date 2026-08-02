# Independent review

The original pipeline produced four candidate dispositions. This review controls the case-study and tracker ledger.

## Accepted

| ID | Ledger | Finding | Evidence |
| --- | --- | --- | --- |
| MC-1 | New | A crash between peer socket teardown and disconnect cleanup permanently skips failover cleanup. | Reproduced; State DB and the CLI remain stale after restart. |
| CR-4 | New | Socket activity can block or mislead the single scheduler and suppress transport recovery. | Reproduced across partial ICCP frames, unsupported APP traffic, and mclagsyncd EOF. |

## Not counted separately

| ID | Disposition | Reason |
| --- | --- | --- |
| MC-2 | Existing mechanism | Its observed consequence is caused by the already recorded `EXCHANGE` to `ERROR` full-sync bug. |
| MC-3 | Folded into CR-4 | The stale positive mclagsyncd descriptor is one of CR-4's reproduced scheduler/transport recovery paths; the run did not independently establish a distinct dangerous-forwarding consequence. |

The original [confirmed-bugs.md](../confirmed-bugs.md) and [bug-severity.md](../bug-severity.md) remain unchanged as run evidence. Their candidate classification is not the deduplicated tracker count.
