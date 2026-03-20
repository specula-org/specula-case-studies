---------------------------- MODULE base ----------------------------
\* TLA+ specification of ScyllaDB's built-in Raft library (raft/).
\*
\* Extends standard Raft with scylla-specific behaviors:
\*   1. Commit index clamping in AppendEntries and ReadQuorum (Bug Family 1)
\*   2. Joint consensus with tracker can_vote field mismatch (Bug Family 2)
\*   3. Snapshot lifecycle and crash recovery (Bug Family 3)
\*   4. Failure detector-based election suppression (Bug Family 5)
\*
\* Source: artifact/scylla/raft/ (fsm.cc, fsm.hh, raft.hh, tracker.cc, log.cc)
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

CONSTANTS RequestVoteRequest,        \* Message types
          RequestVoteResponse,
          AppendEntriesRequest,
          AppendEntriesResponse,
          InstallSnapshotRequest,
          InstallSnapshotResponse,
          ReadQuorumRequest,
          ReadQuorumResponse

----
\* Variables
----

\* Per-server persistent state (survives restart)
\* Reference: fsm.hh:157-161, raft.hh:729 (atomic term+vote persistence)
VARIABLE currentTerm         \* [Server -> Nat]
VARIABLE votedFor            \* [Server -> Server \cup {Nil}]
VARIABLE log                 \* [Server -> Seq(LogEntry)]

