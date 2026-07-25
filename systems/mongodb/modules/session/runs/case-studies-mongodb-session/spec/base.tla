---- MODULE base ----
(*
 * MongoDB Session Lifecycle — Reaper + Prepared Transaction Interaction
 *
 * Models the interaction between session checkout/checkin, the reaper thread,
 * kill-sessions, prepared transactions, step-down, eager reaping, and endSessions.
 *
 * Source: artifact/mongo-src/src/mongo/db/session/
 *         artifact/mongo-src/src/mongo/db/transaction/
 *
 * Bug Families:
 *   F1: Session reaper destroys active/prepared transaction state
 *   F2: Step-down / session checkout deadlock cycle
 *   F3: Prepared transaction + lock hierarchy deadlock (modeled as RSTL contention)
 *   F4: Session/transaction state races during failover
 *   F5: Kill/reap accounting and lifecycle ordering bugs
 *)

EXTENDS Naturals, FiniteSets, Sequences, TLC

\* --- Constants ---

CONSTANTS
    Session,        \* Set of session IDs
    Thread,         \* Set of threads (clients, reaper, step-down, etc.)
    NilThread,      \* Sentinel: no thread
    NilSession      \* Sentinel: no session

ASSUME NilThread \notin Thread
ASSUME NilSession \notin Session

\* --- Variables ---

\* Session catalog state (session_catalog.cpp)
VARIABLES
    sessionExists,      \* [Session -> BOOLEAN] whether session is in the in-memory catalog
    checkoutThread,     \* [Session -> Thread \cup {NilThread}] which thread holds checkout
    killsRequested,     \* [Session -> Nat] pending kill count (session_catalog.h:224)
    numWaiting          \* [Session -> Nat] threads waiting to check out (session.h:76)

sessionVars == <<sessionExists, checkoutThread, killsRequested, numWaiting>>

\* Transaction state (transaction_participant.h:132-140)
VARIABLES
    txnState            \* [Session -> {"none", "inProgress", "prepared", "committed", "aborted"}]

txnVars == <<txnState>>

\* Disk record state — two-step deletion (session_catalog_mongod.cpp:245-294) [F1]
VARIABLES
    imageRecordExists,  \* [Session -> BOOLEAN] config.image_collection entry
    txnRecordExists     \* [Session -> BOOLEAN] config.transactions entry

diskVars == <<imageRecordExists, txnRecordExists>>

\* Step-down state [F2, F3]
VARIABLES
    nodeRole,           \* {"primary", "stepping_down", "secondary"}
    rstlHeld,           \* Thread \cup {NilThread} — which thread holds RSTL exclusively
    checkoutAllowed     \* BOOLEAN — ScopedBlockSessionCheckouts blocks new checkouts

stepDownVars == <<nodeRole, rstlHeld, checkoutAllowed>>

\* Reaper state [F1]
VARIABLES
    reaperPhase,        \* {"idle", "scanned", "deletingImages", "deletingTxns", "done"}
    reaperTargets       \* SUBSET Session — sessions targeted for reaping

reaperVars == <<reaperPhase, reaperTargets>>

\* Eager reap service state (internal_transactions_reap_service.cpp) [F1, F5]
VARIABLES
    eagerReapBuffer,    \* SUBSET Session — sessions queued for eager disk reap
    eagerReapActive     \* BOOLEAN — whether async reap is in progress

eagerReapVars == <<eagerReapBuffer, eagerReapActive>>

\* Session ending state (logical_session_cache_impl.cpp:457-465) [F5]
VARIABLES
    sessionInCache,     \* [Session -> BOOLEAN] whether session is in config.system.sessions
    endingSessions      \* SUBSET Session — sessions marked for ending

endVars == <<sessionInCache, endingSessions>>

\* Thread state — tracks what each thread is doing
VARIABLES
    threadState,        \* [Thread -> {"idle", "checkingOut", "holdingSession", "waitingRSTL", ...}]
    threadSession       \* [Thread -> Session \cup {NilSession}] which session a thread is working with

threadVars == <<threadState, threadSession>>

\* Kill-session tokens [F2, F5]
VARIABLES
    killTokens          \* Bag: set of {session, thread} pairs representing outstanding kill tokens

killVars == <<killTokens>>

