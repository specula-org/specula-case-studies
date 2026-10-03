----------------------------- MODULE MC -----------------------------
(* Counter-bounded exhaustive model for openraft/base. *)

EXTENDS base

openraft == INSTANCE base

CONSTANTS
    MaxElectionLimit, MaxClientWriteLimit, MaxMembershipLimit,
    MaxSnapshotTriggerLimit, MaxSnapshotSendLimit,
    MaxHeartbeatLimit, MaxReadLimit, MaxCrashLimit,
    MaxLoseLimit, MaxClockAdvanceLimit,
    MaxNetworkLimit, MaxPendingResponseLimit

VARIABLE faultCounters

faultVars == <<faultCounters>>
mcVars == <<vars, faultVars>>

(* Fault/nondeterminism counters are checked and incremented on the same
 * transition.  Reactive completion and receive actions remain unbounded. *)

MCHandleElectionTimeout(s) ==
    /\ faultCounters.election < MaxElectionLimit
    /\ openraft!HandleElectionTimeout(s)
    /\ faultCounters' = [faultCounters EXCEPT !.election = @ + 1]

MCLeaderHandlerLeaderAppendEntries(s, value) ==
    /\ faultCounters.clientWrite < MaxClientWriteLimit
    /\ openraft!LeaderHandlerLeaderAppendEntries(s, value)
    /\ faultCounters' = [faultCounters EXCEPT !.clientWrite = @ + 1]

MCManagementApiStartMembership(requestId, s, goal, retain) ==
    /\ faultCounters.membership < MaxMembershipLimit
    /\ openraft!ManagementApiStartMembership(requestId, s, goal, retain)
    /\ faultCounters' = [faultCounters EXCEPT !.membership = @ + 1]

MCSnapshotHandlerTriggerSnapshot(s) ==
    /\ faultCounters.snapshotTrigger < MaxSnapshotTriggerLimit
    /\ openraft!SnapshotHandlerTriggerSnapshot(s)
    /\ faultCounters' =
         [faultCounters EXCEPT !.snapshotTrigger = @ + 1]

MCReplicationCoreSendSnapshot(s, target) ==
    /\ faultCounters.snapshotSend < MaxSnapshotSendLimit
    /\ openraft!ReplicationCoreSendSnapshot(s, target)
    /\ faultCounters' = [faultCounters EXCEPT !.snapshotSend = @ + 1]

MCLeaderHandlerSendHeartbeat(s) ==
    /\ faultCounters.heartbeat < MaxHeartbeatLimit
    /\ openraft!LeaderHandlerSendHeartbeat(s)
    /\ faultCounters' = [faultCounters EXCEPT !.heartbeat = @ + 1]

MCRaftCoreHandleEnsureLinearizableRead(s, policy) ==
    /\ faultCounters.read < MaxReadLimit
    /\ openraft!RaftCoreHandleEnsureLinearizableRead(s, policy)
    /\ faultCounters' = [faultCounters EXCEPT !.read = @ + 1]

MCCrash(s) ==
    /\ faultCounters.crash < MaxCrashLimit
    /\ openraft!Crash(s)
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

MCLoseMessage(msg) ==
    /\ faultCounters.lose < MaxLoseLimit
    /\ openraft!LoseMessage(msg)
    /\ faultCounters' = [faultCounters EXCEPT !.lose = @ + 1]

MCAdvanceClock ==
    /\ faultCounters.clockAdvance < MaxClockAdvanceLimit
    /\ openraft!AdvanceClock
    /\ faultCounters' = [faultCounters EXCEPT !.clockAdvance = @ + 1]

(* Deterministic/reactive actions: these finish work already introduced by a
 * bounded election, API request, I/O operation, snapshot, or message. *)
MCEngineHandleVoteRequest(receiver, candidate) ==
    /\ openraft!EngineHandleVoteRequest(receiver, candidate)
    /\ UNCHANGED faultVars

MCRaftCoreRunCommandSaveVote(s) ==
    /\ openraft!RaftCoreRunCommandSaveVote(s)
    /\ UNCHANGED faultVars