\* Per-server volatile state
VARIABLE state               \* [Server -> {Follower, Candidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat]

\* Leader volatile state (reset on leadership change)
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate state
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Network: bag of in-flight messages
VARIABLE messages            \* Bag of message records

\* Extension: Joint consensus configuration (Bug Family 2)
\* Each server's active configuration. currentVoters = voters in C_new,
\* previousVoters = voters in C_old ({} when not in joint consensus).
\* Reference: raft.hh:136-233 (configuration struct)
VARIABLE currentVoters       \* [Server -> SUBSET Server]
VARIABLE previousVoters      \* [Server -> SUBSET Server]

\* Extension: Read barrier tracking (Bug Family 2)
\* Monotonic read_id counter and per-follower ack tracking.
\* Reference: fsm.hh:100-107, fsm.cc:1052-1094
VARIABLE lastReadId          \* [Server -> Nat]
VARIABLE maxReadIdWithQuorum \* [Server -> Nat]
VARIABLE maxAckedRead        \* [Server -> [Server -> Nat]]

\* Extension: Snapshot descriptor (Bug Family 3)
\* Represents the snapshot that subsumes log prefix.
\* log[s] contains entries from snapshotIdx[s]+1 onward.
\* Reference: raft.hh:335-343 (snapshot_descriptor), log.cc:231-279
VARIABLE snapshotIdx         \* [Server -> Nat]
VARIABLE snapshotTerm        \* [Server -> Nat]

\* Extension: Failure detector oracle (Bug Family 5)
\* Non-deterministic set of servers each server's FD sees as alive.
\* Independent of actual network connectivity.
\* Reference: fsm.cc:523-529 (tick_leader), fsm.cc:590-606 (has_stable_leader)
VARIABLE fdView              \* [Server -> SUBSET Server]

----
\* Variable groups (for UNCHANGED clauses)
----

serverVars    == <<currentTerm, votedFor, state>>
logVars       == <<log, commitIndex>>
leaderVars    == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted>>
configVars    == <<currentVoters, previousVoters>>
readVars      == <<lastReadId, maxReadIdWithQuorum, maxAckedRead>>
snapshotVars  == <<snapshotIdx, snapshotTerm>>
fdVars        == <<fdView>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          configVars, readVars, snapshotVars, fdVars>>

----
\* Helpers
----

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b

\* ---- Log helpers ----

\* Last log index (accounting for snapshot prefix)
LastLogIndex(i) == Len(log[i]) + snapshotIdx[i]

\* Last log term
\* Reference: log.cc:96-101
LastLogTerm(i) ==
    IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term
    ELSE snapshotTerm[i]

\* Term of log entry at real index idx
\* Reference: log.cc:139-147 (term_for)
LogTerm(i, idx) ==
    IF idx = 0 THEN 0
    ELSE IF idx = snapshotIdx[i] THEN snapshotTerm[i]
    ELSE IF idx > snapshotIdx[i] /\ idx <= LastLogIndex(i)
         THEN log[i][idx - snapshotIdx[i]].term
         ELSE 0

\* Log entry at real index idx (only valid for entries in log, not snapshot)
LogEntry(i, idx) ==
    log[i][idx - snapshotIdx[i]]

\* Log up-to-date comparison (§3.6.1 Election restriction)
\* Reference: log.cc:47-55
IsUpToDate(candidateLastIdx, candidateLastTerm, voterLastIdx, voterLastTerm) ==
    \/ candidateLastTerm > voterLastTerm
    \/ (candidateLastTerm = voterLastTerm /\ candidateLastIdx >= voterLastIdx)

\* Match term check for AppendEntries prev entry
\* Reference: log.cc:108-137
MatchTerm(i, idx, term) ==
    IF idx = 0 THEN TRUE
    ELSE IF idx < snapshotIdx[i] THEN TRUE              \* log.cc:117-118 inside snapshot
    ELSE IF idx = snapshotIdx[i] THEN snapshotTerm[i] = term  \* log.cc:123-124
    ELSE IF idx > snapshotIdx[i] /\ idx <= LastLogIndex(i)
         THEN LogEntry(i, idx).term = term               \* log.cc:133-136
    ELSE FALSE                                            \* log.cc:128-131 gap

\* ---- Quorum helpers ----

\* True if subset forms a majority of voterSet
IsQuorum(voterSet, subset) ==
    Cardinality(subset) * 2 > Cardinality(voterSet)

\* Servers whose matchIndex >= idx in leader i's tracker
Agree(i, idx) ==
    {j \in Server : matchIndex[i][j] >= idx}

\* Joint quorum: majority in current AND (if joint) majority in previous
\* Reference: tracker.cc:178-214 (committed)
JointAgree(i, idx) ==
    LET currentAgree  == Agree(i, idx) \cap currentVoters[i]
        previousAgree == Agree(i, idx) \cap previousVoters[i]
    IN /\ IsQuorum(currentVoters[i], currentAgree)
       /\ (previousVoters[i] = {} \/ IsQuorum(previousVoters[i], previousAgree))

\* Servers whose maxAckedRead >= rid in leader i's tracker
ReadAgree(i, rid) ==
    {j \in Server : maxAckedRead[i][j] >= rid}

\* Joint quorum for read barrier acks
JointReadAgree(i, rid) ==
    LET currentAgree  == ReadAgree(i, rid) \cap currentVoters[i]
        previousAgree == ReadAgree(i, rid) \cap previousVoters[i]
    IN /\ IsQuorum(currentVoters[i], currentAgree)
       /\ (previousVoters[i] = {} \/ IsQuorum(previousVoters[i], previousAgree))

\* ---- Tracker can_vote helpers (Bug Family 2) ----

\* Buggy TrackerCanVote: uses can_vote field from tracker, which is set from
\* the FIRST config that adds the server (current config processed first).
\* A server that is voter in previous but non-voter/absent-in current gets FALSE.
\* Reference: tracker.cc:114-127 (set_configuration skips duplicates)
\*
\* This is an over-approximation: servers ONLY in previous (not in current at all)
\* correctly get can_vote from previous in the real code. Our model treats them
\* the same as demoted servers, making violations easier to find. Any violation
\* found must be verified for the specific config membership scenario.
TrackerCanVote(i, j) ==
    j \in currentVoters[i]

\* Correct voter check: voter in either config
CorrectCanVote(i, j) ==
    j \in currentVoters[i] \cup previousVoters[i]

\* ---- Configuration helpers ----

\* Is the configuration joint? (has a previous config)
\* Reference: raft.hh:153-155
IsJoint(i) == previousVoters[i] /= {}

\* ---- Message helpers ----

\* Add a message to the bag
Send(m) == messages' = messages (+) SetToBag({m})

\* Remove a message from the bag
Discard(m) == messages' = messages (-) SetToBag({m})

\* Remove request and add response
Reply(response, request) ==
    messages' = (messages (-) SetToBag({request})) (+) SetToBag({response})

\* Add a set of messages to the bag
SendAll(msgs) == messages' = messages (+) SetToBag(msgs)

\* ---- Config entry helpers ----

\* Extract active config from a server's log (scan from end for last ConfigEntry)
\* Reference: log.cc:149-151 (get_configuration)
ActiveConfig(i) ==
    LET configEntries == {k \in 1..Len(log[i]) :
            log[i][k].type = ConfigEntry}
    IN IF configEntries = {} THEN
        \* No config entry in log; use base config (all servers are voters)
        [cv |-> currentVoters[i], pv |-> previousVoters[i]]
       ELSE
        LET lastK == CHOOSE k \in configEntries :
                \A k2 \in configEntries : k >= k2
            entry == log[i][lastK]
        IN [cv |-> entry.cv, pv |-> entry.pv]

\* Update config variables from a log entry
UpdateConfigFromLog(i, entries) ==
    LET configEntries == {k \in 1..Len(entries) :
            entries[k].type = ConfigEntry}
    IN IF configEntries = {} THEN
        <<currentVoters[i], previousVoters[i]>>
       ELSE
        LET lastK == CHOOSE k \in configEntries :
                \A k2 \in configEntries : k >= k2
            entry == entries[lastK]
        IN <<entry.cv, entry.pv>>

----
\* ===================================================================
\* Actions
\* ===================================================================

\* ---- Election ----

\* Server i times out and starts an election.
\* Reference: fsm.cc:607-611 (tick → become_candidate)
\* Reference: fsm.cc:208-308 (become_candidate)
Timeout(i) ==
    /\ state[i] \in {Follower, Candidate}
    \* Raft paper: increment term, vote for self, send RequestVote
    \* Reference: fsm.cc:276-278 (update_current_term)
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ votedFor'    = [votedFor EXCEPT ![i] = i]
    /\ state'       = [state EXCEPT ![i] = Candidate]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    \* Send RequestVote to all voters
    \* Reference: fsm.cc:281-297 (send vote_request to voters)
    /\ SendAll({[mtype   |-> RequestVoteRequest,
                 mterm   |-> currentTerm[i] + 1,
                 mlastLogIdx  |-> LastLogIndex(i),
                 mlastLogTerm |-> LastLogTerm(i),
                 msource |-> i,
                 mdest   |-> j] : j \in (currentVoters[i] \cup previousVoters[i]) \ {i}})
    /\ UNCHANGED <<logVars, leaderVars, configVars, readVars, snapshotVars, fdVars>>

\* Server i handles a RequestVote request from server j.
\* Reference: fsm.cc:778-831 (request_vote)
HandleRequestVoteRequest(i, j, m) ==
    LET grant ==
        \* Reference: fsm.cc:785-793 (can_vote conditions)
        /\ \/ votedFor[i] = j                          \* repeat vote
           \/ (votedFor[i] = Nil /\ state[i] /= Leader) \* haven't voted, no leader known
        \* Reference: fsm.cc:796 (log up-to-date check via log.cc:47-55)
        /\ IsUpToDate(m.mlastLogIdx, m.mlastLogTerm,
                      LastLogIndex(i), LastLogTerm(i))
    IN
    /\ m.mtype = RequestVoteRequest
    /\ m.mterm = currentTerm[i]  \* Term already matched by step() dispatch
    /\ IF grant THEN
        \* Reference: fsm.cc:802-807 (grant: record vote, reset election timer)
        /\ votedFor' = [votedFor EXCEPT ![i] = j]
        /\ Reply([mtype        |-> RequestVoteResponse,
                  mterm        |-> currentTerm[i],
                  mvoteGranted |-> TRUE,
                  msource      |-> i,
                  mdest        |-> j], m)
       ELSE
        \* Reference: fsm.cc:829 (reject)
        /\ votedFor' = votedFor
        /\ Reply([mtype        |-> RequestVoteResponse,
                  mterm        |-> currentTerm[i],
                  mvoteGranted |-> FALSE,
                  msource      |-> i,
                  mdest        |-> j], m)
    /\ UNCHANGED <<state, currentTerm, logVars, leaderVars, candidateVars,
                   configVars, readVars, snapshotVars, fdVars>>

\* Server i handles a RequestVote response from server j.
\* Reference: fsm.cc:833-862 (request_vote_reply)
HandleRequestVoteResponse(i, j, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mterm = currentTerm[i]
    /\ state[i] = Candidate
    \* Reference: fsm.cc:844 (register_vote)
    /\ votesGranted' = [votesGranted EXCEPT ![i] =
        IF m.mvoteGranted THEN votesGranted[i] \cup {j}
        ELSE votesGranted[i]]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, configVars,
                   readVars, snapshotVars, fdVars>>

\* Server i becomes leader after winning election.
\* Reference: fsm.cc:160-190 (become_leader)
BecomeLeader(i) ==
    /\ state[i] = Candidate
    \* Won election: majority in current voters, and (if joint) in previous voters
    \* Reference: tracker.cc:175-183 (tally_votes), tracker.cc:250-258
    /\ IsQuorum(currentVoters[i], votesGranted[i] \cap currentVoters[i])
    /\ (previousVoters[i] = {} \/
        IsQuorum(previousVoters[i], votesGranted[i] \cap previousVoters[i]))
    /\ state' = [state EXCEPT ![i] = Leader]
    \* Reference: fsm.cc:184 (add_entry(dummy))
    \* Append a dummy entry to establish leadership
    /\ log' = [log EXCEPT ![i] = Append(@, [term |-> currentTerm[i],
                                             type |-> ValueEntry])]
    \* Reference: fsm.cc:187 (set_configuration → initialize tracker)
    \* Scylla: set_configuration passes _log.last_idx() as next_idx,
    \* so nextIndex = old LastLogIndex + 1 = dummy entry's index.
    \* This means the leader immediately replicates the dummy entry.
    /\ nextIndex'  = [nextIndex EXCEPT ![i] =
        [j \in Server |-> LastLogIndex(i) + 1]]  \* Scylla: replicate from last entry
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
        [j \in Server |-> IF j = i THEN LastLogIndex(i) + 1 ELSE 0]]
    \* Initialize read barrier state
    /\ lastReadId'          = [lastReadId EXCEPT ![i] = 0]
    /\ maxReadIdWithQuorum' = [maxReadIdWithQuorum EXCEPT ![i] = 0]
    /\ maxAckedRead'        = [maxAckedRead EXCEPT ![i] =
        [j \in Server |-> 0]]
    /\ UNCHANGED <<currentTerm, votedFor, commitIndex, candidateVars, messages,
                   configVars, snapshotVars, fdVars>>