vars == <<sessionVars, txnVars, diskVars, stepDownVars, reaperVars,
          eagerReapVars, endVars, threadVars, killVars>>

\* --- Helpers ---

\* Session is available for checkout (session_catalog.cpp:140-142)
\* ObservableSession::_isAvailableForCheckOut
IsAvailableForCheckOut(s, forKill) ==
    /\ checkoutThread[s] = NilThread          \* not currently checked out
    /\ IF forKill THEN TRUE
       ELSE /\ killsRequested[s] = 0          \* no pending kills (session_catalog.h:466-470)

\* Transaction is open (transaction_participant.h:381)
TransactionIsOpen(s) == txnState[s] \in {"inProgress", "prepared"}

\* canBeReaped (transaction_participant.h:363-365)
CanBeReaped(s) == ~TransactionIsOpen(s)

\* Session has a prepared transaction
IsPrepared(s) == txnState[s] = "prepared"

\* --- Init ---

Init ==
    /\ sessionExists     = [s \in Session |-> TRUE]
    /\ checkoutThread    = [s \in Session |-> NilThread]
    /\ killsRequested    = [s \in Session |-> 0]
    /\ numWaiting        = [s \in Session |-> 0]
    /\ txnState          = [s \in Session |-> "none"]
    /\ imageRecordExists = [s \in Session |-> TRUE]
    /\ txnRecordExists   = [s \in Session |-> TRUE]
    /\ nodeRole          = "primary"
    /\ rstlHeld          = NilThread
    /\ checkoutAllowed   = TRUE
    /\ reaperPhase       = "idle"
    /\ reaperTargets     = {}
    /\ eagerReapBuffer   = {}
    /\ eagerReapActive   = FALSE
    /\ sessionInCache    = [s \in Session |-> TRUE]
    /\ endingSessions    = {}
    /\ threadState       = [t \in Thread |-> "idle"]
    /\ threadSession     = [t \in Thread |-> NilSession]
    /\ killTokens        = {}

\* ===================================================================
\* Actions: Session Checkout / Checkin
\* ===================================================================

\* --- CheckOutSession (session_catalog.cpp:105-154) ---
\* Normal checkout: thread acquires exclusive access to a session.
\* Preconditions: session exists, not checked out, no pending kills,
\* checkouts allowed (not blocked by step-down).
CheckOutSession(t, s) ==
    /\ threadState[t] = "idle"
    /\ sessionExists[s]
    /\ checkoutAllowed                           \* session_catalog.cpp:304-306 (disallowNewTransactions)
    /\ IsAvailableForCheckOut(s, FALSE)
    /\ checkoutThread' = [checkoutThread EXCEPT ![s] = t]  \* session_catalog.cpp:150
    /\ threadState' = [threadState EXCEPT ![t] = "holdingSession"]
    /\ threadSession' = [threadSession EXCEPT ![t] = s]
    /\ UNCHANGED <<killsRequested, numWaiting, sessionExists,
                   txnVars, diskVars, stepDownVars, reaperVars,
                   eagerReapVars, endVars, killVars>>

\* --- CheckInSession (session_catalog.cpp:354-417) ---
\* Release session: clears checkout, signals condition variable.
CheckInSession(t) ==
    /\ threadState[t] = "holdingSession"
    /\ LET s == threadSession[t] IN
       /\ checkoutThread[s] = t                  \* invariant: session_catalog.cpp:364
       /\ {s, t} \notin killTokens               \* kill checkouts go through KillSessionFinish
                                                  \* (session_catalog.cpp:374-377 handles kill token in _releaseSession)
       /\ checkoutThread' = [checkoutThread EXCEPT ![s] = NilThread]  \* session_catalog.cpp:371
       /\ threadState' = [threadState EXCEPT ![t] = "idle"]
       /\ threadSession' = [threadSession EXCEPT ![t] = NilSession]
       /\ UNCHANGED <<killsRequested, numWaiting, sessionExists,
                      txnVars, diskVars, stepDownVars, reaperVars,
                      eagerReapVars, endVars, killVars>>

\* ===================================================================
\* Actions: Transaction Lifecycle
\* ===================================================================

