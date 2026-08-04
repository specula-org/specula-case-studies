------------------------------- MODULE MC -------------------------------
(*
 * Model-checking wrapper for base.tla.
 *
 * Counter-bounded actions introduce non-determinism or fault/input pressure:
 * elections, client writes/reads, persist failure, old gRPC replies,
 * pending-request timeout/reset, snapshot/purge/restart, config change, and
 * step-down event submission.  Reactive actions such as request handling,
 * physical append completion, reply processing, commit, apply, reply flush,
 * and read completion are deliberately unbounded.
 *)

EXTENDS base

ratis == INSTANCE base

CONSTANTS
    MaxElectionLimit,
    MaxClientAppendLimit,
    MaxReadLimit,
    MaxSendAppendLimit,
    MaxPersistFailureLimit,
    MaxStepDownEventLimit,
    MaxOldReplyLimit,
    MaxTimeoutLimit,
    MaxResetLimit,
    MaxSnapshotLimit,
    MaxPurgeLimit,
    MaxRestartLimit,
    MaxConfigChangeLimit,
    MaxMsgBufferLimit

VARIABLE faultCounters

faultVars == <<faultCounters>>
MCvars == <<vars, faultCounters>>

\* -------------------------------------------------------------------------
\* Counter-bounded input/fault actions
\* -------------------------------------------------------------------------

MCServerState_initElection_ELECTION(s) ==
    /\ faultCounters.election < MaxElectionLimit
    /\ ratis!ServerState_initElection_ELECTION(s)
    /\ faultCounters' = [faultCounters EXCEPT !.election = @ + 1]

MCRaftServerImpl_appendTransaction(l, value) ==
    /\ faultCounters.clientAppend < MaxClientAppendLimit
    /\ ratis!RaftServerImpl_appendTransaction(l, value)
    /\ faultCounters' = [faultCounters EXCEPT !.clientAppend = @ + 1]

MCLeaderStateImpl_getReadIndex(l) ==
    /\ faultCounters.read < MaxReadLimit
    /\ ratis!LeaderStateImpl_getReadIndex(l)
    /\ faultCounters' = [faultCounters EXCEPT !.read = @ + 1]

MCGrpcLogAppender_appendLog(l, f) ==
    /\ faultCounters.sendAppend < MaxSendAppendLimit
    /\ ratis!GrpcLogAppender_appendLog(l, f)
    /\ faultCounters' = [faultCounters EXCEPT !.sendAppend = @ + 1]

MCRaftServerImpl_changeToFollowerAndPersistMetadata_PersistFailure(s, l, t) ==
    /\ faultCounters.persistFailure < MaxPersistFailureLimit
    /\ ratis!RaftServerImpl_changeToFollowerAndPersistMetadata_PersistFailure(s, l, t)
    /\ faultCounters' = [faultCounters EXCEPT !.persistFailure = @ + 1]

MCLeaderStateImpl_submitStepDownEvent(s, t) ==
    /\ faultCounters.stepDownEvent < MaxStepDownEventLimit
    /\ ratis!LeaderStateImpl_submitStepDownEvent(s, t)
    /\ faultCounters' = [faultCounters EXCEPT !.stepDownEvent = @ + 1]

MCGrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_OldStream(l, f, i) ==
    /\ faultCounters.oldReply < MaxOldReplyLimit
    /\ ratis!GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_OldStream(l, f, i)
    /\ faultCounters' = [faultCounters EXCEPT !.oldReply = @ + 1]

MCGrpcLogAppender_timeoutAppendRequest(f) ==
    /\ faultCounters.timeout < MaxTimeoutLimit
    /\ ratis!GrpcLogAppender_timeoutAppendRequest(f)
    /\ faultCounters' = [faultCounters EXCEPT !.timeout = @ + 1]

MCGrpcLogAppender_resetClient(f) ==
    /\ faultCounters.reset < MaxResetLimit
    /\ ratis!GrpcLogAppender_resetClient(f)
    /\ faultCounters' = [faultCounters EXCEPT !.reset = @ + 1]

