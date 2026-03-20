------------------------------ MODULE Trace ------------------------------
\* Trace validation specification for nuraft.
\*
\* Replays implementation traces against the base spec to verify
\* that every observed state transition matches a valid spec action.
\*
EXTENDS base, Sequences, TLCExt, IOUtils, Json, Bags

----
\* Trace Loading
----

\* Trace file path: default or override via IOEnv.JSON
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load raw NDJSON
RawLog == ndJsonDeserialize(JsonFile)

\* Extract config line (tag = "config") for initial snapshot
ConfigLine == TLCEval(
    LET configs == SelectSeq(RawLog, LAMBDA x :
        /\ "tag" \in DOMAIN x /\ x.tag = "config")
    IN IF Len(configs) > 0 THEN configs[1] ELSE [tag |-> "none"])

HasSnapshot == "snapshot" \in DOMAIN ConfigLine

\* Load and filter trace events tagged "trace"
TraceLog == TLCEval(
    SelectSeq(RawLog, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x))

----
\* Trace Variables
----

VARIABLE l       \* Cursor: current position in TraceLog (1-indexed)

traceVars == <<l>>
allVars == <<vars, l>>

\* Current log line accessor (only valid when l <= Len(TraceLog))
logline == TraceLog[l]

\* Advance cursor by one event
StepTrace == l' = l + 1

----
\* Mapping Helpers
----

\* Map implementation role strings to spec constants
\* Reference: nuraft srv_role enum: follower=1, candidate=2, leader=3
RaftRole(str) ==
    CASE str = "follower"  -> Follower
      [] str = "candidate" -> Candidate
      [] str = "leader"    -> Leader

\* Extract server set from trace events
TraceServer ==
    LET ids == {TraceLog[i].nid : i \in 1..Len(TraceLog)}
    IN ids

\* Map server ID string to spec Server constant
\* The instrumentation uses integer node IDs.
MapServer(id) == id

----
\* Event Predicates
----

\* Match event by name at current cursor position
IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

\* Match node-specific event
IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.nid = i

\* Match message event with sender/receiver
IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ logline.from = from
    /\ logline.to = to

----
\* Post-State Validation
----

\* Strong validation: checks all core state fields.
\* Used for actions where the trace captures full state.
ValidatePostState(i) ==
    /\ currentTerm'[i] = logline.state.term
    /\ state'[i] = RaftRole(logline.state.role)
    /\ commitIndex'[i] = logline.state.commitIndex
    /\ LastLogIndex(i)' = logline.state.lastLogIndex

\* Weak validation: only term and role.
\* Used for async or concurrent code paths.
ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.state.term
    /\ state'[i] = RaftRole(logline.state.role)

\* Commit validation: term, role, and commit index.
ValidatePostStateCommit(i) ==
    /\ currentTerm'[i] = logline.state.term
    /\ state'[i] = RaftRole(logline.state.role)
    /\ commitIndex'[i] = logline.state.commitIndex

----
\* Trace Init
----

\* nuraft initializes with term=0, votedFor=-1 (mapped to Nil),
\* empty log, follower role.
\* When a snapshot config line is present, use it to set initial state
\* (for traces that start after cluster formation).
\* Reference: raft_server.cxx:51-163 (constructor)
SnapshotInit ==
    LET snap == ConfigLine.snapshot
    IN
    /\ currentTerm      = [s \in Server |-> snap[s].term]
    /\ votedFor          = [s \in Server |-> Nil]
    /\ log               = [s \in Server |->
        LET n == snap[s].lastLogIndex
        IN [idx \in 1..n |-> [term |-> snap[s].lastLogTerm, type |-> ConfigEntry]]]
    /\ state             = [s \in Server |-> RaftRole(snap[s].role)]
    /\ commitIndex       = [s \in Server |-> snap[s].commitIndex]
    /\ smCommitIndex     = [s \in Server |-> snap[s].smCommitIndex]
    /\ precommitIndex    = [s \in Server |-> snap[s].lastLogIndex]
    /\ nextIndex         = [s \in Server |-> [t \in Server |-> snap[s].lastLogIndex + 1]]
    /\ matchIndex        = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted      = [s \in Server |-> IF snap[s].role = "leader" THEN Server ELSE {}]
    /\ preVotesGranted   = [s \in Server |-> {}]
    /\ persistedTerm     = [s \in Server |-> snap[s].term]
    /\ persistedVotedFor = [s \in Server |-> Nil]
    /\ configChanging    = [s \in Server |-> FALSE]
    /\ customQuorumSize  = [s \in Server |-> 0]
    /\ hbAlive           = [s \in Server |-> state[s] /= Leader]
    /\ messages          = EmptyBag

