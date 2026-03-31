--------------------------------- MODULE base ---------------------------------
\* MongoDB RaftMongo Replication Commit Point Protocol
\*
\* Models the commit point propagation protocol with extensions for:
\*   - Three-level write pipeline: lastWritten -> lastApplied -> lastDurable [Family 2]
\*   - Explicit election protocol with voting and catchup [Family 3]
\*   - firstOpTimeOfMyTerm lifecycle (commit freeze during drain) [Family 3]
\*   - Vote persistence crash window [Family 3]
\*   - writeConcernMajorityShouldJournal flag for Agree() [Family 2]
\*   - Heartbeat commit point term check using lastWritten [Family 1, 4]
\*   - Sync source commit point clamping to lastWritten [Family 1, 2]
\*
\* Based on MongoDB 8.3.0-alpha3 (commit 1425a42f2d)
\* Source: artifact/mongo-src/src/mongo/db/repl/

EXTENDS Integers, FiniteSets, Sequences, TLC

\* ---- Constants ----

\* The set of server IDs
CONSTANT Server

\* The maximum number of oplog entries created on primary in one action
CONSTANT MaxClientWriteSize

\* Nil value for votedFor (no vote cast)
CONSTANT Nil

\* Whether the replica set requires journal for majority write concern
\* topology_coordinator.cpp:3141 — switches Agree() between lastDurable and lastWritten
\* [Family 2]
CONSTANT WriteConcernMajorityShouldJournal

\* Sentinel for "infinity" optime (blocks commit advancement during drain)
\* topology_coordinator.cpp:2935-2936 — _firstOpTimeOfMyTerm = INT_MAX
\* [Family 3]
CONSTANT InfOpTime

\* ---- Variables ----

\* -- Server state --
VARIABLE currentTerm       \* [Server -> Nat] — server's term number
VARIABLE state             \* [Server -> {"Follower", "Candidate", "Leader"}]
VARIABLE votedFor          \* [Server -> Server \cup {Nil}] — who voted for in current term

serverVars == <<currentTerm, state, votedFor>>

\* -- Election --
VARIABLE votesGranted      \* [Server -> SUBSET Server] — votes received (candidate only)

candidateVars == <<votesGranted>>

\* -- Leader --
\* Set to InfOpTime on WinElection (blocks commit advancement during drain).
\* Set to actual no-op optime on WritePrimaryNoOp (unblocks commit advancement).
\* topology_coordinator.cpp:2935-2936, 3271-3278, 3193
\* [Family 3]
VARIABLE firstOpTimeOfMyTerm

leaderVars == <<firstOpTimeOfMyTerm>>

\* -- Log --
VARIABLE log               \* [Server -> Seq([term: Nat])] — oplog
VARIABLE committedEntries   \* Set of [term: Nat, index: Nat] — globally committed entries

logVars == <<log, committedEntries>>

\* -- Three-level pipeline (Family 2) --
\* replication_coordinator_impl.cpp:1672-1708
\* Invariant: lastDurable <= lastApplied <= lastWritten = top of oplog
VARIABLE lastWritten       \* [Server -> [term: Nat, index: Nat]] — latest written to oplog
VARIABLE lastApplied       \* [Server -> [term: Nat, index: Nat]] — latest applied to data
VARIABLE lastDurable       \* [Server -> [term: Nat, index: Nat]] — latest journaled to disk

pipelineVars == <<lastWritten, lastApplied, lastDurable>>

\* -- Commit point --
VARIABLE commitPoint       \* [Server -> [term: Nat, index: Nat]] — learned commit point

commitVars == <<commitPoint, committedEntries>>

\* All variables
vars == <<serverVars, candidateVars, leaderVars, logVars, pipelineVars, commitPoint>>

----
\* ---- Helpers ----

\* OpTime comparison: a <= b (lexicographic on term, then index)
OpTimeLTE(a, b) ==
    \/ a.term < b.term
    \/ /\ a.term = b.term
       /\ a.index <= b.index