MCRaftCoreHandleLocalIO(s, io) ==
    /\ openraft!RaftCoreHandleLocalIO(s, io)
    /\ UNCHANGED faultVars

MCRaftCoreReleaseVoteResponse(p) ==
    /\ openraft!RaftCoreReleaseVoteResponse(p)
    /\ UNCHANGED faultVars

MCEngineHandleVoteResponse(s) ==
    /\ openraft!EngineHandleVoteResponse(s)
    /\ UNCHANGED faultVars

MCRaftCoreRunCommandAppendEntries(s) ==
    /\ openraft!RaftCoreRunCommandAppendEntries(s)
    /\ UNCHANGED faultVars

MCLogStoreCompleteAppend(s) ==
    /\ openraft!LogStoreCompleteAppend(s)
    /\ UNCHANGED faultVars

MCIOCompletionForwarder(s) ==
    /\ openraft!IOCompletionForwarder(s)
    /\ UNCHANGED faultVars

MCReplicationHandlerSendReplicate(s, target) ==
    /\ openraft!ReplicationHandlerSendReplicate(s, target)
    /\ UNCHANGED faultVars

MCEngineHandleAppendEntries(s, msg) ==
    /\ openraft!EngineHandleAppendEntries(s, msg)
    /\ UNCHANGED faultVars

MCRaftCoreReleaseRPCResponse(p) ==
    /\ openraft!RaftCoreReleaseRPCResponse(p)
    /\ UNCHANGED faultVars

MCReplicationHandlerUpdateProgress(s, msg) ==
    /\ openraft!ReplicationHandlerUpdateProgress(s, msg)
    /\ UNCHANGED faultVars

MCRaftCoreRunCommandSaveCommittedAndApply(s) ==
    /\ openraft!RaftCoreRunCommandSaveCommittedAndApply(s)
    /\ UNCHANGED faultVars

MCSMWorkerApply(s) ==
    /\ openraft!SMWorkerApply(s)
    /\ UNCHANGED faultVars

MCApplyResponderComplete(p) ==
    /\ openraft!ApplyResponderComplete(p)
    /\ UNCHANGED faultVars

MCCoreChangeMembership(requestId) ==
    /\ openraft!CoreChangeMembership(requestId)
    /\ UNCHANGED faultVars

MCManagementApiFlattenJoint(requestId) ==
    /\ openraft!ManagementApiFlattenJoint(requestId)
    /\ UNCHANGED faultVars

MCSMWorkerBuildSnapshotStart(s) ==
    /\ openraft!SMWorkerBuildSnapshotStart(s)
    /\ UNCHANGED faultVars

MCEngineOnBuildingSnapshotDone(s) ==
    /\ openraft!EngineOnBuildingSnapshotDone(s)
    /\ UNCHANGED faultVars

MCLogHandlerSchedulePolicyBasedPurge(s) ==
    /\ openraft!LogHandlerSchedulePolicyBasedPurge(s)
    /\ UNCHANGED faultVars

MCLogHandlerPurgeLog(s) ==
    /\ openraft!LogHandlerPurgeLog(s)
    /\ UNCHANGED faultVars

MCRaftCoreRunCommandPurgeLog(s) ==
    /\ openraft!RaftCoreRunCommandPurgeLog(s)
    /\ UNCHANGED faultVars

MCFollowingHandlerInstallFullSnapshot(s, msg) ==
    /\ openraft!FollowingHandlerInstallFullSnapshot(s, msg)
    /\ UNCHANGED faultVars

MCSMWorkerInstallSnapshot(s) ==
    /\ openraft!SMWorkerInstallSnapshot(s)
    /\ UNCHANGED faultVars

MCRaftCoreHandleInstallSnapshotNotification(s) ==
    /\ openraft!RaftCoreHandleInstallSnapshotNotification(s)
    /\ UNCHANGED faultVars

