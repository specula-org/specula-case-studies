# Severity Classification — etcd-raft V01

## Summary

- Total entries: 7
- Reproduced bugs: 2
- Severity-bearing findings: 0
- Critical: 1
- High: 1
- Medium: 0
- Low: 0
- No-severity dispositions: 5

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|---|---|---|---|---|
| 1 | CR-1 | FIXED | — | Verified fixed on this revision; no current severity-bearing disposition. |
| 2 | CR-2 | NEEDS MORE INFO | — | The current public-interface consequence was not re-established. |
| 3 | CR-3 | REPRODUCED | High | Public Node calls commit two membership changes before the first becomes effective, violating the membership serialization contract at the Ready/Advance boundary. |
| 4 | CR-4 | DROPPED | — | Historical duplicate disposition is not severity-bearing. |
| 5 | CR-5 | NEEDS MORE INFO | — | The prior delayed-read consequence was not re-established on the V01 API. |
| 6 | CR-6 | FIXED | — | The configuration request appears in the next Ready after quota release. |
| 7 | MC-1 | REPRODUCED | Critical | Public recovery from a valid joint snapshot lets an incoming-only quorum elect a leader without an outgoing-quorum majority, breaking election safety. |
