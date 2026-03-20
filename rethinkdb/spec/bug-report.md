# Bug Report — RethinkDB Raft

## Summary

- Bug families tested: 6
- Bugs found: 1 (confirmed real bug)
- Configs run: MC_hunt_vhb.cfg, MC_hunt_async.cfg, MC_hunt_config.cfg, MC_hunt_lifecycle.cfg, MC_hunt_reconfig_stepdown.cfg, MC_hunt_snapshot.cfg

## Bug 1: Election Safety Violation via ReenrollWithSameId (Jepsen #5289)

- **Bug Family**: 4 — Raft Lifecycle Management
- **Severity**: Critical
- **Invariant violated**: ElectionSafety
- **Config**: MC_hunt_lifecycle.cfg
- **Counterexample**: 26 states (output/MC_hunt_lifecycle.out)

### Trace Summary

1. **State 1-2**: s3 times out and becomes candidate (term 1)
2. **State 3**: s3's Raft state is externally erased (`EraseRaftState(s3)`) — persistent state wiped
3. **State 4**: s2 times out and becomes candidate (term 1)
4. **State 5**: s3 re-enrolls with the **same member ID** (`ReenrollWithSameId(s3)`) — appears as the same server but with empty state (term 0, no votedFor)
5. **State 6**: s3 times out again and becomes candidate (term 1) — can now vote for itself in term 1, even though its previous incarnation may have already voted in this term
6. **States 7-25**: Both s2 and s3 campaign in term 1. s2 wins votes from some peers, s3 wins votes from others (including s1 after its own re-enrollment)
7. **State 26**: Both s2 and s3 are leaders in term 1 — **ElectionSafety violated**

### Root Cause

When a server is erased (`multi_table_manager.cc` INACTIVE transition) and re-enrolled with the **same member ID**, it loses its `votedFor` and `currentTerm` persistent state. Other servers still recognize this member ID as the same entity. This allows the re-enrolled server to:

1. Vote again in a term where its previous incarnation already voted
2. Start elections in terms that its previous incarnation already participated in
3. Form a separate quorum, leading to two leaders in the same term

The fundamental issue: the re-enrolled server reuses the same identity but has fresh persistent state, violating Raft's assumption that `votedFor` is durable.

### Affected Code

- `src/clustering/generic/raft_core.hpp:347-348`: `current_term` and `voted_for` are persistent state that gets erased
- `multi_table_manager.cc`: INACTIVE transition triggers erasure without changing member ID
- `raft_member_id_t`: UUID identity that persists across erasure/re-enrollment

### Recommendation

Use `ReenrollWithNewId` (increment generation / new member ID) instead of `ReenrollWithSameId`. This ensures the re-enrolled server is treated as a new entity, preventing double-voting. This matches the fix proposed in Jepsen testing: each re-enrollment must use a fresh `raft_member_id_t`.

The spec confirms: `ReenrollWithNewId` (which increments `memberIdGeneration`) does NOT trigger this violation — only `ReenrollWithSameId` does.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| 1: VHB/Election | MC_hunt_vhb.cfg | 231.6M | No violation |
| 2: Async Step-Down | MC_hunt_async.cfg | 193.1M | No violation |
| 3: Config Change | MC_hunt_config.cfg | 150M | No violation (after CommittedConfig spec fix) |
| 5: Snapshot-Log Consistency | MC_hunt_snapshot.cfg | 459M | No violation |
| 2+3: Reconfig Step-Down Race | MC_hunt_reconfig_stepdown.cfg | 502M | No violation (after StartVirtualHeartbeat asyncVars fix) |

## Spec Fixes During Bug Hunting

- **CommittedConfig operator** (Case B, Round 1): Changed fallback from `config[s]` (latest, including uncommitted) to `[old |-> Server, new |-> Nil]` (initial config). The previous version allowed `LeaderContinueReconfiguration` to fire before the joint config entry was committed, creating 2 uncommitted config entries. After the fix, ConfigChangeSafety passes (150M states, 0 violations).

- **StartVirtualHeartbeat asyncVars** (Case B, Round 2): Added pendingStepDown/pendingNewTerm clearing when VHB causes a follower step-down via higher term. In the implementation, `candidate_or_leader_become_follower` (raft_core.tcc:1467-1499) kills the coroutine, cancelling any pending note_term step-down. The spec had `UNCHANGED asyncVars`, leaving stale pendingStepDown. Found via AsyncStepDownSafety violation (10-state counterexample). After the fix, AsyncStepDownSafety passes (502M states, 0 violations).

- **HandleInstallSnapshotRequest electionVars** (Case B, Round 2): Added missing `UNCHANGED electionVars` in the rejection branch. `votesGranted` was not assigned when the request was rejected due to stale term.

- **ReenrollWithSameId/ReenrollWithNewId electionVars** (Case B, Round 2): Added missing `UNCHANGED electionVars`. `votesGranted` was not assigned on re-enrollment.

- **MC.tla counter fixes** (Round 2): Fixed MCTakeSnapshot (snapshotCount in both primed and UNCHANGED), MCDuplicateMessage and MCReenrollWithSameId (missing snapshotCount in UNCHANGED).

## Convergence Summary

- **Round 1**: Spec converged after trace validation (3 traces) + model checking (777M states simulation, 11 invariants)
- **Round 2**: Trace re-validation (2 traces) after spec fixes from bug hunting. Both pass.
- **Key spec fixes during convergence**:
  - HandleAppendEntriesResponse: added `mmatchIndex` field (was using stale `Len(log[s])`)
  - HandleAppendEntriesRequest: added conflict detection (was unconditionally truncating log)
  - LeaderCompleteness invariant replaced with StateMachineSafety (correct Raft safety property)

## Total State Space Coverage

| Config | States | Invariants Checked |
|--------|--------|--------------------|
| MC.cfg (convergence) | 777M sim | ElectionSafety, LogMatching, StateMachineSafety + 8 structural |
| MC_hunt_vhb.cfg | 231.6M | VirtualHeartbeatTermConsistency, NoStaleLeaderCommit |
| MC_hunt_async.cfg | 193.1M | AsyncStepDownSafety |
| MC_hunt_config.cfg | 150M | ConfigChangeSafety |
| MC_hunt_lifecycle.cfg | Bug found | ElectionSafety, MemberIdUniqueness |
| MC_hunt_reconfig_stepdown.cfg | 502M | ElectionSafety, StateMachineSafety, AsyncStepDownSafety, ConfigChangeSafety |
| MC_hunt_snapshot.cfg | 459M | ElectionSafety, StateMachineSafety, LogMatching, SnapshotLogConsistency, CommitIndexMonotonicity, SnapshotBound, CommitIndexBound |
