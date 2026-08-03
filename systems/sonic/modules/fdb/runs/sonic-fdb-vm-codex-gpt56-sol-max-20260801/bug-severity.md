# Severity Classification — fdb

## Summary

- Total entries: 7
- Reproduced bugs: 6
- Severity-bearing findings: 1
- Critical: 5
- High: 1
- Medium: 1
- Low: 0
- No-severity dispositions: 0

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | Critical | A delayed `FLUSHED` notification reachable through normal flush and relearn operations permanently removes the newer entry from the cache and `STATE_DB` while ASIC retains it, causing `MuxOrch` to return no port with no automatic reconciliation. |
| 2 | MC-2 | REPRODUCED | Critical | A delayed same-port `AGE` delivered through the public FDB handler deletes the newer software incarnation while ASIC retains it, leaving `MuxOrch` persistently unable to resolve the port absent an independent relearn or restart. |
| 3 | MC-3 | REPRODUCED | Medium | A normal APP_DB VTEP replacement misattributes tunnel references, causing premature software cleanup of the active new tunnel and a leak of the old tunnel; this is a persistent internal accounting and software/hardware consistency failure, but no direct forwarding or client failure was demonstrated. |
| 4 | MC-4 | MASKED | Critical | Without the named sairedis object-reference guard, a normal VLAN-member teardown after an FDB flush failure would remove a bridge port still referenced by an ASIC FDB entry, leaving persistent dangling forwarding topology; `SAI_STATUS_OBJECT_IN_USE` currently masks that consequence. |
| 5 | MC-5 | REPRODUCED | Critical | Delayed FIFO FDB notifications reachable with timing assistance overwrite a newer MCLAG-owned entry and then erase its software ownership while leaving unmanaged hardware state, so `MuxOrch` persistently returns no port until external input repairs it. |
| 6 | MC-6 | REPRODUCED | Critical | Normal deferred same-key APP_DB updates can program an obsolete remote endpoint into the SAI/ASIC forwarding plane, and the wrong destination persists without an unguaranteed later dependency event. |
| 7 | MC-7 | REPRODUCED | High | An ordinary fdbsyncd restart can discard the one-shot kernel NHG dump before NVO readiness, leaving the production `L2NhgOrch` APP_DB input missing for that group indefinitely; the harm is bounded to affected startup NHGs but has no automatic replay. |
