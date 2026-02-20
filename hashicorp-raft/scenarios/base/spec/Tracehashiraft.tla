--------------------------- MODULE Tracehashiraft ---------------------------
\* Trace validation spec for hashicorp/raft.
\*
\* Reads an NDJSON trace file produced by the Go test harness,
\* and replays each event against the base hashiraft spec to verify
\* the implementation matches the specification.

EXTENDS hashiraft, Json, IOUtils, Sequences, TLC

----
\* Trace loading
----

\* Read JSON file path from environment.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/client_request.ndjson"

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
\* hashicorp/raft's BootstrapCluster sets term=1, writes a configuration
\* log entry at index 1 with term 1, and starts all nodes as Followers.
----

BootstrapLog == <<[term |-> 1, type |-> ConfigEntry, config |-> Server]>>

TraceInit ==
    /\ l = 1
    /\ currentTerm      = [s \in Server |-> 1]
    /\ votedFor          = [s \in Server |-> Nil]
    /\ log               = [s \in Server |-> BootstrapLog]
    /\ state             = [s \in Server |-> Follower]
    /\ commitIndex       = [s \in Server |-> 0]
    /\ nextIndex         = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex        = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted      = [s \in Server |-> {}]
    /\ messages          = EmptyBag
    /\ leaseContact      = [s \in Server |-> {}]
    /\ diskBlocked       = [s \in Server |-> FALSE]
    /\ committedConfig   = [s \in Server |-> Server]
    /\ latestConfig      = [s \in Server |-> Server]
    /\ persistedTerm     = [s \in Server |-> 1]
    /\ persistedVotedFor = [s \in Server |-> Nil]
    /\ pendingVote       = [s \in Server |-> Nil]

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

ValidatePostState(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]
    /\ commitIndex'[i] = logline.event.state.commitIndex
    /\ LastLogIndex(i)' = logline.event.state.lastLogIndex
    /\ LastLogTerm(i)' = logline.event.state.lastLogTerm

\* Weaker validation: only check term and role (useful for async events).
ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]

\* Match a votedFor value from trace (string) to spec value (Server or Nil).
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
\* trace events: noop append after BecomeLeader, client Apply().
\* These use base spec actions (ClientRequest) to fill the gap.
----

\* Concurrent timeouts: when multiple nodes timeout simultaneously,
\* the trace may serialize events non-causally (e.g., node A handles
\* node B's vote request before B's BecomeCandidate appears).
\* This fires Timeout without consuming a trace event.
\* Constrained to HandleRequestVoteRequest events only: the msg.from
\* server (candidate) must have timed out to produce the vote request.
SilentTimeout ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleRequestVoteRequest"
    /\ "msg" \in DOMAIN logline.event
    /\ \E i \in Server :
        /\ i = logline.event.msg.from
        /\ state[i] = Follower
        /\ Timeout(i)
        /\ UNCHANGED l

\* Concurrent response processing: replication goroutines call
\* commitment.match() before emitting trace events. The commitment
\* tracker may advance commitIndex (triggering AdvanceCommitIndex on
\* the main goroutine) before the HandleReplicateResponse trace event
\* appears. This fires HandleReplicateResponse without consuming a
\* trace event, so AdvanceCommitIndex can see the updated matchIndex.
\* Constrained: only fires when current matchIndex can't reach
\* the expected commitIndex (prevents spurious branching).
SilentHandleReplicateResponse ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "AdvanceCommitIndex"
    /\ LET i == logline.event.nid
           expectedCI == logline.event.state.commitIndex
           Agree(idx) == {i} \cup {s \in Server : matchIndex[i][s] >= idx}
       IN
       \* Only fire when quorum for expected commitIndex is not yet met
       /\ ~ IsQuorum(Agree(expectedCI) \cap latestConfig[i], latestConfig[i])
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = AppendEntriesResponse
           /\ m.msubtype = "replicate"
           /\ m.mdest = i
           /\ HandleReplicateResponse(i, m)
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

----
\* Action wrappers
\*
\* Each wrapper: (1) matches event type, (2) calls spec action,
\* (3) validates resulting state, (4) advances cursor.
----

\* BecomeCandidate -> Timeout(i)
\* Two cases: (1) normal timeout, (2) already timed out via SilentTimeout.
TimeoutIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("BecomeCandidate", i)
        /\ \/ \* Normal: fire Timeout
              /\ Timeout(i)
              /\ ValidatePostState(i)
              /\ ValidateVotedFor(i)
              /\ StepTrace
           \/ \* Already timed out via SilentTimeout: state matches, just advance
              /\ state[i] = Candidate
              /\ currentTerm[i] = logline.event.state.term
              /\ votedFor[i] = TraceVotedFor(i)
              /\ UNCHANGED vars
              /\ StepTrace

