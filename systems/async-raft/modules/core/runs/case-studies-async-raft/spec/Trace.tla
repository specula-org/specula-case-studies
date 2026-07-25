--------------------------- MODULE Trace ---------------------------
\* Trace validation spec for async-raft.
\*
\* Reads an NDJSON trace file produced by the instrumentation harness,
\* and replays each event against the base spec to verify
\* the implementation matches the specification.

EXTENDS base, Json, IOUtils, Sequences, TLC

\* Server name constants — declared here so ServerMapping can reference them.
\* Values assigned via Trace.cfg: s1 = s1, s2 = s2, s3 = s3.
CONSTANTS s1, s2, s3

----
\* Trace loading
----

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

----
\* Trace cursor
----

VARIABLE l       \* Current position in TraceLog (1-indexed)

traceVars == <<l>>

logline == TraceLog[l]

----
\* Role mapping
----

RaftRole ==
    "Follower"  :> Follower  @@
    "Candidate" :> Candidate @@
    "Leader"    :> Leader

----
\* Server extraction from trace
\* JSON returns strings; we map them to TLA+ model values.
----

\* Mapping from JSON string IDs to TLA+ model value constants
ServerMapping == TLCEval(
    "s1" :> s1 @@ "s2" :> s2 @@ "s3" :> s3)

\* Map a JSON string server ID to the corresponding TLA+ constant
MapServer(str) == ServerMapping[str]

TraceServerRaw == TLCEval(
    UNION {
        {TraceLog[k].event.nid}
        \cup (IF "msg" \in DOMAIN TraceLog[k].event
              THEN {TraceLog[k].event.msg.from, TraceLog[k].event.msg.to}
                    \ {""}
              ELSE {})
        : k \in 1..Len(TraceLog)
    })

TraceServer == {MapServer(s) : s \in TraceServerRaw}

ASSUME TraceServer /= {}
ASSUME TraceServer \subseteq Server

----
\* Bootstrap state
\*
\* async-raft initializes with term=0 and empty log.
\* (core/mod.rs:160-192: main() initialization)
----

TraceInit ==
    /\ l = 1
    /\ currentTerm   = [s \in Server |-> 0]
    /\ votedFor      = [s \in Server |-> Nil]
    /\ log           = [s \in Server |-> <<>>]
    /\ state         = [s \in Server |-> Follower]
    /\ commitIndex   = [s \in Server |-> 0]
    /\ nextIndex     = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex    = [s \in Server |-> [t \in Server |-> 0]]
    /\ matchTerm     = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted  = [s \in Server |-> {}]
    /\ messages      = EmptyBag
    /\ readConfirmed = [s \in Server |-> 0]
    /\ readQuorum    = [s \in Server |-> 0]
    /\ readActive    = [s \in Server |-> FALSE]
    /\ snapshotIndex = [s \in Server |-> 0]
    /\ membership    = [s \in Server |-> [members |-> Server,
                                          members_after |-> Nil]]

----
\* Event predicates
----

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ MapServer(logline.event.nid) = i

IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ "msg" \in DOMAIN logline.event
    /\ MapServer(logline.event.msg.from) = from
    /\ MapServer(logline.event.msg.to) = to

----
\* Post-state validation
\*
\* Full: validates term, role, commitIndex, lastLogIndex, lastLogTerm.
\* Weak: validates only term and role (for async events).
----

ValidatePostState(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]
    /\ commitIndex'[i] = logline.event.state.commitIndex
    /\ Len(log'[i]) = logline.event.state.lastLogIndex
    /\ LastLogTerm(i)' = logline.event.state.lastLogTerm

ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]

TraceVotedFor(i) ==
    LET v == logline.event.state.votedFor
    IN IF v = "" THEN Nil ELSE MapServer(v)

ValidateVotedFor(i) ==
    votedFor'[i] = TraceVotedFor(i)

----
\* Step trace cursor
----

StepTrace == l' = l + 1

----
\* Silent actions (no trace event consumed)
----

