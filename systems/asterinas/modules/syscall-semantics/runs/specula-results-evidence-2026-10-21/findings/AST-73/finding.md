# AST-73 — Post-seal memfd read-only shared mappings retain writable tracking

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-10-03 |
| Date basis | dated local record |

The shared-mapping path decides to track writable ownership from MAY_WRITE before checking memfd seals. The seal check can remove MAY_WRITE, but the tracking decision remains true. Read-only shared mappings can consequently receive an incorrect EPERM or keep a later WRITE-seal addition failing with EBUSY.

GLM-5.3 reproduced wrong EPERM/EBUSY results for post-seal read-only shared mappings. The prepared source lead was already known locally.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| Memfd / MC-1 | GLM-5.3 / pi | [verdict](../../evidence/native-runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmation/MC-1/verdict.json) · [report](../../evidence/native-runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
