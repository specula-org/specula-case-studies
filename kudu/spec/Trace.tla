--------------------------- MODULE Trace ---------------------------
\* Trace validation spec for Apache Kudu Raft consensus.
\*
\* Reads an NDJSON trace file produced by the C++ test harness,
\* and replays each event against the base spec to verify
\* the implementation matches the specification.

EXTENDS base, Json, IOUtils, Sequences, TLC

----
\* Trace loading
----

\* Read JSON file path from environment or use default.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

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
\* Maps implementation role strings to spec constants.
\* Reference: metadata.proto:70-91 (RaftPeerPB::Role)
----

RaftRole ==
    "Follower"  :> Follower  @@
    "Candidate" :> Candidate @@
    "Leader"    :> Leader

----
\* Server extraction from trace
\* Derive the Server set from all node IDs that appear in trace events.
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
\* Kudu consensus starts with term=0, empty log, all Followers.
\* This matches the base spec Init.
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
    /\ committedConfig   = [s \in Server |-> Server]
    /\ pendingConfig     = [s \in Server |-> Nil]
    /\ hasCommittedInTerm = [s \in Server |-> FALSE]
    /\ withholdVotes     = [s \in Server |-> FALSE]
    /\ memberType        = [s \in Server |-> "Voter"]

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

\* Strong validation: check term, role, commitIndex, lastLogIndex, lastLogTerm
ValidatePostState(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]
    /\ commitIndex'[i] = logline.event.state.commitIndex
    /\ LastLogIndex(i)' = logline.event.state.lastLogIndex
    /\ LastLogTerm(i)' = logline.event.state.lastLogTerm

\* Weak validation: only check term and role (for async events
\* where trace may not capture full state).
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
\* trace events. These fire base spec actions without advancing l.
\*
\* *** All silent actions are tightly constrained to prevent
\* state space explosion. ***
----

\* Concurrent timeouts: when multiple nodes timeout simultaneously,
\* the trace may serialize events non-causally.
\* Constrained: only fires when next event is HandleRequestVoteRequest
\* and the msg.from (candidate) must be a Follower that needs to timeout.
SilentTimeout ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleRequestVoteRequest"
    /\ "msg" \in DOMAIN logline.event
    /\ \E i \in Server :
        /\ i = logline.event.msg.from
        /\ state[i] = Follower
        /\ Timeout(i)
        /\ UNCHANGED l

\* Leader appends entry (noop or client request) without trace event.
\* Fires when the current trace event expects a longer leader log.
\* Constrained: only fires when current log is shorter than expected.
FillLogGap ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name /= "ProposeConfigChange"
    /\ LET nid == logline.event.nid
       IN
       /\ state[nid] = Leader
       /\ \/ \* Full state: event state shows higher lastLogIndex
             /\ "lastLogIndex" \in DOMAIN logline.event.state
             /\ LastLogIndex(nid) < logline.event.state.lastLogIndex
          \/ \* SendEntries: need enough entries for the message
             /\ logline.event.name = "SendEntries"
             /\ "msg" \in DOMAIN logline.event
             /\ "numEntries" \in DOMAIN logline.event.msg
             /\ LastLogIndex(nid) < logline.event.msg.prevLogIndex + logline.event.msg.numEntries
       /\ ClientRequest(nid)
       /\ UNCHANGED l

\* Concurrent response processing: commit index needs matchIndex update
\* before AdvanceCommitIndex trace event.
SilentHandleAppendEntriesResponse ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "AdvanceCommitIndex"
    /\ LET i == logline.event.nid
           expectedCI == logline.event.state.commitIndex
           Agree(idx) == {i} \cup {s \in Server :
                           matchIndex[i][s] >= idx /\ memberType[s] = "Voter"}
       IN
       \* Only fire when quorum for expected commitIndex is not yet met
       /\ ~ IsQuorum(Agree(expectedCI) \cap ActiveVoters(i), ActiveVoters(i))
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = AppendEntriesResponse
           /\ m.mdest = i
           /\ HandleAppendEntriesResponse(i, m)
           /\ UNCHANGED l

