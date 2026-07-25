# Modeling Brief: MongoDB Logical Session Lifecycle and Catalog

## 1. System Overview

- **System**: MongoDB logical session lifecycle — `src/mongo/db/session/` (~4,200 LOC core logic)
- **Language**: C++
- **Category**: **Category A (Distributed / Message-Passing)** with concurrent sub-components. The session lifecycle is a distributed liveness protocol: a background refresh job periodically upserts session records into `system.sessions` (preventing TTL expiry), while a reap job deletes stale `config.transactions` records. A separate kill protocol coordinates session interruption across catalog entries and running operations. The main risks are in protocol correctness across distributed state (catalog vs sessions collection vs transactions table), concurrent background jobs, and multi-step kill sequences.
- **Key architectural choices**:
  - Two independent background threads (`LogicalSessionCacheRefresh`, `LogicalSessionCacheReap`) run on the same 5-minute interval with **no inter-job coordination**
  - `SessionRuntimeInfo` (SRI) is shared by parent + all child sessions; all share a single `checkoutOpCtx` and `availableCondVar` — only one session in the SRI can be checked out at a time
  - Kill protocol is two-step: `kill()` increments `killsRequested` immediately (synchronous), kill cleanup runs asynchronously via a single-threaded pool
  - Session reap is two-phase: memory removal precedes disk deletion (explicitly chosen over a single transaction for simplicity)
- **Concurrency model**: Single `_mutex` guards in-memory session state; all I/O runs outside the lock; background jobs run on separate `PeriodicRunnerImpl` threads (one thread per job)

---

## 2. Bug Families

### Family 1: Refresh-Reap Protocol Race (HIGH)

**Mechanism**: `_periodicRefresh` and `_periodicReap` run concurrently on separate threads with no coordination. `_reap` can delete a `config.transactions` record for a session that `_refresh` is simultaneously refreshing in `system.sessions`. A session that `_refresh` considers live (upserts `lastUse = $$NOW`) can have its transaction record deleted by the concurrent `_reap`, stripping retryable-write deduplication history.

**Evidence**:
- Historical: SERVER-122193 — concurrent `refreshNow` + `_periodicRefresh` race (two refresh workers, no inter-job mutex); fixed with `_refreshMutex` for same-type racing, but **no equivalent fix exists for refresh/reap cross-job race**
- Historical: SERVER-73229 — write errors in `refreshSessions` silently suppressed; sessions believed-refreshed were not, yet cursors were killed; same error-invisibility mechanism
- Code analysis: `logical_session_cache_impl.cpp:109-123` — both jobs scheduled with same interval, no sequencing; `impl.cpp:250-253` — `_reapSessionsOlderThanFn` acts on a point-in-time cutoff with no awareness of concurrent refresh; `impl.cpp:371` — `refreshSessions` upserts `lastUse` without locking out reap

**Affected code paths**:
- `LogicalSessionCacheImpl::_refresh` (impl.cpp:277-455) — specifically `refreshSessions` at line 371
- `LogicalSessionCacheImpl::_reap` (impl.cpp:209-275) — specifically `_reapSessionsOlderThanFn` at line 250
- `MongoDSessionCatalog::reapSessionsOlderThan` (session_catalog_mongod.cpp:706-749) — the reap callback

**Suggested modeling approach**:
- Variables: `sessionLastRefreshed[Session -> Time]`, `txnRecordExists[Session -> BOOL]`, `refreshRunning[BOOL]`, `reapRunning[BOOL]`
- Actions: `StartRefresh`, `CompleteRefresh` (updates sessionLastRefreshed), `StartReap`, `CompleteReap` (deletes txnRecord if lastRefreshed < cutoff), where StartReap and StartRefresh can interleave
- Key invariant: if `txnRecordExists[s] = FALSE`, the session must not be considered retryable-write-safe; if `sessionLastRefreshed[s] > reapCutoff`, `txnRecordExists[s]` must remain TRUE

