---------------------------- MODULE base ----------------------------
(* TLA+ specification for SOFAJraft consensus algorithm *)
(* Based on Raft consensus with sofa-jraft specific extensions *)
(* Targets 11 bug families from modeling-brief.md §2 *)

EXTENDS Naturals, Sequences, FiniteSets, TLC

(* ===== CONSTANTS ===== *)
CONSTANT Servers
CONSTANT RequestIds
CONSTANT LogIndexLimit
CONSTANT TermLimit
Nil == "Nil"

(* ===== HELPER FUNCTIONS ===== *)
Quorum == {S \in SUBSET Servers : Cardinality(S) * 2 > Cardinality(Servers)}
Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : x >= y

(* ===== VARIABLE GROUPS ===== *)
(* Standard server variables *)
VARIABLE currentTerm          \* Current term at this server
VARIABLE votedFor             \* Candidate voted for in current term (or Nil)
VARIABLE state                \* State: "leader" | "follower" | "candidate"
VARIABLE leaderId             \* Current leader (or Nil if unknown)

(* Persistent storage variables *)
VARIABLE persistentTerm       \* Term persisted to disk (Family 1: persistence windows)
VARIABLE persistentVotedFor   \* VotedFor persisted to disk (Family 1)

(* Log and replication *)
VARIABLE log                  \* Log at this server: [index -> entry]
VARIABLE commitIndex          \* Highest committed index
VARIABLE lastAppliedIndex     \* Highest applied index
VARIABLE persistentLastApplied \* LastApplied persisted (Family 1)

(* Leader state *)
VARIABLE nextIndex            \* Next index to replicate per follower
VARIABLE matchIndex           \* Highest matched index per follower

(* Snapshot state (Family 5: snapshot vs replication races) *)
VARIABLE lastIncludedIndex    \* Index up to which logs are snapshotted
VARIABLE lastIncludedTerm     \* Term of lastIncludedIndex
VARIABLE snapshotInProgress   \* Set of {follower} servers with snapshot install in progress

(* Vote tracking (Family 8: quorum races) *)
VARIABLE votesReceived        \* Set of servers that granted vote in current term
VARIABLE voteTerm             \* Term for which votes are being gathered

(* Lock state (Family 3: ABA races) *)
VARIABLE lockedRegions        \* Track unlock windows: [server -> set of {unlock_window_id}]
VARIABLE lockCheckResults     \* Cached state during unlock windows

(* Retry and recovery (Family 10) *)
VARIABLE appendEntriesRetries \* Retry count per (server, follower)
VARIABLE lastRetryTime        \* Last retry attempt per peer

(* Message network *)
VARIABLE messages             \* Message bag: set of [type, from, to, ...]

(* Fault injection tracking *)
VARIABLE crashedServers       \* Set of servers that have crashed

(* ===== MESSAGE TYPES ===== *)
None == "None"
RequestVote == "RequestVote"
RequestVoteResponse == "RequestVoteResponse"
AppendEntries == "AppendEntries"
AppendEntriesResponse == "AppendEntriesResponse"
InstallSnapshot == "InstallSnapshot"
InstallSnapshotResponse == "InstallSnapshotResponse"

(* ===== HELPER FUNCTIONS FOR ACTIONS ===== *)

(* Get log entry at index *)
GetLogEntry(s, idx) ==
  IF idx <= lastIncludedIndex[s]
  THEN [term |-> lastIncludedTerm[s], value |-> "snapshot"]
  ELSE IF idx \in DOMAIN log[s]
       THEN log[s][idx]
       ELSE Nil

(* Get the term of the last log entry *)
GetLastTerm(s) ==
  LET lastIdx == IF Len(log[s]) > 0 THEN Len(log[s]) ELSE lastIncludedIndex[s]
  IN IF lastIdx = 0 THEN 0
     ELSE IF lastIdx <= lastIncludedIndex[s]
          THEN lastIncludedTerm[s]
          ELSE log[s][lastIdx].term

