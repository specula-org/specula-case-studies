---------------------------- MODULE Trace ----------------------------
(*
   Trace validation spec for Autobahn BFT consensus.

   Replays NDJSON traces from instrumented implementation against base spec
   to verify consistency between implementation and formal model.

   Category: A (Distributed / Message-Passing)
*)

EXTENDS base, Naturals, FiniteSets, Sequences, Json

(* ======================== Trace Loading ======================== *)

(* Load trace from JSON file - relative to spec directory *)
JsonFile == "../traces/basic_voting.ndjson"

(* Deserialize NDJSON trace *)
TraceLog == ndJsonDeserialize(JsonFile)

(* ======================== Trace Cursor ======================== *)

VARIABLE l  \* Cursor through trace events

(* Current logline *)
logline == IF l <= Len(TraceLog) THEN TraceLog[l] ELSE NULL_MSG

(* ======================== Event Predicates ======================== *)

IsEvent(name) == "name" \in DOMAIN logline /\ logline.name = name

IsNodeEvent(name, n) == IsEvent(name) /\ "nid" \in DOMAIN logline /\ logline.nid = n

IsMsgEvent(name, from, to) ==
    IsEvent(name) /\ "from" \in DOMAIN logline /\ logline.from = from /\ logline.to = to

(* ======================== Role Mapping ======================== *)

(* Map implementation node IDs to spec Node set *)
NodeIdToSpec(nodeId) == nodeId  \* 1-indexed in both

(* ======================== Post-State Validation ======================== *)

(*
   ValidatePostState: Check spec state after action matches trace observation.

   For each action, validate the key fields that changed.
*)

ValidatePostState(action) ==
    IF action = "CheckVoteSafety"
    THEN
        \* After safety check, in-memory state updated, persistent unchanged
        /\ lastVotedRound[logline.node] = logline.votedRound
        /\ voteStatus[logline.node] = "checked"
        /\ persistentLastVotedRound[logline.node] = logline.persistentVotedRound
    ELSE IF action = "PersistVoteRound"
    THEN
        \* After persistence, durable state matches in-memory
        /\ persistentLastVotedRound[logline.node] = logline.persistentVotedRound
        /\ voteStatus[logline.node] = "persisted"
    ELSE IF action = "SendVote"
    THEN
        \* After vote sent, reset to idle
        /\ voteStatus[logline.node] = "idle"
        /\ logline.voteMessage \in msgs
    ELSE IF action = "ProcessQCFromProposal"
    THEN
        \* QC processing started, in-flight marker set
        /\ qcProcessing[logline.node] = TRUE
        /\ logline.qcRound = highQC[logline.node].round
    ELSE IF action = "AdvanceRoundFromQC"
    THEN
        \* Round advance pending
        /\ pendingRoundAdvance[logline.node] = logline.newRound
        /\ qcProcessing[logline.node] = TRUE
    ELSE IF action = "CommitRoundAdvance"
    THEN
        \* Round committed, atomicity window closed
        /\ round[logline.node] = logline.newRound
        /\ pendingRoundAdvance[logline.node] = NIL
        /\ qcProcessing[logline.node] = FALSE
    ELSE IF action = "AddTimeoutToTC"
    THEN
        \* Timeout added to TC signature set
        /\ logline.sender \in tcSignatures[logline.node]
    ELSE IF action = "AdvanceRoundViaTC"
    THEN
        \* TC round committed to round advance
        /\ round[logline.node] = logline.newRound
        /\ tcRound[logline.node] = NIL
    ELSE IF action = "GenerateProposal"
    THEN
        \* Proposal generated, marked as proposed
        /\ round[logline.node] \in proposedRounds[logline.node]
        /\ logline.proposalMessage \in msgs
    ELSE IF action = "Crash"
    THEN
        \* Node marked crashed, in-memory state lost
        /\ crashed[logline.node] = TRUE
        /\ lastVotedRound[logline.node] = 0
        /\ voteStatus[logline.node] = "idle"
    ELSE IF action = "Recover"
    THEN
        \* Node recovered, persistent state reloaded
        /\ crashed[logline.node] = FALSE
        /\ lastVotedRound[logline.node] = persistentLastVotedRound[logline.node]
    ELSE
        TRUE  \* Unknown action, skip validation

(* ======================== Action Wrappers ======================== *)

(*
   Each action wrapper:
   1. Matches against trace event
   2. Calls base spec action
   3. Validates post-state
   4. Advances cursor
*)

MatchCheckVoteSafety ==
    /\ IsEvent("CheckVoteSafety")
    /\ LET n == NodeIdToSpec(logline.node)
           r == logline.round
           qcr == logline.qcRound
       IN
       /\ CheckVoteSafety(n, r, qcr)
       /\ ValidatePostState("CheckVoteSafety")
    /\ l' = l + 1

