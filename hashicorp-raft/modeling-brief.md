# Modeling Brief: hashicorp/raft

## 1. System Overview

- **System**: hashicorp/raft — Go Raft consensus library used by Consul, Nomad, Vault
- **Language**: Go, ~3600 LOC core logic (raft.go:2286, replication.go:749, configuration.go:368, commitment.go:104, snapshot.go:278)
- **Protocol**: Raft (Ongaro 2014) with PreVote extension, Leadership Transfer, single-server config changes
- **Key architectural choices**:
  - Heartbeat runs in an **independent goroutine** separate from log replication (replication.go:141,416)
  - Uses **leader lease** (lastContact-based) instead of ReadIndex for leader liveness (raft.go:1049)
  - Tracks **two configurations**: `committed` and `latest` (uncommitted) separately (configuration.go:146-157)
  - `persistVote` writes term and votedFor in **two separate disk operations** (raft.go:2175-2183)
  - `setCurrentTerm` is a **separate persistence call** from `persistVote` (raft.go:2186 vs 2175)
- **Concurrency model**: Main state machine on single goroutine; per-peer replication + heartbeat on separate goroutines; snapshot on separate goroutine; FSM on separate goroutine

## 2. Bug Families

### Family 1: Leader Cannot Self-Detect Failure (HIGH → MEDIUM, reclassified as liveness)

**Mechanism**: Leader's disk stalls, but independent heartbeat goroutine continues sending heartbeats to followers. This has a dual effect: (1) maintains leader lease via `lastContact`, and (2) suppresses follower election timeouts via follower-side `setLastContact()`. The cluster gets stuck — no commits, no new leader.