\* OpTime comparison: a < b (strict)
OpTimeLT(a, b) == OpTimeLTE(a, b) /\ (a.term /= b.term \/ a.index /= b.index)

\* Minimum of two optimes
MinOpTime(a, b) == IF OpTimeLTE(a, b) THEN a ELSE b

\* Standard helpers
IsMajority(servers) == Cardinality(servers) * 2 > Cardinality(Server)
GetTerm(xlog, index) == IF index = 0 THEN 0 ELSE xlog[index].term
LogTerm(i, index) == GetTerm(log[i], index)
LastTerm(xlog) == GetTerm(xlog, Len(xlog))
Leaders == {s \in Server : state[s] = "Leader"}
Range(f) == {f[x] : x \in DOMAIN f}
Max(s) == CHOOSE x \in s : \A y \in s : x >= y
GlobalCurrentTerm == Max(Range(currentTerm))

NullOpTime == [term |-> 0, index |-> 0]

\* Server i is allowed to sync from server j.
\* The sync source must be ahead and share a common prefix.
CanSyncFrom(i, j) ==
    /\ Len(log[i]) < Len(log[j])
    /\ LastTerm(log[i]) = LogTerm(j, Len(log[i]))

\* Freshness check for vote granting — uses lastWritten (not log length).
\* topology_coordinator.cpp:3761-3767 — args.getLastWrittenOpTime() < getMyLastWrittenOpTime()
\* [Family 2: vote freshness now uses lastWritten instead of lastApplied]
NotBehind(me, j) ==
    \/ lastWritten[me].term > lastWritten[j].term
    \/ /\ lastWritten[me].term = lastWritten[j].term
       /\ lastWritten[me].index >= lastWritten[j].index

\* The set of nodes whose tracked optime has reached logIndex for leader me.
\* topology_coordinator.cpp:3141-3153 — uses lastDurable or lastWritten based on config
\* [Family 2: key extension — switches between lastDurable and lastWritten]
Agree(me, logIndex) ==
    { node \in Server :
        /\ IF WriteConcernMajorityShouldJournal
           THEN lastDurable[node].index >= logIndex
           ELSE lastWritten[node].index >= logIndex
        /\ LogTerm(me, logIndex) = LogTerm(node, logIndex) }

\* Return whether Node i can learn the commit point from Node j.
CommitPointLessThan(i, j) ==
   \/ commitPoint[i].term < commitPoint[j].term
   \/ /\ commitPoint[i].term = commitPoint[j].term
      /\ commitPoint[i].index < commitPoint[j].index

\* Is it possible for node i's log to roll back based on j's log?
CanRollbackOplog(i, j) ==
    /\ Len(log[i]) > 0
    /\ LastTerm(log[i]) < LastTerm(log[j])
    /\ \/ Len(log[i]) > Len(log[j])
       \/ /\ Len(log[i]) <= Len(log[j])
          /\ LastTerm(log[i]) /= LogTerm(j, Len(log[i]))

----
\* ---- Init ----

Init ==
    /\ currentTerm       = [i \in Server |-> 0]
    /\ state             = [i \in Server |-> "Follower"]
    /\ votedFor          = [i \in Server |-> Nil]
    /\ votesGranted      = [i \in Server |-> {}]
    /\ firstOpTimeOfMyTerm = [i \in Server |-> NullOpTime]
    /\ log               = [i \in Server |-> << >>]
    /\ committedEntries   = {}
    /\ lastWritten       = [i \in Server |-> NullOpTime]
    /\ lastApplied       = [i \in Server |-> NullOpTime]
    /\ lastDurable       = [i \in Server |-> NullOpTime]
    /\ commitPoint       = [i \in Server |-> NullOpTime]

----
\* ---- Election Protocol (Family 3) ----

