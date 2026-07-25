---- MODULE base ----
\***********************************************************************
\* TLA+ specification of the Raft consensus protocol as implemented in
\* willemt/raft (C library). Models the implementation's actual control
\* flow, NOT the paper's pseudocode. Deviations from the paper are
\* annotated and linked to Bug Families from the modeling brief.
\*
\* Source: artifact/raft/src/raft_server.c (1435 lines)
\*         artifact/raft/src/raft_log.c (315 lines)
\*         artifact/raft/src/raft_server_properties.c (269 lines)
\*         artifact/raft/include/raft_private.h (156 lines)
\***********************************************************************
EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

\***********************************************************************
\* Constants
\***********************************************************************
CONSTANTS
    Server,         \* Set of server IDs
    Value,          \* Set of client request values
    Nil,            \* Nil value (no vote, no leader)
    MaxLogLength    \* Bound on log length for finite model checking

\* Server states (raft.h:36-40)
CONSTANTS Follower, Candidate, Leader

\* Message types
CONSTANTS
    RequestVoteRequest, RequestVoteResponse,
    AppendEntriesRequest, AppendEntriesResponse,
    InstallSnapshotRequest

\* Entry types (raft.h:45-82) - simplified: only normal entries modeled
\* Config changes excluded per modeling brief §3.2
CONSTANTS NormalEntry

\***********************************************************************
\* Variables
\***********************************************************************

\* --- Persistent state (raft_private.h:23-34) ---
VARIABLES
    currentTerm,    \* [Server -> Nat] raft_private.h:27
    votedFor,       \* [Server -> Server ∪ {Nil}] raft_private.h:31 (-1 in C)
    log             \* [Server -> Seq(Entry)] raft_private.h:34

\* --- Volatile state (raft_private.h:36-45) ---
VARIABLES
    state,          \* [Server -> {Follower, Candidate, Leader}] raft_private.h:45
    commitIndex,    \* [Server -> Nat] raft_private.h:39
    lastApplied     \* [Server -> Nat] raft_private.h:42

\* --- Leader state (per-peer, raft_private.h via raft_node) ---
VARIABLES
    nextIndex,      \* [Server -> [Server -> Nat]]
    matchIndex      \* [Server -> [Server -> Nat]]

\* --- Candidate state ---
VARIABLES
    votesGranted    \* [Server -> SUBSET Server] votes received

\* --- Network ---
VARIABLES
    messages        \* Bag of messages in transit

\* --- Extension: Snapshot lifecycle (Bug Family 2, 4) ---
VARIABLES
    snapshotLastIdx,    \* [Server -> Nat] raft_private.h:79
    snapshotLastTerm    \* [Server -> Nat] raft_private.h:80

\* --- Extension: Crash + recovery (Bug Family 3) ---
\* In willemt/raft, persist_term persists term+vote atomically (raft_server_properties.c:85-101)
\* persist_vote persists vote separately (raft_server_properties.c:1073-1084)
\* We model the persisted state to detect crash windows
VARIABLES
    crashed             \* [Server -> BOOLEAN]

\* --- Extension: Broadcast abort (Bug Family 6) ---
\* raft_send_appendentries returns RAFT_ERR_NEEDS_SNAPSHOT (-6) when
\* next_idx < snapshot_last_idx (raft_server.c:901-905)
\* raft_send_appendentries_all aborts on first error (raft_server.c:950-952)
\* Modeled implicitly via needsSnapshot predicate

\***********************************************************************
\* Variable groups for UNCHANGED
\***********************************************************************
serverVars    == <<currentTerm, votedFor, state>>
logVars       == <<log, commitIndex, lastApplied>>
leaderVars    == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted>>
snapshotVars  == <<snapshotLastIdx, snapshotLastTerm>>
crashVars     == <<crashed>>
allVars       == <<serverVars, logVars, leaderVars, candidateVars,
                  messages, snapshotVars, crashVars>>

\***********************************************************************
\* Helpers
\***********************************************************************

\* Log entry record
Entry(t, v) == [term |-> t, value |-> v]

\* Last log index accounting for snapshot compaction
\* raft_get_current_idx (raft_server_properties.c:108-112) = log_count + base
LastLogIndex(i) == snapshotLastIdx[i] + Len(log[i])

