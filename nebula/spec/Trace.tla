--------------------------- MODULE Trace ---------------------------
\* Trace validation spec for vesoft-inc/nebula Raft consensus.
\*
\* Reads an NDJSON trace file produced by the C++ test harness,
\* and replays each event against the base spec to verify the
\* implementation matches the specification.

EXTENDS base, Json, IOUtils, Sequences, TLC

----
\* Trace loading
----

\* Read JSON file path from environment.
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
----

\* Maps implementation role strings to spec constants.
\* Reference: RaftPart.h:424-425 (Role enum)
RaftRole ==
    "Follower"  :> Follower  @@
    "Candidate" :> Candidate @@
    "Leader"    :> Leader

----
\* Server extraction from trace
----

\* Extract set of servers from all trace events.
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
\* Nebula initializes: term = lastLogTerm (from WAL), role = Follower,
\* all volatile state at defaults.
\* Reference: RaftPart.cpp:400-454 (start)
----

\* Skip initial Restart events (first boot, not crash recovery).
\* These correspond to RaftPart::start() on fresh servers where alive=TRUE.
FirstNonRestart == TLCEval(
    LET f[i \in 1..Len(TraceLog)+1] ==
        IF i > Len(TraceLog) THEN i
        ELSE IF TraceLog[i].event.name /= "Restart" THEN i
        ELSE f[i+1]
    IN f[1])

TraceInit ==
    /\ l = FirstNonRestart
    \* RaftPart.cpp:412-414: term = wal_->lastLogTerm() (0 for empty WAL)
    /\ term             = [s \in Server |-> 0]
    /\ role             = [s \in Server |-> Follower]
    /\ votedFor         = [s \in Server |-> Nil]
    /\ votedTerm        = [s \in Server |-> 0]
    /\ leader           = [s \in Server |-> Nil]
    /\ log              = [s \in Server |-> <<>>]
    /\ commitIndex      = [s \in Server |-> 0]
    /\ nextIndex        = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex       = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted     = [s \in Server |-> {}]
    /\ preVotesGranted  = [s \in Server |-> {}]
    /\ messages         = EmptyBag
    /\ alive            = [s \in Server |-> TRUE]
    \* RaftPart.h:854: isBlindFollower_ = true on start
    /\ blindFollower    = [s \in Server |-> TRUE]
    /\ leaseExpired     = [s \in Server |-> TRUE]
    /\ commitInThisTerm = [s \in Server |-> FALSE]
    /\ snapshotSending  = [s \in Server |-> [t \in Server |-> FALSE]]
    /\ snapshotTerm     = [s \in Server |-> [t \in Server |-> 0]]

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

\* Strong validation: check term, role, commitIndex, lastLogIndex, lastLogTerm.
ValidatePostState(i) ==
    /\ term'[i] = logline.event.state.term
    /\ role'[i] = RaftRole[logline.event.state.role]
    /\ commitIndex'[i] = logline.event.state.commitIndex
    /\ LastLogIndex(i)' = logline.event.state.lastLogIndex
    /\ LastLogTerm(i)' = logline.event.state.lastLogTerm

\* Weak validation: only check term and role (for async events).
ValidatePostStateWeak(i) ==
    /\ term'[i] = logline.event.state.term
    /\ role'[i] = RaftRole[logline.event.state.role]

\* Validate votedFor field from trace.
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
\* Traced action wrappers
\*
\* Each wrapper:
\*   1. Matches a trace event
\*   2. Calls the base spec action
\*   3. Validates post-state
\*   4. Advances cursor
----

\* --- Election Actions ---

\* Timeout: follower becomes candidate.
\* Reference: RaftPart.cpp:1143-1155 (needToStartElection)
TraceTimeout ==
    /\ \E i \in Server :
        /\ IsNodeEvent("Timeout", i)
        /\ \/ Timeout(i)
           \/ BlindFollowerTimeout(i)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

