# AST-08 — IOMMU teardown frees frames before IOTLB invalidation

| Field | Value |
|---|---|
| Source disposition | REPRODUCED |
| Evidence class | `kernel_or_device_runtime_record` |
| Tracker status (2026-10-21) | Confirmed |
| New/Known tracking label | New |
| Discovery or earliest local record | 2026-08-06 |
| Date basis | dated local record |

Independent agent device test reproduced stale DMA into a recycled frame. Requires DMA-capable device/vIOMMU setup; upstream #3920 acknowledges the missing invalidation.

[Historical finding and reproduction material](../../../asterinas-findings-pack-2026-09-24/findings/AST-08-iommu-stale-iotlb/finding.md) preserves the earlier source record.

## Independent runtime evidence

[Independent kernel/device validation](../../evidence/workspace/reports/ast-validation-2026-09-02/README.md) and [confirmation provenance](../../evidence/workspace/reports/asterinas-findings-pack-2026-09-24/docs/confirmation-provenance.md) describe the separate sessions and their results.

## Upstream repair snapshot

Assessment: `no_complete_merged_fix_established` against Asterinas main `f40d6222dc140cc278bd110757b52f3f0fb496aa` on 2026-10-21.

Additional source qualifications are retained in [the supplied finding table](../../evidence/findings-deduplicated.csv).

The tracker preserves existing higher statuses. A Fixed tracking label is not, by itself, a claim that a complete repair has merged; use the separate repair assessment above.

[All selected findings](../../FINDINGS.md) · [Collection overview](../../README.md)
