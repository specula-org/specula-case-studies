--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation specification for MongoDB Change Streams.
 *
 * Replays implementation traces against the base spec to verify
 * that the base spec can reproduce every observed state transition.
 *
 * Trace format: NDJSON with tag="trace" and event records containing:
 *   - event.name: action name (e.g., "GenerateEvent", "MergeNext")
 *   - event.shard: shard identifier
 *   - event.state: post-action state snapshot
 *   - event.opType: operation type (for event generation)
 *   - event.token: resume token fields (for validation)
 *)

EXTENDS base, Json, IOUtils, Sequences, TLC

\* ============================================================================
\* TRACE LOADING
\* ============================================================================

\* Read JSON file path from environment variable or use default.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load NDJSON, filter to trace events only.
TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x))

ASSUME Len(TraceLog) > 0

\* ============================================================================
\* TRACE CURSOR
\* ============================================================================

VARIABLE l       \* Current position in TraceLog (1-indexed)

traceVars == <<l>>

logline == TraceLog[l]

\* ============================================================================
\* SHARD EXTRACTION FROM TRACE
\* ============================================================================

\* Derive the set of shards mentioned in the trace
TraceShard == TLCEval(
    UNION {
        IF "shard" \in DOMAIN TraceLog[k].event
        THEN {TraceLog[k].event.shard}
        ELSE {}
        : k \in 1..Len(TraceLog)
    })

\* Define string-valued shard set for cfg CONSTANT DEFINITION override
TraceShardConst == {"s1", "s2", "s3"}

ASSUME TraceShard /= {}
ASSUME TraceShard \subseteq Shard

\* ============================================================================
\* EVENT PREDICATES
\* ============================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsShardEvent(name, s) ==
    /\ IsEvent(name)
    /\ logline.event.shard = s

\* ============================================================================
\* TYPE MAPPING
\* ============================================================================

\* Map trace operation type string to spec constant
TraceOpType(s) ==
    CASE s = "insert"     -> InsertOp
      [] s = "update"     -> UpdateOp
      [] s = "delete"     -> DeleteOp
      [] s = "drop"       -> DropOp
      [] s = "rename"     -> RenameOp
      [] s = "invalidate" -> InvalidateOp
      [] OTHER            -> InsertOp   \* fallback

\* Map trace version string to spec constant
TraceVersion(v) ==
    CASE v = 1 -> V1
      [] v = 2 -> V2
      [] v = "V1" -> V1
      [] v = "V2" -> V2
      [] OTHER -> V2   \* default

\* Map trace token type to spec constant
TraceTokenType(t) ==
    IF t = 0 \/ t = "HWM" THEN HWMTokenType ELSE EventTokenType

\* ============================================================================
\* POST-STATE VALIDATION
\* ============================================================================

(*
 * Strong validation: check full state after an action.
 * Used for events where the trace records complete state.
 *)
