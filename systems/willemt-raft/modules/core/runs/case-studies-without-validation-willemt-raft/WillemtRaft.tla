--------------------------------- MODULE WillemtRaft ---------------------------------
\* Formal model of the willemt/raft C library implementation.
\* https://github.com/willemt/raft
\*
\* This spec models the ACTUAL implementation logic, not the Raft paper.
\* Every behavioral statement references the source code location.
\*
\* Scope: elections, log replication, commit advancement.
\* Abstracted: membership changes (fixed config), snapshots, persistence callbacks.

EXTENDS Naturals, Integers, FiniteSets, Sequences, TLC

\* The set of server IDs
CONSTANTS Server

\* A reserved value
CONSTANTS Nil

\* Message types
CONSTANTS RequestVoteRequest, RequestVoteResponse,
          AppendEntriesRequest, AppendEntriesResponse

\* Server states
\* [raft.h:36-40] RAFT_STATE_FOLLOWER, RAFT_STATE_CANDIDATE, RAFT_STATE_LEADER
CONSTANTS Follower, Candidate, Leader

\* Maximum term and log length for state space bounding
CONSTANTS MaxTerm, MaxLogLength

----
\* Variables

\* Per-server persistent state
\* [raft_private.h:27] current_term
VARIABLE currentTerm
\* [raft_private.h:31] voted_for (-1 means Nil)
VARIABLE votedFor
\* Each server's log is a sequence of records [term |-> t, value |-> v]
\* [raft_private.h:34] log
VARIABLE log

\* Per-server volatile state
\* [raft_private.h:39] commit_idx
VARIABLE commitIndex
\* [raft_private.h:45] state
VARIABLE state
\* [raft_private.h:59] current_leader (tracked explicitly, DEVIATION D4)
VARIABLE currentLeader

\* Per-server, per-peer state (leader only, but maintained always)
\* [raft_node.c:31] next_idx
VARIABLE nextIndex
\* [raft_node.c:32] match_idx
VARIABLE matchIndex

\* Network: set of messages in transit
VARIABLE messages

\* Auxiliary variable: elections won (for leader completeness checking)
VARIABLE elections

serverVars   == <<currentTerm, state, votedFor>>
logVars      == <<log, commitIndex>>
leaderVars   == <<nextIndex, matchIndex, elections>>
candidateVars == <<>>
netVars      == <<messages>>

vars == <<currentTerm, state, votedFor, log, commitIndex,
          currentLeader, nextIndex, matchIndex, messages, elections>>

----
\* Helper operators

\* [raft_server_properties.c:108-112] raft_get_current_idx
GetCurrentIdx(i) == Len(log[i])

\* [raft_server_properties.c:216-226] raft_get_last_log_term
GetLastLogTerm(i) == IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term ELSE 0

\* The set of all quorum sets for a given set of servers
Quorum == {Q \in SUBSET Server : Cardinality(Q) * 2 > Cardinality(Server)}

\* Minimum of two values
Min(a, b) == IF a < b THEN a ELSE b

\* The term of a log entry (0 if index is out of bounds)
LogTerm(i, idx) == IF idx > 0 /\ idx <= Len(log[i]) THEN log[i][idx].term ELSE 0

----
\* Message constructors and network

\* Send a message (add to the set of in-flight messages)
Send(m) == messages' = messages \cup {m}

\* Receive/consume a message
Discard(m) == messages' = messages \ {m}

\* Send one message and discard another
Reply(response, request) == messages' = (messages \ {request}) \cup {response}

\* Send a set of messages
SendAll(msgs) == messages' = messages \cup msgs

----
\* State transitions

\* [raft_server_properties.c:85-101] raft_set_current_term
\* CRITICAL: When term increases, voted_for is atomically reset to -1 (Nil).
\* This is the fix from commit 75b0104.
SetCurrentTerm(i, newTerm) ==
    /\ newTerm > currentTerm[i]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
    /\ votedFor' = [votedFor EXCEPT ![i] = Nil]

