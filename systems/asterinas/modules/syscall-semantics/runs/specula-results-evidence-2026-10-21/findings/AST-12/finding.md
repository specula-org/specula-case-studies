# AST-12 — Successful exFAT ftruncate retains the old logical size

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-09-08 to 2026-09-09 |
| Date basis | campaign window |

Reported deterministic reproduction: ftruncate succeeds while fstat retains the old size. ext2 served as the guest control; no separate Linux run is recorded.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-12-exfat-ftruncate-retains-old-size/finding.md) preserves the earlier source record.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| 01b / MC-4 | Kimi-K3 / pi | [verdict](../../evidence/native-runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-4/verdict.json) · [report](../../evidence/native-runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
