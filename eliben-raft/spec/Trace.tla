------------------------------ MODULE Trace ------------------------------
\* Trace validation spec for eliben/raft.
\*
\* Replays NDJSON traces from the instrumented implementation against
\* the base spec, verifying that every observed state transition is
\* consistent with the TLA+ model.
\*
EXTENDS base, Json, IOUtils, Sequences, Integers, FiniteSets, Bags, TLC

----
\* Trace loading
----

\* Trace file location: defaults to ../traces/trace.ndjson,
\* overridable via -DJSON=path on TLC command line.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load and filter trace events
RawLog == ndJsonDeserialize(JsonFile)
TraceLog == SelectSeq(RawLog, LAMBDA e : "event" \in DOMAIN e)

ASSUME Len(TraceLog) > 0

----
\* Trace cursor
----

VARIABLE l       \* Current position in trace (1-indexed)

logline == TraceLog[l]

traceVars == <<l>>
allVars == <<vars, traceVars>>

----
\* Role and type mapping
----

\* Map implementation role strings to spec constants
RaftRole == "Follower" :> Follower
         @@ "Candidate" :> Candidate
         @@ "Leader" :> Leader

----
\* Server extraction
----

\* Derive Server set from trace: collect all node IDs mentioned in events
TraceServer ==
    LET ids == {TraceLog[i].node : i \in 1..Len(TraceLog)}
    IN ids

----
\* Event predicates
----

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.node = i

IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ logline.from = from
    /\ logline.to = to

----
\* Post-state validation
----

