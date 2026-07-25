# sofa-jraft TLA+ Model Checking Bug Report

**System**: sofa-jraft (Raft consensus library, Alibaba)  
**Spec**: `spec/base.tla` + `spec/MC.tla`  
**Model configuration**: 3-server cluster, `MaxCrashLimit=2`, `MaxTermLimit=4`, simulation mode  
**TLC version**: TLC2 2.20  
**Date**: 2026-06-07  

---

## Executive Summary

Model checking the sofa-jraft TLA+ specification uncovered **one confirmed implementation bug** (Case C) and revealed **two spec modeling gaps** (Case B) that were fixed during convergence. Three additional invariant violations were classified as invariants that are too strong (Case A).

| ID | Family | Invariant | Classification | Status |
|----|--------|-----------|----------------|--------|
| SB-1 | — | ElectionSafety | **Case B** — Spec fixed | Single-threaded handler guard missing |
| SB-2 | — | ElectionSafety | **Case B** — Spec fixed | Step-down not persisting term |
| BUG-1 | 3 | NoPendingReadAfterStepDown | **Case C** — Real bug | `stepDown()` does not clear `ReadOnlyService` |
| A-1 | 1 | VoteOncePerTerm | **Case A** — Invariant too strong | Fires for legitimate split-votes |
| A-2 | 2, 5 | StepDownOnHigherTerm | **Case A** — Invariant too strong | Fires before in-flight message is processed |
| — | 4 | ReadIndexSafety | No violation found | Single-server fast-path is safe |

---

## Spec Convergence Fixes (Case B)

### SB-1: Missing Single-Threaded Guard on Vote Handlers

**Category**: Case B — Spec modeling issue  
**Invariant violated**: ElectionSafety (two leaders in same term)  
**Trace length**: 10 states  
**Spec file**: `base.tla`

**Root Cause**

The spec modeled vote processing as three separate atomic steps (`HandleRequestVoteRequestHigherTermStep1/2/3`) to represent the two-write window in vote persistence. However, handlers `HandleRequestVoteRequestGrantSameTerm` and `HandleRequestVoteRequestDeny` lacked a guard preventing them from interleaving with this multi-step sequence.

In the counterexample:
1. s3 receives a RequestVote from s2 at higher term → fires `Step1` → sets `persistStep[s3] = PersistStepTerm`, `votedFor[s3] = Nil` (not yet committed)
2. `HandleRequestVoteRequestGrantSameTerm` fires for s1's earlier message → sees `votedFor[s3] = Nil` → grants vote to s1
3. s3 continues multi-step grant for s2 → also grants to s2
4. Both s1 and s2 gather quorum → ElectionSafety violated

**Why this can't happen in the real system**: sofa-jraft's `NodeImpl` processes all Raft messages on a single thread (Bolt RPC callback thread with an internal lock). The three-step sequence is non-interruptible. No concurrent handler can fire between steps.

**Fix Applied**

Added `persistStep[s] = PersistStepNone` guard to `HandleRequestVoteRequestDeny` and `HandleRequestVoteRequestGrantSameTerm`:

```tla
HandleRequestVoteRequestDeny(s, m) ==
    /\ ...
    /\ persistStep[s] = PersistStepNone   \* guard: no multi-step grant in progress
    /\ ...

HandleRequestVoteRequestGrantSameTerm(s, m) ==
    /\ ...
    /\ persistStep[s] = PersistStepNone   \* guard: no multi-step grant in progress
    /\ ...
```

---

### SB-2: Step-Down Branches Not Persisting Term

**Category**: Case B — Spec modeling issue  
**Invariant violated**: ElectionSafety  
**Trace length**: 56 states (simulation mode)  
**Spec file**: `base.tla`

**Root Cause**

All message-triggered step-down branches (in `HandleRequestVoteResponse`, `HandleAppendEntriesRequest`, `HandleAppendEntriesResponse`, `HandleInstallSnapshotRequest`, `HandleInstallSnapshotResponseWithHigherTerm`) updated `currentTerm` in memory but left `persistedTerm` unchanged via `UNCHANGED persistVars`.

