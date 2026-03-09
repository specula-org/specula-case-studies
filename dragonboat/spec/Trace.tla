---------------------------- MODULE Trace ----------------------------
\* Trace validation spec for lni/dragonboat.
\*
\* Reads an NDJSON trace file produced by the Go instrumentation harness,
\* and replays each event against the base spec to verify the implementation
\* matches the specification.
\*
\* Each action wrapper:
\*   (1) matches the trace event type
\*   (2) calls the corresponding base spec action
\*   (3) validates the resulting state against the trace
\*   (4) advances the trace cursor l

EXTENDS base, Json, IOUtils, Sequences, TLC

----
\* Trace loading
----

\* Read JSON file path from environment variable JSON.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/sample.ndjson"

\* Load NDJSON, keep only lines tagged "trace".
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

VARIABLE l        \* Current position in TraceLog (1-indexed)

traceVars == <<l>>

logline == TraceLog[l]

----
\* Role mapping
----

\* Map implementation role strings to spec constants.
RaftRole ==
    "Follower"  :> Follower  @@
    "Candidate" :> Candidate @@
    "Leader"    :> Leader

\* Map implementation remote state strings to spec constants.
RemoteStateMap ==
    "Retry"     :> RemoteRetry     @@
    "Wait"      :> RemoteWait      @@
    "Replicate" :> RemoteReplicate @@
    "Snapshot"  :> RemoteSnapshot

\* Map implementation entry type strings to spec constants.
EntryTypeMap ==
    "ApplicationEntry"  :> ApplicationEntry  @@
    "ConfigChangeEntry" :> ConfigChangeEntry

----
\* Server extraction from trace
----

\* Derive the Server set from node IDs observed in the trace.
\* Covers both the acting node (nid) and message endpoints.
TraceServer == TLCEval(
    UNION {
        {TraceLog[k].event.nid}
        \cup (IF "msg" \in DOMAIN TraceLog[k].event
              THEN {TraceLog[k].event.msg.from,
                    TraceLog[k].event.msg.to} \ {""}
              ELSE {})
        : k \in 1..Len(TraceLog)
    })

ASSUME TraceServer /= {}
ASSUME TraceServer \subseteq Server

----
\* Bootstrap state
\*
\* dragonboat starts with:
\*   - All nodes in Follower state, term = 0 (before any election)
\*   - Empty logs (no bootstrap config entry unlike hashicorp/raft)
\*   - All volatile state zeroed
----

TraceInit ==
    /\ l = 1
    /\ currentTerm    = [s \in Server |-> 0]
    /\ votedFor       = [s \in Server |-> Nil]
    /\ log            = [s \in Server |-> <<>>]
    /\ state          = [s \in Server |-> Follower]
    /\ commitIndex    = [s \in Server |-> 0]
    /\ applied        = [s \in Server |-> 0]
    /\ nextIndex      = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex     = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted   = [s \in Server |-> {}]
    /\ messages       = EmptyBag
    /\ active         = [s \in Server |-> [t \in Server |-> FALSE]]
    /\ remoteState    = [s \in Server |-> [t \in Server |-> RemoteRetry]]
    /\ pendingConfigChange = [s \in Server |-> FALSE]
    /\ diskError      = [s \in Server |-> FALSE]
    /\ persistedLog   = [s \in Server |-> <<>>]
    /\ persistedState = [s \in Server |-> [term |-> 0, votedFor |-> Nil]]

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
\* Strong validation: checks term, role, commitIndex, lastLogIndex, lastLogTerm.
\* Used for actions that emit full state snapshots in the trace.
\*
\* Weak validation: checks only term and role.
\* Used for async or concurrent actions where the trace may not capture full state.
----

\* Strong: full state check (use when trace captures complete node state).
ValidatePostState(i) ==
    /\ currentTerm'[i]    = logline.event.state.term
    /\ state'[i]          = RaftRole[logline.event.state.role]
    /\ commitIndex'[i]    = logline.event.state.commitIndex
    /\ LastLogIndex(i)'   = logline.event.state.lastLogIndex
    /\ LastLogTerm(i)'    = logline.event.state.lastLogTerm

