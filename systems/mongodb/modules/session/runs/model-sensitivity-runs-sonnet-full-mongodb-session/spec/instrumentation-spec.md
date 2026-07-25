# Instrumentation Spec: MongoDB Logical Session Lifecycle

Maps TLA+ spec actions in `MongoDBSession.tla` / `Trace.tla` to source code locations for harness generation.

---

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a JSON object emitted as one NDJSON line:

```json
{
  "event":   "<event_name>",
  "session": "<lsid_hex>",
  "state":   { <captured_fields> }
}
```

- **`event`**: matches the trace spec's `IsSessionEvent(name, s)` / `IsEvent(name)` predicates
- **`session`**: the `LogicalSessionId.id` UUID hex string; maps to the `Session` constant
- **`state`**: snapshot of relevant spec variables; captured fields are per-event (see below)

### Common State Fields (captured at every event)

| Field | Implementation getter | TLA+ variable |
|---|---|---|
| `sessionInCatalog` | `SessionCatalog::_sessions.count(lsid) > 0` | `sessionInCatalog[s]` |
| `checkoutOpCtx` | `sri->checkoutOpCtx != nullptr ? "normal_or_kill" : "none"` | `checkoutOpCtx[s]` |
| `killsRequested` | `sri->killsRequested` | `killsRequested[s]` |
| `txnRecordOnDisk` | read from `config.transactions` (shadow bit, see §3) | `txnRecordOnDisk[s]` |
| `imageRecordOnDisk` | read from `config.image_collection` (shadow bit, see §3) | `imageRecordOnDisk[s]` |

---

## Section 2: Action-to-Code Mapping

### `wait_for_checkout`

| Field | Value |
|---|---|
| **Spec action** | `WaitForCheckout(s)` |
| **Code location** | `session_catalog.cpp:128` — `++session->_numWaitingToCheckOut` |
| **Trigger** | After incrementing `_numWaitingToCheckOut`, before entering `waitForConditionOrInterruptUntil` |
| **Event name** | `wait_for_checkout` |
| **Captured fields** | `session`, `state.waiters` (incremented count) |
| **Notes** | Emit once per thread entering the wait loop. The corresponding `checkout_session` event fires when the thread successfully wakes and completes checkout. |

---

### `checkout_session`

| Field | Value |
|---|---|
| **Spec action** | `CheckoutSession(s)` |
| **Code location** | `session_catalog.cpp:150` — `sri->checkoutOpCtx = opCtx` |
| **Trigger** | After assignment `sri->checkoutOpCtx = opCtx` (post-checkout) |
| **Event name** | `checkout_session` |
| **Captured fields** | `session`, `state.checkoutOpCtx = "normal"`, `state.sessionInCatalog`, `state.killsRequested` |
| **Notes** | Emit only for non-kill checkouts. Kill checkout has its own event. Instrumented inside `_checkOutSessionInner` after the wait loop exits (line 150). |

---

### `checkin_session`

| Field | Value |
|---|---|
| **Spec action** | `CheckinSession(s)` |
| **Code location** | `session_catalog.cpp:371` — `sri->checkoutOpCtx = nullptr` |
| **Trigger** | After `checkoutOpCtx = nullptr`, before `notify_all` (line 371, pre-notify) |
| **Event name** | `checkin_session` |
| **Captured fields** | `session`, `state.checkoutOpCtx = "none"` |
| **Notes** | Only emit when `killToken` is absent (normal checkin path, not kill release). |

---

### `request_kill`

| Field | Value |
|---|---|
| **Spec action** | `RequestKill(s)` |
| **Code location** | `session_catalog.cpp` — inside `ObservableSession::kill()` after `++sri->killsRequested` |
| **Trigger** | After incrementing `killsRequested` |
| **Event name** | `request_kill` |
| **Captured fields** | `session`, `state.killsRequested`, `state.killTokenRegistered = false` |
| **Notes** | `kill()` is called from `observeDirectWriteToConfigTransactions` (session_catalog_mongod.cpp:686). Emit immediately after `++sri->killsRequested` inside `kill()`. |

---

### `register_kill_change_succeed`

| Field | Value |
|---|---|
| **Spec action** | `RegisterKillChangeSucceed(s)` |
| **Code location** | `session_catalog_mongod.cpp:684` — after `registerChange(make_unique<KillSessionTokenOnCommit>(...))` returns successfully |
| **Trigger** | After `registerChange` returns without throwing |
| **Event name** | `register_kill_change_succeed` |
| **Captured fields** | `session`, `state.killTokenRegistered = true` |
| **Notes** | Emit in the happy path. If `registerChange` throws, emit `register_kill_change_fail` instead (not a spec action in trace validation — fault injection only). |

---

### `kill_release_clear_checkout`