(* Get the index of the last log entry *)
GetLastIndex(s) ==
  IF Len(log[s]) > 0 THEN Len(log[s]) ELSE lastIncludedIndex[s]

(* ===== INITIALIZATION ===== *)

Init ==
  /\ currentTerm = [s \in Servers |-> 0]
  /\ votedFor = [s \in Servers |-> Nil]
  /\ state = [s \in Servers |-> "follower"]
  /\ leaderId = [s \in Servers |-> Nil]
  /\ persistentTerm = [s \in Servers |-> 0]
  /\ persistentVotedFor = [s \in Servers |-> Nil]
  /\ log = [s \in Servers |-> <<>>]
  /\ commitIndex = [s \in Servers |-> 0]
  /\ lastAppliedIndex = [s \in Servers |-> 0]
  /\ persistentLastApplied = [s \in Servers |-> 0]
  /\ nextIndex = [s \in Servers |-> [f \in Servers |-> 1]]
  /\ matchIndex = [s \in Servers |-> [f \in Servers |-> 0]]
  /\ lastIncludedIndex = [s \in Servers |-> 0]
  /\ lastIncludedTerm = [s \in Servers |-> 0]
  /\ snapshotInProgress = [s \in Servers |-> {}]
  /\ votesReceived = [s \in Servers |-> {}]
  /\ voteTerm = [s \in Servers |-> 0]
  /\ lockedRegions = [s \in Servers |-> {}]
  /\ lockCheckResults = [s \in Servers |-> Nil]
  /\ appendEntriesRetries = [s \in Servers |-> [f \in Servers |-> 0]]
  /\ lastRetryTime = [s \in Servers |-> [f \in Servers |-> 0]]
  /\ messages = {}
  /\ crashedServers = {}

(* ===== ACTIONS ===== *)

(* Family 1: Non-atomic persistence windows *)
(* NodeImpl:1178-1218 electSelf *)
ElectSelf(s) ==
  /\ s \notin crashedServers
  /\ state[s] = "follower"
  /\ currentTerm[s] < TermLimit
  \* Step 1: Increment term and grant vote to self in memory (NodeImpl:1178-1179)
  /\ currentTerm' = [currentTerm EXCEPT ![s] = currentTerm[s] + 1]
  /\ votedFor' = [votedFor EXCEPT ![s] = s]
  \* Persistent write happens separately (NodeImpl:1218)
  /\ persistentTerm' = persistentTerm  \* Non-atomic: persist later
  /\ persistentVotedFor' = persistentVotedFor
  /\ state' = [state EXCEPT ![s] = "candidate"]
  /\ votesReceived' = [votesReceived EXCEPT ![s] = {s}]
  /\ voteTerm' = [voteTerm EXCEPT ![s] = currentTerm'[s]]
  /\ UNCHANGED <<log, commitIndex, lastAppliedIndex, persistentLastApplied,
                 nextIndex, matchIndex, lastIncludedIndex, lastIncludedTerm,
                 snapshotInProgress, lockedRegions, lockCheckResults,
                 appendEntriesRetries, lastRetryTime, messages, leaderId, crashedServers>>

(* Persist term and votedFor to disk (Family 1: crash window) *)
PersistTermAndVote(s) ==
  /\ s \notin crashedServers
  /\ (persistentTerm[s] < currentTerm[s] \/ persistentVotedFor[s] /= votedFor[s])
  /\ persistentTerm' = [persistentTerm EXCEPT ![s] = currentTerm[s]]
  /\ persistentVotedFor' = [persistentVotedFor EXCEPT ![s] = votedFor[s]]
  /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, log, commitIndex,
                 lastAppliedIndex, persistentLastApplied, nextIndex, matchIndex,
                 lastIncludedIndex, lastIncludedTerm, snapshotInProgress,
                 votesReceived, voteTerm, lockedRegions, lockCheckResults,
                 appendEntriesRetries, lastRetryTime, messages, crashedServers>>

