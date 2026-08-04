------------------------------ MODULE MC ------------------------------
\* Model-checking wrapper for ratis-grpc replication.
\*
\* The base spec defines implementation-faithful actions.  This wrapper bounds
\* actions that introduce nondeterminism: sends, timeouts, resets, generated
\* replies, snapshot outcomes, staging/restart injections, and transport
\* cancellation/backpressure.  Reply handlers, commit advancement, and staging
\* checks remain reactive and unbounded.

EXTENDS base

CONSTANTS
    SendLimit,
    HeartbeatLimit,
    TimeoutLimit,
    StreamResetLimit,
    ReconnectLimit,
    ReplyLimit,
    SnapshotLimit,
    StagingLimit,
    RestartLimit,
    BackpressureLimit,
    CompactLimit,
    MaxReplyQueueLimit,
    MaxPendingLimit

VARIABLE faultCounters

faultVars == <<faultCounters>>
mcVars == <<vars, faultCounters>>

MCInit ==
    /\ Init
    /\ faultCounters =
        [ send |-> 0,
          heartbeat |-> 0,
          timeout |-> 0,
          streamReset |-> 0,
          reconnect |-> 0,
          reply |-> 0,
          snapshot |-> 0,
          staging |-> 0,
          restart |-> 0,
          backpressure |-> 0,
          compact |-> 0 ]

----
\* Counter-bounded wrappers.
----

MCSendAppendData(f) ==
    /\ faultCounters.send < SendLimit
    /\ SendAppendData(f)
    /\ faultCounters' = [faultCounters EXCEPT !.send = @ + 1]

MCAppendAfterSnapshot(f) ==
    /\ faultCounters.send < SendLimit
    /\ AppendAfterSnapshot(f)
    /\ faultCounters' = [faultCounters EXCEPT !.send = @ + 1]

MCSendHeartbeat(f) ==
    /\ faultCounters.heartbeat < HeartbeatLimit
    /\ SendHeartbeat(f)
    /\ faultCounters' = [faultCounters EXCEPT !.heartbeat = @ + 1]

MCTimeoutAppend(f, q) ==
    /\ faultCounters.timeout < TimeoutLimit
    /\ TimeoutAppend(f, q)
    /\ faultCounters' = [faultCounters EXCEPT !.timeout = @ + 1]

MCStreamErrorReset(f) ==
    /\ faultCounters.streamReset < StreamResetLimit
    /\ StreamErrorReset(f)
    /\ faultCounters' = [faultCounters EXCEPT !.streamReset = @ + 1]

MCStreamCompleteReset(f) ==
    /\ faultCounters.streamReset < StreamResetLimit
    /\ StreamCompleteReset(f)
    /\ faultCounters' = [faultCounters EXCEPT !.streamReset = @ + 1]

MCReconnect(f) ==
    /\ faultCounters.reconnect < ReconnectLimit
    /\ Reconnect(f)
    /\ faultCounters' = [faultCounters EXCEPT !.reconnect = @ + 1]

MCFollowerAppendSuccess(f, req) ==
    /\ faultCounters.reply < ReplyLimit
    /\ FollowerAppendSuccess(f, req)
    /\ faultCounters' = [faultCounters EXCEPT !.reply = @ + 1]

MCFollowerAppendInconsistency(f, req, rn) ==
    /\ faultCounters.reply < ReplyLimit
    /\ FollowerAppendInconsistency(f, req, rn)
    /\ faultCounters' = [faultCounters EXCEPT !.reply = @ + 1]

MCFollowerSnapshotInProgress(f, req) ==
    /\ faultCounters.reply < ReplyLimit
    /\ FollowerSnapshotInProgress(f, req)
    /\ faultCounters' = [faultCounters EXCEPT !.reply = @ + 1]

MCSnapshotChunkSuccess(f) ==
    /\ faultCounters.reply < ReplyLimit
    /\ SnapshotChunkSuccess(f)
    /\ faultCounters' = [faultCounters EXCEPT !.reply = @ + 1]

MCSnapshotChunkInProgress(f) ==
    /\ faultCounters.reply < ReplyLimit
    /\ SnapshotChunkInProgress(f)
    /\ faultCounters' = [faultCounters EXCEPT !.reply = @ + 1]

MCCompactLeaderLog(newStart) ==
    /\ faultCounters.compact < CompactLimit
    /\ CompactLeaderLog(newStart)
    /\ faultCounters' = [faultCounters EXCEPT !.compact = @ + 1]

