# Specula Pipeline Summary

Generated: 2026-04-20T22:54:03+00:00

## Systems Processed

### ccc-mem2reg

- **Phase 1 (Analysis)**: OK (modeling-brief: 412 lines)
- **Analysis Review**: SKIPPED
- **Phase 2 (Spec Gen)**: OK (4/4 files, base: 978 lines)
- **Spec Gen Review**: SKIPPED
- **Phase 2.5 (Harness)**: OK (traces: 1, INSTRUMENTATION.md: yes)
- **Phase 3 (Validation)**: Converged in 2 rounds. Bug hunting: **1 real bug confirmed (D3 asm-goto snapshot overwrite)** + 1 fixture limitation (D2 not reproduced by the current fixture shape).
- **Validation Review**: SKIPPED

**Logs:**
- `.specula-output/agent.log` (4.0K)
- `.specula-output/spec-gen.log` (4.0K)

