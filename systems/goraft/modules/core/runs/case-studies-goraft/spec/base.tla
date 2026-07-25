---------------------------- MODULE base ----------------------------
\* TLA+ specification of goraft/raft — Go Raft consensus library
\*
\* Models the implementation's actual behavior (bugs included):
\*   1. Non-persistent safety state: currentTerm/votedFor memory-only (Bug Family 1)
\*   2. Incorrect election safety: wrong || log comparison (Bug Family 2)
\*   3. Commit without term check: median commit index without verifying current term (Bug Family 3)
\*   4. Snapshot without term validation: 2-phase snapshot protocol lacks term checks (Bug Family 4)
\*   5. Stale heartbeat term: per-peer goroutine reads currentTerm without lock (Bug Family 5)
\*
EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs

CONSTANTS Follower,          \* Server states
          Candidate,
          Leader,
          Snapshotting

CONSTANT Nil                 \* Null value

CONSTANTS ValueEntry,        \* Log entry types
          NOPEntry

CONSTANTS RequestVoteRequest,           \* Message types
          RequestVoteResponse,
          AppendEntriesRequest,
          AppendEntriesResponse,
          SnapshotRequest,
          SnapshotRecoveryRequest

----
\* Variables
----

\* Per-server state (should be persistent but goraft keeps in memory — Bug Family 1)
\* Reference: server.go:118,120 (currentTerm, votedFor are plain struct fields)
VARIABLE currentTerm         \* [Server -> Nat]
VARIABLE votedFor            \* [Server -> Server \cup {Nil}]
VARIABLE log                 \* [Server -> Seq([term: Nat, type: {ValueEntry, NOPEntry}])]

\* Per-server volatile state
VARIABLE state               \* [Server -> {Follower, Candidate, Leader, Snapshotting}]
VARIABLE commitIndex         \* [Server -> Nat]

\* Leader volatile state
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate state
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension 1: Non-persistent state tracking (Bug Family 1)
\* goraft never persists term/votedFor to stable storage.
\* These track what WOULD be on disk in a correct implementation.
\* Reference: server.go:1407-1434 (writeConf only saves commitIndex+peers, not term/vote)
VARIABLE persistedTerm       \* [Server -> Nat]  — always 0 in goraft
VARIABLE persistedVotedFor   \* [Server -> Server \cup {Nil}]  — always Nil in goraft

\* Extension 2: Synced peer tracking (Bug Family 3)
\* Leader only commits when a quorum of peers have replicated current-term entries.
\* Reference: server.go:125 (syncedPeer map[string]bool)
\* Reference: server.go:1004-1006 (resp.append tracks current-term replication)
\* Reference: server.go:1009 (len(syncedPeer) < QuorumSize() gate)
VARIABLE syncedPeer          \* [Server -> SUBSET Server]

\* Extension 3: Stale heartbeat term (Bug Family 5)
\* Per-peer heartbeat goroutines read currentTerm without lock.
\* After leader steps down, goroutine may still send AE with stale term.
\* Reference: peer.go:173 (p.server.currentTerm without lock)
VARIABLE heartbeatTerm       \* [Server -> Nat]

\* History variable for invariant checking
VARIABLE committed           \* Set of <<index, term>> pairs committed by any leader

----
\* Variable groups
----

serverVars    == <<currentTerm, votedFor, state>>
logVars       == <<log, commitIndex>>
leaderVars    == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted>>
persistVars   == <<persistedTerm, persistedVotedFor>>
syncVars      == <<syncedPeer>>
heartbeatVars == <<heartbeatTerm>>
historyVars   == <<committed>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          persistVars, syncVars, heartbeatVars, historyVars>>

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

\* Quorum check: strict majority of all servers
IsQuorum(S) == Cardinality(S) * 2 > Cardinality(Server)
QuorumSize == Cardinality(Server) \div 2 + 1

\* goraft's INCORRECT log comparison (Bug Family 2)
\* Uses || (OR) instead of the correct lexicographic comparison.
\* Reference: server.go:1087
\*   if lastIndex > req.LastLogIndex || lastTerm > req.LastLogTerm
\* This is MORE restrictive than correct Raft: rejects valid candidates
\* whose log has a higher term but fewer entries.
\* Example: voter (idx=5, term=2) rejects candidate (idx=3, term=3)
\*   because 5 > 3, even though term 3 > term 2 should win.
GoRaftLogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    ~(vLastIdx > cLastIdx \/ vLastTerm > cLastTerm)

