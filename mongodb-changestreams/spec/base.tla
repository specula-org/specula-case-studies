--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for MongoDB Change Streams v2 Resume Token Ordering.
 *
 * Derived from: mongo/db/pipeline/resume_token.cpp, change_stream_event_transform.cpp,
 *               document_source_change_stream_check_invalidate.cpp,
 *               document_source_change_stream_handle_topology_change_v2.cpp
 *
 * Bug Families: 1 (Resume Token Ordering & Version Transition),
 *               2 (Invalidation Event Sequencing),
 *               3 (Cross-Shard Event Merging & Topology Change),
 *               5 (Transaction Unwinding & Event Atomicity)
 *
 * This spec models the implementation's actual control flow for resume token
 * generation, cross-shard merging, invalidation state machine, and transaction
 * unwinding. Deviations from the reference algorithm are where bugs live.
 *)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Shard              \* Set of shard identifiers
CONSTANT MaxClusterTime     \* Upper bound on cluster time per shard
CONSTANT MaxTxnOps          \* Max operations in a single transaction
CONSTANT Nil                \* Sentinel value for "none"

\* Token version constants (resume_token.h:55)
CONSTANTS V1, V2

\* Token type constants (resume_token.h:68-71)
\* HWM=0, Event=128 — HWM sorts before Event at same clusterTime
CONSTANTS HWMTokenType, EventTokenType

\* Stream operation types
CONSTANTS
    InsertOp,           \* insert
    UpdateOp,           \* update
    DeleteOp,           \* delete
    DropOp,             \* drop (triggers invalidation)
    RenameOp,           \* rename (triggers invalidation)
    InvalidateOp        \* synthetic invalidation event

\* Stream state constants
CONSTANTS Active, InvalidatedState, ClosedState

\* Topology mode constants (change_stream_shard_targeter.h:48-54)
CONSTANTS NormalMode, DegradedMode

\* Default token version for the server (resume_token.h:55, kDefaultTokenVersion=2)
CONSTANT DefaultTokenVersion

\* ============================================================================
\* TYPED SENTINELS (avoid mixed-type comparisons in TLC)
\* ============================================================================

\* Sentinel for "no token" — sorts before all valid tokens
NoToken == <<0, 0, 0, 0, 0, 0>>

\* Sentinel for "no timestamp" — valid timestamps start at 1
NoTime == 0

\* Sentinel for "no event"
NoEvent == [token |-> NoToken, opType |-> Nil, shard |-> Nil,
            clusterTime |-> 0, txnOpIndex |-> 0]

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Per-shard state ---
VARIABLE shardClock         \* [Shard -> Nat] current clusterTime per shard
VARIABLE shardEvents        \* [Shard -> Seq(Event)] events generated on each shard
VARIABLE shardTokenVersion  \* [Shard -> {V1, V2}] token version per shard (Family 1)
VARIABLE globalEventCounter  \* Nat: global monotonic counter for unique eventIds

shardVars == <<shardClock, shardEvents, shardTokenVersion, globalEventCounter>>

\* --- Mongos merge state (Family 3: cross-shard merge) ---
VARIABLE activeCursors      \* SUBSET Shard: shards with open cursors
VARIABLE cursorPos          \* [Shard -> Nat] read position per shard cursor
VARIABLE hwmToken           \* [Shard -> Token or Nil] high-water-mark per cursor
VARIABLE deliveredEvents    \* Seq(Event) events delivered to client in order

mergeVars == <<activeCursors, cursorPos, hwmToken, deliveredEvents>>

\* --- Stream / invalidation state (Family 2) ---
VARIABLE streamState            \* {Active, InvalidatedState, ClosedState}
VARIABLE startAfterInvalidate   \* Token or Nil: set when resuming after invalidation
VARIABLE pendingInvalidation    \* Event or Nil: invalidation waiting to be delivered
VARIABLE collectionAlive        \* BOOLEAN: whether the watched collection exists

invalidationVars == <<streamState, startAfterInvalidate, pendingInvalidation, collectionAlive>>

\* --- Topology state (Family 3: V2 segment lifecycle) ---
VARIABLE topoMode           \* {NormalMode, DegradedMode}
VARIABLE segmentEnd         \* Nat or Nil: clusterTime boundary for degraded segment
VARIABLE undoneEvent        \* Event or Nil: event rolled back at segment boundary

topoVars == <<topoMode, segmentEnd, undoneEvent>>

\* --- Transaction state (Family 5) ---
VARIABLE pendingTxn         \* [Shard -> Seq(Op)] operations in pending transaction
VARIABLE txnCommitted       \* [Shard -> BOOLEAN] whether txn is committed
VARIABLE txnClusterTime     \* [Shard -> Nat or Nil] commit timestamp of transaction

txnVars == <<pendingTxn, txnCommitted, txnClusterTime>>

\* --- Resume state (Family 1) ---
VARIABLE resumeToken        \* Token or Nil: token being resumed from
VARIABLE isResuming         \* BOOLEAN: whether we are in resume mode

resumeVars == <<resumeToken, isResuming>>

vars == <<shardVars, mergeVars, invalidationVars, topoVars, txnVars, resumeVars>>

\* ============================================================================
\* TOKEN DEFINITION AND COMPARISON
\* ============================================================================

(*
 * A Token is a record encoding the KeyString fields in comparison order.
 * resume_token.cpp:134-190 — Encoding order:
 *   clusterTime > version > tokenType > txnOpIndex > fromInvalidate
 *
 * We represent tokens as tuples for natural lexicographic comparison.
 * TokenType: HWMTokenType=0, EventTokenType=128 (resume_token.h:68-71)
 * fromInvalidate: 0=false, 1=true (false < true in KeyString)
 *)