MCGrpcLogAppender_installSnapshot_Notify(l, f) ==
    /\ faultCounters.snapshot < MaxSnapshotLimit
    /\ ratis!GrpcLogAppender_installSnapshot_Notify(l, f)
    /\ faultCounters' = [faultCounters EXCEPT !.snapshot = @ + 1]

MCConfigurationManager_removeConfigurations_PurgeLog(s, i) ==
    /\ faultCounters.purge < MaxPurgeLimit
    /\ ratis!ConfigurationManager_removeConfigurations_PurgeLog(s, i)
    /\ faultCounters' = [faultCounters EXCEPT !.purge = @ + 1]

MCRaftLogBase_open_Restart(s) ==
    /\ faultCounters.restart < MaxRestartLimit
    /\ ratis!RaftLogBase_open_Restart(s)
    /\ faultCounters' = [faultCounters EXCEPT !.restart = @ + 1]

MCRaftServerImpl_setConfigurationAsync_Start(l, p) ==
    /\ faultCounters.configChange < MaxConfigChangeLimit
    /\ ratis!RaftServerImpl_setConfigurationAsync_Start(l, p)
    /\ faultCounters' = [faultCounters EXCEPT !.configChange = @ + 1]

\* -------------------------------------------------------------------------
\* Unbounded reactive actions
\* -------------------------------------------------------------------------

MCRaftServerImpl_requestVote_Grant(v, c) ==
    /\ ratis!RaftServerImpl_requestVote_Grant(v, c)
    /\ UNCHANGED faultVars

MCRaftServerImpl_changeToLeader(s) ==
    /\ ratis!RaftServerImpl_changeToLeader(s)
    /\ UNCHANGED faultVars

MCServerState_persistMetadata(s) ==
    /\ ratis!ServerState_persistMetadata(s)
    /\ UNCHANGED faultVars

MCLeaderStateImpl_stepDown(s) ==
    /\ ratis!LeaderStateImpl_stepDown(s)
    /\ UNCHANGED faultVars

MCRaftServerImpl_appendEntriesAsync_RegisterInFlight(s) ==
    /\ ratis!RaftServerImpl_appendEntriesAsync_RegisterInFlight(s)
    /\ UNCHANGED faultVars

MCServerImplUtils_NavigableIndices_append_ComposeExisting(s) ==
    /\ ratis!ServerImplUtils_NavigableIndices_append_ComposeExisting(s)
    /\ UNCHANGED faultVars

MCRaftServerImpl_appendEntriesAsync_RecognizeLeaderHeartbeat(s, l, t) ==
    /\ ratis!RaftServerImpl_appendEntriesAsync_RecognizeLeaderHeartbeat(s, l, t)
    /\ UNCHANGED faultVars

MCRaftServerImpl_appendEntriesAsync_InconsistencyReply(s) ==
    /\ ratis!RaftServerImpl_appendEntriesAsync_InconsistencyReply(s)
    /\ UNCHANGED faultVars

MCSegmentedRaftLog_appendImpl_CompletePhysicalAppend(s) ==
    /\ ratis!SegmentedRaftLog_appendImpl_CompletePhysicalAppend(s)
    /\ UNCHANGED faultVars

MCRaftServerImpl_appendEntriesAsync_ReplyOriginal(s) ==
    /\ ratis!RaftServerImpl_appendEntriesAsync_ReplyOriginal(s)
    /\ UNCHANGED faultVars

MCRaftServerImpl_appendEntriesAsync_ReplyComposed(s) ==
    /\ ratis!RaftServerImpl_appendEntriesAsync_ReplyComposed(s)
    /\ UNCHANGED faultVars

MCServerImplUtils_NavigableIndices_removeExisting(s) ==
    /\ ratis!ServerImplUtils_NavigableIndices_removeExisting(s)
    /\ UNCHANGED faultVars

MCGrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS(l, f) ==
    /\ ratis!GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS(l, f)
    /\ UNCHANGED faultVars

MCLeaderStateImpl_updateCommit(l, i) ==
    /\ ratis!LeaderStateImpl_updateCommit(l, i)
    /\ UNCHANGED faultVars