\* --- BeginTransaction (transaction_participant.cpp) ---
\* Start a transaction on a checked-out session.
BeginTransaction(t) ==
    /\ threadState[t] = "holdingSession"
    /\ LET s == threadSession[t] IN
       /\ txnState[s] = "none"
       /\ nodeRole = "primary"
       /\ txnState' = [txnState EXCEPT ![s] = "inProgress"]
       /\ UNCHANGED <<sessionVars, diskVars, stepDownVars, reaperVars,
                      eagerReapVars, endVars, threadVars, killVars>>

\* --- PrepareTransaction (transaction_participant.cpp:1924-2114) ---
\* Prepare a transaction. Drops RSTL after prepare (line 2086-2090). [F3]
PrepareTransaction(t) ==
    /\ threadState[t] = "holdingSession"
    /\ LET s == threadSession[t] IN
       /\ txnState[s] = "inProgress"
       /\ nodeRole = "primary"
       /\ txnState' = [txnState EXCEPT ![s] = "prepared"]
       \* After prepare, RSTL is dropped (transaction_participant.cpp:2086-2090)
       \* This allows step-down to proceed, creating the F3 window
       /\ UNCHANGED <<sessionVars, diskVars, stepDownVars, reaperVars,
                      eagerReapVars, endVars, threadVars, killVars>>

\* --- CommitPreparedTransaction (transaction_participant.cpp:2264-2415) ---
\* Commit a prepared transaction. Must reacquire RSTL (line 2286). [F3]
CommitPreparedTransaction(t) ==
    /\ threadState[t] = "holdingSession"
    /\ LET s == threadSession[t] IN
       /\ txnState[s] = "prepared"
       /\ nodeRole = "primary"                   \* Must be primary to commit
       /\ rstlHeld \notin (Thread \ {t})         \* RSTL not exclusively held by another thread
       /\ txnState' = [txnState EXCEPT ![s] = "committed"]
       /\ UNCHANGED <<sessionVars, diskVars, stepDownVars, reaperVars,
                      eagerReapVars, endVars, threadVars, killVars>>

\* --- AbortTransaction (transaction_participant.cpp:2596-2615) ---
\* Abort an in-progress transaction.
AbortTransaction(t) ==
    /\ threadState[t] = "holdingSession"
    /\ LET s == threadSession[t] IN
       /\ txnState[s] = "inProgress"
       /\ txnState' = [txnState EXCEPT ![s] = "aborted"]
       /\ UNCHANGED <<sessionVars, diskVars, stepDownVars, reaperVars,
                      eagerReapVars, endVars, threadVars, killVars>>

\* --- AbortPreparedTransaction (transaction_participant.cpp:2617-2649) ---
\* Abort a prepared transaction. Must reacquire RSTL in IX mode. [F3]
AbortPreparedTransaction(t) ==
    /\ threadState[t] = "holdingSession"
    /\ LET s == threadSession[t] IN
       /\ txnState[s] = "prepared"
       /\ rstlHeld \notin (Thread \ {t})         \* RSTL available (line 2618-2619)
       /\ txnState' = [txnState EXCEPT ![s] = "aborted"]
       /\ UNCHANGED <<sessionVars, diskVars, stepDownVars, reaperVars,
                      eagerReapVars, endVars, threadVars, killVars>>

\* --- ResetTransactionState ---
\* After commit/abort, reset to none (transaction_participant.cpp:3664-3703) [F4]
ResetTransactionState(t) ==
    /\ threadState[t] = "holdingSession"
    /\ LET s == threadSession[t] IN
       /\ txnState[s] \in {"committed", "aborted"}
       /\ txnState' = [txnState EXCEPT ![s] = "none"]
       /\ UNCHANGED <<sessionVars, diskVars, stepDownVars, reaperVars,
                      eagerReapVars, endVars, threadVars, killVars>>

\* ===================================================================
\* Actions: Session Kill (kill_sessions_local.cpp)
\* ===================================================================

\* --- KillSessionMark (kill_sessions_local.cpp:94-98) ---
\* Phase 1: Scan and mark sessions for kill. Increments killsRequested.
\* Models killSessionsAction scan phase.
KillSessionMark(t, s) ==
    /\ threadState[t] = "idle"
    /\ sessionExists[s]
    /\ killsRequested' = [killsRequested EXCEPT ![s] = @ + 1]  \* session.kill() increments
    /\ killTokens' = killTokens \cup {{s, t}}
    /\ threadState' = [threadState EXCEPT ![t] = "killing"]
    /\ threadSession' = [threadSession EXCEPT ![t] = s]
    /\ UNCHANGED <<checkoutThread, numWaiting, sessionExists,
                   txnVars, diskVars, stepDownVars, reaperVars,
                   eagerReapVars, endVars>>

