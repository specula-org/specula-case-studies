---- MODULE base ----
\*****************************************************************************
\* MongoDB RaftMongoReplTimestamp — Extended Specification
\*
\* Extends the official MongoDB RaftMongoReplTimestamp spec with:
\*   - Oplog holes + allDurable tracking (Bug Family 1)
\*   - Asynchronous journal flusher with TOCTOU window (Bug Family 2)
\*   - Write concern tracking with stepdown loss (Bug Family 3)
\*   - Multi-step crash recovery (Bug Family 5)
\*
\* The official spec treats oplog writes as atomic, journal flush as
\* synchronous, and stepdown as instantaneous. Those simplifications hide
\* 18+ historical bugs. This spec models the gaps.
\*
\* Source: mongodb/mongo (replication_coordinator_impl.cpp, oplog.cpp,
\*         rollback_impl.cpp, replication_recovery.cpp, step_up_step_down.cpp)
\*****************************************************************************
EXTENDS Integers, FiniteSets, Sequences, TLC

\* The set of server IDs.
CONSTANT Server

\* Maximum oplog entries per client write (usually 1 for MC).
CONSTANT MaxClientWriteSize

\* A distinguished "nil" optime for initialization.
NilOpTime == [term |-> 0, index |-> 0]

----
\*****************************************************************************
\* Variables
\*****************************************************************************

\* --- Standard Raft variables (from existing spec) ---

\* Per-server term number.
VARIABLE currentTerm

\* Per-server state: "Follower", "Leader", or "Down" (crashed).
VARIABLE state

\* Per-server commit point learned from leader.
VARIABLE commitPoint

\* Per-server last durable optime (set by journal flusher, or persist action).
VARIABLE lastDurable

\* Per-server last applied optime.
VARIABLE lastApplied

\* Per-server committed snapshot: [last |-> OpTime, curr |-> OpTime].
\* replication_coordinator_impl.cpp:5647-5690 (_updateCommittedSnapshot)
VARIABLE committedSnapshot

\* Per-server oplog (sequence of [term |-> T] entries).
VARIABLE log

\* Set of globally committed entries [term |-> T, index |-> I].
VARIABLE committedEntries

\* --- Extension: Oplog Holes (Bug Family 1) ---
\* Per-server set of reserved-but-not-committed oplog slot indices.
\* oplog.cpp:588 (getNextOpTimes reserves slot)
\* An entry exists in the log at slot.index but the "hole" remains open
\* until the write transaction commits (CloseOplogHole).
VARIABLE oplogHoles

\* --- Extension: Prepared Transactions (Bug Family 1) ---
\* Per-server set of prepared transaction timestamps (oplog indices).
\* Prepared txns hold oplog holes open indefinitely.
VARIABLE preparedTxns

\* --- Extension: Async Journal Flusher (Bug Family 2) ---
\* Per-server snapshot captured by the journal flusher thread.
\* replication_coordinator_impl.cpp:1693-1708 (_setMyLastDurableOpTimeAndWallTime)
\* The flusher reads lastApplied at time T1, then later sets lastDurable.
VARIABLE journalFlusherSnapshot

\* Per-server lastWritten optime (distinct from lastDurable in modern MongoDB).
VARIABLE lastWritten

\* Global config: does write concern majority use durable or written?
\* replication_coordinator_impl.cpp:1702 (getWriteConcernMajorityShouldJournal)
VARIABLE useDurableForCommit

\* --- Extension: Write Concern Tracking (Bug Family 3) ---
\* Per-server set of pending write concern waiters [op |-> OpTime, wc |-> "majority"].
\* replication_coordinator_impl.cpp:2222-2292 (_doneWaitingForReplication)
VARIABLE writeConcernWaiters

\* Set of acknowledged write optimes (client told "success").
VARIABLE acknowledged

\* Set of rolled-back write optimes.
VARIABLE rolledBack

\* --- Extension: Multi-step Recovery (Bug Family 5) ---
\* Per-server recovery phase: "none", "truncate", "replay", "timestamps".
\* replication_recovery.cpp:472-548 (recoverFromOplog is multi-phase)
VARIABLE recoveryPhase

\* Per-server oplog truncate-after point.
\* rollback_impl.cpp:750 (setOplogTruncateAfterPoint)
VARIABLE oplogTruncateAfterPoint

\* --- Control variables (for bounding) ---
VARIABLE restartTimes
VARIABLE failoverTimes

\*****************************************************************************
\* Variable Groups
\*****************************************************************************
electionVars     == <<currentTerm, state>>
oplogTimeVars    == <<lastDurable, lastApplied, lastWritten, committedSnapshot, commitPoint>>
logVars          == <<log, committedEntries>>
holeVars         == <<oplogHoles, preparedTxns>>
flusherVars      == <<journalFlusherSnapshot, useDurableForCommit>>
wcVars           == <<writeConcernWaiters, acknowledged, rolledBack>>
recoveryVars     == <<recoveryPhase, oplogTruncateAfterPoint>>
controlVars      == <<restartTimes, failoverTimes>>

vars == <<electionVars, oplogTimeVars, logVars, holeVars,
          flusherVars, wcVars, recoveryVars, controlVars>>

----
\*****************************************************************************
\* Helpers
\*****************************************************************************

IsMajority(servers) == Cardinality(servers) * 2 > Cardinality(Server)

GetTerm(xlog, index) == IF index = 0 THEN 0 ELSE xlog[index].term
LogTerm(i, index)    == GetTerm(log[i], index)
LastTerm(xlog)       == GetTerm(xlog, Len(xlog))

