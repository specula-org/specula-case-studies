# Severity Classification — dash-ha

## Summary

- Total entries: 7
- Reproduced bugs: 6
- Severity-bearing findings: 1
- Critical: 0
- High: 7
- Medium: 0
- Low: 0
- No-severity dispositions: 0

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | High | During a normal planned switchover, out-of-order DPU notifications can overwrite an acknowledged Active term with an older SwitchingToActive term. The stale authoritative role is persisted and broadcast through peer updates and heartbeats with no automatic repair, propagating a role and term safety violation beyond the actor. |
| 2 | MC-2 | REPRODUCED | High | A normal HA-scope update can make `HaSetActor` and `ProducerBridge` install an APPL_DB route to a vDPU still acknowledged as dead, redirecting traffic before hardware readiness. The premature route persists until an independent acknowledgement, creating direct but bounded forwarding harm. |
| 3 | MC-3 | REPRODUCED | High | After an acknowledgement loss, the public SWBus resend path can replay term 1 after term 2 and persist the regressed term into DPU_APPL_DB with no steady-state reconciliation. This monotonicity violation reaches production state and can miscoordinate later HA transitions. |
| 4 | MC-4 | REPRODUCED | High | During an in-flight re-pair, releasing a delayed former-peer SWBus message can mark the new relationship Connected and send a VoteRequest to the new peer using foreign state. The incorrect relationship state is persisted in STATE_DB until corrective input, contaminating live election behavior. |
| 5 | MC-5 | REPRODUCED | High | Restart rehydration with one asserted DPU pending flag can publish two actionable UUIDs for one request; controller approval of both then emits two DPU activation commands. The duplicate public operation and stale UUID persist until explicit cleanup, producing bounded external control-plane harm. |
| 6 | MC-6 | MASKED | High | Without sairedis Meta's `SAI_STATUS_OBJECT_IN_USE` reference guard, a normal HA-set configuration deletion could remove the parent while a live child continues programming an applied scope that references it, leaving persistent hardware dependency corruption for that HA set. Meta currently rejects the removal and DashHaOrch retains and retries the deletion, which masks the hardware consequence. |
| 7 | MC-7 | REPRODUCED | High | A valid vote exchange interleaved with switchover rejections resets the shared retry counter, causing an extra peer SYN and keeping the Redis switchover state in progress beyond its configured budget. At production timing this adds at least one 30-second interval; later recovery cannot undo the excess wire action and delay. |