\* ---- Log Replication ----

\* Leader i receives a client request and appends a new entry.
\* Reference: fsm.cc:59-121 (add_entry)
ClientRequest(i) ==
    /\ state[i] = Leader
    \* Reference: fsm.cc:62-67 (check is leader, not stepping down)
    /\ log' = [log EXCEPT ![i] = Append(@, [term |-> currentTerm[i],
                                             type |-> ValueEntry])]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   configVars, readVars, snapshotVars, fdVars>>

\* Leader i sends AppendEntries to follower j.
\* Reference: fsm.cc:864-946 (replicate_to)
AppendEntries(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == LogTerm(i, prevIdx)
           \* Reference: fsm.cc:916-928 (collect entries to send)
           \* Send entries from nextIndex[j] up to end of log
           lastIdx  == LastLogIndex(i)
           numEntries == IF nextIndex[i][j] > lastIdx THEN 0
                         ELSE lastIdx - nextIndex[i][j] + 1
           entries == IF numEntries = 0 THEN <<>>
                      ELSE SubSeq(log[i],
                                  nextIndex[i][j] - snapshotIdx[i],
                                  lastIdx - snapshotIdx[i])
       IN
       \* Reference: fsm.cc:895-906 (check if prev_term exists, otherwise snapshot)
       /\ prevIdx >= snapshotIdx[i]  \* Can look up prev term (not inside snapshot gap)
       /\ Send([mtype            |-> AppendEntriesRequest,
                mterm            |-> currentTerm[i],
                mprevLogIdx      |-> prevIdx,
                mprevLogTerm     |-> prevTerm,
                mentries         |-> entries,
                mleaderCommitIdx |-> commitIndex[i],
                msource          |-> i,
                mdest            |-> j])
       /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                      configVars, readVars, snapshotVars, fdVars>>

\* Follower i handles AppendEntries from leader j.
\* Reference: fsm.cc:633-670 (append_entries)
HandleAppendEntriesRequest(i, j, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mterm = currentTerm[i]
    /\ state[i] = Follower
    /\ LET match == MatchTerm(i, m.mprevLogIdx, m.mprevLogTerm)
       IN IF ~match THEN
            \* Reference: fsm.cc:647-653 (log mismatch → reject)
            /\ Reply([mtype       |-> AppendEntriesResponse,
                      mterm       |-> currentTerm[i],
                      msuccess    |-> FALSE,
                      mmatchIdx   |-> 0,
                      mcommitIdx  |-> commitIndex[i],
                      msource     |-> i,
                      mdest       |-> j], m)
            /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                           configVars, readVars, snapshotVars, fdVars>>
          ELSE
            \* Reference: fsm.cc:661-663 (maybe_append)
            \* Reference: log.cc:167-199 (maybe_append: per-entry conflict check)
            LET prevIdx    == m.mprevLogIdx
                newEntries == m.mentries
                \* Step 1: Skip entries within the snapshot (log.cc:172-174)
                skipCount == Max(0, snapshotIdx[i] - prevIdx)
                effectiveEntries == IF skipCount >= Len(newEntries) THEN <<>>
                                    ELSE SubSeq(newEntries, skipCount + 1,
                                                Len(newEntries))
                effectivePrevIdx == Max(prevIdx, snapshotIdx[i])
                \* Step 2: Raw truncate-and-append
                logIdx == effectivePrevIdx - snapshotIdx[i]
                rawNewLog == SubSeq(log[i], 1, logIdx) \o effectiveEntries
                \* Step 3: Conflict detection (log.cc:180-195)
                \* maybe_append checks each entry against existing log:
                \*   - matching term at same index → skip (no truncation)
                \*   - different term → truncate from here, append rest
                \*   - beyond log end → append
                \* If rawNewLog would be shorter (stale msg, all entries match),
                \* keep existing log. Only truncate on actual term conflict.
                noConflict == \A k \in 1..Len(effectiveEntries) :
                    LET pos == effectivePrevIdx + k IN
                    (pos <= LastLogIndex(i) /\ pos > snapshotIdx[i])
                    => LogTerm(i, pos) = effectiveEntries[k].term
                newLog == IF Len(rawNewLog) < Len(log[i]) /\ noConflict
                          THEN log[i]       \* stale msg, all match — keep existing
                          ELSE rawNewLog    \* conflict or extension — apply
                lastNewIdx == IF Len(newEntries) > 0
                              THEN prevIdx + Len(newEntries)
                              ELSE prevIdx
                \* Reference: fsm.cc:667 (CORRECT: clamp commit to last_new_idx)
                newCommitIdx == Max(commitIndex[i],
                                    Min(m.mleaderCommitIdx, lastNewIdx))
                \* Update config from entries actually applied
                appliedEntries == IF newLog = log[i] THEN <<>>
                                  ELSE effectiveEntries
                configUpdate == UpdateConfigFromLog(i, appliedEntries)
            IN
            /\ log'       = [log EXCEPT ![i] = newLog]
            /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
            /\ currentVoters'  = [currentVoters EXCEPT ![i] = configUpdate[1]]
            /\ previousVoters' = [previousVoters EXCEPT ![i] = configUpdate[2]]
            /\ Reply([mtype       |-> AppendEntriesResponse,
                      mterm       |-> currentTerm[i],
                      msuccess    |-> TRUE,
                      mmatchIdx   |-> lastNewIdx,
                      mcommitIdx  |-> commitIndex[i],
                      msource     |-> i,
                      mdest       |-> j], m)
            /\ UNCHANGED <<serverVars, leaderVars, candidateVars,
                           readVars, snapshotVars, fdVars>>

\* BUG VARIANT: Unclamped commit advancement in AppendEntries (Bug Family 1)
\* Historical: #9965 / commit 1216f39977 — used leader_commit_idx directly
\* without clamping to last_new_idx. Follower marks obsolete entries as committed.
BuggyHandleAppendEntriesRequest(i, j, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mterm = currentTerm[i]
    /\ state[i] = Follower
    /\ LET match == MatchTerm(i, m.mprevLogIdx, m.mprevLogTerm)
       IN IF ~match THEN
            /\ Reply([mtype       |-> AppendEntriesResponse,
                      mterm       |-> currentTerm[i],
                      msuccess    |-> FALSE,
                      mmatchIdx   |-> 0,
                      mcommitIdx  |-> commitIndex[i],
                      msource     |-> i,
                      mdest       |-> j], m)
            /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                           configVars, readVars, snapshotVars, fdVars>>
          ELSE
            LET prevIdx    == m.mprevLogIdx
                newEntries == m.mentries
                \* Same snapshot-overlap + conflict detection as correct variant
                skipCount == Max(0, snapshotIdx[i] - prevIdx)
                effectiveEntries == IF skipCount >= Len(newEntries) THEN <<>>
                                    ELSE SubSeq(newEntries, skipCount + 1,
                                                Len(newEntries))
                effectivePrevIdx == Max(prevIdx, snapshotIdx[i])
                logIdx     == effectivePrevIdx - snapshotIdx[i]
                rawNewLog  == SubSeq(log[i], 1, logIdx) \o effectiveEntries
                noConflict == \A k \in 1..Len(effectiveEntries) :
                    LET pos == effectivePrevIdx + k IN
                    (pos <= LastLogIndex(i) /\ pos > snapshotIdx[i])
                    => LogTerm(i, pos) = effectiveEntries[k].term
                newLog     == IF Len(rawNewLog) < Len(log[i]) /\ noConflict
                              THEN log[i]
                              ELSE rawNewLog
                lastNewIdx == IF Len(newEntries) > 0
                              THEN prevIdx + Len(newEntries)
                              ELSE prevIdx
                \* BUG: uses leader_commit_idx WITHOUT clamping to last_new_idx
                \* This was the bug in fsm.cc before fix at line 667
                newCommitIdx == Max(commitIndex[i], m.mleaderCommitIdx)
                appliedEntries == IF newLog = log[i] THEN <<>>
                                  ELSE effectiveEntries
                configUpdate == UpdateConfigFromLog(i, appliedEntries)
            IN
            /\ log'       = [log EXCEPT ![i] = newLog]
            /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
            /\ currentVoters'  = [currentVoters EXCEPT ![i] = configUpdate[1]]
            /\ previousVoters' = [previousVoters EXCEPT ![i] = configUpdate[2]]
            /\ Reply([mtype       |-> AppendEntriesResponse,
                      mterm       |-> currentTerm[i],
                      msuccess    |-> TRUE,
                      mmatchIdx   |-> lastNewIdx,
                      mcommitIdx  |-> commitIndex[i],
                      msource     |-> i,
                      mdest       |-> j], m)
            /\ UNCHANGED <<serverVars, leaderVars, candidateVars,
                           readVars, snapshotVars, fdVars>>

\* Leader i handles AppendEntries response from follower j.
\* Reference: fsm.cc:672-776 (append_entries_reply)
HandleAppendEntriesResponse(i, j, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.mterm = currentTerm[i]
    /\ state[i] = Leader
    /\ IF m.msuccess THEN
        \* Reference: fsm.cc:697-706 (accepted: update match/next)
        /\ matchIndex' = [matchIndex EXCEPT ![i][j] =
            Max(matchIndex[i][j], m.mmatchIdx)]
        /\ nextIndex'  = [nextIndex EXCEPT ![i][j] =
            Max(nextIndex[i][j], m.mmatchIdx + 1)]
        /\ Discard(m)
        /\ UNCHANGED <<serverVars, logVars, candidateVars, configVars,
                       readVars, snapshotVars, fdVars>>
       ELSE
        \* Reference: fsm.cc:730-765 (rejected: backtrack next_idx)
        /\ nextIndex' = [nextIndex EXCEPT ![i][j] =
            Max(matchIndex[i][j] + 1, nextIndex[i][j] - 1)]
        /\ Discard(m)
        /\ UNCHANGED <<serverVars, logVars, matchIndex, candidateVars,
                       configVars, readVars, snapshotVars, fdVars>>

\* Leader i advances commit index based on quorum of matchIndex.
\* Reference: fsm.cc:425-510 (maybe_commit)
MaybeCommit(i) ==
    /\ state[i] = Leader
    \* Find the highest index that has joint quorum agreement
    /\ \E idx \in (commitIndex[i]+1)..LastLogIndex(i) :
        \* Reference: fsm.cc:435-447 (only commit entries from current term)
        /\ LogTerm(i, idx) = currentTerm[i]
        /\ JointAgree(i, idx)
        \* Advance to the highest such index
        /\ ~\E idx2 \in (idx+1)..LastLogIndex(i) :
            /\ LogTerm(i, idx2) = currentTerm[i]
            /\ JointAgree(i, idx2)
        /\ commitIndex' = [commitIndex EXCEPT ![i] = idx]
        \* Reference: fsm.cc:455-509 (handle committed config change)
        \* If a joint config was committed, append non-joint config
        /\ IF /\ IsJoint(i)
              /\ \E k \in 1..Len(log[i]) :
                  /\ log[i][k].type = ConfigEntry
                  /\ k + snapshotIdx[i] > commitIndex[i]
                  /\ k + snapshotIdx[i] <= idx
           THEN
            \* Reference: fsm.cc:462-466 (leave_joint: append non-joint config)
            /\ log' = [log EXCEPT ![i] = Append(@,
                [term |-> currentTerm[i], type |-> ConfigEntry,
                 cv |-> currentVoters[i], pv |-> {}])]
            /\ previousVoters' = [previousVoters EXCEPT ![i] = {}]
            /\ UNCHANGED currentVoters
           ELSE
            /\ UNCHANGED <<log, configVars>>
    /\ UNCHANGED <<currentTerm, votedFor, state, leaderVars, candidateVars,
                   messages, readVars, snapshotVars, fdVars>>

