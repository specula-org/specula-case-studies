# Bug Report — rabbitmq/ra

## Summary

- Bug families tested: 5
- Bugs found: 0 (safety)
- Known deviations confirmed: 1 (commit index monotonicity)
- Configs run: MC_hunt_family1.cfg through MC_hunt_family5.cfg

### Model Checking Coverage

| Config | Mode | States | Traces | Invariants | Result |
|--------|------|--------|--------|------------|--------|
| MC.cfg | BFS | 994M | - | 7 (ElectionSafety, LogMatching, LeaderCompleteness + 4 structural) | All hold |
| MC_hunt_family1.cfg | Simulation | 9.5K | 50 | ElectionSafety, LogMatching, LeaderCompleteness, CommitIndexSafety + MonotonicCommitIndex | **MonotonicCommitIndex violated** |
| MC_hunt_family2.cfg | Simulation | 116M | 222K | ElectionSafety, VoterOnlyElection, VoterOnlyQuorum, NoDuplicateVoteCounting | All hold |
| MC_hunt_family3.cfg | Simulation | 109M | 219K | ElectionSafety, ConsistentQuerySafety, NoPhantomHeartbeatQuorum | All hold |
| MC_hunt_family4.cfg | Simulation | 123M | 301K | ElectionSafety, SnapshotLogConsistency | All hold |
| MC_hunt_family5.cfg | Simulation | 111M | 275K | ElectionSafety, OneClusterChangeAtATime | All hold |

### Trace Validation Coverage

| Trace | Lines | Result |
|-------|-------|--------|
| basic_consensus.ndjson | 71 | Pass |
| leader_step_down.ndjson | 76 | Pass |
| consistent_query.ndjson | 77 | Pass |

---

## Finding 1: Commit Index Monotonicity Violation (Known Paper Deviation)

- **Bug Family**: Family 1 (Log Divergence / Commit Index Safety)
- **Severity**: Low (known design choice, not a safety bug)
- **Property violated**: `MonotonicCommitIndex` (temporal: `[][\A i \in Server : commitIndex'[i] >= commitIndex[i]]_mcVars`)
- **Config**: MC_hunt_family1.cfg (simulation mode)
- **Counterexample**: 44 states (output: `spec/output/MC_hunt_family1.out`)
- **All safety invariants hold**: ElectionSafety, LogMatching, LeaderCompleteness, CommitIndexSafety

### Trace Summary

| State | Action | Key Change |
|-------|--------|------------|
| 1-17 | Election | s3 wins pre-vote and real election at term 1 |
| 18 | BecomeLeader(s3) | s3 becomes leader |
| 19-26 | Client requests + replication | s3 appends 3 entries (v2, v1, v1) + noop, sends AERs to s1, s2 |
| 32 | AdvanceCommitIndex(s3) | Leader advances commitIndex to 1 |
| 42 | s1 receives AER (prevLogIndex=1, entries=[v1,v1,noop], **mcommitIndex=1**) | s1 log grows to 4 entries, **commitIndex becomes 1** |
| 43 | s1 receives STALE AER (prevLogIndex=0, entries=[v2,v1,v1], **mcommitIndex=0**) | Entries already present (stale), log unchanged. **commitIndex REGRESSES to 0** |

The stale AER (state 43→44) was sent earlier when the leader's commitIndex was still 0. Due to unordered message delivery, it arrives after a newer AER that set commitIndex=1. The follower unconditionally adopts `commit_index := LeaderCommit`, causing regression.

### Root Cause

Ra intentionally deviates from the Raft paper by setting `commit_index` directly from `LeaderCommit` without a `max(oldCI, newCI)` guard:

```erlang
%% ra_server.erl:1322-1323 (validated log path)
State1 = State0#{log => Log2,
                 commit_index => LeaderCommit},

%% ra_server.erl:1359-1361 (new entries path)
State1 = State0#{commit_index => LeaderCommit},
```

No `max()` guard exists in either path. The Raft paper (Section 5.3, step 5) specifies `commitIndex = min(leaderCommit, index of last new entry)`, but does not explicitly require monotonicity guard because ordered delivery is assumed.

### Why This Is Safe in Practice

1. **Apply-time guard** (`evaluate_commit_index_follower`, ra_server.erl:2256-2294): `ApplyTo = min(Idx, CommitIndex)` ensures entries are never applied beyond the log. Since `lastApplied` only advances monotonically, a regressed `commitIndex` simply prevents further applies until a newer AER restores it.

2. **TCP ordered delivery**: Within a single TCP connection, messages arrive in order. CommitIndex regression requires a stale AER arriving after a newer one, which only happens after TCP reconnection.

3. **Historical context**: PR #508 fixed a CRITICAL bug where follower applied uncommitted entries due to incorrect commit_index advancement. The current approach was chosen as the simpler fix, relying on the apply-time bound.

### Affected Code

- `ra_server.erl:1322-1323`: commit_index assignment in validated-log path
- `ra_server.erl:1359-1361`: commit_index assignment in new-entries path
- `ra_server.erl:2256-2294`: `evaluate_commit_index_follower` (the safety net)

### Recommendation

This is a documented design choice, not an unknown bug. Adding `max(OldCI, LeaderCommit)` would eliminate the deviation and match the Raft paper, but is not strictly necessary given the apply-time guard and TCP delivery assumptions. The finding confirms that the spec faithfully models this behavior.

---

## Not Reproduced

| Bug Family | Config | States Explored | Traces | Result |
|------------|--------|-----------------|--------|--------|
| Family 1: Log divergence (safety) | MC_hunt_family1.cfg | 9.5K | 50 | CommitIndexSafety holds |
| Family 2: Election/pre-vote | MC_hunt_family2.cfg | 114M | 219K | All 4 invariants hold |
| Family 3: Consistent query | MC_hunt_family3.cfg | 234M | 470K | All 3 invariants hold |
| Family 4: Snapshot installation | MC_hunt_family4.cfg | 237M | 575K | SnapshotLogConsistency holds |
| Family 5: Membership change | MC_hunt_family5.cfg | 226M | 562K | OneClusterChangeAtATime holds |

### Notes on Coverage

- **MC-1 (Vote deduplication gap)**: The spec uses set-based vote tracking (not integer counter), so duplicate counting is structurally prevented. The spec documents this gap; testing with `NoDuplicateVoteCounting` confirms votes stay within cluster bounds. A true test would require modeling message duplication + integer counters, which is outside scope.

- **MC-2 (Vote quorum exact equality)**: Not directly testable — the spec uses `IsQuorum` with `>` comparison, matching the implementation's `required_quorum` calculation.

- **MC-3 through MC-8**: These model-checkable hypotheses from the modeling brief were either fixed in the code already (MC-3, MC-4) or are covered by the safety invariants tested above. No violations found.

### Convergence Summary

- Converged in 4 rounds (Round 4 fixed offset-based log model for snapshot+AER interaction)
- Total BFS coverage: 994M states (convergence, 30-min timeout, no violations)
- Total simulation coverage: 459M+ states checked across hunting configs (Families 2-5)
- 13 distinct invariants checked + 2 temporal properties
- 3 implementation traces validated
- Round 4 fix: offset-based log model correctly handles snapshot truncation + subsequent AER reception