\* Peer thread retries send after LMP mismatch. The response processing
\* happens on the peer thread without a visible trace event. We process
\* the response silently so nextIndex gets decremented for the next send.
\* Constrained: only fires before a SendEntries event where the spec's
\* nextIndex would produce a different prevLogIndex than the trace shows.
SilentHandleAppendEntriesResponseForRetry ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "SendEntries"
    /\ "msg" \in DOMAIN logline.event
    /\ LET i == logline.event.nid
           j == logline.event.msg.to
           expectedPrevIdx == logline.event.msg.prevLogIndex
       IN
       /\ state[i] = Leader
       /\ nextIndex[i][j] - 1 /= expectedPrevIdx
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = AppendEntriesResponse
           /\ m.mdest = i
           /\ m.msource = j
           /\ HandleAppendEntriesResponse(i, m)
           /\ UNCHANGED l

\* Leader sends entries to peer without a visible trace event.
\* Fires when the next trace event is HandleAppendEntriesRequest
\* but no matching AppendEntriesRequest (with correct prevLogIndex) is in the bag.
SilentSendEntries ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleAppendEntriesRequest"
    /\ "msg" \in DOMAIN logline.event
    /\ LET dest == logline.event.nid
       IN
       /\ ~ \E m \in DOMAIN messages :
               /\ m.mtype = AppendEntriesRequest
               /\ m.mdest = dest
               /\ m.mprevLogIndex = logline.event.msg.prevLogIndex
       /\ \E i \in Server :
           /\ state[i] = Leader
           /\ SendEntries(i, dest)
           /\ UNCHANGED l

\* Commit index advancement without trace event.
\* In the implementation, ResponseFromPeer advances commitIndex synchronously,
\* but the AdvanceCommitIndex trace event fires asynchronously via observer.
\* Meanwhile, SendEntries carries the already-updated commitIndex.
\* Constrained: only fires before SendEntries when msg.commitIndex > leader's commitIndex.
SilentAdvanceCommitIndex ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "SendEntries"
    /\ "msg" \in DOMAIN logline.event
    /\ "commitIndex" \in DOMAIN logline.event.msg
    /\ LET i == logline.event.nid
       IN
       /\ state[i] = Leader
       /\ commitIndex[i] < logline.event.msg.commitIndex
       /\ AdvanceCommitIndex(i)
       /\ UNCHANGED l

\* Follower processes AppendEntriesRequest rejection silently.
\* When a peer thread retries (SendEntries with lower prevLogIndex),
\* the initial request was rejected without a trace event (only successful
\* HandleAppendEntriesRequest events are traced). This processes the
\* pending AER so the rejection response enters the message bag.
\* Constrained: only fires before SendEntries retry when nextIndex mismatch.
SilentHandleAppendEntriesRequestReject ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "SendEntries"
    /\ "msg" \in DOMAIN logline.event
    /\ LET i == logline.event.nid
           j == logline.event.msg.to
       IN
       /\ state[i] = Leader
       /\ nextIndex[i][j] - 1 /= logline.event.msg.prevLogIndex
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = AppendEntriesRequest
           /\ m.mdest = j
           /\ HandleAppendEntriesRequest(j, m)
           /\ UNCHANGED l

\* Withhold votes expiry without trace event.
\* Constrained: only when next event requires this server to not withhold.
SilentExpireWithholdVotes ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"StartElection", "BecomeCandidate", "PreVote"}
    /\ \E i \in Server :
        /\ i = logline.event.nid
        /\ withholdVotes[i] = TRUE
        /\ ExpireWithholdVotes(i)
        /\ UNCHANGED l

----
\* Action wrappers
\*
\* Each wrapper: (1) matches event type, (2) calls spec action,
\* (3) validates resulting state, (4) advances cursor.
----

\* BecomeCandidate (real election) -> Timeout(i)
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

\* PreVote -> PreVote(i)
PreVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("PreVote", i)
        /\ PreVote(i)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

\* HandleRequestVoteRequest -> HandleRequestVoteRequest(i, m)
HandleRequestVoteRequestIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleRequestVoteRequest")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = RequestVoteRequest
            /\ m.msource = logline.event.msg.from
            /\ m.mdest = i
            /\ HandleRequestVoteRequest(i, m)
            /\ ValidatePostState(i)
            /\ StepTrace

\* HandleRequestVoteResponse -> HandleRequestVoteResponse(i, m)
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
                       /\ HandleRequestVoteResponse(i, m)
                       /\ ValidatePostState(i)
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