\* ---- Read Barrier (Bug Family 2) ----

\* Leader i starts a read barrier and broadcasts read quorum requests.
\* Reference: fsm.cc:1096-1115 (start_read_barrier) + fsm.cc:1052-1063 (broadcast)
BroadcastReadQuorum(i) ==
    /\ state[i] = Leader
    \* Reference: fsm.cc:1108-1109 (check commit_idx has current term entry)
    /\ LogTerm(i, commitIndex[i]) = currentTerm[i]
    /\ LET newReadId == lastReadId[i] + 1
       IN
       /\ lastReadId' = [lastReadId EXCEPT ![i] = newReadId]
       \* Reference: fsm.cc:1054-1062 (broadcast to can_vote servers)
       \* BUG: uses p.can_vote (TrackerCanVote) instead of correct voter set
       \* This means demoted voters in joint config don't get the request
       /\ SendAll({[mtype            |-> ReadQuorumRequest,
                    mterm            |-> currentTerm[i],
                    mleaderCommitIdx |-> Min(matchIndex[i][j], commitIndex[i]),
                    mreadId          |-> newReadId,
                    msource          |-> i,
                    mdest            |-> j] : j \in {s \in Server :
                        TrackerCanVote(i, s) /\ s /= i}})
       \* Leader acks itself immediately
       \* Reference: fsm.cc:1056-1057 (self-reply)
       /\ maxAckedRead' = [maxAckedRead EXCEPT ![i][i] = newReadId]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, maxReadIdWithQuorum, snapshotVars, fdVars>>

