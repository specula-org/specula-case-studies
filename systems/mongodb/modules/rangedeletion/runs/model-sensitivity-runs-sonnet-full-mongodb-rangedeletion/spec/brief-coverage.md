# Brief Coverage Self-Audit

Maps brief §2 (Bug Families), §5 (Invariants), and §6.1 (Model-Checkable Findings)
to spec and MC artifacts. Generated after writing all spec files.

---

## §2 Bug Families → Hunt Configs

| Family | Brief Priority | Hunt Config | Target Invariant(s) | Assessment |
|---|---|---|---|---|
| F1: Non-atomic coordinator+task init | High | `MC_hunt_family1.cfg` | `MCNoOrphanOnCommit` | Covered. `WriteCoordDoc` and `WriteRangeDeletionTask` are split; `Crash` fires between them; `CommitSilentSkip` models the early-return at line 294. |
| F2: Pending-flag activation gaps | High | `MC_hunt_family2.cfg` | `MCNoAbortedCoordWithStuckPendingRecipient`, `MCNoOrphanOnCommit` | Covered. `MarkRecipientTaskReadyFails` models uncaught ShardNotFound at line 382. `RollbackForgetMigration` models w:1 rollback. Both mechanisms in one config because they share state space (both require coordDoc + task interaction). |
| F3: TOCTOU overlap snapshot | Medium | `MC_hunt_family3.cfg` | `MCNoSimultaneousDonorProcessing` | Covered. `GetOverlapSnapshot`, `RegisterTaskPostSnapshot` modeled. Two migration IDs used to allow concurrent processing scenario. |
| F4: Recovery scan non-atomicity | Low | `MC_hunt_family4.cfg` | `MCRecoveryCompleteness` | Covered as spec-coverage target. `Recovery` models two-pass scan atomically (the real lock protection makes the race narrow). Verifies that `RecoveryCompleteness` holds after crashes. |

---

## §5 Invariants → Spec + Hunt Config Coverage

| Invariant | Type | Spec Location | Enabled in Hunt Config | Notes |
|---|---|---|---|---|
| `OrphanEventualCleanup` | Liveness | `base.tla` (temporal property) | Not in hunt cfg (liveness requires `LiveSpec`) | Modeled as `NoOrphanOnCommit` safety proxy in MC layer. `MCNoOrphanOnCommit` in `MC_hunt_family1.cfg`. |
| `AbortedMigrationRecipientCleanup` | Liveness | `base.tla` (temporal property) | Not in hunt cfg | Safety proxy: `MCNoAbortedCoordWithStuckPendingRecipient` in `MC_hunt_family2.cfg`. |
| `NoPermanentPendingTask` | Liveness | `base.tla` (temporal property) | Not in hunt cfg | Subsumed by Family 1 and Family 2 safety proxies in their respective hunt configs. |
| `NoOrphanedDocAfterForget` | Safety | `MCNoOrphanOnCommit` (approximates brief intent) | `MC_hunt_family1.cfg`, `MC_hunt_family2.cfg` | Brief §5 calls this "after forgetMigration is durable"; modeled as coordDoc=committed+donorTask=absent state check. |
| `NoSimultaneousOverlappingDeletions` | Safety | `base.tla:NoSimultaneousDonorProcessing`, `MC.tla:MCNoSimultaneousDonorProcessing` | `MC_hunt_family3.cfg` | Enabled. |
| `RecoveryCompleteness` | Safety | `base.tla:RecoveryCompleteness`, `MC.tla:MCRecoveryCompleteness` | `MC_hunt_family4.cfg` | Enabled. Also always on in `MC.cfg`. |

### Note on Liveness in MC

TLC cannot check liveness with arbitrary stuttering; temporal properties require `PROPERTIES` in the cfg with `LiveSpec`. The hunt configs use `MCSpec` (safety only). The liveness properties `OrphanEventualCleanup`, `AbortedMigrationRecipientCleanup`, and `NoPermanentPendingTask` in `base.tla` are correct TLA+ and can be checked with `LiveSpec` in a dedicated liveness run. The safety proxy invariants in the MC hunt configs are the primary bug-detection tool.

---

## §6.1 Model-Checkable Findings → Hunt Config Reachability

| Finding ID | Description | Hunt Config | Fault Setup Makes It Reachable? |
|---|---|---|---|
| MC1 | Crash between `insertMigrationCoordinatorDoc` and `createAndPersistRangeDeletionTask` causes donor range never deleted | `MC_hunt_family1.cfg` | Yes. `MaxCrashCount=3` allows crash between `WriteCoordDoc` and `WriteRangeDeletionTask`. `CommitSilentSkip` fires on recovery. Expected: `MCNoOrphanOnCommit` violated. |
| MC2 | `markAsReadyRangeDeletionTaskOnRecipient` throws ShardNotFound (uncaught), recipient task stays pending | `MC_hunt_family2.cfg` | Yes. `MaxRemoveShardCount=2` removes recipient shard, enabling `MarkRecipientTaskReadyFails`. Expected: `MCNoAbortedCoordWithStuckPendingRecipient` violated. |
| MC3 | Post-snapshot task registration allows two concurrent deletions | `MC_hunt_family3.cfg` | Yes. `GetOverlapSnapshot` followed by `RegisterTaskPostSnapshot` with two migration IDs. Expected: `MCNoSimultaneousDonorProcessing` violated. |
| MC4 | ForgetMigration w:1 rolled back; recovery re-runs with absent donor task | `MC_hunt_family2.cfg` | Yes. `MaxRollbackCount=2` enables `RollbackForgetMigration`. Re-triggers `CommitSilentSkip` on recovery. Expected: `MCNoOrphanOnCommit` also violated (covered in family2 config). |

---

## Gaps and Explicit Out-of-Scope Notes

1. **`AdvanceTransactionOnRecipientAbort` is a no-op in the spec.** The RPC advances the transaction number but has no state-variable effect in the spec's abstraction level. This is intentional — the call is the preamble to `markAsReadyRangeDeletionTaskOnRecipient`, and Family 2's bug is in the latter. No invariant targets this action alone.

2. **`coordDocDurable` not captured in traces.** This field represents replication state not directly observable from document reads. Accepted limitation — `RollbackForgetMigration` is a fault-injection-only action, not trace-observable. Trace validation covers the successful protocol path only.

3. **Recovery two-pass atomicity (Family 4) not split in spec.** The brief notes the real race is "partially protected by shared lock." The `Recovery` action models it atomically; `MC_hunt_family4.cfg` verifies `RecoveryCompleteness` holds. A split-pass model would be needed only if the lock protection were removed — out of scope for current spec.

4. **Family 3 requires two MigrationIds in hunt config.** `MC_hunt_family3.cfg` uses `MigrationId = {"m1", "m2"}` while other configs use `{"m1"}`. This is intentional — the TOCTOU scenario requires two concurrent deletion tasks for the same range.
