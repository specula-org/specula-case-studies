------------------------------ MODULE Trace -------------------------------
\* Trace validation spec for sofastack/sofa-jraft.
\*
\* Reads an NDJSON trace file produced by the Java test harness,
\* and replays each event against the base spec to verify
\* the implementation matches the specification.

EXTENDS base, Json, IOUtils, Sequences, TLC

----
\* Trace loading
----

\* Read JSON file path from environment.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/default.ndjson"

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
\* Role mapping
----

\* Map implementation state strings to spec constants.
\* Reference: NodeImpl.java State enum
RaftRole ==
    "Follower"  :> Follower  @@
    "Candidate" :> Candidate @@
    "Leader"    :> Leader

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
\* sofa-jraft initializes with term=0 and no log entries by default.
\* The first election brings the term to 1.
\* If the trace indicates different initial state, adjust here.
----

TraceInit ==
    /\ l = 1
    /\ currentTerm      = [s \in Server |-> 0]
    /\ votedFor          = [s \in Server |-> Nil]
    /\ log               = [s \in Server |-> <<>>]
    /\ state             = [s \in Server |-> Follower]
    /\ commitIndex       = [s \in Server |-> 0]
    /\ nextIndex         = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex        = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted      = [s \in Server |-> {}]
    /\ messages          = EmptyBag
    /\ persistedTerm     = [s \in Server |-> 0]
    /\ persistedVotedFor = [s \in Server |-> Nil]
    /\ pendingVote       = [s \in Server |-> Nil]
    /\ config            = [s \in Server |-> Server]
    /\ configOld         = [s \in Server |-> {}]

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

\* Strong validation: check all primary state fields.
ValidatePostState(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]
    /\ commitIndex'[i] = logline.event.state.commitIndex
    /\ LastLogIndex(i)' = logline.event.state.lastLogIndex
    /\ LastLogTerm(i)' = logline.event.state.lastLogTerm

\* Weak validation: only check term and role (for async events).
ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]

\* Match a votedFor value from trace (string) to spec value.
TraceVotedFor(i) ==
    LET v == logline.event.state.votedFor
    IN IF v = "" THEN Nil ELSE v

ValidateVotedFor(i) ==
    votedFor'[i] = TraceVotedFor(i)

----
\* Step trace cursor
----

StepTrace == l' = l + 1

----
\* Silent actions (no trace event consumed)
\*
\* The implementation performs some state changes that don't emit
\* trace events. These use base spec actions to fill the gap.
\* Each must be tightly constrained to prevent state space explosion.
----

\* Concurrent timeouts: when multiple nodes timeout simultaneously,
\* the trace may serialize events non-causally.
\* Fires ElectSelf without consuming a trace event.
\* Constrained: only when next event is HandleRequestVoteRequest
\* from the candidate that needs to time out first.
SilentTimeout ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleRequestVoteRequest"
    /\ "msg" \in DOMAIN logline.event
    /\ \E i \in Server :
        /\ i = logline.event.msg.from
        /\ state[i] = Follower
        /\ ElectSelf(i)
        /\ UNCHANGED l

\* Concurrent response processing: replication threads may advance
\* matchIndex before the HandleAppendEntriesResponse event appears.
\* Fires HandleAppendEntriesResponseSuccess without consuming event.
SilentHandleAppendEntriesResponse ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "AdvanceCommitIndex"
    /\ LET i == logline.event.nid
           expectedCI == logline.event.state.commitIndex
           Agree(idx) == {i} \cup {s \in Server : matchIndex[i][s] >= idx}
       IN
       \* Only fire when quorum for expected commitIndex is not yet met
       /\ ~ IsJointQuorum(Agree(expectedCI), config[i], configOld[i])
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = AppendEntriesResponse
           /\ m.msubtype = "replicate"
           /\ m.mdest = i
           /\ HandleAppendEntriesResponseSuccess(i, m)
           /\ UNCHANGED l