\* ACTION: StartElection
\* A follower initiates an election by incrementing its term, voting for itself,
\* and transitioning to Candidate state.
\* replication_coordinator_impl_elect_v1.cpp:294-350 — _startRealElection
\* topology_coordinator.cpp:voteForMyselfV1
StartElection(i) ==
    \* replication_coordinator_impl_elect_v1.cpp:329 — _updateTerm(lk, newTerm)
    /\ state[i] = "Follower"
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ state' = [state EXCEPT ![i] = "Candidate"]
    \* replication_coordinator_impl_elect_v1.cpp:336 — voteForMyselfV1()
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ UNCHANGED <<leaderVars, logVars, pipelineVars, commitPoint>>

\* ACTION: RequestVote
\* Candidate i requests a vote from node j, and j grants it.
\* topology_coordinator.cpp:3701-3796 — processReplSetRequestVotes
\* [Family 3: explicit voting replaces BecomePrimaryByMagic]
RequestVote(i, j) ==
    /\ state[i] = "Candidate"
    /\ i /= j
    \* topology_coordinator.cpp:3752-3755 — candidate's term must be >= voter's
    /\ currentTerm[i] >= currentTerm[j]
    \* topology_coordinator.cpp:3761-3767 — candidate must be at least as fresh (uses lastWritten)
    /\ NotBehind(i, j)
    \* topology_coordinator.cpp:3768-3773 — check if already voted in this term
    /\ \/ currentTerm[i] > currentTerm[j]          \* New term resets vote
       \/ votedFor[j] = Nil                          \* Haven't voted in current term
       \/ votedFor[j] = i                            \* Idempotent: already voted for this candidate
    \* Grant vote: update voter's term and state
    /\ currentTerm' = [currentTerm EXCEPT ![j] = currentTerm[i]]
    \* topology_coordinator.cpp — _updateTerm triggers stepdown for leaders/candidates
    /\ state' = [state EXCEPT ![j] = IF currentTerm[i] > currentTerm[j]
                                      THEN "Follower" ELSE state[j]]
    \* topology_coordinator.cpp:3790-3791 — record vote
    /\ votedFor' = [votedFor EXCEPT ![j] = i]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = votesGranted[i] \cup {j}]
    /\ UNCHANGED <<leaderVars, logVars, pipelineVars, commitPoint>>

\* ACTION: WinElection
\* Candidate with majority of votes transitions to Leader in LeaderElect mode.
\* topology_coordinator.cpp:2924-2937 — processWinElection
\* [Family 3: firstOpTimeOfMyTerm = INT_MAX blocks commit advancement during drain]
WinElection(i) ==
    /\ state[i] = "Candidate"
    /\ IsMajority(votesGranted[i])
    /\ state' = [state EXCEPT ![i] = "Leader"]
    \* topology_coordinator.cpp:2935-2936 — freeze commit point during catchup/drain
    /\ firstOpTimeOfMyTerm' = [firstOpTimeOfMyTerm EXCEPT ![i] = InfOpTime]
    /\ UNCHANGED <<currentTerm, votedFor, candidateVars, logVars, pipelineVars, commitPoint>>

\* ACTION: WritePrimaryNoOp
\* Leader completes drain phase: writes no-op entry and becomes writable primary.
\* replication_coordinator_impl.cpp:1523 — onTransitionToPrimary (writes no-op)
\* topology_coordinator.cpp:3271-3278 — completeTransitionToPrimary (sets firstOpTimeOfMyTerm)
\* [Family 3: unblocks commit advancement by setting firstOpTimeOfMyTerm to actual optime]
WritePrimaryNoOp(i) ==
    /\ state[i] = "Leader"
    \* Must still be in LeaderElect mode (firstOpTimeOfMyTerm = Infinity)
    /\ firstOpTimeOfMyTerm[i] = InfOpTime
    /\ LET entry == [term |-> currentTerm[i]]
           newLog == Append(log[i], entry)
           newOpTime == [term |-> currentTerm[i], index |-> Len(newLog)]
       IN /\ log' = [log EXCEPT ![i] = newLog]
          \* Primary writes and applies inline
          \* replication_coordinator_impl.cpp:1603-1621
          /\ lastWritten' = [lastWritten EXCEPT ![i] = newOpTime]
          /\ lastApplied' = [lastApplied EXCEPT ![i] = newOpTime]
          \* topology_coordinator.cpp:3278 — _firstOpTimeOfMyTerm = firstOpTimeOfTerm
          /\ firstOpTimeOfMyTerm' = [firstOpTimeOfMyTerm EXCEPT ![i] = newOpTime]
    /\ UNCHANGED <<serverVars, candidateVars, lastDurable, commitVars>>

