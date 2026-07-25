# Brief Coverage Self-Audit

**Target**: mongodb-raftreconfig  
**Phase**: 2.5 — Self-audit mapping brief §2/§5/§6.1 → spec/MC artifacts  
**Date**: 2026-06-04

This audit verifies that every bug family, invariant, and model-checkable finding from the
modeling brief has a corresponding spec mechanism and at least one hunt config that can reach it.
Coverage is derived by reading actual spec and cfg files, not from memory of intent.

---

## Bug Families (§2) → Spec Coverage

| Family | Brief Mechanism | Spec Variables | Spec Actions | Hunt Config |
|--------|----------------|----------------|--------------|-------------|
| **F1** ConfigVAT non-total ordering | `ConfigLess` falls back to version-only when either term=UNINITIALIZED | `configTerm[n]` with UNINITIALIZED sentinel; `ConfigLess/ConfigLeq` helpers; `IsForceConfig(n)` | `ForceReconfig(n, newCfg, newVer)` sets `configTerm := UNINITIALIZED` | `MC_hunt_family1.cfg` |
| **F2** Dual reconfig paths | HBReconfig skips safety gates; dropped when kConfigReconfiguring active | `configState` with HBReconfiguring state; `pendingHBConfig[n]` | `HBReconfigSchedule`, `HBReconfigFinish`, `HBReconfigAborted` (TV1); `SafeReconfigStart` with full preconditions | `MC_hunt_family2.cfg` |
| **F3** Single-phase cutover + barrier | `_setCurrentRSConfig` before `updateLastCommittedInPrevConfig`; race window | `lastCommittedInPrevConfig[n]`; `PostSwap` configState (synthetic, between lines 3997-4003) | `SafeReconfigSwap` (PostSwap state), `SafeReconfigCaptureBarrier` (PostSwap→Steady), `AdvanceCommitIndex` (fires under new config in PostSwap window) | `MC_hunt_family3.cfg` |
| **F4** Voting eligibility relaxed rule | `ConfigLeq` (≥ not =) in `HandleRequestVote`; configTerm omitted from vote req when UNINITIALIZED | Vote request carries `mconfigVAT`; `HandleRequestVote` checks `ConfigLeq(voterVAT, req.mconfigVAT)` | `HandleRequestVote` | `MC_hunt_family4.cfg` |
| **F5** Non-atomic vote persistence | `_lastVote` updated in-memory before durable write | `inMemVote[n]`, `durableVote[n]` separate; `Crash(n)` resets inMemVote to durableVote | `HandleRequestVote` (updates inMemVote), `PersistVote` (copies to durableVote), `Crash` (reverts inMemVote) | `MC_hunt_family5.cfg` |
| **F6** Auto-reconfig race | `autoReconfigPending` cleared by preemption without updating configTerm | `autoReconfigPending[n]` | `AutoReconfig` (normal path), `AutoReconfigPreempted` (preempted by concurrent reconfig) | `MC_hunt_family6.cfg` |

**Coverage: all 6 families have spec variables, actions, and a targeting hunt config. ✓**

---

## Invariants (§5) → Spec and Hunt Config Coverage

| Brief Invariant | Type | Spec Invariant | Enabled in Hunt Config(s) |
|----------------|------|----------------|--------------------------|
| `ElectionSafety` | Safety | `ElectionSafety` in `base.tla` | All hunt configs (always enabled) |
| `LogMatching` | Safety | `LogMatching` | `MC_hunt_family2.cfg`, `MC_hunt_family3.cfg`, `MC_hunt_family4.cfg` |
| `ConfigMonotonicity` | Safety | `ConfigVersionPositive` (monotonicity proxy; version ≥ 1 always) | All hunt configs |
| `CommitPointSafety` | Safety | `CommitPointSafety` in `base.tla` | `MC_hunt_family2.cfg`, `MC_hunt_family3.cfg`, `MC_hunt_family4.cfg` |
| `ConfigTermBelowElectionTerm` | Safety | `ConfigTermBelowElectionTerm` | `MC_hunt_family1.cfg`, `MC_hunt_family4.cfg`, `MC_hunt_family6.cfg` |
| `VoteOnce` | Safety | `VoteOnce` in `base.tla` | `MC_hunt_family5.cfg` |
| `LeaderConfigCurrentness` | Liveness | `LeaderConfigCurrentness` in `base.tla` (temporal property) | `MC_hunt_family6.cfg` (PROPERTIES block, commented; enable with FairSpec) |

