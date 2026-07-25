# Instrumentation Spec: MongoDB Chunk Migration

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a JSON object with:

```json
{
  "event": "<action-name>",
  "node": "<donor|recipient|config>",
  "before": { <state-snapshot> },
  "after":  { <state-snapshot> }
}
```

- `event` — matches the TLA+ action name exactly (case-sensitive)
- `node` — identifies which party emitted the event
- `before` — state snapshot captured **immediately before** the action's key operation
- `after` — state snapshot captured **immediately after** the action's key operation

### State Fields (captured in `before` and `after`)

| JSON field | TLA+ variable | Source | Notes |
|---|---|---|---|
| `donorPhase` | `donorPhase` | `MigrationSourceManager::_state` | Map: `"kCloning"→"d_cloning"`, `"kCommitted"→"d_committed"`, etc. |
| `recipientState` | `recipientState` | `MigrationDestinationManager::_state` | Direct enum name as string |
| `configCommitted` | `configCommitted` | local bool after commitChunkMigration returns | `true`/`false` |
| `coordinatorDocPresent` | `coordinatorDocPresent` | `PersistentTaskStore` read or existence flag | `true`/`false` |
| `coordinatorDocDecision` | `coordinatorDocDecision` | `_migrationInfo.getDecision()` | `"none"`, `"committed"`, `"aborted"` |
| `critSecReleaseRPCSent` | `critSecReleaseRPCSent` | bool set when `launchReleaseRecipientCriticalSection` fires | `true`/`false` |
| `recipientCritSecReleased` | `recipientCritSecReleased` | bool set after RPC acknowledged | `true`/`false` |
| `donorCrashed` | `donorCrashed` | injected crash flag | `true`/`false` |
| `recipientAbortSignaled` | `recipientAbortSignaled` | bool from `_state == kAbort` at recovery start | `true`/`false` |
| `recipientRecoveryDocPresent` | `recipientRecoveryDocPresent` | recovery doc existence check | `true`/`false` |
| `recipientInRecovery` | `recipientInRecovery` | bool set when recovery path entered | `true`/`false` |
| `donorRDTask` | `donorRDTask` | `getRangeDeletionTask` existence + `pending` flag | `"absent"`, `"pending"`, `"ready"` |
| `recipientRDTask` | `recipientRDTask` | recipient's `config.rangeDeletions` document | `"absent"`, `"pending"`, `"ready"` |

---

## Section 2: Action-to-Code Mapping

### `StartClone`

| Field | Value |
|---|---|
| **Spec action** | `StartClone` |
| **Code location** | `migration_source_manager.cpp:472-500` |
| **Trigger point** | After `_coordinator->startMigration(_opCtx)` at line 500 returns |
| **Trace event** | `"StartClone"` |
| **Node** | `donor` |
| **Fields captured (after)** | `donorPhase`, `coordinatorDocPresent`, `coordinatorDocDecision`, `donorRDTask` |
| **Notes** | `_cloneDriver` registration (line 472) happens before `startMigration` (line 500). Capture after line 500 to see coordinator doc and RD task both written. |

---

### `RecipientBeginClone`

| Field | Value |
|---|---|
| **Spec action** | `RecipientBeginClone` |
| **Code location** | `migration_destination_manager.cpp:1537-1561` |
| **Trigger point** | After local write of recipient range deletion task (after line 1561) |
| **Trace event** | `"RecipientBeginClone"` |
| **Node** | `recipient` |
| **Fields captured (after)** | `recipientState`, `recipientRDTask`, `recipientRecoveryDocPresent` |
| **Notes** | RD task is written with `writeConcernLocalHavingUpstreamWaiter()` (local WC). Capture after local write, before majority wait. |

---

### `DonorEnterCriticalSection`

| Field | Value |
|---|---|
| **Spec action** | `DonorEnterCriticalSection` |
| **Code location** | `migration_source_manager.cpp` (critical section acquisition block) |
| **Trigger point** | After critical section acquired |
| **Trace event** | `"DonorEnterCriticalSection"` |
| **Node** | `donor` |
| **Fields captured (after)** | `donorPhase` |