Leaders  == {s \in Server : state[s] = "Leader"}
Alive    == {s \in Server : state[s] /= "Down"}

Range(f) == {f[x] : x \in DOMAIN f}
Max(s)   == CHOOSE x \in s : \A y \in s : x >= y
Min(s)   == CHOOSE x \in s : \A y \in s : x <= y

\* Timestamp comparison (OpTime ordering).
TimestampLTE(x, y) ==
    IF x.term < y.term THEN TRUE
    ELSE IF x.term > y.term THEN FALSE
    ELSE x.index <= y.index

TimestampLT(x, y) ==
    IF x.term < y.term THEN TRUE
    ELSE IF x.term > y.term THEN FALSE
    ELSE x.index < y.index

MinTimestamp(s) == CHOOSE x \in s : \A y \in s : TimestampLTE(x, y)
MaxTimestamp(s) == CHOOSE x \in s : \A y \in s : TimestampLTE(y, x)

GlobalCurrentTerm == Max(Range(currentTerm))

\* AllDurable: the highest timestamp such that no holes exist at or below it.
\* replication_coordinator_impl.cpp:5074-5078
\* On a primary: min timestamp before the smallest hole.
\* On a secondary or if no holes: top of oplog (lastWritten).
AllDurable(s) ==
    IF oplogHoles[s] = {}
    THEN lastWritten[s]
    ELSE LET minHole == Min(oplogHoles[s])
         IN IF minHole = 1
            THEN NilOpTime  \* hole at position 1 means nothing is durable
            ELSE [term |-> LogTerm(s, minHole - 1),
                  index |-> minHole - 1]

\* Stable timestamp: min(lastApplied, allDurable, commitPoint).
\* replication_coordinator_impl.cpp:5084-5093
StableTimestamp(s) ==
    LET allDur == AllDurable(s)
        noOverlap == MinTimestamp({lastApplied[s], allDur})
    IN MinTimestamp({noOverlap, commitPoint[s]})

\* Server i is allowed to sync from server j.
CanSyncFrom(i, j) ==
    /\ Len(log[i]) < Len(log[j])
    /\ LastTerm(log[i]) = LogTerm(j, Len(log[i]))

\* Server "me" is ahead of or equal to server j.
NotBehind(me, j) ==
    \/ LastTerm(log[me]) > LastTerm(log[j])
    \/ /\ LastTerm(log[me]) = LastTerm(log[j])
       /\ Len(log[me]) >= Len(log[j])

\* The set of nodes that have log[me][logIndex] durably.
\* Uses lastDurable for commit point calculation when useDurableForCommit = TRUE,
\* otherwise uses lastWritten.
\* replication_coordinator_impl.cpp:1701-1704
Agree(me, logIndex) ==
    { node \in Server :
        /\ state[node] /= "Down"
        /\ LET optime == IF useDurableForCommit
                          THEN lastDurable[node]
                          ELSE lastWritten[node]
           IN /\ optime.index >= logIndex
              \* Guard: log must actually contain the entry (Bug Family 2:
              \* stale lastDurable from TOCTOU can exceed log length)
              /\ Len(log[node]) >= logIndex
              /\ LogTerm(me, logIndex) = LogTerm(node, logIndex) }

CommitPointLessThan(i, j) ==
    \/ commitPoint[i].term < commitPoint[j].term
    \/ /\ commitPoint[i].term = commitPoint[j].term
       /\ commitPoint[i].index < commitPoint[j].index

CanRollbackOplog(i, j) ==
    /\ Len(log[i]) > 0
    /\ LastTerm(log[i]) < LastTerm(log[j])
    /\ \/ Len(log[i]) > Len(log[j])
       \/ /\ Len(log[i]) <= Len(log[j])
          /\ LastTerm(log[i]) /= LogTerm(j, Len(log[i]))

\* Update the last and curr for committedSnapshot[i].
\* replication_coordinator_impl.cpp:5647-5690
UpdateCommittedSnapshot(i, newCS) ==
    committedSnapshot' = [committedSnapshot EXCEPT
        ![i] = [last |-> committedSnapshot[i].curr, curr |-> newCS]]

\* Is restart optimized away (no state change expected)?
RestartIsUnnecessary(i) ==
    /\ lastApplied[i] = lastDurable[i]
    /\ lastApplied[i] = committedSnapshot[i].curr

----
\*****************************************************************************
\* Init
\*****************************************************************************
Init ==
    /\ currentTerm          = [i \in Server |-> 0]
    /\ state                = [i \in Server |-> "Follower"]
    /\ commitPoint          = [i \in Server |-> NilOpTime]
    /\ lastDurable          = [i \in Server |-> NilOpTime]
    /\ lastApplied          = [i \in Server |-> NilOpTime]
    /\ lastWritten          = [i \in Server |-> NilOpTime]
    /\ committedSnapshot    = [i \in Server |-> [last |-> NilOpTime, curr |-> NilOpTime]]
    /\ log                  = [i \in Server |-> << >>]
    /\ committedEntries     = {}
    /\ oplogHoles           = [i \in Server |-> {}]
    /\ preparedTxns         = [i \in Server |-> {}]
    /\ journalFlusherSnapshot = [i \in Server |-> NilOpTime]
    /\ useDurableForCommit  = TRUE
    /\ writeConcernWaiters  = [i \in Server |-> {}]
    /\ acknowledged         = {}
    /\ rolledBack           = {}
    /\ recoveryPhase        = [i \in Server |-> "none"]
    /\ oplogTruncateAfterPoint = [i \in Server |-> NilOpTime]
    /\ restartTimes         = [i \in Server |-> 0]
    /\ failoverTimes        = [i \in Server |-> 0]

