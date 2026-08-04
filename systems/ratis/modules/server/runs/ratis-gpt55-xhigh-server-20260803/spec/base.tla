----------------------------- MODULE base -----------------------------
(*
 * Base TLA+ specification for Apache Ratis ratis-server.
 *
 * Category A: distributed / message-passing Raft server.
 * Scope is scenario-driven from modeling-brief.md:
 *   Scenario 1: durable commit boundary vs async log flush.
 *   Scenario 2: recovered/reformatted voter in election.
 *   Scenario 3: snapshot install vs AppendEntries and ReadIndex.
 *   Scenario 4: ReadIndex and leader lease across leadership change.
 *   Scenario 5: reconfiguration, catch-up, and leader recognition.
 *)

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Server,
    BootstrapConf,
    MaxIndex,
    MaxTerm

ASSUME Server /= {}
ASSUME BootstrapConf /= {}
ASSUME BootstrapConf \subseteq Server
ASSUME MaxIndex \in Nat
ASSUME MaxTerm \in Nat
ASSUME MaxTerm > 0

Index == 0..MaxIndex
IndexOrInvalid == -1..MaxIndex
Term == 0..MaxTerm

None == "None"
Follower == "Follower"
Candidate == "Candidate"
Leader == "Leader"
Listener == "Listener"

Roles == {Follower, Candidate, Leader, Listener}
VoteKinds == {"valid", "empty", "missing"}
MsgTypes == {"RequestVote", "RequestVoteReply", "AppendEntries", "AppendEntriesReply", "InstallSnapshot"}
MsgSubtypes == {"election", "heartbeat", "replicate", "snapshot", "none"}
MsgResults == {"SUCCESS", "REJECT", "NOT_LEADER", "INCONSISTENCY", "IN_PROGRESS", "none"}
EntryKinds == {"normal", "config", "metadata", "none"}
ReplyResults == {"none", "SUCCESS", "NOT_LEADER", "HIGHER_TERM", "INCONSISTENCY"}

MessageSet ==
    [ mtype         : MsgTypes,
      msubtype      : MsgSubtypes,
      from          : Server,
      to            : Server,
      term          : Term,
      index         : IndexOrInvalid,
      result        : MsgResults,
      lastEntryKind : VoteKinds \cup {"none"} ]

VARIABLES
    currentTerm,
    role,
    votedFor,
    leaderId,
    persistedTerm,
    persistedVote,
    recovered,
    reformatted,
    voterRole,

    volatileLog,
    diskLog,
    writeQueue,
    lastWrittenIndex,
    flushIndex,
    flushInFlightIndex,
    flushInFlightCovered,
    flushFailure,
    commitIndex,
    metadataCommitIndex,
    stateMachineDataFlushed,
    logTerm,
    logKind,

    matchIndex,
    nextIndex,
    votesGranted,
    candidateCommitKnown,
    voteReplyLastEntryKind,
    leaderStateGeneration,
    leaseEnabled,
    leaseFresh,
    replyTimestampObserved,
    replyResult,
    leaseReadServed,
    readIndexListeners,
    ackedCommitIndex,

    snapshotIndex,
    installedSnapshot,
    snapshotInProgressIndex,
    tempSnapshot,
    snapshotPublished,
    logStartIndex,
    pendingReadIndexes,
    readResult,
    workerQueue,
    appendReplyPending,

    currentConf,
    oldConf,
    durableConf,
    stagingPeers,
    caughtUp,
    attemptedSnapshot,
    confLogIndex,
    durableConfLogIndex,
    confAcked,
    recognizedLeader,

    messages

Max2(a, b) == IF a >= b THEN a ELSE b
Min2(a, b) == IF a <= b THEN a ELSE b
IndexPrefix(i) == IF i < 0 THEN {} ELSE 0..i
SetMax(S) == IF S = {} THEN -1 ELSE CHOOSE m \in S : \A n \in S : n <= m

Majority(conf, acked) ==
    2 * Cardinality(conf \cap acked) > Cardinality(conf)

JointMajority(s, acked) ==
    /\ Majority(currentConf[s], acked)
    /\ (oldConf[s] = {} \/ Majority(oldConf[s], acked))

DurableBoundary(s) ==
    Max2(snapshotIndex[s], SetMax(diskLog[s]))

LastLocalEntry(s) ==
    Max2(snapshotIndex[s], SetMax(volatileLog[s]))

DurableConfigIndex(s) ==
    IF confLogIndex[s] \in diskLog[s] THEN confLogIndex[s] ELSE durableConfLogIndex[s]

RecoveredConf(s) ==
    IF confLogIndex[s] \in diskLog[s] THEN currentConf[s] ELSE durableConf[s]

FlushedMetadataCommitIndex(s) ==
    SetMax({i - 1 : i \in {j \in Index : j <= flushInFlightCovered[s] /\ logKind[s][j] = "metadata"}})

FormatStorageIsEmpty(s) ==
    /\ diskLog[s] = {}
    /\ volatileLog[s] = {}
    /\ writeQueue[s] = {}
    /\ workerQueue[s] = {}
    /\ lastWrittenIndex[s] = -1
    /\ flushIndex[s] = -1
    /\ flushInFlightIndex[s] = -1
    /\ flushInFlightCovered[s] = -1
    /\ commitIndex[s] = -1
    /\ metadataCommitIndex[s] = -1
    /\ snapshotIndex[s] = -1
    /\ installedSnapshot[s] = -1

LastEntryKind(s) ==
    IF voteReplyLastEntryKind[s] # "valid" THEN voteReplyLastEntryKind[s]
    ELSE IF LastLocalEntry(s) < 0 THEN "empty" ELSE "valid"

LogUpToDate(voter, candidateIndex) ==
    LastLocalEntry(voter) <= candidateIndex

