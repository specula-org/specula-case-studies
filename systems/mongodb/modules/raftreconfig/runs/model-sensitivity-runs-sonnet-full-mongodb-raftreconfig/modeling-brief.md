# Modeling Brief: MongoDB Replica-Set Reconfiguration

**Target**: mongodb-raftreconfig  
**Language**: C++  
**Repository**: mongodb/mongo  
**Core files**: `src/mongo/db/repl/` (~15 files, ~15k LOC of core reconfig logic)  
**Date**: 2026-06-04

---

## 1. System Overview

MongoDB replica sets implement a Raft-variant consensus protocol with leader-driven reconfiguration. The system is **Category A (Distributed / Message-Passing)**: the primary risks are protocol-level safety violations, crash recovery windows, and message-handling inconsistencies.

The reconfiguration protocol is a **single-phase logless reconfig** (not joint consensus). Safety relies on three preconditions before a new config is installed: (1) the current config must be majority-committed, (2) the oplog must be committed up to `lastCommittedInPrevConfig`, and (3) a quorum check (heartbeat round) must confirm reachability. After installation, all quorum calculations immediately switch to the new member set.

Key architectural deviations from canonical Raft:
- **No joint consensus**: membership switches atomically in one step.
- **Config identified by `(configVersion, configTerm)` not just `configTerm`**: force reconfigs set `configTerm=-1` (sentinel), causing a non-total ordering when mixed with normal configs.
- **Two reconfig paths**: leader-driven (with full safety checks) and heartbeat-driven (version/term check only, weaker validation).
- **Step-up auto-reconfig**: a newly elected primary immediately re-issues the current config with its election term as the configTerm.
- Concurrency model: mutex-guarded state machine with executor-scheduled async callbacks; heartbeat loop is independent of the main replication coordinator event loop.

---

## 2. Bug Families

### Family 1: ConfigVersionAndTerm Non-Total Ordering Under Force Reconfig

**Mechanism**: Force reconfig sets `configTerm = kUninitializedTerm (-1)`. The `ConfigVersionAndTerm::operator<` falls back to version-only comparison when either operand has `term=-1`. This makes the ordering non-transitive for mixed force/normal configs: a force-reconfigured node (high version, term=-1) and a normally-reconfigured node (lower version, known term) can each appear "better" depending on which is the left operand. Downstream protocol decisions (vote eligibility, heartbeat-triggered config adoption, safe-reconfig commitment check) branch on this comparison.

**Evidence**:
- Historical: SERVER-47119 — config term stays `-1` after force reconfig until a manual `replSetReconfig` is issued; step-up auto-reconfig fails when configTerm is still uninitialized
- Historical: SERVER-47636 — concurrent force reconfig during drain mode crashes primary with invariant because configTerm=-1 config bypasses `canAcceptNonLocalWrites` guard
- Code analysis: `repl_set_config.h:76-129` — `operator<` with term=-1 shortcut; `replication_coordinator_impl.cpp:3425` — force sets term to `kUninitializedTerm`; `vote_requester.cpp:96-124` — configTerm omitted from vote request when=-1

**Affected code paths**:
- `TopologyCoordinator::processReplSetRequestVotes` (config eligibility check)
- `_scheduleHeartbeatReconfig` (version/term comparison to decide whether to adopt)
- `_doReplSetReconfig` (safe-reconfig commitment check skipped for `leavingForceConfig`)
- `VoteRequester::Algorithm::prepareRequests` (conditional omission of configTerm)

**Suggested modeling approach**:
- Variables: `configVersion[n]`, `configTerm[n]` per node (term=-1 is a distinct sentinel, not just "0")
- Actions: `ForceReconfig(n)` sets `configTerm[n] := UNINITIALIZED`; `SafeReconfig(n)` sets `configTerm[n] := currentTerm[n]`
- Granularity: Model `ConfigLess(a, b) = IF a.term = UNINITIALIZED OR b.term = UNINITIALIZED THEN a.version < b.version ELSE (a.term < b.term) OR (a.term = b.term AND a.version < b.version)`; verify the predicate remains antisymmetric under mixed configs

**Priority**: High  
**Rationale**: Three confirmed production bugs; term=-1 sentinel propagates across vote requests, heartbeat config adoption, and safe-reconfig preconditions — a single common mechanism with multiple observed failure modes.

---

### Family 2: Dual Reconfig Paths With Asymmetric Safety Gates