----
\*****************************************************************************
\* Actions
\*****************************************************************************

\* =========================================================================
\* AppendOplog: Secondary i receives oplog entries from sync source j.
\* RaftMongoReplTimestamp.tla:167-173
\* =========================================================================
AppendOplog(i, j) ==
    /\ state[i] = "Follower"
    /\ recoveryPhase[i] = "none"
    /\ CanSyncFrom(i, j)
    /\ state[j] /= "Down"
    /\ \E lastAppended \in (Len(log[i]) + 1)..Len(log[j]) :
        LET appendedEntries == SubSeq(log[j], Len(log[i]) + 1, lastAppended)
        IN log' = [log EXCEPT ![i] = log[i] \o appendedEntries]
    /\ UNCHANGED <<committedEntries, electionVars, oplogTimeVars,
                   holeVars, flusherVars, wcVars, recoveryVars, controlVars>>

\* =========================================================================
\* PersistOplog: Journal flush on server i (synchronous path).
\* Used for secondaries where journal flush is simpler.
\* RaftMongoReplTimestamp.tla:176-180
\* =========================================================================
PersistOplog(i) ==
    /\ state[i] /= "Down"
    /\ recoveryPhase[i] = "none"
    /\ LET newLastDurable == [term |-> LastTerm(log[i]), index |-> Len(log[i])]
       IN /\ ~TimestampLTE(newLastDurable, lastDurable[i])
          /\ lastDurable' = [lastDurable EXCEPT ![i] = newLastDurable]
    /\ UNCHANGED <<lastApplied, lastWritten, commitPoint, committedSnapshot,
                   electionVars, logVars, holeVars, flusherVars, wcVars,
                   recoveryVars, controlVars>>

\* =========================================================================
\* ApplyOplog: Oplog applier on follower i advances lastApplied.
\* RaftMongoReplTimestamp.tla:183-190
\* =========================================================================
ApplyOplog(i) ==
    /\ state[i] = "Follower"
    /\ recoveryPhase[i] = "none"
    /\ LET newLastApplied == [term |-> LastTerm(log[i]), index |-> Len(log[i])]
           newCS == MinTimestamp({commitPoint[i], newLastApplied})
       IN /\ ~TimestampLTE(newLastApplied, lastApplied[i])
          /\ lastApplied' = [lastApplied EXCEPT ![i] = newLastApplied]
          /\ lastWritten' = [lastWritten EXCEPT ![i] = newLastApplied]
          /\ UpdateCommittedSnapshot(i, newCS)
    /\ UNCHANGED <<lastDurable, commitPoint, electionVars, logVars,
                   holeVars, flusherVars, wcVars, recoveryVars, controlVars>>

\* =========================================================================
\* LearnCommitPoint: Node i learns commit point from node j via heartbeat.
\* RaftMongoReplTimestamp.tla:193-199
\* =========================================================================
LearnCommitPoint(i, j) ==
    /\ state[i] /= "Down"
    /\ state[j] /= "Down"
    /\ recoveryPhase[i] = "none"
    /\ CommitPointLessThan(i, j)
    /\ LET newCP == commitPoint[j]
           newCS == MinTimestamp({newCP, lastApplied[i]})
       IN /\ commitPoint' = [commitPoint EXCEPT ![i] = commitPoint[j]]
          /\ UpdateCommittedSnapshot(i, newCS)
    /\ UNCHANGED <<lastDurable, lastApplied, lastWritten, electionVars,
                   logVars, holeVars, flusherVars, wcVars, recoveryVars, controlVars>>

\* =========================================================================
\* LearnCommitPointWithTermCheck: Heartbeat-based commit point with term guard.
\* RaftMongoReplTimestamp.tla:299-301
\* =========================================================================
LearnCommitPointWithTermCheck(i, j) ==
    /\ LastTerm(log[i]) = commitPoint[j].term
    /\ LearnCommitPoint(i, j)

\* =========================================================================
\* LearnCommitPointFromSyncSourceNeverBeyondTopOfOplog
\* RaftMongoReplTimestamp.tla:305-319
\* =========================================================================
LearnCommitPointFromSyncSource(i, j) ==
    /\ state[i] /= "Down"
    /\ state[j] /= "Down"
    /\ recoveryPhase[i] = "none"
    /\ \/ CanSyncFrom(i, j)
       \/ log[i] = log[j]
    /\ CommitPointLessThan(i, j)
    /\ LET myCP == IF commitPoint[j].term <= LastTerm(log[i])
                    THEN commitPoint[j]
                    ELSE [term |-> LastTerm(log[i]), index |-> Len(log[i])]
           newCS == MinTimestamp({myCP, lastApplied[i]})
       IN /\ commitPoint' = [commitPoint EXCEPT ![i] = myCP]
          /\ UpdateCommittedSnapshot(i, newCS)
    /\ UNCHANGED <<lastDurable, lastApplied, lastWritten, electionVars,
                   logVars, holeVars, flusherVars, wcVars, recoveryVars, controlVars>>

