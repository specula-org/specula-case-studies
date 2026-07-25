--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation specification for Aptos BFT — Round 2.
 *
 * Replays implementation traces against the base spec to verify that
 * the base spec can reproduce every observed state transition on an
 * HONEST validator.  Byzantine actions are not traced; they exist
 * only in the MC spec.
 *
 * Trace format (NDJSON, one record per line):
 *   { "tag": "trace",
 *     "event": {
 *       "name":  "<action>",     -- e.g. "SignVote", "CompletePersistVote"
 *       "nid":   "<server>",
 *       "epoch": <int>,
 *       "round": <int>,
 *       "state": {
 *         "epoch":               <int>,
 *         "lastVotedRound":      <int>,
 *         "preferredRound":      <int>,
 *         "oneChainRound":       <int>,
 *         "highestTimeoutRound": <int>,
 *         "highestQCRound":      <int>,
 *         "highestOrderedRound": <int>,
 *         "committedRound":      <int>,
 *         "currentRound":        <int>
 *       },
 *       "msg":  { "source":..., "round":..., "epoch":..., "value":... }
 *     }
 *   }
 *
 * Only events emitted from real implementation hooks are matched;
 * Byzantine actions and the fault-injection counters in MC.tla have
 * no trace event.
 *)

EXTENDS base, Json, IOUtils, Sequences, TLC

\* ============================================================================
\* TRACE LOADING
\* ============================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

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

VARIABLE l

traceVars == <<l>>

logline == TraceLog[l]

\* ============================================================================
\* TRACE SERVERS
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

\* ============================================================================
\* POST-STATE VALIDATION
\* ============================================================================

\* The base spec tracks BOTH persisted and volatile safety data; trace
\* events from the implementation hook AFTER the action completes, so we
\* validate volatile fields (which are what the impl has post-mutation).
ValidateSafetyState(i) ==
    /\ volatileSafetyData'[i].epoch              = logline.event.state.epoch
    /\ volatileSafetyData'[i].lastVotedRound     = logline.event.state.lastVotedRound
    /\ volatileSafetyData'[i].preferredRound     = logline.event.state.preferredRound
    /\ volatileSafetyData'[i].oneChainRound      = logline.event.state.oneChainRound
    /\ volatileSafetyData'[i].highestTimeoutRound = logline.event.state.highestTimeoutRound

\* For events that touch persisted state (Commit*PersistVote, SignTimeout)
ValidatePersistedState(i) ==
    /\ persistedSafetyData'[i].lastVotedRound     = logline.event.state.lastVotedRound
    /\ persistedSafetyData'[i].highestTimeoutRound = logline.event.state.highestTimeoutRound

ValidateCertState(i) ==
    /\ highestQCRound'[i]      = logline.event.state.highestQCRound
    /\ highestOrderedRound'[i] = logline.event.state.highestOrderedRound

ValidateRoundState(i) ==
    /\ currentRound'[i] = logline.event.state.currentRound

\* ============================================================================
\* CURSOR ADVANCE
\* ============================================================================

StepTrace == l' = l + 1

\* ============================================================================
\* ACTION WRAPPERS
\* ============================================================================

\* --- Propose ---
ProposeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Propose", i)
        /\ LET v == TraceValue(logline.event.state.proposalValue)
           IN /\ v /= Nil
              /\ Propose(i, v)
              /\ ValidateRoundState(i)
              /\ StepTrace

\* --- ProposeOpt (Family 7) ---
ProposeOptIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ProposeOpt", i)
        /\ LET v == TraceValue(logline.event.state.proposalValue)
           IN /\ v /= Nil
              /\ ProposeOpt(i, v)
              /\ ValidateRoundState(i)
              /\ StepTrace

\* --- ReceiveProposal ---
ReceiveProposalIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveProposal", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN msgs :
            /\ msgs[m] > 0
            /\ m.mtype \in {ProposalMsgType, OptProposalMsgType}
            /\ m.msrc = logline.event.msg.source
            /\ m.mround = logline.event.msg.round
            /\ ReceiveProposal(i, m)
            /\ ValidateRoundState(i)
            /\ StepTrace

\* --- SignVote (sign + inflight; pre-persist) ---
\* Validates volatile safety data (lastVotedRound has been bumped) but
\* NOT persisted state (still old).  This is exactly the Family 1 split.
SignVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SignVote", i)
        /\ SignVote(i)
        /\ ValidateSafetyState(i)
        /\ StepTrace

\* --- CompletePersistVote ---
\* Validates that persisted now matches volatile.
CompletePersistVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CompletePersistVote", i)
        /\ CompletePersistVote(i)
        /\ ValidatePersistedState(i)
        /\ StepTrace

\* --- ReceiveVote ---
ReceiveVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveVote", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Self-vote: already recorded in SignVote, skip
              /\ logline.event.msg.source = i
              /\ i \in votesForBlock[i][logline.event.msg.round]
              /\ UNCHANGED allVars
              /\ StepTrace
           \/ \* Quorum already reached: redundant; skip
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
FormQCIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("FormQC", i)
        /\ LET r == logline.event.round IN
            /\ FormQC(i, r)
            /\ ValidateCertState(i)
            /\ StepTrace

\* --- SignOrderVote ---
SignOrderVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SignOrderVote", i)
        /\ LET r == logline.event.round IN
            /\ SignOrderVote(i, r)
            /\ ValidateSafetyState(i)
            /\ StepTrace

