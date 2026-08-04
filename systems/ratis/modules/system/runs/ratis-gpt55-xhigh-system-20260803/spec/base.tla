------------------------------ MODULE base ------------------------------
(*
 * Base TLA+ specification for the Apache Ratis end-to-end Raft scope.
 *
 * Category: A (Distributed / Message-Passing).
 *
 * The model is scenario-driven from modeling-brief.md.  It keeps the Raft
 * state space finite while preserving the implementation boundaries that the
 * brief identifies as bug-hunting surfaces: non-atomic metadata persistence,
 * in-flight append composition, snapshot/config frontiers, read-index proof,
 * and gRPC appender progress.
 *)

EXTENDS Naturals, Integers, FiniteSets, TLC

\* -------------------------------------------------------------------------
\* Constants
\* -------------------------------------------------------------------------

CONSTANTS
    Server,
    EntryValue,
    NoLeader,
    NoVote,
    NoEntry,
    NoTerm,
    FOLLOWER,
    CANDIDATE,
    LEADER,
    LISTENER,
    SUCCESS,
    INCONSISTENCY,
    NOT_LEADER,
    CONFIG_OLD_NEW,
    CONFIG_NEW,
    MaxTerm,
    MaxIndex,
    MaxCallId,
    MaxEpoch,
    InitialLeaderHeartbeatCheck

ASSUME Server /= {}
ASSUME EntryValue /= {}
ASSUME MaxTerm \in Nat \ {0}
ASSUME MaxIndex \in Nat \ {0}
ASSUME MaxCallId \in Nat \ {0}
ASSUME MaxEpoch \in Nat \ {0}

Index == 1..MaxIndex
Term == 0..MaxTerm
Index0 == 0..MaxIndex
Index1 == 0..(MaxIndex + 1)
CallId == 0..MaxCallId
Epoch == 0..MaxEpoch
RoleSet == {FOLLOWER, CANDIDATE, LEADER, LISTENER}
PeerRoleSet == {FOLLOWER, LISTENER}
AppendResultSet == {SUCCESS, INCONSISTENCY, NOT_LEADER}
EntryOrEmpty == EntryValue \cup {NoEntry, CONFIG_OLD_NEW, CONFIG_NEW}
TermOrNo == Term \cup {NoTerm}
MaybeServer == Server \cup {NoLeader}
MaybeVote == Server \cup {NoVote}

\* -------------------------------------------------------------------------
\* Variables
\* -------------------------------------------------------------------------

VARIABLES
    role,
    volatileTerm,
    persistedTerm,
    persistedVote,
    votedFor,
    voteGranted,
    leaderId,
    leaderStateAlive,
    stepDownQueued,
    queuedStepDownTerm,
    maxObservedStepDownTerm,
    persistFailureAvailable,
    metadataPersistFailed,

    logTerm,
    logValue,
    logStart,
    logEnd,
    flushIndex,
    commitIndex,
    appliedIndex,
    repliedIndex,
    committedTerm,
    committedValue,

    inFlightAppend,
    composedAppend,
    appendReply,
    acceptedLeaderTerm,

    snapshotIndex,
    snapshotTerm,
    installedSnapshotIndex,
    firstAvailableLogIndex,
    installingSnapshot,
    nextChunkIndex,
    chunk0CallId,
    snapshotConfigIndex,
    attemptedInstallSnapshot,

    conf,
    oldConf,
    roleByPeer,
    stagingPeers,
    caughtUp,
    configLogIndex,
    configStored,

    nextIndex,
    matchIndex,
    pendingRequest,
    requestCallId,
    streamEpoch,
    lastReplyStatus,

    pendingReadIndex,
    readCompletedIndex,
    heartbeatAckedIndex,
    heartbeatAckedSet,
    leaderHeartbeatCheck,
    leaseValid

termRoleVars ==
    <<role, volatileTerm, persistedTerm, persistedVote, votedFor,
      voteGranted, leaderId, leaderStateAlive, stepDownQueued, queuedStepDownTerm,
      maxObservedStepDownTerm, persistFailureAvailable, metadataPersistFailed>>

entryVars ==
    <<logTerm, logValue, logStart, logEnd, flushIndex, commitIndex,
      appliedIndex, repliedIndex, committedTerm, committedValue>>

appendComposeVars ==
    <<inFlightAppend, composedAppend, appendReply, acceptedLeaderTerm>>

snapshotVars ==
    <<snapshotIndex, snapshotTerm, installedSnapshotIndex,
      firstAvailableLogIndex, installingSnapshot, nextChunkIndex,
      chunk0CallId, snapshotConfigIndex, attemptedInstallSnapshot>>

configVars ==
    <<conf, oldConf, roleByPeer, stagingPeers, caughtUp, configLogIndex,
      configStored>>

progressVars ==
    <<nextIndex, matchIndex, pendingRequest, requestCallId, streamEpoch,
      lastReplyStatus>>

readVars ==
    <<pendingReadIndex, readCompletedIndex, heartbeatAckedIndex,
      heartbeatAckedSet, leaderHeartbeatCheck, leaseValid>>

vars ==
    <<termRoleVars, entryVars, appendComposeVars, snapshotVars, configVars,
      progressVars, readVars>>

UnchangedTermRole == UNCHANGED termRoleVars
UnchangedEntries == UNCHANGED entryVars
UnchangedAppendCompose == UNCHANGED appendComposeVars
UnchangedSnapshot == UNCHANGED snapshotVars
UnchangedConfig == UNCHANGED configVars
UnchangedProgress == UNCHANGED progressVars
UnchangedRead == UNCHANGED readVars

UnchangedNonTermRole ==
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

UnchangedNonEntries ==
    /\ UnchangedTermRole
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

UnchangedNonAppendCompose ==
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

UnchangedNonSnapshot ==
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

UnchangedNonConfig ==
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedProgress
    /\ UnchangedRead

UnchangedNonProgress ==
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedRead

UnchangedNonRead ==
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress

\* -------------------------------------------------------------------------
\* Record constructors
\* -------------------------------------------------------------------------

EmptyInFlight ==
    [present |-> FALSE, leader |-> NoLeader, callId |-> 0, start |-> 1,
     term |-> 0, value |-> NoEntry, done |-> FALSE, replied |-> FALSE]

EmptyComposed ==
    [present |-> FALSE, leader |-> NoLeader, callId |-> 0, start |-> 1,
     term |-> 0, value |-> NoEntry]

EmptyReply ==
    [present |-> FALSE, leader |-> NoLeader, callId |-> 0, result |-> NOT_LEADER,
     match |-> 0, next |-> 1, term |-> 0, value |-> NoEntry, followerCommit |-> 0]

EmptyPending ==
    [present |-> FALSE, leader |-> NoLeader, callId |-> 0, first |-> 1,
     last |-> 0, term |-> 0, value |-> NoEntry, stream |-> 0,
     heartbeat |-> FALSE]

InFlightRecordSet ==
    [present: BOOLEAN, leader: MaybeServer, callId: CallId, start: Index,
     term: Term, value: EntryOrEmpty, done: BOOLEAN, replied: BOOLEAN]

ComposedRecordSet ==
    [present: BOOLEAN, leader: MaybeServer, callId: CallId, start: Index,
     term: Term, value: EntryOrEmpty]

ReplyRecordSet ==
    [present: BOOLEAN, leader: MaybeServer, callId: CallId,
     result: AppendResultSet, match: Index0, next: Index1, term: Term,
     value: EntryOrEmpty, followerCommit: Index0]

PendingRecordSet ==
    [present: BOOLEAN, leader: MaybeServer, callId: CallId, first: Index,
     last: Index0, term: Term, value: EntryOrEmpty, stream: Epoch,
     heartbeat: BOOLEAN]

\* -------------------------------------------------------------------------
\* Helpers
\* -------------------------------------------------------------------------

Max2(a, b) == IF a >= b THEN a ELSE b
Min2(a, b) == IF a <= b THEN a ELSE b
StepDownTerm(s) ==
    IF stepDownQueued[s] /\ queuedStepDownTerm[s] # NoTerm
    THEN queuedStepDownTerm[s]
    ELSE volatileTerm[s]

Majority(acked, voters) ==
    /\ voters /= {}
    /\ 2 * Cardinality(acked \cap voters) > Cardinality(voters)

JointMajority(acked) ==
    IF oldConf = {}
    THEN Majority(acked, conf)
    ELSE Majority(acked, conf) /\ Majority(acked, oldConf)

HasLogAt(s, i) ==
    /\ s \in Server
    /\ i \in Index
    /\ logStart[s] <= i
    /\ i <= logEnd[s]
    /\ logTerm[s][i] # 0

SnapshotCovers(s, i) ==
    /\ s \in Server
    /\ i \in Index0
    /\ i <= snapshotIndex[s]

ContainsEntry(s, i, t, v) ==
    /\ HasLogAt(s, i)
    /\ logTerm[s][i] = t
    /\ logValue[s][i] = v

ContainsOrCovers(s, i, t, v) ==
    \/ SnapshotCovers(s, i)
    \/ ContainsEntry(s, i, t, v)

PreviousMatchesFollower(s, i, t, v) ==
    IF i = 1
    THEN TRUE
    ELSE ContainsOrCovers(s, i - 1, t, v)

AppendConsistent(s, i) ==
    /\ ~installingSnapshot[s]
    /\ i > Max2(snapshotIndex[s], commitIndex[s])
    /\ IF i = 1 THEN TRUE ELSE i - 1 <= logEnd[s] \/ SnapshotCovers(s, i - 1)

IndexStoredOrSnap(s, i) ==
    \/ i = 0
    \/ configStored[s] >= i
    \/ snapshotConfigIndex[s] >= i

CanCommit(l, i) ==
    /\ l \in Server
    /\ i \in Index
    /\ role[l] = LEADER
    /\ i > commitIndex[l]
    /\ HasLogAt(l, i)
    /\ logTerm[l][i] = volatileTerm[l]
    /\ flushIndex[l] >= i
    /\ JointMajority({l} \cup
        {s \in Server \ {l}:
            /\ matchIndex[s] >= i
            /\ ContainsOrCovers(s, i, logTerm[l][i], logValue[l][i])})

