--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation specification for CometBFT consensus.
 *
 * Replays implementation execution traces (NDJSON) against the base spec,
 * verifying that every observed state transition is reachable and consistent.
 *
 * Category A (distributed / message-passing): uses a single linear cursor `l`.
 *
 * Trace format (NDJSON lines, tag="trace"):
 *   { "tag": "trace", "event": {
 *       "name": "<action>", "nid": "<server>",
 *       "state": { "height", "round", "step", "lockedRound", "lockedValue",
 *                  "validRound", "validValue" },
 *       "msg":   { "source", "dest", "value", "round", "ve" },  // optional
 *       "ext":   { "verified", "bypassed" }                     // optional, Family 1
 *   }}
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

VARIABLE l          \* Current position in TraceLog (1-indexed)

traceVars == <<l>>
allVars   == <<vars, l>>

logline == TraceLog[l]

\* ============================================================================
\* SERVER EXTRACTION FROM TRACE
\* ============================================================================

TraceServer == TLCEval(
    UNION {
        ({TraceLog[k].event.nid}
        \cup (IF "msg" \in DOMAIN TraceLog[k].event
              THEN LET m == TraceLog[k].event.msg IN
                   ({m.source}
                    \cup (IF "dest" \in DOMAIN m THEN {m.dest} ELSE {})) \ {"", "nil"}
              ELSE {}))
        : k \in 1..Len(TraceLog)})

ASSUME TraceServer /= {}
ASSUME TraceServer \subseteq Server

\* ============================================================================
\* VALUE MAPPING
\* ============================================================================

TraceValue(v) ==
    IF v = "" \/ v = "null" \/ v = "nil" THEN Nil ELSE v

\* ============================================================================
\* STEP MAPPING
\* ============================================================================

StepMapping ==
    "NewHeight"      :> StepNewHeight   @@
    "NewRound"       :> StepNewRound    @@
    "Propose"        :> StepPropose     @@
    "Prevote"        :> StepPrevote     @@
    "PrevoteWait"    :> StepPrevoteWait @@
    "Precommit"      :> StepPrecommit   @@
    "PrecommitWait"  :> StepPrecommitWait @@
    "Commit"         :> StepCommit

\* ============================================================================
\* PROPOSER EXTRACTION FROM TRACE
\* ============================================================================

\* Extract proposer for each (height, round) from trace EnterPropose events.
TraceProposerMap == TLCEval(
    LET propEvents == SelectSeq(TraceLog, LAMBDA x :
            /\ x.event.name = "EnterPropose"
            /\ "msg" \in DOMAIN x.event)
        rcvEvents  == SelectSeq(TraceLog, LAMBDA x :
            /\ x.event.name = "ReceiveProposal"
            /\ "msg" \in DOMAIN x.event)
        propSeq == [k \in 1..Len(propEvents) |->
                    [height |-> propEvents[k].event.state.height,
                     round  |-> propEvents[k].event.state.round,
                     source |-> propEvents[k].event.nid]]
        rcvSeq  == [k \in 1..Len(rcvEvents) |->
                    [height |-> rcvEvents[k].event.state.height,
                     round  |-> rcvEvents[k].event.state.round,
                     source |-> rcvEvents[k].event.msg.source]]
    IN  [k \in 1..(Len(propSeq) + Len(rcvSeq)) |->
             IF k <= Len(propSeq) THEN propSeq[k]
             ELSE rcvSeq[k - Len(propSeq)]])

TraceProposer(h, r) ==
    LET matches == {k \in 1..Len(TraceProposerMap) :
                     /\ TraceProposerMap[k].height = h
                     /\ TraceProposerMap[k].round  = r}
    IN IF matches /= {}
       THEN TraceProposerMap[CHOOSE k \in matches : TRUE].source
       ELSE CHOOSE s \in Server : TRUE   \* fallback (no trace info)

TraceChooseValue(i) ==
    LET propEvents == SelectSeq(TraceLog, LAMBDA x :
            /\ x.event.name = "EnterPropose"
            /\ x.event.nid = i
            /\ "msg" \in DOMAIN x.event
            /\ x.event.state.height = height[i]
            /\ x.event.state.round  = round[i])
        rcvEvents  == SelectSeq(TraceLog, LAMBDA x :
            /\ x.event.name = "ReceiveProposal"
            /\ "msg" \in DOMAIN x.event
            /\ x.event.state.height = height[i]
            /\ x.event.state.round  = round[i])
    IN IF Len(propEvents) > 0
       THEN TraceValue(propEvents[1].event.msg.value)
       ELSE IF Len(rcvEvents) > 0
       THEN TraceValue(rcvEvents[1].event.msg.value)
       ELSE CHOOSE val \in Values : TRUE

