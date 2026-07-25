---- MODULE Trace ----
\* Trace validation spec for CometBFT
\* Replays recorded implementation traces against the base spec to verify consistency
\*
\* Category: A (Distributed/Message-Passing) - single global trace sequence

EXTENDS base, TLC, Naturals, Sequences, Json

\* ============================================================================
\* TRACE LOADING AND CURSOR
\* ============================================================================

\* Load trace from JSON file
JsonFile == "../traces/example_basic_consensus.ndjson"

\* Parse trace file (simplified: assume valid JSON array of events)
TraceLog == ndJsonDeserialize(JsonFile)

\* Sentinel value for "no event"
NULL == [eventName |-> "NULL"]

\* Global cursor walking through trace events
VARIABLE l  \* l \in 0..Len(TraceLog), current event index

traceVars == l

\* ============================================================================
\* EVENT MATCHING PREDICATES
\* ============================================================================

\* Check if we have more events to process
HasMoreEvents == l < Len(TraceLog)

\* Access current event
CurrentEvent == IF HasMoreEvents THEN TraceLog[l + 1] ELSE NULL

\* Check if current event matches a name
IsEvent(name) == CurrentEvent.eventName = name

\* Check if event is from a specific node
IsNodeEvent(name, node) ==
    /\ IsEvent(name)
    /\ CurrentEvent.nodeID = node

\* Check if event is a message between nodes
IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ CurrentEvent.sender = from
    /\ CurrentEvent.receiver = to

\* ============================================================================
\* STATE FIELD EXTRACTION FROM TRACE
\* ============================================================================

\* Extract current state from trace event
GetNodeHeight(event) == IF "height" \in DOMAIN event THEN event.height ELSE 1
GetNodeRound(event) == IF "round" \in DOMAIN event THEN event.round ELSE 0
GetNodeStep(event) == IF "step" \in DOMAIN event THEN event.step ELSE RoundStepNewHeight
GetProposedBlock(event) == IF "proposedBlock" \in DOMAIN event THEN event.proposedBlock ELSE NULL_BLOCK
GetLockedBlock(event) == IF "lockedBlock" \in DOMAIN event THEN event.lockedBlock ELSE NULL_BLOCK
GetLockedRound(event) == IF "lockedRound" \in DOMAIN event THEN event.lockedRound ELSE -1
GetValidBlock(event) == IF "validBlock" \in DOMAIN event THEN event.validBlock ELSE NULL_BLOCK
GetValidRound(event) == IF "validRound" \in DOMAIN event THEN event.validRound ELSE -1

\* Extract vote fields from event
GetVoteHeight(event) == IF "voteHeight" \in DOMAIN event THEN event.voteHeight ELSE 1
GetVoteRound(event) == IF "voteRound" \in DOMAIN event THEN event.voteRound ELSE 0
GetVoteType(event) == IF "voteType" \in DOMAIN event THEN event.voteType ELSE PrevoteType
GetVoteBlockID(event) == IF "voteBlockID" \in DOMAIN event THEN event.voteBlockID ELSE NULL_BLOCK
GetVoteExtension(event) == IF "extension" \in DOMAIN event THEN event.extension ELSE NULL_PROOF

\* ============================================================================
\* BOOTSTRAP STATE
\* ============================================================================

\* Initialize trace state to match implementation's bootstrap state
TraceInit ==
    /\ Init
    /\ l = 0

\* ============================================================================
\* POST-STATE VALIDATION
\* ============================================================================

\* Validate that spec state matches trace after each action
ValidatePostState(event, v) ==
    IF IsNodeEvent("EnterNewRound", v)
    THEN heightRound[v].height = GetNodeHeight(event) /\
         step[v] = RoundStepPropose
    ELSE IF IsNodeEvent("EnterPrevote", v)
    THEN step[v] = RoundStepPrevote /\
         proposedBlock[v] = GetProposedBlock(event)
    ELSE IF IsNodeEvent("EnterPrecommit", v)
    THEN step[v] = RoundStepPrecommit /\
         lockedBlock[v] = GetLockedBlock(event) /\
         lockedRound[v] = GetLockedRound(event)
    ELSE IF IsNodeEvent("AddVote", v)
    THEN LET vote == [height |-> GetVoteHeight(event),
                      round |-> GetVoteRound(event),
                      type |-> GetVoteType(event),
                      voter |-> v,
                      blockID |-> GetVoteBlockID(event),
                      extension |-> GetVoteExtension(event)]
         IN \E voteSet \in votes[vote.height][vote.round][vote.type] :
            vote \in voteSet
    ELSE IF IsNodeEvent("HandleCompleteProposal", v)
    THEN proposedBlock[v] = GetProposedBlock(event)
    ELSE IF IsNodeEvent("UnlockOnPol", v)
    THEN lockedBlock[v] = NULL_BLOCK /\
         lockedRound[v] = -1
    ELSE IF IsNodeEvent("UpdateValidBlock", v)
    THEN validBlock[v] = GetValidBlock(event) /\
         validRound[v] = GetValidRound(event)
    ELSE IF IsNodeEvent("CrashAndRecover", v)
    THEN recoveryMode[v] = "recovered"
    ELSE TRUE  \* Unknown event - no validation

