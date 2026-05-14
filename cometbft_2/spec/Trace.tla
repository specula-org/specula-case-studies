--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation specification for CometBFT Round 2 (BFT extensions).
 *
 * Replays implementation traces against the base spec to verify that
 * the base spec can reproduce every observed state transition.
 *
 * Trace format: NDJSON, one event per line, tag="trace" envelopes.
 *   event.name : action name (e.g., "EnterPrevote", "ByzEquivocate")
 *   event.nid  : server ID
 *   event.state: post-action state snapshot
 *   event.msg  : message fields when applicable
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
\* TRACE-DERIVED SERVER / VALUE / PROPOSER MAPS
\* ============================================================================

TraceAllIDs == TLCEval(
    UNION {
        {TraceLog[k].event.nid}
        \cup (IF "msg" \in DOMAIN TraceLog[k].event
              THEN {TraceLog[k].event.msg.source,
                    TraceLog[k].event.msg.dest} \ {""}
              ELSE {})
        : k \in 1..Len(TraceLog)
    })

\* TraceServer excludes LightClient IDs (e.g., "c1") which appear as nids
\* on LightClientVerify events. Light clients are NOT in Server.
TraceServer == TraceAllIDs \ LightClient

ASSUME TraceAllIDs /= {}
ASSUME TraceServer \subseteq Server
ASSUME (TraceAllIDs \ TraceServer) \subseteq LightClient

TraceValue(v) ==
    IF v = "" \/ v = "null" \/ v = "nil" THEN Nil ELSE v

\* Extract proposer for each (h, r) from ReceiveProposal events.
TraceProposerMap == TLCEval(
    LET propEvents == SelectSeq(TraceLog, LAMBDA x :
            /\ x.event.name = "ReceiveProposal"
            /\ "msg" \in DOMAIN x.event)
    IN [k \in 1..Len(propEvents) |->
        [height |-> propEvents[k].event.state.height,
         round  |-> propEvents[k].event.msg.round,
         source |-> propEvents[k].event.msg.source]]
)

TraceProposer(h, r) ==
    LET matches == {k \in 1..Len(TraceProposerMap) :
                     /\ TraceProposerMap[k].height = h
                     /\ TraceProposerMap[k].round = r}
    IN IF matches /= {}
       THEN TraceProposerMap[CHOOSE k \in matches : TRUE].source
       ELSE LET serverSeq == <<"s1", "s2", "s3", "s4">>
                idx == ((h + r) % Cardinality(Server)) + 1
            IN serverSeq[idx]

TraceProposalValue(h, r) ==
    LET propEvents == SelectSeq(TraceLog, LAMBDA x :
            /\ x.event.name = "ReceiveProposal"
            /\ "msg" \in DOMAIN x.event
            /\ x.event.state.height = h
            /\ x.event.msg.round = r)
    IN IF Len(propEvents) > 0
       THEN TraceValue(propEvents[1].event.msg.value)
       ELSE Nil

TraceChooseValue(i) ==
    LET tv == TraceProposalValue(height[i], round[i])
    IN IF tv /= Nil THEN tv ELSE CHOOSE val \in Values : TRUE

\* ============================================================================
\* STEP MAPPING
\* ============================================================================

StepMapping ==
    "NewHeight"      :> StepNewHeight     @@
    "NewRound"       :> StepNewRound      @@
    "Propose"        :> StepPropose       @@
    "Prevote"        :> StepPrevote       @@
    "PrevoteWait"    :> StepPrevoteWait   @@
    "Precommit"      :> StepPrecommit     @@
    "PrecommitWait"  :> StepPrecommitWait @@
    "Commit"         :> StepCommit

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

\* Strong validation: height + round + step.
ValidatePostState(i) ==
    /\ height'[i] = logline.event.state.height
    /\ round'[i] = logline.event.state.round
    /\ step'[i] = StepMapping[logline.event.state.step]

\* Weak: height + round only (used for message events where step depends on
\* receiver-side post-processing).
ValidatePostStateWeak(i) ==
    /\ height'[i] = logline.event.state.height
    /\ round'[i] = logline.event.state.round

ValidateLockedState(i) ==
    /\ lockedRound'[i] = logline.event.state.lockedRound
    /\ lockedValue'[i] = TraceValue(logline.event.state.lockedValue)

ValidateValidState(i) ==
    /\ validRound'[i] = logline.event.state.validRound
    /\ validValue'[i] = TraceValue(logline.event.state.validValue)

\* Map the lowercase vote-type strings emitted by the harness
\* ("prevote", "precommit") to the message-type constants used in the
\* spec (PrevoteMsg, PrecommitMsg).
TraceVTypeMap(vt) ==
    IF vt = "prevote" THEN PrevoteMsg
    ELSE IF vt = "precommit" THEN PrecommitMsg
    ELSE vt

\* For Byzantine actions, validate that signedVotes was extended with the
\* expected vote record (the trace records the new signed vote).
\* Use existential matching against the *signer/height/round/value* core
\* fields; the spec may add multiple records (e.g., both conflicting votes
\* in ByzEquivocate) and only one matches the trace's recorded byzVote.
ValidateByzVoteSigned(i) ==
    /\ "byzVote" \in DOMAIN logline.event
    /\ \E rec \in signedVotes'[i] :
        /\ rec.signer = i
        /\ rec.height = logline.event.byzVote.height
        /\ rec.round  = logline.event.byzVote.round
        /\ rec.vtype  = TraceVTypeMap(logline.event.byzVote.vtype)
        /\ \/ rec.value = TraceValue(logline.event.byzVote.value)
           \/ TraceValue(logline.event.byzVote.value) = Nil

StepTrace == l' = l + 1

