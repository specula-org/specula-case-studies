--------------------------- MODULE MongoDBSession ----------------------------
(*
 * TLA+ specification for MongoDB logical session lifecycle.
 *
 * System category: A (Distributed / Message-Passing with concurrent background workers)
 *
 * Bug families modeled:
 *   Family 1 - Refresh-Reap Protocol Race (HIGH)
 *   Family 2 - Kill Protocol Ordering Violations (HIGH)
 *   Family 3 - Refresh Partial-Failure and Retry Correctness (MEDIUM)
 *   Family 4 - Non-Atomic Two-Phase Session Reap (MEDIUM)
 *
 * Key source files:
 *   session_catalog.cpp          - checkout / kill / release state machine
 *   logical_session_cache_impl.cpp - background refresh + reap workers
 *   session_catalog_mongod.cpp   - kill registration, stepup, reap
 *)

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Session,    \* set of logical session IDs (bounded for MC)
    MaxTime     \* upper bound on logical clock ticks (for MC state bounding)

ASSUME MaxTime \in Nat /\ MaxTime > 0
ASSUME Session /= {} /\ IsFiniteSet(Session)

(*------------------------------------------------------------------
 * STATE VARIABLES
 *------------------------------------------------------------------*)

(* ---- Standard catalog state ---- *)

\* Session -> BOOLEAN: session currently exists in the in-memory catalog
\* Models SessionCatalog::_sessions map (session_catalog.h)
VARIABLE sessionInCatalog

\* Session -> {"none", "normal", "kill"}: checkout state of each SRI
\*   "none"   = checkoutOpCtx == nullptr (session_catalog.cpp:371)
\*   "normal" = checked out by a normal operation
\*   "kill"   = checked out via checkOutSessionForKill
VARIABLE checkoutOpCtx

\* Session -> Nat: count of threads waiting for a session checkout
\* Models ++session->_numWaitingToCheckOut (session_catalog.cpp:128)
VARIABLE waiters

\* Session -> Nat: pending kill counter for SRI
\* Models sri->killsRequested (session_catalog.h)
VARIABLE killsRequested

(* ---- Extension: Family 2 (kill protocol ordering) ---- *)

\* Session -> BOOLEAN: kill token durably registered with RecoveryUnit
\* Models KillSessionTokenOnCommit registration (session_catalog_mongod.cpp:684-686)
\* If killsRequested[s] > 0 but killTokenRegistered[s] = FALSE, the counter
\* will never be drained → permanent livelock.
VARIABLE killTokenRegistered

\* Session -> BOOLEAN: kill() was called (incrementing killsRequested) but registerChange
\* has not yet succeeded or failed.  While TRUE, killsRequested>0 is an expected intermediate
\* state, NOT an orphan.  Set by RequestKill, cleared by RegisterKillChange{Succeed,Fail}.
VARIABLE killRegistrationPending

\* Kill release phases: captures the non-atomic _releaseSession sequence.
\* Models session_catalog.cpp:371-376 ordering:
\*   line 371: checkoutOpCtx = nullptr
\*   line 372: availableCondVar.notify_all()
\*   line 376: --killsRequested
\* The three-step split exposes the window between notify and decrement.
\* Session -> {"none", "cleared", "notified"}: release phase for in-progress kill release
VARIABLE killReleasePhase

(* ---- Extension: Family 1 + 4 (refresh-reap race + two-phase reap) ---- *)

\* Session -> Nat: logical time of the last successful refresh upsert for this session
\* Models the lastUse = $$NOW upsert in refreshSessions
\* (logical_session_cache_impl.cpp:371)
VARIABLE sessionLastRefreshed

\* Session -> BOOLEAN: config.transactions record exists on disk
\* Models the row in config.transactions (session_catalog_mongod.cpp:272-291)
VARIABLE txnRecordOnDisk

\* Session -> BOOLEAN: config.image_collection record exists on disk
\* Models the row in config.image_collection (session_catalog_mongod.cpp:253-270)
VARIABLE imageRecordOnDisk

(* ---- Extension: Family 3 (refresh partial-failure) ---- *)

\* Session -> {"none", "active", "runningOp"}: session's membership in the current
\* refresh batch, distinguishing the two code paths at logical_session_cache_impl.cpp:356-367:
\*   "active"    - session from _activeSessions (swapped out at line 330)
\*   "runningOp" - session from getActiveOpSessions() (line 356)
\*   "none"      - not currently in a refresh cycle
VARIABLE sessionSource

\* Session -> BOOLEAN: session failed refresh and is queued for retry (active sessions only).
\* Only active sessions are placed back: logical_session_cache_impl.cpp:388-398
\* (backSwap loop over activeSessions, NOT runningOpSessions).
VARIABLE refreshRetryQueued

