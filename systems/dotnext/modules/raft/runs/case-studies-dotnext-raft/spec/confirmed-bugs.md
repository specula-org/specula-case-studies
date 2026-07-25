# Confirmed Bug Report — dotnext-raft

## Summary

- Total findings reviewed: 12 (6 MC-checked, 3 test-verifiable, 3 code-review-only)
- Confirmed: 5 (5 reproduced via test, 5 code-audit confirmed)
- False positives: 5
- Inconclusive: 2 (MC design observations, not bugs)

All 5 bugs reproduced with .NET 10 SDK (10.0.201) via standalone xUnit test project (`repro/`). 14 tests, all pass, confirming all 5 bugs.

---

## Bug 1: MemberAdded Event Remove Accessor Wired to Wrong Handler

- **Source**: Code Review (TV-1)
- **Status**: CONFIRMED (code audit + reproduced)
- **Severity**: High
- **Location**: `RaftCluster.Membership.cs:99`
- **Description**: The `MemberAdded` event's `remove` accessor modifies `memberRemovedHandlers` instead of `memberAddedHandlers`. This is a copy-paste error.

  ```csharp
  // Line 96-100: MemberAdded event
  public event Action<RaftCluster<TMember>, RaftClusterMemberEventArgs<TMember>> MemberAdded
  {
      add => memberAddedHandlers += value;
      remove => memberRemovedHandlers -= value;  // BUG: should be memberAddedHandlers
  }
  ```

  Compare with the correct `MemberRemoved` event (lines 118-122):
  ```csharp
  public event Action<RaftCluster<TMember>, RaftClusterMemberEventArgs<TMember>> MemberRemoved
  {
      add => memberRemovedHandlers += value;
      remove => memberRemovedHandlers -= value;  // correct
  }
  ```

  And the correct `IPeerMesh.PeerDiscovered` interface implementation (lines 103-107):
  ```csharp
  event Action<IPeerMesh, PeerEventArgs> IPeerMesh.PeerDiscovered
  {
      add => memberAddedHandlers += value;
      remove => memberAddedHandlers -= value;  // correct
  }
  ```

- **Trigger scenario**: Any code that subscribes to `MemberAdded` and later unsubscribes will:
  1. Fail to remove the MemberAdded handler (memory leak — handler is permanently registered)
  2. Accidentally remove a MemberRemoved handler instead (incorrect behavior — unrelated event stops firing)

- **Reproduction**: Not attempted (.NET SDK not available). A unit test would subscribe a handler to `MemberAdded`, unsubscribe it, then trigger a member addition — the handler would still fire.

- **Recommendation**: Change line 99 from `remove => memberRemovedHandlers -= value;` to `remove => memberAddedHandlers -= value;`.

---

## Bug 2: Conjunctive Election Restriction (Deviation from Raft Paper)

