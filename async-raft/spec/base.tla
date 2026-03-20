---------------------------- MODULE base ----------------------------
\* TLA+ specification of async-raft Raft consensus protocol.
\*
\* Extends standard Raft with async-raft-specific behaviors:
\*   1. Buggy quorum formula for reads: (len/2)-1 or len/2 (Bug Family 1)
\*   2. Buggy log up-to-date check: AND instead of lexicographic (Bug Family 2)
\*   3. Unconditional commit_index update in AppendEntries (Bug Family 3)
\*   4. Optimistic match_index initialization (Bug Family 3)
\*   5. Snapshot state clobbering (Bug Family 4)
\*   6. Client read continues after deposition (Bug Family 6)
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
          AppendEntriesResponse,
          InstallSnapshotRequest,
          InstallSnapshotResponse

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
VARIABLE matchTerm           \* [Server -> [Server -> Nat]] -- Bug Family 3: optimistic init

\* Candidate state
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension 1: Client read quorum tracking (Bug Family 1, 6)
\* Models the buggy quorum formula from client.rs:109-113
\* and the continuation after deposition from client.rs:181-184
VARIABLE readConfirmed       \* [Server -> Nat] -- confirmations received so far
VARIABLE readQuorum          \* [Server -> Nat] -- needed confirmations (buggy formula)
VARIABLE readActive          \* [Server -> BOOLEAN] -- TRUE = read in progress

\* Extension 2: Snapshot tracking (Bug Family 4)
\* Models incorrect state updates in install_snapshot.rs:135-138
VARIABLE snapshotIndex       \* [Server -> Nat] -- last snapshot index

\* Extension 3: Membership for joint consensus (Bug Family 1, 5)
\* Models membership config with optional C1 for joint consensus
VARIABLE membership          \* [Server -> [members |-> SUBSET Server,
                             \*             members_after |-> SUBSET Server \cup {Nil}]]

----
\* Variable groups
----

serverVars    == <<currentTerm, votedFor, state>>
logVars       == <<log, commitIndex>>
leaderVars    == <<nextIndex, matchIndex, matchTerm>>
candidateVars == <<votesGranted>>
readVars      == <<readConfirmed, readQuorum, readActive>>
snapshotVars  == <<snapshotIndex>>
memberVars    == <<membership>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          readVars, snapshotVars, memberVars>>

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

\* Standard quorum check: majority of voters
IsQuorum(S, voters) == Cardinality(S) * 2 > Cardinality(voters)

\* Buggy quorum formula from client.rs:109-113 (Bug Family 1)
\* For N nodes:
\*   even: (N/2) - 1 confirmations needed
\*   odd:  N/2 confirmations needed
\* Then pre-incremented by 1 for self (client.rs:122)
\* Result: for N=3, needs 1+1=2 but majority needs 2, so passes by 1
\*         for N=4, needs 1+1=2 but majority needs 3 — WRONG
\*         for N=5, needs 2+1=3 but majority needs 3 — borderline
BuggyQuorumNeeded(n) ==
    IF (n % 2) = 0
    THEN (n \div 2) - 1
    ELSE n \div 2

\* Correct log up-to-date check (Raft paper §5.4.1: lexicographic)
CorrectLogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    \/ cLastTerm > vLastTerm
    \/ (cLastTerm = vLastTerm /\ cLastIdx >= vLastIdx)

\* Buggy log up-to-date check from vote.rs:53 (Bug Family 2)
\* Uses AND instead of lexicographic comparison
BuggyLogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    (cLastTerm >= vLastTerm) /\ (cLastIdx >= vLastIdx)

\* All members across C0 and C1
AllMembers(i) ==
    IF membership[i].members_after = Nil
    THEN membership[i].members
    ELSE membership[i].members \cup membership[i].members_after

\* Joint quorum: majority of BOTH C0 and C1
IsJointQuorum(S, oldVoters, newVoters) ==
    /\ IsQuorum(S \cap oldVoters, oldVoters)
    /\ IsQuorum(S \cap newVoters, newVoters)

\* Effective quorum check: uses joint quorum if in joint consensus
QuorumCheck(S, i) ==
    IF membership[i].members_after = Nil
    THEN IsQuorum(S \cap membership[i].members, membership[i].members)
    ELSE IsJointQuorum(S, membership[i].members, membership[i].members_after)