\* SendEntries -> SendEntries(i, j)
\* Guards ensure silent actions fire first when needed:
\*   (a) commitIndex: SilentAdvanceCommitIndex must fire if msg.commitIndex > spec's
\*   (b) numEntries: FillLogGap must fire if leader's log is too short
SendEntriesIfLogged ==
    \E i \in Server :
        /\ IsEvent("SendEntries")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        \* Guard (a): commitIndex must be aligned
        /\ \/ ~ "commitIndex" \in DOMAIN logline.event.msg
           \/ commitIndex[i] >= logline.event.msg.commitIndex
        \* Guard (b): log must have enough entries
        /\ \/ ~ "numEntries" \in DOMAIN logline.event.msg
           \/ LastLogIndex(i) >= logline.event.msg.prevLogIndex + logline.event.msg.numEntries
        /\ LET j == logline.event.msg.to IN
            /\ j \in Server
            /\ SendEntries(i, j)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* SendHeartbeat -> SendEntries(i, j) (heartbeats are empty AppendEntries)
SendHeartbeatIfLogged ==
    \E i \in Server :
        /\ IsEvent("SendHeartbeat")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ LET j == logline.event.msg.to IN
            /\ j \in Server
            /\ SendEntries(i, j)
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
            /\ m.mprevLogIndex = logline.event.msg.prevLogIndex
            /\ HandleAppendEntriesRequest(i, m)
            /\ ValidatePostState(i)
            /\ StepTrace

\* HandleAppendEntriesResponse -> HandleAppendEntriesResponse(i, m)
HandleAppendEntriesResponseIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleAppendEntriesResponse")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Normal: find matching message in bag
              \E m \in DOMAIN messages :
                /\ m.mtype = AppendEntriesResponse
                /\ m.msource = logline.event.msg.from
                /\ m.mdest = i
                /\ HandleAppendEntriesResponse(i, m)
                /\ ValidatePostStateWeak(i)
                /\ StepTrace
           \/ \* Already consumed by SilentHandleAppendEntriesResponse
              /\ ~ \E m \in DOMAIN messages :
                      /\ m.mtype = AppendEntriesResponse
                      /\ m.msource = logline.event.msg.from
                      /\ m.mdest = i
              /\ UNCHANGED vars
              /\ StepTrace

\* AdvanceCommitIndex -> AdvanceCommitIndex(i)
\* Idempotent: if SilentAdvanceCommitIndex already advanced, just validate and skip.
AdvanceCommitIndexIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("AdvanceCommitIndex", i)
        /\ \/ \* Normal: advance commit index
              /\ AdvanceCommitIndex(i)
              /\ ValidatePostState(i)
              /\ StepTrace
           \/ \* Already advanced via SilentAdvanceCommitIndex
              /\ commitIndex[i] = logline.event.state.commitIndex
              /\ currentTerm[i] = logline.event.state.term
              /\ state[i] = RaftRole[logline.event.state.role]
              /\ LastLogIndex(i) = logline.event.state.lastLogIndex
              /\ LastLogTerm(i) = logline.event.state.lastLogTerm
              /\ UNCHANGED vars
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

\* StepDown -> StepDown(i)
StepDownIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("StepDown", i)
        /\ StepDown(i)
        /\ ValidatePostState(i)
        /\ StepTrace

----
\* Main transition
----

TraceNext ==
    \/ TimeoutIfLogged
    \/ PreVoteIfLogged
    \/ HandleRequestVoteRequestIfLogged
    \/ HandleRequestVoteResponseIfLogged
    \/ BecomeLeaderIfLogged
    \/ SendEntriesIfLogged
    \/ SendHeartbeatIfLogged
    \/ HandleAppendEntriesRequestIfLogged
    \/ HandleAppendEntriesResponseIfLogged
    \/ AdvanceCommitIndexIfLogged
    \/ ProposeConfigChangeIfLogged
    \/ StepDownIfLogged
    \* Silent actions (no trace event consumed)
    \/ FillLogGap
    \/ SilentTimeout
    \/ SilentAdvanceCommitIndex
    \/ SilentHandleAppendEntriesRequestReject
    \/ SilentHandleAppendEntriesResponse
    \/ SilentHandleAppendEntriesResponseForRetry
    \/ SilentSendEntries
    \/ SilentExpireWithholdVotes

----
\* Spec and properties
----

TraceSpec == TraceInit /\ [][TraceNext]_<<l, vars>>

\* View must include cursor position to prevent TLC from
\* collapsing identical states at different trace positions.
TraceView == <<vars, l>>

\* This property checks that the entire trace was consumed.
\* Violation means TLC could not advance past some event.
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
        wVotes    |-> withholdVotes
    ]

=============================================================================