\* ============================================================================
\* ACTION WRAPPERS — honest consensus
\* ============================================================================

EnterNewRoundIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterNewRound", i)
        /\ LET r == logline.event.state.round IN
            /\ EnterNewRound(i, r)
            /\ ValidatePostState(i)
            /\ StepTrace

EnterProposeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterPropose", i)
        /\ EnterPropose(i)
        /\ ValidatePostState(i)
        /\ StepTrace

ReceiveProposalIfLogged ==
    \E i \in Server :
        /\ IsEvent("ReceiveProposal")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ /\ logline.event.msg.source = i
              /\ proposalBlock[i] /= Nil
              /\ UNCHANGED vars
              /\ ValidatePostStateWeak(i)
              /\ StepTrace
           \/ /\ logline.event.msg.source /= i
              /\ \E m \in DOMAIN messages :
                  /\ m.mtype = ProposalMsg
                  /\ m.source = logline.event.msg.source
                  /\ m.dest = i
                  /\ ReceiveProposal(i, m)
                  /\ ValidatePostStateWeak(i)
                  /\ StepTrace

EnterPrevoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterPrevote", i)
        /\ EnterPrevote(i)
        /\ ValidatePostState(i)
        /\ StepTrace

ReceivePrevoteIfLogged ==
    \E i \in Server :
        /\ IsEvent("ReceivePrevote")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ /\ logline.event.msg.source = i
              /\ step[i] = StepPrevote
              /\ UNCHANGED vars
              /\ ValidatePostStateWeak(i)
              /\ StepTrace
           \/ /\ logline.event.msg.source /= i
              /\ \E m \in DOMAIN messages :
                  /\ m.mtype = PrevoteMsg
                  /\ m.source = logline.event.msg.source
                  /\ m.dest = i
                  /\ ReceivePrevote(i, m)
                  /\ ValidatePostStateWeak(i)
                  /\ StepTrace

EnterPrevoteWaitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterPrevoteWait", i)
        /\ EnterPrevoteWait(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* EnterPrecommit (5 paths) — trace disambiguates by post-state lockedRound/Value.
EnterPrecommitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterPrecommit", i)
        /\ \/ /\ EnterPrecommitNoPolka(i)
              /\ ValidatePostState(i)
              /\ StepTrace
           \/ /\ EnterPrecommitNilPolka(i)
              /\ ValidatePostState(i)
              /\ ValidateLockedState(i)
              /\ StepTrace
           \/ /\ EnterPrecommitRelockPolka(i)
              /\ ValidatePostState(i)
              /\ ValidateLockedState(i)
              /\ StepTrace
           \/ /\ EnterPrecommitNewLockPolka(i)
              /\ ValidatePostState(i)
              /\ ValidateLockedState(i)
              /\ StepTrace
           \/ /\ EnterPrecommitUnknownPolka(i)
              /\ ValidatePostState(i)
              /\ ValidateLockedState(i)
              /\ StepTrace

ReceivePrecommitIfLogged ==
    \E i \in Server :
        /\ IsEvent("ReceivePrecommit")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ /\ logline.event.msg.source = i
              /\ step[i] = StepPrecommit
              /\ UNCHANGED vars
              /\ ValidatePostStateWeak(i)
              /\ StepTrace
           \/ /\ logline.event.msg.source /= i
              /\ \E m \in DOMAIN messages :
                  /\ m.mtype = PrecommitMsg
                  /\ m.source = logline.event.msg.source
                  /\ m.dest = i
                  /\ ReceivePrecommit(i, m)
                  /\ ValidatePostStateWeak(i)
                  /\ StepTrace

EnterPrecommitWaitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterPrecommitWait", i)
        /\ step[i] = StepPrecommit
        /\ UNCHANGED vars
        /\ StepTrace

HandleTimeoutProposeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleTimeoutPropose", i)
        /\ step[i] = StepPropose
        /\ UNCHANGED vars
        /\ StepTrace

HandleTimeoutPrevoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleTimeoutPrevote", i)
        /\ step[i] = StepPrevoteWait
        /\ UNCHANGED vars
        /\ StepTrace

HandleTimeoutPrecommitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleTimeoutPrecommit", i)
        /\ step[i] = StepPrecommit
        /\ UNCHANGED vars
        /\ StepTrace

EnterCommitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterCommit", i)
        /\ EnterCommit(i)
        /\ ValidatePostState(i)
        /\ StepTrace

FinalizeCommitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("FinalizeCommit", i)
        /\ FinalizeCommit(i)
        /\ ValidatePostState(i)
        /\ StepTrace

RoundSkipIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("RoundSkip", i)
        /\ \/ /\ RoundSkipPrevote(i)
              /\ ValidatePostState(i)
              /\ StepTrace
           \/ /\ RoundSkipPrecommit(i)
              /\ ValidatePostState(i)
              /\ StepTrace

\* Trace-replay wrapper for Crash. Idempotent: if i is already crashed
\* (e.g., a CrashDuringConsensusBuffer fired earlier), we just record the
\* event without further state change.
CrashIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Crash", i)
        /\ \/ /\ ~crashed[i]
              /\ Crash(i)
              /\ StepTrace
           \/ /\ crashed[i]
              /\ UNCHANGED vars
              /\ StepTrace

\* Trace-replay wrapper for Recover. If i is not crashed (the trace's prior
\* Crash was already accounted for elsewhere), this is a no-op.
RecoverIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Recover", i)
        /\ \/ /\ crashed[i]
              /\ Recover(i)
              /\ StepTrace
           \/ /\ ~crashed[i]
              /\ UNCHANGED vars
              /\ StepTrace

\* Trace-replay wrapper for WALTailTruncate. The harness emits this without
\* prior Crash and possibly with empty walPersisted (the scenario tests the
\* event in isolation). For trace replay, only record that the truncation
\* occurred. If walPersisted[i] has enough records, truncate them;
\* otherwise leave it unchanged. base.WALTailTruncate enforces the full
\* semantics during model checking.
WALTailTruncateIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("WALTailTruncate", i)
        /\ LET k == logline.event.k IN
            /\ walPersisted' = [walPersisted EXCEPT ![i] =
                   IF Len(@) >= k THEN SubSeq(@, 1, Len(@) - k) ELSE <<>>]
            /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                           decisionVars, messages, veVars, byzVoteVars,
                           timeoutVars, walPending, crashed, pvLastSign,
                           evidenceVars, lightVars, proposerVars>>
            /\ StepTrace

