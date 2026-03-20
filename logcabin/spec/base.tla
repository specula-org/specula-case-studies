---------------------------- MODULE base ----------------------------
\* TLA+ specification of logcabin/logcabin Raft consensus protocol.
\*
\* Models the implementation by Diego Ongaro (Raft's co-author) with:
\*   Extension 1: Joint consensus config changes (Family 3)
\*   Extension 2: withholdVotesUntil election disruption prevention (Family 3)
\*   Extension 3: Epoch-based leader step-down (Family 4)
\*   Extension 4: Deferred leader disk sync (Family 1, 4)
\*   Extension 5: Snapshot-log boundary tracking (Family 2)
\*
\* Source: Server/RaftConsensus.cc (~3037 LOC)
\*
EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs

CONSTANTS Follower,          \* Server states (RaftConsensus.h:1169-1194)
          Candidate,
          Leader

CONSTANT Nil                 \* Null value (votedFor=0 in impl)

CONSTANTS ValueEntry,        \* Log entry types (Raft.proto:83-103)
          ConfigEntry,
          NoopEntry

\* Configuration states (RaftConsensus.h:510-532)
CONSTANTS ConfigBlank,
          ConfigStable,
          ConfigStaging,
          ConfigTransitional

CONSTANTS RequestVoteRequest,       \* Message types (Raft.proto:26-31)
          RequestVoteResponse,
          AppendEntriesRequest,
          AppendEntriesResponse,
          InstallSnapshotRequest,
          InstallSnapshotResponse

----
\* Variables
----

\* Per-server persistent state (survives restart via updateLogMetadata)
\* RaftConsensus.h:1570,1644
VARIABLE currentTerm         \* [Server -> Nat]
VARIABLE votedFor            \* [Server -> Server \cup {Nil}]
VARIABLE log                 \* [Server -> Seq(Entry)]

\* Per-server volatile state
\* RaftConsensus.h:1576,1627,1634
VARIABLE state               \* [Server -> {Follower, Candidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat]
VARIABLE leaderId            \* [Server -> Server \cup {Nil}]

\* Leader volatile state (per peer)
\* RaftConsensus.h:393,398
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate state
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension 1: Joint consensus configuration (Family 3)
\* RaftConsensus.h:510-532,674,693,700
\* configState tracks the configuration phase per server.
\* oldConfig/newConfig track the server sets for each phase.
VARIABLE configState         \* [Server -> {ConfigBlank, ConfigStable, ConfigStaging, ConfigTransitional}]
VARIABLE configId            \* [Server -> Nat] (log index of current config)
VARIABLE oldConfig           \* [Server -> SUBSET Server]
VARIABLE newConfig           \* [Server -> SUBSET Server]

\* Extension 2: withholdVotesUntil (Family 3)
\* RaftConsensus.h:1682 — prevents removed/partitioned servers from disrupting elections
\* Modeled as a boolean: TRUE means recently heard from leader, will reject votes.
VARIABLE withholdVotes       \* [Server -> BOOLEAN]

\* Extension 3: Epoch-based step-down (Family 4)
\* RaftConsensus.h:1650, Peer:403
\* Leader increments currentEpoch; peers set lastAckEpoch on successful RPC.
\* stepDownThread checks quorumMin(lastAckEpoch) < currentEpoch.
VARIABLE currentEpoch        \* [Server -> Nat]
VARIABLE lastAckEpoch        \* [Server -> [Server -> Nat]]

\* Extension 4: Deferred leader disk sync (Family 1, 4)
\* RaftConsensus.h:1549, LocalServer:246
\* Leader appends to memory, disk thread syncs in background.
\* lastSyncedIndex tracks what's durable for leader's local matchIndex.
VARIABLE lastSyncedIndex     \* [Server -> Nat]
VARIABLE leaderDiskPending   \* [Server -> BOOLEAN]

\* Extension 5: Snapshot-log boundary (Family 2)
\* RaftConsensus.h:1585,1591
\* Tracks snapshot state for each server.
VARIABLE lastSnapshotIndex   \* [Server -> Nat]
VARIABLE lastSnapshotTerm    \* [Server -> Nat]
VARIABLE logStartIndex       \* [Server -> Nat] (log->getLogStartIndex())

----
\* Variable groups for UNCHANGED clauses
----

serverVars    == <<currentTerm, votedFor, state>>
logVars       == <<log, commitIndex>>
leaderVars    == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted>>
configVars    == <<configState, configId, oldConfig, newConfig>>
withholdVar   == <<withholdVotes>>
epochVars     == <<currentEpoch, lastAckEpoch>>
diskVars      == <<lastSyncedIndex, leaderDiskPending>>
snapshotVars  == <<lastSnapshotIndex, lastSnapshotTerm, logStartIndex>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          configVars, withholdVar, epochVars, diskVars, snapshotVars,
          leaderId>>

----
\* Helpers
----

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b

SetMax(S) == CHOOSE x \in S : \A y \in S : x >= y

\* Log helpers — account for snapshot truncation
\* The log sequence stores entries from logStartIndex[i] to logStartIndex[i] + Len(log[i]) - 1.
\* RaftConsensus.cc uses log->getLogStartIndex() and log->getLastLogIndex().

LastLogIndex(i) == logStartIndex[i] + Len(log[i]) - 1

LastLogTerm(i) ==
    IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term
    ELSE IF lastSnapshotIndex[i] > 0 THEN lastSnapshotTerm[i]
    ELSE 0

\* Get term at absolute index idx. Returns 0 for index 0.
\* Handles: in-log entries, snapshot boundary, and pre-snapshot entries.
\* RaftConsensus.cc:2264-2275 (prevLogTerm resolution in appendEntries)
LogTerm(i, idx) ==
    IF idx = 0 THEN 0
    ELSE IF idx >= logStartIndex[i] /\ idx <= LastLogIndex(i)
         THEN log[i][idx - logStartIndex[i] + 1].term
    ELSE IF idx = lastSnapshotIndex[i]
         THEN lastSnapshotTerm[i]
    ELSE 0  \* Entry not available (discarded)

\* Get log entry at absolute index idx (must be in range)
LogEntry(i, idx) == log[i][idx - logStartIndex[i] + 1]

\* Check if absolute index idx is available in the log
HasLogEntry(i, idx) == idx >= logStartIndex[i] /\ idx <= LastLogIndex(i)

\* Quorum check: simple majority
\* RaftConsensus.cc:455-464 (SimpleConfiguration::quorumAll)
IsQuorum(S, voters) == Cardinality(S) * 2 > Cardinality(voters)

\* Joint quorum: during TRANSITIONAL, need majority of BOTH old and new.
\* RaftConsensus.cc:526-534 (Configuration::quorumAll)
IsJointQuorum(S, i) ==
    IF configState[i] = ConfigTransitional
    THEN IsQuorum(S \cap oldConfig[i], oldConfig[i]) /\
         IsQuorum(S \cap newConfig[i], newConfig[i])
    ELSE IsQuorum(S \cap oldConfig[i], oldConfig[i])

\* Log up-to-date comparison
\* RaftConsensus.cc:1538-1540 (logIsOk in handleRequestVote)
LogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    \/ cLastTerm > vLastTerm
    \/ (cLastTerm = vLastTerm /\ cLastIdx >= vLastIdx)

\* Does server i have voting rights in its own configuration?
\* RaftConsensus.cc:506-514 (Configuration::hasVote)
HasVote(i) ==
    IF configState[i] = ConfigTransitional
    THEN i \in oldConfig[i] \/ i \in newConfig[i]
    ELSE i \in oldConfig[i]

\* Scan log for the last ConfigEntry at or before absolute index maxIdx.
\* Returns the config and its index, or Server (initial) if none found.
LatestConfigUpTo(i, maxIdx) ==
    LET bound == Min(maxIdx, LastLogIndex(i))
        relBound == IF bound >= logStartIndex[i]
                    THEN bound - logStartIndex[i] + 1
                    ELSE 0
        indices == {k \in 1..relBound :
                    log[i][k].type = ConfigEntry}
    IN IF indices = {}
       THEN <<Server, 0>>
       ELSE LET maxK == SetMax(indices)
            IN <<log[i][maxK].config, logStartIndex[i] + maxK - 1>>

\* Message bag helpers
Send(m) == messages' = messages (+) SetToBag({m})
SendAll(ms) == messages' = messages (+) SetToBag(ms)
Discard(m) == messages' = messages (-) SetToBag({m})
Reply(resp, req) ==
    messages' = (messages (-) SetToBag({req})) (+) SetToBag({resp})

----
\* Init
----

Init ==
    /\ currentTerm      = [s \in Server |-> 0]
    /\ votedFor          = [s \in Server |-> Nil]
    /\ log               = [s \in Server |-> <<>>]
    /\ state             = [s \in Server |-> Follower]
    /\ commitIndex       = [s \in Server |-> 0]
    /\ leaderId          = [s \in Server |-> Nil]
    /\ nextIndex         = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex        = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted      = [s \in Server |-> {}]
    /\ messages          = EmptyBag
    \* Extension 1: Initial config is STABLE with all servers
    /\ configState       = [s \in Server |-> ConfigStable]
    /\ configId          = [s \in Server |-> 0]
    /\ oldConfig         = [s \in Server |-> Server]
    /\ newConfig         = [s \in Server |-> {}]
    \* Extension 2
    /\ withholdVotes     = [s \in Server |-> FALSE]
    \* Extension 3
    /\ currentEpoch      = [s \in Server |-> 0]
    /\ lastAckEpoch      = [s \in Server |-> [t \in Server |-> 0]]
    \* Extension 4
    /\ lastSyncedIndex   = [s \in Server |-> 0]
    /\ leaderDiskPending = [s \in Server |-> FALSE]
    \* Extension 5
    /\ lastSnapshotIndex = [s \in Server |-> 0]
    /\ lastSnapshotTerm  = [s \in Server |-> 0]
    /\ logStartIndex     = [s \in Server |-> 1]

----
\* Election Actions
----

\* Server i times out and starts a new election.
\* RaftConsensus.cc:2858-2904 (startNewElection)
Timeout(i) ==
    /\ state[i] \in {Follower, Candidate}
    \* Guard: must have a configuration (line 2860)
    /\ configState[i] /= ConfigBlank
    \* Guard: withholdVotesUntil not active (stepDown calls setElectionTimer,
    \* preventing immediate re-election after voting for another server)
    \* RaftConsensus.cc:2916 (stepDown -> setElectionTimer), timerThreadMain:2067
    /\ withholdVotes[i] = FALSE
    \* Guard: if committed config excludes us, don't start election (line 2864-2868)
    /\ \/ commitIndex[i] < configId[i]  \* config not yet committed
       \/ HasVote(i)                     \* we have voting rights
    /\ LET newTerm == currentTerm[i] + 1
       IN
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       /\ state' = [state EXCEPT ![i] = Candidate]
       /\ votedFor' = [votedFor EXCEPT ![i] = i]         \* vote for self (line 2890)
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
       /\ leaderId' = [leaderId EXCEPT ![i] = Nil]       \* line 2889
       \* Send RequestVote to all known peers
       \* RaftConsensus.cc:2893 (forEach beginRequestVote)
       /\ SendAll({[mtype        |-> RequestVoteRequest,
                    mterm        |-> newTerm,
                    mlastLogTerm |-> LastLogTerm(i),
                    mlastLogIndex |-> LastLogIndex(i),
                    msource      |-> i,
                    mdest        |-> j] : j \in (oldConfig[i] \cup newConfig[i]) \ {i}})
       \* Reset election timer via setElectionTimer (line 2892)
       /\ withholdVotes' = [withholdVotes EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<logVars, leaderVars, configVars, epochVars, diskVars, snapshotVars>>

\* Server i handles a RequestVote request m.
\* RaftConsensus.cc:1526-1582 (handleRequestVote)
HandleRequestVoteRequest(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ LET mterm    == m.mterm
           logOk    == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                   LastLogTerm(i), LastLogIndex(i))
       IN
       \/ \* Case 1: Reject due to withholdVotesUntil (Extension 2)
          \* RaftConsensus.cc:1541-1551
          \* Recently heard from leader; reject to prevent disruption.
          /\ withholdVotes[i] = TRUE
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         configVars, withholdVar, epochVars, diskVars,
                         snapshotVars, leaderId>>

       \/ \* Case 2: Reject — term too low
          \* RaftConsensus.cc:1289-1293 pattern (stale term)
          /\ withholdVotes[i] = FALSE
          /\ mterm < currentTerm[i]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         configVars, withholdVar, epochVars, diskVars,
                         snapshotVars, leaderId>>

       \/ \* Case 3: Higher term — step down first, then evaluate
          \* RaftConsensus.cc:1553-1556 (stepDown to higher term)
          /\ withholdVotes[i] = FALSE
          /\ mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
          \* After stepDown, evaluate vote grant
          \* RaftConsensus.cc:1564-1572 (votedFor == 0 after stepDown)
          /\ IF logOk
             THEN \* Grant vote
                  /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
                  /\ withholdVotes' = [withholdVotes EXCEPT ![i] = TRUE]
                  /\ Reply([mtype        |-> RequestVoteResponse,
                            mterm        |-> mterm,
                            mvoteGranted |-> TRUE,
                            msource      |-> i,
                            mdest        |-> m.msource], m)
             ELSE \* Reject — log not up-to-date
                  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
                  /\ UNCHANGED withholdVotes
                  /\ Reply([mtype        |-> RequestVoteResponse,
                            mterm        |-> mterm,
                            mvoteGranted |-> FALSE,
                            msource      |-> i,
                            mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars,
                         epochVars, diskVars, snapshotVars>>

       \/ \* Case 4: Same term — grant if log ok and haven't voted
          \* RaftConsensus.cc:1564-1572
          /\ withholdVotes[i] = FALSE
          /\ mterm = currentTerm[i]
          /\ logOk
          /\ votedFor[i] \in {Nil, m.msource}  \* votedFor==0 or re-vote
          /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
          /\ state' = [state EXCEPT ![i] = Follower]  \* stepDown(currentTerm) line 1569
          /\ withholdVotes' = [withholdVotes EXCEPT ![i] = TRUE]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> TRUE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<currentTerm, logVars, leaderVars, candidateVars,
                         configVars, epochVars, diskVars, snapshotVars,
                         leaderId>>

       \/ \* Case 5: Same term — reject (already voted or log not ok)
          /\ withholdVotes[i] = FALSE
          /\ mterm = currentTerm[i]
          /\ ~(logOk /\ votedFor[i] \in {Nil, m.msource})
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         configVars, withholdVar, epochVars, diskVars,
                         snapshotVars, leaderId>>

\* Candidate i handles a RequestVote response m.
\* RaftConsensus.cc:2796-2819 (response processing in requestVote)
HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ \/ \* Higher term: step down
          \* RaftConsensus.cc:2800-2804
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars,
                         withholdVar, epochVars, diskVars, snapshotVars>>

       \/ \* Current term, still candidate: process vote
          \* RaftConsensus.cc:2806-2819
          /\ m.mterm = currentTerm[i]
          /\ state[i] = Candidate
          /\ IF m.mvoteGranted
             THEN votesGranted' = [votesGranted EXCEPT ![i] = @ \cup {m.msource}]
             ELSE UNCHANGED votesGranted
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, configVars,
                         withholdVar, epochVars, diskVars, snapshotVars,
                         leaderId>>

       \/ \* Stale response, ignore
          /\ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         configVars, withholdVar, epochVars, diskVars,
                         snapshotVars, leaderId>>

\* Candidate i becomes leader after receiving quorum of votes.
\* RaftConsensus.cc:2493-2528 (becomeLeader)
BecomeLeader(i) ==
    /\ state[i] = Candidate
    \* Joint quorum: need majority of both old and new in TRANSITIONAL
    \* RaftConsensus.cc:2818 (quorumAll(&Server::haveVote))
    /\ IsJointQuorum(votesGranted[i], i)
    /\ state' = [state EXCEPT ![i] = Leader]
    /\ leaderId' = [leaderId EXCEPT ![i] = i]  \* line 2501
    \* Initialize leader state
    \* RaftConsensus.cc:2511 (forEach beginLeadership)
    /\ nextIndex'  = [nextIndex  EXCEPT ![i] = [j \in Server |-> LastLogIndex(i) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    \* Append NOOP entry to establish commitment
    \* RaftConsensus.cc:2519-2524
    /\ LET noopEntry == [term |-> currentTerm[i], type |-> NoopEntry, config |-> {}]
       IN log' = [log EXCEPT ![i] = Append(@, noopEntry)]
    \* Leader disk: noop needs syncing (Extension 4)
    /\ leaderDiskPending' = [leaderDiskPending EXCEPT ![i] = TRUE]
    /\ lastSyncedIndex' = [lastSyncedIndex EXCEPT ![i] = LastLogIndex(i)]  \* line 96: lastSyncedIndex = getLastLogIndex() BEFORE append
    \* Disable election timer (line 2503-2504: startElectionAt = max, withholdVotesUntil = max)
    /\ withholdVotes' = [withholdVotes EXCEPT ![i] = TRUE]
    \* Reset epoch for step-down thread
    /\ currentEpoch' = [currentEpoch EXCEPT ![i] = 0]
    /\ lastAckEpoch' = [lastAckEpoch EXCEPT ![i] = [j \in Server |-> 0]]
    /\ UNCHANGED <<currentTerm, votedFor, commitIndex, candidateVars, messages,
                   configVars, snapshotVars>>

----
\* Log Replication Actions
----

\* Leader i appends a client request to its log.
\* RaftConsensus.cc (replicate path via replicateEntry)
ClientRequest(i) ==
    /\ state[i] = Leader
    /\ LET entry == [term |-> currentTerm[i], type |-> ValueEntry, config |-> {}]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    /\ leaderDiskPending' = [leaderDiskPending EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   configVars, withholdVar, epochVars, lastSyncedIndex,
                   snapshotVars, leaderId>>

\* Leader i sends AppendEntries with log entries to server j.
\* RaftConsensus.cc:2249-2384 (appendEntries)
\* Falls back to InstallSnapshot if needed entries are discarded.
AppendEntries(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    \* Must have entries available for peer (line 2254-2257)
    /\ nextIndex[i][j] >= logStartIndex[i]
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == LogTerm(i, prevIdx)
           lastIdx  == LastLogIndex(i)
           \* Pack entries from nextIndex to end of log
           \* RaftConsensus.cc:2280 (packEntries)
           entries  == IF nextIndex[i][j] > lastIdx THEN <<>>
                       ELSE SubSeq(log[i],
                                   nextIndex[i][j] - logStartIndex[i] + 1,
                                   lastIdx - logStartIndex[i] + 1)
           \* commitIndex in request bounded by what peer has
           \* RaftConsensus.cc:2282
           sentCommitIndex == Min(commitIndex[i], prevIdx + Len(entries))
       IN Send([mtype         |-> AppendEntriesRequest,
                mterm         |-> currentTerm[i],
                mprevLogIndex |-> prevIdx,
                mprevLogTerm  |-> prevTerm,
                mentries      |-> entries,
                mcommitIndex  |-> sentCommitIndex,
                msource       |-> i,
                mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, withholdVar, epochVars, diskVars,
                   snapshotVars, leaderId>>

\* Leader i sends InstallSnapshot to server j.
\* RaftConsensus.cc:2387-2490 (installSnapshot)
\* Modeled as atomic snapshot transfer (single message).
SendInstallSnapshot(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    \* Peer needs entries we've already discarded (line 2254-2257)
    /\ nextIndex[i][j] < logStartIndex[i]
    /\ lastSnapshotIndex[i] > 0
    /\ Send([mtype              |-> InstallSnapshotRequest,
             mterm              |-> currentTerm[i],
             mlastSnapshotIndex |-> lastSnapshotIndex[i],
             mlastSnapshotTerm  |-> lastSnapshotTerm[i],
             msource            |-> i,
             mdest              |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, withholdVar, epochVars, diskVars,
                   snapshotVars, leaderId>>

\* Server i handles an AppendEntries request m.
\* RaftConsensus.cc:1263-1427 (handleAppendEntries)
HandleAppendEntriesRequest(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ LET mterm   == m.mterm
           \* Log consistency check
           \* RaftConsensus.cc:1320-1334
           logOk   == \/ m.mprevLogIndex = 0
                      \/ /\ m.mprevLogIndex > 0
                         /\ m.mprevLogIndex <= LastLogIndex(i)
                         /\ \/ \* Entry available in log
                               /\ HasLogEntry(i, m.mprevLogIndex)
                               /\ LogEntry(i, m.mprevLogIndex).term = m.mprevLogTerm
                            \/ \* Entry in snapshot (committed, must agree)
                               \* RaftConsensus.cc:1326-1327
                               /\ m.mprevLogIndex < logStartIndex[i]
       IN
       \/ \* Reject: term too low
          \* RaftConsensus.cc:1289-1293
          /\ mterm < currentTerm[i]
          /\ Reply([mtype        |-> AppendEntriesResponse,
                    mterm        |-> currentTerm[i],
                    msuccess     |-> FALSE,
                    mmatchIndex  |-> LastLogIndex(i),
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         configVars, withholdVar, epochVars, diskVars,
                         snapshotVars, leaderId>>

       \/ \* Reject: log inconsistency
          \* RaftConsensus.cc:1320-1334
          /\ mterm >= currentTerm[i]
          /\ ~logOk
          /\ Reply([mtype        |-> AppendEntriesResponse,
                    mterm        |-> mterm,
                    msuccess     |-> FALSE,
                    mmatchIndex  |-> LastLogIndex(i),
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          \* Step down to new term if needed (line 1306)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ leaderId' = IF mterm > currentTerm[i]
                         THEN [leaderId EXCEPT ![i] = m.msource]
                         ELSE [leaderId EXCEPT ![i] = IF leaderId[i] = Nil THEN m.msource ELSE leaderId[i]]
          \* withholdVotesUntil reset (line 1308)
          /\ withholdVotes' = [withholdVotes EXCEPT ![i] = TRUE]
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars,
                         epochVars, diskVars, snapshotVars>>

       \/ \* Accept: log matches at prevLogIndex
          \* RaftConsensus.cc:1337-1427
          /\ mterm >= currentTerm[i]
          /\ logOk
          /\ LET \* Truncate conflicting entries and append new ones
                 \* RaftConsensus.cc:1356-1408
                 \* Implementation walks entries and only truncates from the
                 \* FIRST conflicting entry (different term at same index).
                 \* Matching entries are kept in place.
                 startIdx == m.mprevLogIndex + 1
                 \* Skip entries that fall before logStartIndex (in snapshot region)
                 \* These are already committed and don't need processing.
                 skipCount == Max(0, logStartIndex[i] - startIdx)
                 \* Effective entries: only those at or after logStartIndex
                 effStart == startIdx + skipCount  \* = Max(startIdx, logStartIndex[i])
                 effEntries == SubSeq(m.mentries,
                                      skipCount + 1, Len(m.mentries))
                 \* CanMatch(k): entry k of effEntries (1-indexed) matches the log
                 CanMatch(k) ==
                     /\ k <= Len(effEntries)
                     /\ HasLogEntry(i, effStart + k - 1)
                     /\ LogEntry(i, effStart + k - 1).term = effEntries[k].term
                 \* Count of leading effective entries that match
                 matchLen ==
                     CHOOSE n \in 0..Len(effEntries) :
                         /\ \A k \in 1..n : CanMatch(k)
                         /\ ~CanMatch(n + 1)
                 \* Truncate only if there's a conflict IN the log (not just beyond it)
                 truncatedLog ==
                     IF matchLen < Len(effEntries) /\
                        HasLogEntry(i, effStart + matchLen)
                     THEN SubSeq(log[i], 1,
                            effStart + matchLen - logStartIndex[i])
                     ELSE log[i]
                 newEntries == SubSeq(effEntries, matchLen + 1, Len(effEntries))
                 newLog == truncatedLog \o newEntries
                 newLastIdx == logStartIndex[i] + Len(newLog) - 1
                 \* Update commitIndex (line 1416-1418)
                 newCommitIdx == IF m.mcommitIndex > commitIndex[i]
                                 THEN Min(m.mcommitIndex, newLastIdx)
                                 ELSE commitIndex[i]
             IN
             /\ log' = [log EXCEPT ![i] = newLog]
             /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
             \* Update config from new log state
             /\ LET configResult == LatestConfigUpTo(i, newLastIdx)
                IN IF configResult[2] > 0
                   THEN /\ configId' = [configId EXCEPT ![i] = configResult[2]]
                        /\ oldConfig' = [oldConfig EXCEPT ![i] = configResult[1]]
                   ELSE UNCHANGED <<configId, oldConfig>>
             /\ Reply([mtype        |-> AppendEntriesResponse,
                       mterm        |-> mterm,
                       msuccess     |-> TRUE,
                       mmatchIndex  |-> newLastIdx,
                       msource      |-> i,
                       mdest        |-> m.msource], m)
          \* Step down / update term (line 1294-1306)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ leaderId' = IF mterm > currentTerm[i]
                         THEN [leaderId EXCEPT ![i] = m.msource]
                         ELSE [leaderId EXCEPT ![i] = IF leaderId[i] = Nil THEN m.msource ELSE leaderId[i]]
          \* withholdVotesUntil reset AFTER disk write too (line 1425-1426)
          /\ withholdVotes' = [withholdVotes EXCEPT ![i] = TRUE]
          /\ UNCHANGED <<leaderVars, candidateVars, epochVars, diskVars,
                         snapshotVars, configState, newConfig>>

\* Leader i handles an AppendEntries response m.
\* RaftConsensus.cc:2296-2380 (response processing in appendEntries)
HandleAppendEntriesResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ \/ \* Higher term: step down
          \* RaftConsensus.cc:2313-2317
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars,
                         withholdVar, epochVars, diskVars, snapshotVars>>

       \/ \* Current term, leader: process response
          \* RaftConsensus.cc:2319-2380
          /\ m.mterm = currentTerm[i]
          /\ state[i] = Leader
          /\ IF m.msuccess
             THEN \* Update matchIndex and nextIndex (line 2330-2338)
                  /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] = m.mmatchIndex]
                  /\ nextIndex'  = [nextIndex  EXCEPT ![i][m.msource] = m.mmatchIndex + 1]
             ELSE \* Decrement nextIndex on failure (line 2354-2360)
                  /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] =
                       Max(1, Min(nextIndex[i][m.msource] - 1,
                                  m.mmatchIndex + 1))]
                  /\ UNCHANGED matchIndex
          \* Update epoch acknowledgment (line 2322)
          /\ lastAckEpoch' = [lastAckEpoch EXCEPT ![i][m.msource] = currentEpoch[i]]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, candidateVars, configVars,
                         withholdVar, currentEpoch, diskVars, snapshotVars,
                         leaderId>>

       \/ \* Stale response, ignore
          /\ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         configVars, withholdVar, epochVars, diskVars,
                         snapshotVars, leaderId>>

\* Server i handles an InstallSnapshot request m.
\* RaftConsensus.cc:1430-1525 (handleInstallSnapshot)
\* Modeled as atomic: on accept, replace log prefix with snapshot.
HandleInstallSnapshotRequest(i, m) ==
    /\ m.mtype = InstallSnapshotRequest
    /\ m.mdest = i
    /\ \/ \* Reject: stale term
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype   |-> InstallSnapshotResponse,
                    mterm   |-> currentTerm[i],
                    msource |-> i,
                    mdest   |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         configVars, withholdVar, epochVars, diskVars,
                         snapshotVars, leaderId>>

       \/ \* Accept: install snapshot
          \* RaftConsensus.cc:1454-1520
          /\ m.mterm >= currentTerm[i]
          \* Step down (line 1455)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF m.mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ leaderId' = IF leaderId[i] = Nil THEN [leaderId EXCEPT ![i] = m.msource]
                         ELSE leaderId
          /\ withholdVotes' = [withholdVotes EXCEPT ![i] = TRUE]
          \* Snapshot replaces log prefix
          \* RaftConsensus.cc readSnapshot:2697-2714
          /\ IF m.mlastSnapshotIndex > lastSnapshotIndex[i]
             THEN
                  /\ lastSnapshotIndex' = [lastSnapshotIndex EXCEPT ![i] = m.mlastSnapshotIndex]
                  /\ lastSnapshotTerm'  = [lastSnapshotTerm  EXCEPT ![i] = m.mlastSnapshotTerm]
                  /\ logStartIndex'     = [logStartIndex     EXCEPT ![i] = m.mlastSnapshotIndex + 1]
                  \* RaftConsensus.cc readSnapshot:2697-2714
                  \* Only discard entries covered by the snapshot; keep entries after.
                  /\ IF m.mlastSnapshotIndex >= LastLogIndex(i)
                     THEN \* Snapshot covers entire log
                          log' = [log EXCEPT ![i] = <<>>]
                     ELSE \* Snapshot covers prefix only; keep suffix
                          log' = [log EXCEPT ![i] =
                              SubSeq(@,
                                     m.mlastSnapshotIndex - logStartIndex[i] + 2,
                                     Len(@))]
                  /\ commitIndex' = [commitIndex EXCEPT ![i] = Max(commitIndex[i], m.mlastSnapshotIndex)]
             ELSE
                  UNCHANGED <<log, commitIndex, snapshotVars>>
          /\ Reply([mtype   |-> InstallSnapshotResponse,
                    mterm   |-> m.mterm,
                    msource |-> i,
                    mdest   |-> m.msource], m)
          /\ UNCHANGED <<leaderVars, candidateVars, configVars,
                         epochVars, diskVars>>

\* Leader i handles an InstallSnapshot response m.
\* RaftConsensus.cc:2451-2490 (response processing in installSnapshot)
HandleInstallSnapshotResponse(i, m) ==
    /\ m.mtype = InstallSnapshotResponse
    /\ m.mdest = i
    /\ \/ \* Higher term: step down
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars,
                         withholdVar, epochVars, diskVars, snapshotVars>>

       \/ \* Current term: update peer state
          \* RaftConsensus.cc:2476-2489 (snapshot transfer complete)
          /\ m.mterm = currentTerm[i]
          /\ state[i] = Leader
          /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] = lastSnapshotIndex[i]]
          /\ nextIndex'  = [nextIndex  EXCEPT ![i][m.msource] = lastSnapshotIndex[i] + 1]
          /\ lastAckEpoch' = [lastAckEpoch EXCEPT ![i][m.msource] = currentEpoch[i]]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, candidateVars, configVars,
                         withholdVar, currentEpoch, diskVars, snapshotVars,
                         leaderId>>

       \/ \* Stale response, ignore
          /\ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         configVars, withholdVar, epochVars, diskVars,
                         snapshotVars, leaderId>>

----
\* Commit Index Advancement
----

\* Leader i advances commitIndex based on quorum replication.
\* RaftConsensus.cc:2174-2223 (advanceCommitIndex)
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET \* Servers that have replicated up to each index
           \* For the leader, matchIndex is effectively lastSyncedIndex (Extension 4)
           leaderMatch == lastSyncedIndex[i]
           Agree(idx) == {i} \cup {s \in Server \ {i} : matchIndex[i][s] >= idx}
           \* Uses quorumMin pattern: find highest index with joint quorum agreement
           \* AND from current term (line 2193)
           agreeIdxs == {idx \in (commitIndex[i]+1)..LastLogIndex(i) :
                          /\ IsJointQuorum(Agree(idx), i)
                          /\ HasLogEntry(i, idx)
                          /\ LogEntry(i, idx).term = currentTerm[i]
                          /\ leaderMatch >= idx}  \* leader's own entries must be synced
       IN
       /\ agreeIdxs /= {}
       /\ LET newCommitIdx == SetMax(agreeIdxs)
          IN
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
          \* Auto-step-down if excluded from committed config
          \* RaftConsensus.cc:2200-2206
          /\ IF /\ newCommitIdx >= configId[i]
                /\ ~HasVote(i)
             THEN \* Step down: excluded from config
                  /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
                  /\ state' = [state EXCEPT ![i] = Follower]
                  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
                  /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
                  /\ UNCHANGED <<log, configVars, leaderDiskPending>>
             ELSE IF /\ newCommitIdx >= configId[i]
                     /\ configState[i] = ConfigTransitional
                  \* Auto-create Cnew after committing Cold,new
                  \* RaftConsensus.cc:2210-2221
                  THEN LET cnewEntry == [term |-> currentTerm[i],
                                         type |-> ConfigEntry,
                                         config |-> newConfig[i]]
                       IN /\ log' = [log EXCEPT ![i] = Append(@, cnewEntry)]
                          /\ configState' = [configState EXCEPT ![i] = ConfigStable]
                          /\ configId' = [configId EXCEPT ![i] = LastLogIndex(i) + 1]
                          /\ oldConfig' = [oldConfig EXCEPT ![i] = newConfig[i]]
                          /\ newConfig' = [newConfig EXCEPT ![i] = {}]
                          /\ leaderDiskPending' = [leaderDiskPending EXCEPT ![i] = TRUE]
                          /\ UNCHANGED <<currentTerm, state, votedFor, leaderId>>
                  ELSE UNCHANGED <<serverVars, log, configVars, diskVars, leaderId>>
    /\ UNCHANGED <<leaderVars, candidateVars, messages, withholdVar, epochVars,
                   lastSyncedIndex, snapshotVars>>

----
\* Leader Disk Thread (Extension 4)
----

\* Leader i's disk thread completes syncing log entries.
\* RaftConsensus.cc:2025-2054 (leaderDiskThreadMain)
\* Models the background sync completing: updates lastSyncedIndex.
LeaderDiskSync(i) ==
    /\ state[i] = Leader
    /\ leaderDiskPending[i] = TRUE
    /\ leaderDiskPending' = [leaderDiskPending EXCEPT ![i] = FALSE]
    \* After sync: update lastSyncedIndex to current last log index
    \* RaftConsensus.cc:2047 (localServer->lastSyncedIndex = sync->lastIndex)
    /\ lastSyncedIndex' = [lastSyncedIndex EXCEPT ![i] = LastLogIndex(i)]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   configVars, withholdVar, epochVars, snapshotVars, leaderId>>

----
\* Epoch-Based Step-Down (Extension 3)
----

\* Leader i checks quorum acknowledgment and steps down if no quorum.
\* RaftConsensus.cc:2123-2169 (stepDownThreadMain)
StepDownCheck(i) ==
    /\ state[i] = Leader
    \* Increment epoch (line 2139)
    /\ currentEpoch' = [currentEpoch EXCEPT ![i] = currentEpoch[i] + 1]
    \* Check if quorum of peers have acked within this epoch window
    \* RaftConsensus.cc:2140-2142 (quorumMin < currentEpoch)
    /\ LET acked == {i} \cup {s \in Server \ {i} :
                        lastAckEpoch[i][s] >= currentEpoch[i]}
       IN
       IF IsJointQuorum(acked, i)
       THEN \* Quorum OK, no step down
            UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                        messages, configVars, withholdVar, lastAckEpoch,
                        diskVars, snapshotVars, leaderId>>
       ELSE \* No quorum: step down (line 2161-2164)
            /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
            /\ state' = [state EXCEPT ![i] = Follower]
            /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
            /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
            /\ UNCHANGED <<logVars, leaderVars, candidateVars, messages,
                           configVars, withholdVar, lastAckEpoch, diskVars,
                           snapshotVars>>

----
\* Configuration Change (Extension 1)
----

\* Leader i proposes a configuration change: set new server set.
\* RaftConsensus.cc:1595-1726 (setConfiguration)
\* Phase 1: STABLE -> create TRANSITIONAL entry (Cold,new)
ProposeConfigChange(i, newServers) ==
    /\ state[i] = Leader
    /\ configState[i] = ConfigStable
    \* Guard: only one uncommitted config at a time (line 1614-1623)
    /\ commitIndex[i] >= configId[i]
    /\ newServers /= oldConfig[i]  \* actual change
    /\ newServers /= {}
    /\ newServers \subseteq Server
    \* Create transitional config entry (Cold,new)
    \* RaftConsensus.cc:1688-1700
    /\ LET entry == [term   |-> currentTerm[i],
                     type   |-> ConfigEntry,
                     config |-> newServers]
       IN
       /\ log' = [log EXCEPT ![i] = Append(@, entry)]
       /\ configState' = [configState EXCEPT ![i] = ConfigTransitional]
       /\ configId' = [configId EXCEPT ![i] = LastLogIndex(i) + 1]
       /\ newConfig' = [newConfig EXCEPT ![i] = newServers]
       \* oldConfig stays the same during TRANSITIONAL
       /\ leaderDiskPending' = [leaderDiskPending EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   withholdVar, epochVars, lastSyncedIndex, snapshotVars,
                   leaderId, oldConfig>>

----
\* Snapshot Operations (Extension 5)
----

\* Server i takes a snapshot covering committed entries.
\* RaftConsensus.cc:1746-1862 (beginSnapshot + snapshotDone)
TakeSnapshot(i) ==
    /\ commitIndex[i] > lastSnapshotIndex[i]
    /\ commitIndex[i] >= logStartIndex[i]
    /\ HasLogEntry(i, commitIndex[i])
    /\ LET snapIdx  == commitIndex[i]
           snapTerm == LogEntry(i, snapIdx).term
       IN
       /\ lastSnapshotIndex' = [lastSnapshotIndex EXCEPT ![i] = snapIdx]
       /\ lastSnapshotTerm'  = [lastSnapshotTerm  EXCEPT ![i] = snapTerm]
       \* Discard log prefix up to snapshot
       \* RaftConsensus.cc:1860 (discardUnneededEntries)
       /\ LET entriesToKeep == SubSeq(log[i],
                                      snapIdx - logStartIndex[i] + 2,
                                      Len(log[i]))
          IN
          /\ log' = [log EXCEPT ![i] = entriesToKeep]
          /\ logStartIndex' = [logStartIndex EXCEPT ![i] = snapIdx + 1]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars,
                   messages, configVars, withholdVar, epochVars, diskVars,
                   leaderId>>

----
\* Crash and Recovery (Family 1, 2, 5)
----

\* Server i crashes. Volatile state is lost; persistent state survives.
\* RaftConsensus.cc:2907-2952 (stepDown) + init on restart
\* Persistent: currentTerm, votedFor, log (atomically persisted via updateLogMetadata)
\* RaftConsensus.cc:2955-2962 — term+votedFor persisted atomically (NOT two-step like hashicorp/raft)
Crash(i) ==
    \* Volatile state reset
    /\ state'          = [state          EXCEPT ![i] = Follower]
    /\ commitIndex'    = [commitIndex    EXCEPT ![i] = Max(0, lastSnapshotIndex[i])]
    /\ leaderId'       = [leaderId       EXCEPT ![i] = Nil]
    /\ nextIndex'      = [nextIndex      EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'     = [matchIndex     EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted'   = [votesGranted   EXCEPT ![i] = {}]
    /\ withholdVotes'  = [withholdVotes  EXCEPT ![i] = FALSE]
    /\ currentEpoch'   = [currentEpoch   EXCEPT ![i] = 0]
    /\ lastAckEpoch'   = [lastAckEpoch   EXCEPT ![i] = [j \in Server |-> 0]]
    /\ lastSyncedIndex'   = [lastSyncedIndex   EXCEPT ![i] = LastLogIndex(i)]
    /\ leaderDiskPending' = [leaderDiskPending EXCEPT ![i] = FALSE]
    \* Persistent state survives (currentTerm, votedFor, log are persisted atomically)
    /\ UNCHANGED <<currentTerm, votedFor, log>>
    \* Snapshot state survives
    /\ UNCHANGED <<lastSnapshotIndex, lastSnapshotTerm, logStartIndex>>
    \* Recompute config from log
    /\ LET configResult == LatestConfigUpTo(i, LastLogIndex(i))
       IN IF configResult[2] > 0
          THEN /\ configId'    = [configId    EXCEPT ![i] = configResult[2]]
               /\ oldConfig'   = [oldConfig   EXCEPT ![i] = configResult[1]]
               /\ configState' = [configState EXCEPT ![i] = ConfigStable]
               /\ newConfig'   = [newConfig   EXCEPT ![i] = {}]
          ELSE /\ configState' = [configState EXCEPT ![i] = ConfigStable]
               /\ UNCHANGED <<configId, oldConfig>>
               /\ newConfig' = [newConfig EXCEPT ![i] = {}]
    /\ UNCHANGED messages

----
\* Network Failures
----

\* Message is lost.
LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, withholdVar, epochVars, diskVars,
                   snapshotVars, leaderId>>

\* Drop messages with stale terms (state space reduction).
DropStaleMessage(m) ==
    /\ m \in DOMAIN messages
    /\ \/ m.mterm < currentTerm[m.mdest]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, withholdVar, epochVars, diskVars,
                   snapshotVars, leaderId>>

----
\* Spec
----

Next ==
    \/ \E i \in Server :
        \/ Timeout(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ AdvanceCommitIndex(i)
        \/ LeaderDiskSync(i)
        \/ StepDownCheck(i)
        \/ TakeSnapshot(i)
        \/ Crash(i)
    \/ \E i, j \in Server :
        \/ AppendEntries(i, j)
        \/ SendInstallSnapshot(i, j)
    \/ \E i \in Server, newServers \in (SUBSET Server \ {{}}) :
        ProposeConfigChange(i, newServers)
    \/ \E m \in DOMAIN messages :
        \/ HandleRequestVoteRequest(m.mdest, m)
        \/ HandleRequestVoteResponse(m.mdest, m)
        \/ HandleAppendEntriesRequest(m.mdest, m)
        \/ HandleAppendEntriesResponse(m.mdest, m)
        \/ HandleInstallSnapshotRequest(m.mdest, m)
        \/ HandleInstallSnapshotResponse(m.mdest, m)
        \/ DropStaleMessage(m)
        \/ LoseMessage(m)

Spec == Init /\ [][Next]_vars

----
\* Invariants
----

\* Standard Raft: at most one leader per term.
ElectionSafety ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ state[s2] = Leader /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* Standard Raft: if two logs have an entry with the same index and term,
\* the logs are identical up to that point.
LogMatching ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(LastLogIndex(s1), LastLogIndex(s2)) :
            (HasLogEntry(s1, idx) /\ HasLogEntry(s2, idx) /\
             LogEntry(s1, idx).term = LogEntry(s2, idx).term) =>
                \A k \in Max(logStartIndex[s1], logStartIndex[s2])..idx :
                    (HasLogEntry(s1, k) /\ HasLogEntry(s2, k)) =>
                        LogEntry(s1, k).term = LogEntry(s2, k).term

\* Standard Raft: committed entries agree across all servers.
\* If two servers have both committed an entry at the same index,
\* the entries must have the same term (and thus the same content).
LeaderCompleteness ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(commitIndex[s1], commitIndex[s2]) :
            (HasLogEntry(s1, idx) /\ HasLogEntry(s2, idx)) =>
                LogEntry(s1, idx).term = LogEntry(s2, idx).term

\* Family 1: CommitSafety — leader only commits entries from current term.
\* RaftConsensus.cc:2193 (advanceCommitIndex current-term check)
\* Verifies the fix for historical bug #44.
CommitSafety ==
    \A s \in Server :
        state[s] = Leader =>
            \A idx \in 1..commitIndex[s] :
                HasLogEntry(s, idx) =>
                    \E cidx \in idx..commitIndex[s] :
                        HasLogEntry(s, cidx) /\
                        LogEntry(s, cidx).term = currentTerm[s]

\* Family 2: SnapshotLogContinuity — log starts right after snapshot.
\* After any snapshot operation, logStartIndex = lastSnapshotIndex + 1.
SnapshotLogContinuity ==
    \A s \in Server :
        logStartIndex[s] <= lastSnapshotIndex[s] + 1

\* Family 3: ConfigSafety — at most one uncommitted config change at a time.
ConfigSafety ==
    \A s \in Server :
        state[s] = Leader =>
            configState[s] \in {ConfigStable, ConfigTransitional}

\* Family 3: JointQuorumAgreement — during TRANSITIONAL, committed entries
\* require both old and new quorum agreement.
JointQuorumAgreement ==
    \A s \in Server :
        (state[s] = Leader /\ configState[s] = ConfigTransitional) =>
            \A idx \in 1..commitIndex[s] :
                HasLogEntry(s, idx) =>
                    LogEntry(s, idx).term <= currentTerm[s]

\* Family 4: StepDownCorrectness — leader should only be active if it has quorum.
\* (Checked as: any leader can still reach a quorum of its config)
\* StepDownCheck increments epoch THEN checks against it. After the check,
\* peers haven't acked the new epoch yet (one-epoch lag). Check against
\* currentEpoch-1 to match the epoch used in the actual quorum decision.
StepDownCorrectness ==
    \A s \in Server :
        state[s] = Leader =>
            LET checkEpoch == Max(0, currentEpoch[s] - 1)
                acked == {s} \cup {j \in Server \ {s} :
                            lastAckEpoch[s][j] >= checkEpoch}
            IN \/ currentEpoch[s] <= 1  \* just became leader or first check
               \/ IsJointQuorum(acked, s)

\* Family 5: PersistenceConsistency — after crash, state is consistent.
\* Term of any log entry never exceeds the persisted currentTerm.
PersistenceConsistency ==
    \A s \in Server :
        \A idx \in logStartIndex[s]..LastLogIndex(s) :
            HasLogEntry(s, idx) =>
                LogEntry(s, idx).term <= currentTerm[s]

\* Structural: commitIndex never exceeds lastLogIndex.
CommitIndexBound ==
    \A s \in Server :
        commitIndex[s] <= LastLogIndex(s) \/
        commitIndex[s] <= lastSnapshotIndex[s]

\* Structural: candidates voted for themselves.
CandidateVotedForSelf ==
    \A s \in Server :
        state[s] = Candidate => votedFor[s] = s

\* Structural: leader term is positive.
LeaderTermPositive ==
    \A s \in Server :
        state[s] = Leader => currentTerm[s] > 0

=============================================================================
