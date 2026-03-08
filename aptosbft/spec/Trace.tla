--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation specification for Aptos BFT (2-chain HotStuff / Jolteon).
 *
 * Replays implementation traces against the base spec to verify
 * that the base spec can reproduce every observed state transition.
 *
 * Trace format: NDJSON with tag="trace" and event records containing:
 *   - event.name: action name (e.g., "CastVote", "CastOrderVote", ...)
 *   - event.nid: server ID
 *   - event.epoch: current epoch
 *   - event.round: current round
 *   - event.state: post-action state snapshot
 *     - state.lastVotedRound
 *     - state.preferredRound
 *     - state.oneChainRound
 *     - state.highestTimeoutRound
 *     - state.highestQCRound
 *     - state.highestOrderedRound
 *     - state.committedRound
 *   - event.msg: message fields (for message events)
 *     - msg.source, msg.round, msg.epoch, msg.value
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
\* SERVER EXTRACTION FROM TRACE
\* ============================================================================

TraceServer == TLCEval(
    UNION {
        {TraceLog[k].event.nid}
        \cup (IF "msg" \in DOMAIN TraceLog[k].event
              THEN {TraceLog[k].event.msg.source} \ {""}
              ELSE {})
        : k \in 1..Len(TraceLog)
    })

ASSUME TraceServer /= {}
ASSUME TraceServer \subseteq Server

\* Map trace value to spec value (Nil for empty/null)
TraceValue(v) ==
    IF v = "" \/ v = "null" \/ v = "nil" THEN Nil ELSE v

\* ============================================================================
\* EVENT PREDICATES
\* ============================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.event.nid = i

IsMsgEvent(name, from) ==
    /\ IsEvent(name)
    /\ "msg" \in DOMAIN logline.event
    /\ logline.event.msg.source = from

\* ============================================================================
\* POST-STATE VALIDATION
\* ============================================================================

\* Strong validation: check all safety-critical state
ValidatePostState(i) ==
    /\ lastVotedRound'[i] = logline.event.state.lastVotedRound
    /\ preferredRound'[i] = logline.event.state.preferredRound
    /\ oneChainRound'[i] = logline.event.state.oneChainRound
    /\ highestTimeoutRound'[i] = logline.event.state.highestTimeoutRound

\* Weak validation: check round progression only
\* Used for message-delivery events where safety state may not change
ValidatePostStateWeak(i) ==
    /\ currentRound'[i] = logline.event.state.currentRound

\* Certificate validation (QC round only — for FormQC events)
ValidateQCState(i) ==
    /\ highestQCRound'[i] = logline.event.state.highestQCRound

\* Full certificate validation (for FormOrderingCert events)
ValidateCertState(i) ==
    /\ highestQCRound'[i] = logline.event.state.highestQCRound
    /\ highestOrderedRound'[i] = logline.event.state.highestOrderedRound

\* ============================================================================
\* STEP TRACE CURSOR
\* ============================================================================

StepTrace == l' = l + 1

\* ============================================================================
\* ACTION WRAPPERS
\* ============================================================================

\* --- Propose ---
\* Matches: event.name = "Propose"
ProposeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Propose", i)
        /\ LET v == TraceValue(logline.event.state.proposalValue)
               r == logline.event.round
           IN /\ v /= Nil
              /\ Propose(i, v)
              /\ StepTrace

\* --- ReceiveProposal ---
\* Matches: event.name = "ReceiveProposal"
ReceiveProposalIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveProposal", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN msgs :
            /\ msgs[m] > 0
            /\ m.mtype = ProposalMsgType
            /\ m.msrc = logline.event.msg.source
            /\ m.mround = logline.event.msg.round
            /\ ReceiveProposal(i, m)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* --- CastVote ---