ReadProofOK(l, i) ==
    /\ i \in Index0
    /\ commitIndex[l] >= i
    /\ appliedIndex[l] >= i
    /\ repliedIndex[l] >= i
    /\ (leaderHeartbeatCheck[l] => (leaseValid[l] \/ heartbeatAckedIndex[l] >= i))

\* -------------------------------------------------------------------------
\* Init
\* -------------------------------------------------------------------------

Init ==
    /\ role = [s \in Server |-> FOLLOWER]
    /\ volatileTerm = [s \in Server |-> 0]
    /\ persistedTerm = [s \in Server |-> 0]
    /\ persistedVote = [s \in Server |-> NoVote]
    /\ votedFor = [s \in Server |-> NoVote]
    /\ voteGranted = [v \in Server |-> [c \in Server |-> FALSE]]
    /\ leaderId = [s \in Server |-> NoLeader]
    /\ leaderStateAlive = [s \in Server |-> FALSE]
    /\ stepDownQueued = [s \in Server |-> FALSE]
    /\ queuedStepDownTerm = [s \in Server |-> NoTerm]
    /\ maxObservedStepDownTerm = [s \in Server |-> 0]
    /\ persistFailureAvailable = [s \in Server |-> TRUE]
    /\ metadataPersistFailed = [s \in Server |-> FALSE]

    /\ logTerm = [s \in Server |-> [i \in Index |-> 0]]
    /\ logValue = [s \in Server |-> [i \in Index |-> NoEntry]]
    /\ logStart = [s \in Server |-> 1]
    /\ logEnd = [s \in Server |-> 0]
    /\ flushIndex = [s \in Server |-> 0]
    /\ commitIndex = [s \in Server |-> 0]
    /\ appliedIndex = [s \in Server |-> 0]
    /\ repliedIndex = [s \in Server |-> 0]
    /\ committedTerm = [i \in Index |-> 0]
    /\ committedValue = [i \in Index |-> NoEntry]

    /\ inFlightAppend = [s \in Server |-> EmptyInFlight]
    /\ composedAppend = [s \in Server |-> EmptyComposed]
    /\ appendReply = [s \in Server |-> EmptyReply]
    /\ acceptedLeaderTerm = [s \in Server |-> 0]

    /\ snapshotIndex = [s \in Server |-> 0]
    /\ snapshotTerm = [s \in Server |-> 0]
    /\ installedSnapshotIndex = [s \in Server |-> 0]
    /\ firstAvailableLogIndex = [s \in Server |-> 1]
    /\ installingSnapshot = [s \in Server |-> FALSE]
    /\ nextChunkIndex = [s \in Server |-> 0]
    /\ chunk0CallId = [s \in Server |-> 0]
    /\ snapshotConfigIndex = [s \in Server |-> 0]
    /\ attemptedInstallSnapshot = [s \in Server |-> FALSE]

    /\ conf = Server
    /\ oldConf = {}
    /\ roleByPeer = [s \in Server |-> FOLLOWER]
    /\ stagingPeers = {}
    /\ caughtUp = [s \in Server |-> TRUE]
    /\ configLogIndex = 0
    /\ configStored = [s \in Server |-> 0]

    /\ nextIndex = [s \in Server |-> 1]
    /\ matchIndex = [s \in Server |-> 0]
    /\ pendingRequest = [s \in Server |-> EmptyPending]
    /\ requestCallId = [s \in Server |-> 0]
    /\ streamEpoch = [s \in Server |-> 0]
    /\ lastReplyStatus = [s \in Server |-> NOT_LEADER]

    /\ pendingReadIndex = [s \in Server |-> 0]
    /\ readCompletedIndex = [s \in Server |-> 0]
    /\ heartbeatAckedIndex = [s \in Server |-> 0]
    /\ heartbeatAckedSet = [s \in Server |-> {}]
    /\ leaderHeartbeatCheck = [s \in Server |-> InitialLeaderHeartbeatCheck]
    /\ leaseValid = [s \in Server |-> FALSE]

\* -------------------------------------------------------------------------
\* Election, term, and metadata persistence actions
\* -------------------------------------------------------------------------

\* ServerState.initElection(Phase.ELECTION): ServerState.java:228-237
ServerState_initElection_ELECTION(s) ==
    /\ s \in Server
    /\ role[s] \in {FOLLOWER, CANDIDATE}
    /\ volatileTerm[s] < MaxTerm
    \* ServerState.java:229-236 clears leader, increments currentTerm,
    \* votes for self, and persists metadata in the election phase.
    /\ role' = [role EXCEPT ![s] = CANDIDATE]
    /\ volatileTerm' = [volatileTerm EXCEPT ![s] = @ + 1]
    /\ votedFor' = [votedFor EXCEPT ![s] = s]
    /\ voteGranted' =
        [voteGranted EXCEPT ![s] =
            [voteGranted[s] EXCEPT ![s] = TRUE]]
    /\ leaderId' = [leaderId EXCEPT ![s] = NoLeader]
    /\ persistedTerm' = [persistedTerm EXCEPT ![s] = volatileTerm[s] + 1]
    /\ persistedVote' = [persistedVote EXCEPT ![s] = s]
    /\ UNCHANGED <<leaderStateAlive, stepDownQueued, queuedStepDownTerm,
                  maxObservedStepDownTerm, persistFailureAvailable,
                  metadataPersistFailed>>
    /\ UnchangedNonTermRole

\* RaftServerImpl.requestVote: RaftServerImpl.java:1496-1542
RaftServerImpl_requestVote_Grant(voter, candidate) ==
    /\ voter \in Server
    /\ candidate \in Server \ {voter}
    /\ role[candidate] = CANDIDATE
    /\ candidate \in conf
    /\ volatileTerm[candidate] >= volatileTerm[voter]
    /\ volatileTerm[candidate] > volatileTerm[voter]
       \/ votedFor[voter] \in {NoVote, candidate}
    /\ logEnd[candidate] >= logEnd[voter]
    \* RaftServerImpl.java:1513-1525 recognizes the candidate, changes
    \* to follower in ELECTION, grants the vote, and syncs metadata.
    /\ role' = [role EXCEPT ![voter] = FOLLOWER]
    /\ volatileTerm' = [volatileTerm EXCEPT ![voter] = volatileTerm[candidate]]
    /\ votedFor' = [votedFor EXCEPT ![voter] = candidate]
    /\ voteGranted' =
        [voteGranted EXCEPT ![voter] =
            [voteGranted[voter] EXCEPT ![candidate] = TRUE]]
    /\ leaderId' = [leaderId EXCEPT ![voter] = NoLeader]
    /\ persistedTerm' = [persistedTerm EXCEPT ![voter] = volatileTerm[candidate]]
    /\ persistedVote' = [persistedVote EXCEPT ![voter] = candidate]
    /\ leaderStateAlive' = [leaderStateAlive EXCEPT ![voter] = FALSE]
    /\ UNCHANGED <<stepDownQueued, queuedStepDownTerm, maxObservedStepDownTerm,
                  persistFailureAvailable, metadataPersistFailed>>
    /\ UnchangedNonTermRole

\* RaftServerImpl.changeToLeader: RaftServerImpl.java:650-658
RaftServerImpl_changeToLeader(s) ==
    /\ s \in Server
    /\ role[s] = CANDIDATE
    /\ s \in conf
    /\ Majority({v \in Server: persistedTerm[v] = volatileTerm[s] /\ persistedVote[v] = s}, conf)
    \* RaftServerImpl.java:652-655 shuts down election, installs leader state,
    \* and records this server as leader for the current term.
    /\ role' = [role EXCEPT ![s] = LEADER]
    /\ leaderId' = [leaderId EXCEPT ![s] = s]
    /\ leaderStateAlive' = [leaderStateAlive EXCEPT ![s] = TRUE]
    /\ stepDownQueued' = [stepDownQueued EXCEPT ![s] = FALSE]
    /\ queuedStepDownTerm' = [queuedStepDownTerm EXCEPT ![s] = NoTerm]
    /\ UNCHANGED <<volatileTerm, persistedTerm, persistedVote, votedFor, voteGranted,
                  maxObservedStepDownTerm, persistFailureAvailable,
                  metadataPersistFailed>>
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ nextIndex' =
        [p \in Server |-> IF p = s THEN nextIndex[p] ELSE logEnd[s] + 1]
    /\ UNCHANGED <<matchIndex, pendingRequest, requestCallId, streamEpoch,
                  lastReplyStatus>>
    /\ UnchangedRead

\* ServerState.updateCurrentTerm + RaftServerImpl.changeToFollowerAndPersistMetadata failure:
\* ServerState.java:211-219, RaftServerImpl.java:638-647, RaftServerImpl.java:1662-1665
RaftServerImpl_changeToFollowerAndPersistMetadata_PersistFailure(s, leader, newTerm) ==
    /\ s \in Server
    /\ leader \in Server \ {s}
    /\ newTerm \in Term
    /\ newTerm > volatileTerm[s]
    /\ persistFailureAvailable[s]
    \* ServerState.java:211-216 updates volatile term, clears votedFor and
    \* leader before RaftServerImpl.java:644-646 persists metadata.
    /\ role' = [role EXCEPT ![s] = FOLLOWER]
    /\ volatileTerm' = [volatileTerm EXCEPT ![s] = newTerm]
    /\ votedFor' = [votedFor EXCEPT ![s] = NoVote]
    /\ leaderId' = [leaderId EXCEPT ![s] = NoLeader]
    /\ leaderStateAlive' = [leaderStateAlive EXCEPT ![s] = FALSE]
    \* RaftServerImpl.java:1662-1665 returns an exceptional future when
    \* persistMetadata throws; the durable term remains old.
    /\ persistFailureAvailable' = [persistFailureAvailable EXCEPT ![s] = FALSE]
    /\ metadataPersistFailed' = [metadataPersistFailed EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<persistedTerm, persistedVote, voteGranted, stepDownQueued,
                  queuedStepDownTerm, maxObservedStepDownTerm>>
    /\ UnchangedNonTermRole

