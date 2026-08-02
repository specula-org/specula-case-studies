# Severity Classification — iccpd

## Summary

- Total entries: 4
- Reproduced bugs: 3
- Severity-bearing findings: 1
- Critical: 3
- High: 1
- Medium: 0
- Low: 0
- No-severity dispositions: 0

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | Critical | An abrupt daemon death after peer-socket teardown permanently leaves ICCP state reported as up and skips peer failover cleanup in State DB and the MC-LAG CLI. The stale disconnected-epoch state persists beyond session timeouts with no automatic reconciliation. |
| 2 | MC-2 | MASKED | High | Overlapping NAK-triggered resyncs can expose stale system configuration to mclagsyncd when an earlier uncorrelated response is accepted as the latest transaction. The separate responder `EXCHANGE`-to-`ERROR` transition masks MC-2 by suppressing the second response and carrying the observed persistent stale-state consequence; absent that mask, MC-2's demonstrated harm is externally visible but bounded until the later response. |
| 3 | MC-3 | REPRODUCED | Critical | A failed traffic-disable write allows an UP MLAG PortChannel to remain forwarding while peer-interface state is unknown, leaving both the forwarding flag and mclagsyncd APP_DB output incorrect. The stale positive sidecar descriptor prevents reconnection or retry, so the unsafe forwarding state persists without automatic recovery. |
| 4 | CR-4 | REPRODUCED | Critical | Peer-supplied partial frames can block the daemon's sole scheduler indefinitely, preventing signal handling, heartbeat expiry, and peer progress, while a mclagsyncd EOF can suppress reconnection for the daemon lifetime. These normal socket surfaces create externally observable service hangs or loss of sidecar service with no automatic recovery while the connection is held or the stale descriptor remains. |
