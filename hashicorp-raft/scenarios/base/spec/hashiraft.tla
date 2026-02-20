---------------------------- MODULE hashiraft ----------------------------
\* TLA+ specification of hashicorp/raft protocol.
\*
\* Extends standard Raft with hashicorp/raft-specific behaviors:
\*   1. Separate heartbeat path (replication.go:385-439)
\*   2. Leader lease via lastContact (raft.go:1037-1082)
\*   3. Disk IO blocking (replication.go comment at line 385)
\*   4. Committed vs latest configuration (raft.go:1049,1089)
\*   5. Non-atomic persistVote (raft.go:1135-1141)
\*
EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs

CONSTANTS Follower,          \* Server states
          Candidate,
          Leader

CONSTANT Nil                 \* Null value

CONSTANTS ValueEntry,        \* Log entry types
          ConfigEntry

CONSTANTS RequestVoteRequest,       \* Message types
          RequestVoteResponse,
          AppendEntriesRequest,
          AppendEntriesResponse

----
\* Variables
----

\* Per-server persistent state (survives restart via stable store)
VARIABLE currentTerm         \* [Server -> Nat]
VARIABLE votedFor            \* [Server -> Server \cup {Nil}]
VARIABLE log                 \* [Server -> Seq(Entry)]

\* Per-server volatile state
VARIABLE state               \* [Server -> {Follower, Candidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat]

\* Leader volatile state
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate state
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension 1+2: Heartbeat path + Leader Lease
\* Tracks followers the leader believes it has recently contacted.
\* Reference: replication.go setLastContact(), raft.go:1037 checkLeaderLease()
VARIABLE leaseContact        \* [Server -> SUBSET Server]

\* Extension 3: Disk IO blocking
\* When TRUE, ReplicateTo is disabled but Heartbeat continues.
\* Reference: replication.go:385 (heartbeat's raison d'etre)
VARIABLE diskBlocked         \* [Server -> BOOLEAN]

\* Extension 4: Committed vs latest configuration
\* hashicorp/raft uses different configs in different code paths.
\* Reference: analysis-report.md Section 6.3
VARIABLE committedConfig     \* [Server -> SUBSET Server]
VARIABLE latestConfig        \* [Server -> SUBSET Server]

\* Extension 5: Non-atomic persistVote
\* persistVote writes term and votedFor in separate disk operations.
\* Reference: raft.go:1135-1141
VARIABLE persistedTerm       \* [Server -> Nat]
VARIABLE persistedVotedFor   \* [Server -> Server \cup {Nil}]
VARIABLE pendingVote         \* [Server -> record \cup {Nil}]

----
\* Variable groups
----

serverVars   == <<currentTerm, votedFor, state>>
logVars      == <<log, commitIndex>>
leaderVars   == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted>>
leaseVars    == <<leaseContact>>
diskVars     == <<diskBlocked>>
configVars   == <<committedConfig, latestConfig>>
persistVars  == <<persistedTerm, persistedVotedFor, pendingVote>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          leaseVars, diskVars, configVars, persistVars>>

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

\* Quorum check using given voter set
IsQuorum(S, voters) == Cardinality(S) * 2 > Cardinality(voters)

\* Log up-to-date comparison (raft.go:1654)
LogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    \/ cLastTerm > vLastTerm
    \/ (cLastTerm = vLastTerm /\ cLastIdx >= vLastIdx)

\* Scan log for the last ConfigEntry at or before index maxIdx.
\* Returns Server (initial config) if no ConfigEntry found.
LatestConfigIn(logSeq, maxIdx) ==
    LET bound == Min(maxIdx, Len(logSeq))
        indices == {k \in 1..bound : logSeq[k].type = ConfigEntry}
    IN IF indices = {} THEN Server
       ELSE logSeq[SetMax(indices)].config

\* Message bag helpers
Send(m) == messages' = messages (+) SetToBag({m})
SendAll(ms) == messages' = messages (+) SetToBag(ms)
Discard(m) == messages' = messages (-) SetToBag({m})
Reply(resp, req) ==
    messages' = (messages (-) SetToBag({req})) (+) SetToBag({resp})
DiscardAndSendAll(discard, sends) ==
    messages' = (messages (-) SetToBag({discard})) (+) SetToBag(sends)

----
\* Init
----

Init ==
    /\ currentTerm      = [s \in Server |-> 0]
    /\ votedFor          = [s \in Server |-> Nil]
    /\ log               = [s \in Server |-> <<>>]
    /\ state             = [s \in Server |-> Follower]
    /\ commitIndex       = [s \in Server |-> 0]
    /\ nextIndex         = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex        = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted      = [s \in Server |-> {}]
    /\ messages          = EmptyBag
    /\ leaseContact      = [s \in Server |-> {}]
    /\ diskBlocked       = [s \in Server |-> FALSE]
    /\ committedConfig   = [s \in Server |-> Server]
    /\ latestConfig      = [s \in Server |-> Server]
    /\ persistedTerm     = [s \in Server |-> 0]
    /\ persistedVotedFor = [s \in Server |-> Nil]
    /\ pendingVote       = [s \in Server |-> Nil]

----
\* Election Actions
----

\* Server i times out and starts election.
\* Reference: raft.go:1086-1130 (electSelf)
\* Key: uses latestConfig for vote targets (raft.go:1096)
Timeout(i) ==
    /\ state[i] \in {Follower, Candidate}
    /\ i \in latestConfig[i]
    /\ pendingVote[i] = Nil
    /\ LET newTerm == currentTerm[i] + 1
       IN
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       /\ state' = [state EXCEPT ![i] = Candidate]
       /\ votedFor' = [votedFor EXCEPT ![i] = i]
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
       \* Self-vote persist is atomic (same goroutine)
       /\ persistedTerm' = [persistedTerm EXCEPT ![i] = newTerm]
       /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = i]
       /\ UNCHANGED pendingVote
       /\ SendAll({[mtype        |-> RequestVoteRequest,
                    mterm        |-> newTerm,
                    mlastLogTerm |-> LastLogTerm(i),
                    mlastLogIndex |-> LastLogIndex(i),
                    msource      |-> i,
                    mdest        |-> j] : j \in latestConfig[i] \ {i}})
    /\ UNCHANGED <<log, commitIndex, leaderVars, leaseVars, diskVars, configVars>>

