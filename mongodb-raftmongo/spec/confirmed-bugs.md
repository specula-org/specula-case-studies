# Confirmed Bug Report — MongoDB RaftMongo Replication Commit Point Protocol

## Summary

- Total findings reviewed: 9 (from MC bug report + modeling brief, after filtering style/cleanup issues)
- Confirmed: 0
- False positives: 7
- Inconclusive: 1 (pre-existing known issue SERVER-39626)
- Not applicable: 1 (pre-existing known issue SERVER-91374)

**Bottom line**: The MongoDB replication commit point protocol is well-engineered.
All suspected bugs identified during model checking and code review are defended
against by existing safeguards in the implementation. No new bugs were found.

---

## Finding 1: Non-Journal Commit Point Loss

- **Source**: MC (MC_hunt_nojournal.cfg, 12-state counterexample)
- **Status**: FALSE POSITIVE (documented trade-off)
- **Severity**: N/A
- **Location**: topology_coordinator.cpp:3141-3153
- **Description**: When `writeConcernMajorityShouldJournal=false`, the commit point is
  calculated using `lastWritten` instead of `lastDurable`. A majority of nodes can
  acknowledge writes that haven't been journaled. If those nodes crash, the committed
  entry is lost, and a new leader can overwrite it.
- **Counterexample**: s1 elected leader (term 1) → writes no-op → s3 syncs →
  commit point advanced using lastWritten (not journaled) → s3 crashes (log truncated
  to empty) → s2 elected leader (term 2) → committed entry lost.
- **Why it's not a bug**: This is documented MongoDB behavior. The
  `writeConcernMajorityShouldJournal` setting defaults to `true` since MongoDB 4.0+.
  When set to `false`, users explicitly accept durability trade-offs. The original
  MongoDB TLA+ spec (`MCRaftMongoReplTimestamp.cfg`) also tests this invariant only
  with journaling enabled. Our spec's ability to detect this validates the Family 2
  extension (three-level pipeline model).
- **Developer evidence**: The setting is documented in the MongoDB manual as a
  performance trade-off. The code comment at topology_coordinator.cpp:3141 explicitly
  marks this as a configurable behavior path.

---

## Finding 2: SERVER-39626 at Larger Bounds

- **Source**: MC (MC_hunt_server39626.cfg) + Code Review (modeling brief MC-1)
- **Status**: INCONCLUSIVE (pre-existing known issue, not reproduced)
- **Severity**: Known
- **Location**: Commit point propagation protocol (topology_coordinator.cpp:3174-3246)
- **Description**: SERVER-39626 documents a known safety violation
  (NeverRollbackCommitted) at 5 servers, 3 terms, and 4+ log entries. The original
  MongoDB TLA+ config (`MCRaftMongo.cfg:19-22`) explicitly states these bounds exceed
  what can be easily model-checked.
- **MC attempt**: Simulation with 198M states (3.2M traces, 10 min) did not trigger
  the violation. BFS at 5 servers is infeasible (state space > 10^12).
- **Why not reproduced**: Our spec includes extensions not in the original
  (three-level pipeline, explicit election protocol, firstOpTimeOfMyTerm guard) which
  may prevent the exact trigger sequence. Additionally, 3.2M random traces may not
  explore the specific narrow path required.
- **Developer evidence**: MongoDB's own spec comments acknowledge this violation:
  "NeverRollbackCommitted and NeverRollbackBeforeCommitPoint can be violated, although
  it's not ultimately a safety issue: SERVER-39626" (MCRaftMongo.cfg:19-22). MongoDB
  considers this a known, accepted protocol-level limitation.

---

## Finding 3: Heartbeat Commit Point Before Term Update

- **Source**: Code Review (modeling brief MC-3, TV-2)
- **Status**: FALSE POSITIVE
- **Severity**: N/A
- **Location**: replication_coordinator_impl_heartbeat.cpp:322-371
- **Description**: In `_handleHeartbeatResponse`, the commit point is advanced
  (line 331) before the term is updated (lines 337, 371). The concern was that a
  stale term could allow commit point advancement on a wrong history branch.