\* =========================================================================
\* RollbackOplog: Node i rolls back based on j's log.
\* RaftMongoReplTimestamp.tla:201-213
\* Also marks any rolled-back entries that were acknowledged.
\* =========================================================================
RollbackOplog(i, j) ==
    /\ state[i] /= "Down"
    /\ state[j] /= "Down"
    /\ recoveryPhase[i] = "none"
    /\ CanRollbackOplog(i, j)
    /\ LET rolledBackIndex == Len(log[i])
           rolledBackEntry == [term |-> LastTerm(log[i]), index |-> rolledBackIndex]
           newLog == [index2 \in 1..(Len(log[i]) - 1) |-> log[i][index2]]
           newOplogWritten == [term |-> LastTerm(newLog), index |-> Len(newLog)]
           newLastDurable  == MinTimestamp({lastDurable[i], newOplogWritten})
           newLastApplied  == MinTimestamp({lastApplied[i], newOplogWritten})
           newLastWritten  == MinTimestamp({lastWritten[i], newOplogWritten})
           newCS           == MinTimestamp({commitPoint[i], newLastApplied})
       IN /\ log' = [log EXCEPT ![i] = newLog]
          /\ lastApplied' = [lastApplied EXCEPT ![i] = newLastApplied]
          /\ lastDurable'  = [lastDurable EXCEPT ![i] = newLastDurable]
          /\ lastWritten'  = [lastWritten EXCEPT ![i] = newLastWritten]
          /\ UpdateCommittedSnapshot(i, newCS)
          \* Bug Family 3: track rolled-back acknowledged writes (as full optimes)
          /\ rolledBack' = rolledBack \union {rolledBackEntry}
          \* Remove any oplog holes for the rolled-back entry
          /\ oplogHoles' = [oplogHoles EXCEPT ![i] = oplogHoles[i] \ {rolledBackIndex}]
          /\ preparedTxns' = [preparedTxns EXCEPT ![i] = preparedTxns[i] \ {rolledBackIndex}]
    /\ UNCHANGED <<electionVars, committedEntries, commitPoint,
                   flusherVars, writeConcernWaiters, acknowledged,
                   recoveryVars, controlVars>>

\* =========================================================================
\* BecomePrimaryByMagic: Node i wins election.
\* RaftMongoReplTimestamp.tla:218-228
\* =========================================================================
BecomePrimaryByMagic(i, ayeVoters) ==
    /\ state[i] /= "Down"
    /\ recoveryPhase[i] = "none"
    /\ \A j \in ayeVoters : /\ NotBehind(i, j)
                             /\ currentTerm[j] <= currentTerm[i]
                             /\ state[j] /= "Down"
    /\ IsMajority(ayeVoters)
    /\ state' = [s \in Server |-> IF s \notin ayeVoters THEN state[s]
                                  ELSE IF s = i THEN "Leader" ELSE
                                       IF state[s] = "Down" THEN "Down"
                                       ELSE "Follower"]
    /\ currentTerm' = [s \in Server |->
                        IF s \in (ayeVoters \union {i})
                        THEN currentTerm[i] + 1
                        ELSE currentTerm[s]]
    /\ UNCHANGED <<oplogTimeVars, logVars, holeVars, flusherVars,
                   wcVars, recoveryVars, controlVars>>

\* =========================================================================
\* UpdateTermThroughHeartbeat: Node i learns higher term from j.
\* RaftMongoReplTimestamp.tla:266-270
\* =========================================================================
UpdateTermThroughHeartbeat(i, j) ==
    /\ state[i] /= "Down"
    /\ state[j] /= "Down"
    /\ currentTerm[j] > currentTerm[i]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[j]]
    /\ state' = [state EXCEPT ![i] = IF state[i] = "Down" THEN "Down" ELSE "Follower"]
    /\ UNCHANGED <<oplogTimeVars, logVars, holeVars, flusherVars,
                   wcVars, recoveryVars, controlVars>>

\* =========================================================================
\* AdvanceCommitPoint: Leader advances commit point based on durable acks.
\* RaftMongoReplTimestamp.tla:273-295
\* =========================================================================
AdvanceCommitPoint ==
    \E leader \in Leaders :
    \E acknowledgers \in SUBSET Server :
    \E committedIndex \in (commitPoint[leader].index + 1)..Len(log[leader]) :
        /\ IsMajority(acknowledgers)
        /\ acknowledgers \subseteq Agree(leader, committedIndex)
        /\ LogTerm(leader, committedIndex) = currentTerm[leader]
        /\ \A j \in acknowledgers : currentTerm[j] <= currentTerm[leader]
        \* Bug Family 1: committed index must not be in an oplog hole
        /\ committedIndex \notin oplogHoles[leader]
        /\ LET newCP == [term |-> LogTerm(leader, committedIndex),
                         index |-> committedIndex]
               newCS == MinTimestamp({newCP, lastApplied[leader]})
           IN /\ commitPoint' = [commitPoint EXCEPT ![leader] = newCP]
              /\ UpdateCommittedSnapshot(leader, newCS)
        /\ committedEntries' = committedEntries \union
               {[term |-> LogTerm(leader, i), index |-> i] :
                    i \in (commitPoint[leader].index + 1)..committedIndex}
    /\ UNCHANGED <<electionVars, log, lastApplied, lastDurable, lastWritten,
                   holeVars, flusherVars, wcVars, recoveryVars, controlVars>>

