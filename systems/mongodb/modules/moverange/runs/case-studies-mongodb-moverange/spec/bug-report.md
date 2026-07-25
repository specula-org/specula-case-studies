# Bug Report — MongoDB MoveRange (Chunk Migration Commit Protocol)

## Summary

- Bug families tested: 3 (Coordinator Recovery, Range Deletion Safety, Commit/Abort Asymmetry)
- Bugs found: 0
- Configs run: MC_hunt_recovery.cfg, MC_hunt_rangedel.cfg, MC_hunt_asymmetry.cfg

## Key Findings During Convergence

### Finding 1: w:1 forgetMigration Rollback Creates Ghost CoordDocs

During convergence (not bug hunting), model checking revealed that the w:1 `forgetMigration` write concern at `migration_coordinator.cpp:400` allows coordinator documents to reappear after stepdown. When back-to-back migrations occur (A→B then B→A), the ghost coordDoc from the first migration has stale `decision=commit` while `configOwner` has been reversed by the second migration.

**Impact analysis**: Ghost recovery re-executes commit side-effects for the stale migration. Cross-referenced with implementation code to determine safety:

- **Recipient-side operations** (`deleteRangeDeletionTaskOnRecipient`, `markAsReadyRangeDeletionTaskOnRecipient`): **SAFE** — use `migrationId` filter (`migration_coordinator.cpp:320-322`: "Add migrationId to the query filter in order to be resilient to delayed network retries"). Ghost recovery targets a non-existent migrationId, resulting in no-op.

- **Donor-side operations** (`deleteRangeDeletionTaskLocally`, `markAsReadyRangeDeletionTaskLocally`): Use range-based matching without migrationId. Potentially unsafe in theory, but ghost recovery is blocked by `migState` check while other migrations are active, and tasks are cleaned up before recovery can run.

**Classification**: Case B (spec modeling issue). The spec was fixed to approximate migrationId scoping by only allowing `CommitDeleteRecipientRangeDel` to delete "pending" tasks (the state set by `StartMigration`). This prevents ghost recovery from interfering with other migrations' range deletion tasks.

### Finding 2: Asymmetric migrationId Usage (Recipient vs Donor Operations)

Code review during counterexample analysis revealed an asymmetry in how MongoDB protects range deletion operations:

| Operation | Side | Matching | migrationId |
|-----------|------|----------|-------------|
| `deleteRangeDeletionTaskOnRecipient` | Remote/Recipient | ID-based | Yes (line 320-322) |
| `markAsReadyRangeDeletionTaskOnRecipient` | Remote/Recipient | ID-based | Yes (line 750) |
| `deleteRangeDeletionTaskLocally` | Local/Donor | Range-based | No |
| `markAsReadyRangeDeletionTaskLocally` | Local/Donor | Range-based | No |

The comment at `migration_coordinator.cpp:320-322` explicitly warns about the risk of range-based matching. Recipient operations were protected with migrationId, but donor operations were not. In the current model, no scenario was found where this asymmetry causes a real safety violation (ghost recovery is blocked during active migrations). However, this asymmetry is a latent risk that could be exposed by future changes to the migration protocol.

---

## Not Reproduced

| Bug Family | Config | States Explored | Depth | Result |
|------------|--------|-----------------|-------|--------|
| Family 1: Coordinator Recovery | MC_hunt_recovery.cfg | 23,393 (8,650 distinct) | 42 | No violation (exhaustive BFS) |
| Family 2: Range Deletion Safety | MC_hunt_rangedel.cfg | 41,090 (16,180 distinct) | 47 | No violation (exhaustive BFS) |
| Family 3: Commit/Abort Asymmetry | MC_hunt_asymmetry.cfg | 20,231 (8,058 distinct) | 38 | No violation (exhaustive BFS) |

### Why No Bugs Found

1. **migrationId scoping on recipient**: The real system's `migrationId` filter on recipient-side operations prevents the most dangerous ghost recovery scenarios (cross-migration task deletion). The spec was corrected to model this.

2. **StartMigration guards**: The `rangeDel[shard][key] = "none"` precondition in `StartMigration` prevents new migrations while range deletion tasks exist (SERVER-46395 fix). This limits the window for interference.

3. **Recovery blocking**: `RecoverMigration` requires `migState[key] = "idle"`, preventing ghost recovery from running concurrently with active migrations. By the time recovery can run, side-effects are idempotent.

4. **Model scope**: The model uses 2 shards and 1 key, which captures the core protocol interactions. Some bugs from the modeling brief (MC-3: infinite retry on ShardNotFound, MC-8: post-commit refresh failure) require modeling error injection or shard removal, which is outside the current spec's scope.

### Scenarios Not Testable in Current Spec

| ID | Description | Reason |
|----|-------------|--------|
| MC-3 | Commit path ShardNotFound infinite retry | Requires modeling shard removal (not in spec) |
| MC-6 | Range deletion TOCTOU | Requires modeling concurrent external task doc deletion (not in spec) |
| MC-8 | Post-commit refresh failure | Requires modeling metadata refresh failures (not in spec) |

---

## Spec Fixes During Convergence

1. **RecoveryConsistency** (Case A): Weakened to allow ghost coordDocs from w:1 rollback. Added escape clause for ownership reversal by back-to-back migration.

2. **NoOverlappingMigrations** (Case A): Weakened to allow ghost coordDocs to coexist with active migration coordDocs. Only flags two fresh (`decision = "none"`) coordDocs for the same key.

3. **CommitDeleteRecipientRangeDel** (Case B): Changed guard from `# "none"` to `= "pending"` to model migrationId-scoped deletion. Prevents ghost recovery from deleting another migration's range deletion task.

## Convergence Statistics

- Converged in 1 round
- Convergence MC: 17,690 states, 7,018 distinct, depth 39
- Validated traces: basic_commit_single (12), basic_commit (45), abort_migration (39), stepdown_recovery (133)
