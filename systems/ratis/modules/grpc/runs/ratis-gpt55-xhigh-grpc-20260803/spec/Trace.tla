------------------------------ MODULE Trace ------------------------------
\* Trace-validation spec for ratis-grpc replication.
\*
\* Replays implementation trace events against base.tla.  Network reply
\* generation can be silent, but only when the next trace event is a reply
\* handler that needs that reply in replyQueue.

EXTENDS base, Json, IOUtils, TLC, Sequences

----
\* Trace loading.
----

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTraceLog == ndJsonDeserialize(JsonFile)
TraceLog == SelectSeq(RawTraceLog, LAMBDA e : ~("tag" \in DOMAIN e) \/ e.tag = "ratis-grpc")

VARIABLE l

traceVars == <<vars, l>>

logline == TraceLog[l]

Has(obj, field) == field \in DOMAIN obj
StateOf(e) == IF Has(e, "state") THEN e.state ELSE [empty |-> TRUE]

----
\* Event predicates and field extraction.
----

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

IsFollowerEvent(name, f) ==
    /\ IsEvent(name)
    /\ logline.follower = f

IsLeaderEvent(name) ==
    /\ IsEvent(name)
    /\ logline.node = LeaderNode

ReplyResultOf(e) ==
    CASE e.result = "SUCCESS" -> Success
      [] e.result = "INCONSISTENCY" -> Inconsistency
      [] e.result = "NOT_LEADER" -> NotLeader

ReplyKindOf(e) ==
    IF Has(e, "isHeartbeat") /\ e.isHeartbeat THEN Heartbeat ELSE Data

ReadyOf(e) ==
    IF Has(e, "ready") THEN e.ready ELSE TRUE

SnapshotResultOf(e) ==
    CASE e.result = "SNAPSHOT_UNAVAILABLE" -> Unavailable
      [] e.result = "SNAPSHOT_EXPIRED" -> Expired

RequestMatchesLogline(req) ==
    /\ IF Has(logline, "callId") THEN req.callId = logline.callId ELSE TRUE
    /\ IF Has(logline, "isHeartbeat") THEN req.kind = ReplyKindOf(logline) ELSE TRUE
    /\ IF Has(logline, "firstIndex") /\ logline.firstIndex >= 0 THEN req.firstIndex = logline.firstIndex ELSE TRUE
    /\ IF Has(logline, "lastIndex") /\ logline.lastIndex >= 0 THEN req.lastIndex = logline.lastIndex ELSE TRUE
    /\ IF Has(logline, "prevIndex") /\ logline.prevIndex >= 0 THEN req.prevIndex = logline.prevIndex ELSE TRUE

ReplyMatchesLogline(r) ==
    /\ IF Has(logline, "callId") THEN r.callId = logline.callId ELSE TRUE
    /\ IF Has(logline, "result") THEN r.result = ReplyResultOf(logline) ELSE TRUE
    /\ IF Has(logline, "isHeartbeat") THEN r.kind = ReplyKindOf(logline) ELSE TRUE
    /\ IF Has(logline, "firstIndex") /\ logline.firstIndex >= 0 THEN r.firstIndex = logline.firstIndex ELSE TRUE
    /\ IF Has(logline, "lastIndex") /\ logline.lastIndex >= 0 THEN r.lastIndex = logline.lastIndex ELSE TRUE
    /\ IF Has(logline, "prevIndex") /\ logline.prevIndex >= 0 THEN r.prevIndex = logline.prevIndex ELSE TRUE
    /\ IF Has(logline, "matchIndex") THEN r.match = logline.matchIndex ELSE TRUE
    /\ IF Has(logline, "replyNextIndex") THEN r.next = logline.replyNextIndex ELSE TRUE

----
\* Post-state validation.
----

