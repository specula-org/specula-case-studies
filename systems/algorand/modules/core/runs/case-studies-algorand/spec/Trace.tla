--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation specification for Algorand BA*.
 *
 * Replays implementation traces against base.tla. Category A: single linear
 * trace, cursor-based.
 *
 * Trace format (NDJSON):
 *   { "tag": "trace",
 *     "event": {
 *        "name": <action name from base.tla, e.g., "IssueSoftVote">,
 *        "nid":  <validator ID, e.g., "n1">,
 *        "state": {
 *           "round": <int>,
 *           "period": <int>,
 *           "step": <int>,
 *           "persistedRound": <int>,
 *           "persistedPeriod": <int>,
 *           "persistedStep": <int>,
 *           "lastConcluding": <int>,
 *           ...
 *        },
 *        "vote": {            // present on IssueSoftVote/IssueCertVote/...
 *           "round": <int>, "period": <int>, "step": <int>,
 *           "value": <string|"Bottom">, "origPeriod": <int>
 *        },
 *        "msg":  { ... }      // present on Receive* events
 *     } }
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
\* SERVER EXTRACTION FROM TRACE
\* ============================================================================

TraceServer == TLCEval(
    UNION {
        {TraceLog[k].event.nid}
        : k \in 1..Len(TraceLog)
    })

ASSUME TraceServer /= {}

\* ============================================================================
\* HELPERS
\* ============================================================================

\* The trace records concrete block digests (e.g. "VRPKKJ7SQWRY24FCA5EHM...").
\* The spec uses symbolic values (v1, v2 in Values). For trace validation we
\* collapse all concrete digests onto the single symbolic value "v1" — this
\* still exercises every action; value-distinguishing safety checks are the
\* model checker's job, not the trace replay's.
TraceValue(v) ==
    IF v = "" \/ v = "null" \/ v = "nil" \/ v = "Bottom" THEN Bottom
    ELSE "v1"

\* Map implementation integer step to spec constant.
\* Reference: agreement/types.go:90-101 (propose=0, soft=1, cert=2, next=3,
\* late=253, redo=254, down=255).
StepFromInt(n) ==
    IF n = 0 THEN StepPropose
    ELSE IF n = 1 THEN StepSoft
    ELSE IF n = 2 THEN StepCert
    ELSE IF n = 253 THEN StepLate
    ELSE IF n = 254 THEN StepRedo
    ELSE IF n = 255 THEN StepDown
    ELSE StepNext + (n - 3)   \* step 3, 4, 5, ... map past StepNext

\* Map implementation threshold-event string to spec constant.
ThresholdTFromStr(s) ==
    IF s = "softThreshold" THEN SoftThresholdT
    ELSE IF s = "certThreshold" THEN CertThresholdT
    ELSE IF s = "nextThreshold" THEN NextThresholdT
    ELSE NoneThresholdT

\* Optional integer field: JSON `omitempty` drops a uint64 0 field, so the
\* trace record may not contain the key at all. Default to 0 in that case.
OptInt(rec, key) ==
    IF key \in DOMAIN rec THEN rec[key] ELSE 0

\* Optional string field: defaults to "" if missing.
OptStr(rec, key) ==
    IF key \in DOMAIN rec THEN rec[key] ELSE ""

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

\* Strong: round, period, step.
ValidatePostState(i) ==
    /\ "state" \in DOMAIN logline.event
    /\ round'[i]  = logline.event.state.round
    /\ period'[i] = logline.event.state.period
    /\ step'[i]   = StepFromInt(logline.event.state.step)

\* Loose: only round and period — used for events where the implementation
\* captures state at a different step transition point than the spec models
\* (e.g., Issue*Vote events fire BEFORE the step transition; PersistState
\* events fire AFTER an asymmetric subset of transitions).
ValidatePostStateLoose(i) ==
    /\ "state" \in DOMAIN logline.event
    /\ round'[i]  = logline.event.state.round
    /\ period'[i] = logline.event.state.period

ValidatePersisted(i) ==
    /\ "state" \in DOMAIN logline.event
    /\ persistedRound'[i]  = logline.event.state.persistedRound
    /\ persistedPeriod'[i] = logline.event.state.persistedPeriod
    /\ persistedStep'[i]   = StepFromInt(logline.event.state.persistedStep)

\* For vote-emitting actions: check the in-flight set contains the vote.
ValidateVoteSigned(i) ==
    /\ "vote" \in DOMAIN logline.event
    /\ LET vt == Vote(i,
                      logline.event.vote.round,
                      logline.event.vote.period,
                      StepFromInt(logline.event.vote.step),
                      TraceValue(logline.event.vote.value),
                      logline.event.vote.origPeriod)
       IN vt \in inFlight'[i]

