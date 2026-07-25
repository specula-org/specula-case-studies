---- MODULE Trace ----
\* ===========================================================================
\* Trace Validation Spec for MongoDB Transaction Router & Resource Contention
\*
\* Replays NDJSON traces against the base spec to verify that the
\* implementation's observed behavior is consistent with the model.
\*
\* Trace events map to base spec actions. Each trace event:
\* 1. Matches by event name
\* 2. Calls the base spec action
\* 3. Validates post-state against trace fields
\* 4. Advances cursor l
\*
\* Silent actions handle state changes not captured in the trace.
\* ===========================================================================
EXTENDS base, Json, Sequences, TLC, IOUtils

\* ===========================================================================
\* Trace Loading
\* ===========================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTraceLog == ndJsonDeserialize(JsonFile)

TraceLog ==
    SelectSeq(RawTraceLog, LAMBDA x : "event" \in DOMAIN x)

ASSUME PrintT(<<"TraceLog length:", Len(TraceLog)>>)
ASSUME Len(TraceLog) > 0

\* ===========================================================================
\* Trace-derived Constants
\* ===========================================================================

TraceShard == TLCEval(
    UNION {{TraceLog[k].shard} :
        k \in {i \in 1..Len(TraceLog) : "shard" \in DOMAIN TraceLog[i]}}
    \cup
    UNION {DOMAIN TraceLog[k].participants :
        k \in {i \in 1..Len(TraceLog) : "participants" \in DOMAIN TraceLog[i]}})

TraceRouter == TLCEval(
    UNION {{TraceLog[k].router} :
        k \in {i \in 1..Len(TraceLog) : "router" \in DOMAIN TraceLog[i]}})

TraceTxn == TLCEval(
    UNION {{TraceLog[k].txn} :
        k \in {i \in 1..Len(TraceLog) : "txn" \in DOMAIN TraceLog[i]}})

\* Derive MaxTickets from trace if present, else default
TraceMaxTickets ==
    IF \E k \in 1..Len(TraceLog) : "maxTickets" \in DOMAIN TraceLog[k]
    THEN TraceLog[CHOOSE k \in 1..Len(TraceLog) : "maxTickets" \in DOMAIN TraceLog[k]].maxTickets
    ELSE 128

\* ===========================================================================
\* Cursor Variable
\* ===========================================================================

VARIABLE l  \* Trace cursor: current position in TraceLog (1..Len(TraceLog)+1)

traceVars == <<vars, l>>

\* Current log line (safe access)
logline == TraceLog[l]

\* ===========================================================================
\* Event Predicates
\* ===========================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

IsRouterEvent(name, r) ==
    /\ IsEvent(name)
    /\ logline.router = r

IsTxnEvent(name, t) ==
    /\ IsEvent(name)
    /\ logline.txn = t

IsRouterTxnEvent(name, r, t) ==
    /\ IsEvent(name)
    /\ logline.router = r
    /\ logline.txn = t

IsShardTxnEvent(name, s, t) ==
    /\ IsEvent(name)
    /\ logline.shard = s
    /\ logline.txn = t

\* ===========================================================================
\* Post-State Validation
\* ===========================================================================