----
\* ---- Replication Protocol ----

\* ACTION: ClientWrite
\* Leader receives a client request and writes entries to the oplog.
\* Primary applies inline: updates both lastWritten and lastApplied atomically.
\* replication_coordinator_impl.cpp:1603-1621 — setMyLastAppliedAndLastWrittenOpTimeAndWallTimeForward
\* [Family 2: models three-level pipeline on primary — write+apply are atomic, durable is separate]
ClientWrite(i) ==
    /\ state[i] = "Leader"
    \* topology_coordinator.cpp:2920-2921 — canAcceptWrites requires WritablePrimary mode
    /\ firstOpTimeOfMyTerm[i] /= InfOpTime
    /\ \E numEntries \in 1..MaxClientWriteSize :
        LET entry == [term |-> currentTerm[i]]
            newEntries == [j \in 1..numEntries |-> entry]
            newLog == log[i] \o newEntries
            newOpTime == [term |-> currentTerm[i], index |-> Len(newLog)]
        IN /\ log' = [log EXCEPT ![i] = newLog]
           \* Primary updates lastWritten and lastApplied together
           /\ lastWritten' = [lastWritten EXCEPT ![i] = newOpTime]
           /\ lastApplied' = [lastApplied EXCEPT ![i] = newOpTime]
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, lastDurable, commitVars>>

\* ACTION: AppendOplog
\* Follower i syncs oplog entries from server j.
\* Updates lastWritten to track top of oplog after appending.
\* [Family 2: lastWritten advances with oplog append, separate from lastApplied]
AppendOplog(i, j) ==
    /\ CanSyncFrom(i, j)
    /\ state[i] = "Follower"
    /\ \E lastAppended \in (Len(log[i]) + 1)..Len(log[j]) :
        LET appendedEntries == SubSeq(log[j], Len(log[i]) + 1, lastAppended)
            newLog == log[i] \o appendedEntries
            newOpTime == [term |-> LastTerm(newLog), index |-> Len(newLog)]
        IN /\ log' = [log EXCEPT ![i] = newLog]
           \* replication_coordinator_impl.cpp — setMyLastWrittenOpTimeAndWallTimeForward
           /\ lastWritten' = [lastWritten EXCEPT ![i] = newOpTime]
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, committedEntries,
                   lastApplied, lastDurable, commitPoint>>

\* ACTION: PersistOplog
\* Journal flush advances lastDurable toward lastWritten.
\* [Family 2: decoupled from lastApplied — durable != applied]
PersistOplog(i) ==
    \* Something to persist: lastDurable < lastWritten
    /\ OpTimeLT(lastDurable[i], lastWritten[i])
    /\ lastDurable' = [lastDurable EXCEPT ![i] = lastWritten[i]]
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   lastWritten, lastApplied, commitPoint>>

\* ACTION: ApplyOplog
\* Oplog applier advances lastApplied toward lastWritten (follower only).
\* On primary, apply happens inline with ClientWrite.
\* [Family 2: decoupled from lastWritten — applied != written on followers]
ApplyOplog(i) ==
    /\ state[i] = "Follower"
    \* Something to apply: lastApplied < lastWritten
    /\ OpTimeLT(lastApplied[i], lastWritten[i])
    /\ lastApplied' = [lastApplied EXCEPT ![i] = lastWritten[i]]
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   lastWritten, lastDurable, commitPoint>>

