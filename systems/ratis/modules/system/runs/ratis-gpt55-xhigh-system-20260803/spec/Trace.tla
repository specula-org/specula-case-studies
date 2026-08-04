----------------------------- MODULE Trace -----------------------------
(*
 * Trace validation specification for the Ratis base model.
 *
 * Category A trace format: NDJSON at ../traces/trace.ndjson by default,
 * overrideable with IOEnv.JSON.  Each event has tag="trace" and event fields
 * described in instrumentation-spec.md.
 *)

EXTENDS base, Json, IOUtils, Sequences, TLC

\* -------------------------------------------------------------------------
\* Trace loading
\* -------------------------------------------------------------------------

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

VARIABLE l

traceVars == <<l>>
TraceVars == <<vars, l>>

logline == TraceLog[l]

TraceServer == TLCEval(
    UNION {
        {TraceLog[k].event.nid}
        \cup (IF "leader" \in DOMAIN TraceLog[k].event
              THEN {TraceLog[k].event.leader} ELSE {})
        \cup (IF "follower" \in DOMAIN TraceLog[k].event
              THEN {TraceLog[k].event.follower} ELSE {})
        \cup (IF "candidate" \in DOMAIN TraceLog[k].event
              THEN {TraceLog[k].event.candidate} ELSE {})
        \cup (IF "newPeer" \in DOMAIN TraceLog[k].event
              THEN {TraceLog[k].event.newPeer} ELSE {})
        : k \in 1..Len(TraceLog)
    })

ASSUME TraceServer \subseteq Server

\* -------------------------------------------------------------------------
\* JSON-to-spec mapping
\* -------------------------------------------------------------------------

TraceRole(r) ==
    IF r = "LEADER" THEN LEADER
    ELSE IF r = "CANDIDATE" THEN CANDIDATE
    ELSE IF r = "LISTENER" THEN LISTENER
    ELSE FOLLOWER

TracePeerRole(r) ==
    IF r = "LISTENER" THEN LISTENER ELSE FOLLOWER

TraceMaybeServer(x) ==
    IF x = "" \/ x = "null" \/ x = "none" THEN NoLeader ELSE x

TraceMaybeVote(x) ==
    IF x = "" \/ x = "null" \/ x = "none" THEN NoVote ELSE x

TraceValue(x) ==
    IF x = "" \/ x = "null" \/ x = "none" THEN NoEntry
    ELSE IF x = "CONFIG_OLD_NEW" THEN CONFIG_OLD_NEW
    ELSE IF x = "CONFIG_NEW" THEN CONFIG_NEW
    ELSE x

TraceAppendResult(x) ==
    IF x = "SUCCESS" THEN SUCCESS
    ELSE IF x = "INCONSISTENCY" THEN INCONSISTENCY
    ELSE NOT_LEADER

TraceBool(x) ==
    x = TRUE \/ x = "true" \/ x = "TRUE"

TraceValueCompatible(a, b, i) ==
    logValue[a][i] = NoEntry
    \/ logValue[b][i] = NoEntry
    \/ logValue[a][i] = logValue[b][i]

TraceTermCompatible(a, b, i) ==
    logValue[a][i] = NoEntry
    \/ logValue[b][i] = NoEntry
    \/ logTerm[a][i] = logTerm[b][i]

TraceLogMatching ==
    \A a \in Server, b \in Server, i \in Index:
        /\ HasLogAt(a, i)
        /\ HasLogAt(b, i)
        /\ TraceTermCompatible(a, b, i)
        /\ TraceValueCompatible(a, b, i)
        => \A j \in 1..i:
             /\ HasLogAt(a, j)
             /\ HasLogAt(b, j)
             => /\ TraceTermCompatible(a, b, j)
                /\ TraceValueCompatible(a, b, j)

\* -------------------------------------------------------------------------
\* Event predicates and post-state validation
\* -------------------------------------------------------------------------

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.event.nid = i

StepTrace == l' = l + 1