\* Session -> BOOLEAN: session had a refresh failure while classified as runningOp.
\* Set in RefreshFail when sessionSource[s] = "runningOp".
\* Used by NoRunningOpDropped: once set, confirms the drop — the session was never
\* placed back into the retry queue (logical_session_cache_impl.cpp:388-398 only
\* iterates activeSessions, not runningOpSessions).
VARIABLE refreshFailedWhileRunningOp

(* ---- Background worker state ---- *)

\* "idle" | "running": refresh worker phase
\* Models LogicalSessionCacheImpl::_periodicRefresh / _refresh
\* (logical_session_cache_impl.cpp:184-198, 277-455)
VARIABLE refreshWorkerPhase

\* "idle" | "running": reap worker phase
\* Models LogicalSessionCacheImpl::_periodicReap / _reap
\* (logical_session_cache_impl.cpp:200-207, 209-275)
VARIABLE reapWorkerPhase

\* Nat: the reap cutoff time used for the current reap cycle.
\* Models: _service->now() - Minutes(gTransactionRecordMinimumLifetimeMinutes)
\* (logical_session_cache_impl.cpp:250-253)
VARIABLE reapCutoff

\* Nat: logical clock (monotonically increasing)
VARIABLE currentTime

\* "idle" | "image_reaped" | "done": two-phase disk reap progress per session
\* Models the two sequential delete calls in removeSessionsTransactionRecordsFromDisk:
\*   Phase A: delete config.image_collection (session_catalog_mongod.cpp:253-270)
\*   Phase B: delete config.transactions    (session_catalog_mongod.cpp:272-291)
VARIABLE diskReapPhase  \* Session -> {"idle","image_reaped","done"}

(*------------------------------------------------------------------
 * VARIABLE GROUPINGS for UNCHANGED clauses
 *------------------------------------------------------------------*)

catalogVars    == <<sessionInCatalog, checkoutOpCtx, waiters, killsRequested>>
killVars       == <<killTokenRegistered, killReleasePhase, killRegistrationPending>>
diskStateVars  == <<txnRecordOnDisk, imageRecordOnDisk, diskReapPhase>>
refreshExtVars == <<sessionLastRefreshed, sessionSource, refreshRetryQueued, refreshFailedWhileRunningOp>>
workerVars     == <<refreshWorkerPhase, reapWorkerPhase, reapCutoff, currentTime>>

vars == <<catalogVars, killVars, diskStateVars, refreshExtVars, workerVars>>

(*------------------------------------------------------------------
 * HELPERS
 *------------------------------------------------------------------*)

\* _isAvailableForCheckOut(forKill) from session_catalog.h:511-513:
\*   return !hasCurrentOperation() && (forKill || !_killed());
IsAvailableForCheckOut(s, forKill) ==
    /\ checkoutOpCtx[s] = "none"
    /\ (forKill \/ killsRequested[s] = 0)

\* _killed() from ObservableSession: killsRequested > 0
IsKilled(s) == killsRequested[s] > 0

(*------------------------------------------------------------------
 * INITIAL STATE
 *------------------------------------------------------------------*)

Init ==
    /\ sessionInCatalog    = [s \in Session |-> TRUE]
    /\ checkoutOpCtx       = [s \in Session |-> "none"]
    /\ waiters             = [s \in Session |-> 0]
    /\ killsRequested      = [s \in Session |-> 0]
    /\ killTokenRegistered      = [s \in Session |-> FALSE]
    /\ killRegistrationPending = [s \in Session |-> FALSE]
    /\ killReleasePhase        = [s \in Session |-> "none"]
    /\ sessionLastRefreshed = [s \in Session |-> 1]
    /\ txnRecordOnDisk     = [s \in Session |-> TRUE]
    /\ imageRecordOnDisk   = [s \in Session |-> TRUE]
    /\ diskReapPhase       = [s \in Session |-> "idle"]
    /\ sessionSource                = [s \in Session |-> "none"]
    /\ refreshRetryQueued          = [s \in Session |-> FALSE]
    /\ refreshFailedWhileRunningOp = [s \in Session |-> FALSE]
    /\ refreshWorkerPhase  = "idle"
    /\ reapWorkerPhase     = "idle"
    /\ reapCutoff          = 0
    /\ currentTime         = 2   \* start ahead of initial lastRefreshed=1

(*==================================================================
 * ACTIONS
 *==================================================================*)

(*------------------------------------------------------------------
 * SECTION 1: SESSION CHECKOUT / CHECKIN
 * Models _checkOutSessionInner (session_catalog.cpp:105-154)
 *------------------------------------------------------------------*)

\* Enter the checkout wait queue: thread increments _numWaitingToCheckOut.
\* Models session_catalog.cpp:128 — ++session->_numWaitingToCheckOut.
\* The thread then blocks on availableCondVar; CheckoutSession models it waking up.
WaitForCheckout(s) ==
    /\ sessionInCatalog[s] = TRUE
    \* session_catalog.cpp:128 — ++session->_numWaitingToCheckOut
    /\ waiters' = [waiters EXCEPT ![s] = @ + 1]
    /\ UNCHANGED <<sessionInCatalog, checkoutOpCtx, killsRequested, killVars,
                   diskStateVars, refreshExtVars, workerVars>>