**Mechanism**: Leader-driven reconfig enforces: (a) current config majority-committed, (b) oplog committed up to `lastCommittedInPrevConfig`, (c) single-node-change limit, (d) quorum reachability check. Heartbeat-driven reconfig enforces: only `newConfig.ConfigVersionAndTerm > current`. A config that would be rejected by the safe path (e.g., adds 2 voting members, violates PSA overlap, arrives during force-reconfig state) can be installed via heartbeat once it exists anywhere in the cluster. The two paths share a config-state mutex (`kConfigReconfiguring` / `kConfigHBReconfiguring`) that provides mutual exclusion but not equivalent safety guarantees.

**Evidence**:
- Historical: SERVER-47949 — primary installs higher config via heartbeat during drain mode, breaking the subsequent step-up auto-reconfig
- Historical: SERVER-46897 — REMOVED node stuck because heartbeat reconfig is silently dropped when state is `kConfigHBReconfiguring`; no retry scheduled
- Historical: SERVER-48776 — quorum check spuriously fails when concurrent election installs a config with higher configVersionAndTerm during the check
- Code analysis: `repl_set_config_checks.cpp:588-615` — heartbeat reconfig skips `validateSingleNodeChange`, `validateArbiterPriorities`, `validateOldAndNewConfigsCompatible`; `replication_coordinator_impl_heartbeat.cpp:689-698` — HB reconfig silently dropped when `kConfigReconfiguring` is active

**Affected code paths**:
- `_scheduleHeartbeatReconfig` / `_heartbeatReconfigStore` / `_heartbeatReconfigFinish`
- `_doReplSetReconfig` / `checkQuorumForReconfig`
- Config state machine transitions in `ReplicationCoordinatorImpl`

**Suggested modeling approach**:
- Variables: `configState[n] ∈ {Steady, Reconfiguring, HBReconfiguring}`
- Actions: Two distinct `Reconfig` actions — `SafeReconfig(n, newCfg)` with full preconditions; `HBReconfig(n, newCfg)` with only version/term ordering precondition
- Granularity: HBReconfig is a single atomic action (no quorum check step); SafeReconfig is split into `QuorumCheck → PersistConfig → InstallConfig` steps to expose the race window

**Priority**: High  
**Rationale**: At least 3 confirmed bugs; the asymmetry is structural and deliberate, but the implicit trust assumption (HB-delivered configs were already safe-validated by the leader) fails under force reconfig and leadership changes.

---

### Family 3: Single-Phase Membership Cutover and Commit-Point Safety Barrier