---

### `RecipientEnterCriticalSection`

| Field | Value |
|---|---|
| **Spec action** | `RecipientEnterCriticalSection` |
| **Code location** | `migration_destination_manager.cpp:1896-1903` (normal path, inside `!skipToCritSecTaken` branch) |
| **Trigger point** | After `_state = kEnteredCritSec` at line 1900 and mutex released |
| **Trace event** | `"RecipientEnterCriticalSection"` |
| **Node** | `recipient` |
| **Fields captured (after)** | `recipientState` |
| **Notes** | This event corresponds to the NORMAL path (with `kFail`/`kAbort` guard at line 1899). The recovery path uses `RecoverySetsCritSecState`. |

---

### `CommitChunkMigrationOnConfigServer`

| Field | Value |
|---|---|
| **Spec action** | `CommitChunkMigrationOnConfigServer` |
| **Code location** | `migration_source_manager.cpp:commitChunkMetadataOnConfig` (line ~680 approximate) |
| **Trigger point** | After `commitChunkMigration` RPC returns successfully |
| **Trace event** | `"CommitChunkMigrationOnConfigServer"` |
| **Node** | `donor` |
| **Fields captured (after)** | `configCommitted` |

---

### `LaunchReleaseRecipientCritSec`

| Field | Value |
|---|---|
| **Spec action** | `LaunchReleaseRecipientCritSec` |
| **Code location** | `migration_coordinator.cpp:204-206` |
| **Trigger point** | After `launchReleaseRecipientCriticalSection(opCtx)` call at line 205 returns (async future stored) |
| **Trace event** | `"LaunchReleaseRecipientCritSec"` |
| **Node** | `donor` |
| **Fields captured (after)** | `critSecReleaseRPCSent` |
| **Notes** | **Critical for Family 1**: this event fires BEFORE `PersistCommitDecision`. The harness must emit this event as soon as the future is created (line 205), not when it resolves. |

---

### `RecipientReleaseCritSec`

| Field | Value |
|---|---|
| **Spec action** | `RecipientReleaseCritSec` |
| **Code location** | Recipient side: `ShardingRecoveryService::releaseRecoverableCriticalSection` handler |
| **Trigger point** | After critical section release RPC is processed by recipient |
| **Trace event** | `"RecipientReleaseCritSec"` |
| **Node** | `recipient` |
| **Fields captured (after)** | `recipientCritSecReleased`, `recipientState` |
| **Notes** | This event may arrive asynchronously. In traces, it may appear between `LaunchReleaseRecipientCritSec` and `PersistCommitDecision`. |

---

### `PersistCommitDecision`

| Field | Value |
|---|---|
| **Spec action** | `PersistCommitDecision` |
| **Code location** | `migration_coordinator.cpp:240` (`migrationutil::persistCommitDecision`) |
| **Trigger point** | After `persistCommitDecision` returns (majority WC satisfied) |
| **Trace event** | `"PersistCommitDecision"` |
| **Node** | `donor` |
| **Fields captured (after)** | `coordinatorDocDecision`, `coordinatorDocPresent` |
| **Notes** | **Critical for Family 1**: this event fires AFTER `LaunchReleaseRecipientCritSec`. The window between the two events is the crash-vulnerability window. |

---

### `DeleteRecipientRangeDeletionTask`

| Field | Value |
|---|---|
| **Spec action** | `DeleteRecipientRangeDeletionTask` |
| **Code location** | `migration_coordinator.cpp:278-282` (`rangedeletionutil::deleteRangeDeletionTaskOnRecipient`) |
| **Trigger point** | After RPC to recipient returns |
| **Trace event** | `"DeleteRecipientRangeDeletionTask"` |
| **Node** | `donor` |
| **Fields captured (after)** | `recipientRDTask` |

---

### `MarkDonorRangeDeletionTaskReady`

| Field | Value |
|---|---|
| **Spec action** | `MarkDonorRangeDeletionTaskReady` |
| **Code location** | `migration_coordinator.cpp:320-321` (`rangedeletionutil::markAsReadyRangeDeletionTaskLocally`) |
| **Trigger point** | After local write returns |
| **Trace event** | `"MarkDonorRangeDeletionTaskReady"` |
| **Node** | `donor` |
| **Fields captured (after)** | `donorRDTask` |