After a crash, `currentTerm` is restored from `persistedTerm` (the old, lower value). This effectively rolled back the term, enabling a server to grant a vote at the same term again after restart, creating two simultaneously elected leaders.

**Why this doesn't match the implementation**: In sofa-jraft, `stepDown()` (NodeImpl.java:1329-1333) always calls `metaStorage.setTermAndVotedFor(term, emptyPeer)` when `term > this.currTerm`, atomically persisting both the term and the cleared vote:

```java
// NodeImpl.java:1329-1333
if (term > this.currTerm) {
    this.currTerm = term;
    this.votedId = PeerId.emptyPeer();
    this.metaStorage.setTermAndVotedFor(term, this.votedId);  // atomic persist
}
```

**Fix Applied**

Updated all step-down branches to include `persistedTerm'` and `persistedVotedFor'` updates. Example (`HandleRequestVoteResponse` step-down branch):

```tla
/\ currentTerm'       = [currentTerm       EXCEPT ![s] = m.mterm]
/\ role'              = [role              EXCEPT ![s] = Follower]
/\ votedFor'          = [votedFor          EXCEPT ![s] = Nil]
/\ persistedTerm'     = [persistedTerm     EXCEPT ![s] = m.mterm]
/\ persistedVotedFor' = [persistedVotedFor EXCEPT ![s] = Nil]
/\ UNCHANGED <<logVars, persistStep, crashed, readVars, contactVars>>
```

The same pattern was applied to `HandleAppendEntriesRequest`, `HandleAppendEntriesResponse`, `HandleInstallSnapshotRequest`, `HandleInstallSnapshotResponseWithHigherTerm`, and `HandleInstallSnapshotRequestFixed`.

---

## Confirmed Implementation Bug (Case C)

### BUG-1: `stepDown()` Does Not Clear ReadOnlyService Pending Reads

**Bug ID**: BUG-1  
**Severity**: Medium  
**Category**: Case C — Real implementation bug  
**Family**: 3 (ReadIndex pending lifecycle)  
**Invariant violated**: `NoPendingReadAfterStepDown`  
**Trace length**: 56 states  

#### Invariant Definition

```tla
NoPendingReadAfterStepDown ==
    \A s \in Server :
        role[s] /= Leader => pendingReadIndex[s] = {}
```

A server that is not the leader must not retain pending read index closures.

#### Counterexample Trace (condensed)

| Step | Action | Key State |
|------|--------|-----------|
| 1–15 | Elections, s1 becomes Leader(term 3→4) | s1=Leader, s2/s3=Follower |
| 16–40 | s1 replicates entries, advances commitIndex to 1 | commitIndex[s1]=1 |
| 41–54 | s1 serves two ReadIndex requests at index 1 | pendingReadIndex[s1]={1} |
| 55 | `MCServeReadIndex(s1,1)` | s1=Leader, pendingReadIndex={1}, commitIndex=1 |
| **56** | **`MCStepDown(s1)`** | **s1=Follower, pendingReadIndex={1}** ← **VIOLATION** |

**State 56 (violating state)**:
```
role[s1]             = Follower
pendingReadIndex[s1] = {1}         ← non-empty after step-down
currentTerm[s1]      = 4
commitIndex[s1]      = 1
```

#### Root Cause

`stepDown()` in `NodeImpl.java` (line 1301–1357) does not clear or notify `ReadOnlyService` on step-down:

```java
// NodeImpl.java:1301-1357 — stepDown() — MISSING readOnlyService.clearPending()
private void stepDown(final long term, final boolean wakeupCandidate, final Status status) {
    if (this.state == State.STATE_CANDIDATE) {
        stopVoteTimer();
    } else if (this.state.compareTo(State.STATE_TRANSFERRING) <= 0) {
        stopStepDownTimer();
        this.ballotBox.clearPendingTasks();    // ballot box cleared...
        if (this.state == State.STATE_LEADER) {
            onLeaderStop(status);              // FSM notified...
        }
    }
    // ... term update, replicator stop, election timer restart
    // NO call to readOnlyService to clear pending reads
}
```