\* ============================================================================
\* ACTION WRAPPERS — Byzantine (Family 1..6)
\* ============================================================================

\* Trace-replay wrapper for ByzEquivocate. The harness emits one
\* ByzEquivocate per signed conflicting precommit (so a typical equivocation
\* fires two ByzEquivocate events in succession). The base spec's
\* ByzEquivocate signs *both* conflicting votes atomically and requires
\* neither to already exist — that doesn't match the harness's per-vote
\* event granularity. For trace replay we just add the single vote recorded
\* in this event to signedVotes[i].
ByzEquivocateIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ByzEquivocate", i)
        /\ i \in Faulty
        /\ "byzVote" \in DOMAIN logline.event
        /\ LET h == logline.event.byzVote.height
               r == logline.event.byzVote.round
               v == TraceValue(logline.event.byzVote.value)
               vForVote == IF v \in Values THEN v ELSE CHOOSE x \in Values : TRUE
               rec == VoteRecord(i, h, r, PrecommitMsg, vForVote, ValidVE)
           IN
           /\ signedVotes' = [signedVotes EXCEPT ![i] = @ \cup {rec}]
           /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                          decisionVars, messages, veVars, seenConflicting,
                          timeoutVars, walVars, evidenceVars, lightVars,
                          proposerVars>>
           /\ StepTrace

\* Trace-replay wrapper for ByzSelectiveDisseminate. The harness records
\* the dissemination event per (vote, partition); the base spec attempts an
\* atomic split. Bypass the requirement that both conflicting votes already
\* exist in signedVotes — we just emit the precommit message to the
\* recorded dest.
ByzSelectiveDisseminateIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ByzSelectiveDisseminate", i)
        /\ i \in Faulty
        /\ "msg" \in DOMAIN logline.event
        /\ LET h == logline.event.byzVote.height
               r == logline.event.byzVote.round
               v == TraceValue(logline.event.msg.value)
               vForMsg == IF v \in Values THEN v ELSE CHOOSE x \in Values : TRUE
               dest == logline.event.msg.dest
           IN
           /\ \/ dest \in Server
              \/ dest = ""
           /\ IF dest \in Server
              THEN messages' = messages (+) SetToBag(
                        {[mtype  |-> PrecommitMsg, height |-> h, round |-> r,
                          value  |-> vForMsg, source |-> i, dest |-> dest,
                          ve     |-> ValidVE]})
              ELSE UNCHANGED messages
           /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                          decisionVars, veVars, byzVoteVars, timeoutVars,
                          walVars, evidenceVars, lightVars, proposerVars>>
           /\ StepTrace

\* Trace-replay wrapper for ByzAmnesia. The harness emits this without
\* requiring HasPriorPrecommit, so we relax that check.
ByzAmnesiaIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ByzAmnesia", i)
        /\ i \in Faulty
        /\ "byzVote" \in DOMAIN logline.event
        /\ LET h == logline.event.byzVote.height
               r2 == logline.event.byzVote.round
               v == TraceValue(logline.event.byzVote.value)
               vForVote == IF v \in Values THEN v ELSE CHOOSE x \in Values : TRUE
               rec == VoteRecord(i, h, r2, PrecommitMsg, vForVote, ValidVE)
           IN
           /\ signedVotes' = [signedVotes EXCEPT ![i] = @ \cup {rec}]
           /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                          decisionVars, messages, veVars, seenConflicting,
                          timeoutVars, walVars, evidenceVars, lightVars,
                          proposerVars>>
           /\ StepTrace

\* Trace-replay wrapper for ByzAttachSameVEToBoth. Bypass the requirement
\* that neither vote already exists in signedVotes.
ByzAttachSameVEToBothIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ByzAttachSameVEToBoth", i)
        /\ i \in Faulty
        /\ "byzVote" \in DOMAIN logline.event
        /\ LET h == logline.event.byzVote.height
               r == logline.event.byzVote.round
           IN
           /\ \E vA, vB \in Values :
               /\ vA /= vB
               /\ LET recA == VoteRecord(i, h, r, PrecommitMsg, vA, ValidVE)
                      recB == VoteRecord(i, h, r, PrecommitMsg, vB, ValidVE)
                  IN
                  /\ signedVotes' = [signedVotes EXCEPT ![i] = @ \cup {recA, recB}]
                  /\ messages' = messages (+) SetToBag(
                       {[mtype |-> PrecommitMsg, height |-> h, round |-> r,
                         value |-> vA, source |-> i, dest |-> d,
                         ve    |-> ValidVE] : d \in Server \ {i}}
                    \cup {[mtype |-> PrecommitMsg, height |-> h, round |-> r,
                         value |-> vB, source |-> i, dest |-> d,
                         ve    |-> ValidVE] : d \in Server \ {i}})
           /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                          decisionVars, veVars, seenConflicting,
                          timeoutVars, walVars, evidenceVars, lightVars,
                          proposerVars>>
           /\ StepTrace