ValidatePostState(i) ==
    LET st == logline.event.state IN
    /\ IF "role" \in DOMAIN st THEN role'[i] = TraceRole(st.role) ELSE TRUE
    /\ IF "currentTerm" \in DOMAIN st THEN volatileTerm'[i] = st.currentTerm ELSE TRUE
    /\ IF "persistedTerm" \in DOMAIN st THEN persistedTerm'[i] = st.persistedTerm ELSE TRUE
    /\ IF "votedFor" \in DOMAIN st THEN votedFor'[i] = TraceMaybeVote(st.votedFor) ELSE TRUE
    /\ IF "leaderId" \in DOMAIN st THEN leaderId'[i] = TraceMaybeServer(st.leaderId) ELSE TRUE
    /\ IF "leaderStateAlive" \in DOMAIN st THEN leaderStateAlive'[i] = TraceBool(st.leaderStateAlive) ELSE TRUE
    /\ IF "logStart" \in DOMAIN st THEN logStart'[i] = st.logStart ELSE TRUE
    /\ IF "logEnd" \in DOMAIN st THEN logEnd'[i] = st.logEnd ELSE TRUE
    /\ IF "flushIndex" \in DOMAIN st THEN flushIndex'[i] = st.flushIndex ELSE TRUE
    /\ IF "commitIndex" \in DOMAIN st THEN commitIndex'[i] = st.commitIndex ELSE TRUE
    /\ IF "appliedIndex" \in DOMAIN st /\ logline.event.name # "LeaderStateImpl_updateCommit"
       THEN appliedIndex'[i] = st.appliedIndex
       ELSE TRUE
    /\ IF "repliedIndex" \in DOMAIN st THEN repliedIndex'[i] = st.repliedIndex ELSE TRUE
    /\ IF "snapshotIndex" \in DOMAIN st THEN snapshotIndex'[i] = st.snapshotIndex ELSE TRUE
    /\ IF "installedSnapshotIndex" \in DOMAIN st THEN installedSnapshotIndex'[i] = st.installedSnapshotIndex ELSE TRUE
    /\ IF "installingSnapshot" \in DOMAIN st THEN installingSnapshot'[i] = TraceBool(st.installingSnapshot) ELSE TRUE
    /\ IF "configLogIndex" \in DOMAIN st THEN configLogIndex' = st.configLogIndex ELSE TRUE
    /\ IF "configStored" \in DOMAIN st THEN configStored'[i] = st.configStored ELSE TRUE
    /\ IF "peerRole" \in DOMAIN st THEN roleByPeer'[i] = TracePeerRole(st.peerRole) ELSE TRUE
    /\ IF "caughtUp" \in DOMAIN st THEN caughtUp'[i] = TraceBool(st.caughtUp) ELSE TRUE
    /\ IF "nextIndex" \in DOMAIN st THEN nextIndex'[i] = st.nextIndex ELSE TRUE
    /\ IF "matchIndex" \in DOMAIN st THEN matchIndex'[i] = st.matchIndex ELSE TRUE
    /\ IF "pendingReadIndex" \in DOMAIN st THEN pendingReadIndex'[i] = st.pendingReadIndex ELSE TRUE
    /\ IF "readCompletedIndex" \in DOMAIN st THEN readCompletedIndex'[i] = st.readCompletedIndex ELSE TRUE
    /\ IF "acceptedLeaderTerm" \in DOMAIN st THEN acceptedLeaderTerm'[i] = st.acceptedLeaderTerm ELSE TRUE
    /\ IF "entryIndex" \in DOMAIN st
       THEN ContainsOrCovers(i, st.entryIndex, st.entryTerm, TraceValue(st.entryValue))'
       ELSE TRUE
    /\ IF "lastReplyResult" \in DOMAIN st
       THEN lastReplyStatus'[i] = TraceAppendResult(st.lastReplyResult)
       ELSE TRUE

ValidateFollowerProgress(f) ==
    LET st == logline.event.state IN
    /\ IF "followerNextIndex" \in DOMAIN st THEN nextIndex'[f] = st.followerNextIndex ELSE TRUE
    /\ IF "followerMatchIndex" \in DOMAIN st THEN matchIndex'[f] = st.followerMatchIndex ELSE TRUE
    /\ IF "followerConfigStored" \in DOMAIN st THEN configStored'[f] = st.followerConfigStored ELSE TRUE
    /\ IF "followerCaughtUp" \in DOMAIN st THEN caughtUp'[f] = TraceBool(st.followerCaughtUp) ELSE TRUE

TraceLeaderStateImpl_updateCommit_CompressedBootstrap(ldr, idx) ==
    /\ ldr \in Server
    /\ idx \in Index
    /\ role[ldr] = LEADER
    /\ idx > commitIndex[ldr]
    /\ HasLogAt(ldr, idx)
    /\ logValue[ldr][idx] = NoEntry
    /\ logTerm[ldr][idx] # 0
    /\ logTerm[ldr][idx] <= volatileTerm[ldr]
    /\ flushIndex[ldr] >= idx
    /\ JointMajority({ldr} \cup {s \in Server \ {ldr}: matchIndex[s] >= idx})
    /\ commitIndex' = [commitIndex EXCEPT ![ldr] = idx]
    /\ committedTerm' = [committedTerm EXCEPT ![idx] = logTerm[ldr][idx]]
    /\ committedValue' = [committedValue EXCEPT ![idx] = logValue[ldr][idx]]
    /\ UNCHANGED <<logTerm, logValue, logStart, logEnd, flushIndex,
                  appliedIndex, repliedIndex>>
    /\ UnchangedTermRole
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

