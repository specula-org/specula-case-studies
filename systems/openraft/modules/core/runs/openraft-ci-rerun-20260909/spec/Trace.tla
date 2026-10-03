---------------------------- MODULE Trace ----------------------------
(* Linear Category A trace replay for openraft/base. *)

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
traceAllVars == <<vars, traceVars>>

logline == TraceLog[l]

TraceServer == TLCEval({TraceLog[k].event.nid : k \in 1..Len(TraceLog)})
TraceNodeCount == TLCEval(Len(TraceLog[1].event.state.match_index))
ASSUME TraceServer \subseteq 1..TraceNodeCount

TraceMaxIndex == TLCEval(
    LET xs == {TraceLog[k].event.state.accepted_log : k \in 1..Len(TraceLog)}
    IN Max2(1, MaxElem(xs)))

TraceMaxTerm == TLCEval(
    LET xs == {TraceLog[k].event.state.vote.term : k \in 1..Len(TraceLog)}
    IN Max2(1, MaxElem(xs)))

TraceMaxClock == TLCEval(
    LET xs == {TraceLog[k].event.state.clock : k \in 1..Len(TraceLog)}
    IN Max2(1, MaxElem(xs)))

TracePayload == TLCEval(
    LET events == SelectSeq(TraceLog, LAMBDA x :
          /\ x.event.name = "LeaderHandlerLeaderAppendEntries"
          /\ "details" \in DOMAIN x.event)
        vals == {events[k].event.details.value : k \in 1..Len(events)}
    IN IF vals = {} THEN {"__unused_payload"} ELSE vals)

RoleMap ==
    "Follower" :> Follower @@ "Candidate" :> Candidate @@
    "Leader" :> Leader @@ "Down" :> Down

RecoveryMap ==
    "Running" :> Running @@ "RecoverLoad" :> RecoverLoad @@
    "RecoverSnapshot" :> RecoverSnapshot @@
    "RecoverReplay" :> RecoverReplay @@ "RecoverReady" :> RecoverReady

ReadPhaseMap ==
    "Idle" :> ReadIdle @@ "WaitQuorum" :> ReadWaitQuorum @@
    "WaitApply" :> ReadWaitApply @@ "Done" :> ReadDone

ReadPolicyMap ==
    "ReadIndex" :> ReadIndexPolicy @@ "LeaseRead" :> LeaseReadPolicy

RequestPhaseMap ==
    "Idle" :> RequestIdle @@ "Started" :> RequestStarted @@
    "JointSubmitted" :> RequestJointSubmitted @@
    "JointCommitted" :> RequestJointCommitted @@
    "UniformSubmitted" :> RequestUniformSubmitted @@
    "Done" :> RequestDone

BuildPhaseMap ==
    "Idle" :> BuildIdle @@ "Queued" :> BuildQueued @@
    "Running" :> BuildRunning

EntryKindMap ==
    "Normal" :> NormalEntry @@ "Blank" :> BlankEntry @@
    "Membership" :> MembershipEntry

TraceVote(v) == Vote(v.term, v.leader, v.committed)
TraceIO(io) == IO(io.vote, io.log)
SeqAsSet(seq) == {seq[i] : i \in DOMAIN seq}

TraceMembership(m) ==
    Membership(m.log, SeqAsSet(m.old_voters), SeqAsSet(m.new_voters),
               m.joint, IF m.request_id = 0 THEN NoRequest ELSE m.request_id)

TraceSession(session) ==
    [term |-> session.term, leader |-> session.leader,
     membershipIndex |-> session.membership_log]

TraceEntry(e) ==
    LET kind == EntryKindMap[e.kind]
        membership == IF kind = MembershipEntry
                      THEN TraceMembership(e.membership)
                      ELSE NoMembership
        requestId == IF e.request_id = 0 THEN NoRequest ELSE e.request_id
        value == IF kind = NormalEntry THEN e.value ELSE NoopValue
    IN Entry(e.term, e.leader, e.index, kind, value, membership, requestId)

TraceReadState(r) ==
    ReadState(ReadPhaseMap[r.phase], ReadPolicyMap[r.policy],
              r.required, r.floor, TraceSession(r.session),
              TraceMembership(r.membership), SeqAsSet(r.acks), r.read_id)

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, s) ==
    /\ IsEvent(name)
    /\ logline.event.nid = s