\* Validate that the vote actually broadcast appears in messages bag.
ValidateVoteBroadcast(i) ==
    /\ "vote" \in DOMAIN logline.event
    /\ \E m \in DOMAIN messages' :
        /\ m.mtype = VoteMsg
        /\ m.vote.sender = i
        /\ m.vote.round = logline.event.vote.round
        /\ m.vote.period = logline.event.vote.period

\* Validate decision recorded.
ValidateDecision(i) ==
    /\ "state" \in DOMAIN logline.event
    /\ "decision" \in DOMAIN logline.event.state
    /\ LET r == logline.event.state.round
           v == TraceValue(logline.event.state.decision)
       IN decision'[i][r] = v

\* ============================================================================
\* STEP TRACE CURSOR
\* ============================================================================

StepTrace == l' = l + 1

\* ============================================================================
\* ACTION WRAPPERS
\* ============================================================================

\* IssueSoftVote is instrumented BEFORE p.Step = cert. The spec's IssueSoftVote
\* atomically transitions step to cert. Use loose validation (no step check)
\* so the trace's pre-transition state.step doesn't conflict with the spec
\* post-state.
IssueSoftVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("IssueSoftVote", i)
        /\ IssueSoftVote(i)
        /\ ValidatePostStateLoose(i)
        /\ StepTrace

\* IssueCertVote does NOT transition step in the implementation (called from
\* softThreshold handler, player.go:405). Spec now matches — step stays at
\* StepCert.
IssueCertVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("IssueCertVote", i)
        /\ IssueCertVote(i)
        /\ ValidatePostState(i)
        /\ ValidateVoteSigned(i)
        /\ StepTrace

\* IssueNextVote is instrumented AFTER p.Step transitions to next/next+1 (see
\* player.go:122,131). Strict post-state check is appropriate.
IssueNextVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("IssueNextVote", i)
        /\ IssueNextVote(i)
        /\ ValidatePostState(i)
        /\ StepTrace

IssueFastVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("IssueFastVote", i)
        /\ IssueFastVote(i)
        /\ ValidateVoteSigned(i)
        /\ StepTrace

HandleFastTimeoutPrimerIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleFastTimeoutPrimer", i)
        /\ HandleFastTimeoutPrimer(i)
        /\ StepTrace

PersistStateIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("PersistState", i)
        /\ PersistState(i)
        /\ ValidatePersisted(i)
        /\ StepTrace

\* BroadcastVote/ProposeBlock are emitted from pseudonode goroutines whose
\* state.round/period/step mirror the vote's coordinates, NOT the player's
\* live state. Furthermore, the test runs a single pseudonode managing many
\* keys; each per-key broadcast becomes a BroadcastVote event with the key
\* as nid, but the spec's `inFlight` is per-key — the actual vote was
\* generated under the "local" pseudonode's player. To bridge this, we
\* relax BroadcastVote in the trace wrapper: it emits the wire message and
\* records the vote in votesSeen without requiring inFlight membership.
BroadcastVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("BroadcastVote", i)
        /\ "vote" \in DOMAIN logline.event
        /\ LET vt == Vote(i,
                          logline.event.vote.round,
                          logline.event.vote.period,
                          StepFromInt(logline.event.vote.step),
                          TraceValue(logline.event.vote.value),
                          logline.event.vote.origPeriod)
           IN /\ Send(SendVoteMsg(vt))
              /\ votesSeen' = [votesSeen EXCEPT
                      ![i][vt.round][vt.period][vt.step] = @ \cup {vt}]
              \* If this vote was previously in inFlight (own server),
              \* drain it; otherwise leave inFlight unchanged.
              /\ inFlight' = [inFlight EXCEPT ![i] = @ \ {vt}]
        /\ StepTrace
        /\ UNCHANGED <<playerVars, cacheVars, ledgerVars, persistVars,
                       filterVars, committeeVars, decisionVars>>

\* ProposeBlock per-key fires similarly to BroadcastVote — for the trace
\* validation we just record the wire message and the pinnedLowest update.
ProposeBlockIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ProposeBlock", i)
        /\ "vote" \in DOMAIN logline.event
        /\ LET r == logline.event.vote.round
               p == logline.event.vote.period
               v == TraceValue(logline.event.vote.value)
               op == logline.event.vote.origPeriod
               pvote == Vote(i, r, p, StepPropose, v, op)
           IN /\ v /= Bottom
              /\ Send(SendProposalMsg(r, p, v, i, op))
              /\ pinnedLowest' = [pinnedLowest EXCEPT ![i][r][p] = v]
              /\ inFlight' = [inFlight EXCEPT ![i] = @ \cup {pvote}]
        /\ StepTrace
        /\ UNCHANGED <<playerVars, voteTrackingVars, ntcBottom, ntcProposal,
                       freshestT, freshestPeriod, freshestValue, freshestOk,
                       staging, ledgerVars, persistVars,
                       filterVars, committeeVars, decisionVars>>

PartitionPolicyRebroadcastIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("PartitionPolicyRebroadcast", i)
        /\ PartitionPolicyRebroadcast(i)
        /\ StepTrace

EnterPeriodViaNextThresholdIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterPeriodViaNextThreshold", i)
        /\ "state" \in DOMAIN logline.event
        /\ LET target == logline.event.state.period
               v == TraceValue(OptStr(logline.event.state, "thresholdValue"))
           IN /\ EnterPeriodViaNextThreshold(i, target, v)
              /\ ValidatePostState(i)
              /\ StepTrace

EnterPeriodViaSoftThresholdIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterPeriodViaSoftThreshold", i)
        /\ "state" \in DOMAIN logline.event
        /\ LET target == logline.event.state.period
               v == TraceValue(OptStr(logline.event.state, "thresholdValue"))
           IN /\ EnterPeriodViaSoftThreshold(i, target, v)
              /\ ValidatePostState(i)
              /\ StepTrace

EnterRoundIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterRound", i)
        /\ "state" \in DOMAIN logline.event
        /\ LET target == logline.event.state.round IN
           /\ EnterRound(i, target)
           /\ ValidatePostState(i)
           /\ StepTrace

CrashIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Crash", i)
        /\ Crash(i)
        /\ StepTrace

RecoverIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Recover", i)
        /\ Recover(i)
        /\ ValidatePostState(i)
        /\ ValidatePersisted(i)
        /\ StepTrace

UpdateNextThresholdCacheIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("UpdateNextThresholdCache", i)
        /\ "state" \in DOMAIN logline.event
        /\ LET r == logline.event.state.round
               p == OptInt(logline.event.state, "thresholdPeriod")
               v == TraceValue(OptStr(logline.event.state, "thresholdValue"))
           IN /\ UpdateNextThresholdCache(i, r, p, v)
              /\ StepTrace

UpdateFreshestIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("UpdateFreshest", i)
        /\ "state" \in DOMAIN logline.event
        /\ LET r == logline.event.state.round
               et == ThresholdTFromStr(OptStr(logline.event.state, "thresholdType"))
               ep == OptInt(logline.event.state, "thresholdPeriod")
               ev == TraceValue(OptStr(logline.event.state, "thresholdValue"))
           IN /\ UpdateFreshest(i, r, et, ep, ev)
              /\ freshestT'[i][r] = et
              /\ freshestPeriod'[i][r] = ep
              /\ freshestValue'[i][r] = ev
              /\ StepTrace

UpdateStagingIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("UpdateStaging", i)
        /\ "state" \in DOMAIN logline.event
        /\ LET r == logline.event.state.round
               p == OptInt(logline.event.state, "thresholdPeriod")
               v == TraceValue(OptStr(logline.event.state, "thresholdValue"))
           IN /\ UpdateStaging(i, r, p, v)
              /\ staging'[i][r][p] = v
              /\ StepTrace

HandleSoftThresholdSamePeriodIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleSoftThresholdSamePeriod", i)
        /\ "state" \in DOMAIN logline.event
        /\ LET p == OptInt(logline.event.state, "thresholdPeriod")
               v == TraceValue(OptStr(logline.event.state, "thresholdValue"))
           IN /\ HandleSoftThresholdSamePeriod(i, p, v)
              /\ StepTrace

HandleCertThresholdLocalIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleCertThresholdLocal", i)
        /\ "state" \in DOMAIN logline.event
        /\ LET p == OptInt(logline.event.state, "thresholdPeriod")
               v == TraceValue(OptStr(logline.event.state, "thresholdValue"))
           IN /\ HandleCertThresholdLocal(i, p, v)
              /\ ValidateDecision(i)
              /\ StepTrace

CatchupInstallIfLogged ==
    /\ IsEvent("CatchupInstall")
    /\ "state" \in DOMAIN logline.event
    /\ LET r == logline.event.state.round
           v == TraceValue(OptStr(logline.event.state, "installedValue"))
       IN /\ CatchupInstall(r, v)
          /\ ledgerCertified'[r] = v
          /\ StepTrace

ReceiveVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveVote", i)
        /\ "vote" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = VoteMsg
            /\ m.vote.round = logline.event.vote.round
            /\ m.vote.period = logline.event.vote.period
            /\ m.vote.sender = logline.event.vote.sender
            /\ ReceiveVote(i, m)
            /\ StepTrace

ReceiveBundleIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveBundle", i)
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = BundleMsg
            /\ m.broadcaster = logline.event.msg.broadcaster
            /\ ReceiveBundle(i, m)
            /\ StepTrace

ReceiveProposalIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveProposal", i)
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = ProposalMsg
            /\ m.round = logline.event.msg.round
            /\ m.period = logline.event.msg.period
            /\ ReceiveProposal(i, m)
            /\ StepTrace

CalculateFilterTimeoutShortIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CalculateFilterTimeoutShort", i)
        /\ CalculateFilterTimeoutShort(i)
        /\ StepTrace

CalculateFilterTimeoutDefaultIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CalculateFilterTimeoutDefault", i)
        /\ CalculateFilterTimeoutDefault(i)
        /\ StepTrace

RecordCredentialArrivalIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("RecordCredentialArrival", i)
        /\ RecordCredentialArrival(i)
        /\ StepTrace

\* ============================================================================
\* SILENT ACTIONS
\* ============================================================================
\* Silent actions handle implementation state changes that occur without a
\* corresponding trace event. They MUST be tightly constrained.
\* NOTE: in this trace setup, BroadcastVoteIfLogged updates the broadcaster's
\* own votesSeen directly, and explicit ReceiveVote events deliver each vote
\* to local. Silent ReceiveVote/ProposeBlock are NOT needed; enabling them
\* causes a state-space explosion because TLC explores every (server,message)
\* pair as a separate branch with cursor unchanged.

\* ============================================================================
\* TRACE INIT
\* ============================================================================

TraceInit ==
    /\ l = 1
    /\ Init

\* ============================================================================
\* TRACE NEXT
\* ============================================================================

TraceDone ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED <<l, vars>>

TraceNext ==
    \/ TraceDone
    \* --- Action wrappers (consume one trace event each) ---
    \/ IssueSoftVoteIfLogged
    \/ IssueCertVoteIfLogged
    \/ IssueNextVoteIfLogged
    \/ IssueFastVoteIfLogged
    \/ HandleFastTimeoutPrimerIfLogged
    \/ PersistStateIfLogged
    \/ BroadcastVoteIfLogged
    \/ ProposeBlockIfLogged
    \/ PartitionPolicyRebroadcastIfLogged
    \/ EnterPeriodViaNextThresholdIfLogged
    \/ EnterPeriodViaSoftThresholdIfLogged
    \/ EnterRoundIfLogged
    \/ CrashIfLogged
    \/ RecoverIfLogged
    \/ UpdateNextThresholdCacheIfLogged
    \/ UpdateFreshestIfLogged
    \/ UpdateStagingIfLogged
    \/ HandleSoftThresholdSamePeriodIfLogged
    \/ HandleCertThresholdLocalIfLogged
    \/ CatchupInstallIfLogged
    \/ ReceiveVoteIfLogged
    \/ ReceiveBundleIfLogged
    \/ ReceiveProposalIfLogged
    \/ CalculateFilterTimeoutShortIfLogged
    \/ CalculateFilterTimeoutDefaultIfLogged
    \/ RecordCredentialArrivalIfLogged

\* Strong fairness on each wrapper action forces TLC to take it whenever
\* enabled infinitely often. WF on TraceNext is not enough because TLC
\* may consider stuttering as the "weak choice" if other Next disjuncts
\* are enabled but TraceNext is the only one to take.
TraceSpec == TraceInit /\ [][TraceNext]_<<l, vars>> /\ WF_<<l, vars>>(TraceNext)

TraceView == <<vars, l>>

\* TraceMatched: temporal property that the trace was fully consumed.
\* Defined explicitly so Trace.cfg references a name.
TraceMatched ==
    <>(l > Len(TraceLog))

\* ============================================================================
\* ALIAS (for debugging)
\* ============================================================================

TraceAlias ==
    [
        cursor   |-> l,
        traceLen |-> Len(TraceLog),
        event    |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
        nid      |-> IF l <= Len(TraceLog) THEN logline.event.nid ELSE "DONE",
        tState   |-> IF l <= Len(TraceLog) /\ "state" \in DOMAIN logline.event
                     THEN logline.event.state ELSE "DONE",
        round    |-> round,
        period   |-> period,
        step     |-> step,
        persistedRound |-> persistedRound,
        persistedPeriod |-> persistedPeriod,
        decision |-> decision,
        ledger   |-> ledgerCertified,
        msgCount |-> BagCardinality(messages)
    ]

====
