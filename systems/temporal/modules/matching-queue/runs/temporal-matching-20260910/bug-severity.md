# Severity Classification — temporal-matching

## Summary

- Total entries: 5
- Reproduced bugs: 1
- Severity-bearing findings: 0
- Critical: 1
- High: 0
- Medium: 0
- Low: 0
- No-severity dispositions: 4

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | CR-1 | FALSE POSITIVE | — | Phase 4's FALSE POSITIVE disposition is not severity-bearing; the exercised persistence and ownership paths did not lose accepted work or produce a wrong worker-visible outcome. |
| 2 | CR-2 | FALSE POSITIVE | — | Phase 4's FALSE POSITIVE disposition is not severity-bearing; the empty nonterminal page was injected diagnostically, and its precondition was not reached through the public API or selected backend. |
| 3 | CR-3 | FALSE POSITIVE | — | Phase 4's FALSE POSITIVE disposition is not severity-bearing; the deleted tasks had already reached workers after History accepted their starts, with no caller-visible lost required work. |
| 4 | CR-4 | DROPPED | — | Phase 4's DROPPED disposition is not severity-bearing; the candidate was excluded as a known issue before reproduction. |
| 5 | CR-5 | REPRODUCED | Critical | When a History-start ResourceExhausted error overlaps concurrent fair-queue writes and eviction during unlocked replacement, the persisted acknowledgement can advance past a still-eligible task, permanently hiding it from restart reads and stranding its work at the reader boundary. The report demonstrates this persistent loss of task visibility with SQLite and controlled timing, with no downstream recovery or masking observed in the reproduction. |