\* Server i handles RequestVoteRequest m.
\* Reference: raft.go:1629-1667 (requestVote)
\*
\* Four cases:
\*   0. Leader-check reject: follower has known leader (raft.go:1691)
\*   1. Reject: term too low, already voted, or log not up-to-date
\*   2. Grant, same term: persist is atomic (only votedFor changes)
\*   3. Grant, higher term: persist is NON-ATOMIC (Extension 5)
\*      Term is persisted first; votedFor persisted in CompletePersistVote.
HandleRequestVoteRequest(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ pendingVote[i] = Nil
    /\ LET mterm    == m.mterm
           logOk    == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                   LastLogTerm(i), LastLogIndex(i))
           canGrant == /\ logOk
                       /\ \/ mterm > currentTerm[i]
                          \/ /\ mterm = currentTerm[i]
                             /\ votedFor[i] \in {Nil, m.msource}
       IN
       \/ \* Case 0: Leader-check rejection (raft.go:1691)
          \* Follower with a known leader rejects without state change.
          \* Implementation: if r.Leader() != "" && r.Leader() != candidate
          \* No term update, no votedFor change.
          /\ state[i] = Follower
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         leaseVars, diskVars, configVars, persistVars>>

       \/ \* Case 1: Reject
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
                  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
                  /\ state' = [state EXCEPT ![i] = Follower]
                  /\ persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
                  /\ UNCHANGED <<persistedVotedFor, pendingVote>>
             ELSE UNCHANGED <<serverVars, persistVars>>
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         leaseVars, diskVars, configVars>>

       \/ \* Case 2: Grant, same term (atomic persist)
          /\ mterm = currentTerm[i]
          /\ canGrant
          /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
          /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = m.msource]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> TRUE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<currentTerm, state, persistedTerm, pendingVote>>
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         leaseVars, diskVars, configVars>>

       \/ \* Case 3: Grant, higher term (NON-ATOMIC persist - Extension 5)
          \* Step 1: persist term only. votedFor NOT yet on disk.
          \* A crash here leaves persistedTerm=new, persistedVotedFor=old.
          /\ mterm > currentTerm[i]
          /\ canGrant
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
          /\ pendingVote' = [pendingVote EXCEPT ![i] =
                [candidate |-> m.msource, term |-> mterm]]
          /\ UNCHANGED persistedVotedFor
          \* Consume request; response deferred to CompletePersistVote
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         leaseVars, diskVars, configVars>>

