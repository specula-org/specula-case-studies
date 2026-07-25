# Specula Pipeline Summary

Generated: 2026-05-08T15:36:14+00:00

## Systems Processed

### crossbeam-epoch_2

- **Phase 1 (Analysis)**: OK (modeling-brief: 293 lines)
- **Analysis Review**: SKIPPED
- **Phase 2 (Spec Gen)**: OK (4/4 files, base: 1009 lines)
- **Spec Gen Review**: SKIPPED
- **Phase 2.5 (Harness)**: OK (traces: 10, INSTRUMENTATION.md: yes)
- **Phase 3 (Validation)**: Converged in 1 round of trace validation + 1 round of MC.cfg checking + 3 incidental spec fixes during hunting. Bug hunting: 0 real bugs found across 6 family configs; F2/F3 confirm the spec correctly detects the corresponding fault classes when adversaries are enabled.
- **Validation Review**: SKIPPED

**Logs:**
- `.specula-output/agent.log` (4.0K)
- `.specula-output/spec-gen.log` (4.0K)

