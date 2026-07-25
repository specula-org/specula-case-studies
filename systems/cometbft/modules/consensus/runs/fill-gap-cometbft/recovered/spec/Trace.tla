------------------------------- MODULE Trace -------------------------------
(*****************************************************************************)
(* Trace validation for the PBTS base spec (Category A — single linear        *)
(* NDJSON trace from one CometBFT consensus run).                             *)
(*                                                                           *)
(* The cursor l walks the recorded events; each wrapper matches one event,     *)
(* drives the corresponding base-spec transition, and validates that the       *)
(* captured post-state agrees with what the spec computes.  The Family-B       *)
(* payload we are validating is the PBTS *timely verdict*: every block         *)
(* prevote the implementation emitted (POLRound = -1) must satisfy the spec's   *)
(* IsTimely gate on the captured (recvTime, Timestamp); every nil prevote       *)
(* attributed to untimeliness must fail it.  This is the cross-check that       *)
(* types/proposal.go:97-107 + state.go:1406 are modeled faithfully.            *)
(*                                                                           *)
(* Fields the spec cannot derive from protocol state — the wall-clock-derived   *)
(* localClock, ProposalReceiveTime, and the proposer's chosen Timestamp — are   *)
(* taken from the trace (post preprocessing to the discrete Time domain, which  *)
(* must preserve the sign of each IsTimely inequality; see                      *)
(* instrumentation-spec.md).  Fields the spec DOES derive (step, lock, valid,   *)
(* decision, vote target) are computed from spec state and checked against the  *)
(* captured values in ValidatePostState.                                       *)
(*****************************************************************************)
EXTENDS base, Json, IOUtils, Sequences

VARIABLE l           \* trace cursor (1-based index into TraceLog)
traceVars == <<l>>
allVars   == <<vars, l>>

----------------------------------------------------------------------------
(* Trace loading.  Default to ../traces/trace.ndjson; override per-run with    *)
(* an IOEnv.JSON environment variable.                                         *)
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)
logline  == TraceLog[l]

(* Implementation validator-id strings -> spec model values.                  *)
NodeMap == ("s1" :> s1 @@ "s2" :> s2 @@ "s3" :> s3 @@ "s4" :> s4)
Node(str) == NodeMap[str]

----------------------------------------------------------------------------
(* Event predicates.                                                          *)
AtEnd   == l > Len(TraceLog)
IsEvent(e) == /\ ~AtEnd
              /\ logline.event = e

\* convenience: the node that produced the current event
EvNode == Node(logline.node)

----------------------------------------------------------------------------
(*                          ACTION WRAPPERS                                   *)
(* Each wrapper: (1) matches the event, (2) asserts the base-spec guard /       *)
(* logic on spec state, (3) updates spec vars, (4) ValidatePostState compares   *)
(* captured fields with the computed post-state, (5) advances l.               *)
----------------------------------------------------------------------------

(* StartRound — enterNewRound entry.  Resets cs.ProposalReceiveTime for the     *)
(* new round (recvTime := NilTime) and captures the local clock.               *)
TraceStartRound ==
    /\ IsEvent("StartRound")
    /\ LET s == EvNode
           r == logline.round
       IN /\ r \in Rounds
          /\ round'    = [round EXCEPT ![s] = r]
          /\ step'     = [step EXCEPT ![s] = "PROPOSE"]
          /\ clock'    = [clock EXCEPT ![s] = logline.clock]
          /\ recvTime' = [recvTime EXCEPT ![s] = NilTime]
          \* ValidatePostState
          /\ logline.step = "PROPOSE"
    /\ UNCHANGED <<lockedValue, lockedRound, validValue, validRound, decision,
                   proposals, prevotes, precommits, auxVars>>
    /\ l' = l + 1

(* Propose — proposer emits its proposal (decideProposal).  The proposal's      *)
(* Timestamp and POLRound are captured (an honest proposer's Timestamp is its   *)
(* clock; a faulty one is arbitrary).                                           *)
TracePropose ==
    /\ IsEvent("Propose")
    /\ LET s == EvNode
           r == logline.round
           t  == logline.propTime
           pr == logline.propPolRound
       IN /\ proposals' = proposals \cup
                {[src |-> s, round |-> r, time |-> t, polRound |-> pr]}
          /\ clock' = [clock EXCEPT ![s] = logline.clock]
          \* ValidatePostState: a re-proposal (pr >= 0) must reuse a block this
          \* node holds as ValidBlock; a fresh proposal (pr = -1) carries the
          \* proposer's local Timestamp.
          /\ (pr >= 0) => (validValue[s] = t /\ validRound[s] = pr)
    /\ UNCHANGED <<coreVars, recvTime, prevotes, precommits, auxVars>>
    /\ l' = l + 1

(* ReceiveProposal — defaultSetProposal records ProposalReceiveTime.           *)
TraceReceiveProposal ==
    /\ IsEvent("ReceiveProposal")
    /\ LET s == EvNode
           r == logline.round
       IN /\ recvTime[s] = NilTime
          /\ \E m \in ProposalsIn(r) :
                /\ m.time = logline.propTime
                /\ m.polRound = logline.propPolRound
          /\ recvTime' = [recvTime EXCEPT ![s] = logline.recvTime]
          /\ clock'    = [clock EXCEPT ![s] = logline.clock]
    /\ UNCHANGED <<coreVars, proposals, prevotes, precommits, auxVars>>
    /\ l' = l + 1

(* Prevote — defaultDoPrevote + signAddVote.  voteId >= 0 is a block prevote    *)
(* (id = the block's Timestamp); voteId = NilBlock is a nil prevote.            *)
(* The core Family-B check: a block prevote MUST satisfy the spec's GatePass    *)
(* (timely for POLRound = -1; local polka for POLRound >= 0).                   *)
TracePrevote ==
    /\ IsEvent("Prevote")
    /\ LET s  == EvNode
           r  == logline.round
           vid == logline.voteId
       IN /\ step[s] = "PROPOSE"
          /\ step' = [step EXCEPT ![s] = "PREVOTE"]
          /\ clock' = [clock EXCEPT ![s] = logline.clock]
          /\ prevotes' = prevotes \cup {[src |-> s, round |-> r, id |-> vid]}
          /\ IF vid # NilBlock
             THEN \* block prevote: the matching proposal must pass the gate
                  /\ \E m \in ProposalsIn(r) :
                        /\ m.time = vid
                        /\ GatePass(s, m)
                        /\ timelyBlocks' = IF m.polRound = NilRound
                                          THEN timelyBlocks \cup {vid}
                                          ELSE timelyBlocks
             ELSE \* nil prevote: no received proposal for r passes the gate
                  /\ ~ \E m \in ProposalsIn(r) :
                        /\ recvTime[s] # NilTime
                        /\ GatePass(s, m)
                  /\ UNCHANGED timelyBlocks
    /\ UNCHANGED <<round, lockedValue, lockedRound, validValue, validRound,
                   decision, recvTime, proposals, precommits>>
    /\ l' = l + 1

(* Precommit — enterPrecommit.  A block precommit locks on a 2/3 polka.         *)
TracePrecommit ==
    /\ IsEvent("Precommit")
    /\ LET s   == EvNode
           r   == logline.round
           vid == logline.voteId
       IN /\ step[s] = "PREVOTE"
          /\ step' = [step EXCEPT ![s] = "PRECOMMIT"]
          /\ clock' = [clock EXCEPT ![s] = logline.clock]
          /\ precommits' = precommits \cup {[src |-> s, round |-> r, id |-> vid]}
          /\ IF vid # NilBlock
             THEN \* lock-on-polka; ValidatePostState checks captured lock/valid
                  /\ HasPolka(r, vid)
                  /\ lockedValue' = [lockedValue EXCEPT ![s] = vid]
                  /\ lockedRound' = [lockedRound EXCEPT ![s] = r]
                  /\ validValue'  = [validValue EXCEPT ![s] = vid]
                  /\ validRound'  = [validRound EXCEPT ![s] = r]
                  /\ logline.lockedValue = vid
                  /\ logline.lockedRound = r
             ELSE /\ ~ \E v \in Timestamps : HasPolka(r, v)
                  /\ UNCHANGED <<lockedValue, lockedRound, validValue, validRound>>
    /\ UNCHANGED <<round, decision, recvTime, proposals, prevotes, auxVars>>
    /\ l' = l + 1

(* Decide — finalizeCommit.  Commits on a 2/3 precommit majority.              *)
TraceDecide ==
    /\ IsEvent("Decide")
    /\ LET s   == EvNode
           vid == logline.decidedId
       IN /\ decision[s] = NilDecision
          /\ \E r \in Rounds : HasCommit(r, vid)
          /\ decision' = [decision EXCEPT ![s] = vid]
          /\ step'     = [step EXCEPT ![s] = "DECIDED"]
    /\ UNCHANGED <<round, lockedValue, lockedRound, validValue, validRound,
                   timeVars, msgVars, auxVars>>
    /\ l' = l + 1

(* UpdateValidBlock — optional setValidBlock event (cs.ValidBlock refresh on a   *)
(* polka).  Emitted when the impl updates ValidBlock OUTSIDE a precommit (addVote *)
(* setValidBlock).  The MC base folds ValidBlock updates into PrecommitBlock for  *)
(* state-space reasons, but a real trace may carry standalone setValidBlock        *)
(* events, so trace validation handles them directly (validating the polka).      *)
TraceUpdateValidBlock ==
    /\ IsEvent("UpdateValidBlock")
    /\ LET s == EvNode
           r == logline.round
           v == logline.voteId
       IN /\ HasPolka(r, v)
          /\ r > validRound[s]
          /\ validValue' = [validValue EXCEPT ![s] = v]
          /\ validRound' = [validRound EXCEPT ![s] = r]
          /\ logline.validValue = v
          /\ logline.validRound = r
    /\ UNCHANGED <<round, step, lockedValue, lockedRound, decision,
                   timeVars, msgVars, auxVars>>
    /\ l' = l + 1

(* Faulty events — a Byzantine validator's observed message.  Validated only    *)
(* as message emission (no honest post-state).                                  *)
TraceFaultyPropose ==
    /\ IsEvent("FaultyPropose")
    /\ LET f == EvNode
       IN /\ f \in Faulty
          /\ proposals' = proposals \cup
                {[src |-> f, round |-> logline.round,
                  time |-> logline.propTime, polRound |-> logline.propPolRound]}
    /\ UNCHANGED <<coreVars, timeVars, prevotes, precommits, auxVars>>
    /\ l' = l + 1

TraceFaultyVote ==
    /\ \/ IsEvent("FaultyPrevote")
       \/ IsEvent("FaultyPrecommit")
    /\ LET f == EvNode IN
       /\ f \in Faulty
       /\ IF logline.event = "FaultyPrevote"
          THEN /\ prevotes' = prevotes \cup
                     {[src |-> f, round |-> logline.round, id |-> logline.voteId]}
               /\ UNCHANGED precommits
          ELSE /\ precommits' = precommits \cup
                     {[src |-> f, round |-> logline.round, id |-> logline.voteId]}
               /\ UNCHANGED prevotes
    /\ UNCHANGED <<coreVars, timeVars, proposals, auxVars>>
    /\ l' = l + 1

----------------------------------------------------------------------------
TraceInit ==
    /\ Init
    /\ clock = [s \in Correct |-> 0]   \* pin the (otherwise nondeterministic) init skew
    /\ l = 1

TraceNext ==
    \/ TraceStartRound
    \/ TracePropose
    \/ TraceReceiveProposal
    \/ TracePrevote
    \/ TracePrecommit
    \/ TraceDecide
    \/ TraceUpdateValidBlock
    \/ TraceFaultyPropose
    \/ TraceFaultyVote

TraceSpec == TraceInit /\ [][TraceNext]_allVars

(* The whole trace must be consumed — without this, TLC reports "no errors"     *)
(* even when l never advances (a false positive).                              *)
TraceMatched == <>(l > Len(TraceLog))

=============================================================================
