# Severity Classification — HashiCorp memberlist

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
| 1 | MC-1 | REPRODUCED | Critical | Selectively ordered terminal and alive messages can permanently resurrect a crashed node through `Members()` and emit a spurious `NotifyJoin`, with no automatic recovery in the tested supported configuration. |
| 2 | MC-2 | MASKED | Critical | A delayed pre-restart `Alive` can bind a node name to its retired address through `Members()` and `NotifyJoin`; absent the documented normal probe/suspicion mask, that externally visible false membership would persist without automatic recovery. |
| 3 | MC-3 | REPRODUCED | Critical | A join rejected through the public merge-policy interface nevertheless permanently admits and gossips the rejected member across existing peers, exposing false membership and join events without a corrective mechanism. |
| 4 | CR-2 | REPRODUCED | High | Under normal probes and packet loss, higher-incarnation suspicion can prematurely emit an incorrect `NotifyLeave` for an older incarnation; membership later reconverges, but the bounded false application event is not retracted. |
