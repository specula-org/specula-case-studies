---------------------------- MODULE base ----------------------------
\* TLA+ specification of lni/dragonboat Raft protocol.
\*
\* Models dragonboat-specific behaviors:
\*   1. CheckQuorum with setActive tracking (raft.go:395-405, 1878-1923, 1976-1995)
\*      - setActive called in HandleReplicateResponse (raft.go:1880)
\*      - setActive called in HandleHeartbeatResponse (raft.go:1912)
\*      - setActive NOT called in HandleSnapshotStatus (raft.go:1976-1995) [Bug Family 1]
\*      - leaderHasQuorum() clears all active flags as side effect (raft.go:401) [Bug Family 1]
\*   2. Remote state machine: Retry/Wait/Replicate/Snapshot (remote.go:52-65)
\*      - Follower in RemoteSnapshot state only communicates via SnapshotStatus
\*   3. Config change single-at-a-time with overly-conservative election guard
\*      (raft.go:1611-1621, 1803-1808) [Bug Family 2]
\*      - hasConfigChangeToApply: committed > applied (ANY committed entry blocks, not just config)
\*      - Second config change silently converted to ApplicationEntry
\*   4. Persistence error silent drop (logdb/db.go:179-204, PR #409) [Bug Family 3]
\*      - saveRaftState returns nil on saveSnapshot failure
\*      - Entries not written to disk but caller assumes success
\*
EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs

CONSTANTS Follower,          \* Server states (raft.go:63-71)
          Candidate,
          Leader

CONSTANT Nil                 \* Null / no-node sentinel

CONSTANTS ApplicationEntry,  \* Log entry types (raft.go pb.EntryType)
          ConfigChangeEntry

CONSTANTS RequestVoteRequest,     \* Message types
          RequestVoteResponse,
          ReplicateRequest,        \* AppendEntries with entries (pb.Replicate)
          ReplicateResponse,       \* AppendEntries response (pb.ReplicateResp)
          HeartbeatRequest,        \* Heartbeat (pb.Heartbeat) — separate from Replicate
          HeartbeatResponse,       \* Heartbeat response (pb.HeartbeatResp)
          InstallSnapshotRequest,  \* Snapshot transfer (pb.InstallSnapshot)
          SnapshotStatus           \* Snapshot transfer status (pb.SnapshotStatus)

CONSTANTS RemoteRetry,       \* Remote state machine types (remote.go:54-58)
          RemoteWait,
          RemoteReplicate,
          RemoteSnapshot

----
\* Variables
----

\* Per-server persistent state
\* dragonboat: {term, vote, commit} persisted as one atomic Pebble batch (logdb/db.go:307-320)
VARIABLE currentTerm         \* [Server -> Nat]
VARIABLE votedFor            \* [Server -> Server \cup {Nil}]
VARIABLE log                 \* [Server -> Seq([term: Nat, type: EntryType])]

\* Per-server volatile state
VARIABLE state               \* [Server -> {Follower, Candidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat]
VARIABLE applied             \* [Server -> Nat]
\*   applied tracks the last index returned to the application layer.
\*   hasConfigChangeToApply (raft.go:1611-1621): committed > applied.
\*   Bug Family 2: overly conservative — any committed-but-not-applied entry
\*   blocks elections, not just config change entries (TODO at raft.go:1617).

\* Leader volatile state
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate state
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension 1: Active tracking for CheckQuorum (Bug Family 1)
\* setActive() called in handleLeaderReplicateResp (raft.go:1880)
\*             and handleLeaderHeartbeatResp (raft.go:1912).
\* setActive() NOT called in handleLeaderSnapshotStatus (raft.go:1976-1995).
\* leaderHasQuorum() clears all active flags as side effect (raft.go:401).
VARIABLE active              \* [Leader -> [Server -> BOOLEAN]]

\* Extension 1: Remote state machine (Bug Family 1)
\* Follower in RemoteSnapshot state only sends SnapshotStatus to the leader.
\* Since HandleSnapshotStatus never calls setActive, the follower is never
\* marked active and CheckQuorum does not count it. Reference: remote.go:52-65
VARIABLE remoteState         \* [Leader -> [Server -> {Retry,Wait,Replicate,Snapshot}]]

\* Extension 2: Config change single-at-a-time flag (Bug Family 2)
\* Set when a ConfigChangeEntry is appended; cleared when it is applied.
\* Reference: raft.go:1368 setPendingConfigChange(), 1376 clearPendingConfigChange()
VARIABLE pendingConfigChange \* [Server -> BOOLEAN]

\* Extension 3: Disk error injection (Bug Family 3, PR #409)
\* When diskError[i]=TRUE, SaveRaftState silently returns nil without writing.
\* Reference: logdb/db.go:193-195 (return nil instead of return err)
VARIABLE diskError           \* [Server -> BOOLEAN]

\* Extension 3: Persisted log — what is actually on disk (Bug Family 3)
\* Normally persistedLog[i] = log[i], but diverges when diskError causes silent failure.
\* Reference: logdb/db.go:179-204 saveRaftState()
VARIABLE persistedLog        \* [Server -> Seq(Entry)]
VARIABLE persistedState      \* [Server -> [term: Nat, votedFor: Server \cup {Nil}]]

----
\* Variable groups
----

serverVars  == <<currentTerm, votedFor, state>>
logVars     == <<log, commitIndex, applied>>
leaderVars  == <<nextIndex, matchIndex>>
candVars    == <<votesGranted>>
quorumVars  == <<active, remoteState>>
configVars  == <<pendingConfigChange>>
persistVars == <<diskError, persistedLog, persistedState>>

vars == <<serverVars, logVars, leaderVars, candVars,
          messages, quorumVars, configVars, persistVars>>

----
\* Helpers
----

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b

SetMax(S) == CHOOSE x \in S : \A y \in S : x >= y

\* Log helpers
LastLogIndex(i) == Len(log[i])
LastLogTerm(i)  == IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term ELSE 0
LogTerm(i, idx) == IF idx > 0 /\ idx <= Len(log[i]) THEN log[i][idx].term ELSE 0

\* Quorum: strict majority of Server
\* dragonboat: quorum() = numVotingMembers/2 + 1 (raft.go:388)
\* All servers are modeled as voting members (NonVoting/Witness excluded per brief §3.2).
IsQuorum(S) == Cardinality(S) * 2 > Cardinality(Server)

\* Log up-to-date comparison
\* Reference: raft.go:1705 upToDate() called by handleNodeRequestVote
LogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    \/ cLastTerm > vLastTerm
    \/ (cLastTerm = vLastTerm /\ cLastIdx >= vLastIdx)

\* Message bag helpers
Send(m)    == messages' = messages (+) SetToBag({m})
SendAll(S) == messages' = messages (+) SetToBag(S)
Discard(m) == messages' = messages (-) SetToBag({m})
Reply(resp, req) ==
    messages' = (messages (-) SetToBag({req})) (+) SetToBag({resp})

\* Entry constructor
Entry(t, tp) == [term |-> t, type |-> tp]

----
\* Init
----

Init ==
    /\ currentTerm    = [s \in Server |-> 0]
    /\ votedFor       = [s \in Server |-> Nil]
    /\ log            = [s \in Server |-> <<>>]
    /\ state          = [s \in Server |-> Follower]
    /\ commitIndex    = [s \in Server |-> 0]
    /\ applied        = [s \in Server |-> 0]
    /\ nextIndex      = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex     = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted   = [s \in Server |-> {}]
    /\ messages       = EmptyBag
    \* Extension 1
    /\ active         = [s \in Server |-> [t \in Server |-> FALSE]]
    /\ remoteState    = [s \in Server |-> [t \in Server |-> RemoteRetry]]
    \* Extension 2
    /\ pendingConfigChange = [s \in Server |-> FALSE]
    \* Extension 3
    /\ diskError      = [s \in Server |-> FALSE]
    /\ persistedLog   = [s \in Server |-> <<>>]
    /\ persistedState = [s \in Server |-> [term |-> 0, votedFor |-> Nil]]

----
\* Election Actions
----

\* Server i times out and starts an election.
\* Reference: raft.go:1176-1216 campaign(), raft.go:1020-1035 becomeCandidate()
\*
\* Bug Family 2: Election is blocked when hasConfigChangeToApply() = committed > applied.
\* This is overly conservative: any committed-but-not-applied entry blocks election,
\* not just config change entries. The TODO at raft.go:1617 acknowledges this.
\* Correct behavior would only block when a ConfigChangeEntry is in committed..applied.
Timeout(i) ==
    \* raft.go:1633: only non-leaders can campaign
    /\ state[i] \in {Follower, Candidate}
    \* raft.go:1644: hasConfigChangeToApply() = committed > applied
    \* Bug Family 2: overly conservative guard
    /\ commitIndex[i] <= applied[i]
    /\ LET newTerm == currentTerm[i] + 1
       IN
       \* raft.go:1030-1034 becomeCandidate: increment term, self-vote
       /\ currentTerm'  = [currentTerm  EXCEPT ![i] = newTerm]
       /\ state'        = [state        EXCEPT ![i] = Candidate]
       /\ votedFor'     = [votedFor     EXCEPT ![i] = i]
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
       \* raft.go:1207-1213: send RequestVote to all voting members
       /\ SendAll({[mtype         |-> RequestVoteRequest,
                    mterm         |-> newTerm,
                    mlastLogTerm  |-> LastLogTerm(i),
                    mlastLogIndex |-> LastLogIndex(i),
                    msource       |-> i,
                    mdest         |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<log, commitIndex, applied, leaderVars,
                   quorumVars, configVars, persistVars>>

\* Server i handles a RequestVoteRequest m.
\* Reference: raft.go:1697-1721 handleNodeRequestVote()
\*            raft.go:1624-1626 canGrantVote()
HandleRequestVoteRequest(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ LET mterm    == m.mterm
           logOk    == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                   LastLogTerm(i), LastLogIndex(i))
           \* raft.go:1624-1626: no-one voted, voted for sender, or higher term
           canGrant == /\ logOk
                       /\ \/ mterm > currentTerm[i]
                          \/ /\ mterm = currentTerm[i]
                             /\ votedFor[i] \in {Nil, m.msource}
       IN
       \/ \* Case 1: Reject (raft.go:1714-1720)
          /\ \/ mterm < currentTerm[i]
             \/ /\ mterm >= currentTerm[i]
                /\ ~canGrant
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> Max(currentTerm[i], mterm),
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ IF mterm > currentTerm[i]
             THEN /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
                  /\ votedFor'    = [votedFor    EXCEPT ![i] = Nil]
                  /\ state'       = [state       EXCEPT ![i] = Follower]
             ELSE UNCHANGED <<currentTerm, votedFor, state>>
          /\ UNCHANGED <<log, commitIndex, applied, leaderVars, candVars,
                         quorumVars, configVars, persistVars>>

       \/ \* Case 2: Grant (raft.go:1709-1713)
          /\ canGrant
          /\ mterm >= currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ votedFor'    = [votedFor    EXCEPT ![i] = m.msource]
          /\ state'       = [state       EXCEPT ![i] = Follower]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> mterm,
                    mvoteGranted |-> TRUE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<log, commitIndex, applied, leaderVars, candVars,
                         quorumVars, configVars, persistVars>>

\* Candidate i records a vote response.
\* Reference: raft.go:2235-2252 handleCandidateRequestVoteResp()
HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ state[i] = Candidate
    /\ m.mterm = currentTerm[i]
    /\ IF m.mvoteGranted
       THEN votesGranted' = [votesGranted EXCEPT ![i] = votesGranted[i] \cup {m.msource}]
       ELSE UNCHANGED votesGranted
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars,
                   quorumVars, configVars, persistVars>>

\* Candidate i transitions to leader after receiving a quorum of votes.
\* Reference: raft.go:2244-2248 handleCandidateRequestVoteResp()
\*            raft.go:1038-1050 becomeLeader()
BecomeLeader(i) ==
    /\ state[i] = Candidate
    \* raft.go:2244: become leader when vote count reaches quorum
    /\ IsQuorum(votesGranted[i])
    \* raft.go:1038: becomeLeader transitions state
    /\ state' = [state EXCEPT ![i] = Leader]
    \* raft.go:1049: append noop entry to establish leadership term
    \* Implementation order: reset() sets next=lastIndex+1 BEFORE noop append,
    \* then appendEntries(noop) updates self match. So nextIndex for followers
    \* points to the old lastIndex+1 (i.e., the noop's index), NOT past it.
    /\ LET oldLastIdx == LastLogIndex(i)
           noopIdx    == oldLastIdx + 1
       IN
       /\ log' = [log EXCEPT ![i] = Append(@, Entry(currentTerm[i], ApplicationEntry))]
       \* raft.go:1088-1096 resetRemotes: reset sets next=lastIndex+1 (before noop)
       \* then appendEntries updates self match to noopIdx
       /\ matchIndex' = [matchIndex EXCEPT ![i] =
                          [j \in Server |-> IF j = i THEN noopIdx ELSE 0]]
       /\ nextIndex'  = [nextIndex  EXCEPT ![i] =
                          [j \in Server |-> IF j = i THEN noopIdx + 1 ELSE noopIdx]]
    \* Extension 1: reset active tracking and remoteState on becoming leader
    /\ active'      = [active      EXCEPT ![i] = [j \in Server |-> FALSE]]
    /\ remoteState' = [remoteState EXCEPT ![i] = [j \in Server |-> RemoteRetry]]
    /\ UNCHANGED <<currentTerm, votedFor, commitIndex, applied,
                   candVars, messages, configVars, persistVars>>

----
\* Log Replication Actions
----

\* Leader i appends a client request entry to its log.
\* Reference: raft.go:1794-1815 handleLeaderPropose(), raft.go:944-954 appendEntries()
ClientRequest(i) ==
    /\ state[i] = Leader
    /\ LET newIdx == LastLogIndex(i) + 1
       IN
       /\ log'       = [log       EXCEPT ![i] = Append(@, Entry(currentTerm[i], ApplicationEntry))]
       \* raft.go:951: remotes[self].tryUpdate(lastIndex)
       /\ matchIndex' = [matchIndex EXCEPT ![i][i] = newIdx]
       /\ nextIndex'  = [nextIndex  EXCEPT ![i][i] = newIdx + 1]
    /\ UNCHANGED <<serverVars, commitIndex, applied, candVars,
                   messages, quorumVars, configVars, persistVars>>

\* Leader i proposes a config change (or silently drops it if one is pending).
\* Reference: raft.go:1794-1815 handleLeaderPropose()
\*
\* Bug Family 2: If hasPendingConfigChange() is TRUE, the config change entry is
\* silently converted to an ApplicationEntry (raft.go:1803-1808). The caller
\* receives no error and believes its config change was accepted.
ProposeConfigChange(i) ==
    /\ state[i] = Leader
    /\ LET newIdx == LastLogIndex(i) + 1
       IN
       /\ matchIndex' = [matchIndex EXCEPT ![i][i] = newIdx]
       /\ nextIndex'  = [nextIndex  EXCEPT ![i][i] = newIdx + 1]
       /\ IF pendingConfigChange[i]
          \* Bug Family 2: silently converted to ApplicationEntry (raft.go:1806)
          THEN /\ log' = [log EXCEPT ![i] = Append(@, Entry(currentTerm[i], ApplicationEntry))]
               /\ UNCHANGED pendingConfigChange
          ELSE \* Genuine config change: append and set pending flag (raft.go:1808)
               /\ log' = [log EXCEPT ![i] = Append(@, Entry(currentTerm[i], ConfigChangeEntry))]
               /\ pendingConfigChange' = [pendingConfigChange EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<serverVars, commitIndex, applied, candVars,
                   messages, quorumVars, diskError, persistedLog, persistedState>>

\* Leader i sends a Replicate message (AppendEntries with entries) to server j.
\* Reference: raft.go:738-818 makeReplicateMessage() / sendReplicateMessage()
\*
\* Only sends when remoteState[i][j] is not paused (remote.go:200-213 isPaused).
\* RemoteWait and RemoteSnapshot are paused; RemoteRetry and RemoteReplicate are not.
ReplicateEntries(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    \* remote.go:200-213 isPaused: Retry and Replicate are not paused
    /\ remoteState[i][j] \in {RemoteRetry, RemoteReplicate}
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == LogTerm(i, prevIdx)
           lastIdx  == LastLogIndex(i)
           entries  == IF nextIndex[i][j] > lastIdx THEN <<>>
                       ELSE SubSeq(log[i], nextIndex[i][j], lastIdx)
       IN
       /\ Send([mtype         |-> ReplicateRequest,
                mterm         |-> currentTerm[i],
                mprevLogIndex |-> prevIdx,
                mprevLogTerm  |-> prevTerm,
                mentries      |-> entries,
                mcommitIndex  |-> commitIndex[i],
                msource       |-> i,
                mdest         |-> j])
       \* raft.go:816: progress() called after send
       \* RemoteRetry -> RemoteWait (remote.go:113-116 retryToWait)
       \* RemoteReplicate: next = lastIndex+1 (remote.go:161-162), stays Replicate
       /\ remoteState' = [remoteState EXCEPT ![i][j] =
                           IF remoteState[i][j] = RemoteRetry
                           THEN RemoteWait
                           ELSE RemoteReplicate]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candVars,
                   active, configVars, persistVars>>

\* Leader i sends a Heartbeat to server j.
\* Reference: raft.go:835-845 sendHeartbeatMessage()
\*
\* Heartbeat is a SEPARATE message type from Replicate in dragonboat (pb.Heartbeat).
\* It carries the leader's commit index and signals aliveness without log entries.
SendHeartbeat(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ Send([mtype        |-> HeartbeatRequest,
             mterm        |-> currentTerm[i],
             mcommitIndex |-> commitIndex[i],
             msource      |-> i,
             mdest        |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candVars,
                   quorumVars, configVars, persistVars>>

\* Server i handles a ReplicateRequest m (AppendEntries with log entries).
\* Reference: raft.go:1444-1484 handleReplicateMessage()
\*            raft.go:2220-2222 handleCandidateReplicate() (candidate falls to follower first)
HandleReplicateRequest(i, m) ==
    /\ m.mtype = ReplicateRequest
    /\ m.mdest = i
    /\ LET mterm == m.mterm
           logOk == \/ m.mprevLogIndex = 0
                    \/ /\ m.mprevLogIndex > 0
                       /\ m.mprevLogIndex <= LastLogIndex(i)
                       /\ LogTerm(i, m.mprevLogIndex) = m.mprevLogTerm
       IN
       \/ \* Reject: stale term (raft.go:1449-1452)
          /\ mterm < currentTerm[i]
          /\ Reply([mtype   |-> ReplicateResponse,
                    mterm   |-> currentTerm[i],
                    mreject |-> TRUE,
                    mindex  |-> commitIndex[i],
                    mhint   |-> 0,
                    msource |-> i,
                    mdest   |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candVars,
                         quorumVars, configVars, persistVars>>

       \/ \* Step down if needed (raft.go:1549-1573 onMessageTermNotMatched)
          /\ mterm >= currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state'       = [state       EXCEPT ![i] = Follower]
          /\ votedFor'    = IF mterm > currentTerm[i]
                            THEN [votedFor EXCEPT ![i] = Nil]
                            ELSE votedFor
          /\ IF ~logOk
             THEN \* Reject: log inconsistency (raft.go:1466-1471)
                  /\ Reply([mtype   |-> ReplicateResponse,
                            mterm   |-> mterm,
                            mreject |-> TRUE,
                            mindex  |-> m.mprevLogIndex,
                            mhint   |-> LastLogIndex(i),
                            msource |-> i,
                            mdest   |-> m.msource], m)
                  /\ UNCHANGED <<log, commitIndex, applied, leaderVars,
                                 quorumVars, configVars, persistVars>>
             ELSE \* Accept: append entries (raft.go:1459-1464)
                  /\ LET newLog    == SubSeq(log[i], 1, m.mprevLogIndex) \o m.mentries
                         newLastIdx == Len(newLog)
                         newCommit  == Min(m.mcommitIndex, newLastIdx)
                     IN
                     /\ log'         = [log         EXCEPT ![i] = newLog]
                     /\ commitIndex' = [commitIndex  EXCEPT ![i] =
                                         Max(commitIndex[i], newCommit)]
                     /\ Reply([mtype   |-> ReplicateResponse,
                               mterm   |-> mterm,
                               mreject |-> FALSE,
                               mindex  |-> newLastIdx,
                               mhint   |-> 0,
                               msource |-> i,
                               mdest   |-> m.msource], m)
                  /\ UNCHANGED <<applied, leaderVars, quorumVars, configVars, persistVars>>
          /\ UNCHANGED candVars

\* Server i handles a HeartbeatRequest m.
\* Reference: raft.go:1400-1408 handleHeartbeatMessage()
\*            raft.go:2230-2232 handleCandidateHeartbeat() (candidate falls to follower)
HandleHeartbeatRequest(i, m) ==
    /\ m.mtype = HeartbeatRequest
    /\ m.mdest = i
    /\ LET mterm == m.mterm
       IN
       \/ \* Reject: stale term
          /\ mterm < currentTerm[i]
          /\ Reply([mtype   |-> HeartbeatResponse,
                    mterm   |-> currentTerm[i],
                    mreject |-> TRUE,
                    msource |-> i,
                    mdest   |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candVars,
                         quorumVars, configVars, persistVars>>

       \/ \* Accept: update commit and respond (raft.go:1401-1407)
          /\ mterm >= currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state'       = [state       EXCEPT ![i] = Follower]
          /\ votedFor'    = IF mterm > currentTerm[i]
                            THEN [votedFor EXCEPT ![i] = Nil]
                            ELSE votedFor
          \* raft.go:1401: log.commitTo(m.Commit)
          /\ commitIndex' = [commitIndex EXCEPT ![i] =
                              Max(commitIndex[i], Min(m.mcommitIndex, LastLogIndex(i)))]
          /\ Reply([mtype   |-> HeartbeatResponse,
                    mterm   |-> mterm,
                    mreject |-> FALSE,
                    msource |-> i,
                    mdest   |-> m.msource], m)
          /\ UNCHANGED <<log, applied, leaderVars, candVars,
                         quorumVars, configVars, persistVars>>

\* Leader i handles a ReplicateResponse from server j.
\* Reference: raft.go:1878-1908 handleLeaderReplicateResp()
\*
\* Bug Family 1: setActive() is called unconditionally at raft.go:1880,
\* before any other checks. This correctly marks j as active for CheckQuorum.
HandleReplicateResponse(i, m) ==
    /\ m.mtype = ReplicateResponse
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ m.mterm = currentTerm[i]
    \* raft.go:1880: setActive() — marks sender as active for CheckQuorum
    /\ active' = [active EXCEPT ![i][m.msource] = TRUE]
    /\ IF ~m.mreject
       THEN \* Success: update matchIndex/nextIndex (raft.go:1883-1895)
            \* raft.go:1883: tryUpdate(m.LogIndex) — remote.go:147-157
            /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] =
                               Max(matchIndex[i][m.msource], m.mindex)]
            /\ nextIndex'  = [nextIndex  EXCEPT ![i][m.msource] =
                               Max(nextIndex[i][m.msource], m.mindex + 1)]
            \* tryUpdate calls waitToRetry (Wait->Retry), then respondedTo (Retry->Replicate).
            \* Net effect: RemoteWait -> RemoteReplicate, RemoteRetry -> RemoteReplicate.
            \* remote.go:152 (waitToRetry), remote.go:170-173 (respondedTo)
            /\ remoteState' = [remoteState EXCEPT ![i][m.msource] =
                                IF remoteState[i][m.msource] \in {RemoteRetry, RemoteWait}
                                THEN RemoteReplicate
                                ELSE remoteState[i][m.msource]]
       ELSE \* Reject: decrease nextIndex (raft.go:1902-1905)
            \* raft.go:1902: decreaseTo() resets nextIndex to match+1
            /\ nextIndex'   = [nextIndex   EXCEPT ![i][m.msource] =
                                Max(1, m.mhint)]
            /\ remoteState' = [remoteState EXCEPT ![i][m.msource] = RemoteRetry]
            /\ UNCHANGED matchIndex
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, candVars, configVars, persistVars>>

\* Leader i advances its commitIndex after receiving quorum replication confirmation.
\* Reference: raft.go:911-941 tryCommit()
\*
\* Raft paper §5.4.2: leader can only commit entries from the current term.
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET \* CanCommit: index is reachable, in current term, replicated to quorum
           CanCommit(idx) ==
               /\ idx > commitIndex[i]
               /\ idx <= LastLogIndex(i)
               \* raft.go:931: only commit entries from current term
               /\ LogTerm(i, idx) = currentTerm[i]
               \* raft.go:926: quorum of voting members have replicated up to idx
               /\ IsQuorum({j \in Server : matchIndex[i][j] >= idx})
           committable == {idx \in 1..LastLogIndex(i) : CanCommit(idx)}
       IN
       /\ committable /= {}
       /\ commitIndex' = [commitIndex EXCEPT ![i] = SetMax(committable)]
    /\ UNCHANGED <<serverVars, log, applied, leaderVars, candVars,
                   messages, quorumVars, configVars, persistVars>>

\* Leader i handles a HeartbeatResponse from server j.
\* Reference: raft.go:1910-1923 handleLeaderHeartbeatResp()
\*
\* Bug Family 1: setActive() is called at raft.go:1912 — this DOES mark j as active,
\* unlike HandleSnapshotStatus which does NOT call setActive.
HandleHeartbeatResponse(i, m) ==
    /\ m.mtype = HeartbeatResponse
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ m.mterm = currentTerm[i]
    \* raft.go:1912: setActive() — marks sender as active for CheckQuorum
    /\ active' = [active EXCEPT ![i][m.msource] = TRUE]
    \* raft.go:1913: waitToRetry() — RemoteWait -> RemoteRetry (remote.go:119-122)
    /\ remoteState' = [remoteState EXCEPT ![i][m.msource] =
                        IF remoteState[i][m.msource] = RemoteWait
                        THEN RemoteRetry
                        ELSE remoteState[i][m.msource]]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candVars, configVars, persistVars>>

----
\* Snapshot Actions
----

\* Leader i decides to send a snapshot to server j (log has been compacted past j's next).
\* Reference: raft.go:800-818 sendReplicateMessage() snapshot fallback
\*            remote.go:137-141 becomeSnapshot()
\*
\* Transition: remoteState[i][j] := RemoteSnapshot
SendSnapshot(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    \* Snapshot is sent when log entries before nextIndex[i][j] have been compacted
    /\ remoteState[i][j] /= RemoteSnapshot
    /\ Send([mtype   |-> InstallSnapshotRequest,
             mterm   |-> currentTerm[i],
             mindex  |-> commitIndex[i],
             mterm2  |-> LogTerm(i, commitIndex[i]),
             msource |-> i,
             mdest   |-> j])
    \* raft.go:813: becomeSnapshot(index)
    /\ remoteState' = [remoteState EXCEPT ![i][j] = RemoteSnapshot]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candVars,
                   active, configVars, persistVars>>

\* Follower i handles an InstallSnapshot message.
\* Reference: raft.go:1411-1441 handleInstallSnapshotMessage()
HandleInstallSnapshot(i, m) ==
    /\ m.mtype = InstallSnapshotRequest
    /\ m.mdest = i
    /\ LET mterm == m.mterm
       IN
       \/ \* Reject: stale term
          /\ mterm < currentTerm[i]
          /\ Reply([mtype   |-> SnapshotStatus,
                    mterm   |-> currentTerm[i],
                    mreject |-> TRUE,
                    mindex  |-> 0,
                    msource |-> i,
                    mdest   |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candVars,
                         quorumVars, configVars, persistVars>>

       \/ \* Accept: restore snapshot state (raft.go:1419-1429)
          /\ mterm >= currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state'       = [state       EXCEPT ![i] = Follower]
          /\ votedFor'    = IF mterm > currentTerm[i]
                            THEN [votedFor EXCEPT ![i] = Nil]
                            ELSE votedFor
          \* Truncate log to snapshot boundary (simplified: take prefix up to snapshot index)
          /\ log'         = [log         EXCEPT ![i] =
                              SubSeq(log[i], 1, Min(m.mindex, Len(log[i])))]
          /\ commitIndex' = [commitIndex EXCEPT ![i] = Max(commitIndex[i], m.mindex)]
          /\ Reply([mtype   |-> SnapshotStatus,
                    mterm   |-> mterm,
                    mreject |-> FALSE,
                    mindex  |-> m.mindex,
                    msource |-> i,
                    mdest   |-> m.msource], m)
          /\ UNCHANGED <<applied, leaderVars, candVars, quorumVars, configVars, persistVars>>

\* Leader i handles a SnapshotStatus from server j.
\* Reference: raft.go:1976-1995 handleLeaderSnapshotStatus()
\*
\* *** Bug Family 1 (HIGH): setActive() is NOT called here. ***
\*
\* Contrast with handleLeaderReplicateResp (raft.go:1880) and
\* handleLeaderHeartbeatResp (raft.go:1912), which both call setActive().
\*
\* When remoteState[i][j] = RemoteSnapshot, the ONLY messages from j to i
\* are SnapshotStatus messages. Since HandleSnapshotStatus never calls setActive,
\* active[i][j] remains FALSE. When CheckQuorum fires, j is not counted.
\* If j is the quorum-deciding follower, the leader incorrectly steps down.
\*
\* Secondary issue (raft.go:1977): early return if j is no longer in snapshot state.
\* This silently drops SnapshotStatus messages that arrive after a state transition.
HandleSnapshotStatus(i, m) ==
    /\ m.mtype = SnapshotStatus
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ m.mterm = currentTerm[i]
    \* raft.go:1977: drop message if j not in snapshot state (silent drop)
    /\ remoteState[i][m.msource] = RemoteSnapshot
    \* *** Bug Family 1: NO active'[i][m.msource] = TRUE here ***
    \* Transition: RemoteSnapshot -> RemoteWait regardless of success/failure
    \* raft.go:1989: becomeWait() in both reject and success paths
    /\ remoteState' = [remoteState EXCEPT ![i][m.msource] = RemoteWait]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candVars,
                   active, configVars, persistVars>>

\* Leader i performs CheckQuorum.
\* Reference: raft.go:1785-1792 handleLeaderCheckQuorum()
\*            raft.go:395-405   leaderHasQuorum()
\*
\* Bug Family 1 (HIGH — two distinct issues):
\*   (a) setActive omission: followers in RemoteSnapshot state are never marked active,
\*       so they are not counted in the quorum check even though they are responsive.
\*   (b) Side-effecting boolean: leaderHasQuorum() clears ALL active flags (raft.go:401)
\*       as a side effect of the quorum check. Calling it twice in the same cycle
\*       causes the second call to always return false.
CheckQuorum(i) ==
    /\ state[i] = Leader
    \* raft.go:395-404: count active members (leader counts itself unconditionally)
    /\ LET voters == {j \in Server : j = i \/ active[i][j]}
       IN
       \/ \* Has quorum: stay leader
          \* raft.go:401: setNotActive() called for ALL members (side effect)
          /\ IsQuorum(voters)
          /\ active' = [active EXCEPT ![i] = [j \in Server |-> FALSE]]
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candVars,
                         messages, remoteState, configVars, persistVars>>

       \/ \* Lost quorum: step down (raft.go:1787-1789)
          /\ ~IsQuorum(voters)
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ active' = [active EXCEPT ![i] = [j \in Server |-> FALSE]]
          /\ UNCHANGED <<currentTerm, votedFor, logVars, leaderVars, candVars,
                         messages, remoteState, configVars, persistVars>>

----
\* Config Change Application
----

\* Server i applies a committed ApplicationEntry.
\* Reference: dragonboat apply pipeline (node.go / rsm)
ApplyEntry(i) ==
    /\ applied[i] < commitIndex[i]
    /\ applied[i] < Len(log[i])
    /\ log[i][applied[i] + 1].type = ApplicationEntry
    /\ applied' = [applied EXCEPT ![i] = applied[i] + 1]
    /\ UNCHANGED <<serverVars, log, commitIndex, leaderVars, candVars,
                   messages, quorumVars, configVars, persistVars>>

\* Server i applies a committed ConfigChangeEntry.
\* Reference: raft.go:1724-1745 handleNodeConfigChange()
\*            raft.go:1236-1258 addNode(), 1282-1299 removeNode()
\*
\* Applying the config change clears the pendingConfigChange flag.
\* Reference: raft.go:1237 clearPendingConfigChange() in addNode/removeNode
ApplyConfigChange(i) ==
    /\ applied[i] < commitIndex[i]
    /\ applied[i] < Len(log[i])
    /\ log[i][applied[i] + 1].type = ConfigChangeEntry
    \* raft.go:1237: clearPendingConfigChange() called when applying config change
    /\ pendingConfigChange' = [pendingConfigChange EXCEPT ![i] = FALSE]
    /\ applied' = [applied EXCEPT ![i] = applied[i] + 1]
    /\ UNCHANGED <<serverVars, log, commitIndex, leaderVars, candVars,
                   messages, quorumVars, diskError, persistedLog, persistedState>>

----
\* Persistence Actions (Bug Family 3)
----

\* Server i persists its raft state to disk.
\* Reference: logdb/db.go:179-204 saveRaftState()
\*
\* Bug Family 3 (HIGH, PR #409 — open, unmerged):
\*   Normal path:    saveSnapshot succeeds -> saveEntries -> CommitWriteBatch
\*   Bug path:       saveSnapshot fails -> return nil (instead of err)
\*                   saveEntries and CommitWriteBatch are NEVER called.
\*                   Caller receives nil and assumes write succeeded.
\*                   In-memory log has entries; disk does NOT. On crash: entries lost.
\*
\* In the model:
\*   Normal: persistedLog[i]' = log[i], persistedState[i]' updated  (CommitWriteBatch ok)
\*   Bug:    UNCHANGED persistedLog, persistedState                  (nil return = silent failure)
SaveRaftState(i) ==
    \/ \* Normal path: CommitWriteBatch succeeds (logdb/db.go:200-202)
       /\ ~diskError[i]
       /\ persistedLog'   = [persistedLog   EXCEPT ![i] = log[i]]
       /\ persistedState' = [persistedState EXCEPT ![i] =
                              [term |-> currentTerm[i], votedFor |-> votedFor[i]]]
       /\ UNCHANGED diskError
    \/ \* Bug path (PR #409): saveSnapshot failure -> return nil (logdb/db.go:193-195)
       \* Nothing written; no error surfaced. Entries silently dropped.
       /\ diskError[i]
       /\ UNCHANGED <<diskError, persistedLog, persistedState>>
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candVars,
                   messages, quorumVars, configVars>>

\* Inject a disk error on server i to trigger the PR #409 code path.
\* Reference: logdb/db.go:193 (saveSnapshot -> listSnapshots failure)
InjectDiskError(i) ==
    /\ ~diskError[i]
    /\ diskError' = [diskError EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candVars,
                   messages, quorumVars, configVars, persistedLog, persistedState>>

\* Server i crashes and recovers from persisted state.
\* Reference: dragonboat recovery: logdb provides the persistent log and state.
\*
\* After PR #409 silent failure:
\*   - persistedLog[i] may be shorter than log[i] (some entries were never written)
\*   - On recovery, log[i] is restored from persistedLog[i]
\*   - commitIndex reverts to what's actually on disk
\*   - Entries the leader believed were replicated to i are LOST
\*   This can violate LeaderCompleteness: if enough followers crash this way,
\*   a new leader can be elected with a shorter log.
Crash(i) ==
    \* Restore from disk
    /\ currentTerm' = [currentTerm EXCEPT ![i] = persistedState[i].term]
    /\ votedFor'    = [votedFor    EXCEPT ![i] = persistedState[i].votedFor]
    /\ log'         = [log         EXCEPT ![i] = persistedLog[i]]
    \* Reset volatile state
    /\ state'       = [state       EXCEPT ![i] = Follower]
    /\ commitIndex' = [commitIndex EXCEPT ![i] =
                        Min(commitIndex[i], Len(persistedLog[i]))]
    /\ applied'     = [applied     EXCEPT ![i] =
                        Min(applied[i], Len(persistedLog[i]))]
    \* Reset leader / candidate state
    /\ nextIndex'   = [nextIndex   EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'  = [matchIndex  EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    \* Reset extension state
    /\ active'      = [active      EXCEPT ![i] = [j \in Server |-> FALSE]]
    /\ remoteState' = [remoteState EXCEPT ![i] = [j \in Server |-> RemoteRetry]]
    \* disk error cleared on restart (Pebble reopens)
    /\ diskError'   = [diskError   EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<messages, configVars, persistedLog, persistedState>>

----
\* Network Actions
----

\* Message m is dropped in transit (network fault).
LoseMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candVars,
                   quorumVars, configVars, persistVars>>

\* Drop a message with a stale term that cannot affect any live server.
\* Prevents unbounded message queue growth.
DropStaleMessage(m) ==
    /\ \A i \in Server : m.mterm < currentTerm[i]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candVars,
                   quorumVars, configVars, persistVars>>

----
\* Next and Spec
----

Next ==
    \/ \E i \in Server :
        \/ Timeout(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ ProposeConfigChange(i)
        \/ AdvanceCommitIndex(i)
        \/ ApplyEntry(i)
        \/ ApplyConfigChange(i)
        \/ CheckQuorum(i)
        \/ SaveRaftState(i)
        \/ InjectDiskError(i)
        \/ Crash(i)
    \/ \E i, j \in Server : i /= j /\
        \/ ReplicateEntries(i, j)
        \/ SendHeartbeat(i, j)
        \/ SendSnapshot(i, j)
    \/ \E m \in DOMAIN messages :
        \/ HandleRequestVoteRequest(m.mdest, m)
        \/ HandleRequestVoteResponse(m.mdest, m)
        \/ HandleReplicateRequest(m.mdest, m)
        \/ HandleHeartbeatRequest(m.mdest, m)
        \/ HandleReplicateResponse(m.mdest, m)
        \/ HandleHeartbeatResponse(m.mdest, m)
        \/ HandleInstallSnapshot(m.mdest, m)
        \/ HandleSnapshotStatus(m.mdest, m)
        \/ LoseMessage(m)

Spec == Init /\ [][Next]_vars

----
\* Invariants
----

\* Standard Raft safety: at most one leader per term.
ElectionSafety ==
    \A i, j \in Server :
        (/\ state[i] = Leader
         /\ state[j] = Leader
         /\ currentTerm[i] = currentTerm[j])
        => i = j

\* Standard Raft safety: matching term at same index implies identical prefix.
LogMatching ==
    \A i, j \in Server :
        \A k \in 1..Min(Len(log[i]), Len(log[j])) :
            log[i][k].term = log[j][k].term =>
                SubSeq(log[i], 1, k) = SubSeq(log[j], 1, k)

\* Standard Raft safety: committed entries appear in future leaders' logs.
\* This invariant will be violated by Bug Family 3 (PR #409):
\* a follower that crashes after silent persist failure loses committed entries.
LeaderCompleteness ==
    \A i \in Server : state[i] = Leader =>
        \A j \in Server :
            \A k \in 1..commitIndex[j] :
                k <= Len(log[i]) /\ log[i][k] = log[j][k]

\* Bug Family 1: A follower in RemoteSnapshot state is never marked active,
\* so CheckQuorum may incorrectly count it as inactive.
\* Invariant: if a follower has communicated with the leader (via SnapshotStatus),
\* the leader should not step down due solely to that follower's inactivity.
\*
\* MC-1: inject scenario where snapshotting follower is quorum-deciding.
\* The model checker should find a state where CheckQuorum fires and the leader
\* steps down even though the snapshotting follower was responsive.
SnapshotActiveTracking ==
    \A i \in Server : state[i] = Leader =>
        \* Every server in RemoteSnapshot state has sent SnapshotStatus to i.
        \* Due to the bug, active[i][j] = FALSE even for those servers.
        \* This invariant checks the INTENDED behavior (not the current buggy behavior):
        \* there should exist a quorum including snapshot-state followers.
        \* We express this as: the set of servers that have EITHER been active OR
        \* are currently in snapshot state should form a quorum.
        IsQuorum({j \in Server :
            j = i \/
            active[i][j] \/
            remoteState[i][j] = RemoteSnapshot})

\* Bug Family 2: at most one uncommitted config change in the log at any time.
\* Reference: raft.go:1075-1083 preLeaderPromotionHandleConfigChange (panic if > 1)
ConfigChangeSingleAtATime ==
    \A i \in Server :
        Cardinality({k \in 1..Len(log[i]) :
            /\ log[i][k].type = ConfigChangeEntry
            /\ k > applied[i]}) <= 1

\* Bug Family 2: pendingConfigChange flag consistency.
\* If set, there must be a ConfigChangeEntry in the unapplied log suffix.
PendingConfigChangeConsistency ==
    \A i \in Server :
        pendingConfigChange[i] =>
            \E k \in 1..Len(log[i]) :
                /\ log[i][k].type = ConfigChangeEntry
                /\ k > applied[i]

\* Bug Family 3: committed entries must be in the persisted log.
\* Violated by PR #409: commitIndex can advance while persistedLog lags behind.
CommittedEntriesPersisted ==
    \A i \in Server :
        \A k \in 1..commitIndex[i] :
            /\ Len(persistedLog[i]) >= k
            /\ persistedLog[i][k] = log[i][k]

\* Structural: commitIndex <= log length
CommitIndexBound ==
    \A i \in Server : commitIndex[i] <= Len(log[i])

\* Structural: applied <= commitIndex
AppliedBound ==
    \A i \in Server : applied[i] <= commitIndex[i]

\* Structural: term is non-decreasing
TermMonotonicity ==
    \A i \in Server : currentTerm[i] >= persistedState[i].term

=============================================================================