\* Strong validation: full state check after action.
\* Used for actions where the trace captures complete server state.
ValidatePostState(i) ==
    /\ currentTerm'[i] = logline.term
    /\ state'[i] = RaftRole[logline.role]
    /\ IF "commitIndex" \in DOMAIN logline
       THEN commitIndex'[i] = logline.commitIndex
       ELSE TRUE
    /\ IF "lastLogIndex" \in DOMAIN logline
       THEN Len(log'[i]) = logline.lastLogIndex
       ELSE TRUE

\* Weak validation: term + role only.
\* Used for async actions where trace doesn't capture full state.
ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.term
    /\ state'[i] = RaftRole[logline.role]

\* VotedFor validation helper
ValidateVotedFor(i) ==
    IF "votedFor" \in DOMAIN logline
    THEN votedFor'[i] = IF logline.votedFor = -1 THEN Nil
                         ELSE logline.votedFor
    ELSE TRUE

----
\* TraceInit
----

\* Initial state must match the implementation's initial state.
\* eliben/raft: term=0, votedFor=-1 (Nil), empty log, commitIndex=-1 (→0)
TraceInit ==
    /\ l = 1
    /\ currentTerm      = [s \in TraceServer |-> 0]
    /\ votedFor          = [s \in TraceServer |-> Nil]
    /\ log               = [s \in TraceServer |-> <<>>]
    /\ state             = [s \in TraceServer |-> Follower]
    /\ commitIndex       = [s \in TraceServer |-> 0]
    /\ nextIndex         = [s \in TraceServer |-> [t \in TraceServer |-> 1]]
    /\ matchIndex        = [s \in TraceServer |-> [t \in TraceServer |-> 0]]
    /\ votesGranted      = [s \in TraceServer |-> {}]
    /\ messages          = EmptyBag
    /\ persistedTerm     = [s \in TraceServer |-> 0]
    /\ persistedVotedFor = [s \in TraceServer |-> Nil]

----
\* Trace action wrappers
\*
\* Each wrapper: match event → call base action → validate → l' = l + 1
----

\* --- Election events ---

TraceTimeout ==
    /\ IsEvent("Timeout")
    /\ LET i == logline.node
       IN
       /\ Timeout(i)
       /\ ValidatePostStateWeak(i)
       /\ l' = l + 1

TraceHandleRequestVoteRequest ==
    /\ IsEvent("HandleRequestVoteRequest")
    /\ LET i == logline.node
       IN
       /\ \E m \in DOMAIN messages :
            /\ m.mtype = RequestVoteRequest
            /\ m.mdest = i
            \* Constrain to RV from the specific candidate in the trace
            /\ IF "from" \in DOMAIN logline
               THEN m.msource = logline.from
               ELSE TRUE
            /\ HandleRequestVoteRequest(i, m)
       /\ ValidatePostState(i)
       /\ ValidateVotedFor(i)
       /\ l' = l + 1

TraceHandleRequestVoteResponse ==
    /\ IsEvent("HandleRequestVoteResponse")
    /\ LET i == logline.node
       IN
       /\ \E m \in DOMAIN messages :
            /\ m.mtype = RequestVoteResponse
            /\ m.mdest = i
            \* Constrain to response from the specific voter in the trace
            /\ IF "from" \in DOMAIN logline
               THEN m.msource = logline.from
               ELSE TRUE
            /\ HandleRequestVoteResponse(i, m)
       /\ ValidatePostStateWeak(i)
       /\ l' = l + 1

TraceBecomeLeader ==
    /\ IsEvent("BecomeLeader")
    /\ LET i == logline.node
       IN
       /\ BecomeLeader(i)
       /\ ValidatePostState(i)
       /\ l' = l + 1

\* --- Log replication events ---

TraceClientRequest ==
    /\ IsEvent("ClientRequest")
    /\ LET i == logline.node
       IN
       /\ ClientRequest(i)
       /\ ValidatePostState(i)
       /\ l' = l + 1

TraceAppendEntries ==
    /\ IsEvent("AppendEntries")
    /\ LET i == logline.from
           j == logline.to
       IN
       /\ AppendEntries(i, j)
       /\ l' = l + 1

TraceHandleAppendEntriesRequest ==
    /\ IsEvent("HandleAppendEntriesRequest")
    /\ LET i == logline.node
       IN
       /\ \E m \in DOMAIN messages :
            /\ m.mtype = AppendEntriesRequest
            /\ m.mdest = i
            \* Constrain to AE from the specific leader in the trace
            /\ IF "from" \in DOMAIN logline
               THEN m.msource = logline.from
               ELSE TRUE
            /\ HandleAppendEntriesRequest(i, m)
       /\ ValidatePostState(i)
       /\ ValidateVotedFor(i)
       /\ l' = l + 1

TraceHandleAppendEntriesResponse ==
    /\ IsEvent("HandleAppendEntriesResponse")
    /\ LET i == logline.node
       IN
       /\ \E m \in DOMAIN messages :
            /\ m.mtype = AppendEntriesResponse
            /\ m.mdest = i
            \* Constrain to response from the specific peer in the trace
            /\ IF "from" \in DOMAIN logline
               THEN m.msource = logline.from
               ELSE TRUE
            /\ HandleAppendEntriesResponse(i, m)
       /\ ValidatePostStateWeak(i)
       /\ l' = l + 1

TraceAdvanceCommitIndex ==
    /\ IsEvent("AdvanceCommitIndex")
    /\ LET i == logline.node
       IN
       /\ AdvanceCommitIndex(i)
       /\ IF "commitIndex" \in DOMAIN logline
          THEN commitIndex'[i] = logline.commitIndex
          ELSE TRUE
       /\ l' = l + 1

\* --- Crash/recovery ---

TraceCrash ==
    /\ IsEvent("Crash")
    /\ LET i == logline.node
       IN
       /\ Crash(i)
       /\ l' = l + 1

----
\* Silent actions
\*
\* Handle implementation state changes that don't emit trace events.
\* Each silent action MUST be tightly constrained to prevent state explosion.
----

\* Silent AppendEntries: leader sends heartbeat/entries without trace event.
\* Constrained: only fire when the NEXT trace event requires a matching
\* AE request and none exists in the message bag. Uses the trace event's
\* from field to identify the specific leader.
SilentAppendEntries ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event = "HandleAppendEntriesRequest"
    /\ LET i == TraceLog[l].node
           leader == TraceLog[l].from
       IN
       \* Only send if no matching AE request from this leader exists for this node
       /\ ~\E m \in DOMAIN messages :
            /\ m.mtype = AppendEntriesRequest
            /\ m.mdest = i
            /\ m.msource = leader
       /\ state[leader] = Leader
       /\ AppendEntries(leader, i)
    /\ UNCHANGED <<l>>

\* Silent HandleRequestVoteRequest: voter processes RV without trace event.
\* Constrained: only when the upcoming HandleRequestVoteResponse needs a
\* response that isn't already in the message bag. Processes the specific
\* RV request from the candidate to the voter mentioned in the trace event.
SilentHandleRequestVoteRequest ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event = "HandleRequestVoteResponse"
    /\ LET candidate == TraceLog[l].node
           voter == TraceLog[l].from
       IN
       \* Only fire when the needed response is NOT already in the bag
       /\ ~\E m \in DOMAIN messages :
            /\ m.mtype = RequestVoteResponse
            /\ m.mdest = candidate
            /\ m.msource = voter
       \* Process the specific RV request from candidate to voter
       /\ \E m \in DOMAIN messages :
            /\ m.mtype = RequestVoteRequest
            /\ m.msource = candidate
            /\ m.mdest = voter
            /\ HandleRequestVoteRequest(voter, m)
    /\ UNCHANGED <<l>>

\* Silent AdvanceCommitIndex: leader advances commit between traced events.
\* Do NOT fire when the next event is an explicit AdvanceCommitIndex,
\* to avoid consuming the advancement before the traced event can fire.
SilentAdvanceCommitIndex ==
    /\ l <= Len(TraceLog)
    /\ TraceLog[l].event /= "AdvanceCommitIndex"
    /\ \E i \in TraceServer :
        /\ state[i] = Leader
        /\ AdvanceCommitIndex(i)
    /\ UNCHANGED <<l>>

\* Silent DropStaleMessage: remove stale messages from bag.
SilentDropStaleMessage ==
    /\ l <= Len(TraceLog)
    /\ \E m \in DOMAIN messages :
        /\ DropStaleMessage(m)
    /\ UNCHANGED <<l>>

----
\* TraceNext
----

TraceNext ==
    \* Traced actions (consume event, advance cursor)
    \/ TraceTimeout
    \/ TraceHandleRequestVoteRequest
    \/ TraceHandleRequestVoteResponse
    \/ TraceBecomeLeader
    \/ TraceClientRequest
    \/ TraceAppendEntries
    \/ TraceHandleAppendEntriesRequest
    \/ TraceHandleAppendEntriesResponse
    \/ TraceAdvanceCommitIndex
    \/ TraceCrash
    \* Silent actions (no cursor advance)
    \/ SilentAppendEntries
    \/ SilentHandleRequestVoteRequest
    \/ SilentAdvanceCommitIndex
    \/ SilentDropStaleMessage

----
\* Trace spec and properties
----

TraceSpec == TraceInit /\ [][TraceNext]_allVars

\* Temporal property: entire trace was consumed
TraceMatched == <>(l > Len(TraceLog))

\* Diagnostic alias for TLC output
TraceAlias ==
    [
        l          |-> l,
        event      |-> IF l <= Len(TraceLog) THEN TraceLog[l].event ELSE "DONE",
        node       |-> IF l <= Len(TraceLog) THEN TraceLog[l].node ELSE "DONE",
        terms      |-> [s \in TraceServer |-> currentTerm[s]],
        states     |-> [s \in TraceServer |-> state[s]],
        votedFor   |-> [s \in TraceServer |-> votedFor[s]],
        commits    |-> [s \in TraceServer |-> commitIndex[s]],
        logLens    |-> [s \in TraceServer |-> Len(log[s])],
        msgCount   |-> BagCardinality(messages)
    ]

=============================================================================