MCHeartbeatWorkerDoRun(s, target) ==
    /\ openraft!HeartbeatWorkerDoRun(s, target)
    /\ UNCHANGED faultVars

MCEngineHandleHeartbeatRequest(s, msg) ==
    /\ openraft!EngineHandleHeartbeatRequest(s, msg)
    /\ UNCHANGED faultVars

MCRaftCoreHandleHeartbeatProgress(s, msg) ==
    /\ openraft!RaftCoreHandleHeartbeatProgress(s, msg)
    /\ UNCHANGED faultVars

MCRaftCoreSendReadIndexRequest(s, target) ==
    /\ openraft!RaftCoreSendReadIndexRequest(s, target)
    /\ UNCHANGED faultVars

MCEngineHandleReadIndexRequest(s, msg) ==
    /\ openraft!EngineHandleReadIndexRequest(s, msg)
    /\ UNCHANGED faultVars

MCRaftCoreHandleReadIndexResponse(s, msg) ==
    /\ openraft!RaftCoreHandleReadIndexResponse(s, msg)
    /\ UNCHANGED faultVars

MCLinearizerTryAwaitReady(s) ==
    /\ openraft!LinearizerTryAwaitReady(s)
    /\ UNCHANGED faultVars

MCRestartLoadState(s) ==
    /\ openraft!RestartLoadState(s)
    /\ UNCHANGED faultVars

MCStorageHelperRestoreFromSnapshot(s) ==
    /\ openraft!StorageHelperRestoreFromSnapshot(s)
    /\ UNCHANGED faultVars

MCStorageHelperReapplyCommitted(s) ==
    /\ openraft!StorageHelperReapplyCommitted(s)
    /\ UNCHANGED faultVars

MCStorageHelperFinishRecovery(s) ==
    /\ openraft!StorageHelperFinishRecovery(s)
    /\ UNCHANGED faultVars

MCEngineStartupRestoreLeader(s) ==
    /\ openraft!EngineStartupRestoreLeader(s)
    /\ UNCHANGED faultVars

MCEngineStartupFollowing(s) ==
    /\ openraft!EngineStartupFollowing(s)
    /\ UNCHANGED faultVars

MCInit ==
    /\ Init
    /\ faultCounters =
         [election |-> 0, clientWrite |-> 0, membership |-> 0,
          snapshotTrigger |-> 0, snapshotSend |-> 0,
          heartbeat |-> 0, read |-> 0, crash |-> 0,
          lose |-> 0, clockAdvance |-> 0]

MCNodeStep(s) ==
    \/ MCHandleElectionTimeout(s)
    \/ \E c \in Server \ {s} : MCEngineHandleVoteRequest(s, c)
    \/ MCRaftCoreRunCommandSaveVote(s)
    \/ \E io \in pendingLocalIO[s] : MCRaftCoreHandleLocalIO(s, io)
    \/ MCEngineHandleVoteResponse(s)
    \/ \E value \in Payload : MCLeaderHandlerLeaderAppendEntries(s, value)
    \/ MCRaftCoreRunCommandAppendEntries(s)
    \/ MCLogStoreCompleteAppend(s)
    \/ MCIOCompletionForwarder(s)
    \/ \E target \in Server \ {s} :
           MCReplicationHandlerSendReplicate(s, target)
    \/ \E msg \in network : MCEngineHandleAppendEntries(s, msg)
    \/ \E msg \in network : MCReplicationHandlerUpdateProgress(s, msg)
    \/ MCRaftCoreRunCommandSaveCommittedAndApply(s)
    \/ MCSMWorkerApply(s)
    \/ MCSnapshotHandlerTriggerSnapshot(s)
    \/ MCSMWorkerBuildSnapshotStart(s)
    \/ MCEngineOnBuildingSnapshotDone(s)
    \/ MCLogHandlerSchedulePolicyBasedPurge(s)
    \/ MCLogHandlerPurgeLog(s)
    \/ MCRaftCoreRunCommandPurgeLog(s)
    \/ \E target \in Server \ {s} : MCReplicationCoreSendSnapshot(s, target)
    \/ \E msg \in network : MCFollowingHandlerInstallFullSnapshot(s, msg)
    \/ MCSMWorkerInstallSnapshot(s)
    \/ MCRaftCoreHandleInstallSnapshotNotification(s)
    \/ MCLeaderHandlerSendHeartbeat(s)
    \/ \E target \in Server \ {s} : MCHeartbeatWorkerDoRun(s, target)
    \/ \E msg \in network : MCEngineHandleHeartbeatRequest(s, msg)
    \/ \E msg \in network : MCRaftCoreHandleHeartbeatProgress(s, msg)
    \/ \E policy \in {ReadIndexPolicy, LeaseReadPolicy} :
           MCRaftCoreHandleEnsureLinearizableRead(s, policy)
    \/ \E target \in Server \ {s} : MCRaftCoreSendReadIndexRequest(s, target)
    \/ \E msg \in network : MCEngineHandleReadIndexRequest(s, msg)
    \/ \E msg \in network : MCRaftCoreHandleReadIndexResponse(s, msg)
    \/ MCLinearizerTryAwaitReady(s)
    \/ MCCrash(s)
    \/ MCRestartLoadState(s)
    \/ MCStorageHelperRestoreFromSnapshot(s)
    \/ MCStorageHelperReapplyCommitted(s)
    \/ MCStorageHelperFinishRecovery(s)
    \/ MCEngineStartupRestoreLeader(s)
    \/ MCEngineStartupFollowing(s)

