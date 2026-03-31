# Bug Report — MongoDB MongoRaftReconfig

## Summary

- Bug families tested: 5 (force reconfig, drain mode, heartbeat propagation, arbiter quorum, newlyAdded)
- Bugs found: 3 (known/by-design)
- Spec unfaithfulness: 1 (Bug 1: newlyAdded — MC counterexample not realizable in implementation)
- Configs run: MC_hunt_force.cfg, MC_hunt_force_v2.cfg, MC_hunt_drain_v3.cfg, MC_hunt_heartbeat_v2.cfg, MC_hunt_arbiter.cfg, MC_hunt_newlyadded_v2.cfg

---

## Bug 1: newlyAdded Quorum Reduction — SPEC UNFAITHFULNESS

- **Bug Family**: Family 5 (newlyAdded two-phase voter addition)
- **Severity**: ~~High~~ → **Not a bug** (spec unfaithfulness, reclassified after reproduction)
- **Invariant violated**: NeverRollbackCommitted (in the TLA+ model only — not realizable in implementation)
- **Config**: MC_hunt_newlyadded_v2.cfg (ForceReconfigLimit=0)
- **Counterexample**: 20 states, output file: `spec/output/MC_hunt_newlyadded_v2.out`
- **Reproduction**: `repro/test_bug1_newlyadded.py` (executed on MongoDB 8.2.6)

### Trace Summary

1. **States 1-3**: s1 wins election (term 1), s2 wins election (term 2). Two leaders in different terms (valid).
2. **States 4-5**: Both complete drain mode. s1 has configTerm=1, s2 has configTerm=2.
3. **States 6-7**: Both write client entries: s1 writes `[term:1]` at index 1, s2 writes `[term:2]` at index 1.
4. **State 8**: s2 sends config to s1 (SendConfig). s1 steps down to Follower (term updated to 2).
5. **State 9**: s2 reconfigures to `{s2,s3}`, removing s1. ConfigIsSafe passes with quorum {s1,s2}.
6. **State 10**: Config propagated to s3 via SendConfig.
7. **State 11**: s2 reconfigures to `{s1,s2,s3}`, re-adding s1. **s1 gets newlyAdded=TRUE** (non-voting).
8. **States 12-13**: New config propagated to s1 and s3.
9. **State 14**: s2 reconfigures to `{s1,s2}`, removing s3. EffectiveVoters = {s2} (s1 is newlyAdded).
10. **State 15**: **s2 commits entry [term:2, index:1] with 1-node DataQuorum** ({s2} is the only effective data voter).
11. **State 16**: s2 removes newlyAdded from s1. **In the spec, this is a global state change; s1 becomes a full voter but config[s1] stays stale.**
12. **State 17**: s1 wins election (term 3) using stale config `{s1,s2,s3}` with votes from s3. **← THIS STATE IS UNREACHABLE IN THE IMPLEMENTATION (see below).**
13. **States 18-19**: s1 completes drain, writes new entry `[term:3]` at index 2.
14. **State 20**: **s2 rolls back its committed entry** to sync with s1's log `<<[term:1],[term:3]>>`.

### What's Real: Quorum Reduction to 1

The quorum reduction IS real. With config `{s1(newlyAdded), s2}`:
- `EffectiveVoters({s1,s2})` = `{s2}` (s1 excluded because `isVoter()` returns false)
- `DataQuorums({s2})` = `{{s2}}` — quorum of 1
- `w:majority` succeeds with only s2 acknowledging

This was **demonstrated** on MongoDB 8.2.6 (Phase A of reproduction test): a `w:majority` write succeeded with only the primary acknowledging, while the other member was stopped and unable to replicate.

### Why The Rollback Is Not Achievable: Spec Unfaithfulness

The MC counterexample's critical transition (State 16 → 17) requires s1 to be **non-newlyAdded** while having a **stale config `{s1,s2,s3}`**. This state is **impossible** in the real implementation.

**The modeling error**: The TLA+ spec models `newlyAdded` as a separate global variable (`VARIABLE newlyAdded`), independent of `config`. The `RemoveNewlyAdded(s2, s1)` action sets `newlyAdded'[s1] = FALSE` globally while `config[s1]` remains stale. This decoupling allows the counterexample to construct an intermediate state that cannot exist in reality.

**In the real implementation**, `newlyAdded` is a field **inside the config document** (`member_config.h:71`, `member_config.idl:87-94`). Config installation is atomic (`_rsConfig.update()` at `replication_coordinator_impl.cpp:4587`). When the primary auto-removes `newlyAdded`, it creates a **new config version** that changes both the newlyAdded flag and the member list simultaneously. This creates an inescapable dilemma:

1. **s1 has stale config** (e.g., `{s1(newlyAdded), s2, s3}` from before s3 was removed) → s1 still sees itself as `newlyAdded` → `getPriority()` returns 0 → `isElectable()` returns false → `invariant(isElectable())` in `ElectionState::start()` **blocks the election**
2. **s1 received the newlyAdded-removed config** → member list is `{s1, s2}` (not `{s1,s2,s3}`) → s1 only sends `RequestVote` to s1 and s2 → **cannot contact s3 for votes**

**Reproduction confirmed this** (Phase B): after starting mongo1, it caught up and received the new config. Once `newlyAdded` was auto-removed, mongo1's config was atomically `{mongo1, mongo2}` — mongo3 was absent. The MC counterexample's State 17 was confirmed unreachable.

**Additional defense**: auto-removal only triggers after the member reaches `RS_SECONDARY` state (`replication_coordinator_impl_heartbeat.cpp:416-417`), which requires replicating all committed data. This ensures entries committed under the 1-node quorum are replicated to the new voter **before** the quorum expands — a property not captured by the TLA+ model.

