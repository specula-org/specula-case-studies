------------------------------ MODULE MC ------------------------------
(*
 * Model checking wrapper for base.tla.
 *
 * Fault-injection / nondeterministic actions are counter-bounded here.
 * Reactive implementation actions are not bounded.
 *)

EXTENDS base

ratis == INSTANCE base

CONSTANTS
    MaxElectionLimit,
    MaxAppendLimit,
    MaxFlushLimit,
    MaxAsyncFlushBugLimit,
    MaxCrashLimit,
    MaxFormatLimit,
    MaxMessageLimit,
    MaxSnapshotLimit,
    MaxSnapshotBugLimit,
    MaxReadLimit,
    MaxLeaseLimit,
    MaxConfigLimit,
    MaxConfigBugLimit,
    MaxMsgBufferLimit

VARIABLE faultCounters

faultVars == <<faultCounters>>
mcVars == <<vars, faultCounters>>

MCInit ==
    /\ Init
    /\ faultCounters = [
        election      |-> 0,
        append        |-> 0,
        flush         |-> 0,
        asyncFlushBug |-> 0,
        crash         |-> 0,
        format        |-> 0,
        message       |-> 0,
        snapshot      |-> 0,
        snapshotBug   |-> 0,
        read          |-> 0,
        lease         |-> 0,
        config        |-> 0,
        configBug     |-> 0 ]

\* --------------------------------------------------------------------------
\* Counter-bounded actions.
\* --------------------------------------------------------------------------

MCServerState_initElection_ELECTION(s) ==
    /\ faultCounters.election < MaxElectionLimit
    /\ ratis!ServerState_initElection_ELECTION(s)
    /\ faultCounters' = [faultCounters EXCEPT !.election = @ + 1]

MCServerProtoUtils_setVoteReplyLastEntryKind(s, kind) ==
    /\ faultCounters.election < MaxElectionLimit
    /\ ratis!ServerProtoUtils_setVoteReplyLastEntryKind(s, kind)
    /\ faultCounters' = [faultCounters EXCEPT !.election = @ + 1]

MCLeaderElection_submitRequestVote(c, v) ==
    /\ faultCounters.message < MaxMessageLimit
    /\ ratis!LeaderElection_submitRequestVote(c, v)
    /\ faultCounters' = [faultCounters EXCEPT !.message = @ + 1]

MCRaftLogBase_appendEntry_CacheAndQueue(s, idx, kind, p) ==
    /\ faultCounters.append < MaxAppendLimit
    /\ ratis!RaftLogBase_appendEntry_CacheAndQueue(s, idx, kind, p)
    /\ faultCounters' = [faultCounters EXCEPT !.append = @ + 1]

MCSegmentedRaftLogWorker_flushIfNecessary_Start(s) ==
    /\ faultCounters.flush < MaxFlushLimit
    /\ ratis!SegmentedRaftLogWorker_flushIfNecessary_Start(s)
    /\ faultCounters' = [faultCounters EXCEPT !.flush = @ + 1]

MCSegmentedRaftLogWorker_asyncFlushOutStream_Fail(s) ==
    /\ faultCounters.asyncFlushBug < MaxAsyncFlushBugLimit
    /\ ratis!SegmentedRaftLogWorker_asyncFlushOutStream_Fail(s)
    /\ faultCounters' = [faultCounters EXCEPT !.asyncFlushBug = @ + 1]

MCSegmentedRaftLogWorker_asyncFlushOutStream_CompleteLateOrFailed(s) ==
    /\ faultCounters.asyncFlushBug < MaxAsyncFlushBugLimit
    /\ ratis!SegmentedRaftLogWorker_asyncFlushOutStream_CompleteLateOrFailed(s)
    /\ faultCounters' = [faultCounters EXCEPT !.asyncFlushBug = @ + 1]

MCCrashAndRecover(s) ==
    /\ faultCounters.crash < MaxCrashLimit
    /\ ratis!CrashAndRecover(s)
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

MCRaftStorageImpl_formatEmptyStorage(s) ==
    /\ faultCounters.format < MaxFormatLimit
    /\ ratis!RaftStorageImpl_formatEmptyStorage(s)
    /\ faultCounters' = [faultCounters EXCEPT !.format = @ + 1]

MCLeaderStateImpl_sendAppendEntries(l, f, idx) ==
    /\ faultCounters.message < MaxMessageLimit
    /\ ratis!LeaderStateImpl_sendAppendEntries(l, f, idx)
    /\ faultCounters' = [faultCounters EXCEPT !.message = @ + 1]