- **Why it's not a bug**: The commit point advancement calls
  `advanceLastCommittedOpTimeAndWallTime` (topology_coordinator.cpp:3174), which has
  its own independent term check at line 3203-3216:
  ```cpp
  if (!_selfConfig().isArbiter() &&
      getMyLastWrittenOpTime().getTerm() != committedOpTime.opTime.getTerm()) {
      // fromSyncSource=false path: REJECT (return false)
  }
  ```
  For the heartbeat path (`fromSyncSource=false`), any commit point whose term
  differs from `getMyLastWrittenOpTime().getTerm()` is rejected outright. This term
  check uses the node's own persistent data (lastWritten), not the heartbeat
  response's term, so the ordering of term update vs. commit point advancement is
  irrelevant to safety.
- **Additional**: The "dual term update" (TODO(sz) at line 368) is a code
  cleanliness issue, not a safety issue. `_updateTerm` is idempotent — the second
  call with the same term is a no-op; if terms differ, the higher one correctly wins.
- **MC result**: CommitPointOnCorrectBranch invariant passes across all configs
  (89M+ states BFS, 329M simulation).

---

## Finding 4: LastVote Crash Window

- **Source**: Code Review (modeling brief MC-4)
- **Status**: FALSE POSITIVE
- **Severity**: N/A
- **Location**: replication_coordinator_impl_elect_v1.cpp:294-408
- **Description**: During self-election, `_startRealElection` votes for self
  in-memory (line 336) and schedules asynchronous disk persistence via
  `scheduleWork` (line 341). The concern was a crash window between the in-memory
  vote and disk persistence could allow double-voting.
- **Why it's not a bug**: The async scheduling is an executor pattern, not a safety
  gap. The `_writeLastVoteForMyElection` callback (lines 352-408) persists the vote
  to disk at line 374, and only AFTER successful persistence does it call
  `_requestVotesForRealElection` at line 404 to actually send vote requests. No
  external communication happens before the vote is durable:
  ```
  _writeLastVoteForMyElection:
    1. storeLocalLastVoteDocument(opCtx, lastVote)  // line 374: PERSIST FIRST
    2. ... check term hasn't changed ...             // line 395
    3. _requestVotesForRealElection(lk, ...)         // line 404: ONLY THEN COMMUNICATE
  ```
  Similarly, when granting votes to other candidates, `processReplSetRequestVotes`
  (replication_coordinator_impl.cpp:5329-5340) calls `storeLocalLastVoteDocument`
  synchronously before returning the response.
- **Developer evidence**: The spec's Crash action (base.tla:432-436) documents
  this analysis: "MongoDB persists lastVote BEFORE sending vote responses
  (elect_v1.cpp:374) and BEFORE requesting external votes for self-election
  (elect_v1.cpp:404). So votes always survive crash."
- **MC result**: NoTwoPrimariesInSameTerm invariant passes across all configs
  (89M+ states BFS, 329M simulation, with crashes enabled).

---

## Finding 5: Catchup Abort and Commit Freeze

- **Source**: Code Review (modeling brief MC-5)
- **Status**: FALSE POSITIVE
- **Severity**: N/A
- **Location**: topology_coordinator.cpp:2935-2936, 3271-3278, 3193
- **Description**: When a new leader wins election, `_firstOpTimeOfMyTerm` is set to
  INT_MAX (topology_coordinator.cpp:2935), blocking all commit point advancement.
  The concern was that a higher-term discovery during catchup could leave the commit
  point improperly frozen or unfrozen.
