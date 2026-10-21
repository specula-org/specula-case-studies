# AST-36 — Unix datagram receive may retain a record after copy fault

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `native_confirmation_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-08-23 |
| Date basis | dated local record |

An ordinary UNIX datagram receive can fault while copying its payload and retain the record in the queue. The same test sequence consumes the datagram on Linux. The October run turns the earlier source lead into a runtime-confirmed observation.

GLM-5.3 reproduced an ordinary payload fault retaining a datagram that Linux consumes.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-36-unix-datagram-retain-after-fault/finding.md) preserves the earlier source record.

## Native confirmation evidence

| Run / finding | Confirmation model | Retained artifacts |
|---|---|---|
| SCM / MC-2 | GLM-5.3 / pi | [verdict](../../evidence/native-runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-2/verdict.json) · [report](../../evidence/native-runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmed-bugs.md) |

Reports retain the tested source revision, reproduction conditions, and original verdict. Repeated confirmations of this AST entry are not additional findings.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
