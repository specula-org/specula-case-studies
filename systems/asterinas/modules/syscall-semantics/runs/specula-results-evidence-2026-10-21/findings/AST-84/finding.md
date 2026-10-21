# AST-84 — A conflicting flock SH→EX conversion keeps the caller's old SH lock

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-10-05 |
| Date basis | prepared source question date |

A conflicting flock SH-to-EX conversion checks for conflicts before removing the caller's old shared lock. The failed nonblocking conversion therefore leaves SH ownership behind; competing blocking converters can each retain the lock that prevents the other from proceeding.

GLM-5.3 reproduced retained SH ownership after a conflicting SH-to-EX conversion.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| Flock / MC-1 | GLM-5.3 / pi | [verdict](../../evidence/native-runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/confirmation/MC-1/verdict.json) · [report](../../evidence/native-runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