\* Log entry record
Entry(t, ty) == [term |-> t, type |-> ty, config |-> {}]
ConfigEntryRec(t, m) == [term |-> t, type |-> ConfigEntry, config |-> m]

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
    /\ currentTerm   = [s \in Server |-> 0]
    /\ votedFor      = [s \in Server |-> Nil]
    /\ log           = [s \in Server |-> <<>>]
    /\ state         = [s \in Server |-> Follower]
    /\ commitIndex   = [s \in Server |-> 0]
    /\ nextIndex     = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex    = [s \in Server |-> [t \in Server |-> 0]]
    /\ matchTerm     = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted  = [s \in Server |-> {}]
    /\ messages      = EmptyBag
    /\ readConfirmed = [s \in Server |-> 0]
    /\ readQuorum    = [s \in Server |-> 0]
    /\ readActive    = [s \in Server |-> FALSE]
    /\ snapshotIndex = [s \in Server |-> 0]
    /\ membership    = [s \in Server |-> [members |-> Server,
                                          members_after |-> Nil]]

----
\* Election Actions
----

\* Server i times out and starts an election.
\* Reference: core/mod.rs:768-839 (CandidateState::run)
\* Increments term, votes for self, sends RequestVote to all members.
Timeout(i) ==
    /\ state[i] \in {Follower, Candidate}
    /\ i \in membership[i].members
    /\ LET newTerm == currentTerm[i] + 1
       IN
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       /\ state' = [state EXCEPT ![i] = Candidate]
       /\ votedFor' = [votedFor EXCEPT ![i] = i]
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
       \* core/mod.rs:786-789: increment term, self-vote, save hard state
       \* core/mod.rs:793: spawn_parallel_vote_requests
       \* vote.rs:145: VoteRequest with current_term, last_log_index, last_log_term
       /\ SendAll({[mtype         |-> RequestVoteRequest,
                    mterm         |-> newTerm,
                    mlastLogTerm  |-> LastLogTerm(i),
                    mlastLogIndex |-> LastLogIndex(i),
                    msource       |-> i,
                    mdest         |-> j] : j \in AllMembers(i) \ {i}})
    /\ UNCHANGED <<logVars, leaderVars, readVars, snapshotVars, memberVars>>

\* Server i handles RequestVote RPC from candidate.
\* Reference: vote.rs:15-93 (handle_vote_request)
\*
\* BUG FAMILY 2: vote.rs:53 uses AND instead of lexicographic for log comparison.
\* This rejects candidates with higher last_log_term but lower last_log_index.
HandleRequestVoteRequest(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ LET mterm == m.mterm
           \* Bug Family 2: buggy log up-to-date check (vote.rs:53)
           \* Uses (term >= myTerm) && (index >= myIndex) instead of lexicographic
           logOk == BuggyLogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                     LastLogTerm(i), LastLogIndex(i))
       IN
       \/ \* Reject: term too low (vote.rs:17-23)
          /\ mterm < currentTerm[i]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         readVars, snapshotVars, memberVars>>

       \/ \* Reject: log not up-to-date (vote.rs:54-63)
          \* Note: heartbeat recency check (vote.rs:26-39) modeled as non-deterministic
          \* skip since we don't model real time
          /\ mterm >= currentTerm[i]
          /\ ~logOk
          \* vote.rs:44-49: update term if higher
          /\ IF mterm > currentTerm[i]
             THEN /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
                  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
                  /\ state' = [state EXCEPT ![i] = Follower]
             ELSE UNCHANGED <<currentTerm, votedFor, state>>
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> Max(currentTerm[i], mterm),
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         readVars, snapshotVars, memberVars>>

       \/ \* Grant vote: log OK and haven't voted or voted for this candidate
          \* (vote.rs:69-92)
          /\ mterm >= currentTerm[i]
          /\ logOk
          /\ \/ votedFor[i] = Nil
             \/ votedFor[i] = m.msource
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> mterm,
                    mvoteGranted |-> TRUE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         readVars, snapshotVars, memberVars>>

       \/ \* Reject: already voted for different candidate (vote.rs:76-79)
          /\ mterm >= currentTerm[i]
          /\ logOk
          /\ votedFor[i] /= Nil
          /\ votedFor[i] /= m.msource
          /\ IF mterm > currentTerm[i]
             THEN /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
                  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
                  /\ state' = [state EXCEPT ![i] = Follower]
             ELSE UNCHANGED <<currentTerm, votedFor, state>>
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> Max(currentTerm[i], mterm),
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         readVars, snapshotVars, memberVars>>

