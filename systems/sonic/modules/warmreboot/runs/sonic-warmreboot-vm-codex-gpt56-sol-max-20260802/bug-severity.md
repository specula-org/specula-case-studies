# Severity Classification — warmreboot

## Summary

- Total entries: 7
- Reproduced bugs: 3
- Severity-bearing findings: 3
- Critical: 3
- High: 3
- Medium: 0
- Low: 0
- No-severity dispositions: 1

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | High | Two public `fast-reboot` callers plus normal SIGTERM can let stale cleanup erase the newer epoch's flags, causing the production service manager to cold-stop services while that reboot proceeds. This turns an intended warm/fast reboot into a bounded client-visible traffic disruption. |
| 2 | MC-2 | ENV_LIMITED | Critical | From public `warm-reboot -f`, an unresolved next hop makes restart-check fail, yet forced mode checkpoints and reboots without quiescence; in production, pending work then makes orchagent fail warm-restore validation and exit without automatic service restart. The persistent outcome requires operator or cold recovery and was unobservable here only because the host lacks the SONiC/DVS runtime and Docker access. |
| 3 | MC-3 | REPRODUCED | Critical | The public restart-check can report `READY` while FDB learning remains enabled, allowing ordinary VLAN traffic to enter ASIC state without matching STATE_DB records before checkpointing. The reproduced inconsistency caused persistent bidirectional forwarding failures beyond the aging window, with no downstream repair. |
| 4 | MC-4 | REPRODUCED | Critical | A process failure during public `APPLY_VIEW` between the two Redis map updates leaves a permanently empty VIDTORID map beside a complete RIDTOVID map. Real translation throws and syncd warm-restart initialization fails after restart, with no validation or repair mechanism to restore operation. |
| 5 | MC-5 | MASKED | High | The warmboot finalizer can observe `RECONCILED` while stale deletions and route updates/additions are still buffered, which would expose completion with incorrect or missing routes and client-visible forwarding impact. The current unconditional fpmsyncd `pipeline.flush()` immediately delivers every queued operation and masks that consequence. |
| 6 | MC-6 | MASKED | High | After public `fast-reboot`, timeout handling clears the warm/fast flags while bgp and orchagent remain incomplete; without the safeguard, xcvrd can treat the system as cold and prematurely publish media settings, flapping all ports. Current xcvrd uses the retained `syncd.restore_count` value, which masks this bounded outage. |
| 7 | CR-5 | DROPPED | — | `DROPPED` is a Phase 4 disposition and is not severity-bearing. |
