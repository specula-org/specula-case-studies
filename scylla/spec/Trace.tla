--------------------------- MODULE Trace ---------------------------
\* Trace validation spec for ScyllaDB Raft library.
\*
\* Reads an NDJSON trace file produced by the instrumentation harness,
\* and replays each event against the base spec to verify
\* the implementation matches the specification.
\*
\* Key design decisions for trace validation:
\*  - Pipeline AppendEntries: sends 1 entry per message (matching Scylla's replicate_to)
\*  - BecomeLeader ordering: impl emits ClientRequest (dummy) BEFORE BecomeLeader;
\*    the combined action is handled by TraceClientRequest when state transitions.
\*  - MaybeCommit ordering: impl emits MaybeCommit INSIDE append_entries_reply,
\*    BEFORE the HandleAppendEntriesResponse event. TraceMaybeCommit is trace-driven.
\*  - No SilentLoseMessage: controlled test harness delivers all messages reliably.

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

----
\* Server extraction from trace
----

TraceServer == TLCEval(
    UNION {
        LET evt == TraceLog[k].event IN
        {evt.nid}
        \cup (IF "msg" \in DOMAIN evt
              THEN (  {evt.msg.from}
                    \cup IF "to" \in DOMAIN evt.msg
                        THEN {evt.msg.to}
                        ELSE {} ) \ {""}
              ELSE {})
        : k \in 1..Len(TraceLog)
    })

ASSUME TraceServer /= {}
ASSUME TraceServer \subseteq Server

----
\* Bootstrap state
\*
\* ScyllaDB Raft initializes with term=0, empty log, all followers.
\* Reference: fsm.cc:23-45 (fsm constructor)
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
    /\ currentVoters     = [s \in Server |-> Server]
    /\ previousVoters    = [s \in Server |-> {}]
    /\ lastReadId          = [s \in Server |-> 0]
    /\ maxReadIdWithQuorum = [s \in Server |-> 0]
    /\ maxAckedRead        = [s \in Server |-> [t \in Server |-> 0]]
    /\ snapshotIdx       = [s \in Server |-> 0]
    /\ snapshotTerm      = [s \in Server |-> 0]
    /\ fdView            = [s \in Server |-> Server]

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
    /\ logline.event.msg.from = from
    /\ logline.event.msg.to = to

----
\* Post-state validation
----

\* Post-state log index (uses primed variables)
LastLogIndex_prime(i) == Len(log'[i]) + snapshotIdx'[i]

\* Strong validation: check all observable state fields (post-state = primed)
ValidatePostState(i) ==
    /\ currentTerm'[i]  = logline.event.state.term
    /\ state'[i]        = RaftRole[logline.event.state.role]
    /\ commitIndex'[i]  = logline.event.state.commitIndex
    /\ LastLogIndex_prime(i)  = logline.event.state.lastLogIndex

\* Weak validation: check only term + role (post-state = primed)
ValidatePostStateWeak(i) ==
    /\ currentTerm'[i]  = logline.event.state.term
    /\ state'[i]        = RaftRole[logline.event.state.role]

----
\* Action wrappers
----

\* Timeout: server starts election
TraceTimeout ==
    /\ IsEvent("Timeout")
    /\ LET i == logline.event.nid
       IN /\ Timeout(i)
          /\ ValidatePostState(i)
    /\ l' = l + 1

\* BecomeLeader: candidate wins election.
\* Two cases:
\*   (a) Normal: spec still has server as Candidate → perform BecomeLeader
\*   (b) Already leader: BecomeLeader was consumed by the preceding ClientRequest
\*       (dummy entry). Just validate and advance.
TraceBecomeLeader ==
    /\ IsEvent("BecomeLeader")
    /\ LET i == logline.event.nid
       IN \/ \* (a) Normal case
             /\ state[i] = Candidate
             /\ BecomeLeader(i)
             /\ ValidatePostStateWeak(i)
          \/ \* (b) Already became leader via combined ClientRequest/BecomeLeader
             /\ state[i] = Leader
             /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                            configVars, readVars, snapshotVars, fdVars>>
             /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* ClientRequest: leader appends entry.
\* Two cases:
\*   (a) Normal: server is already Leader → append entry
\*   (b) Dummy entry from BecomeLeader: server is still Candidate in spec,
\*       but trace shows Leader. Perform BecomeLeader (which appends dummy).
\*       This happens because Scylla's become_leader() calls add_entry(dummy)
\*       which emits ClientRequest BEFORE the BecomeLeader event.
TraceClientRequest ==
    /\ IsEvent("ClientRequest")
    /\ LET i == logline.event.nid
       IN \/ \* (a) Normal: leader appends entry
             /\ state[i] = Leader
             /\ ClientRequest(i)
             /\ ValidatePostState(i)
          \/ \* (b) Dummy entry: BecomeLeader includes the dummy append
             /\ state[i] = Candidate
             /\ logline.event.state.role = "Leader"
             /\ BecomeLeader(i)
             /\ ValidatePostState(i)
    /\ l' = l + 1

\* AppendEntries: leader sends to follower (pipeline mode).
\* Scylla's replicate_to sends entries one at a time.
\* Uses trace fields (prevLogIdx, numEntries) to construct the exact message,
\* and advances nextIndex for pipeline tracking.
TraceAppendEntries ==
    /\ IsEvent("AppendEntries")
    /\ LET from == logline.event.msg.from
           to   == logline.event.msg.to
           prevIdx == logline.event.msg.prevLogIdx
           numE == logline.event.msg.numEntries
       IN /\ state[from] = Leader
          /\ from /= to
          /\ prevIdx >= snapshotIdx[from]
          /\ LET prevTerm == LogTerm(from, prevIdx)
                 entries == IF numE = 0 THEN <<>>
                            ELSE SubSeq(log[from],
                                        prevIdx + 1 - snapshotIdx[from],
                                        prevIdx + numE - snapshotIdx[from])
             IN
             /\ Send([mtype            |-> AppendEntriesRequest,
                      mterm            |-> currentTerm[from],
                      mprevLogIdx      |-> prevIdx,
                      mprevLogTerm     |-> prevTerm,
                      mentries         |-> entries,
                      mleaderCommitIdx |-> commitIndex[from],
                      msource          |-> from,
                      mdest            |-> to])
          \* Pipeline: advance nextIndex past sent entries
          /\ nextIndex' = [nextIndex EXCEPT ![from][to] = prevIdx + numE + 1]
          /\ UNCHANGED <<serverVars, logVars, matchIndex, candidateVars,
                         configVars, readVars, snapshotVars, fdVars>>
          /\ ValidatePostStateWeak(from)
    /\ l' = l + 1

\* HandleAppendEntriesRequest: follower processes append.
\* Constrained: message must be from the right source and produce the expected
\* lastLogIndex (to disambiguate pipelined messages in the bag).
TraceHandleAppendEntriesRequest ==
    /\ IsEvent("HandleAppendEntriesRequest")
    /\ LET i == logline.event.nid
           expectedLastLogIdx == logline.event.state.lastLogIndex
       IN \E m \in DOMAIN messages :
           /\ m.mtype = AppendEntriesRequest
           /\ m.mdest = i
           /\ m.msource = logline.event.msg.from
           /\ m.mterm = currentTerm[i]
           \* Disambiguate pipelined messages: result must match expected log length
           /\ m.mprevLogIdx + Len(m.mentries) = expectedLastLogIdx
           /\ HandleAppendEntriesRequest(i, m.msource, m)
           /\ ValidatePostState(i)
    /\ l' = l + 1

\* HandleAppendEntriesResponse: leader processes reply.
\* Constrained: match on source and matchIdx from trace to pick the right response.
TraceHandleAppendEntriesResponse ==
    /\ IsEvent("HandleAppendEntriesResponse")
    /\ LET i == logline.event.nid
       IN \E m \in DOMAIN messages :
           /\ m.mtype = AppendEntriesResponse
           /\ m.mdest = i
           /\ m.msource = logline.event.msg.from
           /\ m.mterm = currentTerm[i]
           /\ m.mmatchIdx = logline.event.msg.matchIdx
           /\ HandleAppendEntriesResponse(i, m.msource, m)
           /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* HandleRequestVoteRequest: server processes vote request.
\* Constrained: match on source from trace.
TraceHandleRequestVoteRequest ==
    /\ IsEvent("HandleRequestVoteRequest")
    /\ LET i == logline.event.nid
       IN \E m \in DOMAIN messages :
           /\ m.mtype = RequestVoteRequest
           /\ m.mdest = i
           /\ m.msource = logline.event.msg.from
           /\ m.mterm = currentTerm[i]
           /\ HandleRequestVoteRequest(i, m.msource, m)
           /\ ValidatePostState(i)
    /\ l' = l + 1

\* HandleRequestVoteResponse: candidate processes vote reply.
\* Constrained: match on source and voteGranted from trace.
TraceHandleRequestVoteResponse ==
    /\ IsEvent("HandleRequestVoteResponse")
    /\ LET i == logline.event.nid
       IN \E m \in DOMAIN messages :
           /\ m.mtype = RequestVoteResponse
           /\ m.mdest = i
           /\ m.msource = logline.event.msg.from
           /\ m.mterm = currentTerm[i]
           /\ m.mvoteGranted = logline.event.msg.voteGranted
           /\ HandleRequestVoteResponse(i, m.msource, m)
           /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* MaybeCommit: leader advances commit index.
\* Trace-driven: trust the trace's commitIndex because MaybeCommit fires INSIDE
\* append_entries_reply (before HandleAppendEntriesResponse), so the spec's
\* matchIndex hasn't been updated yet. Validate basic constraints instead of JointAgree.
TraceMaybeCommit ==
    /\ IsEvent("MaybeCommit")
    /\ LET i == logline.event.nid
           newCI == logline.event.state.commitIndex
       IN /\ state[i] = Leader
          /\ newCI > commitIndex[i]
          /\ newCI <= LastLogIndex(i)
          /\ LogTerm(i, newCI) = currentTerm[i]
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCI]
          \* Handle leave_joint: if a joint config was committed, append non-joint
          /\ IF /\ IsJoint(i)
                /\ \E k \in 1..Len(log[i]) :
                    /\ log[i][k].type = ConfigEntry
                    /\ k + snapshotIdx[i] > commitIndex[i]
                    /\ k + snapshotIdx[i] <= newCI
             THEN
              /\ log' = [log EXCEPT ![i] = Append(@,
                  [term |-> currentTerm[i], type |-> ConfigEntry,
                   cv |-> currentVoters[i], pv |-> {}])]
              /\ previousVoters' = [previousVoters EXCEPT ![i] = {}]
              /\ UNCHANGED currentVoters
             ELSE
              /\ UNCHANGED <<log, configVars>>
          /\ UNCHANGED <<currentTerm, votedFor, state, leaderVars, candidateVars,
                         messages, readVars, snapshotVars, fdVars>>
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* BroadcastReadQuorum: leader starts read barrier
TraceBroadcastReadQuorum ==
    /\ IsEvent("BroadcastReadQuorum")
    /\ LET i == logline.event.nid
       IN /\ BroadcastReadQuorum(i)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* HandleReadQuorumRequest: follower processes read quorum
