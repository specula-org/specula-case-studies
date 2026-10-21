# AST-02 — ramfs size publication before an empty or zero-progress write

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Fixed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-08-23 to 2026-08-24 |
| Date basis | campaign window |

Agent-reproduced empty-write and zero-progress fault cases. Merged PR #3875 fixes only empty writes; nonempty zero-progress faults remain outside that fix.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-02-ramfs-size-publication/finding.md) preserves the earlier source record.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| 01a / MC-4 | Claude Opus 5 / Claude Code | [verdict](../../evidence/native-runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-4/verdict.json) · [report](../../evidence/native-runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmed-bugs.md) |
| GLM / MC-3 | GLM-5.3 / pi | [verdict](../../evidence/native-runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-3/verdict.json) · [report](../../evidence/native-runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmed-bugs.md) |
| 01b / MC-6 | Kimi-K3 / pi | [verdict](../../evidence/native-runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-6/verdict.json) · [report](../../evidence/native-runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md) |
| 01b / MC-8 | Kimi-K3 / pi | [verdict](../../evidence/native-runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-8/verdict.json) · [report](../../evidence/native-runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `partial_merged_fix` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

[Upstream repair reference](https://github.com/asterinas/asterinas/pull/3875).

Empty writes only; nonempty zero-progress faults remain outside this repair.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
