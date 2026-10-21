# AST-04 — A copied read prefix is erased by EFAULT reporting

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | Known |
| Discovery or earliest local record | 2026-08-23 to 2026-08-24 |
| Date basis | campaign window |

Agent-reproduced copied prefix with EFAULT and unchanged offset. Issue #711 is related, but its original PoC showed skipped data rather than this exact replay outcome.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-04-read-prefix-efault/finding.md) preserves the earlier source record.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| 01a / MC-1 | Claude Opus 5 / Claude Code | [verdict](../../evidence/native-runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-1/verdict.json) · [report](../../evidence/native-runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmed-bugs.md) |
| GLM / MC-1 | GLM-5.3 / pi | [verdict](../../evidence/native-runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-1/verdict.json) · [report](../../evidence/native-runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
