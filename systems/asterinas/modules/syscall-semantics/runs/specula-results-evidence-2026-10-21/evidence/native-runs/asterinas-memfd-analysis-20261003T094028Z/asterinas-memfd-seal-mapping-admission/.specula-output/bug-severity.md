# Severity Classification — asterinas-memfd-seal-mapping-admission

## Summary

- Total entries: 5
- Reproduced bugs: 2
- Severity-bearing findings: 0
- Critical: 1
- High: 1
- Medium: 0
- Low: 0
- No-severity dispositions: 3

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | High | Through an `O_RDWR` memfd handle, a read-only shared `mmap` after `F_SEAL_WRITE` incorrectly fails with `EPERM`, and one admitted after `F_SEAL_FUTURE_WRITE` makes later `F_ADD_SEALS(F_SEAL_WRITE)` attempts fail with `EBUSY` for its entire lifetime. These are bounded, externally observed mapping and sealing failures, with the false `EBUSY` clearing only after the caller unmaps the read-only mapping. |
| 2 | MC-2 | REPRODUCED | Critical | An unprivileged shared `MAP_FIXED` mapping request rejected by a memfd write seal destroys the existing mapping, and subsequent access was observed to kill a consumer with `SIGSEGV`. The address-space hole persists until an explicit remap or process exit, with no automatic rollback or recovery. |
| 3 | CR-1 | FALSE POSITIVE | — | Phase 4a classified this entry as `FALSE POSITIVE`, a disposition that receives no severity. |
| 4 | CR-2 | FALSE POSITIVE | — | Phase 4a classified this entry as `FALSE POSITIVE`, a disposition that receives no severity. |
| 5 | CR-3 | FALSE POSITIVE | — | Phase 4a classified this entry as `FALSE POSITIVE`, a disposition that receives no severity. |
