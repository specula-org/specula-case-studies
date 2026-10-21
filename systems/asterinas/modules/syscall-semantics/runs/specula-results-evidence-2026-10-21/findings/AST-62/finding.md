# AST-62 — timerfd_create accepts generic CPU clocks outside its Linux domain

| Field | Value |
|---|---|
| Source disposition | SOURCE LEAD |
| Evidence class | `not_in_reproduced_index` |
| Tracker status (2026-10-21) | Fixed |
| New/Known tracking label | Known |
| Discovery or earliest local record | 2026-09-14 |
| Date basis | intake date; original discovery date unknown |

Merged PR #3824 rejects unsupported timerfd clocks. Original TLPI target tests were not run; Fixed is based on the verified upstream patch.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-62-timerfd-create-accepts-cpu-clocks/finding.md) preserves the earlier source record.

## Evidence boundary

No positive native confirmation is recorded for this item. The source disposition and tracking status above are independent fields.

## Upstream repair snapshot

Assessment: `complete_merged_fix` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

[Upstream repair reference](https://github.com/asterinas/asterinas/pull/3824).

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
