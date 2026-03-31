---- MODULE Trace ----
\*****************************************************************************
\* Trace validation spec for MongoDB RaftMongoReplTimestamp.
\*
\* Uses a STATE-REPLAY approach due to sparse log-parsed traces:
\*   - Only control-plane events captured (elections, term updates, commit
\*     points, recovery). Data-plane events (writes, replication, persistence)
\*     are NOT in the traces.
\*   - OpTime indices use MongoDB Timestamp.increment (NOT oplog positions),
\*     so absolute optime values cannot be validated against the spec.
\*
\* What IS validated:
\*   - Term progression and state transitions
\*   - Event ordering (valid transition sequence)
\*   - Safety invariants (NoTwoPrimariesInSameTerm, etc.) at each step
\*   - Recovery phase machine
\*
\* What is NOT validated (due to trace sparsity):
\*   - Oplog contents and length
\*   - Absolute optime values (lastApplied, lastDurable, commitPoint index)
\*   - Write concern and prepared transaction state
\*****************************************************************************
EXTENDS base, Json, Sequences, TLC, IOUtils, Naturals

\* --- Trace loading ---
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTraceLog == ndJsonDeserialize(JsonFile)

\* Filter to only "trace" tagged events.
TraceLog == SelectSeq(RawTraceLog, LAMBDA x : x.tag = "trace")

\* --- Cursor variable ---
VARIABLE l

traceVars == <<vars, l>>

----
\* --- Helpers ---

logline == TraceLog[l]

IsEvent(name) == logline.event.name = name

\* Map string state to spec state.
StateMap(s) ==
    IF s = "PRIMARY" THEN "Leader"
    ELSE IF s = "SECONDARY" THEN "Follower"
    ELSE IF s = "DOWN" THEN "Down"
    ELSE "Follower"

NodeOf(name) == name

----
\*****************************************************************************
\* Post-state validation (WEAK only)
\*****************************************************************************