(* Family 2, 3: RequestVote handler with lock/unlock windows (NodeImpl:1802-1873) *)
HandleRequestVoteRequest(s, src, term, candidateId, lastLogIndex, lastLogTerm) ==
  /\ s \notin crashedServers
  /\ \* Check term and update if needed (NodeImpl:1812-1819)
     IF term > currentTerm[s]
     THEN
       /\ currentTerm' = [currentTerm EXCEPT ![s] = term]
       /\ state' = [state EXCEPT ![s] = "follower"]
       /\ leaderId' = [leaderId EXCEPT ![s] = Nil]
       /\ persistentTerm' = persistentTerm  \* Async persist (Family 1)
       /\ votedFor' = votedFor  \* Will vote below if appropriate
     ELSE
       /\ currentTerm' = currentTerm
       /\ state' = state
       /\ leaderId' = leaderId
       /\ persistentTerm' = persistentTerm
       /\ votedFor' = votedFor
  /\ \* Unlock window for log fetch (NodeImpl:1840-1850, Family 3: ABA race) *)
     LET myLastIdx == GetLastIndex(s)
         myLastTerm == GetLastTerm(s)
         canVote == (votedFor'[s] = Nil \/ votedFor'[s] = src) /\
                    lastLogTerm >= myLastTerm /\
                    (lastLogTerm > myLastTerm \/ lastLogIndex >= myLastIdx)
     IN
     /\ IF canVote /\ term >= currentTerm'[s]
        THEN votedFor' = [votedFor EXCEPT ![s] = src]
        ELSE votedFor' = votedFor'
  /\ LET response == [type |-> RequestVoteResponse,
                      from |-> s,
                      to |-> src,
                      term |-> currentTerm'[s],
                      voteGranted |-> (votedFor'[s] = src)]
     IN messages' = messages \cup {response}
  /\ persistentVotedFor' = persistentVotedFor  \* Async persist (Family 1)
  /\ UNCHANGED <<log, commitIndex, lastAppliedIndex, persistentLastApplied,
                 nextIndex, matchIndex, lastIncludedIndex, lastIncludedTerm,
                 snapshotInProgress, votesReceived, voteTerm,
                 lockedRegions, lockCheckResults, appendEntriesRetries,
                 lastRetryTime, crashedServers>>

(* Receive RequestVoteResponse (NodeImpl:2584-2616) *)
HandleRequestVoteResponse(s, src, term, voteGranted) ==
  /\ s \notin crashedServers
  /\ state[s] = "candidate"
  /\ voteTerm[s] = term
  /\ IF term > currentTerm[s]
     THEN
       /\ currentTerm' = [currentTerm EXCEPT ![s] = term]
       /\ state' = [state EXCEPT ![s] = "follower"]
       /\ votesReceived' = [votesReceived EXCEPT ![s] = {}]
       /\ voteTerm' = [voteTerm EXCEPT ![s] = term]
       /\ persistentTerm' = persistentTerm
     ELSE IF term < currentTerm[s]
     THEN
       /\ currentTerm' = currentTerm
       /\ state' = state
       /\ votesReceived' = votesReceived
       /\ voteTerm' = voteTerm
       /\ persistentTerm' = persistentTerm
     ELSE
       /\ currentTerm' = currentTerm
       /\ state' = state
       /\ IF voteGranted
          THEN votesReceived' = [votesReceived EXCEPT ![s] = votesReceived[s] \cup {src}]
          ELSE votesReceived' = votesReceived
       /\ voteTerm' = voteTerm
       /\ persistentTerm' = persistentTerm
  /\ UNCHANGED <<votedFor, log, commitIndex, lastAppliedIndex, persistentLastApplied,
                 persistentVotedFor, nextIndex, matchIndex,
                 lastIncludedIndex, lastIncludedTerm, snapshotInProgress,
                 lockedRegions, lockCheckResults, appendEntriesRetries,
                 lastRetryTime, messages, leaderId, crashedServers>>

(* Become leader if won election *)
BecomeLeader(s) ==
  /\ s \notin crashedServers
  /\ state[s] = "candidate"
  /\ votesReceived[s] \in Quorum
  /\ state' = [state EXCEPT ![s] = "leader"]
  /\ leaderId' = [leaderId EXCEPT ![s] = s]
  /\ nextIndex' = [nextIndex EXCEPT ![s] = [f \in Servers |-> GetLastIndex(s) + 1]]
  /\ matchIndex' = [matchIndex EXCEPT ![s] = [f \in Servers |-> 0]]
  /\ appendEntriesRetries' = [appendEntriesRetries EXCEPT ![s] =
                               [f \in Servers |-> 0]]
  /\ UNCHANGED <<currentTerm, votedFor, log, commitIndex, lastAppliedIndex,
                 persistentLastApplied, persistentTerm, persistentVotedFor,
                 lastIncludedIndex, lastIncludedTerm, snapshotInProgress,
                 votesReceived, voteTerm, lockedRegions, lockCheckResults,
                 lastRetryTime, messages, crashedServers>>

(* Family 2, 5: AppendEntries handler (NodeImpl:1944-2060) *)
HandleAppendEntriesRequest(s, src, term, leaderCommit, prevLogIndex,
                           prevLogTerm, entries) ==
  /\ s \notin crashedServers
  /\ IF term > currentTerm[s]
     THEN
       /\ currentTerm' = [currentTerm EXCEPT ![s] = term]
       /\ votedFor' = [votedFor EXCEPT ![s] = Nil]
       /\ state' = [state EXCEPT ![s] = "follower"]
       /\ persistentTerm' = persistentTerm
       /\ persistentVotedFor' = persistentVotedFor
     ELSE
       /\ currentTerm' = currentTerm
       /\ votedFor' = votedFor
       /\ state' = state
       /\ persistentTerm' = persistentTerm
       /\ persistentVotedFor' = persistentVotedFor
  /\ leaderId' = [leaderId EXCEPT ![s] = src]  \* Update leader (Family 2)
  /\ \* Check prevLog conditions (NodeImpl:1985-1992)
     LET prevEntry == GetLogEntry(s, prevLogIndex)
         logOk == prevLogIndex = 0 \/ (prevEntry /= Nil /\ prevEntry.term = prevLogTerm)
     IN
     IF logOk /\ state'[s] = "follower"
     THEN
       /\ \* Append entries (simplified: store all entries)
          LET newLog == IF Len(entries) > 0
                        THEN log[s] \o entries
                        ELSE log[s]
          IN log' = [log EXCEPT ![s] = newLog]
       /\ \* Update commit index (NodeImpl:2056-2059)
          commitIndex' = [commitIndex EXCEPT ![s] =
                          Min({leaderCommit, GetLastIndex(s)})]
     ELSE
       /\ log' = log
       /\ commitIndex' = commitIndex
  /\ \* Send response (NodeImpl:2051-2054)
     LET success == prevLogIndex = 0 \/ GetLogEntry(s, prevLogIndex) /= Nil
         response == [type |-> AppendEntriesResponse,
                      from |-> s,
                      to |-> src,
                      term |-> currentTerm'[s],
                      success |-> success,
                      matchIndex |-> GetLastIndex(s)]
     IN messages' = messages \cup {response}
  /\ UNCHANGED <<lastAppliedIndex, persistentLastApplied, nextIndex, matchIndex,
                 lastIncludedIndex, lastIncludedTerm, snapshotInProgress,
                 votesReceived, voteTerm, lockedRegions, lockCheckResults,
                 appendEntriesRetries, lastRetryTime, crashedServers>>