(* Strong common post-state validation.  Every event captures the full state
 * visible to the node after the action; action-specific validators below add
 * entry/request/message checks. *)
ValidatePostState(s) ==
    LET st == logline.event.state
    IN /\ online'[s] = st.online
       /\ role'[s] = RoleMap[st.role]
       /\ recoveryStage'[s] = RecoveryMap[st.recovery_stage]
       /\ recoveryReady'[s] = st.recovery_ready
       /\ vote'[s] = TraceVote(st.vote)
       /\ persistentVote'[s] = TraceVote(st.persistent_vote)
       /\ acceptedIO'[s] = IO(st.accepted_vote, st.accepted_log)
       /\ submittedIO'[s] = IO(st.submitted_vote, st.submitted_log)
       /\ durableIO'[s] = IO(st.durable_vote, st.durable_log)
       /\ flushedIO'[s] = IO(st.flushed_vote, st.flushed_log)
       /\ clusterCommitted'[s] = st.cluster_committed
       /\ localCommitted'[s] = st.local_committed
       /\ persistedCommitted'[s] = st.persisted_committed
       /\ applySubmitted'[s] = st.apply_submitted
       /\ smApplied'[s] = st.sm_applied
       /\ committedMembership'[s] = TraceMembership(st.committed_membership)
       /\ effectiveMembership'[s] = TraceMembership(st.effective_membership)
       /\ candidateGranted'[s] = SeqAsSet(st.candidate_granted)
       /\ matchIndex'[s] = [t \in Server |-> st.match_index[t]]
       /\ replicationSession'[s] = TraceSession(st.replication_session)
       /\ clock' = st.clock
       /\ clockAck'[s] = SeqAsSet(st.clock_acks)
       /\ leaseUntil'[s] = st.lease_until
       /\ readBarrier'[s] = TraceReadState(st.read)
       /\ readEpoch'[s] = st.read_epoch
       /\ lastReadObserved'[s] = st.last_read_observed
       /\ lastReadRequired'[s] = st.last_read_required
       /\ buildPhase'[s] = BuildPhaseMap[st.build_phase]
       /\ buildTarget'[s] = st.build_target
       /\ buildMembership'[s] = TraceMembership(st.build_membership)
       /\ snapshotMetaLast'[s] = st.snapshot_meta_last
       /\ snapshotMetaMembership'[s] =
            TraceMembership(st.snapshot_meta_membership)
       /\ snapshotAccepted'[s] = st.snapshot_accepted
       /\ snapshotSubmitted'[s] = st.snapshot_submitted
       /\ snapshotFlushed'[s] = st.snapshot_flushed
       /\ snapshotLast'[s] = st.snapshot_last
       /\ snapshotMembership'[s] = TraceMembership(st.snapshot_membership)
       /\ installDone'[s] = st.install_done
       /\ purgeUpto'[s] = st.purge_upto
       /\ purgeCommand'[s] = st.purge_command
       /\ durablePurged'[s] = st.durable_purged
       /\ clientCompleted' = st.client_completed

ValidateEntryPost(s) ==
    LET d == logline.event.details
    IN /\ d.entry_index \in Index
       /\ engineLog'[s][d.entry_index] = TraceEntry(d.entry)

ValidatePersistentEntryPost(s) ==
    LET d == logline.event.details
    IN /\ d.entry_index \in Index
       /\ persistentLog'[s][d.entry_index] = TraceEntry(d.entry)

ValidateAppliedEntryPost(s) ==
    LET d == logline.event.details
    IN /\ d.entry_index \in Index
       /\ appliedLog'[s][d.entry_index] = TraceEntry(d.entry)

ValidateRequestPost(requestId) ==
    LET r == logline.event.details.request
    IN /\ requestPhase'[requestId] = RequestPhaseMap[r.phase]
       /\ changeRequests'[requestId].status = RequestPhaseMap[r.phase]
       /\ changeRequests'[requestId].owner = r.owner
       /\ changeRequests'[requestId].goal = SeqAsSet(r.goal)
       /\ changeRequests'[requestId].retain = r.retain
       /\ changeRequests'[requestId].log = r.log

StepTrace == l' = l + 1

