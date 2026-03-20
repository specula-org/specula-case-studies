# Modeling Brief: rethinkdb/rethinkdb

## 1. System Overview

- **System**: rethinkdb/rethinkdb — C++ distributed document database with per-table Raft consensus
- **Language**: C++ (template-heavy), ~3,089 LOC core Raft logic
- **Protocol**: Raft (Ongaro 2014) with joint consensus config changes (Section 6)
- **Key architectural choices**:
  - **Virtual heartbeats**: Start/stop messages replace periodic AppendEntries; failure detection delegated to transport layer (`raft_core.hpp:44-48`)
  - **Persisted commit_index**: Prevents state machine regression on crash (`raft_core.hpp:363-366`)
  - **No PreVote**: Uses `watchdog_leader_only` timer to suppress disruptive elections (`raft_core.tcc:431-440`)
  - **Leaders accept RequestVote** from config members — workaround because virtual heartbeats have no reply channel
  - **Async term transitions**: `candidate_or_leader_note_term` spawns a separate coroutine to step down (`raft_core.tcc:1993`)
- **Concurrency model**: Cooperative coroutines with single `new_mutex_t`; mutex released during RPC sends and condition waits, allowing interleaving

## 2. Bug Families

### Family 1: Virtual Heartbeat Architecture (HIGH)

**Mechanism**: Virtual heartbeats (start/stop messages) replace real AppendEntries heartbeats. This creates three distinct gaps: (a) followers don't learn commit index from heartbeats, (b) leader cannot learn higher terms from heartbeat rejection (no reply channel), (c) election timeout depends on transport-layer failure detection, not Raft-layer timing.

**Evidence**:
- Historical: Bug `4093d396c5` — leader treated own virtual heartbeat as follower heartbeat
- Historical: Bug `1df78072b5` — leader rejected ALL RequestVote RPCs, couldn't discover higher terms (workaround: leaders now accept RequestVote from members)
- Historical: Bug `238f9d49ee` — watchdog blockers not reset on term change → elections suppressed after leader gone
- Historical: Bug `5ab7736236` — duplicate `on_connected_members_change` callback → assertion crash
- Issue #4357 (OPEN): non-transitive connectivity prevents failover (transport-dependent detection)
- Code analysis: `raft_core.tcc:1401-1408` — virtual heartbeats carry no commit index
- Code analysis: `raft_core.tcc:906-914` — no reply channel for virtual heartbeat rejection

**Affected code paths**:
- `on_connected_members_change()` (lines 888-953)
- `on_rpc_from_leader()` watchdog blocking (lines 957-1031)
- `leader_send_updates()` commit tracking (lines 1719-1725)
- `candidate_and_leader_coro()` `send_virtual_heartbeats` (lines 1401-1415)

**Suggested modeling approach**:
- Variables: `virtualHeartbeat[Server -> {none, active(term)}]`, `transportConnected[Server -> Server -> BOOLEAN]`
- Actions: Split leader announcement into `StartVirtualHeartbeat` (one-time) and `DetectDisconnection` (transport-level, delayed). Model `AdvanceCommitViaAppendEntries` separately from heartbeat.
- Key: model transport failure detection as a separate, delayed event from actual network partition

**Priority**: High
**Rationale**: 4 historical bugs + 1 open issue + 3 code-analysis findings. The virtual heartbeat architecture is unique to rethinkdb and not present in other Raft implementations. The interaction between virtual heartbeats and term discovery is a rich source of liveness bugs.

---

### Family 2: Configuration Change Safety (HIGH)

**Mechanism**: Joint consensus + leader step-down + non-voter election eligibility interact to create deadlock and safety violations. A tautological invariant (`raft_core.tcc:852`: `X || !X` always true) means the config-readiness correctness property is never actually checked at runtime.