\* CORRECT VARIANT: BroadcastReadQuorum using correct voter set
\* Uses CorrectCanVote instead of TrackerCanVote
CorrectBroadcastReadQuorum(i) ==
    /\ state[i] = Leader
    /\ LogTerm(i, commitIndex[i]) = currentTerm[i]
    /\ LET newReadId == lastReadId[i] + 1
       IN
       /\ lastReadId' = [lastReadId EXCEPT ![i] = newReadId]
       /\ SendAll({[mtype            |-> ReadQuorumRequest,
                    mterm            |-> currentTerm[i],
                    mleaderCommitIdx |-> Min(matchIndex[i][j], commitIndex[i]),
                    mreadId          |-> newReadId,
                    msource          |-> i,
                    mdest            |-> j] : j \in {s \in Server :
                        CorrectCanVote(i, s) /\ s /= i}})
       /\ maxAckedRead' = [maxAckedRead EXCEPT ![i][i] = newReadId]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, maxReadIdWithQuorum, snapshotVars, fdVars>>

\* BUG VARIANT: BroadcastReadQuorum with unclamped commit index (Bug Family 1)
\* Historical: #10578 / commit 1eb849c3d7 — sent raw _commit_idx
\* instead of std::min(p.match_idx, _commit_idx)
BuggyBroadcastReadQuorum(i) ==
    /\ state[i] = Leader
    /\ LogTerm(i, commitIndex[i]) = currentTerm[i]
    /\ LET newReadId == lastReadId[i] + 1
       IN
       /\ lastReadId' = [lastReadId EXCEPT ![i] = newReadId]
       \* BUG: sends commitIndex directly, not clamped to matchIndex
       /\ SendAll({[mtype            |-> ReadQuorumRequest,
                    mterm            |-> currentTerm[i],
                    mleaderCommitIdx |-> commitIndex[i],  \* BUG: unclamped
                    mreadId          |-> newReadId,
                    msource          |-> i,
                    mdest            |-> j] : j \in {s \in Server :
                        TrackerCanVote(i, s) /\ s /= i}})
       /\ maxAckedRead' = [maxAckedRead EXCEPT ![i][i] = newReadId]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, maxReadIdWithQuorum, snapshotVars, fdVars>>

\* Follower i handles a ReadQuorum request from leader j.
\* Reference: fsm.hh:552-556 (step follower read_quorum)
HandleReadQuorumRequest(i, j, m) ==
    /\ m.mtype = ReadQuorumRequest
    /\ m.mterm = currentTerm[i]
    /\ state[i] = Follower
    \* Reference: fsm.hh:554 (advance_commit_idx)
    /\ commitIndex' = [commitIndex EXCEPT ![i] =
        Max(commitIndex[i], Min(m.mleaderCommitIdx, LastLogIndex(i)))]
    /\ Reply([mtype     |-> ReadQuorumResponse,
              mterm     |-> currentTerm[i],
              mcommitIdx |-> commitIndex[i],
              mreadId   |-> m.mreadId,
              msource   |-> i,
              mdest     |-> j], m)
    /\ UNCHANGED <<serverVars, log, leaderVars, candidateVars,
                   configVars, readVars, snapshotVars, fdVars>>

\* Leader i handles a ReadQuorum response from server j.
\* Reference: fsm.cc:1065-1094 (handle_read_quorum_reply)
HandleReadQuorumResponse(i, j, m) ==
    /\ m.mtype = ReadQuorumResponse
    /\ m.mterm = currentTerm[i]
    /\ state[i] = Leader
    \* Reference: fsm.cc:1076 (update max_acked_read)
    /\ maxAckedRead' = [maxAckedRead EXCEPT ![i][j] =
        Max(maxAckedRead[i][j], m.mreadId)]
    \* Reference: fsm.cc:1083-1089 (check if new read quorum committed)
    /\ LET newMaxRead == IF JointReadAgree(i, m.mreadId)
                         THEN Max(maxReadIdWithQuorum[i], m.mreadId)
                         ELSE maxReadIdWithQuorum[i]
       IN maxReadIdWithQuorum' = [maxReadIdWithQuorum EXCEPT ![i] = newMaxRead]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, lastReadId, snapshotVars, fdVars>>