\* ============================================================================
\* ACTION WRAPPERS FOR TRACE EVENTS
\* ============================================================================

\* Generic wrapper: match event, call action, validate, advance cursor
TraceAction(actionName, v, action(_)) ==
    /\ IsNodeEvent(actionName, v)
    /\ action(v)
    /\ ValidatePostState(CurrentEvent, v)
    /\ l' = l + 1

\* Specific trace actions matching instrumentation points
TraceEnterNewRound(v) ==
    /\ IsNodeEvent("EnterNewRound", v)
    /\ EnterNewRound(v)
    /\ ValidatePostState(CurrentEvent, v)
    /\ l' = l + 1

TraceEnterPrevote(v) ==
    /\ IsNodeEvent("EnterPrevote", v)
    /\ EnterPrevote(v)
    /\ ValidatePostState(CurrentEvent, v)
    /\ l' = l + 1

TraceEnterPrecommit(v) ==
    /\ IsNodeEvent("EnterPrecommit", v)
    /\ EnterPrecommit(v)
    /\ ValidatePostState(CurrentEvent, v)
    /\ l' = l + 1

TraceAddVote(v) ==
    /\ IsNodeEvent("AddVote", v)
    /\ LET vote == [height |-> GetVoteHeight(CurrentEvent),
                    round |-> GetVoteRound(CurrentEvent),
                    type |-> GetVoteType(CurrentEvent),
                    voter |-> v,
                    blockID |-> GetVoteBlockID(CurrentEvent),
                    extension |-> GetVoteExtension(CurrentEvent)]
       IN
       /\ AddVote(v, vote)
       /\ ValidatePostState(CurrentEvent, v)
    /\ l' = l + 1

TraceReceiveProposal(v) ==
    /\ IsNodeEvent("ReceiveProposal", v)
    /\ LET proposal == [height |-> GetNodeHeight(CurrentEvent),
                        round |-> GetNodeRound(CurrentEvent),
                        block |-> GetProposedBlock(CurrentEvent)]
       IN
       /\ ReceiveProposal(v, proposal)
       /\ ValidatePostState(CurrentEvent, v)
    /\ l' = l + 1

TraceReceiveBlockPart(v) ==
    /\ IsNodeEvent("ReceiveBlockPart", v)
    /\ ReceiveBlockPart(v, GetNodeHeight(CurrentEvent), GetNodeRound(CurrentEvent))
    /\ ValidatePostState(CurrentEvent, v)
    /\ l' = l + 1

TraceHandleCompleteProposal(v) ==
    /\ IsNodeEvent("HandleCompleteProposal", v)
    /\ HandleCompleteProposal(v)
    /\ ValidatePostState(CurrentEvent, v)
    /\ l' = l + 1

TraceUnlockOnPol(v) ==
    /\ IsNodeEvent("UnlockOnPol", v)
    /\ UnlockOnPol(v)
    /\ ValidatePostState(CurrentEvent, v)
    /\ l' = l + 1

TraceUpdateValidBlock(v) ==
    /\ IsNodeEvent("UpdateValidBlock", v)
    /\ UpdateValidBlock(v)
    /\ ValidatePostState(CurrentEvent, v)
    /\ l' = l + 1

TraceCrashAndRecover(v) ==
    /\ IsNodeEvent("CrashAndRecover", v)
    /\ CrashAndRecover(v)
    /\ ValidatePostState(CurrentEvent, v)
    /\ l' = l + 1

\* ============================================================================
\* SILENT ACTIONS (Implementation details not in trace)
\* ============================================================================

\* Silent actions fire without consuming trace events
\* Must be tightly constrained to avoid explosion

SilentTimeout(v) ==
    /\ HasMoreEvents
    /\ \* Only fire if next event is not a timeout-triggered transition
       ~IsNodeEvent("EnterNewRound", v) \/ ~IsNodeEvent("HandleTimeout", v)
    /\ HandleTimeout(v)
    /\ UNCHANGED l

\* ============================================================================
\* TRACE NEXT-STATE RELATION
\* ============================================================================

TraceNext ==
    \E v \in Validators :
        \/ TraceEnterNewRound(v)
        \/ TraceEnterPrevote(v)
        \/ TraceEnterPrecommit(v)
        \/ TraceAddVote(v)
        \/ TraceReceiveProposal(v)
        \/ TraceReceiveBlockPart(v)
        \/ TraceHandleCompleteProposal(v)
        \/ TraceUnlockOnPol(v)
        \/ TraceUpdateValidBlock(v)
        \/ TraceCrashAndRecover(v)
        \/ SilentTimeout(v)

\* ============================================================================
\* TRACE COMPLETION PROPERTY
\* ============================================================================

\* Temporal property: entire trace must be consumed
TraceMatched == <> (l > Len(TraceLog))

====
