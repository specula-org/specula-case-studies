# Modeling Brief: MongoDB Resharding Coordinator

## 1. System Overview

- **System**: MongoDB resharding coordinator — 3-party distributed state machine
- **Language**: C++, ~6,800 LOC core logic across coordinator (.inl 2204L), donor (1531L), recipient (2287L), DAO (371L), observer (288L)
- **Protocol**: Custom state machine with 9 coordinator states, participant readiness signals via observer promises, abort/commit race resolution via token switching
- **Key architectural choices**:
  - Coordinator state persisted via transactions in `config.reshardingOperations` (w:majority via `bumpCollectionPlacementVersionAndChangeMetadataInTxn`)
  - Participant state documents written with **w:1** (not w:majority!) — majority wait happens separately before notifying coordinator
  - Recovery via `PrimaryOnlyService` framework: constructor reads persisted doc, `run()` re-executes chain with idempotency guards (`state > X` → skip)
  - Abort/commit race resolved by switching cancellation token: once `_awaitAllRecipientsInStrictConsistency` resolves, abort token is replaced with stepdown-only token
  - Post-commit errors crash the server (`LOGV2_FATAL`) — intentional crash-for-safety
  - Observer uses promise-per-milestone pattern, checked in strict sequential order
- **Concurrency model**: Async future chain on PrimaryOnlyService executor. Coordinator mutex for `_coordinatorDoc`. Donor/recipient mutex for context state. Observer mutex for promises.

## 2. Bug Families

### Family 1: Coordinator Failover — Abort Decision Lost (CRITICAL)

**Mechanism**: Coordinator crashes between persisting abort decision and notifying participants. On step-up, recovery re-reads doc. If the abort write was w:1 (not majority), the doc might show the pre-abort state. Recovery resumes from that state, potentially proceeding to commit a resharding that was supposed to be aborted.

**Evidence**:
- Historical: SERVER-61483 (P2/Critical): "Resharding coordinator fails to read abort decision on step-up"
- Code analysis: DAO invariants (`coordinator_dao.cpp:155,199,233,249,274,287,313`) — hard `invariant()` on expected state, not `uassert`. If recovery reads unexpected state, config server crashes.
- Code analysis: `_onAbortCoordinatorAndParticipants` writes kAborting via DAO `transitionToAbortingPhase` which uses `bumpCollectionPlacementVersionAndChangeMetadataInTxn` (w:majority via txn). But the `waitForMajority` call after the txn could be interrupted by step-down before completing.
- Code analysis: Recovery constructor (`resharding_coordinator.inl:167-169`): `if (state > kInitializing) { observer->onReshardingParticipantTransition(doc) }` — re-primes promises but doesn't re-validate abort consistency.

**Affected code paths**: `resharding_coordinator.inl:580-640` (abort flow), `resharding_coordinator_dao.cpp:305-330` (abort persistence), `resharding_coordinator.inl:147-192` (recovery constructor)

**Suggested modeling approach**:
- Variables: `coordState`, `coordDoc` (persisted), `coordDocDurable` (majority committed), `abortReason`
- Actions: `CoordTransition(fromState, toState)`, `CoordCrash`, `CoordRecover`, `CoordAbort`
- Granularity: Split persistence into local-write and majority-commit. Crash between them = doc may or may not be visible to new primary.

**Priority**: CRITICAL
**Rationale**: P2 data loss bug (SERVER-61483), plus DAO invariant crashes on unexpected state

---

### Family 2: Observer Sequential Promise Check — Missed Participant Done (HIGH)

**Mechanism**: The observer checks promises in strict sequential order and returns early if earlier promises aren't fulfilled. During abort, `_onAbortOrStepdown` errors out early promises but NOT `_allRecipientsDone` / `_allDonorsDone`. If a participant jumps to kDone during abort but earlier promises haven't been fulfilled yet, the done-signal is silently missed. The coordinator blocks indefinitely waiting for done.

**Evidence**:
- Code analysis: `resharding_coordinator_observer.cpp:179-205` — strict sequential check, returns early
- Code analysis: `resharding_coordinator_observer.cpp:274-286` — `_onAbortOrStepdown` only sets error on first 3 promises, not `_allRecipientsDone` / `_allDonorsDone`
- Code analysis: `resharding_coordinator_observer.h:143` — comment says "Promises must be fulfilled in descending order" but abort can violate this ordering
- Historical: SERVER-120917 (2026-03): "Resharding hangs in cloning phase" — could be observer-related