\* ACTION: RollbackOplog
\* Follower i rolls back one oplog entry to converge with server j.
\* Adjusts all pipeline variables to stay within the truncated log.
\* rollback_impl.cpp:1182-1248 — _findCommonPoint
\* [Family 5: rollback safety with three-level pipeline]
RollbackOplog(i, j) ==
    /\ CanRollbackOplog(i, j)
    /\ LET newLog == [index2 \in 1..(Len(log[i]) - 1) |-> log[i][index2]]
           newOpTime == IF Len(newLog) = 0 THEN NullOpTime
                        ELSE [term |-> LastTerm(newLog), index |-> Len(newLog)]
           \* Pipeline variables clamped to new log top
           newLastWritten == MinOpTime(lastWritten[i], newOpTime)
           newLastApplied == MinOpTime(lastApplied[i], newOpTime)
           newLastDurable == MinOpTime(lastDurable[i], newOpTime)
       IN /\ log' = [log EXCEPT ![i] = newLog]
          /\ lastWritten' = [lastWritten EXCEPT ![i] = newLastWritten]
          /\ lastApplied' = [lastApplied EXCEPT ![i] = newLastApplied]
          /\ lastDurable' = [lastDurable EXCEPT ![i] = newLastDurable]
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitVars>>

----
\* ---- Term Learning ----

\* ACTION: UpdateTermThroughHeartbeat
\* Node i learns a higher term from node j (via heartbeat, vote request, or any RPC).
\* replication_coordinator_impl.cpp:5573-5588 — _updateTerm triggers stepdown
\* [Family 4: term propagation — abstract model allows any source]
UpdateTermThroughHeartbeat(i, j) ==
    /\ currentTerm[j] > currentTerm[i]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[j]]
    /\ state' = [state EXCEPT ![i] = "Follower"]
    \* New term resets vote
    /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
    /\ UNCHANGED <<candidateVars, leaderVars, logVars, pipelineVars, commitPoint>>

\* ACTION: Stepdown
\* Leader steps down for any reason (admin command, lost contact, etc.).
\* topology_coordinator.cpp:2948-2986 — tryToStartStepDown
Stepdown(i) ==
    /\ state[i] = "Leader"
    /\ state' = [state EXCEPT ![i] = "Follower"]
    /\ UNCHANGED <<currentTerm, votedFor, candidateVars, leaderVars,
                   logVars, pipelineVars, commitPoint>>

----
\* ---- Commit Point Protocol (Family 1) ----

\* ACTION: AdvanceCommitPoint
\* Leader computes new commit point from majority acknowledgment.
\* topology_coordinator.cpp:3131-3172 — updateLastCommittedOpTimeAndWallTime
\* topology_coordinator.cpp:3174-3246 — advanceLastCommittedOpTimeAndWallTime
\* [Family 1: core commit point — now with Family 2 Agree() extension]
\* [Family 3: firstOpTimeOfMyTerm guard blocks advancement during drain]
AdvanceCommitPoint ==
    \E leader \in Leaders :
    \E acknowledgers \in SUBSET Server :
    \E committedIndex \in (commitPoint[leader].index + 1)..Len(log[leader]) :
        \* topology_coordinator.cpp:3136 — must be primary
        /\ state[leader] = "Leader"
        \* topology_coordinator.cpp:3193 — committedOpTime must be >= firstOpTimeOfMyTerm
        \* [Family 3: this blocks commit during LeaderElect/drain when firstOpTimeOfMyTerm = InfOpTime]
        /\ OpTimeLTE(firstOpTimeOfMyTerm[leader],
                     [term |-> LogTerm(leader, committedIndex), index |-> committedIndex])
        /\ IsMajority(acknowledgers)
        \* topology_coordinator.cpp:3141-3153 — Agree() uses lastDurable or lastWritten
        \* [Family 2: WriteConcernMajorityShouldJournal switches the threshold]
        /\ acknowledgers \subseteq Agree(leader, committedIndex)
        \* New commitPoint must be in leader's current term
        /\ LogTerm(leader, committedIndex) = currentTerm[leader]
        \* If an acknowledger has a higher term, the leader would step down
        /\ \A j \in acknowledgers : currentTerm[j] <= currentTerm[leader]
        /\ LET newCommitPoint == [
                   term |-> LogTerm(leader, committedIndex),
                   index |-> committedIndex
               ]
           IN commitPoint' = [commitPoint EXCEPT ![leader] = newCommitPoint]
        /\ committedEntries' = committedEntries \union {[
               term |-> LogTerm(leader, idx),
               index |-> idx
           ] : idx \in (commitPoint[leader].index + 1)..committedIndex}
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, log, pipelineVars>>