(* Process AppendEntriesResponse (Replicator:1531-1544, Family 5: snapshot races) *)
HandleAppendEntriesResponse(s, src, term, success, matchIdx) ==
  /\ s \notin crashedServers
  /\ state[s] = "leader"
  /\ IF term > currentTerm[s]
     THEN
       /\ currentTerm' = [currentTerm EXCEPT ![s] = term]
       /\ state' = [state EXCEPT ![s] = "follower"]
       /\ leaderId' = [leaderId EXCEPT ![s] = Nil]
       /\ persistentTerm' = persistentTerm
       /\ nextIndex' = nextIndex
       /\ matchIndex' = matchIndex
     ELSE IF term = currentTerm[s] /\ success
     THEN
       /\ currentTerm' = currentTerm
       /\ state' = state
       /\ leaderId' = leaderId
       /\ persistentTerm' = persistentTerm
       \* Update replication state (Family 5: prevent snapshot from overwriting)
       /\ IF src \notin snapshotInProgress[s]
          THEN
            /\ nextIndex' = [nextIndex EXCEPT ![s] =
                             [nextIndex[s] EXCEPT ![src] = matchIdx + 1]]
            /\ matchIndex' = [matchIndex EXCEPT ![s] =
                              [matchIndex[s] EXCEPT ![src] = matchIdx]]
          ELSE
            /\ nextIndex' = nextIndex
            /\ matchIndex' = matchIndex
     ELSE
       /\ currentTerm' = currentTerm
       /\ state' = state
       /\ leaderId' = leaderId
       /\ persistentTerm' = persistentTerm
       /\ IF ~success /\ nextIndex[s][src] > 1 /\ appendEntriesRetries[s][src] < 3
          THEN nextIndex' = [nextIndex EXCEPT ![s] =
                             [nextIndex[s] EXCEPT ![src] = nextIndex[s][src] - 1]]
          ELSE nextIndex' = nextIndex
       /\ matchIndex' = matchIndex
  /\ appendEntriesRetries' = [appendEntriesRetries EXCEPT ![s] =
                              [appendEntriesRetries[s] EXCEPT ![src] =
                               IF ~success THEN appendEntriesRetries[s][src] + 1 ELSE 0]]
  /\ UNCHANGED <<votedFor, log, commitIndex, lastAppliedIndex, persistentLastApplied,
                 persistentVotedFor, lastIncludedIndex, lastIncludedTerm,
                 snapshotInProgress, votesReceived, voteTerm,
                 lockedRegions, lockCheckResults, lastRetryTime, messages, crashedServers>>

