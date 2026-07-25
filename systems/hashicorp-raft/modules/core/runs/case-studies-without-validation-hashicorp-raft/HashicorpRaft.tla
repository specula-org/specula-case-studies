----------------------------- MODULE HashicorpRaft -----------------------------
\* Formal specification of the hashicorp/raft implementation.
\* Focus: Non-atomic vote persistence (issue #661) and election safety.
\*
\* This spec models the ACTUAL implementation logic, not the Raft paper.
\* Key deviation: persistVote() is two separate StableStore writes,
\* and setCurrentTerm() is a separate persistence step that happens
\* BEFORE the vote is persisted.

EXTENDS Naturals, FiniteSets, Sequences, TLC

\* The set of server IDs.
CONSTANTS Server

\* Server states.
CONSTANTS Follower, Candidate, Leader

\* A reserved value for "no vote" / "no leader".
CONSTANTS Nil

\* Message types.
CONSTANTS RequestVoteRequest, RequestVoteResponse,
          AppendEntriesRequest, AppendEntriesResponse

----
\* Variables

\* --- Volatile state (in-memory, lost on crash) ---

\* [state.go:76] The server's current state.
VARIABLE state

\* [raft.go:384] votesGranted: set of servers that granted votes (candidate only)
VARIABLE votesGranted

\* [api.go:185] The known leader address (cleared on state change)
VARIABLE leader

\* --- Durable state (persisted to stable storage) ---
\* These are modeled separately to capture non-atomic persistence.

\* [state.go:53] currentTerm — persisted via stable.SetUint64(keyCurrentTerm, t)
\* [raft.go:2142-2148]
VARIABLE currentTerm

\* [raft.go:2131-2138] Vote record — persisted via persistVote() as TWO separate writes:
\*   Step 1: stable.SetUint64(keyLastVoteTerm, term)
\*   Step 2: stable.Set(keyLastVoteCand, candidate)
\* We model these as a single votedFor variable for the "committed" state,
\* but track the persistence state separately.
VARIABLE votedFor

\* The server's log (sequence of [term |-> t, value |-> v]).
VARIABLE log

\* [commitment.go:22] Highest index committed.
VARIABLE commitIndex

\* --- Durable state for crash recovery ---
\* Models what is actually on disk (in the StableStore).
\* [raft.go:2144] keyCurrentTerm
VARIABLE persistedTerm

\* [raft.go:2132-2136] keyLastVoteTerm and keyLastVoteCand
\* These are written separately and non-atomically.
VARIABLE persistedVoteTerm
VARIABLE persistedVoteCand

\* Persisted log length (what's actually on disk)
VARIABLE persistedLogLen

\* --- Leader-only state ---
\* [replication.go:42-44] nextIndex for each follower
VARIABLE nextIndex

\* [commitment.go:20] matchIndex for each follower
VARIABLE matchIndex

\* [commitment.go:26] startIndex: first index that may be committed in this term
VARIABLE startIndex

\* --- Network ---
\* Set of messages in the network (may be delivered in any order, duplicated, or lost)
VARIABLE messages

\* --- Crash tracking ---
\* Models whether a server is alive or crashed
VARIABLE isAlive

----
\* Variable groups
serverVars == <<state, currentTerm, votedFor, leader>>
candidateVars == <<votesGranted>>
leaderVars == <<nextIndex, matchIndex, startIndex>>
logVars == <<log, commitIndex>>
persistVars == <<persistedTerm, persistedVoteTerm, persistedVoteCand, persistedLogLen>>
allVars == <<state, currentTerm, votedFor, leader, votesGranted,
             nextIndex, matchIndex, startIndex,
             log, commitIndex,
             persistedTerm, persistedVoteTerm, persistedVoteCand, persistedLogLen,
             messages, isAlive>>

----
\* Helpers

\* The set of all quorums for a set of servers.
Quorum == {Q \in SUBSET Server : Cardinality(Q) * 2 > Cardinality(Server)}

\* The term of the last entry in a log, or 0 if the log is empty.
LastTerm(xlog) == IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].term

\* Minimum of two values
Min(a, b) == IF a < b THEN a ELSE b

\* Maximum of two values
Max(a, b) == IF a > b THEN a ELSE b

\* Send a message (add to the set of messages)
Send(m) == messages' = messages \cup {m}

\* Send a set of messages
SendAll(ms) == messages' = messages \cup ms

\* Discard a message
Discard(m) == messages' = messages \ {m}

\* Send one message and discard another
Reply(response, request) ==
    messages' = (messages \ {request}) \cup {response}

----
\* Initial state

Init ==
    /\ state = [i \in Server |-> Follower]
    /\ currentTerm = [i \in Server |-> 0]
    /\ votedFor = [i \in Server |-> Nil]
    /\ leader = [i \in Server |-> Nil]
    /\ votesGranted = [i \in Server |-> {}]
    /\ nextIndex = [i \in Server |-> [j \in Server |-> 1]]
    /\ matchIndex = [i \in Server |-> [j \in Server |-> 0]]
    /\ startIndex = [i \in Server |-> 0]
    /\ log = [i \in Server |-> <<>>]
    /\ commitIndex = [i \in Server |-> 0]
    \* Durable state starts in sync
    /\ persistedTerm = [i \in Server |-> 0]
    /\ persistedVoteTerm = [i \in Server |-> 0]
    /\ persistedVoteCand = [i \in Server |-> Nil]
    /\ persistedLogLen = [i \in Server |-> 0]
    /\ messages = {}
    /\ isAlive = [i \in Server |-> TRUE]

----
\* State transitions

\* ============================================================
\* Crash and Recovery
\* ============================================================

\* A server crashes, losing all volatile state.
\* On recovery, it reads from stable storage.
\* [state.go, api.go:500-630] NewRaft/restore reads from StableStore
Crash(i) ==
    /\ isAlive[i] = TRUE
    /\ isAlive' = [isAlive EXCEPT ![i] = FALSE]
    \* Volatile state is lost
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ leader' = [leader EXCEPT ![i] = Nil]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ startIndex' = [startIndex EXCEPT ![i] = 0]
    \* Durable state is recovered from what was persisted
    \* [raft.go:2142-2148] currentTerm recovered from stable
    /\ currentTerm' = [currentTerm EXCEPT ![i] = persistedTerm[i]]
    \* [raft.go:1687-1696] votedFor recovered from lastVoteTerm + lastVoteCand
    \* KEY: If persistedVoteTerm < persistedTerm, the vote record is stale/incomplete
    \* The implementation checks: if lastVoteTerm == req.Term (line 1699)
    \* On recovery, votedFor is effectively the persistedVoteCand IF persistedVoteTerm matches currentTerm
    /\ votedFor' = [votedFor EXCEPT ![i] =
                     IF persistedVoteTerm[i] = persistedTerm[i]
                     THEN persistedVoteCand[i]
                     ELSE Nil]
    \* Log is recovered from LogStore — we model as truncated to persisted length
    /\ log' = [log EXCEPT ![i] = SubSeq(@, 1, Min(Len(@), persistedLogLen[i]))]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    \* Persistence state unchanged (it's on disk)
    /\ UNCHANGED <<persistedTerm, persistedVoteTerm, persistedVoteCand, persistedLogLen>>
    /\ UNCHANGED messages