MCTriggerSnapshot(f) ==
    /\ faultCounters.snapshot < SnapshotLimit
    /\ TriggerSnapshot(f)
    /\ faultCounters' = [faultCounters EXCEPT !.snapshot = @ + 1]

MCSendSnapshotChunk(f) ==
    /\ faultCounters.snapshot < SnapshotLimit
    /\ SendSnapshotChunk(f)
    /\ faultCounters' = [faultCounters EXCEPT !.snapshot = @ + 1]

MCSnapshotInstalled(f, s) ==
    /\ faultCounters.snapshot < SnapshotLimit
    /\ SnapshotInstalled(f, s)
    /\ faultCounters' = [faultCounters EXCEPT !.snapshot = @ + 1]

MCSnapshotAlreadyInstalled(f, s) ==
    /\ faultCounters.snapshot < SnapshotLimit
    /\ SnapshotAlreadyInstalled(f, s)
    /\ faultCounters' = [faultCounters EXCEPT !.snapshot = @ + 1]

MCSnapshotUnavailableOrExpired(f, result) ==
    /\ faultCounters.snapshot < SnapshotLimit
    /\ SnapshotUnavailableOrExpired(f, result)
    /\ faultCounters' = [faultCounters EXCEPT !.snapshot = @ + 1]

MCAddStagingPeer(f) ==
    /\ faultCounters.staging < StagingLimit
    /\ AddStagingPeer(f)
    /\ faultCounters' = [faultCounters EXCEPT !.staging = @ + 1]

MCSnapshotAttemptForStagingPeer(f) ==
    /\ faultCounters.staging < StagingLimit
    /\ SnapshotAttemptForStagingPeer(f)
    /\ faultCounters' = [faultCounters EXCEPT !.staging = @ + 1]

MCRestartAppender(f) ==
    /\ faultCounters.restart < RestartLimit
    /\ RestartAppender(f)
    /\ faultCounters' = [faultCounters EXCEPT !.restart = @ + 1]

MCSetStreamReady(f, ready) ==
    /\ faultCounters.backpressure < BackpressureLimit
    /\ SetStreamReady(f, ready)
    /\ faultCounters' = [faultCounters EXCEPT !.backpressure = @ + 1]

MCCancelAppendStream(f) ==
    /\ faultCounters.backpressure < BackpressureLimit
    /\ CancelAppendStream(f)
    /\ faultCounters' = [faultCounters EXCEPT !.backpressure = @ + 1]

MCSnapshotBackpressureBlock(f) ==
    /\ faultCounters.backpressure < BackpressureLimit
    /\ SnapshotBackpressureBlock(f)
    /\ faultCounters' = [faultCounters EXCEPT !.backpressure = @ + 1]

MCResourceExhausted ==
    /\ faultCounters.backpressure < BackpressureLimit
    /\ ResourceExhausted
    /\ faultCounters' = [faultCounters EXCEPT !.backpressure = @ + 1]

----
\* Reactive wrappers.
----

MCReceiveSuccessWithRequest(f, r) ==
    /\ ReceiveSuccessWithRequest(f, r)
    /\ UNCHANGED faultVars

MCReceiveSuccessWithoutRequest(f, r) ==
    /\ ReceiveSuccessWithoutRequest(f, r)
    /\ UNCHANGED faultVars

MCReceiveInconsistencyWithRequest(f, r) ==
    /\ ReceiveInconsistencyWithRequest(f, r)
    /\ UNCHANGED faultVars

MCReceiveInconsistencyWithoutRequest(f, r) ==
    /\ ReceiveInconsistencyWithoutRequest(f, r)
    /\ UNCHANGED faultVars

MCOldAppendReplyAfterSnapshot(f, r) ==
    /\ OldAppendReplyAfterSnapshot(f, r)
    /\ UNCHANGED faultVars

MCAppendSuccessForStagingPeer(f, r) ==
    /\ AppendSuccessForStagingPeer(f, r)
    /\ UNCHANGED faultVars

MCCheckProgress(f) ==
    /\ CheckProgress(f)
    /\ UNCHANGED faultVars

MCApplyStagingConfiguration ==
    /\ ApplyStagingConfiguration
    /\ UNCHANGED faultVars

MCAdvanceCommitIndex(n) ==
    /\ AdvanceCommitIndex(n)
    /\ UNCHANGED faultVars

----
\* Next relation.
----

