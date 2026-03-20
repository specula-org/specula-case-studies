# Bug Report — vesoft-inc/nebula (Raft Consensus)

## Summary

- Bug families tested: 5
- Bugs found: 4 (across 3 bug families)
- Configs run: MC_hunt_family1.cfg through MC_hunt_family5.cfg
- Convergence: 301M states, 837K simulation traces, 0 violations (MC.cfg)
- Spec fixes during convergence: 2 (HandleRequestVoteResponse term check, HandleHeartbeatRequest step-down)

---

## Bug NB-1: Stale Leader Lease Read (No CheckQuorum)

- **Bug Family**: Family 2 — Leader Lease / Split Brain Without CheckQuorum
- **Severity**: Critical
- **Invariant violated**: NoStaleLeaseRead
- **Config**: MC_hunt_family2.cfg
- **Counterexample**: 44 states (output/hunt_family2.out)
- **Historical**: Confirms #5352 (linearizability broken), #5379, #3111

### Trace Summary

1. s2 crashes and restarts (blind follower)
2. All three servers become Candidates via BlindFollowerTimeout
3. s1 wins election at term 3 via pre-vote + formal vote
4. s1 commits entries, receives quorum AE responses → `commitInThisTerm=TRUE`, `leaseExpired=FALSE` (lease valid)
5. s3 also wins a separate election at term 2 (using votes from a partition/timing gap)
6. **Violation**: s1 believes its lease is valid and would serve reads, but s3 is also a leader — reads from s1 may miss writes accepted by s3

### Root Cause

Nebula implements leader lease reads without CheckQuorum or ReadIndex (RaftPart.cpp:2254-2268). The `leaseValid()` check is purely time-based: if `lastMsgAcceptedTime_ + heartbeat_interval - lastMsgAcceptedCostMs_ > now`, the lease is considered valid. There is no mechanism to verify the leader can still communicate with a majority.

Combined with `isBlindFollower_` (RaftPart.h:854), a restarted node can immediately start an election and win, creating a second leader while the old leader's lease is still valid.

### Affected Code

- `RaftPart.cpp:2254-2268`: `leaseValid()` — time-based check without quorum verification
- `RaftPart.cpp:1145-1147`: `needToStartElection()` — `isBlindFollower_` bypasses election timeout
- `RaftPart.cpp:1560-1607`: `processAskForVoteRequest()` — no leader lease check before granting vote

### Recommendation

Implement CheckQuorum: leader periodically verifies it can communicate with a majority. If not, step down. Alternatively, implement ReadIndex (require majority confirmation before serving reads). This is acknowledged as a design gap in issue #3111.

---

## Bug NB-2: LeaderCompleteness Violation — Committed Entries Lost

- **Bug Family**: Family 3 — Snapshot Lifecycle + Family 4 — Log Replication
- **Severity**: Critical
- **Invariant violated**: LeaderCompleteness
- **Config**: MC_hunt_family3.cfg (69 states), MC_hunt_family4.cfg (68 states)
- **Counterexample**: output/hunt_family3_v2.out, output/hunt_family4_v2.out

### Trace Summary (Family 4 — cleaner example)

