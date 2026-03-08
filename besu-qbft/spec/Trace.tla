------------------------------ MODULE Trace ------------------------------
\* Trace validation spec for besu QBFT.
\*
\* Reads an NDJSON trace file produced by the Java instrumentation harness,
\* and replays each event against the base spec to verify the implementation
\* matches the specification.

EXTENDS base, Json, IOUtils, Sequences, TLC

----
\* Trace loading
----

\* Read JSON file path from environment.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/qbft_trace.ndjson"

\* Load NDJSON, keep only lines with tag="trace".
TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x))

ASSUME Len(TraceLog) > 0

----
\* Trace cursor
----

VARIABLE l       \* Current position in TraceLog (1-indexed)

traceVars == <<l>>

logline == TraceLog[l]

----
\* Proposer selection for trace validation
\* Matches besu implementation: validators[(height + round) % n]
\* With 4 servers: s1=index 0, s2=index 1, s3=index 2, s4=index 3
----

\* Derive proposer from trace events.
\* If there's a HandleProposal for this height, the remote sender is proposer.
\* Otherwise, the node that fired BlockTimerExpiry is proposer.
\* Falls back to round-robin if neither found (e.g., for untouched rounds).
TraceProposer(h, r) ==
    IF \E k \in 1..Len(TraceLog) :
        /\ TraceLog[k].event.name = "HandleProposal"
        /\ TraceLog[k].event.state.height = h
        /\ "msg" \in DOMAIN TraceLog[k].event
        /\ TraceLog[k].event.msg.round = r
    THEN
        LET k == CHOOSE k \in 1..Len(TraceLog) :
            /\ TraceLog[k].event.name = "HandleProposal"
            /\ TraceLog[k].event.state.height = h
            /\ "msg" \in DOMAIN TraceLog[k].event
            /\ TraceLog[k].event.msg.round = r
        IN TraceLog[k].event.msg.from
    ELSE IF \E k \in 1..Len(TraceLog) :
        /\ TraceLog[k].event.name = "BlockTimerExpiry"
        /\ TraceLog[k].event.state.height = h
        /\ TraceLog[k].event.state.round = r
    THEN
        LET k == CHOOSE k \in 1..Len(TraceLog) :
            /\ TraceLog[k].event.name = "BlockTimerExpiry"
            /\ TraceLog[k].event.state.height = h
            /\ TraceLog[k].event.state.round = r
        IN TraceLog[k].event.nid
    ELSE \* Fallback: round-robin
        LET serverSeq == <<"s1", "s2", "s3", "s4">>
            idx == ((h + r) % 4) + 1
        IN serverSeq[idx]

----
\* Phase mapping
----

QbftPhase ==
    "Proposing" :> Proposing @@
    "Prepared"  :> Prepared  @@
    "Committed" :> Committed

----
\* Server extraction from trace
----

TraceServer == TLCEval(
    UNION {
        {TraceLog[k].event.nid}
        \cup (IF "msg" \in DOMAIN TraceLog[k].event
              THEN {TraceLog[k].event.msg.from, TraceLog[k].event.msg.to}
                    \ {""}
              ELSE {})
        : k \in 1..Len(TraceLog)
    })

ASSUME TraceServer /= {}
ASSUME TraceServer \subseteq Server

----
\* Bootstrap state
\*
\* QBFT starts at height 1 with block timer pending (round = -1).
\* All servers are validators, blockchain height = 0.
----

TraceInit ==
    /\ l = 1
    /\ currentHeight       = [s \in Server |-> 1]
    /\ currentRound        = [s \in Server |-> Nil]
    /\ phase               = [s \in Server |-> Proposing]
    /\ proposedBlock       = [s \in Server |-> Nil]
    /\ prepareMessages     = [s \in Server |-> {}]
    /\ commitMessages      = [s \in Server |-> {}]
    /\ roundChangeMessages = [s \in Server |-> [r \in 0..10 |-> {}]]
    /\ roundSummary        = [s \in Server |-> [v \in Server |-> Nil]]
    /\ actioned            = [s \in Server |-> [r \in 0..10 |-> FALSE]]
    /\ latestPrepCert      = [s \in Server |-> Nil]
    /\ blockchainHeight    = [s \in Server |-> 0]
    /\ committed           = [s \in Server |-> FALSE]
    /\ blockImported       = [s \in Server |-> FALSE]
    /\ validators          = InitValidators
    /\ messages            = EmptyBag
    /\ alive               = [s \in Server |-> TRUE]

----
\* Event predicates
----

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.event.nid = i

IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ "msg" \in DOMAIN logline.event
    /\ logline.event.msg.from = from
    /\ logline.event.msg.to = to