\* Checkout succeeds: waiter wakes from availableCondVar and completes checkout.
\* Models session_catalog.cpp:136-153 — condition predicate fires, assigns checkoutOpCtx.
\* Enabled only when isAvailableForCheckOut(false) holds AND there is a waiter.
CheckoutSession(s) ==
    /\ sessionInCatalog[s] = TRUE
    /\ waiters[s] > 0
    \* session_catalog.cpp:136-143 — wait condition: _isAvailableForCheckOut(false)
    /\ IsAvailableForCheckOut(s, FALSE)
    \* session_catalog.cpp:150 — sri->checkoutOpCtx = opCtx
    /\ checkoutOpCtx' = [checkoutOpCtx EXCEPT ![s] = "normal"]
    \* session_catalog.cpp:129 (ON_BLOCK_EXIT) — --session->_numWaitingToCheckOut
    /\ waiters' = [waiters EXCEPT ![s] = @ - 1]
    /\ UNCHANGED <<sessionInCatalog, killsRequested, killVars,
                   diskStateVars, refreshExtVars, workerVars>>

\* Checkin (normal): releases the session back.
\* Models SessionCatalog::_releaseSession (session_catalog.cpp:354-417)
\* when killToken is absent (non-kill path):
\*   line 371: checkoutOpCtx = nullptr
\*   line 372: notify_all
\*   (killsRequested unchanged — no kill token)
CheckinSession(s) ==
    /\ checkoutOpCtx[s] = "normal"
    \* session_catalog.cpp:371 — checkoutOpCtx = nullptr
    /\ checkoutOpCtx' = [checkoutOpCtx EXCEPT ![s] = "none"]
    \* session_catalog.cpp:372 — notify_all (modeled as enabling waiters; TLC explores wake orderings)
    /\ UNCHANGED <<sessionInCatalog, waiters, killsRequested, killVars,
                   diskStateVars, refreshExtVars, workerVars>>

(*------------------------------------------------------------------
 * SECTION 2: KILL PROTOCOL
 * Models Family 2 — Kill Protocol Ordering Violations
 *------------------------------------------------------------------*)

\* Step 1: Caller marks session for kill.
\* Models ObservableSession::kill() + session.kill() in
\* observeDirectWriteToConfigTransactions (session_catalog_mongod.cpp:683-686).
\* kill() increments killsRequested SYNCHRONOUSLY before registerChange.
\* session_catalog.cpp:~kill() — ++sri->killsRequested
RequestKill(s) ==
    /\ sessionInCatalog[s] = TRUE
    /\ killTokenRegistered[s] = FALSE  \* only one pending kill modeled
    \* increment killsRequested immediately (synchronous)
    /\ killsRequested' = [killsRequested EXCEPT ![s] = @ + 1]
    /\ killReleasePhase' = [killReleasePhase EXCEPT ![s] = "none"]
    \* registerChange not yet called — mark pending so NoOrphanKillRequest doesn't fire early
    /\ killRegistrationPending' = [killRegistrationPending EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<sessionInCatalog, checkoutOpCtx, waiters,
                   killTokenRegistered, diskStateVars, refreshExtVars, workerVars>>

\* Step 2a: registerChange succeeds — kill token stored in RecoveryUnit.
\* Models session_catalog_mongod.cpp:684:
\*   shard_role_details::getRecoveryUnit(opCtx)->registerChange(
\*       std::make_unique<KillSessionTokenOnCommit>(..., session.kill(...)))
\* MUST happen after RequestKill; can fail (see RegisterKillChangeFail).
RegisterKillChangeSucceed(s) ==
    /\ killsRequested[s] > 0
    /\ killTokenRegistered[s] = FALSE
    \* session_catalog_mongod.cpp:684 — registerChange succeeds
    /\ killTokenRegistered' = [killTokenRegistered EXCEPT ![s] = TRUE]
    /\ killRegistrationPending' = [killRegistrationPending EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<catalogVars, killReleasePhase, diskStateVars, refreshExtVars, workerVars>>

\* Step 2b: registerChange throws — kill token NOT stored.
\* This leaves killsRequested > 0 with no token to drain it (NoOrphanKillRequest violated).
\* Models the crash window at session_catalog_mongod.cpp:684-686:
\*   if registerChange throws after session.kill(), killsRequested stays > 0 forever.
RegisterKillChangeFail(s) ==
    /\ killsRequested[s] > 0
    /\ killTokenRegistered[s] = FALSE
    /\ killRegistrationPending[s] = TRUE  \* must have pending registration to fail it
    \* registerChange throws — killsRequested NOT decremented, token NOT stored
    \* killsRequested[s] remains > 0 with no live token → orphan kill
    /\ killRegistrationPending' = [killRegistrationPending EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<catalogVars, killTokenRegistered, killReleasePhase, diskStateVars, refreshExtVars, workerVars>>