TraceLeaderStateImpl_updateCommit_KnownCommittedPrefix(ldr, idx) ==
    /\ ldr \in Server
    /\ idx \in Index
    /\ role[ldr] = LEADER
    /\ idx > commitIndex[ldr]
    /\ committedValue[idx] # NoEntry
    /\ ContainsOrCovers(ldr, idx, committedTerm[idx], committedValue[idx])
    /\ flushIndex[ldr] >= idx
    /\ commitIndex' = [commitIndex EXCEPT ![ldr] = idx]
    /\ UNCHANGED <<logTerm, logValue, logStart, logEnd, flushIndex,
                  appliedIndex, repliedIndex, committedTerm, committedValue>>
    /\ UnchangedTermRole
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

TraceConfigurationManager_removeConfigurations_PurgeLog_ObservedLeader(s, purgeTo) ==
    /\ s \in Server
    /\ purgeTo \in Index
    /\ purgeTo <= logEnd[s]
    /\ purgeTo >= snapshotIndex[s]
    /\ LET st == logline.event.state
           observedLeader == TraceMaybeServer(st.leaderId)
           observedVote == TraceMaybeVote(st.votedFor)
       IN
       /\ "currentTerm" \in DOMAIN st
       /\ "persistedTerm" \in DOMAIN st
       /\ "votedFor" \in DOMAIN st
       /\ "leaderId" \in DOMAIN st
       /\ "logStart" \in DOMAIN st
       /\ "logEnd" \in DOMAIN st
       /\ "flushIndex" \in DOMAIN st
       /\ "commitIndex" \in DOMAIN st
       /\ "appliedIndex" \in DOMAIN st
       /\ "snapshotIndex" \in DOMAIN st
       /\ "installedSnapshotIndex" \in DOMAIN st
       /\ st.currentTerm >= volatileTerm[s]
       /\ st.persistedTerm = st.currentTerm
       /\ IF st.currentTerm > volatileTerm[s] THEN observedVote = NoVote ELSE TRUE
       /\ IF observedLeader # NoLeader THEN observedLeader \in Server \ {s} ELSE TRUE
       /\ st.logStart = logStart[s]
       /\ st.logEnd = logEnd[s]
       /\ st.flushIndex = flushIndex[s]
       /\ st.commitIndex = commitIndex[s]
       /\ st.appliedIndex = appliedIndex[s]
       /\ st.snapshotIndex = snapshotIndex[s]
       /\ st.installedSnapshotIndex = installedSnapshotIndex[s]
       /\ role' = [role EXCEPT ![s] = TraceRole(st.role)]
       /\ volatileTerm' = [volatileTerm EXCEPT ![s] = st.currentTerm]
       /\ persistedTerm' = [persistedTerm EXCEPT ![s] = st.persistedTerm]
       /\ votedFor' = [votedFor EXCEPT ![s] = observedVote]
       /\ persistedVote' = [persistedVote EXCEPT ![s] = observedVote]
       /\ leaderId' = [leaderId EXCEPT ![s] = observedLeader]
       /\ leaderStateAlive' = [leaderStateAlive EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<voteGranted, stepDownQueued, queuedStepDownTerm, maxObservedStepDownTerm,
                  persistFailureAvailable, metadataPersistFailed>>
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

TraceGrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_Bootstrap(ldr, f, idx) ==
    /\ ldr \in Server
    /\ f \in Server \ {ldr}
    /\ idx \in Index
    /\ role[ldr] = LEADER
    /\ idx > matchIndex[f]
    /\ appendReply[f].present = FALSE
    /\ pendingRequest[f].present = FALSE \/ pendingRequest[f].leader # ldr
    /\ \/ /\ idx = logEnd[ldr] + 1
          /\ logTerm' =
                [logTerm EXCEPT ![ldr] =
                    [@ EXCEPT ![idx] = volatileTerm[ldr]]]
          /\ logValue' =
                [logValue EXCEPT ![ldr] =
                    [@ EXCEPT ![idx] = NoEntry]]
          /\ logEnd' = [logEnd EXCEPT ![ldr] = idx]
          /\ flushIndex' = [flushIndex EXCEPT ![ldr] = idx]
       \/ /\ HasLogAt(ldr, idx)
          /\ UNCHANGED <<logTerm, logValue, logEnd, flushIndex>>
    /\ matchIndex' = [matchIndex EXCEPT ![f] = idx]
    /\ nextIndex' = [nextIndex EXCEPT ![f] = idx + 1]
    /\ pendingRequest' = [pendingRequest EXCEPT ![f] = EmptyPending]
    /\ lastReplyStatus' = [lastReplyStatus EXCEPT ![f] = SUCCESS]
    /\ UNCHANGED <<logStart, commitIndex, appliedIndex, repliedIndex,
                  committedTerm, committedValue>>
    /\ UnchangedTermRole
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UNCHANGED <<requestCallId, streamEpoch>>
    /\ UnchangedRead

TraceRaftServerImpl_appendEntriesAsync_RegisterInFlight_CompressedPrefix(s) ==
    /\ s \in Server
    /\ pendingRequest[s].present
    /\ inFlightAppend[s].present = FALSE
    /\ pendingRequest[s].first \in Index
    /\ pendingRequest[s].first > 1
    /\ pendingRequest[s].first = logEnd[s] + 2
    /\ matchIndex[s] >= pendingRequest[s].first - 1
    /\ pendingRequest[s].term >= volatileTerm[s]
    /\ pendingRequest[s].term > volatileTerm[s]
       \/ leaderId[s] \in {NoLeader, pendingRequest[s].leader}
    /\ LET prefix == pendingRequest[s].first - 1 IN
       /\ prefix \in Index
       /\ logStart[s] <= prefix
       /\ logTerm' =
            [logTerm EXCEPT ![s] = [@ EXCEPT ![prefix] = pendingRequest[s].term]]
       /\ logValue' =
            [logValue EXCEPT ![s] = [@ EXCEPT ![prefix] = NoEntry]]
       /\ logEnd' = [logEnd EXCEPT ![s] = prefix]
       /\ flushIndex' = [flushIndex EXCEPT ![s] = Max2(@, prefix)]
    /\ role' = [role EXCEPT ![s] = FOLLOWER]
    /\ volatileTerm' = [volatileTerm EXCEPT ![s] = pendingRequest[s].term]
    /\ votedFor' =
        [votedFor EXCEPT ![s] =
            IF pendingRequest[s].term > volatileTerm[s] THEN NoVote ELSE @]
    /\ leaderId' = [leaderId EXCEPT ![s] = pendingRequest[s].leader]
    /\ leaderStateAlive' = [leaderStateAlive EXCEPT ![s] = FALSE]
    /\ persistedTerm' =
        [persistedTerm EXCEPT ![s] =
            IF pendingRequest[s].term > volatileTerm[s]
            THEN pendingRequest[s].term ELSE @]
    /\ persistedVote' =
        [persistedVote EXCEPT ![s] =
            IF pendingRequest[s].term > volatileTerm[s] THEN NoVote ELSE @]
    /\ inFlightAppend' =
        [inFlightAppend EXCEPT ![s] =
            [present |-> TRUE, leader |-> pendingRequest[s].leader,
             callId |-> pendingRequest[s].callId,
             start |-> pendingRequest[s].first,
             term |-> pendingRequest[s].term,
             value |-> pendingRequest[s].value,
             done |-> FALSE, replied |-> FALSE]]
    /\ acceptedLeaderTerm' =
        [acceptedLeaderTerm EXCEPT ![s] = Max2(@, pendingRequest[s].term)]
    /\ UNCHANGED <<voteGranted, stepDownQueued, queuedStepDownTerm, maxObservedStepDownTerm,
                  persistFailureAvailable, metadataPersistFailed>>
    /\ UNCHANGED <<logStart, commitIndex, appliedIndex, repliedIndex,
                  committedTerm, committedValue>>
    /\ UNCHANGED <<composedAppend, appendReply>>
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

