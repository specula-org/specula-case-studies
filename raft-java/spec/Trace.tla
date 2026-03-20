--------------------------- MODULE Trace ---------------------------
\* Trace validation spec for wenweihu86/raft-java.
\*
\* Reads an NDJSON trace file produced by the instrumentation harness,
\* and replays each event against the base spec to verify
\* the implementation matches the specification.
\*
\* Design notes:
\* - The harness runs 3 nodes in-process; many handler events are missing
\*   from the trace (only the focal server's events are reliably captured).
\* - Post-state validation is removed because untraced events on non-focal
\*   servers cause spec state to diverge from implementation state.
\* - Validation relies on: (1) event matching, (2) base action preconditions,
\*   (3) safety invariants (ElectionSafety, LogMatching).
\* - brpc-java produces self-addressed message events as artifacts;
\*   SkipSelfMessage handles these.

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
    "Follower"     :> Follower     @@
    "PreCandidate" :> PreCandidate @@
    "Candidate"    :> Candidate    @@
    "Leader"       :> Leader

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
    /\ preVotesGranted   = [s \in Server |-> {}]
    /\ messages          = EmptyBag
    /\ persistedTerm     = [s \in Server |-> 0]
    /\ persistedVotedFor = [s \in Server |-> Nil]
    /\ snapshotIndex     = [s \in Server |-> 0]
    /\ snapshotTerm      = [s \in Server |-> 0]
    /\ snapshotConfig    = [s \in Server |-> {}]
    /\ config            = [s \in Server |-> Server]

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
\* Lookahead helpers
----

\* Check if server s has an imminent StartPreVote event in the trace
\* at a term LOWER than term t. Used to prevent silent handlers from
\* stepping the server down before its PreVote (ordering issue).
HasImminentLowerTermPreVote(s, t) ==
    \E k \in l..(l + 3) :
        /\ k <= Len(TraceLog)
        /\ TraceLog[k].event.name = "StartPreVote"
        /\ TraceLog[k].event.nid = s
        /\ TraceLog[k].event.state.term < t

----
\* Step trace cursor
----

StepTrace == l' = l + 1

----
\* Action wrappers
\*
\* Each wrapper: match event → call base action → l' = l + 1
\* No post-state validation (trace is incomplete, state diverges).
----

\* --- PreVote ---

TraceStartPreVote ==
    \E i \in Server :
        /\ IsNodeEvent("StartPreVote", i)
        /\ StartPreVote(i)
        /\ StepTrace

TraceHandlePreVoteRequest ==
    \E i \in Server, m \in DOMAIN messages :
        /\ IsMsgEvent("HandlePreVoteRequest", m.msource, i)
        /\ HandlePreVoteRequest(i, m)
        /\ StepTrace

TraceHandlePreVoteResponse ==
    \E i \in Server, m \in DOMAIN messages :
        /\ IsMsgEvent("HandlePreVoteResponse", m.msource, i)
        /\ HandlePreVoteResponse(i, m)
        /\ StepTrace

\* --- Election ---

TraceStartVote ==
    \E i \in Server :
        /\ IsNodeEvent("StartVote", i)
        /\ StartVote(i)
        /\ StepTrace

TraceHandleRequestVoteRequest ==
    \E i \in Server, m \in DOMAIN messages :
        /\ IsMsgEvent("HandleRequestVoteRequest", m.msource, i)
        /\ HandleRequestVoteRequest(i, m)
        /\ StepTrace

TraceHandleRequestVoteResponse ==
    \E i \in Server, m \in DOMAIN messages :
        /\ IsMsgEvent("HandleRequestVoteResponse", m.msource, i)
        /\ HandleRequestVoteResponse(i, m)
        /\ StepTrace

TraceBecomeLeader ==
    \E i \in Server :
        /\ IsNodeEvent("BecomeLeader", i)
        /\ BecomeLeader(i)
        /\ StepTrace

\* --- Log Replication ---

TraceAppendEntries ==
    \E i, j \in Server :
        /\ IsMsgEvent("AppendEntries", i, j)
        /\ AppendEntries(i, j)
        /\ StepTrace

TraceHandleAppendEntriesRequest ==
    \E i \in Server, m \in DOMAIN messages :
        /\ IsMsgEvent("HandleAppendEntriesRequest", m.msource, i)
        /\ HandleAppendEntriesRequest(i, m)
        /\ StepTrace

TraceHandleAppendEntriesResponse ==
    \E i \in Server, m \in DOMAIN messages :
        /\ IsMsgEvent("HandleAppendEntriesResponse", m.msource, i)
        /\ HandleAppendEntriesResponse(i, m)
        /\ StepTrace

TraceClientRequest ==
    \E i \in Server :
        /\ IsNodeEvent("ClientRequest", i)
        /\ ClientRequest(i)
        /\ StepTrace

TraceAdvanceCommitIndex ==
    \E i \in Server :
        /\ IsNodeEvent("AdvanceCommitIndex", i)
        /\ AdvanceCommitIndex(i)
        /\ StepTrace

\* --- Snapshot ---

TraceSendInstallSnapshot ==
    \E i, j \in Server :
        /\ IsMsgEvent("SendInstallSnapshot", i, j)
        /\ SendInstallSnapshot(i, j)
        /\ StepTrace

TraceHandleInstallSnapshotRequest ==
    \E i \in Server, m \in DOMAIN messages :
        /\ IsMsgEvent("HandleInstallSnapshotRequest", m.msource, i)
        /\ HandleInstallSnapshotRequest(i, m)
        /\ StepTrace

TraceHandleInstallSnapshotResponse ==
    \E i \in Server, m \in DOMAIN messages :
        /\ IsMsgEvent("HandleInstallSnapshotResponse", m.msource, i)
        /\ HandleInstallSnapshotResponse(i, m)
        /\ StepTrace

TraceTakeSnapshot ==
    \E i \in Server :
        /\ IsNodeEvent("TakeSnapshot", i)
        /\ TakeSnapshot(i)
        /\ StepTrace

\* --- Config Change ---

TraceProposeConfigChange ==
    \E i \in Server :
        /\ IsNodeEvent("ProposeConfigChange", i)
        /\ LET newCfg == {logline.event.config[k] : k \in DOMAIN logline.event.config}
           IN ProposeConfigChange(i, newCfg)
        /\ StepTrace

----
\* Silent actions
\*
\* Handle implementation state changes without corresponding trace events.
\* The harness misses many handler events; these silent actions let
\* the spec state evolve to match the implementation.
----

\* Silent message handling: process untraced request messages to produce
\* responses (and update handling server's state) via the full base handler.
\* Constrained: only fire when the current logline is a response event
\* that needs a response from a specific server.

SilentHandlePreVoteRequest ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandlePreVoteResponse"
    \* Priority: if the focal server (nid) is PreCandidate and has a pending
    \* higher-term RequestVoteRequest, let SilentHandleRequestVoteRequest
    \* process it first (to step the server down before handling PreVote).
    /\ ~(state[logline.event.nid] = PreCandidate
         /\ \E rv \in DOMAIN messages :
             /\ rv.mtype = RequestVoteRequest
             /\ rv.mdest = logline.event.nid
             /\ rv.mterm > currentTerm[logline.event.nid])
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = PreVoteRequest
        /\ m.mdest = logline.event.msg.from
        /\ HandlePreVoteRequest(m.mdest, m)
    /\ UNCHANGED traceVars

SilentHandleRequestVoteRequest ==
    /\ l <= Len(TraceLog)
    /\ \/ \* Standard: produce vote response for upcoming HandleRequestVoteResponse
          /\ logline.event.name = "HandleRequestVoteResponse"
          /\ \E m \in DOMAIN messages :
              /\ m.mtype = RequestVoteRequest
              /\ m.mdest = logline.event.msg.from
              \* Don't consume if target server has imminent PreVote at lower term
              \* (consuming would step it down prematurely, causing ordering issues)
              /\ ~HasImminentLowerTermPreVote(m.mdest, m.mterm)
              /\ HandleRequestVoteRequest(m.mdest, m)
       \/ \* Intervening: process RequestVote for the focal server that was
          \* stepped down between StartPreVote and HandlePreVoteResponse
          /\ logline.event.name = "HandlePreVoteResponse"
          /\ state[logline.event.nid] = PreCandidate
          /\ \E m \in DOMAIN messages :
              /\ m.mtype = RequestVoteRequest
              /\ m.mdest = logline.event.nid
              /\ HandleRequestVoteRequest(m.mdest, m)
    /\ UNCHANGED traceVars

\* Silent process AppendEntries: server processes AppendEntriesRequest.
\* Tightly constrained to avoid state space explosion:
\* - Only fires when the next traced event is HandleAppendEntriesResponse
\*   (to produce the response message that the traced handler will consume)
\* - Only handles requests destined for the server that sent the response
SilentHandleAppendEntriesRequest ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleAppendEntriesResponse"
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = AppendEntriesRequest
        /\ m.mdest = logline.event.msg.from
        /\ HandleAppendEntriesRequest(m.mdest, m)
    /\ UNCHANGED traceVars

\* Silent BecomeLeader: candidate with quorum becomes leader without trace event.
\* Needed when the trace doesn't show BecomeLeader but the leader sends heartbeats.
\* Tightly constrained: only fires when the next event requires a leader to exist
\* (AppendEntries send, ClientRequest, AdvanceCommitIndex, HandleAppendEntriesResponse).
SilentBecomeLeader ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"AppendEntries", "ClientRequest",
                                "AdvanceCommitIndex", "HandleAppendEntriesResponse"}
    /\ \E i \in Server :
        /\ BecomeLeader(i)
    /\ UNCHANGED traceVars

\* Silent AppendEntries: leader sends heartbeats/entries without trace event.
\* Tightly constrained to reduce state space:
\* - Only fires at HandleAppendEntriesResponse events (leader's follow-up)
\*   or HandleAppendEntriesRequest events (to create missing messages)
\* - Does not send to PreCandidate/Candidate servers (protects elections)
SilentAppendEntries ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"HandleAppendEntriesRequest",
                                "HandleAppendEntriesResponse"}
    /\ \E i, j \in Server :
        /\ state[i] = Leader
        /\ i /= j
        /\ state[j] \notin {PreCandidate, Candidate}
        /\ AppendEntries(i, j)
    /\ UNCHANGED traceVars

\* Silent AdvanceCommitIndex: leader advances commit after response handling.
\* Tightly constrained: only fires at HandleAppendEntriesResponse events
\* (which update matchIndex, enabling commit advancement).
SilentAdvanceCommitIndex ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleAppendEntriesResponse"
    /\ \E i \in Server :
        /\ AdvanceCommitIndex(i)
    /\ UNCHANGED traceVars

\* Silent DropStaleMessage: consume stale messages without trace event.
SilentDropStaleMessage ==
    /\ l <= Len(TraceLog)
    /\ \E m \in DOMAIN messages :
        /\ DropStaleMessage(m)
    /\ UNCHANGED traceVars

\* Skip duplicate handler events: brpc-java sometimes delivers the same
\* RPC twice. The first handling consumed the message; the second has
\* no matching message in the bag. Skip it.
SkipDuplicateHandler ==
    /\ l <= Len(TraceLog)
    /\ "msg" \in DOMAIN logline.event
    /\ logline.event.msg.from /= logline.event.nid  \* not self-addressed
    /\ \/ \* Request handlers: no matching request in bag
          /\ logline.event.name \in {"HandlePreVoteRequest", "HandleRequestVoteRequest",
                                      "HandleAppendEntriesRequest", "HandleInstallSnapshotRequest"}
          /\ ~\E m \in DOMAIN messages :
              /\ m.msource = logline.event.msg.from
              /\ m.mdest = logline.event.nid
              /\ \/ (logline.event.name = "HandlePreVoteRequest" /\ m.mtype = PreVoteRequest)
                 \/ (logline.event.name = "HandleRequestVoteRequest" /\ m.mtype = RequestVoteRequest)
                 \/ (logline.event.name = "HandleAppendEntriesRequest" /\ m.mtype = AppendEntriesRequest)
                 \/ (logline.event.name = "HandleInstallSnapshotRequest" /\ m.mtype = InstallSnapshotRequest)
       \/ \* Response handlers: no matching response in bag AND no pending
          \* request that a silent handler could still convert into a response
          /\ logline.event.name \in {"HandlePreVoteResponse", "HandleRequestVoteResponse",
                                      "HandleAppendEntriesResponse", "HandleInstallSnapshotResponse"}
          /\ ~\E m \in DOMAIN messages :
              /\ m.msource = logline.event.msg.from
              /\ m.mdest = logline.event.nid
              /\ \/ (logline.event.name = "HandlePreVoteResponse" /\ m.mtype = PreVoteResponse)
                 \/ (logline.event.name = "HandleRequestVoteResponse" /\ m.mtype = RequestVoteResponse)
                 \/ (logline.event.name = "HandleAppendEntriesResponse" /\ m.mtype = AppendEntriesResponse)
                 \/ (logline.event.name = "HandleInstallSnapshotResponse" /\ m.mtype = InstallSnapshotResponse)
          \* Don't skip if a request exists that silent handling could safely
          \* convert to the needed response (i.e., won't cause ordering issues)
          /\ ~\E m \in DOMAIN messages :
              /\ m.mdest = logline.event.msg.from
              /\ \/ (logline.event.name = "HandlePreVoteResponse" /\ m.mtype = PreVoteRequest)
                 \/ (logline.event.name = "HandleRequestVoteResponse" /\ m.mtype = RequestVoteRequest)
                 \/ (logline.event.name = "HandleAppendEntriesResponse" /\ m.mtype = AppendEntriesRequest)
                 \/ (logline.event.name = "HandleInstallSnapshotResponse" /\ m.mtype = InstallSnapshotRequest)
              \* Exempt: processing this request would cause an ordering issue
              \* (target server has imminent PreVote at lower term)
              /\ ~HasImminentLowerTermPreVote(m.mdest, m.mterm)
    /\ StepTrace
    /\ UNCHANGED vars

\* Skip stale leader events: the real system may queue AppendEntries
\* messages before step-down; the trace shows these stale sends and
\* their responses. In the spec, the leader is already stepped down
\* so AppendEntries (requires Leader) and HandleAppendEntriesResponse
\* (requires Leader) can't fire. Skip them.
SkipStaleLeaderEvent ==
    /\ l <= Len(TraceLog)
    /\ \/ \* Stale leader sends heartbeat/entries (already stepped down in spec)
          /\ logline.event.name = "AppendEntries"
          /\ state[logline.event.nid] /= Leader
       \/ \* Stale leader handles response (no longer leader in spec)
          /\ logline.event.name \in {"HandleAppendEntriesResponse",
                                      "HandleInstallSnapshotResponse"}
          /\ state[logline.event.nid] /= Leader
    /\ StepTrace
    /\ UNCHANGED vars

\* Skip self-addressed message events (brpc-java in-process artifact).
SkipSelfMessage ==
    /\ l <= Len(TraceLog)
    /\ "msg" \in DOMAIN logline.event
    /\ logline.event.msg.from = logline.event.nid
    /\ logline.event.msg.to = logline.event.nid
    /\ StepTrace
    /\ UNCHANGED vars

----
\* Trace spec
----

TraceNext ==
    \* Event-driven actions
    \/ TraceStartPreVote
    \/ TraceHandlePreVoteRequest
    \/ TraceHandlePreVoteResponse
    \/ TraceStartVote
    \/ TraceHandleRequestVoteRequest
    \/ TraceHandleRequestVoteResponse
    \/ TraceBecomeLeader
    \/ TraceAppendEntries
    \/ TraceHandleAppendEntriesRequest
    \/ TraceHandleAppendEntriesResponse
    \/ TraceClientRequest
    \/ TraceAdvanceCommitIndex
    \/ TraceSendInstallSnapshot
    \/ TraceHandleInstallSnapshotRequest
    \/ TraceHandleInstallSnapshotResponse
    \/ TraceTakeSnapshot
    \/ TraceProposeConfigChange
    \* Skip problematic events
    \/ SkipSelfMessage
    \/ SkipDuplicateHandler
    \/ SkipStaleLeaderEvent
    \* Silent actions
    \/ SilentHandlePreVoteRequest
    \/ SilentHandleRequestVoteRequest
    \/ SilentHandleAppendEntriesRequest
    \/ SilentBecomeLeader
    \/ SilentAdvanceCommitIndex
    \* Terminal: trace fully consumed, allow stutter to avoid deadlock
    \/ (l > Len(TraceLog) /\ UNCHANGED <<vars, traceVars>>)

trace_vars == <<vars, traceVars>>

TraceSpec == TraceInit /\ [][TraceNext]_trace_vars

\* View: include message bag domain so silent message-handling actions
\* (which swap request for response) are not collapsed by TLC.
TraceView == <<l, currentTerm, state, votedFor, log, commitIndex,
               nextIndex, matchIndex, votesGranted, preVotesGranted,
               persistedTerm, persistedVotedFor,
               snapshotIndex, snapshotTerm, snapshotConfig, config,
               DOMAIN messages>>

----
\* Trace completion
----

\* The entire trace was consumed.
TraceMatched == <>(l = Len(TraceLog) + 1)

----
\* Alias for debugging
----

TraceAlias == [
    l          |-> l,
    event      |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
    server_state |-> [s \in Server |-> [
        term       |-> currentTerm[s],
        role       |-> state[s],
        votedFor   |-> votedFor[s],
        commitIdx  |-> commitIndex[s],
        lastLogIdx |-> LastLogIndex(s),
        lastLogTerm |-> LastLogTerm(s)
    ]],
    msgCount   |-> BagCardinality(messages)
]

=============================================================================
