# Specula Pipeline Summary

Generated: 2026-05-08T01:20:56+00:00

## Systems Processed

### scc_2

- **Phase 1 (Analysis)**: OK (modeling-brief: 217 lines)
- **Analysis Review**: SKIPPED
- **Phase 2 (Spec Gen)**: OK (4/4 files, base: 801 lines)
- **Spec Gen Review**: SKIPPED
- **Phase 2.5 (Harness)**: OK (traces: 4, INSTRUMENTATION.md: yes)
- **Phase 3 (Validation)**: Converged in 1 round (Phase 1 ⇄ Phase 2). Bug hunting added Case-A invariant weakenings (above) and one Case-B / structural tightening of iter preconditions. F1 / F3 / F4 found no new violations under the configured bounds; F2 reproduced the documented pre-9573fa1 ordering regression as expected. See `bug-report.md`.
- **Validation Review**: SKIPPED

**Logs:**
- `.specula-output/agent.log` (4.0K)
- `.specula-output/spec-gen.log` (4.0K)