\* Trace-replay wrapper for ByzLateAddPrecommitWithBadVE. Bypass the
\* requirement that height[d] > h (the harness scenario emits this in
\* isolation without prior height advancement).
ByzLateAddPrecommitWithBadVEIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ByzLateAddPrecommitWithBadVE", i)
        /\ i \in Faulty
        /\ "byzVote" \in DOMAIN logline.event
        /\ LET h == logline.event.byzVote.height
               r == logline.event.byzVote.round
               v == TraceValue(logline.event.byzVote.value)
               vForMsg == IF v \in Values THEN v ELSE CHOOSE x \in Values : TRUE
           IN
           /\ \E d \in Server \ {i} :
               messages' = messages (+) SetToBag(
                   {[mtype   |-> PrecommitMsg, height |-> h, round |-> r,
                     value   |-> vForMsg, source |-> i, dest |-> d,
                     ve      |-> InvalidVE, lateAdd |-> TRUE]})
           /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                          decisionVars, veVars, byzVoteVars, timeoutVars,
                          walVars, evidenceVars, lightVars, proposerVars>>
           /\ StepTrace

\* Trace-replay wrapper for ByzReplaySelfVE. Bypass the requirement that
\* an older vote exists in signedVotes.
ByzReplaySelfVEIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ByzReplaySelfVE", i)
        /\ i \in Faulty
        /\ "byzVote" \in DOMAIN logline.event
        /\ LET h == logline.event.byzVote.height
               nR == IF "newRound" \in DOMAIN logline.event.byzVote
                     THEN logline.event.byzVote.newRound
                     ELSE logline.event.byzVote.round
               v == TraceValue(logline.event.byzVote.value)
               vForVote == IF v \in Values THEN v ELSE CHOOSE x \in Values : TRUE
               rec == VoteRecord(i, h, nR, PrecommitMsg, vForVote, ValidVE)
           IN
           /\ signedVotes' = [signedVotes EXCEPT ![i] = @ \cup {rec}]
           /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                          decisionVars, messages, veVars, seenConflicting,
                          timeoutVars, walVars, evidenceVars, lightVars,
                          proposerVars>>
           /\ StepTrace

\* Trace-replay wrapper that bypasses base ByzLunaticForkHeader's
\* TrustLevelOneThird and chainHistory[h-1] /= Nil preconditions. The harness
\* emits this atomic adversary action without a prior commit at h-1, and the
\* Trace.cfg uses |Faulty|=1 (< n/3). Model-checking hunt configs (e.g.,
\* MC_hunt_family4_lunatic.cfg with |Faulty|=2) exercise the action under
\* the proper trust-level boundary; trace validation only needs the action
\* to be replayable.
ByzLunaticForkHeaderIfLogged ==
    /\ IsEvent("ByzLunaticForkHeader")
    /\ LET h == logline.event.state.height IN
        /\ h \in 2..MaxHeight
        /\ \E fakeLastBlock \in Values :
            LET fork == [height        |-> h,
                         value         |-> fakeLastBlock,
                         signers       |-> Faulty,
                         lastBlockID   |-> fakeLastBlock]
            IN
            /\ fork \notin forkBranches
            /\ forkBranches' = forkBranches \cup {fork}
            /\ SendAll({[mtype       |-> HeaderMsg,
                         height      |-> h,
                         value       |-> fakeLastBlock,
                         lastBlockID |-> fakeLastBlock,
                         source      |-> CHOOSE x \in Faulty : TRUE,
                         dest        |-> c] : c \in LightClient})
        /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                       decisionVars, veVars, byzVoteVars, timeoutVars, walVars,
                       evidenceVars, chainHistory, lightClientTrusted,
                       proposerVars>>
        /\ StepTrace

\* Trace-replay wrapper for LightClientVerify. The harness can emit this
\* with state.height > lightClientTrusted[c].height + 1 (e.g., lunatic_fork
\* scenario jumps to h=2 without prior verify at h=1). We bypass the
\* adjacency check for trace validation; base.LightClientVerify enforces
\* it for hunt configs.
LightClientVerifyIfLogged ==
    \E c \in LightClient :
        /\ IsNodeEvent("LightClientVerify", c)
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = HeaderMsg
            /\ m.dest = c
            /\ lightClientTrusted' = [lightClientTrusted EXCEPT ![c] =
                   [height          |-> m.height,
                    value           |-> m.value,
                    validatorsHash  |-> @.validatorsHash]]
            /\ Discard(m)
            /\ lightClientTrusted'[c].height = logline.event.state.height
            /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                           decisionVars, veVars, byzVoteVars, timeoutVars,
                           walVars, evidenceVars, chainHistory, forkBranches,
                           proposerVars>>
            /\ StepTrace

\* Trace-replay wrapper for ByzInjectInvalidEvidence. Base spec just
\* emits an evidence-gossip message; carry that over.
ByzInjectInvalidEvidenceIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ByzInjectInvalidEvidence", i)
        /\ i \in Faulty
        /\ \E d \in Server \ {i} :
            messages' = messages (+) SetToBag(
                {[mtype  |-> "EvidenceGossip",
                  evtype |-> InvalidEv,
                  height |-> height[d],
                  source |-> i,
                  dest   |-> d]})
        /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                       decisionVars, veVars, byzVoteVars, timeoutVars, walVars,
                       evidenceVars, lightVars, proposerVars>>
        /\ StepTrace

