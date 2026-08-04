---------------------------- MODULE Trace ----------------------------
(*
 * Trace validation spec for Apache Ratis ratis-server.
 *
 * Category A standard trace replay: one NDJSON file, one cursor l.
 * Every event wrapper calls the corresponding base.tla action and validates
 * captured post-state fields.
 *)

EXTENDS base, Json, IOUtils, Sequences, TLC

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
traceAllVars == <<vars, l>>

logline == TraceLog[l]

SeqToSet(seq) == {seq[i] : i \in 1..Len(seq)}

TracePeer(v) ==
    IF v = "" \/ v = "null" \/ v = "None" THEN None ELSE v

TraceRole(v) ==
    IF v = "LEADER" \/ v = "Leader" THEN Leader
    ELSE IF v = "CANDIDATE" \/ v = "Candidate" THEN Candidate
    ELSE IF v = "LISTENER" \/ v = "Listener" THEN Listener
    ELSE Follower

HasEventField(name) ==
    name \in DOMAIN logline.event

HasMsgField(name) ==
    /\ "msg" \in DOMAIN logline.event
    /\ name \in DOMAIN logline.event.msg

HasStateField(name) ==
    /\ "state" \in DOMAIN logline.event
    /\ name \in DOMAIN logline.event.state

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.event.nid = i

EventIndex ==
    IF HasEventField("index") THEN logline.event.index
    ELSE IF HasMsgField("index") THEN logline.event.msg.index
    ELSE -1

EventPeer ==
    IF HasMsgField("peer") THEN logline.event.msg.peer
    ELSE IF HasMsgField("source") THEN logline.event.msg.source
    ELSE logline.event.nid

ValidatePostState(i) ==
    \* Common fields captured by instrumentation-spec.md.
    /\ IF HasStateField("term")
       THEN currentTerm'[i] = logline.event.state.term
       ELSE TRUE
    /\ IF HasStateField("role")
       THEN role'[i] = TraceRole(logline.event.state.role)
       ELSE TRUE
    /\ IF HasStateField("votedFor")
       THEN votedFor'[i] = TracePeer(logline.event.state.votedFor)
       ELSE TRUE
    /\ IF HasStateField("leaderId")
       THEN leaderId'[i] = TracePeer(logline.event.state.leaderId)
       ELSE TRUE
    /\ IF HasStateField("commitIndex")
       THEN commitIndex'[i] = logline.event.state.commitIndex
       ELSE TRUE
    /\ IF HasStateField("metadataCommitIndex")
       THEN metadataCommitIndex'[i] = logline.event.state.metadataCommitIndex
       ELSE TRUE
    /\ IF HasStateField("flushIndex")
       THEN flushIndex'[i] = logline.event.state.flushIndex
       ELSE TRUE
    /\ IF HasStateField("lastWrittenIndex")
       THEN lastWrittenIndex'[i] = logline.event.state.lastWrittenIndex
       ELSE TRUE
    /\ IF HasStateField("durableLog")
       THEN diskLog'[i] = SeqToSet(logline.event.state.durableLog)
       ELSE TRUE
    /\ IF HasStateField("snapshotIndex")
       THEN snapshotIndex'[i] = logline.event.state.snapshotIndex
       ELSE TRUE
    /\ IF HasStateField("snapshotInProgressIndex")
       THEN snapshotInProgressIndex'[i] = logline.event.state.snapshotInProgressIndex
       ELSE TRUE
    /\ IF HasStateField("currentConf")
       THEN currentConf'[i] = SeqToSet(logline.event.state.currentConf)
       ELSE TRUE
    /\ IF HasStateField("durableConf")
       THEN durableConf'[i] = SeqToSet(logline.event.state.durableConf)
       ELSE TRUE
    /\ IF HasStateField("leaseEnabled")
       THEN leaseEnabled'[i] = logline.event.state.leaseEnabled
       ELSE TRUE
    /\ IF HasStateField("leaseFresh")
       THEN leaseFresh'[i] = logline.event.state.leaseFresh
       ELSE TRUE
    /\ IF HasStateField("readResult")
       THEN readResult'[i] = logline.event.state.readResult
       ELSE TRUE

StepTrace ==
    /\ l' = l + 1
    /\ PrintT(<<"Progress %:", (l * 100) \div Len(TraceLog)>>)

\* --------------------------------------------------------------------------
\* Silent actions. Each one is constrained by the next trace event.
\* --------------------------------------------------------------------------

SilentSubmitRequestVote ==
    /\ l <= Len(TraceLog)
    /\ (IsEvent("RaftServerImpl.requestVote.grant") \/ IsEvent("RaftServerImpl.requestVote.reject"))
    /\ HasMsgField("source")
    /\ \E c \in Server, v \in Server :
        /\ c = logline.event.msg.source
        /\ v = logline.event.nid
        /\ LeaderElection_submitRequestVote(c, v)
        /\ UNCHANGED traceVars

