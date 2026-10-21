# AST-18 — Final close retains dead epoll interest metadata

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-08-12 to 2026-08-14 |
| Date basis | campaign window |

Reported fdinfo membership and retained interest after final close. Stale event delivery or retargeting to a reused descriptor was not demonstrated.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-18-final-close-dead-epoll-interest/finding.md) preserves the earlier source record.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| FD / MC-3 | GPT-5.6-terra / Codex | [verdict](../../evidence/native-runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-3/verdict.json) · [report](../../evidence/native-runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