\* =========================================================================
\* ClientWrite: Leader i receives a client write. TWO-PHASE:
\*   Phase 1 (this action): Reserve oplog slot + append entry.
\*   The slot creates a "hole" until CloseOplogHole commits it.
\*
\* Bug Family 1: Split ClientWrite into reserve+commit to expose holes.
\* oplog.cpp:588 (getNextOpTimes reserves slot)
\* =========================================================================
ClientWrite(i) ==
    /\ state[i] = "Leader"
    /\ recoveryPhase[i] = "none"
    /\ \E numEntries \in 1..MaxClientWriteSize :
        LET entry   == [term |-> currentTerm[i]]
            newEntries == [j \in 1..numEntries |-> entry]
            newLog   == log[i] \o newEntries
            newSlots == {Len(log[i]) + j : j \in 1..numEntries}
        IN /\ log' = [log EXCEPT ![i] = newLog]
           \* Primary immediately updates lastApplied and lastWritten
           \* replication_coordinator_impl.cpp:263 (ClientWrite sets lastApplied)
           /\ lastApplied' = [lastApplied EXCEPT
                  ![i] = [term |-> LastTerm(newLog), index |-> Len(newLog)]]
           /\ lastWritten' = [lastWritten EXCEPT
                  ![i] = [term |-> LastTerm(newLog), index |-> Len(newLog)]]
           \* Bug Family 1: slots become holes until committed
           /\ oplogHoles' = [oplogHoles EXCEPT ![i] = oplogHoles[i] \union newSlots]
    /\ UNCHANGED <<committedEntries, electionVars, commitPoint, lastDurable,
                   committedSnapshot, preparedTxns, flusherVars,
                   wcVars, recoveryVars, controlVars>>

\* =========================================================================
\* CloseOplogHole: A previously reserved oplog slot is committed (write
\* transaction completes). Removes the hole.
\* Bug Family 1: Closing holes advances allDurable.
\* =========================================================================
CloseOplogHole(i) ==
    /\ state[i] /= "Down"
    /\ recoveryPhase[i] = "none"
    /\ oplogHoles[i] /= {}
    /\ \E slot \in oplogHoles[i] :
        \* Only close non-prepared slots
        /\ slot \notin preparedTxns[i]
        /\ oplogHoles' = [oplogHoles EXCEPT ![i] = oplogHoles[i] \ {slot}]
    /\ UNCHANGED <<electionVars, oplogTimeVars, logVars, preparedTxns,
                   flusherVars, wcVars, recoveryVars, controlVars>>

\* =========================================================================
\* PrepareTransaction: Leader i prepares a transaction at the latest slot.
\* Bug Family 1: Prepared txns hold oplog holes indefinitely.
\* The oplog entry is already written by ClientWrite; this marks it as
\* "prepared" so CloseOplogHole cannot close it.
\* =========================================================================
PrepareTransaction(i) ==
    /\ state[i] = "Leader"
    /\ recoveryPhase[i] = "none"
    /\ oplogHoles[i] /= {}
    /\ \E slot \in oplogHoles[i] :
        /\ slot \notin preparedTxns[i]
        /\ preparedTxns' = [preparedTxns EXCEPT ![i] = preparedTxns[i] \union {slot}]
    /\ UNCHANGED <<electionVars, oplogTimeVars, logVars, oplogHoles,
                   flusherVars, wcVars, recoveryVars, controlVars>>

\* =========================================================================
\* CommitPreparedTxn: Commits a prepared transaction, closing the hole.
\* Bug Family 1: SERVER-39199 — closing prepared hole must recalculate stable.
\* =========================================================================
CommitPreparedTxn(i) ==
    /\ state[i] /= "Down"
    /\ recoveryPhase[i] = "none"
    /\ preparedTxns[i] /= {}
    /\ \E slot \in preparedTxns[i] :
        /\ preparedTxns' = [preparedTxns EXCEPT ![i] = preparedTxns[i] \ {slot}]
        /\ oplogHoles' = [oplogHoles EXCEPT ![i] = oplogHoles[i] \ {slot}]
    /\ UNCHANGED <<electionVars, oplogTimeVars, logVars, flusherVars,
                   wcVars, recoveryVars, controlVars>>

\* =========================================================================
\* JournalFlusherCapture: Flusher thread reads lastApplied into snapshot.
\* Bug Family 2: First step of the TOCTOU race.
\* replication_coordinator_impl.cpp:1693 (journal flusher captures value)
\* =========================================================================
JournalFlusherCapture(i) ==
    /\ state[i] /= "Down"
    /\ recoveryPhase[i] = "none"
    /\ journalFlusherSnapshot' = [journalFlusherSnapshot EXCEPT ![i] = lastApplied[i]]
    /\ UNCHANGED <<electionVars, oplogTimeVars, logVars, holeVars,
                   useDurableForCommit, wcVars, recoveryVars, controlVars>>

\* =========================================================================
\* JournalFlusherFlush: Flusher thread sets lastDurable from snapshot.
\* Bug Family 2: Second step of the TOCTOU race.
\* SERVER-50949: rollback between capture and flush → stale lastDurable.
\* SERVER-85488: guard against null lastWritten.
\* replication_coordinator_impl.cpp:1693-1708
\* =========================================================================
JournalFlusherFlush(i) ==
    /\ state[i] /= "Down"
    /\ recoveryPhase[i] = "none"
    /\ journalFlusherSnapshot[i] /= NilOpTime
    \* Only advance forward (the "Forward" in setMyLastDurableOpTimeAndWallTimeForward)
    /\ ~TimestampLTE(journalFlusherSnapshot[i], lastDurable[i])
    \* SERVER-85488 fix: skip if lastWritten is null (initial sync just reset)
    /\ lastWritten[i] /= NilOpTime
    /\ lastDurable' = [lastDurable EXCEPT ![i] = journalFlusherSnapshot[i]]
    \* replication_coordinator_impl.cpp:1702-1704
    \* If useDurableForCommit, wake up commit level calculation
    /\ UNCHANGED <<lastApplied, lastWritten, commitPoint, committedSnapshot,
                   electionVars, logVars, holeVars,
                   journalFlusherSnapshot, useDurableForCommit,
                   wcVars, recoveryVars, controlVars>>

