# AST-19 — Consumed timerfd remains ready through the poll cache

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Fixed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-08-12 to 2026-08-14 |
| Date basis | campaign window |

Merged PR #3984 invalidates cached readiness after draining or resetting timerfd ticks. Patch and current main checked on 2026-10-21.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-19-consumed-timerfd-stale-poll-cache/finding.md) preserves the earlier source record.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| FD / MC-4 | GPT-5.6-terra / Codex | [verdict](../../evidence/native-runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/verdict.json) · [report](../../evidence/native-runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `complete_merged_fix` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

[Upstream repair reference](https://github.com/asterinas/asterinas/pull/3984).

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