\* --- KillSessionCheckout (kill_sessions_local.cpp:100-143) ---
\* Phase 2: Check out session for kill. Waits until session is available.
\* With kill token, IsAvailableForCheckOut allows checkout even with killsRequested > 0.
KillSessionCheckout(t) ==
    /\ threadState[t] = "killing"
    /\ LET s == threadSession[t] IN
       /\ {s, t} \in killTokens
       /\ IsAvailableForCheckOut(s, TRUE)        \* forKill=TRUE: skip killsRequested check
       /\ checkoutThread' = [checkoutThread EXCEPT ![s] = t]
       /\ threadState' = [threadState EXCEPT ![t] = "holdingSession"]
       /\ UNCHANGED <<killsRequested, numWaiting, sessionExists, threadSession,
                      txnVars, diskVars, stepDownVars, reaperVars,
                      eagerReapVars, endVars, killVars>>

\* --- KillSessionFinish ---
\* Phase 3: After kill checkout, abort transaction and release.
\* killSessionFn aborts unprepared transactions (kill_sessions_local.cpp:159-171).
KillSessionFinish(t) ==
    /\ threadState[t] = "holdingSession"
    /\ LET s == threadSession[t] IN
       /\ {s, t} \in killTokens
       \* Abort if in-progress (not prepared — prepared txns not aborted by kill)
       \* kill_sessions_local.cpp:155-157 filters for transactionIsInProgress
       /\ txnState' = IF txnState[s] = "inProgress"
                       THEN [txnState EXCEPT ![s] = "aborted"]
                       ELSE txnState
       /\ killsRequested' = [killsRequested EXCEPT ![s] = @ - 1]  \* session_catalog.cpp:376
       /\ checkoutThread' = [checkoutThread EXCEPT ![s] = NilThread]
       /\ killTokens' = killTokens \ {{s, t}}
       /\ threadState' = [threadState EXCEPT ![t] = "idle"]
       /\ threadSession' = [threadSession EXCEPT ![t] = NilSession]
       /\ UNCHANGED <<numWaiting, sessionExists,
                      diskVars, stepDownVars, reaperVars,
                      eagerReapVars, endVars>>

\* --- KillSessionTimeout (kill_sessions_local.cpp:126-141) ---
\* Kill checkout times out. Decrements killsRequested if was for-kill. [F2]
\* Models the timeout path where step-down can't complete.
KillSessionTimeout(t) ==
    /\ threadState[t] = "killing"
    /\ LET s == threadSession[t] IN
       /\ {s, t} \in killTokens
       /\ ~IsAvailableForCheckOut(s, TRUE)       \* Can't check out (e.g., held by prepared txn)
       /\ killsRequested' = [killsRequested EXCEPT ![s] = @ - 1]  \* session_catalog.cpp:146
       /\ killTokens' = killTokens \ {{s, t}}
       /\ threadState' = [threadState EXCEPT ![t] = "idle"]
       /\ threadSession' = [threadSession EXCEPT ![t] = NilSession]
       /\ UNCHANGED <<checkoutThread, numWaiting, sessionExists,
                      txnVars, diskVars, stepDownVars, reaperVars,
                      eagerReapVars, endVars>>

\* ===================================================================
\* Actions: Reaper (logical_session_cache_impl.cpp:209-275,
\*                  session_catalog_mongod.cpp:186-232, 238-294, 341-378)
\* ===================================================================