\* Complete the non-atomic persistVote (Extension 5).
\* Step 2: persist votedFor and send the deferred vote response.
CompletePersistVote(i) ==
    /\ pendingVote[i] /= Nil
    /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = pendingVote[i].candidate]
    /\ pendingVote' = [pendingVote EXCEPT ![i] = Nil]
    /\ Send([mtype        |-> RequestVoteResponse,
             mterm        |-> pendingVote[i].term,
             mvoteGranted |-> TRUE,
             msource      |-> i,
             mdest        |-> pendingVote[i].candidate])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, diskVars, configVars, persistedTerm>>

\* Atomic HandleRequestVoteRequest: merges Cases 2 & 3.
\* In the implementation, requestVote() persists term and votedFor
\* in one function call (raft.go:1135-1141). This operator models
\* that atomic behavior, unlike the two-step Case 3 + CompletePersistVote
\* which models a crash between the two persist operations.
HandleRequestVoteRequestAtomic(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ LET mterm    == m.mterm
           logOk    == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                   LastLogTerm(i), LastLogIndex(i))
           canGrant == /\ logOk
                       /\ \/ mterm > currentTerm[i]
                          \/ /\ mterm = currentTerm[i]
                             /\ votedFor[i] \in {Nil, m.msource}
       IN
       \/ \* Leader-check rejection (raft.go:1691)
          /\ state[i] = Follower
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         leaseVars, diskVars, configVars, persistVars>>

       \/ \* Reject
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
                  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
                  /\ state' = [state EXCEPT ![i] = Follower]
                  /\ persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
                  /\ UNCHANGED <<persistedVotedFor, pendingVote>>
             ELSE UNCHANGED <<serverVars, persistVars>>
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         leaseVars, diskVars, configVars>>

       \/ \* Grant (atomic persist)
          /\ canGrant
          /\ mterm >= currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
          /\ state' = IF mterm > currentTerm[i]
                      THEN [state EXCEPT ![i] = Follower]
                      ELSE state
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
          /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = m.msource]
          /\ pendingVote' = [pendingVote EXCEPT ![i] = Nil]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> mterm,
                    mvoteGranted |-> TRUE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         leaseVars, diskVars, configVars>>

\* Server i handles RequestVoteResponse m.
HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ state[i] = Candidate
    /\ m.mterm = currentTerm[i]
    /\ IF m.mvoteGranted
       THEN votesGranted' = [votesGranted EXCEPT ![i] = votesGranted[i] \cup {m.msource}]
       ELSE UNCHANGED votesGranted
    /\ Discard(m)
    /\ IF m.mterm > currentTerm[i]
       THEN /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
            /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
            /\ state' = [state EXCEPT ![i] = Follower]
            /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
            /\ UNCHANGED <<persistedVotedFor, pendingVote>>
       ELSE UNCHANGED <<serverVars, persistVars>>
    /\ UNCHANGED <<logVars, leaderVars, leaseVars, diskVars, configVars>>

\* Candidate i becomes leader after receiving quorum of votes.
\* Reference: raft.go:446-468 (setupLeaderState)
\* Key: quorum computed from latestConfig (raft.go:1089)
BecomeLeader(i) ==
    /\ state[i] = Candidate
    /\ IsQuorum(votesGranted[i] \cap latestConfig[i], latestConfig[i])
    /\ state' = [state EXCEPT ![i] = Leader]
    /\ nextIndex'  = [nextIndex  EXCEPT ![i] = [j \in Server |-> LastLogIndex(i) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ leaseContact' = [leaseContact EXCEPT ![i] = {}]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, candidateVars, messages,
                   diskVars, configVars, persistVars>>

----
\* Log Replication Actions
----