\* ServerState.persistMetadata: ServerState.java:243-245
ServerState_persistMetadata(s) ==
    /\ s \in Server
    /\ persistedTerm[s] < volatileTerm[s] \/ persistedVote[s] /= votedFor[s]
    \* ServerState.java:243-245 persists currentTerm and votedFor together
    \* to the RaftStorageMetadata file.
    /\ persistedTerm' = [persistedTerm EXCEPT ![s] = volatileTerm[s]]
    /\ persistedVote' = [persistedVote EXCEPT ![s] = votedFor[s]]
    /\ metadataPersistFailed' = [metadataPersistFailed EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<role, volatileTerm, votedFor, voteGranted, leaderId, leaderStateAlive,
                  stepDownQueued, queuedStepDownTerm, maxObservedStepDownTerm,
                  persistFailureAvailable>>
    /\ UnchangedNonTermRole

\* LeaderStateImpl.submitStepDownEvent / StateUpdateEvent.equals:
\* LeaderStateImpl.java:129-137, LeaderStateImpl.java:156-158, LeaderStateImpl.java:738-740
LeaderStateImpl_submitStepDownEvent(s, observedTerm) ==
    /\ s \in Server
    /\ role[s] = LEADER
    /\ observedTerm \in Term
    /\ observedTerm >= volatileTerm[s]
    \* LeaderStateImpl.java:738-740 captures a concrete term in the event
    \* handler, but StateUpdateEvent.equals compares only event type.
    /\ maxObservedStepDownTerm' =
        [maxObservedStepDownTerm EXCEPT ![s] = Max2(@, observedTerm)]
    /\ IF stepDownQueued[s]
       THEN /\ stepDownQueued' = stepDownQueued
            /\ queuedStepDownTerm' = queuedStepDownTerm
       ELSE /\ stepDownQueued' = [stepDownQueued EXCEPT ![s] = TRUE]
            /\ queuedStepDownTerm' = [queuedStepDownTerm EXCEPT ![s] = observedTerm]
    /\ UNCHANGED <<role, volatileTerm, persistedTerm, persistedVote, votedFor, voteGranted,
                  leaderId, leaderStateAlive, persistFailureAvailable,
                  metadataPersistFailed>>
    /\ UnchangedNonTermRole

\* LeaderStateImpl.stepDown: LeaderStateImpl.java:742-758
LeaderStateImpl_stepDown(s) ==
    /\ s \in Server
    /\ role[s] = LEADER
    /\ \/ /\ stepDownQueued[s]
          /\ queuedStepDownTerm[s] # NoTerm
          /\ queuedStepDownTerm[s] >= volatileTerm[s]
       \/ /\ ~stepDownQueued[s]
          /\ queuedStepDownTerm[s] = NoTerm
    \* LeaderStateImpl.java:742-746 disables lease and calls
    \* changeToFollowerAndPersistMetadata(term, false, reason).
    /\ role' = [role EXCEPT ![s] = FOLLOWER]
    /\ volatileTerm' = [volatileTerm EXCEPT ![s] = Max2(volatileTerm[s], StepDownTerm(s))]
    /\ persistedTerm' = [persistedTerm EXCEPT ![s] = Max2(persistedTerm[s], StepDownTerm(s))]
    /\ persistedVote' = [persistedVote EXCEPT ![s] = votedFor[s]]
    /\ leaderId' = [leaderId EXCEPT ![s] = NoLeader]
    /\ leaderStateAlive' = [leaderStateAlive EXCEPT ![s] = FALSE]
    /\ stepDownQueued' = [stepDownQueued EXCEPT ![s] = FALSE]
    /\ queuedStepDownTerm' = [queuedStepDownTerm EXCEPT ![s] = NoTerm]
    /\ leaseValid' = [leaseValid EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<votedFor, voteGranted, maxObservedStepDownTerm, persistFailureAvailable,
                  metadataPersistFailed>>
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UNCHANGED <<pendingReadIndex, readCompletedIndex, heartbeatAckedIndex,
                  heartbeatAckedSet, leaderHeartbeatCheck>>

\* -------------------------------------------------------------------------
\* Leader local append, follower AppendEntries, and append composition
\* -------------------------------------------------------------------------

\* RaftServerImpl.appendTransaction: RaftServerImpl.java:869-924
RaftServerImpl_appendTransaction(l, value) ==
    /\ l \in Server
    /\ value \in EntryValue
    /\ role[l] = LEADER
    /\ logEnd[l] < MaxIndex
    /\ LET idx == logEnd[l] + 1 IN
       /\ idx \in Index
       \* RaftServerImpl.java:902-905 appends the transaction to the
       \* leader's local log before notifying senders.
       /\ logTerm' = [logTerm EXCEPT ![l] = [@ EXCEPT ![idx] = volatileTerm[l]]]
       /\ logValue' = [logValue EXCEPT ![l] = [@ EXCEPT ![idx] = value]]
       /\ logEnd' = [logEnd EXCEPT ![l] = idx]
       /\ flushIndex' = [flushIndex EXCEPT ![l] = idx]
    /\ UNCHANGED <<logStart, commitIndex, appliedIndex, repliedIndex,
                  committedTerm, committedValue>>
    /\ UnchangedTermRole
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

\* GrpcLogAppender.appendLog: GrpcLogAppender.java:392-418
GrpcLogAppender_appendLog(l, f) ==
    /\ l \in Server
    /\ f \in Server \ {l}
    /\ role[l] = LEADER
    /\ pendingRequest[f].present = FALSE
    /\ requestCallId[l] < MaxCallId
    /\ nextIndex[f] \in Index
    /\ nextIndex[f] <= logEnd[l]
    \* GrpcLogAppender.java:398-404 creates the request, records it in
    \* pendingRequests, and then increaseNextIndex() advances follower next.
    /\ LET idx == nextIndex[f] IN
       /\ pendingRequest' =
            [pendingRequest EXCEPT ![f] =
                [present |-> TRUE, leader |-> l, callId |-> requestCallId[l],
                 first |-> idx, last |-> idx, term |-> logTerm[l][idx],
                 value |-> logValue[l][idx], stream |-> streamEpoch[f],
                 heartbeat |-> FALSE]]
       /\ nextIndex' = [nextIndex EXCEPT ![f] = idx + 1]
    /\ requestCallId' = [requestCallId EXCEPT ![l] = @ + 1]
    /\ UNCHANGED <<matchIndex, streamEpoch, lastReplyStatus>>
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedRead

\* RaftServerImpl.appendEntriesAsync register path:
\* RaftServerImpl.java:1652-1696, ServerImplUtils.java:145-150
RaftServerImpl_appendEntriesAsync_RegisterInFlight(s) ==
    /\ s \in Server
    /\ pendingRequest[s].present
    /\ inFlightAppend[s].present = FALSE
    /\ AppendConsistent(s, pendingRequest[s].first)
    /\ pendingRequest[s].term >= volatileTerm[s]
    /\ leaderId[s] \in {NoLeader, pendingRequest[s].leader}
    \* RaftServerImpl.java:1656-1668 recognizes leader, changes to
    \* follower, persists metadata if the term increased, and records leader.
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
    \* ServerImplUtils.java:145-150 records the in-flight append range
    \* before the physical SegmentedRaftLog append future completes.
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
    /\ UNCHANGED composedAppend
    /\ UNCHANGED appendReply
    /\ UnchangedEntries
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

\* ServerImplUtils.NavigableIndices.append alreadyExists branch:
\* ServerImplUtils.java:145-164
ServerImplUtils_NavigableIndices_append_ComposeExisting(s) ==
    /\ s \in Server
    /\ pendingRequest[s].present
    /\ inFlightAppend[s].present
    /\ inFlightAppend[s].start = pendingRequest[s].first
    /\ ~inFlightAppend[s].replied
    /\ composedAppend[s].present = FALSE
    /\ pendingRequest[s].term >= volatileTerm[s]
    /\ leaderId[s] \in {NoLeader, pendingRequest[s].leader}
    \* RaftServerImpl.java:1656-1668 still recognizes the new leader and
    \* may persist a higher term before ServerImplUtils.java:153-164
    \* decides the start index already exists and reuses the old future.
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
    /\ composedAppend' =
        [composedAppend EXCEPT ![s] =
            [present |-> TRUE, leader |-> pendingRequest[s].leader,
             callId |-> pendingRequest[s].callId,
             start |-> pendingRequest[s].first,
             term |-> pendingRequest[s].term,
             value |-> pendingRequest[s].value]]
    /\ acceptedLeaderTerm' =
        [acceptedLeaderTerm EXCEPT ![s] = Max2(@, pendingRequest[s].term)]
    /\ UNCHANGED <<voteGranted, stepDownQueued, queuedStepDownTerm, maxObservedStepDownTerm,
                  persistFailureAvailable, metadataPersistFailed>>
    /\ UNCHANGED inFlightAppend
    /\ UNCHANGED appendReply
    /\ UnchangedEntries
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