\* Strong: validate all state fields present in trace
ValidatePostState(r, t) ==
    /\ ("commitType" \in DOMAIN logline =>
        rCommitType'[r][t] = logline.commitType)
    /\ ("rPhase" \in DOMAIN logline =>
        rPhase'[r][t] = logline.rPhase)

ValidateShardState(s, t) ==
    /\ ("sState" \in DOMAIN logline =>
        sState'[s][t] = logline.sState)

ValidateCoordState(t) ==
    /\ ("cPhase" \in DOMAIN logline =>
        cPhase'[t] = logline.cPhase)
    /\ ("cDecision" \in DOMAIN logline =>
        cDecision'[t] = logline.cDecision)

ValidateTickets ==
    /\ ("tickets" \in DOMAIN logline =>
        tickets' = logline.tickets)

\* Constrain participant kinds to match trace (for RouterStartTxn)
ValidateParticipants(r, t) ==
    ("participants" \in DOMAIN logline =>
        \A s \in Shard :
            IF s \in DOMAIN logline.participants
            THEN rPK'[r][t][s] = logline.participants[s]
            ELSE rPK'[r][t][s] = "PK_none")

\* Constrain disallowSWS to FALSE unless specified in trace
ValidateDisallowSWS(r, t) ==
    ("disallowSWS" \notin DOMAIN logline =>
        rDisallowSWS'[r][t] = FALSE)

\* ===========================================================================
\* Trace Action Wrappers
\* ===========================================================================

\* ---------------------------------------------------------------------------
\* TraceRouterStartTxn
\* ---------------------------------------------------------------------------
TraceRouterStartTxn ==
    /\ \E r \in Router, t \in Txn :
        /\ IsRouterTxnEvent("RouterStartTxn", r, t)
        /\ RouterStartTxn(r, t)
        /\ ValidatePostState(r, t)
        /\ ValidateParticipants(r, t)
        /\ ValidateDisallowSWS(r, t)
        /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* TraceRouterCommitTxn
\* ---------------------------------------------------------------------------
TraceRouterCommitTxn ==
    /\ \E r \in Router, t \in Txn :
        /\ IsRouterTxnEvent("RouterCommitTxn", r, t)
        /\ RouterCommitTxn(r, t)
        /\ ValidatePostState(r, t)
        /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* TraceDirectCommit
\* ---------------------------------------------------------------------------
TraceDirectCommit ==
    /\ \E r \in Router, t \in Txn :
        /\ IsRouterTxnEvent("DirectCommit", r, t)
        /\ DirectCommit(r, t)
        /\ ValidatePostState(r, t)
        /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* TraceSWSCommitReadOnly
\* ---------------------------------------------------------------------------
TraceSWSCommitReadOnly ==
    /\ \E r \in Router, t \in Txn :
        /\ IsRouterTxnEvent("SWSCommitReadOnly", r, t)
        /\ SWSCommitReadOnly(r, t)
        /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* TraceSWSCommitWrite
\* ---------------------------------------------------------------------------
TraceSWSCommitWrite ==
    /\ \E r \in Router, t \in Txn :
        /\ IsRouterTxnEvent("SWSCommitWrite", r, t)
        /\ SWSCommitWrite(r, t)
        /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* TraceSWSRetryRecovery
\* ---------------------------------------------------------------------------
TraceSWSRetryRecovery ==
    /\ \E r \in Router, t \in Txn :
        /\ IsRouterTxnEvent("SWSRetryRecovery", r, t)
        /\ SWSRetryRecovery(r, t)
        /\ ValidatePostState(r, t)
        /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* TraceRouterRetry
\* ---------------------------------------------------------------------------
TraceRouterRetry ==
    /\ \E r \in Router, t \in Txn :
        /\ IsRouterTxnEvent("RouterRetry", r, t)
        /\ RouterRetry(r, t)
        /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* TraceCoordDecideCommit
\* ---------------------------------------------------------------------------
TraceCoordDecideCommit ==
    /\ \E t \in Txn :
        /\ IsTxnEvent("CoordDecideCommit", t)
        /\ CoordDecideCommit(t)
        /\ ValidateCoordState(t)
        /\ ValidateTickets
        /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* TraceCoordDecideAbort
\* ---------------------------------------------------------------------------
TraceCoordDecideAbort ==
    /\ \E t \in Txn :
        /\ IsTxnEvent("CoordDecideAbort", t)
        /\ CoordDecideAbort(t)
        /\ ValidateCoordState(t)
        /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* TraceCoordPersistAndSend
\* ---------------------------------------------------------------------------
TraceCoordPersistAndSend ==
    /\ \E t \in Txn :
        /\ IsTxnEvent("CoordPersistAndSend", t)
        /\ CoordPersistAndSend(t)
        /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* TraceCoordSendDecisionToShard
\* ---------------------------------------------------------------------------
TraceCoordSendDecisionToShard ==
    /\ \E t \in Txn, s \in Shard :
        /\ IsShardTxnEvent("CoordSendDecisionToShard", s, t)
        /\ CoordSendDecisionToShard(t, s)
        /\ ValidateShardState(s, t)
        /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* TraceCoordFinish
\* ---------------------------------------------------------------------------
TraceCoordFinish ==
    /\ \E t \in Txn :
        /\ IsTxnEvent("CoordFinish", t)
        /\ CoordFinish(t)
        /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* TraceRouterReceive2PCResult
\* ---------------------------------------------------------------------------
TraceRouterReceive2PCResult ==
    /\ \E r \in Router, t \in Txn :
        /\ IsRouterTxnEvent("RouterReceive2PCResult", r, t)
        /\ RouterReceive2PCResult(r, t)
        /\ ValidatePostState(r, t)
        /\ l' = l + 1

\* ---------------------------------------------------------------------------
\* TraceSessionReaperFire
\* ---------------------------------------------------------------------------
TraceSessionReaperFire ==
    /\ \E s \in Shard, t \in Txn :
        /\ IsShardTxnEvent("SessionReaperFire", s, t)
        /\ SessionReaperFire(s, t)
        /\ ValidateShardState(s, t)
        /\ l' = l + 1

\* ===========================================================================
\* Silent Actions
\* Tightly constrained: only fire when needed for the next trace event.
\* ===========================================================================

\* SilentBackgroundTaskRelease — Background task releases ticket between events
SilentBackgroundTaskRelease ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Shard :
        /\ bgWaiting[s]
        /\ BackgroundTaskRelease(s)
    /\ UNCHANGED l

\* ===========================================================================
\* Init and Next
\* ===========================================================================

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \/ TraceRouterStartTxn
    \/ TraceRouterCommitTxn
    \/ TraceDirectCommit
    \/ TraceSWSCommitReadOnly
    \/ TraceSWSCommitWrite
    \/ TraceSWSRetryRecovery
    \/ TraceRouterRetry
    \/ TraceCoordDecideCommit
    \/ TraceCoordDecideAbort
    \/ TraceCoordPersistAndSend
    \/ TraceCoordSendDecisionToShard
    \/ TraceCoordFinish
    \/ TraceRouterReceive2PCResult
    \/ TraceSessionReaperFire
    \/ SilentBackgroundTaskRelease

\* ===========================================================================
\* Trace Completion
\* ===========================================================================

\* TraceFinished — Invariant that triggers deadlock when trace is fully consumed.
\* A "deadlock" at l = Len(TraceLog) + 1 means successful trace validation.
TraceFinished == l <= Len(TraceLog)

\* TraceMatched — Temporal: eventually the entire trace is consumed.
TraceMatched == <>(l = Len(TraceLog) + 1)

====
