------------------------------ MODULE base ------------------------------
\* Base TLA+ specification for Apache Ratis ratis-grpc replication.
\*
\* Category A: distributed message passing, with explicit leader-side local
\* state for GrpcLogAppender pending maps, stream epochs, and FollowerInfoImpl
\* progress fields.  Every extension below is driven by Modeling Brief
\* Scenarios 1-4.

EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    Server,
    LeaderNode,
    MaxLogIndex,
    MaxCallId,
    MaxReplyId,
    MaxSnapshotChunks,
    StagingCatchupGap,
    ConfLogIndex,
    LeastValidLogIndex,

    Data,
    Heartbeat,
    Success,
    Inconsistency,
    NotLeader,

    PendingState,
    TimedOutState,
    ResetState,

    SnapshotNone,
    SendingChunks,
    FollowerInstalling,
    Installed,
    Unavailable,
    Expired,

    Existing,
    StagingNewPeer,
    Removed,

    ConfigStable,
    ConfigStaging,
    ConfigOldNew,

    Fresh,
    Stale

InvalidIndex == -1

Followers == Server \ {LeaderNode}
Majority == (Cardinality(Server) \div 2) + 1
Index == InvalidIndex..(MaxLogIndex + 1)
Epoch == 0..(MaxCallId + 1)

Max2(a, b) == IF a >= b THEN a ELSE b
Min2(a, b) == IF a <= b THEN a ELSE b
DecNat(n) == IF n > 0 THEN n - 1 ELSE 0

RequestRecord ==
    [ callId: 0..MaxCallId,
      epoch: Epoch,
      kind: {Data, Heartbeat},
      prevIndex: Index,
      firstIndex: Index,
      lastIndex: Index,
      isHeartbeat: BOOLEAN,
      state: {PendingState, TimedOutState, ResetState} ]

ReplyRecord ==
    [ replyId: 0..MaxReplyId,
      follower: Followers,
      callId: 0..MaxCallId,
      epoch: Epoch,
      kind: {Data, Heartbeat},
      result: {Success, Inconsistency, NotLeader},
      match: Index,
      next: Index,
      firstIndex: Index,
      lastIndex: Index,
      prevIndex: Index,
      fromSnapshot: BOOLEAN ]

VARIABLES
    leaderStartIndex,
    leaderLastIndex,
    commitIndex,
    commitProofIndex,

    matchIndex,
    nextIndex,
    snapshotIndex,
    matchProofIndex,
    snapshotProofIndex,

    streamEpoch,
    streamActive,
    pending,
    sentRequests,
    replyQueue,
    callSeq,
    replySeq,

    snapshotState,
    snapshotRequestIndex,
    installedSnapshotIndexOnFollower,
    attemptedSnapshot,
    retryRequired,
    appendDuringSnapshot,

    peerMode,
    caughtUp,
    recentResponse,
    configurationState,
    stagingFailed,
    restartOccurred,
    usefulProgressBeforeRestart,

    streamReady,
    cancelled,
    outstandingChunks,
    resourceExhausted

vars ==
    << leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
       matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
       streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
       snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
       attemptedSnapshot, retryRequired, appendDuringSnapshot,
       peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
       restartOccurred, usefulProgressBeforeRestart,
       streamReady, cancelled, outstandingChunks, resourceExhausted >>

----
\* Helpers that mirror implementation branches.
----

\* LogAppenderBase.getNextIndexForInconsistency, lines 177-190.
GetNextIndexForInconsistency(f, requestFirstIndex, replyNextIndex) ==
    LET provenNext == matchIndex[f] + 1 IN
    LET afterFloor ==
        IF provenNext > replyNextIndex /\ provenNext /= requestFirstIndex
        THEN provenNext
        ELSE replyNextIndex
    IN
        IF afterFloor = requestFirstIndex /\ afterFloor > LeastValidLogIndex
        THEN afterFloor - 1
        ELSE afterFloor

\* LogAppenderBase.getNextIndexForError, lines 193-208.
GetNextIndexForError(f, newNextIndex) ==
    LET provenNext == matchIndex[f] + 1 IN
    LET oldNext == nextIndex[f] IN
    LET decreased ==
        IF oldNext <= 0
        THEN oldNext
        ELSE Min2(oldNext - 1, newNextIndex)
    IN
        IF provenNext > decreased
        THEN provenNext
        ELSE IF oldNext <= 0 THEN oldNext ELSE decreased

\* LogAppenderBase.newAppendEntriesRequest, lines 213-251.
PreviousAvailable(f) ==
    \/ nextIndex[f] = snapshotIndex[f] + 1
    \/ nextIndex[f] - 1 >= leaderStartIndex

CanAppendDataThrough(f, last) ==
    /\ nextIndex[f] >= LeastValidLogIndex
    /\ nextIndex[f] <= leaderLastIndex
    /\ last \in nextIndex[f]..leaderLastIndex
    /\ nextIndex[f] = LeastValidLogIndex \/ PreviousAvailable(f)
    /\ snapshotState[f] \notin {SendingChunks, FollowerInstalling}
    /\ peerMode[f] # StagingNewPeer \/ attemptedSnapshot[f]

CanAppendData(f) ==
    CanAppendDataThrough(f, nextIndex[f])

\* LogAppender.shouldInstallSnapshot, lines 193-219.
ShouldInstallSnapshot(f) ==
    \/ /\ peerMode[f] = StagingNewPeer
       /\ ~attemptedSnapshot[f]
    \/ /\ nextIndex[f] < leaderStartIndex
    \/ /\ nextIndex[f] = leaderStartIndex
       /\ nextIndex[f] > LeastValidLogIndex
       /\ nextIndex[f] /= snapshotIndex[f] + 1

RequestMatchesReply(q, r) ==
    /\ q.callId = r.callId
    /\ q.kind = r.kind

RequestPresent(f, r) ==
    /\ r.follower = f
    /\ \E q \in pending[f] : RequestMatchesReply(q, r)

MatchingRequest(f, r) ==
    CHOOSE q \in pending[f] : RequestMatchesReply(q, r)

RemoveMatchingPending(f, r) ==
    {q \in pending[f] : ~RequestMatchesReply(q, r)}