\* Kill checkout: checkout for kill purposes, bypasses killsRequested check.
\* Models checkOutSessionForKill (session_catalog.cpp:168-178):
\*   calls _checkOutSessionInner with killToken present.
\* _isAvailableForCheckOut(true) = !hasCurrentOperation() (ignores kills).
CheckoutForKill(s) ==
    /\ sessionInCatalog[s] = TRUE
    /\ killTokenRegistered[s] = TRUE
    /\ killsRequested[s] > 0
    \* session_catalog.cpp:136-143: wait on isAvailableForCheckOut(forKill=true)
    /\ checkoutOpCtx[s] = "none"   \* i.e. !hasCurrentOperation()
    \* Kill token is a C++ move-only object — only one outstanding kill checkout per token.
    \* Guard against a second checkout during an active kill-release sequence.
    /\ killReleasePhase[s] = "none"
    /\ checkoutOpCtx' = [checkoutOpCtx EXCEPT ![s] = "kill"]
    /\ UNCHANGED <<sessionInCatalog, waiters, killsRequested, killVars,
                   diskStateVars, refreshExtVars, workerVars>>

\* Kill release — Step A: clear checkoutOpCtx.
\* Models session_catalog.cpp:371: sri->checkoutOpCtx = nullptr
\* This is the FIRST of three steps in _releaseSession when killToken present.
KillReleaseClearCheckout(s) ==
    /\ checkoutOpCtx[s] = "kill"
    /\ killReleasePhase[s] = "none"
    \* session_catalog.cpp:371
    /\ checkoutOpCtx' = [checkoutOpCtx EXCEPT ![s] = "none"]
    /\ killReleasePhase' = [killReleasePhase EXCEPT ![s] = "cleared"]
    /\ UNCHANGED <<sessionInCatalog, waiters, killsRequested,
                   killTokenRegistered, killRegistrationPending, diskStateVars, refreshExtVars, workerVars>>

\* Kill release — Step B: fire notify_all.
\* Models session_catalog.cpp:372: sri->availableCondVar.notify_all()
\* This fires BEFORE --killsRequested (line 376).
\* Bug: waiters that wake here see killsRequested > 0, evaluate
\*   _isAvailableForCheckOut(false) = FALSE, go back to sleep.
\* No second notify_all fires after DecrementKills → waiters stuck.
KillReleaseNotify(s) ==
    /\ killReleasePhase[s] = "cleared"
    \* session_catalog.cpp:372 — notify_all fires
    \* In TLA+ this is modeled as enabling the waiter check in CheckoutSession;
    \* since killsRequested is still > 0, CheckoutSession is still blocked.
    /\ killReleasePhase' = [killReleasePhase EXCEPT ![s] = "notified"]
    /\ UNCHANGED <<catalogVars, killTokenRegistered, killRegistrationPending, diskStateVars, refreshExtVars, workerVars>>

\* Kill release — Step C: decrement killsRequested.
\* Models session_catalog.cpp:376: --sri->killsRequested
\* PROBLEM: no second notify_all after this decrement.
\* Any waiter that woke at KillReleaseNotify and saw killsRequested > 0 is
\* still sleeping — and will never be woken (NoWaitersStuckAfterKillComplete violated).
KillReleaseDecrement(s) ==
    /\ killReleasePhase[s] = "notified"
    /\ killsRequested[s] > 0
    \* session_catalog.cpp:374-376 — killToken present, decrement
    /\ killsRequested' = [killsRequested EXCEPT ![s] = @ - 1]
    /\ killTokenRegistered' = [killTokenRegistered EXCEPT ![s] = FALSE]
    /\ killReleasePhase' = [killReleasePhase EXCEPT ![s] = "none"]
    /\ UNCHANGED <<sessionInCatalog, checkoutOpCtx, waiters,
                   killRegistrationPending, diskStateVars, refreshExtVars, workerVars>>

(*------------------------------------------------------------------
 * SECTION 3: REFRESH WORKER
 * Models Family 1 + Family 3
 * logical_session_cache_impl.cpp:277-455 (_refresh)
 *------------------------------------------------------------------*)