\* Build a token tuple for lexicographic comparison
\* resume_token.cpp:137-190
\* Fields: clusterTime, version, tokenType, txnOpIndex, fromInvalidate, eventId
\* The eventId field models UUID+eventIdentifier uniqueness (resume_token.cpp:168-173)
MakeToken(clusterTime, version, tokenType, txnOpIndex, fromInvalidate, eventId) ==
    <<clusterTime, version, tokenType, txnOpIndex, fromInvalidate, eventId>>

\* Convenience: make an event token (most common case)
\* resume_token.cpp:149-173, change_stream_event_transform.cpp:264
MakeEventToken(clusterTime, version, txnOpIndex, eventId) ==
    MakeToken(clusterTime, version, EventTokenType, txnOpIndex, 0, eventId)

\* Make a high-water-mark token (resume_token.cpp:336-346)
\* HWM tokens have: tokenType=0, txnOpIndex=0, fromInvalidate=false, eventId=0
MakeHWMToken(clusterTime, version) ==
    MakeToken(clusterTime, version, HWMTokenType, 0, 0, 0)

\* Make an invalidation token (fromInvalidate=true)
\* resume_token.h:60-63, document_source_change_stream_check_invalidate.cpp
\* fromInvalidate=true makes this sort AFTER the triggering event at same clusterTime
MakeInvalidateToken(clusterTime, version, txnOpIndex, eventId) ==
    MakeToken(clusterTime, version, EventTokenType, txnOpIndex, 1, eventId)

\* Token comparison: TLC does not support < on tuples, so we implement
\* lexicographic comparison manually on the 5-element token tuple.
\* Fields are all integers, compared left to right.
RECURSIVE SeqLT(_, _, _)
SeqLT(s1, s2, i) ==
    IF i > Len(s1) THEN FALSE          \* equal
    ELSE IF s1[i] < s2[i] THEN TRUE    \* strictly less at position i
    ELSE IF s1[i] > s2[i] THEN FALSE   \* strictly greater at position i
    ELSE SeqLT(s1, s2, i + 1)          \* equal at position i, continue

TokenLT(t1, t2) == SeqLT(t1, t2, 1)
TokenLE(t1, t2) == t1 = t2 \/ SeqLT(t1, t2, 1)
TokenEQ(t1, t2) == t1 = t2

\* Token version numbers for encoding
VersionNum(v) == IF v = V1 THEN 1 ELSE IF v = V2 THEN 2 ELSE 0

\* Build token with symbolic version constants mapped to numbers
MakeEventTokenV(clusterTime, version, txnOpIndex, eventId) ==
    MakeEventToken(clusterTime, VersionNum(version), txnOpIndex, eventId)

MakeHWMTokenV(clusterTime, version) ==
    MakeHWMToken(clusterTime, VersionNum(version))

MakeInvalidateTokenV(clusterTime, version, txnOpIndex, eventId) ==
    MakeInvalidateToken(clusterTime, VersionNum(version), txnOpIndex, eventId)

\* ============================================================================
\* EVENT DEFINITION
\* ============================================================================

(*
 * An Event record represents a change stream event produced by a shard
 * and delivered to the client through mongos.
 *)

\* Event record constructor
MakeEvent(token, opType, shard, clusterTime, txnOpIndex) ==
    [token |-> token,
     opType |-> opType,
     shard |-> shard,
     clusterTime |-> clusterTime,
     txnOpIndex |-> txnOpIndex]

\* Check if an operation type triggers invalidation
\* document_source_change_stream_check_invalidate.cpp:99-102
\* change_stream_helpers.h:78-82
IsInvalidatingOp(opType) ==
    opType \in {DropOp, RenameOp}

\* ============================================================================
\* VERSION TRANSITION LOGIC (Family 1: MC-1)
\* ============================================================================

(*
 * change_stream_event_transform.cpp:259-261
 * Version transition uses || (OR): switch to default version when EITHER
 * clusterTime > resumeToken.clusterTime OR txnOpIndex > resumeToken.txnOpIndex.
 *
 * This is the potentially buggy logic identified in MC-1: the || may switch
 * versions prematurely within the same clusterTime when only txnOpIndex advances.
 *)

\* Determine token version for a new event given resume context
\* change_stream_event_transform.cpp:259-261
DetermineVersion(clusterTime, txnOpIndex, resumeTok, shardVersion) ==
    IF resumeTok = NoToken
    THEN VersionNum(shardVersion)
    ELSE
        \* resume_token.cpp:259: clusterTime > resume.clusterTime || txnOpIndex > resume.txnOpIndex
        IF clusterTime > resumeTok[1] \/ txnOpIndex > resumeTok[4]
        THEN VersionNum(DefaultTokenVersion)   \* Switch to server default
        ELSE resumeTok[2]                       \* Keep resume token's version

\* ============================================================================
\* HELPERS
\* ============================================================================

\* Minimum token across a set of candidates
MinToken(tokenSet) ==
    CHOOSE t \in tokenSet : \A t2 \in tokenSet : TokenLE(t, t2)

\* Check if a shard cursor has an event available
HasEventOnShard(s) ==
    cursorPos[s] <= Len(shardEvents[s])

\* Get the next event available on a shard cursor
\* PRECONDITION: HasEventOnShard(s) must be TRUE
NextEventOnShard(s) ==
    shardEvents[s][cursorPos[s]]

\* Get the effective token for a shard cursor (event token or HWM)
\* Shards without events still provide HWM tokens for merge ordering
\* resume_token.cpp:336-346
\* Always returns a valid token tuple (never Nil).
EffectiveToken(s) ==
    IF HasEventOnShard(s)
    THEN NextEventOnShard(s).token
    ELSE hwmToken[s]

\* Find the shard with the minimum effective token among active cursors
\* This implements the AsyncResultsMerger min-heap merge
\* document_source_change_stream_handle_topology_change_v2.cpp
\* Returns Nil (string) if activeCursors is empty.
MinTokenShard ==
    IF activeCursors = {} THEN Nil
    ELSE CHOOSE s \in activeCursors :
         \A s2 \in activeCursors : TokenLE(EffectiveToken(s), EffectiveToken(s2))