\* Identity mapping: each block hash maps to itself (no collisions).
\* These traces don't exercise the evidence hash-collision family.
TraceHashAliases == [bh \in BlockHash |-> bh]

\* String-valued constant sets (trace JSON uses strings, not TLC model values)
TraceServerConst    == {"s1", "s2", "s3"}
TraceFaultyConst    == {"s3"}
TraceValuesConst    == {"v1", "v2"}
TraceBlockHashConst == {"bh1", "bh2", "bh3"}
TraceSyncPeersConst == {"s1", "s2", "s3"}

\* ============================================================================
\* EVENT PREDICATES
\* ============================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.event.nid = i

IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ "msg" \in DOMAIN logline.event
    /\ logline.event.msg.source = from
    /\ logline.event.msg.dest   = to

\* ============================================================================
\* POST-STATE VALIDATION
\* ============================================================================

\* Strong validation: height + round + step match trace state
ValidatePostState(i) ==
    /\ height'[i] = logline.event.state.height
    /\ round'[i]  = logline.event.state.round
    /\ step'[i]   = StepMapping[logline.event.state.step]

\* Weak validation: height + round only (for async events where step may lead)
ValidatePostStateWeak(i) ==
    /\ height'[i] = logline.event.state.height
    /\ round'[i]  = logline.event.state.round

\* Lock state validation
ValidateLockedState(i) ==
    /\ lockedRound'[i] = logline.event.state.lockedRound
    /\ lockedValue'[i] = TraceValue(logline.event.state.lockedValue)

\* Valid state validation
ValidateValidState(i) ==
    /\ validRound'[i] = logline.event.state.validRound
    /\ validValue'[i] = TraceValue(logline.event.state.validValue)

\* Extension verification validation (Family 1)
ValidateExtState(i, voter) ==
    IF "ext" \in DOMAIN logline.event
    THEN extABCIVerified'[i][voter][logline.event.state.height] =
             logline.event.ext.verified
    ELSE TRUE

\* ============================================================================
\* CURSOR ADVANCE
\* ============================================================================

StepTrace == l' = l + 1

\* ============================================================================
\* ACTION WRAPPERS (consume one trace event each)
\* ============================================================================

\* --- EnterNewRound ---
EnterNewRoundIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterNewRound", i)
        /\ LET r == logline.event.state.round IN
            /\ EnterNewRound(i, r)
            /\ ValidatePostState(i)
            /\ StepTrace