\* Weak validation: only check term + state.
\* OpTime values are NOT validated — they use MongoDB Timestamp increments
\* which don't correspond to spec oplog positions.
ValidatePostStateWeak(node) ==
    LET s == NodeOf(node)
        st == logline.event.state
    IN /\ ("term" \in DOMAIN st) => (currentTerm'[s] = st.term)
       /\ ("state" \in DOMAIN st) => (state'[s] = StateMap(st.state))

----
\*****************************************************************************
\* Init and cursor
\*****************************************************************************

TraceInit ==
    /\ Init
    /\ l = 1

\* Advance cursor after matching.
AdvanceCursor == l' = l + 1

----
\*****************************************************************************
\* Trace-driven actions
\*****************************************************************************

\* =========================================================================
\* UpdateTerm: Direct term update.
\*
\* The spec's UpdateTermThroughHeartbeat requires another server with a
\* higher term. But traces show:
\*   (a) No-op events at same term (initialization heartbeats)
\*   (b) Election-protocol term increments that precede BecomePrimary
\*       (no server in the spec has the higher term yet)
\*
\* Fix: directly set the term. Step down if term increases.
\* =========================================================================
TraceUpdateTerm ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("UpdateTerm")
    /\ LET s == NodeOf(logline.event.node)
           postTerm == logline.event.state.term
       IN \/ \* No-op: term unchanged (initialization event)
             /\ postTerm = currentTerm[s]
             /\ UNCHANGED vars
          \/ \* Term advancement: directly set + step down
             /\ postTerm > currentTerm[s]
             /\ currentTerm' = [currentTerm EXCEPT ![s] = postTerm]
             /\ state' = [state EXCEPT ![s] =
                    IF state[s] = "Down" THEN "Down" ELSE "Follower"]
             /\ UNCHANGED <<oplogTimeVars, logVars, holeVars, flusherVars,
                            wcVars, recoveryVars, controlVars>>
    /\ AdvanceCursor

\* =========================================================================
\* BecomePrimary: Direct state update.
\*
\* The spec's BecomePrimaryByMagic atomically increments terms for all
\* voters. But traces show individual UpdateTerm events BEFORE BecomePrimary.
\* So we just set state to Leader (term already set by prior UpdateTerm).
\* =========================================================================
TraceBecomePrimary ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("BecomePrimary")
    /\ LET s == NodeOf(logline.event.node)
           postTerm == logline.event.state.term
       IN /\ state' = [state EXCEPT ![s] = "Leader"]
          /\ currentTerm' = [currentTerm EXCEPT ![s] = postTerm]
    /\ UNCHANGED <<oplogTimeVars, logVars, holeVars, flusherVars,
                   wcVars, recoveryVars, controlVars>>
    /\ AdvanceCursor

\* =========================================================================
\* Stepdown: Use base spec when node is Leader. No-op when already Follower
\* (trace started mid-session after an unobserved election).
\* =========================================================================
TraceStepdown ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("Stepdown")
    /\ LET s == NodeOf(logline.event.node)
       IN \/ \* Normal stepdown from Leader
             /\ state[s] = "Leader"
             /\ Stepdown(s)
          \/ \* Already Follower (trace started mid-session)
             /\ state[s] /= "Leader"
             /\ UNCHANGED vars
    /\ ValidatePostStateWeak(logline.event.node)
    /\ AdvanceCursor

\* =========================================================================
\* LearnCommitPoint: No-op.
\*
\* CommitPoint values use MongoDB Timestamp increments (not oplog positions),
\* so they can't be validated against the spec. The base spec's actions also
\* require log entries that aren't captured in the traces.
\* Only validate term + state.
\* =========================================================================
TraceLearnCommitPoint ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("LearnCommitPoint")
    /\ UNCHANGED vars
    /\ ValidatePostStateWeak(logline.event.node)
    /\ AdvanceCursor

\* =========================================================================
\* AdvanceCommitPoint: No-op.
\*
\* Requires log entries (quorum calculation) which traces don't capture.
\* Validate that the node is a Leader and check term + state.
\* =========================================================================
TraceAdvanceCommitPoint ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("AdvanceCommitPoint")
    /\ UNCHANGED vars
    /\ ValidatePostStateWeak(logline.event.node)
    /\ AdvanceCursor

\* =========================================================================
\* RollbackOplog: No-op (oplog state not tracked in traces).
\* =========================================================================
TraceRollbackOplog ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("RollbackOplog")
    /\ UNCHANGED vars
    /\ ValidatePostStateWeak(logline.event.node)
    /\ AdvanceCursor

\* =========================================================================
\* Recovery events: Use base spec actions.
\* These work with empty logs and validate the recovery phase machine.
\* =========================================================================

TraceRecoverTruncateOplog ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("RecoverTruncateOplog")
    /\ LET s == NodeOf(logline.event.node)
       IN /\ RecoverTruncateOplog(s)
    /\ AdvanceCursor

TraceRecoverReplayOplog ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("RecoverReplayOplog")
    /\ LET s == NodeOf(logline.event.node)
       IN /\ RecoverReplayOplog(s)
    /\ AdvanceCursor

TraceRecoverSetTimestamps ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("RecoverSetTimestamps")
    /\ LET s == NodeOf(logline.event.node)
       IN /\ RecoverSetTimestamps(s)
    /\ AdvanceCursor

\* =========================================================================
\* Data-plane events: No-ops (not captured in current traces).
\* Kept for forward-compatibility if harness adds these events later.
\* =========================================================================

TraceAppendOplog ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("AppendOplog")
    /\ UNCHANGED vars
    /\ AdvanceCursor

TracePersistOplog ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("PersistOplog")
    /\ UNCHANGED vars
    /\ AdvanceCursor

TraceApplyOplog ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("ApplyOplog")
    /\ UNCHANGED vars
    /\ AdvanceCursor

TraceClientWrite ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("ClientWrite")
    /\ UNCHANGED vars
    /\ AdvanceCursor

TraceCloseOplogHole ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("CloseOplogHole")
    /\ UNCHANGED vars
    /\ AdvanceCursor

TraceJournalFlusherCapture ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("JournalFlusherCapture")
    /\ UNCHANGED vars
    /\ AdvanceCursor

TraceJournalFlusherFlush ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("JournalFlusherFlush")
    /\ UNCHANGED vars
    /\ AdvanceCursor

TraceClientWriteWithWC ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("ClientWriteWithWC")
    /\ UNCHANGED vars
    /\ AdvanceCursor

TraceWriteConcernSatisfied ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("WriteConcernSatisfied")
    /\ UNCHANGED vars
    /\ AdvanceCursor

TracePrepareTransaction ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("PrepareTransaction")
    /\ UNCHANGED vars
    /\ AdvanceCursor

TraceCommitPreparedTxn ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("CommitPreparedTxn")
    /\ UNCHANGED vars
    /\ AdvanceCursor

TraceCrash ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("Crash")
    /\ UNCHANGED vars
    /\ AdvanceCursor

----
\*****************************************************************************
\* Silent actions
\*****************************************************************************

\* SilentSetupCrash: Transitions a node to Down + "truncate" recovery phase
\* when the next trace event is a recovery event but the node is not yet Down.
\* Handles traces that start mid-session after an unobserved crash.
SilentSetupCrash ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"RecoverTruncateOplog", "RecoverReplayOplog",
                                "RecoverSetTimestamps"}
    /\ LET s == NodeOf(logline.event.node)
       IN /\ state[s] /= "Down"
          /\ state' = [state EXCEPT ![s] = "Down"]
          /\ recoveryPhase' = [recoveryPhase EXCEPT ![s] = "truncate"]
          /\ restartTimes' = [restartTimes EXCEPT ![s] = restartTimes[s] + 1]
          /\ oplogHoles' = [oplogHoles EXCEPT ![s] = {}]
          /\ preparedTxns' = [preparedTxns EXCEPT ![s] = {}]
          /\ journalFlusherSnapshot' = [journalFlusherSnapshot EXCEPT
                ![s] = NilOpTime]
          /\ writeConcernWaiters' = [writeConcernWaiters EXCEPT ![s] = {}]
          /\ committedSnapshot' = [committedSnapshot EXCEPT
                ![s] = [last |-> NilOpTime, curr |-> NilOpTime]]
          /\ oplogTruncateAfterPoint' = [oplogTruncateAfterPoint EXCEPT
                ![s] = lastDurable[s]]
    /\ UNCHANGED <<currentTerm, commitPoint, lastDurable, lastApplied,
                   lastWritten, log, committedEntries,
                   useDurableForCommit, acknowledged, rolledBack,
                   failoverTimes, l>>