\* Leader appends entry without trace event (noop on leadership start,
\* or gap-filling before an observed state).
\* Constrained: only fire when next trace event expects higher lastLogIndex.
FillLogGap ==
    /\ l <= Len(TraceLog)
    /\ LET nid     == MapServer(logline.event.nid)
           expected == logline.event.state.lastLogIndex
       IN
       /\ state[nid] = Leader
       /\ Len(log[nid]) < expected
       /\ ClientRequest(nid)
       /\ UNCHANGED l

\* Leader sends heartbeat or replication without trace event.
\* Constrained: only fire when next trace event is HandleAppendEntriesRequest
\* and we need to create the message in the bag.
SilentSendHeartbeat ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleAppendEntriesRequest"
    /\ "msg" \in DOMAIN logline.event
    /\ LET from == MapServer(logline.event.msg.from)
           to   == MapServer(logline.event.nid)
       IN
       /\ ~ \E m \in DOMAIN messages :
               /\ m.mtype = AppendEntriesRequest
               /\ m.msource = from
               /\ m.mdest = to
       /\ SendHeartbeat(from, to)
       /\ UNCHANGED l

\* Leader sends replication entries without trace event.
SilentReplicateEntries ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleAppendEntriesRequest"
    /\ "msg" \in DOMAIN logline.event
    /\ LET from == MapServer(logline.event.msg.from)
           to   == MapServer(logline.event.nid)
       IN
       /\ ~ \E m \in DOMAIN messages :
               /\ m.mtype = AppendEntriesRequest
               /\ m.msource = from
               /\ m.mdest = to
       /\ ReplicateEntries(from, to)
       /\ UNCHANGED l

\* Process pending AppendEntries response without trace event.
\* Needed when the trace only logs the AdvanceCommitIndex event
\* but the response handling must happen first.
SilentHandleAppendEntriesResponse ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "AdvanceCommitIndex"
    /\ LET i == MapServer(logline.event.nid) IN
       \E m \in DOMAIN messages :
           /\ m.mtype = AppendEntriesResponse
           /\ m.mdest = i
           /\ HandleAppendEntriesResponse(i, m)
           /\ UNCHANGED l

\* Advance commit index without trace event.
\* Needed when the impl advances commit asynchronously.
SilentAdvanceCommitIndex ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ state[i] = Leader
        /\ AdvanceCommitIndex(i)
        /\ UNCHANGED l

----
\* Action wrappers
----

\* Timeout -> Timeout(i)
TimeoutIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Timeout", i)
        /\ Timeout(i)
        /\ ValidatePostState(i)
        /\ ValidateVotedFor(i)
        /\ StepTrace

\* HandleRequestVoteRequest -> HandleRequestVoteRequest(i, m)
HandleRequestVoteRequestIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleRequestVoteRequest")
        /\ MapServer(logline.event.nid) = i
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = RequestVoteRequest
            /\ m.msource = MapServer(logline.event.msg.from)
            /\ m.mdest = i
            /\ HandleRequestVoteRequest(i, m)
            /\ ValidatePostState(i)
            /\ StepTrace

\* HandleRequestVoteResponse -> HandleRequestVoteResponse(i, m)
HandleRequestVoteResponseIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleRequestVoteResponse")
        /\ MapServer(logline.event.nid) = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \E m \in DOMAIN messages :
                /\ m.mtype = RequestVoteResponse
                /\ m.msource = MapServer(logline.event.msg.from)
                /\ m.mdest = i
                /\ HandleRequestVoteResponse(i, m)
                /\ ValidatePostStateWeak(i)
                /\ StepTrace
           \/ \* Transport failure: response lost
              /\ ~ \E m \in DOMAIN messages :
                      /\ m.mtype = RequestVoteResponse
                      /\ m.msource = MapServer(logline.event.msg.from)
                      /\ m.mdest = i
              /\ UNCHANGED vars
              /\ StepTrace