**Mechanism**: MongoDB uses a single-phase reconfig without joint consensus. When `_setCurrentRSConfig` installs the new config, all quorum calculations switch to the new member set immediately. The safety relies on two barriers computed just before install: (a) `_lastCommittedInPrevConfig` (the commit point at the moment of the old config's last majority write) and (b) `getConfigOplogCommitmentOpTime = max(lastCommittedInPrevConfig, firstOpTimeOfMyTerm)`. If these barriers are stale or mis-ordered relative to config install, a new majority can form that excludes committed entries.

**Evidence**:
- Historical: SERVER-45086 — `lastCommittedInPrevConfig` was not recorded before installing the new config; safety barrier was effectively empty
- Historical: SERVER-55376 — PSA reconfig that reduces a secondary's votes + restores them enables a stale secondary to win election with arbiter, rolling back committed writes
- Code analysis: `replication_coordinator_impl.cpp:3997` (`_setCurrentRSConfig`) called **before** `updateLastCommittedInPrevConfig` at line 4003; heartbeats under the new config can fire in the window between these two lines
- Code analysis: `topology_coordinator.cpp:1705-1709` — barrier = `max(_lastCommittedInPrevConfig, _firstOpTimeOfMyTerm)` with no atomic update ordering guarantee

**Affected code paths**:
- `_finishReplSetReconfig`: lines 3997 → 4003 ordering
- `TopologyCoordinator::updateLastCommittedInPrevConfig` / `getConfigOplogCommitmentOpTime`
- `updateLastCommittedOpTimeAndWallTime` (switches voter set atomically with config install)

**Suggested modeling approach**:
- Variables: `lastCommittedInPrevConfig[n]`, `firstOpTimeOfMyTerm[n]`, `configInstalledAtOptime[n]`
- Actions: Split `InstallConfig(n)` into `CaptureCommitPoint(n)` → `SwapConfig(n)`; introduce a `CommitPointAdvance(n)` action that can fire between them
- Invariant: After any reconfig, every entry in the new majority's log that is tagged committed must also be present in every member of any subsequently elected majority

**Priority**: High (Critical)  
**Rationale**: Two safety-critical bugs (potential data loss / write rollback); the barrier mechanism is non-trivially correct and its correctness depends on the ordering of `_setCurrentRSConfig` vs `updateLastCommittedInPrevConfig` which are currently in the wrong order in the code.

---

### Family 4: Voting Eligibility Under Config Version/Term Constraints

**Mechanism**: The rule for whether a node grants a vote has changed multiple times. The current rule (as of SERVER-57262) allows voting for candidates with `configVersionAndTerm >= self`. The prior strict rule (SERVER-46387: only same config) caused an availability deadlock: a primary stuck in catchup cannot update its configTerm, but catchup-takeover requires that primary's vote, which the primary cannot grant to a candidate with a higher configTerm. The current relaxed rule creates a model state where a node can vote for a candidate using a config the voter has never seen.

**Evidence**:
- Historical: SERVER-46387 — strict same-config voting rule; fixed crash on selfIndex=-1
- Historical: SERVER-57262 — relaxed to ">= self" to resolve availability deadlock; MongoDB team validated this with TLA+ before merging
- Historical: SERVER-47613 — crash when selfIndex=-1 after network failure during heartbeat reconfig; same root cause as SERVER-46387
- Code analysis: `topology_coordinator.cpp:3747-3752` — config check before term check; `vote_requester.cpp:97-112` — configTerm omitted from request when self term=-1; `topology_coordinator.cpp:3747` — voters with newer config can still vote yes

**Affected code paths**:
- `TopologyCoordinator::processReplSetRequestVotes`
- `VoteRequester::Algorithm::prepareRequests` / `processResponse`
- `ElectionState::_onDryRunComplete` / `_onVoteRequestComplete`

**Suggested modeling approach**:
- Variables: `configVersionAndTerm[n]` per node, `lastVote[n]`, `votedFor[n]`
- Actions: `RequestVote(candidate, voter)` with message `{term, configVAT}`; voter applies rule `configVAT >= self.configVAT AND term >= self.term`
- Invariant: `ElectionSafety` — no two leaders in same term; verify it holds under the relaxed ">=" rule with mixed force/normal config orderings

**Priority**: High  
**Rationale**: MongoDB's own team needed TLA+ to resolve the SERVER-46387/57262 tension; the current fix has a known open question: does the relaxed rule preserve `ElectionSafety` when combined with force-reconfig configTerm=-1 non-total ordering?

---

### Family 5: Non-Atomic Vote Persistence

**Mechanism**: In `processReplSetRequestVotes`, the in-memory last-vote record (`TopologyCoordinator::_lastVote`) is advanced before the caller persists it durably. If the node crashes between the in-memory update and the durable write, it restarts with the old vote and may vote again in the same term.

**Evidence**:
- Code analysis: `replication_coordinator_impl.cpp:5325-5340` — comment "Note the topology coordinator has already advanced its last vote at this point"; `storeLocalLastVoteDocument` called outside the mutex after in-memory update
- Code analysis: `topology_coordinator.cpp:3789-3791` — `_lastVote` updated in `processReplSetRequestVotes` before caller persists

**Affected code paths**:
- `ReplicationCoordinatorImpl::processReplSetRequestVotes`
- `TopologyCoordinator::processReplSetRequestVotes`
- `ReplicationCoordinatorExternalStateImpl::storeLocalLastVoteDocument`

**Suggested modeling approach**:
- Variables: `inMemVote[n]`, `durableVote[n]` (initially equal)
- Actions: `GrantVoteInMemory(n)` sets `inMemVote[n]`; `PersistVote(n)` copies to `durableVote[n]`; `Crash(n)` resets `inMemVote[n] := durableVote[n]`
- Invariant: No candidate receives votes from more than one majority-sized set of nodes in the same term

**Priority**: Medium  
**Rationale**: Classic Raft non-atomicity; likely intentional design with acknowledged comment. The crash window is small. Lower priority than Families 1-4 because MongoDB's protocol relies on the write concern majority for the oplog (which is crash-safe) not the vote persistence, as the primary safety guarantee.

---

### Family 6: Step-Up Auto-Reconfig Config Term Initialization Race

**Mechanism**: When a primary wins an election, it must immediately issue a "step-up reconfig" that bumps the configTerm to its election term. This auto-reconfig is a separate async operation that can be preempted by a concurrent force reconfig or heartbeat reconfig that installs a different config (with a potentially inconsistent configTerm). If preempted, the primary's configTerm remains at the old term or at -1, breaking the invariant that a primary's configTerm equals its election term.

**Evidence**:
- Historical: SERVER-47119 — configTerm stays -1 because step-up auto-reconfig only fires when configTerm is already initialized
- Historical: SERVER-47949 — heartbeat reconfig during drain mode preempts step-up auto-reconfig
- Historical: SERVER-47636 — force reconfig during drain mode races with step-up auto-reconfig
- Code analysis: `replication_coordinator_impl.cpp:1468-1514` — auto-reconfig is "best effort" with non-fatal error on preemption; `1484-1487` — ConfigVersionAndTerm snapshot check; `1504-1512` — `ConfigurationInProgress` is non-fatal

**Affected code paths**:
- `ReplicationCoordinatorImpl::_reconfigToCSRSIfNeeded` / draining completion callback
- `_doReplSetReconfig` (auto-reconfig variant)

**Suggested modeling approach**:
- Actions: `WinElection(n)` → `BecomePrimary(n)` → (non-atomic) `AutoReconfig(n)` that can be preempted
- Variables: `autoReconfigPending[n]` boolean
- Invariant: Eventually, every primary has `configTerm[n] = currentTerm[n]` (liveness); immediately after election, `configTerm[n]` may lag

**Priority**: Medium  
**Rationale**: Three bugs in this pattern but all fixed. The auto-reconfig best-effort design is intentional. The open question is whether the non-atomic step-up sequence can combine with Family 1 (non-total ordering) to produce a state where two nodes believe they are primary with different configTerms simultaneously.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| `ConfigVersionAndTerm` non-total ordering | Family 1: three bugs, sentinel propagation | Add `IsForceConfig(cfg)` predicate; define `ConfigLess` with special case |
| Dual reconfig paths (safe + HB) | Family 2: structural asymmetry; HB path skips safety gates | Two `Reconfig` actions with different precondition sets |
| Explicit `configState` variable | Families 2, 6: state machine governs which path can fire | `configState[n] ∈ {Steady, Reconfiguring, HBReconfiguring}` |
| `lastCommittedInPrevConfig` barrier | Family 3: installed before vs. after config swap matters | Separate `CaptureBarrier` action from `SwapConfig` action |
| Relaxed vote-eligibility rule | Family 4: MongoDB TLA+ fix; open question with force configs | `VoteGranted(voter, req) ⟺ req.configVAT >= voter.configVAT AND req.term >= voter.term` |
| Crash-and-recover | Families 3, 5: crash windows are primary safety vectors | `Crash(n)` action resets in-memory state; persistent state (durableConfig, durableVote) survives |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| RSTL (Replication State Transition Lock) | Internal locking mechanism, not protocol-level. Abstract as a binary "write-gate" flag. |
| Heartbeat scheduling timing | Heartbeat interval and jitter are performance concerns; abstract to "eventually delivers" |
| Force reconfig version randomization (`+10000 + random`) | Implementation detail of version bump; model as "version advances past all known versions" |
| `writeConcernMajorityJournalDefault` | Orthogonal to membership/reconfig safety; journal durability is a separate concern |
| Self-identification DNS resolution | Network-layer artifact; abstract node identity as always-known |
| Driver-side RSM configVersion tracking | Client-visible availability issue (SERVER-59409); not a server-side safety property |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Force-config sentinel | `configTerm[n]` with `UNINITIALIZED` value | Track which nodes have force-reconfigured config | Family 1 |
| Dual reconfig action | `configState[n]` | Distinguish SafeReconfig vs HBReconfig code paths | Family 2 |
| Commit-point barrier capture | `lastCommittedInPrevConfig[n]` | Track barrier captured before vs. after config swap | Family 3 |
| Persistent vote store | `durableVote[n]`, `inMemVote[n]` | Model non-atomic vote persistence | Family 5 |
| Auto-reconfig pending flag | `autoReconfigPending[n]` | Track step-up reconfig not yet committed | Family 6 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `ElectionSafety` | Safety | No two leaders in same term | Families 1, 4 |
| `LogMatching` | Safety | If two logs agree on `(index, term)`, they agree on all prior entries | Family 3 |
| `ConfigMonotonicity` | Safety | Installed configVersionAndTerm never decreases on a node (except crash) | Families 1, 2, 6 |
| `CommitPointSafety` | Safety | No entry marked committed under old config is absent from all members of any new majority | Family 3 |
| `ConfigTermBelowElectionTerm` | Safety | A leader's configTerm ≤ its election term (configTerm catches up; never exceeds term) | Family 6 |
| `VoteOnce` | Safety | No node grants more than one vote per term (including post-crash) | Family 5 |
| `LeaderConfigCurrentness` | Liveness | Eventually, every primary has `configTerm = electionTerm` | Family 6 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC1 | Can a node install via HBReconfig a config that excludes a member whose writes were committed under the old config, without the CommitPointSafety barrier being checked? | `CommitPointSafety` | Family 2, 3 |
| MC2 | Under the relaxed ">= configVAT" vote rule, can two primaries be elected in the same term when a force-reconfigured node (configTerm=-1) is involved in both elections? | `ElectionSafety` | Families 1, 4 |
| MC3 | If `CaptureBarrier` runs after `SwapConfig` (wrong order), can a new majority form that lacks an entry committed under the old config? | `CommitPointSafety` | Family 3 |
| MC4 | Can a step-up auto-reconfig preemption (by concurrent HBReconfig) leave the system in a state where a primary exists with `configTerm != electionTerm` indefinitely (liveness failure)? | `LeaderConfigCurrentness` | Family 6 |
| MC5 | Can a voter with the old config version grant a vote to a candidate whose new config excludes a node with committed writes, if that candidate's configVAT is >= voter's? | `CommitPointSafety`, `ElectionSafety` | Families 3, 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV1 | `_heartbeatReconfigFinish` assertion fires if `kConfigHBReconfiguring` → concurrent user reconfig → `kConfigSteady` before callback runs | Integration test: inject artificial delay in `_heartbeatReconfigStore`; fire user reconfig concurrently |
| TV2 | Force reconfig version randomization collision: two concurrent force reconfigs produce same version | Unit test with seeded PRNG; verify version monotonicity invariant |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `_setCurrentRSConfig` (line 3997) called before `updateLastCommittedInPrevConfig` (line 4003) — ordering inversion | Review whether any heartbeat action or commit-point advance can interleave in this gap; consider swapping call order |
| CR2 | `updatePosition` command omits `configTerm` (topology_coordinator.cpp:2395) — progress tracking uses version only | Assess whether a version collision between force-reconfig config and normal config causes incorrect majority commit-point advances |
| CR3 | Heartbeat sender-index lookup uses `configVersion` only (topology_coordinator.cpp:1043) but return value uses `configVersionAndTerm` (line 1056) — internal inconsistency within the same function | Fix: use `configVersionAndTerm` for the sender-index lookup |
| CR4 | Double `arsd.emplace` in `_finishReplSetReconfig` (lines 3941, 3946) — RSTL acquired then destroyed and re-acquired for step-down | Review for correctness; appears to invoke step-down twice |
| CR5 | `SERVER-30852` TODO in `_setLeaderMode` state machine — `kNotLeader` from `kLeaderElect` is acknowledged as an invalid transition | Track removal of this shortcut; verify no code path silently swallows an election result |

---

## 7. Reference Pointers

**Source files** (all under `artifact/mongo-src/src/mongo/db/repl/`):
- `replication_coordinator_impl.cpp` — main reconfig entry point; lines 3412–4078
- `topology_coordinator.cpp` — config install, quorum, vote processing; lines 1043, 1705, 2611, 3143, 3747
- `replication_coordinator_impl_heartbeat.cpp` — heartbeat reconfig path; lines 674–1053
- `check_quorum_for_config_change.cpp` — quorum check; lines 64–346
- `repl_set_config_checks.cpp` — validation; lines 542–615
- `repl_set_config.h` — ConfigVersionAndTerm ordering; lines 76–129
- `vote_requester.cpp` — vote request construction; lines 83–199
- `replication_coordinator_impl_elect_v1.cpp` — election state machine; lines 140, 179
- `replication_coordinator_impl_step_up_step_down.cpp` — stepdown concurrency; lines 238–318

**GitHub issues / Jira**:
- SERVER-45086 — lastCommittedInPrevConfig barrier (safety critical, fixed)
- SERVER-55376 — PSA reconfig write rollback (safety critical, fixed)
- SERVER-47206 — majority commit point not reset after force reconfig (OPEN)
- SERVER-57262 — relaxed vote eligibility rule (TLA+ validated by MongoDB team)
- SERVER-46387 — strict config vote rule causing crash (fixed; reverted by 57262)
- SERVER-47119 / 47636 / 47949 — configTerm initialization race cluster (fixed)
- SERVER-46897 — REMOVED node stuck (fixed)
- SERVER-48776 — spurious quorum check failure during concurrent election (fixed)

**Reference algorithm**:
- "Logless Reconfiguration" paper by Shi et al. (MongoDB internal blog: "Rapid Prototyping Safe Logless Reconfiguration with TLA+")
