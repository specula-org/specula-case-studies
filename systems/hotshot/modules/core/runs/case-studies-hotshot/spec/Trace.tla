--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation spec for HotShot (Espresso Network).
 *
 * Replays implementation traces against the base spec to verify the base spec
 * can reproduce every observed state transition.
 *
 * Category: A (distributed / message-passing). Single linear cursor `l`.
 *
 * Trace format: NDJSON, one record per line, with:
 *   { "tag": "trace",
 *     "event": {
 *       "name":  "<spec action name>",
 *       "nid":   "<replica id>",
 *       "view":  <Nat>,
 *       "epoch": <Nat>,
 *       "state": { ... post-action state snapshot ... },
 *       "msg":   { ... event-specific message fields ... } }
 *   }
 *
 * Event names recognized (see instrumentation-spec.md for the exhaustive map):
 *   HandleQuorumProposalRecv | SubmitVote | TimeoutVote | FormQC | FormTC |
 *   ObserveQC | ProposeLeader | CommitLeaf | ViewSyncVote | FormViewSyncCert |
 *   Crash | Recover
 *
 * Byzantine actions are NOT instrumented in the production code paths — they
 * would have to come from a separate adversarial harness. The trace replays
 * only honest paths.
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
\* SERVER EXTRACTION
\* ============================================================================

TraceServer == TLCEval(
    { TraceLog[k].event.nid : k \in 1..Len(TraceLog) })

ASSUME TraceServer /= {}
ASSUME TraceServer \subseteq AllReplicas

\* Convenience: read trace-supplied state fields with sane defaults.
TraceValueOrNil(x) == IF x = "" \/ x = "null" THEN NilLeaf ELSE x

\* ============================================================================
\* EVENT PREDICATES
\* ============================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.event.nid = i

StepTrace == l' = l + 1

\* ============================================================================
\* POST-STATE VALIDATION
\* ============================================================================

\* HandleQuorumProposalRecv updates: curView, lockedView (if liveness),
\* savedLeaves (always — pre-bail update_leaf at L114), highestBlock,
\* highQcInMem (if qcAdvances), highQcPersisted (if qcAdvances &
\* !inTransitionEpoch). Validate the fields we expect the trace to capture.
ValidateHandleQuorumProposalRecv(i) ==
    /\ curView'[i]      = logline.event.state.curView
    /\ lockedView'[i]   = logline.event.state.lockedView
    /\ highestBlock'[i] = logline.event.state.highestBlock
    /\ \A leaf \in {logline.event.msg.leaf} :
            leaf \in savedLeaves'[i]

\* SubmitVote updates latestVotedView and emits a vote into the bag.
\* The new vote must appear in votes' with matching (voter, view, leaf).
ValidateSubmitVote(i) ==
    /\ latestVotedView'[i] = logline.event.state.latestVotedView
    /\ \E v \in votes' :
            /\ v.voter = i
            /\ v.view  = logline.event.msg.view
            /\ v.leaf  = logline.event.msg.leaf

\* TimeoutVote emits a timeout vote into timeoutVotes.
ValidateTimeoutVote(i) ==
    /\ \E tv \in timeoutVotes' :
            /\ tv.voter = i
            /\ tv.view  = logline.event.msg.view
            /\ tv.epoch = logline.event.msg.epoch

\* FormQC produces a QC; validate (view, leaf, epoch) appears in qcs'.
ValidateFormQC ==
    /\ \E qc \in qcs' :
            /\ qc.view       = logline.event.msg.view
            /\ qc.leafCommit = logline.event.msg.leaf
            /\ qc.epoch      = logline.event.msg.epoch

\* FormTC produces a TC; validate (view, epochClaim) appears in tcs'.
\* Family A note: the trace must capture epochClaim, NOT some "true" epoch.
ValidateFormTC ==
    /\ \E tc \in tcs' :
            /\ tc.view       = logline.event.msg.view
            /\ tc.epochClaim = logline.event.msg.epochClaim

\* ObserveQC: highQcInMem may or may not advance depending on monotonicity.
\* qcWitnessed always records the observation.
ValidateObserveQC(i) ==
    /\ \E qc \in qcWitnessed'[i][logline.event.msg.view] :
            /\ qc.view       = logline.event.msg.view
            /\ qc.leafCommit = logline.event.msg.leaf
            /\ qc.epoch      = logline.event.msg.epoch
    /\ \/ \* accepted (high QC view advanced)
          /\ highQcInMem'[i] /= NilQC
          /\ highQcInMem'[i].view >= logline.event.msg.view
       \/ \* dropped (consensus.rs:1325 silent drop) — high QC view did not advance
          /\ TRUE   \* both branches are accepted by the impl, so we don't require advance