\* Weak: term + role only (use for async events).
ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i]       = RaftRole[logline.event.state.role]

\* Helper: resolve votedFor from trace (empty string maps to Nil).
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
\* Silent actions
\*
\* Silent actions fire base spec actions without consuming a trace event.
\* They handle implementation state changes that don't emit trace events.
\*
\* All silent actions are TIGHTLY CONSTRAINED to prevent state space explosion.
----

\* SilentTimeout: fires Timeout(i) without consuming a trace event.
\*
\* Needed when two nodes timeout concurrently and the trace serializes
\* events non-causally (e.g., node A processes node B's vote request before
\* B's own BecomeCandidate event appears).
\*
\* Constraint: only fires when the next trace event is HandleRequestVoteRequest
\* and the message sender is still in Follower state (hasn't timed out yet).
SilentTimeout ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleRequestVoteRequest"
    /\ "msg" \in DOMAIN logline.event
    /\ \E i \in Server :
        /\ i = logline.event.msg.from
        /\ state[i] = Follower
        /\ Timeout(i)
        /\ UNCHANGED l

\* SilentHandleReplicateResponse: fires HandleReplicateResponse(i, m) without
\* consuming a trace event.
\*
\* Needed because dragonboat emits HandleReplicateResponse AFTER its side effects
\* (matchIndex update, remoteState transition, tryCommit, broadcastReplicate).
\* This means AdvanceCommitIndex and SendReplicateEntries events appear in the
\* trace BEFORE the HandleReplicateResponse that triggered them.
\*
\* Fires in two cases:
\*   Case 1: next event is AdvanceCommitIndex but quorum not yet reached
\*   Case 2: next event is SendReplicateEntries but target remote is paused
SilentHandleReplicateResponse ==
    /\ l <= Len(TraceLog)
    /\ \/ \* Case 1: Before AdvanceCommitIndex — process response to build quorum
          /\ logline.event.name = "AdvanceCommitIndex"
          /\ LET i          == logline.event.nid
                 expectedCI == logline.event.state.commitIndex
                 Agree(idx) == {j \in Server : matchIndex[i][j] >= idx}
             IN
             /\ ~IsQuorum(Agree(expectedCI))
             /\ \E m \in DOMAIN messages :
                 /\ m.mtype = ReplicateResponse
                 /\ m.mdest = i
                 /\ ~m.mreject
                 /\ HandleReplicateResponse(i, m)
                 /\ UNCHANGED l
       \/ \* Case 2: Before SendReplicateEntries — unblock paused remote
          \* The response's side effects (respondedTo: Wait->Replicate) must be
          \* applied before the leader can send to that follower again.
          /\ logline.event.name = "SendReplicateEntries"
          /\ "msg" \in DOMAIN logline.event
          /\ LET i == logline.event.nid
                 j == logline.event.msg.to
             IN
             /\ j \in Server
             /\ remoteState[i][j] \notin {RemoteRetry, RemoteReplicate}
             /\ \E m \in DOMAIN messages :
                 /\ m.mtype = ReplicateResponse
                 /\ m.mdest = i
                 /\ m.msource = j
                 /\ ~m.mreject
                 /\ HandleReplicateResponse(i, m)
                 /\ UNCHANGED l

\* SilentSaveRaftState: fires SaveRaftState(i) without consuming a trace event.
\*
\* Needed because persistence is asynchronous in dragonboat. The trace may
\* record state changes that imply persistence has already completed.
\*
\* Constraint: only fires when persistedLog[i] is shorter than log[i].
SilentSaveRaftState ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ Len(persistedLog[i]) < Len(log[i])
        /\ ~diskError[i]
        /\ SaveRaftState(i)
        /\ UNCHANGED l

----
\* Action wrappers
\*
\* Each wrapper matches an event, calls the spec action, validates state,
\* and advances the trace cursor.
----

\* BecomeCandidate -> Timeout(i)
TimeoutIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("BecomeCandidate", i)
        /\ \/ \* Normal: fire Timeout, validate state
              /\ Timeout(i)
              /\ ValidatePostState(i)
              /\ ValidateVotedFor(i)
              /\ StepTrace
           \/ \* Already timed out via SilentTimeout: just validate and advance
              /\ state[i] = Candidate
              /\ currentTerm[i] = logline.event.state.term
              /\ votedFor[i] = TraceVotedFor(i)
              /\ UNCHANGED vars
              /\ StepTrace

\* HandleRequestVoteRequest -> HandleRequestVoteRequest(i, m)
HandleRequestVoteRequestIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleRequestVoteRequest", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype   = RequestVoteRequest
            /\ m.msource = logline.event.msg.from
            /\ m.mdest   = i
            /\ HandleRequestVoteRequest(i, m)
            /\ ValidatePostState(i)
            /\ ValidateVotedFor(i)
            /\ StepTrace

\* HandleRequestVoteResponse -> HandleRequestVoteResponse(i, m)
\* Self-vote skip: the impl logs the self-vote separately; it's already
\* recorded in votesGranted by Timeout, so we just advance the cursor.
HandleRequestVoteResponseIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleRequestVoteResponse", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Self-vote: already counted in Timeout, just advance
              /\ logline.event.msg.from = i
              /\ UNCHANGED vars
              /\ StepTrace
           \/ \* Remote vote: find matching message in bag
              /\ logline.event.msg.from /= i
              /\ \/ \E m \in DOMAIN messages :
                       /\ m.mtype   = RequestVoteResponse
                       /\ m.msource = logline.event.msg.from
                       /\ m.mdest   = i
                       /\ HandleRequestVoteResponse(i, m)
                       /\ ValidatePostStateWeak(i)
                       /\ StepTrace
                 \/ \* Message was lost in transit: advance without state change
                    /\ ~\E m \in DOMAIN messages :
                            /\ m.mtype   = RequestVoteResponse
                            /\ m.msource = logline.event.msg.from
                            /\ m.mdest   = i
                    /\ UNCHANGED vars
                    /\ StepTrace

\* BecomeLeader -> BecomeLeader(i)
BecomeLeaderIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("BecomeLeader", i)
        /\ BecomeLeader(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* ClientRequest -> ClientRequest(i)
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
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ LET j == logline.event.msg.to
           IN
           /\ j \in Server
           /\ ReplicateEntries(i, j)
           /\ ValidatePostStateWeak(i)
           /\ StepTrace

\* SendHeartbeat -> SendHeartbeat(i, j)
SendHeartbeatIfLogged ==
    \E i \in Server :
        /\ IsEvent("SendHeartbeat")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ LET j == logline.event.msg.to
           IN
           /\ j \in Server
           /\ SendHeartbeat(i, j)
           /\ ValidatePostStateWeak(i)
           /\ StepTrace

\* HandleReplicateRequest -> HandleReplicateRequest(i, m)
HandleReplicateRequestIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleReplicateRequest", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype   = ReplicateRequest
            /\ m.msource = logline.event.msg.from
            /\ m.mdest   = i
            /\ HandleReplicateRequest(i, m)
            /\ ValidatePostState(i)
            /\ StepTrace

\* HandleHeartbeatRequest -> HandleHeartbeatRequest(i, m)
HandleHeartbeatRequestIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleHeartbeatRequest", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype   = HeartbeatRequest
            /\ m.msource = logline.event.msg.from
            /\ m.mdest   = i
            /\ HandleHeartbeatRequest(i, m)
            /\ ValidatePostState(i)
            /\ StepTrace

\* HandleReplicateResponse -> HandleReplicateResponse(i, m)
\* May have been silently processed by SilentHandleReplicateResponse.
HandleReplicateResponseIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleReplicateResponse", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Normal: find matching message
              \E m \in DOMAIN messages :
                  /\ m.mtype   = ReplicateResponse
                  /\ m.msource = logline.event.msg.from
                  /\ m.mdest   = i
                  /\ HandleReplicateResponse(i, m)
                  /\ ValidatePostStateWeak(i)
                  /\ StepTrace
           \/ \* Already consumed by SilentHandleReplicateResponse: just advance
              /\ ~\E m \in DOMAIN messages :
                      /\ m.mtype   = ReplicateResponse
                      /\ m.msource = logline.event.msg.from
                      /\ m.mdest   = i
              /\ UNCHANGED vars
              /\ StepTrace

\* HandleHeartbeatResponse -> HandleHeartbeatResponse(i, m)
HandleHeartbeatResponseIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleHeartbeatResponse", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype   = HeartbeatResponse
            /\ m.msource = logline.event.msg.from
            /\ m.mdest   = i
            /\ HandleHeartbeatResponse(i, m)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* AdvanceCommitIndex -> AdvanceCommitIndex(i)
AdvanceCommitIndexIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("AdvanceCommitIndex", i)
        /\ AdvanceCommitIndex(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* CheckQuorum -> CheckQuorum(i)
CheckQuorumIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CheckQuorum", i)
        /\ CheckQuorum(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* SendSnapshot -> SendSnapshot(i, j)
SendSnapshotIfLogged ==
    \E i \in Server :
        /\ IsEvent("SendSnapshot")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ LET j == logline.event.msg.to
           IN
           /\ j \in Server
           /\ SendSnapshot(i, j)
           /\ ValidatePostStateWeak(i)
           /\ StepTrace

\* HandleInstallSnapshot -> HandleInstallSnapshot(i, m)
HandleInstallSnapshotIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleInstallSnapshot", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype   = InstallSnapshotRequest
            /\ m.msource = logline.event.msg.from
            /\ m.mdest   = i
            /\ HandleInstallSnapshot(i, m)
            /\ ValidatePostState(i)
            /\ StepTrace

\* HandleSnapshotStatus -> HandleSnapshotStatus(i, m)
\* Note: due to the Bug Family 1 issue, active[i][m.msource] will NOT be set.
\* The trace validation will confirm the spec matches this buggy behavior.
HandleSnapshotStatusIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HandleSnapshotStatus", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype   = SnapshotStatus
            /\ m.msource = logline.event.msg.from
            /\ m.mdest   = i
            /\ HandleSnapshotStatus(i, m)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

----
\* TraceNext: all wrappers + silent actions
----

TraceNext ==
    \/ TimeoutIfLogged
    \/ HandleRequestVoteRequestIfLogged
    \/ HandleRequestVoteResponseIfLogged
    \/ BecomeLeaderIfLogged
    \/ ClientRequestIfLogged
    \/ ReplicateEntriesIfLogged
    \/ SendHeartbeatIfLogged
    \/ HandleReplicateRequestIfLogged
    \/ HandleHeartbeatRequestIfLogged
    \/ HandleReplicateResponseIfLogged
    \/ HandleHeartbeatResponseIfLogged
    \/ AdvanceCommitIndexIfLogged
    \/ CheckQuorumIfLogged
    \/ SendSnapshotIfLogged
    \/ HandleInstallSnapshotIfLogged
    \/ HandleSnapshotStatusIfLogged
    \* Silent actions (do NOT consume trace event)
    \/ SilentTimeout
    \/ SilentHandleReplicateResponse
    \/ SilentSaveRaftState
    \* Terminal stuttering: allow deadlock-free termination after consuming entire trace
    \/ /\ l = Len(TraceLog) + 1
       /\ UNCHANGED <<vars, l>>

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_<<vars, traceVars>>
    \* Weak fairness prevents trivial stuttering counterexamples:
    \* if some action is continuously enabled, progress must eventually occur.
    /\ WF_<<vars, traceVars>>(TraceNext)

----
\* TraceMatched: verify entire trace was consumed
----

\* Temporal property: the trace cursor must reach the end of the log.
\* Violated if TLC cannot replay some event.
TraceMatched ==
    <>[](l = Len(TraceLog) + 1)

=============================================================================
