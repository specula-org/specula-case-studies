# Changelog: MongoDB Chunk Migration Spec Validation

## Round 1 - Trace Validation
- [fix] Trace.cfg: added CHECK_DEADLOCK FALSE, removed PROPERTIES TraceMatched (trivially fails without fairness with INIT/NEXT). Trace completion verified by state depth.
- basic_commit.ndjson: PASS (13 states, depth 13)
- back_to_back.ndjson: PASS (41 states, depth 26, includes SilentRangeDeleterProcessTask + SilentForgetBecomeDurable)

## Round 1 - Model Checking
- MC.cfg (BFS, 46 workers): 16,624 states generated, 7,105 distinct, depth 65 — all 4 structural invariants pass, no errors

## Bug Hunting
- [bug] MC_hunt_family1_commit.cfg: NoPrematureRangeDeletion violated (24 states). M1 commit cleanup replayed after stepdown marks M2's task as ready — missing migrationId in markAsReadyRangeDeletionTaskLocally filter.
- [bug] MC_hunt_family2.cfg: CommitPathHandlesRecipientRemoval violated (6 states). Commit path stuck at cmtAdvTxn when recipient removed — no ShardNotFound try-catch (commit path line 252-255 vs abort path line 361-375).
- [bug] MC_hunt_family3.cfg: NoLimboCoordinatorDoc violated (4 states). ConfigCommitFail leaves coordinator doc with NoDecision and no active migration — _cleanup(false) doesn't set decision when _state >= kCommittingOnConfig.
- [bug] MC_hunt_family5.cfg: OrphanCountBounded violated (14 states). persistUpdatedNumOrphans $inc replayed on recovery after stepdown doubles orphan count.
- [fix-inv] MC_hunt_family1.cfg: ActiveMigrationHasTask too strong (Case A, 6 states). After partial abort cleanup + stepdown, task may be deleted but coordDoc persists. Invariant should only require task for NoDecision docs.

## Result
Converged in 1 round. Bug hunting: 4 bugs found (Family 1 commit, Family 2, Family 3, Family 5).