**Affected code paths**: `resharding_coordinator_observer.cpp:80-210` (entire `onReshardingParticipantTransition`)

**Suggested modeling approach**:
- Variables: Per-participant state (donor/recipient enum), per-promise fulfilled/unfulfilled/errored
- Actions: `ParticipantTransition(p, newState)`, `ObserverCheck`, `CoordWaitPromise`
- Key: model the sequential promise check order and verify no state combination causes permanent block

**Priority**: HIGH
**Rationale**: Could explain SERVER-120917 hang; no timeout on done-promises except critical section

---

### Family 3: DAO Invariant Crash on Race (HIGH)

**Mechanism**: Every DAO `transitionTo*Phase` method starts with `invariant(doc.getState() == expectedState)`. The pattern is: read doc → check invariant → write update. This is NOT atomic. If two coordinator instances (from rapid stepdown/stepup) or an abort + normal transition race, the invariant could fire on a state that was just changed by the other operation, crashing the config server.

**Evidence**:
- Code analysis: `resharding_coordinator_dao.cpp:155` — `invariant(doc.getState() == kInitializing)`
- Code analysis: `resharding_coordinator_dao.cpp:199` — `invariant(doc.getState() == kPreparingToDonate)`
- Code analysis: `resharding_coordinator_dao.cpp:313` — `invariant(doc.getState() > kInitializing && doc.getState() < kAborting)`
- Historical: SERVER-74647: "State machine creation not idempotent → permanent hang" — related pattern
- Historical: SERVER-61473: "onCompletion() called multiple times → config server crash"

**Affected code paths**: `resharding_coordinator_dao.cpp` (all `transitionTo*Phase` methods)

**Suggested modeling approach**:
- Variables: `daoState` (on-disk state read by DAO), `coordInstance` (which instance is running)
- Actions: `DAOReadState`, `DAOCheckInvariant`, `DAOWriteTransition` — make non-atomic
- Fault injection: `RapidStepdownStepup` — create two overlapping coordinator instances

**Priority**: HIGH
**Rationale**: invariant() = server crash, non-atomic read-check-write pattern

---

### Family 4: Participant w:1 State Write — Lost on Stepdown (MEDIUM)