TraceHandleReadQuorumRequest ==
    /\ IsEvent("HandleReadQuorumRequest")
    /\ LET i == logline.event.nid
       IN \E m \in DOMAIN messages :
           /\ m.mtype = ReadQuorumRequest
           /\ m.mdest = i
           /\ m.mterm = currentTerm[i]
           /\ HandleReadQuorumRequest(i, m.msource, m)
           /\ ValidatePostState(i)
    /\ l' = l + 1

\* HandleReadQuorumResponse: leader processes read quorum reply
TraceHandleReadQuorumResponse ==
    /\ IsEvent("HandleReadQuorumResponse")
    /\ LET i == logline.event.nid
       IN \E m \in DOMAIN messages :
           /\ m.mtype = ReadQuorumResponse
           /\ m.mdest = i
           /\ m.mterm = currentTerm[i]
           /\ HandleReadQuorumResponse(i, m.msource, m)
           /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* HandleInstallSnapshot: follower applies snapshot
TraceHandleInstallSnapshot ==
    /\ IsEvent("HandleInstallSnapshot")
    /\ LET i == logline.event.nid
       IN \E m \in DOMAIN messages :
           /\ m.mtype = InstallSnapshotRequest
           /\ m.mdest = i
           /\ m.mterm = currentTerm[i]
           /\ HandleInstallSnapshot(i, m.msource, m)
           /\ ValidatePostState(i)
    /\ l' = l + 1

