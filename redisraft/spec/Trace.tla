--------------------------- MODULE Trace ---------------------------
\* Trace validation spec for RedisRaft.
\*
\* Reads an NDJSON trace file produced by the instrumentation harness,
\* and replays each event against the base spec to verify
\* the implementation matches the specification.

EXTENDS base, Json, IOUtils, Sequences, TLC

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

\* Map JSON server ID strings to TLA+ model values
\* TLC model values have string representation matching their name,
\* so ToString(s) = "s1" for model value s1.
ServerMap == TLCEval(
    [s \in {ToString(sv) : sv \in Server} |->
        CHOOSE sv \in Server : ToString(sv) = s])

MapServer(str) == IF str = "" THEN Nil ELSE ServerMap[str]

\* Entry type mapping
EntryTypeMap ==
    "ValueEntry"  :> ValueEntry  @@
    "ConfigEntry" :> ConfigEntry @@
    "NoopEntry"   :> NoopEntry

----
\* Server extraction from trace
----

TraceServerStrings == TLCEval(
    UNION {
        {TraceLog[k].event.nid}
        \cup (IF "msg" \in DOMAIN TraceLog[k].event
              THEN {TraceLog[k].event.msg.from, TraceLog[k].event.msg.to}
                    \ {""}
              ELSE {})
        : k \in 1..Len(TraceLog)
    })

TraceServer == {MapServer(s) : s \in TraceServerStrings}

ASSUME TraceServer /= {}
ASSUME TraceServer \subseteq Server

----
\* Bootstrap state
\*
\* RedisRaft initializes with term=0 and empty log.
\* Reference: raft_server.c init (term=0, votedFor=NONE)
----

TraceInit ==
    /\ l = 1
    /\ currentTerm       = [s \in Server |-> 0]
    /\ votedFor           = [s \in Server |-> Nil]
    /\ log                = [s \in Server |-> <<>>]
    /\ logOffset          = [s \in Server |-> 0]
    /\ state              = [s \in Server |-> Follower]
    /\ commitIndex        = [s \in Server |-> 0]
    /\ nextIndex          = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex         = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted       = [s \in Server |-> {}]
    /\ messages           = EmptyBag
    /\ snapshotLastIdx    = [s \in Server |-> 0]
    /\ snapshotLastTerm   = [s \in Server |-> 0]
    /\ loadingSnapshot    = [s \in Server |-> FALSE]
    /\ pendingSnapshotIdx = [s \in Server |-> 0]
    /\ pendingSnapshotTerm = [s \in Server |-> 0]
    /\ staleReadDetected  = FALSE
    /\ noopReadDetected   = FALSE
    /\ clusterConfig      = [s \in Server |-> Server]
    /\ votingCfgChangeIdx = [s \in Server |-> 0]

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
\* Use for events that capture state AFTER all updates.
\*
\* Weak: validates only term and role.
\* Use for events where the trace captures state before log/commit updates.
----

ValidatePostState(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]
    /\ commitIndex'[i] = logline.event.state.commitIndex
    /\ LastLogIndex(i)' = logline.event.state.lastLogIndex
    /\ LastLogTerm(i)' = logline.event.state.lastLogTerm

ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]

ValidatePostStateCommit(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]
    /\ commitIndex'[i] = logline.event.state.commitIndex

TraceVotedFor(i) ==
    LET v == logline.event.state.votedFor
    IN MapServer(v)

ValidateVotedFor(i) ==
    votedFor'[i] = TraceVotedFor(i)

----
\* Step trace cursor
----

StepTrace == l' = l + 1

----
\* Silent actions (no trace event consumed)
----

\* Leader's noop append after election is not directly traced.
\* The trace shows BecomeLeader, then the log is longer.
SilentBecomeLeader ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ state[i] = Candidate
        /\ IsQuorum(votesGranted[i], EffectiveConfig(i))
        /\ BecomeLeader(i)
        /\ UNCHANGED l

\* Leader appends entry (noop or client request) without trace event.
\* Needed when the trace shows a post-state with more entries than the spec.
SilentAppendEntry ==
    /\ l <= Len(TraceLog)
    \* Don't fire when the traced event will do the append itself
    /\ logline.event.name /= "ClientRequest"
    /\ LET nid == MapServer(logline.event.nid)
       IN
       /\ state[nid] = Leader
       /\ "state" \in DOMAIN logline.event
       /\ "lastLogIndex" \in DOMAIN logline.event.state
       /\ LastLogIndex(nid) < logline.event.state.lastLogIndex
       /\ ClientRequest(nid)
       /\ UNCHANGED l

\* SendAppendEntries: leader sends entries to a follower.
\* The send event is usually not traced; only the receive is.
SilentSendAppendEntries ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleAppendEntriesRequest"
    /\ "msg" \in DOMAIN logline.event
    /\ LET from == MapServer(logline.event.msg.from)
           to   == MapServer(logline.event.nid)
       IN
       \* Only create the message if not already in the bag
       /\ ~ \E m \in DOMAIN messages :
               /\ m.mtype = AppendEntriesRequest
               /\ m.msource = from
               /\ m.mdest = to
       /\ state[from] = Leader
       /\ AppendEntries(from, to)
       /\ UNCHANGED l

\* SendInstallSnapshot: leader sends snapshot to lagging follower.
SilentSendInstallSnapshot ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleInstallSnapshotRequest"
    /\ "msg" \in DOMAIN logline.event
    /\ LET from == MapServer(logline.event.msg.from)
           to   == MapServer(logline.event.nid)
       IN
       /\ ~ \E m \in DOMAIN messages :
               /\ m.mtype = InstallSnapshotRequest
               /\ m.msource = from
               /\ m.mdest = to
       /\ state[from] = Leader
       /\ SendInstallSnapshot(from, to)
       /\ UNCHANGED l