AcceptedVoteReply(c, m) ==
    /\ m.mtype = "RequestVoteReply"
    /\ m.to = c
    /\ m.result = "SUCCESS"
    \* A LeaderElection instance is bound to one electionTerm and stops when
    \* the server current term changes; stale replies from older elections are
    \* not counted in a later term.
    \* LeaderElection.java:416-418, LeaderElection.java:513-565.
    /\ m.term = currentTerm[c]
    \* LeaderElection.nonEmptyLog accepts missing lastEntry for old versions.
    \* LeaderElection.java:569-571, LeaderElection.java:601-619.
    /\ (candidateCommitKnown[c] = FALSE \/ m.lastEntryKind # "empty")

GoodVotePeers(c) ==
    {m.from : m \in {x \in messages : AcceptedVoteReply(c, x)}}

Message(from, to, typ, subtype, term, index, result, kind) ==
    [ mtype         |-> typ,
      msubtype      |-> subtype,
      from          |-> from,
      to            |-> to,
      term          |-> term,
      index         |-> index,
      result        |-> result,
      lastEntryKind |-> kind ]

serverVars ==
    << currentTerm, role, votedFor, leaderId, persistedTerm, persistedVote,
       recovered, reformatted, voterRole >>

logVars ==
    << volatileLog, diskLog, writeQueue, lastWrittenIndex, flushIndex,
       flushInFlightIndex, flushInFlightCovered, flushFailure, commitIndex,
       metadataCommitIndex, stateMachineDataFlushed, logTerm, logKind >>

leaderVars ==
    << matchIndex, nextIndex, votesGranted, candidateCommitKnown,
       voteReplyLastEntryKind, leaderStateGeneration, leaseEnabled, leaseFresh,
       replyTimestampObserved, replyResult, leaseReadServed, readIndexListeners,
       ackedCommitIndex >>

snapshotVars ==
    << snapshotIndex, installedSnapshot, snapshotInProgressIndex, tempSnapshot,
       snapshotPublished, logStartIndex, pendingReadIndexes, readResult,
       workerQueue, appendReplyPending >>

configVars ==
    << currentConf, oldConf, durableConf, stagingPeers, caughtUp,
       attemptedSnapshot, confLogIndex, durableConfLogIndex, confAcked,
       recognizedLeader >>

vars ==
    << currentTerm, role, votedFor, leaderId, persistedTerm, persistedVote,
       recovered, reformatted, voterRole,
       volatileLog, diskLog, writeQueue, lastWrittenIndex, flushIndex,
       flushInFlightIndex, flushInFlightCovered, flushFailure, commitIndex,
       metadataCommitIndex, stateMachineDataFlushed, logTerm, logKind,
       matchIndex, nextIndex, votesGranted, candidateCommitKnown,
       voteReplyLastEntryKind, leaderStateGeneration, leaseEnabled, leaseFresh,
       replyTimestampObserved, replyResult, leaseReadServed, readIndexListeners,
       ackedCommitIndex,
       snapshotIndex, installedSnapshot, snapshotInProgressIndex, tempSnapshot,
       snapshotPublished, logStartIndex, pendingReadIndexes, readResult,
       workerQueue, appendReplyPending,
       currentConf, oldConf, durableConf, stagingPeers, caughtUp,
       attemptedSnapshot, confLogIndex, durableConfLogIndex, confAcked,
       recognizedLeader,
       messages >>

InitialFunction(value) == [s \in Server |-> value]

Init ==
    /\ currentTerm = [s \in Server |-> 0]
    /\ role = [s \in Server |-> Follower]
    /\ votedFor = [s \in Server |-> None]
    /\ leaderId = [s \in Server |-> None]
    /\ persistedTerm = [s \in Server |-> 0]
    /\ persistedVote = [s \in Server |-> None]
    /\ recovered = [s \in Server |-> FALSE]
    /\ reformatted = [s \in Server |-> FALSE]
    /\ voterRole = [s \in Server |-> IF s \in BootstrapConf THEN Follower ELSE Listener]

    /\ volatileLog = [s \in Server |-> {}]
    /\ diskLog = [s \in Server |-> {}]
    /\ writeQueue = [s \in Server |-> {}]
    /\ lastWrittenIndex = [s \in Server |-> -1]
    /\ flushIndex = [s \in Server |-> -1]
    /\ flushInFlightIndex = [s \in Server |-> -1]
    /\ flushInFlightCovered = [s \in Server |-> -1]
    /\ flushFailure = [s \in Server |-> FALSE]
    /\ commitIndex = [s \in Server |-> -1]
    /\ metadataCommitIndex = [s \in Server |-> -1]
    /\ stateMachineDataFlushed = [s \in Server |-> -1]
    /\ logTerm = [s \in Server |-> [i \in Index |-> 0]]
    /\ logKind = [s \in Server |-> [i \in Index |-> "none"]]

    /\ matchIndex = [s \in Server |-> [p \in Server |-> -1]]
    /\ nextIndex = [s \in Server |-> [p \in Server |-> 0]]
    /\ votesGranted = [s \in Server |-> {}]
    /\ candidateCommitKnown = [s \in Server |-> FALSE]
    /\ voteReplyLastEntryKind = [s \in Server |-> "valid"]
    /\ leaderStateGeneration = [s \in Server |-> 0]
    /\ leaseEnabled = [s \in Server |-> FALSE]
    /\ leaseFresh = [s \in Server |-> FALSE]
    /\ replyTimestampObserved = [s \in Server |-> FALSE]
    /\ replyResult = [s \in Server |-> "none"]
    /\ leaseReadServed = [s \in Server |-> FALSE]
    /\ readIndexListeners = [s \in Server |-> {}]
    /\ ackedCommitIndex = [s \in Server |-> -1]

    /\ snapshotIndex = [s \in Server |-> -1]
    /\ installedSnapshot = [s \in Server |-> -1]
    /\ snapshotInProgressIndex = [s \in Server |-> -1]
    /\ tempSnapshot = [s \in Server |-> -1]
    /\ snapshotPublished = [s \in Server |-> FALSE]
    /\ logStartIndex = [s \in Server |-> 0]
    /\ pendingReadIndexes = [s \in Server |-> {}]
    /\ readResult = [s \in Server |-> "none"]
    /\ workerQueue = [s \in Server |-> {}]
    /\ appendReplyPending = [s \in Server |-> "none"]

    /\ currentConf = [s \in Server |-> BootstrapConf]
    /\ oldConf = [s \in Server |-> {}]
    /\ durableConf = [s \in Server |-> BootstrapConf]
    /\ stagingPeers = [s \in Server |-> {}]
    /\ caughtUp = [s \in Server |-> {}]
    /\ attemptedSnapshot = [s \in Server |-> {}]
    /\ confLogIndex = [s \in Server |-> -1]
    /\ durableConfLogIndex = [s \in Server |-> -1]
    /\ confAcked = [s \in Server |-> {}]
    /\ recognizedLeader = [s \in Server |-> None]

    /\ messages = {}

\* --------------------------------------------------------------------------
\* Election and vote actions.
\* --------------------------------------------------------------------------

ServerState_initElection_ELECTION(s) ==
    /\ s \in Server
    /\ currentTerm[s] < MaxTerm
    \* Only voting members of the current configuration can start election
    \* rounds. Listener follower loops do not transition to candidate, and
    \* LeaderElection aborts when the server is not in the election conf.
    \* FollowerState.java:136-165, LeaderElection.java:421-425,
    \* RaftServerImpl.java:1858-1871.
    /\ voterRole[s] # Listener
    /\ s \in currentConf[s]
    \* Candidate increments term, votes for self, and persists metadata.
    \* ServerState.java:228-240, ServerState.java:243-245.
    /\ currentTerm' = [currentTerm EXCEPT ![s] = @ + 1]
    /\ role' = [role EXCEPT ![s] = Candidate]
    /\ votedFor' = [votedFor EXCEPT ![s] = s]
    /\ persistedTerm' = [persistedTerm EXCEPT ![s] = currentTerm[s] + 1]
    /\ persistedVote' = [persistedVote EXCEPT ![s] = s]
    /\ leaderId' = [leaderId EXCEPT ![s] = None]
    /\ candidateCommitKnown' = [candidateCommitKnown EXCEPT ![s] = commitIndex[s] >= 0]
    /\ UNCHANGED <<recovered, reformatted, voterRole, logVars,
                  matchIndex, nextIndex, votesGranted, voteReplyLastEntryKind,
                  leaderStateGeneration, leaseEnabled, leaseFresh,
                  replyTimestampObserved, replyResult, leaseReadServed,
                  readIndexListeners, ackedCommitIndex, snapshotVars,
                  configVars, messages>>

LeaderElection_submitRequestVote(c, v) ==
    /\ c \in Server
    /\ v \in Server \ {c}
    /\ role[c] = Candidate
    \* LeaderElection.submitRequests sends RequestVote to peers in the election conf.
    \* LeaderElection.java:485-493.
    /\ messages' = messages \cup {
        Message(c, v, "RequestVote", "election", currentTerm[c], LastLocalEntry(c), "none", "none") }
    /\ UNCHANGED <<serverVars, logVars, leaderVars, snapshotVars, configVars>>

CanGrantVote(v, m) ==
    /\ m.mtype = "RequestVote"
    /\ m.to = v
    \* VoteContext.checkConf rejects candidates outside current conf.
    \* VoteContext.java:54-60.
    /\ m.from \in currentConf[v]
    \* VoteContext.checkTerm permits higher term or unconflicted same-term vote.
    \* VoteContext.java:67-89.
    /\ m.term >= currentTerm[v]
    /\ m.term > currentTerm[v] \/ votedFor[v] = None \/ votedFor[v] = m.from
    \* VoteContext.decideVote rejects listeners and stale logs.
    \* VoteContext.java:136-163, ServerState.java:345-361.
    /\ voterRole[v] # Listener
    /\ LogUpToDate(v, m.index)

RaftServerImpl_requestVote_Grant(v, m) ==
    /\ v \in Server
    /\ m \in messages
    /\ CanGrantVote(v, m)
    \* RaftServerImpl.requestVote changes to follower, grants vote, then syncs metadata.
    \* RaftServerImpl.java:1513-1525, ServerState.java:254-257.
    /\ currentTerm' = [currentTerm EXCEPT ![v] = Max2(@, m.term)]
    /\ role' = [role EXCEPT ![v] = Follower]
    /\ votedFor' = [votedFor EXCEPT ![v] = m.from]
    /\ persistedTerm' = [persistedTerm EXCEPT ![v] = Max2(@, m.term)]
    /\ persistedVote' = [persistedVote EXCEPT ![v] = m.from]
    /\ leaderId' = [leaderId EXCEPT ![v] = None]
    /\ messages' = (messages \ {m}) \cup {
        Message(v, m.from, "RequestVoteReply", "election",
                Max2(currentTerm[v], m.term), LastLocalEntry(v), "SUCCESS", LastEntryKind(v)) }
    /\ UNCHANGED <<recovered, reformatted, voterRole, logVars,
                  matchIndex, nextIndex, votesGranted, candidateCommitKnown,
                  voteReplyLastEntryKind, leaderStateGeneration, leaseEnabled,
                  leaseFresh, replyTimestampObserved, replyResult,
                  leaseReadServed, readIndexListeners, ackedCommitIndex,
                  snapshotVars, configVars>>

RaftServerImpl_requestVote_Reject(v, m) ==
    /\ v \in Server
    /\ m \in messages
    /\ m.mtype = "RequestVote"
    /\ m.to = v
    /\ ~CanGrantVote(v, m)
    \* Reject reply still carries current term and lastEntry evidence.
    \* RaftServerImpl.java:1532-1537, ServerProtoUtils.toRequestVoteReplyProto.
    /\ messages' = (messages \ {m}) \cup {
        Message(v, m.from, "RequestVoteReply", "election",
                currentTerm[v], LastLocalEntry(v), "REJECT", LastEntryKind(v)) }
    /\ UNCHANGED <<serverVars, logVars, leaderVars, snapshotVars, configVars>>

LeaderElection_waitForResults(c) ==
    /\ c \in Server
    /\ role[c] = Candidate
    \* Votes are accepted only when successful and, if the candidate has commits,
    \* the reply is not explicit empty-log evidence. Missing lastEntry is accepted.
    \* LeaderElection.java:506-599, LeaderElection.java:606-619.
    /\ JointMajority(c, GoodVotePeers(c) \cup {c})
    /\ role' = [role EXCEPT ![c] = Leader]
    /\ leaderId' = [leaderId EXCEPT ![c] = c]
    /\ votesGranted' = [votesGranted EXCEPT ![c] = GoodVotePeers(c) \cup {c}]
    /\ leaderStateGeneration' = [leaderStateGeneration EXCEPT ![c] = @ + 1]
    /\ messages' = messages \ {m \in messages : m.mtype = "RequestVoteReply" /\ m.to = c}
    /\ UNCHANGED <<currentTerm, votedFor, persistedTerm, persistedVote, recovered,
                  reformatted, voterRole, logVars,
                  matchIndex, nextIndex, candidateCommitKnown,
                  voteReplyLastEntryKind, leaseEnabled, leaseFresh,
                  replyTimestampObserved, replyResult, leaseReadServed,
                  readIndexListeners, ackedCommitIndex, snapshotVars, configVars>>