\* Leader appends entry (noop or client request) without trace event.
\* Fires when the current trace event expects a longer leader log.
FillLogGap ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name /= "ProposeConfigChange"
    /\ LET nid     == logline.event.nid
           expected == logline.event.state.lastLogIndex
       IN
       /\ state[nid] = Leader
       /\ LastLogIndex(nid) < expected
       /\ ClientRequest(nid)
       /\ UNCHANGED l

\* Silent PersistElectSelf: the trace doesn't log persistence separately.
\* Fires when the current event is for a candidate whose persist is pending.
SilentPersistElectSelf ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ state[i] = Candidate
        /\ persistedTerm[i] < currentTerm[i]
        /\ PersistElectSelf(i)
        /\ UNCHANGED l

\* Silent sends: the implementation sends heartbeats/probes automatically
\* (e.g., after BecomeLeader or periodically) without always logging the
\* send event. When the trace shows HandleAppendEntriesRequest but no
\* matching message exists in the bag, fire the send silently.
SilentSendHeartbeat ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleAppendEntriesRequest"
    /\ "msg" \in DOMAIN logline.event
    /\ "prevLogIndex" \notin DOMAIN logline.event.msg  \* heartbeat: no prevLogIndex
    /\ LET from == logline.event.msg.from
           to   == logline.event.nid
       IN
       /\ from \in Server /\ to \in Server
       /\ state[from] = Leader
       \* Only fire when no matching heartbeat message exists yet
       /\ ~ \E m \in DOMAIN messages :
              /\ m.mtype = AppendEntriesRequest
              /\ m.msubtype = "heartbeat"
              /\ m.msource = from
              /\ m.mdest = to
       /\ SendHeartbeat(from, to)
       /\ UNCHANGED l

SilentSendAppendEntries ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleAppendEntriesRequest"
    /\ "msg" \in DOMAIN logline.event
    /\ "prevLogIndex" \in DOMAIN logline.event.msg  \* replicate: has prevLogIndex
    /\ LET from == logline.event.msg.from
           to   == logline.event.nid
       IN
       /\ from \in Server /\ to \in Server
       /\ state[from] = Leader
       \* Only fire when no matching replicate message exists yet
       /\ ~ \E m \in DOMAIN messages :
              /\ m.mtype = AppendEntriesRequest
              /\ m.msubtype = "replicate"
              /\ m.msource = from
              /\ m.mdest = to
       /\ AppendEntries(from, to)
       /\ UNCHANGED l

----
\* Action wrappers
\*
\* Each wrapper: (1) matches event type, (2) calls spec action,
\* (3) validates resulting state, (4) advances cursor.
----

\* BecomeCandidate -> ElectSelf(i)
\* Two cases: (1) normal timeout, (2) already timed out via SilentTimeout.
ElectSelfIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("BecomeCandidate", i)
        /\ \/ \* Normal: fire ElectSelf
              /\ ElectSelf(i)
              /\ ValidatePostState(i)
              /\ ValidateVotedFor(i)
              /\ StepTrace
           \/ \* Already timed out via SilentTimeout: state matches, just advance
              /\ state[i] = Candidate
              /\ currentTerm[i] = logline.event.state.term
              /\ votedFor[i] = TraceVotedFor(i)
              /\ UNCHANGED vars
              /\ StepTrace