\* Check if all shards have advanced past a given token
AllShardsAdvancedPast(token) ==
    \A s \in activeCursors : TokenLT(token, EffectiveToken(s))

\* ============================================================================
\* INIT
\* ============================================================================

Init ==
    \* Per-shard state: all clocks start at 1, no events, V2 default
    /\ shardClock = [s \in Shard |-> 1]
    /\ shardEvents = [s \in Shard |-> <<>>]
    /\ shardTokenVersion = [s \in Shard |-> V2]
    /\ globalEventCounter = 1
    \* Mongos: all shards have cursors, starting at position 1
    /\ activeCursors = Shard
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

\* ============================================================================
\* ACTIONS: Per-Shard Event Generation
\* ============================================================================

(*
 * GenerateEvent: A shard produces a new event at its current clusterTime.
 * Models the oplog tailing + transform pipeline on each shard.
 *
 * change_stream_event_transform.cpp:321-744 (applyTransformation)
 * resume_token.cpp:137-190 (token encoding)
 *)
GenerateEvent(s, opType) ==
    /\ streamState = Active
    /\ collectionAlive = TRUE
    /\ shardClock[s] < MaxClusterTime  \* Strict < since we advance clock
    /\ ~IsInvalidatingOp(opType)    \* Invalidating ops handled separately
    /\ pendingTxn[s] = <<>>         \* No active transaction on this shard
    \* Each oplog entry gets a unique timestamp (MongoDB logical clock)
    /\ LET ct == shardClock[s] + 1  \* Consume next timestamp
           version == DetermineVersion(ct, 0, resumeToken, shardTokenVersion[s])
           eid == globalEventCounter
           token == MakeEventToken(ct, version, 0, eid)
           evt == MakeEvent(token, opType, s, ct, 0)
       IN /\ shardEvents' = [shardEvents EXCEPT ![s] = Append(@, evt)]
          /\ globalEventCounter' = globalEventCounter + 1
          /\ shardClock' = [shardClock EXCEPT ![s] = ct]
          \* Advance HWM
          /\ hwmToken' = [hwmToken EXCEPT ![s] =
                IF TokenLT(@, token) THEN MakeHWMTokenV(ct, shardTokenVersion[s])
                ELSE @]
    /\ UNCHANGED <<shardTokenVersion>>
    /\ UNCHANGED <<activeCursors, cursorPos, deliveredEvents>>
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED txnVars
    /\ UNCHANGED resumeVars

(*
 * AdvanceShardClock: A shard's cluster time advances.
 * Models the passage of time on individual shards (independent clocks).
 *)
AdvanceShardClock(s) ==
    /\ shardClock[s] < MaxClusterTime
    /\ shardClock' = [shardClock EXCEPT ![s] = @ + 1]
    \* Update HWM to reflect new clock time
    /\ LET newHWM == MakeHWMTokenV(shardClock[s] + 1, shardTokenVersion[s])
       IN hwmToken' = [hwmToken EXCEPT ![s] =
            IF TokenLT(@, newHWM) THEN newHWM ELSE @]
    /\ UNCHANGED <<shardEvents, shardTokenVersion, globalEventCounter>>
    /\ UNCHANGED <<activeCursors, cursorPos, deliveredEvents>>
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED txnVars
    /\ UNCHANGED resumeVars

(*
 * SwitchTokenVersion: A shard transitions from V1 to V2.
 * Models the v1->v2 version transition identified in Bug Family 1.
 *
 * change_stream_event_transform.cpp:259-261 — version transition
 * resume_token.h:55 — kDefaultTokenVersion = 2
 *)
SwitchTokenVersion(s) ==
    /\ shardTokenVersion[s] = V1
    /\ shardTokenVersion' = [shardTokenVersion EXCEPT ![s] = V2]
    /\ UNCHANGED <<shardClock, shardEvents, globalEventCounter>>
    /\ UNCHANGED <<hwmToken>>
    /\ UNCHANGED <<activeCursors, cursorPos, deliveredEvents>>
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED txnVars
    /\ UNCHANGED resumeVars

\* ============================================================================
\* ACTIONS: Invalidation State Machine (Family 2)
\* ============================================================================

(*
 * GenerateInvalidatingEvent: A shard produces a drop/rename event.
 * The event itself is a normal event; the CheckInvalidate stage on mongos
 * will generate the synthetic invalidation event afterward.
 *
 * document_source_change_stream_check_invalidate.cpp
 * change_stream_pipeline_helpers.cpp:191-195
 *)
GenerateInvalidatingEvent(s, opType) ==
    /\ streamState = Active
    /\ collectionAlive = TRUE
    /\ IsInvalidatingOp(opType)
    /\ shardClock[s] < MaxClusterTime
    /\ pendingTxn[s] = <<>>
    /\ LET ct == shardClock[s] + 1
           version == DetermineVersion(ct, 0, resumeToken, shardTokenVersion[s])
           eid == globalEventCounter
           token == MakeEventToken(ct, version, 0, eid)
           evt == MakeEvent(token, opType, s, ct, 0)
       IN /\ shardEvents' = [shardEvents EXCEPT ![s] = Append(@, evt)]
          /\ globalEventCounter' = globalEventCounter + 1
          /\ shardClock' = [shardClock EXCEPT ![s] = ct]
          /\ hwmToken' = [hwmToken EXCEPT ![s] =
                IF TokenLT(@, token) THEN MakeHWMTokenV(ct, shardTokenVersion[s])
                ELSE @]
    \* Collection is now dropped/renamed
    /\ collectionAlive' = FALSE
    /\ UNCHANGED <<shardTokenVersion>>
    /\ UNCHANGED <<activeCursors, cursorPos, deliveredEvents>>
    /\ UNCHANGED <<streamState, startAfterInvalidate, pendingInvalidation>>
    /\ UNCHANGED topoVars
    /\ UNCHANGED txnVars
    /\ UNCHANGED resumeVars

