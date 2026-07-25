--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation specification for Autobahn BFT consensus.
 *
 * Replays implementation traces against the base spec to verify
 * that the base spec can reproduce every observed state transition.
 *
 * Trace format: NDJSON with tag="trace" and event records containing:
 *   - event.name: action name (e.g., "SendPrepare", "ReceivePrepare")
 *   - event.nid: server ID (e.g., "s1")
 *   - event.state: post-action state snapshot
 *   - event.msg: message fields (for message-related events)
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
              THEN {TraceLog[k].event.msg.author} \ {""}
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

\* ============================================================================
\* POST-STATE VALIDATION
\* ============================================================================

\* Strong validation: check view, votedPrepare, votedConfirm, committed
ValidatePostState(i, sl) ==
    /\ views'[i][sl] = logline.event.state.view
    /\ votedPrepare'[i][sl] = logline.event.state.votedPrepare
    /\ votedConfirm'[i][sl] = logline.event.state.votedConfirm
    /\ committed'[i][sl] = TraceValue(logline.event.state.committed)

\* Weak validation: check view only
\* Used for actions where trace may not capture full state
ValidatePostStateWeak(i, sl) ==
    /\ views'[i][sl] = logline.event.state.view

\* View-only validation (for actions that don't change vote state)
ValidateView(i, sl) ==
    /\ views'[i][sl] = logline.event.state.view

\* ============================================================================
\* STEP TRACE CURSOR
\* ============================================================================

StepTrace == l' = l + 1

\* ============================================================================
\* ACTION WRAPPERS
\* ============================================================================

\* --- SendPrepare ---
\* Matches: event.name = "SendPrepare"
\* Emitted when honest leader broadcasts a Prepare message.
SendPrepareIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SendPrepare", i)
        /\ LET sl  == logline.event.msg.slot
               v   == logline.event.msg.view
               val == logline.event.msg.value
           IN
           /\ SendPrepare(i, sl, v, val)
           /\ ValidateView(i, sl)
           /\ StepTrace

\* --- ReceivePrepare ---
\* Matches: event.name = "ReceivePrepare"
\* Emitted when honest server votes on a received Prepare.
ReceivePrepareIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceivePrepare", i)
        /\ LET sl == logline.event.msg.slot
               v  == logline.event.msg.view
           IN
           /\ ReceivePrepare(i, sl, v)
           /\ ValidatePostState(i, sl)
           /\ StepTrace

\* --- SendConfirm ---
\* Matches: event.name = "SendConfirm"
\* Emitted when leader broadcasts Confirm after PrepareQC.
SendConfirmIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SendConfirm", i)
        /\ LET sl  == logline.event.msg.slot
               v   == logline.event.msg.view
               val == logline.event.msg.value
           IN
           /\ SendConfirm(i, sl, v, val)
           /\ StepTrace

\* --- ReceiveConfirm ---
\* Matches: event.name = "ReceiveConfirm"
\* Emitted when honest server votes on a received Confirm.
ReceiveConfirmIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveConfirm", i)
        /\ LET sl == logline.event.msg.slot
               v  == logline.event.msg.view
           IN
           /\ ReceiveConfirm(i, sl, v)
           /\ ValidatePostState(i, sl)
           /\ StepTrace

\* --- SendCommit ---
\* Matches: event.name = "SendCommit"
\* Emitted when leader broadcasts Commit after ConfirmQC.
SendCommitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SendCommit", i)
        /\ LET sl  == logline.event.msg.slot
               v   == logline.event.msg.view
               val == logline.event.msg.value
           IN
           /\ SendCommit(i, sl, v, val)
           /\ StepTrace

\* --- SendFastCommit ---
\* Matches: event.name = "SendFastCommit"
\* Emitted when leader broadcasts Commit via fast path (3f+1 PrepareQC).
SendFastCommitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SendFastCommit", i)
        /\ LET sl  == logline.event.msg.slot
               v   == logline.event.msg.view
               val == logline.event.msg.value
           IN
           /\ SendFastCommit(i, sl, v, val)
           /\ StepTrace

\* --- ReceiveCommit ---
\* Matches: event.name = "ReceiveCommit"
\* Emitted when honest server commits upon receiving Commit.
ReceiveCommitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveCommit", i)
        /\ LET sl == logline.event.msg.slot
               v  == logline.event.msg.view
           IN
           /\ ReceiveCommit(i, sl, v)
           /\ ValidatePostState(i, sl)
           /\ StepTrace

\* --- SendTimeout ---
\* Matches: event.name = "SendTimeout"
\* Emitted when honest server sends a timeout for (slot, view).
SendTimeoutIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SendTimeout", i)
        /\ LET sl == logline.event.state.slot IN
           /\ SendTimeout(i, sl)
           /\ StepTrace

\* --- AdvanceView ---
\* Matches: event.name = "AdvanceView"
\* Emitted when server processes 2f+1 timeouts and advances view.
AdvanceViewIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("AdvanceView", i)
        /\ LET sl == logline.event.state.slot
               v  == logline.event.state.prevView
           IN
           /\ AdvanceView(i, sl, v)
           /\ ValidateView(i, sl)
           /\ StepTrace

\* --- GeneratePrepareFromTC ---
\* Matches: event.name = "GeneratePrepareFromTC"
\* Emitted when new leader creates Prepare from TC evidence.
GeneratePrepareFromTCIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("GeneratePrepareFromTC", i)
        /\ LET sl == logline.event.msg.slot
               v  == logline.event.msg.view
           IN
           /\ GeneratePrepareFromTC(i, sl, v)
           /\ StepTrace

\* --- EnterSlot ---
\* Matches: event.name = "EnterSlot"
\* Emitted when server enters a new slot (view 1).
EnterSlotIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EnterSlot", i)
        /\ LET sl == logline.event.state.slot IN
           /\ EnterSlot(i, sl)
           /\ ValidateView(i, sl)
           /\ StepTrace

\* ============================================================================
\* SILENT ACTIONS
\* ============================================================================

\* Silent actions handle impl state changes without trace events.
\* Must be tightly constrained to prevent state explosion.

\* --- Silent vote accumulation ---
\* When the traced node is a leader and sees a QC form, the individual
\* vote arrivals from other nodes may not be traced. We need to fire
\* ReceivePrepare silently for non-observed servers so that
\* prepareVotes accumulates enough for QC formation.
SilentReceivePrepare ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"SendConfirm", "SendFastCommit"}
    /\ \E i \in Server, sl \in Slot, v \in View :
        /\ i /= logline.event.nid
        /\ ReceivePrepare(i, sl, v)
        /\ UNCHANGED l

