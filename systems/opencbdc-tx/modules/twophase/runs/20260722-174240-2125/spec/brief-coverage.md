# Brief Coverage Audit

## Bug Families (§2) → Hunt Cfgs

| Family | Hunt Cfg | Notes |
|--------|----------|-------|
| Family 1: Leader/Follower Asymmetry | `MC_hunt_family1.cfg` | Targets `MCLeaderHasHandler` and `MCHandlerOnlyWhenLeader`. Two coordinator nodes, two shard nodes. High election limits (4) to explore handler activation/deactivation patterns. |
| Family 2: Non-Atomic RSM Transitions | `MC_hunt_family2.cfg` | Targets `MCRSMCommitImpliesShardsLocked`. Single leader, high RSM replicate limit (8) + crash limits (2) to exercise RSM-before-shard divergence. |
| Family 3: Sentinel Communication Gaps | `MC_hunt_family3.cfg` | Targets `MCNonLeaderRejectsRequest`. Two coordinators (one non-leader), high sentinel request limits (4) to explore retry patterns. |
| Family 4: Unbounded Raft Log Growth | `MC_hunt_family4.cfg` | Structural exploration only (no family-specific invariant). Log growth (6) with minimal other actions. |
| Family 5: Batch Processing Races | `MC_hunt_family5.cfg` | `MCBatchConsistency` always active. High batch add (8) and swap (4) limits to exercise batch lifecycle races. |
| Family 6: In-Memory Shard State Loss | `MC_hunt_family6.cfg` | Targets `MCLockedNotInUhs`. Shard crash limit (3) with RSM operations to test state loss scenarios. |

## Safety Invariants (§5) → Definition and Activation

| Invariant | Defined in `base.tla` | Wired in `MC.tla` | Enabled in hunt cfg(s) |
|-----------|----------------------|-------------------|------------------------|
| InvLeaderHasHandler | Family 1 | `MCLeaderHasHandler` | `MC_hunt_family1.cfg` |
| InvHandlerOnlyWhenLeader | Family 1 | `MCHandlerOnlyWhenLeader` | `MC_hunt_family1.cfg` |
| InvRSMCommitImpliesShardsLocked | Family 2 | `MCRSMCommitImpliesShardsLocked` | `MC_hunt_family2.cfg` |
| InvNonLeaderRejectsRequest | Family 3 | `MCNonLeaderRejectsRequest` | `MC_hunt_family3.cfg` |
| InvBatchConsistency | Family 5 | `MCBatchConsistency` | `MC.cfg` + all hunt cfgs (structural) |
| InvLockedNotInUhs | Family 6 | `MCLockedNotInUhs` | `MC_hunt_family6.cfg` |
| InvUhsConsistent | Structural | `MCUhsConsistent` | `MC.cfg` + all hunt cfgs (structural) |
| InvShardStateConsistent | Structural | `MCShardStateConsistent` | `MC.cfg` + all hunt cfgs (structural) |
| InvRSMDoneImpliesShardsDiscarded | Structural | `MCRSMDoneImpliesShardsDiscarded` | `MC.cfg` + hunt families 2, 6 |

### Invariant Activation Verification (read from cfg files)

- `MC.cfg`: structural only (TypeOK, UhsConsistent, ShardStateConsistent, RSMDoneImpliesShardsDiscarded, BatchConsistency). Extension invariants commented out.
- `MC_hunt_family1.cfg`: structural + `MCLeaderHasHandler` + `MCHandlerOnlyWhenLeader`. No `MCRSMDoneImpliesShardsDiscarded`.
- `MC_hunt_family2.cfg`: structural + `MCRSMDoneImpliesShardsDiscarded` + `MCRSMCommitImpliesShardsLocked`.
- `MC_hunt_family3.cfg`: structural + `MCNonLeaderRejectsRequest`.
- `MC_hunt_family4.cfg`: structural only (log growth exploration — no family invariant proposed in brief §5 for Family 4).
- `MC_hunt_family5.cfg`: structural + `MCBatchConsistency`.
- `MC_hunt_family6.cfg`: structural + `MCRSMDoneImpliesShardsDiscarded` + `MCBatchConsistency` + `MCLockedNotInUhs`.

## Model-Checkable Findings (§6.1) → Hunt Cfg Targeting

| ID | Description | Expected Violated Invariant | Hunt Cfg |
|----|-------------|----------------------------|----------|
| MC1 | Shard crash during 2PC — coordinator completes dtx shard partially applied | `ShardStateMatchesCoordinator` → `MCRSMDoneImpliesShardsDiscarded`, `MCLockedNotInUhs` | `MC_hunt_family6.cfg` (shard crash + RSM ops) |
| MC2 | RSM prepare→commit before shard lock completes — crash recovery re-issues prepare | `AtMostOnePreparePerDtx` → `MCRSMCommitImpliesShardsLocked` | `MC_hunt_family2.cfg` (RSM-before-shard divergence) |
| MC3 | Coordinator handler activation delay after becoming leader allows stale responses | `LeaderHasHandler` → `MCLeaderHasHandler` | `MC_hunt_family1.cfg` (two coord nodes, election limits) |
| MC4 | Locking shard RPC active while follower — stale/inconsistent state | `HandlerOnlyWhenLeader` → `MCHandlerOnlyWhenLeader` | `MC_hunt_family1.cfg` (shard node asymmetry) |
| MC5 | Sentinel sends to coordinator that just lost leadership (handler still active) | `NonLeaderRejectsRequest` → `MCNonLeaderRejectsRequest` | `MC_hunt_family3.cfg` (two coordinators, non-leader requests) |

**Note on MC1**: The brief proposes `ShardStateMatchesCoordinator` and `NoOutputsCreatedWithoutInputsLocked` for this finding. Our spec maps these to `InvRSMDoneImpliesShardsDiscarded` (structural: done implies all shards discarded) and `InvLockedNotInUhs` (Family 6: locked UTXOs not in UHS set). Both are enabled in `MC_hunt_family6.cfg`.

**Note on MC2**: The brief proposes `AtMostOnePreparePerDtx` for this finding. Our spec's `InvRSMCommitImpliesShardsLocked` captures the stronger property: RSM should not reach commit before shards have locked. This is the operational invariant that MC2's scenario would violate.

## Out-of-Scope Families

- **Family 7 (Error Handling Gaps, LOW)**: No invariants proposed in brief §5. Not model-checkable per brief's own assessment (§7: "Better suited to code review than TLA+").

## Gaps and Honest Notes

1. **Family 4 (No Snapshots)**: The brief §5 proposes no invariants for Family 4. The `MC_hunt_family4.cfg` explores log growth structurally but has no invariant violation to hunt. This is consistent with the brief's assessment (medium priority, practical deployment concern, not a safety issue).

2. **Family 5 (Batch Processing)**: The `MCBatchConsistency` invariant is structural (always active). The brief's suggested variables (`currentBatch`, `pendingTxs`, `execThreads`) are modeled but the yield-based scheduling is abstracted to non-deterministic `CoordScheduleExec`/`CoordCompleteExec` transitions. No additional family-specific invariant is defined since the brief §5 only proposes `BatchConsistency`.

3. **MC findings vs hunt cfgs**: MC2 uses `MCRSMCommitImpliesShardsLocked` rather than a separate `AtMostOnePreparePerDtx` invariant. The RSM-commit-implies-shards-locked check is the stronger invariant — if RSM commits before all shards lock, the invariant catches the exact race that MC2 describes. This is an honest tightening, not a gap.
