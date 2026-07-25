--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation spec for sofa-jraft.
 *
 * Category A (Distributed / Message-Passing).
 * Single-file NDJSON trace; cursor variable `l` walks through events.
 *
 * Each action wrapper:
 *   1. Checks IsEvent(name) — event at position l matches this action
 *   2. Calls the base spec action (full preconditions enforced)
 *   3. Validates post-state fields captured by instrumentation
 *   4. Advances l' = l + 1
 *
 * Silent actions fire base spec actions without consuming a trace event
 * (e.g., AdvanceCommitIndex, ApplyCommittedEntries, TickClock). These are
 * tightly constrained to avoid state-space explosion.
 *)

EXTENDS base, Sequences, TLC, IOUtils, Json

\* ============================================================================
\* TRACE LOADING
\* ============================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* ============================================================================
\* CURSOR
\* ============================================================================

VARIABLE l   \* current position in TraceLog (1-indexed)

TraceInit ==
    /\ Init
    /\ l = 1

\* Current log line (unprimed l — always refers to the event being consumed)
logline == TraceLog[l]

\* ============================================================================
\* SERVER MAPPING
\* ============================================================================

\* Map implementation server ID string to TLA+ Server constant
\* Populated from trace headers; override via IOEnv.SERVER_MAP if needed
ServerOf(str) ==
    CHOOSE s \in Server : ToString(s) = str

\* ============================================================================
\* EVENT PREDICATES
\* ============================================================================

\* True iff current logline is an event with the given name
IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

\* True iff current logline is an event for server s
IsNodeEvent(name, s) ==
    /\ IsEvent(name)
    /\ ServerOf(logline.node) = s

\* ============================================================================
\* POST-STATE VALIDATION HELPERS
\* (Use primed state vars + unprimed logline; call WITHOUT prime in wrappers)
\* ============================================================================