**2026-03-18 update**: Originally described as a safety bug (phantom contacts from higher-term followers fool lease quorum). After maintainer review (https://github.com/hashicorp/raft/issues/666), reclassified as a **liveness** issue. The phantom contact scenario is unreachable because heartbeats prevent followers from reaching higher terms (they suppress election timeouts and block vote granting). The real issue is that heartbeats keep the cluster alive but unable to make progress.

**Evidence**:
- Historical: #503 (OPEN, production) — LogStore hang + heartbeat independence = entire cluster stuck
- Historical: #522 (OPEN) — Leader can't load snapshot, doesn't step down
- Historical: #612 (OPEN) — Replication stopped but heartbeat kept working
- Historical: #614 — Corrupted storage node wins elections repeatedly
- Historical: #666 (OPEN, confirmed as liveness issue) — Missing resp.Term check in heartbeat (code inconsistency confirmed, but phantom contact precondition unreachable)
- Maintainer analysis: heartbeats reset follower election timeout (raft.go:1580) and block vote granting (raft.go:1650-1656), preventing term divergence

**Affected code paths**:
- `heartbeat()` (replication.go:416-483) — independent goroutine, **no** `resp.Term` check (real code issue, but unreachable precondition)
- `replicateTo()` (replication.go:250) — checks `resp.Term > req.Term`
- `pipelineDecode()` (replication.go:607) — checks `resp.Term > req.Term`
- `sendLatestSnapshot()` (replication.go:387) — checks `resp.Term > req.Term`
- `appendEntries()` (raft.go:1580) — follower calls `setLastContact()`, suppressing election timeout
- `requestVote()` (raft.go:1650-1656) — rejects votes if leader contact is recent
- `checkLeaderLease()` (raft.go:1049-1094) — reads `lastContact` from follower replState

**Suggested modeling approach (revised)**:
- To model the liveness issue correctly, need to couple heartbeat receipt with election timeout suppression
- Variables: `lastHeartbeat [Server -> Time]`, with `Timeout(i)` guarded by `lastHeartbeat[i]` staleness
- Verify temporal property: `<>(diskBlocked[leader] ~> \E s \in Server : state[s] = Leader /\ ~diskBlocked[s])`
- The original approach (safety invariants NoPhantomContact, LeaseImpliesLoyalty) targets an unreachable scenario

**Priority**: Medium (liveness, not safety)
**Rationale**: 5 open/confirmed production bugs sharing the same root mechanism. However, this is a liveness issue involving design tradeoffs (temporary disk stalls should not cause leadership flapping), not an unconditional safety violation. The maintainers' proposed fix (timeout on replicateTo blocking duration) reflects this nuance.

---

### Family 2: Configuration Change Safety (HIGH)

**Mechanism**: Inconsistent use of `committed` vs `latest` configuration across code paths. Different functions use different versions, which can lead to inconsistent quorum decisions during config changes.

**Evidence**:
- Historical: commit `38cb186` — removed node can still vote
- Historical: commit `656e6c0` — NonVoter can transition to Candidate
- Historical: commit `6b4e320` — non-voter with higher term gets elected
- Historical: #472 — config divergence causes permanent election deadlock (multiple independent reports)
- Historical: #524 — NonVoter with inflated term destabilizes cluster
- Code analysis: committed vs latest usage table (see analysis-report.md)

**Affected code paths**:
- `quorumSize()` uses latest (raft.go:1101)
- `checkLeaderLease()` iterates latest (raft.go:1061)
- Leader step-down check uses committed (raft.go:810)
- Vote eligibility uses latest (raft.go:1685, 1722)
- `electSelf()` sends to latest (raft.go:2058)
- `commitment.setConfiguration()` uses latest (commitment.go:53)
- `configurationChangeChIfStable()` compares latestIndex == committedIndex (raft.go:668)

**Suggested modeling approach**:
- Variables: `committedConfig [Server -> SUBSET Server]`, `latestConfig [Server -> SUBSET Server]`
- Actions: Add `ProposeConfigChange` with single-uncommitted-at-a-time constraint. Update committed config in `AdvanceCommitIndex`. Followers update configs on AppendEntries via `processConfigurationLogEntry`.
- Key: election quorum, lease check, and commit quorum all use `latestConfig`, while leader step-down uses `committedConfig`

**Priority**: High
**Rationale**: 5+ historical bugs, systematic inconsistency across many code paths. TLA+ is well-suited for exploring config change + election interaction state space.

---

### Family 3: Non-Atomic Persistence (MEDIUM)

**Mechanism**: Operations that persist multiple values in separate disk writes. A crash between writes leaves inconsistent state. The most critical gap is between `setCurrentTerm()` and `persistVote()`.

**Evidence**:
- Code: raft.go:1709 — `setCurrentTerm(req.Term)` persists term
- Code: raft.go:1768 — `persistVote(req.Term, candidateBytes)` persists vote (59 lines later, after multiple checks)
- Code: raft.go:2175-2183 — `persistVote` itself writes term then candidate in two steps
- Code: raft.go:1555,1569 — appendEntries `DeleteRange` then `StoreLogs` with crash window
- Code: raft.go:1571 — developer TODO acknowledging lastLog cache stale after truncation + StoreLogs failure
- Historical: #85 (OPEN 10 years) — panic after restoring from old snapshot
- Historical: #86 (OPEN 8 years) — `TrailingLogs=0` crashes after snapshot
- Issue #661 — **debunked** by maintainers: the double-vote at persistence level does NOT cause split-brain because RPC response is deferred (line 1655) and only sent after `persistVote` completes; after crash recovery, next election uses term+1

**Affected code paths**:
- `requestVote()` (raft.go:1709, 1768) — setCurrentTerm then persistVote
- `electSelf()` (raft.go:2026, 2064) — setCurrentTerm then persistVote for self
- `appendEntries()` (raft.go:1555, 1569) — DeleteRange then StoreLogs
- `persistVote()` (raft.go:2176, 2179) — SetUint64(term) then Set(candidate)

**Suggested modeling approach**:
- Variables: `persistedTerm`, `persistedVotedFor`, `pendingVote`
- Actions: Split `HandleRequestVoteRequest` into two steps: step 1 persists term, step 2 persists votedFor and sends response. Model `Crash` recovering from persisted (not volatile) state.
- Also provide atomic variants for trace validation (normal non-crash path)

**Priority**: Medium
**Rationale**: The double-vote concern was debunked (#661), but crash recovery is a classic TLA+ strength. The lastLog cache staleness (TODO line 1571) and snapshot-log gaps (#85, #86) are real issues worth modeling.

---

### Family 4: Copy-Paste / Incomplete PreVote Implementation (LOW)

**Mechanism**: PreVote was implemented by copying RequestVote code with some paths missing necessary modifications.

**Evidence**:
- Historical: commit `42d3446` — granting PreVote incorrectly updated leader lastContact
- Historical: commit `497108f` — requestPreVote candidate address not decoded from header
- Code: raft.go:1780 — metrics label `"requestVote"` should be `"requestPreVote"`

**Priority**: Low
**Rationale**: Not suitable for TLA+ modeling. These are code-level issues better found by line-by-line comparison of requestVote vs requestPreVote.

---

### Family 5: Error Handling / Edge Cases (LOW)

**Mechanism**: Incomplete recovery paths after partial failures or unusual RPC sequences.

**Evidence**:
- Code: raft.go:2254-2259 — `timeoutNow` has no state/term/config guard
- Historical: #498 (OPEN) — `Apply()` permanently deadlocks when quorum lost
- Code: installSnapshot doesn't update lastLog cache (raft.go:1977 updates lastSnapshot only)
- Historical: commit `ec99ca3` — installSnapshot didn't consume stream on early return

**Priority**: Low (for TLA+ modeling)
**Rationale**: Most issues are better verified by testing or code review. The timeoutNow issue is an edge case requiring stale/replayed messages.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Independent heartbeat path | Family 1: root cause of 5 open production bugs, confirmed #666 | Split AppendEntries send/response into heartbeat vs replicate variants |
| Leader lease via lastContact | Family 1: lease is the mechanism that should detect stale leaders | `leaseContact` variable + `CheckLeaderLease` action |
| Disk IO blocking | Family 1: heartbeat continues when disk blocked (#503) | `diskBlocked` variable as guard on `ReplicateEntries` and `ClientRequest` |
| Committed vs latest config | Family 2: systematic code inconsistency, unfixed #472, 5+ historical bugs | Two config variables, different actions use different ones |
| Non-atomic persistVote | Family 3: concrete crash window, #85/#86 unfixed for years | Split vote persist into two steps + `Crash` recovering from persisted state |
| Crash and recovery | Family 3: validates persistence correctness | `Crash` action resets volatile state, recovers from persisted |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| PreVote | Not related to any high-priority bug family. Adds state space without targeting known issues. Can be added later. |
| Metrics/logging | Family 4: code-level issue, not protocol logic |
| Snapshot transfer | Important but not in the top bug families. Would significantly expand spec scope. |
| Pipeline replication | Optimization path. Requires modeling Go channel semantics, not protocol logic. |
| Leadership Transfer | timeoutNow guard (Family 5) is an edge case. The transfer mechanism itself works. |
| FSM application | Application logic, not consensus protocol |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Heartbeat path | (split in actions, no new vars) | Distinguish heartbeat from replicate to model term-check omission | Family 1 |
| Leader lease | `leaseContact` | Track follower contacts for lease quorum check | Family 1 |
| Disk blocking | `diskBlocked` | Model heartbeat continuing when disk IO blocks | Family 1 |
| Dual configuration | `committedConfig`, `latestConfig` | Capture committed/latest config inconsistency | Family 2 |
| Non-atomic persist | `persistedTerm`, `persistedVotedFor`, `pendingVote` | Model crash between two disk writes | Family 3 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ElectionSafety | Safety | At most one leader per term | Standard |
| LogMatching | Safety | Matching term at same index implies identical prefix | Standard |
| LeaderCompleteness | Safety | Committed entries appear in future leaders' logs | Standard |
| NoPhantomContact | Safety | Leader's lease contacts only count followers whose response term <= leader's term | Family 1, #666 |
| LeaseImpliesLoyalty | Safety | If leader's lease check passes, a real quorum has term <= leader's term | Family 1 |
| DiskBlockLiveness | Liveness | If leader's disk is permanently blocked, eventually a new leader is elected | Family 1, #503 |
| ConfigSafety | Safety | At most one uncommitted config change at a time | Family 2 |
| QuorumOverlap | Safety | Old and new quorums overlap during config change | Family 2 |
| VoteSafety | Safety | A node votes for at most one candidate per term (even across crashes) | Family 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| F1-A | Heartbeat phantom contact allows stale leader to hold lease indefinitely | NoPhantomContact, LeaseImpliesLoyalty | 1 |
| F1-B | Disk-blocked leader holds lease via heartbeat while cluster is stuck | DiskBlockLiveness | 1 |
| F1-C | checkLeaderLease uses latestConfig — miscalculated quorum during config change | LeaseImpliesLoyalty | 1, 2 |
| F2-A | quorumSize uses latest — incorrect quorum during config change | ElectionSafety | 2 |
| F2-B | electSelf sends to latest — votes from uncommitted members | ElectionSafety | 2 |
| F2-C | Config rollback on log truncation (raft.go:1559-1560) — races with commit | ConfigSafety | 2 |
| F3-A | persistVote crash window — term persisted but votedFor not | VoteSafety | 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T1 | nextIndex non-atomic read-write (replication.go:275) | Go race detector test with concurrent heartbeat + replicate |
| T2 | lastLog cache stale after truncation + StoreLogs failure (raft.go:1571) | Unit test: mock StoreLogs to fail after DeleteRange |
| T3 | installSnapshot doesn't update lastLog cache (raft.go:1977) | Unit test: appendEntries after installSnapshot |
| T4 | Apply future deadlock on quorum loss (#498) | Integration test with partitioned leader |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| C1 | requestPreVote metrics label "requestVote" (raft.go:1780) | Submit fix PR |
| C2 | timeoutNow no state/term guard (raft.go:2254) | Discuss with maintainers |
| C3 | s.peer.ID access without peerLock in updateLastAppended (replication.go:744) | Check if Go struct assignment atomicity guarantees suffice |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/hashicorp-raft/analysis-report.md`
- **Key source files**:
  - `artifact/raft/raft.go` (core state machine, 2286 lines)
  - `artifact/raft/replication.go` (replication + heartbeat, 749 lines)
  - `artifact/raft/configuration.go` (config changes, 368 lines)
  - `artifact/raft/commitment.go` (commit tracking, 104 lines)
- **GitHub issues**: #503, #522, #612, #614, #666 (Family 1); #472, #524 (Family 2); #85, #86, #661 (Family 3); #498 (Family 5)
- **Reference spec**: Raft paper (Ongaro & Ousterhout, 2014), Raft dissertation (Ongaro, 2014)