MCLoseMessage(m) ==
    /\ faultCounters.message < MaxMessageLimit
    /\ ratis!LoseMessage(m)
    /\ faultCounters' = [faultCounters EXCEPT !.message = @ + 1]

MCSnapshotInstallationHandler_notifyStateMachineToInstallSnapshot(f, l, idx) ==
    /\ faultCounters.snapshot < MaxSnapshotLimit
    /\ ratis!SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot(f, l, idx)
    /\ faultCounters' = [faultCounters EXCEPT !.snapshot = @ + 1]

MCSnapshotInstallationHandler_checkAndInstallSnapshot_AppendChunk(f, idx) ==
    /\ faultCounters.snapshot < MaxSnapshotLimit
    /\ ratis!SnapshotInstallationHandler_checkAndInstallSnapshot_AppendChunk(f, idx)
    /\ faultCounters' = [faultCounters EXCEPT !.snapshot = @ + 1]

MCRaftServerImpl_appendEntriesAsync_AcceptDuringSnapshotFault(f, m) ==
    /\ faultCounters.snapshotBug < MaxSnapshotBugLimit
    /\ ratis!RaftServerImpl_appendEntriesAsync_AcceptDuringSnapshotFault(f, m)
    /\ faultCounters' = [faultCounters EXCEPT !.snapshotBug = @ + 1]

MCRaftServerImpl_sendReadIndexAsync(f, idx) ==
    /\ faultCounters.read < MaxReadLimit
    /\ ratis!RaftServerImpl_sendReadIndexAsync(f, idx)
    /\ faultCounters' = [faultCounters EXCEPT !.read = @ + 1]

MCLeaderStateImpl_getReadIndex_LeaseFastPath(l, idx) ==
    /\ faultCounters.read < MaxReadLimit
    /\ ratis!LeaderStateImpl_getReadIndex_LeaseFastPath(l, idx)
    /\ faultCounters' = [faultCounters EXCEPT !.read = @ + 1]

MCLeaderLease_enableForTarget(l) ==
    /\ faultCounters.lease < MaxLeaseLimit
    /\ ratis!LeaderLease_enableForTarget(l)
    /\ faultCounters' = [faultCounters EXCEPT !.lease = @ + 1]

MCLogAppenderDefault_receiveAppendEntriesReply_Timestamp(l, f, result) ==
    /\ faultCounters.lease < MaxLeaseLimit
    /\ ratis!LogAppenderDefault_receiveAppendEntriesReply_Timestamp(l, f, result)
    /\ faultCounters' = [faultCounters EXCEPT !.lease = @ + 1]

MCLeaderStateImpl_startSetConfiguration(l, p) ==
    /\ faultCounters.config < MaxConfigLimit
    /\ ratis!LeaderStateImpl_startSetConfiguration(l, p)
    /\ faultCounters' = [faultCounters EXCEPT !.config = @ + 1]

MCLeaderStateImpl_markAttemptedSnapshot(l, p) ==
    /\ faultCounters.config < MaxConfigLimit
    /\ ratis!LeaderStateImpl_markAttemptedSnapshot(l, p)
    /\ faultCounters' = [faultCounters EXCEPT !.config = @ + 1]

MCServerState_updateConfiguration_BeforeAppendDurable(f, p) ==
    /\ faultCounters.config < MaxConfigLimit
    /\ ratis!ServerState_updateConfiguration_BeforeAppendDurable(f, p)
    /\ faultCounters' = [faultCounters EXCEPT !.config = @ + 1]

MCLeaderStateImpl_commitConfigWithoutOldMajorityFault(l) ==
    /\ faultCounters.configBug < MaxConfigBugLimit
    /\ ratis!LeaderStateImpl_commitConfigWithoutOldMajorityFault(l)
    /\ faultCounters' = [faultCounters EXCEPT !.configBug = @ + 1]

\* --------------------------------------------------------------------------
\* Unbounded reactive actions.
\* --------------------------------------------------------------------------

MCRaftServerImpl_requestVote_Grant(v, m) ==
    /\ ratis!RaftServerImpl_requestVote_Grant(v, m)
    /\ UNCHANGED faultVars

MCRaftServerImpl_requestVote_Reject(v, m) ==
    /\ ratis!RaftServerImpl_requestVote_Reject(v, m)
    /\ UNCHANGED faultVars

MCLeaderElection_waitForResults(c) ==
    /\ ratis!LeaderElection_waitForResults(c)
    /\ UNCHANGED faultVars