\* Candidate i handles RequestVoteResponse.
\* Reference: vote.rs:99-137 (handle_vote_response)
HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ state[i] = Candidate
    /\ \/ \* Higher term: revert to follower (vote.rs:101-108)
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         readVars, snapshotVars, memberVars>>
       \/ \* Vote granted: count it (vote.rs:111-132)
          /\ m.mterm = currentTerm[i]
          /\ m.mvoteGranted
          /\ votesGranted' = [votesGranted EXCEPT ![i] = @ \cup {m.msource}]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars,
                         readVars, snapshotVars, memberVars>>
       \/ \* Vote rejected or stale: discard
          /\ \/ (m.mterm = currentTerm[i] /\ ~m.mvoteGranted)
             \/ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         readVars, snapshotVars, memberVars>>

\* Candidate i becomes leader after receiving quorum of votes.
\* Reference: core/mod.rs:588-602 (LeaderState::run entry point)
\*            core/replication.rs:13-33 (spawn_replication_stream)
\*
\* BUG FAMILY 3: Optimistic match_index/match_term initialization.
\* replication.rs:27-28: match_index = self.core.last_log_index,
\*                        match_term = self.core.current_term
\* Instead of standard Raft's match_index = 0.
BecomeLeader(i) ==
    /\ state[i] = Candidate
    /\ QuorumCheck(votesGranted[i], i)
    /\ state' = [state EXCEPT ![i] = Leader]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> LastLogIndex(i) + 1]]
    \* Bug Family 3: optimistic match_index initialization
    \* replication.rs:27: match_index: self.core.last_log_index
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |->
                        IF j = i THEN LastLogIndex(i)
                        ELSE LastLogIndex(i)]]
    \* Bug Family 3: optimistic match_term initialization
    \* replication.rs:28: match_term: self.core.current_term
    /\ matchTerm' = [matchTerm EXCEPT ![i] = [j \in Server |->
                        IF j = i THEN currentTerm[i]
                        ELSE currentTerm[i]]]
    /\ readActive' = [readActive EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, candidateVars, messages,
                   readConfirmed, readQuorum, snapshotVars, memberVars>>

----
\* Log Replication Actions
----

\* Leader i appends a client request to its log.
\* Reference: client.rs:228-241 (append_payload_to_log)
ClientRequest(i) ==
    /\ state[i] = Leader
    /\ LET entry == [term |-> currentTerm[i], type |-> ValueEntry, config |-> {}]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   readVars, snapshotVars, memberVars>>