ServerProtoUtils_setVoteReplyLastEntryKind(s, kind) ==
    /\ s \in Server
    /\ kind \in VoteKinds
    \* Scenario 2 models valid, explicit empty, and missing/default lastEntry
    \* vote reply evidence. Missing/default is accepted for old-version
    \* compatibility.
    \* LeaderElection.java:601-619.
    /\ voteReplyLastEntryKind' = [voteReplyLastEntryKind EXCEPT ![s] = kind]
    /\ UNCHANGED <<serverVars, logVars,
                  matchIndex, nextIndex, votesGranted, candidateCommitKnown,
                  leaderStateGeneration, leaseEnabled, leaseFresh,
                  replyTimestampObserved, replyResult, leaseReadServed,
                  readIndexListeners, ackedCommitIndex,
                  snapshotVars, configVars, messages>>

\* --------------------------------------------------------------------------
\* WAL append, flush, commit, metadata, crash/recovery.
\* --------------------------------------------------------------------------

RaftLogBase_appendEntry_CacheAndQueue(s, idx, kind, p) ==
    /\ s \in Server
    /\ idx \in Index
    /\ kind \in {"normal", "config"}
    /\ p \in Server
    /\ role[s] = Leader
    /\ idx = LastLocalEntry(s) + 1
    \* SegmentedRaftLog.appendEntry queues worker write before cache visibility.
    \* SegmentedRaftLog.java:430-444, RaftLogBase.java:169-213.
    /\ volatileLog' = [volatileLog EXCEPT ![s] = @ \cup {idx}]
    /\ writeQueue' = [writeQueue EXCEPT ![s] = @ \cup {idx}]
    /\ workerQueue' = [workerQueue EXCEPT ![s] = @ \cup {idx}]
    /\ logTerm' = [logTerm EXCEPT ![s][idx] = currentTerm[s]]
    /\ logKind' = [logKind EXCEPT ![s][idx] = kind]
    /\ currentConf' = [currentConf EXCEPT ![s] =
        IF kind = "config" THEN @ \cup {p} ELSE @]
    /\ oldConf' = [oldConf EXCEPT ![s] =
        IF kind = "config" /\ p \notin currentConf[s] THEN currentConf[s] ELSE @]
    /\ confLogIndex' = [confLogIndex EXCEPT ![s] =
        IF kind = "config" THEN Max2(@, idx) ELSE @]
    /\ confAcked' = [confAcked EXCEPT ![s] =
        IF kind = "config" THEN @ \cup {s} ELSE @]
    /\ UNCHANGED <<serverVars, diskLog, lastWrittenIndex, flushIndex,
                  flushInFlightIndex, flushInFlightCovered, flushFailure,
                  commitIndex, metadataCommitIndex, stateMachineDataFlushed,
                  matchIndex, nextIndex, votesGranted, candidateCommitKnown,
                  voteReplyLastEntryKind, leaderStateGeneration, leaseEnabled,
                  leaseFresh, replyTimestampObserved, replyResult,
                  leaseReadServed, readIndexListeners, ackedCommitIndex,
                  snapshotIndex, installedSnapshot, snapshotInProgressIndex,
                  tempSnapshot, snapshotPublished, logStartIndex,
                  pendingReadIndexes, readResult, appendReplyPending,
                  durableConf, stagingPeers, caughtUp, attemptedSnapshot,
                  durableConfLogIndex, recognizedLeader, messages>>

SegmentedRaftLogWorker_WriteLog_execute(s, idx) ==
    /\ s \in Server
    /\ idx \in writeQueue[s]
    /\ idx = lastWrittenIndex[s] + 1
    \* WriteLog.execute writes to the output stream and advances lastWrittenIndex;
    \* durability is not published until flush completes.
    \* SegmentedRaftLogWorker.java:549-562.
    /\ lastWrittenIndex' = [lastWrittenIndex EXCEPT ![s] = idx]
    /\ writeQueue' = [writeQueue EXCEPT ![s] = @ \ {idx}]
    /\ workerQueue' = [workerQueue EXCEPT ![s] = @ \ {idx}]
    /\ UNCHANGED <<serverVars, volatileLog, diskLog, flushIndex,
                  flushInFlightIndex, flushInFlightCovered, flushFailure,
                  commitIndex, metadataCommitIndex, stateMachineDataFlushed,
                  logTerm, logKind, leaderVars,
                  snapshotIndex, installedSnapshot, snapshotInProgressIndex,
                  tempSnapshot, snapshotPublished, logStartIndex,
                  pendingReadIndexes, readResult, appendReplyPending,
                  configVars, messages>>

SegmentedRaftLogWorker_flushIfNecessary_Start(s) ==
    /\ s \in Server
    /\ lastWrittenIndex[s] > flushIndex[s]
    /\ flushInFlightIndex[s] = -1
    \* flushIfNecessary captures a force/state-machine flush future after writes.
    \* SegmentedRaftLogWorker.java:368-392.
    /\ flushInFlightIndex' = [flushInFlightIndex EXCEPT ![s] = lastWrittenIndex[s]]
    /\ flushInFlightCovered' = [flushInFlightCovered EXCEPT ![s] = lastWrittenIndex[s]]
    /\ flushFailure' = [flushFailure EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<serverVars, volatileLog, diskLog, writeQueue,
                  lastWrittenIndex, flushIndex, commitIndex,
                  metadataCommitIndex, stateMachineDataFlushed, logTerm,
                  logKind, leaderVars, snapshotVars, configVars, messages>>

SegmentedRaftLogWorker_asyncFlushOutStream_Fail(s) ==
    /\ s \in Server
    /\ flushInFlightIndex[s] # -1
    \* The async callback receives an exception value, but the implementation path
    \* under review does not check it before publishing.
    \* SegmentedRaftLogWorker.java:402-409.
    /\ flushFailure' = [flushFailure EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<serverVars, volatileLog, diskLog, writeQueue,
                  lastWrittenIndex, flushIndex, flushInFlightIndex,
                  flushInFlightCovered, commitIndex, metadataCommitIndex,
                  stateMachineDataFlushed, logTerm, logKind, leaderVars,
                  snapshotVars, configVars, messages>>

SegmentedRaftLogWorker_asyncFlushOutStream_Complete(s) ==
    /\ s \in Server
    /\ flushInFlightIndex[s] # -1
    /\ flushFailure[s] = FALSE
    \* Correct completion publishes only the captured force boundary and the
    \* state-machine data boundary covered by that future.
    \* SegmentedRaftLogWorker.java:402-409, SegmentedRaftLogWorker.java:422-430.
    /\ flushIndex' = [flushIndex EXCEPT ![s] = Max2(@, flushInFlightCovered[s])]
    /\ diskLog' = [diskLog EXCEPT ![s] = @ \cup IndexPrefix(flushInFlightCovered[s])]
    /\ stateMachineDataFlushed' = [stateMachineDataFlushed EXCEPT ![s] = Max2(@, flushInFlightCovered[s])]
    /\ metadataCommitIndex' = [metadataCommitIndex EXCEPT ![s] = Max2(@, FlushedMetadataCommitIndex(s))]
    /\ commitIndex' = [commitIndex EXCEPT ![s] =
        IF role[s] = Leader THEN @ ELSE Max2(@, flushInFlightCovered[s])]
    /\ flushInFlightIndex' = [flushInFlightIndex EXCEPT ![s] = -1]
    /\ flushInFlightCovered' = [flushInFlightCovered EXCEPT ![s] = -1]
    /\ flushFailure' = [flushFailure EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<serverVars, volatileLog, writeQueue, lastWrittenIndex,
                  logTerm, logKind,
                  leaderVars, snapshotVars, configVars, messages>>

SegmentedRaftLogWorker_asyncFlushOutStream_CompleteLateOrFailed(s) ==
    /\ s \in Server
    /\ flushInFlightIndex[s] # -1
    /\ flushFailure[s] \/ lastWrittenIndex[s] > flushInFlightCovered[s]
    \* Optional fault action for Scenario 1: model the async callback publishing
    \* callback-time lastWrittenIndex or publishing after force/state-machine
    \* failure. This action is disabled in the default MC.cfg and enabled only
    \* by the Scenario 1 hunt config.
    \* SegmentedRaftLogWorker.java:402-409.
    /\ flushIndex' = [flushIndex EXCEPT ![s] = Max2(@, lastWrittenIndex[s])]
    /\ flushInFlightIndex' = [flushInFlightIndex EXCEPT ![s] = -1]
    /\ flushInFlightCovered' = [flushInFlightCovered EXCEPT ![s] = -1]
    /\ UNCHANGED <<serverVars, volatileLog, diskLog, writeQueue,
                  lastWrittenIndex, flushFailure, commitIndex,
                  metadataCommitIndex, stateMachineDataFlushed, logTerm,
                  logKind, leaderVars, snapshotVars, configVars, messages>>

LeaderStateImpl_updateCommit(s, idx) ==
    /\ s \in Server
    /\ idx \in Index
    /\ role[s] = Leader
    /\ idx > commitIndex[s]
    \* LeaderStateImpl includes local raftLog.getFlushIndex in majority/min
    \* computation, then ServerState.updateCommitIndex delegates to RaftLogBase.
    \* LeaderStateImpl.java:946-949, LeaderStateImpl.java:1015-1023.
    /\ JointMajority(s, {p \in Server : matchIndex[s][p] >= idx} \cup
                       IF flushIndex[s] >= idx THEN {s} ELSE {})
    /\ idx <= flushIndex[s]
    /\ logTerm[s][idx] = currentTerm[s]
    /\ commitIndex' = [commitIndex EXCEPT ![s] = idx]
    /\ UNCHANGED <<serverVars, volatileLog, diskLog, writeQueue,
                  lastWrittenIndex, flushIndex, flushInFlightIndex,
                  flushInFlightCovered, flushFailure, metadataCommitIndex,
                  stateMachineDataFlushed, logTerm, logKind, leaderVars,
                  snapshotVars, configVars, messages>>