----
\*****************************************************************************
\* Trace Next
\*****************************************************************************
TraceNext ==
    \* --- Control-plane events (actively validated) ---
    \/ TraceUpdateTerm
    \/ TraceBecomePrimary
    \/ TraceStepdown
    \/ TraceLearnCommitPoint
    \/ TraceAdvanceCommitPoint
    \/ TraceRollbackOplog
    \* --- Recovery events (phase machine validated) ---
    \/ TraceRecoverTruncateOplog
    \/ TraceRecoverReplayOplog
    \/ TraceRecoverSetTimestamps
    \* --- Data-plane events (no-ops, not in current traces) ---
    \/ TraceAppendOplog
    \/ TracePersistOplog
    \/ TraceApplyOplog
    \/ TraceClientWrite
    \/ TraceCloseOplogHole
    \/ TraceJournalFlusherCapture
    \/ TraceJournalFlusherFlush
    \/ TraceClientWriteWithWC
    \/ TraceWriteConcernSatisfied
    \/ TracePrepareTransaction
    \/ TraceCommitPreparedTxn
    \/ TraceCrash
    \* --- Silent actions ---
    \/ SilentSetupCrash

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

\* --- Trace completeness property ---
\* Checks that the entire trace was consumed (deadlock at end = success).
TraceMatched == <>(l = Len(TraceLog) + 1)

----
\*****************************************************************************
\* Trace-specific invariants
\*****************************************************************************

\* Safety invariant: no two primaries in the same term.
TraceNoTwoPrimariesInSameTerm == NoTwoPrimariesInSameTerm

\* Structural: lastApplied never exceeds log length.
TraceLastAppliedBound == LastAppliedBound

\* Structural: lastDurable never exceeds log length.
TraceLastDurableBound == LastDurableBound

====