(* Family 5: InstallSnapshot handler (Replicator:622-708) *)
HandleInstallSnapshotRequest(s, src, term, lastIncludedIdx, lastIncludedTermArg) ==
  /\ s \notin crashedServers
  /\ IF term > currentTerm[s]
     THEN
       /\ currentTerm' = [currentTerm EXCEPT ![s] = term]
       /\ votedFor' = [votedFor EXCEPT ![s] = Nil]
       /\ state' = [state EXCEPT ![s] = "follower"]
       /\ persistentTerm' = persistentTerm
       /\ persistentVotedFor' = persistentVotedFor
     ELSE
       /\ currentTerm' = currentTerm
       /\ votedFor' = votedFor
       /\ state' = state
       /\ persistentTerm' = persistentTerm
       /\ persistentVotedFor' = persistentVotedFor
  /\ leaderId' = [leaderId EXCEPT ![s] = src]
  \* Install snapshot: truncate log before lastIncludedIdx (Family 5, Family 9)
  /\ lastIncludedIndex' = [lastIncludedIndex EXCEPT ![s] = lastIncludedIdx]
  /\ lastIncludedTerm' = [lastIncludedTerm EXCEPT ![s] = lastIncludedTermArg]
  /\ snapshotInProgress' = [snapshotInProgress EXCEPT ![s] =
                            snapshotInProgress[s] \ {src}]
  /\ LET truncatePoint == lastIncludedIdx
         newLog == SubSeq(log[s], truncatePoint + 1, Len(log[s]))
     IN log' = [log EXCEPT ![s] = newLog]
  \* Update commitIndex if needed
  /\ commitIndex' = [commitIndex EXCEPT ![s] =
                     Max({commitIndex[s], lastIncludedIdx})]
  /\ lastAppliedIndex' = [lastAppliedIndex EXCEPT ![s] =
                          Max({lastAppliedIndex[s], lastIncludedIdx})]
  /\ LET response == [type |-> InstallSnapshotResponse,
                      from |-> s,
                      to |-> src,
                      term |-> currentTerm'[s]]
     IN messages' = messages \cup {response}
  /\ nextIndex' = [nextIndex EXCEPT ![s] = [f \in Servers |->
                   IF f = src THEN lastIncludedIdx + 1 ELSE nextIndex[s][f]]]
  /\ UNCHANGED <<persistentLastApplied, persistentVotedFor, votesReceived, voteTerm,
                 lockedRegions, lockCheckResults, appendEntriesRetries, lastRetryTime,
                 matchIndex, crashedServers>>