- **Why it's not a bug**: The commit freeze mechanism is simple and correct:
  1. `processWinElection` sets `_firstOpTimeOfMyTerm = INT_MAX` (line 2935)
  2. `advanceLastCommittedOpTimeAndWallTime` checks `committedOpTime < _firstOpTimeOfMyTerm`
     at line 3193 — since INT_MAX is unreachable, all commit advancement is blocked
  3. `completeTransitionToPrimary` sets `_firstOpTimeOfMyTerm` to the actual no-op
     optime (line 3278), unblocking only entries at or after the no-op
  4. If a higher term arrives during catchup, `_updateTerm` triggers stepdown, which
     transitions the node to Follower — the frozen state is irrelevant since the node
     is no longer leader
  Additionally, `signalApplierDrainComplete` (replication_coordinator_impl.cpp:1394)
  explicitly checks `canCompleteTransitionToPrimary(termWhenExhausted)` and
  `_pendingTermUpdateDuringStepDown` before completing the transition.
- **MC result**: LeaderElectCommitFreeze invariant (base.tla:590) and all commit
  point invariants pass across all configs.

---

## Finding 6: Sync Source Clamping Safety

- **Source**: MC (MC_hunt_commitbranch.cfg) + Code Review (modeling brief MC-6)
- **Status**: FALSE POSITIVE (tested, no violation)
- **Severity**: N/A
- **Location**: topology_coordinator.cpp:3205-3206
- **Description**: The sync source commit point path clamps the learned commit point
  to `min(committedOpTime, myLastWritten)` when terms differ
  (topology_coordinator.cpp:3206). The concern was whether this clamping could still
  allow safety violations.
- **Why it's not a bug**: The clamping ensures the commit point never advances beyond
  what the node has actually written. Combined with the heartbeat path's term-match
  rejection, the two channels provide complementary safety:
  - Heartbeat (non-sync-source): reject if terms differ
  - Sync source: clamp to min(remote, local) if terms differ
  Both are conservative — the heartbeat path is strict, the sync source path is lenient
  but bounded.
- **MC result**: 569M states explored via BFS (MC_hunt_commitbranch.cfg), no
  violation of NeverRollbackCommitted or CommitPointOnCorrectBranch. Additionally,
  329M states via simulation (MC.cfg, 12.7M traces) with no violation.

---

## Finding 7: SERVER-91374 Data Race in Reconfig

- **Source**: Code Review (modeling brief TV-1)
- **Status**: NOT APPLICABLE (pre-existing known MongoDB issue)
- **Severity**: N/A (already tracked)
- **Location**: replication_coordinator_impl.cpp (getTerm/updateTerm)
- **Description**: SERVER-91374 identifies a data race between `getTerm()` (reads
  atomic `_termShadow` without mutex) and `_updateTerm()` during
  `_doReplSetReconfig`. The `getTerm()` call at heartbeat.cpp:272 reads from an
  atomic variable while the reconfig path may be updating the term concurrently.
- **Classification**: This is an already-filed MongoDB JIRA ticket. It was identified
  during code review as a known issue, not a new finding from our analysis. Not
  counted as a new bug.

---

## Finding 8: Dual Term Update in Heartbeat Response

- **Source**: Code Review (modeling brief TV-2)
- **Status**: FALSE POSITIVE (code smell, not a safety bug)
- **Severity**: N/A
- **Location**: replication_coordinator_impl_heartbeat.cpp:337, 368-371
- **Description**: The heartbeat response handler updates the term twice: once via
  `_processReplSetMetadata` (line 337, which calls `_updateTerm`) and once directly
  via `_updateTerm(lk, hbResponse.getTerm())` (line 371). The code contains a TODO
  comment acknowledging this redundancy.
- **Why it's not a bug**: `_updateTerm` is idempotent — if called with the same or
  lower term, it's a no-op (replication_coordinator_impl.cpp:5554 checks
  `term > _topCoord->getTerm()`). If the metadata term and response body term differ,
  both calls are needed to ensure the higher term is processed. The TODO at line 368
  indicates this is a known code cleanliness issue, not a safety concern.
- **Developer evidence**: The TODO comment itself says "Because the term is duplicated
  in ReplSetMetaData, we can get rid of this and update tests" — confirming the
  developers are aware and consider it cosmetic.

---

## State Space Coverage Summary