RaftLogBase_appendMetadata(s) ==
    /\ s \in Server
    /\ role[s] = Leader
    /\ commitIndex[s] > metadataCommitIndex[s]
    /\ commitIndex[s] > 0
    /\ commitIndex[s] < MaxIndex
    \* appendMetadata appends a metadata entry and marks lastMetadataEntry
    \* immediately after append is enqueued.
    \* RaftLogBase.java:217-235, LeaderStateImpl.java:1028-1031.
    /\ metadataCommitIndex' = [metadataCommitIndex EXCEPT ![s] = commitIndex[s]]
    /\ volatileLog' = [volatileLog EXCEPT ![s] = @ \cup {commitIndex[s] + 1}]
    /\ writeQueue' = [writeQueue EXCEPT ![s] = @ \cup {commitIndex[s] + 1}]
    /\ logTerm' = [logTerm EXCEPT ![s][commitIndex[s] + 1] = currentTerm[s]]
    /\ logKind' = [logKind EXCEPT ![s][commitIndex[s] + 1] = "metadata"]
    /\ UNCHANGED <<currentTerm, role, votedFor, leaderId, persistedTerm,
                  persistedVote, recovered, reformatted, voterRole,
                  diskLog, lastWrittenIndex, flushIndex, flushInFlightIndex,
                  flushInFlightCovered, flushFailure, commitIndex,
                  stateMachineDataFlushed, leaderVars, snapshotVars,
                  configVars, messages, workerQueue>>

CrashAndRecover(s) ==
    /\ s \in Server
    \* Recovery loads durable metadata/config/log/snapshot; in-memory role and
    \* volatile log are reconstructed from durable evidence.
    \* ServerState.java:129-142, RaftStorageImpl.java:105-123,
    \* ServerState.java:425-429.
    /\ currentTerm' = [currentTerm EXCEPT ![s] = persistedTerm[s]]
    /\ votedFor' = [votedFor EXCEPT ![s] = persistedVote[s]]
    /\ role' = [role EXCEPT ![s] =
        IF s \in RecoveredConf(s) THEN Follower ELSE Listener]
    /\ leaderId' = [leaderId EXCEPT ![s] = None]
    /\ recovered' = [recovered EXCEPT ![s] = TRUE]
    /\ volatileLog' = [volatileLog EXCEPT ![s] = diskLog[s]]
    /\ writeQueue' = [writeQueue EXCEPT ![s] = {}]
    /\ workerQueue' = [workerQueue EXCEPT ![s] = {}]
    /\ lastWrittenIndex' = [lastWrittenIndex EXCEPT ![s] = DurableBoundary(s)]
    /\ flushIndex' = [flushIndex EXCEPT ![s] = DurableBoundary(s)]
    /\ flushInFlightIndex' = [flushInFlightIndex EXCEPT ![s] = -1]
    /\ flushInFlightCovered' = [flushInFlightCovered EXCEPT ![s] = -1]
    /\ flushFailure' = [flushFailure EXCEPT ![s] = FALSE]
    /\ commitIndex' = [commitIndex EXCEPT ![s] = metadataCommitIndex[s]]
    /\ currentConf' = [currentConf EXCEPT ![s] = RecoveredConf(s)]
    /\ oldConf' = [oldConf EXCEPT ![s] = {}]
    /\ confLogIndex' = [confLogIndex EXCEPT ![s] = DurableConfigIndex(s)]
    /\ voterRole' = [voterRole EXCEPT ![s] =
        IF s \in RecoveredConf(s) THEN Follower ELSE Listener]
    /\ UNCHANGED <<persistedTerm, persistedVote, reformatted, diskLog,
                  metadataCommitIndex, stateMachineDataFlushed, logTerm,
                  logKind, leaderVars, snapshotIndex, installedSnapshot,
                  snapshotInProgressIndex, tempSnapshot, snapshotPublished,
                  logStartIndex, pendingReadIndexes, readResult,
                  appendReplyPending, durableConf, stagingPeers, caughtUp,
                  attemptedSnapshot, durableConfLogIndex,
                  confAcked, recognizedLeader, messages>>

RaftStorageImpl_formatEmptyStorage(s) ==
    /\ s \in Server
    /\ reformatted[s] = FALSE
    \* Empty storage can be formatted with default metadata; production reaches
    \* this path only for FORMAT startup or NOT_FORMATTED current-empty storage.
    \* RaftStorageImpl.java:55-64, RaftStorageImpl.java:118-123,
    \* StorageImplUtils.java:137-151.
    /\ FormatStorageIsEmpty(s)
    /\ reformatted' = [reformatted EXCEPT ![s] = TRUE]
    /\ persistedTerm' = [persistedTerm EXCEPT ![s] = 0]
    /\ persistedVote' = [persistedVote EXCEPT ![s] = None]
    /\ diskLog' = [diskLog EXCEPT ![s] = {}]
    /\ volatileLog' = [volatileLog EXCEPT ![s] = {}]
    /\ snapshotIndex' = [snapshotIndex EXCEPT ![s] = -1]
    /\ installedSnapshot' = [installedSnapshot EXCEPT ![s] = -1]
    /\ metadataCommitIndex' = [metadataCommitIndex EXCEPT ![s] = -1]
    /\ currentConf' = [currentConf EXCEPT ![s] = BootstrapConf]
    /\ durableConf' = [durableConf EXCEPT ![s] = BootstrapConf]
    /\ confLogIndex' = [confLogIndex EXCEPT ![s] = -1]
    /\ durableConfLogIndex' = [durableConfLogIndex EXCEPT ![s] = -1]
    /\ voterRole' = [voterRole EXCEPT ![s] =
        IF s \in BootstrapConf THEN Follower ELSE Listener]
    /\ UNCHANGED <<currentTerm, role, votedFor, leaderId, recovered,
                  writeQueue, lastWrittenIndex, flushIndex,
                  flushInFlightIndex, flushInFlightCovered, flushFailure,
                  commitIndex, stateMachineDataFlushed, logTerm, logKind,
                  leaderVars, snapshotInProgressIndex, tempSnapshot,
                  snapshotPublished, logStartIndex, pendingReadIndexes,
                  readResult, workerQueue, appendReplyPending,
                  oldConf, stagingPeers, caughtUp,
                  attemptedSnapshot,
                  confAcked, recognizedLeader, messages>>

\* --------------------------------------------------------------------------
\* AppendEntries, snapshot, and ReadIndex actions.
\* --------------------------------------------------------------------------

LeaderStateImpl_sendAppendEntries(l, f, idx) ==
    /\ l \in Server
    /\ f \in Server \ {l}
    /\ idx \in IndexOrInvalid
    /\ role[l] = Leader
    \* LogAppenderBase heartbeat trigger and LogAppenderDefault send path.
    \* LogAppenderBase.java:83-103, LogAppenderDefault.java:80-105.
    /\ messages' = messages \cup {
        Message(l, f, "AppendEntries",
                IF idx = -1 THEN "heartbeat" ELSE "replicate",
                currentTerm[l], idx, "none", "none") }
    /\ UNCHANGED <<serverVars, logVars, leaderVars, snapshotVars, configVars>>

RaftServerImpl_appendEntriesAsync_RejectSnapshot(f, m) ==
    /\ f \in Server
    /\ m \in messages
    /\ m.mtype = "AppendEntries"
    /\ m.to = f
    /\ snapshotInProgressIndex[f] # -1
    \* checkInconsistentAppendEntries rejects while snapshot install is in progress.
    \* RaftServerImpl.java:1739-1745.
    /\ appendReplyPending' = [appendReplyPending EXCEPT ![f] = "inconsistency"]
    /\ messages' = (messages \ {m}) \cup {
        Message(f, m.from, "AppendEntriesReply", m.msubtype,
                currentTerm[f], stateMachineDataFlushed[f], "INCONSISTENCY", "none") }
    /\ UNCHANGED <<serverVars, logVars, leaderVars,
                  snapshotIndex, installedSnapshot, snapshotInProgressIndex,
                  tempSnapshot, snapshotPublished, logStartIndex,
                  pendingReadIndexes, readResult, workerQueue,
                  configVars>>

RaftServerImpl_appendEntriesAsync_Success(f, m) ==
    /\ f \in Server
    /\ m \in messages
    /\ m.mtype = "AppendEntries"
    /\ m.to = f
    /\ snapshotInProgressIndex[f] = -1
    /\ m.term >= currentTerm[f]
    /\ m.index = -1 \/ m.index = LastLocalEntry(f) + 1
    \* appendEntries recognizes leader, updates configuration before append future,
    \* then appends and updates commit from effectiveCommitIndex.
    \* RaftServerImpl.java:1639-1731.
    /\ currentTerm' = [currentTerm EXCEPT ![f] = Max2(@, m.term)]
    /\ role' = [role EXCEPT ![f] = Follower]
    /\ leaderId' = [leaderId EXCEPT ![f] = m.from]
    /\ recognizedLeader' = [recognizedLeader EXCEPT ![f] = m.from]
    /\ volatileLog' = [volatileLog EXCEPT ![f] =
        IF m.index = -1 THEN @ ELSE @ \cup {m.index}]
    /\ writeQueue' = [writeQueue EXCEPT ![f] =
        IF m.index = -1 THEN @ ELSE @ \cup {m.index}]
    /\ logTerm' = [logTerm EXCEPT ![f] =
        IF m.index = -1 THEN @ ELSE [@ EXCEPT ![m.index] = m.term]]
    /\ logKind' = [logKind EXCEPT ![f] =
        IF m.index = -1 THEN @ ELSE [@ EXCEPT ![m.index] = logKind[m.from][m.index]]]
    /\ appendReplyPending' = [appendReplyPending EXCEPT ![f] = "success"]
    /\ messages' = (messages \ {m}) \cup {
        Message(f, m.from, "AppendEntriesReply", m.msubtype,
                Max2(currentTerm[f], m.term), m.index, "SUCCESS", "none") }
    /\ UNCHANGED <<votedFor, persistedTerm, persistedVote, recovered,
                  reformatted, voterRole, diskLog, lastWrittenIndex,
                  flushIndex, flushInFlightIndex, flushInFlightCovered,
                  flushFailure, commitIndex, metadataCommitIndex,
                  stateMachineDataFlushed, leaderVars,
                  snapshotIndex, installedSnapshot, snapshotInProgressIndex,
                  tempSnapshot, snapshotPublished, logStartIndex,
                  pendingReadIndexes, readResult, workerQueue,
                  currentConf, oldConf, durableConf, stagingPeers, caughtUp,
                  attemptedSnapshot, confLogIndex, durableConfLogIndex,
                  confAcked>>