MCNext ==
    \/ \E f \in Followers : MCSendAppendData(f)
    \/ \E f \in Followers : MCAppendAfterSnapshot(f)
    \/ \E f \in Followers : MCSendHeartbeat(f)
    \/ \E f \in Followers : \E q \in pending[f] : MCTimeoutAppend(f, q)
    \/ \E f \in Followers : MCStreamErrorReset(f)
    \/ \E f \in Followers : MCStreamCompleteReset(f)
    \/ \E f \in Followers : MCReconnect(f)
    \/ \E f \in Followers : \E req \in sentRequests[f] : MCFollowerAppendSuccess(f, req)
    \/ \E f \in Followers : \E req \in sentRequests[f] : \E rn \in 0..MaxLogIndex :
            MCFollowerAppendInconsistency(f, req, rn)
    \/ \E f \in Followers : \E req \in sentRequests[f] : MCFollowerSnapshotInProgress(f, req)
    \/ \E f \in Followers : MCSnapshotChunkSuccess(f)
    \/ \E f \in Followers : MCSnapshotChunkInProgress(f)
    \/ \E f \in Followers : \E r \in replyQueue : MCReceiveSuccessWithRequest(f, r)
    \/ \E f \in Followers : \E r \in replyQueue : MCReceiveSuccessWithoutRequest(f, r)
    \/ \E f \in Followers : \E r \in replyQueue : MCReceiveInconsistencyWithRequest(f, r)
    \/ \E f \in Followers : \E r \in replyQueue : MCReceiveInconsistencyWithoutRequest(f, r)
    \/ \E f \in Followers : \E r \in replyQueue : MCOldAppendReplyAfterSnapshot(f, r)
    \/ \E newStart \in (leaderStartIndex + 1)..(leaderLastIndex + 1) : MCCompactLeaderLog(newStart)
    \/ \E f \in Followers : MCTriggerSnapshot(f)
    \/ \E f \in Followers : MCSendSnapshotChunk(f)
    \/ \E f \in Followers : \E s \in 0..MaxLogIndex : MCSnapshotInstalled(f, s)
    \/ \E f \in Followers : \E s \in 0..MaxLogIndex : MCSnapshotAlreadyInstalled(f, s)
    \/ \E f \in Followers : \E result \in {Unavailable, Expired} :
            MCSnapshotUnavailableOrExpired(f, result)
    \/ \E f \in Followers : MCAddStagingPeer(f)
    \/ \E f \in Followers : MCRestartAppender(f)
    \/ \E f \in Followers : \E r \in replyQueue : MCAppendSuccessForStagingPeer(f, r)
    \/ \E f \in Followers : MCSnapshotAttemptForStagingPeer(f)
    \/ \E f \in Followers : MCCheckProgress(f)
    \/ MCApplyStagingConfiguration
    \/ \E f \in Followers : \E ready \in BOOLEAN : MCSetStreamReady(f, ready)
    \/ \E f \in Followers : MCCancelAppendStream(f)
    \/ \E f \in Followers : MCSnapshotBackpressureBlock(f)
    \/ MCResourceExhausted
    \/ \E n \in (commitIndex + 1)..leaderLastIndex : MCAdvanceCommitIndex(n)

MCSpec == MCInit /\ [][MCNext]_mcVars

\* Used by the staging liveness hunt so that enabled checkProgress eventually
\* fires when its catch-up predicate is continuously true.
MCLivenessSpec ==
    MCSpec /\ \A f \in Followers : WF_mcVars(MCCheckProgress(f))

----
\* MC constraints and structural invariants.
----

MCQueueConstraint ==
    /\ Cardinality(replyQueue) <= MaxReplyQueueLimit
    /\ \A f \in Followers : Cardinality(pending[f]) <= MaxPendingLimit

MCTypeOK ==
    /\ TypeOK
    /\ faultCounters \in
        [ send: 0..SendLimit,
          heartbeat: 0..HeartbeatLimit,
          timeout: 0..TimeoutLimit,
          streamReset: 0..StreamResetLimit,
          reconnect: 0..ReconnectLimit,
          reply: 0..ReplyLimit,
          snapshot: 0..SnapshotLimit,
          staging: 0..StagingLimit,
          restart: 0..RestartLimit,
          backpressure: 0..BackpressureLimit,
          compact: 0..CompactLimit ]

MCStructuralProgressBounds ==
    /\ commitIndex <= leaderLastIndex
    /\ commitProofIndex <= leaderLastIndex
    /\ leaderStartIndex <= leaderLastIndex + 1
    /\ \A f \in Followers :
        /\ matchIndex[f] <= leaderLastIndex
        /\ snapshotIndex[f] <= leaderLastIndex
        /\ nextIndex[f] <= leaderLastIndex + 1

=============================================================================