\* HandleRequestVoteResponse -> HandleRequestVoteResponse(i, m)
\* Self-vote skip is a trace logging artifact (impl logs self-vote separately).
\* Stale response discard uses base spec's DropStaleMessage.
\* Transport failure uses base spec's LoseMessage (message already lost).
HandleRequestVoteResponseIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleRequestVoteResponse")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Self-vote: skip (already handled by Timeout)
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
                 \/ \* Transport failure: message was lost (LoseMessage already fired)
                    /\ ~ \E m \in DOMAIN messages :
                            /\ m.mtype = RequestVoteResponse
                            /\ m.msource = logline.event.msg.from
                            /\ m.mdest = i
                    /\ UNCHANGED vars
                    /\ StepTrace

\* HandleRequestVoteRequest -> HandleRequestVoteRequestAtomic(i, m)
\* Leader-check rejection is now modeled in base spec.
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

\* BecomeLeader -> BecomeLeader(i)
BecomeLeaderIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("BecomeLeader", i)
        /\ BecomeLeader(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* SendReplicateEntries -> ReplicateEntries(i, j)
ReplicateEntriesIfLogged ==
    \E i \in Server :
        /\ IsEvent("SendReplicateEntries")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ LET j == logline.event.msg.to IN
            /\ j \in Server
            /\ ReplicateEntries(i, j)
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
\* Disambiguation: heartbeat msgs lack "prevLogIndex" (Go omitempty),
\* replicate msgs always have it (>= 1 in practice).
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
            \* Use prevLogIndex presence to match heartbeat vs replicate
            /\ IF "prevLogIndex" \in DOMAIN logline.event.msg
               THEN m.msubtype = "replicate"
               ELSE m.msubtype = "heartbeat"
            /\ HandleAppendEntriesRequest(i, m)
            /\ ValidatePostState(i)
            /\ StepTrace

\* HandleReplicateResponse -> HandleReplicateResponse(i, m)
\* Already-consumed case: response was processed by SilentHandleReplicateResponse.
HandleReplicateResponseIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleReplicateResponse")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Normal: find matching message in bag
              \E m \in DOMAIN messages :
                /\ m.mtype = AppendEntriesResponse
                /\ m.msubtype = "replicate"
                /\ m.msource = logline.event.msg.from
                /\ m.mdest = i
                /\ m.mmatchIndex = logline.event.msg.matchIndex
                /\ HandleReplicateResponse(i, m)
                /\ ValidatePostStateWeak(i)
                /\ StepTrace
           \/ \* Already consumed by SilentHandleReplicateResponse
              /\ ~ \E m \in DOMAIN messages :
                      /\ m.mtype = AppendEntriesResponse
                      /\ m.msubtype = "replicate"
                      /\ m.msource = logline.event.msg.from
                      /\ m.mdest = i
                      /\ m.mmatchIndex = logline.event.msg.matchIndex
              /\ UNCHANGED vars
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

\* ProposeConfigChange -> ProposeConfigChange(i, s)
ProposeConfigChangeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ProposeConfigChange", i)
        /\ "msg" \in DOMAIN logline.event
        /\ LET s == logline.event.msg.to IN
            /\ ProposeConfigChange(i, s)
            /\ ValidatePostState(i)
            /\ StepTrace

\* AdvanceCommitIndex -> AdvanceCommitIndex(i)
AdvanceCommitIndexIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("AdvanceCommitIndex", i)
        /\ AdvanceCommitIndex(i)
        /\ ValidatePostState(i)
        /\ StepTrace

----
\* Main transition
----

TraceNext ==
    \/ TimeoutIfLogged
    \/ HandleRequestVoteResponseIfLogged
    \/ HandleRequestVoteRequestIfLogged
    \/ BecomeLeaderIfLogged
    \/ ReplicateEntriesIfLogged
    \/ SendHeartbeatIfLogged
    \/ HandleAppendEntriesRequestIfLogged
    \/ HandleReplicateResponseIfLogged
    \/ HandleHeartbeatResponseIfLogged
    \/ AdvanceCommitIndexIfLogged
    \/ ProposeConfigChangeIfLogged
    \* Silent actions (no trace event consumed)
    \/ FillLogGap
    \/ SilentTimeout
    \/ SilentHandleReplicateResponse

----
\* Spec and properties
----

TraceSpec == TraceInit /\ [][TraceNext]_<<l, vars>>

\* View must include cursor position to prevent TLC from
\* collapsing identical states at different trace positions.
TraceView == <<vars, l>>

\* This property checks that the entire trace was consumed.
\* Violation means TLC could not advance past some event.
\* Requires single-worker BFS.
\* Must be a temporal formula (with []) so TLC checks all behaviors,
\* not just the initial state.
TraceMatched ==
    [](l <= Len(TraceLog) => [](TLCGet("queue") = 1 \/ l > Len(TraceLog)))

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
        lease     |-> leaseContact
    ]

=============================================================================