**Priority**: High
**Rationale**: Two concurrent background jobs with overlapping distributed state and no coordination. No current fix addresses the cross-job race. Multiple historical bugs from the same family of error-invisibility. Well-suited to TLA+ because the protocol question (does concurrent refresh protect txn records from reap?) has a non-obvious answer depending on the reap window.

---

### Family 2: Kill Protocol Ordering Violations (HIGH)

**Mechanism**: The kill protocol has two independent ordering hazards that cause either permanent session unavailability (liveness) or incorrect kill decisions: (a) `notify_all` fires before `killsRequested` is decremented in `_releaseSession`, leaving normal waiters blocked indefinitely after kill completion; (b) `session.kill()` increments `killsRequested` synchronously before `registerChange` stores the kill token — if `registerChange` throws, the session is stuck with `killsRequested > 0` forever.

**Evidence**:
- Historical: SERVER-78187 — killing a child session did not propagate to sibling sessions; fixed by adding cross-SRI kill propagation; shows the kill protocol's atomicity model was incomplete
- Historical: SERVER-77172 — `checkOutSessionForKill` in `abortExpiredTransactions` had no timeout; session checkout could hang indefinitely; shows the kill completion path has liveness exposure
- Code analysis: `session_catalog.cpp:371-376` — `checkoutOpCtx = nullptr; notify_all(); --killsRequested;` — notify_all fires at line 372, decrements at line 376; no second notify_all after decrement; waiters that woke and saw `_killed() = true` remain blocked
- Code analysis: `session_catalog_mongod.cpp:684-686` — `session.kill(...)` (synchronous, under catalog scan) followed by `registerChange(make_unique<KillSessionTokenOnCommit>(...))` — if registerChange throws, KillToken destructor does not decrement `killsRequested`

**Affected code paths**:
- `SessionCatalog::_releaseSession` (session_catalog.cpp:363-416) — ordering of notify_all and --killsRequested
- `SessionCatalog::_checkOutSessionInner` (session_catalog.cpp:109-155) — waiter loop condition `_isAvailableForCheckOut`
- `MongoDSessionCatalog::observeDirectWriteToConfigTransactions` (session_catalog_mongod.cpp:641-689) — kill-then-registerChange sequence

**Suggested modeling approach**:
- Variables: `killsRequested[SRI -> Nat]`, `checkoutOpCtx[SRI -> OpCtx | NULL]`, `waiters[SRI -> Nat]`, `killTokenPending[SRI -> BOOL]`
- Actions: Split `ReleaseKillCheckout` into `ClearCheckoutOpCtx` + `NotifyWaiters` + `DecrementKills` (capturing the ordering); `RequestKill` (increment only) + `RegisterKillChange` (stores token, can fail); `CheckoutNormal` (blocked when `killsRequested > 0`)
- Key invariants: `NoLivelock` — if `killsRequested = 0 ∧ checkoutOpCtx = NULL`, no waiter remains blocked; `NoOrphanKill` — `killsRequested > 0` implies a live kill token exists somewhere

**Priority**: High
**Rationale**: Two independent but related protocol hazards. The liveness hazard (notify_all ordering) is present in current mainline and has no historical fix. The kill token orphan is a crash-window pattern well-suited to TLA+. Both map cleanly to split TLA+ actions.

---

### Family 3: Refresh Partial-Failure and Retry Correctness (MEDIUM)

**Mechanism**: The session refresh pathway has an asymmetric partial-failure recovery: sessions in `_activeSessions` that fail to refresh are put back for retry, but sessions in `runningOpSessions` that fail are silently dropped. A long-running operation's session can expire via TTL if its refresh consistently fails.

**Evidence**:
- Historical: SERVER-94001 — `_refresh()` was void and exited early on failure; explicitly-ending sessions were not processed; fixed by threading failure status through
- Historical: SERVER-115981 — refresh errors silently swallowed, ending sessions skipped; same root cause, subsequent fix
- Historical: SERVER-73229 — write errors inside `refreshSessions` response BSON were invisible (command-level check only); sessions treated as refreshed when they weren't
- Code analysis: `logical_session_cache_impl.cpp:388-398` — back-fill loop iterates `activeSessions` only; `runningOpSessions` entries not tracked in `activeSessions`, so partial failures for them are not retried

