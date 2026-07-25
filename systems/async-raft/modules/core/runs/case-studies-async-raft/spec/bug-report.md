# Bug Report — async-raft

## Summary

- Bug families tested: 5
- Bugs found: 5 (all bug families confirmed)
- Configs run: MC_hunt_commit.cfg, MC_hunt_election.cfg, MC_hunt_linearizable_read.cfg, MC_hunt_quorum.cfg, MC_hunt_snapshot.cfg
- Convergence: 2 rounds, 197M states (simulation), 700K traces — ElectionSafety, LogMatching, structural invariants pass

---

## Bug 1: Buggy Quorum Formula for Client Reads

- **Bug Family**: 1 — Buggy quorum formula
- **Severity**: Critical
- **Invariant violated**: QuorumConfirmation
- **Config**: MC_hunt_quorum.cfg
- **Counterexample**: 8 states (output/MC_hunt_quorum.out)

### Trace Summary

1. s3 wins election in term 1 with votes from {s1, s3}
2. s3 initiates a client read request (`ClientReadRequest(s3)`)
3. `BuggyQuorumNeeded(3)` computes `3 div 2 = 1` confirmation needed
4. Self-vote sets `readConfirmed[s3] = 1`
5. `readConfirmed[s3] (1) >= readQuorum[s3] (1)` → read succeeds immediately
6. But true majority of 3 servers requires `>1.5`, i.e., 2 confirmations

### Root Cause

The quorum formula in `client.rs:109-113` computes `c0_needed` using integer division:
- Odd N: `N / 2` (e.g., 3/2 = 1)
- Even N: `(N / 2) - 1` (e.g., 4/2 - 1 = 1)

After self-incrementing at `client.rs:122`, the threshold is off-by-one for all cluster sizes. For N=3: needs 1 but majority requires 2. For N=4: needs 1 but majority requires 3.

### Affected Code

- `core/client.rs:109-113`: Quorum formula computation
- `core/client.rs:122`: Self-vote pre-increment

### Recommendation

Replace with correct majority formula: `c0_needed = (members.len() + 1) / 2` (ceiling division), or equivalently `c0_needed = members.len() / 2 + 1` then subtract 1 for the self-vote.

---

## Bug 2: Buggy Log Up-to-Date Check in Vote Granting

- **Bug Family**: 2 — AND instead of lexicographic comparison
- **Severity**: Critical
- **Invariant violated**: LeaderCompleteness
- **Config**: MC_hunt_election.cfg
- **Counterexample**: 51 states (output/MC_hunt_election.out)

### Trace Summary

1. s1 becomes leader in term 1, appends entry `[term=1]` at index 1
2. Entry is NOT replicated before s1 loses leadership
3. s2 and s3 (both with empty logs) run elections in higher terms
4. s2 requests votes; s3 grants vote to s2 despite s2 having no entries
5. s2 becomes leader in term 3 WITHOUT s1's term-1 entry
6. s2 appends `[term=3]` entries, replicates to s3, commits
7. **Violation**: s2 (leader, term 3) has `log[1].term = 3` but s1 has `log[1].term = 1` — committed entries diverge

### Root Cause

`vote.rs:53` uses AND instead of lexicographic comparison for log up-to-date check:
```rust
// Buggy: (term >= myTerm) && (index >= myIndex)
// Correct: term > myTerm || (term == myTerm && index >= myIndex)
```

This rejects candidates with higher `lastLogTerm` but lower `lastLogIndex`, and accepts candidates with same term but incomplete logs. A candidate without committed entries can win an election.

### Affected Code

- `core/vote.rs:53`: Log up-to-date comparison

### Recommendation

Replace AND with lexicographic comparison per Raft §5.4.1:
```rust
msg.last_log_term > self.last_log_term
    || (msg.last_log_term == self.last_log_term && msg.last_log_index >= self.last_log_index)
```

---

## Bug 3: Unconditional commit_index Update + Optimistic match_index

- **Bug Family**: 3 — Unconditional commit_index, optimistic match_index
- **Severity**: Critical
- **Invariant violated**: CommitIndexSafety (hunting), LeaderCompleteness (convergence)
- **Config**: MC_hunt_commit.cfg
- **Counterexample**: 65 states (output/MC_hunt_commit.out), also 59 states during convergence (output/MC_sim_LeaderCompleteness_BugFamily3.out)

### Trace Summary

