# AST-09 — Pipe readv/writev return EINTR despite SA_RESTART

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | Known |
| Discovery or earliest local record | 2026-08-26 to 2026-08-28 |
| Date basis | campaign window |

Reported pipe reproduction fails two restart checks while Linux passes. Earlier PR #3576 covers the restart family; regular-file positional I/O remains latent.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-09-pipe-readv-eintr-restart/finding.md) preserves the earlier source record.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| GLM / CR-2 | GLM-5.3 / pi | [verdict](../../evidence/native-runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/CR-2/verdict.json) · [report](../../evidence/native-runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