\* RaftServerImpl.appendEntriesAsync heartbeat/register path without a
\* traceable log entry: RaftServerImpl.java:1656-1685,
\* ServerState.java:213-218, ServerState.java:246-249.
RaftServerImpl_appendEntriesAsync_RecognizeLeaderHeartbeat(s, ldr, t) ==
    /\ s \in Server
    /\ ldr \in Server \ {s}
    /\ t \in Term \ {0}
    /\ role[ldr] = LEADER
    /\ volatileTerm[ldr] = t
    /\ t >= volatileTerm[s]
    /\ t > volatileTerm[s] \/ leaderId[s] \in {NoLeader, ldr}
    /\ role' = [role EXCEPT ![s] = FOLLOWER]
    /\ volatileTerm' = [volatileTerm EXCEPT ![s] = t]
    /\ votedFor' =
        [votedFor EXCEPT ![s] =
            IF t > volatileTerm[s] THEN NoVote ELSE @]
    /\ leaderId' = [leaderId EXCEPT ![s] = ldr]
    /\ leaderStateAlive' = [leaderStateAlive EXCEPT ![s] = FALSE]
    /\ persistedTerm' =
        [persistedTerm EXCEPT ![s] =
            IF t > volatileTerm[s] THEN t ELSE @]
    /\ persistedVote' =
        [persistedVote EXCEPT ![s] =
            IF t > volatileTerm[s] THEN NoVote ELSE @]
    /\ acceptedLeaderTerm' = [acceptedLeaderTerm EXCEPT ![s] = Max2(@, t)]
    /\ UNCHANGED <<voteGranted, stepDownQueued, queuedStepDownTerm, maxObservedStepDownTerm,
                  persistFailureAvailable, metadataPersistFailed>>
    /\ UNCHANGED <<logTerm, logValue, logStart, logEnd, flushIndex,
                  commitIndex, appliedIndex, repliedIndex, committedTerm,
                  committedValue>>
    /\ UNCHANGED <<inFlightAppend, composedAppend, appendReply>>
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

\* RaftServerImpl.checkInconsistentAppendEntries: RaftServerImpl.java:1739-1771
RaftServerImpl_appendEntriesAsync_InconsistencyReply(s) ==
    /\ s \in Server
    /\ pendingRequest[s].present
    /\ pendingRequest[s].term >= volatileTerm[s]
    /\ pendingRequest[s].term > volatileTerm[s]
       \/ leaderId[s] \in {NoLeader, pendingRequest[s].leader}
    /\ \/ installingSnapshot[s]
       \/ pendingRequest[s].first <= Max2(snapshotIndex[s], commitIndex[s])
       \/ ~AppendConsistent(s, pendingRequest[s].first)
    \* RaftServerImpl.java:1673-1685 recognizes leader and persists a higher
    \* term before the inconsistency checks at lines 1692-1747.
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
    \* RaftServerImpl.java:1739-1771 returns INCONSISTENCY before appending
    \* when snapshot install, overlap, or gap checks fail.
    /\ appendReply' =
        [appendReply EXCEPT ![s] =
            [present |-> TRUE, leader |-> pendingRequest[s].leader,
             callId |-> pendingRequest[s].callId, result |-> INCONSISTENCY,
             match |-> 0, next |-> Max2(1, logEnd[s] + 1),
             term |-> pendingRequest[s].term, value |-> NoEntry,
             followerCommit |-> commitIndex[s]]]
    /\ lastReplyStatus' = [lastReplyStatus EXCEPT ![s] = INCONSISTENCY]
    /\ acceptedLeaderTerm' =
        [acceptedLeaderTerm EXCEPT ![s] = Max2(@, pendingRequest[s].term)]
    /\ UNCHANGED <<voteGranted, stepDownQueued, queuedStepDownTerm, maxObservedStepDownTerm,
                  persistFailureAvailable, metadataPersistFailed>>
    /\ UnchangedEntries
    /\ UNCHANGED <<inFlightAppend, composedAppend>>
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UNCHANGED <<nextIndex, matchIndex, pendingRequest, requestCallId,
                  streamEpoch>>
    /\ UnchangedRead

\* SegmentedRaftLog.appendImpl: SegmentedRaftLog.java:464-486
SegmentedRaftLog_appendImpl_CompletePhysicalAppend(s) ==
    /\ s \in Server
    /\ inFlightAppend[s].present
    /\ ~inFlightAppend[s].done
    /\ AppendConsistent(s, inFlightAppend[s].start)
    \* SegmentedRaftLog.java:470-484 computes truncation and appends the
    \* concrete entries under the log write lock.
    /\ LET idx == inFlightAppend[s].start IN
       /\ logTerm' =
            [logTerm EXCEPT ![s] =
                [i \in Index |->
                    IF i < idx THEN logTerm[s][i]
                    ELSE IF i = idx THEN inFlightAppend[s].term ELSE 0]]
       /\ logValue' =
            [logValue EXCEPT ![s] =
                [i \in Index |->
                    IF i < idx THEN logValue[s][i]
                    ELSE IF i = idx THEN inFlightAppend[s].value ELSE NoEntry]]
       /\ logEnd' = [logEnd EXCEPT ![s] = idx]
       /\ flushIndex' = [flushIndex EXCEPT ![s] = idx]
       /\ configStored' =
            [configStored EXCEPT ![s] =
                IF inFlightAppend[s].value \in {CONFIG_OLD_NEW, CONFIG_NEW}
                THEN Max2(@, idx) ELSE @]
    /\ inFlightAppend' = [inFlightAppend EXCEPT ![s].done = TRUE]
    /\ UNCHANGED <<logStart, commitIndex, appliedIndex, repliedIndex,
                  committedTerm, committedValue>>
    /\ UnchangedTermRole
    /\ UNCHANGED <<composedAppend, appendReply, acceptedLeaderTerm>>
    /\ UnchangedSnapshot
    /\ UNCHANGED <<conf, oldConf, roleByPeer, stagingPeers, caughtUp,
                  configLogIndex>>
    /\ UnchangedProgress
    /\ UnchangedRead

\* RaftServerImpl.appendEntriesAsync reply success:
\* RaftServerImpl.java:1709-1730
RaftServerImpl_appendEntriesAsync_ReplyOriginal(s) ==
    /\ s \in Server
    /\ inFlightAppend[s].present
    /\ inFlightAppend[s].done
    /\ ~inFlightAppend[s].replied
    \* RaftServerImpl.java:1720-1727 updates commit index and constructs a
    \* SUCCESS reply with matchIndex = last appended entry.
    /\ appendReply' =
        [appendReply EXCEPT ![s] =
            [present |-> TRUE, leader |-> inFlightAppend[s].leader,
             callId |-> inFlightAppend[s].callId, result |-> SUCCESS,
             match |-> inFlightAppend[s].start,
             next |-> inFlightAppend[s].start + 1,
             term |-> inFlightAppend[s].term,
             value |-> inFlightAppend[s].value,
             followerCommit |-> commitIndex[s]]]
    /\ inFlightAppend' = [inFlightAppend EXCEPT ![s].replied = TRUE]
    /\ lastReplyStatus' = [lastReplyStatus EXCEPT ![s] = SUCCESS]
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UNCHANGED <<composedAppend, acceptedLeaderTerm>>
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UNCHANGED <<nextIndex, matchIndex, pendingRequest, requestCallId,
                  streamEpoch>>
    /\ UnchangedRead

\* RaftServerImpl.appendEntriesAsync reply for a composed append that reused
\* the original future: RaftServerImpl.java:1694-1696, ServerImplUtils.java:148
RaftServerImpl_appendEntriesAsync_ReplyComposed(s) ==
    /\ s \in Server
    /\ composedAppend[s].present
    /\ inFlightAppend[s].present
    /\ inFlightAppend[s].done
    \* ServerImplUtils.java:148 returns the existing future; when it
    \* completes, RaftServerImpl.java:1725-1727 can report SUCCESS for the
    \* later composed request even though that request's entry was not appended.
    /\ appendReply' =
        [appendReply EXCEPT ![s] =
            [present |-> TRUE, leader |-> composedAppend[s].leader,
             callId |-> composedAppend[s].callId, result |-> SUCCESS,
             match |-> composedAppend[s].start,
             next |-> composedAppend[s].start + 1,
             term |-> composedAppend[s].term,
             value |-> composedAppend[s].value,
             followerCommit |-> commitIndex[s]]]
    /\ composedAppend' = [composedAppend EXCEPT ![s] = EmptyComposed]
    /\ lastReplyStatus' = [lastReplyStatus EXCEPT ![s] = SUCCESS]
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UNCHANGED <<inFlightAppend, acceptedLeaderTerm>>
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UNCHANGED <<nextIndex, matchIndex, pendingRequest, requestCallId,
                  streamEpoch>>
    /\ UnchangedRead

\* Cleanup of the append composition cache after both original and composed
\* waiters have observed the future: ServerImplUtils.java:169-173
ServerImplUtils_NavigableIndices_removeExisting(s) ==
    /\ s \in Server
    /\ inFlightAppend[s].present
    /\ inFlightAppend[s].done
    /\ inFlightAppend[s].replied
    /\ composedAppend[s].present = FALSE
    /\ inFlightAppend' = [inFlightAppend EXCEPT ![s] = EmptyInFlight]
    /\ UNCHANGED <<composedAppend, appendReply, acceptedLeaderTerm>>
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

\* -------------------------------------------------------------------------
\* Leader response handling, commit, read visibility, and gRPC progress
\* -------------------------------------------------------------------------

\* GrpcLogAppender.AppendLogResponseHandler.onNext SUCCESS:
\* GrpcLogAppender.java:487-539, FollowerInfoImpl.java:93-119
GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS(l, f) ==
    /\ l \in Server
    /\ f \in Server \ {l}
    /\ appendReply[f].present
    /\ appendReply[f].leader = l
    /\ appendReply[f].result = SUCCESS
    \* GrpcLogAppender.java:512-519 updates follower commit, matchIndex,
    \* nextIndex, and then notifies LeaderStateImpl.
    /\ matchIndex' = [matchIndex EXCEPT ![f] = Max2(@, appendReply[f].match)]
    /\ nextIndex' = [nextIndex EXCEPT ![f] = Max2(@, appendReply[f].match + 1)]
    /\ lastReplyStatus' = [lastReplyStatus EXCEPT ![f] = SUCCESS]
    /\ pendingRequest' =
        [pendingRequest EXCEPT ![f] =
            IF pendingRequest[f].present
               /\ pendingRequest[f].leader = l
               /\ pendingRequest[f].callId = appendReply[f].callId
            THEN EmptyPending ELSE @]
    /\ appendReply' = [appendReply EXCEPT ![f] = EmptyReply]
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UNCHANGED <<inFlightAppend, composedAppend, acceptedLeaderTerm>>
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UNCHANGED <<requestCallId, streamEpoch>>
    /\ UnchangedRead