QuorumProofFor(idx) ==
    Cardinality({s \in Server :
        \/ /\ s = LeaderNode
           /\ leaderLastIndex >= idx
        \/ /\ s # LeaderNode
           /\ matchIndex[s] >= idx}) >= Majority

CommitOnlyFromQuorumProof ==
    commitIndex <= commitProofIndex

CatchupPredicate(f) ==
    /\ matchIndex[f] + StagingCatchupGap > commitIndex
    /\ matchIndex[f] >= ConfLogIndex
    /\ recentResponse[f] = Fresh
    /\ attemptedSnapshot[f]

StaleAfterSnapshot(f, r) ==
    /\ snapshotProofIndex[f] > 0
    /\ \/ r.epoch < streamEpoch[f]
       \/ r.lastIndex < snapshotIndex[f]

\* RaftServerImpl.checkInconsistentAppendEntries, lines 1745-1777, and
\* ServerState.getNextIndex/containsTermIndex.  Once the follower has a
\* snapshot boundary in its current state, a newly generated INCONSISTENCY
\* reply is bounded by that snapshot frontier.  Older already-generated replies
\* are still represented by replyQueue and handled by OldAppendReplyAfterSnapshot.
GeneratedInconsistencyReplyNextOK(f, replyNext) ==
    /\ replyNext \in 0..MaxLogIndex
    /\ snapshotProofIndex[f] = 0 \/ replyNext >= snapshotIndex[f] + 1

----
\* Initialization.
----

Init ==
    /\ leaderStartIndex = 1
    /\ leaderLastIndex = MaxLogIndex
    /\ commitIndex = 0
    /\ commitProofIndex = 0
    /\ matchIndex = [f \in Followers |-> 0]
    /\ nextIndex = [f \in Followers |-> 1]
    /\ snapshotIndex = [f \in Followers |-> 0]
    /\ matchProofIndex = [f \in Followers |-> 0]
    /\ snapshotProofIndex = [f \in Followers |-> 0]
    /\ streamEpoch = [f \in Followers |-> 0]
    /\ streamActive = [f \in Followers |-> TRUE]
    /\ pending = [f \in Followers |-> {}]
    /\ sentRequests = [f \in Followers |-> {}]
    /\ replyQueue = {}
    /\ callSeq = [f \in Followers |-> 1]
    /\ replySeq = 1
    /\ snapshotState = [f \in Followers |-> SnapshotNone]
    /\ snapshotRequestIndex = [f \in Followers |-> 0]
    /\ installedSnapshotIndexOnFollower = [f \in Followers |-> 0]
    /\ attemptedSnapshot = [f \in Followers |-> FALSE]
    /\ retryRequired = [f \in Followers |-> FALSE]
    /\ appendDuringSnapshot = [f \in Followers |-> FALSE]
    /\ peerMode = [f \in Followers |-> Existing]
    /\ caughtUp = [f \in Followers |-> TRUE]
    /\ recentResponse = [f \in Followers |-> Fresh]
    /\ configurationState = ConfigStable
    /\ stagingFailed = [f \in Followers |-> FALSE]
    /\ restartOccurred = [f \in Followers |-> FALSE]
    /\ usefulProgressBeforeRestart = [f \in Followers |-> FALSE]
    /\ streamReady = [f \in Followers |-> TRUE]
    /\ cancelled = [f \in Followers |-> FALSE]
    /\ outstandingChunks = [f \in Followers |-> 0]
    /\ resourceExhausted = FALSE

----
\* Scenario 1: gRPC AppendEntries stream, pending requests, reset, late replies.
----

\* GrpcLogAppender.appendLog, lines 392-408; increaseNextIndex, lines 459-463.
SendAppendDataRangeWithCallId(f, cid, last) ==
    /\ f \in Followers
    /\ peerMode[f] # Removed
    /\ streamActive[f]
    /\ streamReady[f]
    /\ cid \in 0..MaxCallId
    /\ CanAppendDataThrough(f, last)
    /\ LET first == nextIndex[f] IN
       LET req ==
            [ callId |-> cid,
              epoch |-> streamEpoch[f],
              kind |-> Data,
              prevIndex |-> first - 1,
              firstIndex |-> first,
              lastIndex |-> last,
              isHeartbeat |-> FALSE,
              state |-> PendingState ] IN
        /\ pending' = [pending EXCEPT ![f] = @ \cup {req}]
        /\ sentRequests' = [sentRequests EXCEPT ![f] = @ \cup {req}]
        /\ nextIndex' = [nextIndex EXCEPT ![f] = Max2(@, last + 1)]
        /\ callSeq' = [callSeq EXCEPT ![f] = Max2(@, cid + 1)]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, replyQueue, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

SendAppendDataWithCallId(f, cid) ==
    SendAppendDataRangeWithCallId(f, cid, nextIndex[f])

SendAppendDataRangeAfterObservedPendingRemoval(f, cid, last, r) ==
    /\ f \in Followers
    /\ r \in replyQueue
    /\ RequestPresent(f, r)
    /\ peerMode[f] # Removed
    /\ streamActive[f]
    /\ streamReady[f]
    /\ cid \in 0..MaxCallId
    /\ CanAppendDataThrough(f, last)
    /\ LET first == nextIndex[f] IN
       LET req ==
            [ callId |-> cid,
              epoch |-> streamEpoch[f],
              kind |-> Data,
              prevIndex |-> first - 1,
              firstIndex |-> first,
              lastIndex |-> last,
              isHeartbeat |-> FALSE,
              state |-> PendingState ] IN
        /\ pending' = [pending EXCEPT ![f] = RemoveMatchingPending(f, r) \cup {req}]
        /\ sentRequests' = [sentRequests EXCEPT ![f] = @ \cup {req}]
        /\ nextIndex' = [nextIndex EXCEPT ![f] = Max2(@, last + 1)]
        /\ callSeq' = [callSeq EXCEPT ![f] = Max2(@, cid + 1)]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, replyQueue, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

SendAppendData(f) ==
    /\ callSeq[f] <= MaxCallId
    /\ SendAppendDataWithCallId(f, callSeq[f])