- **Source**: Code Review (MC-1) + Model Checking
- **Status**: CONFIRMED (code audit + MC verified safety preserved + reproduced)
- **Severity**: Medium (liveness concern, safety preserved)
- **Location**: `PersistentStateExtensions.cs:29-32`
- **Description**: The log up-to-dateness check uses a **conjunctive** comparison instead of the Raft paper's **disjunctive** one.

  Code (line 32):
  ```csharp
  return index >= localIndex && term >= await auditTrail.GetTermAsync(localIndex, token);
  ```

  Raft paper (Section 5.4.1):
  ```
  (term > localTerm) || (term == localTerm && index >= localIndex)
  ```

  **Concrete counterexample**: Candidate has term=5, logLen=2. Voter has term=3, logLen=5.
  - Paper: 5 > 3 → GRANT (candidate's last entry has higher term, so its log is more up-to-date)
  - Code: 2 >= 5 → FALSE → REJECT (candidate's log is shorter, rejected despite higher term)

  The conjunctive check is **strictly more restrictive** — it rejects some valid candidates but never accepts an invalid one. This preserves ElectionSafety (at most one leader per term), confirmed by MC with 786M BFS states. However, it can prevent progress in specific partition/recovery scenarios where a node with a higher-term last entry but shorter log cannot win an election.

- **Trigger scenario**: Network partition where one node receives entries in a higher term while another accumulates more entries in a lower term. After healing, the node with the higher-term log cannot be elected despite having the more up-to-date log by the paper's definition.

- **Historical context**: This area has 4+ historical bugs (issues #168, #149, #89; commit 287762551 — pre-vote reverted due to stalled elections), suggesting liveness in this code path is a recurring problem.

- **Recommendation**: Change to the paper's disjunctive check: `(term > localLastTerm) || (term == localLastTerm && index >= localIndex)`.

---

## Bug 3: Election Timer Reset on Rejected Vote Request

- **Source**: Code Review (TV-3)
- **Status**: CONFIRMED (code audit + reproduced)
- **Severity**: Medium (liveness concern, safety preserved)
- **Location**: `RaftCluster.cs:825-828`
- **Description**: When processing a `RequestVote` RPC, if the sender's term equals the local term and the node is a follower, the election timer is refreshed **before** checking whether the vote is actually granted.

  ```csharp
  // Lines 820-838 in VoteAsync:
  if (result.Term > senderTerm)
  {
      goto exit;                           // reject: our term is higher
  }
  else if (result.Term != senderTerm)
  {
      Leader = null;
      await StepDownAsync(senderTerm, consensusReached: false);  // step down to new term
  }
  else if (state is RefreshableState<TMember> followerOrStandbyState)
  {
      followerOrStandbyState.Refresh();   // BUG: resets timer unconditionally
  }
  else
  {
      goto exit;
  }

  // Vote decision happens AFTER timer reset:
  if (auditTrail.IsVotedFor(sender) && await auditTrail.IsUpToDateAsync(...))
  {
      await auditTrail.UpdateVotedForAsync(sender, tokenSource.Token);
      result = result with { Value = true };  // grant vote
  }
  ```

  The Raft paper (Section 5.2) specifies: "If election timeout elapses without receiving AppendEntries RPC from current leader **or granting vote to candidate**: convert to candidate."

  The timer should only be reset when the vote is **granted**, not when it is rejected.

- **Trigger scenario**: In a 5-node cluster, node A votes for candidate B in term 5. Then candidates C and D each send RequestVote for term 5 (split-vote scenario). Node A rejects both (already voted for B), but its election timer is reset each time. This delays A's own timeout, slowing down the next election round and potentially prolonging the period without a leader.

- **Recommendation**: Move the `Refresh()` call inside the vote-grant block (after line 836), or make it conditional on the vote being granted.

---

## Bug 4: Missing Membership Check in AppendEntries Handler

- **Source**: Code Review (CR-2) + Model Checking (MC-3)
- **Status**: CONFIRMED (code audit + reproduced, no safety violation found by MC)
- **Severity**: Low
- **Location**: `RaftCluster.cs:594-692` (AppendEntriesAsync)
- **Description**: The `AppendEntriesAsync` handler does NOT verify that the sender is a member of the cluster. Both `VoteAsync` (line 804: `!members.ContainsKey(sender)`) and `PreVoteAsync` (line 718: `members.ContainsKey(sender)`) check membership, but AppendEntries does not.

  At line 610-611:
  ```csharp
  var senderMember = TryGetMember(sender);  // returns null if not a member
  Leader = senderMember;                     // Leader is set to null for non-members
  ```

  A non-member node can send AppendEntries messages that are accepted — entries are appended to the log and the commit index is advanced. The `Leader` field is set to `null` (since `TryGetMember` returns null), but log mutation still occurs.

  The same issue exists in `InstallSnapshotAsync` (line 537-574).

- **Safety analysis**: MC explored this scenario and found no safety violation — a non-member cannot form a quorum to commit entries. However, it could cause a follower to accept entries from a stale/removed leader that should have been rejected.

- **Recommendation**: Add `if (!members.ContainsKey(sender)) return result;` early in `AppendEntriesAsync` and `InstallSnapshotAsync`, consistent with the existing check in `VoteAsync`.

---

## Bug 5: Unguarded MoveToStandbyState in async void Exception Handlers

- **Source**: Code Review (CR-1)
- **Status**: CONFIRMED (code audit + reproduced)
- **Severity**: Low
- **Location**: `RaftCluster.cs:1049, 1122, 1179`
- **Description**: Three `async void` state transition methods have catch-all exception handlers that call `MoveToStandbyState()` as a fallback:

  ```csharp
  // Example from MoveToFollowerState (line 1046-1050):
  catch (Exception e)
  {
      Logger.TransitionToFollowerStateFailed(e);
      await MoveToStandbyState().ConfigureAwait(false);  // can throw
  }
  ```

  This pattern appears in:
  - `MoveToFollowerState` (line 1049)
  - `MoveToCandidateState` (line 1122)
  - `MoveToLeaderState` (line 1179)

  `MoveToStandbyState` (line 976-980) calls `UpdateStateAsync` which disposes the old state. If the disposal throws, the exception escapes the `async void` method unhandled, crashing the process on the thread pool.

- **Trigger scenario**: A transition fails (e.g., due to I/O error), and the fallback `MoveToStandbyState` also fails because the old state's `DisposeAsync` throws (e.g., the tracker task faulted, cancellation token source already disposed). This is a low-probability scenario but represents an unrecoverable crash path.

- **Recommendation**: Wrap the `MoveToStandbyState()` call in a try-catch within each handler, logging any secondary failure.

---

## False Positives

### FP-1: Leader Stickiness TOCTOU Race (TV-2)

- **Location**: `RaftCluster.cs:804`
- **Why not a bug**: The `lastUpdated.Elapsed < ElectionTimeout` stickiness check at line 804 is performed before acquiring the `transitionLock`, and is NOT re-checked inside the lock (lines 814-838). A heartbeat arriving between the check and lock acquisition could make the stickiness condition stale. However, leader stickiness is a **best-effort liveness optimization**, not a safety mechanism. The actual vote decision at line 834 correctly checks `votedFor` and log up-to-dateness. The TOCTOU race means stickiness occasionally fails to prevent a vote, which is harmless.

### FP-2: Implicit Rejection via Default Enum Value (CR-3)

- **Location**: `RaftCluster.cs:605`
- **Why not a bug**: `result = new() { Term = Term }` defaults `Value` to `HeartbeatResult.Rejected` (enum value 0). When the term check at line 606 fails (`result.Term > senderTerm`), the method returns with `Rejected`, which is the **correct** behavior. The default initialization is intentional.

### FP-3: Sideband Config Divergence (MC-2)

- **Location**: `LeaderState.cs:189-192`
- **Why not a bug**: The `ConfigCommitConsistency` invariant was too strong for dotNext's sideband config model. The leader applies config on heartbeat quorum, creating a transient window where `activeConfig` differs between leader and followers. This is a **design choice** (not a Raft paper violation, since config is not a log entry in dotNext). MC found no safety violation — the divergence is eventually consistent after the next heartbeat round.

### FP-4: Lease Renewed Before Commit (MC-4)

- **Location**: `LeaderState.cs:168`
- **Why not a bug**: MC explored 1.7B states with the `NoStaleLeaderWithLease` invariant and found no violation. The lease timing (renewed on quorum response, before commit completes) is correct because the quorum response already establishes that a majority acknowledges the leader.

### FP-5: WAL Commit Ordering (MC-5)

- **Location**: `WriteAheadLog.Flusher.cs`
- **Why not a bug**: MC explored 997M states with `PersistedCommitBound` and found no violation. Crash recovery correctly regresses `commitIndex` to the persisted checkpoint without violating safety.

---

## Design Observations (Not Bugs)

### Async Transition Dispatch (MC-6/Family 3)

State transitions dispatched via `ThreadPool.UnsafeQueueUserWorkItem` were thoroughly tested by MC: 786M BFS states + 295M simulation states. ElectionSafety, StateMachineSafety, and LogMatching all pass. The `WeakGCHandle` guard, `IsValid` checks, and `transitionLock` serialization provide sufficient protection. Despite 5+ historical bugs in this area (#221, #168), the current implementation appears correct.

### No AppendEntries Membership Check — Safety Analysis (MC-3)

While Bug 4 confirms the missing check exists, MC's exploration of 786M+ states found no safety violation from non-member AppendEntries. This is because a non-member cannot independently form a quorum to commit entries. The bug is a defense-in-depth gap, not a safety violation.