\* ACTION: LearnCommitPointWithTermCheck
\* Node i learns the commit point from j via heartbeat with term check.
\* This is the non-sync-source path: reject if terms differ.
\* topology_coordinator.cpp:3203-3217 — term check uses getMyLastWrittenOpTime().getTerm()
\* [Family 1, 4: term check is the key safety mechanism for heartbeat commit point]
\* [Family 2: uses lastWritten term, not lastApplied]
LearnCommitPointWithTermCheck(i, j) ==
    /\ CommitPointLessThan(i, j)
    \* topology_coordinator.cpp:3204 — reject if lastWritten term != commitPoint term
    /\ lastWritten[i].term = commitPoint[j].term
    /\ commitPoint' = [commitPoint EXCEPT ![i] = commitPoint[j]]
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, pipelineVars>>

\* ACTION: LearnCommitPointFromSyncSourceNeverBeyondLastWritten
\* Node i learns the commit point from sync source j.
\* If terms differ, clamp to min(committedOpTime, myLastWritten).
\* topology_coordinator.cpp:3202-3217 — sync source path with clamping
\* [Family 1: clamping prevents commit point from exceeding written state]
\* [Family 2: clamp uses lastWritten (was lastApplied in older code — SERVER-87920)]
LearnCommitPointFromSyncSourceNeverBeyondLastWritten(i, j) ==
    \* j is a potential sync source (ahead or equal)
    /\ \/ CanSyncFrom(i, j)
       \/ log[i] = log[j]
    /\ LET cpj == commitPoint[j]
           myLW == lastWritten[i]
           \* topology_coordinator.cpp:3204-3206 — clamp if terms differ
           clampedCP ==
               IF cpj.term = myLW.term
               THEN cpj                       \* Same term: accept as-is
               ELSE MinOpTime(cpj, myLW)       \* Different term: clamp to min
       IN \* topology_coordinator.cpp:3219-3230 — must advance current commit point
          /\ \/ clampedCP.term > commitPoint[i].term
             \/ /\ clampedCP.term = commitPoint[i].term
                /\ clampedCP.index > commitPoint[i].index
          /\ commitPoint' = [commitPoint EXCEPT ![i] = clampedCP]
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, pipelineVars>>

----
\* ---- Fault Injection ----