\* Delayed old stream success reply after reconnect/timeout:
\* GrpcLogAppender.java:487-539, GrpcLogAppender.java:556-557
GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_OldStream(l, f, idx) ==
    /\ l \in Server
    /\ f \in Server \ {l}
    /\ role[l] = LEADER
    /\ idx \in Index
    /\ idx > matchIndex[f]
    /\ HasLogAt(l, idx)
    /\ ContainsOrCovers(f, idx, logTerm[l][idx], logValue[l][idx])
    \* GrpcLogAppender.java:488 removes by reply; request may be null.
    \* GrpcLogAppender.java:512-519 still applies SUCCESS progress from
    \* the reply's matchIndex without requiring a matching pending request.
    /\ matchIndex' = [matchIndex EXCEPT ![f] = idx]
    /\ nextIndex' = [nextIndex EXCEPT ![f] = idx + 1]
    /\ lastReplyStatus' = [lastReplyStatus EXCEPT ![f] = SUCCESS]
    /\ UNCHANGED <<pendingRequest, requestCallId, streamEpoch>>
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedRead

\* GrpcLogAppender.timeoutAppendRequest: GrpcLogAppender.java:448-456
GrpcLogAppender_timeoutAppendRequest(f) ==
    /\ f \in Server
    /\ pendingRequest[f].present
    \* GrpcLogAppender.java:449-456 removes the pending request and updates
    \* error state without changing nextIndex directly.
    /\ pendingRequest' = [pendingRequest EXCEPT ![f] = EmptyPending]
    /\ lastReplyStatus' = [lastReplyStatus EXCEPT ![f] = INCONSISTENCY]
    /\ UNCHANGED <<nextIndex, matchIndex, requestCallId, streamEpoch>>
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedRead

\* GrpcLogAppender.resetClient: GrpcLogAppender.java:206-232,
\* LogAppenderBase.getNextIndexForError: LogAppenderBase.java:193-208
GrpcLogAppender_resetClient(f) ==
    /\ f \in Server
    /\ streamEpoch[f] < MaxEpoch
    \* GrpcLogAppender.java:209-215 stops observers and clears pending
    \* requests; lines 221-230 keep nextIndex on null/error or heartbeat.
    /\ pendingRequest' = [pendingRequest EXCEPT ![f] = EmptyPending]
    /\ streamEpoch' = [streamEpoch EXCEPT ![f] = @ + 1]
    /\ nextIndex' =
        [nextIndex EXCEPT ![f] =
            IF pendingRequest[f].present /\ ~pendingRequest[f].heartbeat
            THEN Max2(matchIndex[f] + 1, Min2(nextIndex[f], pendingRequest[f].first))
            ELSE @]
    /\ lastReplyStatus' = [lastReplyStatus EXCEPT ![f] = INCONSISTENCY]
    /\ UNCHANGED <<matchIndex, requestCallId>>
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedRead

\* LeaderStateImpl.updateCommit: LeaderStateImpl.java:946-1025,
\* RaftLogBase.updateCommitIndex: RaftLogBase.java:122-134
LeaderStateImpl_updateCommit(l, i) ==
    /\ l \in Server
    /\ i \in Index
    /\ CanCommit(l, i)
    \* LeaderStateImpl.java:1015-1022 reads log headers before calling
    \* ServerState.updateCommitIndex; RaftLogBase.java:122-134 clamps to
    \* flush index and requires current-term entries on leaders.
    /\ commitIndex' = [commitIndex EXCEPT ![l] = i]
    /\ committedTerm' = [committedTerm EXCEPT ![i] = logTerm[l][i]]
    /\ committedValue' = [committedValue EXCEPT ![i] = logValue[l][i]]
    /\ UNCHANGED <<logTerm, logValue, logStart, logEnd, flushIndex,
                  appliedIndex, repliedIndex>>
    /\ UnchangedTermRole
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

\* StateMachineUpdater via ServerState.updateCommitIndex notification:
\* ServerState.java:413-418, ReadRequests.java:104-120
StateMachineUpdater_applyEntry(s) ==
    /\ s \in Server
    /\ appliedIndex[s] < commitIndex[s]
    \* ServerState.java:413-418 notifies the updater after commit advances;
    \* ReadRequests.java:104-120 completes read futures up to appliedIndex.
    /\ appliedIndex' = [appliedIndex EXCEPT ![s] = @ + 1]
    /\ UNCHANGED <<logTerm, logValue, logStart, logEnd, flushIndex,
                  commitIndex, repliedIndex, committedTerm, committedValue>>
    /\ UnchangedTermRole
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

\* ReplyFlusher.flush: ReplyFlusher.java:127-148
ReplyFlusher_flush(s) ==
    /\ s \in Server
    /\ repliedIndex[s] < appliedIndex[s]
    \* ReplyFlusher.java:131-143 drains held replies and advances
    \* repliedIndex to the max log index being completed.
    /\ repliedIndex' = [repliedIndex EXCEPT ![s] = appliedIndex[s]]
    /\ UNCHANGED <<logTerm, logValue, logStart, logEnd, flushIndex,
                  commitIndex, appliedIndex, committedTerm, committedValue>>
    /\ UnchangedTermRole
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

\* LeaderStateImpl.getReadIndex: LeaderStateImpl.java:1173-1217
LeaderStateImpl_getReadIndex(l) ==
    /\ l \in Server
    /\ role[l] = LEADER
    /\ pendingReadIndex[l] = 0
    /\ commitIndex[l] > 0
    \* LeaderStateImpl.java:1181-1190 chooses readIndex from committed,
    \* applied, or replied supplier plus read-after-write floor.
    /\ pendingReadIndex' = [pendingReadIndex EXCEPT ![l] = commitIndex[l]]
    \* LeaderStateImpl.java:1202-1205 completes immediately when heartbeat
    \* check is disabled or lease is valid; otherwise a heartbeat listener is
    \* installed.
    /\ heartbeatAckedSet' =
        [heartbeatAckedSet EXCEPT ![l] =
            IF ~leaderHeartbeatCheck[l] \/ leaseValid[l] THEN conf ELSE {l}]
    /\ heartbeatAckedIndex' =
        [heartbeatAckedIndex EXCEPT ![l] =
            IF ~leaderHeartbeatCheck[l] \/ leaseValid[l] THEN commitIndex[l] ELSE @]
    /\ UNCHANGED <<readCompletedIndex, leaderHeartbeatCheck, leaseValid>>
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress

\* ReadIndexHeartbeats receive path:
\* ReadIndexHeartbeats.java:49-82, ReadIndexHeartbeats.java:139-157
ReadIndexHeartbeats_HeartbeatAck(l, f) ==
    /\ l \in Server
    /\ f \in Server \ {l}
    /\ pendingReadIndex[l] > 0
    /\ leaderHeartbeatCheck[l]
    /\ appendReply[f].present
    /\ appendReply[f].leader = l
    /\ appendReply[f].result = SUCCESS
    /\ appendReply[f].callId >= pendingRequest[f].callId
    /\ appendReply[f].followerCommit >= pendingReadIndex[l]
    \* ReadIndexHeartbeats.java:76-82 accepts only successful replies with
    \* callId >= the listener's minCallId.
    /\ heartbeatAckedSet' =
        [heartbeatAckedSet EXCEPT ![l] = @ \cup {f}]
    /\ heartbeatAckedIndex' =
        [heartbeatAckedIndex EXCEPT ![l] =
            IF JointMajority(heartbeatAckedSet[l] \cup {f})
            THEN Max2(@, pendingReadIndex[l]) ELSE @]
    /\ appendReply' = [appendReply EXCEPT ![f] = EmptyReply]
    /\ UNCHANGED <<pendingReadIndex, readCompletedIndex,
                  leaderHeartbeatCheck, leaseValid>>
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UNCHANGED <<inFlightAppend, composedAppend, acceptedLeaderTerm>>
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress

\* RaftServerImpl.readAsync + ReadRequests.waitToAdvance:
\* RaftServerImpl.java:1147-1152, ReadRequests.java:58-84
ReadRequests_waitToAdvance_CompleteRead(l) ==
    /\ l \in Server
    /\ pendingReadIndex[l] > 0
    /\ ReadProofOK(l, pendingReadIndex[l])
    \* RaftServerImpl.java:1147-1151 waits for read index to be applied
    \* before querying the state machine.
    /\ readCompletedIndex' =
        [readCompletedIndex EXCEPT ![l] = Max2(@, pendingReadIndex[l])]
    /\ pendingReadIndex' = [pendingReadIndex EXCEPT ![l] = 0]
    /\ UNCHANGED <<heartbeatAckedIndex, heartbeatAckedSet,
                  leaderHeartbeatCheck, leaseValid>>
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress

\* -------------------------------------------------------------------------
\* Snapshot, purge, restart, and configuration actions
\* -------------------------------------------------------------------------

\* GrpcLogAppender.installSnapshot notification path:
\* GrpcLogAppender.java:241-253, LogAppenderBase.java:225-233
GrpcLogAppender_installSnapshot_Notify(l, f) ==
    /\ l \in Server
    /\ f \in Server \ {l}
    /\ role[l] = LEADER
    /\ ~installingSnapshot[f]
    /\ logStart[l] > 1
    \* GrpcLogAppender.java:249-253 sends a snapshot notification when the
    \* follower needs an index earlier than the leader's first available log.
    /\ installingSnapshot' = [installingSnapshot EXCEPT ![f] = TRUE]
    /\ firstAvailableLogIndex' = [firstAvailableLogIndex EXCEPT ![f] = logStart[l]]
    /\ attemptedInstallSnapshot' = [attemptedInstallSnapshot EXCEPT ![f] = TRUE]
    /\ nextChunkIndex' = [nextChunkIndex EXCEPT ![f] = 0]
    /\ chunk0CallId' = [chunk0CallId EXCEPT ![f] = requestCallId[l]]
    /\ UNCHANGED <<snapshotIndex, snapshotTerm, installedSnapshotIndex,
                  snapshotConfigIndex>>
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

