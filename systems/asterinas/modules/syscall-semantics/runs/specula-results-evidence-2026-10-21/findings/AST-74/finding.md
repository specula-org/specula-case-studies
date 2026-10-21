# AST-74 — MAP_SHARED_VALIDATE skips the ordinary shared-map FD write-access check

| Field | Value |
|---|---|
| Source disposition | SOURCE LEAD |
| Evidence class | `not_in_reproduced_index` |
| Tracker status (2026-10-21) | Blank |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-10-03 |
| Date basis | dated local record |

The MAP_SHARED_VALIDATE admission path may bypass the ordinary shared-map check that requires a writable file descriptor. Four sequential admission cases were prepared but not executed. Writable-byte effects and security consequences remain unverified.

Source lead; four admission tests were prepared but not run. Byte modification and security impact are not established.

## Evidence boundary

No positive native confirmation is recorded for this item. The source disposition and tracking status above are independent fields.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