\* Leader i appends a client request to its log.
ClientRequest(i) ==
    /\ state[i] = Leader
    /\ ~diskBlocked[i]
    /\ LET entry == [term |-> currentTerm[i], type |-> ValueEntry, config |-> {}]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   leaseVars, diskVars, configVars, persistVars>>

\* Leader i proposes a configuration change: add or remove server s.
\* Reference: raft.go:1003-1035
\* Constraint: only one uncommitted config change at a time.
ProposeConfigChange(i, s) ==
    /\ state[i] = Leader
    /\ ~diskBlocked[i]
    /\ committedConfig[i] = latestConfig[i]  \* one at a time (configurationChangeChIfStable)
    /\ \/ /\ s \notin latestConfig[i]        \* add voter
          /\ s \in Server
       \/ /\ s \in latestConfig[i]            \* remove voter
          /\ Cardinality(latestConfig[i]) > 1
    /\ LET newConfig == IF s \in latestConfig[i]
                        THEN latestConfig[i] \ {s}
                        ELSE latestConfig[i] \cup {s}
           entry == [term |-> currentTerm[i], type |-> ConfigEntry, config |-> newConfig]
       IN
       /\ log' = [log EXCEPT ![i] = Append(@, entry)]
       /\ latestConfig' = [latestConfig EXCEPT ![i] = newConfig]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   leaseVars, diskVars, committedConfig, persistVars>>