1. All servers start, multiple election rounds occur
2. A leader at term 1 commits entry 1 on a quorum (e.g., s1+s3, commitIndex=1)
3. Through message loss and re-elections, the committed entry ends up on only one server (the other quorum member's log was truncated by a subsequent leader with conflicting entries)
4. A new leader is elected at a higher term WITHOUT the committed entry (wins votes from servers that don't have it)
5. **Violation**: s2 becomes Leader at term 6 with empty log, but s3 has commitIndex=1 with entries from term 1

### Root Cause

The combination of nebula-specific behaviors creates a scenario where committed entries can be lost:

1. **Non-persisted term/vote** (RaftPart.cpp:412-414): After crash+restart, `term_` is recovered from `wal_->lastLogTerm()` (not the actual persisted term), and `votedFor` is lost entirely. This allows a node to vote in a term where it already voted.

2. **Pre-vote step-down bug** (RaftPart.cpp:1522-1528): Pre-vote with higher actual term causes the recipient to step down and update term, which defeats pre-vote's purpose of preventing disruption from stale nodes.

3. **Heartbeat doesn't advance commitIndex** (RaftPart.cpp:1895-1952): Followers only learn about committed entries via AppendEntries, not heartbeats. If the leader crashes after committing but before sending AE with the updated commitIndex, followers may not know entries are committed.

These mechanisms interact to allow a committed entry to be present on a quorum, but then a re-election with a different quorum can elect a leader without those entries (because the LogUpToDate check is undermined by term confusion from non-persisted votes).

### Affected Code

- `RaftPart.cpp:412-414`: Term recovery from WAL lastLogTerm (not persisted term)
- `RaftPart.h:819-827`: `votedAddr_`, `votedTerm_` are volatile, never persisted
- `RaftPart.cpp:1895-1952`: Heartbeat handler doesn't advance follower commitIndex
- `RaftPart.cpp:1522-1528`: Pre-vote causes step-down (defeats purpose)

### Recommendation

1. Persist `currentTerm` and `votedFor` to stable storage before responding to RPCs (core Raft requirement)
2. Include `committedLogId_` in heartbeat responses so followers can track commits
3. Fix pre-vote to NOT cause step-down (restore Ongaro's pre-vote semantics)

---

## Bug NB-3: Pre-Vote Enables Stale Lease Read

- **Bug Family**: Family 5 — Pre-Vote Implementation Defeats Its Purpose
- **Severity**: High
- **Invariant violated**: NoStaleLeaseRead
- **Config**: MC_hunt_family5.cfg
- **Counterexample**: 65 states (output/hunt_family5.out)
- **Historical**: Confirms PR #3415 (7 bugs from pre-vote), #3322

### Trace Summary

1. s1 becomes leader at term 2, commits entries, lease is valid
2. s1's lease expires (ExpireLease)
3. s2 starts election via Timeout, sends pre-votes at term 3
4. Pre-vote causes s1 (or other servers) to step down due to higher actual term (RaftPart.cpp:1522-1528 bug)
5. s2 wins election at a higher term
6. s2 commits entries, refreshes lease → `commitInThisTerm=TRUE`, `leaseExpired=FALSE`
7. Meanwhile, another server starts a competing election enabled by the pre-vote disruption
8. **Violation**: Two leaders exist, one with a valid lease

### Root Cause

Nebula's pre-vote implementation at RaftPart.cpp:1522-1528 causes the recipient to step down and update its term when the pre-vote sender has a higher *actual* term (`req.term - 1`). This is exactly the disruption that pre-vote was designed to prevent.

The step-down disrupts the current leader's lease, enabling a new election. Combined with the lack of CheckQuorum (Bug NB-1), this creates scenarios where a leader with valid lease coexists with another leader.

### Affected Code

- `RaftPart.cpp:1522-1528`: Pre-vote with higher actual term causes step-down
- `RaftPart.cpp:1572-1575`: Pre-vote grant does NOT reset `lastMsgRecvDur_`
- `RaftPart.cpp:1247-1253`: No term staleness check for pre-vote responses

### Recommendation

Fix pre-vote to NOT modify any state (term, role, leader) on the recipient. Pre-vote should only return a yes/no response based on log comparison, without any side effects on the recipient's state. This matches Ongaro's pre-vote specification.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Family 1 — Non-Persisted Term/Vote (ElectionSafety) | MC_hunt_family1.cfg | 122M states, 354K traces | No violation — the non-persisted vote mechanism alone doesn't create two leaders in the same term (pre-vote quorum prevents direct double-voting). The safety violation manifests through LeaderCompleteness (Bug NB-2) instead. |

## Spec Fixes During Convergence

1. **HandleRequestVoteResponse**: Added `m.mterm = term[i]` check — stale vote responses from previous election rounds were being counted. Implementation has this check at RaftPart.cpp:1345 (`proposedTerm != term_`). Case B (spec modeling issue).

2. **HandleHeartbeatRequest**: Fixed `role'` to step down ALL roles to Follower (not just Leaders). Implementation at RaftPart.cpp:2043-2044 sets `role_ = FOLLOWER` for all non-Learner roles. Candidates receiving heartbeats were remaining Candidate with stale `votesGranted`. Case B (spec modeling issue).

3. **LeaderCompleteness invariant**: Weakened to only check the highest-term leader. Stale leaders at lower terms naturally don't have entries committed by higher-term leaders. Case A (invariant too strong).