\* Leader i sends AppendEntries with log entries to server j.
\* Reference: replication/mod.rs (ReplicationStream sends entries)
ReplicateEntries(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == LogTerm(i, prevIdx)
           lastIdx  == LastLogIndex(i)
           entries  == IF nextIndex[i][j] > lastIdx THEN <<>>
                       ELSE SubSeq(log[i], nextIndex[i][j], lastIdx)
       IN Send([mtype         |-> AppendEntriesRequest,
                mterm         |-> currentTerm[i],
                mprevLogIndex |-> prevIdx,
                mprevLogTerm  |-> prevTerm,
                mentries      |-> entries,
                mcommitIndex  |-> commitIndex[i],
                msource       |-> i,
                mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   readVars, snapshotVars, memberVars>>

\* Leader i sends heartbeat (empty AppendEntries) to server j.
\* Reference: async-raft uses empty AppendEntries as heartbeat (same handler)
SendHeartbeat(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ Send([mtype         |-> AppendEntriesRequest,
             mterm         |-> currentTerm[i],
             mprevLogIndex |-> 0,
             mprevLogTerm  |-> 0,
             mentries      |-> <<>>,
             mcommitIndex  |-> commitIndex[i],
             msource       |-> i,
             mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   readVars, snapshotVars, memberVars>>

\* Server i handles AppendEntries RPC.
\* Reference: append_entries.rs:14-167 (handle_append_entries_request)
\*
\* BUG FAMILY 3: append_entries.rs:28 sets commit_index = msg.leader_commit
\* UNCONDITIONALLY — no min(leaderCommit, lastNewEntry) per Raft Figure 2 Rule 5.
\* This update happens BEFORE the log consistency check (line 80+),
\* so even rejected RPCs advance commit_index.
HandleAppendEntriesRequest(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ LET mterm   == m.mterm
           logOk   == \/ m.mprevLogIndex = 0
                      \/ /\ m.mprevLogIndex > 0
                         /\ m.mprevLogIndex <= LastLogIndex(i)
                         /\ LogTerm(i, m.mprevLogIndex) = m.mprevLogTerm
       IN
       \/ \* Reject: term too low (append_entries.rs:16-23)
          /\ mterm < currentTerm[i]
          /\ Reply([mtype        |-> AppendEntriesResponse,
                    mterm        |-> currentTerm[i],
                    msuccess     |-> FALSE,
                    mmatchIndex  |-> 0,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         readVars, snapshotVars, memberVars>>

       \/ \* Reject: log inconsistency (append_entries.rs:78-151)
          /\ mterm >= currentTerm[i]
          /\ ~logOk
          \* BUG (Family 3): commit_index updated BEFORE consistency check
          \* append_entries.rs:28: self.commit_index = msg.leader_commit
          /\ commitIndex' = [commitIndex EXCEPT ![i] = m.mcommitIndex]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ Reply([mtype        |-> AppendEntriesResponse,
                    mterm        |-> mterm,
                    msuccess     |-> FALSE,
                    mmatchIndex  |-> 0,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<log, leaderVars, candidateVars,
                         readVars, snapshotVars, memberVars>>

       \/ \* Accept: log matches at prevLogIndex (append_entries.rs:61-76, 157-166)
          /\ mterm >= currentTerm[i]
          /\ logOk
          /\ LET newLog == IF Len(m.mentries) > 0
                           THEN SubSeq(log[i], 1, m.mprevLogIndex) \o m.mentries
                           ELSE log[i]
                 newLastIdx == Len(newLog)
                 \* BUG (Family 3): commit_index set unconditionally
                 \* append_entries.rs:28: self.commit_index = msg.leader_commit
                 \* Missing: min(leaderCommit, index of last new entry)
                 newCommitIdx == m.mcommitIndex
             IN
             /\ log' = [log EXCEPT ![i] = newLog]
             /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
             /\ Reply([mtype        |-> AppendEntriesResponse,
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
          /\ UNCHANGED <<leaderVars, candidateVars,
                         readVars, snapshotVars, memberVars>>

\* Leader i handles AppendEntries response.
\* Reference: replication.rs:107-196 (handle_update_match_index)
HandleAppendEntriesResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ \/ \* Higher term: step down (replication.rs:95-103)
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         readVars, snapshotVars, memberVars>>

       \/ \* Current term, success: update match index (replication.rs:119-121)
          /\ m.mterm = currentTerm[i]
          /\ m.msuccess
          /\ nextIndex'  = [nextIndex  EXCEPT ![i][m.msource] = m.mmatchIndex + 1]
          /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] = m.mmatchIndex]
          /\ matchTerm'  = [matchTerm  EXCEPT ![i][m.msource] = m.mterm]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, candidateVars,
                         readVars, snapshotVars, memberVars>>

       \/ \* Current term, failure: decrement nextIndex (backtrack)
          /\ m.mterm = currentTerm[i]
          /\ ~m.msuccess
          /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] = Max(1, nextIndex[i][m.msource] - 1)]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, matchIndex, matchTerm, candidateVars,
                         readVars, snapshotVars, memberVars>>

       \/ \* Stale response: discard
          /\ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         readVars, snapshotVars, memberVars>>

\* Leader i advances commit index based on quorum replication.
\* Reference: replication.rs:138-160 (handle_update_match_index commit logic)
\*            replication.rs:259-271 (calculate_new_commit_index)
\*
\* Bug Family 3: optimistic match_index initialization means
\* new leaders may think followers have replicated entries they haven't.
\* Bug Family 1: C1 quorum omits leader's own entry (replication.rs:153-158)
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET \* Effective match: leader uses its own log length,
           \* followers use matchIndex from replication tracking.
           \* replication.rs:139-147: includes ALL tracked nodes + leader self.
           \* No matchIndex > 0 filter — code uses Vec (preserves duplicates),
           \* so we count servers directly rather than using a set of pairs.
           EffMatch(s) == IF s = i THEN LastLogIndex(i)
                          ELSE matchIndex[i][s]
           EffMatchTerm(s) == IF s = i THEN LastLogTerm(i)
                              ELSE matchTerm[i][s]
           \* C0 voters: current members including leader
           c0Voters == membership[i].members
           \* Count servers that have replicated at least up to idx
           C0Agree(idx) == {s \in c0Voters : EffMatch(s) >= idx}
           \* Committable: quorum agrees, entry is from current term
           CommittableC0(idx) ==
               /\ idx > commitIndex[i]
               /\ idx <= LastLogIndex(i)
               /\ LogTerm(i, idx) = currentTerm[i]
               /\ IsQuorum(C0Agree(idx), c0Voters)
           commitC0 == IF \E idx \in 1..LastLogIndex(i) : CommittableC0(idx)
                       THEN SetMax({idx \in 1..LastLogIndex(i) : CommittableC0(idx)})
                       ELSE commitIndex[i]
           \* C1 voters: new config members (Bug Family 1: MISSING leader!)
           \* replication.rs:153-158: does NOT push leader's own index for C1
           c1Voters == IF membership[i].members_after /= Nil
                       THEN membership[i].members_after
                       ELSE {}
           C1Agree(idx) == {s \in c1Voters :
                              /\ s /= i          \* Bug Family 1: leader excluded
                              /\ matchIndex[i][s] >= idx}
           CommittableC1(idx) ==
               /\ c1Voters /= {}
               /\ idx > commitIndex[i]
               /\ idx <= LastLogIndex(i)
               /\ LogTerm(i, idx) = currentTerm[i]
               /\ IsQuorum(C1Agree(idx), c1Voters)
           commitC1 == IF c1Voters /= {} /\ \E idx \in 1..LastLogIndex(i) : CommittableC1(idx)
                       THEN SetMax({idx \in 1..LastLogIndex(i) : CommittableC1(idx)})
                       ELSE commitC0
           newCommit == Min(commitC0, commitC1)
       IN
       /\ newCommit > commitIndex[i]
       /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommit]
    /\ UNCHANGED <<serverVars, log, leaderVars, candidateVars, messages,
                   readVars, snapshotVars, memberVars>>

----
\* Client Read Actions (Bug Family 1, 6)
----

\* Leader i starts handling a client read request.
\* Reference: client.rs:105-139 (handle_client_read_request setup)
\*
\* BUG FAMILY 1: client.rs:109-113 — quorum formula is wrong.
\* For N=3: c0_needed = 3/2 = 1, after self-increment c0_confirmed = 1.
\* So c0_confirmed(1) >= c0_needed(1) → succeeds with just self!
\* Correct: majority of 3 = 2 confirmations needed, self = 1, need 1 more.
ClientReadRequest(i) ==
    /\ state[i] = Leader
    /\ ~readActive[i]
    /\ LET needed == BuggyQuorumNeeded(Cardinality(membership[i].members))
       IN
       \* client.rs:122: c0_confirmed += 1 (self)
       /\ readConfirmed' = [readConfirmed EXCEPT ![i] = 1]
       /\ readQuorum' = [readQuorum EXCEPT ![i] = needed]
       /\ readActive' = [readActive EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   snapshotVars, memberVars>>

\* Leader i receives a heartbeat confirmation for the read.
\* Reference: client.rs:166-204 (response handling loop)
\*
\* BUG FAMILY 6: client.rs:181-184 — after detecting higher term,
\* sets target_state = Follower but does NOT return/break.
\* Execution falls through to confirmation counting (lines 187-203),
\* potentially returning Ok(()) after deposition.
\*
\* Also: client.rs:181 uses != instead of > for term comparison.
\* A response with a LOWER term triggers spurious step-down.
ClientReadConfirm(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ readActive[i]
    /\ \/ \* Bug Family 6: detect deposition but CONTINUE (client.rs:181-184)
          \* The code sets target_state = Follower but does NOT break/return.
          \* It falls through to the confirmation counting below.
          /\ m.mterm /= currentTerm[i]
          \* client.rs:182-183: update_current_term and set_target_state(Follower)
          \* BUT no break or return — falls through!
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ IF m.mterm > currentTerm[i]
             THEN /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
                  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
             ELSE UNCHANGED <<currentTerm, votedFor>>
          \* Falls through to count confirmation (client.rs:187-203)
          /\ readConfirmed' = [readConfirmed EXCEPT ![i] = @ + 1]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         readQuorum, readActive, snapshotVars, memberVars>>

       \/ \* Normal: count confirmation (client.rs:187-203)
          /\ m.mterm = currentTerm[i]
          /\ readConfirmed' = [readConfirmed EXCEPT ![i] = @ + 1]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         readQuorum, readActive, snapshotVars, memberVars>>

\* Read completes after getting enough confirmations.
\* Reference: client.rs:200-202
ClientReadComplete(i) ==
    /\ readActive[i]
    /\ readConfirmed[i] >= readQuorum[i]
    /\ readActive' = [readActive EXCEPT ![i] = FALSE]
    /\ readConfirmed' = [readConfirmed EXCEPT ![i] = 0]
    /\ readQuorum' = [readQuorum EXCEPT ![i] = 0]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   snapshotVars, memberVars>>

----
\* Snapshot Actions (Bug Family 4)
----

\* Leader i sends InstallSnapshot to server j.
\* Reference: replication.rs:200-244 (handle_needs_snapshot)
SendInstallSnapshot(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ Send([mtype              |-> InstallSnapshotRequest,
             mterm              |-> currentTerm[i],
             mlastIncludedIndex |-> snapshotIndex[i],
             mlastIncludedTerm  |-> LogTerm(i, snapshotIndex[i]),
             msource            |-> i,
             mdest              |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   readVars, snapshotVars, memberVars>>

\* Server i handles InstallSnapshot RPC.
\* Reference: install_snapshot.rs:17-58 (handle_install_snapshot_request)
\*            install_snapshot.rs:114-140 (finalize_snapshot_installation)
\*
\* BUG FAMILY 4: install_snapshot.rs:135-136 — last_log_index and
\* last_log_term unconditionally set to snapshot values, even when
\* log retains entries past the snapshot index (line 120-121).
\* Also: commit_index is NOT updated after snapshot install (line 138 updates
\* last_applied but not commit_index).
HandleInstallSnapshotRequest(i, m) ==
    /\ m.mtype = InstallSnapshotRequest
    /\ m.mdest = i
    /\ \/ \* Reject: term too low (install_snapshot.rs:19-21)
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype   |-> InstallSnapshotResponse,
                    mterm   |-> currentTerm[i],
                    msource |-> i,
                    mdest   |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         readVars, snapshotVars, memberVars>>

       \/ \* Accept: install snapshot (install_snapshot.rs:26-57)
          /\ m.mterm >= currentTerm[i]
          \* install_snapshot.rs:28-32: update term if needed
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF m.mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          \* install_snapshot.rs:120-127: truncate log up to snapshot index
          \* Bug Family 4: install_snapshot.rs:135-136 CLOBBERS last_log_index/term
          \* Even when log[i] retains entries past m.mlastIncludedIndex (line 120-121
          \* keeps them), lines 135-136 override last_log_index to snapshot values.
          /\ log' = [log EXCEPT ![i] = IF LastLogIndex(i) > m.mlastIncludedIndex
                                       THEN SubSeq(@, m.mlastIncludedIndex + 1, Len(@))
                                       ELSE <<>>]
          \* Bug Family 4: commit_index NOT updated! (install_snapshot.rs:135-138)
          \* Only last_applied and snapshot_index are updated, not commit_index.
          /\ UNCHANGED commitIndex
          /\ snapshotIndex' = [snapshotIndex EXCEPT ![i] = m.mlastIncludedIndex]
          /\ Reply([mtype   |-> InstallSnapshotResponse,
                    mterm   |-> m.mterm,
                    msource |-> i,
                    mdest   |-> m.msource], m)
          /\ UNCHANGED <<leaderVars, candidateVars,
                         readVars, memberVars>>

\* Leader i handles InstallSnapshotResponse.
HandleInstallSnapshotResponse(i, m) ==
    /\ m.mtype = InstallSnapshotResponse
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ \/ /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
       \/ /\ m.mterm <= currentTerm[i]
          /\ UNCHANGED serverVars
    /\ Discard(m)
    /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                   readVars, snapshotVars, memberVars>>

\* Server i takes a snapshot (log compaction).
\* Reference: core/mod.rs:358-409 (trigger_log_compaction_if_needed)
TakeSnapshot(i) ==
    /\ commitIndex[i] > snapshotIndex[i]
    /\ snapshotIndex' = [snapshotIndex EXCEPT ![i] = commitIndex[i]]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   readVars, memberVars>>

----
\* Membership Change Actions (Bug Family 5)
----

\* Leader i proposes a membership change entering joint consensus.
\* Reference: admin.rs:86-178 (change_membership)
\* Enters joint consensus with C0 = current members, C1 = new members.
ChangeMembership(i, newMembers) ==
    /\ state[i] = Leader
    /\ membership[i].members_after = Nil   \* only in uniform state
    /\ newMembers /= {}
    /\ newMembers /= membership[i].members  \* actual change
    \* admin.rs:143-144: enter joint consensus
    /\ membership' = [membership EXCEPT ![i] = [@ EXCEPT !.members_after = newMembers]]
    \* admin.rs:149-157: append config entry to log
    /\ LET entry == [term   |-> currentTerm[i],
                     type   |-> ConfigEntry,
                     config |-> [members |-> membership[i].members,
                                 members_after |-> newMembers]]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   readVars, snapshotVars>>

\* Leader i finalizes joint consensus after commitment.
\* Reference: admin.rs:194-229 (finalize_joint_consensus)
\* Bug Family 5: admin.rs:195-229 — non-voters promoted via membership
\* change are never moved from non_voters to nodes map, invisible to commit.
\* We model the cutover of membership config.
FinalizeJointConsensus(i) ==
    /\ state[i] = Leader
    /\ membership[i].members_after /= Nil
    \* Must have committed the joint config entry
    /\ \E idx \in 1..commitIndex[i] :
        /\ idx <= LastLogIndex(i)
        /\ log[i][idx].type = ConfigEntry
    \* admin.rs:203-206: cut over to new config
    /\ membership' = [membership EXCEPT ![i] = [members |-> membership[i].members_after,
                                                 members_after |-> Nil]]
    \* admin.rs:219-224: append uniform config entry
    /\ LET entry == [term   |-> currentTerm[i],
                     type   |-> ConfigEntry,
                     config |-> [members |-> membership[i].members_after,
                                 members_after |-> Nil]]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   readVars, snapshotVars>>

----
\* Crash and Network Failure Actions
----

\* Server i crashes. All volatile state is lost.
Crash(i) ==
    /\ state' = [state EXCEPT ![i] = Follower]
    \* Volatile state reset
    /\ commitIndex'   = [commitIndex   EXCEPT ![i] = 0]
    /\ nextIndex'     = [nextIndex     EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'    = [matchIndex    EXCEPT ![i] = [j \in Server |-> 0]]
    /\ matchTerm'     = [matchTerm     EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted'  = [votesGranted  EXCEPT ![i] = {}]
    /\ readActive'    = [readActive    EXCEPT ![i] = FALSE]
    /\ readConfirmed' = [readConfirmed EXCEPT ![i] = 0]
    /\ readQuorum'    = [readQuorum    EXCEPT ![i] = 0]
    \* Persistent state survives
    /\ UNCHANGED <<currentTerm, votedFor, log, messages, snapshotVars, memberVars>>

\* A message is lost from the network.
LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   readVars, snapshotVars, memberVars>>

\* Drop stale messages with outdated terms.
DropStaleMessage(m) ==
    /\ m \in DOMAIN messages
    /\ m.mterm < currentTerm[m.mdest]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   readVars, snapshotVars, memberVars>>

----
\* Spec
----

Next ==
    \/ \E i \in Server :
        \/ Timeout(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ ClientReadRequest(i)
        \/ ClientReadComplete(i)
        \/ AdvanceCommitIndex(i)
        \/ TakeSnapshot(i)
        \/ Crash(i)
    \/ \E i, j \in Server :
        \/ ReplicateEntries(i, j)
        \/ SendHeartbeat(i, j)
        \/ SendInstallSnapshot(i, j)
    \/ \E i \in Server, newM \in SUBSET Server \ {{}} :
        \/ ChangeMembership(i, newM)
    \/ \E i \in Server :
        \/ FinalizeJointConsensus(i)
    \/ \E m \in DOMAIN messages :
        \/ HandleRequestVoteRequest(m.mdest, m)
        \/ HandleRequestVoteResponse(m.mdest, m)
        \/ HandleAppendEntriesRequest(m.mdest, m)
        \/ HandleAppendEntriesResponse(m.mdest, m)
        \/ ClientReadConfirm(m.mdest, m)
        \/ HandleInstallSnapshotRequest(m.mdest, m)
        \/ HandleInstallSnapshotResponse(m.mdest, m)
        \/ DropStaleMessage(m)
        \/ LoseMessage(m)

Spec == Init /\ [][Next]_vars

----
\* Invariants
----

\* === Standard Raft Safety Invariants ===

\* At most one leader per term.
ElectionSafety ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ state[s2] = Leader /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* If two logs have an entry with the same index and term,
\* the logs are identical up to that point.
LogMatching ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(LastLogIndex(s1), LastLogIndex(s2)) :
            log[s1][idx].term = log[s2][idx].term =>
                \A k \in 1..idx : log[s1][k].term = log[s2][k].term

\* A committed entry appears in all future leaders' logs.
\* Raft paper: entries committed in term T are present in all leaders of term >= T.
\* A stale leader (lower term) need not have entries from a later-term leader.
\* Guarded: only check entries that exist in s2's log
\* (Bug Family 3 can push commitIndex past log length).
LeaderCompleteness ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ commitIndex[s2] > 0) =>
            \A idx \in 1..Min(commitIndex[s2], LastLogIndex(s2)) :
                (log[s2][idx].term <= currentTerm[s1]) =>
                    /\ idx <= LastLogIndex(s1)
                    /\ log[s1][idx].term = log[s2][idx].term

\* === Extension Invariants (Bug Family Detection) ===

\* Bug Family 1: Read succeeds only after true majority confirmation.
\* The buggy formula allows reads with fewer than majority confirmations.
QuorumConfirmation ==
    \A s \in Server :
        (readActive[s] /\ readConfirmed[s] >= readQuorum[s]) =>
            \* True majority = more than half of members
            readConfirmed[s] * 2 > Cardinality(membership[s].members)

\* Bug Family 1, 6: Linearizable read requires active leadership.
\* A read should not complete if the server is no longer leader.
LinearizableRead ==
    \A s \in Server :
        (readActive[s] /\ readConfirmed[s] >= readQuorum[s]) =>
            state[s] = Leader

\* Bug Family 2: Vote granted only to candidate with lexicographically >= log.
\* This checks the CORRECT property — the buggy check can violate this.
VoteUpToDate ==
    \A m \in DOMAIN messages :
        (m.mtype = RequestVoteResponse /\ m.mvoteGranted) =>
            CorrectLogUpToDate(
                m.mlastLogTerm, m.mlastLogIndex,
                LastLogTerm(m.msource), LastLogIndex(m.msource))

\* Bug Family 3: Committed entries must be truly replicated to majority.
\* commit_index should not exceed the last entry that was truly replicated
\* and verified.
CommitIndexSafety ==
    \A s \in Server :
        commitIndex[s] > 0 =>
            commitIndex[s] <= LastLogIndex(s)

\* Bug Family 4: After snapshot install, state is consistent.
\* commit_index should be >= snapshot_index (violated because install_snapshot
\* doesn't update commit_index).
SnapshotConsistency ==
    \A s \in Server :
        snapshotIndex[s] > 0 =>
            commitIndex[s] >= snapshotIndex[s]

\* Bug Family 1, 5: Both C0 and C1 majorities agree during joint consensus.
JointQuorum ==
    \A s \in Server :
        (state[s] = Leader /\ membership[s].members_after /= Nil) =>
            \A idx \in 1..commitIndex[s] :
                idx <= LastLogIndex(s) =>
                    LET Agree == {t \in Server : matchIndex[s][t] >= idx} \cup {s}
                    IN /\ IsQuorum(Agree \cap membership[s].members,
                                   membership[s].members)
                       /\ IsQuorum(Agree \cap membership[s].members_after,
                                   membership[s].members_after)

\* === Structural Invariants ===

\* Commit index never exceeds log length (basic sanity check,
\* can be violated by Bug Family 3's unconditional commit update).
CommitIndexBoundInv ==
    \A i \in Server : commitIndex[i] <= LastLogIndex(i)

\* Candidates always voted for themselves.
CandidateVotedForSelfInv ==
    \A i \in Server : state[i] = Candidate => votedFor[i] = i

\* Leaders always have a positive term.
LeaderTermPositiveInv ==
    \A i \in Server : state[i] = Leader => currentTerm[i] > 0

\* A leader's log contains all committed entries from all servers.
LeaderLogCompleteness ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ commitIndex[s2] > 0) =>
            \A idx \in 1..commitIndex[s2] :
                /\ idx <= LastLogIndex(s1)
                /\ log[s1][idx] = log[s2][idx]

=============================================================================
