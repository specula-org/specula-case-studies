---- MODULE Trace ----
\* Trace validation spec for Apache Ratis.
\* Replays NDJSON traces against the base spec to verify consistency.

EXTENDS base, Json, IOUtils, Sequences, TLC

\* ============================================================================
\* Trace Loading
\* ============================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTraceLog == ndJsonDeserialize(JsonFile)

\* Filter to only protocol-relevant events
TraceLog == SelectSeq(RawTraceLog, LAMBDA e : "event" \in DOMAIN e)

\* ============================================================================
\* Cursor Variable
\* ============================================================================

VARIABLE l   \* Trace cursor: index into TraceLog

traceVars == <<vars, l>>

logline == TraceLog[l]

\* ============================================================================
\* Server Extraction
\* ============================================================================

\* Derive Server set from trace
TraceServer == {TraceLog[i].node : i \in 1..Len(TraceLog)}

\* ============================================================================
\* Role/Type Mapping
\* ============================================================================

RoleMap(r) ==
    CASE r = "FOLLOWER"  -> Follower
      [] r = "CANDIDATE" -> Candidate
      [] r = "LEADER"    -> Leader
      [] OTHER           -> Follower

PhaseMap(p) ==
    CASE p = "PRE_VOTE"  -> PreVote
      [] p = "ELECTION"  -> Election
      [] OTHER           -> Election

ResultMap(r) ==
    CASE r = "SUCCESS"        -> SUCCESS
      [] r = "INCONSISTENCY"  -> INCONSISTENCY
      [] r = "NOT_LEADER"     -> NOT_LEADER
      [] OTHER                -> NOT_LEADER

\* ============================================================================
\* Event Predicates
\* ============================================================================

IsEvent(name) == logline.event = name

IsNodeEvent(name, s) ==
    /\ logline.event = name
    /\ logline.node = s

IsMsgEvent(name, src, dst) ==
    /\ logline.event = name
    /\ logline.src = src
    /\ logline.dst = dst

\* ============================================================================
\* Post-State Validation
\* ============================================================================