\* SnapshotInstallationHandler.checkAndInstallSnapshot chunk zero:
\* SnapshotInstallationHandler.java:193-209
SnapshotInstallationHandler_checkAndInstallSnapshot_Chunk0(f) ==
    /\ f \in Server
    /\ installingSnapshot[f]
    /\ nextChunkIndex[f] = 0
    \* SnapshotInstallationHandler.java:206-209 resets nextChunkIndex and
    \* records chunk0CallId for a new stream.
    /\ nextChunkIndex' = [nextChunkIndex EXCEPT ![f] = 1]
    /\ chunk0CallId' = [chunk0CallId EXCEPT ![f] = @ + 1]
    /\ UNCHANGED <<snapshotIndex, snapshotTerm, installedSnapshotIndex,
                  firstAvailableLogIndex, installingSnapshot,
                  snapshotConfigIndex, attemptedInstallSnapshot>>
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

\* SnapshotInstallationHandler final chunk + ServerState.reloadStateMachine:
\* SnapshotInstallationHandler.java:229-240, ServerState.java:425-430
SnapshotInstallationHandler_checkAndInstallSnapshot_Finalize(f) ==
    /\ f \in Server
    /\ installingSnapshot[f]
    /\ nextChunkIndex[f] > 0
    /\ firstAvailableLogIndex[f] > 1
    /\ LET snap == firstAvailableLogIndex[f] - 1 IN commitIndex[f] < snap
    \* SnapshotInstallationHandler.java:235-239 finalizes the snapshot and
    \* reloads the state machine; ServerState.java:425-430 updates log and
    \* latestInstalledSnapshot.
    /\ LET snap == firstAvailableLogIndex[f] - 1 IN
       /\ snapshotIndex' = [snapshotIndex EXCEPT ![f] = Max2(@, snap)]
       /\ snapshotTerm' = [snapshotTerm EXCEPT ![f] = volatileTerm[f]]
       /\ installedSnapshotIndex' = [installedSnapshotIndex EXCEPT ![f] = snap]
       /\ logStart' = [logStart EXCEPT ![f] = firstAvailableLogIndex[f]]
       /\ logEnd' = [logEnd EXCEPT ![f] = Max2(logEnd[f], snap)]
       /\ flushIndex' = [flushIndex EXCEPT ![f] = Max2(flushIndex[f], snap)]
       /\ commitIndex' = [commitIndex EXCEPT ![f] = Max2(commitIndex[f], snap)]
       /\ snapshotConfigIndex' =
            [snapshotConfigIndex EXCEPT ![f] = Max2(@, configLogIndex)]
       /\ configStored' =
            [configStored EXCEPT ![f] = Max2(@, configLogIndex)]
    /\ installingSnapshot' = [installingSnapshot EXCEPT ![f] = FALSE]
    /\ nextChunkIndex' = [nextChunkIndex EXCEPT ![f] = 0]
    /\ UNCHANGED <<firstAvailableLogIndex, chunk0CallId,
                  attemptedInstallSnapshot>>
    /\ UNCHANGED <<logTerm, logValue, appliedIndex, repliedIndex,
                  committedTerm, committedValue>>
    /\ UnchangedTermRole
    /\ UnchangedAppendCompose
    /\ UNCHANGED <<conf, oldConf, roleByPeer, stagingPeers, caughtUp,
                  configLogIndex>>
    /\ UnchangedProgress
    /\ UnchangedRead

\* SnapshotInstallationHandler.notifyStateMachineToInstallSnapshot reload:
\* SnapshotInstallationHandler.java:322-386, ServerState.java:425-430
SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_Reload(f) ==
    /\ f \in Server
    /\ installingSnapshot[f]
    /\ firstAvailableLogIndex[f] > 1
    /\ snapshotIndex[f] + 1 < firstAvailableLogIndex[f]
    \* SnapshotInstallationHandler.java:370-386 consumes an installed
    \* snapshot notification, reloads the state machine, clears in-progress,
    \* and reports SNAPSHOT_INSTALLED to the leader.
    /\ LET snap == firstAvailableLogIndex[f] - 1 IN
       /\ snapshotIndex' = [snapshotIndex EXCEPT ![f] = Max2(@, snap)]
       /\ installedSnapshotIndex' = [installedSnapshotIndex EXCEPT ![f] = snap]
       /\ logStart' = [logStart EXCEPT ![f] = firstAvailableLogIndex[f]]
       /\ logEnd' = [logEnd EXCEPT ![f] = Max2(logEnd[f], snap)]
       /\ flushIndex' = [flushIndex EXCEPT ![f] = Max2(flushIndex[f], snap)]
       /\ commitIndex' = [commitIndex EXCEPT ![f] = Max2(commitIndex[f], snap)]
    /\ installingSnapshot' = [installingSnapshot EXCEPT ![f] = FALSE]
    /\ snapshotConfigIndex' =
        [snapshotConfigIndex EXCEPT ![f] = Max2(@, configLogIndex)]
    /\ configStored' = [configStored EXCEPT ![f] = Max2(@, configLogIndex)]
    /\ UNCHANGED <<snapshotTerm, firstAvailableLogIndex, nextChunkIndex,
                  chunk0CallId, attemptedInstallSnapshot>>
    /\ UNCHANGED <<logTerm, logValue, appliedIndex, repliedIndex,
                  committedTerm, committedValue>>
    /\ UnchangedTermRole
    /\ UnchangedAppendCompose
    /\ UNCHANGED <<conf, oldConf, roleByPeer, stagingPeers, caughtUp,
                  configLogIndex>>
    /\ UnchangedProgress
    /\ UnchangedRead

\* SnapshotInstallationHandler.java:278-289 returns ALREADY_INSTALLED when
\* the follower already has a snapshot at or beyond the notified boundary.
SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_AlreadyInstalled(f) ==
    /\ f \in Server
    /\ installingSnapshot[f]
    /\ firstAvailableLogIndex[f] > 1
    /\ snapshotIndex[f] + 1 >= firstAvailableLogIndex[f]
    /\ installingSnapshot' = [installingSnapshot EXCEPT ![f] = FALSE]
    /\ nextChunkIndex' = [nextChunkIndex EXCEPT ![f] = 0]
    /\ UNCHANGED <<snapshotIndex, snapshotTerm, installedSnapshotIndex,
                  firstAvailableLogIndex, chunk0CallId,
                  snapshotConfigIndex, attemptedInstallSnapshot>>
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

\* ConfigurationManager.removeConfigurations and purge boundary:
\* ConfigurationManager.java:96-103, ServerState.java:393-395
ConfigurationManager_removeConfigurations_PurgeLog(s, purgeTo) ==
    /\ s \in Server
    /\ purgeTo \in Index
    /\ purgeTo <= logEnd[s]
    /\ purgeTo >= snapshotIndex[s]
    \* ConfigurationManager.java:96-103 removes configurations at or after
    \* the truncation index and falls back to the previous configuration.
    /\ logStart' = [logStart EXCEPT ![s] = purgeTo + 1]
    /\ snapshotIndex' = [snapshotIndex EXCEPT ![s] = Max2(@, purgeTo)]
    /\ snapshotTerm' = [snapshotTerm EXCEPT ![s] = logTerm[s][purgeTo]]
    /\ IF configLogIndex >= purgeTo
       THEN /\ configStored' = [configStored EXCEPT ![s] = snapshotConfigIndex[s]]
       ELSE /\ configStored' = configStored
    /\ UNCHANGED <<logTerm, logValue, logEnd, flushIndex, commitIndex,
                  appliedIndex, repliedIndex, committedTerm, committedValue>>
    /\ UNCHANGED <<installedSnapshotIndex, firstAvailableLogIndex,
                  installingSnapshot, nextChunkIndex, chunk0CallId,
                  snapshotConfigIndex, attemptedInstallSnapshot>>
    /\ UnchangedTermRole
    /\ UnchangedAppendCompose
    /\ UNCHANGED <<conf, oldConf, roleByPeer, stagingPeers, caughtUp,
                  configLogIndex>>
    /\ UnchangedProgress
    /\ UnchangedRead

\* RaftLogBase.open and ServerState.initialize restart path:
\* ServerState.java:129-142, RaftLogBase.java:263-273
RaftLogBase_open_Restart(s) ==
    /\ s \in Server
    \* ServerState.java:139-142 reloads persisted metadata; RaftLogBase.java
    \* 263-273 opens the log and applies stored metadata commit index.
    /\ role' = [role EXCEPT ![s] = FOLLOWER]
    /\ volatileTerm' = [volatileTerm EXCEPT ![s] = persistedTerm[s]]
    /\ votedFor' = [votedFor EXCEPT ![s] = persistedVote[s]]
    /\ leaderId' = [leaderId EXCEPT ![s] = NoLeader]
    /\ leaderStateAlive' = [leaderStateAlive EXCEPT ![s] = FALSE]
    /\ stepDownQueued' = [stepDownQueued EXCEPT ![s] = FALSE]
    /\ queuedStepDownTerm' = [queuedStepDownTerm EXCEPT ![s] = NoTerm]
    /\ UNCHANGED <<persistedTerm, persistedVote, voteGranted, maxObservedStepDownTerm,
                  persistFailureAvailable, metadataPersistFailed>>
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedConfig
    /\ UnchangedProgress
    /\ UnchangedRead

\* RaftServerImpl.setConfigurationAsync: RaftServerImpl.java:1388-1456
RaftServerImpl_setConfigurationAsync_Start(l, p) ==
    /\ l \in Server
    /\ p \in Server \ conf
    /\ role[l] = LEADER
    /\ oldConf = {}
    /\ stagingPeers = {}
    \* RaftServerImpl.java:1406-1454 checks stable config and starts
    \* LeaderStateImpl staging for the new voting peer.
    /\ stagingPeers' = {p}
    /\ caughtUp' = [caughtUp EXCEPT ![p] = FALSE]
    /\ roleByPeer' = [roleByPeer EXCEPT ![p] = FOLLOWER]
    /\ UNCHANGED <<conf, oldConf, configLogIndex, configStored>>
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedProgress
    /\ UnchangedRead