TraceInit ==
    /\ IF HasSnapshot THEN SnapshotInit ELSE Init
    /\ l = 1

----
\* Action Wrappers
\*
\* Each wrapper: match event → call base action → validate → advance cursor
----

\* === Election / Pre-Vote ===

TraceTimeout ==
    \E i \in Server :
        /\ IsNodeEvent("Timeout", i)
        /\ Timeout(i)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

TraceHandlePreVoteRequest ==
    \E i \in Server :
        /\ IsNodeEvent("HandlePreVoteRequest", i)
        /\ \E m \in DOMAIN messages :
            /\ HandlePreVoteRequest(i, m)
            /\ ValidatePostStateWeak(i)
        /\ StepTrace

TraceHandlePreVoteResponse ==
    \E i \in Server :
        /\ IsNodeEvent("HandlePreVoteResponse", i)
        /\ \E m \in DOMAIN messages :
            /\ HandlePreVoteResponse(i, m)
            /\ ValidatePostStateWeak(i)
        /\ StepTrace

TraceInitiateVote ==
    \E i \in Server :
        /\ IsNodeEvent("InitiateVote", i)
        /\ InitiateVote(i)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

TraceHandleVoteRequest ==
    \E i \in Server :
        /\ IsNodeEvent("HandleVoteRequest", i)
        /\ \E m \in DOMAIN messages :
            /\ HandleVoteRequest(i, m)
            /\ ValidatePostStateWeak(i)
        /\ StepTrace

TraceHandleVoteResponse ==
    \E i \in Server :
        /\ IsNodeEvent("HandleVoteResponse", i)
        /\ \E m \in DOMAIN messages :
            /\ HandleVoteResponse(i, m)
            /\ ValidatePostStateWeak(i)
        /\ StepTrace