**Evidence**:
- Historical: Bug `f5bc92aca0` — overlapping config changes allowed (used latest instead of committed config)
- Historical: Bug `347a7e635b` — non-voters blocked from elections during config change → cluster deadlock (#4234, CRITICAL)
- Historical: Bug `c665c97ac2` — premature leader step-down (checked only committed config, not latest)
- Historical: Bug `15714934a8` — stale config in `propose_config_change` (part of #5289 split-brain chain)
- Issue #4824 (OPEN): Raft fuzzer reproduces committed ≠ active_config divergence
- Code analysis: `raft_core.tcc:852` — tautological invariant (readiness_for_change || !readiness_for_change)

**Affected code paths**:
- `propose_config_change()` (lines 216-257) — readiness check + joint entry creation
- `leader_continue_reconfiguration()` (lines 1943-1977) — second phase + step-down
- `update_readiness_for_change()` (lines 1243-1270) — readiness computation
- `on_watchdog()` (line 1034) — election eligibility during config change

**Suggested modeling approach**:
- Variables: `committedConfig[Server]`, `latestConfig[Server]`, `readinessForConfigChange[Server -> BOOLEAN]`
- Actions: `ProposeConfigChange` (creates joint consensus entry), `CommitJointConfig`, `ProposeNewConfig` (second phase), `CommitNewConfig`. Add `LeaderStepDown` checking both committed and latest config.
- Key: model non-voter election eligibility — non-voters must be able to start elections during joint consensus (Raft dissertation 4.2.2)

**Priority**: High
**Rationale**: 4 historical bugs (1 CRITICAL), 1 open fuzzer finding, tautological invariant. Configuration changes are the most complex part of Raft and historically the most dangerous in this codebase.

---

### Family 3: Term/Mode Transition Ordering (HIGH)

**Mechanism**: The order of `update_term` and `become_follower` operations matters: updating term while still in candidate/leader mode leaves a window where the election coroutine operates with inconsistent state. The async spawning pattern (`candidate_or_leader_note_term` spawns a coroutine) creates a temporal gap between detecting a higher term and acting on it.

**Evidence**:
- Historical: Bug `15714934a8` — `update_term` called before `become_follower` corrupted state while `candidate_run_election` still running (#5289 CRITICAL)
- Historical: Bug `c665c97ac2` — `note_term` spawned coroutine when already follower → double-transition crash
- Historical: Bug `92fa1e644c` — non-interruptible mutex acquisition blocked transitions
- Code analysis: `raft_core.tcc:1993-2012` — spawned coroutine checks `ps().current_term == local_current_term` guard and `mode != follower` guard

**Affected code paths**:
- `candidate_or_leader_note_term()` (lines 1980-2026) — async transition spawning
- `candidate_or_leader_become_follower()` (lines 1272-1283)
- `update_term()` (lines 1108-1120)
- All callers of `note_term`: `leader_send_updates`, `candidate_run_election`, `on_rpc_from_leader`

**Suggested modeling approach**:
- Variables: `pendingTransition[Server -> BOOLEAN]` (models the async gap)
- Actions: Split `NoteHigherTerm` into `DetectHigherTerm` (marks pending, caller returns) and `ExecuteTransition` (actually steps down, updates term). Between these two actions, other actions can interleave.
- Key: verify that no safety violation occurs during the gap when the node has detected a higher term but hasn't yet stepped down

**Priority**: High
**Rationale**: 3 historical bugs (1 CRITICAL Jepsen-discovered). The async spawning pattern is subtle and all callers must cooperate correctly. A TLA+ model can systematically explore all interleavings during the transition gap.

---

### Family 4: Election Timer / Liveness (MEDIUM)

**Mechanism**: Election timer management is fragile — multiple bugs from shared timers, incorrect reset conditions, and mutex interactions during timeout handling.

**Evidence**:
- Historical: Bug `15a3175b3e` — rejected RequestVote reset election timer → starvation
- Historical: Bug `ad4f9d02eb` — mutex held during vote-request sleep → deadlock
- Historical: Bug `96fefea48b` — shared timer for leader/candidate RPCs
- Historical: Bug `67a57bb37c` — timer not reset after stepping down → premature re-election
- Issue #6038: I/O latency > election timeout → livelock with 100+ tables

**Priority**: Medium
**Rationale**: 5 historical bugs (all fixed). Well-understood area. Election timer modeling is useful for liveness properties but the bugs are largely resolved.

---

### Family 5: Snapshot-Log Consistency (MEDIUM)

**Mechanism**: Snapshot install has three boundary cases (before log, overlapping log, beyond log). Bugs occurred in all three case distinctions.

**Evidence**:
- Historical: Bug `9871a1a410` — entire log discarded when only prefix covered by snapshot
- Historical: Bug `af6ad0f478` — valid AppendEntries rejected when prevLogIndex at snapshot boundary
- Historical: Bug `3fb075a7fd` — incompatible log entries not cleared on snapshot install

**Affected code paths**:
- `on_install_snapshot_rpc()` (lines 523-623) — three cases
- `on_append_entries_rpc()` (lines 644-660) — prevLogIndex vs snapshot boundary

**Suggested modeling approach**:
- Variables: `snapshotIndex[Server]`, `snapshotTerm[Server]`
- Actions: `InstallSnapshot` with explicit case distinction. `HandleAppendEntries` must correctly handle entries that overlap with snapshot boundary.

**Priority**: Medium
**Rationale**: 3 historical bugs (all fixed). Boundary conditions are classic TLA+ targets.

---

### Family 6: Persistence Correctness (MEDIUM)

**Mechanism**: Storage layer has had critical bugs (non-persisted commit index, hex encoding corruption, interruptible writes). In-memory state is mutated before transaction commit.

**Evidence**:
- Historical: Bug `3889ed0b22` — commit_index not persisted → state machine regression (CRITICAL)
- Historical: Bug `cf97eb5b05` — hex encoding + off-by-one → log corruption (CRITICAL)
- Historical: Bug `9f12645d47` — writes interrupted mid-transaction (CRITICAL)
- Historical: Bug `a37c84b65e` — implicit transaction commit on partial writes
- Code analysis: `raft_storage_interface.cc` — all write methods mutate in-memory state before `txn.commit()`

**Suggested modeling approach**:
- Variables: `persistedTerm`, `persistedVotedFor`, `persistedCommitIndex` (separate from volatile state)
- Actions: `Crash` action that recovers from persisted state only. `PersistState` as explicit action.
- Key: verify that crash between any two persistence calls leaves recoverable state

**Priority**: Medium
**Rationale**: 4 historical bugs (all fixed, all CRITICAL/HIGH). Crash-recovery is a classic TLA+ strength, but the specific storage bugs were implementation-level (hex encoding, transaction semantics).

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Virtual heartbeat protocol | Family 1: 4 bugs + 1 open issue; unique architecture | Split heartbeat into start/stop + delayed disconnect detection |
| Joint consensus config changes | Family 2: 4 bugs + open fuzzer finding; highest complexity | Two-phase config entry + dual quorum + non-voter election eligibility |
| Async term transition gap | Family 3: 3 bugs including Jepsen split-brain | Split NoteHigherTerm into detect + execute with interleaving gap |
| Leader step-down on config removal | Family 2: checks both committed + latest | Check both configs before stepping down |
| Snapshot-log boundary cases | Family 5: 3 bugs in boundary conditions | Three-case InstallSnapshot + snapshot-aware AppendEntries handling |
| Crash and recovery | Family 6: commit_index regression bug | Crash action restoring from persisted state only |
| Persisted commit_index | Family 6: Bug `3889ed0b22` added this deliberately | Include in persistent state (deviation from paper) |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Transport-layer failure detection timing | Transport semantics are environment-specific; model as nondeterministic disconnect event instead |
| Cooperative coroutine scheduling details | TLA+ naturally models nondeterministic scheduling; cooperative semantics are too implementation-specific |
| In-memory-before-commit pattern (DA-6) | Implementation-level risk, mitigated by fail-stop; not a protocol issue |
| Hex encoding / integer overflow (Bug #19, #25) | Low-level encoding bugs, not protocol logic |
| Iterator invalidation (Bug #13) | C++-specific memory management, not protocol |
| Mutex deadlock patterns (Bug #7) | Cooperative mutex semantics don't map to TLA+ |
| Election timeout randomization | Model as nondeterministic timeout; specific timer values are not protocol-level |
| Backfill / branch history (#6071, #4866) | Above the Raft layer; operates on contract/shard management |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Virtual heartbeat | `virtualHB[s -> {none, active(term)}]` | Model start/stop heartbeat semantics | Family 1 |
| Transport disconnect | `transportUp[s1, s2 -> BOOLEAN]` | Separate network partition from Raft-level detection | Family 1 |
| Dual config tracking | `committedConfig[s]`, `latestConfig[s]` | Capture committed/latest config distinction | Family 2 |
| Config readiness | `readyForConfigChange[s -> BOOLEAN]` | Prevent overlapping config changes | Family 2 |
| Non-voter election | (modify election eligibility) | Non-voters can start elections during joint consensus | Family 2 |
| Async transition gap | `pendingStepDown[s -> BOOLEAN]` | Model delay between higher-term detection and step-down | Family 3 |
| Snapshot state | `snapshotIndex[s]`, `snapshotTerm[s]` | Model snapshot-log boundary cases | Family 5 |
| Persisted commit | `persistedCommitIndex[s]` | Model crash recovery with persisted commit_index | Family 6 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard |
| LogMatching | Safety | Same index + term ⟹ identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries in all future leaders' logs | Standard |
| StateMachineSafety | Safety | Same commit index ⟹ same committed state | Standard |
| NoOverlappingConfigChange | Safety | At most one joint-consensus config at a time | Family 2 |
| ConfigChangeReadiness | Safety | `readyForConfigChange ⟹ readyForChange` (the tautological invariant) | Family 2, DA-1 |
| NonVoterElectionLiveness | Liveness | If only non-voters can form a quorum, election eventually completes | Family 2 |
| VirtualHeartbeatTermDiscovery | Liveness | Stale leader eventually discovers higher term (via RequestVote) | Family 1 |
| CommitIndexMonotonicity | Safety | Commit index never decreases, even across crashes | Family 6 |
| SnapshotLogConsistency | Safety | `snapshotIndex <= commitIndex` and no gap between snapshot and log start | Family 5 |
| TransitionGapSafety | Safety | No safety violation while `pendingStepDown` is true | Family 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Virtual heartbeat: leader doesn't learn higher term until follower election | VirtualHeartbeatTermDiscovery (liveness) | Family 1 |
| MC-2 | Commit index lag: follower has stale commit between heartbeat start and AppendEntries | CommitIndexMonotonicity (should hold) | Family 1 |
| MC-3 | Config change + election interleaving: non-voter election during joint consensus | ElectionSafety, NoOverlappingConfigChange | Family 2 |
| MC-4 | Async step-down gap: actions interleave between higher-term detection and transition | TransitionGapSafety | Family 3 |
| MC-5 | InstallSnapshot at boundary: snapshot overlaps with existing log entries | SnapshotLogConsistency, LogMatching | Family 5 |
| MC-6 | Crash between write_commit_index and write_snapshot | CommitIndexMonotonicity, SnapshotLogConsistency | Family 6 |
| MC-7 | Leader step-down race: checking committed vs latest config during reconfig | ElectionSafety | Family 2, 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | next_index O(N) decrement performance | Integration test with far-behind follower |
| TV-2 | Election livelock under I/O pressure | Stress test with slow disk simulation + 100 tables |
| TV-3 | Vote retry pestering on already-voted peer | Count wasted RPCs in test with 3+ candidates |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Tautological invariant at `raft_core.tcc:852` | Fix to `readiness_for_change \|\| !readiness_for_config_change` |
| CR-2 | In-memory state mutated before txn.commit() | Add rollback on commit failure, or crash on commit failure |
| CR-3 | Missing global invariants (vote uniqueness, leader completeness) | Add to `check_invariants()` function |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/rethinkdb/analysis-report.md`
- **Key source files**:
  - `artifact/rethinkdb/src/clustering/generic/raft_core.tcc` (main algorithm, 2064 lines)
  - `artifact/rethinkdb/src/clustering/generic/raft_core.hpp` (types + class, 1015 lines)
  - `artifact/rethinkdb/src/clustering/administration/persist/raft_storage_interface.cc` (persistence, 244 lines)
- **GitHub issues**: #5289, #4234, #4979 (Family 2/3 CRITICAL); #4357 (Family 1 OPEN); #4824 (Family 2 OPEN)
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Raft dissertation Sections 4.2.2, 6
- **Test files**: `artifact/rethinkdb/src/unittest/clustering_raft.cc`, `clustering_raft_fuzzer.cc`