\* Advance commit index without a trace event.
\* Needed when the trace shows a higher commitIndex than the spec.
SilentAdvanceCommitIndex ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ state[i] = Leader
        /\ "state" \in DOMAIN logline.event
        /\ "commitIndex" \in DOMAIN logline.event.state
        /\ MapServer(logline.event.nid) = i
        /\ commitIndex[i] < logline.event.state.commitIndex
        /\ AdvanceCommitIndex(i)
        /\ UNCHANGED l

\* End snapshot load without a direct trace event.
SilentEndLoadSnapshot ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ loadingSnapshot[i] = TRUE
        /\ EndLoadSnapshot(i)
        /\ UNCHANGED l

\* Silent Timeout for elections not directly observed.
SilentTimeout ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleRequestVoteRequest"
    /\ "msg" \in DOMAIN logline.event
    /\ \E i \in Server :
        /\ i = MapServer(logline.event.msg.from)
        /\ state[i] \in {Follower, Candidate}
        \* Only fire if sender hasn't already started this election
        /\ ~ \E m \in DOMAIN messages :
                /\ m.mtype = RequestVoteRequest
                /\ m.msource = i
        /\ Timeout(i)
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

\* BecomeLeader -> BecomeLeader(i)
BecomeLeaderIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("BecomeLeader", i)
        /\ \/ /\ BecomeLeader(i)
              /\ ValidatePostState(i)
              /\ StepTrace
           \/ \* Already became leader via SilentBecomeLeader
              /\ state[i] = Leader
              /\ currentTerm[i] = logline.event.state.term
              /\ UNCHANGED vars
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
           \/ \* Transport failure — message not in bag
              /\ ~ \E m \in DOMAIN messages :
                      /\ m.mtype = RequestVoteResponse
                      /\ m.msource = MapServer(logline.event.msg.from)
                      /\ m.mdest = i
              /\ UNCHANGED vars
              /\ StepTrace

\* ClientRequest -> ClientRequest(i)
ClientRequestIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ClientRequest", i)
        /\ ClientRequest(i)
        /\ ValidatePostState(i)
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
           \/ \* Transport failure
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
        /\ \/ \* Normal advance
              /\ AdvanceCommitIndex(i)
              /\ ValidatePostStateCommit(i)
           \/ \* Already advanced by SilentAdvanceCommitIndex — idempotent
              /\ commitIndex[i] = logline.event.state.commitIndex
              /\ UNCHANGED vars
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
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* EndLoadSnapshot -> EndLoadSnapshot(i)
EndLoadSnapshotIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("EndLoadSnapshot", i)
        /\ EndLoadSnapshot(i)
        /\ StepTrace

\* TakeSnapshot -> TakeSnapshot(i)
TakeSnapshotIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("TakeSnapshot", i)
        /\ TakeSnapshot(i)
        /\ StepTrace

\* ProposeAddServer -> ProposeAddServer(i, target)
ProposeAddServerIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ProposeAddServer", i)
        /\ "target" \in DOMAIN logline.event
        /\ \E target \in Server :
            /\ target = MapServer(logline.event.target)
            /\ ProposeAddServer(i, target)
            /\ ValidatePostState(i)
            /\ StepTrace

\* ProposeRemoveServer -> ProposeRemoveServer(i, target)
ProposeRemoveServerIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ProposeRemoveServer", i)
        /\ "target" \in DOMAIN logline.event
        /\ \E target \in Server :
            /\ target = MapServer(logline.event.target)
            /\ ProposeRemoveServer(i, target)
            /\ ValidatePostState(i)
            /\ StepTrace

\* Crash -> Crash(i)
CrashIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Crash", i)
        /\ Crash(i)
        /\ StepTrace

----
\* TraceNext — combined next-state relation
----

TraceNext ==
    \* Traced actions (consume one trace event)
    \/ TimeoutIfLogged
    \/ BecomeLeaderIfLogged
    \/ HandleRequestVoteRequestIfLogged
    \/ HandleRequestVoteResponseIfLogged
    \/ ClientRequestIfLogged
    \/ HandleAppendEntriesRequestIfLogged
    \/ HandleAppendEntriesResponseIfLogged
    \/ AdvanceCommitIndexIfLogged
    \/ HandleInstallSnapshotRequestIfLogged
    \/ EndLoadSnapshotIfLogged
    \/ TakeSnapshotIfLogged
    \/ ProposeAddServerIfLogged
    \/ ProposeRemoveServerIfLogged
    \/ CrashIfLogged
    \* Silent actions (do not consume a trace event)
    \/ SilentBecomeLeader
    \/ SilentAppendEntry
    \/ SilentSendAppendEntries
    \/ SilentSendInstallSnapshot
    \/ SilentAdvanceCommitIndex
    \/ SilentEndLoadSnapshot
    \/ SilentTimeout
    \* Termination: trace fully consumed — self-loop
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED <<vars, l>>

----
\* Trace completion
\*
\* We use INIT/NEXT (not SPECIFICATION) so TLC checks for deadlock.
\* The trace is "matched" when l reaches Len(TraceLog)+1.
\* If TLC reports deadlock before that, an event couldn't match.
----

TraceMatched == <>(l = Len(TraceLog) + 1)

trace_vars == <<vars, traceVars>>

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_trace_vars

=============================================================================