RaftServerImpl_appendEntriesAsync_AcceptDuringSnapshotFault(f, m) ==
    /\ f \in Server
    /\ m \in messages
    /\ m.mtype = "AppendEntries"
    /\ m.to = f
    /\ snapshotInProgressIndex[f] # -1
    /\ m.index \in Index
    \* Optional Scenario 3 fault: append succeeds despite the in-progress snapshot
    \* exclusion check. Disabled in default MC.cfg.
    \* RaftServerImpl.java:1739-1745.
    /\ volatileLog' = [volatileLog EXCEPT ![f] = @ \cup {m.index}]
    /\ appendReplyPending' = [appendReplyPending EXCEPT ![f] = "success"]
    /\ messages' = messages \ {m}
    /\ UNCHANGED <<serverVars, diskLog, writeQueue, lastWrittenIndex,
                  flushIndex, flushInFlightIndex, flushInFlightCovered,
                  flushFailure, commitIndex, metadataCommitIndex,
                  stateMachineDataFlushed, logTerm, logKind, leaderVars,
                  snapshotIndex, installedSnapshot, snapshotInProgressIndex,
                  tempSnapshot, snapshotPublished, logStartIndex,
                  pendingReadIndexes, readResult, workerQueue, configVars>>

SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot(f, l, idx) ==
    /\ f \in Server
    /\ l \in Server \ {f}
    /\ idx \in Index
    /\ snapshotInProgressIndex[f] = -1
    /\ currentTerm[l] >= currentTerm[f]
    \* Notification mode recognizes leader, persists follower metadata, sets
    \* inProgressInstallSnapshotIndex, and fails reads.
    \* SnapshotInstallationHandler.java:253-396, RaftServerImpl.java:1099-1107.
    /\ role' = [role EXCEPT ![f] = Follower]
    /\ currentTerm' = [currentTerm EXCEPT ![f] = Max2(@, currentTerm[l])]
    /\ persistedTerm' = [persistedTerm EXCEPT ![f] = Max2(@, currentTerm[l])]
    /\ leaderId' = [leaderId EXCEPT ![f] = l]
    /\ recognizedLeader' = [recognizedLeader EXCEPT ![f] = l]
    /\ snapshotInProgressIndex' = [snapshotInProgressIndex EXCEPT ![f] = idx]
    /\ pendingReadIndexes' = [pendingReadIndexes EXCEPT ![f] = {}]
    /\ readResult' = [readResult EXCEPT ![f] = "failed"]
    /\ appendReplyPending' = [appendReplyPending EXCEPT ![f] = "none"]
    /\ UNCHANGED <<votedFor, persistedVote, recovered, reformatted,
                  voterRole, logVars, leaderVars, snapshotIndex,
                  installedSnapshot, tempSnapshot, snapshotPublished,
                  logStartIndex, workerQueue,
                  currentConf, oldConf, durableConf, stagingPeers, caughtUp,
                  attemptedSnapshot, confLogIndex, durableConfLogIndex,
                  confAcked, messages>>

SnapshotInstallationHandler_checkAndInstallSnapshot_AppendChunk(f, idx) ==
    /\ f \in Server
    /\ idx \in Index
    /\ idx >= tempSnapshot[f]
    \* Chunk mode appends chunks to a temporary location before final publish.
    \* SnapshotInstallationHandler.java:174-250.
    /\ tempSnapshot' = [tempSnapshot EXCEPT ![f] = idx]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, snapshotIndex,
                  installedSnapshot, snapshotInProgressIndex,
                  snapshotPublished, logStartIndex, pendingReadIndexes,
                  readResult, workerQueue, appendReplyPending,
                  configVars, messages>>

SnapshotInstallationHandler_checkAndInstallSnapshot_FinalChunkPublish(f) ==
    /\ f \in Server
    /\ tempSnapshot[f] \in Index
    \* Final chunk pauses state machine, finalizes snapshot, reloads, and syncs
    \* the log worker with the installed snapshot.
    \* SnapshotInstallationHandler.java:229-250, ServerState.java:425-429,
    \* SegmentedRaftLogWorker.java:261-267.
    /\ snapshotIndex' = [snapshotIndex EXCEPT ![f] = Max2(@, tempSnapshot[f])]
    /\ installedSnapshot' = [installedSnapshot EXCEPT ![f] = Max2(@, tempSnapshot[f])]
    /\ snapshotPublished' = [snapshotPublished EXCEPT ![f] = TRUE]
    /\ logStartIndex' = [logStartIndex EXCEPT ![f] = Max2(@, tempSnapshot[f] + 1)]
    /\ diskLog' = [diskLog EXCEPT ![f] = @ \cap ((tempSnapshot[f] + 1)..MaxIndex)]
    /\ volatileLog' = [volatileLog EXCEPT ![f] = @ \cap ((tempSnapshot[f] + 1)..MaxIndex)]
    /\ flushIndex' = [flushIndex EXCEPT ![f] = Max2(@, tempSnapshot[f])]
    /\ lastWrittenIndex' = [lastWrittenIndex EXCEPT ![f] = Max2(@, tempSnapshot[f])]
    /\ workerQueue' = [workerQueue EXCEPT ![f] = {}]
    /\ tempSnapshot' = [tempSnapshot EXCEPT ![f] = -1]
    /\ UNCHANGED <<currentTerm, role, votedFor, leaderId, persistedTerm,
                  persistedVote, recovered, reformatted, voterRole,
                  writeQueue, flushInFlightIndex, flushInFlightCovered,
                  flushFailure, commitIndex, metadataCommitIndex,
                  stateMachineDataFlushed, logTerm, logKind, leaderVars,
                  snapshotInProgressIndex, pendingReadIndexes, readResult,
                  appendReplyPending, configVars, messages>>

SnapshotInstallationHandler_notifyStateMachine_Complete(f) ==
    /\ f \in Server
    /\ snapshotInProgressIndex[f] \in Index
    \* Async state-machine notification later reloads the state machine and
    \* clears inProgressInstallSnapshotIndex.
    \* SnapshotInstallationHandler.java:331-386.
    /\ installedSnapshot' = [installedSnapshot EXCEPT ![f] = snapshotInProgressIndex[f]]
    /\ snapshotIndex' = [snapshotIndex EXCEPT ![f] = snapshotInProgressIndex[f]]
    /\ logStartIndex' = [logStartIndex EXCEPT ![f] = snapshotInProgressIndex[f] + 1]
    /\ diskLog' = [diskLog EXCEPT ![f] = @ \cap ((snapshotInProgressIndex[f] + 1)..MaxIndex)]
    /\ volatileLog' = [volatileLog EXCEPT ![f] = @ \cap ((snapshotInProgressIndex[f] + 1)..MaxIndex)]
    /\ flushIndex' = [flushIndex EXCEPT ![f] = Max2(@, snapshotInProgressIndex[f])]
    /\ lastWrittenIndex' = [lastWrittenIndex EXCEPT ![f] = Max2(@, snapshotInProgressIndex[f])]
    /\ workerQueue' = [workerQueue EXCEPT ![f] = {}]
    /\ snapshotInProgressIndex' = [snapshotInProgressIndex EXCEPT ![f] = -1]
    /\ readResult' = [readResult EXCEPT ![f] = "none"]
    /\ UNCHANGED <<currentTerm, role, votedFor, leaderId, persistedTerm,
                  persistedVote, recovered, reformatted, voterRole,
                  writeQueue, flushInFlightIndex, flushInFlightCovered,
                  flushFailure, commitIndex, metadataCommitIndex,
                  stateMachineDataFlushed, logTerm, logKind, leaderVars,
                  tempSnapshot, snapshotPublished, pendingReadIndexes,
                  appendReplyPending, configVars, messages>>

RaftServerImpl_sendReadIndexAsync(f, idx) ==
    /\ f \in Server
    /\ idx \in Index
    \* ReadIndex forwarding fails while snapshot install is in progress.
    \* RaftServerImpl.java:1099-1118.
    /\ IF snapshotInProgressIndex[f] # -1
       THEN /\ readResult' = [readResult EXCEPT ![f] = "failed"]
            /\ pendingReadIndexes' = [pendingReadIndexes EXCEPT ![f] = @ \ {idx}]
       ELSE /\ readResult' = [readResult EXCEPT ![f] = "pending"]
            /\ pendingReadIndexes' = [pendingReadIndexes EXCEPT ![f] = @ \cup {idx}]
    /\ UNCHANGED <<serverVars, logVars, leaderVars,
                  snapshotIndex, installedSnapshot, snapshotInProgressIndex,
                  tempSnapshot, snapshotPublished, logStartIndex,
                  workerQueue, appendReplyPending, configVars, messages>>