\* --- EnterPropose ---
EnterProposeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterPropose", i)
        /\ EnterPropose(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* --- ReceiveProposal ---
ReceiveProposalIfLogged ==
    \E i \in Server :
        /\ IsEvent("ReceiveProposal")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Self-proposal: proposer already has proposal from EnterPropose
              /\ logline.event.msg.source = i
              /\ proposalBlock[i] /= Nil
              /\ UNCHANGED vars
              /\ ValidatePostStateWeak(i)
              /\ StepTrace
           \/ \* Normal: receive from another server
              /\ logline.event.msg.source /= i
              /\ \E m \in DOMAIN messages :
                  /\ m.mtype = ProposalMsg
                  /\ m.source = logline.event.msg.source
                  /\ m.dest = i
                  /\ ReceiveProposal(i, m)
                  /\ ValidatePostStateWeak(i)
                  /\ StepTrace

\* --- EnterPrevote ---
EnterPrevoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterPrevote", i)
        /\ EnterPrevote(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* --- ReceivePrevote ---
ReceivePrevoteIfLogged ==
    \E i \in Server :
        /\ IsEvent("ReceivePrevote")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Self-prevote already recorded in EnterPrevote
              /\ logline.event.msg.source = i
              /\ step[i] = StepPrevote
              /\ UNCHANGED vars
              /\ ValidatePostStateWeak(i)
              /\ StepTrace
           \/ /\ logline.event.msg.source /= i
              /\ LET traceVoteVal ==
                         LET raw == logline.event.msg.value
                         IN IF raw = "nil" THEN NilVote ELSE raw
                 IN
                 \E m \in DOMAIN messages :
                    /\ m.mtype = PrevoteMsg
                    /\ m.source = logline.event.msg.source
                    /\ m.dest = i
                    /\ m.height = height[i]
                    /\ prevotes[i][m.round][m.source] = Nil
                    /\ prevotes' = [prevotes EXCEPT ![i][m.round][m.source] = traceVoteVal]
                    /\ Discard(m)
                    /\ LET hasPolka == \E v \in Values : HasPrevoteQuorum(i, m.round, v)
                           polkaVal == IF hasPolka
                                       THEN CHOOSE v \in Values : HasPrevoteQuorum(i, m.round, v)
                                       ELSE Nil
                       IN
                       IF /\ hasPolka /\ lockedValue[i] /= Nil
                          /\ lockedRound[i] < m.round /\ m.round <= round[i]
                          /\ lockedValue[i] /= polkaVal
                       THEN /\ lockedRound' = [lockedRound EXCEPT ![i] = -1]
                            /\ lockedValue' = [lockedValue EXCEPT ![i] = Nil]
                            /\ IF polkaVal /= Nil /\ validRound[i] < m.round
                                  /\ m.round = round[i] /\ proposalBlock[i] = polkaVal
                               THEN /\ validRound' = [validRound EXCEPT ![i] = m.round]
                                    /\ validValue' = [validValue EXCEPT ![i] = polkaVal]
                               ELSE UNCHANGED <<validRound, validValue>>
                       ELSE IF hasPolka /\ polkaVal /= Nil /\ validRound[i] < m.round
                               /\ m.round = round[i] /\ proposalBlock[i] = polkaVal
                            THEN /\ validRound' = [validRound EXCEPT ![i] = m.round]
                                 /\ validValue' = [validValue EXCEPT ![i] = polkaVal]
                                 /\ UNCHANGED <<lockedRound, lockedValue>>
                            ELSE UNCHANGED lockVars
                    /\ UNCHANGED <<consensusVars, proposalVars, precommits, decisionVars,
                                   extVerifyVars, doubleSignVars, evidenceVars,
                                   blocksyncVars, walVars>>
                    /\ ValidatePostStateWeak(i)
                    /\ StepTrace

\* --- EnterPrevoteWait ---
EnterPrevoteWaitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterPrevoteWait", i)
        /\ EnterPrevoteWait(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* --- EnterPrecommit (all 5 paths) ---
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

\* --- ReceivePrecommit (consensus path, Family 1) ---
\* Captures whether VerifyVoteExtension was called and its result.
ReceivePrecommitIfLogged ==
    \E i \in Server :
        /\ IsEvent("ReceivePrecommit")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Self-precommit: already recorded in EnterPrecommit*
              /\ logline.event.msg.source = i
              /\ step[i] = StepPrecommit
              /\ UNCHANGED vars
              /\ ValidatePostStateWeak(i)
              /\ StepTrace
           \/ /\ logline.event.msg.source /= i
              /\ LET src      == logline.event.msg.source
                     rawVal   == logline.event.msg.value
                     traceVal == IF rawVal = "nil" THEN NilVote ELSE rawVal
                     isNil    == (traceVal = NilVote)
                     newVe    == IF /\ "ext" \in DOMAIN logline.event
                                    /\ logline.event.ext.verified
                                 THEN ValidExt ELSE NoExt
                     veValid  == (newVe = ValidExt)
                 IN
                 \E m \in DOMAIN messages :
                    /\ m.mtype = PrecommitMsg
                    /\ m.source = src
                    /\ m.dest = i
                    /\ m.height = height[i]
                    /\ precommits[i][m.round][src] = Nil
                    /\ Discard(m)
                    /\ IF ~isNil
                       THEN \* Non-nil precommit: full ext verification path
                            /\ extABCIVerified' = [extABCIVerified EXCEPT
                                   ![i][src][m.height] = veValid]
                            /\ IF veValid
                               THEN precommits' = [precommits EXCEPT
                                        ![i][m.round][src] = traceVal]
                               ELSE UNCHANGED precommits
                            /\ UNCHANGED selfExtBypassed
                       ELSE \* Nil precommit: accept without ABCI check
                            /\ precommits' = [precommits EXCEPT
                                   ![i][m.round][src] = NilVote]
                            /\ UNCHANGED <<extABCIVerified, selfExtBypassed>>
                    /\ UNCHANGED <<consensusVars, proposalVars, lockVars, prevotes,
                                   decisionVars, voteExt, lightClientAccepted,
                                   blocksyncAccepted, doubleSignVars, evidenceVars,
                                   blocksyncVars, walVars>>
                    /\ ValidateExtState(i, src)
                    /\ ValidatePostStateWeak(i)
                    /\ StepTrace