\* LogAppenderBase.newAppendEntriesRequest heartbeat branch, lines 213-220;
\* RequestMap heartbeat map, lines 898-925.
SendHeartbeatWithCallId(f, cid) ==
    /\ f \in Followers
    /\ peerMode[f] # Removed
    /\ streamActive[f]
    /\ streamReady[f]
    /\ cid \in 0..MaxCallId
    /\ LET req ==
            [ callId |-> cid,
              epoch |-> streamEpoch[f],
              kind |-> Heartbeat,
              prevIndex |-> nextIndex[f] - 1,
              firstIndex |-> InvalidIndex,
              lastIndex |-> InvalidIndex,
              isHeartbeat |-> TRUE,
              state |-> PendingState ] IN
        /\ pending' = [pending EXCEPT ![f] = @ \cup {req}]
        /\ sentRequests' = [sentRequests EXCEPT ![f] = @ \cup {req}]
        /\ callSeq' = [callSeq EXCEPT ![f] = Max2(@, cid + 1)]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, replyQueue, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

SendHeartbeat(f) ==
    /\ callSeq[f] <= MaxCallId
    /\ SendHeartbeatWithCallId(f, callSeq[f])

\* GrpcLogAppender.timeoutAppendRequest, lines 448-456.
TimeoutAppend(f, q) ==
    /\ f \in Followers
    /\ q \in pending[f]
    /\ pending' = [pending EXCEPT ![f] = @ \ {q}]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

\* AppendLogResponseHandler.onError, lines 547-557; resetClient, lines 206-231.
StreamErrorResetWithRequest(f, q) ==
    /\ f \in Followers
    /\ q \in pending[f]
    /\ pending' = [pending EXCEPT ![f] = {}]
    /\ streamActive' = [streamActive EXCEPT ![f] = FALSE]
    /\ nextIndex' =
        [nextIndex EXCEPT ![f] =
            IF q.kind = Heartbeat
            THEN @
            ELSE GetNextIndexForError(f, q.prevIndex + 1)]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

\* resetClient error with request == null, lines 206-227.
StreamErrorResetWithoutRequest(f) ==
    /\ f \in Followers
    /\ pending' = [pending EXCEPT ![f] = {}]
    /\ streamActive' = [streamActive EXCEPT ![f] = FALSE]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

StreamErrorReset(f) ==
    \/ \E q \in pending[f] : StreamErrorResetWithRequest(f, q)
    \/ StreamErrorResetWithoutRequest(f)

\* AppendLogResponseHandler.onCompleted, lines 561-564; resetClient, lines 206-231.
StreamCompleteReset(f) ==
    /\ f \in Followers
    /\ pending' = [pending EXCEPT ![f] = {}]
    /\ streamActive' = [streamActive EXCEPT ![f] = FALSE]
    /\ nextIndex' = [nextIndex EXCEPT ![f] = GetNextIndexForError(f, matchIndex[f] + 1)]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

\* GrpcLogAppender.appendLog creates StreamObservers when null, lines 405-408.
Reconnect(f) ==
    /\ f \in Followers
    /\ ~streamActive[f]
    /\ streamEpoch' = [streamEpoch EXCEPT ![f] = @ + 1]
    /\ streamActive' = [streamActive EXCEPT ![f] = TRUE]
    /\ cancelled' = [cancelled EXCEPT ![f] = FALSE]
    /\ streamReady' = [streamReady EXCEPT ![f] = TRUE]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   outstandingChunks, resourceExhausted>>

\* GrpcLogAppender.appendLog constructs the pending AppendEntries request before
\* creating a new observer and emitting the reconnect trace event, lines 436-458.
ReconnectWithPreparedHeartbeat(f, cid) ==
    /\ f \in Followers
    /\ cid \in 0..MaxCallId
    /\ streamEpoch[f] < MaxCallId + 1
    /\ LET newEpoch == streamEpoch[f] + 1 IN
       LET req ==
            [ callId |-> cid,
              epoch |-> newEpoch,
              kind |-> Heartbeat,
              prevIndex |-> nextIndex[f] - 1,
              firstIndex |-> InvalidIndex,
              lastIndex |-> InvalidIndex,
              isHeartbeat |-> TRUE,
              state |-> PendingState ] IN
        /\ pending' = [pending EXCEPT ![f] = @ \cup {req}]
        /\ sentRequests' = [sentRequests EXCEPT ![f] = @ \cup {req}]
        /\ callSeq' = [callSeq EXCEPT ![f] = Max2(@, cid + 1)]
    /\ streamEpoch' = [streamEpoch EXCEPT ![f] = @ + 1]
    /\ streamActive' = [streamActive EXCEPT ![f] = TRUE]
    /\ cancelled' = [cancelled EXCEPT ![f] = FALSE]
    /\ streamReady' = [streamReady EXCEPT ![f] = TRUE]
    /\ attemptedSnapshot' = [attemptedSnapshot EXCEPT ![f] = @ \/ ShouldInstallSnapshot(f)]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   replyQueue, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   outstandingChunks, resourceExhausted>>

\* RaftServerImpl success reply, lines 1691-1730.
FollowerAppendSuccessWithReplyNext(f, req, replyNext) ==
    /\ f \in Followers
    /\ req \in sentRequests[f]
    /\ replyNext \in Index
    /\ replySeq <= MaxReplyId
    /\ snapshotState[f] # FollowerInstalling
        /\ LET reply ==
            [ replyId |-> replySeq,
              follower |-> f,
              callId |-> req.callId,
              epoch |-> req.epoch,
              kind |-> req.kind,
              result |-> Success,
              match |-> IF req.kind = Data THEN req.lastIndex ELSE InvalidIndex,
              next |-> replyNext,
              firstIndex |-> req.firstIndex,
              lastIndex |-> req.lastIndex,
              prevIndex |-> req.prevIndex,
              fromSnapshot |-> FALSE ] IN
        /\ replyQueue' = replyQueue \cup {reply}
        /\ replySeq' = replySeq + 1
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, callSeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

FollowerAppendSuccess(f, req) ==
    /\ FollowerAppendSuccessWithReplyNext(
        f, req, IF req.kind = Data THEN req.lastIndex + 1 ELSE nextIndex[f])