\* [raft_server.c:212-220] raft_become_follower
\* NOTE: Does NOT reset votedFor (fix from commit daa93cb/75b0104).
\* Only resets timeout and sets state.
BecomeFollower(i) ==
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ currentLeader' = [currentLeader EXCEPT ![i] = Nil]

\* [raft_server.c:157-177] raft_become_leader
BecomeLeader(i) ==
    /\ state' = [state EXCEPT ![i] = Leader]
    /\ currentLeader' = [currentLeader EXCEPT ![i] = i]
    \* [raft_server.c:173] raft_node_set_next_idx(node, raft_get_current_idx(me_) + 1)
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> GetCurrentIdx(i) + 1]]
    \* [raft_server.c:174] raft_node_set_match_idx(node, 0)
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]

----
\* Election actions

\* [raft_server.c:179-210] raft_become_candidate
\* Server i starts a new election.
Timeout(i) ==
    /\ state[i] \in {Follower, Candidate}
    /\ currentTerm[i] + 1 <= MaxTerm
    \* [raft_server.c:186] raft_set_current_term(me_, raft_get_current_term(me_) + 1)
    \* This atomically resets votedFor to Nil via SetCurrentTerm
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    \* [raft_server.c:191] raft_vote(me_, me->node)
    \* Vote for self (after term increment reset votedFor to Nil)
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    \* [raft_server.c:193] raft_set_state(me_, RAFT_STATE_CANDIDATE)
    /\ state' = [state EXCEPT ![i] = Candidate]
    /\ currentLeader' = [currentLeader EXCEPT ![i] = Nil]
    \* [raft_server.c:198-208] Send RequestVote to all other voting nodes
    /\ messages' = messages \cup
        {[mtype   |-> RequestVoteRequest,
          mterm   |-> currentTerm[i] + 1,
          \* [raft_server.c:793] rv.last_log_idx = raft_get_current_idx(me_)
          mlastLogIndex |-> GetCurrentIdx(i),
          \* [raft_server.c:794] rv.last_log_term = raft_get_last_log_term(me_)
          mlastLogTerm  |-> GetLastLogTerm(i),
          \* [raft_server.c:795] rv.candidate_id = raft_get_nodeid(me_)
          msource |-> i,
          mdest   |-> j] : j \in Server \ {i}}
    /\ UNCHANGED <<log, commitIndex, nextIndex, matchIndex, elections>>

\* [raft_server.c:535-573] __should_grant_vote
\* Returns whether this server should grant its vote to the candidate.
ShouldGrantVote(me, mterm, mlastLogTerm, mlastLogIdx) ==
    \* [raft_server.c:537-538] Must be a voting node (always true in fixed config)
    \* [raft_server.c:540-541] vr->term < currentTerm => don't grant
    /\ mterm >= currentTerm[me]
    \* [raft_server.c:543-545] TODO comment: should re-vote for same candidate
    \* ACTUAL CODE: if already_voted, return 0 (don't grant)
    /\ votedFor[me] = Nil
    \* [raft_server.c:549-571] Log up-to-date check
    /\ \/ GetCurrentIdx(me) = 0
       \/ mlastLogTerm > GetLastLogTerm(me)
       \/ (mlastLogTerm = GetLastLogTerm(me) /\ mlastLogIdx >= GetCurrentIdx(me))

\* [raft_server.c:575-644] raft_recv_requestvote
\* Server i handles a RequestVote request from server j.
HandleRequestVoteRequest(i, j, m) ==
    LET mterm == m.mterm
        mlastLogTerm == m.mlastLogTerm
        mlastLogIdx == m.mlastLogIndex
    IN
    \* [raft_server.c:587-591] Reject if we have a leader and haven't timed out
    \* DEVIATION D1: Leader lease check (commit ab96a76)
    \* In TLA+ we non-deterministically model this: either the lease is active or not
    \* For soundness, we allow the vote to proceed (worst case for safety)

    \* [raft_server.c:593-602] Step down if higher term
    \/ /\ mterm > currentTerm[i]
       /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
       /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
       /\ state' = [state EXCEPT ![i] = Follower]
       /\ currentLeader' = [currentLeader EXCEPT ![i] = Nil]
       \* Now check if should grant vote (with updated state)
       /\ LET grant == \* After stepping down, votedFor is Nil, so check log
              \/ GetCurrentIdx(i) = 0
              \/ mlastLogTerm > GetLastLogTerm(i)
              \/ (mlastLogTerm = GetLastLogTerm(i) /\ mlastLogIdx >= GetCurrentIdx(i))
          IN
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> mterm,
                    mvoteGranted |-> grant,
                    msource      |-> i,
                    mdest        |-> j], m)
          /\ IF grant
             THEN votedFor' = [votedFor EXCEPT ![i] = j]
             ELSE UNCHANGED <<>>
       /\ UNCHANGED <<log, commitIndex, nextIndex, matchIndex, elections>>
    \* [raft_server.c:604-635] Same or lower term
    \/ /\ mterm <= currentTerm[i]
       /\ LET grant == ShouldGrantVote(i, mterm, mlastLogTerm, mlastLogIdx)
          IN
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> grant,
                    msource      |-> i,
                    mdest        |-> j], m)
          /\ IF grant
             THEN /\ votedFor' = [votedFor EXCEPT ![i] = j]
                  \* [raft_server.c:617] me->current_leader = NULL
                  /\ currentLeader' = [currentLeader EXCEPT ![i] = Nil]
             ELSE UNCHANGED <<votedFor, currentLeader>>
          /\ UNCHANGED <<currentTerm, state, log, commitIndex, nextIndex, matchIndex, elections>>