(*
 * CheckInvalidate: Mongos pipeline stage processes an invalidating event
 * and generates a synthetic invalidation event.
 *
 * document_source_change_stream_check_invalidate.cpp:57-66
 * SERVER-120644: 3-way classification — rethrow, generate, swallow
 *
 * Classification logic:
 *   - If startAfterInvalidate is set AND event token matches: RETHROW
 *   - If startAfterInvalidate is not set OR token differs: GENERATE
 *   - After rethrow consumed, clear flag (SERVER-58442 fix): prevents SWALLOW
 *)
CheckInvalidateGenerate(triggeringEvent) ==
    /\ streamState = Active
    /\ pendingInvalidation = NoEvent
    /\ IsInvalidatingOp(triggeringEvent.opType)
    \* Classification: GENERATE — no startAfterInvalidate or different token
    \* document_source_change_stream_check_invalidate.cpp:57-66
    /\ \/ startAfterInvalidate = NoToken
       \/ ~TokenEQ(startAfterInvalidate, triggeringEvent.token)
    \* Generate synthetic invalidation with fromInvalidate=true
    \* The invalidation token sorts AFTER the triggering event (resume_token.h:60-63)
    /\ LET invToken == MakeInvalidateToken(
                triggeringEvent.clusterTime,
                triggeringEvent.token[2],  \* same version
                triggeringEvent.txnOpIndex,
                triggeringEvent.token[6])  \* same eventId
           invEvent == MakeEvent(invToken, InvalidateOp, triggeringEvent.shard,
                                 triggeringEvent.clusterTime, triggeringEvent.txnOpIndex)
       IN pendingInvalidation' = invEvent
    \* Note: streamState, startAfterInvalidate, collectionAlive unchanged here.
    \* cursorPos, deliveredEvents, shardVars, etc. are managed by the calling action.
    /\ UNCHANGED <<streamState, startAfterInvalidate, collectionAlive>>

(*
 * CheckInvalidateRethrow: When resuming after invalidation (startAfter),
 * encountering the same invalidation event triggers a rethrow.
 *
 * document_source_change_stream_check_invalidate.cpp:57-66
 * change_stream_start_after_invalidate_info.h:48-66
 * SERVER-120644 fix: after rethrow, clear startAfterInvalidate
 *)
CheckInvalidateRethrow(triggeringEvent) ==
    /\ streamState = Active
    /\ pendingInvalidation = NoEvent
    /\ IsInvalidatingOp(triggeringEvent.opType)
    \* Classification: RETHROW — startAfterInvalidate matches
    /\ startAfterInvalidate /= NoToken
    /\ TokenEQ(startAfterInvalidate, triggeringEvent.token)
    \* Clear the flag (SERVER-58442 fix) so future invalidations are GENERATED
    /\ startAfterInvalidate' = NoToken
    \* Stream reopens past this point (rethrow allows continuation)
    \* cursorPos, deliveredEvents, shardVars, etc. managed by calling action.
    /\ UNCHANGED <<streamState, pendingInvalidation, collectionAlive>>

(*
 * DeliverInvalidation: Deliver the pending invalidation event to the client.
 * After delivery, the stream transitions to InvalidatedState.
 *
 * document_source_change_stream_check_invalidate.cpp
 * change_stream_invalidation_info.h:47-64
 *)
DeliverInvalidation ==
    /\ streamState = Active
    /\ pendingInvalidation /= NoEvent
    \* Deliver the invalidation event
    /\ deliveredEvents' = Append(deliveredEvents, pendingInvalidation)
    /\ streamState' = InvalidatedState
    /\ pendingInvalidation' = NoEvent
    /\ UNCHANGED <<startAfterInvalidate, collectionAlive>>
    /\ UNCHANGED shardVars
    /\ UNCHANGED <<activeCursors, cursorPos, hwmToken>>
    /\ UNCHANGED topoVars
    /\ UNCHANGED txnVars
    /\ UNCHANGED resumeVars

(*
 * RecreateCollection: The collection is re-created after being dropped.
 * This enables the drop-recreate-drop sequence for MC-2 testing.
 *)
RecreateCollection ==
    /\ collectionAlive = FALSE
    /\ streamState /= ClosedState
    /\ collectionAlive' = TRUE
    /\ UNCHANGED <<streamState, startAfterInvalidate, pendingInvalidation>>
    /\ UNCHANGED shardVars
    /\ UNCHANGED mergeVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED txnVars
    /\ UNCHANGED resumeVars

\* ============================================================================
\* ACTIONS: Cross-Shard Merge at Mongos (Family 3)
\* ============================================================================

(*
 * MergeNext: Mongos picks the event with minimum token from active cursors.
 * This models the AsyncResultsMerger with sort on {"_id._data": 1}.
 *
 * document_source_change_stream_handle_topology_change_v2.cpp
 * change_stream_constants.h:46 — kSortSpec = {"_id._data": 1}
 *
 * In Normal mode, events are passed through directly.
 * In Degraded mode, events at or past segmentEnd trigger undoGetNext.
 *)
MergeNextNormal ==
    /\ streamState = Active
    /\ pendingInvalidation = NoEvent
    /\ topoMode = NormalMode
    /\ activeCursors /= {}
    /\ LET s == MinTokenShard
       IN /\ HasEventOnShard(s)
          /\ LET evt == NextEventOnShard(s)
             IN \* If this is an invalidating op, route to CheckInvalidate instead
                /\ ~IsInvalidatingOp(evt.opType)
                \* Deliver the event to the client
                /\ deliveredEvents' = Append(deliveredEvents, evt)
                \* Advance cursor on this shard
                /\ cursorPos' = [cursorPos EXCEPT ![s] = @ + 1]
    /\ UNCHANGED <<activeCursors, hwmToken>>
    /\ UNCHANGED shardVars
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED txnVars
    /\ UNCHANGED resumeVars