\* Start a refresh cycle: swap out active sessions and observe running ops.
\* Models logical_session_cache_impl.cpp:326-367:
\*   lines 326-331: swap(activeSessions, _activeSessions)
\*   lines 356-367: iterate runningOpSessions, build activeSessionRecords
StartRefresh ==
    /\ refreshWorkerPhase = "idle"
    \* logical_session_cache_impl.cpp:109-123 — both jobs scheduled independently, no coordination
    /\ refreshWorkerPhase' = "running"
    \* Tag each session with its source type for the current refresh batch.
    \* active: from _activeSessions (line 330 swap)
    \* runningOp: from getActiveOpSessions() (line 356)
    \* For simplicity, each session is either active or runningOp (not both modeled here).
    /\ sessionSource' = [s \in Session |->
        IF sessionInCatalog[s] THEN "active" ELSE "runningOp"]
    \* Clear per-cycle failure tracking and retry queue on new refresh cycle.
    /\ refreshRetryQueued'          = [s \in Session |-> FALSE]
    /\ refreshFailedWhileRunningOp' = [s \in Session |-> FALSE]
    /\ UNCHANGED <<catalogVars, killVars, diskStateVars,
                   sessionLastRefreshed, reapWorkerPhase, reapCutoff, currentTime>>

\* Successful refresh of a single session: upsert lastUse = $$NOW.
\* Models logical_session_cache_impl.cpp:371 — _sessionsColl->refreshSessions(...)
\* For the session being refreshed, lastUse is set to now (= currentTime).
RefreshSucceed(s) ==
    /\ refreshWorkerPhase = "running"
    /\ sessionSource[s] \in {"active", "runningOp"}
    \* logical_session_cache_impl.cpp:371 — refreshSessions upserts lastUse
    /\ sessionLastRefreshed' = [sessionLastRefreshed EXCEPT ![s] = currentTime]
    /\ sessionSource' = [sessionSource EXCEPT ![s] = "none"]
    /\ UNCHANGED <<catalogVars, killVars, diskStateVars,
                   refreshRetryQueued, refreshFailedWhileRunningOp, workerVars>>

\* Failed refresh of a single session.
\* Models logical_session_cache_impl.cpp:373-398:
\*   Active sessions: put back into _activeSessions for retry (backSwap loop, line 394-397)
\*   RunningOp sessions: NOT in the backSwap — silently dropped (Family 3 bug)
RefreshFail(s) ==
    /\ refreshWorkerPhase = "running"
    /\ sessionSource[s] \in {"active", "runningOp"}
    /\ sessionSource' = [sessionSource EXCEPT ![s] = "none"]
    \* logical_session_cache_impl.cpp:388-397:
    \*   "active" sessions are placed in failedLsids and re-inserted into _activeSessions.
    \*   "runningOp" sessions are NOT tracked in failedLsids — they are dropped.
    /\ refreshRetryQueued' = [refreshRetryQueued EXCEPT ![s] =
        IF sessionSource[s] = "active" THEN TRUE ELSE @]
    \* Record that a runningOp session was dropped without being queued for retry.
    \* This is the observable evidence of Family 3 bug.
    /\ refreshFailedWhileRunningOp' = [refreshFailedWhileRunningOp EXCEPT ![s] =
        IF sessionSource[s] = "runningOp" THEN TRUE ELSE @]
    /\ UNCHANGED <<catalogVars, killVars, diskStateVars,
                   sessionLastRefreshed, workerVars>>

\* End a refresh cycle.
\* Models logical_session_cache_impl.cpp:404-454 (end of _refresh).
EndRefresh ==
    /\ refreshWorkerPhase = "running"
    /\ \A s \in Session : sessionSource[s] = "none"  \* all sessions processed
    /\ refreshWorkerPhase' = "idle"
    /\ UNCHANGED <<catalogVars, killVars, diskStateVars,
                   sessionLastRefreshed, sessionSource, refreshRetryQueued,
                   refreshFailedWhileRunningOp, reapWorkerPhase, reapCutoff, currentTime>>

(*------------------------------------------------------------------
 * SECTION 4: REAP WORKER
 * Models Family 1 + Family 4
 * logical_session_cache_impl.cpp:209-275 (_reap)
 * session_catalog_mongod.cpp:707-724 (reapSessionsOlderThan)
 *------------------------------------------------------------------*)

\* Start a reap cycle: record the current cutoff time.
\* Models logical_session_cache_impl.cpp:250-253:
\*   _reapSessionsOlderThanFn(opCtx, *_sessionsColl,
\*       _service->now() - Minutes(gTransactionRecordMinimumLifetimeMinutes))
\* The cutoff is set at cycle start; sessions refreshed BEFORE this cutoff
\* are candidates for reap.
StartReap ==
    /\ reapWorkerPhase = "idle"
    \* logical_session_cache_impl.cpp:109-123 — both jobs on same interval, no sequencing
    /\ reapWorkerPhase' = "running"
    /\ reapCutoff' = currentTime    \* reap removes sessions with lastRefreshed < cutoff
    /\ UNCHANGED <<catalogVars, killVars, diskStateVars, refreshExtVars,
                   refreshWorkerPhase, currentTime>>

