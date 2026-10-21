# Severity Classification — asterinas-unix-dgram-scm-rights

## Summary

- Total entries: 4
- Reproduced bugs: 2
- Severity-bearing findings: 0
- Critical: 1
- High: 1
- Medium: 0
- Low: 0
- No-severity dispositions: 2

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | Critical | Repeated control-buffer faults in AF_UNIX datagram `recvmsg`, including `MSG_PEEK`, can exhaust the receiver's descriptor table through unpublished live descriptors that survive until process exit or manual closure of guessed descriptor numbers. Critical reflects the report's argued persistent exhaustion without automatic recovery, supported by direct observation of leaked descriptors and misreported partial delivery. |
| 2 | MC-2 | REPRODUCED | High | An ordinary AF_UNIX datagram `recvmsg` payload-copy fault leaves the datagram and its `SCM_RIGHTS` references queued, so a later valid receive delivers data and descriptors that Linux would have discarded. This externally visible compatibility failure is bounded by a successful receive or socket close, and the report records no reference leak. |
| 3 | CR-1 | FALSE POSITIVE | — | The Phase 4 FALSE POSITIVE disposition carries no severity. |
| 4 | CR-2 | FALSE POSITIVE | — | The Phase 4 FALSE POSITIVE disposition carries no severity. |