\* Correct Raft log comparison (for reference / invariant checking)
RaftLogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    \/ cLastTerm > vLastTerm
    \/ (cLastTerm = vLastTerm /\ cLastIdx >= vLastIdx)

\* Message bag helpers (using Bags module)
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
    /\ nextIndex         = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex        = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted      = [s \in Server |-> {}]
    /\ messages          = EmptyBag
    \* Extension 1 (Bug Family 1): persisted state starts at 0/Nil
    /\ persistedTerm     = [s \in Server |-> 0]
    /\ persistedVotedFor = [s \in Server |-> Nil]
    \* Extension 2 (Bug Family 3): no synced peers initially
    /\ syncedPeer        = [s \in Server |-> {}]
    \* Extension 3 (Bug Family 5): no heartbeat term initially
    /\ heartbeatTerm     = [s \in Server |-> 0]
    \* History
    /\ committed         = {}

----
\* Standard Raft Actions
----

\* Timeout: Follower becomes Candidate
\* Reference: server.go:668-727 (followerLoop)
\* server.go:710-714: on timeout, setState(Candidate) if promotable
Timeout(i) ==
    /\ state[i] = Follower
    /\ state' = [state EXCEPT ![i] = Candidate]
    \* Clear stale votes from previous elections
    \* (server.go:729 candidateLoop creates fresh vote tracking each time)
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, leaderVars,
                   messages, persistVars, syncVars, heartbeatVars, historyVars>>

\* RequestVote: Candidate starts a new election round
\* Reference: server.go:729-808 (candidateLoop)
\* server.go:747: s.currentTerm++
\* server.go:748: s.votedFor = s.name
\* server.go:750-757: send RequestVoteRequests to all peers
\* Bug Family 1: term and votedFor changes are memory-only (no persist)
RequestVote(i) ==
    /\ state[i] = Candidate
    \* Increment term, vote for self (server.go:747-748)
    /\ currentTerm' = [currentTerm EXCEPT ![i] = @ + 1]
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    \* Send RV to all peers (server.go:750-757)
    /\ SendAll({[mtype         |-> RequestVoteRequest,
                 mterm         |-> currentTerm[i] + 1,
                 mlastLogTerm  |-> LastLogTerm(i),
                 mlastLogIndex |-> LastLogIndex(i),
                 msource       |-> i,
                 mdest         |-> j] : j \in Server \ {i}})
    \* Bug Family 1: NO persistence (server.go:747-748 are plain assignments)
    /\ UNCHANGED <<state, logVars, leaderVars, persistVars, syncVars,
                   heartbeatVars, historyVars>>