\* SendInstallSnapshot: leader sends snapshot
TraceSendInstallSnapshot ==
    /\ IsEvent("SendInstallSnapshot")
    /\ LET from == logline.event.msg.from
           to   == logline.event.msg.to
       IN /\ SendInstallSnapshot(from, to)
          /\ ValidatePostStateWeak(from)
    /\ l' = l + 1

\* TakeLocalSnapshot: server takes local snapshot
TraceTakeLocalSnapshot ==
    /\ IsEvent("TakeLocalSnapshot")
    /\ LET i == logline.event.nid
       IN /\ TakeLocalSnapshot(i)
          /\ ValidatePostState(i)
    /\ l' = l + 1

\* Crash: server crashes
TraceCrash ==
    /\ IsEvent("Crash")
    /\ LET i == logline.event.nid
       IN /\ Crash(i)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* UpdateTerm: server updates term from higher-term message.
\* Constrained: message term must equal the expected new term.
TraceUpdateTerm ==
    /\ IsEvent("UpdateTerm")
    /\ LET i == logline.event.nid
           expectedTerm == logline.event.state.term
       IN \E m \in DOMAIN messages :
           /\ m.mdest = i
           /\ m.mterm = expectedTerm
           /\ m.mterm > currentTerm[i]
           /\ UpdateTerm(i, m.msource, m)
           /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* ProposeConfigChange: leader proposes config change