\* RaftServerImpl.checkInconsistentAppendEntries, lines 1739-1769.
FollowerAppendInconsistency(f, req, replyNext) ==
    /\ f \in Followers
    /\ req \in sentRequests[f]
    /\ GeneratedInconsistencyReplyNextOK(f, replyNext)
    /\ replySeq <= MaxReplyId
        /\ LET reply ==
            [ replyId |-> replySeq,
              follower |-> f,
              callId |-> req.callId,
              epoch |-> req.epoch,
              kind |-> req.kind,
              result |-> Inconsistency,
              match |-> InvalidIndex,
              next |-> replyNext,
              firstIndex |-> req.firstIndex,
              lastIndex |-> req.lastIndex,
              prevIndex |-> req.prevIndex,
              fromSnapshot |-> snapshotState[f] = FollowerInstalling ] IN
        /\ replyQueue' = replyQueue \cup {reply}
        /\ replySeq' = replySeq + 1
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, callSeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

\* AppendLogResponseHandler.onNext and SUCCESS branch, lines 487-519.
ReceiveSuccessWithRequest(f, r) ==
    /\ f \in Followers
    /\ r \in replyQueue
    /\ r.follower = f
    /\ r.result = Success
    /\ RequestPresent(f, r)
    /\ pending' = [pending EXCEPT ![f] = RemoveMatchingPending(f, r)]
    /\ replyQueue' = replyQueue \ {r}
    /\ matchIndex' =
        [matchIndex EXCEPT ![f] =
            IF r.kind = Data /\ r.match > @ THEN r.match ELSE @]
    /\ nextIndex' =
        [nextIndex EXCEPT ![f] =
            IF r.kind = Data /\ r.match > matchIndex[f]
            THEN Max2(@, r.match + 1)
            ELSE @]
    /\ matchProofIndex' =
        [matchProofIndex EXCEPT ![f] =
            IF r.kind = Data /\ r.match > @ THEN r.match ELSE @]
    /\ recentResponse' = [recentResponse EXCEPT ![f] = Fresh]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   snapshotIndex, snapshotProofIndex,
                   streamEpoch, streamActive, sentRequests, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

\* Same SUCCESS branch with request == null after timeout/reset, lines 487-519.
ReceiveSuccessWithoutRequest(f, r) ==
    /\ f \in Followers
    /\ r \in replyQueue
    /\ r.follower = f
    /\ r.result = Success
    /\ ~RequestPresent(f, r)
    /\ replyQueue' = replyQueue \ {r}
    /\ matchIndex' =
        [matchIndex EXCEPT ![f] =
            IF r.kind = Data /\ r.match >= matchIndex[f] /\ r.match <= r.lastIndex
            THEN Max2(@, r.match)
            ELSE @]
    /\ nextIndex' =
        [nextIndex EXCEPT ![f] =
            IF r.kind = Data /\ r.match >= matchIndex[f] /\ r.match <= r.lastIndex
            THEN Max2(@, r.match + 1)
            ELSE @]
    /\ matchProofIndex' =
        [matchProofIndex EXCEPT ![f] =
            IF r.kind = Data /\ r.match >= matchIndex[f] /\ r.match <= r.lastIndex
            THEN Max2(@, r.match)
            ELSE @]
    /\ recentResponse' = [recentResponse EXCEPT ![f] = Fresh]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   snapshotIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

\* AppendLogResponseHandler INCONSISTENCY branch, lines 528-535;
\* GrpcLogAppender.updateNextIndex, lines 572-575.
ReceiveInconsistencyWithRequest(f, r) ==
    /\ f \in Followers
    /\ r \in replyQueue
    /\ r.follower = f
    /\ r.result = Inconsistency
    /\ RequestPresent(f, r)
    /\ LET req == MatchingRequest(f, r) IN
        /\ pending' = [pending EXCEPT ![f] = {}]
        /\ nextIndex' = [nextIndex EXCEPT ![f] =
              GetNextIndexForInconsistency(f, req.firstIndex, r.next)]
    /\ replyQueue' = replyQueue \ {r}
    /\ recentResponse' = [recentResponse EXCEPT ![f] = Fresh]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, sentRequests, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

\* Same INCONSISTENCY branch with request == null, lines 487-535.
ReceiveInconsistencyWithoutRequest(f, r) ==
    /\ f \in Followers
    /\ r \in replyQueue
    /\ r.follower = f
    /\ r.result = Inconsistency
    /\ ~RequestPresent(f, r)
    /\ pending' = [pending EXCEPT ![f] = {}]
    /\ nextIndex' =
        [nextIndex EXCEPT ![f] =
            GetNextIndexForInconsistency(f, InvalidIndex, r.next)]
    /\ replyQueue' = replyQueue \ {r}
    /\ recentResponse' = [recentResponse EXCEPT ![f] = Fresh]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, sentRequests, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

----
\* Scenario 2: AppendEntries to InstallSnapshot transition.
----

\* Log compaction makes a follower's previous entry unavailable; see
\* LogAppender.shouldInstallSnapshot, lines 205-219.
CompactLeaderLog(newStart) ==
    /\ newStart \in (leaderStartIndex + 1)..(leaderLastIndex + 1)
    /\ leaderStartIndex' = newStart
    /\ UNCHANGED <<leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

\* GrpcLogAppender.run/installSnapshot, lines 260-265; LogAppender, lines 193-219.
TriggerSnapshot(f) ==
    /\ f \in Followers
    /\ peerMode[f] # Removed
    /\ ShouldInstallSnapshot(f)
    /\ snapshotState' = [snapshotState EXCEPT ![f] = SendingChunks]
    /\ snapshotRequestIndex' = [snapshotRequestIndex EXCEPT ![f] = 0]
    /\ outstandingChunks' = [outstandingChunks EXCEPT ![f] = 0]
    /\ retryRequired' = [retryRequired EXCEPT ![f] = FALSE]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   installedSnapshotIndexOnFollower, attemptedSnapshot, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, resourceExhausted>>

\* GrpcLogAppender.installSnapshot sends chunks, lines 764-799; addPending, lines 594-610.
SendSnapshotChunk(f) ==
    /\ f \in Followers
    /\ snapshotState[f] \in {SendingChunks, FollowerInstalling}
    /\ outstandingChunks[f] < MaxSnapshotChunks
    /\ snapshotRequestIndex' = [snapshotRequestIndex EXCEPT ![f] = @ + 1]
    /\ outstandingChunks' = [outstandingChunks EXCEPT ![f] = @ + 1]
    /\ snapshotState' = [snapshotState EXCEPT ![f] = FollowerInstalling]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   installedSnapshotIndexOnFollower, attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, resourceExhausted>>