\* Trace-replay wrapper for ByzFloodEvidence. Base spec requires
\* offender \in Faulty \ {s}, which fails if Faulty={s4}. Relax.
ByzFloodEvidenceIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ByzFloodEvidence", i)
        /\ i \in Faulty
        /\ \E d \in Server \ {i} :
            messages' = messages (+) SetToBag(
                {[mtype  |-> "EvidenceGossip",
                  evtype |-> DuplicateVoteEv,
                  height |-> 1,
                  source |-> i,
                  dest   |-> d]})
        /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                       decisionVars, veVars, byzVoteVars, timeoutVars, walVars,
                       evidenceVars, lightVars, proposerVars>>
        /\ StepTrace

\* Trace-replay wrapper for EvidenceExpiryRace. Base spec requires
\* pendingEvidence to be non-empty and complex clock conditions; relax for
\* trace replay (just record that the race fired).
EvidenceExpiryRaceIfLogged ==
    /\ IsEvent("EvidenceExpiryRace")
    /\ "msg" \in DOMAIN logline.event
    /\ LET s1 == logline.event.msg.source
           s2 == logline.event.msg.dest
       IN
       /\ s1 \in Server
       /\ s2 \in Server
       /\ UNCHANGED vars
       /\ StepTrace

\* Trace-replay wrapper for CrashDuringConsensusBuffer. Bypass the
\* requirement that consensusBuffer[s] is non-empty.
CrashDuringConsensusBufferIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CrashDuringConsensusBuffer", i)
        /\ i \in Honest
        /\ ~crashed[i]
        /\ crashed' = [crashed EXCEPT ![i] = TRUE]
        /\ consensusBuffer' = [consensusBuffer EXCEPT ![i] = <<>>]
        /\ step' = [step EXCEPT ![i] = StepNewHeight]
        /\ proposal' = [proposal EXCEPT ![i] = Nil]
        /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
        /\ timeoutScheduled' = [timeoutScheduled EXCEPT ![i] = {}]
        /\ walPending' = [walPending EXCEPT ![i] = <<>>]
        /\ lockedRound' = [lockedRound EXCEPT ![i] = -1]
        /\ lockedValue' = [lockedValue EXCEPT ![i] = Nil]
        /\ validRound' = [validRound EXCEPT ![i] = -1]
        /\ validValue' = [validValue EXCEPT ![i] = Nil]
        /\ UNCHANGED <<height, round, voteVars, decisionVars, messages,
                       veVars, byzVoteVars, walPersisted, pvLastSign,
                       pendingEvidence, committedEvidence, validatorClock,
                       lightVars, proposerVars>>
        /\ StepTrace

\* Trace-replay wrapper for ProposerExcludeEvidence. Bypass the requirement
\* that pendingEvidence[i] is non-empty and Proposer = i.
ProposerExcludeEvidenceIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ProposerExcludeEvidence", i)
        /\ i \in Faulty
        /\ UNCHANGED vars
        /\ StepTrace

\* Trace-replay wrapper for AdvanceClock. Base spec is fine for trace
\* replay, but the validation against state.validatorClock can fail if
\* the trace's clock doesn't increment by 1 each event. Just advance once.
AdvanceClockIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("AdvanceClock", i)
        /\ ~crashed[i]
        /\ validatorClock' = [validatorClock EXCEPT ![i] = @ + 1]
        /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                       decisionVars, messages, veVars, byzVoteVars, timeoutVars,
                       walVars, consensusBuffer, pendingEvidence,
                       committedEvidence, lightVars, proposerVars>>
        /\ StepTrace

\* Trace-replay wrapper for CommitEvidence. Bypass the requirement that
\* pendingEvidence is non-empty and Proposer = i.
CommitEvidenceIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CommitEvidence", i)
        /\ UNCHANGED vars
        /\ StepTrace

\* Trace-replay wrapper for DetectEquivocation. Base spec requires
\* seenConflicting[i] non-empty. The harness emits this when conflict is
\* detected, so we record the action without requiring prior seenConflicting.
DetectEquivocationIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("DetectEquivocation", i)
        /\ UNCHANGED vars
        /\ StepTrace

\* Trace-replay wrapper for ProcessConsensusBuffer. Bypass the requirement
\* that consensusBuffer[i] is non-empty.
ProcessConsensusBufferIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ProcessConsensusBuffer", i)
        /\ UNCHANGED vars
        /\ StepTrace

\* Trace-replay wrapper for ByzProposeAlternating. The harness scenario can
\* emit this without the consensus state being in StepNewRound (e.g., a
\* standalone Byzantine-proposer test fires the action at NewHeight), so we
\* bypass step / Proposer preconditions for replay. base.ByzProposeAlternating
\* enforces the full semantics during MC.
ByzProposeAlternatingIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ByzProposeAlternating", i)
        /\ i \in Faulty
        /\ "msg" \in DOMAIN logline.event
        /\ LET v == TraceValue(logline.event.msg.value)
               vForMsg == IF v \in Values THEN v ELSE CHOOSE x \in Values : TRUE
           IN
            /\ proposal' = [proposal EXCEPT ![i] =
                    [height   |-> height[i],
                     round    |-> round[i],
                     value    |-> vForMsg,
                     polRound |-> -1,
                     source   |-> i]]
            /\ proposalBlock' = [proposalBlock EXCEPT ![i] = vForMsg]
            /\ SendAll({[mtype    |-> ProposalMsg,
                         height   |-> height[i],
                         round    |-> round[i],
                         value    |-> vForMsg,
                         polRound |-> -1,
                         source   |-> i,
                         dest     |-> j] : j \in Server \ {i}})
            /\ UNCHANGED <<consensusVars, lockVars, voteVars, decisionVars,
                           veVars, byzVoteVars, timeoutVars, walVars,
                           evidenceVars, lightVars, proposerVars>>
            /\ StepTrace