\* --- ReaperScanMemory (session_catalog_mongod.cpp:186-232) ---
\* Reaper scans sessions, checks canBeReaped, removes from memory.
\* Two-step: first scan and identify targets, then delete from disk.
ReaperScanMemory(t) ==
    /\ threadState[t] = "idle"
    /\ reaperPhase = "idle"
    /\ nodeRole = "primary"                      \* session_catalog_mongod.cpp:718-720
    /\ LET targets == {s \in Session :
            /\ sessionExists[s]
            /\ checkoutThread[s] = NilThread     \* Not checked out (scanSessionsForReap)
            /\ CanBeReaped(s)                    \* transaction_participant.h:363-365
            /\ killsRequested[s] = 0}            \* Not being killed
       IN
       /\ reaperTargets' = targets
       \* Remove from memory (scanSessionsForReap erases from catalog)
       /\ sessionExists' = [s \in Session |->
            IF s \in targets THEN FALSE ELSE sessionExists[s]]
       /\ reaperPhase' = "scanned"
       /\ threadState' = [threadState EXCEPT ![t] = "reaping"]
       /\ threadSession' = [threadSession EXCEPT ![t] = NilSession]
       /\ UNCHANGED <<checkoutThread, killsRequested, numWaiting,
                      txnVars, diskVars, stepDownVars,
                      eagerReapVars, endVars, killVars>>

\* --- ReaperDeleteImages (session_catalog_mongod.cpp:253-270) ---
\* First disk deletion step: remove config.image_collection entries. [F1]
ReaperDeleteImages(t) ==
    /\ threadState[t] = "reaping"
    /\ reaperPhase = "scanned"
    /\ imageRecordExists' = [s \in Session |->
         IF s \in reaperTargets THEN FALSE ELSE imageRecordExists[s]]
    /\ reaperPhase' = "deletingImages"
    /\ UNCHANGED <<sessionVars, txnVars, txnRecordExists, reaperTargets,
                   stepDownVars, eagerReapVars, endVars, threadVars, killVars>>

\* --- ReaperDeleteTxnRecords (session_catalog_mongod.cpp:272-294) ---
\* Second disk deletion step: remove config.transactions entries. [F1]
\* Non-atomic: if failure occurs between image and txn deletion, we get DiskConsistency violation.
ReaperDeleteTxnRecords(t) ==
    /\ threadState[t] = "reaping"
    /\ reaperPhase = "deletingImages"
    /\ txnRecordExists' = [s \in Session |->
         IF s \in reaperTargets THEN FALSE ELSE txnRecordExists[s]]
    /\ reaperPhase' = "done"
    /\ threadState' = [threadState EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<sessionVars, txnVars, imageRecordExists, reaperTargets,
                   stepDownVars, eagerReapVars, endVars, threadSession, killVars>>

\* --- ReaperComplete ---
\* Reset reaper to idle after completion.
ReaperComplete ==
    /\ reaperPhase = "done"
    /\ reaperPhase' = "idle"
    /\ reaperTargets' = {}
    /\ UNCHANGED <<sessionVars, txnVars, diskVars, stepDownVars,
                   eagerReapVars, endVars, threadVars, killVars>>

\* --- ReaperFailBetweenDeletes ---
\* Failure between two disk deletion steps. [F1: MC-4]
\* Images deleted but txn records persist — creates inconsistency.
ReaperFailBetweenDeletes(t) ==
    /\ threadState[t] = "reaping"
    /\ reaperPhase = "deletingImages"
    \* Reaper crashes: images already deleted, txn records remain
    /\ reaperPhase' = "idle"
    /\ reaperTargets' = {}
    /\ threadState' = [threadState EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<sessionVars, txnVars, diskVars, stepDownVars,
                   eagerReapVars, endVars, threadSession, killVars>>

\* ===================================================================
\* Actions: Eager Reap (session_catalog.cpp:386-397,
\*                      internal_transactions_reap_service.cpp:129-159)
\* ===================================================================

\* --- EagerReapMark (session_catalog.cpp:386-397) ---
\* During session release, child sessions with old txn numbers are marked for reap.
\* Adds to eager reap buffer (internal_transactions_reap_service.cpp:103-104).
EagerReapMark(s) ==
    /\ sessionExists[s]
    /\ CanBeReaped(s)
    /\ checkoutThread[s] = NilThread
    /\ killsRequested[s] = 0
    /\ eagerReapBuffer' = eagerReapBuffer \cup {s}
    \* Session erased from sri->childSessions (session_catalog.cpp:387-396)
    /\ sessionExists' = [sessionExists EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<checkoutThread, killsRequested, numWaiting,
                   txnVars, diskVars, stepDownVars,
                   reaperVars, eagerReapActive, endVars, threadVars, killVars>>