LeaderStateImpl_getReadIndex_LeaseFastPath(l, idx) ==
    /\ l \in Server
    /\ idx \in Index
    /\ role[l] = Leader
    /\ leaseEnabled[l]
    /\ leaseFresh[l]
    \* getReadIndex returns immediately when heartbeat checking is disabled or
    \* leader lease is valid.
    \* LeaderStateImpl.java:1181-1218, LeaderStateImpl.java:1229-1249.
    /\ readResult' = [readResult EXCEPT ![l] = "success"]
    /\ leaseReadServed' = [leaseReadServed EXCEPT ![l] = TRUE]
    /\ pendingReadIndexes' = [pendingReadIndexes EXCEPT ![l] = @ \ {idx}]
    /\ UNCHANGED <<serverVars, logVars,
                  matchIndex, nextIndex, votesGranted, candidateCommitKnown,
                  voteReplyLastEntryKind, leaderStateGeneration, leaseEnabled,
                  leaseFresh, replyTimestampObserved, replyResult,
                  readIndexListeners, ackedCommitIndex,
                  snapshotIndex, installedSnapshot, snapshotInProgressIndex,
                  tempSnapshot, snapshotPublished, logStartIndex, workerQueue,
                  appendReplyPending, configVars, messages>>

LeaderLease_enableForTarget(l) ==
    /\ l \in Server
    /\ role[l] = Leader
    \* LeaderLease is configured from raft.server.read.leader.lease.* and is
    \* disabled in the default model; hunt configs enable this action for
    \* Scenario 4.
    \* LeaderLease.java:42-49, LeaderStateImpl.java:1202-1205.
    /\ leaseEnabled' = [leaseEnabled EXCEPT ![l] = TRUE]
    /\ UNCHANGED <<serverVars, logVars,
                  matchIndex, nextIndex, votesGranted, candidateCommitKnown,
                  voteReplyLastEntryKind, leaderStateGeneration, leaseFresh,
                  replyTimestampObserved, replyResult, leaseReadServed,
                  readIndexListeners, ackedCommitIndex,
                  snapshotVars, configVars, messages>>

LogAppenderDefault_receiveAppendEntriesReply_Timestamp(l, f, result) ==
    /\ l \in Server
    /\ f \in Server \ {l}
    /\ result \in {"SUCCESS", "NOT_LEADER", "HIGHER_TERM", "INCONSISTENCY"}
    /\ role[l] = Leader
    \* sendAppendEntriesWithRetries records lastRespondedAppendEntriesSendTime
    \* before handleReply processes SUCCESS, NOT_LEADER, or INCONSISTENCY.
    \* LogAppenderDefault.java:94-105, LogAppenderDefault.java:192-225.
    /\ replyTimestampObserved' = [replyTimestampObserved EXCEPT ![l] = TRUE]
    /\ replyResult' = [replyResult EXCEPT ![l] = result]
    /\ matchIndex' = [matchIndex EXCEPT ![l][f] =
        IF result = "SUCCESS" THEN Max2(@, LastLocalEntry(l)) ELSE @]
    /\ confAcked' = [confAcked EXCEPT ![l] =
        IF result = "SUCCESS" /\ confLogIndex[l] # -1 /\ LastLocalEntry(l) >= confLogIndex[l]
        THEN @ \cup {f}
        ELSE @]
    /\ UNCHANGED <<serverVars, logVars, nextIndex, votesGranted,
                  candidateCommitKnown, voteReplyLastEntryKind,
                  leaderStateGeneration, leaseEnabled, leaseFresh,
                  leaseReadServed, readIndexListeners, ackedCommitIndex,
                  snapshotVars, currentConf, oldConf, durableConf, stagingPeers,
                  caughtUp, attemptedSnapshot, confLogIndex,
                  durableConfLogIndex, recognizedLeader, messages>>

LeaderLease_extend(l) ==
    /\ l \in Server
    /\ role[l] = Leader
    /\ leaseEnabled[l]
    /\ replyTimestampObserved[l]
    /\ JointMajority(l, {p \in Server : matchIndex[l][p] >= commitIndex[l]} \cup {l})
    \* LeaderLease.extend decides from response timestamps and majority.
    \* LeaderLease.java:68-83, LeaderStateImpl.java:1238-1243.
    /\ leaseFresh' = [leaseFresh EXCEPT ![l] = TRUE]
    /\ UNCHANGED <<serverVars, logVars, matchIndex, nextIndex, votesGranted,
                  candidateCommitKnown, voteReplyLastEntryKind,
                  leaderStateGeneration, leaseEnabled,
                  replyTimestampObserved, replyResult, leaseReadServed,
                  readIndexListeners, ackedCommitIndex, snapshotVars,
                  configVars, messages>>

LogAppenderDefault_handleReply_NotLeaderOrHigherTerm(l) ==
    /\ l \in Server
    /\ role[l] = Leader
    /\ replyResult[l] \in {"NOT_LEADER", "HIGHER_TERM"}
    \* handleReply delegates higher-term/not-leader outcomes to step down.
    \* LogAppenderDefault.java:192-225, LeaderStateImpl.java:460-478.
    /\ role' = [role EXCEPT ![l] = Follower]
    /\ leaderId' = [leaderId EXCEPT ![l] = None]
    /\ leaseFresh' = [leaseFresh EXCEPT ![l] = FALSE]
    /\ leaseEnabled' = [leaseEnabled EXCEPT ![l] = FALSE]
    /\ readIndexListeners' = [readIndexListeners EXCEPT ![l] = {}]
    /\ leaderStateGeneration' = [leaderStateGeneration EXCEPT ![l] = @ + 1]
    /\ UNCHANGED <<currentTerm, votedFor, persistedTerm, persistedVote,
                  recovered, reformatted, voterRole, logVars,
                  matchIndex, nextIndex, votesGranted, candidateCommitKnown,
                  voteReplyLastEntryKind, replyTimestampObserved, replyResult,
                  leaseReadServed, ackedCommitIndex, snapshotVars,
                  configVars, messages>>

LeaderStateImpl_stop(l) ==
    /\ l \in Server
    /\ role[l] = Leader
    \* stop fails pending ReadIndex listeners and disables the lease.
    \* LeaderStateImpl.java:460-478.
    /\ role' = [role EXCEPT ![l] = Follower]
    /\ leaseFresh' = [leaseFresh EXCEPT ![l] = FALSE]
    /\ leaseEnabled' = [leaseEnabled EXCEPT ![l] = FALSE]
    /\ readIndexListeners' = [readIndexListeners EXCEPT ![l] = {}]
    /\ leaderStateGeneration' = [leaderStateGeneration EXCEPT ![l] = @ + 1]
    /\ UNCHANGED <<currentTerm, votedFor, leaderId, persistedTerm,
                  persistedVote, recovered, reformatted, voterRole, logVars,
                  matchIndex, nextIndex, votesGranted, candidateCommitKnown,
                  voteReplyLastEntryKind, replyTimestampObserved, replyResult,
                  leaseReadServed, ackedCommitIndex, snapshotVars,
                  configVars, messages>>

\* --------------------------------------------------------------------------
\* Configuration staging and membership actions.
\* --------------------------------------------------------------------------

LeaderStateImpl_startSetConfiguration(l, p) ==
    /\ l \in Server
    /\ p \in Server \ {l}
    /\ role[l] = Leader
    /\ stagingPeers[l] = {}
    \* startSetConfiguration adds new senders before old/new config is appended.
    \* LeaderStateImpl.java:518-553.
    /\ stagingPeers' = [stagingPeers EXCEPT ![l] = {p}]
    /\ caughtUp' = [caughtUp EXCEPT ![l] = @ \ {p}]
    /\ attemptedSnapshot' = [attemptedSnapshot EXCEPT ![l] = @ \ {p}]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, snapshotVars,
                  currentConf, oldConf, durableConf, confLogIndex,
                  durableConfLogIndex, confAcked, recognizedLeader, messages>>

LeaderStateImpl_markAttemptedSnapshot(l, p) ==
    /\ l \in Server
    /\ role[l] = Leader
    /\ p \in stagingPeers[l]
    \* LogAppenderDefault marks attempted snapshot after snapshot reply outcomes.
    \* LogAppenderDefault.java:160-175.
    /\ attemptedSnapshot' = [attemptedSnapshot EXCEPT ![l] = @ \cup {p}]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, snapshotVars,
                  currentConf, oldConf, durableConf, stagingPeers, caughtUp,
                  confLogIndex, durableConfLogIndex, confAcked,
                  recognizedLeader, messages>>

LeaderStateImpl_checkProgress_CaughtUp(l, p) ==
    /\ l \in Server
    /\ role[l] = Leader
    /\ p \in stagingPeers[l]
    /\ p \in attemptedSnapshot[l]
    /\ matchIndex[l][p] >= Max2(commitIndex[l], confLogIndex[l])
    \* checkProgress requires match index, conf index, recent response, and
    \* snapshot-attempt gates before declaring a peer caught up.
    \* LeaderStateImpl.java:828-840.
    /\ caughtUp' = [caughtUp EXCEPT ![l] = @ \cup {p}]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, snapshotVars,
                  currentConf, oldConf, durableConf, stagingPeers,
                  attemptedSnapshot, confLogIndex, durableConfLogIndex,
                  confAcked, recognizedLeader, messages>>