\* HandleRequestVoteRequest -> HandleRequestVoteRequestAtomic(i, m)
\* Uses atomic variant (impl doesn't crash mid-persist during normal trace).
HandleRequestVoteRequestIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleRequestVoteRequest")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = RequestVoteRequest
            /\ m.msource = logline.event.msg.from
            /\ m.mdest = i
            /\ HandleRequestVoteRequestAtomic(i, m)
            /\ ValidatePostState(i)
            /\ StepTrace

\* HandleRequestVoteResponse -> HandleRequestVoteResponse(i, m)
HandleRequestVoteResponseIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleRequestVoteResponse")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Self-vote: skip (already handled by ElectSelf)
              /\ logline.event.msg.from = logline.event.msg.to
              /\ logline.event.msg.from = i
              /\ UNCHANGED vars
              /\ StepTrace
           \/ \* Remote vote: find matching message in bag
              /\ logline.event.msg.from /= logline.event.msg.to
              /\ \/ \E m \in DOMAIN messages :
                       /\ m.mtype = RequestVoteResponse
                       /\ m.msource = logline.event.msg.from
                       /\ m.mdest = i
                       /\ \/ \* Normal: process via spec action
                             /\ HandleRequestVoteResponse(i, m)
                             /\ ValidatePostState(i)
                             /\ StepTrace
                          \/ \* Stale: use base spec's DropStaleMessage
                             /\ DropStaleMessage(m)
                             /\ StepTrace
                 \/ \* Transport failure: message was lost
                    /\ ~ \E m \in DOMAIN messages :
                            /\ m.mtype = RequestVoteResponse
                            /\ m.msource = logline.event.msg.from
                            /\ m.mdest = i
                    /\ UNCHANGED vars
                    /\ StepTrace

\* BecomeLeader -> BecomeLeader(i)
BecomeLeaderIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("BecomeLeader", i)
        /\ BecomeLeader(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* SendAppendEntries -> AppendEntries(i, j)
AppendEntriesIfLogged ==
    \E i \in Server :
        /\ IsEvent("SendAppendEntries")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ LET j == logline.event.msg.to IN
            /\ j \in Server
            /\ AppendEntries(i, j)
            /\ ValidatePostState(i)
            /\ StepTrace

\* SendHeartbeat -> SendHeartbeat(i, j)
SendHeartbeatIfLogged ==
    \E i \in Server :
        /\ IsEvent("SendHeartbeat")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ LET j == logline.event.msg.to IN
            /\ j \in Server
            /\ SendHeartbeat(i, j)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* HandleAppendEntriesRequest -> HandleAppendEntriesRequest(i, m)
HandleAppendEntriesRequestIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleAppendEntriesRequest")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = AppendEntriesRequest
            /\ m.msource = logline.event.msg.from
            /\ m.mdest = i
            /\ m.mterm = logline.event.msg.term
            \* Disambiguate heartbeat vs replicate by presence of entries info
            /\ IF "prevLogIndex" \in DOMAIN logline.event.msg
               THEN m.msubtype = "replicate"
               ELSE m.msubtype = "heartbeat"
            /\ HandleAppendEntriesRequest(i, m)
            \* Both replicate and heartbeat: use weak validation because
            \* (a) replicate: log append is async (Disruptor), PRE-append state
            \* (b) heartbeat: commitIndex from prior replicates may lag (async)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* HandleAppendEntriesResponse (success) -> HandleAppendEntriesResponseSuccess(i, m)
HandleAppendEntriesResponseSuccessIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleAppendEntriesResponseSuccess")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Normal: find matching message in bag
              \E m \in DOMAIN messages :
                /\ m.mtype = AppendEntriesResponse
                /\ m.msubtype = "replicate"
                /\ m.msource = logline.event.msg.from
                /\ m.mdest = i
                /\ m.msuccess = TRUE
                /\ HandleAppendEntriesResponseSuccess(i, m)
                /\ ValidatePostStateWeak(i)
                /\ StepTrace
           \/ \* Already consumed by silent action
              /\ ~ \E m \in DOMAIN messages :
                      /\ m.mtype = AppendEntriesResponse
                      /\ m.msubtype = "replicate"
                      /\ m.msource = logline.event.msg.from
                      /\ m.mdest = i
                      /\ m.msuccess = TRUE
              /\ UNCHANGED vars
              /\ StepTrace

\* HandleAppendEntriesResponse (failure) -> HandleAppendEntriesResponseFailure(i, m)
HandleAppendEntriesResponseFailureIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleAppendEntriesResponseFailure")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = AppendEntriesResponse
            /\ m.msubtype = "replicate"
            /\ m.msource = logline.event.msg.from
            /\ m.mdest = i
            /\ m.msuccess = FALSE
            /\ HandleAppendEntriesResponseFailure(i, m)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* HandleHeartbeatResponse -> HandleHeartbeatResponse(i, m)
HandleHeartbeatResponseIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleHeartbeatResponse")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = AppendEntriesResponse
            /\ m.msubtype = "heartbeat"
            /\ m.msource = logline.event.msg.from
            /\ m.mdest = i
            /\ HandleHeartbeatResponse(i, m)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* HandleInstallSnapshotResponse -> HandleInstallSnapshotResponse(i, m)
HandleInstallSnapshotResponseIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleInstallSnapshotResponse")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = InstallSnapshotResponse
            /\ m.msource = logline.event.msg.from
            /\ m.mdest = i
            /\ HandleInstallSnapshotResponse(i, m)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* AdvanceCommitIndex -> AdvanceCommitIndex(i)
AdvanceCommitIndexIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("AdvanceCommitIndex", i)
        /\ AdvanceCommitIndex(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* ProposeConfigChange -> ProposeConfigChange(i, newPeers)
ProposeConfigChangeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ProposeConfigChange", i)
        /\ "msg" \in DOMAIN logline.event
        /\ LET newPeers == logline.event.msg.newPeers IN
            /\ ProposeConfigChange(i, newPeers)
            /\ ValidatePostState(i)
            /\ StepTrace

----
\* Main transition
----

TraceNext ==
    \/ ElectSelfIfLogged
    \/ HandleRequestVoteRequestIfLogged
    \/ HandleRequestVoteResponseIfLogged
    \/ BecomeLeaderIfLogged
    \/ AppendEntriesIfLogged
    \/ SendHeartbeatIfLogged
    \/ HandleAppendEntriesRequestIfLogged
    \/ HandleAppendEntriesResponseSuccessIfLogged
    \/ HandleAppendEntriesResponseFailureIfLogged
    \/ HandleHeartbeatResponseIfLogged
    \/ HandleInstallSnapshotResponseIfLogged
    \/ AdvanceCommitIndexIfLogged
    \/ ProposeConfigChangeIfLogged
    \* Silent actions (no trace event consumed)
    \/ FillLogGap
    \/ SilentTimeout
    \/ SilentHandleAppendEntriesResponse
    \/ SilentPersistElectSelf
    \/ SilentSendHeartbeat
    \/ SilentSendAppendEntries

----
\* Spec and properties
----

TraceSpec == TraceInit /\ [][TraceNext]_<<l, vars>> /\ WF_<<l, vars>>(TraceNext)

\* View must include cursor position to prevent TLC from
\* collapsing identical states at different trace positions.
TraceView == <<vars, l>>

\* This property checks that the entire trace was consumed.
\* Violation means TLC could not advance past some event.
\* Uses eventual consumption check with fairness (WF in TraceSpec).
TraceMatched == <>(l > Len(TraceLog))

\* Alias for debugging trace failures.
TraceAlias ==
    [
        l         |-> l,
        len       |-> Len(TraceLog),
        event     |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
        nid       |-> IF l <= Len(TraceLog) THEN logline.event.nid ELSE "DONE",
        tState    |-> IF l <= Len(TraceLog) THEN logline.event.state ELSE "DONE",
        term      |-> currentTerm,
        vFor      |-> votedFor,
        role      |-> state,
        cIdx      |-> commitIndex,
        logLen    |-> [s \in Server |-> Len(log[s])],
        vGrant    |-> votesGranted,
        msgCount  |-> BagCardinality(messages),
        conf      |-> config,
        confOld   |-> configOld
    ]

=============================================================================