TraceProposeConfigChange ==
    /\ IsEvent("ProposeConfigChange")
    /\ LET i == logline.event.nid
           newV == {logline.event.newVoters[k] :
                    k \in DOMAIN logline.event.newVoters}
       IN /\ ProposeConfigChange(i, newV)
          /\ ValidatePostState(i)
    /\ l' = l + 1

----
\* Silent actions
\*
\* Handle state changes that occur without a trace event.
\* Each must be tightly constrained to avoid state explosion.
----

\* Silent MaybeCommit: leader commits without explicit trace event.
\* Trace-driven: trusts the trace's expected commitIndex.
\* Constrained: only when next trace event for this server requires higher commit,
\* and that event is NOT an explicit MaybeCommit (avoid preempting).
SilentMaybeCommit ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name /= "MaybeCommit"
    /\ \E i \in Server :
        /\ state[i] = Leader
        /\ logline.event.nid = i
        /\ "state" \in DOMAIN logline.event
        /\ logline.event.state.commitIndex > commitIndex[i]
        /\ logline.event.state.commitIndex <= LastLogIndex(i)
        /\ commitIndex' = [commitIndex EXCEPT ![i] = logline.event.state.commitIndex]
        /\ UNCHANGED <<currentTerm, votedFor, state, log, leaderVars, candidateVars,
                       messages, configVars, readVars, snapshotVars, fdVars>>
    /\ UNCHANGED l