LeaderStateImpl_applyOldNewConf(l) ==
    /\ l \in Server
    /\ role[l] = Leader
    /\ stagingPeers[l] # {}
    /\ stagingPeers[l] \subseteq caughtUp[l]
    /\ LastLocalEntry(l) < MaxIndex
    \* applyOldNewConf appends old/new config and immediately sets it as
    \* in-memory current configuration.
    \* LeaderStateImpl.java:624-640.
    /\ oldConf' = [oldConf EXCEPT ![l] = currentConf[l]]
    /\ currentConf' = [currentConf EXCEPT ![l] = currentConf[l] \cup stagingPeers[l]]
    /\ confLogIndex' = [confLogIndex EXCEPT ![l] = LastLocalEntry(l) + 1]
    /\ volatileLog' = [volatileLog EXCEPT ![l] = @ \cup {LastLocalEntry(l) + 1}]
    /\ writeQueue' = [writeQueue EXCEPT ![l] = @ \cup {LastLocalEntry(l) + 1}]
    /\ logKind' = [logKind EXCEPT ![l][LastLocalEntry(l) + 1] = "config"]
    /\ logTerm' = [logTerm EXCEPT ![l][LastLocalEntry(l) + 1] = currentTerm[l]]
    /\ confAcked' = [confAcked EXCEPT ![l] = {l}]
    /\ UNCHANGED <<currentTerm, role, votedFor, leaderId, persistedTerm,
                  persistedVote, recovered, reformatted, voterRole,
                  diskLog, lastWrittenIndex, flushIndex, flushInFlightIndex,
                  flushInFlightCovered, flushFailure, commitIndex,
                  metadataCommitIndex, stateMachineDataFlushed,
                  matchIndex, nextIndex, votesGranted, candidateCommitKnown,
                  voteReplyLastEntryKind, leaderStateGeneration, leaseEnabled,
                  leaseFresh, replyTimestampObserved, replyResult,
                  leaseReadServed, readIndexListeners, ackedCommitIndex,
                  snapshotVars, durableConf, stagingPeers, caughtUp,
                  attemptedSnapshot, durableConfLogIndex,
                  recognizedLeader, messages, workerQueue>>

LeaderStateImpl_configAck(l, p) ==
    /\ l \in Server
    /\ role[l] = Leader
    /\ p \in currentConf[l] \cup oldConf[l]
    /\ confLogIndex[l] # -1
    \* Follower match index contributes to old/new majority calculations.
    \* LeaderStateImpl.java:946-983, RaftConfigurationImpl.java:264-282.
    /\ confAcked' = [confAcked EXCEPT ![l] = @ \cup {p}]
    /\ matchIndex' = [matchIndex EXCEPT ![l][p] = Max2(@, confLogIndex[l])]
    /\ UNCHANGED <<serverVars, logVars, nextIndex, votesGranted,
                  candidateCommitKnown, voteReplyLastEntryKind,
                  leaderStateGeneration, leaseEnabled, leaseFresh,
                  replyTimestampObserved, replyResult, leaseReadServed,
                  readIndexListeners, ackedCommitIndex, snapshotVars,
                  currentConf, oldConf, durableConf, stagingPeers, caughtUp,
                  attemptedSnapshot, confLogIndex, durableConfLogIndex,
                  recognizedLeader, messages>>

LeaderStateImpl_commitOldNewConf(l) ==
    /\ l \in Server
    /\ role[l] = Leader
    /\ confLogIndex[l] \in Index
    /\ JointMajority(l, confAcked[l])
    /\ confLogIndex[l] <= flushIndex[l]
    \* Transitional config commit requires old and new majorities, then
    \* replicateNewConf eventually persists the stable configuration.
    \* LeaderStateImpl.java:1034-1074, RaftConfigurationImpl.java:264-282.
    /\ durableConf' = [durableConf EXCEPT ![l] = currentConf[l]]
    /\ durableConfLogIndex' = [durableConfLogIndex EXCEPT ![l] = confLogIndex[l]]
    /\ commitIndex' = [commitIndex EXCEPT ![l] = Max2(@, confLogIndex[l])]
    /\ oldConf' = [oldConf EXCEPT ![l] = {}]
    /\ stagingPeers' = [stagingPeers EXCEPT ![l] = {}]
    /\ UNCHANGED <<currentTerm, role, votedFor, leaderId, persistedTerm,
                  persistedVote, recovered, reformatted, voterRole,
                  volatileLog, diskLog, writeQueue, lastWrittenIndex,
                  flushIndex, flushInFlightIndex, flushInFlightCovered,
                  flushFailure, metadataCommitIndex, stateMachineDataFlushed,
                  logTerm, logKind, leaderVars, snapshotVars, currentConf,
                  caughtUp, attemptedSnapshot, confLogIndex, confAcked,
                  recognizedLeader, messages>>

ServerState_updateConfiguration_BeforeAppendDurable(f, p) ==
    /\ f \in Server
    /\ p \in Server
    /\ LastLocalEntry(f) < MaxIndex
    \* Follower AppendEntries updates in-memory configuration before log append
    \* futures complete, after the AppendEntries leader has been recognized,
    \* recorded, and snapshot-in-progress inconsistency has been rejected.
    \* RaftServerImpl.java:1664-1706, ServerState.java:397-410.
    /\ role[f] = Follower
    /\ leaderId[f] # "None"
    /\ recognizedLeader[f] = leaderId[f]
    /\ snapshotInProgressIndex[f] = -1
    /\ currentConf' = [currentConf EXCEPT ![f] = @ \cup {p}]
    /\ confLogIndex' = [confLogIndex EXCEPT ![f] = Max2(@, LastLocalEntry(f) + 1)]
    /\ voterRole' = [voterRole EXCEPT ![f] =
        IF f \in (currentConf[f] \cup {p}) THEN Follower ELSE Listener]
    /\ UNCHANGED <<currentTerm, role, votedFor, leaderId, persistedTerm,
                  persistedVote, recovered, reformatted, volatileLog, diskLog,
                  writeQueue, lastWrittenIndex, flushIndex, flushInFlightIndex,
                  flushInFlightCovered, flushFailure, commitIndex,
                  metadataCommitIndex, stateMachineDataFlushed, logTerm,
                  logKind, leaderVars, snapshotVars, oldConf, durableConf,
                  stagingPeers, caughtUp, attemptedSnapshot,
                  durableConfLogIndex, confAcked, recognizedLeader, messages>>

LeaderStateImpl_commitConfigWithoutOldMajorityFault(l) ==
    /\ l \in Server
    /\ role[l] = Leader
    /\ oldConf[l] # {}
    /\ Majority(currentConf[l], confAcked[l])
    /\ ~Majority(oldConf[l], confAcked[l])
    /\ confLogIndex[l] \in Index
    \* Optional Scenario 5 fault: commit transitional config with only new/current
    \* majority. Disabled in default MC.cfg.
    \* LeaderStateImpl.java:946-983, RaftConfigurationImpl.java:264-282.
    /\ durableConf' = [durableConf EXCEPT ![l] = currentConf[l]]
    /\ durableConfLogIndex' = [durableConfLogIndex EXCEPT ![l] = confLogIndex[l]]
    /\ commitIndex' = [commitIndex EXCEPT ![l] = Max2(@, confLogIndex[l])]
    /\ UNCHANGED <<serverVars, volatileLog, diskLog, writeQueue,
                  lastWrittenIndex, flushIndex, flushInFlightIndex,
                  flushInFlightCovered, flushFailure, metadataCommitIndex,
                  stateMachineDataFlushed, logTerm, logKind, leaderVars,
                  snapshotVars, currentConf, oldConf, stagingPeers, caughtUp,
                  attemptedSnapshot, confLogIndex, confAcked,
                  recognizedLeader, messages>>

\* --------------------------------------------------------------------------
\* Message loss.
\* --------------------------------------------------------------------------

LoseMessage(m) ==
    /\ m \in messages
    /\ messages' = messages \ {m}
    /\ UNCHANGED <<serverVars, logVars, leaderVars, snapshotVars, configVars>>