MCStateMachineUpdater_applyEntry(s) ==
    /\ ratis!StateMachineUpdater_applyEntry(s)
    /\ UNCHANGED faultVars

MCReplyFlusher_flush(s) ==
    /\ ratis!ReplyFlusher_flush(s)
    /\ UNCHANGED faultVars

MCReadIndexHeartbeats_HeartbeatAck(l, f) ==
    /\ ratis!ReadIndexHeartbeats_HeartbeatAck(l, f)
    /\ UNCHANGED faultVars

MCReadRequests_waitToAdvance_CompleteRead(l) ==
    /\ ratis!ReadRequests_waitToAdvance_CompleteRead(l)
    /\ UNCHANGED faultVars

MCSnapshotInstallationHandler_checkAndInstallSnapshot_Chunk0(f) ==
    /\ ratis!SnapshotInstallationHandler_checkAndInstallSnapshot_Chunk0(f)
    /\ UNCHANGED faultVars

MCSnapshotInstallationHandler_checkAndInstallSnapshot_Finalize(f) ==
    /\ ratis!SnapshotInstallationHandler_checkAndInstallSnapshot_Finalize(f)
    /\ UNCHANGED faultVars

MCSnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_Reload(f) ==
    /\ ratis!SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_Reload(f)
    /\ UNCHANGED faultVars

MCSnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_AlreadyInstalled(f) ==
    /\ ratis!SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_AlreadyInstalled(f)
    /\ UNCHANGED faultVars

MCLeaderStateImpl_checkProgress_CaughtUp(l, f) ==
    /\ ratis!LeaderStateImpl_checkProgress_CaughtUp(l, f)
    /\ UNCHANGED faultVars

MCLeaderStateImpl_applyOldNewConf(l) ==
    /\ ratis!LeaderStateImpl_applyOldNewConf(l)
    /\ UNCHANGED faultVars

MCLeaderStateImpl_replicateNewConf(l) ==
    /\ ratis!LeaderStateImpl_replicateNewConf(l)
    /\ UNCHANGED faultVars

MCServerState_updateConfiguration_PromoteListener(s) ==
    /\ ratis!ServerState_updateConfiguration_PromoteListener(s)
    /\ UNCHANGED faultVars

\* -------------------------------------------------------------------------
\* Init / Next
\* -------------------------------------------------------------------------

MCInit ==
    /\ Init
    /\ faultCounters =
        [election |-> 0, clientAppend |-> 0, read |-> 0,
         sendAppend |-> 0, persistFailure |-> 0, stepDownEvent |-> 0,
         oldReply |-> 0, timeout |-> 0, reset |-> 0, snapshot |-> 0,
         purge |-> 0, restart |-> 0, configChange |-> 0]