\* Strong validation: check term, role, commitIndex, lastLogIndex
\* Note: LastLogIndex(s)' is inlined to avoid TLC scoping issue with LET-bound
\* variables inside primed operator calls (l becomes undefined in primed context).
ValidatePostState(s) ==
    /\ ("term" \in DOMAIN logline) => currentTerm'[s] = logline.term
    /\ ("role" \in DOMAIN logline) => role'[s] = RoleMap(logline.role)
    /\ ("commitIndex" \in DOMAIN logline) => commitIndex'[s] = logline.commitIndex
    /\ ("lastLogIndex" \in DOMAIN logline) =>
        (Len(log'[s]) + snapshotIndex'[s]) = logline.lastLogIndex

\* Weak validation: only term + role
ValidatePostStateWeak(s) ==
    /\ ("term" \in DOMAIN logline) => currentTerm'[s] = logline.term
    /\ ("role" \in DOMAIN logline) => role'[s] = RoleMap(logline.role)

\* ============================================================================
\* Action Wrappers
\* ============================================================================

\* --- Election actions ---

\* Timeout: server starts election
TraceTimeout ==
    /\ IsEvent("Timeout")
    /\ LET s == logline.node IN
       /\ Timeout(s)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* PreVote: server sends pre-vote requests
TracePreVote ==
    /\ IsEvent("PreVote")
    /\ LET s == logline.node IN
       /\ StartPreVote(s)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* HandleRequestVoteRequest: server receives vote request
TraceHandleRequestVoteRequest ==
    /\ IsEvent("HandleRequestVoteRequest")
    /\ LET s == logline.node IN
       /\ \E m \in DOMAIN messages :
          /\ messages[m] > 0
          /\ m.mtype = RequestVoteRequest
          /\ m.mdst = s
          /\ ("src" \in DOMAIN logline) => m.msrc = logline.src
          /\ HandleRequestVoteRequest(s, m)
       /\ ValidatePostState(s)
    /\ l' = l + 1

\* HandleRequestVoteResponse: candidate receives vote response and becomes leader
\* Uses Weak validation because the spec appends a no-op on becoming leader,
\* but the implementation trace is captured before the no-op entry.
TraceHandleRequestVoteResponse ==
    /\ IsEvent("HandleRequestVoteResponse")
    /\ LET s == logline.node IN
       /\ \E m \in DOMAIN messages :
          /\ messages[m] > 0
          /\ m.mtype = RequestVoteResponse
          /\ m.mdst = s
          /\ HandleRequestVoteResponse(s, m)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* HandleRequestVoteResponseHigherTerm: step down on higher term
TraceHandleRequestVoteResponseHigherTerm ==
    /\ IsEvent("HandleRequestVoteResponseHigherTerm")
    /\ LET s == logline.node IN
       /\ \E m \in DOMAIN messages :
          /\ messages[m] > 0
          /\ m.mtype = RequestVoteResponse
          /\ m.mdst = s
          /\ HandleRequestVoteResponseHigherTerm(s, m)
       /\ ValidatePostState(s)
    /\ l' = l + 1

\* --- Log replication actions ---

\* ClientRequest: leader appends entry
TraceClientRequest ==
    /\ IsEvent("ClientRequest")
    /\ LET s == logline.node IN
       /\ \E v \in Value : ClientRequest(s, v)
       /\ ValidatePostState(s)
    /\ l' = l + 1

\* FlushLog: async disk write completes
TraceFlushLog ==
    /\ IsEvent("FlushLog")
    /\ LET s == logline.node IN
       /\ FlushLog(s)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* Pre-state check for leader-side events (captured BEFORE the action).
\* Forces silent actions to fill any gaps before the trace action fires.
ValidatePreState(s) ==
    /\ ("term" \in DOMAIN logline) => currentTerm[s] = logline.term
    /\ ("commitIndex" \in DOMAIN logline) => commitIndex[s] = logline.commitIndex
    /\ ("lastLogIndex" \in DOMAIN logline) =>
        (Len(log[s]) + snapshotIndex[s]) = logline.lastLogIndex

\* AppendEntries: leader sends log entries
TraceAppendEntries ==
    /\ IsEvent("AppendEntries")
    /\ LET s == logline.node
           t == logline.dst
       IN
       /\ ValidatePreState(s)
       /\ AppendEntries(s, t)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* Heartbeat: leader sends empty AppendEntries
TraceHeartbeat ==
    /\ IsEvent("Heartbeat")
    /\ LET s == logline.node
           t == logline.dst
       IN
       /\ ValidatePreState(s)
       /\ Heartbeat(s, t)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* HandleAppendEntriesRequest: follower receives AppendEntries
TraceHandleAppendEntriesRequest ==
    /\ IsEvent("HandleAppendEntriesRequest")
    /\ LET s == logline.node IN
       /\ \E m \in DOMAIN messages :
          /\ messages[m] > 0
          /\ m.mtype = AppendEntriesRequest
          /\ m.mdst = s
          /\ ("src" \in DOMAIN logline) => m.msrc = logline.src
          /\ HandleAppendEntriesRequest(s, m)
       /\ ValidatePostState(s)
    /\ l' = l + 1

\* HandleAppendEntriesResponse: leader receives AppendEntries reply
TraceHandleAppendEntriesResponse ==
    /\ IsEvent("HandleAppendEntriesResponse")
    /\ LET s == logline.node IN
       \* Pre-state check: leader log must match trace (forces SilentClientRequest first)
       /\ ("lastLogIndex" \in DOMAIN logline) => LastLogIndex(s) >= logline.lastLogIndex
       /\ \E m \in DOMAIN messages :
          /\ messages[m] > 0
          /\ m.mtype = AppendEntriesResponse
          /\ m.mdst = s
          /\ ("src" \in DOMAIN logline) => m.msrc = logline.src
          /\ HandleAppendEntriesResponse(s, m)
       /\ ValidatePostState(s)
    /\ l' = l + 1

\* --- Commit advancement ---

TraceAdvanceCommitIndex ==
    /\ IsEvent("AdvanceCommitIndex")
    /\ LET s == logline.node IN
       \/ /\ role[s] = Leader
          /\ AdvanceCommitIndex(s)
          /\ ValidatePostState(s)
       \/ /\ role[s] /= Leader
          \* Follower commit update is part of HandleAppendEntriesRequest in the spec;
          \* the implementation emits a separate AdvanceCommitIndex event, consume as no-op.
          /\ UNCHANGED vars
    /\ l' = l + 1

\* --- Configuration changes ---

TraceProposeConfigChange ==
    /\ IsEvent("ProposeConfigChange")
    /\ LET s == logline.node IN
       /\ \E newPeers \in SUBSET Server \ {{}} :
          /\ ProposeConfigChange(s, newPeers)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

TraceCommitJointConfig ==
    /\ IsEvent("CommitJointConfig")
    /\ LET s == logline.node IN
       /\ CommitJointConfig(s)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* --- Reads ---

TraceClientRead ==
    /\ IsEvent("ClientRead")
    /\ LET s == logline.node IN
       /\ ClientRead(s)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

TraceExtendLease ==
    /\ IsEvent("ExtendLease")
    /\ LET s == logline.node IN
       /\ ExtendLease(s)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* --- Snapshots ---

TraceTakeSnapshot ==
    /\ IsEvent("TakeSnapshot")
    /\ LET s == logline.node IN
       /\ TakeSnapshot(s)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

TraceSendInstallSnapshot ==
    /\ IsEvent("SendInstallSnapshot")
    /\ LET s == logline.node
           t == logline.dst
       IN
       /\ SendInstallSnapshot(s, t)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

TraceHandleInstallSnapshotRequest ==
    /\ IsEvent("HandleInstallSnapshotRequest")
    /\ LET s == logline.node IN
       /\ \E m \in DOMAIN messages :
          /\ messages[m] > 0
          /\ m.mtype = InstallSnapshotRequest
          /\ m.mdst = s
          /\ HandleInstallSnapshotRequest(s, m)
       /\ ValidatePostState(s)
    /\ l' = l + 1

TraceHandleInstallSnapshotResponse ==
    /\ IsEvent("HandleInstallSnapshotResponse")
    /\ LET s == logline.node IN
       /\ \E m \in DOMAIN messages :
          /\ messages[m] > 0
          /\ m.mtype = InstallSnapshotResponse
          /\ m.mdst = s
          /\ HandleInstallSnapshotResponse(s, m)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* --- Leadership management ---

TraceCheckLeadership ==
    /\ IsEvent("CheckLeadership")
    /\ LET s == logline.node IN
       /\ CheckLeadership(s)
       /\ ValidatePostState(s)
    /\ l' = l + 1

TraceExpireLeaderValidity ==
    /\ IsEvent("ExpireLeaderValidity")
    /\ LET s == logline.node IN
       /\ ExpireLeaderValidity(s)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* --- Crash ---

TraceCrash ==
    /\ IsEvent("Crash")
    /\ LET s == logline.node IN
       /\ Crash(s)
       /\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* ============================================================================
\* Silent Actions (no trace event consumed)
\* Must be tightly constrained to avoid state space explosion.
\* ============================================================================

\* Silent FlushLog: disk write completes between trace events
SilentFlushLog ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Server :
       /\ flushIndex[s] < LastLogIndex(s)
       \* Only allow flush if next event is for this server (tight constraint)
       /\ logline.node = s
       /\ FlushLog(s)
    /\ UNCHANGED l

\* Silent AdvanceCommitIndex: commit index advances between events
SilentAdvanceCommitIndex ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Server :
       /\ role[s] = Leader
       /\ logline.node = s
       /\ AdvanceCommitIndex(s)
    /\ UNCHANGED l

\* Silent ExtendLease: lease extension between events
SilentExtendLease ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Server :
       /\ role[s] = Leader
       /\ logline.node = s
       /\ ExtendLease(s)
    /\ UNCHANGED l

\* Silent ExpireLeaderValidity: follower validity timer expires
SilentExpireLeaderValidity ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Server :
       /\ role[s] = Follower
       /\ leaderValid[s]
       /\ logline.node = s
       /\ ExpireLeaderValidity(s)
    /\ UNCHANGED l

\* Silent ClientRequest: leader appends entry not captured in trace
\* Needed because the implementation may process client requests between traced events.
SilentClientRequest ==
    /\ l <= Len(TraceLog)
    /\ logline.event /= "ClientRequest"  \* Don't preempt explicit ClientRequest trace events
    /\ \E s \in Server :
       /\ role[s] = Leader
       /\ logline.node = s
       /\ "lastLogIndex" \in DOMAIN logline
       /\ LastLogIndex(s) < logline.lastLogIndex  \* Need more entries to match trace
       /\ \E v \in Value : ClientRequest(s, v)
    /\ UNCHANGED l

\* Silent HandleAppendEntriesRequest: follower processes heartbeat (empty entries)
\* without a trace event. Needed because heartbeat handling on followers is not traced.
\* Constrained to fire only when leader expects a response (HandleAppendEntriesResponse next),
\* preventing consumption of messages that explicit trace events need.
SilentHandleAppendEntriesRequest ==
    /\ l <= Len(TraceLog)
    /\ logline.event = "HandleAppendEntriesResponse"  \* Only fire before leader response events
    /\ \E s \in Server, m \in DOMAIN messages :
       /\ messages[m] > 0
       /\ m.mtype = AppendEntriesRequest
       /\ m.mdst = s
       /\ m.mentries = <<>>  \* Only heartbeats (empty entries)
       /\ logline.node = m.msrc  \* Next event is for the sender (leader)
       /\ HandleAppendEntriesRequest(s, m)
    /\ UNCHANGED l

\* ============================================================================
\* Init and Next
\* ============================================================================

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \/ (l <= Len(TraceLog) /\
        (\/ TraceTimeout
         \/ TracePreVote
         \/ TraceHandleRequestVoteRequest
         \/ TraceHandleRequestVoteResponse
         \/ TraceHandleRequestVoteResponseHigherTerm
         \/ TraceClientRequest
         \/ TraceFlushLog
         \/ TraceAppendEntries
         \/ TraceHeartbeat
         \/ TraceHandleAppendEntriesRequest
         \/ TraceHandleAppendEntriesResponse
         \/ TraceAdvanceCommitIndex
         \/ TraceProposeConfigChange
         \/ TraceCommitJointConfig
         \/ TraceClientRead
         \/ TraceExtendLease
         \/ TraceTakeSnapshot
         \/ TraceSendInstallSnapshot
         \/ TraceHandleInstallSnapshotRequest
         \/ TraceHandleInstallSnapshotResponse
         \/ TraceCheckLeadership
         \/ TraceExpireLeaderValidity
         \/ TraceCrash))
    \* Silent actions
    \/ SilentFlushLog
    \/ SilentAdvanceCommitIndex
    \/ SilentExtendLease
    \/ SilentExpireLeaderValidity
    \/ SilentHandleAppendEntriesRequest
    \/ SilentClientRequest

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

\* ============================================================================
\* Trace Completion
\* ============================================================================

\* Temporal property: trace was fully consumed
TraceMatched == <>(l = Len(TraceLog) + 1)

\* Alias for TLC output
TraceAlias ==
    [
        cursor |-> l,
        event  |-> IF l <= Len(TraceLog) THEN logline.event ELSE "DONE",
        node   |-> IF l <= Len(TraceLog) THEN logline.node ELSE "DONE"
    ]

====