SilentSendAppendEntries ==
    /\ l <= Len(TraceLog)
    /\ (IsEvent("RaftServerImpl.appendEntries.success")
        \/ IsEvent("RaftServerImpl.appendEntries.rejectSnapshot")
        \/ IsEvent("RaftServerImpl.appendEntries.acceptDuringSnapshotFault"))
    /\ HasMsgField("source")
    /\ \E leader \in Server, follower \in Server :
        /\ leader = logline.event.msg.source
        /\ follower = logline.event.nid
        /\ LeaderStateImpl_sendAppendEntries(leader, follower, EventIndex)
        /\ UNCHANGED traceVars

\* --------------------------------------------------------------------------
\* Action wrappers.
\* --------------------------------------------------------------------------

ServerStateInitElectionIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ServerState.initElection.ELECTION", i)
        /\ ServerState_initElection_ELECTION(i)
        /\ ValidatePostState(i)
        /\ StepTrace

SetVoteReplyLastEntryKindIfLogged ==
    \E i \in Server, kind \in VoteKinds :
        /\ IsNodeEvent("ServerProtoUtils.setVoteReplyLastEntryKind", i)
        /\ HasEventField("kind")
        /\ kind = logline.event.kind
        /\ ServerProtoUtils_setVoteReplyLastEntryKind(i, kind)
        /\ ValidatePostState(i)
        /\ StepTrace

RequestVoteGrantIfLogged ==
    \E i \in Server, m \in messages :
        /\ IsNodeEvent("RaftServerImpl.requestVote.grant", i)
        /\ m.mtype = "RequestVote"
        /\ m.to = i
        /\ RaftServerImpl_requestVote_Grant(i, m)
        /\ ValidatePostState(i)
        /\ StepTrace

RequestVoteRejectIfLogged ==
    \E i \in Server, m \in messages :
        /\ IsNodeEvent("RaftServerImpl.requestVote.reject", i)
        /\ m.mtype = "RequestVote"
        /\ m.to = i
        /\ RaftServerImpl_requestVote_Reject(i, m)
        /\ ValidatePostState(i)
        /\ StepTrace

LeaderElectionWaitForResultsIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("LeaderElection.waitForResults.pass", i)
        /\ LeaderElection_waitForResults(i)
        /\ ValidatePostState(i)
        /\ StepTrace

TraceEntryKind ==
    IF HasEventField("kind") THEN logline.event.kind ELSE "normal"

AppendEntryCacheAndQueueIfLogged ==
    \E i \in Server, kind \in {"normal", "config"}, p \in Server :
        /\ IsNodeEvent("RaftLogBase.appendEntry.cacheAndQueue", i)
        /\ kind = TraceEntryKind
        /\ p = EventPeer
        /\ RaftLogBase_appendEntry_CacheAndQueue(i, EventIndex, kind, p)
        /\ ValidatePostState(i)
        /\ StepTrace

WriteLogExecuteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SegmentedRaftLogWorker.WriteLog.execute", i)
        /\ SegmentedRaftLogWorker_WriteLog_execute(i, EventIndex)
        /\ ValidatePostState(i)
        /\ StepTrace

FlushStartIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SegmentedRaftLogWorker.flushIfNecessary.start", i)
        /\ SegmentedRaftLogWorker_flushIfNecessary_Start(i)
        /\ ValidatePostState(i)
        /\ StepTrace

FlushFailIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SegmentedRaftLogWorker.asyncFlushOutStream.fail", i)
        /\ SegmentedRaftLogWorker_asyncFlushOutStream_Fail(i)
        /\ ValidatePostState(i)
        /\ StepTrace

FlushCompleteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SegmentedRaftLogWorker.asyncFlushOutStream.complete", i)
        /\ SegmentedRaftLogWorker_asyncFlushOutStream_Complete(i)
        /\ ValidatePostState(i)
        /\ StepTrace

FlushLateOrFailedIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SegmentedRaftLogWorker.asyncFlushOutStream.completeLateOrFailed", i)
        /\ SegmentedRaftLogWorker_asyncFlushOutStream_CompleteLateOrFailed(i)
        /\ ValidatePostState(i)
        /\ StepTrace

UpdateCommitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("LeaderStateImpl.updateCommit", i)
        /\ LeaderStateImpl_updateCommit(i, EventIndex)
        /\ ValidatePostState(i)
        /\ StepTrace

AppendMetadataIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("RaftLogBase.appendMetadata", i)
        /\ RaftLogBase_appendMetadata(i)
        /\ ValidatePostState(i)
        /\ StepTrace

CrashAndRecoverIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CrashAndRecover", i)
        /\ CrashAndRecover(i)
        /\ ValidatePostState(i)
        /\ StepTrace

FormatEmptyStorageIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("RaftStorageImpl.formatEmptyStorage", i)
        /\ RaftStorageImpl_formatEmptyStorage(i)
        /\ ValidatePostState(i)
        /\ StepTrace

AppendEntriesRejectSnapshotIfLogged ==
    \E i \in Server, m \in messages :
        /\ IsNodeEvent("RaftServerImpl.appendEntries.rejectSnapshot", i)
        /\ m.mtype = "AppendEntries"
        /\ m.to = i
        /\ RaftServerImpl_appendEntriesAsync_RejectSnapshot(i, m)
        /\ ValidatePostState(i)
        /\ StepTrace

AppendEntriesSuccessIfLogged ==
    \E i \in Server, m \in messages :
        /\ IsNodeEvent("RaftServerImpl.appendEntries.success", i)
        /\ m.mtype = "AppendEntries"
        /\ m.to = i
        /\ RaftServerImpl_appendEntriesAsync_Success(i, m)
        /\ ValidatePostState(i)
        /\ StepTrace

AppendEntriesAcceptDuringSnapshotFaultIfLogged ==
    \E i \in Server, m \in messages :
        /\ IsNodeEvent("RaftServerImpl.appendEntries.acceptDuringSnapshotFault", i)
        /\ m.mtype = "AppendEntries"
        /\ m.to = i
        /\ RaftServerImpl_appendEntriesAsync_AcceptDuringSnapshotFault(i, m)
        /\ ValidatePostState(i)
        /\ StepTrace

SnapshotNotifyIfLogged ==
    \E f \in Server, leader \in Server :
        /\ IsNodeEvent("SnapshotInstallationHandler.notifyStateMachineToInstallSnapshot", f)
        /\ HasMsgField("source")
        /\ leader = logline.event.msg.source
        /\ SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot(f, leader, EventIndex)
        /\ ValidatePostState(f)
        /\ StepTrace

SnapshotChunkAppendIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SnapshotInstallationHandler.checkAndInstallSnapshot.appendChunk", i)
        /\ SnapshotInstallationHandler_checkAndInstallSnapshot_AppendChunk(i, EventIndex)
        /\ ValidatePostState(i)
        /\ StepTrace

SnapshotFinalChunkPublishIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SnapshotInstallationHandler.checkAndInstallSnapshot.finalChunkPublish", i)
        /\ SnapshotInstallationHandler_checkAndInstallSnapshot_FinalChunkPublish(i)
        /\ ValidatePostState(i)
        /\ StepTrace

SnapshotNotificationCompleteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("SnapshotInstallationHandler.notifyStateMachine.complete", i)
        /\ SnapshotInstallationHandler_notifyStateMachine_Complete(i)
        /\ ValidatePostState(i)
        /\ StepTrace

SendReadIndexIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("RaftServerImpl.sendReadIndexAsync", i)
        /\ RaftServerImpl_sendReadIndexAsync(i, EventIndex)
        /\ ValidatePostState(i)
        /\ StepTrace

LeaseFastPathIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("LeaderStateImpl.getReadIndex.leaseFastPath", i)
        /\ LeaderStateImpl_getReadIndex_LeaseFastPath(i, EventIndex)
        /\ ValidatePostState(i)
        /\ StepTrace

EnableLeaseIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("LeaderLease.enableForTarget", i)
        /\ LeaderLease_enableForTarget(i)
        /\ ValidatePostState(i)
        /\ StepTrace

ReceiveAppendEntriesReplyTimestampIfLogged ==
    \E i \in Server, f \in Server, result \in {"SUCCESS", "NOT_LEADER", "HIGHER_TERM", "INCONSISTENCY"} :
        /\ IsNodeEvent("LogAppenderDefault.receiveAppendEntriesReply.timestamp", i)
        /\ HasMsgField("peer")
        /\ HasEventField("result")
        /\ f = logline.event.msg.peer
        /\ result = logline.event.result
        /\ LogAppenderDefault_receiveAppendEntriesReply_Timestamp(i, f, result)
        /\ ValidatePostState(i)
        /\ StepTrace

LeaderLeaseExtendIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("LeaderLease.extend", i)
        /\ LeaderLease_extend(i)
        /\ ValidatePostState(i)
        /\ StepTrace

HandleReplyNotLeaderIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("LogAppenderDefault.handleReply.notLeaderOrHigherTerm", i)
        /\ LogAppenderDefault_handleReply_NotLeaderOrHigherTerm(i)
        /\ ValidatePostState(i)
        /\ StepTrace

LeaderStateStopIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("LeaderStateImpl.stop", i)
        /\ LeaderStateImpl_stop(i)
        /\ ValidatePostState(i)
        /\ StepTrace