**Affected code paths**:
- `LogicalSessionCacheImpl::_refresh` (impl.cpp:356-398) — runningOpSessions refresh path; `activeSessionsBackSwapper.dismiss()` at line 372 before error inspection
- `SessionsCollection::refreshSessions` and `makeSendFnForBatchWrite` (sessions_collection.cpp) — write-error detection layer

**Suggested modeling approach**:
- Variables: `pendingRefresh[Session -> {active, runningOp, dropped}]`, `sessionExpiresAt[Session -> Time]`
- Actions: `BeginRefresh` (swaps out active set, observes runningOps), `RefreshSucceed[s]`, `RefreshFail[s]` (active sessions put back, runningOp sessions dropped), `TTLExpire[s]`
- Key invariant: if a session has `pendingRefresh = runningOp` and `RefreshFail`, `sessionExpiresAt` should not decrease (i.e., the session should not expire while its op is running)

**Priority**: Medium
**Rationale**: Three historical bugs with the same root cause, recently patched but with a known remaining gap (`runningOpSessions` not retried). The gap is subtle and easy to miss; TLA+ can confirm whether the current retry logic is sufficient under all interleaving scenarios.

---

### Family 4: Non-Atomic Two-Phase Session Reap (MEDIUM)

**Mechanism**: Session reaping removes sessions from the in-memory catalog before deleting their on-disk records (`config.transactions`, `config.image_collection`). Between phases, a new operation can check out the session (re-created in the catalog) and find no transaction record on disk, incorrectly treating a retryable operation as new. Additionally, `config.image_collection` is deleted before `config.transactions`, leaving a window where an entry references a deleted pre-image.

**Evidence**:
- Code analysis: `session_catalog_mongod.cpp:244-294` — explicit comment: "We opt for this rather than performing the two sets of deletes in a single transaction simply to reduce code complexity"; Phase A deletes `image_collection`, Phase B deletes `transactions`
- Code analysis: `session_catalog_mongod.cpp:706-749` — `reapSessionsOlderThan` removes from memory catalog, then calls `removeExpiredTransactionSessionsFromDisk`; no re-entry guard between the two phases
- Historical: SERVER-94001 — ending sessions skipped on error; same family: disk state diverges from in-memory state after partial operation

**Affected code paths**:
- `MongoDSessionCatalog::reapSessionsOlderThan` (session_catalog_mongod.cpp:706-749)
- `removeExpiredTransactionSessionsFromDisk` (session_catalog_mongod.cpp:295-379) — two-phase delete

**Suggested modeling approach**:
- Variables: `sessionInCatalog[Session -> BOOL]`, `txnRecordOnDisk[Session -> BOOL]`, `imageRecordOnDisk[Session -> BOOL]`
- Actions: `MemoryReap[s]` (sets `sessionInCatalog = FALSE`), `DiskReapImages[s]` (deletes image), `DiskReapTxn[s]` (deletes txn record); allow interleaving with `CheckoutSession[s]` which can re-insert into catalog
- Key invariants: if `sessionInCatalog = FALSE ∧ txnRecordOnDisk = TRUE`, a new checkout does not treat it as a fresh session (reads disk); if `imageRecordOnDisk = FALSE ∧ txnRecordOnDisk = TRUE`, no read of image_collection via txn record should succeed

**Priority**: Medium
**Rationale**: Explicitly documented design tradeoff. Crash safety and concurrency between reap phases are unexplored. Well-suited to TLA+: the two-phase delete has a natural intermediate state that TLA+ can enumerate.

---

### Family 5: shouldRegisterKill Stale-Read / Dead-Code Cluster (LOW)

**Mechanism**: (a) `shouldRegisterKill` in `observeDirectWriteToConfigTransactions` reads `lastClientTxnNumberStarted` which is only updated at checkin; a concurrent checkout can cause the kill decision to compare against a stale value, incorrectly killing the wrong session's SRI. (b) Dead declarations (`_isDead`, `_lastRefreshTime`, `staleSessions`) create specification drift — future readers may assume behaviors that don't exist.

