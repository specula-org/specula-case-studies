# Bug Report: MongoDB Raft Reconfig — Model Checking Results

**Target**: mongodb-raftreconfig  
**Spec**: `spec/MC.tla` / `spec/base.tla`  
**Date**: 2026-06-04  
**TLC Mode**: Simulation (-S), 30-minute timeout per run  
**Configs run**: MC.cfg (base), MC_hunt_family1–6.cfg  

---

## Summary

| Bug ID | Invariant | Family | Classification | Severity | Confirmation |
|--------|-----------|--------|----------------|----------|--------------|
| BUG-1  | MCConfigTermBelowElectionTerm | 1, 4, 6 | Case C — Real Bug | Medium | REPRODUCED |
| BUG-2  | MCElectionSafety | 1 | Case C — Known Limitation | High | REPRODUCED |
| BUG-3  | MCElectionSafety | 2 | Case B — Spec Artifact | N/A | PENDING REPAIR (RR-001) |
| BUG-4  | MCCommitPointSafety | 2, 3 | Case B — Spec Artifact | N/A | PENDING REPAIR (RR-002) |
| BUG-5  | MCVoteOnce | 5 | Case C — Real Bug | **Critical** | REPRODUCED |

**Spec fixes applied** (Case B — spec modeling issues, not implementation bugs):
- `Crash` action: missing `currentTerm = max(durableVote.term, configTerm)` on restart (confirmed from `_finishLoadLocalConfig()` lines 783–786)
- `HandleRequestVote`, `HandleAppendEntries`, `HandleHeartbeat`: configState not reset to Steady when Leader steps down (confirmed from MongoDB step-down path)

---

## BUG-1: Leader configTerm Exceeds Election Term

**ID**: BUG-1  
**Severity**: Medium  
**Category**: Config Version/Term Ordering (Family 1, 4, 6)  
**Invariant Violated**: `MCConfigTermBelowElectionTerm`  
**Configs**: MC.cfg (base), MC_hunt_family4.cfg, MC_hunt_family6.cfg  

### Root Cause

A node can receive an HBReconfig that installs a config with `configTerm > currentTerm`, then win a leader election without updating `configTerm`. This happens because:

1. A heartbeat sender can have `configTerm=X` (from a previous era) with `mterm < X` (currentTerm reset via crash + low durableVote)
2. `HandleHeartbeat` updates `currentTerm` only based on `mterm`, not `configVAT.term`
3. The HBReconfig installs `configTerm=X` without bumping `currentTerm`
4. The node then wins an election in a lower term Y < X

When this leader runs `AutoReconfig`, it **downgrades** `configTerm` from X to Y (its election term). The resulting config VAT `(version+1, term=Y)` is less than other nodes' `(version, term=X)`, so other nodes reject it as stale. This breaks config propagation.

### Counterexample (base run, 35 steps)

Key states:
- MCHBReconfigSchedule(n3,..., configTerm=3): n3 pending HBReconfig with configTerm=3
- MCHBReconfigFinish(n3): n3.configTerm=3 installed
- (via chain) MCHBReconfigSchedule/Finish on n1: n1.configTerm=3 installed
- MCTimeout(n1) × 2: n1.currentTerm=2
- MCBecomeLeader(n1): n1 is Leader with currentTerm=2, **configTerm=3**

Final state 35:
```
n1: Leader, currentTerm=2, configTerm=3, config={n1}, configVersion=3
n2: Follower, currentTerm=2, configTerm=UNINITIALIZED
n3: Follower, currentTerm=2, configTerm=3
```

`configTerm=3 > currentTerm=2` → invariant violated.

### Affected Code

- `replication_coordinator_impl_heartbeat.cpp:689–698` — HBReconfig schedule does not update currentTerm
- `replication_coordinator_impl.cpp:1468–1514` — AutoReconfig sets `configTerm = currentTerm` (downgrade if configTerm > currentTerm)
- `replication_coordinator_impl.cpp:783–786` — `_finishLoadLocalConfig` bumps term on restart (modeled in spec fix)