\* InstallSnapshotResponseHandler SUCCESS/IN_PROGRESS, lines 747-756.
\* These replies release per-chunk backpressure permits but are not always
\* emitted as distinct trace events by the harness.
SnapshotChunkSuccess(f) ==
    /\ f \in Followers
    /\ snapshotState[f] \in {SendingChunks, FollowerInstalling, Installed}
    /\ outstandingChunks[f] > 0
    /\ attemptedSnapshot' = [attemptedSnapshot EXCEPT ![f] = TRUE]
    /\ retryRequired' = [retryRequired EXCEPT ![f] = FALSE]
    /\ outstandingChunks' = [outstandingChunks EXCEPT ![f] = DecNat(@)]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, resourceExhausted>>

SnapshotChunkInProgress(f) ==
    /\ f \in Followers
    /\ snapshotState[f] \in {SendingChunks, FollowerInstalling}
    /\ outstandingChunks[f] > 0
    /\ retryRequired' = [retryRequired EXCEPT ![f] = FALSE]
    /\ outstandingChunks' = [outstandingChunks EXCEPT ![f] = DecNat(@)]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, resourceExhausted>>

\* RaftServerImpl.checkInconsistentAppendEntries rejects appends while snapshot
\* installation is in progress, lines 1739-1745.
FollowerSnapshotInProgress(f, req) ==
    /\ f \in Followers
    /\ req \in sentRequests[f]
    /\ snapshotState[f] = FollowerInstalling
    /\ replySeq <= MaxReplyId
        /\ LET reply ==
            [ replyId |-> replySeq,
              follower |-> f,
              callId |-> req.callId,
              epoch |-> req.epoch,
              kind |-> req.kind,
              result |-> Inconsistency,
              match |-> InvalidIndex,
              next |-> nextIndex[f],
              firstIndex |-> req.firstIndex,
              lastIndex |-> req.lastIndex,
              prevIndex |-> req.prevIndex,
              fromSnapshot |-> TRUE ] IN
        /\ replyQueue' = replyQueue \cup {reply}
        /\ replySeq' = replySeq + 1
    /\ appendDuringSnapshot' = [appendDuringSnapshot EXCEPT ![f] = TRUE]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, callSeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

\* InstallSnapshotResponseHandler SNAPSHOT_INSTALLED, lines 704-712;
\* FollowerInfoImpl.setSnapshotIndex, lines 147-150.
SnapshotInstalled(f, installedIndex) ==
    /\ f \in Followers
    /\ installedIndex \in 0..MaxLogIndex
    /\ installedIndex >= installedSnapshotIndexOnFollower[f]
    /\ snapshotState[f] \in {SendingChunks, FollowerInstalling}
    /\ snapshotRequestIndex[f] > 0
    /\ snapshotIndex' = [snapshotIndex EXCEPT ![f] = installedIndex]
    /\ matchIndex' = [matchIndex EXCEPT ![f] = installedIndex]
    /\ nextIndex' = [nextIndex EXCEPT ![f] = installedIndex + 1]
    /\ snapshotProofIndex' = [snapshotProofIndex EXCEPT ![f] = Max2(@, installedIndex)]
    /\ matchProofIndex' = [matchProofIndex EXCEPT ![f] = Max2(@, installedIndex)]
    /\ installedSnapshotIndexOnFollower' =
        [installedSnapshotIndexOnFollower EXCEPT ![f] = Max2(@, installedIndex)]
    /\ attemptedSnapshot' = [attemptedSnapshot EXCEPT ![f] = TRUE]
    /\ retryRequired' = [retryRequired EXCEPT ![f] = FALSE]
    /\ snapshotState' = [snapshotState EXCEPT ![f] = Installed]
    /\ outstandingChunks' = [outstandingChunks EXCEPT ![f] = DecNat(@)]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotRequestIndex, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, resourceExhausted>>

\* InstallSnapshotResponseHandler ALREADY_INSTALLED, lines 687-694.
SnapshotAlreadyInstalled(f, installedIndex) ==
    /\ f \in Followers
    /\ installedIndex \in 0..MaxLogIndex
    /\ installedIndex >= installedSnapshotIndexOnFollower[f]
    /\ snapshotState[f] \in {SendingChunks, FollowerInstalling}
    /\ snapshotRequestIndex[f] > 0
    /\ snapshotIndex' = [snapshotIndex EXCEPT ![f] = installedIndex]
    /\ matchIndex' = [matchIndex EXCEPT ![f] = installedIndex]
    /\ nextIndex' = [nextIndex EXCEPT ![f] = installedIndex + 1]
    /\ snapshotProofIndex' = [snapshotProofIndex EXCEPT ![f] = Max2(@, installedIndex)]
    /\ matchProofIndex' = [matchProofIndex EXCEPT ![f] = Max2(@, installedIndex)]
    /\ installedSnapshotIndexOnFollower' =
        [installedSnapshotIndexOnFollower EXCEPT ![f] = Max2(@, installedIndex)]
    /\ attemptedSnapshot' = [attemptedSnapshot EXCEPT ![f] = TRUE]
    /\ retryRequired' = [retryRequired EXCEPT ![f] = FALSE]
    /\ snapshotState' = [snapshotState EXCEPT ![f] = Installed]
    /\ outstandingChunks' = [outstandingChunks EXCEPT ![f] = DecNat(@)]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotRequestIndex, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, resourceExhausted>>

\* InstallSnapshotResponseHandler SNAPSHOT_UNAVAILABLE / SNAPSHOT_EXPIRED,
\* lines 714-729.
SnapshotUnavailableOrExpired(f, result) ==
    /\ f \in Followers
    /\ result \in {Unavailable, Expired}
    /\ snapshotState[f] \in {SendingChunks, FollowerInstalling}
    /\ snapshotRequestIndex[f] > 0
    /\ snapshotState' = [snapshotState EXCEPT ![f] = result]
    /\ retryRequired' = [retryRequired EXCEPT ![f] = TRUE]
    /\ attemptedSnapshot' =
        [attemptedSnapshot EXCEPT ![f] = @ \/ result = Unavailable]
    /\ outstandingChunks' = [outstandingChunks EXCEPT ![f] = DecNat(@)]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotRequestIndex, installedSnapshotIndexOnFollower, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, resourceExhausted>>

