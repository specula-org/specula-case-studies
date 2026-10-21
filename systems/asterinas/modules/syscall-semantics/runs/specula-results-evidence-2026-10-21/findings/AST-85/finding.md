# AST-85 — flock unlock drops a temporary owner reference under the list Mutex and self-deadlocks on re-entry

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-10-05 |
| Date basis | prepared source question date |

The unlock scan holds the flock-list mutex while temporarily upgrading a weak owner reference. A concurrent final close can make that temporary reference the last owner. Dropping it then invokes cleanup that re-enters the same nonrecursive mutex. The record includes observer-assisted and timing-assisted race evidence; the plain 128-crossing run did not trigger the defect.

GLM-5.3 reproduced destructor reentry under the flock-list mutex using observers/timing assistance. An unassisted 128-crossing run missed it.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| Flock / MC-2 | GLM-5.3 / pi | [verdict](../../evidence/native-runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/confirmation/MC-2/verdict.json) · [report](../../evidence/native-runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