### Impact

A leader with `configTerm > currentTerm` will have AutoReconfig downgrade its configTerm, making its config "older" than other nodes' configs. Subsequent HBReconfig propagation stalls. Other nodes continue to use the higher-term config, potentially causing split views of cluster membership.

---

## BUG-2: Force Reconfig Enables Multi-Leader Split Brain

**ID**: BUG-2  
**Severity**: Critical  
**Category**: Force Reconfig Non-Total Ordering (Family 1)  
**Invariant Violated**: `MCElectionSafety`  
**Config**: MC_hunt_family1.cfg  
**References**: SERVER-47119, SERVER-47636

### Root Cause

`ForceReconfig` (`force=true`) skips `validateSingleNodeChange()` (confirmed at `repl_set_config_checks.cpp:570–578`). This allows creating **disjoint single-node configs** (e.g., `{n1}` and `{n3}` simultaneously). Each single-node cluster elects itself independently, producing two simultaneous leaders in the same term.

### Counterexample (41 steps)

```
MCForceReconfig(n3,{n1},6)     → n3.config={n1}, configTerm=UNINITIALIZED
MCForceReconfig(n2,{n2},4)     → n2.config={n2}
MCForceReconfig(n1,{n1,...})   → n1.config={n1,...}
MCTimeout(n3) + MCBecomeLeader(n1)  → n1 elected in term 1 (config includes itself)
...
MCHBReconfigFinish(n3)         → n3.config={n3}
MCBecomeLeader(n3)             → n3 ALSO elected in term 1
```

Final state 41:
```
n1: Leader, currentTerm=1, configTerm=UNINITIALIZED, config={n1}
n3: Leader, currentTerm=1, configTerm=1,             config={n3}
```

**Two leaders in term 1**.

### Affected Code

- `repl_set_config_checks.cpp:570–578` — `validateSingleNodeChange()` skipped for force reconfigs
- `replication_coordinator_impl.cpp:3457–3459` — `term = force ? kUninitializedTerm : currentTerm`

### Impact

Split-brain: two nodes independently accept writes as primary. Data written to each partition is unrecoverable without manual intervention.

---

## BUG-3: HBReconfig Excludes Leader from Its Own Config

**ID**: BUG-3  
**Severity**: Critical  
**Category**: Dual Reconfig Paths (Family 2)  
**Invariant Violated**: `MCElectionSafety`  
**Config**: MC_hunt_family2.cfg  
**References**: SERVER-47949, SERVER-46897

### Root Cause

`HBReconfigFinish` installs a config received via heartbeat without checking whether the new config includes the current node (the leader). If the new config excludes the current leader, the leader continues operating with a config it is not a member of. Nodes in the new config can independently form a quorum and elect a new leader, producing two simultaneous leaders in the same term.

### Counterexample (41 steps)

```
MCHBReconfigSchedule(n1,{n1},5,2) + MCHBReconfigFinish(n1): installs config={n1} on n1
...later HBReconfigs change n1.config to {n3}...
MCBecomeLeader(n1): n1 is leader with config={n3} (n1 not in its own config!)
...
MCHBReconfigFinish(n3): n3.config={n3}
MCBecomeLeader(n3): n3 self-elects with config={n3}
```

Final state 41:
```
n1: Leader, currentTerm=1, configTerm=1, config={n3}
n3: Leader, currentTerm=1, configTerm=1, config={n3}
```

**Two leaders in term 1**.

### Affected Code

- `replication_coordinator_impl_heartbeat.cpp:_heartbeatReconfigFinish()` — no check that node is in new config
- `repl_set_config_checks.cpp:588–615` — HBReconfig skips member-present check

### Impact

Split-brain: two leaders operating simultaneously. Writes to each are not replicated to the other's quorum, leading to divergent logs and potential data loss.

---