MCSegmentedRaftLogWorker_WriteLog_execute(s, idx) ==
    /\ ratis!SegmentedRaftLogWorker_WriteLog_execute(s, idx)
    /\ UNCHANGED faultVars

MCSegmentedRaftLogWorker_asyncFlushOutStream_Complete(s) ==
    /\ ratis!SegmentedRaftLogWorker_asyncFlushOutStream_Complete(s)
    /\ UNCHANGED faultVars

MCLeaderStateImpl_updateCommit(s, idx) ==
    /\ ratis!LeaderStateImpl_updateCommit(s, idx)
    /\ UNCHANGED faultVars

MCRaftLogBase_appendMetadata(s) ==
    /\ ratis!RaftLogBase_appendMetadata(s)
    /\ UNCHANGED faultVars

MCRaftServerImpl_appendEntriesAsync_RejectSnapshot(f, m) ==
    /\ ratis!RaftServerImpl_appendEntriesAsync_RejectSnapshot(f, m)
    /\ UNCHANGED faultVars

MCRaftServerImpl_appendEntriesAsync_Success(f, m) ==
    /\ ratis!RaftServerImpl_appendEntriesAsync_Success(f, m)
    /\ UNCHANGED faultVars

MCSnapshotInstallationHandler_checkAndInstallSnapshot_FinalChunkPublish(f) ==
    /\ ratis!SnapshotInstallationHandler_checkAndInstallSnapshot_FinalChunkPublish(f)
    /\ UNCHANGED faultVars

MCSnapshotInstallationHandler_notifyStateMachine_Complete(f) ==
    /\ ratis!SnapshotInstallationHandler_notifyStateMachine_Complete(f)
    /\ UNCHANGED faultVars

MCLeaderLease_extend(l) ==
    /\ ratis!LeaderLease_extend(l)
    /\ UNCHANGED faultVars

MCLogAppenderDefault_handleReply_NotLeaderOrHigherTerm(l) ==
    /\ ratis!LogAppenderDefault_handleReply_NotLeaderOrHigherTerm(l)
    /\ UNCHANGED faultVars

MCLeaderStateImpl_stop(l) ==
    /\ ratis!LeaderStateImpl_stop(l)
    /\ UNCHANGED faultVars

MCLeaderStateImpl_checkProgress_CaughtUp(l, p) ==
    /\ ratis!LeaderStateImpl_checkProgress_CaughtUp(l, p)
    /\ UNCHANGED faultVars

MCLeaderStateImpl_applyOldNewConf(l) ==
    /\ ratis!LeaderStateImpl_applyOldNewConf(l)
    /\ UNCHANGED faultVars

MCLeaderStateImpl_configAck(l, p) ==
    /\ ratis!LeaderStateImpl_configAck(l, p)
    /\ UNCHANGED faultVars

MCLeaderStateImpl_commitOldNewConf(l) ==
    /\ ratis!LeaderStateImpl_commitOldNewConf(l)
    /\ UNCHANGED faultVars