ValidateFollowerPostState(f) ==
    LET s == StateOf(logline) IN
        /\ IF Has(s, "matchIndex") THEN matchIndex'[f] = s.matchIndex ELSE TRUE
        /\ IF Has(s, "nextIndex") THEN nextIndex'[f] = s.nextIndex ELSE TRUE
        /\ IF Has(s, "snapshotIndex") THEN snapshotIndex'[f] = s.snapshotIndex ELSE TRUE
        /\ IF Has(s, "attemptedSnapshot") THEN attemptedSnapshot'[f] = s.attemptedSnapshot ELSE TRUE
        /\ IF Has(s, "caughtUp") THEN caughtUp'[f] = s.caughtUp ELSE TRUE
        /\ IF Has(s, "recentResponse") THEN
              recentResponse'[f] = IF s.recentResponse = "Fresh" THEN Fresh ELSE Stale
           ELSE TRUE
        /\ IF Has(s, "streamEpoch") THEN streamEpoch'[f] = s.streamEpoch ELSE TRUE
        /\ IF Has(s, "streamActive") THEN streamActive'[f] = s.streamActive ELSE TRUE
        /\ IF Has(s, "pendingCount") THEN Cardinality(pending'[f]) = s.pendingCount ELSE TRUE
        /\ IF Has(s, "snapshotState") THEN
              snapshotState'[f] =
                CASE s.snapshotState = "SnapshotNone" -> SnapshotNone
                  [] s.snapshotState = "SendingChunks" -> SendingChunks
                  [] s.snapshotState = "FollowerInstalling" -> FollowerInstalling
                  [] s.snapshotState = "Installed" -> Installed
                  [] s.snapshotState = "Unavailable" -> Unavailable
                  [] s.snapshotState = "Expired" -> Expired
           ELSE TRUE
        /\ IF Has(s, "outstandingChunks") THEN outstandingChunks'[f] = s.outstandingChunks ELSE TRUE
        /\ IF Has(s, "streamReady") THEN streamReady'[f] = s.streamReady ELSE TRUE
        /\ IF Has(s, "cancelled") THEN cancelled'[f] = s.cancelled ELSE TRUE

ValidateFollowerPostStateExceptCaughtUp(f) ==
    LET s == StateOf(logline) IN
        /\ IF Has(s, "matchIndex") THEN matchIndex'[f] = s.matchIndex ELSE TRUE
        /\ IF Has(s, "nextIndex") THEN nextIndex'[f] = s.nextIndex ELSE TRUE
        /\ IF Has(s, "snapshotIndex") THEN snapshotIndex'[f] = s.snapshotIndex ELSE TRUE
        /\ IF Has(s, "attemptedSnapshot") THEN attemptedSnapshot'[f] = s.attemptedSnapshot ELSE TRUE
        /\ IF Has(s, "recentResponse") THEN
              recentResponse'[f] = IF s.recentResponse = "Fresh" THEN Fresh ELSE Stale
           ELSE TRUE
        /\ IF Has(s, "streamEpoch") THEN streamEpoch'[f] = s.streamEpoch ELSE TRUE
        /\ IF Has(s, "streamActive") THEN streamActive'[f] = s.streamActive ELSE TRUE
        /\ IF Has(s, "pendingCount") THEN Cardinality(pending'[f]) = s.pendingCount ELSE TRUE
        /\ IF Has(s, "snapshotState") THEN
              snapshotState'[f] =
                CASE s.snapshotState = "SnapshotNone" -> SnapshotNone
                  [] s.snapshotState = "SendingChunks" -> SendingChunks
                  [] s.snapshotState = "FollowerInstalling" -> FollowerInstalling
                  [] s.snapshotState = "Installed" -> Installed
                  [] s.snapshotState = "Unavailable" -> Unavailable
                  [] s.snapshotState = "Expired" -> Expired
           ELSE TRUE
        /\ IF Has(s, "outstandingChunks") THEN outstandingChunks'[f] = s.outstandingChunks ELSE TRUE
        /\ IF Has(s, "streamReady") THEN streamReady'[f] = s.streamReady ELSE TRUE
        /\ IF Has(s, "cancelled") THEN cancelled'[f] = s.cancelled ELSE TRUE

ValidateLeaderPostState ==
    LET s == StateOf(logline) IN
        /\ IF Has(s, "commitIndex") THEN commitIndex' = s.commitIndex ELSE TRUE
        /\ IF Has(s, "commitProofIndex") THEN commitProofIndex' = s.commitProofIndex ELSE TRUE
        /\ IF Has(s, "leaderStartIndex") THEN leaderStartIndex' = s.leaderStartIndex ELSE TRUE
        /\ IF Has(s, "leaderLastIndex") THEN leaderLastIndex' = s.leaderLastIndex ELSE TRUE
        /\ IF Has(s, "replyQueueCount") THEN Cardinality(replyQueue') = s.replyQueueCount ELSE TRUE

ValidatePostState(f) ==
    /\ ValidateFollowerPostState(f)
    /\ ValidateLeaderPostState

ValidateObservedStreamPostState(f) ==
    LET s == StateOf(logline) IN
        /\ IF Has(s, "streamEpoch") THEN streamEpoch'[f] = s.streamEpoch ELSE TRUE
        /\ IF Has(s, "streamReady") THEN streamReady'[f] = s.streamReady ELSE TRUE
        /\ IF Has(s, "cancelled") THEN cancelled'[f] = s.cancelled ELSE TRUE

----
\* Trace initialization.
----

TraceInit ==
    /\ Init
    /\ l = 1

----
\* Trace wrappers for base actions.
----

TraceSendAppendData(f) ==
    /\ IsFollowerEvent("SendAppendData", f)
    /\ LET last == IF Has(logline, "lastIndex") THEN logline.lastIndex ELSE nextIndex[f] IN
        \/ SendAppendDataRangeWithCallId(f, logline.callId, last)
        \/ \E r \in replyQueue :
            SendAppendDataRangeAfterObservedPendingRemoval(f, logline.callId, last, r)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceAppendAfterSnapshot(f) ==
    /\ IsFollowerEvent("AppendAfterSnapshot", f)
    /\ AppendAfterSnapshotWithCallId(f, logline.callId)
    /\ ValidateFollowerPostStateExceptCaughtUp(f)
    /\ ValidateLeaderPostState
    /\ l' = l + 1

TraceSendHeartbeat(f) ==
    /\ IsFollowerEvent("SendHeartbeat", f)
    /\ SendHeartbeatWithCallId(f, logline.callId)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceTimeoutAppend(f) ==
    /\ IsFollowerEvent("TimeoutAppend", f)
    /\ \E q \in pending[f] : TimeoutAppend(f, q)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceStreamErrorReset(f) ==
    /\ IsFollowerEvent("StreamErrorReset", f)
    /\ \/ /\ StreamErrorReset(f)
          /\ ValidatePostState(f)
       \/ /\ ObservedStreamReset(f)
          /\ ValidateObservedStreamPostState(f)
    /\ l' = l + 1

TraceStreamCompleteReset(f) ==
    /\ IsFollowerEvent("StreamCompleteReset", f)
    /\ \/ /\ StreamCompleteReset(f)
          /\ ValidatePostState(f)
       \/ /\ ObservedStreamReset(f)
          /\ ValidateObservedStreamPostState(f)
    /\ l' = l + 1

TraceReconnect(f) ==
    /\ IsFollowerEvent("Reconnect", f)
    /\ LET s == StateOf(logline) IN
        IF Has(s, "pendingCount") /\ s.pendingCount = Cardinality(pending[f]) + 1
        THEN ReconnectWithPreparedHeartbeat(f, 0)
        ELSE Reconnect(f)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceFollowerAppendSuccess(f) ==
    /\ IsFollowerEvent("FollowerAppendSuccess", f)
    /\ \E req \in sentRequests[f] :
        /\ RequestMatchesLogline(req)
        /\ \E rn \in Index :
            /\ IF Has(logline, "replyNextIndex") THEN rn = logline.replyNextIndex
               ELSE rn = IF req.kind = Data THEN req.lastIndex + 1 ELSE nextIndex[f]
            /\ FollowerAppendSuccessWithReplyNext(f, req, rn)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceFollowerAppendInconsistency(f) ==
    /\ IsFollowerEvent("FollowerAppendInconsistency", f)
    /\ \E req \in sentRequests[f] :
        /\ RequestMatchesLogline(req)
        /\ \E rn \in 0..MaxLogIndex :
            /\ IF Has(logline, "replyNextIndex") THEN rn = logline.replyNextIndex ELSE TRUE
            /\ FollowerAppendInconsistency(f, req, rn)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceReceiveSuccessWithRequest(f) ==
    /\ IsFollowerEvent("ReceiveSuccessWithRequest", f)
    /\ \E r \in replyQueue :
        /\ ReplyMatchesLogline(r)
        /\ ReceiveSuccessWithRequest(f, r)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceReceiveSuccessWithoutRequest(f) ==
    /\ IsFollowerEvent("ReceiveSuccessWithoutRequest", f)
    /\ \E r \in replyQueue :
        /\ ReplyMatchesLogline(r)
        /\ ReceiveSuccessWithoutRequest(f, r)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceReceiveInconsistencyWithRequest(f) ==
    /\ IsFollowerEvent("ReceiveInconsistencyWithRequest", f)
    /\ \E r \in replyQueue :
        /\ ReplyMatchesLogline(r)
        /\ ReceiveInconsistencyWithRequest(f, r)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceReceiveInconsistencyWithoutRequest(f) ==
    /\ IsFollowerEvent("ReceiveInconsistencyWithoutRequest", f)
    /\ \E r \in replyQueue :
        /\ ReplyMatchesLogline(r)
        /\ ReceiveInconsistencyWithoutRequest(f, r)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceOldAppendReplyAfterSnapshot(f) ==
    /\ IsFollowerEvent("OldAppendReplyAfterSnapshot", f)
    /\ \E r \in replyQueue :
        /\ ReplyMatchesLogline(r)
        /\ OldAppendReplyAfterSnapshot(f, r)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceCompactLeaderLog ==
    /\ IsLeaderEvent("CompactLeaderLog")
    /\ \E newStart \in (leaderStartIndex + 1)..(leaderLastIndex + 1) :
        /\ IF Has(logline, "leaderStartIndex") THEN newStart = logline.leaderStartIndex ELSE TRUE
        /\ CompactLeaderLog(newStart)
    /\ ValidateLeaderPostState
    /\ l' = l + 1

TraceTriggerSnapshot(f) ==
    /\ IsFollowerEvent("TriggerSnapshot", f)
    /\ TriggerSnapshot(f)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceSendSnapshotChunk(f) ==
    /\ IsFollowerEvent("SendSnapshotChunk", f)
    /\ SendSnapshotChunk(f)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceFollowerSnapshotInProgress(f) ==
    /\ IsFollowerEvent("FollowerSnapshotInProgress", f)
    /\ \E req \in sentRequests[f] : FollowerSnapshotInProgress(f, req)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceSnapshotInstalled(f) ==
    /\ IsFollowerEvent("SnapshotInstalled", f)
    /\ \E s \in 0..MaxLogIndex :
        /\ IF Has(logline, "snapshotIndex") THEN s = logline.snapshotIndex ELSE TRUE
        /\ SnapshotInstalled(f, s)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceSnapshotAlreadyInstalled(f) ==
    /\ IsFollowerEvent("SnapshotAlreadyInstalled", f)
    /\ \E s \in 0..MaxLogIndex :
        /\ IF Has(logline, "snapshotIndex") THEN s = logline.snapshotIndex ELSE TRUE
        /\ SnapshotAlreadyInstalled(f, s)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceSnapshotUnavailableOrExpired(f) ==
    /\ IsFollowerEvent("SnapshotUnavailableOrExpired", f)
    /\ \E result \in {Unavailable, Expired} :
        /\ IF Has(logline, "result") THEN result = SnapshotResultOf(logline) ELSE TRUE
        /\ SnapshotUnavailableOrExpired(f, result)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceAddStagingPeer(f) ==
    /\ IsFollowerEvent("AddStagingPeer", f)
    /\ AddStagingPeer(f)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceRestartAppender(f) ==
    /\ IsFollowerEvent("RestartAppender", f)
    /\ RestartAppender(f)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceAppendSuccessForStagingPeer(f) ==
    /\ IsFollowerEvent("AppendSuccessForStagingPeer", f)
    /\ \/ /\ \E r \in replyQueue :
              /\ ReplyMatchesLogline(r)
              /\ AppendSuccessForStagingPeer(f, r)
          /\ ValidateFollowerPostStateExceptCaughtUp(f)
       \/ /\ ~(\E r \in replyQueue : ReplyMatchesLogline(r))
          /\ UNCHANGED vars
          /\ ValidateFollowerPostStateExceptCaughtUp(f)
    /\ l' = l + 1

TraceSnapshotAttemptForStagingPeer(f) ==
    /\ IsFollowerEvent("SnapshotAttemptForStagingPeer", f)
    /\ SnapshotAttemptForStagingPeer(f)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceCheckProgress(f) ==
    /\ IsFollowerEvent("CheckProgress", f)
    /\ CheckProgress(f)
    /\ ValidatePostState(f)
    /\ l' = l + 1

TraceApplyStagingConfiguration ==
    /\ IsLeaderEvent("ApplyStagingConfiguration")
    /\ ApplyStagingConfiguration
    /\ ValidateLeaderPostState
    /\ l' = l + 1

TraceSetStreamReady(f) ==
    /\ IsFollowerEvent("SetStreamReady", f)
    /\ SetStreamReady(f, ReadyOf(logline))
    /\ ValidateObservedStreamPostState(f)
    /\ l' = l + 1

TraceCancelAppendStream(f) ==
    /\ IsFollowerEvent("CancelAppendStream", f)
    /\ \/ /\ CancelAppendStream(f)
          /\ ValidatePostState(f)
       \/ /\ ObservedCancelAppendStream(f)
          /\ ValidateObservedStreamPostState(f)
    /\ l' = l + 1

TraceSnapshotBackpressureBlock(f) ==
    /\ IsFollowerEvent("SnapshotBackpressureBlock", f)
    /\ SnapshotBackpressureBlock(f)
    /\ LET s == StateOf(logline) IN
        /\ IF Has(s, "outstandingChunks") THEN outstandingChunks'[f] = s.outstandingChunks ELSE TRUE
    /\ l' = l + 1

TraceResourceExhausted ==
    /\ IsLeaderEvent("ResourceExhausted")
    /\ ResourceExhausted
    /\ ValidateLeaderPostState
    /\ l' = l + 1

TraceAdvanceCommitIndex ==
    /\ IsLeaderEvent("AdvanceCommitIndex")
    /\ \E n \in (commitIndex + 1)..leaderLastIndex :
        /\ IF Has(logline, "commitIndex") THEN n = logline.commitIndex ELSE TRUE
        /\ \/ AdvanceCommitIndex(n)
           \/ AdvanceCommitIndexObserved(n)
    /\ ValidateLeaderPostState
    /\ l' = l + 1

----
\* Tightly constrained silent actions for granularity mismatch.
----

NextEventNeedsReply ==
    /\ l <= Len(TraceLog)
    /\ logline.event \in {
        "ReceiveSuccessWithRequest",
        "ReceiveSuccessWithoutRequest",
        "ReceiveInconsistencyWithRequest",
        "ReceiveInconsistencyWithoutRequest",
        "OldAppendReplyAfterSnapshot",
        "AppendSuccessForStagingPeer" }

QueuedReplyForLogline ==
    \E r \in replyQueue : ReplyMatchesLogline(r)

TraceSilentEnqueueSuccessReply ==
    /\ NextEventNeedsReply
    /\ Has(logline, "result")
    /\ logline.result = "SUCCESS"
    /\ ~QueuedReplyForLogline
    /\ \E f \in Followers :
        /\ logline.follower = f
        /\ (logline.event # "AppendSuccessForStagingPeer" \/ ~caughtUp[f])
        /\ \E req \in sentRequests[f] :
            /\ RequestMatchesLogline(req)
            /\ \E rn \in Index :
                /\ IF Has(logline, "replyNextIndex") THEN rn = logline.replyNextIndex
                   ELSE rn = IF req.kind = Data THEN req.lastIndex + 1 ELSE nextIndex[f]
                /\ FollowerAppendSuccessWithReplyNext(f, req, rn)
    /\ UNCHANGED l

TraceSilentEnqueueInconsistencyReply ==
    /\ NextEventNeedsReply
    /\ Has(logline, "result")
    /\ logline.result = "INCONSISTENCY"
    /\ ~QueuedReplyForLogline
    /\ \E f \in Followers :
        /\ logline.follower = f
        /\ \E req \in sentRequests[f] :
            /\ RequestMatchesLogline(req)
            /\ \E rn \in 0..MaxLogIndex :
                /\ IF Has(logline, "replyNextIndex") THEN rn = logline.replyNextIndex ELSE TRUE
                /\ FollowerAppendInconsistency(f, req, rn)
    /\ UNCHANGED l

TraceSilentReceiveSuccessBeforeCheckProgress ==
    /\ l <= Len(TraceLog)
    /\ logline.event = "CheckProgress"
    /\ \E f \in Followers :
        /\ logline.follower = f
        /\ ~CatchupPredicate(f)
        /\ \E r \in replyQueue :
            /\ r.result = Success
            /\ \/ ReceiveSuccessWithRequest(f, r)
               \/ ReceiveSuccessWithoutRequest(f, r)
    /\ UNCHANGED l

NextEventForFollower(f) ==
    /\ l <= Len(TraceLog)
    /\ Has(logline, "follower")
    /\ logline.follower = f

NextEventWantsOutstandingDecrease(f) ==
    LET s == StateOf(logline) IN
        /\ Has(s, "outstandingChunks")
        /\ s.outstandingChunks < outstandingChunks[f]

NextEventWantsAttemptedSnapshot(f) ==
    LET s == StateOf(logline) IN
        /\ Has(s, "attemptedSnapshot")
        /\ s.attemptedSnapshot
        /\ ~attemptedSnapshot[f]

NextEventSendSnapshotNeedsPermitRelease(f) ==
    LET s == StateOf(logline) IN
        /\ logline.event = "SendSnapshotChunk"
        /\ Has(s, "outstandingChunks")
        /\ s.outstandingChunks <= outstandingChunks[f]

TraceSilentSnapshotChunkSuccess ==
    /\ \E f \in Followers :
        /\ NextEventForFollower(f)
        /\ \/ NextEventWantsOutstandingDecrease(f)
           \/ NextEventWantsAttemptedSnapshot(f)
           \/ NextEventSendSnapshotNeedsPermitRelease(f)
        /\ SnapshotChunkSuccess(f)
    /\ UNCHANGED l

TraceSilentSnapshotChunkInProgress ==
    /\ \E f \in Followers :
        /\ NextEventForFollower(f)
        /\ NextEventWantsOutstandingDecrease(f)
        /\ ~NextEventWantsAttemptedSnapshot(f)
        /\ SnapshotChunkInProgress(f)
    /\ UNCHANGED l

TraceSilentActions ==
    \/ TraceSilentEnqueueSuccessReply
    \/ TraceSilentEnqueueInconsistencyReply
    \/ TraceSilentReceiveSuccessBeforeCheckProgress
    \/ TraceSilentSnapshotChunkSuccess
    \/ TraceSilentSnapshotChunkInProgress

TraceNext ==
    \/ \E f \in Followers : TraceSendAppendData(f)
    \/ \E f \in Followers : TraceAppendAfterSnapshot(f)
    \/ \E f \in Followers : TraceSendHeartbeat(f)
    \/ \E f \in Followers : TraceTimeoutAppend(f)
    \/ \E f \in Followers : TraceStreamErrorReset(f)
    \/ \E f \in Followers : TraceStreamCompleteReset(f)
    \/ \E f \in Followers : TraceReconnect(f)
    \/ \E f \in Followers : TraceFollowerAppendSuccess(f)
    \/ \E f \in Followers : TraceFollowerAppendInconsistency(f)
    \/ \E f \in Followers : TraceReceiveSuccessWithRequest(f)
    \/ \E f \in Followers : TraceReceiveSuccessWithoutRequest(f)
    \/ \E f \in Followers : TraceReceiveInconsistencyWithRequest(f)
    \/ \E f \in Followers : TraceReceiveInconsistencyWithoutRequest(f)
    \/ \E f \in Followers : TraceOldAppendReplyAfterSnapshot(f)
    \/ TraceCompactLeaderLog
    \/ \E f \in Followers : TraceTriggerSnapshot(f)
    \/ \E f \in Followers : TraceSendSnapshotChunk(f)
    \/ \E f \in Followers : TraceFollowerSnapshotInProgress(f)
    \/ \E f \in Followers : TraceSnapshotInstalled(f)
    \/ \E f \in Followers : TraceSnapshotAlreadyInstalled(f)
    \/ \E f \in Followers : TraceSnapshotUnavailableOrExpired(f)
    \/ \E f \in Followers : TraceAddStagingPeer(f)
    \/ \E f \in Followers : TraceRestartAppender(f)
    \/ \E f \in Followers : TraceAppendSuccessForStagingPeer(f)
    \/ \E f \in Followers : TraceSnapshotAttemptForStagingPeer(f)
    \/ \E f \in Followers : TraceCheckProgress(f)
    \/ TraceApplyStagingConfiguration
    \/ \E f \in Followers : TraceSetStreamReady(f)
    \/ \E f \in Followers : TraceCancelAppendStream(f)
    \/ \E f \in Followers : TraceSnapshotBackpressureBlock(f)
    \/ TraceResourceExhausted
    \/ TraceAdvanceCommitIndex
    \/ TraceSilentActions
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED traceVars

TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceNext)

TraceMatched == <>(l > Len(TraceLog))

=============================================================================