\* --- EnterPrecommitWait ---
EnterPrecommitWaitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterPrecommitWait", i)
        /\ step[i] = StepPrecommit
        /\ UNCHANGED vars
        /\ StepTrace

\* --- Timeout handlers (pre-state events, actual change in subsequent action) ---
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
        /\ step[i] \in {StepPrecommit, StepPrecommitWait}
        /\ UNCHANGED vars
        /\ StepTrace

\* --- EnterCommit ---
EnterCommitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterCommit", i)
        /\ EnterCommit(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* --- FinalizeCommit ---
FinalizeCommitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("FinalizeCommit", i)
        /\ FinalizeCommit(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* --- RoundSkip ---
RoundSkipIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("RoundSkip", i)
        /\ \/ /\ RoundSkipPrevote(i)
              /\ ValidatePostState(i)
              /\ StepTrace
           \/ /\ RoundSkipPrecommit(i)
              /\ ValidatePostState(i)
              /\ StepTrace

\* --- Crash ---
CrashIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Crash", i)
        /\ Crash(i)
        /\ StepTrace

\* --- Recover ---
RecoverIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Recover", i)
        /\ Recover(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* --- Family 1: AcceptCommitLightClient ---
AcceptCommitLightClientIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("AcceptCommitLightClient", i)
        /\ "state" \in DOMAIN logline.event
        /\ AcceptCommitLightClient(i, logline.event.state.height)
        /\ StepTrace

\* --- Family 1: AcceptCommitBlockSync ---
AcceptCommitBlockSyncIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("AcceptCommitBlockSync", i)
        /\ "state" \in DOMAIN logline.event
        /\ AcceptCommitBlockSync(i, logline.event.state.height)
        /\ StepTrace

\* --- Family 2: CheckDoubleSigningRisk ---
CheckDoubleSigningRiskIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CheckDoubleSigningRisk", i)
        /\ "state" \in DOMAIN logline.event
        /\ CheckDoubleSigningRisk(i, logline.event.state.height)
        /\ StepTrace

\* --- Family 3: SubmitLightClientEvidence ---
SubmitLightClientEvidenceIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SubmitLightClientEvidence", i)
        /\ "evidence" \in DOMAIN logline.event
        /\ SubmitLightClientEvidence(
               i,
               logline.event.evidence.commonHeight,
               logline.event.evidence.conflictingBlockHash)
        /\ StepTrace

\* --- Family 4: SetPeerRange ---
SetPeerRangeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SetPeerRange", i)
        /\ "peer" \in DOMAIN logline.event
        /\ SetPeerRange(i, logline.event.peer.id, logline.event.peer.height)
        /\ StepTrace

\* --- Family 4: RemovePeer ---
RemovePeerIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("RemovePeer", i)
        /\ "peer" \in DOMAIN logline.event
        /\ RemovePeer(i, logline.event.peer.id)
        /\ StepTrace

\* --- Family 4: CheckCaughtUp ---
CheckCaughtUpIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CheckCaughtUp", i)
        /\ CheckCaughtUp(i)
        /\ StepTrace

\* ============================================================================
\* SILENT ACTIONS (fire without consuming a trace event)
\* All must be tightly constrained to prevent state-space explosion.
\* ============================================================================

ObservedNode == logline.event.nid

\* Silent prevote delivery: needed when trace jumps to EnterPrevoteWait/EnterPrecommit
SilentReceivePrevote ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"EnterPrevoteWait", "EnterPrecommit"}
    /\ LET i == ObservedNode IN
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = PrevoteMsg
           /\ m.dest = i
           /\ m.height = height[i]
           /\ ReceivePrevote(i, m)
           /\ UNCHANGED l

\* Silent precommit delivery: needed before EnterPrecommitWait/EnterCommit
SilentReceivePrecommit ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"EnterPrecommitWait", "EnterCommit"}
    /\ LET i == ObservedNode IN
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = PrecommitMsg
           /\ m.dest = i
           /\ m.height = height[i]
           /\ ReceivePrecommitConsensus(i, m)
           /\ UNCHANGED l

\* Silent round advance for observed server
SilentEnterNewRound ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"EnterPropose", "EnterPrevote"}
    /\ LET i == ObservedNode IN
       /\ round[i] < logline.event.state.round
       /\ EnterNewRound(i, logline.event.state.round)
       /\ UNCHANGED l