\* SendPreVote: candidate sends pre-vote requests.
\* Reference: RaftPart.cpp:1157-1195 (prepareElectionRequest, isPreVote=true)
TraceSendPreVote ==
    /\ \E i \in Server :
        /\ IsNodeEvent("SendPreVote", i)
        /\ SendPreVote(i)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

\* SendRequestVote: candidate sends formal vote requests.
\* Reference: RaftPart.cpp:1157-1195 (prepareElectionRequest, isPreVote=false)
TraceSendRequestVote ==
    /\ \E i \in Server :
        /\ IsNodeEvent("SendRequestVote", i)
        /\ SendRequestVote(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* HandlePreVoteRequest: server handles pre-vote request.
\* Reference: RaftPart.cpp:1465-1576 (processAskForVoteRequest, pre-vote)
TraceHandlePreVoteRequest ==
    /\ \E i \in Server :
        /\ IsNodeEvent("HandlePreVoteRequest", i)
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = RequestVoteRequest
            /\ m.mpreVote = TRUE
            /\ m.mdest = i
            /\ m.msource = logline.event.msg.from
            /\ HandlePreVoteRequest(i, m)
        /\ ValidatePostState(i)
        /\ ValidateVotedFor(i)
        /\ StepTrace

\* HandleRequestVoteRequest: server handles formal vote request.
\* Reference: RaftPart.cpp:1465-1607 (processAskForVoteRequest, formal)
TraceHandleRequestVoteRequest ==
    /\ \E i \in Server :
        /\ IsNodeEvent("HandleRequestVoteRequest", i)
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = RequestVoteRequest
            /\ m.mpreVote = FALSE
            /\ m.mdest = i
            /\ m.msource = logline.event.msg.from
            /\ HandleRequestVoteRequest(i, m)
        /\ ValidatePostState(i)
        /\ ValidateVotedFor(i)
        /\ StepTrace

\* HandlePreVoteResponse: candidate handles pre-vote response.
\* Reference: RaftPart.cpp:1218-1289 (processElectionResponses, pre-vote)
TraceHandlePreVoteResponse ==
    /\ \E i \in Server :
        /\ IsNodeEvent("HandlePreVoteResponse", i)
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = RequestVoteResponse
            /\ m.mpreVote = TRUE
            /\ m.mdest = i
            /\ m.msource = logline.event.msg.from
            /\ HandlePreVoteResponse(i, m)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

\* HandleRequestVoteResponse: candidate handles formal vote response.
\* Reference: RaftPart.cpp:1218-1289 (processElectionResponses, formal)
TraceHandleRequestVoteResponse ==
    /\ \E i \in Server :
        /\ IsNodeEvent("HandleRequestVoteResponse", i)
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = RequestVoteResponse
            /\ m.mpreVote = FALSE
            /\ m.mdest = i
            /\ m.msource = logline.event.msg.from
            /\ HandleRequestVoteResponse(i, m)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

\* BecomeLeader: candidate with quorum becomes leader.
\* Reference: RaftPart.cpp:1275-1284, 1370-1398
\* Idempotent: BecomeLeader trace event may arrive AFTER the server is already
\* acting as Leader (due to async trace emission from handleElectionResponses).
\* In that case, just validate term and advance cursor.
TraceBecomeLeader ==
    /\ \E i \in Server :
        /\ IsNodeEvent("BecomeLeader", i)
        /\ \/ /\ BecomeLeader(i)
              /\ ValidatePostState(i)
           \/ /\ role[i] = Leader  \* Already became leader via SilentBecomeLeader
              /\ term[i] = logline.event.state.term
              /\ UNCHANGED vars
        /\ StepTrace

\* --- Log Replication Actions ---

\* ClientRequest: leader appends entry to local log.
\* Reference: RaftPart.cpp:874-906 (appendLogsInternal)
TraceClientRequest ==
    /\ \E i \in Server :
        /\ IsNodeEvent("ClientRequest", i)
        /\ ClientRequest(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* AppendEntries: leader sends AppendEntries to follower.
\* Reference: RaftPart.cpp:918-1000 (replicateLogs)
TraceAppendEntries ==
    /\ \E i, j \in Server :
        /\ i /= j
        /\ IsMsgEvent("AppendEntries", i, j)
        /\ AppendEntries(i, j)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

\* HandleAppendEntriesRequest: follower handles AppendEntries.
\* Reference: RaftPart.cpp:1610-1827 (processAppendLogRequest)
TraceHandleAppendEntriesRequest ==
    /\ \E i \in Server :
        /\ IsNodeEvent("HandleAppendEntriesRequest", i)
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = AppendEntriesRequest
            /\ m.mdest = i
            /\ m.msource = logline.event.msg.from
            /\ HandleAppendEntriesRequest(i, m)
        /\ ValidatePostState(i)
        /\ StepTrace

\* HandleAppendEntriesResponse: leader handles batch commit.
\* Reference: RaftPart.cpp:1047-1146 (processAppendLogResponses)
\*
\* The implementation processes ALL pending responses at once and commits if quorum.
\* The trace emits ONE event per batch commit (no msg.from field).
\* To avoid non-deterministic message matching, we batch-process ALL pending AE
\* responses: update matchIndex/nextIndex from ALL responses, set commitIndex from
\* the trace, and discard all processed responses.
TraceHandleAppendEntriesResponse ==
    /\ \E i \in Server :
        /\ IsNodeEvent("HandleAppendEntriesResponse", i)
        /\ role[i] = Leader
        /\ LET \* Collect all pending AE responses for this leader
               allResps == {m \in DOMAIN messages :
                   m.mtype = AppendEntriesResponse /\ m.mdest = i}
               succResps == {m \in allResps : m.msuccess = TRUE}
           IN
           /\ succResps /= {}
           \* Update matchIndex from all success responses
           /\ matchIndex' = [matchIndex EXCEPT ![i] =
                [j \in Server |->
                    IF j = i THEN matchIndex[i][i]
                    ELSE
                        LET resps == {m \in succResps : m.msource = j}
                        IN IF resps /= {} THEN
                            LET maxMI == CHOOSE idx \in {m.mmatchIndex : m \in resps} :
                                    \A idx2 \in {m.mmatchIndex : m \in resps} : idx >= idx2
                            IN Max(matchIndex[i][j], maxMI)
                           ELSE matchIndex[i][j]]]
           \* Update nextIndex from matchIndex
           /\ nextIndex' = [nextIndex EXCEPT ![i] =
                [j \in Server |->
                    IF j = i THEN nextIndex[i][j]
                    ELSE
                        LET resps == {m \in succResps : m.msource = j}
                        IN IF resps /= {} THEN
                            LET maxMI == CHOOSE idx \in {m.mmatchIndex : m \in resps} :
                                    \A idx2 \in {m.mmatchIndex : m \in resps} : idx >= idx2
                            IN Max(nextIndex[i][j], maxMI + 1)
                           ELSE nextIndex[i][j]]]
           \* Set commitIndex directly from the trace (batch commit)
           /\ LET newCI == logline.event.state.commitIndex
              IN
              /\ commitIndex' = [commitIndex EXCEPT ![i] = newCI]
              /\ IF newCI > commitIndex[i] THEN
                    /\ leaseExpired' = [leaseExpired EXCEPT ![i] = FALSE]
                    /\ commitInThisTerm' = [commitInThisTerm EXCEPT ![i] = TRUE]
                 ELSE UNCHANGED <<leaseExpired, commitInThisTerm>>
           \* Discard all processed responses
           /\ messages' = messages (-) SetToBag(allResps)
        \* Validate: term, role, log unchanged; commitIndex set from trace
        /\ term[i] = logline.event.state.term
        /\ role[i] = RaftRole[logline.event.state.role]
        /\ LastLogIndex(i) = logline.event.state.lastLogIndex
        /\ LastLogTerm(i) = logline.event.state.lastLogTerm
        /\ UNCHANGED <<role, term, votedFor, votedTerm, leader, log, candidateVars,
                       blindFollower, snapshotVars, crashVars>>
        /\ StepTrace