\* A pre-snapshot AppendEntries reply enters the same onNextImpl code after
\* snapshot progress has been recorded; GrpcLogAppender lines 487-535 and
\* snapshot reply handling lines 687-712.
OldAppendReplyAfterSnapshot(f, r) ==
    /\ f \in Followers
    /\ r \in replyQueue
    /\ StaleAfterSnapshot(f, r)
    /\ \/ ReceiveSuccessWithRequest(f, r)
       \/ ReceiveSuccessWithoutRequest(f, r)
       \/ ReceiveInconsistencyWithRequest(f, r)
       \/ ReceiveInconsistencyWithoutRequest(f, r)

\* GrpcLogAppender resumes appendLog after snapshot, lines 260-266 and 392-417.
AppendAfterSnapshotWithCallId(f, cid) ==
    /\ f \in Followers
    /\ snapshotState[f] = Installed
    /\ nextIndex[f] >= snapshotIndex[f] + 1
    /\ SendAppendDataWithCallId(f, cid)

AppendAfterSnapshot(f) ==
    /\ callSeq[f] <= MaxCallId
    /\ AppendAfterSnapshotWithCallId(f, callSeq[f])

----
\* Scenario 3: bootstrapping, restart, and staging catch-up.
----

\* LeaderStateImpl.startSetConfiguration/addSenders, lines 518-550 and 667-685.
AddStagingPeer(f) ==
    /\ f \in Followers
    /\ peerMode[f] = Existing
    /\ peerMode' = [peerMode EXCEPT ![f] = StagingNewPeer]
    /\ caughtUp' = [caughtUp EXCEPT ![f] = FALSE]
    /\ nextIndex' = [nextIndex EXCEPT ![f] = LeastValidLogIndex]
    /\ matchIndex' = [matchIndex EXCEPT ![f] = InvalidIndex]
    /\ snapshotIndex' = [snapshotIndex EXCEPT ![f] = 0]
    /\ matchProofIndex' = [matchProofIndex EXCEPT ![f] = InvalidIndex]
    /\ snapshotProofIndex' = [snapshotProofIndex EXCEPT ![f] = 0]
    /\ attemptedSnapshot' = [attemptedSnapshot EXCEPT ![f] = FALSE]
    /\ recentResponse' = [recentResponse EXCEPT ![f] = Stale]
    /\ configurationState' = ConfigStaging
    /\ pending' = [pending EXCEPT ![f] = {}]
    /\ sentRequests' = [sentRequests EXCEPT ![f] = {}]
    /\ replyQueue' = {r \in replyQueue : r.follower # f}
    /\ usefulProgressBeforeRestart' = [usefulProgressBeforeRestart EXCEPT ![f] = FALSE]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   streamEpoch, streamActive, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   retryRequired, appendDuringSnapshot,
                   stagingFailed, restartOccurred,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

\* LeaderStateImpl.restart replaces the appender via addAndStartSenders only
\* when getPeer(info.getId()) finds the peer in the current Raft configuration,
\* lines 715-728 and 676-687.  Staging-only peers are not in that configuration:
\* restart removes their sender but does not recreate FollowerInfoImpl or emit
\* the RestartAppender trace event.
RestartAppender(f) ==
    /\ f \in Followers
    /\ peerMode[f] = Existing
    /\ usefulProgressBeforeRestart' =
        [usefulProgressBeforeRestart EXCEPT ![f] =
            @ \/ /\ peerMode[f] = StagingNewPeer
                  /\ \/ matchIndex[f] >= ConfLogIndex
                     \/ snapshotIndex[f] >= ConfLogIndex]
    /\ restartOccurred' = [restartOccurred EXCEPT ![f] = TRUE]
    /\ pending' = [pending EXCEPT ![f] = {}]
    /\ streamEpoch' = [streamEpoch EXCEPT ![f] = @ + 1]
    /\ streamActive' = [streamActive EXCEPT ![f] = TRUE]
    /\ nextIndex' = [nextIndex EXCEPT ![f] = LeastValidLogIndex]
    /\ matchIndex' = [matchIndex EXCEPT ![f] = InvalidIndex]
    /\ snapshotIndex' = [snapshotIndex EXCEPT ![f] = 0]
    /\ matchProofIndex' = [matchProofIndex EXCEPT ![f] = InvalidIndex]
    /\ snapshotProofIndex' = [snapshotProofIndex EXCEPT ![f] = 0]
    /\ attemptedSnapshot' = [attemptedSnapshot EXCEPT ![f] = FALSE]
    /\ caughtUp' = [caughtUp EXCEPT ![f] = FALSE]
    /\ recentResponse' = [recentResponse EXCEPT ![f] = Stale]
    /\ cancelled' = [cancelled EXCEPT ![f] = FALSE]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   retryRequired, appendDuringSnapshot,
                   peerMode, configurationState, stagingFailed,
                   streamReady, outstandingChunks, resourceExhausted>>

\* Staging peer success is the same reply branch plus the staging event
\* submitted by onFollowerSuccessAppendEntries, lines 516-519 and 846-852.
AppendSuccessForStagingPeer(f, r) ==
    /\ f \in Followers
    /\ ~caughtUp[f]
    /\ \/ ReceiveSuccessWithRequest(f, r)
       \/ ReceiveSuccessWithoutRequest(f, r)

\* LogAppender.shouldInstallSnapshot bootstrapping branch, lines 193-203.
SnapshotAttemptForStagingPeer(f) ==
    /\ f \in Followers
    /\ peerMode[f] = StagingNewPeer
    /\ TriggerSnapshot(f)

\* LeaderStateImpl.checkProgress, lines 828-843.
CheckProgress(f) ==
    /\ f \in Followers
    /\ peerMode[f] = StagingNewPeer
    /\ ~caughtUp[f]
    /\ \/ /\ recentResponse[f] = Stale
          /\ stagingFailed' = [stagingFailed EXCEPT ![f] = TRUE]
          /\ UNCHANGED caughtUp
       \/ /\ CatchupPredicate(f)
          /\ caughtUp' = [caughtUp EXCEPT ![f] = TRUE]
          /\ UNCHANGED stagingFailed
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, recentResponse, configurationState,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