\* Ordering helper for non-observed server silent progress
StepRank(s) ==
    CASE step[s] = StepNewHeight     -> 0
      [] step[s] = StepNewRound      -> 1
      [] step[s] = StepPropose       -> 2
      [] step[s] = StepPrevote       -> 3
      [] step[s] = StepPrevoteWait   -> 4
      [] step[s] = StepPrecommit     -> 5
      [] step[s] = StepPrecommitWait -> 6
      [] step[s] = StepCommit        -> 7
      [] OTHER                       -> 0

ServerOrder == "s1" :> 1 @@ "s2" :> 2 @@ "s3" :> 3

OrderedSilentProgress(i) ==
    \A j \in Server :
        (j /= ObservedNode /\ j /= i /\ height[j] = height[i]) =>
            \/ round[j] > round[i]
            \/ (round[j] = round[i] /\ StepRank(j) > StepRank(i))
            \/ (round[j] = round[i] /\ StepRank(j) = StepRank(i)
                /\ ServerOrder[j] > ServerOrder[i])

\* Silent non-observed server: enter new round
SilentOtherEnterNewRound ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ i /= ObservedNode
        /\ OrderedSilentProgress(i)
        /\ \/ step[i] \in {StepNewHeight, StepCommit}
           \/ round[ObservedNode] > round[i]
        /\ EnterNewRound(i, round[ObservedNode])
        /\ UNCHANGED l

\* Silent non-observed server: enter propose
SilentOtherEnterPropose ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ i /= ObservedNode
        /\ OrderedSilentProgress(i)
        /\ step[i] = StepNewRound
        /\ height[i] = height[ObservedNode]
        /\ round[i] = round[ObservedNode]
        /\ EnterPropose(i)
        /\ UNCHANGED l

\* Silent non-observed server: receive proposal
SilentOtherReceiveProposal ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ i /= ObservedNode
        /\ step[i] = StepPropose
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = ProposalMsg
            /\ m.dest = i
            /\ m.height = height[i]
            /\ ReceiveProposal(i, m)
            /\ UNCHANGED l

\* Silent non-observed server: enter prevote (generates votes for observed node)
SilentOtherEnterPrevote ==
    /\ l <= Len(TraceLog)
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

\* Silent non-observed server: receive prevotes from peers
SilentOtherReceivePrevote ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"EnterPrevoteWait", "EnterPrecommit",
                                "ReceivePrecommit", "EnterPrecommitWait", "EnterCommit"}
    /\ \E i \in Server :
        /\ i /= ObservedNode
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = PrevoteMsg
            /\ m.dest = i
            /\ m.height = height[i]
            /\ ReceivePrevote(i, m)
            /\ UNCHANGED l

\* Silent non-observed server: enter precommit (generates precommit votes)
SilentOtherEnterPrecommit ==
    /\ l <= Len(TraceLog)
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

\* Silent non-observed server: jump to target height (atomic height advance)
SilentOtherJumpToHeight ==
    /\ l <= Len(TraceLog)
    /\ logline.event.state.height > 1
    /\ \E i \in Server :
        /\ i /= ObservedNode
        /\ OrderedSilentProgress(i)
        /\ height[i] < logline.event.state.height
        /\ height'      = [height      EXCEPT ![i] = height[i] + 1]
        /\ round'       = [round       EXCEPT ![i] = 0]
        /\ step'        = [step        EXCEPT ![i] = StepNewHeight]
        /\ proposal'    = [proposal    EXCEPT ![i] = Nil]
        /\ proposalBlock' = [proposalBlock EXCEPT ![i] = Nil]
        /\ lockedRound' = [lockedRound EXCEPT ![i] = -1]
        /\ lockedValue' = [lockedValue EXCEPT ![i] = Nil]
        /\ validRound'  = [validRound  EXCEPT ![i] = -1]
        /\ validValue'  = [validValue  EXCEPT ![i] = Nil]
        /\ decision'    = [decision    EXCEPT ![i][height[i]] =
               IF @ /= Nil THEN @
               ELSE IF lockedValue[i] /= Nil THEN lockedValue[i]
               ELSE CHOOSE v \in Values : TRUE]
        /\ prevotes'    = [prevotes    EXCEPT ![i] = [r \in 0..MaxRound |-> EmptyVoteMap]]
        /\ precommits'  = [precommits  EXCEPT ![i] = [r \in 0..MaxRound |-> EmptyVoteMap]]
        /\ privvalLastSigned' = [privvalLastSigned EXCEPT ![i] =
               [height |-> height[i], round |-> round[i]]]
        /\ walEntries'  = [walEntries  EXCEPT ![i] = Append(@,
               [type |-> "endHeight", height |-> height[i]])]
        /\ UNCHANGED <<l, messages, extVerifyVars, crashed, evidenceVars, blocksyncVars,
                       walPresent, lookbackChecked>>