MatchPersistVoteRound ==
    /\ IsEvent("PersistVoteRound")
    /\ LET n == NodeIdToSpec(logline.node)
       IN
       /\ PersistVoteRound(n)
       /\ ValidatePostState("PersistVoteRound")
    /\ l' = l + 1

MatchSendVote ==
    /\ IsEvent("SendVote")
    /\ LET n == NodeIdToSpec(logline.node)
       IN
       /\ SendVote(n)
       /\ ValidatePostState("SendVote")
    /\ l' = l + 1

MatchProcessQCFromProposal ==
    /\ IsEvent("ProcessQCFromProposal")
    /\ LET n == NodeIdToSpec(logline.node)
           br == logline.blockRound
           qcr == logline.qcRound
       IN
       /\ ProcessQCFromProposal(n, br, qcr)
       /\ ValidatePostState("ProcessQCFromProposal")
    /\ l' = l + 1

MatchAdvanceRoundFromQC ==
    /\ IsEvent("AdvanceRoundFromQC")
    /\ LET n == NodeIdToSpec(logline.node)
           nr == logline.newRound
       IN
       /\ AdvanceRoundFromQC(n, nr)
       /\ ValidatePostState("AdvanceRoundFromQC")
    /\ l' = l + 1

MatchCommitRoundAdvance ==
    /\ IsEvent("CommitRoundAdvance")
    /\ LET n == NodeIdToSpec(logline.node)
       IN
       /\ CommitRoundAdvance(n)
       /\ ValidatePostState("CommitRoundAdvance")
    /\ l' = l + 1

MatchAddTimeoutToTC ==
    /\ IsEvent("AddTimeoutToTC")
    /\ LET n == NodeIdToSpec(logline.node)
           tcr == logline.tcRound
           s == NodeIdToSpec(logline.sender)
       IN
       /\ AddTimeoutToTC(n, tcr, s)
       /\ ValidatePostState("AddTimeoutToTC")
    /\ l' = l + 1

MatchAdvanceRoundViaTC ==
    /\ IsEvent("AdvanceRoundViaTC")
    /\ LET n == NodeIdToSpec(logline.node)
       IN
       /\ AdvanceRoundViaTC(n)
       /\ ValidatePostState("AdvanceRoundViaTC")
    /\ l' = l + 1

MatchGenerateProposal ==
    /\ IsEvent("GenerateProposal")
    /\ LET n == NodeIdToSpec(logline.node)
       IN
       /\ GenerateProposal(n)
       /\ ValidatePostState("GenerateProposal")
    /\ l' = l + 1

MatchCrash ==
    /\ IsEvent("Crash")
    /\ LET n == NodeIdToSpec(logline.node)
       IN
       /\ Crash(n)
       /\ ValidatePostState("Crash")
    /\ l' = l + 1

MatchRecover ==
    /\ IsEvent("Recover")
    /\ LET n == NodeIdToSpec(logline.node)
       IN
       /\ Recover(n)
       /\ ValidatePostState("Recover")
    /\ l' = l + 1

(* ======================== Silent Actions ======================== *)

(*
   Silent actions handle implementation state changes without trace events.
   Must be tightly constrained to prevent state space explosion.
*)

(* Message loss can occur without being traced *)
SilentMessageLoss ==
    /\ l <= Len(TraceLog)  \* Don't lose messages when trace is done
    /\ LoseMessage

(* ======================== All Variables ======================== *)

vars == <<round, highQC, highTC, msgs, lastVotedRound, persistentLastVotedRound,
          voteStatus, pendingRoundAdvance, qcProcessing, tcRound, tcSignatures,
          proposedRounds, crashed>>

(* ======================== Trace Init ======================== *)

TraceInit ==
    /\ Init
    /\ l = 2  \* Skip config record at index 1

(* ======================== Trace Next ======================== *)

TraceNext ==
    \/ MatchCheckVoteSafety
    \/ MatchPersistVoteRound
    \/ MatchSendVote
    \/ MatchProcessQCFromProposal
    \/ MatchAdvanceRoundFromQC
    \/ MatchCommitRoundAdvance
    \/ MatchAddTimeoutToTC
    \/ MatchAdvanceRoundViaTC
    \/ MatchGenerateProposal
    \/ MatchCrash
    \/ MatchRecover
    \/ SilentMessageLoss
    \/ (l > Len(TraceLog) /\ UNCHANGED <<vars, l>>)  \* Stuttering after trace complete

(* ======================== Trace Completion ======================== *)

TraceMatched == <>(l > Len(TraceLog))

=============================================================================