| Field | Value |
|---|---|
| **Spec action** | `KillReleaseClearCheckout(s)` |
| **Code location** | `session_catalog.cpp:371` — `sri->checkoutOpCtx = nullptr` (inside `_releaseSession` with killToken present) |
| **Trigger** | After `checkoutOpCtx = nullptr`, before `notify_all` |
| **Event name** | `kill_release_clear_checkout` |
| **Captured fields** | `session`, `state.checkoutOpCtx = "none"`, `state.killsRequested` |
| **Notes** | Only emit when `killToken` is present (kill release path). Distinguish from normal checkin by checking `if (killToken)` at line 365. |

---

### `kill_release_notify`

| Field | Value |
|---|---|
| **Spec action** | `KillReleaseNotify(s)` |
| **Code location** | `session_catalog.cpp:372` — `sri->availableCondVar.notify_all()` |
| **Trigger** | After `notify_all()` call, before `--killsRequested` |
| **Event name** | `kill_release_notify` |
| **Captured fields** | `session`, `state.killsRequested` (still > 0 at this point — captures the bug window) |
| **Notes** | This event captures the critical ordering bug window: `notify_all` has fired but `killsRequested` is still > 0. Any waiter that woke will see `_isAvailableForCheckOut(false) = false` and go back to sleep. |

---

### `kill_release_decrement`

| Field | Value |
|---|---|
| **Spec action** | `KillReleaseDecrement(s)` |
| **Code location** | `session_catalog.cpp:376` — `--sri->killsRequested` |
| **Trigger** | After `--sri->killsRequested` |
| **Event name** | `kill_release_decrement` |
| **Captured fields** | `session`, `state.killsRequested` (now decremented), `state.killTokenRegistered = false` |
| **Notes** | Emit immediately after decrement. After this event, there is NO second `notify_all`. |

---

### `start_refresh`

| Field | Value |
|---|---|
| **Spec action** | `StartRefresh` |
| **Code location** | `logical_session_cache_impl.cpp:326` — start of lock scope that swaps `_activeSessions` |
| **Trigger** | Before the `swap(activeSessions, _activeSessions)` at line 330 |
| **Event name** | `start_refresh` |
| **Captured fields** | (no session field) |
| **Notes** | Worker-level event. Emit once per `_refresh` invocation at the start of the active session swap. |

---

### `refresh_succeed`

| Field | Value |
|---|---|
| **Spec action** | `RefreshSucceed(s)` |
| **Code location** | `logical_session_cache_impl.cpp:371` — after `_sessionsColl->refreshSessions(...)` succeeds for session `s` |
| **Trigger** | After successful upsert of `lastUse` for session `s` |
| **Event name** | `refresh_succeed` |
| **Captured fields** | `session`, `state.lastRefreshed = <currentTime>` |
| **Notes** | Emit once per successfully refreshed session. The `lastRefreshed` value should be the logical timestamp used in the upsert (correlate with `_service->now()`). |

---

### `refresh_fail`

| Field | Value |
|---|---|
| **Spec action** | `RefreshFail(s)` |
| **Code location** | `logical_session_cache_impl.cpp:373-398` — inside the `if (refreshRes.hasErrors())` block |
| **Trigger** | After identifying that session `s` is in `refreshRes.failedSessions` |
| **Event name** | `refresh_fail` |
| **Captured fields** | `session`, `state.sessionSource` (whether `"active"` or `"runningOp"`) |
| **Notes** | Emit per failed session. `sessionSource = "active"` if session was in the `activeSessions` map (line 394 loop); `"runningOp"` if it was only in `runningOpSessions` (line 356 loop). This captures the asymmetry at the heart of Family 3. |

---

### `end_refresh`

| Field | Value |
|---|---|
| **Spec action** | `EndRefresh` |
| **Code location** | `logical_session_cache_impl.cpp:454` — end of `_refresh` return |
| **Trigger** | Just before `_refresh` returns |
| **Event name** | `end_refresh` |
| **Captured fields** | (no session field) |

---

### `start_reap`

| Field | Value |
|---|---|
| **Spec action** | `StartReap` |
| **Code location** | `logical_session_cache_impl.cpp:250` — before calling `_reapSessionsOlderThanFn` |
| **Trigger** | Before `_reapSessionsOlderThanFn(opCtx, *_sessionsColl, cutoff)` |
| **Event name** | `start_reap` |
| **Captured fields** | `state.reapCutoff = <cutoff_timestamp>` |
| **Notes** | The `cutoff` is `_service->now() - Minutes(gTransactionRecordMinimumLifetimeMinutes)`. Emit the cutoff value so the trace spec can validate `reapCutoff`. |

---

### `memory_reap`

| Field | Value |
|---|---|
| **Spec action** | `MemoryReap(s)` |
| **Code location** | `session_catalog_mongod.cpp:710-712` — inside `removeExpiredTransactionSessionsNotInUseFromMemory`, after session removed from in-memory catalog |
| **Trigger** | After `SessionCatalog::_sessions.erase(lsid)` |
| **Event name** | `memory_reap` |
| **Captured fields** | `session`, `state.sessionInCatalog = false` |
| **Notes** | This is Phase 1 of the two-phase reap. The session is now absent from the catalog but disk records remain — the bug window starts here. |