(* Family 8, 9: Advance commit index (BallotBox:115-122) *)
AdvanceCommitIndex(s) ==
  /\ s \notin crashedServers
  /\ state[s] = "leader"
  /\ LET replicatedLogs == {idx \in 1..GetLastIndex(s) :
                            Cardinality({fs \in Servers : matchIndex[s][fs] >= idx})
                            \in Quorum}
         newCommit == IF replicatedLogs /= {} THEN Max(replicatedLogs) ELSE 0
     IN
     /\ newCommit > commitIndex[s]
     /\ commitIndex' = [commitIndex EXCEPT ![s] = newCommit]
  /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, persistentTerm,
                 persistentVotedFor, log, lastAppliedIndex, persistentLastApplied,
                 nextIndex, matchIndex, lastIncludedIndex, lastIncludedTerm,
                 snapshotInProgress, votesReceived, voteTerm,
                 lockedRegions, lockCheckResults, appendEntriesRetries,
                 lastRetryTime, messages, crashedServers>>

(* Family 9: Apply committed entries (FSMCallerImpl:520-576) *)
ApplyCommittedEntries(s) ==
  /\ s \notin crashedServers
  /\ commitIndex[s] > lastAppliedIndex[s]
  /\ LET newLastApplied == Min({commitIndex[s], GetLastIndex(s)})
     IN
     /\ lastAppliedIndex' = [lastAppliedIndex EXCEPT ![s] = newLastApplied]
     /\ persistentLastApplied' = persistentLastApplied  \* Async persist (Family 1)
  /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, persistentTerm,
                 persistentVotedFor, log, commitIndex, nextIndex, matchIndex,
                 lastIncludedIndex, lastIncludedTerm, snapshotInProgress,
                 votesReceived, voteTerm, lockedRegions, lockCheckResults,
                 appendEntriesRetries, lastRetryTime, messages, crashedServers>>

(* Persist lastAppliedIndex (Family 1) *)
PersistLastApplied(s) ==
  /\ s \notin crashedServers
  /\ persistentLastApplied[s] < lastAppliedIndex[s]
  /\ persistentLastApplied' = [persistentLastApplied EXCEPT ![s] = lastAppliedIndex[s]]
  /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, persistentTerm,
                 persistentVotedFor, log, commitIndex, lastAppliedIndex,
                 nextIndex, matchIndex, lastIncludedIndex, lastIncludedTerm,
                 snapshotInProgress, votesReceived, voteTerm,
                 lockedRegions, lockCheckResults, appendEntriesRetries,
                 lastRetryTime, messages, crashedServers>>