\* Matches: event.name = "CastVote"
\* Full safety state validation since this updates all safety vars.
CastVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CastVote", i)
        /\ CastVote(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* --- ReceiveVote ---
\* Matches: event.name = "ReceiveVote"
\* Self-votes: already recorded in CastVote, so skip.
ReceiveVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveVote", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Self-vote: already recorded
              /\ logline.event.msg.source = i
              /\ i \in votesForBlock[i][logline.event.msg.round]
              /\ UNCHANGED allVars
              /\ StepTrace
           \/ \* QC already formed: vote is redundant, skip
              /\ HasQuorum(votesForBlock[i][logline.event.msg.round])
              /\ UNCHANGED allVars
              /\ StepTrace
           \/ \* Normal: receive from network
              /\ logline.event.msg.source /= i
              /\ \E m \in DOMAIN msgs :
                  /\ msgs[m] > 0
                  /\ m.mtype = VoteMsgType
                  /\ m.msrc = logline.event.msg.source
                  /\ m.mround = logline.event.msg.round
                  /\ ReceiveVote(i, m)
                  /\ StepTrace

\* --- FormQC ---
\* Matches: event.name = "FormQC"
FormQCIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("FormQC", i)
        /\ LET r == logline.event.round IN
            /\ FormQC(i, r)
            /\ ValidateQCState(i)
            /\ StepTrace

\* --- CastOrderVote ---
\* Matches: event.name = "CastOrderVote"
\* Family 2: Validates that order vote safety state matches.
CastOrderVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CastOrderVote", i)
        /\ LET r == logline.event.round IN
            /\ CastOrderVote(i, r)
            /\ ValidatePostState(i)
            /\ StepTrace

\* --- ReceiveOrderVote ---
\* Matches: event.name = "ReceiveOrderVote"
ReceiveOrderVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveOrderVote", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Self-vote
              /\ logline.event.msg.source = i
              /\ i \in orderVotesForBlock[i][logline.event.msg.round]
              /\ UNCHANGED allVars
              /\ StepTrace
           \/ \* Normal
              /\ logline.event.msg.source /= i
              /\ \E m \in DOMAIN msgs :
                  /\ msgs[m] > 0
                  /\ m.mtype = OrderVoteMsgType
                  /\ m.msrc = logline.event.msg.source
                  /\ m.mround = logline.event.msg.round
                  /\ ReceiveOrderVote(i, m)
                  /\ StepTrace

\* --- FormOrderingCert ---
\* Matches: event.name = "FormOrderingCert"
FormOrderingCertIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("FormOrderingCert", i)
        /\ LET r == logline.event.round IN
            /\ FormOrderingCert(i, r)
            /\ ValidateCertState(i)
            /\ StepTrace

\* --- SignTimeout ---
\* Matches: event.name = "SignTimeout"
SignTimeoutIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SignTimeout", i)
        /\ SignTimeout(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* --- ReceiveTimeout ---
\* Matches: event.name = "ReceiveTimeout"
ReceiveTimeoutIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveTimeout", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Self-timeout
              /\ logline.event.msg.source = i
              /\ i \in timeoutVotes[i][logline.event.msg.round]
              /\ UNCHANGED allVars
              /\ StepTrace
           \/ \* Normal
              /\ logline.event.msg.source /= i
              /\ \E m \in DOMAIN msgs :
                  /\ msgs[m] > 0
                  /\ m.mtype = TimeoutMsgType
                  /\ m.msrc = logline.event.msg.source
                  /\ m.mround = logline.event.msg.round
                  /\ ReceiveTimeout(i, m)
                  /\ StepTrace

\* --- FormTC ---
\* Matches: event.name = "FormTC"
FormTCIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("FormTC", i)
        /\ LET r == logline.event.round IN
            /\ FormTC(i, r)
            /\ ValidateCertState(i)
            /\ StepTrace

\* --- SignCommitVote ---
\* Matches: event.name = "SignCommitVote"
SignCommitVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SignCommitVote", i)
        /\ LET r == logline.event.round IN
            /\ SignCommitVote(i, r)
            /\ StepTrace

\* --- ReceiveCommitVote ---
\* Matches: event.name = "ReceiveCommitVote"
ReceiveCommitVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveCommitVote", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN msgs :
            /\ msgs[m] > 0
            /\ m.mtype = CommitVoteMsgType
            /\ m.msrc = logline.event.msg.source
            /\ m.mround = logline.event.msg.round
            /\ ReceiveCommitVote(i, m)
            /\ StepTrace

\* --- Pipeline events ---

ExecuteBlockIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ExecuteBlock", i)
        /\ LET r == logline.event.round IN
            /\ ExecuteBlock(i, r)
            /\ StepTrace

AggregateCommitVotesIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("AggregateCommitVotes", i)
        /\ LET r == logline.event.round IN
            /\ AggregateCommitVotes(i, r)
            /\ StepTrace

PersistBlockIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("PersistBlock", i)
        /\ LET r == logline.event.round IN
            /\ PersistBlock(i, r)
            /\ StepTrace

ResetPipelineIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ResetPipeline", i)
        /\ ResetPipeline(i)
        /\ StepTrace

\* --- Epoch events ---

EpochChangeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EpochChange", i)
        /\ EpochChange(i)
        /\ StepTrace

\* ============================================================================
\* SILENT ACTIONS
\*
\* These fire base actions without consuming a trace event.
\* MUST be tightly constrained to avoid state space explosion.
\* ============================================================================

\* Silent FormQC: QC forms from accumulated votes without an explicit trace event.
\* Constrained: only fires when the NEXT trace event requires the QC to exist.
\* NOTE: "FormQC" removed from triggers — FormQCIfLogged handles it explicitly.
SilentFormQC ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"CastOrderVote", "FormOrderingCert"}
    /\ \E s \in Server, r \in 1..MaxRound :
        /\ FormQC(s, r)
        /\ UNCHANGED traceVars

\* Silent FormTC: TC forms from accumulated timeouts.
\* Constrained: only fires if the next event needs a higher round.
SilentFormTC ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"Propose", "CastVote", "SignTimeout"}
    /\ \E s \in Server, r \in 1..MaxRound :
        /\ FormTC(s, r)
        /\ UNCHANGED traceVars