\* ============================================================================
\* TRACE INIT
\* ============================================================================

TraceInit ==
    /\ l = 1
    /\ height        = [s \in Server |-> 1]
    /\ round         = [s \in Server |-> 0]
    /\ step          = [s \in Server |-> StepNewHeight]
    /\ proposal      = [s \in Server |-> Nil]
    /\ proposalBlock = [s \in Server |-> Nil]
    /\ lockedRound   = [s \in Server |-> -1]
    /\ lockedValue   = [s \in Server |-> Nil]
    /\ validRound    = [s \in Server |-> -1]
    /\ validValue    = [s \in Server |-> Nil]
    /\ prevotes      = [s \in Server |-> [r \in 0..MaxRound |-> EmptyVoteMap]]
    /\ precommits    = [s \in Server |-> [r \in 0..MaxRound |-> EmptyVoteMap]]
    /\ decision      = [s \in Server |-> [h \in 1..MaxHeight |-> Nil]]
    /\ messages      = EmptyBag
    /\ voteExt            = [s \in Server |-> ValidExt]
    /\ extABCIVerified    = [s \in Server |-> [j \in Server |-> [h \in 1..MaxHeight |-> FALSE]]]
    /\ selfExtBypassed    = [s \in Server |-> [h \in 1..MaxHeight |-> FALSE]]
    /\ lightClientAccepted = [s \in Server |-> [h \in 1..MaxHeight |-> FALSE]]
    /\ blocksyncAccepted   = [s \in Server |-> [h \in 1..MaxHeight |-> FALSE]]
    /\ walPresent         = [s \in Server |-> TRUE]
    /\ lookbackChecked    = [s \in Server |-> [h \in 1..MaxHeight |-> FALSE]]
    /\ privvalLastSigned  = [s \in Server |-> Nil]
    /\ evidencePool  = [s \in Server |-> InitEvidencePool(s)]
    /\ hashCollision = FALSE
    /\ syncMode       = [s \in Server |-> CONSENSUS]
    /\ maxPeerHeight  = [s \in Server |-> 0]
    /\ peerRecords    = [s \in Server |-> [p \in SyncPeers |-> AbsentPeer]]
    /\ localSyncHeight = [s \in Server |-> 0]
    /\ walEntries = [s \in Server |-> <<>>]
    /\ crashed    = [s \in Server |-> FALSE]

\* ============================================================================
\* TRACE NEXT
\* ============================================================================

TraceDone ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED <<l, vars>>

TraceNext ==
    \* Stuttering after trace consumed
    \/ TraceDone
    \* Action wrappers
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
    \* Family 1 wrappers
    \/ AcceptCommitLightClientIfLogged
    \/ AcceptCommitBlockSyncIfLogged
    \* Family 2 wrappers
    \/ CheckDoubleSigningRiskIfLogged
    \* Family 3 wrappers
    \/ SubmitLightClientEvidenceIfLogged
    \* Family 4 wrappers
    \/ SetPeerRangeIfLogged
    \/ RemovePeerIfLogged
    \/ CheckCaughtUpIfLogged
    \* Silent actions
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

TraceSpec == TraceInit /\ [][TraceNext]_<<l, vars>> /\ WF_<<l, vars>>(TraceNext)

TraceView == <<vars, l>>

\* Property: entire trace was consumed
TraceMatched == <>(l > Len(TraceLog))

\* ============================================================================
\* ALIAS (for debugging trace validation failures)
\* ============================================================================

TraceAlias ==
    [
        cursor   |-> l,
        traceLen |-> Len(TraceLog),
        event    |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
        nid      |-> IF l <= Len(TraceLog) THEN logline.event.nid  ELSE "DONE",
        tState   |-> IF l <= Len(TraceLog) THEN logline.event.state ELSE "DONE",
        height   |-> height,
        round    |-> round,
        step     |-> step,
        locked   |-> [s \in Server |-> [round |-> lockedRound[s], value |-> lockedValue[s]]],
        valid    |-> [s \in Server |-> [round |-> validRound[s],  value |-> validValue[s]]],
        decision |-> decision,
        msgCount |-> BagCardinality(messages),
        crashed  |-> crashed,
        maxPH    |-> maxPeerHeight,
        hashCol  |-> hashCollision
    ]

====