Finish(s) == /\ ValidatePostState(s) /\ StepTrace
FinishEntry(s) == /\ ValidatePostState(s) /\ ValidateEntryPost(s) /\ StepTrace

MessageMatches(msg, kind) ==
    LET d == logline.event.details
    IN /\ msg.kind = kind
       /\ msg.src = d.src /\ msg.dst = d.dst
       /\ msg.idx = d.idx /\ msg.readId = d.read_id
       /\ msg.session = TraceSession(d.session)

ResponseMatches(p, kind) ==
    LET d == logline.event.details
    IN /\ p.kind = kind
       /\ p.node = d.node /\ p.peer = d.peer
       /\ p.requiredVote = d.required_vote
       /\ p.requiredLog = d.required_log
       /\ p.readId = d.read_id

HandleElectionTimeoutIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("HandleElectionTimeout", s)
      /\ HandleElectionTimeout(s)
      /\ Finish(s)

EngineHandleVoteRequestIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("EngineHandleVoteRequest", s)
      /\ EngineHandleVoteRequest(s, logline.event.details.candidate)
      /\ Finish(s)

RaftCoreRunCommandSaveVoteIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("RaftCoreRunCommandSaveVote", s)
      /\ RaftCoreRunCommandSaveVote(s)
      /\ Finish(s)

RaftCoreHandleLocalIOIfLogged ==
    \E s \in Server :
      \E io \in pendingLocalIO[s] :
        /\ IsNodeEvent("RaftCoreHandleLocalIO", s)
        /\ io = TraceIO(logline.event.details.io)
        /\ RaftCoreHandleLocalIO(s, io)
        /\ Finish(s)

RaftCoreReleaseVoteResponseIfLogged ==
    \E p \in pendingResponses :
      /\ IsNodeEvent("RaftCoreReleaseVoteResponse", p.peer)
      /\ ResponseMatches(p, VoteResponseKind)
      /\ RaftCoreReleaseVoteResponse(p)
      /\ Finish(p.peer)

EngineHandleVoteResponseIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("EngineHandleVoteResponse", s)
      /\ EngineHandleVoteResponse(s)
      /\ FinishEntry(s)

LeaderHandlerLeaderAppendEntriesIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("LeaderHandlerLeaderAppendEntries", s)
      /\ LeaderHandlerLeaderAppendEntries(s, logline.event.details.value)
      /\ FinishEntry(s)

RaftCoreRunCommandAppendEntriesIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("RaftCoreRunCommandAppendEntries", s)
      /\ RaftCoreRunCommandAppendEntries(s)
      /\ Finish(s)

LogStoreCompleteAppendIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("LogStoreCompleteAppend", s)
      /\ LogStoreCompleteAppend(s)
      /\ ValidatePostState(s)
      /\ ValidatePersistentEntryPost(s)
      /\ StepTrace

ReplicationHandlerSendReplicateIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("ReplicationHandlerSendReplicate", s)
      /\ ReplicationHandlerSendReplicate(s, logline.event.details.target)
      /\ Finish(s)

EngineHandleAppendEntriesIfLogged ==
    \E s \in Server, msg \in network :
      /\ IsNodeEvent("EngineHandleAppendEntries", s)
      /\ MessageMatches(msg, AppendRequest)
      /\ msg.entry = TraceEntry(logline.event.details.entry)
      /\ EngineHandleAppendEntries(s, msg)
      /\ FinishEntry(s)

RaftCoreReleaseRPCResponseIfLogged ==
    \E p \in pendingResponses :
      /\ IsNodeEvent("RaftCoreReleaseRPCResponse", p.node)
      /\ p.kind =
           CASE logline.event.details.kind = "Append" -> AppendResponseKind
             [] logline.event.details.kind = "Heartbeat" -> HeartbeatResponseKind
             [] OTHER -> ReadIndexResponseKind
      /\ ResponseMatches(p, p.kind)
      /\ RaftCoreReleaseRPCResponse(p)
      /\ Finish(p.node)

ReplicationHandlerUpdateProgressIfLogged ==
    \E s \in Server, msg \in network :
      /\ IsNodeEvent("ReplicationHandlerUpdateProgress", s)
      /\ MessageMatches(msg, AppendResponse)
      /\ ReplicationHandlerUpdateProgress(s, msg)
      /\ Finish(s)