MCGlobalStep ==
    \/ \E p \in pendingResponses : MCRaftCoreReleaseVoteResponse(p)
    \/ \E p \in pendingResponses : MCRaftCoreReleaseRPCResponse(p)
    \/ \E p \in pendingResponses : MCApplyResponderComplete(p)
    \/ \E r \in Request, s \in Server, goal \in SUBSET Server,
          retain \in BOOLEAN :
           MCManagementApiStartMembership(r, s, goal, retain)
    \/ \E r \in Request : MCCoreChangeMembership(r)
    \/ \E r \in Request : MCManagementApiFlattenJoint(r)
    \/ \E msg \in network : MCLoseMessage(msg)
    \/ MCAdvanceClock

MCNext == (\E s \in Server : MCNodeStep(s)) \/ MCGlobalStep

MCSpec == MCInit /\ [][MCNext]_mcVars

(* Payloads are opaque and interchangeable, so this symmetry is safe even
 * though ordered numeric NodeIds themselves are intentionally asymmetric. *)
Symmetry == Permutations(Payload)

MCView == vars

StateConstraint ==
    /\ Cardinality(network) <= MaxNetworkLimit
    /\ Cardinality(pendingResponses) <= MaxPendingResponseLimit

MCTypeOK ==
    /\ TypeOK
    /\ faultCounters.election \in 0..MaxElectionLimit
    /\ faultCounters.clientWrite \in 0..MaxClientWriteLimit
    /\ faultCounters.membership \in 0..MaxMembershipLimit
    /\ faultCounters.snapshotTrigger \in 0..MaxSnapshotTriggerLimit
    /\ faultCounters.snapshotSend \in 0..MaxSnapshotSendLimit
    /\ faultCounters.heartbeat \in 0..MaxHeartbeatLimit
    /\ faultCounters.read \in 0..MaxReadLimit
    /\ faultCounters.crash \in 0..MaxCrashLimit
    /\ faultCounters.lose \in 0..MaxLoseLimit
    /\ faultCounters.clockAdvance \in 0..MaxClockAdvanceLimit

MCProgressStructure == ProgressStructure

RecoveryEventuallyReady ==
    \A s \in Server :
      (online[s] /\ ~recoveryReady[s])
      ~> (recoveryReady[s] \/ ~online[s])

ReadEventuallyCompletes ==
    \A s \in Server :
      readBarrier[s].phase \in {ReadWaitQuorum, ReadWaitApply}
      ~> readBarrier[s].phase \in {ReadDone, ReadIdle}

=================================================================