\* Validate key fields after an election-related action
ValidateServerState(s) ==
    /\ currentTerm'[s] = logline.currentTerm
    /\ ToString(role'[s]) = logline.role

\* Validate vote-persistence state (Family 1)
ValidatePersistState(s) ==
    /\ persistedTerm'[s] = logline.persistedTerm
    /\ (IF logline.persistedVotedFor = "nil"
        THEN persistedVotedFor'[s] = Nil
        ELSE persistedVotedFor'[s] = ServerOf(logline.persistedVotedFor))

\* Validate log state after append/apply
ValidateLogState(s) ==
    /\ LastLogIndex(s)' = logline.lastLogIndex
    /\ commitIndex'[s]  = logline.commitIndex
    /\ lastApplied'[s]  = logline.lastApplied

\* Validate ReadIndex state (Families 3, 4)
ValidateReadState(s) ==
    /\ Cardinality(pendingReadIndex'[s]) = logline.pendingReadCount

\* ============================================================================
\* ACTION WRAPPERS
\* ============================================================================

\* --- TraceElectionTimeout ---
\* Emitted by: NodeImpl.handleElectionTimeout() before electSelf
\* Event: "ElectionTimeout"
TraceElectionTimeout ==
    \E s \in Server :
        /\ IsNodeEvent("ElectionTimeout", s)
        /\ ElectionTimeout(s)
        /\ ValidateServerState(s)
        /\ l' = l + 1

\* --- TraceHandleRequestVoteRequestDeny ---
\* Emitted by: NodeImpl.handleRequestVoteRequest() rejection path
\* Event: "HandleRequestVoteRequestDeny"
TraceHandleRequestVoteRequestDeny ==
    \E s \in Server :
    \E m \in BagToSet(messages) :
        /\ IsNodeEvent("HandleRequestVoteRequestDeny", s)
        /\ HandleRequestVoteRequestDeny(s, m)
        /\ ValidateServerState(s)
        /\ l' = l + 1

\* --- TraceHandleRequestVoteRequestGrantSameTerm ---
\* Emitted by: NodeImpl.handleRequestVoteRequest() same-term grant path
\* Event: "HandleRequestVoteRequestGrantSameTerm"
TraceHandleRequestVoteRequestGrantSameTerm ==
    \E s \in Server :
    \E m \in BagToSet(messages) :
        /\ IsNodeEvent("HandleRequestVoteRequestGrantSameTerm", s)
        /\ HandleRequestVoteRequestGrantSameTerm(s, m)
        /\ ValidateServerState(s)
        /\ ValidatePersistState(s)
        /\ l' = l + 1

\* --- TraceHandleRequestVoteRequestHigherTermStep1 ---
\* Emitted by: after stepDown writes (term, emptyVotedFor) to disk
\* NodeImpl.java:1856 — between the two persistence writes
\* Event: "PersistTermEmptyVote"
TraceHandleRequestVoteRequestHigherTermStep1 ==
    \E s \in Server :
    \E m \in BagToSet(messages) :
        /\ IsNodeEvent("PersistTermEmptyVote", s)
        /\ HandleRequestVoteRequestHigherTermStep1(s, m)
        /\ ValidateServerState(s)
        /\ ValidatePersistState(s)
        /\ l' = l + 1

\* --- TraceHandleRequestVoteRequestHigherTermStep2 ---
\* Emitted by: after setVotedFor(candidateId) writes to disk
\* NodeImpl.java:1860
\* Event: "PersistActualVote"
TraceHandleRequestVoteRequestHigherTermStep2 ==
    \E s \in Server :
    \E m \in BagToSet(messages) :
        /\ IsNodeEvent("PersistActualVote", s)
        /\ HandleRequestVoteRequestHigherTermStep2(s, m)
        /\ ValidatePersistState(s)
        /\ l' = l + 1

\* --- TraceHandleRequestVoteRequestHigherTermStep3 ---
\* Emitted by: after response is sent
\* NodeImpl.java:1860
\* Event: "SendVoteGranted"
TraceHandleRequestVoteRequestHigherTermStep3 ==
    \E s \in Server :
    \E m \in BagToSet(messages) :
        /\ IsNodeEvent("SendVoteGranted", s)
        /\ HandleRequestVoteRequestHigherTermStep3(s, m)
        /\ l' = l + 1

\* --- TraceHandleRequestVoteResponse ---
\* Emitted by: NodeImpl.handleRequestVoteResponse
\* Event: "HandleRequestVoteResponse"
TraceHandleRequestVoteResponse ==
    \E s \in Server :
    \E m \in BagToSet(messages) :
        /\ IsNodeEvent("HandleRequestVoteResponse", s)
        /\ HandleRequestVoteResponse(s, m)
        /\ ValidateServerState(s)
        /\ l' = l + 1

\* --- TraceCrash ---
\* Emitted by: test harness before killing a node process
\* Event: "Crash"
TraceCrash ==
    \E s \in Server :
        /\ IsNodeEvent("Crash", s)
        /\ Crash(s)
        /\ l' = l + 1

\* --- TraceRestartFromPersisted ---
\* Emitted by: NodeImpl.init() after loading LocalRaftMetaStorage
\* Event: "RestartFromPersisted"
TraceRestartFromPersisted ==
    \E s \in Server :
        /\ IsNodeEvent("RestartFromPersisted", s)
        /\ RestartFromPersisted(s)
        /\ ValidateServerState(s)
        /\ ValidatePersistState(s)
        /\ l' = l + 1

\* --- TraceClientRequest ---
\* Emitted by: NodeImpl.apply() after leader appends to log
\* Event: "ClientRequest"
TraceClientRequest ==
    \E s \in Server :
    \E v \in Values :
        /\ IsNodeEvent("ClientRequest", s)
        /\ ClientRequest(s, v)
        /\ ValidateLogState(s)
        /\ l' = l + 1

\* --- TraceHandleAppendEntriesRequest ---
\* Emitted by: NodeImpl.handleAppendEntriesRequest after applying entries
\* Event: "HandleAppendEntriesRequest"
TraceHandleAppendEntriesRequest ==
    \E s \in Server :
    \E m \in BagToSet(messages) :
        /\ IsNodeEvent("HandleAppendEntriesRequest", s)
        /\ HandleAppendEntriesRequest(s, m)
        /\ ValidateServerState(s)
        /\ ValidateLogState(s)
        /\ l' = l + 1

\* --- TraceHandleInstallSnapshotRequest ---
\* Emitted by: NodeImpl.handleInstallSnapshotRequest after snapshot install
\* Event: "HandleInstallSnapshotRequest"
TraceHandleInstallSnapshotRequest ==
    \E s \in Server :
    \E m \in BagToSet(messages) :
        /\ IsNodeEvent("HandleInstallSnapshotRequest", s)
        /\ HandleInstallSnapshotRequest(s, m)
        /\ ValidateServerState(s)
        /\ snapshotIndex'[s] = logline.snapshotIndex
        \* Family 5: lastLeaderContact NOT updated (bug) — validate it stays unchanged
        /\ lastLeaderContact'[s] = lastLeaderContact[s]
        /\ l' = l + 1

\* --- TraceHandleInstallSnapshotResponseNormal ---
\* Emitted by: Replicator.onInstallSnapshotReturned
\* Event: "HandleInstallSnapshotResponseNormal"
TraceHandleInstallSnapshotResponseNormal ==
    \E s \in Server :
    \E m \in BagToSet(messages) :
        /\ IsNodeEvent("HandleInstallSnapshotResponseNormal", s)
        /\ HandleInstallSnapshotResponseNormal(s, m)
        /\ ValidateServerState(s)    \* Family 2: leader should stay leader (bug)
        /\ l' = l + 1

\* --- TraceHandleInstallSnapshotResponseWithHigherTerm ---
\* Emitted by: hypothetical fixed path (not in current implementation)
\* Event: "HandleInstallSnapshotResponseWithHigherTerm"
TraceHandleInstallSnapshotResponseWithHigherTerm ==
    \E s \in Server :
    \E m \in BagToSet(messages) :
        /\ IsNodeEvent("HandleInstallSnapshotResponseWithHigherTerm", s)
        /\ HandleInstallSnapshotResponseWithHigherTerm(s, m)
        /\ ValidateServerState(s)
        /\ l' = l + 1

\* --- TraceServeReadIndex ---
\* Emitted by: NodeImpl.readIndex / readLeader before adding to pendingNotifyStatus
\* Event: "ServeReadIndex"
TraceServeReadIndex ==
    \E s \in Server :
    \E idx \in 1..20 :
        /\ IsNodeEvent("ServeReadIndex", s)
        /\ logline.readIndex = idx
        /\ ServeReadIndex(s, idx)
        /\ ValidateReadState(s)
        /\ l' = l + 1

\* --- TraceApplyCommittedEntries ---
\* Emitted by: FSMCallerImpl.setLastApplied / notifyLastAppliedIndexUpdated
\* Event: "ApplyCommittedEntries"
TraceApplyCommittedEntries ==
    \E s \in Server :
        /\ IsNodeEvent("ApplyCommittedEntries", s)
        /\ ApplyCommittedEntries(s)
        /\ commitIndex'[s] = logline.commitIndex
        /\ lastApplied'[s] = logline.lastApplied
        /\ ValidateReadState(s)
        /\ l' = l + 1

\* --- TraceStepDown ---
\* Emitted by: NodeImpl.stepDown
\* Event: "StepDown"
TraceStepDown ==
    \E s \in Server :
        /\ IsNodeEvent("StepDown", s)
        /\ (IF ~crashed[s] /\ role[s] = Leader
            THEN StepDown(s)
            ELSE UNCHANGED vars)
        /\ ValidateServerState(s)
        \* Family 4 BUG: pendingReadIndex NOT cleared — validate it is still non-empty if it was
        /\ ValidateReadState(s)
        /\ l' = l + 1

\* ============================================================================
\* SILENT ACTIONS
\* ============================================================================

\* Silent leader appending no-op or client entries not captured in trace.
\* Fires when the leader's log is too short for the upcoming trace event.
SilentClientRequest ==
    /\ l <= Len(TraceLog)
    /\ "lastLogIndex" \in DOMAIN logline
    /\ \E s \in Server :
       /\ role[s] = Leader
       /\ (IF logline.event = "ClientRequest"
           THEN /\ ServerOf(logline.node) = s
                /\ LastLogIndex(s) + 1 < logline.lastLogIndex
           ELSE LastLogIndex(s) < logline.lastLogIndex)
       /\ \E v \in Values : ClientRequest(s, v)
    /\ UNCHANGED l

\* Silent AppendEntries: leader sends AE to the follower in the next traced HandleAE event.
\* Only fires when no AE from any leader to that follower currently exists in the bag.
SilentAppendEntries ==
    /\ l <= Len(TraceLog)
    /\ logline.event = "HandleAppendEntriesRequest"
    /\ \E s \in Server :
       /\ role[s] = Leader
       /\ LastLogIndex(s) >= logline.lastLogIndex  \* leader already has the entries; don't send stale heartbeat
       /\ ~\E m \in BagToSet(messages) :
             /\ m.mtype = AppendEntriesRequest
             /\ m.msrc = s
             /\ m.mdst = ServerOf(logline.node)
       /\ AppendEntries(s, ServerOf(logline.node))
    /\ UNCHANGED l

\* Silent HandleAppendEntriesResponse: leader processes a follower AE response.
\* Fires when the next trace event is ApplyCommittedEntries for the leader.
\* Needed to advance matchIndex so AdvanceCommitIndex can fire.
SilentHandleAppendEntriesResponse ==
    /\ l <= Len(TraceLog)
    /\ logline.event = "ApplyCommittedEntries"
    /\ \E s \in Server :
       /\ role[s] = Leader
       /\ ServerOf(logline.node) = s
       /\ \E m \in BagToSet(messages) :
          /\ m.mtype = AppendEntriesResponse
          /\ m.msubtype = MSubtypeNormal
          /\ m.mdst = s
          /\ m.msuccess = TRUE
          /\ m.mmatchIndex > matchIndex[s][m.msrc]
          \* always process the best (highest mmatch) response for this follower first
          /\ ~\E m2 \in BagToSet(messages) :
                 /\ m2.mtype = AppendEntriesResponse
                 /\ m2.msrc  = m.msrc
                 /\ m2.mdst  = s
                 /\ m2.msuccess = TRUE
                 /\ m2.mmatchIndex > m.mmatchIndex
          /\ HandleAppendEntriesResponse(s, m)
    /\ UNCHANGED l

\* Silent AdvanceCommitIndex: leader advances commit index between trace events.
\* Constrained to the leader identified by the current logline.
SilentAdvanceCommitIndex ==
    \E s \in Server :
        /\ l <= Len(TraceLog)
        /\ role[s] = Leader
        /\ ServerOf(logline.node) = s
        /\ AdvanceCommitIndex(s)
        /\ UNCHANGED l

\* Silent send heartbeat/entries: leader sends AE to a follower before follower applies.
\* Fires when the next trace event is ApplyCommittedEntries for a follower that needs
\* a commitIndex update from the leader.
SilentSendHeartbeat ==
    /\ l <= Len(TraceLog)
    /\ logline.event = "ApplyCommittedEntries"
    /\ \E s \in Server :
       /\ role[s] = Leader
       /\ ServerOf(logline.node) /= s
       /\ commitIndex[ServerOf(logline.node)] < logline.commitIndex
       /\ ~\E m \in BagToSet(messages) :
             /\ m.mtype = AppendEntriesRequest
             /\ m.msrc = s
             /\ m.mdst = ServerOf(logline.node)
       /\ AppendEntries(s, ServerOf(logline.node))
    /\ UNCHANGED l

\* Silent HandleAppendEntriesRequest: follower processes an AE (heartbeat or replication)
\* without a trace event. Fires before a follower's ApplyCommittedEntries to update
\* its commitIndex.
SilentHandleAppendEntriesRequest ==
    /\ l <= Len(TraceLog)
    /\ logline.event = "ApplyCommittedEntries"
    /\ \E s \in Server :
       /\ ServerOf(logline.node) = s
       /\ role[s] /= Leader
       /\ commitIndex[s] < logline.commitIndex
       /\ \E m \in BagToSet(messages) :
          /\ m.mtype = AppendEntriesRequest
          /\ m.mdst = s
          /\ HandleAppendEntriesRequest(s, m)
    /\ UNCHANGED l


\* ============================================================================
\* TRACE NEXT
\* ============================================================================

TraceNext ==
    \/ TraceElectionTimeout
    \/ TraceHandleRequestVoteRequestDeny
    \/ TraceHandleRequestVoteRequestGrantSameTerm
    \/ TraceHandleRequestVoteRequestHigherTermStep1
    \/ TraceHandleRequestVoteRequestHigherTermStep2
    \/ TraceHandleRequestVoteRequestHigherTermStep3
    \/ TraceHandleRequestVoteResponse
    \/ TraceCrash
    \/ TraceRestartFromPersisted
    \/ TraceClientRequest
    \/ TraceHandleAppendEntriesRequest
    \/ TraceHandleInstallSnapshotRequest
    \/ TraceHandleInstallSnapshotResponseNormal
    \/ TraceHandleInstallSnapshotResponseWithHigherTerm
    \/ TraceServeReadIndex
    \/ TraceApplyCommittedEntries
    \/ TraceStepDown
    \* Silent actions
    \/ SilentClientRequest
    \/ SilentAppendEntries
    \/ SilentHandleAppendEntriesResponse
    \/ SilentAdvanceCommitIndex
    \/ SilentSendHeartbeat
    \/ SilentHandleAppendEntriesRequest
    \* Stuttering when trace is fully consumed
    \/ (l > Len(TraceLog) /\ UNCHANGED <<vars, l>>)

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>>

\* ============================================================================
\* TRACE COMPLETION
\* ============================================================================

\* TraceMatched: temporal property that the entire trace was consumed.
\* Must be in Trace.cfg PROPERTIES. Without it TLC reports "no errors" even
\* when l never advances past event 1.
TraceMatched == <>(l > Len(TraceLog))

=============================================================================
