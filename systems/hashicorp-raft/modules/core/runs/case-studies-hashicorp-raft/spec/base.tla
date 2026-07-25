---------------------------- MODULE base ----------------------------
\* TLA+ specification of hashicorp/raft protocol.
\*
\* Models hashicorp/raft's actual implementation, not the Raft paper.
\* Extends standard Raft with hashicorp/raft-specific behaviors:
\*   Extension 1: Separate heartbeat path (replication.go:416-483)
\*                Heartbeat is an independent goroutine that sends empty
\*                AppendEntries without log/commit info. [Bug Family 1]
\*   Extension 2: Leader lease via lastContact (raft.go:1049-1094)
\*                Leader tracks per-follower contacts for lease quorum
\*                check. Heartbeat records contact WITHOUT checking
\*                resp.Term (Bug #666). [Bug Family 1]
\*   Extension 3: Disk IO blocking (replication.go comment line 164-168)
\*                ReplicateEntries needs disk; Heartbeat does not.
\*                When disk hangs, heartbeat continues → phantom lease.
\*                [Bug Family 1]
\*   Extension 4: Committed vs latest configuration (configuration.go:146-157)
\*                Different code paths use different config versions.
\*                quorumSize/checkLeaderLease/electSelf use latest;
\*                leader step-down check uses committed. [Bug Family 2]
\*   Extension 5: Non-atomic persistVote (raft.go:2175-2183)
\*                persistVote writes term then votedFor in two separate
\*                stable store operations. Crash between them leaves
\*                inconsistent persisted state. [Bug Family 3]
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
\* Reference: raft.go NewRaft() restores from stable store (api.go:506-633)
VARIABLE currentTerm         \* [Server -> Nat]
VARIABLE votedFor            \* [Server -> Server \cup {Nil}]
VARIABLE log                 \* [Server -> Seq(Entry)]

\* Per-server volatile state
VARIABLE state               \* [Server -> {Follower, Candidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat]

\* Leader volatile state
\* Reference: raft.go:464-473 setupLeaderState()
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate state
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension 1+2: Heartbeat path + Leader Lease [Bug Family 1]
\* Tracks followers the leader believes it has recently contacted.
\* Reference: replication.go setLastContact(), raft.go:1049 checkLeaderLease()
\* Bug #666: heartbeat records contact without checking resp.Term
VARIABLE leaseContact        \* [Server -> SUBSET Server]

\* Extension 3: Disk IO blocking [Bug Family 1]
\* When TRUE, ReplicateEntries is disabled but SendHeartbeat continues.
\* Reference: replication.go:164-168 (heartbeat's raison d'etre)
\* Bug #503: disk hang + heartbeat independence = entire cluster stuck
VARIABLE diskBlocked         \* [Server -> BOOLEAN]

\* Extension 4: Committed vs latest configuration [Bug Family 2]
\* hashicorp/raft uses different configs in different code paths.
\* Reference: configuration.go:146-157 (configurations struct)
\* Bug #472: config divergence causes permanent election deadlock
VARIABLE committedConfig     \* [Server -> SUBSET Server]
VARIABLE latestConfig        \* [Server -> SUBSET Server]

\* Extension 5: Non-atomic persistVote [Bug Family 3]
\* persistVote writes term and votedFor in separate disk operations.
\* Reference: raft.go:2175-2183 (persistVote two-step write)
\* Bug #85, #86: crash recovery from inconsistent persisted state
VARIABLE persistedTerm       \* [Server -> Nat]
VARIABLE persistedVotedFor   \* [Server -> Server \cup {Nil}]
VARIABLE pendingVote         \* [Server -> record \cup {Nil}]

----
\* Variable groups (for UNCHANGED clauses)
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
\* Reference: raft.go:1099-1107 quorumSize() — voters/2 + 1
IsQuorum(S, voters) == Cardinality(S) * 2 > Cardinality(voters)

\* Log up-to-date comparison
\* Reference: raft.go:1750-1765 (requestVote log comparison)
LogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    \/ cLastTerm > vLastTerm
    \/ (cLastTerm = vLastTerm /\ cLastIdx >= vLastIdx)

\* Conflict-aware log merge (raft.go:1541-1565).
\* Walks through new entries; only truncates on actual conflict (different term).
\* If entries match existing log, keeps existing suffix intact.
MergeEntries(existingLog, prevIdx, entries) ==
    IF Len(entries) = 0 THEN existingLog
    ELSE LET
        \* Find first entry index k (1..Len(entries)+1) where:
        \*   - all entries 1..k-1 match the existing log, AND
        \*   - entry k conflicts, goes beyond existing log, or k = Len(entries)+1 (all match)
        firstNew == CHOOSE k \in 1..(Len(entries) + 1) :
            /\ \A j \in 1..(k-1) :
                /\ prevIdx + j <= Len(existingLog)
                /\ existingLog[prevIdx + j].term = entries[j].term
            /\ \/ k = Len(entries) + 1                              \* all entries matched
               \/ prevIdx + k > Len(existingLog)                    \* beyond existing log
               \/ existingLog[prevIdx + k].term /= entries[k].term  \* conflict
    IN IF firstNew = Len(entries) + 1
       THEN existingLog   \* all entries already in log, keep existing (possibly longer)
       ELSE SubSeq(existingLog, 1, prevIdx + firstNew - 1)
            \o SubSeq(entries, firstNew, Len(entries))

\* Scan log for the last ConfigEntry at or before index maxIdx.
\* Returns Server (initial config) if no ConfigEntry found.
\* Reference: api.go:575-600 (configuration recovery from log scan)
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
\* Reference: raft.go:2019-2088 (electSelf)
\*   - Line 2026: newTerm = currentTerm + 1, setCurrentTerm(newTerm)
\*   - Line 2064: persistVote(newTerm, localAddr) for self-vote
\*   - Line 2044: iterates configurations.latest.Servers (Voter only)
\* Key: uses latestConfig for vote targets [Bug Family 2]
\* Self-vote persist is atomic (same goroutine, no interleaving)
Timeout(i) ==
    /\ state[i] \in {Follower, Candidate}
    \* Only voters can become candidates (configuration.go:170-177 hasVote)
    /\ i \in latestConfig[i]                            \* raft.go:2044
    \* Cannot start election while persist is pending [Extension 5]
    /\ pendingVote[i] = Nil
    /\ LET newTerm == currentTerm[i] + 1
       IN
       \* Increment term and become candidate (raft.go:2026)
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       /\ state' = [state EXCEPT ![i] = Candidate]
       /\ votedFor' = [votedFor EXCEPT ![i] = i]
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
       \* Self-vote persist is atomic (raft.go:2064)
       /\ persistedTerm' = [persistedTerm EXCEPT ![i] = newTerm]
       /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = i]
       /\ UNCHANGED pendingVote
       \* Send RequestVote to all other voters in latestConfig (raft.go:2044)
       /\ SendAll({[mtype        |-> RequestVoteRequest,
                    mterm        |-> newTerm,
                    mlastLogTerm |-> LastLogTerm(i),
                    mlastLogIndex |-> LastLogIndex(i),
                    msource      |-> i,
                    mdest        |-> j] : j \in latestConfig[i] \ {i}})
    /\ UNCHANGED <<log, commitIndex, leaderVars, leaseVars, diskVars, configVars>>

\* Server i handles RequestVoteRequest m.
\* Reference: raft.go:1632-1776 (requestVote)
\*
\* Four cases modeled separately because code paths diverge:
\*   Case 0: Leader-check rejection (raft.go:1691)
\*           Follower with known leader rejects without state change.
\*   Case 1: Reject (term too low, already voted, log not up-to-date)
\*           If higher term: step down + persist term (raft.go:1705-1713)
\*   Case 2: Grant, same term (atomic persist — only votedFor changes)
\*           persistVote at raft.go:1768
\*   Case 3: Grant, higher term (NON-ATOMIC persist — Extension 5)
\*           Step 1: persist term only (raft.go:1709 setCurrentTerm)
\*           Step 2: persist votedFor in CompletePersistVote (raft.go:1768)
\*           A crash between steps leaves persistedTerm=new, persistedVotedFor=old.
HandleRequestVoteRequest(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ pendingVote[i] = Nil
    /\ LET mterm    == m.mterm
           \* Log up-to-date check (raft.go:1750-1765)
           logOk    == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                   LastLogTerm(i), LastLogIndex(i))
           \* Can grant if log is OK and either higher term or same term with
           \* no prior vote / already voted for this candidate (raft.go:1728-1747)
           canGrant == /\ logOk
                       /\ \/ mterm > currentTerm[i]
                          \/ /\ mterm = currentTerm[i]
                             /\ votedFor[i] \in {Nil, m.msource}
       IN
       \/ \* Case 0: Leader-check rejection (raft.go:1691)
          \* Follower with a known leader rejects without state change.
          \* Implementation: if r.Leader() != "" && r.Leader() != candidate
          \* Modeled as non-deterministic rejection for Followers.
          /\ state[i] = Follower
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         leaseVars, diskVars, configVars, persistVars>>

       \/ \* Case 1: Reject
          \* Reject if term too low (raft.go:1700-1702) or can't grant
          /\ \/ mterm < currentTerm[i]
             \/ /\ mterm >= currentTerm[i]
                /\ ~canGrant
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> Max(currentTerm[i], mterm),
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          \* Step down on newer term (raft.go:1705-1713)
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
          \* persistVote writes both term and votedFor (raft.go:1768)
          \* No term change needed, only votedFor update
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

       \/ \* Case 3: Grant, higher term (NON-ATOMIC persist — Extension 5)
          \* Step 1: persist term only (raft.go:1709 setCurrentTerm).
          \* votedFor is set in memory but NOT yet on disk.
          \* A crash here leaves persistedTerm=new, persistedVotedFor=old.
          \* Response is deferred to CompletePersistVote.
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

\* Complete the non-atomic persistVote (Extension 5) [Bug Family 3].
\* Step 2: persist votedFor and send the deferred vote response.
\* Reference: raft.go:1768 persistVote(req.Term, candidateBytes)
\* This completes the two-step persistence started in Case 3.
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
\* In the normal (non-crash) execution path, requestVote() persists
\* term and votedFor in one function call (raft.go:2175-2183).
\* This operator models the atomic behavior for trace validation,
\* where crashes between persist steps are not being tested.
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

       \/ \* Grant (atomic persist — both term and votedFor in one step)
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
\* Reference: raft.go:286-449 (runCandidate vote tally)
\*   - Line 364: if vote.Term > currentTerm, step down
\*   - Line 372: if vote.Granted, increment tally
HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ state[i] = Candidate
    /\ m.mterm = currentTerm[i]
    /\ IF m.mvoteGranted
       THEN votesGranted' = [votesGranted EXCEPT ![i] = votesGranted[i] \cup {m.msource}]
       ELSE UNCHANGED votesGranted
    /\ Discard(m)
    \* Step down if response has higher term (raft.go:364)
    /\ IF m.mterm > currentTerm[i]
       THEN /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
            /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
            /\ state' = [state EXCEPT ![i] = Follower]
            /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
            /\ UNCHANGED <<persistedVotedFor, pendingVote>>
       ELSE UNCHANGED <<serverVars, persistVars>>
    /\ UNCHANGED <<logVars, leaderVars, leaseVars, diskVars, configVars>>

\* Candidate i becomes leader after receiving quorum of votes.
\* Reference: raft.go:377-383 (runCandidate quorum check)
\*   - quorum computed from latestConfig (raft.go:1099-1107) [Bug Family 2]
\*   - Line 464-473: setupLeaderState() initializes nextIndex/matchIndex
\*   - leaseContact reset on becoming leader
BecomeLeader(i) ==
    /\ state[i] = Candidate
    /\ IsQuorum(votesGranted[i] \cap latestConfig[i], latestConfig[i])
    /\ state' = [state EXCEPT ![i] = Leader]
    \* setupLeaderState (raft.go:464-473)
    /\ nextIndex'  = [nextIndex  EXCEPT ![i] = [j \in Server |-> LastLogIndex(i) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ leaseContact' = [leaseContact EXCEPT ![i] = {}]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, candidateVars, messages,
                   diskVars, configVars, persistVars>>

----
\* Log Replication Actions
----

\* Leader i appends a client request to its log.
\* Reference: raft.go:918-945 (leaderLoop applyCh case)
\*   - Requires disk access for StoreLogs (raft.go:1262-1301 dispatchLogs)
\* Disk blocked guard: if disk hangs, no new entries can be written [Bug Family 1]
ClientRequest(i) ==
    /\ state[i] = Leader
    /\ ~diskBlocked[i]                                  \* needs disk (raft.go:1262)
    /\ LET entry == [term |-> currentTerm[i], type |-> ValueEntry, config |-> {}]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   leaseVars, diskVars, configVars, persistVars>>

\* Leader i proposes a configuration change: add or remove server s.
\* Reference: raft.go:905-912 (leaderLoop configurationChangeChIfStable)
\*   - raft.go:663-673: only allowed when latestIndex == committedIndex
\*   - Single uncommitted config at a time [Bug Family 2]
ProposeConfigChange(i, s) ==
    /\ state[i] = Leader
    /\ ~diskBlocked[i]
    \* One at a time (raft.go:663-673 configurationChangeChIfStable)
    /\ committedConfig[i] = latestConfig[i]             \* raft.go:668
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
\* Reference: replication.go:202-323 (replicateTo)
\*   - Reads log entries from stable store → requires disk [Bug Family 1]
\*   - Line 250: checks resp.Term > req.Term (unlike heartbeat)
\*   - Sends PrevLogIndex, PrevLogTerm, entries, and LeaderCommitIndex
ReplicateEntries(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ ~diskBlocked[i]                                  \* needs disk to read log
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == LogTerm(i, prevIdx)
           \* Send entries from nextIndex to end of log (replication.go:226)
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
\* Reference: replication.go:416-483 (heartbeat)
\*   - Independent goroutine, does NOT require disk access [Bug Family 1]
\*   - Constructs minimal request: only Term and Leader (replication.go:418-423)
\*   - prevLogIndex, prevLogTerm, entries, commitIndex all zero/empty
\*   - Does NOT advance follower's commitIndex (intentional: replication.go:164-168)
\*   - No ~diskBlocked guard: heartbeat works even when disk hangs (#503)
SendHeartbeat(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    \* NOTE: no ~diskBlocked[i] guard — heartbeat is disk-independent [Bug Family 1]
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
\* Reference: raft.go:1458-1610 (appendEntries)
\*   - Follower's handling is identical for heartbeat and replicate subtypes.
\*   - Three cases: reject (term too low), reject (log inconsistency), accept.
HandleAppendEntriesRequest(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ LET mterm   == m.mterm
           \* PrevLog consistency check (raft.go:1506-1532)
           logOk   == \/ m.mprevLogIndex = 0
                      \/ /\ m.mprevLogIndex > 0
                         /\ m.mprevLogIndex <= LastLogIndex(i)
                         /\ LogTerm(i, m.mprevLogIndex) = m.mprevLogTerm
       IN
       \/ \* Reject: term too low (raft.go:1484-1487)
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

       \/ \* Reject: log inconsistency (raft.go:1506-1532)
          /\ mterm >= currentTerm[i]
          /\ ~logOk
          /\ Reply([mtype        |-> AppendEntriesResponse,
                    msubtype     |-> m.msubtype,
                    mterm        |-> mterm,
                    msuccess     |-> FALSE,
                    mmatchIndex  |-> 0,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          \* Step down / update term (raft.go:1491-1497)
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

       \/ \* Accept: log matches at prevLogIndex (raft.go:1535-1609)
          /\ mterm >= currentTerm[i]
          /\ logOk
          /\ LET \* Process new entries with conflict checking (raft.go:1535-1593)
                 \* Only truncates on actual conflict (different term at same index).
                 \* If entries match existing log, keeps existing suffix intact.
                 newLog == MergeEntries(log[i], m.mprevLogIndex, m.mentries)
                 newLastIdx == Len(newLog)
                 \* Update commitIndex (raft.go:1596-1605)
                 newCommitIdx == IF m.mcommitIndex > commitIndex[i]
                                 THEN Min(m.mcommitIndex, newLastIdx)
                                 ELSE commitIndex[i]
             IN
             /\ log' = [log EXCEPT ![i] = newLog]
             /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
             \* Update configs from new log state [Bug Family 2]
             \* Reference: raft.go:1559-1560 (config rollback on truncation)
             /\ latestConfig' = [latestConfig EXCEPT ![i] = LatestConfigIn(newLog, newLastIdx)]
             /\ committedConfig' = [committedConfig EXCEPT ![i] = LatestConfigIn(newLog, newCommitIdx)]
             /\ Reply([mtype        |-> AppendEntriesResponse,
                       msubtype     |-> m.msubtype,
                       mterm        |-> mterm,
                       msuccess     |-> TRUE,
                       mmatchIndex  |-> newLastIdx,
                       msource      |-> i,
                       mdest        |-> m.msource], m)
          \* Step down / update term (raft.go:1491-1497)
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
\* Reference: replication.go:202-323 (replicateTo)
\*
\* Key: CHECKS resp.Term (replication.go:250) and calls handleStaleTerm.
\* This is the CORRECT behavior — contrast with HandleHeartbeatResponse.
\*
\* Three cases:
\*   - Higher term: step down via handleStaleTerm (replication.go:250)
\*   - Same term success: update matchIndex/nextIndex + record contact
\*   - Same term failure: decrement nextIndex (replication.go:275)
\*   - Stale response: ignore
HandleReplicateResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.msubtype = "replicate"
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ \/ \* Response has higher term: step down (handleStaleTerm)
          \* Reference: replication.go:250 — if resp.Term > req.Term
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
             THEN \* Update matchIndex and nextIndex (replication.go:265-270)
                  /\ nextIndex'  = [nextIndex  EXCEPT ![i][m.msource] = m.mmatchIndex + 1]
                  /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] = m.mmatchIndex]
                  \* Record successful contact for lease [Bug Family 1]
                  \* Reference: replication.go:265 updateLastAppended → setLastContact
                  /\ leaseContact' = [leaseContact EXCEPT ![i] = @ \cup {m.msource}]
             ELSE \* Decrement nextIndex on failure (replication.go:275)
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
\* Reference: replication.go:416-483 (heartbeat)
\*
\* *** THIS IS THE BUG (Issue #666) *** [Bug Family 1]
\*
\* Key difference from HandleReplicateResponse:
\*   - Does NOT check resp.Term (replication.go:458-480)
\*   - Calls setLastContact() unconditionally on transport success
\*   - This creates "phantom contacts" where the leader records contact
\*     with a follower that has actually moved to a higher term.
\*
\* Contrast with replicateTo (replication.go:250):
\*   if resp.Term > req.Term → handleStaleTerm (steps leader down)
\* In heartbeat: no such check exists.
HandleHeartbeatResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.msubtype = "heartbeat"
    /\ m.mdest = i
    /\ state[i] = Leader
    \* *** BUG (Issue #666): No term check here! ***
    \* In replicateTo (replication.go:250): if resp.Term > req.Term → handleStaleTerm
    \* In heartbeat (replication.go:462): just setLastContact() regardless of resp.Term
    \* The leader unconditionally records contact even if follower has higher term.
    /\ leaseContact' = [leaseContact EXCEPT ![i] = @ \cup {m.msource}]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   diskVars, configVars, persistVars>>

\* Leader i advances commit index based on quorum replication.
\* Reference: commitment.go:88-104 (recalculate)
\*   - Sorts matchIndexes, takes median for quorum
\*   - Advances only if quorumMatchIndex >= startIndex (current-term entry committed)
\*   - Uses latestConfig for quorum (commitment.go:53 setConfiguration) [Bug Family 2]
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET \* Servers that have replicated up to each index
           Agree(idx) == {i} \cup {s \in Server : matchIndex[i][s] >= idx}
           \* Find highest index with quorum agreement in current term
           \* commitment.go:99: quorumMatchIndex >= startIndex
           agreeIdxs == {idx \in (commitIndex[i]+1)..LastLogIndex(i) :
                          /\ IsQuorum(Agree(idx) \cap latestConfig[i], latestConfig[i])
                          /\ log[i][idx].term = currentTerm[i]}
       IN
       /\ agreeIdxs /= {}
       /\ LET newCommitIdx == SetMax(agreeIdxs)
          IN
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
          \* Update committedConfig if config entry was committed [Bug Family 2]
          /\ committedConfig' = [committedConfig EXCEPT
                ![i] = LatestConfigIn(log[i], newCommitIdx)]
    /\ UNCHANGED <<serverVars, log, leaderVars, candidateVars, messages,
                   leaseVars, diskVars, latestConfig, persistVars>>

----
\* Leader Lease (Extension 2) [Bug Family 1]
----

\* Leader i checks if its lease is still valid.
\* Reference: raft.go:1049-1094 (checkLeaderLease)
\*   - Line 1061: iterates configurations.latest.Servers (NOT committed) [Bug Family 2]
\*   - Line 1049: uses leaseTimeout to check recency of contacts
\*   - If contacted followers + self don't form quorum: step down
\*   - After checking, contacts are reset for the next lease period
\*
\* Combined with Bug #666 (HandleHeartbeatResponse phantom contacts),
\* this allows a stale leader to maintain lease indefinitely.
CheckLeaderLease(i) ==
    /\ state[i] = Leader
    /\ LET contacted == leaseContact[i] \cup {i}
           voters    == latestConfig[i]                 \* raft.go:1061 (NOT committed!)
       IN
       /\ IF IsQuorum(contacted \cap voters, voters)
          THEN \* Lease valid: reset contacts for next period
               /\ UNCHANGED state
               /\ leaseContact' = [leaseContact EXCEPT ![i] = {}]
          ELSE \* Lease expired: step down (raft.go:1087)
               /\ state' = [state EXCEPT ![i] = Follower]
               /\ leaseContact' = [leaseContact EXCEPT ![i] = {}]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, leaderVars, candidateVars,
                   messages, diskVars, configVars, persistVars>>

----
\* Disk IO (Extension 3) [Bug Family 1]
----

\* Server i's disk becomes blocked.
\* ReplicateEntries and ClientRequest are disabled, but SendHeartbeat continues.
\* Reference: replication.go:164-168 (heartbeat independence rationale)
\* Bug #503: LogStore hang + heartbeat independence = entire cluster stuck
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
\* Crash and Recovery (Extension 5) [Bug Family 3]
----

\* Server i crashes. All volatile state is lost.
\* Only persistedTerm, persistedVotedFor, and log survive.
\* Reference: api.go:506-633 (NewRaft recovery path)
\*
\* Key (Extension 5): if pendingVote was in progress, votedFor reverts
\* to persistedVotedFor (which may be Nil or old value from prior term).
\* This models the crash window between setCurrentTerm and persistVote.
Crash(i) ==
    /\ state' = [state EXCEPT ![i] = Follower]
    \* Volatile state reset
    /\ commitIndex'  = [commitIndex  EXCEPT ![i] = 0]
    /\ nextIndex'    = [nextIndex    EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'   = [matchIndex   EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ leaseContact' = [leaseContact EXCEPT ![i] = {}]
    /\ diskBlocked'  = [diskBlocked  EXCEPT ![i] = FALSE]
    \* Recover from persisted state (api.go:545-555)
    \* Key: if pendingVote was in progress, persistedVotedFor is stale
    /\ currentTerm' = [currentTerm EXCEPT ![i] = persistedTerm[i]]
    /\ votedFor'    = [votedFor    EXCEPT ![i] = persistedVotedFor[i]]
    /\ pendingVote' = [pendingVote EXCEPT ![i] = Nil]
    \* Recompute configs from persisted log (api.go:575-600)
    /\ latestConfig'    = [latestConfig    EXCEPT ![i] = LatestConfigIn(log[i], Len(log[i]))]
    /\ committedConfig' = [committedConfig EXCEPT ![i] = LatestConfigIn(log[i], 0)]
    \* log and persisted state survive crash
    /\ UNCHANGED <<log, messages, persistedTerm, persistedVotedFor>>

----
\* Network failures
----

\* Message is lost due to transport failure.
\* Models: server unreachable, network partition, transport error.
\* Reference: InmemTransport returns error on Disconnect
LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, diskVars, configVars, persistVars>>

\* Drop stale messages from network (helps bound state space).
\* Messages with term < receiver's currentTerm would be rejected anyway.
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
\* Reference: Raft paper Figure 3, Election Safety Property
ElectionSafety ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ state[s2] = Leader /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* Standard Raft: if two logs have an entry with the same index and term,
\* the logs are identical up to that point.
\* Reference: Raft paper Figure 3, Log Matching Property
LogMatching ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(LastLogIndex(s1), LastLogIndex(s2)) :
            log[s1][idx].term = log[s2][idx].term =>
                \A k \in 1..idx : log[s1][k].term = log[s2][k].term

\* Standard Raft: a committed entry appears in all future leaders' logs.
\* Reference: Raft paper Figure 3, Leader Completeness Property
\* Guard: only requires leaders to have entries committed at or before
\* their term. A stale leader in term T need not have entries committed
\* in term T+1 (it became leader before those entries existed).
LeaderCompleteness ==
    \A leader \in Server :
        state[leader] = Leader =>
            \A other \in Server :
                \A idx \in 1..commitIndex[other] :
                    log[other][idx].term <= currentTerm[leader] =>
                        /\ idx <= LastLogIndex(leader)
                        /\ log[leader][idx].term = log[other][idx].term

\* Extension invariant [Bug Family 1]: No phantom contacts.
\* If leader records a contact for follower f, then f's term <= leader's term.
\* Violation of this invariant demonstrates Bug #666:
\*   heartbeat records contact even when follower has moved to higher term.
NoPhantomContact ==
    \A s \in Server :
        state[s] = Leader =>
            \A f \in leaseContact[s] :
                currentTerm[f] <= currentTerm[s]

\* Extension invariant [Bug Family 1]: Lease implies loyalty.
\* If a leader's lease check would pass, a real quorum of voters
\* actually has term <= leader's term.
\* This is the safety property that Bug #666 violates:
\*   phantom contacts from heartbeats can make lease pass even when
\*   a quorum of followers has moved to a higher term.
LeaseImpliesLoyalty ==
    \A s \in Server :
        state[s] = Leader =>
            LET contacted == leaseContact[s] \cup {s}
                voters    == latestConfig[s]
            IN IsQuorum(contacted \cap voters, voters) =>
               LET loyal == {f \in contacted \cap voters : currentTerm[f] <= currentTerm[s]}
               IN IsQuorum(loyal, voters)

\* Extension invariant [Bug Family 2]: Configuration safety.
\* At most one uncommitted configuration change at a time.
\* Reference: raft.go:663-673 configurationChangeChIfStable
ConfigSafety ==
    \A s \in Server :
        state[s] = Leader =>
            \/ committedConfig[s] = latestConfig[s]
            \/ LET configIndices == {idx \in (commitIndex[s]+1)..LastLogIndex(s) :
                                      log[s][idx].type = ConfigEntry}
               IN Cardinality(configIndices) <= 1

=============================================================================