1. s1 becomes leader, initializes `matchIndex[s1][*] = LastLogIndex(s1)` (optimistic)
2. s1 appends 3 entries via client requests
3. s1 replicates to s2 successfully (matchIndex[s1][s2] = 3)
4. s3 receives only partial replication (1 entry) due to message loss
5. s1's `AdvanceCommitIndex` sees matchIndex[s1][s3] still at optimistic value
6. s1 commits index 3, but s3 only has 1 entry → **CommitIndexSafety violated**

Also during convergence: follower s1 receives AppendEntries with `mcommitIndex=2`, log consistency check fails (prevLogTerm mismatch), but `commitIndex[s1]` is set to 2 unconditionally. s1 now has `commitIndex=2` with only 1 log entry of wrong term → **LeaderCompleteness violated**.

### Root Cause

Two compounding bugs:

**Bug 3a**: `append_entries.rs:28` — `self.commit_index = msg.leader_commit` is executed BEFORE log consistency check (line 80+). Even rejected AppendEntries advances commit_index.

**Bug 3b**: `replication.rs:27-28` — `match_index: self.core.last_log_index` initializes all followers' matchIndex to the leader's log length, not 0 per Raft Figure 2.

### Affected Code

- `core/append_entries.rs:28`: Unconditional commit_index assignment
- `core/replication.rs:27-28`: Optimistic match_index initialization

### Recommendation

**Fix 3a**: Move commit_index update after log consistency check, and apply `min(leaderCommit, lastNewEntry)` per Raft Figure 2 Rule 5.

**Fix 3b**: Initialize match_index to 0 for all followers per Raft Figure 2, or at minimum to the last confirmed replicated index.

---

## Bug 4: Snapshot Installation Doesn't Update commit_index

- **Bug Family**: 4 — Snapshot state clobbering
- **Severity**: High
- **Invariant violated**: SnapshotConsistency
- **Config**: MC_hunt_snapshot.cfg
- **Counterexample**: 41 states (output/MC_hunt_snapshot.out)

### Trace Summary

1. s3 becomes leader, commits entries, takes snapshot at index 1
2. s3 sends InstallSnapshotRequest to s1 with `mlastIncludedIndex=1`
3. s1 installs snapshot: `snapshotIndex[s1] = 1`
4. But `commitIndex[s1]` remains at 0 (not updated during snapshot install)
5. **Violation**: `snapshotIndex[s1] = 1 > commitIndex[s1] = 0`

### Root Cause

`install_snapshot.rs:135-138` updates `last_applied` and `snapshot_index` but NOT `commit_index`. After snapshot installation, `commit_index < snapshot_index`, which breaks the invariant that all snapshotted state has been committed.

### Affected Code

- `core/install_snapshot.rs:135-138`: Missing commit_index update

### Recommendation

After snapshot installation, set `commit_index = max(commit_index, snapshot.last_included_index)`.

---

## Bug 5: Client Read Continues After Leader Deposition

- **Bug Family**: 6 — Read after deposition
- **Severity**: Critical
- **Invariant violated**: LinearizableRead
- **Config**: MC_hunt_linearizable_read.cfg
- **Counterexample**: 21 states (output/MC_hunt_linearizable_read.out)

### Trace Summary

1. s2 becomes leader in term 1, initiates client read (`readActive[s2] = TRUE`)
2. `BuggyQuorumNeeded(3) = 1`, self-vote sets `readConfirmed[s2] = 1`
3. s1 starts election in higher term, messages propagate
4. s2 receives AppendEntriesResponse with `term ≠ currentTerm[s2]`
5. `ClientReadConfirm` triggers deposition branch (client.rs:181-184):
   - Sets `state[s2] = Follower` (deposition detected)
   - Updates `currentTerm[s2]`
   - **BUG: No break/return — falls through to confirmation counting**
   - Increments `readConfirmed[s2]`
6. `readConfirmed[s2] >= readQuorum[s2]` with `state[s2] = Follower` → **LinearizableRead violated**

### Root Cause

`client.rs:181-184` detects higher-term response and sets `target_state = Follower`, but does NOT break or return from the response handling loop. Execution falls through to lines 187-203 which increment the confirmation counter. The read can then complete (return `Ok(())`) even though the server is no longer leader.

### Affected Code

- `core/client.rs:181-184`: Missing break/return after deposition detection
- `core/client.rs:187-203`: Confirmation counting reached after deposition

### Recommendation

Add `return` or `break` after detecting deposition at client.rs:184. The read should be aborted immediately when the server discovers it is no longer leader.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| 5 (Membership change) | N/A | N/A | Not testable — ConfigChangeLimit=0 in all configs; no hunting config for membership changes. Spec models the bug but no dedicated test. |
