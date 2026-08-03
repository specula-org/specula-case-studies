# Independent review

## Tracker decision

The tracker batch for this archive records new findings only. This run contributes one row:

| Finding | Pipeline disposition | Novelty | Tracker decision |
|---|---|---|---|
| MC-5 | MASKED | NEW | Add. `RECONCILED` is visible before queued route operations are flushed; the immediate caller flush prevents a persistent wrong route state. |

## Excluded from this tracker batch

| Finding | Pipeline disposition | Novelty | Reason |
|---|---|---|---|
| MC-1 | REPRODUCED | KNOWN, unfixed | Prior upstream PR #1460; excluded by the new-only policy. |
| MC-2 | ENV_LIMITED | KNOWN, unfixed | Prior upstream PR #4297; excluded by the new-only policy. |
| MC-3 | REPRODUCED | NEW | Exact tracker duplicate of New #221. |
| MC-4 | REPRODUCED | KNOWN, unfixed | Prior upstream PR #1784; excluded by the new-only policy. |
| MC-6 | MASKED | KNOWN, fixed | Historical consequence fixed by upstream PR #666; excluded by the new-only policy. |
| CR-5 | DROPPED | KNOWN, unfixed | Upstream issue #28650 and PR #2007 already identify the mechanism; excluded by the new-only policy. |

## Wording boundary

MC-5 is an ordering defect, not evidence of persistent route loss: the following unconditional pipeline flush successfully delivers all queued operations. MC-2 did not reach a full SONiC/DVS restoration run. The archived pipeline report remains the source for detailed evidence and limitations.