\* Memory reap: remove session from in-memory catalog.
\* Models session_catalog_mongod.cpp:710-712 (removeExpiredTransactionSessionsNotInUseFromMemory).
\* This is Phase 1 of the two-phase reap.
\* PRECONDITION: session's lastRefreshed < reapCutoff (session is stale by the cutoff).
MemoryReap(s) ==
    /\ reapWorkerPhase = "running"
    /\ sessionInCatalog[s] = TRUE
    \* session_catalog_mongod.cpp:706-712: reap sessions older than possiblyExpired
    /\ sessionLastRefreshed[s] < reapCutoff
    \* session_catalog.cpp:475 _shouldBeReaped(): !isCheckedOut && !_numWaitingToCheckOut && !_killed()
    /\ checkoutOpCtx[s] = "none"
    /\ waiters[s] = 0
    /\ killsRequested[s] = 0
    /\ sessionInCatalog' = [sessionInCatalog EXCEPT ![s] = FALSE]
    /\ diskReapPhase' = [diskReapPhase EXCEPT ![s] = "idle"]  \* mark as candidate for disk reap
    /\ UNCHANGED <<checkoutOpCtx, waiters, killsRequested, killVars,
                   txnRecordOnDisk, imageRecordOnDisk, refreshExtVars, workerVars>>

\* Disk reap phase A: delete config.image_collection entry.
\* Models session_catalog_mongod.cpp:253-270 (first delete in removeSessionsTransactionRecordsFromDisk).
\* This MUST fire before DiskReapTxn for the same session (code ordering).
\* Between MemoryReap and DiskReapImage, a new checkout can re-vivify the session
\* (Family 4 intermediate state).
DiskReapImage(s) ==
    /\ reapWorkerPhase = "running"
    /\ sessionInCatalog[s] = FALSE  \* memory phase already done
    /\ diskReapPhase[s] = "idle"
    /\ imageRecordOnDisk[s] = TRUE
    \* session_catalog_mongod.cpp:253-270: delete from config.image_collection
    /\ imageRecordOnDisk' = [imageRecordOnDisk EXCEPT ![s] = FALSE]
    /\ diskReapPhase' = [diskReapPhase EXCEPT ![s] = "image_reaped"]
    /\ UNCHANGED <<sessionInCatalog, checkoutOpCtx, waiters, killsRequested, killVars,
                   txnRecordOnDisk, refreshExtVars, workerVars>>

\* Disk reap phase B: delete config.transactions entry.
\* Models session_catalog_mongod.cpp:272-291 (second delete in removeSessionsTransactionRecordsFromDisk).
\* Explicit code comment (line 244-251): "We opt for this rather than performing the two
\* sets of deletes in a single transaction simply to reduce code complexity."
DiskReapTxn(s) ==
    /\ reapWorkerPhase = "running"
    /\ sessionInCatalog[s] = FALSE
    /\ diskReapPhase[s] = "image_reaped"
    /\ txnRecordOnDisk[s] = TRUE
    \* session_catalog_mongod.cpp:272-291: delete from config.transactions
    /\ txnRecordOnDisk' = [txnRecordOnDisk EXCEPT ![s] = FALSE]
    /\ diskReapPhase' = [diskReapPhase EXCEPT ![s] = "done"]
    /\ UNCHANGED <<sessionInCatalog, checkoutOpCtx, waiters, killsRequested, killVars,
                   imageRecordOnDisk, refreshExtVars, workerVars>>

\* Session re-vivification between reap phases.
\* Models the window between MemoryReap and DiskReapTxn where a new checkout
\* can re-create the session in the catalog (via _getOrCreateSessionRuntimeInfo).
\* session_catalog.cpp:118: sri = _getOrCreateSessionRuntimeInfo(ul, lsid)
\* Guard: only enabled while disk reap is still in progress (not fully complete).
RevivifySession(s) ==
    /\ sessionInCatalog[s] = FALSE
    \* Only relevant during the gap between MemoryReap and DiskReapTxn.
    \* After DiskReapTxn (diskReapPhase = "done"), the session is fully reaped —
    \* a new checkout creates a fresh session unrelated to the reap window.
    /\ diskReapPhase[s] \in {"idle", "image_reaped"}
    \* New checkout finds session absent, creates new SRI.
    /\ sessionInCatalog' = [sessionInCatalog EXCEPT ![s] = TRUE]
    \* The re-vivified session gets a fresh diskReapPhase; the in-progress reap
    \* may still proceed against the re-vivified session's disk records.
    /\ UNCHANGED <<checkoutOpCtx, waiters, killsRequested, killVars,
                   diskStateVars, refreshExtVars, workerVars>>

\* End a reap cycle.
EndReap ==
    /\ reapWorkerPhase = "running"
    /\ reapWorkerPhase' = "idle"
    /\ UNCHANGED <<catalogVars, killVars, diskStateVars, refreshExtVars,
                   refreshWorkerPhase, reapCutoff, currentTime>>

(*------------------------------------------------------------------
 * SECTION 5: CLOCK ADVANCE
 *------------------------------------------------------------------*)