(*
 * MergeNextDegraded: In degraded mode, events within segment are delivered.
 * Events at or past segmentEnd trigger the undo mechanism.
 *
 * document_source_change_stream_handle_topology_change_v2.cpp (test lines 2321-2366)
 * SERVER-110575: Event consumed past segment end but not rolled back
 *)
MergeNextDegraded ==
    /\ streamState = Active
    /\ pendingInvalidation = NoEvent
    /\ topoMode = DegradedMode
    /\ segmentEnd /= NoTime
    /\ activeCursors /= {}
    /\ LET s == MinTokenShard
       IN /\ HasEventOnShard(s)
          /\ LET evt == NextEventOnShard(s)
             IN /\ ~IsInvalidatingOp(evt.opType)
                \* Check if event is within segment bounds
                /\ evt.clusterTime < segmentEnd
                \* Deliver within-segment event
                /\ deliveredEvents' = Append(deliveredEvents, evt)
                /\ cursorPos' = [cursorPos EXCEPT ![s] = @ + 1]
    /\ UNCHANGED <<activeCursors, hwmToken>>
    /\ UNCHANGED shardVars
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED txnVars
    /\ UNCHANGED resumeVars

(*
 * MergeNextInvalidating: Mongos encounters an invalidating event during merge.
 * Routes to the CheckInvalidate stage before delivery.
 *
 * change_stream_pipeline_helpers.cpp:191-195 — CheckInvalidate before CheckResumability
 *)
MergeNextInvalidating ==
    /\ streamState = Active
    /\ pendingInvalidation = NoEvent
    /\ activeCursors /= {}
    /\ LET s == MinTokenShard
       IN /\ HasEventOnShard(s)
          /\ LET evt == NextEventOnShard(s)
             IN /\ IsInvalidatingOp(evt.opType)
                \* Deliver the triggering event first
                /\ deliveredEvents' = Append(deliveredEvents, evt)
                /\ cursorPos' = [cursorPos EXCEPT ![s] = @ + 1]
                \* Then trigger CheckInvalidate
                /\ \/ CheckInvalidateGenerate(evt)
                   \/ CheckInvalidateRethrow(evt)
    /\ UNCHANGED <<activeCursors, hwmToken>>
    /\ UNCHANGED shardVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED txnVars
    /\ UNCHANGED resumeVars

(*
 * UndoGetNextAtSegmentBoundary: In degraded mode, when the min-token event
 * is at or past segmentEnd, undo the consumed event and set HWM.
 *
 * document_source_change_stream_handle_topology_change_v2.cpp (test lines 2253-2257)
 * SERVER-110575 fix: undoGetNextAndSetHighWaterMark()
 *)
UndoGetNextAtSegmentBoundary ==
    /\ streamState = Active
    /\ topoMode = DegradedMode
    /\ segmentEnd /= NoTime
    /\ activeCursors /= {}
    /\ LET s == MinTokenShard
       IN /\ HasEventOnShard(s)
          /\ LET evt == NextEventOnShard(s)
             IN \* Event is at or past segment end — trigger undo
                /\ evt.clusterTime >= segmentEnd
                \* Roll back: store the event for replay in next segment
                /\ undoneEvent' = evt
                \* Set HWM to segment end (test line 2254)
                /\ hwmToken' = [hwmToken EXCEPT ![s] =
                      MakeHWMTokenV(segmentEnd, shardTokenVersion[s])]
    \* Transition to starting next segment
    /\ topoMode' = NormalMode
    /\ segmentEnd' = NoTime
    /\ UNCHANGED <<activeCursors, cursorPos, deliveredEvents>>
    /\ UNCHANGED shardVars
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED txnVars
    /\ UNCHANGED resumeVars

\* ============================================================================
\* ACTIONS: Topology Changes (Family 3)
\* ============================================================================

(*
 * AddShard: A new shard is added to the cluster.
 * Opens a cursor on the new shard starting from the current HWM.
 *
 * change_stream_topology_helpers.cpp:87-97 — createUpdatedCommandForNewShard
 * change_stream_reader_context.h:65-66 — openCursorsOnDataShards
 *
 * Precondition: atClusterTime > current control event clusterTime (reader_context.h:59)
 *)
AddShard(newShard) ==
    /\ streamState = Active
    /\ topoMode = NormalMode
    /\ newShard \notin activeCursors
    \* Open cursor on new shard starting AFTER all previously delivered events.
    \* change_stream_topology_helpers.cpp:87-97: uses startAfter with HWM token
    \* change_stream_reader_context.h:59: atClusterTime > current control event
    /\ LET \* Reference point: last delivered token, or resumeToken if resuming, else NoToken
           \* change_stream_topology_helpers.cpp:87-97: uses global HWM / resume token
           refToken == IF Len(deliveredEvents) > 0
                       THEN deliveredEvents[Len(deliveredEvents)].token
                       ELSE IF isResuming THEN resumeToken
                       ELSE NoToken
           \* change_stream_reader_context.h:59: atClusterTime > current control event
           \* The new shard's cursor starts at a time >= the reference clusterTime.
           refCT == refToken[1]
           \* Advance shard clock to at least the reference clusterTime
           effectiveClock == IF shardClock[newShard] < refCT
                             THEN refCT ELSE shardClock[newShard]
           newHWM == MakeHWMTokenV(effectiveClock, shardTokenVersion[newShard])
           \* Find first event on shard STRICTLY past the reference token
           startPos == IF \E p \in 1..Len(shardEvents[newShard]) :
                            TokenLT(refToken, shardEvents[newShard][p].token)
                       THEN CHOOSE p \in 1..Len(shardEvents[newShard]) :
                            /\ TokenLT(refToken, shardEvents[newShard][p].token)
                            /\ \A q \in 1..(p-1) :
                                TokenLE(shardEvents[newShard][q].token, refToken)
                       ELSE Len(shardEvents[newShard]) + 1
       IN /\ activeCursors' = activeCursors \cup {newShard}
          /\ cursorPos' = [cursorPos EXCEPT ![newShard] = startPos]
          /\ hwmToken' = [hwmToken EXCEPT ![newShard] = newHWM]
          \* Advance shard clock to match atClusterTime constraint
          /\ shardClock' = [shardClock EXCEPT ![newShard] = effectiveClock]
    /\ UNCHANGED <<deliveredEvents>>
    /\ UNCHANGED <<shardEvents, shardTokenVersion, globalEventCounter>>
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED txnVars
    /\ UNCHANGED resumeVars