---

### `disk_reap_image`

| Field | Value |
|---|---|
| **Spec action** | `DiskReapImage(s)` |
| **Code location** | `session_catalog_mongod.cpp:253-270` — after the `client.remove(imageDeleteOp)` call |
| **Trigger** | After `config.image_collection` delete for session `s` |
| **Event name** | `disk_reap_image` |
| **Captured fields** | `session`, `state.imageRecordOnDisk = false` |
| **Notes** | Phase 2A. Between this and `disk_reap_txn`, there is a window where image is gone but txn record still references it (`NoDanglingImageWithoutTxnRecord` violation). |

---

### `disk_reap_txn`

| Field | Value |
|---|---|
| **Spec action** | `DiskReapTxn(s)` |
| **Code location** | `session_catalog_mongod.cpp:272-291` — after the `client.remove(sessionDeleteOp)` call |
| **Trigger** | After `config.transactions` delete for session `s` |
| **Event name** | `disk_reap_txn` |
| **Captured fields** | `session`, `state.txnRecordOnDisk = false` |
| **Notes** | Phase 2B. After this, both disk records are gone. |

---

### `end_reap`

| Field | Value |
|---|---|
| **Spec action** | `EndReap` |
| **Code location** | `logical_session_cache_impl.cpp:274` — end of `_reap` return |
| **Trigger** | Just before `_reap` returns `Status::OK()` |
| **Event name** | `end_reap` |
| **Captured fields** | (no session field) |

---

## Section 3: Special Considerations

### Shadow bits for disk record existence

`txnRecordOnDisk[s]` and `imageRecordOnDisk[s]` are not directly readable from a running `_refresh` or `_reap` call without a separate read. **Recommended approach**: maintain shadow counters in the harness rather than doing live disk reads.

- Increment `txnRecordOnDisk[s] = TRUE` when a session is created (vivified or started).
- Set `txnRecordOnDisk[s] = FALSE` in the `disk_reap_txn` event handler.
- Set `imageRecordOnDisk[s] = FALSE` in the `disk_reap_image` event handler.

This avoids read-modify-write races and gives precise event boundaries.

### Session ID mapping

The spec uses symbolic constants `{s1, s2}`. In the harness, assign each distinct `LogicalSessionId.id` UUID to a constant. Map via a stable ordering (e.g., lexicographic sort of UUID strings).

### `sessionSource` classification

At `start_refresh` time, the harness must record for each session whether it came from `_activeSessions` (active) or `getActiveOpSessions()` (runningOp). Concretely:

1. Capture the set of active session IDs at the point of `swap(activeSessions, _activeSessions)` → these are `"active"`.
2. Capture the set of running-op session IDs at line 356 → these are `"runningOp"`.
3. Include the `sessionSource` field in each `refresh_fail` event.

### Kill checkout vs normal checkout

Both paths go through `_checkOutSessionInner`. Distinguish via the `killToken` parameter:
- `killToken.has_value() = true` → emit `checkout_for_kill` (not a trace event; kill checkout is inferred from the kill release sequence)
- `killToken.has_value() = false` → emit `checkout_session`

### Three-step kill release ordering

The three kill release events (`kill_release_clear_checkout`, `kill_release_notify`, `kill_release_decrement`) must be emitted **in order** from within `_releaseSession` at `session_catalog.cpp:371-376`. Insert probes:

```cpp
// After line 371: sri->checkoutOpCtx = nullptr
emit("kill_release_clear_checkout", lsid, {checkoutOpCtx: "none", killsRequested: sri->killsRequested})

sri->availableCondVar.notify_all();  // line 372
// After line 372:
emit("kill_release_notify", lsid, {killsRequested: sri->killsRequested})

// ... line 374-375 check killToken ...
--sri->killsRequested;  // line 376
// After line 376:
emit("kill_release_decrement", lsid, {killsRequested: sri->killsRequested, killTokenRegistered: false})
```

The probe at `kill_release_notify` captures the critical state where `killsRequested > 0` and `checkoutOpCtx = "none"` — the window in which a waiter can wake and observe a non-avaliable session.

### Concurrent worker interleaving

`_periodicRefresh` and `_periodicReap` run on separate `PeriodicRunnerImpl` threads (`logical_session_cache_impl.cpp:109-123`). Their events will interleave in the trace. The trace spec's Category A single-cursor approach handles this by replaying events in the recorded order. Ensure the harness includes a global monotonic sequence number in each event to preserve cross-thread ordering during collection.

### Bootstrap state

The trace spec's `TraceInit` initializes all sessions as present in the catalog with no checkout and `killsRequested = 0`. If the implementation starts a trace after some sessions are already checked out or killed, inject synthetic initial events or adjust `TraceInit` to read the first event's `state` snapshot.