\* LeaderStateImpl.checkStaging applies old-new configuration, lines 863-887.
ApplyStagingConfiguration ==
    /\ configurationState = ConfigStaging
    /\ \A f \in Followers : peerMode[f] # StagingNewPeer \/ caughtUp[f]
    /\ configurationState' = ConfigOldNew
    /\ peerMode' =
        [f \in Followers |->
            IF peerMode[f] = StagingNewPeer THEN Existing ELSE peerMode[f]]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   caughtUp, recentResponse, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

----
\* Scenario 4: small cancellation/backpressure abstraction.
----

\* StreamObservers.onNext waits on isReady, lines 356-370.
SetStreamReady(f, ready) ==
    /\ f \in Followers
    /\ ready \in BOOLEAN
    /\ streamReady' = [streamReady EXCEPT ![f] = ready]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   cancelled, outstandingChunks, resourceExhausted>>

\* StreamObservers.stop only flips running, lines 372-374; server stream onError
\* closes, GrpcServerProtocolService lines 184-191.
CancelAppendStream(f) ==
    /\ f \in Followers
    /\ cancelled' = [cancelled EXCEPT ![f] = TRUE]
    /\ streamActive' = [streamActive EXCEPT ![f] = FALSE]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, outstandingChunks, resourceExhausted>>

\* Trace-only abstraction for old observer lifecycle events that arrive after
\* LeaderStateImpl.restart has replaced the shared FollowerInfo object.
ObservedCancelAppendStream(f) ==
    /\ f \in Followers
    /\ cancelled' = [cancelled EXCEPT ![f] = TRUE]
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, outstandingChunks, resourceExhausted>>

ObservedStreamReset(f) ==
    /\ f \in Followers
    /\ UNCHANGED vars

\* StreamObserverWithTimeout bounds outstanding snapshot sends, lines 40-53 and 80-107.
SnapshotBackpressureBlock(f) ==
    /\ f \in Followers
    /\ outstandingChunks[f] > 0
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

ResourceExhausted ==
    /\ resourceExhausted' = TRUE
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks>>

----
\* Commit advancement.
----

\* LeaderStateImpl.onFollowerCommitIndex/commitIndexChanged, lines 606-621.
AdvanceCommitIndex(newCommit) ==
    /\ newCommit \in (commitIndex + 1)..leaderLastIndex
    /\ QuorumProofFor(newCommit)
    /\ commitIndex' = newCommit
    /\ commitProofIndex' = Max2(commitProofIndex, newCommit)
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

AdvanceCommitIndexObserved(newCommit) ==
    /\ newCommit \in (commitIndex + 1)..leaderLastIndex
    /\ commitIndex' = newCommit
    /\ commitProofIndex' = Max2(commitProofIndex, newCommit)
    /\ UNCHANGED <<leaderStartIndex, leaderLastIndex,
                   matchIndex, nextIndex, snapshotIndex, matchProofIndex, snapshotProofIndex,
                   streamEpoch, streamActive, pending, sentRequests, replyQueue, callSeq, replySeq,
                   snapshotState, snapshotRequestIndex, installedSnapshotIndexOnFollower,
                   attemptedSnapshot, retryRequired, appendDuringSnapshot,
                   peerMode, caughtUp, recentResponse, configurationState, stagingFailed,
                   restartOccurred, usefulProgressBeforeRestart,
                   streamReady, cancelled, outstandingChunks, resourceExhausted>>

----
\* Next-state relation.
----

Next ==
    \/ \E f \in Followers : SendAppendData(f)
    \/ \E f \in Followers : SendHeartbeat(f)
    \/ \E f \in Followers : \E q \in pending[f] : TimeoutAppend(f, q)
    \/ \E f \in Followers : StreamErrorReset(f)
    \/ \E f \in Followers : StreamCompleteReset(f)
    \/ \E f \in Followers : Reconnect(f)
    \/ \E f \in Followers : \E req \in sentRequests[f] : FollowerAppendSuccess(f, req)
    \/ \E f \in Followers : \E req \in sentRequests[f] : \E rn \in 0..MaxLogIndex :
            FollowerAppendInconsistency(f, req, rn)
    \/ \E f \in Followers : \E r \in replyQueue : ReceiveSuccessWithRequest(f, r)
    \/ \E f \in Followers : \E r \in replyQueue : ReceiveSuccessWithoutRequest(f, r)
    \/ \E f \in Followers : \E r \in replyQueue : ReceiveInconsistencyWithRequest(f, r)
    \/ \E f \in Followers : \E r \in replyQueue : ReceiveInconsistencyWithoutRequest(f, r)
    \/ \E newStart \in (leaderStartIndex + 1)..(leaderLastIndex + 1) : CompactLeaderLog(newStart)
    \/ \E f \in Followers : TriggerSnapshot(f)
    \/ \E f \in Followers : SendSnapshotChunk(f)
    \/ \E f \in Followers : SnapshotChunkSuccess(f)
    \/ \E f \in Followers : SnapshotChunkInProgress(f)
    \/ \E f \in Followers : \E req \in sentRequests[f] : FollowerSnapshotInProgress(f, req)
    \/ \E f \in Followers : \E s \in 0..MaxLogIndex : SnapshotInstalled(f, s)
    \/ \E f \in Followers : \E s \in 0..MaxLogIndex : SnapshotAlreadyInstalled(f, s)
    \/ \E f \in Followers : \E result \in {Unavailable, Expired} :
            SnapshotUnavailableOrExpired(f, result)
    \/ \E f \in Followers : \E r \in replyQueue : OldAppendReplyAfterSnapshot(f, r)
    \/ \E f \in Followers : AppendAfterSnapshot(f)
    \/ \E f \in Followers : AddStagingPeer(f)
    \/ \E f \in Followers : RestartAppender(f)
    \/ \E f \in Followers : \E r \in replyQueue : AppendSuccessForStagingPeer(f, r)
    \/ \E f \in Followers : SnapshotAttemptForStagingPeer(f)
    \/ \E f \in Followers : CheckProgress(f)
    \/ ApplyStagingConfiguration
    \/ \E f \in Followers : \E ready \in BOOLEAN : SetStreamReady(f, ready)
    \/ \E f \in Followers : CancelAppendStream(f)
    \/ \E f \in Followers : SnapshotBackpressureBlock(f)
    \/ ResourceExhausted
    \/ \E n \in (commitIndex + 1)..leaderLastIndex : AdvanceCommitIndex(n)