---

### `ForgetMigration`

| Field | Value |
|---|---|
| **Spec action** | `ForgetMigration` |
| **Code location** | `migration_coordinator.cpp:389-401` |
| **Trigger point** | After coordinator doc delete returns (w:1 WC) |
| **Trace event** | `"ForgetMigration"` |
| **Node** | `donor` |
| **Fields captured (after)** | `coordinatorDocPresent`, `donorPhase` |

---

### `PersistAbortDecision`

| Field | Value |
|---|---|
| **Spec action** | `PersistAbortDecision` |
| **Code location** | `migration_coordinator.cpp:334` (`migrationutil::persistAbortDecision`) |
| **Trigger point** | After `persistAbortDecision` returns |
| **Trace event** | `"PersistAbortDecision"` |
| **Node** | `donor` |
| **Fields captured (after)** | `coordinatorDocDecision` |

---

### `DeleteDonorRangeDeletionTaskOnAbort`

| Field | Value |
|---|---|
| **Spec action** | `DeleteDonorRangeDeletionTaskOnAbort` |
| **Code location** | `migration_coordinator.cpp:347-350` (`rangedeletionutil::deleteRangeDeletionTaskLocally`) |
| **Trigger point** | After local delete returns (majority WC) |
| **Trace event** | `"DeleteDonorRangeDeletionTaskOnAbort"` |
| **Node** | `donor` |
| **Fields captured (after)** | `donorRDTask` |

---

### `MarkRecipientRangeDeletionTaskReadyOnAbort`

| Field | Value |
|---|---|
| **Spec action** | `MarkRecipientRangeDeletionTaskReadyOnAbort` |
| **Code location** | `migration_coordinator.cpp:382-386` (`rangedeletionutil::markAsReadyRangeDeletionTaskOnRecipient`) |
| **Trigger point** | After RPC to recipient returns |
| **Trace event** | `"MarkRecipientRangeDeletionTaskReadyOnAbort"` |
| **Node** | `donor` |
| **Fields captured (after)** | `recipientRDTask` |

---

### `CrashDonor`

| Field | Value |
|---|---|
| **Spec action** | `CrashDonor` |
| **Code location** | Injected via failpoint or SIGKILL in test harness |
| **Trigger point** | After crash is injected; before new primary is elected |
| **Trace event** | `"CrashDonor"` |
| **Node** | `donor` |
| **Fields captured (after)** | `donorCrashed`, `donorPhase` |

---

### `RecoverDonor`

| Field | Value |
|---|---|
| **Spec action** | `RecoverDonor` |
| **Code location** | `migration_util.cpp:543-561` (`drainMigrationsPendingRecovery`), new primary calls `completeMigration` |
| **Trigger point** | After `coordinatorDocDecision` is determined to be non-NONE and recovery proceeds |
| **Trace event** | `"RecoverDonor"` |
| **Node** | `donor` |
| **Fields captured (after)** | `donorCrashed`, `donorPhase`, `coordinatorDocDecision` |

---

### `RecoverDonorNoDecision`

| Field | Value |
|---|---|
| **Spec action** | `RecoverDonorNoDecision` |
| **Code location** | `migration_coordinator.cpp:186-196` (no-decision early-return in `completeMigration`) |
| **Trigger point** | After `completeMigration` returns `boost::none` due to no decision |
| **Trace event** | `"RecoverDonorNoDecision"` |
| **Node** | `donor` |
| **Fields captured (after)** | `donorCrashed`, `donorPhase`, `coordinatorDocDecision` |
| **Notes** | **Key Family 1 event**: coordinator doc has no decision; migration effectively abandoned. |

---

### `StartRecipientRecovery`

| Field | Value |
|---|---|
| **Spec action** | `StartRecipientRecovery` |
| **Code location** | `migration_util.cpp:495-541` (`resumeMigrationRecipientsOnStepUp`) |
| **Trigger point** | After recovery doc found and `_migrateDriver` thread is about to re-enter |
| **Trace event** | `"StartRecipientRecovery"` |
| **Node** | `recipient` |
| **Fields captured (after)** | `recipientInRecovery`, `recipientRecoveryDocPresent` |