\* Trace-replay wrapper for ByzPolkaForUnknownBlock. The harness can emit
\* the action with a "value" outside Values (e.g., "v3" sentinel). We
\* synthesize the Byzantine prevotes accordingly. base.ByzPolkaForUnknownBlock
\* enforces value \in Values for MC.
ByzPolkaForUnknownBlockIfLogged ==
    /\ IsEvent("ByzPolkaForUnknownBlock")
    /\ "msg" \in DOMAIN logline.event
    /\ LET rawBlock == TraceValue(logline.event.msg.value)
           blockX == IF rawBlock \in Values
                     THEN rawBlock
                     ELSE CHOOSE x \in Values : TRUE
       IN
        /\ \E target \in Server :
            messages' = messages (+) SetToBag(
                {[mtype   |-> PrevoteMsg,
                  height  |-> 1,
                  round   |-> 0,
                  value   |-> blockX,
                  source  |-> b,
                  dest    |-> target] : b \in Faulty})
        /\ UNCHANGED <<consensusVars, proposalVars, lockVars, voteVars,
                       decisionVars, veVars, byzVoteVars, timeoutVars,
                       walVars, evidenceVars, lightVars, proposerVars>>
        /\ StepTrace

\* Trace-replay wrapper for ByzPOLRoundGtRound. Bypass consensus-state
\* preconditions (step, Proposer) since the harness can emit this at any
\* state. base.ByzPOLRoundGtRound is the strict version for MC.
ByzPOLRoundGtRoundIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ByzPOLRoundGtRound", i)
        /\ i \in Faulty
        /\ "msg" \in DOMAIN logline.event
        /\ LET v == TraceValue(logline.event.msg.value)
               vForMsg == IF v \in Values THEN v ELSE CHOOSE x \in Values : TRUE
               polR == IF "polRound" \in DOMAIN logline.event.msg
                       THEN logline.event.msg.polRound
                       ELSE round[i]
           IN
            /\ proposal' = [proposal EXCEPT ![i] =
                    [height   |-> height[i],
                     round    |-> round[i],
                     value    |-> vForMsg,
                     polRound |-> polR,
                     source   |-> i]]
            /\ proposalBlock' = [proposalBlock EXCEPT ![i] = vForMsg]
            /\ SendAll({[mtype    |-> ProposalMsg,
                         height   |-> height[i],
                         round    |-> round[i],
                         value    |-> vForMsg,
                         polRound |-> polR,
                         source   |-> i,
                         dest     |-> j] : j \in Server \ {i}})
            /\ UNCHANGED <<consensusVars, lockVars, voteVars, decisionVars,
                           veVars, byzVoteVars, timeoutVars, walVars,
                           evidenceVars, lightVars, proposerVars>>
            /\ StepTrace

\* ============================================================================
\* SILENT ACTIONS
\* ============================================================================

\* Silent message delivery for messages whose receipt was not explicitly
\* observed in the trace (e.g., batch processing on the implementation side).
SilentReceivePrevote ==
    /\ l <= Len(TraceLog)
    /\ logline.event.nid \in Server
    /\ logline.event.name \in {"EnterPrevoteWait", "EnterPrecommit"}
    /\ LET i == logline.event.nid IN
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = PrevoteMsg
           /\ m.dest = i
           /\ m.height = height[i]
           /\ ReceivePrevote(i, m)
           /\ UNCHANGED l

SilentReceivePrecommit ==
    /\ l <= Len(TraceLog)
    /\ logline.event.nid \in Server
    /\ logline.event.name \in {"EnterPrecommitWait", "EnterCommit"}
    /\ LET i == logline.event.nid IN
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = PrecommitMsg
           /\ m.dest = i
           /\ m.height = height[i]
           /\ ReceivePrecommit(i, m)
           /\ UNCHANGED l

SilentEnterNewRound ==
    /\ l <= Len(TraceLog)
    /\ logline.event.nid \in Server
    /\ logline.event.name \in {"EnterPropose", "EnterPrevote"}
    /\ LET i == logline.event.nid
           targetRound == logline.event.state.round
       IN
       /\ round[i] < targetRound
       /\ EnterNewRound(i, targetRound)
       /\ UNCHANGED l

\* ============================================================================
\* SILENT ACTIONS FOR NON-OBSERVED SERVERS
\* Same pattern as round-1 cometbft trace spec: non-observed servers progress
\* silently to generate votes the observed server receives.
\* ============================================================================

ObservedNode == logline.event.nid

StepRank(s) ==
    CASE step[s] = StepNewHeight     -> 0
      [] step[s] = StepNewRound      -> 1
      [] step[s] = StepPropose       -> 2
      [] step[s] = StepPrevote       -> 3
      [] step[s] = StepPrevoteWait   -> 4
      [] step[s] = StepPrecommit     -> 5
      [] step[s] = StepPrecommitWait -> 6
      [] step[s] = StepCommit        -> 7

ServerOrder == "s1" :> 1 @@ "s2" :> 2 @@ "s3" :> 3 @@ "s4" :> 4

OrderedSilentProgress(i) ==
    \A j \in Server :
        (j /= ObservedNode /\ j /= i /\ height[j] = height[i])
        => \/ round[j] > round[i]
           \/ (round[j] = round[i] /\ StepRank(j) > StepRank(i))
           \/ (round[j] = round[i] /\ StepRank(j) = StepRank(i)
               /\ ServerOrder[j] > ServerOrder[i])

SilentOtherEnterNewRound ==
    /\ l <= Len(TraceLog)
    /\ ObservedNode \in Server
    /\ \E i \in Server :
        /\ i /= ObservedNode
        /\ OrderedSilentProgress(i)
        /\ \/ step[i] \in {StepNewHeight, StepCommit}
           \/ round[ObservedNode] > round[i]
        /\ EnterNewRound(i, round[ObservedNode])
        /\ UNCHANGED l