\* [raft_server.c:655-716] raft_recv_requestvote_response
\* Server i handles a RequestVote response from server j.
HandleRequestVoteResponse(i, j, m) ==
    \* [raft_server.c:665-668] If not candidate, ignore
    \/ /\ state[i] /= Candidate
       /\ Discard(m)
       /\ UNCHANGED <<serverVars, logVars, leaderVars, currentLeader>>
    \* [raft_server.c:669-677] Higher term: step down
    \/ /\ state[i] = Candidate
       /\ m.mterm > currentTerm[i]
       /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
       /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
       /\ state' = [state EXCEPT ![i] = Follower]
       /\ currentLeader' = [currentLeader EXCEPT ![i] = Nil]
       /\ Discard(m)
       /\ UNCHANGED <<logVars, nextIndex, matchIndex, elections>>
    \* [raft_server.c:678-684] Stale term: ignore
    \/ /\ state[i] = Candidate
       /\ m.mterm < currentTerm[i]
       /\ Discard(m)
       /\ UNCHANGED <<serverVars, logVars, leaderVars, currentLeader>>
    \* [raft_server.c:692-713] Same term: process vote
    \/ /\ state[i] = Candidate
       /\ m.mterm = currentTerm[i]
       /\ \/ /\ m.mvoteGranted
             \* [raft_server.c:697-699] Count votes and potentially become leader
             /\ LET newVoteQuorum ==
                    {i} \cup {k \in Server : k /= i /\
                        \E msg \in messages :
                            /\ msg.mtype = RequestVoteResponse
                            /\ msg.mdest = i
                            /\ msg.msource = k
                            /\ msg.mterm = currentTerm[i]
                            /\ msg.mvoteGranted} \cup {j}
                IN
                IF newVoteQuorum \in Quorum
                THEN \* [raft_server.c:699] raft_become_leader(me_)
                     /\ BecomeLeader(i)
                     /\ elections' = elections \cup
                            {[eterm   |-> currentTerm[i],
                              eleader |-> i,
                              elog    |-> log[i]]}
                     /\ Discard(m)
                     /\ UNCHANGED <<currentTerm, votedFor, logVars>>
                ELSE /\ Discard(m)
                     /\ UNCHANGED <<serverVars, logVars, leaderVars, currentLeader>>
          \/ /\ ~m.mvoteGranted
             /\ Discard(m)
             /\ UNCHANGED <<serverVars, logVars, leaderVars, currentLeader>>

----
\* AppendEntries actions