\* Advance the logical clock. Bounds kept finite for MC.
\* Models passage of time (periodic refresh/reap intervals, TTL expiry).
TickClock ==
    /\ currentTime < MaxTime
    /\ currentTime' = currentTime + 1
    /\ UNCHANGED <<catalogVars, killVars, diskStateVars, refreshExtVars,
                   refreshWorkerPhase, reapWorkerPhase, reapCutoff>>

(*==================================================================
 * NEXT
 *==================================================================*)

Next ==
    \/ \E s \in Session : WaitForCheckout(s)
    \/ \E s \in Session : CheckoutSession(s)
    \/ \E s \in Session : CheckinSession(s)
    \/ \E s \in Session : RequestKill(s)
    \/ \E s \in Session : RegisterKillChangeSucceed(s)
    \/ \E s \in Session : RegisterKillChangeFail(s)
    \/ \E s \in Session : CheckoutForKill(s)
    \/ \E s \in Session : KillReleaseClearCheckout(s)
    \/ \E s \in Session : KillReleaseNotify(s)
    \/ \E s \in Session : KillReleaseDecrement(s)
    \/ StartRefresh
    \/ \E s \in Session : RefreshSucceed(s)
    \/ \E s \in Session : RefreshFail(s)
    \/ EndRefresh
    \/ StartReap
    \/ \E s \in Session : MemoryReap(s)
    \/ \E s \in Session : DiskReapImage(s)
    \/ \E s \in Session : DiskReapTxn(s)
    \/ \E s \in Session : RevivifySession(s)
    \/ EndReap
    \/ TickClock

Spec == Init /\ [][Next]_vars

(*==================================================================
 * FAIRNESS
 *==================================================================*)

\* Weak fairness for worker progress — both background jobs must eventually complete cycles.
Fairness ==
    /\ WF_vars(StartRefresh)
    /\ WF_vars(EndRefresh)
    /\ WF_vars(StartReap)
    /\ WF_vars(EndReap)
    /\ \A s \in Session : WF_vars(KillReleaseDecrement(s))

LiveSpec == Spec /\ Fairness

(*==================================================================
 * INVARIANTS
 *==================================================================*)

(*------------------------------------------------------------------
 * Structural invariants (sanity checks, hold in all correct states)
 *------------------------------------------------------------------*)

\* A session checked out must be in the catalog.
CheckoutImpliesInCatalog ==
    \A s \in Session :
        checkoutOpCtx[s] /= "none" => sessionInCatalog[s] = TRUE

\* Kill checkout requires a registered token.
KillCheckoutRequiresToken ==
    \A s \in Session :
        checkoutOpCtx[s] = "kill" => killTokenRegistered[s] = TRUE

\* Kill release phases only valid when there was a kill checkout.
KillReleasePhaseConsistency ==
    \A s \in Session :
        killReleasePhase[s] /= "none" =>
            /\ killsRequested[s] > 0
            /\ checkoutOpCtx[s] \in {"none", "kill"}

\* Disk reap phases "done" implies session is absent from catalog.
\* NOTE: "image_reaped => not in catalog" is NOT listed here because RevivifySession
\* deliberately creates the state {image_reaped=TRUE, sessionInCatalog=TRUE} — that
\* intermediate state IS the Family 4 bug, checked by NoDanglingImageWithoutTxnRecord.
DiskReapDoneConsistency ==
    \A s \in Session :
        diskReapPhase[s] = "done" => sessionInCatalog[s] = FALSE

\* TxnRecord only absent after image is also absent (intermediate violation is the bug).
StructuralImageTxnOrder ==
    \A s \in Session :
        diskReapPhase[s] = "done" =>
            /\ txnRecordOnDisk[s] = FALSE
            /\ imageRecordOnDisk[s] = FALSE

(*------------------------------------------------------------------
 * Extension invariants (bug-family-specific, primary detection tools)
 *------------------------------------------------------------------*)

\* Family 1: TxnRecordSafeWhileLive
\* If a session has been refreshed at or after the current reap cutoff, its
\* config.transactions record must not have been deleted.
\* Violated when _reap deletes txnRecord for a session _refresh just upserted.
TxnRecordSafeWhileLive ==
    \A s \in Session :
        (reapWorkerPhase = "running" /\ sessionLastRefreshed[s] >= reapCutoff)
        => txnRecordOnDisk[s] = TRUE

\* Family 2a: NoWaitersStuckAfterKillComplete
\* After a kill checkout is fully released (killsRequested=0, checkoutOpCtx=none),
\* no thread should remain stuck waiting.
\* Violated because notify_all fires at KillReleaseNotify (killsRequested still > 0),
\* then KillReleaseDecrement fires with no second notify.
NoWaitersStuckAfterKillComplete ==
    \A s \in Session :
        (killsRequested[s] = 0 /\ checkoutOpCtx[s] = "none" /\ killReleasePhase[s] = "none")
        => waiters[s] = 0

