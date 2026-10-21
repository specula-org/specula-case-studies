# AST-47 — openat FD insertion omits the stored RLIMIT_NOFILE limit

| Field | Value |
|---|---|
| Source disposition | SOURCE LEAD |
| Evidence class | `not_in_reproduced_index` |
| Tracker status (2026-10-21) | Blank |
| New/Known tracking label | Known |
| Discovery or earliest local record | 2026-09-14 |
| Date basis | intake date; original discovery date unknown |

TLPI source lead; Asterinas tests not run. #2841 tracks NOFILE enforcement; PR #4035 concerns F_DUPFD and does not establish an openat fix.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-47-openat-ignores-rlimit-nofile/finding.md) preserves the earlier source record.

## Evidence boundary

No positive native confirmation is recorded for this item. The source disposition and tracking status above are independent fields.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
