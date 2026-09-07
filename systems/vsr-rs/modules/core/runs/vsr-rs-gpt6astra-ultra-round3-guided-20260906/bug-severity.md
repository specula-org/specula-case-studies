# Severity Classification — vsr-rs

## Summary

- Total entries: 5
- Reproduced bugs: 1
- Severity-bearing findings: 1
- Critical: 1
- High: 0
- Medium: 1
- Low: 0
- No-severity dispositions: 3

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | CR-1 | REPRODUCED | Critical | Clean EOF after an exact prefix of a primary-generated PREPARE frame on kvstore's peer TCP interface lets surviving replicas commit a shortened PUT value after primary failure and failover. A fresh client GET returns the corrupted value, which persists in the surviving view without automatic repair. |
| 2 | CR-2 | FALSE POSITIVE | — | Phase 4a's FALSE POSITIVE disposition is not severity-bearing: the tested excluding-primary view change and rolling recovery preserved committed operation order through quorum intersection and recovery safeguards. |
| 3 | CR-3 | MASKED | Medium | Reordered authentic RecoveryResponse messages from the same sender and nonce can discard newer-view evidence and install a stale committed prefix, creating downstream stale-state risk if left uncorrected. The higher-view Commit guard and GetState/NewState catch-up mask this internal recovery regression; Phase 4a establishes no client-visible inconsistency. |
| 4 | CR-4 | FALSE POSITIVE | — | Phase 4a's FALSE POSITIVE disposition is not severity-bearing: partial output publication before a crash behaved as allowed transport loss, with recovery and client resend preserving order and regenerating lost replies. |
| 5 | CR-5 | FALSE POSITIVE | — | Phase 4a's FALSE POSITIVE disposition is not severity-bearing: with fair idle calls and healthy-majority message delivery, retry and view-change timers moved past an unavailable primary and completed pending requests. |