### Affected Code (reference only — no fix needed)

- `member_config.h:177-186` — `isVoter()` returns false for newlyAdded
- `member_config.h:154-156` — `getPriority()` returns 0 for newlyAdded (blocks election)
- `member_config.h:270-272` — `isElectable()` returns false for newlyAdded
- `replication_coordinator_impl_elect_v1.cpp:204` — `invariant(isElectable())` at election start
- `replication_coordinator_impl.cpp:4587` — atomic config installation via `_rsConfig.update()`
- `replication_coordinator_impl_heartbeat.cpp:416-417` — SECONDARY gate for auto-removal

### Recommendation

1. **Fix the TLA+ spec**: Model `newlyAdded` as part of the config document, not as a separate global variable. The `RemoveNewlyAdded` action should simultaneously update the member's voting status and the config membership visible to that node. This eliminates the spurious counterexample.
2. **No code fix needed**: The implementation's defense mechanisms (atomic config installation + SECONDARY-gate for auto-removal) prevent the quorum reduction from causing data rollback.
3. **Documentation**: Consider documenting that transient 1-effective-voter configs are possible during newlyAdded reconfig sequences, so operators are aware of the temporary durability reduction window.

---

## Bug 2: Force Reconfig Committed Data Rollback

- **Bug Family**: Family 1 (force reconfig safety bypass)
- **Severity**: Medium (known limitation, documented)
- **Invariant violated**: NeverRollbackCommitted
- **Config**: MC_hunt_force_v2.cfg
- **Counterexample**: 11 states, output file: `spec/output/MC_hunt_force_v2.out`

### Trace Summary

1. s1 self-elects in 1-node config, completes drain, writes and commits entry `[term:1, index:1]`.
2. s2 force-reconfigures to `{s2}` — isolated config island with configTerm=-1.
3. s2's force config (version=10000, term=-1) propagates to s1 via SendConfig. s1 adopts config `{s2}`.
4. s2 wins election (term 2), writes entry `[term:2, index:1]`.
5. s1 rolls back committed entry to sync with s2's log.

### Root Cause

Force reconfig (`configTerm=-1`) bypasses all ConfigIsSafe preconditions and uses version-only comparison that overrides safe configs. This allows creation of isolated config islands that break quorum overlap, enabling committed data to be overwritten.

Known: SERVER-55376 (reconfig can roll back committed writes), SERVER-47852/SERVER-54746 (two primaries possible after force reconfig, closed as "Works as Designed").

### Affected Code

- `replication_coordinator_impl.cpp:3563-3624` — three `if (!force)` guards skip safety checks
- `repl_set_config.h:82-99` — ConfigVersionAndTerm comparison ignores terms when either is -1

### Recommendation

This is a known design trade-off. Force reconfig is documented as an emergency tool that may cause data loss. No fix recommended beyond existing documentation warnings.

---

## Bug 3: Force Reconfig Election Safety Violation

- **Bug Family**: Family 1 (force reconfig safety bypass)
- **Severity**: Medium (known limitation)
- **Invariant violated**: ElectionSafety (two leaders in same term)
- **Config**: MC_hunt_force_deep.cfg
- **Counterexample**: 4 states, output file: `spec/output/MC_hunt_force_deep.out`

### Trace Summary

1. s1 self-elects (term 1) in single-node config.
2. s2 force-reconfigures to `{s2}`.
3. s2 self-elects (term 1) — **two leaders in term 1**.

### Root Cause

Force reconfig allows creation of isolated configs where separate nodes can independently elect themselves. Known: SERVER-47852/SERVER-54746.

---

## Bug 4: Arbiter Quorum Overlap Violation

- **Bug Family**: Family 4 (config quorum calculation errors)
- **Severity**: Low (design limitation)
- **Invariant violated**: ArbiterQuorumOverlap (in initial state)
- **Config**: MC_hunt_arbiter.cfg (5 servers: 2 data + 3 arbiters)
- **Counterexample**: 1 state (initial), output file: `spec/output/MC_hunt_arbiter.out`

### Trace Summary

With config `{s1,s2,s3,s4,s5}` where `{s3,s4,s5}` are arbiters: ConfigQuorum (3 of 5 voters) can be `{s3,s4,s5}` (all arbiters), which has zero overlap with DataQuorum `{s1,s2}`. A config can be "committed" by arbiters without any data node acknowledging.

### Root Cause

`$configMajority` counts arbiters as voters, but `$majority` (data commitment) excludes them. In arbiter-heavy configs (arbiters >= data nodes), config quorum can be all-arbiter.

### Affected Code

- `repl_set_config.cpp:683-688` — `$configMajority` pattern includes arbiters
- `repl_set_config.cpp:637-648` — separate `_majorityVoteCount` (with arbiters) vs `_writeMajority` (without)

### Recommendation

This is a known design property of arbiter-heavy configs. MongoDB documentation warns against using many arbiters. Consider: add a startup validation warning when `|arbiters| >= |data nodes|`.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Family 2: Drain mode races (no force) | MC_hunt_drain_v3.cfg | 29M states, 3M distinct | No violation |
| Family 3: Heartbeat propagation | MC_hunt_heartbeat_v2.cfg | 207M states, 14.7M distinct | No violation |

---

## Spec Fixes During Validation

1. **CompleteDrain configVersion**: Removed increment — implementation only bumps configTerm during drain completion.
2. **GetTerm out-of-bounds**: Added guard `index > Len(xlog)` to return 0 for out-of-range access.
3. **NodeCommitIndex**: Replaced global `MaxCommittedIndex` with per-node bound `Min({MaxCommittedIndex, Len(log[i])})` to prevent nodes from claiming commit points beyond their log.