\* Silent FormOrderingCert: Ordering cert forms from accumulated order votes.
SilentFormOrderingCert ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"SignCommitVote", "ExecuteBlock"}
    /\ \E s \in Server, r \in 1..MaxRound :
        /\ FormOrderingCert(s, r)
        /\ UNCHANGED traceVars

\* Silent DropMessage: Message consumed without trace event.
SilentDropMessage ==
    /\ l <= Len(TraceLog)
    /\ \E m \in DOMAIN msgs :
        /\ DropMessage(m)
        /\ UNCHANGED traceVars

\* ============================================================================
\* TRACE INIT
\* ============================================================================

\* TraceInit matches the implementation's initial state.
\* The first trace event should correspond to the initial state.
TraceInit ==
    /\ Init
    /\ l = 1

\* ============================================================================
\* TRACE NEXT
\* ============================================================================

TraceNext ==
    \* Event-consuming actions (advance trace cursor)
    \/ ProposeIfLogged
    \/ ReceiveProposalIfLogged
    \/ CastVoteIfLogged
    \/ ReceiveVoteIfLogged
    \/ FormQCIfLogged
    \/ CastOrderVoteIfLogged
    \/ ReceiveOrderVoteIfLogged
    \/ FormOrderingCertIfLogged
    \/ SignTimeoutIfLogged
    \/ ReceiveTimeoutIfLogged
    \/ FormTCIfLogged
    \/ SignCommitVoteIfLogged
    \/ ReceiveCommitVoteIfLogged
    \/ ExecuteBlockIfLogged
    \/ AggregateCommitVotesIfLogged
    \/ PersistBlockIfLogged
    \/ ResetPipelineIfLogged
    \/ EpochChangeIfLogged
    \* Silent actions (do not advance cursor)
    \/ SilentFormQC
    \/ SilentFormTC
    \/ SilentFormOrderingCert
    \* NOTE: SilentDropMessage removed — with proper broadcast (N copies),
    \* all messages are explicitly consumed by receive events.

\* ============================================================================
\* TRACE MATCHED — temporal property
\* Checks that the entire trace was consumed.
\* ============================================================================

TraceMatched == <>[](l > Len(TraceLog))

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

\* WF ensures TraceNext fires whenever it is enabled (prevents trivial stuttering).
TraceSpec == TraceInit /\ [][TraceNext]_<<allVars, traceVars>>
             /\ WF_<<allVars, traceVars>>(TraceNext)

=============================================================================