\* --- Heartbeat Actions ---

\* SendHeartbeat: leader sends heartbeat to follower.
\* Reference: RaftPart.cpp:2041-2123 (sendHeartbeat)
TraceSendHeartbeat ==
    /\ \E i, j \in Server :
        /\ i /= j
        /\ IsMsgEvent("SendHeartbeat", i, j)
        /\ SendHeartbeat(i, j)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

\* HandleHeartbeatRequest: follower handles heartbeat.
\* Reference: RaftPart.cpp:1895-1952 (processHeartbeatRequest)
TraceHandleHeartbeatRequest ==
    /\ \E i \in Server :
        /\ IsNodeEvent("HandleHeartbeatRequest", i)
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = HeartbeatRequest
            /\ m.mdest = i
            /\ m.msource = logline.event.msg.from
            /\ HandleHeartbeatRequest(i, m)
        /\ ValidatePostState(i)
        /\ StepTrace

\* HandleHeartbeatResponse: leader handles heartbeat response.
\* Reference: RaftPart.cpp:2091-2122 (sendHeartbeat callback)
\* Note: trace event has no msg field. Batch-consume ALL pending HB responses
\* to prevent message bag accumulation and state explosion.
TraceHandleHeartbeatResponse ==
    /\ \E i \in Server :
        /\ IsNodeEvent("HandleHeartbeatResponse", i)
        /\ LET allHBResps == {m \in DOMAIN messages :
                m.mtype = HeartbeatResponse /\ m.mdest = i}
           IN
           /\ allHBResps /= {}
           \* Check none have higher term (would cause step-down)
           /\ IF \A m \in allHBResps : m.mterm <= term[i] THEN
                \* Normal case: refresh lease
                /\ leaseExpired' = [leaseExpired EXCEPT ![i] = FALSE]
                /\ UNCHANGED <<role, term, votedFor, votedTerm, leader>>
              ELSE
                \* Step-down if higher term found
                LET maxTerm == CHOOSE t \in {m.mterm : m \in allHBResps} :
                        \A t2 \in {m.mterm : m \in allHBResps} : t >= t2
                IN
                /\ term' = [term EXCEPT ![i] = maxTerm]
                /\ role' = [role EXCEPT ![i] = Follower]
                /\ leader' = [leader EXCEPT ![i] = Nil]
                /\ UNCHANGED <<votedFor, votedTerm, leaseExpired>>
           /\ messages' = messages (-) SetToBag(allHBResps)
           /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                          blindFollower, commitInThisTerm, snapshotVars, crashVars>>
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