\* Silent AppendEntries: leader sends append without trace event.
\* Pipeline mode: sends one entry at a time, advances nextIndex.
\* Constrained: only when a message-receiving event is next.
SilentAppendEntries ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"HandleAppendEntriesRequest", "HandleInstallSnapshot"}
    /\ \E i, j \in Server :
        /\ i /= j
        /\ state[i] = Leader
        /\ nextIndex[i][j] <= LastLogIndex(i)
        /\ LET prevIdx == nextIndex[i][j] - 1
               prevTerm == LogTerm(i, prevIdx)
               entryIdx == nextIndex[i][j]
               entry == log[i][entryIdx - snapshotIdx[i]]
           IN
           /\ prevIdx >= snapshotIdx[i]
           /\ Send([mtype            |-> AppendEntriesRequest,
                    mterm            |-> currentTerm[i],
                    mprevLogIdx      |-> prevIdx,
                    mprevLogTerm     |-> prevTerm,
                    mentries         |-> <<entry>>,
                    mleaderCommitIdx |-> commitIndex[i],
                    msource          |-> i,
                    mdest            |-> j])
           /\ nextIndex' = [nextIndex EXCEPT ![i][j] = entryIdx + 1]
    /\ UNCHANGED <<serverVars, logVars, matchIndex, candidateVars,
                   configVars, readVars, snapshotVars, fdVars>>
    /\ UNCHANGED l

\* Silent UpdateTerm: term update from message without explicit event.
\* Constrained: must match the expected term, and must NOT preempt
\* an explicit UpdateTerm event.
SilentUpdateTerm ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name /= "UpdateTerm"
    /\ \E i \in Server :
        /\ "state" \in DOMAIN logline.event
        /\ logline.event.nid = i
        /\ logline.event.state.term > currentTerm[i]
        /\ \E m \in DOMAIN messages :
            /\ m.mdest = i
            /\ m.mterm = logline.event.state.term
            /\ m.mterm > currentTerm[i]
            /\ UpdateTerm(i, m.msource, m)
    /\ UNCHANGED l

\* Silent DropStaleMessage: stale message dropped.
\* Constrained: only drop messages for the current trace event's server.
SilentDropStaleMessage ==
    /\ l <= Len(TraceLog)
    /\ \E m \in DOMAIN messages :
        /\ \E i \in Server :
            /\ m.mdest = i
            /\ logline.event.nid = i
            /\ m.mterm < currentTerm[i]
            /\ DropStaleMessage(i, m.msource, m)
    /\ UNCHANGED l

----
\* TraceNext and TraceSpec
----

TraceNext ==
    \/ TraceTimeout
    \/ TraceBecomeLeader
    \/ TraceClientRequest
    \/ TraceAppendEntries
    \/ TraceHandleAppendEntriesRequest
    \/ TraceHandleAppendEntriesResponse
    \/ TraceHandleRequestVoteRequest
    \/ TraceHandleRequestVoteResponse
    \/ TraceMaybeCommit
    \/ TraceBroadcastReadQuorum
    \/ TraceHandleReadQuorumRequest
    \/ TraceHandleReadQuorumResponse
    \/ TraceHandleInstallSnapshot
    \/ TraceSendInstallSnapshot
    \/ TraceTakeLocalSnapshot
    \/ TraceCrash
    \/ TraceUpdateTerm
    \/ TraceProposeConfigChange
    \* Silent actions
    \/ SilentMaybeCommit
    \/ SilentAppendEntries
    \/ SilentUpdateTerm
    \/ SilentDropStaleMessage
    \* No SilentLoseMessage: controlled test harness delivers all messages

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, traceVars>>

----
\* TraceMatched: verify entire trace was consumed
----

TraceMatched == <>(l = Len(TraceLog) + 1)

----
\* Alias for TLC trace output
----

TraceAlias ==
    [
        l         |-> l,
        event     |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
        server    |-> IF l <= Len(TraceLog) THEN logline.event.nid ELSE "DONE",
        terms     |-> [s \in Server |-> currentTerm[s]],
        states    |-> [s \in Server |-> state[s]],
        commits   |-> [s \in Server |-> commitIndex[s]],
        logLens   |-> [s \in Server |-> LastLogIndex(s)],
        msgCount  |-> BagCardinality(messages)
    ]

====