\* =========================================================================
\* ClientWriteWithWC: Leader i writes with write concern "majority".
\* Bug Family 3: Creates a write concern waiter.
\* replication_coordinator_impl.cpp:2294 (awaitReplication)
\* =========================================================================
ClientWriteWithWC(i) ==
    /\ state[i] = "Leader"
    /\ recoveryPhase[i] = "none"
    /\ \E numEntries \in 1..MaxClientWriteSize :
        LET entry    == [term |-> currentTerm[i]]
            newEntries == [j \in 1..numEntries |-> entry]
            newLog   == log[i] \o newEntries
            newSlots == {Len(log[i]) + j : j \in 1..numEntries}
            writeOpTime == [term |-> LastTerm(newLog), index |-> Len(newLog)]
        IN /\ log' = [log EXCEPT ![i] = newLog]
           /\ lastApplied' = [lastApplied EXCEPT
                  ![i] = [term |-> LastTerm(newLog), index |-> Len(newLog)]]
           /\ lastWritten' = [lastWritten EXCEPT
                  ![i] = [term |-> LastTerm(newLog), index |-> Len(newLog)]]
           /\ oplogHoles' = [oplogHoles EXCEPT ![i] = oplogHoles[i] \union newSlots]
           \* Create a write concern waiter for the write's optime
           /\ writeConcernWaiters' = [writeConcernWaiters EXCEPT
                  ![i] = writeConcernWaiters[i] \union {writeOpTime}]
    /\ UNCHANGED <<committedEntries, electionVars, commitPoint, lastDurable,
                   committedSnapshot, preparedTxns, flusherVars,
                   acknowledged, rolledBack, recoveryVars, controlVars>>

\* =========================================================================
\* WriteConcernSatisfied: A write concern waiter is satisfied.
\* Bug Family 3: The write is acknowledged to the client.
\* replication_coordinator_impl.cpp:2240-2273 (_doneWaitingForReplication)
\* For w:majority with snapshots: need _currentCommittedSnapshot >= opTime.
\* =========================================================================
WriteConcernSatisfied(i) ==
    /\ state[i] = "Leader"
    /\ writeConcernWaiters[i] /= {}
    /\ \E opTime \in writeConcernWaiters[i] :
        \* Check: committed snapshot has advanced past the write's optime
        /\ TimestampLTE(opTime, committedSnapshot[i].curr)
        /\ writeConcernWaiters' = [writeConcernWaiters EXCEPT
               ![i] = writeConcernWaiters[i] \ {opTime}]
        /\ acknowledged' = acknowledged \union {opTime}
    /\ UNCHANGED <<electionVars, oplogTimeVars, logVars, holeVars,
                   flusherVars, rolledBack, recoveryVars, controlVars>>

\* =========================================================================
\* Stepdown: Leader i steps down. Multi-phase:
\*   1. Set state to Follower
\*   2. Error all write concern waiters (catchup.cpp:253-255)
\*   3. Increment failoverTimes
\*
\* Bug Family 3: The window between WriteConcernSatisfied and Stepdown
\* is where SERVER-113256 lives — the write can be acked then rolled back.
\*
\* step_up_step_down.cpp:234-246 (RSTL release during stepdown)
\* catchup.cpp:251-255 (_replicationWaiterList.setErrorAll)
\* =========================================================================
Stepdown(i) ==
    /\ state[i] = "Leader"
    /\ state' = [state EXCEPT ![i] = "Follower"]
    /\ failoverTimes' = [failoverTimes EXCEPT ![i] = failoverTimes[i] + 1]
    \* Cancel all pending write concern waiters — they get errors
    \* catchup.cpp:253-255
    /\ writeConcernWaiters' = [writeConcernWaiters EXCEPT ![i] = {}]
    /\ UNCHANGED <<currentTerm, oplogTimeVars, logVars, holeVars,
                   flusherVars, acknowledged, rolledBack, recoveryVars, restartTimes>>

\* =========================================================================
\* Crash: Server i crashes. Goes to "Down" state.
\* Volatile state is lost; durable state remains.
\* Bug Family 5: Sets up multi-step recovery.
\* =========================================================================
Crash(i) ==
    /\ state[i] /= "Down"
    /\ ~RestartIsUnnecessary(i)
    /\ state' = [state EXCEPT ![i] = "Down"]
    /\ restartTimes' = [restartTimes EXCEPT ![i] = restartTimes[i] + 1]
    \* Volatile state lost: in-flight holes, waiters, flusher snapshot, committed snapshot
    /\ oplogHoles' = [oplogHoles EXCEPT ![i] = {}]
    /\ preparedTxns' = [preparedTxns EXCEPT ![i] = {}]
    /\ journalFlusherSnapshot' = [journalFlusherSnapshot EXCEPT ![i] = NilOpTime]
    /\ writeConcernWaiters' = [writeConcernWaiters EXCEPT ![i] = {}]
    \* committedSnapshot is volatile (_currentCommittedSnapshot) — reset on crash
    /\ committedSnapshot' = [committedSnapshot EXCEPT
           ![i] = [last |-> NilOpTime, curr |-> NilOpTime]]
    \* Set oplogTruncateAfterPoint to lastDurable (entries beyond are lost)
    \* rollback_impl.cpp:750
    /\ oplogTruncateAfterPoint' = [oplogTruncateAfterPoint EXCEPT ![i] = lastDurable[i]]
    \* Enter recovery
    /\ recoveryPhase' = [recoveryPhase EXCEPT ![i] = "truncate"]
    /\ UNCHANGED <<currentTerm, commitPoint, lastDurable, lastApplied, lastWritten,
                   log, committedEntries, useDurableForCommit,
                   acknowledged, rolledBack, failoverTimes>>