RaftCoreRunCommandSaveCommittedAndApplyIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("RaftCoreRunCommandSaveCommittedAndApply", s)
      /\ RaftCoreRunCommandSaveCommittedAndApply(s)
      /\ Finish(s)

SMWorkerApplyIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("SMWorkerApply", s)
      /\ SMWorkerApply(s)
      /\ ValidatePostState(s)
      /\ ValidateAppliedEntryPost(s)
      /\ IF logline.event.details.entry.kind = "Membership"
         THEN ValidateRequestPost(logline.event.details.entry.request_id)
         ELSE TRUE
      /\ StepTrace

ApplyResponderCompleteIfLogged ==
    \E p \in pendingResponses :
      /\ IsNodeEvent("ApplyResponderComplete", p.node)
      /\ ResponseMatches(p, ClientResponseKind)
      /\ ApplyResponderComplete(p)
      /\ Finish(p.node)

ManagementApiStartMembershipIfLogged ==
    LET d == logline.event.details
    IN \E s \in Server :
      /\ IsNodeEvent("ManagementApiStartMembership", s)
      /\ ManagementApiStartMembership(d.request_id, s,
                                       SeqAsSet(d.goal), d.retain)
      /\ ValidatePostState(s)
      /\ ValidateRequestPost(d.request_id)
      /\ StepTrace

CoreChangeMembershipIfLogged ==
    LET d == logline.event.details
    IN \E s \in Server :
      /\ IsNodeEvent("CoreChangeMembership", s)
      /\ changeRequests[d.request_id].owner = s
      /\ CoreChangeMembership(d.request_id)
      /\ ValidatePostState(s)
      /\ ValidateEntryPost(s)
      /\ ValidateRequestPost(d.request_id)
      /\ StepTrace

ManagementApiFlattenJointIfLogged ==
    LET d == logline.event.details
    IN \E s \in Server :
      /\ IsNodeEvent("ManagementApiFlattenJoint", s)
      /\ changeRequests[d.request_id].owner = s
      /\ ManagementApiFlattenJoint(d.request_id)
      /\ ValidatePostState(s)
      /\ ValidateEntryPost(s)
      /\ ValidateRequestPost(d.request_id)
      /\ StepTrace

SnapshotHandlerTriggerSnapshotIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("SnapshotHandlerTriggerSnapshot", s)
      /\ SnapshotHandlerTriggerSnapshot(s)
      /\ Finish(s)

SMWorkerBuildSnapshotStartIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("SMWorkerBuildSnapshotStart", s)
      /\ SMWorkerBuildSnapshotStart(s)
      /\ Finish(s)

EngineOnBuildingSnapshotDoneIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("EngineOnBuildingSnapshotDone", s)
      /\ EngineOnBuildingSnapshotDone(s)
      /\ Finish(s)

LogHandlerSchedulePolicyBasedPurgeIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("LogHandlerSchedulePolicyBasedPurge", s)
      /\ LogHandlerSchedulePolicyBasedPurge(s)
      /\ Finish(s)

LogHandlerPurgeLogIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("LogHandlerPurgeLog", s)
      /\ LogHandlerPurgeLog(s)
      /\ Finish(s)

RaftCoreRunCommandPurgeLogIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("RaftCoreRunCommandPurgeLog", s)
      /\ RaftCoreRunCommandPurgeLog(s)
      /\ Finish(s)

ReplicationCoreSendSnapshotIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("ReplicationCoreSendSnapshot", s)
      /\ ReplicationCoreSendSnapshot(s, logline.event.details.target)
      /\ Finish(s)

FollowingHandlerInstallFullSnapshotIfLogged ==
    \E s \in Server, msg \in network :
      /\ IsNodeEvent("FollowingHandlerInstallFullSnapshot", s)
      /\ MessageMatches(msg, AppendRequest) /\ msg.entry = Nil
      /\ FollowingHandlerInstallFullSnapshot(s, msg)
      /\ Finish(s)

SMWorkerInstallSnapshotIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("SMWorkerInstallSnapshot", s)
      /\ SMWorkerInstallSnapshot(s)
      /\ Finish(s)

RaftCoreHandleInstallSnapshotNotificationIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("RaftCoreHandleInstallSnapshotNotification", s)
      /\ RaftCoreHandleInstallSnapshotNotification(s)
      /\ Finish(s)

LeaderHandlerSendHeartbeatIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("LeaderHandlerSendHeartbeat", s)
      /\ LeaderHandlerSendHeartbeat(s)
      /\ Finish(s)

HeartbeatWorkerDoRunIfLogged ==
    LET d == logline.event.details
    IN \E s \in Server :
      /\ IsNodeEvent("HeartbeatWorkerDoRun", s)
      /\ HeartbeatWorkerDoRun(s, d.target)
      /\ Finish(s)

EngineHandleHeartbeatRequestIfLogged ==
    \E s \in Server, msg \in network :
      /\ IsNodeEvent("EngineHandleHeartbeatRequest", s)
      /\ MessageMatches(msg, HeartbeatRequest)
      /\ EngineHandleHeartbeatRequest(s, msg)
      /\ Finish(s)

RaftCoreHandleHeartbeatProgressIfLogged ==
    \E s \in Server, msg \in network :
      /\ IsNodeEvent("RaftCoreHandleHeartbeatProgress", s)
      /\ MessageMatches(msg, HeartbeatResponse)
      /\ RaftCoreHandleHeartbeatProgress(s, msg)
      /\ Finish(s)

RaftCoreHandleEnsureLinearizableReadIfLogged ==
    LET policy == ReadPolicyMap[logline.event.details.policy]
    IN \E s \in Server :
      /\ IsNodeEvent("RaftCoreHandleEnsureLinearizableRead", s)
      /\ RaftCoreHandleEnsureLinearizableRead(s, policy)
      /\ Finish(s)

RaftCoreSendReadIndexRequestIfLogged ==
    LET d == logline.event.details
    IN \E s \in Server :
      /\ IsNodeEvent("RaftCoreSendReadIndexRequest", s)
      /\ RaftCoreSendReadIndexRequest(s, d.target)
      /\ Finish(s)

EngineHandleReadIndexRequestIfLogged ==
    \E s \in Server, msg \in network :
      /\ IsNodeEvent("EngineHandleReadIndexRequest", s)
      /\ MessageMatches(msg, ReadIndexRequest)
      /\ EngineHandleReadIndexRequest(s, msg)
      /\ Finish(s)

RaftCoreHandleReadIndexResponseIfLogged ==
    \E s \in Server, msg \in network :
      /\ IsNodeEvent("RaftCoreHandleReadIndexResponse", s)
      /\ MessageMatches(msg, ReadIndexResponse)
      /\ RaftCoreHandleReadIndexResponse(s, msg)
      /\ Finish(s)

LinearizerTryAwaitReadyIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("LinearizerTryAwaitReady", s)
      /\ LinearizerTryAwaitReady(s)
      /\ Finish(s)

AdvanceClockIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("AdvanceClock", s)
      /\ AdvanceClock
      /\ Finish(s)

LoseMessageIfLogged ==
    \E s \in Server, msg \in network :
      /\ IsNodeEvent("LoseMessage", s)
      /\ MessageMatches(msg,
           CASE logline.event.details.kind = "AppendRequest" -> AppendRequest
             [] logline.event.details.kind = "AppendResponse" -> AppendResponse
             [] logline.event.details.kind = "HeartbeatRequest" -> HeartbeatRequest
             [] logline.event.details.kind = "HeartbeatResponse" -> HeartbeatResponse
             [] logline.event.details.kind = "ReadIndexRequest" -> ReadIndexRequest
             [] OTHER -> ReadIndexResponse)
      /\ LoseMessage(msg)
      /\ Finish(s)

CrashIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("Crash", s)
      /\ Crash(s)
      /\ Finish(s)

RestartLoadStateIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("RestartLoadState", s)
      /\ RestartLoadState(s)
      /\ Finish(s)

StorageHelperRestoreFromSnapshotIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("StorageHelperRestoreFromSnapshot", s)
      /\ StorageHelperRestoreFromSnapshot(s)
      /\ Finish(s)

StorageHelperReapplyCommittedIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("StorageHelperReapplyCommitted", s)
      /\ StorageHelperReapplyCommitted(s)
      /\ Finish(s)

StorageHelperFinishRecoveryIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("StorageHelperFinishRecovery", s)
      /\ StorageHelperFinishRecovery(s)
      /\ Finish(s)

EngineStartupRestoreLeaderIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("EngineStartupRestoreLeader", s)
      /\ EngineStartupRestoreLeader(s)
      /\ Finish(s)

EngineStartupFollowingIfLogged ==
    \E s \in Server :
      /\ IsNodeEvent("EngineStartupFollowing", s)
      /\ EngineStartupFollowing(s)
      /\ Finish(s)

TraceInit == /\ Init /\ l = 1

TraceAction ==
    \/ HandleElectionTimeoutIfLogged
    \/ EngineHandleVoteRequestIfLogged
    \/ RaftCoreRunCommandSaveVoteIfLogged
    \/ RaftCoreHandleLocalIOIfLogged
    \/ RaftCoreReleaseVoteResponseIfLogged
    \/ EngineHandleVoteResponseIfLogged
    \/ LeaderHandlerLeaderAppendEntriesIfLogged
    \/ RaftCoreRunCommandAppendEntriesIfLogged
    \/ LogStoreCompleteAppendIfLogged
    \/ ReplicationHandlerSendReplicateIfLogged
    \/ EngineHandleAppendEntriesIfLogged
    \/ RaftCoreReleaseRPCResponseIfLogged
    \/ ReplicationHandlerUpdateProgressIfLogged
    \/ RaftCoreRunCommandSaveCommittedAndApplyIfLogged
    \/ SMWorkerApplyIfLogged
    \/ ApplyResponderCompleteIfLogged
    \/ ManagementApiStartMembershipIfLogged
    \/ CoreChangeMembershipIfLogged
    \/ ManagementApiFlattenJointIfLogged
    \/ SnapshotHandlerTriggerSnapshotIfLogged
    \/ SMWorkerBuildSnapshotStartIfLogged
    \/ EngineOnBuildingSnapshotDoneIfLogged
    \/ LogHandlerSchedulePolicyBasedPurgeIfLogged
    \/ LogHandlerPurgeLogIfLogged
    \/ RaftCoreRunCommandPurgeLogIfLogged
    \/ ReplicationCoreSendSnapshotIfLogged
    \/ FollowingHandlerInstallFullSnapshotIfLogged
    \/ SMWorkerInstallSnapshotIfLogged
    \/ RaftCoreHandleInstallSnapshotNotificationIfLogged
    \/ LeaderHandlerSendHeartbeatIfLogged
    \/ HeartbeatWorkerDoRunIfLogged
    \/ EngineHandleHeartbeatRequestIfLogged
    \/ RaftCoreHandleHeartbeatProgressIfLogged
    \/ RaftCoreHandleEnsureLinearizableReadIfLogged
    \/ RaftCoreSendReadIndexRequestIfLogged
    \/ EngineHandleReadIndexRequestIfLogged
    \/ RaftCoreHandleReadIndexResponseIfLogged
    \/ LinearizerTryAwaitReadyIfLogged
    \/ AdvanceClockIfLogged
    \/ LoseMessageIfLogged
    \/ CrashIfLogged
    \/ RestartLoadStateIfLogged
    \/ StorageHelperRestoreFromSnapshotIfLogged
    \/ StorageHelperReapplyCommittedIfLogged
    \/ StorageHelperFinishRecoveryIfLogged
    \/ EngineStartupRestoreLeaderIfLogged
    \/ EngineStartupFollowingIfLogged

TraceInternalAction ==
    \E s \in Server :
      /\ IOCompletionForwarder(s)
      /\ UNCHANGED traceVars

(* Every semantically visible base action is instrumented.  The update adds one
 * constrained internal bridge action for the watch-channel forwarder, which
 * does not own enough Raft state to emit the full common trace record. *)
TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ TraceAction
    \/ /\ l <= Len(TraceLog)
       /\ TraceInternalAction
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED traceAllVars

LoggedTraceAction == /\ l <= Len(TraceLog) /\ TraceAction
InternalTraceAction == /\ l <= Len(TraceLog) /\ TraceInternalAction

(* Weak fairness rules out vacuous infinite stuttering while the next logged
 * event, or a required internal bridge step, is matchable. *)
TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_traceAllVars
    /\ WF_traceAllVars(LoggedTraceAction \/ InternalTraceAction)

TraceMatched == <>(l > Len(TraceLog))
TraceTypeOK == l \in 1..(Len(TraceLog) + 1)

=================================================================