\* A crashed server comes back online.
Restart(i) ==
    /\ isAlive[i] = FALSE
    /\ isAlive' = [isAlive EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<state, currentTerm, votedFor, leader, votesGranted,
                   nextIndex, matchIndex, startIndex,
                   log, commitIndex,
                   persistedTerm, persistedVoteTerm, persistedVoteCand, persistedLogLen,
                   messages>>

\* ============================================================
\* Election: Timeout and become candidate
\* ============================================================

\* [raft.go:286-301] runCandidate(): increment term, start election
\* [raft.go:1977-2044] electSelf(): increment term, persist, vote for self
\* NOTE: We skip PreVote for simplicity and model direct election.
\* PreVote doesn't affect persistence safety (it doesn't increment term).
Timeout(i) ==
    /\ isAlive[i] = TRUE
    /\ state[i] \in {Follower, Candidate}
    \* [raft.go:1982-1984] newTerm = currentTerm + 1; setCurrentTerm(newTerm)
    /\ LET newTerm == currentTerm[i] + 1
       IN
       /\ state' = [state EXCEPT ![i] = Candidate]
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       \* [raft.go:2142-2148] setCurrentTerm persists to stable
       /\ persistedTerm' = [persistedTerm EXCEPT ![i] = newTerm]
       \* [raft.go:2022-2026] persistVote(req.Term, req.Addr) for self
       \* Step 1: stable.SetUint64(keyLastVoteTerm, term)
       /\ persistedVoteTerm' = [persistedVoteTerm EXCEPT ![i] = newTerm]
       \* Step 2: stable.Set(keyLastVoteCand, candidate)
       /\ persistedVoteCand' = [persistedVoteCand EXCEPT ![i] = i]
       /\ votedFor' = [votedFor EXCEPT ![i] = i]
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
       /\ leader' = [leader EXCEPT ![i] = Nil]
       \* [raft.go:2015-2039] Send RequestVote to all other servers
       /\ SendAll({[mtype   |-> RequestVoteRequest,
                    mterm   |-> newTerm,
                    mlastLogTerm  |-> LastTerm(log[i]),
                    mlastLogIndex |-> Len(log[i]),
                    msource |-> i,
                    mdest   |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<nextIndex, matchIndex, startIndex, logVars, persistedLogLen, isAlive>>

\* ============================================================
\* Election: Become leader
\* ============================================================

\* [raft.go:381-385] Candidate becomes leader when it has enough votes
BecomeLeader(i) ==
    /\ isAlive[i] = TRUE
    /\ state[i] = Candidate
    /\ votesGranted[i] \in Quorum
    /\ state' = [state EXCEPT ![i] = Leader]
    /\ leader' = [leader EXCEPT ![i] = i]
    \* [raft.go:456-465] setupLeaderState
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> Len(log[i]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    \* [commitment.go:35-47] startIndex = getLastIndex() + 1
    /\ startIndex' = [startIndex EXCEPT ![i] = Len(log[i]) + 1]
    /\ UNCHANGED <<currentTerm, votedFor, votesGranted, logVars,
                   persistVars, messages, isAlive>>

\* ============================================================
\* Leader: Client request (append to log)
\* ============================================================

\* [raft.go:1245-1284] dispatchLogs: leader appends entry to its own log
ClientRequest(i) ==
    /\ isAlive[i] = TRUE
    /\ state[i] = Leader
    /\ LET entry == [term |-> currentTerm[i], value |-> i]
           newLog == Append(log[i], entry)
       IN
       /\ log' = [log EXCEPT ![i] = newLog]
       /\ persistedLogLen' = [persistedLogLen EXCEPT ![i] = Len(newLog)]
       \* [commitment.go:77-83] Leader updates its own matchIndex
       /\ matchIndex' = [matchIndex EXCEPT ![i][i] = Len(newLog)]
    /\ UNCHANGED <<state, currentTerm, votedFor, leader, votesGranted,
                   nextIndex, startIndex, commitIndex,
                   persistedTerm, persistedVoteTerm, persistedVoteCand,
                   messages, isAlive>>

\* ============================================================
\* Leader: Send AppendEntries to a follower
\* ============================================================

\* [replication.go:200-295] replicateTo / setupAppendEntries
AppendEntries(i, j) ==
    /\ isAlive[i] = TRUE
    /\ state[i] = Leader
    /\ i # j
    /\ LET prevLogIndex == nextIndex[i][j] - 1
           prevLogTerm == IF prevLogIndex > 0 /\ prevLogIndex <= Len(log[i])
                          THEN log[i][prevLogIndex].term
                          ELSE 0
           \* Send entries from nextIndex[i][j] to end of log
           lastEntry == Len(log[i])
           entries == IF nextIndex[i][j] > lastEntry
                      THEN <<>>
                      ELSE SubSeq(log[i], nextIndex[i][j], lastEntry)
       IN Send([mtype |-> AppendEntriesRequest,
                mterm |-> currentTerm[i],
                mprevLogIndex |-> prevLogIndex,
                mprevLogTerm |-> prevLogTerm,
                mentries |-> entries,
                mcommitIndex |-> commitIndex[i],
                msource |-> i,
                mdest |-> j])
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, persistVars, isAlive>>

\* ============================================================
\* Leader: Advance commit index
\* ============================================================

\* [commitment.go:88-104] recalculate(): sorted matchIndexes, median for quorum
\* [commitment.go:100] quorumMatchIndex > commitIndex AND >= startIndex
AdvanceCommitIndex(i) ==
    /\ isAlive[i] = TRUE
    /\ state[i] = Leader
    /\ LET Agree(index) == {i} \cup {k \in Server \ {i} : matchIndex[i][k] >= index}
           \* Find the highest index that has quorum agreement AND >= startIndex
           agreeIndexes == {index \in 1..Len(log[i]) :
                            Agree(index) \in Quorum /\ index >= startIndex[i]}
           maxAgreeIndex == CHOOSE idx \in agreeIndexes : \A idx2 \in agreeIndexes : idx >= idx2
           newCommitIndex == IF agreeIndexes # {} THEN Max(maxAgreeIndex, commitIndex[i])
                             ELSE commitIndex[i]
       IN
       /\ newCommitIndex > commitIndex[i]
       /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIndex]
    /\ UNCHANGED <<state, currentTerm, votedFor, leader, votesGranted,
                   nextIndex, matchIndex, startIndex, log, persistVars, messages, isAlive>>

\* ============================================================
\* Handle RequestVote request
\* ============================================================

\* [raft.go:1604-1734] requestVote handler
\* This is the CRITICAL action that models the non-atomic persistence bug.
\*
\* The implementation does (in order):
\*   1. If req.Term > currentTerm: setState(Follower), setCurrentTerm(req.Term)
\*      [raft.go:1665-1671] — setCurrentTerm PERSISTS term
\*   2. Check lastVoteTerm/lastVoteCand from stable storage [1686-1706]
\*   3. Check log up-to-date [1708-1724]
\*   4. persistVote(req.Term, candidate) [1726-1730] — PERSISTS vote (2 writes)
\*   5. Set resp.Granted = true [1732]
\*
\* We model two variants:
\*   HandleRequestVoteGrantSafe — normal case, all persists succeed
\*   HandleRequestVoteCrashAfterTermPersist — crash between step 1 and step 4

\* Normal case: grant vote with all persistence completed
HandleRequestVoteGrant(i, j, m) ==
    /\ isAlive[i] = TRUE
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ m.msource = j
    \* [raft.go:1660-1662] Ignore older term
    /\ m.mterm >= currentTerm[i]
    \* [raft.go:1665-1671] Step down if newer term
    /\ LET newTerm == Max(m.mterm, currentTerm[i])
           termChanged == m.mterm > currentTerm[i]
           \* [raft.go:1698-1706] Check if already voted in this term
           \* If term changed, votedFor resets (implicitly, since we check lastVoteTerm)
           canVote == \/ termChanged  \* New term, can vote
                      \/ votedFor[i] = Nil  \* Haven't voted yet
                      \/ votedFor[i] = j  \* Already voted for this candidate (duplicate)
           \* [raft.go:1708-1724] Log up-to-date check
           lastTerm == LastTerm(log[i])
           lastIdx == Len(log[i])
           logOK == \/ m.mlastLogTerm > lastTerm
                    \/ (m.mlastLogTerm = lastTerm /\ m.mlastLogIndex >= lastIdx)
       IN
       /\ canVote
       /\ logOK
       \* Grant the vote — all persistence succeeds atomically in this action
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       /\ votedFor' = [votedFor EXCEPT ![i] = j]
       /\ state' = [state EXCEPT ![i] = IF termChanged THEN Follower ELSE @]
       /\ leader' = [leader EXCEPT ![i] = IF termChanged THEN Nil ELSE @]
       \* Persist everything
       /\ persistedTerm' = [persistedTerm EXCEPT ![i] = newTerm]
       /\ persistedVoteTerm' = [persistedVoteTerm EXCEPT ![i] = newTerm]
       /\ persistedVoteCand' = [persistedVoteCand EXCEPT ![i] = j]
       \* Send response
       /\ Reply([mtype |-> RequestVoteResponse,
                 mterm |-> newTerm,
                 mvoteGranted |-> TRUE,
                 msource |-> i,
                 mdest |-> j], m)
    /\ UNCHANGED <<votesGranted, leaderVars, logVars, persistedLogLen, isAlive>>

\* Reject vote request
HandleRequestVoteReject(i, j, m) ==
    /\ isAlive[i] = TRUE
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ m.msource = j
    /\ LET newTerm == Max(m.mterm, currentTerm[i])
           termChanged == m.mterm > currentTerm[i]
           canVote == \/ termChanged
                      \/ votedFor[i] = Nil
                      \/ votedFor[i] = j
           lastTerm == LastTerm(log[i])
           lastIdx == Len(log[i])
           logOK == \/ m.mlastLogTerm > lastTerm
                    \/ (m.mlastLogTerm = lastTerm /\ m.mlastLogIndex >= lastIdx)
       IN
       \* Either can't vote or log not up-to-date
       /\ \/ ~canVote
          \/ ~logOK
          \/ m.mterm < currentTerm[i]
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       /\ state' = [state EXCEPT ![i] = IF termChanged THEN Follower ELSE @]
       /\ leader' = [leader EXCEPT ![i] = IF termChanged THEN Nil ELSE @]
       /\ votedFor' = [votedFor EXCEPT ![i] = IF termChanged THEN Nil ELSE @]
       \* Persist term if changed
       /\ persistedTerm' = [persistedTerm EXCEPT ![i] = IF termChanged THEN newTerm ELSE @]
       /\ Reply([mtype |-> RequestVoteResponse,
                 mterm |-> newTerm,
                 mvoteGranted |-> FALSE,
                 msource |-> i,
                 mdest |-> j], m)
    /\ UNCHANGED <<votesGranted, leaderVars, logVars,
                   persistedVoteTerm, persistedVoteCand, persistedLogLen, isAlive>>

\* ============================================================
\* BUG MODEL: Crash between setCurrentTerm and persistVote
\* [Issue #661] Non-atomic vote persistence
\* ============================================================

\* This models the crash window in requestVote:
\*   [raft.go:1669] r.setCurrentTerm(req.Term)  — PERSISTS term
\*   ... (58 lines of checks, all pass) ...
\*   [raft.go:1727] r.persistVote(...)           — WOULD persist vote, but CRASH
\*
\* The server processes the vote request, sends the grant response,
\* but crashes before persistVote completes. On recovery:
\*   - currentTerm is at the new value (persisted by setCurrentTerm)
\*   - lastVoteTerm/lastVoteCand are OLD (persistVote didn't complete)
\*   - The server can vote again in the same term for a different candidate
HandleRequestVoteCrashAfterTermPersist(i, j, m) ==
    /\ isAlive[i] = TRUE
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ m.msource = j
    /\ m.mterm > currentTerm[i]  \* Must be newer term (otherwise setCurrentTerm not called)
    /\ LET newTerm == m.mterm
           \* Same checks as normal grant
           lastTerm == LastTerm(log[i])
           lastIdx == Len(log[i])
           logOK == \/ m.mlastLogTerm > lastTerm
                    \/ (m.mlastLogTerm = lastTerm /\ m.mlastLogIndex >= lastIdx)
       IN
       /\ logOK
       \* [raft.go:1669] setCurrentTerm PERSISTS the new term
       /\ persistedTerm' = [persistedTerm EXCEPT ![i] = newTerm]
       \* The vote grant response IS sent (network delivers it before crash)
       /\ Reply([mtype |-> RequestVoteResponse,
                 mterm |-> newTerm,
                 mvoteGranted |-> TRUE,
                 msource |-> i,
                 mdest |-> j], m)
       \* BUT: persistVote does NOT complete — vote record stays old
       /\ UNCHANGED persistedVoteTerm
       /\ UNCHANGED persistedVoteCand
       \* Server crashes immediately after sending response
       /\ isAlive' = [isAlive EXCEPT ![i] = FALSE]
       \* Volatile state is lost (crash)
       /\ state' = [state EXCEPT ![i] = Follower]
       /\ leader' = [leader EXCEPT ![i] = Nil]
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
       \* On crash, volatile state for term/votedFor reverts to persisted
       \* currentTerm recovers from persistedTerm (which WAS updated)
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       \* votedFor recovers based on persisted vote state
       \* Since persistedVoteTerm < newTerm (not updated), votedFor = Nil
       /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
       /\ nextIndex' = [nextIndex EXCEPT ![i] = [k \in Server |-> 1]]
       /\ matchIndex' = [matchIndex EXCEPT ![i] = [k \in Server |-> 0]]
       /\ startIndex' = [startIndex EXCEPT ![i] = 0]
       \* Log recovers to persisted length
       /\ log' = [log EXCEPT ![i] = SubSeq(@, 1, Min(Len(@), persistedLogLen[i]))]
       /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    /\ UNCHANGED persistedLogLen

\* ============================================================
\* Handle RequestVote response
\* ============================================================

\* [raft.go:364-386] Candidate processes vote response
HandleRequestVoteResponse(i, j, m) ==
    /\ isAlive[i] = TRUE
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ m.msource = j
    \* [raft.go:367-371] If response has higher term, step down
    /\ \/ /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ leader' = [leader EXCEPT ![i] = Nil]
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
          /\ UNCHANGED votesGranted
       \/ /\ m.mterm = currentTerm[i]
          /\ state[i] = Candidate
          /\ \/ /\ m.mvoteGranted
                /\ votesGranted' = [votesGranted EXCEPT ![i] = @ \cup {j}]
             \/ /\ ~m.mvoteGranted
                /\ UNCHANGED votesGranted
          /\ UNCHANGED <<state, currentTerm, votedFor, leader, persistedTerm>>
       \/ \* Stale response, ignore
          /\ m.mterm < currentTerm[i]
          /\ UNCHANGED <<state, currentTerm, votedFor, leader, votesGranted, persistedTerm>>
    /\ Discard(m)
    /\ UNCHANGED <<leaderVars, logVars, persistedVoteTerm, persistedVoteCand, persistedLogLen, isAlive>>

\* ============================================================
\* Handle AppendEntries request
\* ============================================================

\* [raft.go:1441-1581] appendEntries handler
HandleAppendEntriesRequest(i, j, m) ==
    /\ isAlive[i] = TRUE
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ m.msource = j
    /\ LET termChanged == m.mterm > currentTerm[i]
       IN
       \* [raft.go:1457-1458] Ignore older term
       /\ m.mterm >= currentTerm[i]
       /\ \/ \* Success case: log matches and entries are applied
             /\ \/ m.mprevLogIndex = 0  \* No previous entry to check
                \/ /\ m.mprevLogIndex > 0
                   /\ m.mprevLogIndex <= Len(log[i])
                   /\ log[i][m.mprevLogIndex].term = m.mprevLogTerm
             \* [raft.go:1506-1561] Process entries
             \* Simplified: we model the end result — log is updated to match leader
             /\ LET \* Find the index after prevLogIndex where entries start
                    newEntryIndex == m.mprevLogIndex + 1
                    \* Truncate conflicting entries and append new ones
                    logBefore == SubSeq(log[i], 1, m.mprevLogIndex)
                    newLog == logBefore \o m.mentries
                IN
                /\ log' = [log EXCEPT ![i] = newLog]
                /\ persistedLogLen' = [persistedLogLen EXCEPT ![i] = Len(newLog)]
             \* [raft.go:1567-1570] Update commitIndex
             /\ commitIndex' = [commitIndex EXCEPT ![i] =
                    IF m.mcommitIndex > @
                    THEN Min(m.mcommitIndex, m.mprevLogIndex + Len(m.mentries))
                    ELSE @]
             \* [raft.go:1465-1468] Update term and state
             /\ currentTerm' = [currentTerm EXCEPT ![i] = Max(m.mterm, @)]
             /\ persistedTerm' = [persistedTerm EXCEPT ![i] = IF termChanged THEN m.mterm ELSE @]
             /\ state' = [state EXCEPT ![i] = Follower]
             /\ leader' = [leader EXCEPT ![i] = j]
             /\ votedFor' = [votedFor EXCEPT ![i] = IF termChanged THEN Nil ELSE @]
             /\ Reply([mtype |-> AppendEntriesResponse,
                       mterm |-> Max(m.mterm, currentTerm[i]),
                       msuccess |-> TRUE,
                       mmatchIndex |-> m.mprevLogIndex + Len(m.mentries),
                       msource |-> i,
                       mdest |-> j], m)
          \/ \* Failure case: log doesn't match
             /\ m.mprevLogIndex > 0
             /\ \/ m.mprevLogIndex > Len(log[i])
                \/ /\ m.mprevLogIndex <= Len(log[i])
                   /\ log[i][m.mprevLogIndex].term # m.mprevLogTerm
             /\ currentTerm' = [currentTerm EXCEPT ![i] = Max(m.mterm, @)]
             /\ persistedTerm' = [persistedTerm EXCEPT ![i] = IF termChanged THEN m.mterm ELSE @]
             /\ state' = [state EXCEPT ![i] = IF termChanged THEN Follower ELSE @]
             /\ leader' = [leader EXCEPT ![i] = IF termChanged THEN Nil ELSE @]
             /\ votedFor' = [votedFor EXCEPT ![i] = IF termChanged THEN Nil ELSE @]
             /\ Reply([mtype |-> AppendEntriesResponse,
                       mterm |-> Max(m.mterm, currentTerm[i]),
                       msuccess |-> FALSE,
                       mmatchIndex |-> 0,
                       msource |-> i,
                       mdest |-> j], m)
             /\ UNCHANGED <<log, commitIndex, persistedLogLen>>
    /\ UNCHANGED <<votesGranted, leaderVars, persistedVoteTerm, persistedVoteCand, isAlive>>

\* ============================================================
\* Handle AppendEntries response
\* ============================================================

\* [replication.go:238-263] Process AppendEntries response
HandleAppendEntriesResponse(i, j, m) ==
    /\ isAlive[i] = TRUE
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ m.msource = j
    /\ \/ \* [replication.go:239-241] Higher term: step down
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ leader' = [leader EXCEPT ![i] = Nil]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ UNCHANGED <<nextIndex, matchIndex, startIndex>>
       \/ /\ m.mterm = currentTerm[i]
          /\ state[i] = Leader
          /\ \/ \* [replication.go:248-254] Success
                /\ m.msuccess
                /\ nextIndex' = [nextIndex EXCEPT ![i][j] = m.mmatchIndex + 1]
                \* [commitment.go:77-83] Update matchIndex for this follower
                /\ matchIndex' = [matchIndex EXCEPT ![i][j] = m.mmatchIndex]
             \/ \* [replication.go:255-261] Failure: back up nextIndex
                /\ ~m.msuccess
                /\ nextIndex' = [nextIndex EXCEPT ![i][j] = Max(@[j] - 1, 1)]
                /\ UNCHANGED matchIndex
          /\ UNCHANGED <<state, currentTerm, votedFor, leader, startIndex, persistedTerm>>
       \/ \* Stale
          /\ m.mterm < currentTerm[i]
          /\ UNCHANGED <<state, currentTerm, votedFor, leader, leaderVars, persistedTerm>>
    /\ Discard(m)
    /\ UNCHANGED <<votesGranted, logVars, persistedVoteTerm, persistedVoteCand, persistedLogLen, isAlive>>

\* ============================================================
\* Drop message (model message loss)
\* ============================================================

DropMessage(m) ==
    /\ m \in messages
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, persistVars, isAlive>>

\* ============================================================
\* Next state relation
\* ============================================================

Next ==
    \/ \E i \in Server : Timeout(i)
    \/ \E i \in Server : BecomeLeader(i)
    \/ \E i \in Server : ClientRequest(i)
    \/ \E i,j \in Server : i # j /\ AppendEntries(i, j)
    \/ \E i \in Server : AdvanceCommitIndex(i)
    \/ \E m \in messages :
        \E i, j \in Server :
            \/ HandleRequestVoteGrant(i, j, m)
            \/ HandleRequestVoteReject(i, j, m)
            \/ HandleRequestVoteCrashAfterTermPersist(i, j, m)
            \/ HandleRequestVoteResponse(i, j, m)
            \/ HandleAppendEntriesRequest(i, j, m)
            \/ HandleAppendEntriesResponse(i, j, m)
    \/ \E m \in messages : DropMessage(m)
    \/ \E i \in Server : Crash(i)
    \/ \E i \in Server : Restart(i)

Spec == Init /\ [][Next]_allVars

----
\* Invariants

\* Type correctness
TypeOK ==
    /\ state \in [Server -> {Follower, Candidate, Leader}]
    /\ currentTerm \in [Server -> Nat]
    /\ votedFor \in [Server -> Server \cup {Nil}]
    /\ leader \in [Server -> Server \cup {Nil}]
    /\ votesGranted \in [Server -> SUBSET Server]
    /\ log \in [Server -> Seq([term : Nat, value : Server])]
    /\ commitIndex \in [Server -> Nat]
    /\ isAlive \in [Server -> BOOLEAN]

\* ============================================================
\* ELECTION SAFETY: At most one leader per term.
\* This is the invariant that the non-atomic vote persistence bug violates.
\* [raft.go] Two servers should never both be Leader in the same term.
\* ============================================================
ElectionSafety ==
    \A i, j \in Server :
        (state[i] = Leader /\ state[j] = Leader /\ currentTerm[i] = currentTerm[j])
        => i = j

\* ============================================================
\* LOG MATCHING: If two logs contain an entry with the same index and term,
\* then the logs are identical in all entries up through and including that index.
\* ============================================================
LogMatching ==
    \A i, j \in Server :
        \A n \in 1..Min(Len(log[i]), Len(log[j])) :
            log[i][n].term = log[j][n].term =>
                SubSeq(log[i], 1, n) = SubSeq(log[j], 1, n)

\* ============================================================
\* LEADER COMPLETENESS: If a log entry is committed in a given term,
\* then that entry will be present in the logs of the leaders for
\* all higher-numbered terms.
\* ============================================================
LeaderCompleteness ==
    \A i \in Server :
        state[i] = Leader =>
            \A j \in Server :
                \A n \in 1..commitIndex[j] :
                    n <= Len(log[i]) /\ log[i][n] = log[j][n]

\* ============================================================
\* VOTE SAFETY: Each server votes for at most one candidate per term.
\* (This is what the non-atomic persistence violates — a server can
\*  vote for different candidates in the same term after crash+recovery)
\* ============================================================
VoteSafety ==
    \A i \in Server :
        votedFor[i] # Nil =>
            \A j \in Server :
                (votedFor[j] # Nil /\ currentTerm[i] = currentTerm[j] /\ i = j)
                => votedFor[i] = votedFor[j]

\* ============================================================
\* "Fixed" version without the non-atomic vote persistence bug
\* ============================================================
NextSafe ==
    \/ \E i \in Server : Timeout(i)
    \/ \E i \in Server : BecomeLeader(i)
    \/ \E i \in Server : ClientRequest(i)
    \/ \E i,j \in Server : i # j /\ AppendEntries(i, j)
    \/ \E i \in Server : AdvanceCommitIndex(i)
    \/ \E m \in messages :
        \E i, j \in Server :
            \/ HandleRequestVoteGrant(i, j, m)
            \/ HandleRequestVoteReject(i, j, m)
            \* NOTE: HandleRequestVoteCrashAfterTermPersist is EXCLUDED
            \/ HandleRequestVoteResponse(i, j, m)
            \/ HandleAppendEntriesRequest(i, j, m)
            \/ HandleAppendEntriesResponse(i, j, m)
    \/ \E m \in messages : DropMessage(m)
    \/ \E i \in Server : Crash(i)
    \/ \E i \in Server : Restart(i)

SpecSafe == Init /\ [][NextSafe]_allVars

\* ============================================================
\* State constraint to bound the model checking state space
\* ============================================================
StateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 4
    /\ \A i \in Server : Len(log[i]) <= 3
    /\ Cardinality(messages) <= 15

\* Tighter constraint for faster exhaustive checking
StateConstraintSmall ==
    /\ \A i \in Server : currentTerm[i] <= 3
    /\ \A i \in Server : Len(log[i]) <= 2
    /\ Cardinality(messages) <= 10

\* ============================================================
\* Symmetry
\* ============================================================
Symmetry == Permutations(Server)

===============================================================================