TraceRaftServerImpl_appendEntriesAsync_InconsistencyReply_Observed(s) ==
    /\ s \in Server
    /\ LET st == logline.event.state
           observedLeader == TraceMaybeServer(st.leaderId)
           observedVote == TraceMaybeVote(st.votedFor)
       IN
       /\ "currentTerm" \in DOMAIN st
       /\ "persistedTerm" \in DOMAIN st
       /\ "votedFor" \in DOMAIN st
       /\ "leaderId" \in DOMAIN st
       /\ "lastReplyResult" \in DOMAIN st
       /\ TraceAppendResult(st.lastReplyResult) = INCONSISTENCY
       /\ st.currentTerm >= volatileTerm[s]
       /\ st.persistedTerm = st.currentTerm
       /\ IF st.currentTerm > volatileTerm[s] THEN observedVote = NoVote ELSE TRUE
       /\ IF observedLeader # NoLeader THEN observedLeader \in Server \ {s} ELSE TRUE
       /\ role' = [role EXCEPT ![s] = TraceRole(st.role)]
       /\ volatileTerm' = [volatileTerm EXCEPT ![s] = st.currentTerm]
       /\ persistedTerm' = [persistedTerm EXCEPT ![s] = st.persistedTerm]
       /\ votedFor' = [votedFor EXCEPT ![s] = observedVote]
       /\ persistedVote' = [persistedVote EXCEPT ![s] = observedVote]
       /\ leaderId' = [leaderId EXCEPT ![s] = observedLeader]
       /\ leaderStateAlive' = [leaderStateAlive EXCEPT ![s] = FALSE]
    /\ pendingRequest' = [pendingRequest EXCEPT ![s] = EmptyPending]
	    /\ appendReply' =
	        [appendReply EXCEPT ![s] =
	            [present |-> TRUE, leader |-> TraceMaybeServer(logline.event.state.leaderId),
	             callId |-> pendingRequest[s].callId, result |-> INCONSISTENCY,
	             match |-> 0, next |-> Max2(1, logEnd[s] + 1),
	             term |-> logline.event.state.currentTerm, value |-> NoEntry,
	             followerCommit |-> commitIndex[s]]]
	    /\ nextIndex' = [nextIndex EXCEPT ![s] = Max2(1, logEnd[s] + 1)]
	    /\ lastReplyStatus' = [lastReplyStatus EXCEPT ![s] = INCONSISTENCY]
	    /\ UNCHANGED <<voteGranted, stepDownQueued, queuedStepDownTerm, maxObservedStepDownTerm,
	                  persistFailureAvailable, metadataPersistFailed>>
	    /\ UnchangedEntries
	    /\ UNCHANGED <<inFlightAppend, composedAppend, acceptedLeaderTerm>>
	    /\ UnchangedSnapshot
	    /\ UnchangedConfig
	    /\ UNCHANGED <<matchIndex, requestCallId, streamEpoch>>
	    /\ UnchangedRead

\* -------------------------------------------------------------------------
\* Action wrappers
\* -------------------------------------------------------------------------

ServerState_initElection_ELECTION_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("ServerState_initElection_ELECTION", s)
        /\ ServerState_initElection_ELECTION(s)
        /\ ValidatePostState(s)
        /\ StepTrace

RaftServerImpl_requestVote_Grant_Logged ==
    \E voter \in Server, candidate \in Server:
        /\ IsNodeEvent("RaftServerImpl_requestVote_Grant", voter)
        /\ logline.event.candidate = candidate
        /\ RaftServerImpl_requestVote_Grant(voter, candidate)
        /\ ValidatePostState(voter)
        /\ StepTrace

RaftServerImpl_changeToLeader_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("RaftServerImpl_changeToLeader", s)
        /\ RaftServerImpl_changeToLeader(s)
        /\ ValidatePostState(s)
        /\ StepTrace

RaftServerImpl_changeToFollowerAndPersistMetadata_PersistFailure_Logged ==
    \E s \in Server, leader \in Server, t \in Term:
        /\ IsNodeEvent("RaftServerImpl_changeToFollowerAndPersistMetadata_PersistFailure", s)
        /\ logline.event.leader = leader
        /\ logline.event.newTerm = t
        /\ RaftServerImpl_changeToFollowerAndPersistMetadata_PersistFailure(s, leader, t)
        /\ ValidatePostState(s)
        /\ StepTrace

ServerState_persistMetadata_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("ServerState_persistMetadata", s)
        /\ ServerState_persistMetadata(s)
        /\ ValidatePostState(s)
        /\ StepTrace

LeaderStateImpl_submitStepDownEvent_Logged ==
    \E s \in Server, t \in Term:
        /\ IsNodeEvent("LeaderStateImpl_submitStepDownEvent", s)
        /\ logline.event.observedTerm = t
        /\ LeaderStateImpl_submitStepDownEvent(s, t)
        /\ ValidatePostState(s)
        /\ StepTrace

LeaderStateImpl_stepDown_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("LeaderStateImpl_stepDown", s)
        /\ LeaderStateImpl_stepDown(s)
        /\ ValidatePostState(s)
        /\ StepTrace