## BUG-4: Commit Point Safety Violation in Config Swap Window

**ID**: BUG-4  
**Severity**: Critical  
**Category**: Single-Phase Membership Cutover (Family 3) / HBReconfig Safety Bypass (Family 2)  
**Invariant Violated**: `MCCommitPointSafety`  
**Configs**: MC_hunt_family3.cfg  
**References**: SERVER-45086, SERVER-55376

### Root Cause (CR1)

In `_doReplSetReconfig()`, `_setCurrentRSConfig()` (line 3997) is called **before** `updateLastCommittedInPrevConfig()` (line 4003). This creates a race window (`PostSwap` state) where:

1. New config is installed (`config[n] = newConfig`)
2. `AdvanceCommitIndex` uses the NEW config's quorum to advance the commit index
3. `SafeReconfigCaptureBarrier` captures `lastCommittedInPrevConfig = commitIndex`

If the leader then does a **second** reconfig that adds new members, those new members may not have entries committed in step 2, but `lastCommittedInPrevConfig` claims they should.

### Counterexample (30 steps)

```
BecomeLeader(n1)
SafeReconfigStart(n1,{n1})          → config in progress
AppendEntry(n1)                     → log[n1] = [{term:1,idx:1}]
SafeReconfigSwap(n1,{n1})           → config={n1}, PostSwap
AdvanceCommitIndex(n1)              → commitIndex[n1]=1 (quorum of new {n1})
AppendEntry(n1)                     → log[n1] = [{term:1,idx:1},{term:1,idx:2}]
SafeReconfigCaptureBarrier(n1)      → lastCommittedInPrevConfig[n1]=1
SafeReconfigStart(n1,{n1,n2})       → second reconfig
SafeReconfigSwap(n1,{n1,n2})        → config={n1,n2}, PostSwap
```

Final state 30:
```
n1: config={n1,n2}, lastCommittedInPrevConfig=1, commitIndex=1, log=[idx1,idx2]
n2: config={n1,n2,n3}, log=[] (EMPTY)
```

`CommitPointSafety` requires a quorum of `{n1,n2}` to have log entry 1.  
`Quorum({n1,n2}) = {{n1,n2}}` — n2.log=[] → **VIOLATION**.

### Affected Code

- `replication_coordinator_impl.cpp:3997` — `_setCurrentRSConfig()` (config swap before barrier)
- `replication_coordinator_impl.cpp:4003` — `updateLastCommittedInPrevConfig()` (barrier after swap)
- `topology_coordinator.cpp:1705–1709` — barrier capture logic

### Impact

A newly reconfigured replica set can elect a new primary that is missing committed entries. Reads at majority concern or writes with majority writeConcern can silently lose data.

---

## BUG-5: Non-Atomic Vote Persistence Allows Double Voting

**ID**: BUG-5  
**Severity**: Critical  
**Category**: Non-Atomic Vote Persistence (Family 5)  
**Invariant Violated**: `MCVoteOnce`  
**Config**: MC_hunt_family5.cfg  
**References**: replication_coordinator_impl.cpp:5325–5340; topology_coordinator.cpp:3789–3791

### Root Cause

In `HandleRequestVote`, the vote is recorded in-memory (`_lastVote` / `inMemVote`) **before** the caller (`storeLocalLastVoteDocument`) writes it to disk (`durableVote`). If the node crashes between these two operations:

1. `inMemVote` had already recorded the vote for candidate A
2. `durableVote` was NOT updated (disk write not yet issued)
3. On restart, `currentTerm` is restored from `durableVote`, which does not reflect the vote for A
4. The old RequestVoteReply(granted=TRUE) for A is still in-flight
5. The node can now grant a second vote to candidate B in the same term

Both granted-TRUE replies (for A and for B) may be in-flight simultaneously, allowing **two leaders** to win elections in the same term.

### Counterexample (19 steps)