MCNext ==
    \/ \E s \in Server : MCServerState_initElection_ELECTION(s)
    \/ \E s \in Server, kind \in VoteKinds : MCServerProtoUtils_setVoteReplyLastEntryKind(s, kind)
    \/ \E c \in Server, v \in Server : MCLeaderElection_submitRequestVote(c, v)
    \/ \E v \in Server, m \in messages : MCRaftServerImpl_requestVote_Grant(v, m)
    \/ \E v \in Server, m \in messages : MCRaftServerImpl_requestVote_Reject(v, m)
    \/ \E c \in Server : MCLeaderElection_waitForResults(c)
    \/ \E s \in Server, idx \in Index, kind \in {"normal", "config"}, p \in Server :
        MCRaftLogBase_appendEntry_CacheAndQueue(s, idx, kind, p)
    \/ \E s \in Server, idx \in Index : MCSegmentedRaftLogWorker_WriteLog_execute(s, idx)
    \/ \E s \in Server : MCSegmentedRaftLogWorker_flushIfNecessary_Start(s)
    \/ \E s \in Server : MCSegmentedRaftLogWorker_asyncFlushOutStream_Fail(s)
    \/ \E s \in Server : MCSegmentedRaftLogWorker_asyncFlushOutStream_Complete(s)
    \/ \E s \in Server : MCSegmentedRaftLogWorker_asyncFlushOutStream_CompleteLateOrFailed(s)
    \/ \E s \in Server, idx \in Index : MCLeaderStateImpl_updateCommit(s, idx)
    \/ \E s \in Server : MCRaftLogBase_appendMetadata(s)
    \/ \E s \in Server : MCCrashAndRecover(s)
    \/ \E s \in Server : MCRaftStorageImpl_formatEmptyStorage(s)
    \/ \E l \in Server, f \in Server, idx \in IndexOrInvalid : MCLeaderStateImpl_sendAppendEntries(l, f, idx)
    \/ \E f \in Server, m \in messages : MCRaftServerImpl_appendEntriesAsync_RejectSnapshot(f, m)
    \/ \E f \in Server, m \in messages : MCRaftServerImpl_appendEntriesAsync_Success(f, m)
    \/ \E f \in Server, l \in Server, idx \in Index : MCSnapshotInstallationHandler_notifyStateMachineToInstallSnapshot(f, l, idx)
    \/ \E f \in Server, idx \in Index : MCSnapshotInstallationHandler_checkAndInstallSnapshot_AppendChunk(f, idx)
    \/ \E f \in Server : MCSnapshotInstallationHandler_checkAndInstallSnapshot_FinalChunkPublish(f)
    \/ \E f \in Server : MCSnapshotInstallationHandler_notifyStateMachine_Complete(f)
    \/ \E f \in Server, idx \in Index : MCRaftServerImpl_sendReadIndexAsync(f, idx)
    \/ \E l \in Server, idx \in Index : MCLeaderStateImpl_getReadIndex_LeaseFastPath(l, idx)
    \/ \E l \in Server : MCLeaderLease_enableForTarget(l)
    \/ \E l \in Server, f \in Server, result \in {"SUCCESS", "NOT_LEADER", "HIGHER_TERM", "INCONSISTENCY"} :
        MCLogAppenderDefault_receiveAppendEntriesReply_Timestamp(l, f, result)
    \/ \E l \in Server : MCLeaderLease_extend(l)
    \/ \E l \in Server : MCLogAppenderDefault_handleReply_NotLeaderOrHigherTerm(l)
    \/ \E l \in Server : MCLeaderStateImpl_stop(l)
    \/ \E l \in Server, p \in Server : MCLeaderStateImpl_startSetConfiguration(l, p)
    \/ \E l \in Server, p \in Server : MCLeaderStateImpl_markAttemptedSnapshot(l, p)
    \/ \E l \in Server, p \in Server : MCLeaderStateImpl_checkProgress_CaughtUp(l, p)
    \/ \E l \in Server : MCLeaderStateImpl_applyOldNewConf(l)
    \/ \E l \in Server, p \in Server : MCLeaderStateImpl_configAck(l, p)
    \/ \E l \in Server : MCLeaderStateImpl_commitOldNewConf(l)
    \/ \E f \in Server, p \in Server : MCServerState_updateConfiguration_BeforeAppendDurable(f, p)
    \/ \E m \in messages : MCLoseMessage(m)

MCSpec == MCInit /\ [][MCNext]_mcVars

Symmetry == Permutations(Server)
ModelView == vars
MsgBufferConstraint == Cardinality(messages) <= MaxMsgBufferLimit

MCTypeOK ==
    /\ TypeOK
    /\ faultCounters \in [
        election      : 0..MaxElectionLimit,
        append        : 0..MaxAppendLimit,
        flush         : 0..MaxFlushLimit,
        asyncFlushBug : 0..MaxAsyncFlushBugLimit,
        crash         : 0..MaxCrashLimit,
        format        : 0..MaxFormatLimit,
        message       : 0..MaxMessageLimit,
        snapshot      : 0..MaxSnapshotLimit,
        snapshotBug   : 0..MaxSnapshotBugLimit,
        read          : 0..MaxReadLimit,
        lease         : 0..MaxLeaseLimit,
        config        : 0..MaxConfigLimit,
        configBug     : 0..MaxConfigBugLimit ]

FlushIndexWithinPublishedWrites ==
    \A s \in Server :
        flushIndex[s] <= Max2(lastWrittenIndex[s], snapshotIndex[s])

CommitMonotoneStructural ==
    \A s \in Server :
        commitIndex[s] >= -1 /\ metadataCommitIndex[s] >= -1

ConfigurationSetsKnown ==
    \A s \in Server :
        /\ currentConf[s] \subseteq Server
        /\ oldConf[s] \subseteq Server
        /\ durableConf[s] \subseteq Server

SnapshotBoundariesOrdered ==
    \A s \in Server :
        /\ installedSnapshot[s] <= snapshotIndex[s] \/ installedSnapshot[s] = -1
        /\ logStartIndex[s] >= 0

=============================================================================