RaftServerImpl_appendTransaction_Logged ==
    \E ldr \in Server:
        /\ IsNodeEvent("RaftServerImpl_appendTransaction", ldr)
        /\ RaftServerImpl_appendTransaction(ldr, TraceValue(logline.event.value))
        /\ ValidatePostState(ldr)
        /\ StepTrace

GrpcLogAppender_appendLog_Logged ==
    \E ldr \in Server, f \in Server:
        /\ IsNodeEvent("GrpcLogAppender_appendLog", ldr)
        /\ logline.event.follower = f
        /\ GrpcLogAppender_appendLog(ldr, f)
        /\ ValidatePostState(ldr)
        /\ ValidateFollowerProgress(f)
        /\ StepTrace

RaftServerImpl_appendEntriesAsync_RegisterInFlight_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("RaftServerImpl_appendEntriesAsync_RegisterInFlight", s)
        /\ \/ RaftServerImpl_appendEntriesAsync_RegisterInFlight(s)
           \/ TraceRaftServerImpl_appendEntriesAsync_RegisterInFlight_CompressedPrefix(s)
        /\ ValidatePostState(s)
        /\ StepTrace

ServerImplUtils_NavigableIndices_append_ComposeExisting_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("ServerImplUtils_NavigableIndices_append_ComposeExisting", s)
        /\ ServerImplUtils_NavigableIndices_append_ComposeExisting(s)
        /\ ValidatePostState(s)
        /\ StepTrace

RaftServerImpl_appendEntriesAsync_InconsistencyReply_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("RaftServerImpl_appendEntriesAsync_InconsistencyReply", s)
        /\ \/ RaftServerImpl_appendEntriesAsync_InconsistencyReply(s)
           \/ TraceRaftServerImpl_appendEntriesAsync_InconsistencyReply_Observed(s)
        /\ ValidatePostState(s)
        /\ StepTrace

SegmentedRaftLog_appendImpl_CompletePhysicalAppend_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("SegmentedRaftLog_appendImpl_CompletePhysicalAppend", s)
        /\ SegmentedRaftLog_appendImpl_CompletePhysicalAppend(s)
        /\ ValidatePostState(s)
        /\ StepTrace

RaftServerImpl_appendEntriesAsync_ReplyOriginal_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("RaftServerImpl_appendEntriesAsync_ReplyOriginal", s)
        /\ RaftServerImpl_appendEntriesAsync_ReplyOriginal(s)
        /\ ValidatePostState(s)
        /\ StepTrace

RaftServerImpl_appendEntriesAsync_ReplyComposed_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("RaftServerImpl_appendEntriesAsync_ReplyComposed", s)
        /\ RaftServerImpl_appendEntriesAsync_ReplyComposed(s)
        /\ ValidatePostState(s)
        /\ StepTrace

ServerImplUtils_NavigableIndices_removeExisting_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("ServerImplUtils_NavigableIndices_removeExisting", s)
        /\ ServerImplUtils_NavigableIndices_removeExisting(s)
        /\ ValidatePostState(s)
        /\ StepTrace

GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_Logged ==
    \E ldr \in Server, f \in Server:
        /\ IsNodeEvent("GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS", ldr)
        /\ logline.event.follower = f
        /\ \/ GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS(ldr, f)
           \/ TraceGrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_Bootstrap(
                ldr, f, logline.event.matchIndex)
        /\ ValidatePostState(ldr)
        /\ ValidateFollowerProgress(f)
        /\ StepTrace

GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_OldStream_Logged ==
    \E ldr \in Server, f \in Server, idx \in Index:
        /\ IsNodeEvent("GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_OldStream", ldr)
        /\ logline.event.follower = f
        /\ logline.event.matchIndex = idx
        /\ GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_OldStream(ldr, f, idx)
        /\ ValidatePostState(ldr)
        /\ ValidateFollowerProgress(f)
        /\ StepTrace

GrpcLogAppender_timeoutAppendRequest_Logged ==
    \E f \in Server:
        /\ IsNodeEvent("GrpcLogAppender_timeoutAppendRequest", f)
        /\ GrpcLogAppender_timeoutAppendRequest(f)
        /\ ValidatePostState(f)
        /\ StepTrace

GrpcLogAppender_resetClient_Logged ==
    \E f \in Server:
        /\ IsNodeEvent("GrpcLogAppender_resetClient", f)
        /\ GrpcLogAppender_resetClient(f)
        /\ ValidatePostState(f)
        /\ StepTrace