---

### `ConcurrentAbortSignalDuringRecovery`

| Field | Value |
|---|---|
| **Spec action** | `ConcurrentAbortSignalDuringRecovery` |
| **Code location** | `MigrationDestinationManager::abort()` — sets `_state = kAbort` under mutex |
| **Trigger point** | After `_state = kAbort` inside `abort()`, while `recipientInRecovery == true` |
| **Trace event** | `"ConcurrentAbortSignalDuringRecovery"` |
| **Node** | `recipient` |
| **Fields captured (after)** | `recipientState`, `recipientAbortSignaled` |

---

### `RecoverySetsCritSecState`

| Field | Value |
|---|---|
| **Spec action** | `RecoverySetsCritSecState` |
| **Code location** | `migration_destination_manager.cpp:1927-1930` (recovery branch, `skipToCritSecTaken == true`) |
| **Trigger point** | After `_state = kEnteredCritSec` at line 1929 |
| **Trace event** | `"RecoverySetsCritSecState"` |
| **Node** | `recipient` |
| **Fields captured (after)** | `recipientState`, `recipientInRecovery` |
| **Notes** | **Key Family 2 event**: no `kFail`/`kAbort` guard here (contrast with normal path at line 1899). |

---

## Section 3: Special Considerations

### 1. Async Future for Crit-Sec Release (Family 1)

`launchReleaseRecipientCriticalSection` at `coordinator.cpp:204-206` stores a `SharedSemiFuture` in `_releaseRecipientCriticalSectionFuture`. The async RPC to the recipient is dispatched on an executor thread, not inline. In the trace:

- The `LaunchReleaseRecipientCritSec` event must be emitted **when the future is stored** (line 205), not when it resolves.
- The `RecipientReleaseCritSec` event is emitted by the recipient side when the RPC is processed.
- These two events will have different `node` values and may appear in any relative order in the trace.

### 2. Coordinator Doc Decision Timing

`persistCommitDecision` writes to the `config.migrationCoordinators` collection with majority WC. In the trace, `coordinatorDocDecision` transitions from `"none"` to `"committed"` exactly at the `PersistCommitDecision` event. Any events between `LaunchReleaseRecipientCritSec` and `PersistCommitDecision` represent the crash-vulnerability window (Family 1).

### 3. Recipient Recovery Doc

The `MigrationRecipientRecoveryDocument` is written during `RecipientBeginClone` and removed during successful migration completion. The trace must capture `recipientRecoveryDocPresent` at `StartRecipientRecovery` to confirm recovery was triggered by doc presence.

### 4. Range Deletion Task State Encoding

The donor range deletion task transitions are:
- `absent` → `pending`: during `StartClone` (coordinator doc write includes RD task creation)
- `pending` → `ready`: during `MarkDonorRangeDeletionTaskReady` (commit path only)
- `pending` → `absent`: during `DeleteDonorRangeDeletionTaskOnAbort` (abort path)

The `pending` flag in MongoDB's `config.rangeDeletions` collection is `true` while pending, `false` (or document deleted) otherwise. Map: document absent → `absent`; document present with `pending=true` → `pending`; document present with `pending=false` → `ready`.

### 5. Donor Phase Mapping

`MigrationSourceManager` state enum maps to `donorPhase` spec values:

| Source enum | Spec constant |
|---|---|
| `kNew` | `d_init` |
| `kCloning` | `d_cloning` |
| `kCriticalSection` | `d_critsec` |
| `kCloneCompleted` | `d_critsec` (treated as critsec for modeling purposes) |
| `kCommittedOnConfig` | `d_committed` |
| (after forgetMigration) | `d_committed` or `d_aborted` |

### 6. TraceInit Bootstrap

If a trace begins mid-migration (e.g., after primary step-up), `before` of the first event must carry all 13 state fields. The instrumentation harness must snapshot full state at the entry point of each instrumented function, not just the fields that change.