Next ==
    \/ \E s \in Server : ServerState_initElection_ELECTION(s)
    \/ \E c \in Server, v \in Server : LeaderElection_submitRequestVote(c, v)
    \/ \E v \in Server, m \in messages : RaftServerImpl_requestVote_Grant(v, m)
    \/ \E v \in Server, m \in messages : RaftServerImpl_requestVote_Reject(v, m)
    \/ \E c \in Server : LeaderElection_waitForResults(c)
    \/ \E s \in Server, kind \in VoteKinds : ServerProtoUtils_setVoteReplyLastEntryKind(s, kind)
    \/ \E s \in Server, idx \in Index, kind \in {"normal", "config"}, p \in Server :
        RaftLogBase_appendEntry_CacheAndQueue(s, idx, kind, p)
    \/ \E s \in Server, idx \in Index : SegmentedRaftLogWorker_WriteLog_execute(s, idx)
    \/ \E s \in Server : SegmentedRaftLogWorker_flushIfNecessary_Start(s)
    \/ \E s \in Server : SegmentedRaftLogWorker_asyncFlushOutStream_Fail(s)
    \/ \E s \in Server : SegmentedRaftLogWorker_asyncFlushOutStream_Complete(s)
    \/ \E s \in Server : SegmentedRaftLogWorker_asyncFlushOutStream_CompleteLateOrFailed(s)
    \/ \E s \in Server, idx \in Index : LeaderStateImpl_updateCommit(s, idx)
    \/ \E s \in Server : RaftLogBase_appendMetadata(s)
    \/ \E s \in Server : CrashAndRecover(s)
    \/ \E s \in Server : RaftStorageImpl_formatEmptyStorage(s)
    \/ \E l \in Server, f \in Server, idx \in IndexOrInvalid : LeaderStateImpl_sendAppendEntries(l, f, idx)
    \/ \E f \in Server, m \in messages : RaftServerImpl_appendEntriesAsync_RejectSnapshot(f, m)
    \/ \E f \in Server, m \in messages : RaftServerImpl_appendEntriesAsync_Success(f, m)
    \/ \E f \in Server, l \in Server, idx \in Index : SnapshotInstallationHandler_notifyStateMachineToInstallSnapshot(f, l, idx)
    \/ \E f \in Server, idx \in Index : SnapshotInstallationHandler_checkAndInstallSnapshot_AppendChunk(f, idx)
    \/ \E f \in Server : SnapshotInstallationHandler_checkAndInstallSnapshot_FinalChunkPublish(f)
    \/ \E f \in Server : SnapshotInstallationHandler_notifyStateMachine_Complete(f)
    \/ \E f \in Server, idx \in Index : RaftServerImpl_sendReadIndexAsync(f, idx)
    \/ \E l \in Server, idx \in Index : LeaderStateImpl_getReadIndex_LeaseFastPath(l, idx)
    \/ \E l \in Server : LeaderLease_enableForTarget(l)
    \/ \E l \in Server, f \in Server, result \in {"SUCCESS", "NOT_LEADER", "HIGHER_TERM", "INCONSISTENCY"} :
        LogAppenderDefault_receiveAppendEntriesReply_Timestamp(l, f, result)
    \/ \E l \in Server : LeaderLease_extend(l)
    \/ \E l \in Server : LogAppenderDefault_handleReply_NotLeaderOrHigherTerm(l)
    \/ \E l \in Server : LeaderStateImpl_stop(l)
    \/ \E l \in Server, p \in Server : LeaderStateImpl_startSetConfiguration(l, p)
    \/ \E l \in Server, p \in Server : LeaderStateImpl_markAttemptedSnapshot(l, p)
    \/ \E l \in Server, p \in Server : LeaderStateImpl_checkProgress_CaughtUp(l, p)
    \/ \E l \in Server : LeaderStateImpl_applyOldNewConf(l)
    \/ \E l \in Server, p \in Server : LeaderStateImpl_configAck(l, p)
    \/ \E l \in Server : LeaderStateImpl_commitOldNewConf(l)
    \/ \E f \in Server, p \in Server : ServerState_updateConfiguration_BeforeAppendDurable(f, p)
    \/ \E m \in messages : LoseMessage(m)

Spec == Init /\ [][Next]_vars

\* --------------------------------------------------------------------------
\* Invariants.
\* --------------------------------------------------------------------------

TypeOK ==
    /\ currentTerm \in [Server -> Term]
    /\ role \in [Server -> Roles]
    /\ votedFor \in [Server -> Server \cup {None}]
    /\ leaderId \in [Server -> Server \cup {None}]
    /\ persistedTerm \in [Server -> Term]
    /\ persistedVote \in [Server -> Server \cup {None}]
    /\ recovered \in [Server -> BOOLEAN]
    /\ reformatted \in [Server -> BOOLEAN]
    /\ voterRole \in [Server -> {Follower, Listener}]
    /\ volatileLog \in [Server -> SUBSET Index]
    /\ diskLog \in [Server -> SUBSET Index]
    /\ writeQueue \in [Server -> SUBSET Index]
    /\ lastWrittenIndex \in [Server -> IndexOrInvalid]
    /\ flushIndex \in [Server -> IndexOrInvalid]
    /\ flushInFlightIndex \in [Server -> IndexOrInvalid]
    /\ flushInFlightCovered \in [Server -> IndexOrInvalid]
    /\ flushFailure \in [Server -> BOOLEAN]
    /\ commitIndex \in [Server -> IndexOrInvalid]
    /\ metadataCommitIndex \in [Server -> IndexOrInvalid]
    /\ stateMachineDataFlushed \in [Server -> IndexOrInvalid]
    /\ logTerm \in [Server -> [Index -> Term]]
    /\ logKind \in [Server -> [Index -> EntryKinds]]
    /\ matchIndex \in [Server -> [Server -> IndexOrInvalid]]
    /\ nextIndex \in [Server -> [Server -> 0..(MaxIndex + 1)]]
    /\ votesGranted \in [Server -> SUBSET Server]
    /\ candidateCommitKnown \in [Server -> BOOLEAN]
    /\ voteReplyLastEntryKind \in [Server -> VoteKinds]
    /\ leaderStateGeneration \in [Server -> Nat]
    /\ leaseEnabled \in [Server -> BOOLEAN]
    /\ leaseFresh \in [Server -> BOOLEAN]
    /\ replyTimestampObserved \in [Server -> BOOLEAN]
    /\ replyResult \in [Server -> ReplyResults]
    /\ leaseReadServed \in [Server -> BOOLEAN]
    /\ readIndexListeners \in [Server -> SUBSET Index]
    /\ ackedCommitIndex \in [Server -> IndexOrInvalid]
    /\ snapshotIndex \in [Server -> IndexOrInvalid]
    /\ installedSnapshot \in [Server -> IndexOrInvalid]
    /\ snapshotInProgressIndex \in [Server -> IndexOrInvalid]
    /\ tempSnapshot \in [Server -> IndexOrInvalid]
    /\ snapshotPublished \in [Server -> BOOLEAN]
    /\ logStartIndex \in [Server -> 0..(MaxIndex + 1)]
    /\ pendingReadIndexes \in [Server -> SUBSET Index]
    /\ readResult \in [Server -> {"none", "pending", "success", "failed"}]
    /\ workerQueue \in [Server -> SUBSET Index]
    /\ appendReplyPending \in [Server -> {"none", "success", "inconsistency"}]
    /\ currentConf \in [Server -> SUBSET Server]
    /\ oldConf \in [Server -> SUBSET Server]
    /\ durableConf \in [Server -> SUBSET Server]
    /\ stagingPeers \in [Server -> SUBSET Server]
    /\ caughtUp \in [Server -> SUBSET Server]
    /\ attemptedSnapshot \in [Server -> SUBSET Server]
    /\ confLogIndex \in [Server -> IndexOrInvalid]
    /\ durableConfLogIndex \in [Server -> IndexOrInvalid]
    /\ confAcked \in [Server -> SUBSET Server]
    /\ recognizedLeader \in [Server -> Server \cup {None}]
    /\ messages \subseteq MessageSet

ElectionSafety ==
    \A t \in Term \ {0} :
        Cardinality({s \in Server : role[s] = Leader /\ currentTerm[s] = t}) <= 1

LeaderCompleteness ==
    \A l \in Server :
        role[l] = Leader =>
            \A s \in Server :
                metadataCommitIndex[s] <= Max2(snapshotIndex[l], LastLocalEntry(l))

LogMatching ==
    \A a \in Server, b \in Server, i \in Index :
        /\ i \in diskLog[a]
        /\ i \in diskLog[b]
        /\ logTerm[a][i] = logTerm[b][i]
        =>
        \A j \in Index :
            j <= i /\ j \in diskLog[a] /\ j \in diskLog[b] =>
                logTerm[a][j] = logTerm[b][j]

CommittedImpliesDurableFlush ==
    \A s \in Server :
        commitIndex[s] <= DurableBoundary(s)

RecoveredCommitCovered ==
    \A s \in Server :
        recovered[s] => metadataCommitIndex[s] <= DurableBoundary(s)

SnapshotInstallExclusion ==
    \A s \in Server :
        snapshotInProgressIndex[s] # -1 =>
            /\ appendReplyPending[s] # "success"
            /\ readResult[s] # "success"

ReadIndexRequiresCurrentLeader ==
    \A s \in Server :
        leaseReadServed[s] =>
            /\ role[s] = Leader
            /\ leaderId[s] = s
            /\ s \in currentConf[s]
            /\ leaderStateGeneration[s] > 0

NoOldLeaderLeaseRead ==
    \A s \in Server :
        ~( /\ leaseReadServed[s]
           /\ replyTimestampObserved[s]
           /\ replyResult[s] \in {"NOT_LEADER", "HIGHER_TERM"}
           /\ role[s] = Leader )

JointConfigMajorityOverlap ==
    \A s \in Server :
        oldConf[s] # {} /\ durableConfLogIndex[s] = confLogIndex[s] /\ confLogIndex[s] # -1 =>
            /\ Majority(currentConf[s], confAcked[s])
            /\ Majority(oldConf[s], confAcked[s])

DurableConfigMatchesRecoveredRole ==
    \A s \in Server :
        recovered[s] =>
            \* A recovered server can later accept a new config AppendEntries
            \* and update in-memory config/role before the entry is durable.
            \* Only states still aligned with durable recovery evidence are
            \* required to match that durable configuration.
            /\ ( /\ confLogIndex[s] = durableConfLogIndex[s]
                 /\ confLogIndex[s] \notin diskLog[s]
               => /\ currentConf[s] = durableConf[s]
                  /\ voterRole[s] = IF s \in durableConf[s] THEN Follower ELSE Listener )
            /\ ( confLogIndex[s] \in diskLog[s]
               => voterRole[s] = IF s \in currentConf[s] THEN Follower ELSE Listener )

SnapshotEventuallyClearsOrFails ==
    \A s \in Server : snapshotInProgressIndex[s] # -1 ~> snapshotInProgressIndex[s] = -1

ReadIndexEventuallyCompletesOrFails ==
    \A s \in Server : pendingReadIndexes[s] # {} ~> readResult[s] \in {"success", "failed"}

=============================================================================
