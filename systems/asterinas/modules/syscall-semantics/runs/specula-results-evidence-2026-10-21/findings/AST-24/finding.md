# AST-24 — ext2 direct-write fault/rollback can leave an earlier BIO live

| Field | Value |
|---|---|
| Source disposition | MASKED |
| Evidence class | `not_in_reproduced_index` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-08-23 to 2026-08-24 |
| Date basis | campaign window |

MASKED: submitted-I/O mechanism reported, but no late publication or clobbered later write was observed on the tested backends.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-24-ext2-direct-write-live-bio/finding.md) preserves the earlier source record.

## Evidence boundary

No positive native confirmation is recorded for this item. The source disposition and tracking status above are independent fields.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