\* HandleRequestVoteRequest: Process a vote request
\* Reference: server.go:1066-1099 (processRequestVoteRequest)
\* Bug Family 2: server.go:1087 uses || instead of lexicographic comparison
HandleRequestVoteRequest(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ LET logOk == GoRaftLogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                       LastLogTerm(i), LastLogIndex(i))
       IN
       \/ \* Reject: stale term (server.go:1069-1071)
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, syncVars, heartbeatVars, historyVars>>

       \/ \* Higher term: step down then check log (server.go:1077-1078)
          \* updateCurrentTerm (server.go:545-577) sets Follower, clears votedFor
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ \/ \* Log up-to-date: grant vote (server.go:1094-1098)
                /\ logOk
                /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
                /\ Reply([mtype        |-> RequestVoteResponse,
                          mterm        |-> m.mterm,
                          mvoteGranted |-> TRUE,
                          msource      |-> i,
                          mdest        |-> m.msource], m)
             \/ \* Log not up-to-date: reject (server.go:1087-1091)
                /\ ~logOk
                /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
                /\ Reply([mtype        |-> RequestVoteResponse,
                          mterm        |-> m.mterm,
                          mvoteGranted |-> FALSE,
                          msource      |-> i,
                          mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         persistVars, syncVars, heartbeatVars, historyVars>>

       \/ \* Same term: check vote status (server.go:1079-1083)
          /\ m.mterm = currentTerm[i]
          /\ \/ \* Already voted for different candidate: reject (server.go:1079-1082)
                /\ votedFor[i] /= Nil
                /\ votedFor[i] /= m.msource
                /\ Reply([mtype        |-> RequestVoteResponse,
                          mterm        |-> currentTerm[i],
                          mvoteGranted |-> FALSE,
                          msource      |-> i,
                          mdest        |-> m.msource], m)
                /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                               persistVars, syncVars, heartbeatVars, historyVars>>
             \/ \* Can vote: haven't voted or voted for same candidate
                /\ \/ votedFor[i] = Nil
                   \/ votedFor[i] = m.msource
                /\ \/ \* Log up-to-date: grant (server.go:1094-1098)
                      /\ logOk
                      /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
                      /\ Reply([mtype        |-> RequestVoteResponse,
                                mterm        |-> currentTerm[i],
                                mvoteGranted |-> TRUE,
                                msource      |-> i,
                                mdest        |-> m.msource], m)
                      /\ UNCHANGED <<currentTerm, state, logVars, leaderVars,
                                     candidateVars, persistVars, syncVars,
                                     heartbeatVars, historyVars>>
                   \/ \* Log not up-to-date: reject (server.go:1087-1091)
                      /\ ~logOk
                      /\ Reply([mtype        |-> RequestVoteResponse,
                                mterm        |-> currentTerm[i],
                                mvoteGranted |-> FALSE,
                                msource      |-> i,
                                mdest        |-> m.msource], m)
                      /\ UNCHANGED <<serverVars, logVars, leaderVars,
                                     candidateVars, persistVars, syncVars,
                                     heartbeatVars, historyVars>>

\* HandleRequestVoteResponse: Process a vote response
\* Reference: server.go:1033-1050 (processVoteResponse)
HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ state[i] = Candidate
    /\ \/ \* Vote granted at current term (server.go:1039-1041)
          /\ m.mvoteGranted
          /\ m.mterm = currentTerm[i]
          /\ votesGranted' = [votesGranted EXCEPT ![i] = @ \cup {m.msource}]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars,
                         persistVars, syncVars, heartbeatVars, historyVars>>
       \/ \* Higher term: step down (server.go:1043-1045)
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         persistVars, syncVars, heartbeatVars, historyVars>>
       \/ \* Stale or denied: ignore (server.go:1046-1048)
          /\ m.mterm <= currentTerm[i]
          /\ ~(m.mvoteGranted /\ m.mterm = currentTerm[i])
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, syncVars, heartbeatVars, historyVars>>

\* BecomeLeader: Candidate with quorum becomes leader
\* Reference: server.go:772-829 (candidateLoop quorum check + leaderLoop entry)
\* server.go:774: setState(Leader)
\* server.go:816-818: set peer prevLogIndex to leader's lastLogIndex
\* server.go:825-829: async NOP (modeled as separate AppendNOP action)
BecomeLeader(i) ==
    /\ state[i] = Candidate
    /\ IsQuorum(votesGranted[i])
    /\ state' = [state EXCEPT ![i] = Leader]
    \* Initialize leader volatile state (server.go:816-818)
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> LastLogIndex(i) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    \* Reset syncedPeer (server.go:861 sets to nil at end of previous leadership)
    /\ syncedPeer' = [syncedPeer EXCEPT ![i] = {}]
    \* Bug Family 5: capture heartbeat term (peer goroutines start reading currentTerm)
    /\ heartbeatTerm' = [heartbeatTerm EXCEPT ![i] = currentTerm[i]]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, candidateVars, messages,
                   persistVars, historyVars>>

\* ClientRequest: Leader appends a value entry to its log
\* Reference: server.go:896-925 (Do -> processCommand)
\* server.go:905: createEntry with currentTerm
\* server.go:913: appendEntry
\* server.go:919: syncedPeer[self] = true
ClientRequest(i) ==
    /\ state[i] = Leader
    /\ LET entry == [term |-> currentTerm[i], type |-> ValueEntry]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    \* Mark self as synced (server.go:919)
    /\ syncedPeer' = [syncedPeer EXCEPT ![i] = @ \cup {i}]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   persistVars, heartbeatVars, historyVars>>

\* AppendNOP: Leader appends a NOP entry (sent async after becoming leader)
\* Reference: server.go:825-829 (go func() { s.Do(NOPCommand{}) }())
\* The NOP goes through processCommand which sets syncedPeer[self] = true
AppendNOP(i) ==
    /\ state[i] = Leader
    /\ LET entry == [term |-> currentTerm[i], type |-> NOPEntry]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    \* Mark self as synced (server.go:919)
    /\ syncedPeer' = [syncedPeer EXCEPT ![i] = @ \cup {i}]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   persistVars, heartbeatVars, historyVars>>

\* Replicate: Leader sends AppendEntries with entries to peer
\* Reference: peer.go:170-178 (flush, entries != nil branch)
\* peer.go:173: term := p.server.currentTerm (reads server's term)
\* peer.go:178: newAppendEntriesRequest(term, prevLogIndex, prevLogTerm, commitIndex, name, entries)
Replicate(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ LET prevLogIndex == nextIndex[i][j] - 1
           prevLogTerm  == LogTerm(i, prevLogIndex)
           \* Send all entries from nextIndex to end of log (peer.go:175)
           entries      == SubSeq(log[i], nextIndex[i][j], LastLogIndex(i))
       IN /\ nextIndex[i][j] > 0
          /\ Send([mtype         |-> AppendEntriesRequest,
                   mterm         |-> currentTerm[i],
                   mprevLogIndex |-> prevLogIndex,
                   mprevLogTerm  |-> prevLogTerm,
                   mentries      |-> entries,
                   mcommitIndex  |-> Min(commitIndex[i], LastLogIndex(i)),
                   msource       |-> i,
                   mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, syncVars, heartbeatVars, historyVars>>

\* HandleAppendEntriesRequest: Process an AppendEntries request
\* Reference: server.go:938-984 (processAppendEntriesRequest)
HandleAppendEntriesRequest(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ \/ \* Reject: stale term (server.go:942-944)
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype       |-> AppendEntriesResponse,
                    mterm       |-> currentTerm[i],
                    msuccess    |-> FALSE,
                    mmatchIndex |-> 0,
                    msource     |-> i,
                    mdest       |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, syncVars, heartbeatVars, historyVars>>

       \/ \* Accept: valid term (server.go:947-984)
          /\ m.mterm >= currentTerm[i]
          \* Update term/state: higher term -> Follower via updateCurrentTerm (server.go:961)
          \* Same term + Candidate -> Follower (server.go:951-953)
          \* Same term + Snapshotting -> stay Snapshotting (no code handles this transition!)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor' = [votedFor EXCEPT
                 ![i] = IF m.mterm > currentTerm[i]
                        THEN Nil              \* updateCurrentTerm clears votedFor (server.go:568)
                        ELSE @]
          /\ state' = [state EXCEPT
                 ![i] = IF m.mterm > currentTerm[i]
                        THEN Follower         \* updateCurrentTerm (server.go:561-562)
                        ELSE IF @ = Candidate
                        THEN Follower         \* step down on same-term AE (server.go:951-953)
                        ELSE @]               \* Follower/Snapshotting: stay
          /\ LET logOk == \/ m.mprevLogIndex = 0
                          \/ (m.mprevLogIndex > 0
                              /\ m.mprevLogIndex <= Len(log[i])
                              /\ log[i][m.mprevLogIndex].term = m.mprevLogTerm)
             IN \/ \* Log mismatch: reject (server.go:965-967)
                   /\ ~logOk
                   /\ UNCHANGED <<log, commitIndex>>
                   /\ Reply([mtype       |-> AppendEntriesResponse,
                             mterm       |-> m.mterm,
                             msuccess    |-> FALSE,
                             mmatchIndex |-> 0,
                             msource     |-> i,
                             mdest       |-> m.msource], m)
                   /\ UNCHANGED <<leaderVars, candidateVars,
                                  persistVars, syncVars, heartbeatVars, historyVars>>

                \/ \* Log match: truncate, append, update commitIndex (server.go:965-984)
                   /\ logOk
                   /\ LET \* Truncate only conflicting entries (Raft paper Section 5.3):
                          \* "If an existing entry conflicts with a new one (same index
                          \* but different terms), delete the existing entry and all that
                          \* follow it. Append any new entries not already in the log."
                          \* Reference: log.go:409-467 (truncate checks for conflicts)
                          overlap == Min(Len(m.mentries),
                                        Len(log[i]) - m.mprevLogIndex)
                          allMatch == \A k \in 1..overlap :
                                          log[i][m.mprevLogIndex + k] = m.mentries[k]
                          newLog == IF allMatch
                                      /\ m.mprevLogIndex + Len(m.mentries) <= Len(log[i])
                                   THEN log[i]  \* all new entries match, log is longer — preserve
                                   ELSE SubSeq(log[i], 1, m.mprevLogIndex) \o m.mentries
                          \* Advance commitIndex to min(leaderCommit, lastLogIndex)
                          \* Reference: log.go:330-393 (setCommitIndex — only advances, never goes back)
                          newCommitIndex == Max(commitIndex[i],
                                               Min(m.mcommitIndex, Len(newLog)))
                      IN /\ log' = [log EXCEPT ![i] = newLog]
                         /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIndex]
                   /\ Reply([mtype       |-> AppendEntriesResponse,
                             mterm       |-> m.mterm,
                             msuccess    |-> TRUE,
                             mmatchIndex |-> m.mprevLogIndex + Len(m.mentries),
                             msource     |-> i,
                             mdest       |-> m.msource], m)
                   /\ UNCHANGED <<leaderVars, candidateVars,
                                  persistVars, syncVars, heartbeatVars, historyVars>>

\* HandleAppendEntriesResponse: Process an AE response
\* Reference: server.go:990-1031 (processAppendEntriesResponse)
HandleAppendEntriesResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ \/ \* Higher term: step down (server.go:992-994)
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         persistVars, syncVars, heartbeatVars, historyVars>>

       \/ \* Not successful: decrement nextIndex (server.go:998-999)
          \* Simplified from peer.go:217-247 (various fallback strategies)
          /\ m.mterm <= currentTerm[i]
          /\ ~m.msuccess
          /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] = Max(@-1, 1)]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, log, commitIndex, matchIndex, candidateVars,
                         persistVars, syncVars, heartbeatVars, historyVars>>

       \/ \* Successful: update matchIndex and syncedPeer (server.go:1001-1006)
          /\ m.mterm <= currentTerm[i]
          /\ m.msuccess
          /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] = m.mmatchIndex]
          /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] = m.mmatchIndex + 1]
          \* Bug Family 3: syncedPeer tracking (server.go:1004-1006)
          \* peer.go:210: resp.append = (lastEntry.GetTerm() == currentTerm)
          /\ syncedPeer' = [syncedPeer EXCEPT ![i] =
                IF m.mmatchIndex > 0
                   /\ m.mmatchIndex <= Len(log[i])
                   /\ log[i][m.mmatchIndex].term = currentTerm[i]
                THEN @ \cup {m.msource}
                ELSE @]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, candidateVars,
                         persistVars, heartbeatVars, historyVars>>