\* --- EagerReapExecute (internal_transactions_reap_service.cpp:129-159) ---
\* Async worker drains buffer and deletes disk records. [F1]
\* Buffer is swapped out atomically (line 139), then deletion happens.
\* If deletion fails, sessions are lost from pipeline (line 154-158). [F1: MC-5]
EagerReapExecute ==
    /\ eagerReapBuffer /= {}
    /\ ~eagerReapActive
    /\ eagerReapActive' = TRUE
    /\ LET targets == eagerReapBuffer IN
       \* Swap out buffer (internal_transactions_reap_service.cpp:139)
       /\ eagerReapBuffer' = {}
       \* Delete disk records only (removeSessionsTransactionRecords)
       \* Memory removal already happened in _releaseSession erase_if
       /\ imageRecordExists' = [s \in Session |->
            IF s \in targets THEN FALSE ELSE imageRecordExists[s]]
       /\ txnRecordExists' = [s \in Session |->
            IF s \in targets THEN FALSE ELSE txnRecordExists[s]]
    /\ UNCHANGED <<sessionVars,
                   txnVars, stepDownVars, reaperVars, endVars, threadVars, killVars>>

\* --- EagerReapComplete ---
\* Mark eager reap as done.
EagerReapComplete ==
    /\ eagerReapActive
    /\ eagerReapActive' = FALSE
    /\ UNCHANGED <<sessionVars, txnVars, diskVars, stepDownVars,
                   reaperVars, eagerReapBuffer, endVars, threadVars, killVars>>

\* --- EagerReapFail (internal_transactions_reap_service.cpp:154-158) ---
\* Eager reap fails after buffer swap. Sessions lost from pipeline. [F1]
EagerReapFail ==
    /\ eagerReapBuffer /= {}
    /\ ~eagerReapActive
    /\ eagerReapActive' = TRUE
    /\ eagerReapBuffer' = {}     \* Buffer swapped (line 139) but deletion fails
    \* Disk records NOT deleted — but sessions removed from buffer permanently
    /\ UNCHANGED <<sessionVars, txnVars, diskVars, stepDownVars,
                   reaperVars, endVars, threadVars, killVars>>

\* ===================================================================
\* Actions: Step-Down (kill_sessions_local.cpp, session_catalog.cpp)
\* ===================================================================

\* --- StepDownBegin ---
\* Primary begins stepping down. Blocks new checkouts, starts killing sessions. [F2]
\* ScopedBlockSessionCheckouts (session_catalog.cpp:304-306)
StepDownBegin(t) ==
    /\ threadState[t] = "idle"
    /\ nodeRole = "primary"
    /\ checkoutAllowed' = FALSE                  \* Block new checkouts
    /\ nodeRole' = "stepping_down"
    /\ rstlHeld' = t                             \* Step-down thread enqueues/holds RSTL
    /\ threadState' = [threadState EXCEPT ![t] = "steppingDown"]
    /\ UNCHANGED <<sessionExists, checkoutThread, killsRequested, numWaiting,
                   txnVars, diskVars, reaperVars, eagerReapVars, endVars,
                   threadSession, killVars>>

\* --- StepDownKillSessions (kill_sessions_local.cpp:148-177) ---
\* Step-down kills all non-prepared in-progress sessions. [F2]
\* killSessionsAbortUnpreparedTransactions
StepDownKillSessions(t) ==
    /\ threadState[t] = "steppingDown"
    /\ \E s \in Session :
       /\ sessionExists[s]
       /\ checkoutThread[s] /= NilThread         \* Session is checked out
       /\ txnState[s] = "inProgress"             \* kill_sessions_local.cpp:155-157
       /\ killsRequested' = [killsRequested EXCEPT ![s] = @ + 1]
       /\ killTokens' = killTokens \cup {{s, t}}
    /\ UNCHANGED <<checkoutThread, numWaiting, sessionExists,
                   txnVars, diskVars, nodeRole, rstlHeld, checkoutAllowed,
                   reaperVars, eagerReapVars, endVars, threadState, threadSession>>

