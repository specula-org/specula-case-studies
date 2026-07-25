# Bug Report — MongoDB Change Streams v2 Resume Token Ordering

## Summary

- Bug families tested: 4 (Resume Token Ordering, Invalidation Sequencing, Cross-Shard Merge & Topology, Transaction Unwinding)
- Bugs found: 0
- Configs run: MC_hunt_version_transition.cfg, MC_hunt_invalidation.cfg, MC_hunt_segment_boundary.cfg, MC_hunt_txn_ordering.cfg

---

## Not Reproduced

| Bug Family | Config | States Explored | Traces | Result |
|------------|--------|-----------------|--------|--------|
| Family 1 — Resume Token Ordering & Version Transition | MC_hunt_version_transition.cfg | 247M | 14.7M | No violation (TotalOrder, NoGapOnResume) |
| Family 2 — Invalidation Event Sequencing | MC_hunt_invalidation.cfg | 192M | 14.3M | No violation (InvalidationCompleteness, InvalidationIdempotency) |
| Family 3 — Cross-Shard Merge & Topology Change | MC_hunt_segment_boundary.cfg | 347M | 19M | No violation (TotalOrder, NoEventLossAtSegmentBoundary, NoGapOnResume) |
| Family 5 — Transaction Unwinding & Event Atomicity | MC_hunt_txn_ordering.cfg | 340M | 16.3M | No violation (TxnOrderPreservation, TotalOrder, NoGapOnResume) |

Total: ~1.13B states checked, ~64.3M simulation traces, 0 violations.

---

## Spec Fixes During Bug Hunting

Two Case B (spec modeling issue) fixes were applied during bug hunting. Both involved the `AddShard` action not correctly modeling MongoDB's cursor opening protocol for newly added shards.

### Fix 1: AddShard resume token reference (Case B)

- **Invariant violated**: NoGapOnResume
- **Config**: MC_hunt_segment_boundary.cfg (pre-fix)
- **Counterexample**: 19 states (output/hunt_segment_boundary_sim.out)
- **Issue**: `AddShard` used `deliveredEvents[Len(deliveredEvents)]` as the reference token for cursor positioning. After `InitiateResume`, `deliveredEvents` is cleared to `<<>>`, so AddShard fell back to `NoToken`, positioning the new shard's cursor at the beginning of its event log. This caused events BEFORE the resume point to be delivered.
- **Fix**: Use `resumeToken` as reference when `isResuming` and `deliveredEvents` is empty. Maps to implementation's global HWM propagation through resume (change_stream_topology_helpers.cpp:87-97).

### Fix 2: AddShard clock advancement (Case B)

- **Invariant violated**: TotalOrder
- **Config**: MC_hunt_segment_boundary.cfg (post-fix-1)
- **Counterexample**: 21 states (output/hunt_segment_boundary_v2.out)
- **Issue**: After AddShard, a newly added shard could generate events at stale timestamps (e.g., ct=3 while the delivered stream was at ct=4). The spec didn't model MongoDB's `atClusterTime` constraint that ensures the new cursor's start time is past the current stream position.
- **Fix**: Advance new shard's clock to `max(shardClock[newShard], refToken[1])` during AddShard. Set HWM based on effective clock. Maps to `atClusterTime > current control event clusterTime` (change_stream_reader_context.h:59).

---

## Coverage Notes

- The spec models resume token generation, cross-shard merge ordering, invalidation state machine, topology change lifecycle (V2 segments), and transaction unwinding.
- Simulation mode was used for all hunting configs due to state space size (~50M+ distinct states with full bounds). BFS was used for convergence verification with tight bounds (56M states exhaustive).
- All 3 implementation traces (basic_insert, invalidation, resume) pass validation against the spec.
- The convergence configuration (MC.cfg) passes BFS exhaustive with tight bounds (56M states), simulation (756M states post-fix), and partial BFS with full bounds (1.5B states generated, 660M distinct, depth 17, 0 violations in 30 min) — all with 6 structural invariants.