\* --- Silent Confirm vote accumulation ---
SilentReceiveConfirm ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "SendCommit"
    /\ \E i \in Server, sl \in Slot, v \in View :
        /\ i /= logline.event.nid
        /\ ReceiveConfirm(i, sl, v)
        /\ UNCHANGED l

\* --- Silent timeout accumulation ---
\* When AdvanceView fires, other servers' timeouts may not be traced.
SilentSendTimeout ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"AdvanceView", "GeneratePrepareFromTC"}
    /\ \E i \in Server, sl \in Slot :
        /\ i /= logline.event.nid
        /\ SendTimeout(i, sl)
        /\ UNCHANGED l

\* --- Silent EnterSlot ---
\* Non-observed servers may enter slots without trace events.
SilentEnterSlot ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server, sl \in Slot :
        /\ i /= logline.event.nid
        /\ EnterSlot(i, sl)
        /\ UNCHANGED l

\* ============================================================================
\* TRACE INIT
\* ============================================================================

TraceInit ==
    /\ l = 1
    /\ views = [s \in Server |-> [sl \in Slot |-> 0]]
    /\ votedPrepare = [s \in Server |-> [sl \in Slot |-> 0]]
    /\ votedConfirm = [s \in Server |-> [sl \in Slot |-> 0]]
    /\ highQCView = [s \in Server |-> [sl \in Slot |-> 0]]
    /\ highQCValue = [s \in Server |-> [sl \in Slot |-> Nil]]
    /\ highPropView = [s \in Server |-> [sl \in Slot |-> 0]]
    /\ highPropValue = [s \in Server |-> [sl \in Slot |-> Nil]]
    /\ committed = [s \in Server |-> [sl \in Slot |-> Nil]]
    /\ prepareVotes = [sl \in Slot |-> [v \in View |-> {}]]
    /\ confirmVotes = [sl \in Slot |-> [v \in View |-> {}]]
    /\ timeoutSent = [sl \in Slot |-> [v \in View |-> {}]]
    /\ proposed = [sl \in Slot |-> [v \in View |-> {}]]
    /\ timeoutHighQCView = [sl \in Slot |-> [v \in View |->
                                [s \in Server |-> 0]]]
    /\ timeoutHighQCValue = [sl \in Slot |-> [v \in View |->
                                 [s \in Server |-> Nil]]]
    /\ timeoutHighPropView = [sl \in Slot |-> [v \in View |->
                                  [s \in Server |-> 0]]]
    /\ timeoutHighPropValue = [sl \in Slot |-> [v \in View |->
                                   [s \in Server |-> Nil]]]
    /\ messages = {}

\* ============================================================================
\* TRACE NEXT
\* ============================================================================

TraceDone ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED <<l, vars>>

TraceNext ==
    \* Stuttering after trace consumed (prevents deadlock)
    \/ TraceDone
    \* Action wrappers (consume one trace event each)
    \/ SendPrepareIfLogged
    \/ ReceivePrepareIfLogged
    \/ SendConfirmIfLogged
    \/ ReceiveConfirmIfLogged
    \/ SendCommitIfLogged
    \/ SendFastCommitIfLogged
    \/ ReceiveCommitIfLogged
    \/ SendTimeoutIfLogged
    \/ AdvanceViewIfLogged
    \/ GeneratePrepareFromTCIfLogged
    \/ EnterSlotIfLogged
    \* Silent actions (no trace event consumed)
    \/ SilentReceivePrepare
    \/ SilentReceiveConfirm
    \/ SilentSendTimeout
    \/ SilentEnterSlot

\* ============================================================================
\* SPEC AND PROPERTIES
\* ============================================================================

TraceSpec == TraceInit /\ [][TraceNext]_<<l, vars>>

\* View must include cursor position
TraceView == <<vars, l>>

\* Property: entire trace was consumed
TraceMatched ==
    <>(l > Len(TraceLog))

\* ============================================================================
\* ALIAS (for debugging trace failures)
\* ============================================================================

TraceAlias ==
    [
        cursor     |-> l,
        traceLen   |-> Len(TraceLog),
        event      |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
        nid        |-> IF l <= Len(TraceLog) THEN logline.event.nid ELSE "DONE",
        tState     |-> IF l <= Len(TraceLog)
                       THEN logline.event.state
                       ELSE "DONE",
        views      |-> views,
        votedPrepare |-> votedPrepare,
        votedConfirm |-> votedConfirm,
        highQCView |-> highQCView,
        committed  |-> committed,
        proposed   |-> proposed,
        prepareVotes |-> prepareVotes,
        confirmVotes |-> confirmVotes,
        msgCount   |-> Cardinality(messages)
    ]

====