```
MCTimeout(n3) → n3 candidate term 1
MCBecomeLeader(n3) → n3 leader, n2 voted for n3 (inMemVote updated)
[PersistVote NOT called — n2.durableVote still {term:0, for:Nil}]
MCCrash(n2)  → n2 resets: inMemVote={0,Nil}, votedFor=Nil
MCRequestVotes(n1) → n1 in term 1 asks for votes
HandleRequestVote: n2 grants vote to n1 in term 1
```

Final state 19 — messages set contains:
```
RequestVoteReply(from=n2, to=n3, term=1, granted=TRUE)  ← old, pre-crash
RequestVoteReply(from=n2, to=n1, term=1, granted=TRUE)  ← new, post-crash
```

`VoteOnce` violated: n2 sent two granted replies in term 1 to different candidates.

### Affected Code

- `topology_coordinator.cpp:3789–3791` — `_lastVote` updated in-memory before disk
- `replication_coordinator_impl.cpp:5325–5340` — `storeLocalLastVoteDocument` called outside mutex, after in-memory update

### Impact

Two candidates can simultaneously achieve quorum for the same term and both become leaders. Data written to each leader before one steps down is not replicated to the other, leading to divergent logs and data loss.

---

## Spec Fixes Applied

The following **Case B (Spec Modeling Issues)** were identified and fixed during analysis. These do not represent implementation bugs.

### Fix 1: Crash Action — Term Bump on Restart

**File**: `spec/base.tla`, `Crash(n)` action

**Problem**: The original spec set `currentTerm' = durableVote[n].term` on crash. The real MongoDB implementation (`_finishLoadLocalConfig()` lines 783–786) sets `term = max(lastVote.term, configTerm)` on restart.

**Fix applied**:
```tla
/\ currentTerm' = [currentTerm EXCEPT
       ![n] = IF configTerm[n] /= UNINITIALIZED /\ configTerm[n] > durableVote[n].term
              THEN configTerm[n]
              ELSE durableVote[n].term]
```

### Fix 2: Step-Down Does Not Reset ConfigState

**File**: `spec/base.tla`, `HandleRequestVote`, `HandleAppendEntries`, `HandleHeartbeat`

**Problem**: When a Leader received a higher-term message and stepped down to Follower, the spec kept `configState` unchanged (leaving it in `Reconfiguring` or `PostSwap`). The real MongoDB resets config state to `kConfigSteady` when stepping down.

**Fix applied**: Added `configState' = Steady` when the voter/receiver transitions to Follower via a higher-term message, for all three message handlers.

**Effect**: Eliminated the false `MCReconfigOnlyByLeader` violation in family3, which was a spec artifact. This revealed the genuine `MCCommitPointSafety` violation (BUG-4).

### Fix 3: MC.tla — Uncommented Extension Invariants

**File**: `spec/MC.tla`

**Problem**: `MCVoteOnce` and `MCCommitPointSafety` were commented out in MC.tla, causing hunt configs that referenced them to fail with "invariant not defined".

**Fix**: Uncommented both definitions.

---

## Run Log

| Config | Output File | Result | Invariant |
|--------|-------------|--------|-----------|
| MC.cfg (r1) | MC_base.out | Violation | MCConfigTermBelowElectionTerm (spec bug path) |
| MC.cfg (r2 + crash fix) | MC_base_r2.out | Violation | MCConfigTermBelowElectionTerm (BUG-1 real path) |
| MC_hunt_family1.cfg | MC_hunt_family1.out | Violation | MCElectionSafety (BUG-2) |
| MC_hunt_family1.cfg (r2) | MC_hunt_family1_r2.out | Violation | MCElectionSafety (BUG-2 confirmed) |
| MC_hunt_family2.cfg (r2) | MC_hunt_family2_r2.out | Violation | MCElectionSafety (BUG-3) |
| MC_hunt_family3.cfg (r2) | MC_hunt_family3_r2.out | Violation | MCReconfigOnlyByLeader (spec bug — fixed) |
| MC_hunt_family3.cfg (r3) | MC_hunt_family3_r3.out | Violation | MCCommitPointSafety (BUG-4) |
| MC_hunt_family4.cfg (r2) | MC_hunt_family4_r2.out | Violation | MCConfigTermBelowElectionTerm (BUG-1) |
| MC_hunt_family5.cfg (r2) | MC_hunt_family5_r2.out | Violation | MCVoteOnce (BUG-5) |
| MC_hunt_family6.cfg | MC_hunt_family6.out | Violation | MCConfigTermBelowElectionTerm (spec bug path) |
| MC_hunt_family6.cfg (r2) | MC_hunt_family6_r2.out | Violation | MCConfigTermBelowElectionTerm (BUG-1 real path) |