\* Leader i sends AppendEntries with log entries to server j.
\* Reference: replication.go:199-282 (replicateTo)
\* Requires disk access (reads log entries from stable store).
ReplicateEntries(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ ~diskBlocked[i]   \* needs disk to read log entries
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == LogTerm(i, prevIdx)
           \* Send entries from nextIndex to end of log
           lastIdx  == LastLogIndex(i)
           entries  == IF nextIndex[i][j] > lastIdx THEN <<>>
                       ELSE SubSeq(log[i], nextIndex[i][j], lastIdx)
       IN Send([mtype        |-> AppendEntriesRequest,
                msubtype     |-> "replicate",
                mterm        |-> currentTerm[i],
                mprevLogIndex |-> prevIdx,
                mprevLogTerm |-> prevTerm,
                mentries     |-> entries,
                mcommitIndex |-> commitIndex[i],
                msource      |-> i,
                mdest        |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, diskVars, configVars, persistVars>>

\* Leader i sends heartbeat (empty AppendEntries) to server j.
\* Reference: replication.go:385-439 (heartbeat)
\* Does NOT require disk access (uses pre-built in-memory request).
\* This is heartbeat's raison d'etre: it runs when disk IO blocks.
\*
\* Implementation: heartbeat constructs a minimal request with only
\* Term and Leader fields — prevLogIndex, prevLogTerm, entries, and
\* commitIndex are all zero/empty.  (replication.go:390-395)
SendHeartbeat(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    \* NOTE: no ~diskBlocked[i] guard — heartbeat works even when disk blocked
    /\ Send([mtype        |-> AppendEntriesRequest,
             msubtype     |-> "heartbeat",
             mterm        |-> currentTerm[i],
             mprevLogIndex |-> 0,
             mprevLogTerm |-> 0,
             mentries     |-> <<>>,
             mcommitIndex |-> 0,
             msource      |-> i,
             mdest        |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, diskVars, configVars, persistVars>>

\* Server i handles an AppendEntriesRequest m.
\* Reference: raft.go:1441-1578 (appendEntries)
\* The follower's handling is identical for heartbeat and replicate.
HandleAppendEntriesRequest(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ LET mterm   == m.mterm
           logOk   == \/ m.mprevLogIndex = 0
                      \/ /\ m.mprevLogIndex > 0
                         /\ m.mprevLogIndex <= LastLogIndex(i)
                         /\ LogTerm(i, m.mprevLogIndex) = m.mprevLogTerm
       IN
       \/ \* Reject: term too low
          /\ mterm < currentTerm[i]
          /\ Reply([mtype        |-> AppendEntriesResponse,
                    msubtype     |-> m.msubtype,
                    mterm        |-> currentTerm[i],
                    msuccess     |-> FALSE,
                    mmatchIndex  |-> 0,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         leaseVars, diskVars, configVars, persistVars>>

       \/ \* Reject: log inconsistency
          /\ mterm >= currentTerm[i]
          /\ ~logOk
          /\ Reply([mtype        |-> AppendEntriesResponse,
                    msubtype     |-> m.msubtype,
                    mterm        |-> mterm,
                    msuccess     |-> FALSE,
                    mmatchIndex  |-> 0,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ IF mterm > currentTerm[i]
             THEN persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
             ELSE UNCHANGED persistedTerm
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         leaseVars, diskVars, configVars,
                         persistedVotedFor, pendingVote>>

       \/ \* Accept: log matches at prevLogIndex
          /\ mterm >= currentTerm[i]
          /\ logOk
          /\ LET \* Only modify log if there are new entries (raft.go:1506)
                 \* Heartbeats have prevLogIndex=0, entries=<<>> — don't touch log
                 newLog == IF Len(m.mentries) > 0
                           THEN SubSeq(log[i], 1, m.mprevLogIndex) \o m.mentries
                           ELSE log[i]
                 newLastIdx == Len(newLog)
                 \* Update commitIndex (raft.go:1567)
                 newCommitIdx == IF m.mcommitIndex > commitIndex[i]
                                 THEN Min(m.mcommitIndex, newLastIdx)
                                 ELSE commitIndex[i]
             IN
             /\ log' = [log EXCEPT ![i] = newLog]
             /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
             \* Update configs from new log state
             /\ latestConfig' = [latestConfig EXCEPT ![i] = LatestConfigIn(newLog, newLastIdx)]
             /\ committedConfig' = [committedConfig EXCEPT ![i] = LatestConfigIn(newLog, newCommitIdx)]
             /\ Reply([mtype        |-> AppendEntriesResponse,
                       msubtype     |-> m.msubtype,
                       mterm        |-> mterm,
                       msuccess     |-> TRUE,
                       mmatchIndex  |-> newLastIdx,
                       msource      |-> i,
                       mdest        |-> m.msource], m)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ IF mterm > currentTerm[i]
             THEN persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
             ELSE UNCHANGED persistedTerm
          /\ UNCHANGED <<leaderVars, candidateVars, leaseVars, diskVars,
                         persistedVotedFor, pendingVote>>

\* Leader i handles response from the REPLICATE path.
\* Reference: replication.go:199-282 (replicateTo)
\* Key: CHECKS resp.Term (line 239) and calls handleStaleTerm.
HandleReplicateResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.msubtype = "replicate"
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ \/ \* Response has higher term: step down (handleStaleTerm)
          \* Reference: replication.go:239-241
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
          /\ leaseContact' = [leaseContact EXCEPT ![i] = {}]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         diskVars, configVars, persistedVotedFor, pendingVote>>

       \/ \* Response from current term
          /\ m.mterm = currentTerm[i]
          /\ IF m.msuccess
             THEN \* Update matchIndex and nextIndex
                  /\ nextIndex'  = [nextIndex  EXCEPT ![i][m.msource] = m.mmatchIndex + 1]
                  /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] = m.mmatchIndex]
                  \* Record successful contact for lease
                  /\ leaseContact' = [leaseContact EXCEPT ![i] = @ \cup {m.msource}]
             ELSE \* Decrement nextIndex on failure
                  /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] = Max(1, nextIndex[i][m.msource] - 1)]
                  /\ UNCHANGED <<matchIndex, leaseContact>>
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, candidateVars,
                         diskVars, configVars, persistVars>>

       \/ \* Stale response (from old term), ignore
          /\ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         leaseVars, diskVars, configVars, persistVars>>

\* Leader i handles response from the HEARTBEAT path.
\* Reference: replication.go:412-437 (heartbeat)
\*
\* *** THIS IS THE BUG (Issue #666) ***
\*
\* Key difference from HandleReplicateResponse:
\*   - Does NOT check resp.Term
\*   - Calls setLastContact() unconditionally on transport success
\*   - This creates "phantom contacts" where the leader records contact
\*     with a follower that has actually moved to a higher term.
HandleHeartbeatResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.msubtype = "heartbeat"
    /\ m.mdest = i
    /\ state[i] = Leader
    \* *** BUG (Issue #666): No term check here! ***
    \* In replicateTo (line 239): if resp.Term > req.Term → handleStaleTerm
    \* In heartbeat (line 423): just setLastContact() regardless of resp.Term
    \* The leader unconditionally records contact even if follower has higher term.
    /\ leaseContact' = [leaseContact EXCEPT ![i] = @ \cup {m.msource}]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   diskVars, configVars, persistVars>>

\* Leader i advances commit index based on quorum replication.
\* Reference: commitment.go
\* Key: quorum computed from latestConfig (raft.go:1089)
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET \* Servers that have replicated up to each index
           Agree(idx) == {i} \cup {s \in Server : matchIndex[i][s] >= idx}
           \* Find highest index with quorum agreement in current term
           agreeIdxs == {idx \in (commitIndex[i]+1)..LastLogIndex(i) :
                          /\ IsQuorum(Agree(idx) \cap latestConfig[i], latestConfig[i])
                          /\ log[i][idx].term = currentTerm[i]}
       IN
       /\ agreeIdxs /= {}
       /\ LET newCommitIdx == SetMax(agreeIdxs)
          IN
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
          \* Update committedConfig if config entry was committed
          /\ committedConfig' = [committedConfig EXCEPT
                ![i] = LatestConfigIn(log[i], newCommitIdx)]
    /\ UNCHANGED <<serverVars, log, leaderVars, candidateVars, messages,
                   leaseVars, diskVars, latestConfig, persistVars>>

----
\* Leader Lease (Extension 2)
----

\* Leader i checks if its lease is still valid.
\* Reference: raft.go:1037-1082 (checkLeaderLease)
\* Key: uses latestConfig (raft.go:1049) — not committedConfig.
\*
\* If contacted followers + self don't form a quorum, leader steps down.
\* After checking, contacts are reset for the next lease period.
CheckLeaderLease(i) ==
    /\ state[i] = Leader
    /\ LET contacted == leaseContact[i] \cup {i}
           voters    == latestConfig[i]
       IN
       /\ IF IsQuorum(contacted \cap voters, voters)
          THEN \* Lease valid: reset contacts for next period
               /\ UNCHANGED state
               /\ leaseContact' = [leaseContact EXCEPT ![i] = {}]
          ELSE \* Lease expired: step down
               /\ state' = [state EXCEPT ![i] = Follower]
               /\ leaseContact' = [leaseContact EXCEPT ![i] = {}]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, leaderVars, candidateVars,
                   messages, diskVars, configVars, persistVars>>

----
\* Disk IO (Extension 3)
----

\* Server i's disk becomes blocked.
\* ReplicateTo is disabled, but Heartbeat continues.
DiskBlock(i) ==
    /\ ~diskBlocked[i]
    /\ diskBlocked' = [diskBlocked EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   leaseVars, configVars, persistVars>>

\* Server i's disk becomes available again.
DiskUnblock(i) ==
    /\ diskBlocked[i]
    /\ diskBlocked' = [diskBlocked EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   leaseVars, configVars, persistVars>>

----
\* Crash and Recovery (Extension 5)
----

\* Server i crashes. All volatile state is lost.
\* Only persistedTerm, persistedVotedFor, and log survive.
Crash(i) ==
    /\ state' = [state EXCEPT ![i] = Follower]
    \* Volatile state reset
    /\ commitIndex'  = [commitIndex  EXCEPT ![i] = 0]
    /\ nextIndex'    = [nextIndex    EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'   = [matchIndex   EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ leaseContact' = [leaseContact EXCEPT ![i] = {}]
    /\ diskBlocked'  = [diskBlocked  EXCEPT ![i] = FALSE]
    \* Recover from persisted state
    \* Key (Extension 5): if pendingVote was in progress, votedFor reverts
    \* to persistedVotedFor (which may be Nil or old value)
    /\ currentTerm' = [currentTerm EXCEPT ![i] = persistedTerm[i]]
    /\ votedFor'    = [votedFor    EXCEPT ![i] = persistedVotedFor[i]]
    /\ pendingVote' = [pendingVote EXCEPT ![i] = Nil]
    \* Recompute configs from persisted log
    /\ latestConfig'    = [latestConfig    EXCEPT ![i] = LatestConfigIn(log[i], Len(log[i]))]
    /\ committedConfig' = [committedConfig EXCEPT ![i] = LatestConfigIn(log[i], 0)]
    \* log and persisted state survive
    /\ UNCHANGED <<log, messages, persistedTerm, persistedVotedFor>>

----
\* Network failures
\* Reference: InmemTransport.RequestVote() returns error on Disconnect
----

\* Message is lost due to transport failure.
\* Models: server unreachable, network partition, transport error.
\* Implementation: when trans.RequestVote()/AppendEntries() fails,
\* the caller fabricates a local rejection or ignores the failure.
LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, diskVars, configVars, persistVars>>

\* Drop stale messages from network (helps bound state space)
DropStaleMessage(m) ==
    /\ m \in DOMAIN messages
    /\ \/ /\ m.mtype = RequestVoteRequest
          /\ m.mterm < currentTerm[m.mdest]
       \/ /\ m.mtype = RequestVoteResponse
          /\ m.mterm < currentTerm[m.mdest]
       \/ /\ m.mtype = AppendEntriesRequest
          /\ m.mterm < currentTerm[m.mdest]
       \/ /\ m.mtype = AppendEntriesResponse
          /\ m.mterm < currentTerm[m.mdest]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, diskVars, configVars, persistVars>>

----
\* Spec
----

Next ==
    \/ \E i \in Server :
        \/ Timeout(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ CompletePersistVote(i)
        \/ CheckLeaderLease(i)
        \/ DiskBlock(i)
        \/ DiskUnblock(i)
        \/ Crash(i)
        \/ AdvanceCommitIndex(i)
    \/ \E i, j \in Server :
        \/ ReplicateEntries(i, j)
        \/ SendHeartbeat(i, j)
        \/ ProposeConfigChange(i, j)
    \/ \E m \in DOMAIN messages :
        \/ HandleRequestVoteRequest(m.mdest, m)
        \/ HandleRequestVoteResponse(m.mdest, m)
        \/ HandleAppendEntriesRequest(m.mdest, m)
        \/ HandleReplicateResponse(m.mdest, m)
        \/ HandleHeartbeatResponse(m.mdest, m)
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
            log[s1][idx].term = log[s2][idx].term =>
                \A k \in 1..idx : log[s1][k].term = log[s2][k].term

\* Standard Raft: a committed entry appears in all future leaders' logs.
\* (Checked as: any leader's log contains all committed entries.)
LeaderCompleteness ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ commitIndex[s2] > 0) =>
            \A idx \in 1..commitIndex[s2] :
                /\ idx <= LastLogIndex(s1)
                /\ log[s1][idx].term = log[s2][idx].term

\* Extension: No phantom contacts.
\* If leader records a contact for follower f, then f's term <= leader's term.
\* Violation of this invariant demonstrates Bug #666.
NoPhantomContact ==
    \A s \in Server :
        state[s] = Leader =>
            \A f \in leaseContact[s] :
                currentTerm[f] <= currentTerm[s]

\* Extension: Lease implies loyalty.
\* If a leader's lease check would pass, a real quorum of voters
\* actually has term <= leader's term.
\* This is the safety property that Bug #666 violates.
LeaseImpliesLoyalty ==
    \A s \in Server :
        state[s] = Leader =>
            LET contacted == leaseContact[s] \cup {s}
                voters    == latestConfig[s]
            IN IsQuorum(contacted \cap voters, voters) =>
               LET loyal == {f \in contacted \cap voters : currentTerm[f] <= currentTerm[s]}
               IN IsQuorum(loyal, voters)

\* Extension: Configuration safety.
\* At most one uncommitted configuration change at a time.
ConfigSafety ==
    \A s \in Server :
        state[s] = Leader =>
            \/ committedConfig[s] = latestConfig[s]
            \/ LET configIndices == {idx \in (commitIndex[s]+1)..LastLogIndex(s) :
                                      log[s][idx].type = ConfigEntry}
               IN Cardinality(configIndices) <= 1

=============================================================================