\* AdvanceCommitIndex: Leader computes median commit index
\* Reference: server.go:1008-1030 (inline in processAppendEntriesResponse)
\* Bug Family 3: commits median index WITHOUT checking that entry is from current term
\* server.go:1022: commitIndex := indices[s.QuorumSize()-1]
\* Correct Raft (Section 5.4.2) requires: log[commitIndex].term == currentTerm
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    \* Gate: quorum of synced peers (server.go:1009)
    /\ Cardinality(syncedPeer[i]) >= QuorumSize
    \* Find highest index that a quorum has replicated (server.go:1014-1022)
    /\ LET agreeIndices == {idx \in 1..Len(log[i]) :
                                IsQuorum({i} \cup {j \in Server \ {i} :
                                    matchIndex[i][j] >= idx})}
           newCommitIndex == IF agreeIndices /= {} THEN SetMax(agreeIndices)
                            ELSE 0
       IN /\ newCommitIndex > commitIndex[i]
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIndex]
          \* Update committed history variable
          /\ committed' = committed \cup
                 {<<k, log[i][k].term>> : k \in (commitIndex[i]+1)..newCommitIndex}
    /\ UNCHANGED <<serverVars, log, leaderVars, candidateVars, messages,
                   persistVars, syncVars, heartbeatVars>>