\* --- StepDownComplete ---
\* All sessions released (no checkouts). Step-down completes. [F2]
StepDownComplete(t) ==
    /\ threadState[t] = "steppingDown"
    /\ \A s \in Session :
       sessionExists[s] => checkoutThread[s] = NilThread  \* All sessions checked in
    /\ \A s \in Session : killsRequested[s] = 0           \* All kills completed
    /\ nodeRole' = "secondary"
    /\ rstlHeld' = NilThread
    /\ checkoutAllowed' = TRUE
    /\ threadState' = [threadState EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<sessionExists, checkoutThread, killsRequested, numWaiting,
                   txnVars, diskVars, reaperVars, eagerReapVars, endVars,
                   threadSession, killVars>>

\* --- StepUp ---
\* Node becomes primary again (after being secondary). [F4]
StepUp ==
    /\ nodeRole = "secondary"
    /\ nodeRole' = "primary"
    /\ checkoutAllowed' = TRUE
    /\ UNCHANGED <<sessionExists, checkoutThread, killsRequested, numWaiting,
                   txnVars, diskVars, rstlHeld, reaperVars,
                   eagerReapVars, endVars, threadVars, killVars>>

\* ===================================================================
\* Actions: EndSessions (logical_session_cache_impl.cpp:457-465) [F5]
\* ===================================================================

\* --- EndSession ---
\* Client ends a session. Removes from config.system.sessions.
\* Does NOT check for prepared transactions (Finding MC-3). [F5]
EndSession(s) ==
    /\ sessionInCache[s]
    /\ endingSessions' = endingSessions \cup {s}
    /\ sessionInCache' = [sessionInCache EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<sessionVars, txnVars, diskVars, stepDownVars,
                   reaperVars, eagerReapVars, threadVars, killVars>>

\* ===================================================================
\* Actions: Fault Injection
\* ===================================================================

\* --- ReaperBypassPreparedCheck ---
\* Models the SERVER-105751 pattern: reaper path that bypasses the
\* prepared transaction check. [F1: MC-1]
\* This is a fault-injection action for hunting.
ReaperBypassPreparedCheck(t) ==
    /\ threadState[t] = "idle"
    /\ reaperPhase = "idle"
    /\ nodeRole = "primary"
    /\ \E s \in Session :
       /\ sessionExists[s]
       /\ checkoutThread[s] = NilThread
       /\ IsPrepared(s)                          \* Session HAS prepared txn — normally blocked
       /\ reaperTargets' = {s}
       /\ sessionExists' = [sessionExists EXCEPT ![s] = FALSE]
    /\ reaperPhase' = "scanned"
    /\ threadState' = [threadState EXCEPT ![t] = "reaping"]
    /\ threadSession' = [threadSession EXCEPT ![t] = NilSession]
    /\ UNCHANGED <<checkoutThread, killsRequested, numWaiting,
                   txnVars, diskVars, stepDownVars,
                   eagerReapVars, endVars, killVars>>

\* --- DiskDeletePartialFailure ---
\* Crash/failure between image deletion and txn record deletion. [F1: MC-4]
\* (Handled by ReaperFailBetweenDeletes above — this is the same action)

\* --- CoordinatorReceivesNoSuchTransaction ---
\* Models the coordinator-side interpretation of a reaped session. [F1: MC-7]
\* If a session with a prepared txn was reaped, coordinator gets NoSuchTransaction.
CoordinatorReceivesNoSuchTransaction(s) ==
    /\ ~sessionExists[s]                         \* Session was reaped from memory
    /\ ~txnRecordExists[s]                       \* And from disk
    /\ txnState[s] = "prepared"                  \* But had a prepared transaction
    \* This is the bug condition — no state change, just observability
    /\ UNCHANGED vars

\* ===================================================================
\* Next State
\* ===================================================================

