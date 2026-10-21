# AST-10 — ramfs snapshots read length before serializing with resize

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Fixed |
| New/Known tracking label | Known |
| Discovery or earliest local record | 2026-09-03 |
| Date basis | dated local record |

Agent-reproduced resize race with userspace timing assistance. Earlier PR #3778 review identified the lock gap; the PR remains open as of 2026-10-21.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-10-ramfs-read-length-snapshot-resize/finding.md) preserves the earlier source record.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| 01b / MC-1 | Kimi-K3 / pi | [verdict](../../evidence/native-runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-1/verdict.json) · [report](../../evidence/native-runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `open_fix_pr` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

[Upstream repair reference](https://github.com/asterinas/asterinas/pull/3778).

PR is open. The existing tracker Fixed label was retained under its non-regression policy.

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
