# AST-75 — Seal-rejected shared MAP_FIXED removes the old mapping before returning EPERM

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-10-03 |
| Date basis | source contract date; novelty disputed |

A shared MAP_FIXED replacement can remove the old mapping before checking whether a memfd seal permits the replacement. When admission then returns EPERM, the old mapping has already disappeared. Confirmation covers the failed replacement behavior; its discovery credit remains disputed because related source-contract knowledge preceded the run.

GLM-5.3 reproduced removal of an existing mapping before a seal-rejected MAP_FIXED returns EPERM. Discovery credit remains disputed.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| Memfd / MC-2 | GLM-5.3 / pi | [verdict](../../evidence/native-runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-2/verdict.json) · [report](../../evidence/native-runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