TraceBecomeLeader ==
    \E i \in Server :
        /\ IsNodeEvent("BecomeLeader", i)
        /\ BecomeLeader(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* === Log Replication ===

TraceClientRequest ==
    \E i \in Server :
        /\ IsNodeEvent("ClientRequest", i)
        /\ ClientRequest(i)
        /\ ValidatePostState(i)
        /\ StepTrace

TraceAppendEntries ==
    \E i \in Server :
        /\ IsNodeEvent("AppendEntries", i)
        \* Ensure commitIndex is already at the level shown in the trace.
        \* In nuraft, AdvanceCommitIndex runs inside the handler before sending AE,
        \* but the trace emits the AdvanceCommitIndex event AFTER the AE event.
        \* SilentAdvanceCommitIndex must fire first to bring commitIndex up.
        /\ commitIndex[i] >= logline.state.commitIndex
        /\ \E j \in Server \ {i} :
            /\ logline.to = j
            /\ AppendEntries(i, j)
        /\ ValidatePostStateWeak(i)
        /\ StepTrace

TraceHandleAppendEntries ==
    \E i \in Server :
        /\ IsNodeEvent("HandleAppendEntries", i)
        /\ \E m \in DOMAIN messages :
            /\ HandleAppendEntries(i, m)
            /\ ValidatePostState(i)
        /\ StepTrace

TraceHandleAppendEntriesResponse ==
    \E i \in Server :
        /\ IsNodeEvent("HandleAppendEntriesResponse", i)
        /\ \E m \in DOMAIN messages :
            /\ HandleAppendEntriesResponse(i, m)
            /\ ValidatePostStateWeak(i)
        /\ StepTrace

\* === Commit ===

TraceAdvanceCommitIndex ==
    \E i \in Server :
        /\ IsNodeEvent("AdvanceCommitIndex", i)
        /\ \/ \* Normal case: commitIndex not yet advanced
              /\ AdvanceCommitIndex(i)
              /\ ValidatePostStateCommit(i)
           \/ \* Idempotent case: commitIndex already advanced by SilentAdvanceCommitIndex
              /\ commitIndex[i] = logline.state.commitIndex
              /\ currentTerm[i] = logline.state.term
              /\ state[i] = RaftRole(logline.state.role)
              /\ UNCHANGED vars
        /\ StepTrace

TraceCommitEntry ==
    \E i \in Server :
        /\ IsNodeEvent("CommitEntry", i)
        /\ CommitEntry(i)
        /\ ValidatePostStateCommit(i)
        /\ StepTrace

\* === Config Change ===

TraceProposeConfigChange ==
    \E i \in Server :
        /\ IsNodeEvent("ProposeConfigChange", i)
        /\ ProposeConfigChange(i)
        /\ ValidatePostState(i)
        /\ StepTrace

\* === Quorum ===

TraceAdjustQuorum ==
    \E i \in Server :
        /\ IsNodeEvent("AdjustQuorum", i)
        /\ AdjustQuorum(i)
        /\ StepTrace

\* === Crash ===

TraceCrash ==
    \E i \in Server :
        /\ IsNodeEvent("Crash", i)
        /\ Crash(i)
        /\ StepTrace

\* === Persistence ===

TracePersistState ==
    \E i \in Server :
        /\ IsNodeEvent("PersistState", i)
        /\ PersistState(i)
        /\ StepTrace

----
\* Silent Actions
\*
\* Handle impl state changes without trace events.
\* Must be tightly constrained to avoid state space explosion.
----

\* Silent AppendEntries: leader sends AE that wasn't traced.
\* Tightly constrained: only fires for the specific destination of the next
\* HandleAppendEntries event, and only if no AEReq for that dest exists.
SilentAppendEntries ==
    /\ l <= Len(TraceLog)
    /\ logline.event = "HandleAppendEntries"
    \* Only fire if no AE request for the target is already in the bag
    /\ ~\E m \in DOMAIN messages :
        /\ m.mtype = AppendEntriesRequest
        /\ m.mdest = logline.nid
    /\ \E i \in Server :
        /\ i /= logline.nid
        /\ state[i] = Leader
        /\ AppendEntries(i, logline.nid)
    /\ UNCHANGED <<l>>

\* Silent AdvanceCommitIndex: leader commits without traced event.
\* Constrained: don't steal from a traced AdvanceCommitIndex event.
SilentAdvanceCommitIndex ==
    /\ l <= Len(TraceLog)
    /\ logline.event /= "AdvanceCommitIndex"
    /\ \E i \in Server :
        /\ state[i] = Leader
        /\ AdvanceCommitIndex(i)
    /\ UNCHANGED <<l>>

\* Silent CommitEntry: background commit thread advancing smCommitIndex.
\* Constrained: don't steal from a traced CommitEntry event.
SilentCommitEntry ==
    /\ l <= Len(TraceLog)
    /\ logline.event /= "CommitEntry"
    /\ \E i \in Server :
        /\ CommitEntry(i)
    /\ UNCHANGED <<l>>

\* Silent PersistState: persistence that wasn't traced.
SilentPersistState ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ PersistState(i)
    /\ UNCHANGED <<l>>

\* Silent DropStaleMessage: clean up messages that don't match any event.
SilentDropStaleMessage ==
    /\ l <= Len(TraceLog)
    /\ \E m \in DOMAIN messages :
        /\ DropStaleMessage(m)
    /\ UNCHANGED <<l>>

----
\* TraceNext
----

TraceNext ==
    \* Action wrappers (consume trace events)
    \/ TraceTimeout
    \/ TraceHandlePreVoteRequest
    \/ TraceHandlePreVoteResponse
    \/ TraceInitiateVote
    \/ TraceHandleVoteRequest
    \/ TraceHandleVoteResponse
    \/ TraceBecomeLeader
    \/ TraceClientRequest
    \/ TraceAppendEntries
    \/ TraceHandleAppendEntries
    \/ TraceHandleAppendEntriesResponse
    \/ TraceAdvanceCommitIndex
    \/ TraceCommitEntry
    \/ TraceProposeConfigChange
    \/ TraceAdjustQuorum
    \/ TraceCrash
    \/ TracePersistState
    \* Silent actions (no trace event consumed)
    \/ SilentAppendEntries
    \/ SilentAdvanceCommitIndex
    \*\/ SilentCommitEntry         \* Disabled: all commits are traced
    \*\/ SilentPersistState        \* Disabled: all persists are traced
    \*\/ SilentDropStaleMessage  \* Disabled: causes state explosion

----
\* Spec and Properties
----

TraceSpec == TraceInit /\ [][TraceNext]_allVars

\* Temporal property: eventually the entire trace is consumed.
\* This is checked via deadlock detection (INIT/NEXT style):
\* TLC reports "deadlock" when all events are consumed, which is success.
TraceMatched == <>(l > Len(TraceLog))

\* Debugging alias for TLC output
TraceAlias == [
    cursor     |-> l,
    event      |-> IF l <= Len(TraceLog) THEN logline.event ELSE "END",
    traceLen   |-> Len(TraceLog),
    terms      |-> [s \in Server |-> currentTerm[s]],
    roles      |-> [s \in Server |-> state[s]],
    commits    |-> [s \in Server |-> commitIndex[s]],
    smCommits  |-> [s \in Server |-> smCommitIndex[s]],
    precommits |-> [s \in Server |-> precommitIndex[s]],
    logLens    |-> [s \in Server |-> LastLogIndex(s)],
    msgCount   |-> BagCardinality(messages)
]

=============================================================================