\* =========================================================================
\* RecoverTruncateOplog: First recovery step — truncate entries beyond
\* the oplogTruncateAfterPoint.
\* Bug Family 5: replication_recovery.cpp:495 (_truncateOplogIfNeeded)
\* SERVER-48934: stale oplogTruncateAfterPoint → wrong truncation
\* =========================================================================
RecoverTruncateOplog(i) ==
    /\ state[i] = "Down"
    /\ recoveryPhase[i] = "truncate"
    /\ LET truncPoint == oplogTruncateAfterPoint[i]
           \* Truncate log beyond the truncate point
           newLogLen == IF truncPoint = NilOpTime THEN Len(log[i])
                        ELSE IF truncPoint.index < Len(log[i])
                             THEN truncPoint.index
                             ELSE Len(log[i])
           newLog == [idx \in 1..newLogLen |-> log[i][idx]]
       IN /\ log' = [log EXCEPT ![i] = newLog]
    /\ recoveryPhase' = [recoveryPhase EXCEPT ![i] = "replay"]
    /\ UNCHANGED <<committedEntries, electionVars, oplogTimeVars,
                   holeVars, flusherVars, wcVars,
                   oplogTruncateAfterPoint, controlVars>>

\* =========================================================================
\* RecoverReplayOplog: Second recovery step — replay entries from stable
\* timestamp to top of oplog (abstracted as advancing lastApplied).
\* Bug Family 5: replication_recovery.cpp:522 (_recoverFromStableTimestamp)
\* =========================================================================
RecoverReplayOplog(i) ==
    /\ state[i] = "Down"
    /\ recoveryPhase[i] = "replay"
    \* After replay, lastApplied advances to top of remaining oplog
    /\ LET newLastApplied == IF Len(log[i]) = 0 THEN NilOpTime
                             ELSE [term |-> LastTerm(log[i]), index |-> Len(log[i])]
       IN lastApplied' = [lastApplied EXCEPT ![i] = newLastApplied]
    /\ recoveryPhase' = [recoveryPhase EXCEPT ![i] = "timestamps"]
    /\ UNCHANGED <<lastDurable, lastWritten, commitPoint, committedSnapshot,
                   electionVars, logVars, holeVars, flusherVars, wcVars,
                   oplogTruncateAfterPoint, controlVars>>

\* =========================================================================
\* RecoverSetTimestamps: Final recovery step — set lastDurable, lastWritten,
\* committedSnapshot, and transition to Follower.
\* Bug Family 5: replication_recovery.cpp:510-534
\* SERVER-58721: setting stable timestamp without proper initialization
\* =========================================================================
RecoverSetTimestamps(i) ==
    /\ state[i] = "Down"
    /\ recoveryPhase[i] = "timestamps"
    /\ LET \* After recovery: lastDurable = lastApplied (everything replayed is durable)
           newLastDurable == lastApplied[i]
           newLastWritten == lastApplied[i]
           \* committedSnapshot resets to min(commitPoint, lastApplied)
           newCS == MinTimestamp({commitPoint[i], lastApplied[i]})
       IN /\ lastDurable'  = [lastDurable EXCEPT ![i] = newLastDurable]
          /\ lastWritten'  = [lastWritten EXCEPT ![i] = newLastWritten]
          /\ UpdateCommittedSnapshot(i, newCS)
    /\ state' = [state EXCEPT ![i] = "Follower"]
    /\ recoveryPhase' = [recoveryPhase EXCEPT ![i] = "none"]
    /\ oplogTruncateAfterPoint' = [oplogTruncateAfterPoint EXCEPT ![i] = NilOpTime]
    /\ UNCHANGED <<currentTerm, commitPoint, lastApplied, logVars,
                   holeVars, flusherVars, wcVars, restartTimes, failoverTimes>>

\* =========================================================================
\* RecoveryCrash: Crash during recovery (between recovery steps).
\* Bug Family 5: Crash window between truncate/replay/timestamps.
\* Resets to beginning of recovery.
\* =========================================================================
RecoveryCrash(i) ==
    /\ state[i] = "Down"
    /\ recoveryPhase[i] \in {"truncate", "replay", "timestamps"}
    /\ recoveryPhase' = [recoveryPhase EXCEPT ![i] = "truncate"]
    \* oplogTruncateAfterPoint persists across crashes
    /\ UNCHANGED <<electionVars, oplogTimeVars, logVars, holeVars,
                   flusherVars, wcVars, oplogTruncateAfterPoint, controlVars>>

----
\*****************************************************************************
\* Action Wrappers
\*****************************************************************************

AppendOplogAction        == \E i, j \in Server : AppendOplog(i, j)
PersistOplogAction       == \E i \in Server : PersistOplog(i)
ApplyOplogAction         == \E i \in Server : ApplyOplog(i)
LearnCommitPointWithTermCheckAction ==
    \E i, j \in Server : LearnCommitPointWithTermCheck(i, j)
LearnCommitPointFromSyncSourceAction ==
    \E i, j \in Server : LearnCommitPointFromSyncSource(i, j)
RollbackOplogAction      == \E i, j \in Server : RollbackOplog(i, j)
BecomePrimaryByMagicAction ==
    \E i \in Server : \E ayeVoters \in SUBSET(Server) : BecomePrimaryByMagic(i, ayeVoters)
UpdateTermThroughHeartbeatAction ==
    \E i, j \in Server : UpdateTermThroughHeartbeat(i, j)