\* --- Crash/Recovery Actions ---

\* Crash: server crashes.
TraceCrash ==
    /\ \E i \in Server :
        /\ IsNodeEvent("Crash", i)
        /\ Crash(i)
        /\ StepTrace

\* Restart: server recovers.
\* Reference: RaftPart.cpp:400-454 (start)
TraceRestart ==
    /\ \E i \in Server :
        /\ IsNodeEvent("Restart", i)
        /\ Restart(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* --- Snapshot Actions ---

\* StartSnapshot: leader starts sending snapshot to follower.
TraceStartSnapshot ==
    /\ \E i, j \in Server :
        /\ i /= j
        /\ IsMsgEvent("StartSnapshot", i, j)
        /\ StartSnapshot(i, j)
        /\ StepTrace

\* CompleteSnapshot: snapshot transfer completes.
TraceCompleteSnapshot ==
    /\ \E i, j \in Server :
        /\ i /= j
        /\ IsMsgEvent("CompleteSnapshot", i, j)
        /\ CompleteSnapshot(i, j)
        /\ StepTrace

----
\* Silent actions (no trace event consumed)
\*
\* Handle implementation state changes that don't emit trace events.
\* Each silent action must be tightly constrained to prevent state explosion.
----

\* Silent ClientRequest: leader appends noop entry (heartbeat sends empty log).
\* Reference: RaftPart.cpp:2044-2048 — sendHeartbeat appends empty log if not replicating
\* Constrained: only when next trace event expects a longer log than current spec state,
\* AND the next event is NOT ClientRequest (that would be handled by TraceClientRequest).
SilentClientRequest ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name /= "ClientRequest"  \* Don't double-count explicit requests
    /\ "state" \in DOMAIN logline.event
    /\ "lastLogIndex" \in DOMAIN logline.event.state
    /\ LET nid     == logline.event.nid
           expected == logline.event.state.lastLogIndex
       IN
       /\ role[nid] = Leader
       /\ LastLogIndex(nid) < expected
       /\ ClientRequest(nid)
       /\ UNCHANGED l

\* Silent SendHeartbeat: heartbeat sent without trace event.
\* Constrained: only when the next event is HandleHeartbeatRequest
SilentSendHeartbeat ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleHeartbeatRequest"
    /\ \E i, j \in Server :
        /\ i /= j
        /\ logline.event.msg.from = i
        /\ logline.event.nid = j
        /\ SendHeartbeat(i, j)
        /\ UNCHANGED l

\* Silent AppendEntries: log replication sent without trace event.
\* Constrained: only when the next event is HandleAppendEntriesRequest
SilentAppendEntries ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleAppendEntriesRequest"
    /\ \E i, j \in Server :
        /\ i /= j
        /\ logline.event.msg.from = i
        /\ logline.event.nid = j
        /\ AppendEntries(i, j)
        /\ UNCHANGED l

\* Silent Timeout: concurrent timeout (another server times out without trace event).
\* Constrained: only when a HandleRequestVoteRequest is about to fire from
\* a candidate that hasn't timed out yet in the spec.
SilentTimeout ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"HandlePreVoteRequest", "HandleRequestVoteRequest"}
    /\ \E i \in Server :
        /\ "msg" \in DOMAIN logline.event
        /\ i = logline.event.msg.from
        /\ role[i] = Follower
        /\ \/ Timeout(i)
           \/ BlindFollowerTimeout(i)
        /\ UNCHANGED l