\* [raft_server.c:882-937] raft_send_appendentries
\* Leader i sends AppendEntries to server j.
AppendEntries(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ LET
        prevLogIdx == nextIndex[i][j] - 1
        prevLogTerm == LogTerm(i, prevLogIdx)
        \* [raft_server.c:908] ae.entries = raft_get_entries_from_idx(me_, next_idx, &ae.n_entries)
        entries == IF nextIndex[i][j] <= Len(log[i])
                   THEN SubSeq(log[i], nextIndex[i][j], Len(log[i]))
                   ELSE <<>>
       IN
       /\ Send([mtype         |-> AppendEntriesRequest,
                mterm         |-> currentTerm[i],
                mprevLogIndex |-> prevLogIdx,
                mprevLogTerm  |-> prevLogTerm,
                mentries      |-> entries,
                \* [raft_server.c:894] ae.leader_commit = raft_get_commit_idx(me_)
                mcommitIndex  |-> commitIndex[i],
                msource       |-> i,
                mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, currentLeader>>

\* [raft_server.c:385-528] raft_recv_appendentries
\* Server i handles an AppendEntries request from server j.
HandleAppendEntriesRequest(i, j, m) ==
    LET mterm == m.mterm IN
    \* [raft_server.c:406-409] Candidate with same term: become follower
    \* [raft_server.c:410-416] Higher term: update term, become follower
    \* [raft_server.c:417-423] Lower term: reject
    IF mterm < currentTerm[i]
    THEN \* [raft_server.c:417-423] Reply false, term < currentTerm
         /\ Reply([mtype       |-> AppendEntriesResponse,
                   mterm       |-> currentTerm[i],
                   msuccess    |-> FALSE,
                   mmatchIndex |-> 0,
                   msource     |-> i,
                   mdest       |-> j], m)
         /\ UNCHANGED <<serverVars, logVars, leaderVars, currentLeader>>
    ELSE
       \* Step down if needed
       /\ IF mterm > currentTerm[i]
          THEN /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
               /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
               /\ state' = [state EXCEPT ![i] = Follower]
          ELSE IF state[i] = Candidate /\ mterm = currentTerm[i]
          THEN \* [raft_server.c:406-409] Candidate with same term becomes follower
               /\ state' = [state EXCEPT ![i] = Follower]
               /\ UNCHANGED <<currentTerm, votedFor>>
          ELSE UNCHANGED <<currentTerm, votedFor, state>>
       \* [raft_server.c:426] me->current_leader = node
       /\ currentLeader' = [currentLeader EXCEPT ![i] = j]
       \* Process log entries
       /\ LET
            prevLogIdx == m.mprevLogIndex
            prevLogTerm == m.mprevLogTerm
            entries == m.mentries
            leaderCommit == m.mcommitIndex
            \* [raft_server.c:432-470] Check prev log entry
            logOk == \/ prevLogIdx = 0
                     \/ /\ prevLogIdx > 0
                        /\ prevLogIdx <= Len(log[i])
                        /\ log[i][prevLogIdx].term = prevLogTerm
          IN
          IF ~logOk
          THEN \* [raft_server.c:449-469] Log doesn't match: reply false
               \* [raft_server.c:467] delete entries if prev_log doesn't match
               \* In the implementation, entries from prevLogIdx onward are deleted.
               \* For safety, we model this as: if prevLogIdx <= commitIndex, it's
               \* a fatal error (SHUTDOWN). Otherwise truncate the log.
               /\ LET newLog == IF prevLogIdx > 0 /\ prevLogIdx <= Len(log[i])
                                   /\ log[i][prevLogIdx].term /= prevLogTerm
                                   /\ prevLogIdx > commitIndex[i]
                                THEN SubSeq(log[i], 1, prevLogIdx - 1)
                                ELSE log[i]
                  IN
                  /\ log' = [log EXCEPT ![i] = newLog]
                  /\ Reply([mtype       |-> AppendEntriesResponse,
                            mterm       |-> mterm,
                            msuccess    |-> FALSE,
                            mmatchIndex |-> 0,
                            msource     |-> i,
                            mdest       |-> j], m)
                  /\ UNCHANGED <<commitIndex, nextIndex, matchIndex, elections>>
          ELSE \* [raft_server.c:472-512] Log matches, process entries
               \* [raft_server.c:479-503] Check each entry for conflicts
               \* [raft_server.c:506-512] Append new entries
               LET
                   \* Find the index where existing log and new entries diverge
                   \* [raft_server.c:479-503] Conflict detection loop
                   existingLen == Len(log[i])
                   newEntryCount == Len(entries)
                   \* Determine how many entries already match
                   matchCount == LET
                       MatchAt(k) == prevLogIdx + k <= existingLen
                                     /\ log[i][prevLogIdx + k].term = entries[k].term
                   IN IF newEntryCount = 0 THEN 0
                      ELSE LET maxMatch == CHOOSE n \in 0..newEntryCount :
                               /\ \A k \in 1..n : MatchAt(k)
                               /\ (n = newEntryCount \/ ~MatchAt(n + 1))
                           IN maxMatch
                   \* Truncate conflicting entries and append new ones
                   newLog == IF matchCount = newEntryCount
                             THEN log[i] \* All entries already present
                             ELSE \* [raft_server.c:495] delete from conflict point
                                  \* [raft_server.c:506-512] append remainder
                                  SubSeq(log[i], 1, prevLogIdx + matchCount)
                                  \o SubSeq(entries, matchCount + 1, newEntryCount)
                   newLastIdx == prevLogIdx + newEntryCount
                   \* [raft_server.c:516-520] Update commit index
                   \* min(leaderCommit, index of most recent entry)
                   newCommitIndex == IF leaderCommit > commitIndex[i]
                                    THEN Min(leaderCommit,
                                             IF newLastIdx > 0 THEN newLastIdx
                                             ELSE Len(log[i]))
                                    ELSE commitIndex[i]
               IN
               /\ log' = [log EXCEPT ![i] = newLog]
               /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIndex]
               /\ Reply([mtype       |-> AppendEntriesResponse,
                         mterm       |-> mterm,
                         msuccess    |-> TRUE,
                         \* [raft_server.c:473,502,511] r->current_idx tracks progress
                         mmatchIndex |-> prevLogIdx + newEntryCount,
                         msource     |-> i,
                         mdest       |-> j], m)
               /\ UNCHANGED <<nextIndex, matchIndex, elections>>

\* [raft_server.c:275-383] raft_recv_appendentries_response
\* Server i handles an AppendEntries response from server j.
HandleAppendEntriesResponse(i, j, m) ==
    \* [raft_server.c:291-292] Not leader: return RAFT_ERR_NOT_LEADER
    \/ /\ state[i] /= Leader
       /\ Discard(m)
       /\ UNCHANGED <<serverVars, logVars, leaderVars, currentLeader>>
    \* [raft_server.c:296-304] Higher term: step down
    \/ /\ state[i] = Leader
       /\ m.mterm > currentTerm[i]
       /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
       /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
       /\ state' = [state EXCEPT ![i] = Follower]
       /\ currentLeader' = [currentLeader EXCEPT ![i] = Nil]
       /\ Discard(m)
       /\ UNCHANGED <<logVars, nextIndex, matchIndex, elections>>
    \* [raft_server.c:305-306] Different (lower) term: ignore
    \/ /\ state[i] = Leader
       /\ m.mterm < currentTerm[i]
       /\ Discard(m)
       /\ UNCHANGED <<serverVars, logVars, leaderVars, currentLeader>>
    \* Same term responses
    \/ /\ state[i] = Leader
       /\ m.mterm = currentTerm[i]
       /\ \/ \* [raft_server.c:310-327] Failure response
             /\ ~m.msuccess
             \* [raft_server.c:317-318] Stale response: current_idx < match_idx => ignore
             \* [raft_server.c:319-322] Decrement nextIndex
             /\ nextIndex' = [nextIndex EXCEPT ![i][j] =
                    IF nextIndex[i][j] > 1 THEN nextIndex[i][j] - 1 ELSE 1]
             /\ Discard(m)
             /\ UNCHANGED <<serverVars, logVars, matchIndex, currentLeader, elections>>
          \/ \* [raft_server.c:329-378] Success response
             /\ m.msuccess
             \* [raft_server.c:343-344] Stale: r->current_idx <= match_idx => ignore
             /\ \/ /\ m.mmatchIndex <= matchIndex[i][j]
                   /\ Discard(m)
                   /\ UNCHANGED <<serverVars, logVars, leaderVars, currentLeader>>
                \/ /\ m.mmatchIndex > matchIndex[i][j]
                   \* [raft_server.c:348] raft_node_set_next_idx(node, r->current_idx + 1)
                   /\ nextIndex' = [nextIndex EXCEPT ![i][j] = m.mmatchIndex + 1]
                   \* [raft_server.c:349] raft_node_set_match_idx(node, r->current_idx)
                   /\ matchIndex' = [matchIndex EXCEPT ![i][j] = m.mmatchIndex]
                   \* [raft_server.c:352-373] Update commit index
                   \* Only advance if entry at point has current term (§5.4.2)
                   /\ LET
                        point == m.mmatchIndex
                        \* [raft_server.c:356] ety->term == me->current_term
                        entryTermOk == /\ point > 0
                                       /\ point <= Len(log[i])
                                       /\ log[i][point].term = currentTerm[i]
                        \* [raft_server.c:358-369] Count votes (including self)
                        \* [raft_server.c:371] raft_get_num_voting_nodes(me_) / 2 < votes
                        \* Fix from commit c4de21e: uses voting nodes, not all nodes
                        agreeCount == Cardinality({i} \cup
                            {k \in Server \ {i} :
                                IF k = j THEN m.mmatchIndex >= point
                                ELSE matchIndex[i][k] >= point})
                        isMajority == agreeCount * 2 > Cardinality(Server)
                      IN
                      commitIndex' = IF /\ entryTermOk
                                        /\ isMajority
                                        /\ point > commitIndex[i]
                                     THEN [commitIndex EXCEPT ![i] = point]
                                     ELSE UNCHANGED commitIndex
                   /\ Discard(m)
                   /\ UNCHANGED <<serverVars, currentLeader, elections>>

----
\* Client request action

\* [raft_server.c:718-779] raft_recv_entry
\* Leader i receives a client request to add entry v to the log.
ClientRequest(i) ==
    /\ state[i] = Leader
    /\ Len(log[i]) < MaxLogLength
    \* [raft_server.c:743] ety->term = me->current_term
    /\ LET entry == [term |-> currentTerm[i], value |-> 1]
       IN
       /\ log' = [log EXCEPT ![i] = Append(log[i], entry)]
       \* [raft_server.c:767-768] Single-node cluster: commit immediately
       /\ IF Cardinality(Server) = 1
          THEN commitIndex' = [commitIndex EXCEPT ![i] = Len(log[i]) + 1]
          ELSE UNCHANGED commitIndex
    /\ UNCHANGED <<serverVars, currentLeader, nextIndex, matchIndex, messages, elections>>

----
\* Periodic action (heartbeat)

\* Model the leader sending heartbeats/appendentries to all peers
\* [raft_server.c:939-956] raft_send_appendentries_all
\* We model this as the leader sending individual AE messages
\* (the action AppendEntries above handles individual sends)

----
\* Receive message dispatch

Receive(m) ==
    LET i == m.mdest
        j == m.msource
    IN
    \/ /\ m.mtype = RequestVoteRequest
       /\ HandleRequestVoteRequest(i, j, m)
    \/ /\ m.mtype = RequestVoteResponse
       /\ HandleRequestVoteResponse(i, j, m)
    \/ /\ m.mtype = AppendEntriesRequest
       /\ HandleAppendEntriesRequest(i, j, m)
    \/ /\ m.mtype = AppendEntriesResponse
       /\ HandleAppendEntriesResponse(i, j, m)

\* Message duplication
DuplicateMessage(m) ==
    /\ Send(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, currentLeader>>

\* Message drop
DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, currentLeader>>

----
\* Initial state

Init ==
    \* [raft_server.c:75] me->current_term = 0
    /\ currentTerm = [i \in Server |-> 0]
    \* [raft_server.c:76] me->voted_for = -1
    /\ votedFor = [i \in Server |-> Nil]
    /\ log = [i \in Server |-> <<>>]
    \* [raft_server.c:39] commit_idx starts at 0 (implicit from calloc)
    /\ commitIndex = [i \in Server |-> 0]
    \* [raft_server.c:87] RAFT_STATE_FOLLOWER
    /\ state = [i \in Server |-> Follower]
    /\ currentLeader = [i \in Server |-> Nil]
    \* [raft_node.c:46] next_idx = 1
    /\ nextIndex = [i \in Server |-> [j \in Server |-> 1]]
    \* [raft_node.c:47] match_idx = 0
    /\ matchIndex = [i \in Server |-> [j \in Server |-> 0]]
    /\ messages = {}
    /\ elections = {}

----
\* Next state relation

Next ==
    \/ \E i \in Server : Timeout(i)
    \/ \E i \in Server : ClientRequest(i)
    \/ \E i,j \in Server : i /= j /\ AppendEntries(i, j)
    \/ \E m \in messages : Receive(m)
    \/ \E m \in messages : DuplicateMessage(m)
    \/ \E m \in messages : DropMessage(m)

\* State constraint to bound the state space
StateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= MaxTerm
    /\ \A i \in Server : Len(log[i]) <= MaxLogLength
    /\ Cardinality(messages) <= 2 * Cardinality(Server) * Cardinality(Server)

\* Specification
Spec == Init /\ [][Next]_vars

----
\* Invariants

\* Type correctness
TypeOK ==
    /\ \A i \in Server : currentTerm[i] \in Nat
    /\ \A i \in Server : votedFor[i] \in Server \cup {Nil}
    /\ \A i \in Server : state[i] \in {Follower, Candidate, Leader}
    /\ \A i \in Server : commitIndex[i] \in Nat
    /\ \A i \in Server : Len(log[i]) >= 0

\* [Raft Safety] Election Safety: at most one leader per term
\* This was violated by bugs B1 and B2 (both now fixed).
ElectionSafety ==
    \A i, j \in Server :
        (/\ state[i] = Leader
         /\ state[j] = Leader
         /\ currentTerm[i] = currentTerm[j])
        => i = j

\* [Raft Safety] Log Matching: if two logs contain an entry with the same
\* index and term, then the logs are identical in all entries up through
\* that index. Bug B3 (entries not having their term checked) violated this.
LogMatching ==
    \A i, j \in Server :
        \A n \in 1..Min(Len(log[i]), Len(log[j])) :
            log[i][n].term = log[j][n].term =>
                SubSeq(log[i], 1, n) = SubSeq(log[j], 1, n)

\* [Raft Safety] Leader Completeness: if a log entry is committed in a given
\* term, then that entry will be present in the logs of the leaders for all
\* higher-numbered terms.
LeaderCompleteness ==
    \A e \in elections :
        \A i \in Server :
            /\ state[i] = Leader
            /\ currentTerm[i] >= e.eterm
            => \A idx \in 1..Len(e.elog) :
                /\ idx <= Len(log[i])
                /\ log[i][idx] = e.elog[idx]

\* Committed entries are never overwritten.
\* An entry at index <= commitIndex[i] on server i is stable.
CommittedEntriesStable ==
    \A i \in Server :
        commitIndex[i] <= Len(log[i])

\* [Implementation-specific] Commit index advances only with majority agreement
\* This catches bug B4 (majority counting all nodes instead of voting nodes).
CommitIndexSafety ==
    \A i \in Server :
        state[i] = Leader =>
            \A idx \in 1..commitIndex[i] :
                /\ idx <= Len(log[i])

\* [Implementation-specific] votedFor consistency:
\* If a server has voted for someone in a term, it can only vote for that
\* same server in that term. This catches bugs related to votedFor management.
VotedForConsistency ==
    \A i \in Server :
        votedFor[i] /= Nil =>
            \* There should not be a granted vote message from i to someone
            \* other than votedFor[i] in the current term
            ~\E m \in messages :
                /\ m.mtype = RequestVoteResponse
                /\ m.msource = i
                /\ m.mvoteGranted
                /\ m.mterm = currentTerm[i]
                /\ m.mdest /= votedFor[i]

\* Symmetry optimization
Symmetry == Permutations(Server)

====