\* BecomeLeader -> BecomeLeader(i)
BecomeLeaderIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("BecomeLeader", i)
        /\ BecomeLeader(i)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

\* ClientRequest -> ClientRequest(i) (append payload to log)
ClientRequestIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ClientRequest", i)
        /\ ClientRequest(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* SendReplicateEntries -> ReplicateEntries(i, j)
ReplicateEntriesIfLogged ==
    \E i \in Server :
        /\ IsEvent("SendReplicateEntries")
        /\ MapServer(logline.event.nid) = i
        /\ "msg" \in DOMAIN logline.event
        /\ LET j == MapServer(logline.event.msg.to) IN
            /\ j \in Server
            /\ ReplicateEntries(i, j)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* SendHeartbeat -> SendHeartbeat(i, j)
SendHeartbeatIfLogged ==
    \E i \in Server :
        /\ IsEvent("SendHeartbeat")
        /\ MapServer(logline.event.nid) = i
        /\ "msg" \in DOMAIN logline.event
        /\ LET j == MapServer(logline.event.msg.to) IN
            /\ j \in Server
            /\ SendHeartbeat(i, j)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* HandleAppendEntriesRequest -> HandleAppendEntriesRequest(i, m)
HandleAppendEntriesRequestIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleAppendEntriesRequest")
        /\ MapServer(logline.event.nid) = i
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = AppendEntriesRequest
            /\ m.msource = MapServer(logline.event.msg.from)
            /\ m.mdest = i
            /\ HandleAppendEntriesRequest(i, m)
            /\ ValidatePostState(i)
            /\ StepTrace

\* HandleAppendEntriesResponse -> HandleAppendEntriesResponse(i, m)
HandleAppendEntriesResponseIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleAppendEntriesResponse")
        /\ MapServer(logline.event.nid) = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \E m \in DOMAIN messages :
                /\ m.mtype = AppendEntriesResponse
                /\ m.msource = MapServer(logline.event.msg.from)
                /\ m.mdest = i
                /\ HandleAppendEntriesResponse(i, m)
                /\ ValidatePostStateWeak(i)
                /\ StepTrace
           \/ \* Transport failure: response lost
              /\ ~ \E m \in DOMAIN messages :
                      /\ m.mtype = AppendEntriesResponse
                      /\ m.msource = MapServer(logline.event.msg.from)
                      /\ m.mdest = i
              /\ UNCHANGED vars
              /\ StepTrace

\* AdvanceCommitIndex -> AdvanceCommitIndex(i)
AdvanceCommitIndexIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("AdvanceCommitIndex", i)
        /\ AdvanceCommitIndex(i)
        /\ ValidatePostStateWeak(i)
        /\ commitIndex'[i] = logline.event.state.commitIndex
        /\ StepTrace

\* ClientReadRequest -> ClientReadRequest(i)
ClientReadRequestIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ClientReadRequest", i)
        /\ ClientReadRequest(i)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

\* ClientReadConfirm -> ClientReadConfirm(i, m)
ClientReadConfirmIfLogged ==
    \E i \in Server :
        /\ IsEvent("ClientReadConfirm")
        /\ MapServer(logline.event.nid) = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \E m \in DOMAIN messages :
                /\ m.mtype = AppendEntriesResponse
                /\ m.msource = MapServer(logline.event.msg.from)
                /\ m.mdest = i
                /\ ClientReadConfirm(i, m)
                /\ StepTrace
           \/ /\ UNCHANGED vars
              /\ StepTrace

\* ClientReadComplete -> ClientReadComplete(i)
ClientReadCompleteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ClientReadComplete", i)
        /\ ClientReadComplete(i)
        /\ StepTrace

\* HandleInstallSnapshotRequest -> HandleInstallSnapshotRequest(i, m)
HandleInstallSnapshotRequestIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleInstallSnapshotRequest")
        /\ MapServer(logline.event.nid) = i
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = InstallSnapshotRequest
            /\ m.msource = MapServer(logline.event.msg.from)
            /\ m.mdest = i
            /\ HandleInstallSnapshotRequest(i, m)
            /\ ValidatePostState(i)
            /\ StepTrace

\* SendInstallSnapshot -> SendInstallSnapshot(i, j)
SendInstallSnapshotIfLogged ==
    \E i \in Server :
        /\ IsEvent("SendInstallSnapshot")
        /\ MapServer(logline.event.nid) = i
        /\ "msg" \in DOMAIN logline.event
        /\ LET j == MapServer(logline.event.msg.to) IN
            /\ j \in Server
            /\ SendInstallSnapshot(i, j)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* HandleInstallSnapshotResponse -> HandleInstallSnapshotResponse(i, m)
HandleInstallSnapshotResponseIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleInstallSnapshotResponse")
        /\ MapServer(logline.event.nid) = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \E m \in DOMAIN messages :
                /\ m.mtype = InstallSnapshotResponse
                /\ m.msource = MapServer(logline.event.msg.from)
                /\ m.mdest = i
                /\ HandleInstallSnapshotResponse(i, m)
                /\ ValidatePostStateWeak(i)
                /\ StepTrace
           \/ /\ UNCHANGED vars
              /\ StepTrace

\* TakeSnapshot -> TakeSnapshot(i)
TakeSnapshotIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("TakeSnapshot", i)
        /\ TakeSnapshot(i)
        /\ StepTrace

\* ChangeMembership -> ChangeMembership(i, newMembers)
ChangeMembershipIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ChangeMembership", i)
        /\ "members" \in DOMAIN logline.event
        /\ LET newM == {MapServer(logline.event.members[k]) : k \in DOMAIN logline.event.members}
           IN ChangeMembership(i, newM)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

\* FinalizeJointConsensus -> FinalizeJointConsensus(i)
FinalizeJointConsensusIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("FinalizeJointConsensus", i)
        /\ FinalizeJointConsensus(i)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

----
\* TraceNext
----

TraceNext ==
    \* Action wrappers (consume trace event)
    \/ TimeoutIfLogged
    \/ HandleRequestVoteRequestIfLogged
    \/ HandleRequestVoteResponseIfLogged
    \/ BecomeLeaderIfLogged
    \/ ClientRequestIfLogged
    \/ ReplicateEntriesIfLogged
    \/ SendHeartbeatIfLogged
    \/ HandleAppendEntriesRequestIfLogged
    \/ HandleAppendEntriesResponseIfLogged
    \/ AdvanceCommitIndexIfLogged
    \/ ClientReadRequestIfLogged
    \/ ClientReadConfirmIfLogged
    \/ ClientReadCompleteIfLogged
    \/ HandleInstallSnapshotRequestIfLogged
    \/ SendInstallSnapshotIfLogged
    \/ HandleInstallSnapshotResponseIfLogged
    \/ TakeSnapshotIfLogged
    \/ ChangeMembershipIfLogged
    \/ FinalizeJointConsensusIfLogged
    \* Silent actions (no trace event consumed)
    \/ FillLogGap
    \/ SilentSendHeartbeat
    \/ SilentReplicateEntries
    \/ SilentHandleAppendEntriesResponse
    \/ SilentAdvanceCommitIndex

----
\* Specification
----

trace_vars == <<vars, traceVars>>

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_trace_vars

----
\* Temporal property: entire trace was consumed
----

TraceMatched ==
    <>(l = Len(TraceLog) + 1)

----
\* Alias for debugging
----

TraceAlias ==
    [
        l          |-> l,
        logline    |-> IF l <= Len(TraceLog) THEN logline ELSE "END",
        traceLen   |-> Len(TraceLog),
        state      |-> state,
        currentTerm |-> currentTerm,
        votedFor   |-> votedFor,
        log        |-> [s \in Server |-> [i \in 1..Len(log[s]) |-> log[s][i].term]],
        commitIndex |-> commitIndex,
        matchIndex |-> matchIndex,
        messages   |-> messages
    ]

=============================================================================