----
\* Snapshot Actions (Bug Family 4)
\*
\* goraft uses a custom 2-phase snapshot protocol:
\*   Phase 1: SnapshotRequest (no term field!) -> enter Snapshotting
\*   Phase 2: SnapshotRecoveryRequest -> recover state
\*
\* Key bugs:
\*   - SnapshotRequest has NO Term field (snapshot.go:43-47)
\*   - processSnapshotRequest has zero term validation (server.go:1267-1281)
\*   - processSnapshotRecoveryRequest overwrites currentTerm without clearing
\*     votedFor (server.go:1289-1313)
\*   - Snapshotting state has no guaranteed exit (must receive higher-term AE)
----

\* SendSnapshotRequest: Leader sends snapshot request to peer
\* Reference: peer.go:180 (sendSnapshotRequest when entries not available)
\* Reference: snapshot.go:43-47 (SnapshotRequest struct — NO Term field!)
SendSnapshotRequest(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ commitIndex[i] > 0  \* must have something to snapshot
    \* Bug Family 4: message has NO mterm field!
    /\ Send([mtype      |-> SnapshotRequest,
             mleader    |-> i,
             mlastIndex |-> commitIndex[i],
             mlastTerm  |-> LogTerm(i, commitIndex[i]),
             msource    |-> i,
             mdest      |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, syncVars, heartbeatVars, historyVars>>

\* HandleSnapshotRequest: Follower enters Snapshotting state
\* Reference: server.go:1267-1281 (processSnapshotRequest)
\* Bug Family 4: NO term validation! A stale leader can force this.
HandleSnapshotRequest(i, m) ==
    /\ m.mtype = SnapshotRequest
    /\ m.mdest = i
    /\ state[i] /= Leader       \* leaders don't process snapshot requests
    /\ state[i] /= Snapshotting \* already in snapshot mode
    \* Check: if we already have the entry, reject (server.go:1271-1275)
    /\ \/ m.mlastIndex > Len(log[i])
       \/ (m.mlastIndex > 0 /\ m.mlastIndex <= Len(log[i])
           /\ log[i][m.mlastIndex].term /= m.mlastTerm)
       \/ m.mlastIndex = 0
    \* Bug Family 4: unconditional setState(Snapshotting) (server.go:1278)
    \* NO term check — any leader (even stale) can trigger this
    /\ state' = [state EXCEPT ![i] = Snapshotting]
    /\ Discard(m)
    /\ UNCHANGED <<currentTerm, votedFor, logVars, leaderVars, candidateVars,
                   persistVars, syncVars, heartbeatVars, historyVars>>

\* SendSnapshotRecoveryRequest: Leader sends recovery data to peer
\* Reference: peer.go:269-298 (sendSnapshotRequest success branch sends recovery)
SendSnapshotRecoveryRequest(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ commitIndex[i] > 0
    /\ Send([mtype      |-> SnapshotRecoveryRequest,
             mleader    |-> i,
             mlastIndex |-> commitIndex[i],
             mlastTerm  |-> LogTerm(i, commitIndex[i]),
             mentries   |-> SubSeq(log[i], 1, commitIndex[i]),
             msource    |-> i,
             mdest      |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, syncVars, heartbeatVars, historyVars>>

\* HandleSnapshotRecoveryRequest: Follower recovers from snapshot
\* Reference: server.go:1289-1313 (processSnapshotRecoveryRequest)
\* Bug Family 4:
\*   server.go:1302: s.currentTerm = req.LastTerm (overwrites term!)
\*   NO votedFor clear! (server.go:1289-1313 never resets votedFor)
\*   State stays Snapshotting (no setState call in processSnapshotRecoveryRequest)
HandleSnapshotRecoveryRequest(i, m) ==
    /\ m.mtype = SnapshotRecoveryRequest
    /\ m.mdest = i
    /\ state[i] = Snapshotting
    \* Bug Family 4: overwrite currentTerm with snapshot's lastTerm (server.go:1302)
    /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mlastTerm]
    \* Bug Family 4: DO NOT clear votedFor! This is the key bug.
    \* votedFor may still point to a candidate from the old term.
    /\ UNCHANGED votedFor
    \* State stays Snapshotting (no setState in processSnapshotRecoveryRequest)
    /\ UNCHANGED state
    \* Replace log with snapshot content (server.go:1310 - log.compact)
    /\ log' = [log EXCEPT ![i] = m.mentries]
    \* Update commitIndex (server.go:1303 - log.updateCommitIndex)
    /\ commitIndex' = [commitIndex EXCEPT ![i] = m.mlastIndex]
    /\ Discard(m)
    /\ UNCHANGED <<leaderVars, candidateVars,
                   persistVars, syncVars, heartbeatVars, historyVars>>

----
\* Heartbeat Actions (Bug Family 5)
\*
\* Per-peer heartbeat goroutines read server.currentTerm without lock.
\* Reference: peer.go:138-168 (heartbeat loop)
\* Reference: peer.go:170-182 (flush reads currentTerm at line 173)
\* After leader steps down, heartbeat goroutine may still send AE with stale term.
----

\* SendHeartbeat: Send AppendEntries with possibly stale term
\* Reference: peer.go:173 (term := p.server.currentTerm — no lock!)
\* Reference: peer.go:178 (newAppendEntriesRequest with this term)
\* The heartbeat goroutine captures currentTerm at flush time.
\* If the leader has stepped down since the goroutine started,
\* heartbeatTerm may be stale (< currentTerm).
SendHeartbeat(i, j) ==
    /\ heartbeatTerm[i] > 0  \* heartbeat goroutine is active
    /\ i /= j
    \* Bug Family 5: uses heartbeatTerm (may be stale) instead of currentTerm
    /\ LET prevLogIndex == IF nextIndex[i][j] > 0 THEN nextIndex[i][j] - 1 ELSE 0
       IN Send([mtype         |-> AppendEntriesRequest,
                mterm         |-> heartbeatTerm[i],  \* potentially stale!
                mprevLogIndex |-> prevLogIndex,
                mprevLogTerm  |-> LogTerm(i, prevLogIndex),
                mentries      |-> <<>>,  \* heartbeat: no entries
                mcommitIndex  |-> Min(commitIndex[i], LastLogIndex(i)),
                msource       |-> i,
                mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, syncVars, heartbeatVars, historyVars>>

\* UpdateHeartbeatTerm: Heartbeat goroutine re-reads currentTerm
\* Models the moment when the goroutine captures a fresh copy of currentTerm.
\* Between updates, heartbeatTerm may lag behind currentTerm.
UpdateHeartbeatTerm(i) ==
    /\ state[i] = Leader
    /\ heartbeatTerm[i] /= currentTerm[i]
    /\ heartbeatTerm' = [heartbeatTerm EXCEPT ![i] = currentTerm[i]]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   persistVars, syncVars, historyVars>>

----
\* Fault Injection Actions
----

\* Crash: Server crashes and recovers from persisted state
\* Reference: server.go:118,120 (currentTerm, votedFor are memory-only)
\* Reference: server.go:1407-1434 (writeConf only saves commitIndex+peers, not term/vote)
\* Bug Family 1: After crash, currentTerm reverts to persistedTerm (always 0),
\* votedFor reverts to persistedVotedFor (always Nil).
\* The server can then vote again in a term it already voted in.
Crash(i) ==
    \* Recover from persisted state (which lacks term/votedFor)
    /\ currentTerm' = [currentTerm EXCEPT ![i] = persistedTerm[i]]     \* always 0
    /\ votedFor' = [votedFor EXCEPT ![i] = persistedVotedFor[i]]       \* always Nil
    /\ state' = [state EXCEPT ![i] = Follower]
    \* Log survives crash (stored on disk via log.go)
    /\ UNCHANGED log
    \* commitIndex lost — not reliably persisted (server.go:1397-1401 FlushCommitIndex
    \* is external, never called internally). Model worst case.
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    \* Reset volatile leader/candidate state
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    \* Reset extension state
    /\ syncedPeer' = [syncedPeer EXCEPT ![i] = {}]
    /\ heartbeatTerm' = [heartbeatTerm EXCEPT ![i] = 0]
    /\ UNCHANGED <<messages, persistVars, historyVars>>

\* LoseMessage: Network drops a message
LoseMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, syncVars, heartbeatVars, historyVars>>

----
\* Next state relation
----

Next ==
    \/ \E i \in Server :
        \/ Timeout(i)
        \/ RequestVote(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ AppendNOP(i)
        \/ AdvanceCommitIndex(i)
        \/ UpdateHeartbeatTerm(i)
        \/ Crash(i)
        \/ \E j \in Server \ {i} :
            \/ Replicate(i, j)
            \/ SendHeartbeat(i, j)
            \/ SendSnapshotRequest(i, j)
            \/ SendSnapshotRecoveryRequest(i, j)
    \/ \E m \in DOMAIN messages :
        \/ HandleRequestVoteRequest(m.mdest, m)
        \/ HandleRequestVoteResponse(m.mdest, m)
        \/ HandleAppendEntriesRequest(m.mdest, m)
        \/ HandleAppendEntriesResponse(m.mdest, m)
        \/ HandleSnapshotRequest(m.mdest, m)
        \/ HandleSnapshotRecoveryRequest(m.mdest, m)
        \/ LoseMessage(m)

Spec == Init /\ [][Next]_vars

----
\* Invariants
----

\* --- Standard safety invariants ---

\* ElectionSafety: At most one leader per term
\* Targets: Bug Family 1 (double-voting after crash), Bug Family 4 (votedFor leak after snapshot)
ElectionSafety ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ state[s2] = Leader
         /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* LogMatching: If two logs have entries with the same index and term,
\* the logs are identical up through that index.
LogMatching ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(Len(log[s1]), Len(log[s2])) :
            log[s1][idx].term = log[s2][idx].term =>
                \A j \in 1..idx : log[s1][j] = log[s2][j]

\* LeaderCompleteness: Any committed entry must appear in all current leaders' logs.
\* Targets: Bug Family 2 (wrong leader elected), Bug Family 3 (unsafe commit)
LeaderCompleteness ==
    \A c \in committed :
        \A s \in Server :
            state[s] = Leader =>
                (c[1] <= Len(log[s]) /\ log[s][c[1]].term = c[2])

\* --- Extension invariants (bug-family specific) ---

\* CommitTermSafety: Leader should only commit entries from its current term.
\* Targets: Bug Family 3 (commits previous-term entries via median without term check)
\* In correct Raft (Section 5.4.2), the leader only advances commitIndex to an index
\* where the entry's term matches currentTerm. goraft skips this check.
CommitTermSafety ==
    \A s \in Server :
        state[s] = Leader /\ commitIndex[s] > 0 =>
            log[s][commitIndex[s]].term = currentTerm[s]

\* NoStaleLeaderSnapshot: Snapshot recovery should only accept from a leader
\* whose term >= the server's currentTerm.
\* Targets: Bug Family 4 (SnapshotRequest has no term field, stale leader can force snapshot)
\* Since SnapshotRequest has no term, we check the Snapshotting state invariant:
\* a server in Snapshotting should have entered from a valid (non-stale) leader interaction.
\* This is a structural invariant — the actual violation manifests via ElectionSafety.

\* --- Structural invariants (sanity checks) ---

\* TypeOK: basic type invariant
TypeOK ==
    /\ currentTerm \in [Server -> Nat]
    /\ votedFor \in [Server -> Server \cup {Nil}]
    /\ state \in [Server -> {Follower, Candidate, Leader, Snapshotting}]
    /\ commitIndex \in [Server -> Nat]
    /\ \A s \in Server : Len(log[s]) >= commitIndex[s]

\* CommitIndexBound: commitIndex never exceeds log length
CommitIndexBound ==
    \A s \in Server : commitIndex[s] <= Len(log[s])

\* MatchIndexBound: leader's matchIndex for each peer doesn't exceed that peer's actual log
\* (This can be violated transiently in the spec due to message reordering, so it's informational)

\* MessageBound: constrains message buffer size (used by MC spec for pruning)
MsgCount == BagCardinality(messages)

====