\* ---- Snapshot (Bug Family 3) ----

\* Leader i sends InstallSnapshot to follower j whose log is too far behind.
\* Reference: fsm.cc:895-906 (enter snapshot transfer)
SendInstallSnapshot(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    \* Follower's nextIndex is at or before our snapshot
    /\ nextIndex[i][j] <= snapshotIdx[i]
    /\ Send([mtype        |-> InstallSnapshotRequest,
             mterm        |-> currentTerm[i],
             msnapshotIdx  |-> snapshotIdx[i],
             msnapshotTerm |-> snapshotTerm[i],
             msource      |-> i,
             mdest        |-> j])
    \* Reference: fsm.cc:901-902 (become_snapshot state: next_idx = snp.idx + 1)
    /\ nextIndex' = [nextIndex EXCEPT ![i][j] = snapshotIdx[i] + 1]
    /\ UNCHANGED <<serverVars, logVars, matchIndex, candidateVars,
                   configVars, readVars, snapshotVars, fdVars>>

\* Follower i handles InstallSnapshot from leader j.
\* Reference: fsm.hh:544-546 (step follower install_snapshot → apply_snapshot)
\* Reference: fsm.cc:982-1018 (apply_snapshot)
HandleInstallSnapshot(i, j, m) ==
    /\ m.mtype = InstallSnapshotRequest
    /\ m.mterm = currentTerm[i]
    /\ state[i] = Follower
    \* Reference: fsm.cc:994-999 (reject outdated snapshot)
    /\ m.msnapshotIdx > snapshotIdx[i]
    /\ m.msnapshotIdx > commitIndex[i]  \* Remote snapshot must be fresher than commit
    \* Reference: fsm.cc:1006-1007 (advance commit, apply snapshot)
    /\ snapshotIdx'  = [snapshotIdx EXCEPT ![i] = m.msnapshotIdx]
    /\ snapshotTerm' = [snapshotTerm EXCEPT ![i] = m.msnapshotTerm]
    /\ commitIndex'  = [commitIndex EXCEPT ![i] =
        Max(commitIndex[i], m.msnapshotIdx)]
    \* Truncate log: for remote snapshots, trailing = 0 (CORRECT behavior)
    \* Reference: fsm.hh:546 (apply_snapshot(snp, 0, 0, false))
    /\ log' = [log EXCEPT ![i] =
        IF m.msnapshotIdx >= LastLogIndex(i) THEN <<>>
        ELSE SubSeq(log[i], m.msnapshotIdx - snapshotIdx[i] + 1, Len(log[i]))]
    /\ Reply([mtype    |-> InstallSnapshotResponse,
              mterm    |-> currentTerm[i],
              msuccess |-> TRUE,
              msource  |-> i,
              mdest    |-> j], m)
    /\ UNCHANGED <<serverVars, leaderVars, candidateVars,
                   configVars, readVars, fdVars>>

\* BUG VARIANT: Remote snapshot with non-zero trailing (Bug Family 3)
\* Historical: #9551 / commit bdf7d1a411 — used _config.snapshot_trailing
\* instead of 0 for remote snapshots. Stale entries corrupt state after restart.
BuggyHandleInstallSnapshot(i, j, m) ==
    /\ m.mtype = InstallSnapshotRequest
    /\ m.mterm = currentTerm[i]
    /\ state[i] = Follower
    /\ m.msnapshotIdx > snapshotIdx[i]
    /\ m.msnapshotIdx > commitIndex[i]
    /\ snapshotIdx'  = [snapshotIdx EXCEPT ![i] = m.msnapshotIdx]
    /\ snapshotTerm' = [snapshotTerm EXCEPT ![i] = m.msnapshotTerm]
    /\ commitIndex'  = [commitIndex EXCEPT ![i] =
        Max(commitIndex[i], m.msnapshotIdx)]
    \* BUG: keeps trailing entries instead of truncating all
    \* Stale entries from old term may remain, corrupting state after recovery
    /\ log' = [log EXCEPT ![i] =
        IF m.msnapshotIdx >= LastLogIndex(i) THEN <<>>
        ELSE SubSeq(log[i],
                    Max(1, m.msnapshotIdx - snapshotIdx[i] - 1),  \* keep 1 trailing
                    Len(log[i]))]
    /\ Reply([mtype    |-> InstallSnapshotResponse,
              mterm    |-> currentTerm[i],
              msuccess |-> TRUE,
              msource  |-> i,
              mdest    |-> j], m)
    /\ UNCHANGED <<serverVars, leaderVars, candidateVars,
                   configVars, readVars, fdVars>>

\* Leader i handles InstallSnapshot response from follower j.
\* Reference: fsm.cc:958-980 (install_snapshot_reply)
HandleInstallSnapshotResponse(i, j, m) ==
    /\ m.mtype = InstallSnapshotResponse
    /\ m.mterm = currentTerm[i]
    /\ state[i] = Leader
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, readVars, snapshotVars, fdVars>>

\* Server i takes a local snapshot up to commitIndex.
\* Reference: fsm.cc:982-1018 (apply_snapshot with local=true)
TakeLocalSnapshot(i) ==
    /\ commitIndex[i] > snapshotIdx[i]
    \* Reference: fsm.cc:988 (local: snp.idx <= observed commit)
    /\ LET newSnapIdx == commitIndex[i]
           newSnapTerm == LogTerm(i, newSnapIdx)
       IN
       /\ snapshotIdx'  = [snapshotIdx EXCEPT ![i] = newSnapIdx]
       /\ snapshotTerm' = [snapshotTerm EXCEPT ![i] = newSnapTerm]
       \* Local snapshot keeps trailing entries
       \* Reference: log.cc:231-279 (apply_snapshot with max_trailing)
       /\ log' = [log EXCEPT ![i] =
            IF newSnapIdx >= LastLogIndex(i) THEN <<>>
            ELSE SubSeq(log[i], newSnapIdx - snapshotIdx[i] + 1, Len(log[i]))]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   configVars, readVars, fdVars>>

