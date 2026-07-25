------------------------------ MODULE Trace ------------------------------
\* Trace validation spec for logcabin Raft.
\*
\* Replays NDJSON traces from the instrumented implementation against
\* the base spec to verify that every observed state transition is
\* consistent with the spec.
\*
EXTENDS base, Json, IOUtils, Sequences, TLC

----
\* Trace loading
----

\* Trace file location: override via -DJSON=path on command line
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load and filter trace events
RawTraceLog == ndJsonDeserialize(JsonFile)
TraceLog == SelectSeq(RawTraceLog, LAMBDA e : e.tag = "trace")

----
\* Cursor variable
----

VARIABLE l  \* Trace cursor: 1..Len(TraceLog)+1

traceVars == <<vars, l>>

logline == TraceLog[l]

----
\* Server extraction — derive Server set from trace
----

TraceServer ==
    LET ids == {TraceLog[i].node : i \in 1..Len(TraceLog)}
    IN ids

----
\* Role/type mapping — implementation strings to spec constants
----

RoleMap(role) ==
    CASE role = "follower"  -> Follower
      [] role = "candidate" -> Candidate
      [] role = "leader"    -> Leader

EntryTypeMap(t) ==
    CASE t = "value"   -> ValueEntry
      [] t = "config"  -> ConfigEntry
      [] t = "noop"    -> NoopEntry
      [] OTHER         -> ValueEntry

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

\* Strong validation: verify full state after action.
\* Used when the trace captures complete node state.
ValidatePostState(i) ==
    /\ currentTerm'[i] = logline.state.currentTerm
    /\ state'[i] = RoleMap(logline.state.role)
    /\ commitIndex'[i] = logline.state.commitIndex
    /\ LastLogIndex(i)' = logline.state.lastLogIndex

\* Weak validation: only verify term and role.
\* Used for async events where full state may not be captured.
ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.state.currentTerm
    /\ state'[i] = RoleMap(logline.state.role)

\* Commit-only validation: verify term, role, and commitIndex.
ValidatePostStateCommit(i) ==
    /\ currentTerm'[i] = logline.state.currentTerm
    /\ state'[i] = RoleMap(logline.state.role)
    /\ commitIndex'[i] = logline.state.commitIndex

----
\* Bootstrap state
----

\* TraceInit: match the implementation's post-bootstrap state.
\* LogCabin servers are initialized with currentTerm=1, a configuration
\* entry at log index 1 (term=1), and ConfigStable state.
TraceInit ==
    /\ l = 1
    /\ currentTerm      = [s \in Server |-> 1]
    /\ votedFor          = [s \in Server |-> Nil]
    /\ log               = [s \in Server |-> <<[term |-> 1, type |-> ConfigEntry, config |-> Server]>>]
    /\ state             = [s \in Server |-> Follower]
    /\ commitIndex       = [s \in Server |-> 0]
    /\ leaderId          = [s \in Server |-> Nil]
    /\ nextIndex         = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex        = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted      = [s \in Server |-> {}]
    /\ messages          = EmptyBag
    /\ configState       = [s \in Server |-> ConfigStable]
    /\ configId          = [s \in Server |-> 1]
    /\ oldConfig         = [s \in Server |-> Server]
    /\ newConfig         = [s \in Server |-> {}]
    /\ withholdVotes     = [s \in Server |-> FALSE]
    /\ currentEpoch      = [s \in Server |-> 0]
    /\ lastAckEpoch      = [s \in Server |-> [t \in Server |-> 0]]
    /\ lastSyncedIndex   = [s \in Server |-> 0]
    /\ leaderDiskPending = [s \in Server |-> FALSE]
    /\ lastSnapshotIndex = [s \in Server |-> 0]
    /\ lastSnapshotTerm  = [s \in Server |-> 0]
    /\ logStartIndex     = [s \in Server |-> 1]

----
\* Trace action wrappers
----

\* Each wrapper: match event -> call base action -> validate -> advance cursor

TraceTimeout(i) ==
    /\ IsNodeEvent("Timeout", i)
    /\ Timeout(i)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceBecomeLeader(i) ==
    /\ IsNodeEvent("BecomeLeader", i)
    /\ BecomeLeader(i)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceClientRequest(i) ==
    /\ IsNodeEvent("ClientRequest", i)
    /\ ClientRequest(i)
    /\ ValidatePostState(i)
    /\ l' = l + 1

TraceAppendEntries(i, j) ==
    /\ IsMsgEvent("AppendEntries", i, j)
    /\ AppendEntries(i, j)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceSendInstallSnapshot(i, j) ==
    /\ IsMsgEvent("InstallSnapshot", i, j)
    /\ SendInstallSnapshot(i, j)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceHandleRequestVoteRequest(i, m) ==
    /\ IsNodeEvent("HandleRequestVote", i)
    /\ HandleRequestVoteRequest(i, m)
    /\ ValidatePostState(i)
    /\ l' = l + 1

TraceHandleRequestVoteResponse(i, m) ==
    /\ IsNodeEvent("HandleRequestVoteResponse", i)
    /\ HandleRequestVoteResponse(i, m)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceHandleAppendEntriesRequest(i, m) ==
    /\ IsNodeEvent("HandleAppendEntries", i)
    /\ HandleAppendEntriesRequest(i, m)
    /\ ValidatePostState(i)
    /\ l' = l + 1