MCNext ==
    \/ \E s \in Server: MCServerState_initElection_ELECTION(s)
    \/ \E v \in Server, c \in Server: MCRaftServerImpl_requestVote_Grant(v, c)
    \/ \E s \in Server: MCRaftServerImpl_changeToLeader(s)
    \/ \E s \in Server, l \in Server, t \in Term:
            MCRaftServerImpl_changeToFollowerAndPersistMetadata_PersistFailure(s, l, t)
    \/ \E s \in Server: MCServerState_persistMetadata(s)
    \/ \E s \in Server, t \in Term: MCLeaderStateImpl_submitStepDownEvent(s, t)
    \/ \E s \in Server: MCLeaderStateImpl_stepDown(s)
    \/ \E l \in Server, v \in EntryValue: MCRaftServerImpl_appendTransaction(l, v)
    \/ \E l \in Server, f \in Server: MCGrpcLogAppender_appendLog(l, f)
    \/ \E s \in Server: MCRaftServerImpl_appendEntriesAsync_RegisterInFlight(s)
    \/ \E s \in Server: MCServerImplUtils_NavigableIndices_append_ComposeExisting(s)
    \/ \E s \in Server, l \in Server, t \in Term:
            MCRaftServerImpl_appendEntriesAsync_RecognizeLeaderHeartbeat(s, l, t)
    \/ \E s \in Server: MCRaftServerImpl_appendEntriesAsync_InconsistencyReply(s)
    \/ \E s \in Server: MCSegmentedRaftLog_appendImpl_CompletePhysicalAppend(s)
    \/ \E s \in Server: MCRaftServerImpl_appendEntriesAsync_ReplyOriginal(s)
    \/ \E s \in Server: MCRaftServerImpl_appendEntriesAsync_ReplyComposed(s)
    \/ \E s \in Server: MCServerImplUtils_NavigableIndices_removeExisting(s)
    \/ \E l \in Server, f \in Server: MCGrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS(l, f)
    \/ \E l \in Server, f \in Server, i \in Index:
            MCGrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_OldStream(l, f, i)
    \/ \E f \in Server: MCGrpcLogAppender_timeoutAppendRequest(f)
    \/ \E f \in Server: MCGrpcLogAppender_resetClient(f)
    \/ \E l \in Server, i \in Index: MCLeaderStateImpl_updateCommit(l, i)
    \/ \E s \in Server: MCStateMachineUpdater_applyEntry(s)
    \/ \E s \in Server: MCReplyFlusher_flush(s)
    \/ \E l \in Server: MCLeaderStateImpl_getReadIndex(l)
    \/ \E l \in Server, f \in Server: MCReadIndexHeartbeats_HeartbeatAck(l, f)
    \/ \E l \in Server: MCReadRequests_waitToAdvance_CompleteRead(l)
    \/ \E l \in Server, f \in Server: MCGrpcLogAppender_installSnapshot_Notify(l, f)
    \/ \E f \in Server: MCSnapshotInstallationHandler_checkAndInstallSnapshot_Chunk0(f)
    \/ \E f \in Server: MCSnapshotInstallationHandler_checkAndInstallSnapshot_Finalize(f)
    \/ \E f \in Server: MCSnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_Reload(f)
    \/ \E f \in Server: MCSnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_AlreadyInstalled(f)
    \/ \E s \in Server, i \in Index: MCConfigurationManager_removeConfigurations_PurgeLog(s, i)
    \/ \E s \in Server: MCRaftLogBase_open_Restart(s)
    \/ \E l \in Server, p \in Server: MCRaftServerImpl_setConfigurationAsync_Start(l, p)
    \/ \E l \in Server, f \in Server: MCLeaderStateImpl_checkProgress_CaughtUp(l, f)
    \/ \E l \in Server: MCLeaderStateImpl_applyOldNewConf(l)
    \/ \E l \in Server: MCLeaderStateImpl_replicateNewConf(l)
    \/ \E s \in Server: MCServerState_updateConfiguration_PromoteListener(s)

MCSpec == MCInit /\ [][MCNext]_MCvars

\* -------------------------------------------------------------------------
\* MC structural constraints
\* -------------------------------------------------------------------------

MCTypeOK ==
    /\ TypeOK
    /\ faultCounters \in
        [election: 0..MaxElectionLimit,
         clientAppend: 0..MaxClientAppendLimit,
         read: 0..MaxReadLimit,
         sendAppend: 0..MaxSendAppendLimit,
         persistFailure: 0..MaxPersistFailureLimit,
         stepDownEvent: 0..MaxStepDownEventLimit,
         oldReply: 0..MaxOldReplyLimit,
         timeout: 0..MaxTimeoutLimit,
         reset: 0..MaxResetLimit,
         snapshot: 0..MaxSnapshotLimit,
         purge: 0..MaxPurgeLimit,
         restart: 0..MaxRestartLimit,
         configChange: 0..MaxConfigChangeLimit]

PendingRequestCount ==
    Cardinality({s \in Server: pendingRequest[s].present})
    + Cardinality({s \in Server: inFlightAppend[s].present})
    + Cardinality({s \in Server: composedAppend[s].present})
    + Cardinality({s \in Server: appendReply[s].present})

MsgBufferConstraint == PendingRequestCount <= MaxMsgBufferLimit

Symmetry == Permutations(Server)

MCModelView ==
    <<ModelView, faultCounters>>

=============================================================================