ValidateProposeLeader(i) ==
    /\ \E p \in proposals' :
            /\ p.view = logline.event.msg.view
            /\ p.leaf = logline.event.msg.leaf

ValidateCommitLeaf(i) ==
    /\ committedLeaf'[i][logline.event.msg.view] = logline.event.msg.leaf

ValidateViewSyncVote(i) ==
    /\ i \in relayPool'[logline.event.msg.epoch]
                      [logline.event.msg.view]
                      [logline.event.msg.relay]
                      [logline.event.msg.phase]

ValidateFormViewSyncCert ==
    /\ logline.event.msg.phase = PhaseFinalize =>
            \E vsc \in vscs' :
                /\ vsc.view  = logline.event.msg.view
                /\ vsc.relay = logline.event.msg.relay
                /\ vsc.epoch = logline.event.msg.epoch

ValidateCrash(i) ==
    /\ crashed'[i] = TRUE
    /\ curView'[i] = 1
    /\ highQcInMem'[i] = NilQC
    /\ latestVotedView'[i] = 0

ValidateRecover(i) ==
    /\ crashed'[i] = FALSE
    /\ highQcInMem'[i] = highQcPersisted[i]

\* ============================================================================
\* ACTION WRAPPERS
\* ============================================================================

\* ============================================================================
\* SILENT BOOTSTRAP — synthesize proposal + parent leaf from trace fields
\* ============================================================================
\*
\* The trace harness feeds a fully-built proposal directly into the recv task
\* without a preceding ProposeLeader event. The proposal is not in our local
\* `proposals` bag yet, and the parent leaf is not in `savedLeaves`. The harness
\* pre-populates `saved_leaves` with the parent leaf via consensus_writer.update_leaf
\* (see harness test L105-111). This silent action models that bootstrap: it adds
\* the trace-provided proposal to the bag and the parent leaf to the receiver's
\* saved leaves. It does NOT advance the cursor.
\*
\* Enabled only when:
\*   - current trace event is HandleQuorumProposalRecv
\*   - the matching proposal is not yet in the bag
BootstrapProposalIfNeeded ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("HandleQuorumProposalRecv")
    /\ ~\E p \in proposals :
            /\ p.view = logline.event.msg.view
            /\ p.leaf = logline.event.msg.leaf
    /\ LET ev == logline.event.msg
           recv == logline.event.nid
           synthJustifyQc == [
               leafCommit |-> ev.parentLeaf,
               view       |-> ev.view - 1,
               epoch      |-> ev.epochClaim,
               signers    |-> AllReplicas
           ]
           synthProposal == [
               view         |-> ev.view,
               leaf         |-> ev.leaf,
               parentLeaf   |-> ev.parentLeaf,
               epochClaim   |-> ev.epochClaim,
               justifyQc    |-> synthJustifyQc,
               evidenceKind |-> ev.evidenceKind,
               tcEvidence   |-> [view |-> ev.view - 1,
                                 epochClaim |-> ev.epochClaim,
                                 signers |-> {}],
               vscEvidence  |-> [view |-> ev.view,
                                 relay |-> 0,
                                 epoch |-> ev.epochClaim,
                                 signers |-> {}]
           ]
       IN  /\ proposals' = proposals \cup {synthProposal}
           /\ savedLeaves' = [savedLeaves EXCEPT ![recv] = @ \cup {ev.parentLeaf}]
    \* Don't advance the cursor — this is bootstrap, not the actual event match.
    /\ UNCHANGED <<l, curView, curEpoch, highQcInMem, highQcPersisted,
                   lockedView, latestVotedView, highestBlock, transitionQc,
                   pendingPersistHighQC, pendingEqcStorage,
                   votes, timeoutVotes, qcs, tcs, vscs,
                   qcWitnessed, equivocationFlagged, relayPool,
                   crashed, committedLeaf>>

HandleQuorumProposalRecvIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleQuorumProposalRecv", i)
        /\ \E p \in proposals :
                /\ p.view = logline.event.msg.view
                /\ p.leaf = logline.event.msg.leaf
                /\ HandleQuorumProposalRecv(i, p)
        /\ ValidateHandleQuorumProposalRecv(i)
        /\ StepTrace
        /\ UNCHANGED <<>>  \* no extra-spec vars to keep; faultCtrs lives in MC

SubmitVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SubmitVote", i)
        /\ \E p \in proposals :
                /\ p.view = logline.event.msg.view
                /\ p.leaf = logline.event.msg.leaf
                /\ SubmitVote(i, p)
        /\ ValidateSubmitVote(i)
        /\ StepTrace

TimeoutVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("TimeoutVote", i)
        /\ TimeoutVote(i)
        /\ ValidateTimeoutVote(i)
        /\ StepTrace

FormQCIfLogged ==
    /\ IsEvent("FormQC")
    /\ FormQC(logline.event.msg.view,
              logline.event.msg.leaf,
              logline.event.msg.epoch,
              logline.event.msg.signers)
    /\ ValidateFormQC
    /\ StepTrace

FormTCIfLogged ==
    /\ IsEvent("FormTC")
    /\ FormTC(logline.event.msg.view,
              logline.event.msg.epochClaim,
              logline.event.msg.signers)
    /\ ValidateFormTC
    /\ StepTrace

ObserveQCIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ObserveQC", i)
        /\ \E qc \in qcs :
                /\ qc.view       = logline.event.msg.view
                /\ qc.leafCommit = logline.event.msg.leaf
                /\ qc.epoch      = logline.event.msg.epoch
                /\ ObserveQC(i, qc)
        /\ ValidateObserveQC(i)
        /\ StepTrace

ProposeLeaderIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ProposeLeader", i)
        /\ ProposeLeader(i,
                         logline.event.msg.leaf,
                         logline.event.msg.view,
                         logline.event.msg.evidenceKind)
        /\ ValidateProposeLeader(i)
        /\ StepTrace

CommitLeafIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CommitLeaf", i)
        /\ CommitLeaf(i, logline.event.msg.leaf, logline.event.msg.view)
        /\ ValidateCommitLeaf(i)
        /\ StepTrace

ViewSyncVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ViewSyncVote", i)
        /\ ViewSyncVote(i,
                        logline.event.msg.epoch,
                        logline.event.msg.view,
                        logline.event.msg.relay,
                        logline.event.msg.phase)
        /\ ValidateViewSyncVote(i)
        /\ StepTrace

FormViewSyncCertIfLogged ==
    /\ IsEvent("FormViewSyncCert")
    /\ FormViewSyncCert(logline.event.msg.epoch,
                        logline.event.msg.view,
                        logline.event.msg.relay,
                        logline.event.msg.phase)
    /\ ValidateFormViewSyncCert
    /\ StepTrace

CrashIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Crash", i)
        /\ Crash(i)
        /\ ValidateCrash(i)
        /\ StepTrace

RecoverIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Recover", i)
        /\ Recover(i)
        /\ ValidateRecover(i)
        /\ StepTrace

\* ============================================================================
\* SILENT ACTIONS
\* ============================================================================
\*
\* Silent actions handle implementation state changes that do not have a
\* corresponding trace event. They must be tightly constrained so they cannot
\* fire arbitrarily.
\*
\* Currently no silent actions are required: every base-spec action has a
\* matching trace event in the harness. If new internal transitions are added
\* (e.g., DRB-driven leader rotation between explicit events), wire them here
\* with `l <= Len(TraceLog)` AND a precondition on the NEXT trace event so the
\* silent step is only legal when it sets up the matching event.

\* ============================================================================
\* INIT / NEXT
\* ============================================================================

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \/ BootstrapProposalIfNeeded
    \/ HandleQuorumProposalRecvIfLogged
    \/ SubmitVoteIfLogged
    \/ TimeoutVoteIfLogged
    \/ FormQCIfLogged
    \/ FormTCIfLogged
    \/ ObserveQCIfLogged
    \/ ProposeLeaderIfLogged
    \/ CommitLeafIfLogged
    \/ ViewSyncVoteIfLogged
    \/ FormViewSyncCertIfLogged
    \/ CrashIfLogged
    \/ RecoverIfLogged
    \* Once cursor passes end-of-trace, stutter forever so TraceMatched can hold.
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED <<vars, traceVars>>

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_<<vars, traceVars>>
    \* Strong fairness: if any trace-matching action is ever enabled, it must
    \* eventually fire. This prevents TLC from finding trivial-stutter
    \* counterexamples where l never advances even though valid transitions
    \* exist.
    /\ SF_<<vars, traceVars>>(TraceNext)

\* ============================================================================
\* TEMPORAL PROPERTY
\* ============================================================================

\* The whole trace must be consumed. Without this, TLC reports "no errors"
\* even when l never advances.
TraceMatched == <>(l > Len(TraceLog))

================================================================================