---

## Phase 4: Bug Confirmation Results

**Confirmation date**: 2026-06-04  
**Method**: Code audit + state-machine simulation (Level 2 state injection)  
**Full output**: `spec/confirmed-bugs.md`  
**Repair requests**: `spec/repair-requests/RR-001.md` (BUG-3), `spec/repair-requests/RR-002.md` (BUG-4)

### BUG-1 Confirmation — REPRODUCED

**Code audit findings**:
- `replication_coordinator_impl_heartbeat.cpp:372`: `_updateTerm(lk, hbResponse.getTerm())` uses only `mterm`, NOT the config's configTerm. HBReconfig can install `configTerm=X` without bumping `currentTerm`.
- `replication_coordinator_impl.cpp:~1495` (AutoReconfig): `config.setConfigTerm(primaryTerm)` sets configTerm = election term unconditionally. When `configTerm > currentTerm`, this **downgrades** configTerm.
- No safeguard prevents this downgrade. The `needBumpConfigTerm` check only skips bumping when `configTerm == kUninitializedTerm`.

**Developer intent evidence**: No developer documentation acknowledges `configTerm > currentTerm` as an expected state or a known limitation. The README describes config ordering via `(term, version)` and AutoReconfig bumping, but does not address the downgrade case.

**Reproduction**: `spec/repro/test_bug1_configterm_downgrade.py` (Level 2). State injected per MC counterexample; invariant confirmed violated; post-AutoReconfig config ordering confirmed broken (n3's VAT > n1's new VAT, so n3 rejects n1's propagated config).

**Final classification**: **REPRODUCED** (Confirmed — code path is reachable, no safeguard prevents downgrade)

---

### BUG-2 Confirmation — REPRODUCED (Known Limitation)

**Code audit findings**:
- `repl_set_config_checks.cpp:570-574`: `validateSingleNodeChange` is inside `if (!force)`, confirmed skipped for force reconfigs.
- `replication_coordinator_impl.cpp:3458-3459`: `term = (!args.force) ? currentTerm : OpTime::kUninitializedTerm` — force reconfigs use `kUninitializedTerm`.
- Two concurrent force reconfigs installing disjoint single-node configs is fully reachable; no cross-node coordination check exists.

**Developer intent evidence**: `README.md:1935` explicitly states force reconfigs are "unsafe" and exist for salvage scenarios. Split-brain is an **acknowledged trade-off** for force reconfigs. This is a known limitation, not an unintended defect. Severity downgraded from Critical to High accordingly.

**Reproduction**: `spec/repro/test_bug2_force_reconfig_split_brain.py` (Level 2). Two force reconfigs create disjoint {n1} and {n3} configs; both elect primaries in term 1; MCElectionSafety violated.

**Final classification**: **REPRODUCED** (by-design known limitation — split-brain is acknowledged for force reconfigs)

---

### BUG-3 Confirmation — FALSE POSITIVE → PENDING REPAIR (RR-001)

**Code audit findings**:
Two safeguards prevent the counterexample scenario:
1. `_shouldStepDownOnReconfig` (heartbeat.cpp): when a primary receives an HBReconfig that excludes it, the function returns `true` and triggers an unconditional step-down **before** `_setCurrentRSConfig` installs the new config.
2. `selfIndex=-1` guard: after HBReconfig excludes the node, `selfIndex` is set to `-1`. `processReplSetRequestVotes` returns `ErrorCodes::InvalidReplicaSetConfig` when `_selfIndex == -1`, preventing elections.

The counterexample requires `BecomeLeader(n1)` when `n1 ∉ config[n1]` — structurally impossible in the real code.

**Developer intent evidence**: `_shouldStepDownOnReconfig` is the explicit handling for "primary not in new config." The safeguard is intentional.

**Reproduction**: `spec/repro/test_bug3_hbreconfig_excludes_leader.py` — safeguards prevent the scenario. State injection shows that after HBReconfig to `{n3}`, n1 steps down and gets `selfIndex=-1`, unable to run for election.

**Spec issue**: `BecomeLeader(n)` lacks the precondition `n ∈ config[n]`, allowing the spec to model a state that the real code's `selfIndex` check prevents.

**Final classification**: **PENDING REPAIR (RR-001)** — spec needs `n ∈ config[n]` precondition on `BecomeLeader`.

---

### BUG-4 Confirmation — FALSE POSITIVE → PENDING REPAIR (RR-002)

**Code audit findings**:
The `_setCurrentRSConfig` (line 4037) and `updateLastCommittedInPrevConfig` (line 4065) calls both hold `_mutex` (`WithLock lk`) throughout. Developer comment at line 4062: *"Once we have acquired the replication mutex above, we are ensured that no new writes will be committed in the previous config."* `AdvanceCommitIndex` requires the same mutex; it cannot interleave between lines 4037 and 4065.

Additionally, `awaitReplication(configOplogCommitmentOpTime)` at line 4161 blocks until a quorum of the new config has replicated all committed entries — preventing the second reconfig from starting until the first is fully committed.

**Developer intent evidence**: Developer comment at line 4062 explicitly describes the mutex guarantee. `awaitReplication` is the documented mechanism for config oplog commitment.

**Reproduction**: `spec/repro/test_bug4_commit_barrier_race.py` — mutex audit confirms atomicity; `awaitReplication` audit confirms second guard.

**Spec issue**: `SafeReconfigSwap` and `SafeReconfigCaptureBarrier` are separate interleave-able TLA+ actions; the real mutex makes them atomic. Missing: mutex variable or merged action.

**Final classification**: **PENDING REPAIR (RR-002)** — spec needs `SafeReconfigSwap` + `SafeReconfigCaptureBarrier` merged into one atomic action.

---

### BUG-5 Confirmation — REPRODUCED

**Code audit findings**:
- `topology_coordinator.cpp:3789-3791`: `_lastVote.setTerm` / `setCandidateIndex` run inside `processVoteRequestV1` while `_mutex` is held.
- `replication_coordinator_impl.cpp:5417-5423`: Code comment says "It's safe to store lastVote outside of _mutex" (addressing thread-race only, not crash recovery). `storeLocalLastVoteDocument` is called **after** the mutex is released and **after** the `RequestVoteReply` has been buffered.
- **Crash window**: Between the mutex-release (in-memory `_lastVote` updated, reply in flight) and `storeLocalLastVoteDocument` completing. No safeguard detects or recovers from a crash in this window.

**Developer intent evidence**: The comment explicitly addresses "threads racing to store votes from different terms" but NOT crash recovery. The comment represents an incomplete safety analysis. No test covers the crash-in-vote-window scenario.

**Reproduction**: `spec/repro/test_bug5_double_vote.py` (Level 2). Crash-recovery double-vote scenario: n2 votes for n3 in-memory, crashes before disk write, restarts with stale `durableVote={term:0}`, votes for n1 in term 1. Both granted replies are in-flight simultaneously. MCVoteOnce violated.

**Final classification**: **REPRODUCED** (Confirmed — code path is reachable, no safeguard prevents double voting across crash boundary)