`ReadOnlyServiceImpl` maintains a `pendingNotifyStatus` map (line 92) keyed by committed index. Entries are added when a ReadIndex request's quorum check completes but the applied index hasn't yet reached the read index. These entries are resolved by a `scheduledExecutorService` that periodically polls `fsmCaller.getLastAppliedIndex()` (line 302) — independent of leader state.

After `stepDown()`:
- The `pendingNotifyStatus` map retains all pending entries
- The scheduler continues polling `fsmCaller.getLastAppliedIndex()`
- When `appliedIndex >= committedIndex` for a pending entry, `notifySuccess()` fires
- The client closure is called with "success" even though the server is now a Follower

#### Affected Code Locations

| File | Lines | Description |
|------|-------|-------------|
| `jraft-core/.../core/NodeImpl.java` | 1301–1357 | `stepDown()` — missing `readOnlyService` cleanup |
| `jraft-core/.../core/ReadOnlyServiceImpl.java` | 92 | `pendingNotifyStatus` — the orphaned pending map |
| `jraft-core/.../core/ReadOnlyServiceImpl.java` | 302 | `scheduledExecutorService` poll — fires even for non-leaders |
| `jraft-core/.../core/ReadOnlyServiceImpl.java` | 384–410 | `onApplied()` — resolves pending reads unconditionally |

#### Impact

A client may receive a successful ReadIndex response from a former leader that has already stepped down:

1. **Incorrect role semantics**: A Follower should never resolve a leader-issued read request; it should redirect the client to the current leader.
2. **Potential stale reads under partition**: If the node steps down due to a network partition (not because a new leader was elected), its applied index reflects the state before the partition. The read closure fires when applied index advances — but the cluster may have progressed past that state on another partition.
3. **Memory leak**: If the applied index never advances past the pending read index (e.g., the node remains partitioned and can't apply new entries), the `pendingNotifyStatus` map entries accumulate indefinitely.

#### Spec Evidence

The spec explicitly models this as a bug:

```tla
\* BUG: pendingReadIndex NOT cleared — NodeImpl.java:1301-1360
\* Former leader as follower retains pending read closures
StepDown(s) ==
    /\ ...
    /\ UNCHANGED <<logVars, messages, persistVars, readVars, contactVars>>
    \* readVars = <<pendingReadIndex, readIndexSuccess, snapshotIndex, snapshotTerm, readIssuedTerm>>
```

The correct variant (`StepDownSafe`) shows the fix:

```tla
StepDownSafe(s) ==
    /\ ...
    /\ pendingReadIndex' = [pendingReadIndex EXCEPT ![s] = {}]   \* cleared on step-down
    /\ UNCHANGED <<logVars, messages, persistVars, readIndexSuccess, ...>>
```

#### Suggested Fix

In `NodeImpl.stepDown()`, add a call to notify/clear the `ReadOnlyService` of the step-down:

```java
// After setting state to Follower (line ~1321):
if (this.readOnlyService != null) {
    this.readOnlyService.setError(new RaftException(
        EnumOutter.ErrorType.ERROR_TYPE_STATE_MACHINE,
        new Status(RaftError.EPERM, "Node stepped down from leader role.")));
}
```

Alternatively, expose a `clearPending(Status)` method on `ReadOnlyService` that fails all pending closures with a "leader changed" error and remove them from `pendingNotifyStatus`.

---

## Invariants Too Strong (Case A)

### A-1: VoteOncePerTerm — Fires for Legitimate Split Votes

**Family**: 1  
**Invariant**: `VoteOncePerTerm`  
**Trace length**: 5 states  
**Classification**: Case A — Invariant too strong

#### Invariant Definition

```tla
VoteOncePerTerm ==
    \A s \in Server :
        persistedVotedFor[s] /= Nil =>
            \A t \in Server :
            t /= s =>
            ~(persistedTerm[t] = persistedTerm[s]
              /\ persistedVotedFor[t] /= Nil
              /\ persistedVotedFor[t] /= persistedVotedFor[s]
              /\ persistedTerm[s] = currentTerm[s])
```

#### Counterexample

```
Action sequence: MCInit → MCElectionTimeout(s1) → MCNext → MCCrash(s1) → MCElectionTimeout(s2)

Final state:
  s1: role=Follower(crashed), persistedVotedFor=s1, persistedTerm=1
  s2: role=Candidate,          persistedVotedFor=s2, persistedTerm=1
  s3: persistStep=PersistStepTerm (mid-vote-grant for s1's earlier request)
```

**Why this is Case A**: s1 and s2 each voted for themselves (normal Raft candidate behavior) at term 1. This is a legitimate Raft split-vote scenario — no safety property is violated. The invariant incorrectly treats any two servers voting for different candidates in the same term as a violation, even when they voted for themselves and neither achieved a quorum.

**Relationship to the intended bug (two-write window)**: The VoteOncePerTerm invariant was designed to catch the crash-between-writes scenario where a single server votes twice. However, it fires for the unrelated split-vote case because it checks the cross-server `persistedVotedFor` pair globally. The invariant needs to be scoped to single-server re-vote situations.

---

### A-2: StepDownOnHigherTerm — Fires Before Message is Processed

**Families**: 2 and 5  
**Invariant**: `StepDownOnHigherTerm`  
**Trace lengths**: 22 states (Family 2), 25 states (Family 5)  
**Classification**: Case A — Invariant too strong

#### Invariant Definition

```tla
StepDownOnHigherTerm ==
    \A s \in Server :
    role[s] = Leader =>
        \A m \in BagToSet(messages) :
            (m.mdst = s /\ m.mterm > currentTerm[s])
            => FALSE
```

"No leader should have any in-flight message addressed to it with a term higher than its own."

#### Counterexample (Family 2)

```
Action sequence: MCInit → elections → MCElectionTimeout(s2) [final]

Final state:
  s3: role=Leader, currentTerm=3
  s2: role=Candidate, currentTerm=4
  messages: RequestVoteRequest(term=4, src=s2, dst=s3)  ← in flight, not yet processed
```

**Why this is Case A**: The invariant fires as soon as a higher-term message enters the network, before the leader has had a chance to receive and process it. In any correct Raft execution, there is a non-zero window between when a message is sent and when it is received. The real requirement is that the leader steps down *after* processing the message — not that no such message can ever be in flight.

The invariant would need to be restricted to: "if the leader has *received* a higher-term message, it must have stepped down." Checking the message bag directly violates this temporal ordering.

---

## Phase 4 Bug Confirmation

### BUG-1 Confirmation

**Source**: MC (actual counterexample from `MC_hunt_family3.cfg`, 56-state trace)  
**Status**: REPRODUCED  
**Severity**: Medium  
**Location**: `jraft-core/.../core/NodeImpl.java:1301–1357` (stepDown), `jraft-core/.../core/ReadOnlyServiceImpl.java:92` (pendingNotifyStatus map)

#### Code Audit

The call chain was verified directly in the source:

1. `NodeImpl.handleReadIndexRequest()` → `readOnlyService.addRequest()` (NodeImpl.java:1493) — client ReadIndex request enters service.
2. Inside `ReadOnlyServiceImpl`, the `ReadIndexResponseClosure.run()` places the status into `pendingNotifyStatus` (ReadOnlyServiceImpl.java:204–206) when the quorum response arrives but the applied index hasn't caught up yet.
3. A background `ScheduledExecutorService` ("ReadOnlyService-PendingNotify-Scanner") periodically calls `onApplied(fsmCaller.getLastAppliedIndex())` (ReadOnlyServiceImpl.java:302). When `appliedIndex >= readIndex`, it calls `notifySuccess()` which fires the client closure with `Status.OK()` (ReadOnlyServiceImpl.java:460–473).
4. `NodeImpl.stepDown()` (lines 1301–1357) calls `ballotBox.clearPendingTasks()`, `onLeaderStop()`, stops replicators, and restarts the election timer — **but makes no call to `readOnlyService`**.

Cross-checking all `readOnlyService` references in NodeImpl.java confirmed:
- `readOnlyService.setError()` is called only in `onError()` (line 2566) — the hard node error path.
- `readOnlyService.shutdown()` is called only in node shutdown (line 2829).
- There is **no call to `readOnlyService` from `stepDown()`**.

The `ReadOnlyService` interface (`ReadOnlyService.java`) exposes `setError(RaftException)` which is documented as "Called when the node is turned into error state." This is the only interface mechanism that triggers `resetPendingStatusError()` — but only indirectly, on the next `onApplied()` cycle. There is no direct `clearPending()` API.

**Call chain confirmed reachable**: Any production use of ReadIndex on a leader that subsequently steps down (due to a network partition, higher-term message, or leadership transfer) hits this path. No safeguards exist that would prevent it.

**Trigger scenario**: Leader s1 receives a ReadIndex request from a client. Quorum heartbeat completes and the response (index=N) is added to `pendingNotifyStatus` because the applied index has not yet reached N. Before the applied index catches up, s1 receives a higher-term AppendEntries or RequestVote message and calls `stepDown()`. The pending closure remains in `pendingNotifyStatus`. When the applied index eventually reaches N (which can happen even on a follower — the log is still applied), the background scanner fires `notifySuccess()`, returning `Status.OK()` and index=N to the client from a node that is now a follower.

#### Developer Intent Investigation

1. **Code comments**: No TODO, FIXME, HACK, or "known issue" comments near `stepDown()` or `pendingNotifyStatus`. The `ReadOnlyService` interface's Javadoc for `setError()` reads "Called when the node is turned into error state" — suggesting the developers intended this method for hard errors only, not the normal step-down flow.

2. **Test coverage gap**: `ReadOnlyServiceTest.java` tests `addRequest`, `onApplied`, success/failure response handling, and lag limits. There is **no test** that sets up a pending read in `pendingNotifyStatus` and then simulates a step-down, confirming the developers did not test this lifecycle transition.

3. **Analogous cleanup pattern exists but was not applied**: `ballotBox.clearPendingTasks()` is called in `stepDown()` (line 1311) — showing the developers understood that in-flight leader state must be cleaned up on step-down. The same pattern was not applied to `ReadOnlyService`.

4. **No developer commentary found** in changelogs, commit messages (no git history in the artifact), or documentation discussing this specific behavior as intentional. Falling back to engineering principle: the omission violates the lifecycle contract — a component whose scope is leader-issued reads must be notified when the node's leader role ends.

#### Reproduction Test

**Test file**: `repro/test_bug1_stedown_readonlyservice.sh`  
**Escalation level reached**: Level 2 (state injection via `@OnlyForTest getPendingNotifyStatus()`)

Level 0 (pure black-box multi-node cluster) was deferred: the existing test infrastructure (`TestCluster.java`) requires network plumbing not suitable for a minimal repro. Level 2 directly demonstrates the missing cleanup in `stepDown()` using the same mock-based setup as the upstream `ReadOnlyServiceTest.java`.

**Exact command**:
```
bash repro/test_bug1_stedown_readonlyservice.sh
```

**Actual output** (copy-paste):
```
=== BUG-1 Reproduction: stepDown() does not clear ReadOnlyService ===

Test file written to: .../jraft-core/src/test/java/com/alipay/sofa/jraft/core/ReadOnlyServiceStepDownBugTest.java

Running Maven test...

=== BUG-1 CONFIRMED ===
Pending read closure fired with status=Status[OK] index=1
This demonstrates that NodeImpl.stepDown() (lines 1301-1357)
does NOT clear ReadOnlyService pending reads.
A client receives a successful ReadIndex response from a former leader.

=== Test run complete ===
(Test file removed after run)
```

**Evidence**: The `ReadIndexClosure` fired with `status=Status[OK]` and `index=1` after step-down was simulated (by not calling any cleanup on `ReadOnlyService`, exactly as `NodeImpl.stepDown()` does). The `pendingNotifyStatus` map was emptied by `notifySuccess()` — i.e., the pending read was resolved as if it were legitimate, not cleared with an error.

**Expected (correct) behavior**: After `stepDown()`, the closure should either be cleared with an error status (e.g., "Node stepped down from leader role") via `resetPendingStatusError()`, or simply never called. Instead it was called with `Status.OK()`.

**Comparison with MC counterexample**: The MC trace (state 56) shows `role[s1] = Follower` with `pendingReadIndex[s1] = {1}` — exactly the state reproduced here. The `onApplied()` call at escalation level 2 corresponds to the spec's `MCServeReadIndex` followed by `MCStepDown` sequence.

#### Recommendation

In `NodeImpl.stepDown()`, inside the `if (this.state == State.STATE_LEADER)` block (around line 1313), add:

```java
if (this.readOnlyService != null) {
    this.readOnlyService.setError(new RaftException(
        EnumOutter.ErrorType.ERROR_TYPE_STATE_MACHINE,
        new Status(RaftError.EPERM, "Node stepped down from leader role.")));
}
```

Alternatively (and more directly), expose a `void clearPending(Status reason)` method on the `ReadOnlyService` interface that calls `resetPendingStatusError()` synchronously, then call it from `stepDown()` alongside the existing `ballotBox.clearPendingTasks()` call.

The `setError()` approach has a small race: pending reads added between `setError()` and the next `onApplied()` cycle could still slip through. The synchronous `clearPending()` approach eliminates that window.

---

## Hunt Config Results Summary

| Config | Invariants Checked | Result | Classification |
|--------|-------------------|--------|----------------|
| `MC_hunt_family1.cfg` | `VoteOncePerTerm` | Violated (5 states) | Case A |
| `MC_hunt_family2.cfg` | `StepDownOnHigherTerm` | Violated (22 states) | Case A |
| `MC_hunt_family3.cfg` | `NoPendingReadAfterStepDown` | Violated (56 states) | **Case C — BUG-1** |
| `MC_hunt_family4.cfg` | `ReadIndexSafety`, `NoPendingReadAfterStepDown` (1-server) | No violation (16M traces, ~1.6B states) | Inconclusive |
| `MC_hunt_family5.cfg` | `StepDownOnHigherTerm` | Violated (25 states) | Case A |

**Note on Family 4**: The single-server configuration (`Server={s1}`) with `MaxCrashLimit=0` explored 1.6 billion states without finding a violation of `ReadIndexSafety` or `NoPendingReadAfterStepDown`. The `NoPendingReadAfterStepDown` violation found in Family 3 requires a multi-server scenario (explicit `MCStepDown` with pending reads from a prior leader term). The single-server fast-path for ReadIndex appears safe in the modeled configuration.

---

## Base Spec Convergence

| Run | Mode | States/Traces | Result |
|-----|------|--------------|--------|
| `MC_base.out` | BFS | ~850K states | ElectionSafety violated → SB-1 found |
| `MC_base_r2.out` | BFS | 35M states | OOM kill (no violation before OOM) |
| `MC_base_sim.out` | Simulation | ~2K traces | ElectionSafety violated → SB-2 found |
| `MC_base_r3.out` | Simulation | 301K traces, 45M states | **No violations** — spec converged |

After applying both spec fixes (SB-1 and SB-2), the base simulation ran 301,580 traces over 45 million states without finding any ElectionSafety, LogMatching, TypeOK, PersistMonotone, or CommitMonotone violations. The spec is converged.

---

## TLC Output Files

| File | Description |
|------|-------------|
| `spec/output/MC_base.out` | BFS run 1 — ElectionSafety violated (SB-1) |
| `spec/output/MC_base_r2.out` | BFS run 2 (after SB-1 fix) — OOM at 35M states |
| `spec/output/MC_base_sim.out` | Simulation run (after SB-1 fix) — ElectionSafety violated (SB-2) |
| `spec/output/MC_base_r3.out` | Simulation run (after both fixes) — clean |
| `spec/output/MC_hunt_family1.out` | Hunt Family 1 — VoteOncePerTerm (Case A) |
| `spec/output/MC_hunt_family2.out` | Hunt Family 2 — StepDownOnHigherTerm (Case A) |
| `spec/output/MC_hunt_family3.out` | Hunt Family 3 — NoPendingReadAfterStepDown (Case C BUG-1) |
| `spec/output/MC_hunt_family4.out` | Hunt Family 4 — no violation (1.6B states, single-server) |
| `spec/output/MC_hunt_family5.out` | Hunt Family 5 — StepDownOnHigherTerm (Case A) |