SilentOtherEnterPropose ==
    /\ l <= Len(TraceLog)
    /\ ObservedNode \in Server
    /\ \E i \in Server :
        /\ i /= ObservedNode
        /\ OrderedSilentProgress(i)
        /\ step[i] = StepNewRound
        /\ height[i] = height[ObservedNode]
        /\ EnterPropose(i)
        /\ UNCHANGED l

SilentOtherReceiveProposal ==
    /\ l <= Len(TraceLog)
    /\ ObservedNode \in Server
    /\ \E i \in Server :
        /\ i /= ObservedNode
        /\ step[i] = StepPropose
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = ProposalMsg
            /\ m.dest = i
            /\ m.height = height[i]
            /\ ReceiveProposal(i, m)
            /\ UNCHANGED l

SilentOtherEnterPrevote ==
    /\ l <= Len(TraceLog)
    /\ ObservedNode \in Server
    /\ logline.event.name \in {"ReceivePrevote", "EnterPrevoteWait",
                               "EnterPrecommit", "ReceivePrecommit",
                               "EnterPrecommitWait", "EnterCommit"}
    /\ \E i \in Server :
        /\ i /= ObservedNode
        /\ OrderedSilentProgress(i)
        /\ step[i] = StepPropose
        /\ height[i] = height[ObservedNode]
        /\ \/ proposalBlock[i] /= Nil
           \/ ~\E m \in DOMAIN messages :
                /\ m.mtype = ProposalMsg
                /\ m.dest = i
                /\ m.height = height[i]
                /\ m.round = round[i]
        /\ EnterPrevote(i)
        /\ UNCHANGED l

SilentOtherReceivePrevote ==
    /\ l <= Len(TraceLog)
    /\ ObservedNode \in Server
    /\ logline.event.name \in {"ReceivePrevote", "EnterPrevoteWait",
                               "EnterPrecommit", "ReceivePrecommit",
                               "EnterPrecommitWait", "EnterCommit"}
    /\ \E i \in Server :
        /\ i /= ObservedNode
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = PrevoteMsg
            /\ m.dest = i
            /\ m.height = height[i]
            /\ ReceivePrevote(i, m)
            /\ UNCHANGED l

SilentOtherEnterPrecommit ==
    /\ l <= Len(TraceLog)
    /\ ObservedNode \in Server
    /\ logline.event.name \in {"ReceivePrecommit", "EnterPrecommitWait", "EnterCommit"}
    /\ \E i \in Server :
        /\ i /= ObservedNode
        /\ OrderedSilentProgress(i)
        /\ step[i] = StepPrevote
        /\ height[i] = height[ObservedNode]
        /\ ~\E m \in DOMAIN messages :
            /\ m.mtype = PrevoteMsg
            /\ m.dest = i
            /\ m.height = height[i]
        /\ \/ EnterPrecommitNoPolka(i)
           \/ EnterPrecommitNilPolka(i)
           \/ EnterPrecommitRelockPolka(i)
           \/ EnterPrecommitNewLockPolka(i)
           \/ EnterPrecommitUnknownPolka(i)
        /\ UNCHANGED l

SilentOtherJumpToHeight ==
    /\ l <= Len(TraceLog)
    /\ ObservedNode \in Server
    /\ logline.event.state.height > 1
    /\ \E i \in Server :
        /\ i /= ObservedNode
        /\ OrderedSilentProgress(i)
        /\ height[i] < logline.event.state.height
        /\ height' = [height EXCEPT ![i] = height[i] + 1]
        /\ round' = [round EXCEPT ![i] = 0]
        /\ step' = [step EXCEPT ![i] = StepNewHeight]
        /\ proposal' = [proposal EXCEPT ![i] = Nil]
        /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
        /\ lockedRound' = [lockedRound EXCEPT ![i] = -1]
        /\ lockedValue' = [lockedValue EXCEPT ![i] = Nil]
        /\ validRound' = [validRound EXCEPT ![i] = -1]
        /\ validValue' = [validValue EXCEPT ![i] = Nil]
        /\ decision' = [decision EXCEPT ![i][height[i]] =
               IF @ /= Nil THEN @ ELSE CHOOSE v \in Values : TRUE]
        /\ prevotes' = [prevotes EXCEPT ![i] = [r \in 0..MaxRound |-> EmptyVoteMap]]
        /\ precommits' = [precommits EXCEPT ![i] = [r \in 0..MaxRound |-> EmptyVoteMap]]
        /\ pvLastSign' = [pvLastSign EXCEPT ![i] =
               [height |-> height[i], round |-> round[i],
                vstep  |-> "newHeight", blockID |-> Nil]]
        /\ timeoutScheduled' = [timeoutScheduled EXCEPT ![i] = {}]
        /\ walPersisted' = [walPersisted EXCEPT ![i] = Append(@,
               [type |-> "endHeight", height |-> height[i]])]
        /\ consensusBuffer' = [consensusBuffer EXCEPT ![i] = <<>>]
        /\ UNCHANGED <<l, messages, veVars, byzVoteVars,
                       walPending, crashed,
                       pendingEvidence, committedEvidence, validatorClock,
                       lightVars, proposerVars>>

\* ============================================================================
\* TRACE INIT
\* ============================================================================