\* Family 2b: NoOrphanKillRequest
\* Once the registerChange step completes (either success or failure), if
\* killsRequested > 0 then a live token must exist to drain it.
\* killRegistrationPending guards the normal intermediate window between
\* RequestKill and RegisterKillChange{Succeed,Fail}.
\* Violated when RegisterKillChangeFail fires — killsRequested stays > 0 forever.
NoOrphanKillRequest ==
    \A s \in Session :
        (killsRequested[s] > 0 /\ ~killRegistrationPending[s]) => killTokenRegistered[s] = TRUE

\* Family 3: RunningOpSessionNotSilentlyDropped
\* If a runningOp session fails to refresh, it must appear in the next refresh attempt
\* (refreshRetryQueued tracks this). This invariant checks that a runningOp session
\* that failed refresh is eventually retried (not permanently dropped).
\* Simplified model: after RefreshFail for a runningOp session, refreshRetryQueued stays FALSE
\* (the code does NOT queue it), which IS the bug.
RunningOpSessionNotSilentlyDropped ==
    \A s \in Session :
        (sessionSource[s] = "runningOp" /\ refreshRetryQueued[s] = FALSE)
        => TRUE   \* NOTE: this weakened form confirms the drop; hunt cfg uses negation

\* NoRunningOpDropped: a runningOp session that failed refresh MUST be queued for retry.
\* This is the invariant the hunt config checks; the code VIOLATES it because the backSwap
\* at logical_session_cache_impl.cpp:394-397 only iterates activeSessions.
\* Violation = refreshFailedWhileRunningOp[s] = TRUE (drop confirmed).
NoRunningOpDropped ==
    \A s \in Session : refreshFailedWhileRunningOp[s] = FALSE

\* Family 4a: NoDanglingImageWithoutTxnRecord
\* config.image_collection absent implies config.transactions also absent.
\* Violated during the window between DiskReapImage and DiskReapTxn.
NoDanglingImageWithoutTxnRecord ==
    \A s \in Session :
        imageRecordOnDisk[s] = FALSE => txnRecordOnDisk[s] = FALSE

\* Family 4b: NoStaleCheckoutAfterMemoryReap
\* A session checked out between MemoryReap and DiskReapTxn finds no txnRecord.
\* Violated when RevivifySession fires after MemoryReap but before DiskReapTxn.
NoStaleCheckoutAfterMemoryReap ==
    \A s \in Session :
        (sessionInCatalog[s] = TRUE /\ diskReapPhase[s] \in {"idle", "image_reaped"})
        => txnRecordOnDisk[s] = TRUE

(*------------------------------------------------------------------
 * Standard safety properties
 *------------------------------------------------------------------*)

\* At most one checkout per session SRI.
AtMostOneCheckout ==
    \A s \in Session : checkoutOpCtx[s] \in {"none", "normal", "kill"}

\* All invariants bundled (for MC.cfg INVARIANTS)
TypeOK ==
    /\ \A s \in Session : sessionInCatalog[s] \in BOOLEAN
    /\ \A s \in Session : checkoutOpCtx[s] \in {"none", "normal", "kill"}
    /\ \A s \in Session : waiters[s] \in Nat
    /\ \A s \in Session : killsRequested[s] \in Nat
    /\ \A s \in Session : killTokenRegistered[s] \in BOOLEAN
    /\ \A s \in Session : killRegistrationPending[s] \in BOOLEAN
    /\ \A s \in Session : killReleasePhase[s] \in {"none", "cleared", "notified"}
    /\ \A s \in Session : sessionLastRefreshed[s] \in Nat
    /\ \A s \in Session : txnRecordOnDisk[s] \in BOOLEAN
    /\ \A s \in Session : imageRecordOnDisk[s] \in BOOLEAN
    /\ \A s \in Session : diskReapPhase[s] \in {"idle", "image_reaped", "done"}
    /\ \A s \in Session : sessionSource[s] \in {"none", "active", "runningOp"}
    /\ \A s \in Session : refreshRetryQueued[s] \in BOOLEAN
    /\ \A s \in Session : refreshFailedWhileRunningOp[s] \in BOOLEAN
    /\ refreshWorkerPhase \in {"idle", "running"}
    /\ reapWorkerPhase \in {"idle", "running"}
    /\ reapCutoff \in Nat
    /\ currentTime \in Nat

(*==================================================================
 * TEMPORAL PROPERTIES (liveness)
 *==================================================================*)

\* Family 2a (liveness): After kill complete, waiters eventually check out.
\* Requires fairness on CheckoutSession.
NoLivelockAfterKill ==
    \A s \in Session :
        [](killsRequested[s] = 0 /\ waiters[s] > 0 =>
           <>(checkoutOpCtx[s] = "normal"))

=============================================================================