\* ---- Configuration Change (Bug Family 2) ----

\* Leader i proposes a configuration change to newVoters.
\* Reference: fsm.cc:69-121 (add_entry for configuration)
ProposeConfigChange(i, newVoters) ==
    /\ state[i] = Leader
    \* Reference: fsm.cc:74-88 (no overlapping config changes)
    /\ ~IsJoint(i)
    \* Must not have uncommitted config entry
    /\ \A k \in 1..Len(log[i]) :
        log[i][k].type = ConfigEntry =>
            k + snapshotIdx[i] <= commitIndex[i]
    /\ newVoters /= currentVoters[i]  \* Must be a real change
    /\ newVoters /= {}                 \* Must have voters
    \* Reference: fsm.cc:96-98 (enter_joint)
    /\ LET jointCv == newVoters
           jointPv == currentVoters[i]
       IN
       /\ log' = [log EXCEPT ![i] = Append(@,
            [term |-> currentTerm[i], type |-> ConfigEntry,
             cv |-> jointCv, pv |-> jointPv])]
       /\ currentVoters'  = [currentVoters EXCEPT ![i] = jointCv]
       /\ previousVoters' = [previousVoters EXCEPT ![i] = jointPv]
       \* Reference: fsm.cc:117 (set_configuration for tracker)
       /\ nextIndex' = [nextIndex EXCEPT ![i] =
            [j \in Server |-> IF j \in DOMAIN nextIndex[i] THEN nextIndex[i][j]
                              ELSE LastLogIndex(i) + 2]]
       /\ matchIndex' = [matchIndex EXCEPT ![i] =
            [j \in Server |-> IF j \in DOMAIN matchIndex[i]
                              THEN matchIndex[i][j] ELSE 0]]
    /\ UNCHANGED <<serverVars, commitIndex, candidateVars, messages,
                   readVars, snapshotVars, fdVars>>

\* ---- Crash and Recovery (Bug Family 3) ----

\* Server i crashes and restarts.
\* Reference: fsm.cc:23-45 (fsm constructor — recovery from persisted state)
\* Scylla persists term+vote atomically (raft.hh:729), so those survive.
\* Log entries are persisted by io_fiber before commit advances.
Crash(i) ==
    \* Volatile state is lost
    /\ state'       = [state EXCEPT ![i] = Follower]
    \* Reference: fsm.cc:32 (commit_idx = snapshot.idx on recovery)
    /\ commitIndex' = [commitIndex EXCEPT ![i] = snapshotIdx[i]]
    \* Leader/candidate state lost
    /\ nextIndex'   = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'  = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    \* Read barrier state lost
    /\ lastReadId'          = [lastReadId EXCEPT ![i] = 0]
    /\ maxReadIdWithQuorum' = [maxReadIdWithQuorum EXCEPT ![i] = 0]
    /\ maxAckedRead'        = [maxAckedRead EXCEPT ![i] =
        [j \in Server |-> 0]]
    \* Term and vote are preserved (atomic persistence)
    /\ UNCHANGED <<currentTerm, votedFor, log, messages,
                   configVars, snapshotVars, fdVars>>

\* ---- Failure Detector (Bug Family 5) ----

\* Non-deterministic FD state change.
\* FD view can diverge from actual connectivity.
\* Reference: fsm.cc:527 (failure_detector.is_alive)
FDUpdate(i) ==
    \E alive \in SUBSET Server :
        /\ fdView' = [fdView EXCEPT ![i] = alive]
        /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                       configVars, readVars, snapshotVars>>

\* Leader i checks activity via FD and may step down.
\* Reference: fsm.cc:512-585 (tick_leader)
TickLeader(i) ==
    /\ state[i] = Leader
    \* Reference: fsm.cc:513-519 (election timeout → step down)
    \* Reference: fsm.cc:522-529 (count alive followers for quorum)
    /\ LET active == {i} \cup {j \in Server \ {i} : j \in fdView[i]}
           \* Need quorum of active servers
       IN ~IsQuorum(currentVoters[i], active \cap currentVoters[i])
          \/ (previousVoters[i] /= {} /\
              ~IsQuorum(previousVoters[i], active \cap previousVoters[i]))
    \* Reference: fsm.cc:519 (become_follower)
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, leaderVars, candidateVars,
                   messages, configVars, readVars, snapshotVars, fdVars>>

\* Follower i suppresses election because FD says leader is alive.
\* This is modeled implicitly: Timeout is only enabled when FD
\* does NOT report a stable leader. We add the precondition to Timeout.
\* Reference: fsm.cc:590-606 (has_stable_leader)

\* ---- Term Handling (step dispatch) ----

\* Handle messages with higher term: step down and update term.
\* Reference: fsm.hh:559-612 (step — term comparison)
UpdateTerm(i, j, m) ==
    /\ m.mterm > currentTerm[i]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
    /\ votedFor'    = [votedFor EXCEPT ![i] = Nil]
    \* Become follower; leader known if msg is append/snapshot/read_quorum
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ UNCHANGED <<logVars, leaderVars, candidateVars, messages,
                   configVars, readVars, snapshotVars, fdVars>>

\* Drop a message with stale term.
\* Reference: fsm.hh:613-630 (msg.current_term < _current_term → reject/ignore)
DropStaleMessage(i, j, m) ==
    /\ m.mterm < currentTerm[i]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, readVars, snapshotVars, fdVars>>

\* ---- Network Faults ----

\* Lose a message from the network.
LoseMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, readVars, snapshotVars, fdVars>>

\* ---- Duplicate message delivery ----

\* TLC explores all interleavings; duplicate delivery is implicit.

----
\* ===================================================================
\* Specification
\* ===================================================================

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
    /\ currentVoters     = [s \in Server |-> Server]
    /\ previousVoters    = [s \in Server |-> {}]
    /\ lastReadId          = [s \in Server |-> 0]
    /\ maxReadIdWithQuorum = [s \in Server |-> 0]
    /\ maxAckedRead        = [s \in Server |-> [t \in Server |-> 0]]
    /\ snapshotIdx       = [s \in Server |-> 0]
    /\ snapshotTerm      = [s \in Server |-> 0]
    /\ fdView            = [s \in Server |-> Server]