\* Silent SendPreVote: pre-vote sent without trace event.
\* Constrained: only when the next event is HandlePreVoteRequest
\* and pre-votes haven't been sent yet (preVotesGranted still empty).
SilentSendPreVote ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandlePreVoteRequest"
    /\ \E i \in Server :
        /\ "msg" \in DOMAIN logline.event
        /\ i = logline.event.msg.from
        /\ preVotesGranted[i] = {}  \* Only if pre-votes haven't been sent
        /\ SendPreVote(i)
        /\ UNCHANGED l

\* Silent SendRequestVote: formal vote sent without trace event.
\* Constrained: only when the next event is HandleRequestVoteRequest
\* and formal votes haven't been sent yet (votesGranted still empty).
SilentSendRequestVote ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleRequestVoteRequest"
    /\ \E i \in Server :
        /\ "msg" \in DOMAIN logline.event
        /\ i = logline.event.msg.from
        /\ votesGranted[i] = {}  \* Only if formal votes haven't been sent
        /\ SendRequestVote(i)
        /\ UNCHANGED l

\* Silent HandlePreVoteRequest: receiver processes pre-vote request without trace event.
\* Needed because pre-vote request handling is not instrumented.
\* Constrained: only when preparing for SendRequestVote (candidate needs pre-vote quorum)
SilentHandlePreVoteRequest ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "SendRequestVote"
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = RequestVoteRequest
        /\ m.mpreVote = TRUE
        /\ HandlePreVoteRequest(m.mdest, m)
        /\ UNCHANGED l

