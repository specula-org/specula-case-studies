# Severity Classification — asterinas-local-flock-ownership

## Summary

- Total entries: 6
- Reproduced bugs: 2
- Severity-bearing findings: 0
- Critical: 2
- High: 0
- Medium: 0
- Low: 0
- No-severity dispositions: 4

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | Critical | Public `flock(2)` conversions from shared to exclusive mode retain the old shared locks on conflict, causing unexpected `EAGAIN` and a permanent mutual deadlock when two shared-lock holders request blocking conversions. The deadlock has no automatic recovery and requires external unlock, close, or signal intervention. |
| 2 | MC-2 | REPRODUCED | Critical | A public `flock(LOCK_UN)` racing with `close()` on another open of the same file can drop the final temporary owner reference while holding the inode's flock-list mutex, causing permanent recursive-lock deadlock. The affected syscall, subsequent flock calls including nonblocking calls, and close cleanup on that inode then hang with no automatic recovery. |
| 3 | CR-1 | FALSE POSITIVE | — | This Phase 4 FALSE POSITIVE disposition carries no severity. The report found ownership across independent opens and descriptor aliases consistent with Linux. |
| 4 | CR-2 | FALSE POSITIVE | — | This Phase 4 FALSE POSITIVE disposition carries no severity. The report found waiter registration, notification, and retry behavior correct in the exercised scenarios. |
| 5 | CR-3 | FALSE POSITIVE | — | This Phase 4 FALSE POSITIVE disposition carries no severity. The report confirmed that deferred final release follows the Linux open-file-description lifetime contract. |
| 6 | CR-4 | FALSE POSITIVE | — | This Phase 4 FALSE POSITIVE disposition carries no severity. The report recorded the extra wake/retry as intended behavior with no incorrect flock result and negligible measured cost. |