StartSetConfigurationIfLogged ==
    \E i \in Server, p \in Server :
        /\ IsNodeEvent("LeaderStateImpl.startSetConfiguration", i)
        /\ p = EventPeer
        /\ LeaderStateImpl_startSetConfiguration(i, p)
        /\ ValidatePostState(i)
        /\ StepTrace

MarkAttemptedSnapshotIfLogged ==
    \E i \in Server, p \in Server :
        /\ IsNodeEvent("LeaderStateImpl.markAttemptedSnapshot", i)
        /\ p = EventPeer
        /\ LeaderStateImpl_markAttemptedSnapshot(i, p)
        /\ ValidatePostState(i)
        /\ StepTrace

CheckProgressCaughtUpIfLogged ==
    \E i \in Server, p \in Server :
        /\ IsNodeEvent("LeaderStateImpl.checkProgress.caughtUp", i)
        /\ p = EventPeer
        /\ LeaderStateImpl_checkProgress_CaughtUp(i, p)
        /\ ValidatePostState(i)
        /\ StepTrace

ApplyOldNewConfIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("LeaderStateImpl.applyOldNewConf", i)
        /\ LeaderStateImpl_applyOldNewConf(i)
        /\ ValidatePostState(i)
        /\ StepTrace

ConfigAckIfLogged ==
    \E i \in Server, p \in Server :
        /\ IsNodeEvent("LeaderStateImpl.configAck", i)
        /\ p = EventPeer
        /\ LeaderStateImpl_configAck(i, p)
        /\ ValidatePostState(i)
        /\ StepTrace

CommitOldNewConfIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("LeaderStateImpl.commitOldNewConf", i)
        /\ LeaderStateImpl_commitOldNewConf(i)
        /\ ValidatePostState(i)
        /\ StepTrace

FollowerUpdateConfBeforeDurableIfLogged ==
    \E i \in Server, p \in Server :
        /\ IsNodeEvent("ServerState.updateConfiguration.beforeAppendDurable", i)
        /\ p = EventPeer
        /\ ServerState_updateConfiguration_BeforeAppendDurable(i, p)
        /\ ValidatePostState(i)
        /\ StepTrace

CommitConfigWithoutOldMajorityFaultIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("LeaderStateImpl.commitConfigWithoutOldMajorityFault", i)
        /\ LeaderStateImpl_commitConfigWithoutOldMajorityFault(i)
        /\ ValidatePostState(i)
        /\ StepTrace

LoseMessageIfLogged ==
    \E m \in messages :
        /\ IsEvent("LoseMessage")
        /\ LoseMessage(m)
        /\ StepTrace

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \/ ServerStateInitElectionIfLogged
    \/ SetVoteReplyLastEntryKindIfLogged
    \/ SilentSubmitRequestVote
    \/ RequestVoteGrantIfLogged
    \/ RequestVoteRejectIfLogged
    \/ LeaderElectionWaitForResultsIfLogged
    \/ AppendEntryCacheAndQueueIfLogged
    \/ WriteLogExecuteIfLogged
    \/ FlushStartIfLogged
    \/ FlushFailIfLogged
    \/ FlushCompleteIfLogged
    \/ FlushLateOrFailedIfLogged
    \/ UpdateCommitIfLogged
    \/ AppendMetadataIfLogged
    \/ CrashAndRecoverIfLogged
    \/ FormatEmptyStorageIfLogged
    \/ SilentSendAppendEntries
    \/ AppendEntriesRejectSnapshotIfLogged
    \/ AppendEntriesSuccessIfLogged
    \/ AppendEntriesAcceptDuringSnapshotFaultIfLogged
    \/ SnapshotNotifyIfLogged
    \/ SnapshotChunkAppendIfLogged
    \/ SnapshotFinalChunkPublishIfLogged
    \/ SnapshotNotificationCompleteIfLogged
    \/ SendReadIndexIfLogged
    \/ LeaseFastPathIfLogged
    \/ EnableLeaseIfLogged
    \/ ReceiveAppendEntriesReplyTimestampIfLogged
    \/ LeaderLeaseExtendIfLogged
    \/ HandleReplyNotLeaderIfLogged
    \/ LeaderStateStopIfLogged
    \/ StartSetConfigurationIfLogged
    \/ MarkAttemptedSnapshotIfLogged
    \/ CheckProgressCaughtUpIfLogged
    \/ ApplyOldNewConfIfLogged
    \/ ConfigAckIfLogged
    \/ CommitOldNewConfIfLogged
    \/ FollowerUpdateConfBeforeDurableIfLogged
    \/ CommitConfigWithoutOldMajorityFaultIfLogged
    \/ LoseMessageIfLogged
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED traceAllVars

TraceSpec == TraceInit /\ [][TraceNext]_traceAllVars /\ WF_traceAllVars(TraceNext)

TraceMatched == <>(l > Len(TraceLog))

=============================================================================