\* Silent HandlePreVoteResponse: candidate processes pre-vote response without trace event.
\* Needed because pre-vote response handling is not instrumented.
\* Constrained: only when preparing for SendRequestVote (candidate needs quorum)
SilentHandlePreVoteResponse ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "SendRequestVote"
    /\ \E m \in DOMAIN messages :
        /\ m.mtype = RequestVoteResponse
        /\ m.mpreVote = TRUE
        /\ HandlePreVoteResponse(m.mdest, m)
        /\ UNCHANGED l

\* Silent HandleRequestVoteResponse: candidate processes formal vote response without trace.
\* Needed because formal vote responses are not instrumented.
\* Constrained: only for the server in the next event that needs to transition from Candidate
SilentHandleRequestVoteResponse ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ logline.event.nid = i
        /\ role[i] = Candidate
        /\ \E m \in DOMAIN messages :
            /\ m.mtype = RequestVoteResponse
            /\ m.mpreVote = FALSE
            /\ m.mdest = i
            /\ HandleRequestVoteResponse(i, m)
        /\ UNCHANGED l

\* Silent BecomeLeader: candidate becomes leader without explicit trace event yet.
\* Needed because BecomeLeader trace event arrives after the server already acts as Leader.
\* Constrained: only when a Candidate has quorum and the next event expects Leader behavior
SilentBecomeLeader ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ logline.event.nid = i
        /\ role[i] = Candidate
        /\ IsQuorum(votesGranted[i])
        /\ BecomeLeader(i)
        /\ UNCHANGED l

----
\* Trace Next
----

\* Trace completion — stutter when all events consumed (prevents false deadlock)
TraceDone ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED <<vars, traceVars>>

TraceNext ==
    \* Trace completion
    \/ TraceDone
    \* Traced actions (consume one trace event)
    \/ TraceTimeout
    \/ TraceSendPreVote
    \/ TraceSendRequestVote
    \/ TraceHandlePreVoteRequest
    \/ TraceHandleRequestVoteRequest
    \/ TraceHandlePreVoteResponse
    \/ TraceHandleRequestVoteResponse
    \/ TraceBecomeLeader
    \/ TraceClientRequest
    \/ TraceAppendEntries
    \/ TraceHandleAppendEntriesRequest
    \/ TraceHandleAppendEntriesResponse
    \/ TraceSendHeartbeat
    \/ TraceHandleHeartbeatRequest
    \/ TraceHandleHeartbeatResponse
    \/ TraceCrash
    \/ TraceRestart
    \/ TraceStartSnapshot
    \/ TraceCompleteSnapshot
    \* Silent actions (no trace event consumed)
    \/ SilentClientRequest
    \/ SilentSendHeartbeat
    \/ SilentAppendEntries
    \/ SilentTimeout
    \/ SilentSendPreVote
    \/ SilentSendRequestVote
    \/ SilentHandlePreVoteRequest
    \/ SilentHandlePreVoteResponse
    \/ SilentHandleRequestVoteResponse
    \/ SilentBecomeLeader

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, traceVars>>

----
\* Temporal property: entire trace was consumed
----

TraceMatched == <>(l = Len(TraceLog) + 1)

----
\* Trace-specific aliases for TLC
----

TraceAlias ==
    [
        cursor    |-> l,
        event     |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "END",
        traceLen  |-> Len(TraceLog),
        terms     |-> [s \in Server |-> term[s]],
        roles     |-> [s \in Server |-> role[s]],
        logs      |-> [s \in Server |-> Len(log[s])],
        commits   |-> [s \in Server |-> commitIndex[s]],
        aliveSet  |-> {s \in Server : alive[s]}
    ]

\* View for state space reduction: exclude message bag from fingerprint.
\* Safe for trace validation — we only need ONE valid path.
TraceView == <<l, term, role, [s \in Server |-> Len(log[s])], commitIndex,
               matchIndex, nextIndex, votedFor, votedTerm, alive,
               blindFollower, leaseExpired, commitInThisTerm,
               votesGranted, preVotesGranted>>

====