Next ==
    \/ \E t \in Thread, s \in Session : CheckOutSession(t, s)
    \/ \E t \in Thread : CheckInSession(t)
    \/ \E t \in Thread : BeginTransaction(t)
    \/ \E t \in Thread : PrepareTransaction(t)
    \/ \E t \in Thread : CommitPreparedTransaction(t)
    \/ \E t \in Thread : AbortTransaction(t)
    \/ \E t \in Thread : AbortPreparedTransaction(t)
    \/ \E t \in Thread : ResetTransactionState(t)
    \/ \E t \in Thread, s \in Session : KillSessionMark(t, s)
    \/ \E t \in Thread : KillSessionCheckout(t)
    \/ \E t \in Thread : KillSessionFinish(t)
    \/ \E t \in Thread : KillSessionTimeout(t)
    \/ \E t \in Thread : ReaperScanMemory(t)
    \/ \E t \in Thread : ReaperDeleteImages(t)
    \/ \E t \in Thread : ReaperDeleteTxnRecords(t)
    \/ ReaperComplete
    \/ \E t \in Thread : ReaperFailBetweenDeletes(t)
    \/ \E s \in Session : EagerReapMark(s)
    \/ EagerReapExecute
    \/ EagerReapComplete
    \/ EagerReapFail
    \/ \E t \in Thread : StepDownBegin(t)
    \/ \E t \in Thread : StepDownKillSessions(t)
    \/ \E t \in Thread : StepDownComplete(t)
    \/ StepUp
    \/ \E s \in Session : EndSession(s)
    \/ \E t \in Thread : ReaperBypassPreparedCheck(t)

Spec == Init /\ [][Next]_vars

\* ===================================================================
\* Invariants
\* ===================================================================

\* --- Standard Safety ---

\* At most one thread holds checkout for any session (session_catalog.cpp:150,364)
SessionCheckoutExclusive ==
    \A s \in Session :
        checkoutThread[s] /= NilThread =>
            Cardinality({t \in Thread : checkoutThread[s] = t}) = 1

\* --- Extension Invariants (Bug Family targets) ---

\* F1: A session with a prepared transaction must not have its memory or disk records removed.
\* This is the core invariant for SERVER-105751 and related bugs.
PreparedTxnSafety ==
    \A s \in Session :
        IsPrepared(s) =>
            /\ sessionExists[s]
            /\ txnRecordExists[s]
            /\ imageRecordExists[s]

\* F1: NoSuchTransaction should never occur for a prepared participant.
\* If txn was prepared, the session+disk must still exist.
NoTornTransaction ==
    \A s \in Session :
        txnState[s] = "prepared" =>
            /\ sessionExists[s]
            /\ txnRecordExists[s]

\* F1: Disk consistency — if txn record exists, image record should too.
\* (or both absent). Violation means non-atomic deletion left dangling state.
\* Only checked when reaper is idle — during active deletion, the intermediate state
\* where images are deleted but txn records remain is expected (two-step design).
\* If reaper fails between deletes (ReaperFailBetweenDeletes), it returns to idle
\* with the inconsistency persisted — THAT is what this invariant catches.
DiskConsistency ==
    reaperPhase = "idle" =>
        \A s \in Session :
            txnRecordExists[s] => imageRecordExists[s]

\* F2: After all kill operations complete, killsRequested must be 0.
\* Leaked killsRequested permanently blocks checkout. (session_catalog.cpp:129)
NoKillsRequestedLeak ==
    \A s \in Session :
        (killTokens = {} /\ \A t \in Thread : threadState[t] /= "killing") =>
            killsRequested[s] = 0

\* F5: A session removed from config.system.sessions should not have a prepared txn.
\* endSessions() doesn't check (logical_session_cache_impl.cpp:457-465).
EndSessionSafety ==
    \A s \in Session :
        ~sessionInCache[s] => ~IsPrepared(s)

\* --- Structural Invariants ---

\* If a session is checked out, it must exist
CheckedOutExists ==
    \A s \in Session :
        checkoutThread[s] /= NilThread => sessionExists[s]

\* killsRequested is always >= 0
KillsRequestedNonNeg ==
    \A s \in Session : killsRequested[s] >= 0

\* A thread holding a session must reference an existing session
ThreadSessionConsistency ==
    \A t \in Thread :
        threadState[t] = "holdingSession" =>
            /\ threadSession[t] /= NilSession
            /\ threadSession[t] \in Session
            /\ checkoutThread[threadSession[t]] = t

\* Reaper targets must be sessions that were removed from memory
ReaperTargetsConsistency ==
    reaperPhase /= "idle" =>
        \A s \in reaperTargets : ~sessionExists[s]

\* Transaction state is valid
TxnStateValid ==
    \A s \in Session :
        txnState[s] \in {"none", "inProgress", "prepared", "committed", "aborted"}

\* ===================================================================
\* Temporal Properties
\* ===================================================================

\* F2: Step-down eventually completes (liveness — requires fairness)
StepDownTermination ==
    nodeRole = "stepping_down" ~> nodeRole = "secondary"

====