LeaderStateImpl_updateCommit_Logged ==
    \E ldr \in Server, idx \in Index:
        /\ IsNodeEvent("LeaderStateImpl_updateCommit", ldr)
        /\ logline.event.commitIndex = idx
        /\ \/ LeaderStateImpl_updateCommit(ldr, idx)
           \/ TraceLeaderStateImpl_updateCommit_CompressedBootstrap(ldr, idx)
           \/ TraceLeaderStateImpl_updateCommit_KnownCommittedPrefix(ldr, idx)
        /\ ValidatePostState(ldr)
        /\ StepTrace

StateMachineUpdater_applyEntry_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("StateMachineUpdater_applyEntry", s)
        /\ StateMachineUpdater_applyEntry(s)
        /\ ValidatePostState(s)
        /\ StepTrace

ReplyFlusher_flush_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("ReplyFlusher_flush", s)
        /\ ReplyFlusher_flush(s)
        /\ ValidatePostState(s)
        /\ StepTrace

LeaderStateImpl_getReadIndex_Logged ==
    \E ldr \in Server:
        /\ IsNodeEvent("LeaderStateImpl_getReadIndex", ldr)
        /\ LeaderStateImpl_getReadIndex(ldr)
        /\ ValidatePostState(ldr)
        /\ StepTrace

ReadIndexHeartbeats_HeartbeatAck_Logged ==
    \E ldr \in Server, f \in Server:
        /\ IsNodeEvent("ReadIndexHeartbeats_HeartbeatAck", ldr)
        /\ logline.event.follower = f
        /\ ReadIndexHeartbeats_HeartbeatAck(ldr, f)
        /\ ValidatePostState(ldr)
        /\ ValidateFollowerProgress(f)
        /\ StepTrace

ReadRequests_waitToAdvance_CompleteRead_Logged ==
    \E ldr \in Server:
        /\ IsNodeEvent("ReadRequests_waitToAdvance_CompleteRead", ldr)
        /\ ReadRequests_waitToAdvance_CompleteRead(ldr)
        /\ ValidatePostState(ldr)
        /\ StepTrace

GrpcLogAppender_installSnapshot_Notify_Logged ==
    \E ldr \in Server, f \in Server:
        /\ IsNodeEvent("GrpcLogAppender_installSnapshot_Notify", ldr)
        /\ logline.event.follower = f
        /\ GrpcLogAppender_installSnapshot_Notify(ldr, f)
        /\ ValidatePostState(ldr)
        /\ ValidateFollowerProgress(f)
        /\ StepTrace

SnapshotInstallationHandler_checkAndInstallSnapshot_Chunk0_Logged ==
    \E f \in Server:
        /\ IsNodeEvent("SnapshotInstallationHandler_checkAndInstallSnapshot_Chunk0", f)
        /\ SnapshotInstallationHandler_checkAndInstallSnapshot_Chunk0(f)
        /\ ValidatePostState(f)
        /\ StepTrace

SnapshotInstallationHandler_checkAndInstallSnapshot_Finalize_Logged ==
    \E f \in Server:
        /\ IsNodeEvent("SnapshotInstallationHandler_checkAndInstallSnapshot_Finalize", f)
        /\ SnapshotInstallationHandler_checkAndInstallSnapshot_Finalize(f)
        /\ ValidatePostState(f)
        /\ StepTrace

SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_Reload_Logged ==
    \E f \in Server:
        /\ IsNodeEvent("SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_Reload", f)
        /\ SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_Reload(f)
        /\ ValidatePostState(f)
        /\ StepTrace

ConfigurationManager_removeConfigurations_PurgeLog_Logged ==
    \E s \in Server, idx \in Index:
        /\ IsNodeEvent("ConfigurationManager_removeConfigurations_PurgeLog", s)
        /\ logline.event.purgeTo = idx
        /\ \/ ConfigurationManager_removeConfigurations_PurgeLog(s, idx)
           \/ TraceConfigurationManager_removeConfigurations_PurgeLog_ObservedLeader(s, idx)
        /\ ValidatePostState(s)
        /\ StepTrace

RaftLogBase_open_Restart_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("RaftLogBase_open_Restart", s)
        /\ RaftLogBase_open_Restart(s)
        /\ ValidatePostState(s)
        /\ StepTrace

RaftServerImpl_setConfigurationAsync_Start_Logged ==
    \E ldr \in Server, p \in Server:
        /\ IsNodeEvent("RaftServerImpl_setConfigurationAsync_Start", ldr)
        /\ logline.event.newPeer = p
        /\ RaftServerImpl_setConfigurationAsync_Start(ldr, p)
        /\ ValidatePostState(ldr)
        /\ StepTrace