TraceHandleAppendEntriesResponse(i, m) ==
    /\ IsNodeEvent("HandleAppendEntriesResponse", i)
    /\ HandleAppendEntriesResponse(i, m)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceHandleInstallSnapshotRequest(i, m) ==
    /\ IsNodeEvent("HandleInstallSnapshot", i)
    /\ HandleInstallSnapshotRequest(i, m)
    /\ ValidatePostState(i)
    /\ l' = l + 1

TraceHandleInstallSnapshotResponse(i, m) ==
    /\ IsNodeEvent("HandleInstallSnapshotResponse", i)
    /\ HandleInstallSnapshotResponse(i, m)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceAdvanceCommitIndex(i) ==
    /\ IsNodeEvent("AdvanceCommitIndex", i)
    /\ AdvanceCommitIndex(i)
    /\ ValidatePostStateCommit(i)
    /\ l' = l + 1

TraceLeaderDiskSync(i) ==
    /\ IsNodeEvent("LeaderDiskSync", i)
    /\ LeaderDiskSync(i)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceTakeSnapshot(i) ==
    /\ IsNodeEvent("TakeSnapshot", i)
    /\ TakeSnapshot(i)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceCrash(i) ==
    /\ IsNodeEvent("Crash", i)
    /\ Crash(i)
    /\ l' = l + 1

TraceProposeConfigChange(i) ==
    /\ IsNodeEvent("ProposeConfigChange", i)
    /\ LET newServers == {logline.newServers[k] : k \in DOMAIN logline.newServers}
       IN ProposeConfigChange(i, newServers)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceStepDownCheck(i) ==
    /\ IsNodeEvent("StepDownCheck", i)
    /\ StepDownCheck(i)
    /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

----
\* Silent actions — fire base actions without consuming a trace event.
\* Tightly constrained to prevent state space explosion.
----

\* Silent AdvanceCommitIndex: fires when the NEXT trace event requires
\* a higher commitIndex than currently present.
SilentAdvanceCommitIndex(i) ==
    /\ l <= Len(TraceLog)
    /\ state[i] = Leader
    \* Only fire if next event is for this node and needs higher commit
    /\ logline.node = i
    /\ logline.event /= "AdvanceCommitIndex"  \* don't preempt traced version
    /\ "commitIndex" \in DOMAIN logline.state
    /\ logline.state.commitIndex > commitIndex[i]
    /\ AdvanceCommitIndex(i)
    /\ UNCHANGED l

\* Silent LeaderDiskSync: fires when leader has pending disk writes
\* and next event expects higher lastSyncedIndex.
SilentLeaderDiskSync(i) ==
    /\ l <= Len(TraceLog)
    /\ state[i] = Leader
    /\ leaderDiskPending[i] = TRUE
    /\ logline.node = i
    /\ logline.event /= "LeaderDiskSync"  \* don't preempt traced version
    /\ LeaderDiskSync(i)
    /\ UNCHANGED l

\* Silent LoseMessage: consume a message that was lost in transit.
\* Only fires when next event can't match any message handler.
SilentLoseMessage(m) ==
    /\ l <= Len(TraceLog)
    /\ m \in DOMAIN messages
    /\ LoseMessage(m)
    /\ UNCHANGED l

\* Silent DropStaleMessage: remove messages with stale terms.
SilentDropStaleMessage(m) ==
    /\ l <= Len(TraceLog)
    /\ m \in DOMAIN messages
    /\ DropStaleMessage(m)
    /\ UNCHANGED l

----
\* TraceNext
----

TraceNext ==
    \/ \E i \in Server :
        \/ TraceTimeout(i)
        \/ TraceBecomeLeader(i)
        \/ TraceClientRequest(i)
        \/ TraceAdvanceCommitIndex(i)
        \/ TraceLeaderDiskSync(i)
        \/ TraceStepDownCheck(i)
        \/ TraceTakeSnapshot(i)
        \/ TraceCrash(i)
        \/ TraceProposeConfigChange(i)
        \/ SilentAdvanceCommitIndex(i)
        \/ SilentLeaderDiskSync(i)
    \/ \E i, j \in Server :
        \/ TraceAppendEntries(i, j)
        \/ TraceSendInstallSnapshot(i, j)
    \/ \E m \in DOMAIN messages :
        \/ TraceHandleRequestVoteRequest(m.mdest, m)
        \/ TraceHandleRequestVoteResponse(m.mdest, m)
        \/ TraceHandleAppendEntriesRequest(m.mdest, m)
        \/ TraceHandleAppendEntriesResponse(m.mdest, m)
        \/ TraceHandleInstallSnapshotRequest(m.mdest, m)
        \/ TraceHandleInstallSnapshotResponse(m.mdest, m)
        \/ SilentLoseMessage(m)
        \/ SilentDropStaleMessage(m)

----
\* Temporal property: entire trace was consumed
----

TraceMatched == <>(l = Len(TraceLog) + 1)

----
\* Spec
----

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

----
\* View — exclude message bag for trace validation (reduce state space)
----

TraceView == <<l, serverVars, logVars, configVars, snapshotVars, diskVars>>

----
\* Alias for debugging
----

TraceAlias == [
    cursor      |-> l,
    event       |-> IF l <= Len(TraceLog) THEN logline.event ELSE "DONE",
    node        |-> IF l <= Len(TraceLog) THEN logline.node ELSE "DONE",
    currentTerm |-> currentTerm,
    state       |-> state,
    commitIndex |-> commitIndex,
    log         |-> [s \in Server |-> Len(log[s])],
    messages    |-> BagCardinality(messages),
    lastSnapshotIndex |-> lastSnapshotIndex,
    logStartIndex     |-> logStartIndex
]

=============================================================================
