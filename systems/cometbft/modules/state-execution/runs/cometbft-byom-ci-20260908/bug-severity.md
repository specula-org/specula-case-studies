# Severity Classification — cometbft

## Summary

- Total entries: 3
- Reproduced bugs: 0
- Severity-bearing findings: 0
- Critical: 0
- High: 0
- Medium: 0
- Low: 0
- No-severity dispositions: 3

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | CR-1 | FALSE POSITIVE | — | Phase 4 determined that rejected parameter updates do not alter active or persisted consensus state, so this disposition is not severity-bearing. |
| 2 | CR-2 | FALSE POSITIVE | — | Phase 4 determined that startup replay resolves the exercised durable boundaries before normal consumers observe state, so this disposition is not severity-bearing. |
| 3 | CR-3 | FALSE POSITIVE | — | Phase 4 determined that supported startup height relations synchronize correctly and unsupported relations stop before normal operation, so this disposition is not severity-bearing. |