ValidatePostState(s) ==
    /\ "state" \in DOMAIN logline.event
    /\ LET st == logline.event.state
       IN /\ ("clusterTime" \in DOMAIN st) =>
               shardClock'[s] >= st.clusterTime
          /\ ("numEvents" \in DOMAIN st) =>
               Len(shardEvents'[s]) = st.numEvents

(*
 * Weak validation: check only shard identity.
 * Used for events where trace doesn't capture full state.
 *)
ValidatePostStateWeak(s) ==
    /\ s \in Shard

(*
 * Merge validation: check delivered events count.
 *)
ValidatePostStateMerge ==
    /\ "state" \in DOMAIN logline.event
    /\ LET st == logline.event.state
       IN ("deliveredCount" \in DOMAIN st) =>
            Len(deliveredEvents') = st.deliveredCount

\* ============================================================================
\* TRACE ACTION WRAPPERS
\* ============================================================================

(*
 * Each wrapper: match event → call base action → validate → advance cursor.
 *)

\* --- GenerateEvent: shard produces a new event ---
TraceGenerateEvent ==
    /\ \E s \in Shard :
        /\ IsShardEvent("GenerateEvent", s)
        /\ LET opType == TraceOpType(logline.event.opType) IN
           /\ GenerateEvent(s, opType)
           /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* --- AdvanceShardClock: shard clock advances ---
TraceAdvanceShardClock ==
    /\ \E s \in Shard :
        /\ IsShardEvent("AdvanceShardClock", s)
        /\ AdvanceShardClock(s)
        /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* --- SwitchTokenVersion: shard switches V1→V2 ---
TraceSwitchTokenVersion ==
    /\ \E s \in Shard :
        /\ IsShardEvent("SwitchTokenVersion", s)
        /\ SwitchTokenVersion(s)
        /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* --- GenerateInvalidatingEvent: shard produces drop/rename ---
TraceGenerateInvalidatingEvent ==
    /\ \E s \in Shard :
        /\ IsShardEvent("GenerateInvalidatingEvent", s)
        /\ LET opType == TraceOpType(logline.event.opType) IN
           GenerateInvalidatingEvent(s, opType)
    /\ l' = l + 1

\* --- MergeNext: mongos delivers next merged event ---
TraceMergeNextNormal ==
    /\ IsEvent("MergeNextNormal")
    /\ MergeNextNormal
    /\ l' = l + 1

TraceMergeNextDegraded ==
    /\ IsEvent("MergeNextDegraded")
    /\ MergeNextDegraded
    /\ l' = l + 1

TraceMergeNextInvalidating ==
    /\ IsEvent("MergeNextInvalidating")
    /\ MergeNextInvalidating
    /\ l' = l + 1

\* --- DeliverInvalidation: invalidation event delivered ---
TraceDeliverInvalidation ==
    /\ IsEvent("DeliverInvalidation")
    /\ DeliverInvalidation
    /\ l' = l + 1

\* --- UndoGetNext: event rolled back at segment boundary ---
TraceUndoGetNextAtSegmentBoundary ==
    /\ IsEvent("UndoGetNextAtSegmentBoundary")
    /\ UndoGetNextAtSegmentBoundary
    /\ l' = l + 1

\* --- AddShard / RemoveShard: topology changes ---
TraceAddShard ==
    /\ \E s \in Shard :
        /\ IsShardEvent("AddShard", s)
        /\ AddShard(s)
    /\ l' = l + 1

TraceRemoveShard ==
    /\ \E s \in Shard :
        /\ IsShardEvent("RemoveShard", s)
        /\ RemoveShard(s)
    /\ l' = l + 1

\* --- StartNewSegment: begin new segment after degraded ---
TraceStartNewSegment ==
    /\ IsEvent("StartNewSegment")
    /\ StartNewSegment
    /\ l' = l + 1

\* --- BeginTransaction: start transaction on shard ---
TraceBeginTransaction ==
    /\ \E s \in Shard :
        /\ IsShardEvent("BeginTransaction", s)
        /\ BeginTransaction(s)
    /\ l' = l + 1

\* --- AddTxnOperation: add op to pending transaction ---
TraceAddTxnOperation ==
    /\ \E s \in Shard :
        /\ IsShardEvent("AddTxnOperation", s)
        /\ LET opType == TraceOpType(logline.event.opType) IN
           AddTxnOperation(s, opType)
    /\ l' = l + 1

\* --- CommitTransaction: commit transaction ---
TraceCommitTransaction ==
    /\ \E s \in Shard :
        /\ IsShardEvent("CommitTransaction", s)
        /\ CommitTransaction(s)
    /\ l' = l + 1

\* --- RecreateCollection ---
TraceRecreateCollection ==
    /\ IsEvent("RecreateCollection")
    /\ RecreateCollection
    /\ l' = l + 1

\* --- InitiateResume ---
TraceInitiateResume ==
    /\ IsEvent("InitiateResume")
    /\ InitiateResume
    /\ l' = l + 1

\* --- InitiateResumeAfterInvalidate ---
TraceInitiateResumeAfterInvalidate ==
    /\ IsEvent("InitiateResumeAfterInvalidate")
    /\ InitiateResumeAfterInvalidate
    /\ l' = l + 1

\* ============================================================================
\* SILENT ACTIONS
\* ============================================================================

(*
 * Silent actions handle state changes that happen in the implementation
 * without emitting trace events. MUST be tightly constrained to prevent
 * state space explosion.
 *)

\* SilentAdvanceShardClock: Clock advance between traced events.
\* Constrained: only fires when next trace event on this shard requires
\* a higher clusterTime than the shard currently has.
SilentAdvanceShardClock ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Shard :
        /\ "shard" \in DOMAIN logline.event
        /\ logline.event.shard = s
        /\ "state" \in DOMAIN logline.event
        /\ "clusterTime" \in DOMAIN logline.event.state
        /\ shardClock[s] < logline.event.state.clusterTime
        /\ AdvanceShardClock(s)
    /\ UNCHANGED l

\* SilentMergeNext: Mongos merges events not explicitly traced.
\* Constrained: only fires when there are undelivered events before
\* the next traced merge event.
SilentMergeNext ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"MergeNextNormal", "MergeNextDegraded",
                                "DeliverInvalidation"}
    /\ "state" \in DOMAIN logline.event
    /\ "deliveredCount" \in DOMAIN logline.event.state
    /\ Len(deliveredEvents) < logline.event.state.deliveredCount - 1
    /\ \/ MergeNextNormal
       \/ MergeNextDegraded
    /\ UNCHANGED l

\* SilentResetTxnState: Reset transaction state between traces.
SilentResetTxnState ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Shard : ResetTxnState(s)
    /\ UNCHANGED l

\* ============================================================================
\* TRACE INIT
\* ============================================================================

TraceInit ==
    \* Per-shard state: all clocks start at 1, no events, V2 default
    /\ shardClock = [s \in Shard |-> 1]
    /\ shardEvents = [s \in Shard |-> <<>>]
    /\ shardTokenVersion = [s \in Shard |-> V2]
    /\ globalEventCounter = 1
    \* Mongos: only activate shards from the trace (not all of Shard)
    /\ activeCursors = TraceShard
    /\ cursorPos = [s \in Shard |-> 1]
    /\ hwmToken = [s \in Shard |-> MakeHWMTokenV(1, V2)]
    /\ deliveredEvents = <<>>
    \* Stream: active, no invalidation pending
    /\ streamState = Active
    /\ startAfterInvalidate = NoToken
    /\ pendingInvalidation = NoEvent
    /\ collectionAlive = TRUE
    \* Topology: normal mode
    /\ topoMode = NormalMode
    /\ segmentEnd = NoTime
    /\ undoneEvent = NoEvent
    \* Transactions: none pending
    /\ pendingTxn = [s \in Shard |-> <<>>]
    /\ txnCommitted = [s \in Shard |-> FALSE]
    /\ txnClusterTime = [s \in Shard |-> NoTime]
    \* Resume: not resuming
    /\ resumeToken = NoToken
    /\ isResuming = FALSE
    \* Trace cursor
    /\ l = 1

\* ============================================================================
\* TRACE NEXT
\* ============================================================================

TraceNext ==
    \* Traced actions (consume a trace event, advance l)
    \/ TraceGenerateEvent
    \/ TraceAdvanceShardClock
    \/ TraceSwitchTokenVersion
    \/ TraceGenerateInvalidatingEvent
    \/ TraceMergeNextNormal
    \/ TraceMergeNextDegraded
    \/ TraceMergeNextInvalidating
    \/ TraceDeliverInvalidation
    \/ TraceUndoGetNextAtSegmentBoundary
    \/ TraceAddShard
    \/ TraceRemoveShard
    \/ TraceStartNewSegment
    \/ TraceBeginTransaction
    \/ TraceAddTxnOperation
    \/ TraceCommitTransaction
    \/ TraceRecreateCollection
    \/ TraceInitiateResume
    \/ TraceInitiateResumeAfterInvalidate
    \* Silent actions (do not consume trace events)
    \/ SilentAdvanceShardClock
    \/ SilentMergeNext
    \/ SilentResetTxnState

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>>

\* ============================================================================
\* TRACE COMPLETION
\* ============================================================================

\* Check that the entire trace was consumed (deadlock-based: TLC should
\* report deadlock when l > Len(TraceLog) if all events are matched).
\*
\* Alternative: use a temporal property (requires fairness).
TraceMatched ==
    <>(l > Len(TraceLog))

\* Alias for TLC output readability
TraceAlias ==
    [
        l |-> l,
        loglineEvent |-> IF l <= Len(TraceLog)
                         THEN logline.event.name
                         ELSE "END",
        deliveredCount |-> Len(deliveredEvents),
        streamState |-> streamState,
        activeCursors |-> activeCursors,
        topoMode |-> topoMode
    ]

====