\* LeaderStateImpl.checkProgress/checkStaging: LeaderStateImpl.java:828-887
LeaderStateImpl_checkProgress_CaughtUp(l, f) ==
    /\ l \in Server
    /\ f \in stagingPeers
    /\ role[l] = LEADER
    /\ ~caughtUp[f]
    /\ attemptedInstallSnapshot[f]
    /\ matchIndex[f] >= configLogIndex
    \* LeaderStateImpl.java:836-840 declares CAUGHTUP from matchIndex,
    \* current configuration logEntryIndex, response time, and snapshot attempt.
    /\ caughtUp' = [caughtUp EXCEPT ![f] = TRUE]
    /\ UnchangedTermRole
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UNCHANGED <<conf, oldConf, roleByPeer, stagingPeers,
                  configLogIndex, configStored>>
    /\ UnchangedProgress
    /\ UnchangedRead

\* LeaderStateImpl.applyOldNewConf + appendConfiguration:
\* LeaderStateImpl.java:624-639, LeaderStateImpl.java:1303-1308
LeaderStateImpl_applyOldNewConf(l) ==
    /\ l \in Server
    /\ role[l] = LEADER
    /\ stagingPeers /= {}
    /\ \A p \in stagingPeers: caughtUp[p]
    /\ oldConf = {}
    /\ logEnd[l] < MaxIndex
    \* LeaderStateImpl.java:624-639 generates old-new configuration and
    \* appends it as a configuration log entry, then installs it in ServerState.
    /\ LET idx == logEnd[l] + 1 IN
       /\ oldConf' = conf
       /\ conf' = conf \cup stagingPeers
       /\ configLogIndex' = idx
       /\ configStored' = [configStored EXCEPT ![l] = idx]
       /\ logTerm' = [logTerm EXCEPT ![l] = [@ EXCEPT ![idx] = volatileTerm[l]]]
       /\ logValue' = [logValue EXCEPT ![l] = [@ EXCEPT ![idx] = CONFIG_OLD_NEW]]
       /\ logEnd' = [logEnd EXCEPT ![l] = idx]
       /\ flushIndex' = [flushIndex EXCEPT ![l] = idx]
    /\ stagingPeers' = {}
    /\ UNCHANGED <<roleByPeer, caughtUp>>
    /\ UNCHANGED <<logStart, commitIndex, appliedIndex, repliedIndex,
                  committedTerm, committedValue>>
    /\ UnchangedTermRole
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedProgress
    /\ UnchangedRead

\* LeaderStateImpl.replicateNewConf/checkAndUpdateConfiguration:
\* LeaderStateImpl.java:1034-1044, LeaderStateImpl.java:1064-1073
LeaderStateImpl_replicateNewConf(l) ==
    /\ l \in Server
    /\ role[l] = LEADER
    /\ oldConf /= {}
    /\ commitIndex[l] >= configLogIndex
    /\ logEnd[l] < MaxIndex
    \* LeaderStateImpl.java:1034-1038 observes committed old-new config;
    \* lines 1064-1073 appends the stable new configuration and updates senders.
    /\ LET idx == logEnd[l] + 1 IN
       /\ oldConf' = {}
       /\ configLogIndex' = idx
       /\ configStored' = [configStored EXCEPT ![l] = idx]
       /\ logTerm' = [logTerm EXCEPT ![l] = [@ EXCEPT ![idx] = volatileTerm[l]]]
       /\ logValue' = [logValue EXCEPT ![l] = [@ EXCEPT ![idx] = CONFIG_NEW]]
       /\ logEnd' = [logEnd EXCEPT ![l] = idx]
       /\ flushIndex' = [flushIndex EXCEPT ![l] = idx]
    /\ UNCHANGED <<conf, roleByPeer, stagingPeers, caughtUp>>
    /\ UNCHANGED <<logStart, commitIndex, appliedIndex, repliedIndex,
                  committedTerm, committedValue>>
    /\ UnchangedTermRole
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedProgress
    /\ UnchangedRead

\* ServerState.updateConfiguration listener promotion:
\* ServerState.java:397-410, RaftConfigurationImpl.java:152-159
ServerState_updateConfiguration_PromoteListener(s) ==
    /\ s \in Server
    /\ roleByPeer[s] = LISTENER
    /\ s \in conf
    /\ configStored[s] >= configLogIndex
    \* ServerState.java:408-410 moves a LISTENER into follower state when
    \* a configuration entry makes it a voting peer.
    /\ roleByPeer' = [roleByPeer EXCEPT ![s] = FOLLOWER]
    /\ role' = [role EXCEPT ![s] = FOLLOWER]
    /\ UNCHANGED <<conf, oldConf, stagingPeers, caughtUp, configLogIndex,
                  configStored>>
    /\ UNCHANGED <<volatileTerm, persistedTerm, persistedVote, votedFor, voteGranted,
                  leaderId, leaderStateAlive, stepDownQueued,
                  queuedStepDownTerm, maxObservedStepDownTerm,
                  persistFailureAvailable, metadataPersistFailed>>
    /\ UnchangedEntries
    /\ UnchangedAppendCompose
    /\ UnchangedSnapshot
    /\ UnchangedProgress
    /\ UnchangedRead

\* -------------------------------------------------------------------------
\* Next
\* -------------------------------------------------------------------------

Next ==
    \/ \E s \in Server: ServerState_initElection_ELECTION(s)
    \/ \E v \in Server, c \in Server: RaftServerImpl_requestVote_Grant(v, c)
    \/ \E s \in Server: RaftServerImpl_changeToLeader(s)
    \/ \E s \in Server, l \in Server, t \in Term:
            RaftServerImpl_changeToFollowerAndPersistMetadata_PersistFailure(s, l, t)
    \/ \E s \in Server: ServerState_persistMetadata(s)
    \/ \E s \in Server, t \in Term: LeaderStateImpl_submitStepDownEvent(s, t)
    \/ \E s \in Server: LeaderStateImpl_stepDown(s)
    \/ \E l \in Server, v \in EntryValue: RaftServerImpl_appendTransaction(l, v)
    \/ \E l \in Server, f \in Server: GrpcLogAppender_appendLog(l, f)
    \/ \E s \in Server: RaftServerImpl_appendEntriesAsync_RegisterInFlight(s)
    \/ \E s \in Server: ServerImplUtils_NavigableIndices_append_ComposeExisting(s)
    \/ \E s \in Server, l \in Server, t \in Term:
            RaftServerImpl_appendEntriesAsync_RecognizeLeaderHeartbeat(s, l, t)
    \/ \E s \in Server: RaftServerImpl_appendEntriesAsync_InconsistencyReply(s)
    \/ \E s \in Server: SegmentedRaftLog_appendImpl_CompletePhysicalAppend(s)
    \/ \E s \in Server: RaftServerImpl_appendEntriesAsync_ReplyOriginal(s)
    \/ \E s \in Server: RaftServerImpl_appendEntriesAsync_ReplyComposed(s)
    \/ \E s \in Server: ServerImplUtils_NavigableIndices_removeExisting(s)
    \/ \E l \in Server, f \in Server: GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS(l, f)
    \/ \E l \in Server, f \in Server, i \in Index:
            GrpcLogAppender_AppendLogResponseHandler_onNext_SUCCESS_OldStream(l, f, i)
    \/ \E f \in Server: GrpcLogAppender_timeoutAppendRequest(f)
    \/ \E f \in Server: GrpcLogAppender_resetClient(f)
    \/ \E l \in Server, i \in Index: LeaderStateImpl_updateCommit(l, i)
    \/ \E s \in Server: StateMachineUpdater_applyEntry(s)
    \/ \E s \in Server: ReplyFlusher_flush(s)
    \/ \E l \in Server: LeaderStateImpl_getReadIndex(l)
    \/ \E l \in Server, f \in Server: ReadIndexHeartbeats_HeartbeatAck(l, f)
    \/ \E l \in Server: ReadRequests_waitToAdvance_CompleteRead(l)
    \/ \E l \in Server, f \in Server: GrpcLogAppender_installSnapshot_Notify(l, f)
    \/ \E f \in Server: SnapshotInstallationHandler_checkAndInstallSnapshot_Chunk0(f)
    \/ \E f \in Server: SnapshotInstallationHandler_checkAndInstallSnapshot_Finalize(f)
    \/ \E f \in Server: SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_Reload(f)
    \/ \E f \in Server: SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot_AlreadyInstalled(f)
    \/ \E s \in Server, i \in Index: ConfigurationManager_removeConfigurations_PurgeLog(s, i)
    \/ \E s \in Server: RaftLogBase_open_Restart(s)
    \/ \E l \in Server, p \in Server: RaftServerImpl_setConfigurationAsync_Start(l, p)
    \/ \E l \in Server, f \in Server: LeaderStateImpl_checkProgress_CaughtUp(l, f)
    \/ \E l \in Server: LeaderStateImpl_applyOldNewConf(l)
    \/ \E l \in Server: LeaderStateImpl_replicateNewConf(l)
    \/ \E s \in Server: ServerState_updateConfiguration_PromoteListener(s)

Spec == Init /\ [][Next]_vars

\* -------------------------------------------------------------------------
\* Type and structural invariants
\* -------------------------------------------------------------------------

