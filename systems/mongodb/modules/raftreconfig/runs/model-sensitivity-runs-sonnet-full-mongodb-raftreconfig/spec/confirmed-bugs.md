# Confirmed Bugs: MongoDB Raft Reconfig

**Target**: mongodb-raftreconfig  
**Phase**: Bug Confirmation (Phase 4)  
**Date**: 2026-06-04  

---

## Summary

| Bug ID | Invariant | Status | Severity | Repair |
|--------|-----------|--------|----------|--------|
| BUG-1  | MCConfigTermBelowElectionTerm | REPRODUCED | Medium | — |
| BUG-2  | MCElectionSafety | REPRODUCED | High (see note) | — |
| BUG-3  | MCElectionSafety | PENDING REPAIR (RR-001) | N/A | RR-001 |
| BUG-4  | MCCommitPointSafety | PENDING REPAIR (RR-002) | N/A | RR-002 |
| BUG-5  | MCVoteOnce | REPRODUCED | Critical | — |

---

## BUG-1: Leader configTerm Exceeds Election Term

**Source**: MC  
**Status**: REPRODUCED  
**Severity**: Medium  
**Location**: `replication_coordinator_impl_heartbeat.cpp:372`, `replication_coordinator_impl.cpp:~1495`

### Description

When a node installs a config via HBReconfig, `configTerm` is set to the config's
term (e.g., 3), but `currentTerm` is NOT updated (`_updateTerm` uses only `mterm`,
not the config's term). The node can then win an election in a lower term (e.g., 2).
When AutoReconfig runs on step-up, it calls `config.setConfigTerm(primaryTerm)`
which DOWNGRADES `configTerm` from 3 to 2. The resulting VAT `(version+1, term=2)` is
ordering-less than other nodes' configs with `(version, term=3)`, so those nodes
reject the new config as stale. Config propagation stalls.

### Code Audit

- `replication_coordinator_impl_heartbeat.cpp:372`: `_updateTerm(lk, hbResponse.getTerm())` uses only `mterm` from the heartbeat response. The heartbeat response's config term (`configVAT.term`) is NOT used to update `currentTerm`.
- `replication_coordinator_impl.cpp:~1495` (AutoReconfig / `_onCompletion` drain loop): `config.setConfigTerm(primaryTerm)` sets the new configTerm to the election term — unconditionally, even when `configTerm > primaryTerm`.
- No safeguard checks `configTerm > currentTerm` before the downgrade. The `needBumpConfigTerm` check only skips bumping when `configTerm == kUninitializedTerm`, not when it's already higher than the election term.

**Trigger scenario**: (1) Node A has `configTerm=3` (installed via HBReconfig). (2) Node A crashes and restarts with `currentTerm = max(durableVote.term, configTerm)` — but if it wins an election at term 2 (because other nodes haven't seen term 3 yet), it has `currentTerm=2, configTerm=3`. (3) AutoReconfig sets `configTerm=2`, downgrading from 3. Other nodes reject the propagated config.

### Developer Intent Investigation

The README documents that config ordering uses `(term, version)` and that a leader bumps configTerm on step-up via AutoReconfig. No documentation found that acknowledges configTerm > currentTerm as a possible invariant violation, and no developer comment addresses this case. No existing test covers this specific scenario.

### Reproduction Test

`spec/repro/test_bug1_configterm_downgrade.py` — Level 2 (state injection)

```
[State injection] Pre-AutoReconfig state:
  n1: role=PRIMARY, currentTerm=2, configTerm=3
  n3: role=SECONDARY, currentTerm=2, configTerm=3

[INVARIANT VIOLATED] MCConfigTermBelowElectionTerm:
  n1: configTerm=3 > currentTerm=2
  n3: configTerm=3 > currentTerm=2

[Action] AutoReconfig(n1): set configTerm = currentTerm
  n1.configTerm: 3 → 2  (downgraded!)

[Config ordering check]
  n1 VAT: (version=4, term=2)
  n3 VAT: (version=3, term=3)
  RESULT: n3's config is NEWER than n1's — n3 REJECTS n1's config!
```

**Reproduction result**: PASS — invariant violated pre-AutoReconfig, and config propagation stalls post-AutoReconfig. (Level 2 — state injection, `exit:0`)

### Recommendation

In `_scheduleHeartbeatReconfig` or `_heartbeatReconfigFinish`, after installing a new config via HBReconfig, update `currentTerm = max(currentTerm, newConfig.getConfigTerm())`. Alternatively, in AutoReconfig, skip the configTerm bump if `configTerm > currentTerm` (preserve the higher value). This mirrors the crash-recovery logic in `_finishLoadLocalConfig` which already does `term = max(lastVote.term, configTerm)`.

---

## BUG-2: Force Reconfig Enables Multi-Leader Split Brain

**Source**: MC  
**Status**: REPRODUCED  
**Severity**: High (by-design / known limitation — see note)  
**Location**: `repl_set_config_checks.cpp:570-574`, `replication_coordinator_impl.cpp:3458-3459`

### Description

`ForceReconfig` (force=true) skips `validateSingleNodeChange()`, which enforces
the Raft single-node-change condition guaranteeing quorum overlap between
consecutive configs. This allows two concurrent force reconfigs to install
disjoint single-node configs (e.g., `{n1}` and `{n3}`). Each single-node
cluster forms its own quorum of one and independently elects a primary in the
same term, producing simultaneous leaders.

### Code Audit

- `repl_set_config_checks.cpp:570-574`: The `validateSingleNodeChange` check is explicitly inside `if (!force)`, confirming the bypass for force reconfigs.
- `replication_coordinator_impl.cpp:3458-3459`: `auto term = (!args.force) ? currentTerm : OpTime::kUninitializedTerm` — force reconfigs use `kUninitializedTerm`, allowing configs to not participate in term-based ordering.
- No safeguard prevents two simultaneous force reconfigs from creating disjoint membership sets.

**Trigger scenario**: (1) A 3-node RS is in a degraded state where no majority is reachable. (2) An operator issues `rs.reconfig({members: [{host:"n1"}]}, {force: true})` on node n3. (3) Another operator issues `rs.reconfig({members: [{host:"n3"}]}, {force: true})` on a different surviving node. (4) Both nodes see themselves as single-node clusters and elect themselves as primaries in term 1.

### Developer Intent Investigation

The MongoDB README explicitly documents: *"force reconfigs are unsafe, they exist to allow users to salvage or repair a replica set where a majority of nodes are no longer operational."* The unsafe nature of force reconfigs is an **acknowledged trade-off**. However, the specific mechanism of two concurrent force reconfigs creating simultaneous leaders is not called out as a supported-but-unsafe scenario in the docs.

**Note on severity**: Because the docs acknowledge force reconfigs as "unsafe," this is a known limitation rather than an unintended bug. However, it is a concretely triggerable ElectionSafety violation with real data-loss implications. The operator-facing documentation should warn that two concurrent force reconfigs on different surviving nodes can produce simultaneous primaries.

### Reproduction Test

`spec/repro/test_bug2_force_reconfig_split_brain.py` — Level 2 (state injection)

```
[Level 0 code audit] Force reconfig bypasses validateSingleNodeChange:
  if (!force) {
      status = validateSingleNodeChange(oldConfig, newConfig);
  }
  → CONFIRMED: single-node change check is skipped for force=true

[INVARIANT VIOLATED] MCElectionSafety:
  Term 1: multiple leaders = ['n1', 'n3']

RESULT: BUG-2 REPRODUCED (Level 2 — state injection)
```

**Reproduction result**: PASS — two leaders in term 1 via dual force reconfigs. (Level 2, `exit:0`)

### Recommendation

Add a guard in the `replSetReconfig` command that prevents multiple simultaneous force reconfigs from producing disjoint single-node configs. Alternatively, add an operator warning in the documentation and tooling when a force reconfig would result in a single-node cluster. The long-term fix requires either requiring a majority presence even for force reconfigs, or adding a "cluster token" that prevents disjoint force-reconfig scenarios.

---

## BUG-3: HBReconfig Excludes Leader from Its Own Config

**Source**: MC  
**Status**: PENDING REPAIR (RR-001)  
**Severity**: N/A — false positive  
**Repair Request**: `spec/repair-requests/RR-001.md`  
**Location**: `replication_coordinator_impl_heartbeat.cpp` (`_heartbeatReconfigFinish`)

### Description

The TLA+ counterexample shows `BecomeLeader(n1)` when `n1 ∉ config[n1]`, then `n3` also elects itself from a single-node `{n3}` config, producing two simultaneous leaders. In the real code, this is prevented by two independent safeguards.

### Code Audit

Two safeguards prevent the counterexample scenario:

1. **`_shouldStepDownOnReconfig`** (`replication_coordinator_impl_heartbeat.cpp`): Returns `_memberState.primary() && !(myIndex.isOK() && newConfig.getMemberAt(myIndex.getValue()).isElectable())`. When a primary receives an HBReconfig that excludes itself, `_shouldStepDownOnReconfig` returns `true` and the primary calls `prepareForUnconditionalStepDown()` and steps down **before** `_setCurrentRSConfig` installs the new config. A primary cannot be in a stable state where its own config excludes itself.

2. **`selfIndex = -1` guard**: In `_heartbeatReconfigFinish`, when `findSelf` returns `NodeNotFound`, `myIndexValue` is set to `-1`. `_setCurrentRSConfig` stores `_selfIndex = -1`. `processReplSetRequestVotes` guards on `_selfIndex == -1` and returns `ErrorCodes::InvalidReplicaSetConfig`, preventing the node from participating in elections.

**Trigger scenario**: Not constructible in the real code. The counterexample requires a node to `BecomeLeader` when it is not in its own config, which is structurally prevented by `selfIndex=-1`.

### Developer Intent Investigation

The `_shouldStepDownOnReconfig` safeguard is the intended mechanism for this case. Its presence demonstrates that the developers explicitly handle "primary not in new config" as a step-down trigger. No developer commentary indicates this was intended to be unsafe.

### Reproduction Test

`spec/repro/test_bug3_hbreconfig_excludes_leader.py` — Level 0 + Level 2 (safeguard audit)

```
[Level 2] Attempting to inject counterexample state:
  Before HBReconfig: n1.role=PRIMARY
  HBReconfig(n1, config={n3}) — new config excludes n1
  _shouldStepDownOnReconfig(n1) = True → n1 steps down to SECONDARY
  n1 selfIndex = -1 (not in new config)
  After HBReconfig: n1.role=SECONDARY, n1.config=['n3']

  Can n1 run for election? selfIndex=-1
  → NO: selfIndex=-1 → not a member → cannot run for election
```

**Reproduction result**: FALSE POSITIVE — safeguard prevents scenario. Repair request RR-001 created.

### Recommendation

Add `n ∈ config[n]` as a precondition to `BecomeLeader(n)` in `base.tla`. This models the `selfIndex ≥ 0` requirement enforced by the real code. See `spec/repair-requests/RR-001.md`.

---

## BUG-4: Commit Point Safety Violation in Config Swap Window

**Source**: MC  
**Status**: PENDING REPAIR (RR-002)  
**Severity**: N/A — false positive  
**Repair Request**: `spec/repair-requests/RR-002.md`  
**Location**: `replication_coordinator_impl.cpp:4037,4065`

### Description

The TLA+ counterexample shows `AdvanceCommitIndex(n1)` interleaving between `SafeReconfigSwap` and `SafeReconfigCaptureBarrier`. This inflates `lastCommittedInPrevConfig` to an entry that a quorum of the new config doesn't have, violating `MCCommitPointSafety`. In the real code, the replication mutex prevents this interleaving.

### Code Audit

Two safeguards prevent the interleaving:

1. **Replication mutex atomicity**: Both `_setCurrentRSConfig` (line 4037) and `updateLastCommittedInPrevConfig` (line 4065) are called while holding `_mutex` (`WithLock lk`). The developer comment at line 4062 explicitly states: *"Once we have acquired the replication mutex above, we are ensured that no new writes will be committed in the previous config, since any other system operation must acquire the mutex to advance the commit point."* `AdvanceCommitIndex` → `_advanceCommitPoint` → `advanceLastCommittedOpTimeAndWallTime` also requires `_mutex`, so it cannot run between lines 4037 and 4065.

2. **`awaitReplication` barrier** (line 4161): After the config swap, `awaitReplication(configOplogCommitmentOpTime)` blocks until a quorum of the NEW config has replicated all committed entries. This prevents a second `SafeReconfigStart` from starting before the first reconfig's commitment obligations are satisfied.

**Trigger scenario**: Not constructible in the real code. The mutex prevents the interleaving; `awaitReplication` prevents the cascading second reconfig.

### Developer Intent Investigation

The developer comment at line 4062 explicitly describes the mutex guarantee. `awaitReplication` at line 4161 is the documented mechanism for ensuring config oplog commitment. Both are intentional design choices, not accidental.

### Reproduction Test

`spec/repro/test_bug4_commit_barrier_race.py` — Level 0 (mutex audit) + Level 2

```
[Level 0] Auditing mutex protection in _doReplSetReconfig
  _setCurrentRSConfig call found at line ~4037
  updateLastCommittedInPrevConfig call found at line ~4065
  Both calls take 'lk' (WithLock) parameter — same mutex held throughout
  → AdvanceCommitIndex CANNOT interleave between lines 4037–4065

  line 4037: _setCurrentRSConfig(lk, opCtx, newConfig, myIndex);
  line 4062: // Once we have acquired the replication mutex above,
             // we are ensured that no new writes will be committed
  line 4065: _topCoord->updateLastCommittedInPrevConfig();
```

**Reproduction result**: FALSE POSITIVE — mutex prevents interleaving. Repair request RR-002 created.

### Recommendation

Merge `SafeReconfigSwap` and `SafeReconfigCaptureBarrier` into a single atomic TLA+ action to model the mutex-protected section. See `spec/repair-requests/RR-002.md`.

---

## BUG-5: Non-Atomic Vote Persistence Allows Double Voting

**Source**: MC  
**Status**: REPRODUCED  
**Severity**: Critical  
**Location**: `topology_coordinator.cpp:3789-3791`, `replication_coordinator_impl.cpp:5418-5423`

### Description

In `HandleRequestVote`, the in-memory `_lastVote` is updated inside the mutex (`topology_coordinator.cpp:3790-3791`) and the `RequestVoteReply(granted=TRUE)` reply is sent. The durable write (`storeLocalLastVoteDocument`) is then called **outside** the mutex (`replication_coordinator_impl.cpp:5423`). A crash between the in-memory update and the disk write leaves `durableVote` stale. On restart, `currentTerm` and `_lastVote` are loaded from the stale `durableVote`, and the node can grant a second vote to a different candidate in the same term. If both granted replies reach their respective candidates, two leaders can win elections in the same term.

### Code Audit

- `topology_coordinator.cpp:3789-3791`: `_lastVote.setTerm(args.getTerm())` and `_lastVote.setCandidateIndex(args.getCandidateIndex())` run inside `processVoteRequestV1`, which is called while `_mutex` is held.
- `replication_coordinator_impl.cpp:5417-5423`: Comment says "It's safe to store lastVote outside of _mutex" for thread-safety reasons (concurrent updates from different terms), but this ignores the crash-recovery case. `storeLocalLastVoteDocument` is called after the mutex is released.
- **Crash window**: Between the return of the `processVoteRequestV1` call (in-memory `_lastVote` updated, reply sent) and the `storeLocalLastVoteDocument` call completing.
- No safeguard prevents the pre-crash reply from being in-flight when the post-restart re-vote occurs.

**Trigger scenario**: (1) n2 receives `RequestVote(term=1)` from n3. (2) n2 grants the vote: `_lastVote={term:1, for:n3}` updated in-memory; `RequestVoteReply(granted=TRUE)` put in message buffer. (3) Before `storeLocalLastVoteDocument` persists the vote, n2 crashes. `durableVote` still has `{term:0, for:Nil}`. (4) n3 wins with n2's pre-crash vote. (5) n2 restarts: `_lastVote = durableVote = {term:0, for:Nil}`. (6) n1 starts election in term 1; n2 grants vote to n1. (7) n1 wins with n2's post-crash vote. Two leaders in term 1.

### Developer Intent Investigation

The code comment at line 5417 ("It's safe to store lastVote outside of _mutex") addresses only the concurrent multi-term scenario (threads racing to store votes from different terms). It does not address crash recovery. No test covers the crash-in-vote-window scenario. The comment represents an incomplete safety analysis — it's safe for the concurrent-terms case but not for crash recovery.

### Reproduction Test

`spec/repro/test_bug5_double_vote.py` — Level 2 (state injection)

```
[Level 0] Code audit of vote persistence sequence:
  topology_coordinator.cpp:3790:  _lastVote.setTerm(args.getTerm());
  topology_coordinator.cpp:3791:  _lastVote.setCandidateIndex(args.getCandidateIndex());
  → In-memory _lastVote updated INSIDE mutex

  replication_coordinator_impl.cpp:5423:
      Status status = _externalState->storeLocalLastVoteDocument(opCtx, lastVote);
  comment: "It's safe to store lastVote outside of _mutex."

  *** CRASH WINDOW: between in-memory update and disk write ***

[Final message state]
  RequestVoteReply(from=n2, to=n3, term=1, granted=True)
  RequestVoteReply(from=n2, to=n1, term=1, granted=True)

[INVARIANT VIOLATED] MCVoteOnce:
  n2 sent granted votes in term 1 to: ['n1', 'n3']
```

**Reproduction result**: PASS — MCVoteOnce violated via crash-recovery double vote. (Level 2, `exit:0`)

### Recommendation

Reverse the order of operations: call `storeLocalLastVoteDocument` **before** updating `_lastVote` in-memory and before sending the `RequestVoteReply`. This ensures that if the node crashes, either the disk write succeeded (node correctly cannot re-vote) or it failed (node can safely vote again). Alternative: log the vote intention durably first (WAL-style), then update memory and send reply.

---

## Reproduction Tests

| Bug | Test File | Level | Exit |
|-----|-----------|-------|------|
| BUG-1 | `spec/repro/test_bug1_configterm_downgrade.py` | L2 state-injection | 0 |
| BUG-2 | `spec/repro/test_bug2_force_reconfig_split_brain.py` | L2 state-injection | 0 |
| BUG-3 | `spec/repro/test_bug3_hbreconfig_excludes_leader.py` | L0 audit + L2 | 0 |
| BUG-4 | `spec/repro/test_bug4_commit_barrier_race.py` | L0 audit + L2 | 0 |
| BUG-5 | `spec/repro/test_bug5_double_vote.py` | L2 state-injection | 0 |

## Repair Requests

| ID | Bug | Status |
|----|-----|--------|
| RR-001 | BUG-3 | OPEN |
| RR-002 | BUG-4 | OPEN |