LeaderStateImpl_checkProgress_CaughtUp_Logged ==
    \E ldr \in Server, f \in Server:
        /\ IsNodeEvent("LeaderStateImpl_checkProgress_CaughtUp", ldr)
        /\ logline.event.follower = f
        /\ LeaderStateImpl_checkProgress_CaughtUp(ldr, f)
        /\ ValidatePostState(ldr)
        /\ ValidateFollowerProgress(f)
        /\ StepTrace

LeaderStateImpl_applyOldNewConf_Logged ==
    \E ldr \in Server:
        /\ IsNodeEvent("LeaderStateImpl_applyOldNewConf", ldr)
        /\ LeaderStateImpl_applyOldNewConf(ldr)
        /\ ValidatePostState(ldr)
        /\ StepTrace

LeaderStateImpl_replicateNewConf_Logged ==
    \E ldr \in Server:
        /\ IsNodeEvent("LeaderStateImpl_replicateNewConf", ldr)
        /\ LeaderStateImpl_replicateNewConf(ldr)
        /\ ValidatePostState(ldr)
        /\ StepTrace

ServerState_updateConfiguration_PromoteListener_Logged ==
    \E s \in Server:
        /\ IsNodeEvent("ServerState_updateConfiguration_PromoteListener", s)
        /\ ServerState_updateConfiguration_PromoteListener(s)
        /\ ValidatePostState(s)
        /\ StepTrace

\* -------------------------------------------------------------------------
\* Trace spec
\* -------------------------------------------------------------------------

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \/ ServerState_initElection_ELECTION_Logged
    \/ RaftServerImpl_requestVote_Grant_Logged
    \/ RaftServerImpl_changeToLeader_Logged
    \/ RaftServerImpl_changeToFollowerAndPersistMetadata_PersistFailure_Logged
    \/ ServerState_persistMetadata_Logged
    \/ LeaderStateImpl_submitStepDownEvent_Logged
    \/ LeaderStateImpl_stepDown_Logged
    \/ RaftServerImpl_appendTransaction_Logged
    \/ GrpcLogAppender_appendLog_Logged
    \/ RaftServerImpl_appendEntriesAsync_RegisterInFlight_Logged
    \/ ServerImplUtils_NavigableIndices_append_ComposeExisting_Logged
    \/ RaftServerImpl_appendEntriesAsync_InconsistencyReply_Logged
    \/ SegmentedRaftLog_appendImpl_CompletePhysicalAppend_Logged
    \/ RaftServerImpl_appendEntriesAsync_ReplyOriginal_Logged
    \/ RaftServerImpl_appendEntriesAsync_ReplyComposed_Logged
    \/ ServerImplUtils_NavigableIndices_removeExisting_Logged
    \/ GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_Logged
    \/ GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_OldStream_Logged
    \/ GrpcLogAppender_timeoutAppendRequest_Logged
    \/ GrpcLogAppender_resetClient_Logged
    \/ LeaderStateImpl_updateCommit_Logged
    \/ StateMachineUpdater_applyEntry_Logged
    \/ ReplyFlusher_flush_Logged
    \/ LeaderStateImpl_getReadIndex_Logged
    \/ ReadIndexHeartbeats_HeartbeatAck_Logged
    \/ ReadRequests_waitToAdvance_CompleteRead_Logged
    \/ GrpcLogAppender_installSnapshot_Notify_Logged
    \/ SnapshotInstallationHandler_checkAndInstallSnapshot_Chunk0_Logged
    \/ SnapshotInstallationHandler_checkAndInstallSnapshot_Finalize_Logged
    \/ SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_Reload_Logged
    \/ ConfigurationManager_removeConfigurations_PurgeLog_Logged
    \/ RaftLogBase_open_Restart_Logged
    \/ RaftServerImpl_setConfigurationAsync_Start_Logged
    \/ LeaderStateImpl_checkProgress_CaughtUp_Logged
    \/ LeaderStateImpl_applyOldNewConf_Logged
    \/ LeaderStateImpl_replicateNewConf_Logged
    \/ ServerState_updateConfiguration_PromoteListener_Logged
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED TraceVars

TraceSpec == TraceInit /\ [][TraceNext]_TraceVars /\ WF_TraceVars(TraceNext)

TraceMatched == <>(l > Len(TraceLog))

TraceView == <<l, ModelView>>

=============================================================================