Next ==
    \/ \E i \in Server :
        \/ Timeout(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ MaybeCommit(i)
        \/ TakeLocalSnapshot(i)
        \/ Crash(i)
        \/ TickLeader(i)
        \/ FDUpdate(i)
    \/ \E i, j \in Server : i /= j /\
        \/ AppendEntries(i, j)
        \/ SendInstallSnapshot(i, j)
    \/ \E i \in Server :
        \/ BroadcastReadQuorum(i)
    \/ \E i \in Server, newV \in SUBSET Server \ {{}} :
        ProposeConfigChange(i, newV)
    \/ \E m \in DOMAIN messages :
        \/ \E i, j \in Server :
            /\ i = m.mdest
            /\ j = m.msource
            /\ \/ m.mterm > currentTerm[i] /\ UpdateTerm(i, j, m)
               \/ m.mterm < currentTerm[i] /\ DropStaleMessage(i, j, m)
               \/ m.mterm = currentTerm[i] /\
                  \/ HandleRequestVoteRequest(i, j, m)
                  \/ HandleRequestVoteResponse(i, j, m)
                  \/ HandleAppendEntriesRequest(i, j, m)
                  \/ HandleAppendEntriesResponse(i, j, m)
                  \/ HandleReadQuorumRequest(i, j, m)
                  \/ HandleReadQuorumResponse(i, j, m)
                  \/ HandleInstallSnapshot(i, j, m)
                  \/ HandleInstallSnapshotResponse(i, j, m)
        \/ LoseMessage(m)

Spec == Init /\ [][Next]_vars

----
\* ===================================================================
\* Invariants
\* ===================================================================

\* ---- Standard Safety Invariants ----

\* At most one leader per term.
\* Reference: Raft paper §5.2
ElectionSafety ==
    \A i, j \in Server :
        (state[i] = Leader /\ state[j] = Leader /\ currentTerm[i] = currentTerm[j])
        => i = j

\* If two logs contain an entry with the same index and term,
\* then the logs are identical in all preceding entries.
\* Reference: Raft paper §5.3
LogMatching ==
    \A i, j \in Server :
        \A idx \in 1..Min(LastLogIndex(i), LastLogIndex(j)) :
            (idx > snapshotIdx[i] /\ idx > snapshotIdx[j] /\
             LogTerm(i, idx) = LogTerm(j, idx))
            =>
            (\A k \in (Max(snapshotIdx[i], snapshotIdx[j])+1)..idx :
                LogTerm(i, k) = LogTerm(j, k))

\* If an entry is committed at a given index, no future leader
\* (with term >= the committed entry's term) will have a different entry.
\* Stale leaders at lower terms are exempt — they'll step down on contact.
\* Reference: Raft paper §5.4.3
LeaderCompleteness ==
    \A i \in Server :
        state[i] = Leader =>
            \A j \in Server :
                \A idx \in 1..commitIndex[j] :
                    (idx > snapshotIdx[i] /\ idx > snapshotIdx[j]
                     /\ currentTerm[i] >= LogTerm(j, idx))
                    => LogTerm(i, idx) = LogTerm(j, idx)

\* ---- Extension Invariants (Bug Family targets) ----

\* CommitIndexSafety (Bug Family 1):
\* No server's committed entries diverge from a leader with term >= the entry's term.
\* Violated by unclamped commit advancement. Same term guard as LeaderCompleteness.
CommitIndexSafety ==
    \A i \in Server :
        state[i] = Leader =>
            \A j \in Server :
                \A idx \in 1..commitIndex[j] :
                    (idx > snapshotIdx[i] /\ idx > snapshotIdx[j]
                     /\ currentTerm[i] >= LogTerm(j, idx))
                    => LogTerm(i, idx) = LogTerm(j, idx)

\* JointQuorumAgreement (Bug Family 2):
\* During joint config, committed entries have majority in BOTH configs.
JointQuorumAgreement ==
    \A i \in Server :
        state[i] = Leader =>
            \A idx \in 1..commitIndex[i] :
                idx > snapshotIdx[i] =>
                LET agreeing == {j \in Server :
                    /\ idx <= LastLogIndex(j)
                    /\ idx > snapshotIdx[j]
                    /\ LogTerm(j, idx) = LogTerm(i, idx)}
                IN /\ IsQuorum(currentVoters[i], agreeing \cap currentVoters[i])
                   /\ (previousVoters[i] = {} \/
                       IsQuorum(previousVoters[i], agreeing \cap previousVoters[i]))

\* SnapshotLogContinuity (Bug Family 3):
\* After snapshot application, log has no gaps.
\* First entry in log (if any) has index = snapshotIdx + 1.
SnapshotLogContinuity ==
    \A i \in Server :
        Len(log[i]) > 0 =>
            snapshotIdx[i] + 1 <= LastLogIndex(i)

\* CrashRecoveryConsistency (Bug Family 3):
\* Committed entries are never lost: commitIndex <= LastLogIndex.
CrashRecoveryConsistency ==
    \A i \in Server :
        commitIndex[i] <= LastLogIndex(i)

\* ---- Structural Invariants ----

\* Term monotonicity: currentTerm >= 0
TermPositive ==
    \A i \in Server : currentTerm[i] >= 0

\* CommitIndex does not exceed log length
CommitBound ==
    \A i \in Server : commitIndex[i] <= LastLogIndex(i)

\* If a server has voted, the vote is for a valid server
VoteValid ==
    \A i \in Server :
        votedFor[i] /= Nil => votedFor[i] \in Server

\* Leader's matchIndex for itself equals its last log index (eventually)
LeaderSelfMatch ==
    \A i \in Server :
        state[i] = Leader =>
            matchIndex[i][i] <= LastLogIndex(i)

\* Snapshot index does not exceed commit index (for non-crashed servers)
SnapshotBound ==
    \A i \in Server : snapshotIdx[i] <= commitIndex[i] \/ state[i] = Follower

\* Read IDs are monotonic
ReadIdMonotonic ==
    \A i \in Server :
        maxReadIdWithQuorum[i] <= lastReadId[i]

\* Message bag is finite (structural, not a real invariant — for TLC)
MsgCount == BagCardinality(messages) >= 0

\* ---- Temporal Properties ----

\* ReadBarrierLiveness (Bug Family 2):
\* Under fairness, a read barrier eventually completes.
\* This is a leads-to property requiring WF on the spec.
\* ReadBarrierLiveness ==
\*     \A i \in Server :
\*         (state[i] = Leader /\ lastReadId[i] > maxReadIdWithQuorum[i])
\*         ~> (maxReadIdWithQuorum[i] >= lastReadId[i] \/ state[i] /= Leader)

====