**Evidence**:
- Code analysis: `session_catalog_mongod.cpp:681-686` — `session.getLastClientTxnNumberStarted()` reads SRI's `lastClientTxnNumberStarted` which is only written in `_releaseSession` under the catalog mutex
- Code analysis: `logical_session_cache_impl.h:118, 132` — `_isDead` declared but never defined; `_lastRefreshTime` declared but never written/read
- Code analysis: `logical_session_cache_impl.cpp:322` — `staleSessions` declared, never written

**Priority**: Low — stale-read is a code-review target; dead code cluster is cleanup-only

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Concurrent refresh + reap workers | Family 1: protocol-level race with no current fix | Two concurrent action groups; `refreshSessions` and `reapSessionsOlder` interleave freely |
| Reap cutoff vs refresh timestamp | Family 1: the key safety condition | `sessionLastRefreshed` variable; reap deletes when `lastRefreshed < cutoff` |
| Kill protocol ordering | Family 2: `notify_all` before `--killsRequested` blocks waiters | Split `_releaseSession` into `ClearCheckout`, `NotifyWaiters`, `DecrementKills` |
| Kill token registration | Family 2: `kill()` then `registerChange`, registerChange can fail | `RequestKill` + `RegisterKillChange` as separate actions; model registration failure |
| Session checkout blocked state | Family 2: checkout waits until `killsRequested == 0` | `waiters` variable; conditional enable on `killsRequested = 0` |
| runningOp session refresh failure | Family 3: partial failure drops runningOp sessions | Distinguish `activeSession` vs `runningOpSession` in refresh; model drop path |
| Two-phase disk delete | Family 4: memory-before-disk, image-before-txn | `sessionInCatalog`, `txnRecordOnDisk`, `imageRecordOnDisk` as separate state bits; interleave with checkout |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Retryable write deduplication logic | Inside `TransactionParticipant`; separate concern from session lifecycle protocol |
| Mongos transaction routing (`transaction_router.cpp`) | Separate subsystem; would expand scope without targeting these bug families |
| `AlternativeSessionRegion` null dereference | Null-check error; best verified by adding a null-check + test, not TLA+ |
| `isKillableByStepdown = false` jobs | Operational concern; the TLA+ question (what happens when jobs run post-stepdown) is real but requires modeling replication role changes, significantly expanding scope |
| Copy-paste error message in `scanParentSessions` | Diagnostic accuracy bug; code-review-only |
| Dead code cluster (`_isDead`, `_lastRefreshTime`, `staleSessions`) | Cleanup-only; no protocol impact |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Session refresh timestamp | `sessionLastRefreshed[Session -> Time]` | Track when each session was last refreshed | Family 1 |
| Txn record existence | `txnRecordExists[Session -> BOOL]` | Capture whether reap has deleted the on-disk record | Family 1, 4 |
| Kill counter | `killsRequested[SRI -> Nat]` | Model pending kill count separate from checkout state | Family 2 |
| Kill token registration | `killTokenRegistered[SRI -> BOOL]` | Capture whether kill token is durably registered | Family 2 |
| Session source type | `sessionSource[Session -> {active, runningOp}]` | Distinguish which sessions are retried on refresh failure | Family 3 |
| Disk delete phases | `imageRecordOnDisk`, `txnRecordOnDisk` | Model two-phase reap atomicity | Family 4 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `TxnRecordSafeWhileLive` | Safety | If a session has been refreshed since the last reap cycle started, `txnRecordExists` must remain TRUE | Family 1 |
| `NoWaitersStuckAfterKillComplete` | Liveness | If `killsRequested[sri] = 0 ∧ checkoutOpCtx[sri] = NULL`, no waiter for that SRI remains blocked | Family 2 |
| `NoOrphanKillRequest` | Safety | `killsRequested[sri] > 0` implies `killTokenRegistered[sri] = TRUE` (a live token exists to drain the counter) | Family 2 |
| `RunningOpSessionNotSilentlyDropped` | Safety | If a running operation's session fails to refresh, it must appear in the next refresh attempt | Family 3 |
| `NoDanglingImageWithoutTxnRecord` | Safety | `imageRecordOnDisk = FALSE` implies `txnRecordOnDisk = FALSE` (image can only be absent if the txn record is also gone) | Family 4 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Family |
|----|-------------|------------------------------|--------|
| MC-1 | Can `_reap` delete a `config.transactions` entry for a session that `_refresh` upserted within the same 5-minute window? | `TxnRecordSafeWhileLive` | 1 |
| MC-2 | After a kill checkout is released, do normal checkout waiters remain blocked indefinitely (no second `notify_all` after `--killsRequested`)? | `NoWaitersStuckAfterKillComplete` | 2 |
| MC-3 | If `registerChange` throws after `session.kill()`, is the SRI permanently stuck with `killsRequested > 0`? | `NoOrphanKillRequest` | 2 |
| MC-4 | Can a session whose `runningOpSession` refresh fails expire via TTL while its operation is still running? | `RunningOpSessionNotSilentlyDropped` | 3 |
| MC-5 | Can a session checkout occur between memory-reap and disk-reap (phase 1 and phase 2) and find no `config.transactions` entry, causing a retried write to execute twice? | `TxnRecordSafeWhileLive`, `NoDanglingImageWithoutTxnRecord` | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV-1 | `AlternativeSessionRegion` destructor null dereference when cache is torn down | Unit test: destroy AlternativeSessionRegion after `LogicalSessionCache::set(svcCtx, nullptr)` |
| TV-2 | `startSession` with child LSID inserts under child key, conflicting with parent-keyed entry from `vivify` | Unit test: call `startSession(childLsid)` then `vivify(childLsid)`, check for duplicate in `_activeSessions` |
| TV-3 | `reapSessionsOlderThan` secondary disk-write via stale `canAcceptWritesForDatabase_UNSAFE` | Integration test: trigger reap during stepup transition |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `scanParentSessions` invariant message says `"via 'scanSessions'"` — copy-paste error | Fix string literal, submit one-line PR |
| CR-2 | `_isDead` declared in `logical_session_cache_impl.h:118` but never defined anywhere | Remove declaration |
| CR-3 | `staleSessions` / `_lastRefreshTime` declared but never used | Remove; flag in code review |
| CR-4 | `shouldRegisterKill` reads stale `lastClientTxnNumberStarted` — kill applied to wrong-txnNumber sibling | Audit whether reading under the catalog scan (which holds the lock) provides sufficient freshness; if not, add a comment or re-read after a fresh checkout |
| CR-5 | `KillSessionTokenOnCommit::commit` delegates to `rollback` — kills session on rollback of config.transactions write | Add code comment; consider whether rollback-kill is always correct behavior or only needed for commits |

---

## 7. Reference Pointers

- **Key source files**:
  - `src/mongo/db/session/session_catalog.cpp` — checkout / kill / release state machine (606 lines)
  - `src/mongo/db/session/session_catalog.h` — SRI data structures, ObservableSession, ScopedCheckedOutSession (587 lines)
  - `src/mongo/db/session/logical_session_cache_impl.cpp` — background refresh + reap workers (535 lines)
  - `src/mongo/db/session/logical_session_cache_impl.h` — cache interface (137 lines)
  - `src/mongo/db/session/session_catalog_mongod.cpp` — kill registration, stepup, reap (836 lines)
- **Historical GitHub issues**: SERVER-122193 (refresh/refresh race), SERVER-94001 (refresh-exit skips ending sessions), SERVER-115981 (errors swallowed), SERVER-73229 (write-error invisible), SERVER-78187 (child kill not propagated), SERVER-77172 (unbounded kill checkout)
- **Category**: Category A (Distributed / Message-Passing); use `distributed-analysis.md` patterns
- **Reference algorithm**: MongoDB Logical Sessions design document; no external paper, but the refresh/reap protocol is analogous to a lease-renewal pattern