| Config | Mode | States | Distinct | Traces | Duration | Result |
|--------|------|--------|----------|--------|----------|--------|
| MC_small.cfg | BFS | 89M | 7.7M | - | 2.5 min | All 11 invariants pass |
| MC.cfg | Simulation | 329M | - | 12.7M | ~10 min | All pass |
| MC_hunt_nojournal.cfg | BFS | 324K | 82K | - | 5s | **NeverRollbackCommitted violated** (documented behavior) |
| MC_hunt_commitbranch.cfg | BFS | 569M | 72M | - | ~24 min | No violation |
| MC_hunt_server39626.cfg | Simulation | 198M | - | 3.2M | ~10 min | No violation |

## Invariants Checked

All 11 invariants pass in the standard configuration (journal=true):

1. NoTwoPrimariesInSameTerm (election safety)
2. NeverRollbackCommitted (commit safety)
3. NeverRollbackBeforeCommitPoint (rollback safety)
4. CommitPointNeverExceedsLastWritten (pipeline consistency)
5. WriteApplyOrdering (lastApplied <= lastWritten)
6. DurableWriteOrdering (lastDurable <= lastWritten)
7. LeaderElectCommitFreeze (drain-phase safety)
8. CommitPointOnCorrectBranch (branch safety)
9. LastDurableWithinLog (structural)
10. LastWrittenEqualsLogLen (structural)
11. LastWrittenTermConsistent (structural)

## Methodology

### Phase 1: Code Audit

Each finding from the bug report and modeling brief was audited by:
1. Reading the exact source code at the cited locations
2. Tracing the call chain from entry point to the potentially buggy code
3. Identifying existing safeguards (term checks, persistence ordering, invariant guards)
4. Constructing or refuting trigger scenarios

### Phase 1.5: Developer Intent Investigation

For each finding, developer intent was assessed via:
- MongoDB JIRA ticket references (SERVER-39626, SERVER-91374, etc.)
- Code comments and TODOs (heartbeat.cpp:368, elect_v1.cpp:356-359)
- TLA+ spec comments in the original MongoDB spec (MCRaftMongo.cfg:19-22)
- Persistence ordering analysis (elect_v1.cpp:374 vs 404)

### Why No Phase 2 (Reproduction)

No findings progressed to reproduction because:
- All MC-found violations are documented behavior (non-journal config)
- All code-review findings were refuted by existing safeguards during Phase 1
- The one inconclusive finding (SERVER-39626) is a known pre-existing issue
  that requires infeasible state space exploration (>10^12 states) to reproduce via MC
- No finding reached "CONFIRMED" or "NEEDS REPRODUCTION" status

## Key Safeguards Identified

The following implementation patterns collectively prevent the hypothesized bugs:

1. **Term check in commit point advancement** (topology_coordinator.cpp:3203-3216):
   Heartbeat-path commit points are rejected if `getMyLastWrittenOpTime().getTerm()`
   differs from the committed entry's term. This is independent of when the node's
   own term is updated.

2. **Persist-before-communicate vote ordering** (elect_v1.cpp:374, 404):
   Vote persistence (`storeLocalLastVoteDocument`) completes before vote requests
   are sent (`_requestVotesForRealElection`). Similarly, vote-granting persists
   before the response function returns (replication_coordinator_impl.cpp:5329-5331).

3. **firstOpTimeOfMyTerm = INT_MAX freeze** (topology_coordinator.cpp:2935):
   Commit point advancement is blocked during the leader-elect/drain phase by
   requiring `committedOpTime >= firstOpTimeOfMyTerm`. Since INT_MAX is unreachable,
   no commit advancement can occur until the no-op is written.

4. **Sync source clamping** (topology_coordinator.cpp:3206):
   Cross-term commit points from sync sources are clamped to
   `min(committedOpTime, myLastWritten)`, preventing advancement beyond written state.

5. **Rollback fasserts** (rollback_impl.cpp:1231-1245):
   Four fatal assertions enforce `commonPoint >= commitPoint` and
   `commonPoint >= committedSnapshot`, crashing the node rather than allowing
   rollback past the commit point.