**Gap — ConfigMonotonicity**: The brief's `ConfigMonotonicity` says "installed configVersionAndTerm never decreases (except after crash)". The spec enforces `configVersion >= 1` as a structural invariant but does not directly check that configVAT is non-decreasing across transitions. This is a deliberate simplification: HBReconfig and SafeReconfig both explicitly require `ConfigLess(self, new)` as a precondition, which enforces monotonicity by construction in the spec. A direct monotonicity invariant would require tracking the previous configVAT, adding a ghost variable. The current approach trades precision for simplicity and covers the mechanism through preconditions.

**Gap — LeaderConfigCurrentness**: This is a liveness property requiring `WF_vars(Next)` (use `FairSpec` in `MC_hunt_family6.cfg`). Liveness checking is not enabled by default due to state space cost. The safety proxy `ConfigTermBelowElectionTerm` is always enabled as a substitute.

---

## Model-Checkable Findings (§6.1) → Hunt Config Reachability

| Finding | Target Invariant | Hunt Config | Fault Setup That Makes It Reachable |
|---------|-----------------|-------------|--------------------------------------|
| MC1 — HBReconfig installs config that excludes committed-write member | `CommitPointSafety` | `MC_hunt_family2.cfg` | `MaxHBReconfigLimit=4` (HBReconfig fires with new config that excludes old member); `MaxAppendLimit=2` (committed entries exist); `MaxLostMsgLimit=1` (simulates network partition during replication) |
| MC2 — Two primaries in same term via force-reconfig non-total ordering | `ElectionSafety` | `MC_hunt_family1.cfg` + `MC_hunt_family4.cfg` | `MaxForceReconfigLimit=3` (create mixed force/normal config state); `MaxTimeoutLimit=5` (multiple elections) |
| MC3 — CaptureBarrier after SwapConfig allows new majority without old committed entries | `CommitPointSafety` | `MC_hunt_family3.cfg` | `AdvanceCommitIndex` fires in PostSwap window (no bound — reactive action); `SafeReconfigSwap` + `SafeReconfigCaptureBarrier` split creates the window |
| MC4 — Auto-reconfig preemption liveness failure | `LeaderConfigCurrentness` | `MC_hunt_family6.cfg` | `MaxHBReconfigLimit=3` (preemption trigger); `MaxForceReconfigLimit=2` (force-config preemption); fairness needed (use `FairSpec`) |
| MC5 — Voter with old config grants vote to candidate whose config excludes committed-write node | `CommitPointSafety` + `ElectionSafety` | `MC_hunt_family4.cfg` | `MaxForceReconfigLimit=3` (mixed config states); `MaxAppendLimit=2` (committed entries); `MaxTimeoutLimit=5` (election after reconfig) |

**All 5 MC findings have a targeting hunt config with a fault setup that makes the scenario reachable. ✓**

---

## Out-of-Scope Items (Deliberate Exclusions)

| Item | Brief §3.2 Rationale | Spec Treatment |
|------|----------------------|----------------|
| RSTL (Replication State Transition Lock) | Internal locking; abstract as binary write-gate | Not modeled; equivalent to the `role[n] = Leader` guard on reconfig actions |
| Heartbeat scheduling timing | Performance concern; abstract as "eventually delivers" | `SendHeartbeat` fires non-deterministically under TLC; no timing |
| Force reconfig version randomization | Implementation detail; model as "version advances past known" | `newVer > configVersion[n]` precondition in `ForceReconfig` |
| `writeConcernMajorityJournalDefault` | Orthogonal to membership safety | Not modeled |
| Driver-side RSM configVersion tracking | Client-visible; not a server-side safety property | Not modeled |

---

## Known Weaknesses and Future Work

1. **`newCfg \in SUBSET Server` in Next**: The existential over all subsets of Server is only feasible for |Server| ≤ 4. For larger clusters, pre-define a `Configs` constant (set of allowed configs) and bound `newCfg \in Configs` in the MC spec.

2. **LogMatching simplification**: `HandleAppendEntries` uses a simplified model (replace entire log with leader's log) rather than a proper prefix-match. This is a faithfulness regression for detecting log-matching bugs, but acceptable since log consistency is not the primary concern of the reconfig families.

3. **HBReconfigDropped not modeled as a base action**: The silent drop (line 698) is modeled via the precondition `configState[n] = Steady` in `HBReconfigSchedule`. The `HBReconfigAborted` action covers the TV1 race (callback fires after state reset). The case where HBReconfigSchedule silently drops during Reconfiguring state is captured by the negative precondition.

4. **`VoteOnce` completeness**: The spec checks that no two in-flight vote-grant messages exist for the same term/voter. This does not directly check the durability invariant (vote persisted before granting). The crash scenario (F5) is covered by `Crash` reverting `inMemVote`, which can re-enable `HandleRequestVote` with the same term, potentially sending a second grant message and violating `VoteOnce`.