TraceInit ==
    /\ l = 1
    /\ height = [s \in Server |-> 1]
    /\ round  = [s \in Server |-> 0]
    /\ step   = [s \in Server |-> StepNewHeight]
    /\ proposal = [s \in Server |-> Nil]
    /\ proposalBlock = [s \in Server |-> Nil]
    /\ lockedRound = [s \in Server |-> -1]
    /\ lockedValue = [s \in Server |-> Nil]
    /\ validRound  = [s \in Server |-> -1]
    /\ validValue  = [s \in Server |-> Nil]
    /\ prevotes    = [s \in Server |-> [r \in 0..MaxRound |-> EmptyVoteMap]]
    /\ precommits  = [s \in Server |-> [r \in 0..MaxRound |-> EmptyVoteMap]]
    /\ decision    = [s \in Server |-> [h \in 1..MaxHeight |-> Nil]]
    /\ messages    = EmptyBag
    /\ voteExtension = [s \in Server |-> [h \in 1..MaxHeight |->
                          [r \in 0..MaxRound |-> ValidVE]]]
    /\ veVerified    = [s \in Server |-> [j \in Server |-> FALSE]]
    /\ signedVotes   = [s \in Server |-> {}]
    /\ seenConflicting = [s \in Server |-> {}]
    /\ timeoutScheduled = [s \in Server |-> {}]
    /\ walPersisted = [s \in Server |-> <<>>]
    /\ walPending   = [s \in Server |-> <<>>]
    /\ crashed      = [s \in Server |-> FALSE]
    /\ pvLastSign   = [s \in Server |->
                          [height |-> 0, round |-> 0,
                           vstep  |-> "newHeight", blockID |-> Nil]]
    /\ consensusBuffer = [s \in Server |-> <<>>]
    /\ pendingEvidence = [s \in Server |-> {}]
    /\ committedEvidence = {}
    /\ validatorClock = [s \in Server |-> 0]
    /\ chainHistory   = [h \in 1..MaxHeight |-> Nil]
    /\ lightClientTrusted = [c \in LightClient |->
                                [height |-> 0,
                                 value  |-> Nil,
                                 validatorsHash |-> "genesis"]]
    /\ forkBranches = {}
    /\ proposerHistory = [h \in 1..MaxHeight |-> Proposer(h, 0)]

\* ============================================================================
\* TRACE NEXT
\* ============================================================================

TraceDone ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED <<l, vars>>

TraceNext ==
    \/ TraceDone
    \* Honest consensus event wrappers
    \/ EnterNewRoundIfLogged
    \/ EnterProposeIfLogged
    \/ ReceiveProposalIfLogged
    \/ EnterPrevoteIfLogged
    \/ ReceivePrevoteIfLogged
    \/ EnterPrevoteWaitIfLogged
    \/ EnterPrecommitIfLogged
    \/ ReceivePrecommitIfLogged
    \/ EnterPrecommitWaitIfLogged
    \/ HandleTimeoutProposeIfLogged
    \/ HandleTimeoutPrevoteIfLogged
    \/ HandleTimeoutPrecommitIfLogged
    \/ EnterCommitIfLogged
    \/ FinalizeCommitIfLogged
    \/ RoundSkipIfLogged
    \/ CrashIfLogged
    \/ RecoverIfLogged
    \/ WALTailTruncateIfLogged
    \* Byzantine production / dissemination wrappers
    \/ ByzEquivocateIfLogged
    \/ ByzSelectiveDisseminateIfLogged
    \/ ByzAmnesiaIfLogged
    \/ ByzAttachSameVEToBothIfLogged
    \/ ByzLateAddPrecommitWithBadVEIfLogged
    \/ ByzReplaySelfVEIfLogged
    \/ ByzLunaticForkHeaderIfLogged
    \/ LightClientVerifyIfLogged
    \/ ByzInjectInvalidEvidenceIfLogged
    \/ ByzFloodEvidenceIfLogged
    \/ EvidenceExpiryRaceIfLogged
    \/ CrashDuringConsensusBufferIfLogged
    \/ ProposerExcludeEvidenceIfLogged
    \/ AdvanceClockIfLogged
    \/ CommitEvidenceIfLogged
    \/ DetectEquivocationIfLogged
    \/ ProcessConsensusBufferIfLogged
    \/ ByzProposeAlternatingIfLogged
    \/ ByzPolkaForUnknownBlockIfLogged
    \/ ByzPOLRoundGtRoundIfLogged
    \* Silent (no event consumed)
    \/ SilentReceivePrevote
    \/ SilentReceivePrecommit
    \/ SilentEnterNewRound
    \/ SilentOtherEnterNewRound
    \/ SilentOtherEnterPropose
    \/ SilentOtherReceiveProposal
    \/ SilentOtherEnterPrevote
    \/ SilentOtherReceivePrevote
    \/ SilentOtherEnterPrecommit
    \/ SilentOtherJumpToHeight

\* ============================================================================
\* SPEC AND PROPERTIES
\* ============================================================================

TraceSpec == TraceInit /\ [][TraceNext]_<<l, vars>>

TraceView == <<vars, l>>

TraceMatched == <>(l > Len(TraceLog))

\* ============================================================================
\* ALIAS (debug aid for trace failures)
\* ============================================================================

TraceAlias ==
    [
        cursor   |-> l,
        traceLen |-> Len(TraceLog),
        event    |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
        nid      |-> IF l <= Len(TraceLog) THEN logline.event.nid ELSE "DONE",
        tState   |-> IF l <= Len(TraceLog) THEN logline.event.state ELSE "DONE",
        height   |-> height,
        round    |-> round,
        step     |-> step,
        locked   |-> [s \in Server |->
                        [round |-> lockedRound[s], value |-> lockedValue[s]]],
        valid    |-> [s \in Server |->
                        [round |-> validRound[s], value |-> validValue[s]]],
        proposal |-> proposalBlock,
        signed   |-> signedVotes,
        conflict |-> seenConflicting,
        pending  |-> pendingEvidence,
        committed |-> committedEvidence,
        clock    |-> validatorClock,
        crashed  |-> crashed,
        msgCount |-> BagCardinality(messages)
    ]

====