TypeOK ==
    /\ role \in [Server -> RoleSet]
    /\ volatileTerm \in [Server -> Term]
    /\ persistedTerm \in [Server -> Term]
    /\ persistedVote \in [Server -> MaybeVote]
    /\ votedFor \in [Server -> MaybeVote]
    /\ voteGranted \in [Server -> [Server -> BOOLEAN]]
    /\ leaderId \in [Server -> MaybeServer]
    /\ leaderStateAlive \in [Server -> BOOLEAN]
    /\ stepDownQueued \in [Server -> BOOLEAN]
    /\ queuedStepDownTerm \in [Server -> TermOrNo]
    /\ maxObservedStepDownTerm \in [Server -> Term]
    /\ persistFailureAvailable \in [Server -> BOOLEAN]
    /\ metadataPersistFailed \in [Server -> BOOLEAN]

    /\ logTerm \in [Server -> [Index -> Term]]
    /\ logValue \in [Server -> [Index -> EntryOrEmpty]]
    /\ logStart \in [Server -> Index1]
    /\ logEnd \in [Server -> Index0]
    /\ flushIndex \in [Server -> Index0]
    /\ commitIndex \in [Server -> Index0]
    /\ appliedIndex \in [Server -> Index0]
    /\ repliedIndex \in [Server -> Index0]
    /\ committedTerm \in [Index -> Term]
    /\ committedValue \in [Index -> EntryOrEmpty]

    /\ inFlightAppend \in [Server -> InFlightRecordSet]
    /\ composedAppend \in [Server -> ComposedRecordSet]
    /\ appendReply \in [Server -> ReplyRecordSet]
    /\ acceptedLeaderTerm \in [Server -> Term]

    /\ snapshotIndex \in [Server -> Index0]
    /\ snapshotTerm \in [Server -> Term]
    /\ installedSnapshotIndex \in [Server -> Index0]
    /\ firstAvailableLogIndex \in [Server -> Index1]
    /\ installingSnapshot \in [Server -> BOOLEAN]
    /\ nextChunkIndex \in [Server -> Index0]
    /\ chunk0CallId \in [Server -> CallId]
    /\ snapshotConfigIndex \in [Server -> Index0]
    /\ attemptedInstallSnapshot \in [Server -> BOOLEAN]

    /\ conf \in SUBSET Server
    /\ oldConf \in SUBSET Server
    /\ roleByPeer \in [Server -> PeerRoleSet]
    /\ stagingPeers \in SUBSET Server
    /\ caughtUp \in [Server -> BOOLEAN]
    /\ configLogIndex \in Index0
    /\ configStored \in [Server -> Index0]

    /\ nextIndex \in [Server -> Index1]
    /\ matchIndex \in [Server -> Index0]
    /\ pendingRequest \in [Server -> PendingRecordSet]
    /\ requestCallId \in [Server -> CallId]
    /\ streamEpoch \in [Server -> Epoch]
    /\ lastReplyStatus \in [Server -> AppendResultSet]

    /\ pendingReadIndex \in [Server -> Index0]
    /\ readCompletedIndex \in [Server -> Index0]
    /\ heartbeatAckedIndex \in [Server -> Index0]
    /\ heartbeatAckedSet \in [Server -> SUBSET Server]
    /\ leaderHeartbeatCheck \in [Server -> BOOLEAN]
    /\ leaseValid \in [Server -> BOOLEAN]

IndexBounds ==
    /\ \A s \in Server: logStart[s] <= logEnd[s] + 1
    /\ \A s \in Server: commitIndex[s] <= flushIndex[s]
    /\ \A s \in Server: appliedIndex[s] <= commitIndex[s]
    /\ \A s \in Server: repliedIndex[s] <= appliedIndex[s]

TermMonotonicShape ==
    /\ \A s \in Server: persistedTerm[s] <= MaxTerm
    /\ \A s \in Server: volatileTerm[s] <= MaxTerm

ConfigShape ==
    /\ conf /= {}
    /\ stagingPeers \cap conf = {}
    /\ oldConf = {} \/ oldConf /= conf
    /\ \A s \in Server: configStored[s] <= MaxIndex

ProgressShape ==
    /\ \A s \in Server: matchIndex[s] <= MaxIndex
    /\ \A s \in Server: nextIndex[s] <= MaxIndex + 1

\* -------------------------------------------------------------------------
\* Standard Raft safety invariants
\* -------------------------------------------------------------------------

ElectionSafety ==
    \A t \in Term:
        Cardinality({s \in Server: role[s] = LEADER /\ volatileTerm[s] = t}) <= 1

LogMatching ==
    \A a \in Server, b \in Server, i \in Index:
        /\ HasLogAt(a, i)
        /\ HasLogAt(b, i)
        /\ logTerm[a][i] = logTerm[b][i]
        => \A j \in 1..i:
             /\ HasLogAt(a, j)
             /\ HasLogAt(b, j)
             => /\ logTerm[a][j] = logTerm[b][j]
                /\ logValue[a][j] = logValue[b][j]

KnownBug_StaleAppendSuccessAfterVote(l, i) ==
    \E oldLeader \in Server, voter \in Server:
        /\ oldLeader # l
        /\ voter # l
        /\ ContainsOrCovers(oldLeader, i, committedTerm[i], committedValue[i])
        /\ ContainsOrCovers(voter, i, committedTerm[i], committedValue[i])
        /\ voteGranted[voter][l]
        /\ persistedTerm[voter] > committedTerm[i]
        /\ \/ /\ inFlightAppend[voter].present
              /\ inFlightAppend[voter].leader = oldLeader
              /\ inFlightAppend[voter].term = committedTerm[i]
              /\ inFlightAppend[voter].start <= i
              /\ inFlightAppend[voter].done
           \/ /\ matchIndex[voter] >= i

LeaderCompleteness ==
    \A l \in Server, i \in Index:
        /\ role[l] = LEADER
        /\ committedValue[i] /= NoEntry
        /\ volatileTerm[l] >= committedTerm[i]
        => \/ ContainsOrCovers(l, i, committedTerm[i], committedValue[i])
           \/ KnownBug_StaleAppendSuccessAfterVote(l, i)

StateMachineSafety ==
    \A a \in Server, b \in Server, i \in Index:
        /\ i <= appliedIndex[a]
        /\ i <= appliedIndex[b]
        /\ committedValue[i] /= NoEntry
        => /\ ContainsOrCovers(a, i, committedTerm[i], committedValue[i])
           /\ ContainsOrCovers(b, i, committedTerm[i], committedValue[i])

\* -------------------------------------------------------------------------
\* Scenario invariants
\* -------------------------------------------------------------------------

\* Scenario 1 / MC-RATIS-1.
KnownBug_ComposedSuccessMismatchedFuture(s) ==
    /\ appendReply[s].present
    /\ appendReply[s].result = SUCCESS
    /\ appendReply[s].value /= NoEntry
    /\ inFlightAppend[s].present
    /\ inFlightAppend[s].done
    /\ ~inFlightAppend[s].replied
    /\ appendReply[s].match = inFlightAppend[s].start
    /\ \/ appendReply[s].leader # inFlightAppend[s].leader
       \/ appendReply[s].term # inFlightAppend[s].term
       \/ appendReply[s].value # inFlightAppend[s].value
    /\ ContainsOrCovers(s, inFlightAppend[s].start,
                        inFlightAppend[s].term, inFlightAppend[s].value)

AppendSuccessReflectsLog ==
    \A s \in Server:
        /\ appendReply[s].present
        /\ appendReply[s].result = SUCCESS
        /\ appendReply[s].value /= NoEntry
        => \/ ContainsOrCovers(s, appendReply[s].match,
                               appendReply[s].term, appendReply[s].value)
           \/ KnownBug_ComposedSuccessMismatchedFuture(s)

\* Scenario 2 / MC-RATIS-2.
KnownBug_PersistFailureSameTermAccept(s) ==
    /\ metadataPersistFailed[s]
    /\ ~persistFailureAvailable[s]
    /\ persistedTerm[s] < acceptedLeaderTerm[s]
    /\ volatileTerm[s] <= acceptedLeaderTerm[s]

PersistedTermBeforeAccept ==
    \A s \in Server:
        \/ acceptedLeaderTerm[s] <= persistedTerm[s]
        \/ KnownBug_PersistFailureSameTermAccept(s)

\* Scenario 2 / MC-RATIS-3.
KnownBug_DroppedHigherStepDownTerm(s) ==
    /\ role[s] = LEADER
    /\ stepDownQueued[s]
    /\ queuedStepDownTerm[s] # NoTerm
    /\ queuedStepDownTerm[s] < maxObservedStepDownTerm[s]

StepDownTermNotLost ==
    \A s \in Server:
        /\ role[s] = LEADER
        /\ stepDownQueued[s]
        /\ queuedStepDownTerm[s] # NoTerm
        => \/ queuedStepDownTerm[s] >= maxObservedStepDownTerm[s]
           \/ KnownBug_DroppedHigherStepDownTerm(s)

\* Scenario 3 / MC-RATIS-5.
SnapshotLogContinuity ==
    \A s \in Server:
        /\ snapshotIndex[s] + 1 <= logStart[s]
        /\ logStart[s] <= logEnd[s] + 1
        /\ configStored[s] >= snapshotConfigIndex[s]

\* Scenario 4 / MC-RATIS-4 and MC-RATIS-5.
ConfigEntryBeforeCaughtUp ==
    \A s \in Server:
        /\ s \in conf
        /\ caughtUp[s]
        => IndexStoredOrSnap(s, configLogIndex)

\* Scenario 5.
LinearizableReadIndex ==
    \A s \in Server:
        readCompletedIndex[s] > 0 => ReadProofOK(s, readCompletedIndex[s])

\* Scenario 6 / MC-RATIS-6.
ProgressBounds ==
    \A s \in Server:
        /\ nextIndex[s] >= matchIndex[s] + 1
        /\ nextIndex[s] <= MaxIndex + 1
        /\ matchIndex[s] <= MaxIndex

\* -------------------------------------------------------------------------
\* Views and temporal properties
\* -------------------------------------------------------------------------

ModelView ==
    <<role, volatileTerm, persistedTerm, leaderId, logStart, logEnd,
      snapshotIndex, commitIndex, appliedIndex, repliedIndex, conf, oldConf,
      configLogIndex, configStored, nextIndex, matchIndex, pendingReadIndex,
      readCompletedIndex>>

CommitEventuallyApplied ==
    \A s \in Server: [](commitIndex[s] > appliedIndex[s] => <> (appliedIndex[s] >= commitIndex[s]))

=============================================================================