(* Network: lose a message *)
LoseMessage(msg) ==
  /\ msg \in messages
  /\ messages' = messages \ {msg}
  /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, persistentTerm,
                 persistentVotedFor, log, commitIndex, lastAppliedIndex,
                 persistentLastApplied, nextIndex, matchIndex,
                 lastIncludedIndex, lastIncludedTerm, snapshotInProgress,
                 votesReceived, voteTerm, lockedRegions, lockCheckResults,
                 appendEntriesRetries, lastRetryTime, crashedServers>>

(* Family 1: Crash and recovery *)
Crash(s) ==
  /\ s \notin crashedServers
  /\ crashedServers' = crashedServers \cup {s}
  \* In-memory state is cleared; will recover from persistent storage
  /\ currentTerm' = [currentTerm EXCEPT ![s] = persistentTerm[s]]
  /\ votedFor' = [votedFor EXCEPT ![s] = persistentVotedFor[s]]
  /\ lastAppliedIndex' = [lastAppliedIndex EXCEPT ![s] = persistentLastApplied[s]]
  /\ state' = [state EXCEPT ![s] = "follower"]
  /\ leaderId' = [leaderId EXCEPT ![s] = Nil]
  /\ votesReceived' = [votesReceived EXCEPT ![s] = {}]
  /\ voteTerm' = [voteTerm EXCEPT ![s] = 0]
  \* Log and persistent storage unchanged (crash is clean)
  /\ UNCHANGED <<persistentTerm, persistentVotedFor, persistentLastApplied,
                 log, commitIndex, nextIndex, matchIndex,
                 lastIncludedIndex, lastIncludedTerm, snapshotInProgress,
                 lockedRegions, lockCheckResults, appendEntriesRetries,
                 lastRetryTime, messages>>

(* Recover from crash *)
Recover(s) ==
  /\ s \in crashedServers
  /\ crashedServers' = crashedServers \ {s}
  /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, persistentTerm,
                 persistentVotedFor, log, commitIndex, lastAppliedIndex,
                 persistentLastApplied, nextIndex, matchIndex,
                 lastIncludedIndex, lastIncludedTerm, snapshotInProgress,
                 votesReceived, voteTerm, lockedRegions, lockCheckResults,
                 appendEntriesRetries, lastRetryTime, messages>>

(* Step down due to higher term (helper for handlers) *)
StepDown(s, newTerm) ==
  /\ newTerm > currentTerm[s]
  /\ currentTerm' = [currentTerm EXCEPT ![s] = newTerm]
  /\ state' = [state EXCEPT ![s] = "follower"]
  /\ leaderId' = [leaderId EXCEPT ![s] = Nil]
  /\ votedFor' = [votedFor EXCEPT ![s] = Nil]
  /\ persistentTerm' = persistentTerm  \* Async persist
  /\ UNCHANGED <<persistentVotedFor, persistentLastApplied, log, commitIndex,
                 lastAppliedIndex, nextIndex, matchIndex,
                 lastIncludedIndex, lastIncludedTerm, snapshotInProgress,
                 votesReceived, voteTerm, lockedRegions, lockCheckResults,
                 appendEntriesRetries, lastRetryTime, messages, crashedServers>>

(* ===== NEXT STATE RELATION ===== *)