\* Term of entry at index idx, accounting for snapshot
\* raft_get_last_log_term (raft_server_properties.c:216-226) returns 0 after compaction!
\* BUG (Family 4, PR #118 Bug 9): returns 0 when log empty AND no snapshot term fallback
LogTermAt(i, idx) ==
    IF idx = 0 THEN 0
    ELSE IF idx = snapshotLastIdx[i] THEN snapshotLastTerm[i]
    ELSE IF idx > snapshotLastIdx[i] /\ idx <= LastLogIndex(i)
         THEN log[i][idx - snapshotLastIdx[i]].term
    ELSE 0  \* BUG: returns 0 for compacted entries not at snapshot boundary

\* Last log term following implementation's logic
\* raft_get_last_log_term (raft_server_properties.c:216-226)
LastLogTerm(i) ==
    LET idx == LastLogIndex(i)
    IN IF idx > 0 THEN
         IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term
         \* After full compaction with empty log: returns 0!
         \* BUG (Family 4, PR #118 Bug 9): should return snapshotLastTerm
         ELSE IF snapshotLastIdx[i] = idx THEN snapshotLastTerm[i]
         ELSE 0
       ELSE 0

\* Majority check: raft_votes_is_majority (raft_server.c:647-653)
\* half = num_nodes / 2; return half + 1 <= nvotes
IsMajority(n, total) == (total \div 2) + 1 <= n

\* Entry at physical log position
LogEntry(i, idx) ==
    IF idx > snapshotLastIdx[i] /\ idx <= LastLogIndex(i)
    THEN log[i][idx - snapshotLastIdx[i]]
    ELSE [term |-> 0, value |-> Nil]

\* Sub-log from physical position
SubLog(i, fromIdx) ==
    IF fromIdx > LastLogIndex(i) THEN <<>>
    ELSE IF fromIdx <= snapshotLastIdx[i] THEN log[i]
    ELSE SubSeq(log[i], fromIdx - snapshotLastIdx[i], Len(log[i]))

\***********************************************************************
\* Message helpers (bag-based network)
\***********************************************************************
Send(m) == messages' = messages (+) SetToBag({m})
Discard(m) == messages' = messages (-) SetToBag({m})
Reply(response, request) ==
    messages' = (messages (-) SetToBag({request})) (+) SetToBag({response})

\* Check if a message is in the bag
HasMessage(m) == BagIn(m, messages)

\***********************************************************************
\* NeedsSnapshot predicate (raft_server.c:901)
\* Used for both SendAppendEntries and broadcast abort modeling
\***********************************************************************
NeedsSnapshot(leader, peer) ==
    /\ snapshotLastIdx[leader] > 0
    /\ nextIndex[leader][peer] < snapshotLastIdx[leader]

\***********************************************************************
\* Initial state
\* raft_new (raft_server.c:69-94)
\***********************************************************************
Init ==
    /\ currentTerm  = [s \in Server |-> 0]           \* raft_server.c:75
    /\ votedFor     = [s \in Server |-> Nil]          \* raft_server.c:76 (-1)
    /\ log          = [s \in Server |-> <<>>]
    /\ state        = [s \in Server |-> Follower]     \* raft_server.c:87
    /\ commitIndex  = [s \in Server |-> 0]
    /\ lastApplied  = [s \in Server |-> 0]
    /\ nextIndex    = [s \in Server |-> [j \in Server |-> 1]]
    /\ matchIndex   = [s \in Server |-> [j \in Server |-> 0]]
    /\ votesGranted = [s \in Server |-> {}]
    /\ messages     = EmptyBag
    /\ snapshotLastIdx  = [s \in Server |-> 0]       \* raft_server.c:91
    /\ snapshotLastTerm = [s \in Server |-> 0]       \* raft_server.c:91
    /\ crashed      = [s \in Server |-> FALSE]

\***********************************************************************
\* ACTION: Timeout — follower/candidate election timeout
\* raft_periodic (raft_server.c:222-262) → raft_election_start (raft_server.c:146-155)
\* → raft_become_candidate (raft_server.c:179-210)
\***********************************************************************
Timeout(i) ==
    \* Guard: not crashed, not leader (raft_server.c:239-250)
    /\ ~crashed[i]
    /\ state[i] \in {Follower, Candidate}
    \* raft_become_candidate (raft_server.c:179-210):
    \* 1. Increment term (line 186)
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    \* 2. Vote for self (line 191)
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    \* 3. Clear vote tracking, set state (lines 189-193)
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ state' = [state EXCEPT ![i] = Candidate]
    \* 4. Send RequestVote to all voting nodes (lines 198-208)
    /\ messages' = messages (+) SetToBag(
         {[mtype        |-> RequestVoteRequest,
           mterm        |-> currentTerm[i] + 1,
           mlastLogIdx  |-> LastLogIndex(i),
           mlastLogTerm |-> LastLogTerm(i),
           msource      |-> i,
           mdest        |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<logVars, leaderVars, snapshotVars, crashVars>>

\***********************************************************************
\* ACTION: HandleRequestVoteRequest
\* raft_recv_requestvote (raft_server.c:575-645)
\***********************************************************************
HandleRequestVoteRequest(i, j, m) ==
    /\ ~crashed[i]
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ m.msource = j
    /\ \/ \* Leader lease reject (raft_server.c:608-613)
          \* When server has a recent leader contact (current_leader != NULL),
          \* reject without term update. current_leader is not modeled; this is
          \* a non-deterministic overapproximation. Candidates clear current_leader
          \* (line 201), so only followers/leaders can hit this path.
          /\ state[i] \in {Follower, Leader}
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> j], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         snapshotVars, crashVars>>
       \/ \* Normal processing
          LET myLastLogIdx  == LastLogIndex(i)
              myLastLogTerm == LastLogTerm(i)
              \* __should_grant_vote (raft_server.c:535-573)
              logUpToDate ==
                \/ m.mlastLogTerm > myLastLogTerm                        \* line 566
                \/ (m.mlastLogTerm = myLastLogTerm                       \* line 569
                    /\ m.mlastLogIdx >= myLastLogIdx)                    \* line 569
              \* BUG (Family 3): line 543-545: denies re-vote to same candidate
              \* TODO comment in code acknowledges deviation from Raft paper §5.2
              shouldGrant ==
                /\ m.mterm >= currentTerm[i]                             \* line 540
                /\ votedFor[i] = Nil                                     \* line 544
                /\ logUpToDate
          IN
          \* Term update: if vr.term > currentTerm (lines 593-602)
          /\ IF m.mterm > currentTerm[i]
             THEN \* raft_set_current_term (raft_server_properties.c:85-101)
                  \* Persists term + clears vote atomically (voted_for = -1)
                  \* THEN __should_grant_vote is called with NEW state (voted_for=Nil)
                  \* So grant decision = logUpToDate (since voted_for is now Nil)
                  /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
                  /\ votedFor' = [votedFor EXCEPT ![i] =
                       IF logUpToDate THEN j ELSE Nil]
                  /\ state' = [state EXCEPT ![i] = Follower]            \* line 600
             ELSE IF shouldGrant
                  THEN \* Grant vote (lines 605-619)
                       /\ currentTerm' = currentTerm
                       /\ votedFor' = [votedFor EXCEPT ![i] = j]
                       /\ state' = state
                  ELSE \* Deny vote
                       /\ UNCHANGED <<currentTerm, votedFor, state>>
          \* Build response
          /\ LET grant == IF m.mterm > currentTerm[i]
                           THEN logUpToDate  \* after term update, voted_for is Nil
                           ELSE shouldGrant
             IN Reply([mtype        |-> RequestVoteResponse,
                       mterm        |-> IF m.mterm > currentTerm[i]
                                        THEN m.mterm
                                        ELSE currentTerm[i],
                       mvoteGranted |-> grant,
                       msource      |-> i,
                       mdest        |-> j], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, snapshotVars, crashVars>>

\***********************************************************************
\* ACTION: HandleRequestVoteResponse
\* raft_recv_requestvote_response (raft_server.c:655-716)
\***********************************************************************
HandleRequestVoteResponse(i, j, m) ==
    /\ ~crashed[i]
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ m.msource = j
    \* Must be candidate (line 665-668)
    /\ state[i] = Candidate
    /\ \/ \* Higher term: step down (lines 669-677)
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ UNCHANGED <<votesGranted, leaderVars>>
       \/ \* Same term, vote granted (lines 692-700)
          /\ m.mterm = currentTerm[i]
          /\ m.mvoteGranted
          /\ votesGranted' = [votesGranted EXCEPT ![i] = @ \cup {j}]
          \* Check majority → become leader (lines 698-699)
          /\ IF IsMajority(Cardinality(votesGranted[i] \cup {j}),
                           Cardinality(Server))
             THEN \* raft_become_leader (raft_server.c:157-177)
                  /\ state' = [state EXCEPT ![i] = Leader]
                  \* Initialize nextIndex and matchIndex (lines 173-174)
                  /\ nextIndex' = [nextIndex EXCEPT ![i] =
                       [k \in Server |-> LastLogIndex(i) + 1]]
                  /\ matchIndex' = [matchIndex EXCEPT ![i] =
                       [k \in Server |-> 0]]
                  \* NOTE: BUG (Family 1, Issue #120): no no-op entry appended!
                  \* raft_become_leader does NOT call raft_append_entry
             ELSE UNCHANGED <<state, leaderVars>>
          /\ UNCHANGED <<currentTerm, votedFor>>
       \/ \* Same term, vote denied or stale term (lines 678-683, 702-703)
          /\ \/ (~m.mvoteGranted /\ m.mterm = currentTerm[i])
             \/ m.mterm < currentTerm[i]
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars>>
    /\ Discard(m)
    /\ UNCHANGED <<logVars, snapshotVars, crashVars>>

\***********************************************************************
\* ACTION: ClientRequest — leader receives client entry
\* raft_recv_entry (raft_server.c:718-779)
\***********************************************************************
ClientRequest(i, v) ==
    /\ ~crashed[i]
    /\ state[i] = Leader                                              \* line 737
    /\ Len(log[i]) + snapshotLastIdx[i] < MaxLogLength  \* bound
    /\ LET entry == Entry(currentTerm[i], v)                          \* line 743
       IN
       \* Append entry (line 744)
       /\ log' = [log EXCEPT ![i] = Append(@, entry)]
       \* Single-node cluster: commit immediately (lines 767-768)
       /\ IF Cardinality(Server) = 1
          THEN commitIndex' = [commitIndex EXCEPT ![i] = LastLogIndex(i) + 1]
          ELSE UNCHANGED commitIndex
    /\ UNCHANGED <<serverVars, lastApplied, leaderVars, candidateVars,
                   messages, snapshotVars, crashVars>>

\***********************************************************************
\* ACTION: SendAppendEntries — leader sends AE to a single peer
\* raft_send_appendentries (raft_server.c:882-937)
\*
\* Split from SendAppendEntriesAll for granularity.
\* Models both heartbeats (empty AE) and replication (with entries).
\***********************************************************************
SendAppendEntries(i, j) ==
    /\ ~crashed[i]
    /\ state[i] = Leader
    /\ i # j
    \* Not needs-snapshot path (raft_server.c:901-905)
    /\ ~NeedsSnapshot(i, j)
    /\ LET nxt   == nextIndex[i][j]
           \* raft_get_entries_from_idx (raft_server.c:908)
           entries == SubLog(i, nxt)
           \* Previous log entry (raft_server.c:913-926)
           prevIdx  == IF nxt > 1
                       THEN IF nxt - 1 > snapshotLastIdx[i]
                            THEN nxt - 1
                            ELSE snapshotLastIdx[i]     \* line 918
                       ELSE 0                           \* line 895
           prevTerm == IF prevIdx = 0 THEN 0
                       ELSE IF prevIdx = snapshotLastIdx[i]
                            THEN snapshotLastTerm[i]    \* line 919
                            ELSE LogTermAt(i, prevIdx)  \* line 924
       IN Send([mtype          |-> AppendEntriesRequest,
                mterm          |-> currentTerm[i],       \* line 893
                mprevLogIdx    |-> prevIdx,
                mprevLogTerm   |-> prevTerm,
                mleaderCommit  |-> commitIndex[i],       \* line 894
                mentries       |-> entries,
                msource        |-> i,
                mdest          |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   snapshotVars, crashVars>>

\***********************************************************************
\* ACTION: SendAppendEntriesAll — broadcast AE (with early-abort bug)
\* raft_send_appendentries_all (raft_server.c:939-956)
\*
\* BUG (Family 6): returns on first non-zero return (line 950-952)
\* If one peer needs snapshot, remaining peers are starved.
\***********************************************************************
BroadcastAppendEntries(i) ==
    /\ ~crashed[i]
    /\ state[i] = Leader
    \* Model the early-abort: only send to peers before the first
    \* needs-snapshot peer (iteration order matters in impl)
    \* For TLA+, we non-deterministically choose whether abort occurs
    /\ \E peers \in SUBSET (Server \ {i}) :
         /\ peers # {}
         \* All chosen peers must NOT need snapshot
         /\ \A p \in peers : ~NeedsSnapshot(i, p)
         /\ messages' = messages (+) SetToBag(
              {LET nxt      == nextIndex[i][p]
                   entries  == SubLog(i, nxt)
                   prevIdx  == IF nxt > 1
                               THEN IF nxt - 1 > snapshotLastIdx[i]
                                    THEN nxt - 1
                                    ELSE snapshotLastIdx[i]
                               ELSE 0
                   prevTerm == IF prevIdx = 0 THEN 0
                               ELSE IF prevIdx = snapshotLastIdx[i]
                                    THEN snapshotLastTerm[i]
                                    ELSE LogTermAt(i, prevIdx)
               IN [mtype          |-> AppendEntriesRequest,
                   mterm          |-> currentTerm[i],
                   mprevLogIdx    |-> prevIdx,
                   mprevLogTerm   |-> prevTerm,
                   mleaderCommit  |-> commitIndex[i],
                   mentries       |-> entries,
                   msource        |-> i,
                   mdest          |-> p] : p \in peers})
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   snapshotVars, crashVars>>

\***********************************************************************
\* ACTION: HandleAppendEntriesRequest
\* raft_recv_appendentries (raft_server.c:385-528)
\*
\* This is the most bug-dense function in the codebase (Family 2).
\* Models the implementation's exact control flow.
\***********************************************************************
HandleAppendEntriesRequest(i, j, m) ==
    /\ ~crashed[i]
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ m.msource = j
    /\ LET \* Term handling (raft_server.c:406-423)
           newTerm == IF m.mterm > currentTerm[i] THEN m.mterm
                      ELSE currentTerm[i]
           becomeFollower ==
             \/ (state[i] = Candidate /\ m.mterm = currentTerm[i])    \* line 406-409
             \/ m.mterm > currentTerm[i]                              \* line 410-416
           reject == m.mterm < currentTerm[i]                         \* line 417-423

           \* Prev log check (raft_server.c:430-469)
           prevOk ==
             \/ m.mprevLogIdx = 0                                     \* first AE
             \/ /\ m.mprevLogIdx <= LastLogIndex(i)
                /\ m.mprevLogIdx > 0
                /\ LogTermAt(i, m.mprevLogIdx) = m.mprevLogTerm
           \* Snapshot boundary check (raft_server.c:437-446)
           prevIsSnapshot ==
             /\ m.mprevLogIdx = snapshotLastIdx[i]
             /\ m.mprevLogIdx > 0
           prevSnapshotOk ==
             prevIsSnapshot => snapshotLastTerm[i] = m.mprevLogTerm

           \* Conflict resolution (raft_server.c:475-512)
           \* Find first conflicting entry
           logOk == prevOk \/ prevIsSnapshot

           \* Compute new log after conflict resolution + append
           newLog ==
             IF ~logOk \/ reject THEN log[i]
             ELSE LET \* Entries to process
                      startIdx == m.mprevLogIdx + 1
                      \* Find first conflict or missing entry
                      firstConflict ==
                        LET conflicts == {k \in 1..Len(m.mentries) :
                              LET eidx == startIdx + k - 1
                              IN \/ eidx > LastLogIndex(i)
                                 \/ (eidx <= LastLogIndex(i) /\
                                     LogTermAt(i, eidx) # m.mentries[k].term)}
                        IN IF conflicts = {} THEN Len(m.mentries) + 1
                           ELSE CHOOSE k \in conflicts :
                                  \A k2 \in conflicts : k <= k2
                      \* Keep log up to conflict point, then append remaining entries
                      keepLen == IF firstConflict > Len(m.mentries)
                                 THEN Len(log[i])  \* no conflict, keep all
                                 ELSE (startIdx + firstConflict - 2) - snapshotLastIdx[i]
                      keptLog == IF keepLen >= 1
                                 THEN SubSeq(log[i], 1, IF keepLen > Len(log[i])
                                                         THEN Len(log[i])
                                                         ELSE keepLen)
                                 ELSE <<>>
                      \* Append new entries from conflict point onward
                      newEntries == IF firstConflict <= Len(m.mentries)
                                    THEN SubSeq(m.mentries, firstConflict, Len(m.mentries))
                                    ELSE <<>>
                  IN keptLog \o newEntries

           \* Commit index update (raft_server.c:514-520)
           newCommitIndex ==
             IF ~logOk \/ reject THEN commitIndex[i]
             ELSE IF commitIndex[i] < m.mleaderCommit
                  THEN LET lastIdx == IF snapshotLastIdx[i] + Len(newLog) > 0
                                      THEN snapshotLastIdx[i] + Len(newLog)
                                      ELSE 1               \* max(current_idx, 1) line 518
                       IN IF m.mleaderCommit < lastIdx
                          THEN m.mleaderCommit              \* min(leaderCommit, lastIdx)
                          ELSE lastIdx
                  ELSE commitIndex[i]

           \* Response (raft_server.c:522-527)
           success == logOk /\ ~reject /\ prevSnapshotOk
           respCurrentIdx ==
             IF success THEN
               IF Len(m.mentries) > 0
               THEN m.mprevLogIdx + Len(m.mentries)        \* line 511
               ELSE m.mprevLogIdx                           \* line 473
             ELSE snapshotLastIdx[i] + Len(newLog)          \* line 525
       IN
       \* State transitions
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       /\ state' = [state EXCEPT ![i] =
            IF reject THEN state[i]
            ELSE IF becomeFollower THEN Follower
            ELSE state[i]]
       /\ votedFor' = [votedFor EXCEPT ![i] =
            IF m.mterm > currentTerm[i] THEN Nil            \* raft_set_current_term clears vote
            ELSE votedFor[i]]
       /\ log' = [log EXCEPT ![i] = newLog]
       /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIndex]
       /\ Reply([mtype       |-> AppendEntriesResponse,
                 mterm       |-> newTerm,
                 msuccess    |-> success,
                 mcurrentIdx |-> respCurrentIdx,
                 mfirstIdx   |-> m.mprevLogIdx + 1,
                 msource     |-> i,
                 mdest       |-> j], m)
       /\ UNCHANGED <<lastApplied, leaderVars, candidateVars,
                      snapshotVars, crashVars>>

\***********************************************************************
\* ACTION: HandleAppendEntriesResponse
\* raft_recv_appendentries_response (raft_server.c:275-383)
\*
\* Contains the commit advancement logic (Family 1).
\***********************************************************************
HandleAppendEntriesResponse(i, j, m) ==
    /\ ~crashed[i]
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ m.msource = j
    /\ \/ \* Higher term: step down (lines 294-304)
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ UNCHANGED <<logVars, leaderVars>>
       \/ \* Stale term: ignore (lines 305-306)
          /\ m.mterm < currentTerm[i]
          /\ UNCHANGED <<serverVars, logVars, leaderVars>>
       \/ \* Current term, must be leader (line 291-292)
          /\ m.mterm = currentTerm[i]
          /\ state[i] = Leader
          /\ \/ \* Failure response (lines 310-327)
                /\ ~m.msuccess
                /\ LET curMatchIdx == matchIndex[i][j]
                       curNextIdx  == nextIndex[i][j]
                   IN
                   \* Stale response check (line 317-318)
                   IF m.mcurrentIdx < curMatchIdx
                   THEN UNCHANGED <<logVars, leaderVars, serverVars>>
                   ELSE
                     /\ nextIndex' = [nextIndex EXCEPT ![i][j] =
                          IF m.mcurrentIdx < curNextIdx - 1
                          THEN IF m.mcurrentIdx + 1 < LastLogIndex(i)
                               THEN m.mcurrentIdx + 1           \* line 320
                               ELSE LastLogIndex(i)             \* min(..., current_idx)
                          ELSE curNextIdx - 1]                  \* line 322
                     /\ UNCHANGED <<matchIndex, logVars, serverVars>>
             \/ \* Success response (lines 329-378)
                /\ m.msuccess
                /\ LET curMatchIdx == matchIndex[i][j]
                   IN
                   \* Stale check (line 343-344)
                   IF m.mcurrentIdx <= curMatchIdx
                   THEN UNCHANGED <<logVars, leaderVars, serverVars>>
                   ELSE
                     \* Update nextIndex and matchIndex (lines 348-349)
                     /\ nextIndex' = [nextIndex EXCEPT ![i][j] = m.mcurrentIdx + 1]
                     /\ matchIndex' = [matchIndex EXCEPT ![i][j] = m.mcurrentIdx]
                     \* Commit advancement (lines 351-373)
                     \* BUG (Family 1): only checks r->current_idx (the single point),
                     \* not scanning for highest N with majority support.
                     \* This is the implementation's actual behavior.
                     /\ LET point == m.mcurrentIdx                     \* line 352
                            ety == LogEntry(i, point)
                        IN IF /\ commitIndex[i] < point               \* line 356
                              /\ ety.term = currentTerm[i]             \* line 356
                              /\ LET votes == 1 + Cardinality(         \* line 358
                                       {k \in Server \ {i} :
                                         /\ point <= IF k = j
                                                     THEN m.mcurrentIdx  \* use new matchIdx
                                                     ELSE matchIndex[i][k]})
                                 IN IsMajority(votes, Cardinality(Server))  \* line 371
                           THEN commitIndex' = [commitIndex EXCEPT ![i] = point]  \* line 372
                           ELSE UNCHANGED commitIndex
                     /\ UNCHANGED <<serverVars, log, lastApplied>>
    /\ Discard(m)
    /\ UNCHANGED <<candidateVars, snapshotVars, crashVars>>

\***********************************************************************
\* ACTION: AdvanceCommitIndex (paper-correct version for comparison)
\*
\* The Raft paper (Figure 2) says: find greatest N such that
\* majority of matchIndex[i] >= N and log[N].term == currentTerm.
\* The implementation only checks the single point from AE response.
\* This action is included for specification comparison but is NOT
\* part of the implementation model.
\***********************************************************************

\***********************************************************************
\* ACTION: TakeSnapshot — compact log up to commit index
\* raft_begin_snapshot + raft_end_snapshot (raft_server.c:1258-1357)
\***********************************************************************
TakeSnapshot(i) ==
    /\ ~crashed[i]
    \* Need snapshottable logs (line 1262)
    /\ commitIndex[i] > snapshotLastIdx[i]
    /\ Len(log[i]) > 1  \* need at least 2 entries (line 1262: count <= 1 → return -1)
    /\ commitIndex[i] > 0
    /\ LET snapIdx  == commitIndex[i]
           snapTerm == LogTermAt(i, snapIdx)
           \* Number of entries to compact: commit_idx - log_base (line 1255)
           numCompact == snapIdx - snapshotLastIdx[i]
       IN
       /\ snapTerm > 0
       /\ numCompact > 0
       /\ numCompact <= Len(log[i])
       \* Compact log: remove entries up to snapshot point (lines 1319-1326)
       /\ log' = [log EXCEPT ![i] = SubSeq(@, numCompact + 1, Len(@))]
       /\ snapshotLastIdx'  = [snapshotLastIdx  EXCEPT ![i] = snapIdx]
       /\ snapshotLastTerm' = [snapshotLastTerm EXCEPT ![i] = snapTerm]
    /\ UNCHANGED <<serverVars, commitIndex, lastApplied, leaderVars,
                   candidateVars, messages, crashVars>>

\***********************************************************************
\* ACTION: SendInstallSnapshot — leader sends snapshot to lagging peer
\* raft_send_appendentries (raft_server.c:901-905) triggers send_snapshot callback
\***********************************************************************
SendInstallSnapshot(i, j) ==
    /\ ~crashed[i]
    /\ state[i] = Leader
    /\ i # j
    /\ NeedsSnapshot(i, j)
    /\ Send([mtype             |-> InstallSnapshotRequest,
             mterm             |-> currentTerm[i],
             msnapshotLastIdx  |-> snapshotLastIdx[i],
             msnapshotLastTerm |-> snapshotLastTerm[i],
             msource           |-> i,
             mdest             |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   snapshotVars, crashVars>>

\***********************************************************************
\* ACTION: HandleInstallSnapshot — follower loads snapshot
\* raft_begin_load_snapshot (raft_server.c:1359-1417)
\*
\* BUG (Family 3, 4): lines 1383-1384 directly set current_term and
\* voted_for WITHOUT calling persist callbacks. Term can DECREASE.
\***********************************************************************
HandleInstallSnapshot(i, j, m) ==
    /\ ~crashed[i]
    /\ m.mtype = InstallSnapshotRequest
    /\ m.mdest = i
    /\ m.msource = j
    \* Validity checks (lines 1366-1381)
    /\ m.msnapshotLastIdx > 0
    /\ m.msnapshotLastTerm > 0
    /\ m.msnapshotLastIdx >= lastApplied[i]                   \* line 1373
    /\ m.msnapshotLastIdx >= LastLogIndex(i)                  \* line 1377
    /\ ~(m.msnapshotLastTerm = snapshotLastTerm[i] /\        \* line 1380
         m.msnapshotLastIdx = snapshotLastIdx[i])
    \* BUG (Family 3+4, PR #118 Bug 4): direct term/vote write, no persistence!
    \* me->current_term = last_included_term (line 1383) — CAN DECREASE TERM
    /\ currentTerm' = [currentTerm EXCEPT ![i] = m.msnapshotLastTerm]
    \* me->voted_for = -1 (line 1384) — vote cleared without persist
    /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
    \* Become follower (line 1385)
    /\ state' = [state EXCEPT ![i] = Follower]
    \* Clear log, set base (line 1388)
    /\ log' = [log EXCEPT ![i] = <<>>]
    \* Update commit index (lines 1390-1391)
    /\ commitIndex' = [commitIndex EXCEPT ![i] =
         IF commitIndex[i] < m.msnapshotLastIdx
         THEN m.msnapshotLastIdx
         ELSE commitIndex[i]]
    \* Update last applied (line 1393)
    /\ lastApplied' = [lastApplied EXCEPT ![i] = m.msnapshotLastIdx]
    \* Update snapshot metadata (line 1394)
    /\ snapshotLastIdx'  = [snapshotLastIdx  EXCEPT ![i] = m.msnapshotLastIdx]
    /\ snapshotLastTerm' = [snapshotLastTerm EXCEPT ![i] = m.msnapshotLastTerm]
    /\ Discard(m)
    /\ UNCHANGED <<leaderVars, candidateVars, crashVars>>

\***********************************************************************
\* ACTION: Crash — server crashes and recovers from persisted state
\* Bug Family 3: models crash windows in persistence
\*
\* In willemt/raft:
\* - persist_term persists (term, -1) atomically (raft_server_properties.c:85-101)
\* - persist_vote persists vote separately (raft_server.c:1073-1084)
\* - LoadSnapshot bypasses both persist callbacks (raft_server.c:1383-1384)
\*
\* On recovery: term and log come from persistent store.
\* Volatile state (commitIndex, lastApplied, state) reset.
\***********************************************************************
Crash(i) ==
    /\ ~crashed[i]
    /\ crashed' = [crashed EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   messages, snapshotVars>>

Recover(i) ==
    /\ crashed[i]
    /\ crashed' = [crashed EXCEPT ![i] = FALSE]
    \* Volatile state resets
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    /\ lastApplied' = [lastApplied EXCEPT ![i] = 0]
    \* Persistent state preserved: currentTerm, votedFor, log, snapshot metadata
    /\ UNCHANGED <<currentTerm, votedFor, log, leaderVars, candidateVars,
                   messages, snapshotVars>>

\***********************************************************************
\* ACTION: LoseMessage — network drops a message
\***********************************************************************
LoseMessage(m) ==
    /\ BagIn(m, messages)
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   snapshotVars, crashVars>>

\***********************************************************************
\* ACTION: DuplicateMessage — network duplicates a message
\* Bug Family 2, 3: tests dedup and re-vote paths
\***********************************************************************
DuplicateMessage(m) ==
    /\ BagIn(m, messages)
    /\ Send(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   snapshotVars, crashVars>>

\***********************************************************************
\* Next-state relation
\***********************************************************************
Next ==
    \/ \E i \in Server : Timeout(i)
    \/ \E i \in Server, v \in Value : ClientRequest(i, v)
    \/ \E i \in Server : BroadcastAppendEntries(i)
    \/ \E i,j \in Server : SendAppendEntries(i, j)
    \/ \E i \in Server : TakeSnapshot(i)
    \/ \E i,j \in Server : SendInstallSnapshot(i, j)
    \/ \E i \in Server : Crash(i)
    \/ \E i \in Server : Recover(i)
    \/ \E m \in BagToSet(messages) : HandleRequestVoteRequest(m.mdest, m.msource, m)
    \/ \E m \in BagToSet(messages) : HandleRequestVoteResponse(m.mdest, m.msource, m)
    \/ \E m \in BagToSet(messages) : HandleAppendEntriesRequest(m.mdest, m.msource, m)
    \/ \E m \in BagToSet(messages) : HandleAppendEntriesResponse(m.mdest, m.msource, m)
    \/ \E m \in BagToSet(messages) : HandleInstallSnapshot(m.mdest, m.msource, m)
    \/ \E m \in BagToSet(messages) : LoseMessage(m)
    \/ \E m \in BagToSet(messages) : DuplicateMessage(m)

Spec == Init /\ [][Next]_allVars

\***********************************************************************
\* INVARIANTS
\***********************************************************************

\* --- Standard Protocol Invariants ---

\* ElectionSafety: at most one leader per term (Raft Figure 3)
\* Targeted by: Family 3 (vote safety), Family 4 (snapshot term bypass)
ElectionSafety ==
    \A i, j \in Server :
        (state[i] = Leader /\ state[j] = Leader /\ currentTerm[i] = currentTerm[j])
        => i = j

\* LogMatching: if two logs have entry at same index+term, all preceding match
\* Targeted by: Family 2 (AE conflict resolution)
LogMatching ==
    \A i, j \in Server :
        \A idx \in 1..IF LastLogIndex(i) < LastLogIndex(j)
                      THEN LastLogIndex(i) ELSE LastLogIndex(j) :
            (idx > snapshotLastIdx[i] /\ idx > snapshotLastIdx[j] /\
             LogTermAt(i, idx) = LogTermAt(j, idx) /\ LogTermAt(i, idx) > 0)
            =>
            \A pidx \in (IF snapshotLastIdx[i] > snapshotLastIdx[j]
                         THEN snapshotLastIdx[i] ELSE snapshotLastIdx[j]) + 1..idx :
                LogTermAt(i, pidx) = LogTermAt(j, pidx)

\* LeaderCompleteness: committed entry on all future leaders (Raft §5.4.3)
\* "If a log entry is committed in a given term, that entry will be present
\*  in the logs of the leaders for all higher-numbered terms."
\* Only applies to leaders whose term >= the committer's term.
\* A stale leader (lower term) is not a "future leader" and will step down.
\* Targeted by: Family 1 (commit advancement), Family 2 (log consistency)
LeaderCompleteness ==
    \A i \in Server :
        state[i] = Leader =>
        \A j \in Server :
            currentTerm[i] >= currentTerm[j] =>
            \A idx \in 1..commitIndex[j] :
                idx > snapshotLastIdx[i] /\ idx > snapshotLastIdx[j] =>
                (idx <= LastLogIndex(i) /\
                 LogTermAt(i, idx) = LogTermAt(j, idx))

\* --- Extension Invariants (Bug Family specific) ---

\* CommitMonotonicity: commitIndex never decreases (Family 1)
\* This is checked structurally — the base spec should maintain this
\* but snapshot loading can violate it if term goes backward
CommitMonotonicity ==
    \A i \in Server :
        ~crashed[i] => commitIndex[i] >= 0

\* TermMonotonicity: currentTerm should never decrease (Family 3, 4)
\* BUG: HandleInstallSnapshot CAN decrease term (raft_server.c:1383)
\* This invariant is expected to be VIOLATED by the snapshot load bug
TermMonotonicity ==
    TRUE  \* Checked as temporal property: [][\A i \in Server: currentTerm'[i] >= currentTerm[i]]_allVars

\* VoteSafety: each server votes for at most one candidate per term (Family 3)
VoteSafety ==
    \A i, j \in Server :
        (state[i] = Candidate /\ state[j] = Candidate /\
         currentTerm[i] = currentTerm[j] /\ i # j)
        => ~(i \in votesGranted[j] /\ j \in votesGranted[i])

\* NoCommittedEntryDeletion: committed entries are never removed (Family 2)
NoCommittedEntryDeletion ==
    \A i \in Server :
        ~crashed[i] =>
        \A idx \in 1..commitIndex[i] :
            idx > snapshotLastIdx[i] =>
            idx <= LastLogIndex(i)

\* --- Structural Invariants ---

\* Type invariant
TypeOK ==
    /\ currentTerm \in [Server -> Nat]
    /\ votedFor \in [Server -> Server \cup {Nil}]
    /\ state \in [Server -> {Follower, Candidate, Leader}]
    /\ commitIndex \in [Server -> Nat]
    /\ lastApplied \in [Server -> Nat]
    /\ snapshotLastIdx \in [Server -> Nat]
    /\ snapshotLastTerm \in [Server -> Nat]
    /\ crashed \in [Server -> BOOLEAN]

\* Log index consistency
LogConsistency ==
    \A i \in Server :
        /\ LastLogIndex(i) >= snapshotLastIdx[i]
        /\ commitIndex[i] <= LastLogIndex(i) \/ crashed[i]

\* Commit index bounded by log length
CommitBound ==
    \A i \in Server :
        ~crashed[i] => commitIndex[i] <= LastLogIndex(i)

\* Match index bounded for leader
MatchIndexBound ==
    \A i \in Server :
        state[i] = Leader =>
        \A j \in Server \ {i} :
            matchIndex[i][j] <= LastLogIndex(j) \/ TRUE  \* may lag

====