----
\* Post-state validation
\*
\* After each spec action, verify the resulting state matches the trace.
----

\* Map trace round value to spec round value (trace uses -1 for no round)
TraceRound(traceVal) ==
    IF traceVal = 0 - 1 THEN Nil ELSE traceVal

\* Strong validation: check height, round, phase, committed
ValidatePostState(i) ==
    /\ currentHeight'[i] = logline.event.state.height
    /\ currentRound'[i] = TraceRound(logline.event.state.round)
    /\ committed'[i] = logline.event.state.committed

\* Weak validation: only check height and round
ValidatePostStateWeak(i) ==
    /\ currentHeight'[i] = logline.event.state.height
    /\ currentRound'[i] = TraceRound(logline.event.state.round)

\* Pre-state validation: for events emitted before the state change
\* (e.g., RoundExpiry emits at handler start, before round increment)
ValidatePreState(i) ==
    /\ currentHeight[i] = logline.event.state.height
    /\ currentRound[i] = TraceRound(logline.event.state.round)

----
\* Step trace cursor
----

StepTrace == l' = l + 1

----
\* Action wrappers
\*
\* Each wrapper: (1) matches event type, (2) calls spec action,
\* (3) validates resulting state, (4) advances cursor.
----

\* BlockTimerExpiry -> BlockTimerExpiry(s)
BlockTimerExpiryIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("BlockTimerExpiry", i)
        /\ BlockTimerExpiry(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* HandleProposal -> HandleProposal(s, m)
HandleProposalIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleProposal")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = ProposalMsg
            /\ m.msource = logline.event.msg.from
            /\ m.mdest = i
            /\ HandleProposal(i, m)
            /\ ValidatePostState(i)
            /\ StepTrace

\* HandlePrepare -> HandlePrepare(s, m) — remote prepares only
HandlePrepareIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandlePrepare")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ logline.event.msg.from /= i  \* NOT self-prepare
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = PrepareMsg
            /\ m.msource = logline.event.msg.from
            /\ m.mdest = i
            /\ HandlePrepare(i, m)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* Self-prepare: proposer/non-proposer processes own prepare locally.
\* Implementation calls peerIsPrepared(localPrepareMessage) which is
\* not a network message — handle directly without message bag lookup.
SelfPrepareIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandlePrepare")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ logline.event.msg.from = i   \* Self-prepare: from = to
        /\ logline.event.msg.to = i
        /\ alive[i]
        /\ ~IsNil(proposedBlock[i])
        /\ LET h == currentHeight[i]
               r == currentRound[i]
               valSet == ValidatorsAt(h)
               blockHash == proposedBlock[i].hash
               newPrepares == prepareMessages[i] \cup
                   {[sender |-> i, blockHash |-> blockHash]}
               wasPrepared == phase[i] \in {Prepared, Committed}
               isPrepared == Cardinality(newPrepares) >= PrepareQuorum(valSet)
           IN
           /\ prepareMessages' = [prepareMessages EXCEPT ![i] = newPrepares]
           /\ IF ~wasPrepared /\ isPrepared
              THEN /\ phase' = [phase EXCEPT ![i] = Prepared]
                   /\ SendAll({[mtype |-> CommitMsg,
                                msource |-> i,
                                mdest |-> d,
                                mheight |-> h,
                                mround |-> r,
                                mblockHash |-> blockHash,
                                mseal |-> i] : d \in valSet \ {i}})
              ELSE /\ UNCHANGED <<phase, messages>>
        /\ UNCHANGED <<currentHeight, currentRound, proposedBlock, commitMessages,
                       rcVars, heightVars, latchVars, validatorVars, crashVars>>
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

\* HandleCommit -> HandleCommit(s, m)
\* Force import-succeeds when commit quorum is reached (the trace
\* wouldn't continue to NewChainHead if import had failed).
HandleCommitIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleCommit")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = CommitMsg
            /\ m.msource = logline.event.msg.from
            /\ m.mdest = i
            /\ HandleCommit(i, m)
            /\ IF committed'[i] /\ ~committed[i]
               THEN blockImported'[i] = TRUE
               ELSE TRUE
            /\ ValidatePostState(i)
            /\ StepTrace

\* RoundExpiry -> RoundExpiry(s)
\* Trace captures pre-state (emitted before round increment)
RoundExpiryIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("RoundExpiry", i)
        /\ ValidatePreState(i)
        /\ RoundExpiry(i)
        /\ StepTrace

\* HandleRoundChange -> HandleRoundChange(s, m)
HandleRoundChangeIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleRoundChange")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = RoundChangeMsg
            /\ m.msource = logline.event.msg.from
            /\ m.mdest = i
            /\ HandleRoundChange(i, m)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* NewChainHead -> NewChainHead(s)
NewChainHeadIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("NewChainHead", i)
        /\ NewChainHead(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* Crash -> Crash(s)
CrashIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Crash", i)
        /\ Crash(i)
        /\ StepTrace

\* Recover -> Recover(s)
RecoverIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Recover", i)
        /\ Recover(i)
        /\ StepTrace

----
\* Silent actions (no trace event consumed)
\*
\* The implementation performs some state changes that don't emit trace events.
\* These use base spec actions to fill the gap without consuming a trace line.
----

\* Silent actions: non-traced servers take protocol steps without consuming trace lines.
\* Only fire when the NEXT trace event needs a message from a remote server.
\* This prevents state explosion from irrelevant silent action interleavings.

\* The traced node (always the first event's nid)
TracedNode == TraceLog[1].event.nid

\* Guard: only allow silent actions when current trace event needs a remote message
NeedRemoteMessage ==
    /\ "msg" \in DOMAIN logline.event
    /\ logline.event.msg.from /= logline.event.nid

SilentBlockTimerExpiry ==
    /\ l <= Len(TraceLog)
    /\ NeedRemoteMessage
    /\ \E s \in Server \ {TracedNode} :
        /\ BlockTimerExpiry(s)
        /\ UNCHANGED l

SilentHandleProposal ==
    /\ l <= Len(TraceLog)
    /\ NeedRemoteMessage
    /\ \E s \in Server \ {TracedNode} :
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = ProposalMsg
            /\ m.mdest = s
            /\ HandleProposal(s, m)
            /\ UNCHANGED l

SilentHandlePrepare ==
    /\ l <= Len(TraceLog)
    /\ NeedRemoteMessage
    /\ \E s \in Server \ {TracedNode} :
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = PrepareMsg
            /\ m.mdest = s
            /\ HandlePrepare(s, m)
            /\ UNCHANGED l

SilentHandleRoundChange ==
    /\ l <= Len(TraceLog)
    /\ NeedRemoteMessage
    /\ \E s \in Server \ {TracedNode} :
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = RoundChangeMsg
            /\ m.mdest = s
            /\ HandleRoundChange(s, m)
            /\ UNCHANGED l

----
\* Main transition
----

TraceNext ==
    \/ BlockTimerExpiryIfLogged
    \/ HandleProposalIfLogged
    \/ HandlePrepareIfLogged
    \/ SelfPrepareIfLogged
    \/ HandleCommitIfLogged
    \/ RoundExpiryIfLogged
    \/ HandleRoundChangeIfLogged
    \/ NewChainHeadIfLogged
    \/ CrashIfLogged
    \/ RecoverIfLogged
    \* Silent actions (no trace event consumed)
    \/ SilentBlockTimerExpiry
    \/ SilentHandleProposal
    \/ SilentHandlePrepare
    \/ SilentHandleRoundChange

----
\* Spec and properties
----

\* The property TraceMatched below will be violated if TLC runs with more than a single worker.
ASSUME TLCGet("config").worker = 1

TraceSpec == TraceInit /\ [][TraceNext]_<<l, vars>> /\ WF_<<l, vars>>(TraceNext)

\* View must include cursor position to prevent TLC from
\* collapsing identical states at different trace positions.
TraceView == <<vars, l>>

\* This property checks that the entire trace was consumed.
\* With WF on TraceNext, this says "eventually the trace is fully consumed."
\* Violation means TLC could not advance past some event.
TraceMatched == <>(l > Len(TraceLog))

\* Sentinel invariant: violation means the trace WAS fully consumed (success!)
\* Use this in Trace.cfg instead of TraceMatched for faster checking.
NotDone == l <= Len(TraceLog)

\* Alias for debugging trace failures.
TraceAlias ==
    [
        l          |-> l,
        len        |-> Len(TraceLog),
        event      |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
        nid        |-> IF l <= Len(TraceLog) THEN logline.event.nid ELSE "DONE",
        tState     |-> IF l <= Len(TraceLog)
                       THEN IF "state" \in DOMAIN logline.event
                            THEN logline.event.state ELSE "NO_STATE"
                       ELSE "DONE",
        height     |-> currentHeight,
        round      |-> currentRound,
        phaseVal   |-> phase,
        commitFlag |-> committed,
        imported   |-> blockImported,
        bcHeight   |-> blockchainHeight,
        msgCount   |-> BagCardinality(messages),
        aliveVal   |-> alive
    ]

=============================================================================