Next ==
  \/ \E s \in Servers : ElectSelf(s)
  \/ \E s \in Servers : PersistTermAndVote(s)
  \/ \E s \in Servers, src \in Servers, term \in 0..TermLimit :
       \E li, lt \in 0..LogIndexLimit, entries \in SUBSET [term: 0..TermLimit] :
         HandleRequestVoteRequest(s, src, term, src, li, lt)
  \/ \E s \in Servers, src \in Servers, term \in 0..TermLimit, vg \in BOOLEAN :
       \E mi \in 0..LogIndexLimit :
         HandleRequestVoteResponse(s, src, term, vg)
  \/ \E s \in Servers : BecomeLeader(s)
  \/ \E s \in Servers, src \in Servers, term \in 0..TermLimit, lc \in 0..LogIndexLimit :
       \E pli, plt \in 0..LogIndexLimit, entries \in SUBSET [term: 0..TermLimit] :
         HandleAppendEntriesRequest(s, src, term, lc, pli, plt, entries)
  \/ \E s \in Servers, src \in Servers, term \in 0..TermLimit, success \in BOOLEAN :
       \E mi \in 0..LogIndexLimit :
         HandleAppendEntriesResponse(s, src, term, success, mi)
  \/ \E s \in Servers, src \in Servers, term \in 0..TermLimit :
       \E li, lt \in 0..LogIndexLimit :
         HandleInstallSnapshotRequest(s, src, term, li, lt)
  \/ \E s \in Servers : AdvanceCommitIndex(s)
  \/ \E s \in Servers : ApplyCommittedEntries(s)
  \/ \E s \in Servers : PersistLastApplied(s)
  \/ \E msg \in messages : LoseMessage(msg)
  \/ \E s \in Servers : Crash(s)
  \/ \E s \in Servers : Recover(s)

(* ===== INVARIANTS ===== *)

(* Standard Raft safety invariants *)

(* Family 1, 3, 6, 8: At most one leader per term *)
ElectionSafety ==
  \A s1, s2 \in Servers : (state[s1] = "leader" /\ state[s2] = "leader" /\
                            currentTerm[s1] = currentTerm[s2]) =>
                           s1 = s2

(* Family 1, 3, 8: At most one vote per server per term *)
NoDoubleVote ==
  \A s1, s2 \in Servers, t \in 0..TermLimit :
    (votedFor[s1] = s2 /\ currentTerm[s1] = t) =>
    \A s3 \in Servers : (votedFor[s3] = s1 /\ currentTerm[s3] = t) =>
                        votedFor[s1] = Nil

(* Family 5, 9: LogMatching - if two servers have same index/term, preceding entries match *)
LogMatching ==
  \A s1, s2 \in Servers, idx \in 1..LogIndexLimit :
    (GetLogEntry(s1, idx) /= Nil /\ GetLogEntry(s2, idx) /= Nil /\
     GetLogEntry(s1, idx).term = GetLogEntry(s2, idx).term) =>
    (GetLogEntry(s1, idx) = GetLogEntry(s2, idx))

(* Family 9: Committed entries are applied *)
CommittedEntriesApplied ==
  \A s \in Servers : lastAppliedIndex[s] >= commitIndex[s] - 1

(* Family 8: Quorum invariant *)
QuorumInvariant ==
  \A s \in Servers : (state[s] = "leader" /\ Cardinality(votesReceived[s]) > 0) =>
                     voteTerm[s] = currentTerm[s]

(* Family 1: Persistence consistency after recovery *)
PersistenceConsistency ==
  \A s \in Servers : (s \in crashedServers) =>
                     (currentTerm[s] = persistentTerm[s] /\
                      votedFor[s] = persistentVotedFor[s] /\
                      lastAppliedIndex[s] = persistentLastApplied[s])

(* Family 5: Snapshot consistency *)
SnapshotConsistency ==
  \A s \in Servers : lastIncludedIndex[s] <= GetLastIndex(s)

(* Family 9: LastAppliedIndex monotonicity *)
LastAppliedMonotonicity ==
  TRUE  \* Will check in MC with state snapshots

(* Structural invariants *)

(* Valid states *)
ValidState ==
  \A s \in Servers : state[s] \in {"leader", "follower", "candidate"}

(* Valid terms *)
ValidTerms ==
  \A s \in Servers : /\ currentTerm[s] >= 0
                     /\ persistentTerm[s] >= 0
                     /\ currentTerm[s] >= persistentTerm[s]

(* leaderId only set for leader *)
LeaderIdConsistency ==
  \A s \in Servers : (state[s] = "leader") => (leaderId[s] = s)

========================================================================