\* --- ReceiveOrderVote ---
ReceiveOrderVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveOrderVote", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Self
              /\ logline.event.msg.source = i
              /\ \E v \in Values : i \in orderVotesForDigest[i][logline.event.msg.round][v]
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
FormOrderingCertIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("FormOrderingCert", i)
        /\ LET r == logline.event.round
               v == TraceValue(logline.event.state.proposalValue)
           IN /\ v /= Nil
              /\ FormOrderingCert(i, r, v)
              /\ ValidateCertState(i)
              /\ StepTrace

\* --- SignTimeout ---
SignTimeoutIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SignTimeout", i)
        /\ SignTimeout(i)
        /\ ValidatePersistedState(i)
        /\ StepTrace

\* --- ReceiveTimeout ---
ReceiveTimeoutIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveTimeout", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \/ /\ logline.event.msg.source = i
              /\ i \in timeoutVotes[i][logline.event.msg.round]
              /\ UNCHANGED allVars
              /\ StepTrace
           \/ /\ logline.event.msg.source /= i
              /\ \E m \in DOMAIN msgs :
                  /\ msgs[m] > 0
                  /\ m.mtype = TimeoutMsgType
                  /\ m.msrc = logline.event.msg.source
                  /\ m.mround = logline.event.msg.round
                  /\ ReceiveTimeout(i, m)
                  /\ StepTrace

\* --- FormTC ---
FormTCIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("FormTC", i)
        /\ LET r == logline.event.round IN
            /\ FormTC(i, r)
            /\ StepTrace

\* --- EchoTimeout ---
\* EchoTimeout re-broadcasts the current-round timeout without changing
\* persisted state.  ValidateSafetyState verifies volatile fields
\* remained as expected (lastVotedRound, highestTimeoutRound unchanged).
EchoTimeoutIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EchoTimeout", i)
        /\ EchoTimeout(i)
        /\ ValidateSafetyState(i)
        /\ StepTrace

\* --- SignCommitVote ---
SignCommitVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SignCommitVote", i)
        /\ LET r == logline.event.round
               e == logline.event.state.epoch
           IN /\ SignCommitVote(i, r, e)
              /\ StepTrace

\* --- ReceiveCommitVote ---
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

EpochChangeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EpochChange", i)
        /\ EpochChange(i)
        /\ StepTrace

\* --- Crash / Recover (Family 1) ---
\* The implementation has no in-process trace event for "crash"; we
\* model this as a silent edge.  But if the harness emits an explicit
\* "Recover" event (which IS observable: SafetyRules::initialize is
\* called on recovery), we match it.

RecoverIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Recover", i)
        /\ Recover(i)
        /\ ValidatePersistedState(i)
        /\ StepTrace

\* ============================================================================
\* SILENT ACTIONS
\*
\* Tightly constrained: each is gated on the NEXT trace event requiring
\* the state change.  This prevents state-space explosion.
\* ============================================================================

\* Silent FormQC — QC becomes formable as votes accumulate; no explicit
\* event.  Fires only when the next event needs QC to be present.
SilentFormQC ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"SignOrderVote", "FormOrderingCert"}
    /\ \E s \in Server, r \in 1..MaxRound :
        /\ FormQC(s, r)
        /\ UNCHANGED traceVars

\* Silent FormTC — only fires when the next event needs a higher round.
SilentFormTC ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"Propose", "SignVote", "SignTimeout"}
    /\ \E s \in Server, r \in 1..MaxRound :
        /\ FormTC(s, r)
        /\ UNCHANGED traceVars

\* Silent FormOrderingCert
SilentFormOrderingCert ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"SignCommitVote", "ExecuteBlock"}
    /\ \E s \in Server, r \in 1..MaxRound, v \in Values :
        /\ FormOrderingCert(s, r, v)
        /\ UNCHANGED traceVars

\* Silent Crash — the impl has no "crash" hook; we approximate by
\* allowing Crash to fire only immediately before a Recover event.
SilentCrash ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "Recover"
    /\ \E s \in Server :
        /\ alive[s] = TRUE
        /\ Crash(s)
        /\ UNCHANGED traceVars

\* ============================================================================
\* TRACE INIT / NEXT
\* ============================================================================

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \/ ProposeIfLogged
    \/ ProposeOptIfLogged
    \/ ReceiveProposalIfLogged
    \/ SignVoteIfLogged
    \/ CompletePersistVoteIfLogged
    \/ ReceiveVoteIfLogged
    \/ FormQCIfLogged
    \/ SignOrderVoteIfLogged
    \/ ReceiveOrderVoteIfLogged
    \/ FormOrderingCertIfLogged
    \/ SignTimeoutIfLogged
    \/ ReceiveTimeoutIfLogged
    \/ FormTCIfLogged
    \/ EchoTimeoutIfLogged
    \/ SignCommitVoteIfLogged
    \/ ReceiveCommitVoteIfLogged
    \/ ExecuteBlockIfLogged
    \/ AggregateCommitVotesIfLogged
    \/ PersistBlockIfLogged
    \/ ResetPipelineIfLogged
    \/ EpochChangeIfLogged
    \/ RecoverIfLogged
    \* Silent (no cursor advance)
    \/ SilentFormQC
    \/ SilentFormTC
    \/ SilentFormOrderingCert
    \/ SilentCrash

\* ============================================================================
\* TRACE MATCHED
\* ============================================================================

TraceMatched == <>(l > Len(TraceLog))

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

TraceSpec == TraceInit /\ [][TraceNext]_<<allVars, traceVars>>
             /\ WF_<<allVars, traceVars>>(TraceNext)

=============================================================================