(*
 * RemoveShard: A shard is removed from the cluster.
 * Enters degraded mode with segment boundary at the removal time.
 *
 * change_stream_shard_targeter.h:111-112 — startChangeStreamSegment
 * change_stream_reader_context.h:80 — closeCursorsOnDataShards
 *)
RemoveShard(s) ==
    /\ streamState = Active
    /\ topoMode = NormalMode
    /\ s \in activeCursors
    /\ Cardinality(activeCursors) > 1   \* Keep at least one shard
    \* Close cursor on removed shard
    /\ activeCursors' = activeCursors \ {s}
    \* Enter degraded mode with segment end at shard's current clock
    /\ topoMode' = DegradedMode
    /\ segmentEnd' = shardClock[s]
    /\ UNCHANGED <<cursorPos, hwmToken, deliveredEvents>>
    /\ UNCHANGED <<undoneEvent>>
    /\ UNCHANGED shardVars
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED txnVars
    /\ UNCHANGED resumeVars

(*
 * StartNewSegment: After completing a degraded segment, start a new one.
 * Transitions back to normal mode. Replays any undone event.
 *
 * document_source_change_stream_handle_topology_change_v2.cpp (test lines 2361-2366)
 * State: kFetchingStartingChangeStreamSegment → kFetchingNormalGettingChangeEvent
 *)
StartNewSegment ==
    /\ topoMode = NormalMode    \* UndoGetNext already reset to NormalMode
    /\ undoneEvent /= NoEvent       \* There's an undone event to replay
    \* Clear undone event (it will be naturally replayed from the shard cursor)
    /\ undoneEvent' = NoEvent
    /\ UNCHANGED <<topoMode, segmentEnd>>
    /\ UNCHANGED shardVars
    /\ UNCHANGED mergeVars
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED txnVars
    /\ UNCHANGED resumeVars

\* ============================================================================
\* ACTIONS: Transaction Unwinding (Family 5)
\* ============================================================================

(*
 * BeginTransaction: Start accumulating operations in a transaction on a shard.
 *
 * document_source_change_stream_unwind_transaction.cpp:83-129
 *)
BeginTransaction(s) ==
    /\ pendingTxn[s] = <<>>
    /\ ~txnCommitted[s]
    /\ streamState = Active
    /\ collectionAlive = TRUE
    /\ pendingTxn' = [pendingTxn EXCEPT ![s] = <<>>]
    /\ txnClusterTime' = [txnClusterTime EXCEPT ![s] = shardClock[s]]
    /\ UNCHANGED <<txnCommitted>>
    /\ UNCHANGED shardVars
    /\ UNCHANGED mergeVars
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED resumeVars

(*
 * AddTxnOperation: Add an operation to a pending transaction.
 *
 * document_source_change_stream_unwind_transaction.cpp:83-129
 * Operations inside applyOps are filtered by namespace + operation type
 *)
AddTxnOperation(s, opType) ==
    /\ txnClusterTime[s] /= NoTime
    /\ ~txnCommitted[s]
    /\ Len(pendingTxn[s]) < MaxTxnOps
    /\ ~IsInvalidatingOp(opType)
    /\ pendingTxn' = [pendingTxn EXCEPT ![s] = Append(@, opType)]
    /\ UNCHANGED <<txnCommitted, txnClusterTime>>
    /\ UNCHANGED shardVars
    /\ UNCHANGED mergeVars
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED resumeVars

(*
 * CommitTransaction: Commit the transaction, making all operations visible.
 * Each operation becomes an event with incrementing txnOpIndex.
 *
 * change_stream_event_transform.cpp:652 — kTxnOpIndexField
 * resume_token.cpp:144 — txnOpIndex encoded in KeyString
 *
 * The commit timestamp determines the clusterTime for ALL operations
 * in the transaction. txnOpIndex provides ordering within the transaction.
 *)
CommitTransaction(s) ==
    /\ txnClusterTime[s] /= NoTime
    /\ ~txnCommitted[s]
    /\ Len(pendingTxn[s]) > 0
    /\ streamState = Active
    /\ shardClock[s] < MaxClusterTime
    \* Generate events for all operations with incrementing txnOpIndex
    \* change_stream_event_transform.cpp:253, resume_token.cpp:144
    \* Commit timestamp is the CURRENT oplog time (advances clock).
    /\ LET ct == shardClock[s] + 1
           ops == pendingTxn[s]
           baseEid == globalEventCounter
           \* Build events for each operation in the transaction
           events == [i \in 1..Len(ops) |->
               LET txnOpIdx == i - 1   \* 0-based (line 253: missing → 0)
                   eid == baseEid + (i - 1)
                   version == DetermineVersion(ct, txnOpIdx, resumeToken, shardTokenVersion[s])
                   token == MakeEventToken(ct, version, txnOpIdx, eid)
               IN MakeEvent(token, ops[i], s, ct, txnOpIdx)]
       IN /\ shardEvents' = [shardEvents EXCEPT ![s] = @ \o
                [i \in 1..Len(ops) |-> events[i]]]
          /\ globalEventCounter' = globalEventCounter + Len(ops)
          \* Update HWM past the last transaction event
          /\ hwmToken' = [hwmToken EXCEPT ![s] =
                LET lastToken == events[Len(ops)].token
                IN IF TokenLT(@, lastToken)
                   THEN MakeHWMTokenV(ct, shardTokenVersion[s])
                   ELSE @]
          /\ shardClock' = [shardClock EXCEPT ![s] = ct]
    /\ txnCommitted' = [txnCommitted EXCEPT ![s] = TRUE]
    /\ pendingTxn' = [pendingTxn EXCEPT ![s] = <<>>]
    /\ txnClusterTime' = [txnClusterTime EXCEPT ![s] = NoTime]
    /\ UNCHANGED <<shardTokenVersion>>
    /\ UNCHANGED <<activeCursors, cursorPos, deliveredEvents>>
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED resumeVars