**Mechanism**: Donor and recipient write state documents with `w:1` (acknowledged by local primary only). Majority wait happens separately before notifying coordinator. If primary steps down between the w:1 write and majority wait, the state is lost. New primary may have old participant state, causing coordinator to wait for a transition that already happened (but wasn't replicated).

**Evidence**:
- Code analysis: `resharding_donor_service.cpp:129/1382` — `kNoWaitWriteConcern`
- Code analysis: `resharding_recipient_service.cpp:144/1718/1809/1845` — `kNoWaitWriteConcern`
- Historical: SERVER-68628 (P2): "Retry after failover leads to crash or lost writes"

**Affected code paths**: All `_updateDonorDocument`/`_updateRecipientDocument` calls

**Suggested modeling approach**:
- Variables: `participantDocState` (persisted), `participantDocDurable` (majority), `participantInMemState`
- Actions: `ParticipantWriteState(w:1)`, `ParticipantWaitMajority`, `ParticipantCrash`
- Key: model the gap between w:1 write and majority commit

**Priority**: MEDIUM
**Rationale**: P2 bug (SERVER-68628), but mitigated by the separate majority-wait step

---

### Family 5: Post-Commit Fatal — Transient Error Kills Server (MEDIUM)

**Mechanism**: Both coordinator (`LOGV2_FATAL(5277000)`), donor (`LOGV2_FATAL(5160600)`), and recipient (`LOGV2_FATAL(5551101)`) call `LOGV2_FATAL` on ANY error past the point of no return. A transient error (brief network glitch, temporary storage hiccup) that isn't correctly classified as retryable or step-down could crash the server unnecessarily.

**Evidence**:
- Code analysis: `resharding_coordinator.inl:630-633` — catches ANY non-stepdown error
- Code analysis: `resharding_donor_service.cpp:669` — same pattern
- Code analysis: `resharding_recipient_service.cpp:711` — same pattern
- The `TransactionTooLargeForCache` special case shows they've already hit this: one error was incorrectly fatal and had to be special-cased

**Affected code paths**: `_commitAndFinishReshardOperation`, `_finishReshardingOperation` (donor/recipient)

**Suggested modeling approach**:
- Variables: `postCommit` (boolean), `errorKind` (transient/fatal/stepdown)
- Actions: `PostCommitError(kind)` — model which errors are correctly classified
- This is more of a code-review finding than a MC target

**Priority**: MEDIUM
**Rationale**: `TransactionTooLargeForCache` special-case proves this class of bug exists

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Coordinator 9-state machine | Core protocol; all families | State variable with transitions |
| Coordinator doc persistence (local + majority) | Family 1: abort decision lost | Split into localWrite and majorityCommit |
| Coordinator crash/recovery | Family 1, 3: failover bugs | CoordCrash + CoordRecover actions |
| Participant readiness signals | Family 2: observer promise miss | Per-participant state enum |
| Observer sequential promise check | Family 2: strict ordering causes hang | Model the check order faithfully |
| DAO invariant checking (non-atomic) | Family 3: crash on race | Read-check-write as 3 separate steps |
| Participant w:1 write + separate majority | Family 4: lost state | Two-phase participant persistence |
| Abort/commit token switch | Family 1, 2: race resolution | Boolean: abortable vs committed |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Data cloning mechanics | Implementation-level, not protocol |
| Oplog application details | Too low-level for state machine model |
| Network message format | Abstract to readiness signals |
| WiredTiger storage engine | Too low-level |
| Temp collection creation/swap DDL | DDL details, not state machine |
| Chunk/zone calculation | Purely computational, no concurrency |
| Metrics/logging | Observability, not correctness |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Split persistence | coordDocLocal, coordDocMajority | Model w:1 vs w:majority gap | 1, 4 |
| Abort token | abortable, abortReason | Model abort/commit race | 1, 2 |
| Sequential promise check | promiseState[5], checkOrder | Model observer ordering | 2 |
| Non-atomic DAO | daoReadState, daoWritePending | Model read-check-write race | 3 |
| Participant w:1 | pDocLocal, pDocMajority | Model participant state loss | 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NoCommitAfterAbort | Safety | Once abort decided, coordinator never reaches kCommitting | Family 1 |
| AbortDecisionSurvivesFailover | Safety | If abort persisted to majority, recovery reads abort | Family 1 |
| DAOInvariantNeverFires | Safety | DAO read-check-write never sees unexpected state | Family 3 |
| NoPromiseDeadlock | Liveness | Coordinator eventually fulfills or errors all promises | Family 2 |
| ParticipantDoneReachable | Liveness | All participants eventually reach kDone or error detected | Family 2 |
| ParticipantStateMonotonic | Safety | Participant state never goes backward | Family 4 |
| PostCommitNoAbort | Safety | After kCommitting, abort is impossible | Family 1 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Family |
|----|-------------|----------------------------|--------|
| MC-1 | Abort during kBlockingWrites → step-down → recovery reads pre-abort state → proceeds to commit | NoCommitAfterAbort | 1 |
| MC-2 | Participant kDone during abort, earlier promise unfulfilled → coordinator blocks forever | NoPromiseDeadlock | 2 |
| MC-3 | Rapid stepdown/stepup → two DAO transitions race → invariant crash | DAOInvariantNeverFires | 3 |
| MC-4 | Participant writes kDone with w:1 → step-down → coordinator re-reads old state → re-sends commit | ParticipantStateMonotonic | 4 |

### 6.2 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `TransactionTooLargeForCache` is only special-cased error past commit point; others still fatal | Review error classification completeness |
| CR-2 | Observer typo `stateTransistionsComplete` | Fix spelling |
| CR-3 | Donor `_updateCoordinator` uses `CancellationToken::uncancelable()` for majority wait | Review if this blocks abort |

## 7. Reference Pointers

- **Coordinator state machine**: `resharding_coordinator.inl` (full file, 2204 lines)
- **DAO persistence**: `resharding_coordinator_dao.cpp` (371 lines)
- **Observer promises**: `resharding_coordinator_observer.cpp` (288 lines)
- **Donor service**: `resharding_donor_service.cpp` (1531 lines)
- **Recipient service**: `resharding_recipient_service.cpp` (2287 lines)
- **Key JIRAs**: SERVER-61483, SERVER-68628, SERVER-74647, SERVER-120917, SERVER-100785
- **Source location**: `/home/ubuntu/Specula/case-studies/mongodb/artifact/mongo-src/src/mongo/db/s/resharding/`