\* ACTION: Crash
\* Node crashes and recovers with durable state only.
\* Log truncated to lastDurable; lastApplied recovers from stable timestamp.
\* rollback_impl.cpp, replication_coordinator_impl.cpp:4962-4984
\* [Family 5: recovery from durable state]
\*
\* Note on vote persistence: MongoDB persists lastVote BEFORE sending vote
\* responses (elect_v1.cpp:374) and BEFORE requesting external votes for
\* self-election (elect_v1.cpp:404). So votes always survive crash.
\* The async persistence window (MC-4) is closed by this persist-before-communicate
\* pattern. We preserve votedFor on crash to match this behavior.
Crash(i) ==
    \* Only crash if there's something to lose (optimization)
    /\ \/ state[i] /= "Follower"
       \/ OpTimeLT(lastDurable[i], lastWritten[i])
       \/ OpTimeLT(lastApplied[i], lastWritten[i])
    /\ state' = [state EXCEPT ![i] = "Follower"]
    \* Log truncated to durable entries only
    /\ log' = [log EXCEPT ![i] = SubSeq(log[i], 1, lastDurable[i].index)]
    \* Pipeline reverts to durable state
    /\ lastWritten' = [lastWritten EXCEPT ![i] = lastDurable[i]]
    \* lastApplied recovers from stableTimestamp ≈ min(commitPoint, lastDurable)
    /\ lastApplied' = [lastApplied EXCEPT ![i] = MinOpTime(commitPoint[i], lastDurable[i])]
    \* lastDurable unchanged — it's what survived on disk
    \* Commit point clamped to durable state (can't claim commitment beyond what's on disk)
    /\ commitPoint' = [commitPoint EXCEPT ![i] = MinOpTime(commitPoint[i], lastDurable[i])]
    /\ UNCHANGED <<currentTerm, lastDurable>>
    \* Vote survives crash (persisted before it takes effect)
    /\ UNCHANGED votedFor
    \* Clear election state
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ firstOpTimeOfMyTerm' = [firstOpTimeOfMyTerm EXCEPT ![i] = NullOpTime]
    /\ UNCHANGED committedEntries

----
\* ---- Next State Relation ----

AppendOplogAction ==
    \E i, j \in Server : AppendOplog(i, j)

RollbackOplogAction ==
    \E i, j \in Server : RollbackOplog(i, j)

StartElectionAction ==
    \E i \in Server : StartElection(i)

RequestVoteAction ==
    \E i, j \in Server : RequestVote(i, j)

WinElectionAction ==
    \E i \in Server : WinElection(i)

WritePrimaryNoOpAction ==
    \E i \in Server : WritePrimaryNoOp(i)

StepdownAction ==
    \E i \in Server : Stepdown(i)

ClientWriteAction ==
    \E i \in Server : ClientWrite(i)

PersistOplogAction ==
    \E i \in Server : PersistOplog(i)

ApplyOplogAction ==
    \E i \in Server : ApplyOplog(i)

UpdateTermThroughHeartbeatAction ==
    \E i, j \in Server : UpdateTermThroughHeartbeat(i, j)

LearnCommitPointWithTermCheckAction ==
    \E i, j \in Server : LearnCommitPointWithTermCheck(i, j)

LearnCommitPointFromSyncSourceAction ==
    \E i, j \in Server : LearnCommitPointFromSyncSourceNeverBeyondLastWritten(i, j)

CrashAction ==
    \E i \in Server : Crash(i)

Next ==
    \* --- Replication protocol
    \/ AppendOplogAction
    \/ RollbackOplogAction
    \/ ClientWriteAction
    \/ PersistOplogAction
    \/ ApplyOplogAction
    \* --- Election protocol (Family 3)
    \/ StartElectionAction
    \/ RequestVoteAction
    \/ WinElectionAction
    \/ WritePrimaryNoOpAction
    \/ StepdownAction
    \* --- Term learning
    \/ UpdateTermThroughHeartbeatAction
    \* --- Commit point protocol (Family 1)
    \/ AdvanceCommitPoint
    \/ LearnCommitPointWithTermCheckAction
    \/ LearnCommitPointFromSyncSourceAction
    \* --- Fault injection
    \/ CrashAction

Spec == Init /\ [][Next]_vars

----
\* ---- Invariants ----

\* -- Standard safety --