StepdownAction           == \E i \in Server : Stepdown(i)
ClientWriteAction        == \E i \in Server : ClientWrite(i)
CloseOplogHoleAction     == \E i \in Server : CloseOplogHole(i)
PrepareTransactionAction == \E i \in Server : PrepareTransaction(i)
CommitPreparedTxnAction  == \E i \in Server : CommitPreparedTxn(i)
JournalFlusherCaptureAction == \E i \in Server : JournalFlusherCapture(i)
JournalFlusherFlushAction   == \E i \in Server : JournalFlusherFlush(i)
ClientWriteWithWCAction  == \E i \in Server : ClientWriteWithWC(i)
WriteConcernSatisfiedAction == \E i \in Server : WriteConcernSatisfied(i)
CrashAction              == \E i \in Server : Crash(i)
RecoverTruncateOplogAction  == \E i \in Server : RecoverTruncateOplog(i)
RecoverReplayOplogAction    == \E i \in Server : RecoverReplayOplog(i)
RecoverSetTimestampsAction  == \E i \in Server : RecoverSetTimestamps(i)
RecoveryCrashAction         == \E i \in Server : RecoveryCrash(i)

----
\*****************************************************************************
\* Next-State Relation
\*****************************************************************************
Next ==
    \* --- Replication protocol ---
    \/ AppendOplogAction
    \/ RollbackOplogAction
    \/ BecomePrimaryByMagicAction
    \/ StepdownAction
    \/ UpdateTermThroughHeartbeatAction
    \* --- Oplog + durability ---
    \/ ClientWriteAction
    \/ CloseOplogHoleAction
    \/ PersistOplogAction
    \/ ApplyOplogAction
    \* --- Commit point ---
    \/ AdvanceCommitPoint
    \/ LearnCommitPointWithTermCheckAction
    \/ LearnCommitPointFromSyncSourceAction
    \* --- Bug Family 1: Prepared transactions ---
    \/ PrepareTransactionAction
    \/ CommitPreparedTxnAction
    \* --- Bug Family 2: Async journal flusher ---
    \/ JournalFlusherCaptureAction
    \/ JournalFlusherFlushAction
    \* --- Bug Family 3: Write concern ---
    \/ ClientWriteWithWCAction
    \/ WriteConcernSatisfiedAction
    \* --- Bug Family 5: Crash + recovery ---
    \/ CrashAction
    \/ RecoverTruncateOplogAction
    \/ RecoverReplayOplogAction
    \/ RecoverSetTimestampsAction
    \/ RecoveryCrashAction

Spec == Init /\ [][Next]_vars

----
\*****************************************************************************
\* Invariants
\*****************************************************************************

\* --- Standard safety (from existing spec) ---

NoTwoPrimariesInSameTerm ==
    ~\E i, j \in Server :
        /\ i /= j
        /\ currentTerm[i] = currentTerm[j]
        /\ state[i] = "Leader"
        /\ state[j] = "Leader"

NeverRollbackCommitted ==
    \A i \in Server :
        ~(/\ [term |-> LastTerm(log[i]), index |-> Len(log[i])] \in committedEntries
          /\ \E j \in Server : CanRollbackOplog(i, j))

CommittedSnapshotNeverRollback ==
    \A i \in Server :
        TimestampLTE(committedSnapshot[i].last, committedSnapshot[i].curr)

\* --- Extension invariants (Bug Family targets) ---

\* Bug Family 1: Stable timestamp never exceeds allDurable on primaries.
\* replication_coordinator_impl.cpp:5097-5110 (invariant checks)
StableNeverExceedsAllDurable ==
    \A s \in Server :
        state[s] = "Leader" =>
            TimestampLTE(StableTimestamp(s), AllDurable(s))

\* Bug Family 1: Holes block allDurable.
\* If any hole exists, allDurable is below the smallest hole.
HolesBlockAllDurable ==
    \A s \in Server :
        state[s] /= "Down" /\ oplogHoles[s] /= {} =>
            AllDurable(s).index < Min(oplogHoles[s])

\* Bug Family 1: Prepared transaction pins stable timestamp.
PreparedTxnPinsStable ==
    \A s \in Server :
        \A slot \in preparedTxns[s] :
            state[s] /= "Down" =>
                StableTimestamp(s).index < slot

\* Bug Family 2: lastDurable refers to an entry that exists in the oplog.
\* SERVER-50949: after rollback, lastDurable may point to rolled-back entry.
LastDurableImpliesInOplog ==
    \A s \in Server :
        /\ state[s] /= "Down"
        /\ lastDurable[s] /= NilOpTime
        => /\ lastDurable[s].index <= Len(log[s])
           /\ LogTerm(s, lastDurable[s].index) = lastDurable[s].term

\* Bug Family 3: Acknowledged writes are never rolled back.
\* SERVER-113256: the core safety property.
AcknowledgedWriteNeverRolledBack ==
    \A opTime \in acknowledged :
        opTime \notin rolledBack

\* --- Structural invariants ---

\* lastApplied never exceeds log length.
LastAppliedBound ==
    \A s \in Server :
        state[s] /= "Down" => lastApplied[s].index <= Len(log[s])

\* lastDurable never exceeds log length.
LastDurableBound ==
    \A s \in Server :
        state[s] /= "Down" => lastDurable[s].index <= Len(log[s])

\* Commit point monotonically increases (within a term).
CommitPointMonotonic ==
    \A s \in Server :
        TimestampLTE(committedSnapshot[s].last, committedSnapshot[s].curr)

\* Oplog holes are within log bounds.
HolesInBounds ==
    \A s \in Server :
        \A slot \in oplogHoles[s] :
            /\ slot >= 1
            /\ slot <= Len(log[s])

====