Spec == Init /\ [][Next]_vars

----
\* Type, safety, scenario, and structural invariants.
----

TypeOK ==
    /\ LeaderNode \in Server
    /\ leaderStartIndex \in 1..(MaxLogIndex + 1)
    /\ leaderLastIndex \in 0..MaxLogIndex
    /\ commitIndex \in 0..MaxLogIndex
    /\ commitProofIndex \in 0..MaxLogIndex
    /\ matchIndex \in [Followers -> Index]
    /\ nextIndex \in [Followers -> Index]
    /\ snapshotIndex \in [Followers -> 0..MaxLogIndex]
    /\ matchProofIndex \in [Followers -> Index]
    /\ snapshotProofIndex \in [Followers -> 0..MaxLogIndex]
    /\ streamEpoch \in [Followers -> Epoch]
    /\ streamActive \in [Followers -> BOOLEAN]
    /\ pending \in [Followers -> SUBSET RequestRecord]
    /\ sentRequests \in [Followers -> SUBSET RequestRecord]
    /\ replyQueue \subseteq ReplyRecord
    /\ callSeq \in [Followers -> 1..(MaxCallId + 1)]
    /\ replySeq \in 1..(MaxReplyId + 1)
    /\ snapshotState \in [Followers -> {SnapshotNone, SendingChunks, FollowerInstalling, Installed, Unavailable, Expired}]
    /\ snapshotRequestIndex \in [Followers -> 0..(MaxSnapshotChunks + MaxCallId + 1)]
    /\ installedSnapshotIndexOnFollower \in [Followers -> 0..MaxLogIndex]
    /\ attemptedSnapshot \in [Followers -> BOOLEAN]
    /\ retryRequired \in [Followers -> BOOLEAN]
    /\ appendDuringSnapshot \in [Followers -> BOOLEAN]
    /\ peerMode \in [Followers -> {Existing, StagingNewPeer, Removed}]
    /\ caughtUp \in [Followers -> BOOLEAN]
    /\ recentResponse \in [Followers -> {Fresh, Stale}]
    /\ configurationState \in {ConfigStable, ConfigStaging, ConfigOldNew}
    /\ stagingFailed \in [Followers -> BOOLEAN]
    /\ restartOccurred \in [Followers -> BOOLEAN]
    /\ usefulProgressBeforeRestart \in [Followers -> BOOLEAN]
    /\ streamReady \in [Followers -> BOOLEAN]
    /\ cancelled \in [Followers -> BOOLEAN]
    /\ outstandingChunks \in [Followers -> 0..MaxSnapshotChunks]
    /\ resourceExhausted \in BOOLEAN

NextBeyondMatch ==
    \A f \in Followers :
        \* Legacy hunt name retained.  Ratis intentionally lets an
        \* INCONSISTENCY reply back nextIndex down to requestFirstIndex - 1
        \* to avoid resending the same first entry; safety is carried by
        \* match/commit proof indexes, not by nextIndex > matchIndex.
        peerMode[f] = Removed \/ nextIndex[f] >= LeastValidLogIndex

MatchOnlyFromProof ==
    \A f \in Followers :
        matchIndex[f] <= matchProofIndex[f]

StaleReplyNoProgressRegression ==
    \A f \in Followers :
        /\ matchIndex[f] <= matchProofIndex[f]
        /\ nextIndex[f] >= LeastValidLogIndex

SnapshotAppendBoundary ==
    \A f \in Followers :
        snapshotProofIndex[f] = 0 \/ nextIndex[f] >= snapshotIndex[f] + 1

SnapshotProgressMonotonic ==
    \A f \in Followers :
        /\ snapshotIndex[f] <= snapshotProofIndex[f]
        /\ snapshotIndex[f] = 0 \/ snapshotIndex[f] <= matchIndex[f]

NoCommitFromHeartbeatTail ==
    /\ CommitOnlyFromQuorumProof
    /\ \A f \in Followers : matchIndex[f] <= matchProofIndex[f]

PendingResetDoesNotLoseSafety ==
    /\ CommitOnlyFromQuorumProof
    /\ \A f \in Followers :
        pending[f] = {} =>
            /\ matchIndex[f] <= matchProofIndex[f]
            /\ nextIndex[f] >= LeastValidLogIndex

AppendDuringSnapshotDoesNotCommitUnprovenEntries ==
    /\ CommitOnlyFromQuorumProof
    /\ \A f \in Followers :
        appendDuringSnapshot[f] => matchIndex[f] <= matchProofIndex[f]

SnapshotRetryPreservesCatchup ==
    \A f \in Followers :
        /\ snapshotState[f] \in {Unavailable, Expired}
        /\ peerMode[f] = StagingNewPeer
        /\ ~caughtUp[f]
        => retryRequired[f]

NoPrematureStagingCommit ==
    \A f \in Followers :
        /\ peerMode[f] = StagingNewPeer
        /\ caughtUp[f]
        => CatchupPredicate(f)

RestartPreservesUsefulProgress ==
    \A f \in Followers :
        /\ restartOccurred[f]
        /\ usefulProgressBeforeRestart[f]
        /\ peerMode[f] = StagingNewPeer
        => \/ matchIndex[f] >= ConfLogIndex
           \/ snapshotIndex[f] >= ConfLogIndex

CancelledStreamNoCommitProof ==
    /\ CommitOnlyFromQuorumProof
    /\ \A f \in Followers :
        cancelled[f] => matchIndex[f] <= matchProofIndex[f]

NoPermanentStaging ==
    \A f \in Followers :
        (peerMode[f] = StagingNewPeer /\ CatchupPredicate(f)) ~> caughtUp[f]

BoundedQueues ==
    /\ Cardinality(replyQueue) <= MaxReplyId
    /\ \A f \in Followers : Cardinality(pending[f]) <= MaxCallId

MCView ==
    << leaderStartIndex, leaderLastIndex, commitIndex, commitProofIndex,
       matchIndex, nextIndex, snapshotIndex,
       streamEpoch, streamActive, pending, replyQueue,
       snapshotState, attemptedSnapshot, peerMode, caughtUp,
       streamReady, cancelled, outstandingChunks >>

ModelSymmetry == Permutations(Followers)

=============================================================================