(*
 * ResetTxnState: Reset transaction state after commit for reuse.
 *)
ResetTxnState(s) ==
    /\ txnCommitted[s] = TRUE
    /\ txnCommitted' = [txnCommitted EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<pendingTxn, txnClusterTime>>
    /\ UNCHANGED shardVars
    /\ UNCHANGED mergeVars
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED resumeVars

\* ============================================================================
\* ACTIONS: Resume From Token (Family 1, 2)
\* ============================================================================

(*
 * InitiateResume: Client resumes a change stream from a previously received token.
 * Each shard must replay from the correct position.
 *
 * document_source_change_stream_check_resumability.h:58-78
 * document_source_change_stream_ensure_resume_token_present.cpp:53-62
 *
 * Two-tier verification:
 *   1. Per-shard: oplog has sufficient history, consume pre-resume events
 *   2. Mongos: exact resume token exists in merged stream
 *)
InitiateResume ==
    /\ ~isResuming
    /\ Len(deliveredEvents) > 0    \* Must have received at least one event
    \* Resume from the last delivered event's token
    /\ LET lastEvt == deliveredEvents[Len(deliveredEvents)]
       IN resumeToken' = lastEvt.token
    /\ isResuming' = TRUE
    \* Reset cursor positions: each shard replays from the token position
    \* Per-shard CheckResumability (check_resumability.h:58-78)
    /\ cursorPos' = [s \in Shard |->
           \* Find the first event on this shard that is past the resume token
           LET pos == CHOOSE p \in 1..(Len(shardEvents[s]) + 1) :
               /\ \A j \in 1..(p-1) :
                   TokenLE(shardEvents[s][j].token, resumeToken')
               /\ (p > Len(shardEvents[s]) \/
                   TokenLT(resumeToken', shardEvents[s][p].token))
           IN pos]
    \* Reset delivered events (new stream from resume point)
    /\ deliveredEvents' = <<>>
    /\ UNCHANGED <<activeCursors, hwmToken>>
    /\ UNCHANGED shardVars
    /\ UNCHANGED invalidationVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED txnVars

(*
 * InitiateResumeAfterInvalidate: Client resumes after an invalidation
 * using startAfter with the invalidation token.
 *
 * document_source_change_stream_check_invalidate.cpp:57-66
 * document_source_change_stream.cpp:448-451 — rejects resumeAfter with invalidation token
 *)
InitiateResumeAfterInvalidate ==
    /\ streamState = InvalidatedState
    /\ Len(deliveredEvents) > 0
    /\ LET lastEvt == deliveredEvents[Len(deliveredEvents)]
       IN /\ lastEvt.opType = InvalidateOp
          \* fromInvalidate must be true in the token (position 5 in tuple)
          /\ lastEvt.token[5] = 1
          /\ resumeToken' = lastEvt.token
          /\ startAfterInvalidate' = lastEvt.token
    /\ isResuming' = TRUE
    /\ streamState' = Active
    \* Reset cursor positions for replay
    /\ cursorPos' = [s \in Shard |->
           LET pos == CHOOSE p \in 1..(Len(shardEvents[s]) + 1) :
               /\ \A j \in 1..(p-1) :
                   TokenLE(shardEvents[s][j].token, resumeToken')
               /\ (p > Len(shardEvents[s]) \/
                   TokenLT(resumeToken', shardEvents[s][p].token))
           IN pos]
    /\ deliveredEvents' = <<>>
    /\ UNCHANGED <<pendingInvalidation, collectionAlive>>
    /\ UNCHANGED <<activeCursors, hwmToken>>
    /\ UNCHANGED shardVars
    /\ UNCHANGED topoVars
    /\ UNCHANGED txnVars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

(*
 * ---- Standard Safety Invariants ----
 *)

\* TotalOrder: Events delivered to client are in token order.
\* For any two consecutive events, the first's token must be < the second's.
\* Targets: Family 1 (token ordering), Family 3 (cross-shard merge)
TotalOrder ==
    \A i \in 1..(Len(deliveredEvents) - 1) :
        TokenLT(deliveredEvents[i].token, deliveredEvents[i+1].token)

(*
 * ---- Extension Invariants (Bug Family targeting) ----
 *)

\* HWMMonotonicity: A shard's HWM token never decreases.
\* Targets: Family 1 (resume_token.cpp:336-346)
\* Not directly checkable as a state invariant without history,
\* but we enforce it through action design.

\* InvalidationCompleteness: An invalidation event is delivered only after
\* all prior events on all shards have been delivered.
\* Targets: Family 2, 3
\* Encoded as: if deliveredEvents contains an invalidation event at position i,
\* then no event at position j > i (except another invalidation) should have
\* a token < the triggering event's token.
InvalidationCompleteness ==
    \A i \in 1..Len(deliveredEvents) :
        (deliveredEvents[i].opType = InvalidateOp) =>
            \* All events before the invalidation have smaller tokens
            (\A j \in 1..(i-1) :
                TokenLT(deliveredEvents[j].token, deliveredEvents[i].token))

\* InvalidationIdempotency: After resuming from an invalidation token,
\* at most one new invalidation event is generated (not duplicates).
\* Targets: Family 2 (SERVER-58442, SERVER-120644)
InvalidationIdempotency ==
    LET invCount == Cardinality({i \in 1..Len(deliveredEvents) :
                                  deliveredEvents[i].opType = InvalidateOp})
    IN invCount <= 1

\* NoEventLossAtSegmentBoundary: When in degraded mode, events at the
\* segment boundary are preserved (either delivered or undone, never lost).
\* Targets: Family 3 (SERVER-110575)
NoEventLossAtSegmentBoundary ==
    \* If we transition out of degraded mode, any boundary event is in undoneEvent
    (topoMode = NormalMode /\ undoneEvent /= NoEvent) =>
        \* The undone event exists in some shard's event log
        \E s \in Shard : \E i \in 1..Len(shardEvents[s]) :
            shardEvents[s][i] = undoneEvent

\* TxnOrderPreservation: Events from the same transaction are delivered
\* in txnOpIndex order. Transaction events have txnOpIndex > 0 for the
\* second and subsequent operations (first has txnOpIndex=0).
\* We identify same-transaction by: same clusterTime, same shard,
\* AND at least one has txnOpIndex > 0 (indicates a multi-op transaction).
\* Targets: Family 5 (SERVER-34314)
TxnOrderPreservation ==
    \A i \in 1..Len(deliveredEvents) :
        \A j \in (i+1)..Len(deliveredEvents) :
            (deliveredEvents[i].clusterTime = deliveredEvents[j].clusterTime
             /\ deliveredEvents[i].shard = deliveredEvents[j].shard
             /\ (deliveredEvents[i].txnOpIndex > 0 \/ deliveredEvents[j].txnOpIndex > 0)) =>
                deliveredEvents[i].txnOpIndex < deliveredEvents[j].txnOpIndex

\* NoGapOnResume: After resuming from token T, the first delivered event
\* must be the event immediately after T (no skipped events).
\* Targets: Family 1, 3 (SERVER-47810, SERVER-67677)
NoGapOnResume ==
    (isResuming /\ Len(deliveredEvents) > 0) =>
        \* First event after resume must have token > resumeToken
        TokenLT(resumeToken, deliveredEvents[1].token)

(*
 * ---- Structural Invariants (sanity checks) ----
 *)

\* CursorPositionsValid: Cursor positions are within bounds
CursorPositionsValid ==
    \A s \in activeCursors :
        cursorPos[s] >= 1 /\ cursorPos[s] <= Len(shardEvents[s]) + 1

\* ActiveCursorsSubset: Active cursors are a subset of all shards
ActiveCursorsSubset ==
    activeCursors \subseteq Shard

\* StreamStateConsistency: Stream state is consistent with other variables
StreamStateConsistency ==
    /\ (streamState = InvalidatedState) => (pendingInvalidation = NoEvent)
    /\ (pendingInvalidation /= NoEvent) => (streamState = Active)

\* TokenVersionsValid: Token versions are V1 or V2
TokenVersionsValid ==
    \A s \in Shard : shardTokenVersion[s] \in {V1, V2}

\* DeliveredEventsHaveTokens: All delivered events have well-formed tokens
DeliveredEventsHaveTokens ==
    \A i \in 1..Len(deliveredEvents) :
        Len(deliveredEvents[i].token) = 6

\* ============================================================================
\* NEXT STATE
\* ============================================================================

Next ==
    \* Per-shard event generation
    \/ \E s \in Shard : \E op \in {InsertOp, UpdateOp, DeleteOp} :
        GenerateEvent(s, op)
    \/ \E s \in Shard : AdvanceShardClock(s)
    \/ \E s \in Shard : SwitchTokenVersion(s)
    \* Invalidation (Family 2)
    \/ \E s \in Shard : \E op \in {DropOp, RenameOp} :
        GenerateInvalidatingEvent(s, op)
    \/ DeliverInvalidation
    \/ RecreateCollection
    \* Cross-shard merge (Family 3)
    \/ MergeNextNormal
    \/ MergeNextDegraded
    \/ MergeNextInvalidating
    \/ UndoGetNextAtSegmentBoundary
    \* Topology changes (Family 3)
    \/ \E s \in Shard : AddShard(s)
    \/ \E s \in Shard : RemoveShard(s)
    \/ StartNewSegment
    \* Transactions (Family 5)
    \/ \E s \in Shard : BeginTransaction(s)
    \/ \E s \in Shard : \E op \in {InsertOp, UpdateOp, DeleteOp} :
        AddTxnOperation(s, op)
    \/ \E s \in Shard : CommitTransaction(s)
    \/ \E s \in Shard : ResetTxnState(s)
    \* Resume (Family 1, 2)
    \/ InitiateResume
    \/ InitiateResumeAfterInvalidate

\* Fairness: weak fairness on merge to ensure progress
Fairness ==
    /\ WF_vars(MergeNextNormal)
    /\ WF_vars(MergeNextDegraded)
    /\ WF_vars(DeliverInvalidation)

Spec == Init /\ [][Next]_vars

FairSpec == Spec /\ Fairness

\* ============================================================================
\* LIVENESS PROPERTIES
\* ============================================================================

\* CrossShardMergeProgress: If all shards have events, mongos eventually delivers.
\* Targets: Family 3
CrossShardMergeProgress ==
    (streamState = Active /\ activeCursors /= {} /\ HasEventOnShard(MinTokenShard))
        ~> (Len(deliveredEvents) > Len(deliveredEvents))

\* InvalidationDelivery: If a collection is dropped, the invalidation is eventually delivered.
\* Targets: Family 2
InvalidationDelivery ==
    (pendingInvalidation /= NoEvent) ~> (streamState = InvalidatedState)

====
