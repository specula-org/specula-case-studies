# AST-07 — Empty Segment conversion dereferences an unowned first frame

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `kernel_or_device_runtime_record` |
| Tracker status (2026-10-21) | Fixed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-08-07 |
| Date basis | dated local record |

Independent kernel tests reproduced wrong answers; merged PR #3959 forbids empty Segment values. Kernel death is environment-dependent.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-07-segment-empty-slice/finding.md) preserves the earlier source record.

## Independent runtime evidence

[Independent kernel/device validation](../../evidence/workspace/reports/ast-validation-2026-09-02/README.md) and [confirmation provenance](../../evidence/workspace/reports/asterinas-findings-pack-2026-09-24/docs/confirmation-provenance.md) describe the separate sessions and their results.

## Upstream repair snapshot

Assessment: `complete_merged_fix` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

[Upstream repair reference](https://github.com/asterinas/asterinas/pull/3959).

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