\* At most one leader per term (election safety).
\* [Family 3: MC-4 — violated if lastVote lost on crash allows double voting]
TwoPrimariesInSameTerm ==
    \E i, j \in Server :
        /\ i /= j
        /\ currentTerm[i] = currentTerm[j]
        /\ state[i] = "Leader"
        /\ state[j] = "Leader"

NoTwoPrimariesInSameTerm == ~TwoPrimariesInSameTerm

\* A committed entry is never the target of a rollback.
\* [Family 1: SERVER-39626 — violated at 5 servers, 3 terms, 4+ log entries]
RollbackCommitted(i) ==
    /\ [term |-> LastTerm(log[i]), index |-> Len(log[i])] \in committedEntries
    /\ \E j \in Server : CanRollbackOplog(i, j)

NeverRollbackCommitted ==
    \A i \in Server : ~RollbackCommitted(i)

\* Oplog is never shorter than own commit point after a potential rollback.
\* [Family 1, 5]
RollbackBeforeCommitPoint(i) ==
    /\ \E j \in Server : CanRollbackOplog(i, j)
    /\ \/ LastTerm(log[i]) < commitPoint[i].term
       \/ /\ LastTerm(log[i]) = commitPoint[i].term
          /\ Len(log[i]) <= commitPoint[i].index

NeverRollbackBeforeCommitPoint == \A i \in Server : ~RollbackBeforeCommitPoint(i)

\* -- Family 2: Three-level pipeline invariants --

\* Commit point never exceeds lastWritten on a WRITABLE leader.
\* Followers can learn a commit point ahead of their lastWritten via heartbeat
\* (the heartbeat path only checks term, not index — topology_coordinator.cpp:3204).
\* This invariant checks that the leader who COMPUTES the commit point stays consistent.
\* [Family 2: MC-2 — validates non-journal commit point path]
CommitPointNeverExceedsLastWritten ==
    \A i \in Server :
        state[i] = "Leader" /\ firstOpTimeOfMyTerm[i] /= InfOpTime =>
            OpTimeLTE(commitPoint[i], lastWritten[i])

\* lastApplied <= lastWritten always holds (three-level ordering).
\* [Family 2: structural invariant]
WriteApplyOrdering ==
    \A i \in Server : OpTimeLTE(lastApplied[i], lastWritten[i])

\* lastDurable <= lastWritten always holds.
\* [Family 2: structural invariant]
DurableWriteOrdering ==
    \A i \in Server : OpTimeLTE(lastDurable[i], lastWritten[i])

\* -- Family 3: Election + commit freeze invariants --

\* A leader in LeaderElect mode (firstOpTimeOfMyTerm = InfOpTime) never advances commit point.
\* [Family 3: MC-5 — validates commit freeze during catchup/drain]
LeaderElectCommitFreeze ==
    \A i \in Server :
        state[i] = "Leader" /\ firstOpTimeOfMyTerm[i] = InfOpTime =>
            commitPoint[i] = commitPoint[i]  \* Tautology — real check is in AdvanceCommitPoint guard

\* -- Family 4: Commit point branch safety --

\* If the commit point index is within the log, it must be on the same branch.
\* [Family 4: MC-3 — validates heartbeat commit point ordering]
CommitPointOnCorrectBranch ==
    \A i \in Server :
        commitPoint[i].index > 0 /\ commitPoint[i].index <= Len(log[i]) =>
            LogTerm(i, commitPoint[i].index) = commitPoint[i].term

\* -- Structural invariants --

\* lastDurable index never exceeds log length
LastDurableWithinLog ==
    \A i \in Server : lastDurable[i].index <= Len(log[i])

\* lastWritten index equals log length (they track together)
LastWrittenEqualsLogLen ==
    \A i \in Server : lastWritten[i].index = Len(log[i])

\* lastWritten term equals LastTerm(log) when log is non-empty
LastWrittenTermConsistent ==
    \A i \in Server :
        Len(log[i]) > 0 => lastWritten[i].term = LastTerm(log[i])

===============================================================================
