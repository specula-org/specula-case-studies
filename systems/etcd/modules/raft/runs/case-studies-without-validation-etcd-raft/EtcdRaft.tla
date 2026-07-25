------------------------------ MODULE EtcdRaft --------------------------------
\* Formal specification of the etcd-raft implementation.
\* Models the actual implementation logic from https://github.com/etcd-io/raft
\* with focus on:
\*   1. Joint consensus config changes (issue #372 quorum overlap)
\*   2. Election safety with PreVote and CheckQuorum
\*   3. Log consistency under leader changes
\*
\* This spec models the IMPLEMENTATION, not the Raft paper.

EXTENDS Naturals, Integers, FiniteSets, Sequences, TLC

\* ============================================================================
\* Constants
\* ============================================================================

CONSTANT Server
CONSTANT Nil
CONSTANTS Follower, Candidate, Leader, PreCandidate
CONSTANT MaxLogLength, MaxTerm, MaxConfigChanges, MaxMessages

\* ============================================================================
\* Variables
\* ============================================================================

VARIABLE currentTerm   \* [raft.go:344]
VARIABLE votedFor      \* [raft.go:345]
VARIABLE state         \* [raft.go:357]
VARIABLE leader        \* [raft.go:380]
VARIABLE log           \* [raft.go:350] Sequence of [term, type, value]
VARIABLE commitIndex   \* [log.go:33]
VARIABLE config        \* [tracker/tracker.go:28] <<incoming_voters, outgoing_voters>>
VARIABLE pendingConfIndex \* [raft.go:390]
VARIABLE votesGranted  \* Set of servers that granted vote
VARIABLE votesResponded \* Set of servers that responded to vote
VARIABLE matchIndex    \* [tracker/progress.go:33]
VARIABLE messages      \* Network messages (set)
VARIABLE configChangeCount \* For bounding

vars == <<currentTerm, votedFor, state, leader, log, commitIndex,
          config, pendingConfIndex, votesGranted, votesResponded,
          matchIndex, messages, configChangeCount>>

\* ============================================================================
\* Helpers
\* ============================================================================

GetConfig(i) == config[i][1]
GetOutgoingConfig(i) == config[i][2]
IsJointConfig(i) == config[i][2] /= {}
AllVoters(i) == GetConfig(i) \union GetOutgoingConfig(i)

Quorum(s) == {q \in SUBSET s : Cardinality(q) * 2 > Cardinality(s)}

LastTerm(xlog) == IF xlog = <<>> THEN 0 ELSE xlog[Len(xlog)].term

Min2(a, b) == IF a < b THEN a ELSE b
Max2(a, b) == IF a > b THEN a ELSE b

\* Max of a non-empty set
SetMax(S) == CHOOSE x \in S : \A y \in S : x >= y

\* Is candidate's log at least as up-to-date as voter's?
\* [log.go isUpToDate]
IsUpToDate(candidateLastTerm, candidateLastIndex, voterLastTerm, voterLastIndex) ==
    \/ candidateLastTerm > voterLastTerm
    \/ /\ candidateLastTerm = voterLastTerm
       /\ candidateLastIndex >= voterLastIndex

\* Check if a set of agreeing servers forms a joint quorum for server i's config
HasJointQuorum(i, agreeSet) ==
    IF IsJointConfig(i) THEN
        /\ (agreeSet \intersect GetConfig(i)) \in Quorum(GetConfig(i))
        /\ (agreeSet \intersect GetOutgoingConfig(i)) \in Quorum(GetOutgoingConfig(i))
    ELSE
        (agreeSet \intersect GetConfig(i)) \in Quorum(GetConfig(i))

\* Network helpers
Send(m) == messages' = messages \union {m}
Discard(m) == messages' = messages \ {m}
Reply(response, request) == messages' = (messages \ {request}) \union {response}

\* ============================================================================
\* Type Invariant
\* ============================================================================

TypeOK ==
    /\ currentTerm \in [Server -> Nat]
    /\ votedFor \in [Server -> Server \union {Nil}]
    /\ state \in [Server -> {Follower, Candidate, Leader, PreCandidate}]
    /\ leader \in [Server -> Server \union {Nil}]
    /\ commitIndex \in [Server -> Nat]

\* ============================================================================
\* Initial State
\* ============================================================================

Init ==
    /\ currentTerm = [i \in Server |-> 0]
    /\ votedFor = [i \in Server |-> Nil]
    /\ state = [i \in Server |-> Follower]
    /\ leader = [i \in Server |-> Nil]
    /\ log = [i \in Server |-> <<>>]
    /\ commitIndex = [i \in Server |-> 0]
    /\ config = [i \in Server |-> <<Server, {}>>]
    /\ pendingConfIndex = [i \in Server |-> 0]
    /\ configChangeCount = 0
    /\ votesGranted = [i \in Server |-> {}]
    /\ votesResponded = [i \in Server |-> {}]
    /\ matchIndex = [i \in Server |-> [j \in Server |-> 0]]
    /\ messages = {}

\* ============================================================================
\* Server restarts
\* ============================================================================

\* [raft.go:891-900] Restart as follower, keeping persisted state
Restart(i) ==
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ leader' = [leader EXCEPT ![i] = Nil]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ pendingConfIndex' = [pendingConfIndex EXCEPT ![i] = 0]
    /\ UNCHANGED <<currentTerm, votedFor, log, commitIndex, config,
                   configChangeCount, messages>>

\* ============================================================================
\* Election: Timeout -> PreCandidate -> Candidate -> Leader
\* ============================================================================

\* [raft.go:917-931] Become PreCandidate (does NOT change term/vote)
Timeout(i) ==
    /\ state[i] \in {Follower, Candidate, PreCandidate}
    /\ i \in GetConfig(i)
    /\ currentTerm[i] < MaxTerm
    /\ state' = [state EXCEPT ![i] = PreCandidate]
    /\ leader' = [leader EXCEPT ![i] = Nil]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ UNCHANGED <<currentTerm, votedFor, log, commitIndex, config,
                   pendingConfIndex, configChangeCount, matchIndex, messages>>

\* [raft.go:1052-1072] PreCandidate sends MsgPreVote
RequestPreVote(i, j) ==
    /\ state[i] = PreCandidate
    /\ j \in AllVoters(i)
    /\ j /= i
    /\ j \notin votesResponded[i]
    /\ Cardinality(messages) < MaxMessages
    /\ Send([mtype |-> "PreVote",
             mterm |-> currentTerm[i] + 1,
             mlastLogTerm |-> LastTerm(log[i]),
             mlastLogIndex |-> Len(log[i]),
             msource |-> i,
             mdest |-> j])
    /\ UNCHANGED <<currentTerm, votedFor, state, leader, log, commitIndex,
                   config, pendingConfIndex, configChangeCount,
                   votesGranted, votesResponded, matchIndex>>

\* Handle PreVote self-vote: PreCandidate votes for itself
PreVoteSelf(i) ==
    /\ state[i] = PreCandidate
    /\ i \notin votesResponded[i]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = @ \union {i}]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = @ \union {i}]
    /\ UNCHANGED <<currentTerm, votedFor, state, leader, log, commitIndex,
                   config, pendingConfIndex, configChangeCount, matchIndex, messages>>

\* [raft.go:1204-1254] Handle PreVote request
HandlePreVoteReq(i, j, m) ==
    /\ m.mtype = "PreVote"
    /\ m.mdest = i
    /\ m.msource = j
    /\ LET
        canVote == \/ votedFor[i] = j
                   \/ (votedFor[i] = Nil /\ leader[i] = Nil)
                   \/ m.mterm > currentTerm[i]
        candidateLogOk == IsUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                      LastTerm(log[i]), Len(log[i]))
        grant == canVote /\ candidateLogOk
       IN
        /\ IF grant
           THEN Reply([mtype |-> "PreVoteResp", mterm |-> m.mterm,
                       msource |-> i, mdest |-> j, mreject |-> FALSE], m)
           ELSE Reply([mtype |-> "PreVoteResp", mterm |-> currentTerm[i],
                       msource |-> i, mdest |-> j, mreject |-> TRUE], m)
        \* [raft.go:1107] PreVote does NOT change term
        /\ UNCHANGED <<currentTerm, votedFor, state, leader, log, commitIndex,
                       config, pendingConfIndex, configChangeCount,
                       votesGranted, votesResponded, matchIndex>>

\* [raft.go:1691-1706] Handle PreVote response
HandlePreVoteResp(i, j, m) ==
    /\ m.mtype = "PreVoteResp"
    /\ m.mdest = i
    /\ m.msource = j
    /\ state[i] = PreCandidate
    /\ LET
        newGranted == IF ~m.mreject THEN votesGranted[i] \union {j} ELSE votesGranted[i]
        newResponded == votesResponded[i] \union {j}
        wonPreVote == HasJointQuorum(i, newGranted)
       IN
        /\ IF wonPreVote
           THEN
             \* Won pre-vote -> become Candidate [raft.go:1696-1697]
             \* [raft.go:902-915] becomeCandidate: increment term, vote for self
             /\ state' = [state EXCEPT ![i] = Candidate]
             /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
             /\ votedFor' = [votedFor EXCEPT ![i] = i]
             /\ leader' = [leader EXCEPT ![i] = Nil]
             /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
             /\ votesResponded' = [votesResponded EXCEPT ![i] = {i}]
           ELSE
             /\ votesGranted' = [votesGranted EXCEPT ![i] = newGranted]
             /\ votesResponded' = [votesResponded EXCEPT ![i] = newResponded]
             /\ UNCHANGED <<state, currentTerm, votedFor, leader>>
        /\ Discard(m)
        /\ UNCHANGED <<log, commitIndex, config, pendingConfIndex,
                       configChangeCount, matchIndex>>

\* [raft.go:1052-1072] Candidate sends MsgVote
RequestVote(i, j) ==
    /\ state[i] = Candidate
    /\ j \in AllVoters(i)
    /\ j /= i
    /\ j \notin votesResponded[i]
    /\ Cardinality(messages) < MaxMessages
    /\ Send([mtype |-> "Vote",
             mterm |-> currentTerm[i],
             mlastLogTerm |-> LastTerm(log[i]),
             mlastLogIndex |-> Len(log[i]),
             msource |-> i,
             mdest |-> j])
    /\ UNCHANGED <<currentTerm, votedFor, state, leader, log, commitIndex,
                   config, pendingConfIndex, configChangeCount,
                   votesGranted, votesResponded, matchIndex>>

\* [raft.go:1204-1254] Handle Vote request
HandleVoteReq(i, j, m) ==
    /\ m.mtype = "Vote"
    /\ m.mdest = i
    /\ m.msource = j
    /\ m.mterm >= currentTerm[i]
    /\ LET
        \* [raft.go:1092] Step down if higher term
        stepDown == m.mterm > currentTerm[i]
        newTerm == IF stepDown THEN m.mterm ELSE currentTerm[i]
        newVotedFor == IF stepDown THEN Nil ELSE votedFor[i]
        newLeader == IF stepDown THEN Nil ELSE leader[i]

        \* [raft.go:1206-1210] canVote
        canVote == \/ newVotedFor = j
                   \/ (newVotedFor = Nil /\ newLeader = Nil)

        \* [raft.go:1212-1214] Log up-to-date
        candidateLogOk == IsUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                      LastTerm(log[i]), Len(log[i]))
        grant == canVote /\ candidateLogOk
       IN
        /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
        /\ state' = [state EXCEPT ![i] = IF stepDown THEN Follower ELSE state[i]]
        /\ leader' = [leader EXCEPT ![i] = newLeader]
        /\ IF grant
           THEN
             /\ votedFor' = [votedFor EXCEPT ![i] = j]
             /\ Reply([mtype |-> "VoteResp", mterm |-> newTerm,
                       msource |-> i, mdest |-> j, mreject |-> FALSE], m)
           ELSE
             /\ votedFor' = [votedFor EXCEPT ![i] = newVotedFor]
             /\ Reply([mtype |-> "VoteResp", mterm |-> newTerm,
                       msource |-> i, mdest |-> j, mreject |-> TRUE], m)
        /\ UNCHANGED <<log, commitIndex, config, pendingConfIndex,
                       configChangeCount, votesGranted, votesResponded, matchIndex>>

\* [raft.go:1691-1710] Handle Vote response
HandleVoteResp(i, j, m) ==
    /\ m.mtype = "VoteResp"
    /\ m.mdest = i
    /\ m.msource = j
    /\ state[i] = Candidate
    /\ m.mterm = currentTerm[i]
    /\ LET
        newGranted == IF ~m.mreject THEN votesGranted[i] \union {j} ELSE votesGranted[i]
        newResponded == votesResponded[i] \union {j}
        wonElection == HasJointQuorum(i, newGranted)
       IN
        /\ IF wonElection
           THEN
             \* [raft.go:1699] becomeLeader
             /\ state' = [state EXCEPT ![i] = Leader]
             /\ leader' = [leader EXCEPT ![i] = i]
             \* [raft.go:958] pendingConfIndex = lastIndex
             /\ pendingConfIndex' = [pendingConfIndex EXCEPT ![i] = Len(log[i])]
             \* [raft.go:961-965] Append empty entry (leader's no-op)
             /\ log' = [log EXCEPT ![i] = Append(@, [term |-> currentTerm[i],
                                                      type |-> "normal",
                                                      value |-> Nil])]
             \* [raft.go:939] reset matchIndex
             /\ matchIndex' = [matchIndex EXCEPT ![i] =
                    [k \in Server |-> IF k = i THEN Len(log[i]) + 1 ELSE 0]]
             /\ votesGranted' = [votesGranted EXCEPT ![i] = newGranted]
             /\ votesResponded' = [votesResponded EXCEPT ![i] = newResponded]
           ELSE
             /\ votesGranted' = [votesGranted EXCEPT ![i] = newGranted]
             /\ votesResponded' = [votesResponded EXCEPT ![i] = newResponded]
             /\ UNCHANGED <<state, leader, pendingConfIndex, log, matchIndex>>
        /\ Discard(m)
        /\ UNCHANGED <<currentTerm, votedFor, commitIndex, config, configChangeCount>>

\* ============================================================================
\* Log Replication
\* ============================================================================

\* [raft.go:1286-1345] Leader appends a normal entry
ClientRequest(i) ==
    /\ state[i] = Leader
    /\ Len(log[i]) < MaxLogLength
    /\ log' = [log EXCEPT ![i] = Append(@, [term |-> currentTerm[i],
                                             type |-> "normal",
                                             value |-> Len(@) + 1])]
    /\ matchIndex' = [matchIndex EXCEPT ![i][i] = Len(log[i]) + 1]
    /\ UNCHANGED <<currentTerm, votedFor, state, leader, commitIndex,
                   config, pendingConfIndex, configChangeCount,
                   votesGranted, votesResponded, messages>>

\* [raft.go:616-660] Leader sends MsgApp to follower
AppendEntries(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ j \in AllVoters(i)
    /\ Cardinality(messages) < MaxMessages
    /\ LET
        prevIdx == matchIndex[i][j]
        prevTerm == IF prevIdx > 0 /\ prevIdx <= Len(log[i])
                    THEN log[i][prevIdx].term ELSE 0
        \* Send one entry at a time for simplicity
        ents == IF prevIdx < Len(log[i])
                THEN <<log[i][prevIdx + 1]>>
                ELSE <<>>
        lastSent == IF prevIdx < Len(log[i]) THEN prevIdx + 1 ELSE prevIdx
       IN
        /\ Send([mtype |-> "App",
                 mterm |-> currentTerm[i],
                 mprevLogIndex |-> prevIdx,
                 mprevLogTerm |-> prevTerm,
                 mentries |-> ents,
                 mcommitIndex |-> Min2(commitIndex[i], lastSent),
                 msource |-> i,
                 mdest |-> j])
    /\ UNCHANGED <<currentTerm, votedFor, state, leader, log, commitIndex,
                   config, pendingConfIndex, configChangeCount,
                   votesGranted, votesResponded, matchIndex>>

\* [raft.go:1786-1828] Handle MsgApp
HandleAppendEntries(i, j, m) ==
    /\ m.mtype = "App"
    /\ m.mdest = i
    /\ m.msource = j
    /\ m.mterm >= currentTerm[i]
    /\ LET
        stepDown == m.mterm > currentTerm[i]
        newTerm == IF stepDown THEN m.mterm ELSE currentTerm[i]
        newVotedFor == IF stepDown THEN Nil ELSE votedFor[i]
        \* [raft.go:1725-1728] Follower updates leader
        newState == IF stepDown THEN Follower
                    ELSE IF state[i] \in {Candidate, PreCandidate} THEN Follower
                    ELSE state[i]

        \* [raft.go:1791] Check log match
        logOk == \/ m.mprevLogIndex = 0
                 \/ /\ m.mprevLogIndex > 0
                    /\ m.mprevLogIndex <= Len(log[i])
                    /\ log[i][m.mprevLogIndex].term = m.mprevLogTerm
       IN
        /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
        /\ state' = [state EXCEPT ![i] = newState]
        /\ votedFor' = [votedFor EXCEPT ![i] = newVotedFor]
        /\ leader' = [leader EXCEPT ![i] = j]
        /\ IF logOk
           THEN
             LET
               \* Truncate and append
               baseLog == SubSeq(log[i], 1, m.mprevLogIndex)
               newLog == IF m.mentries = <<>> THEN log[i] ELSE baseLog \o m.mentries
               newCommit == Max2(commitIndex[i], Min2(m.mcommitIndex, Len(newLog)))
             IN
               /\ log' = [log EXCEPT ![i] = newLog]
               /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommit]
               /\ Reply([mtype |-> "AppResp", mterm |-> newTerm,
                         msource |-> i, mdest |-> j,
                         mmatchIndex |-> Len(newLog), mreject |-> FALSE], m)
           ELSE
             /\ UNCHANGED <<log, commitIndex>>
             /\ Reply([mtype |-> "AppResp", mterm |-> newTerm,
                       msource |-> i, mdest |-> j,
                       mmatchIndex |-> 0, mreject |-> TRUE], m)
        /\ UNCHANGED <<config, pendingConfIndex, configChangeCount,
                       votesGranted, votesResponded, matchIndex>>

\* [raft.go:1376-1569] Handle MsgAppResp
HandleAppendEntriesResp(i, j, m) ==
    /\ m.mtype = "AppResp"
    /\ m.mdest = i
    /\ m.msource = j
    /\ state[i] = Leader
    /\ m.mterm = currentTerm[i]
    /\ IF m.mreject
       THEN
         /\ matchIndex' = [matchIndex EXCEPT ![i][j] = Max2(0, matchIndex[i][j] - 1)]
       ELSE
         /\ matchIndex' = [matchIndex EXCEPT ![i][j] = Max2(@, m.mmatchIndex)]
    /\ Discard(m)
    /\ UNCHANGED <<currentTerm, votedFor, state, leader, log, commitIndex,
                   config, pendingConfIndex, configChangeCount,
                   votesGranted, votesResponded>>

\* ============================================================================
\* Commit Index Advancement
\* ============================================================================

\* [raft.go:778-781] Leader advances commit index
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET
        \* [raft.go:781, tracker.go:179] Only commit entries from current term
        Agree(idx) == {k \in AllVoters(i) : matchIndex[i][k] >= idx}
        candidates == {idx \in (commitIndex[i]+1)..Len(log[i]) :
                        /\ HasJointQuorum(i, Agree(idx))
                        /\ log[i][idx].term = currentTerm[i]}
       IN
        /\ candidates /= {}
        /\ LET newCI == SetMax(candidates)
           IN commitIndex' = [commitIndex EXCEPT ![i] = newCI]
    /\ UNCHANGED <<currentTerm, votedFor, state, leader, log,
                   config, pendingConfIndex, configChangeCount,
                   votesGranted, votesResponded, matchIndex, messages>>

\* ============================================================================
\* Config Changes
\* ============================================================================

\* [raft.go:1301-1339] Leader proposes a config change
ProposeConfigChange(i, newVoters) ==
    /\ state[i] = Leader
    /\ Len(log[i]) < MaxLogLength
    /\ configChangeCount < MaxConfigChanges
    \* [raft.go:1318] pendingConfIndex guard: no pending unapplied conf change
    /\ pendingConfIndex[i] <= commitIndex[i]
    \* [raft.go:1319] Not already in joint config
    /\ ~IsJointConfig(i)
    /\ newVoters /= GetConfig(i)
    /\ newVoters /= {}
    /\ newVoters \subseteq Server
    /\ log' = [log EXCEPT ![i] = Append(@, [term |-> currentTerm[i],
                                             type |-> "config",
                                             value |-> newVoters])]
    /\ pendingConfIndex' = [pendingConfIndex EXCEPT ![i] = Len(log[i]) + 1]
    /\ matchIndex' = [matchIndex EXCEPT ![i][i] = Len(log[i]) + 1]
    /\ UNCHANGED <<currentTerm, votedFor, state, leader, commitIndex,
                   config, configChangeCount,
                   votesGranted, votesResponded, messages>>

\* [raft.go:1947-2031] Apply a committed config change
\* KEY MODELING CHOICE: Config is applied at COMMIT time (not append time).
\* This is the etcd deviation from the Raft paper (D4 in bug_archaeology.md).
\* Issue #372 suggests this can lead to data loss without quorum overlap check.
ApplyConfigChange(i) ==
    /\ \E idx \in 1..Len(log[i]) :
        /\ idx <= commitIndex[i]
        /\ log[i][idx].type = "config"
        /\ config[i] /= <<log[i][idx].value, {}>>
        /\ config' = [config EXCEPT ![i] = <<log[i][idx].value, {}>>]
        /\ configChangeCount' = configChangeCount + 1
        \* [raft.go:1989-2000] Step down if leader was removed
        /\ IF state[i] = Leader /\ i \notin log[i][idx].value
           THEN /\ state' = [state EXCEPT ![i] = Follower]
                /\ leader' = [leader EXCEPT ![i] = Nil]
           ELSE UNCHANGED <<state, leader>>
        \* Clear pendingConfIndex if it was the pending one
        /\ IF pendingConfIndex[i] = idx
           THEN pendingConfIndex' = [pendingConfIndex EXCEPT ![i] = 0]
           ELSE UNCHANGED pendingConfIndex
    /\ UNCHANGED <<currentTerm, votedFor, log, commitIndex,
                   votesGranted, votesResponded, matchIndex, messages>>

\* ============================================================================
\* Higher-term step-down (for messages we receive but don't otherwise handle)
\* ============================================================================

\* [raft.go:1092-1123]
UpdateTerm(i, j, m) ==
    /\ m.mterm > currentTerm[i]
    /\ m.mdest = i
    /\ m.mtype \notin {"PreVote", "PreVoteResp"}
    /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
    /\ leader' = [leader EXCEPT ![i] = IF m.mtype = "App" THEN j ELSE Nil]
    /\ UNCHANGED <<log, commitIndex, config, pendingConfIndex, configChangeCount,
                   votesGranted, votesResponded, matchIndex, messages>>

\* ============================================================================
\* Message loss
\* ============================================================================

DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<currentTerm, votedFor, state, leader, log, commitIndex,
                   config, pendingConfIndex, configChangeCount,
                   votesGranted, votesResponded, matchIndex>>

\* ============================================================================
\* Next-State Relation
\* ============================================================================

Next ==
    \/ \E i \in Server : Restart(i)
    \/ \E i \in Server : Timeout(i)
    \/ \E i \in Server : PreVoteSelf(i)
    \/ \E i \in Server : ClientRequest(i)
    \/ \E i \in Server : AdvanceCommitIndex(i)
    \/ \E i \in Server : ApplyConfigChange(i)
    \/ \E i,j \in Server : RequestPreVote(i, j)
    \/ \E i,j \in Server : RequestVote(i, j)
    \/ \E i,j \in Server : AppendEntries(i, j)
    \* Restrict config changes to interesting cases for Issue #372 scenario
    \* removing 1 or 2 servers (the dangerous case for quorum overlap)
    \/ \E i \in Server, v \in {s \in SUBSET Server : s /= {} /\ Cardinality(s) >= Cardinality(Server) - 2} : ProposeConfigChange(i, v)
    \/ \E m \in messages :
        \/ HandlePreVoteReq(m.mdest, m.msource, m)
        \/ HandlePreVoteResp(m.mdest, m.msource, m)
        \/ HandleVoteReq(m.mdest, m.msource, m)
        \/ HandleVoteResp(m.mdest, m.msource, m)
        \/ HandleAppendEntries(m.mdest, m.msource, m)
        \/ HandleAppendEntriesResp(m.mdest, m.msource, m)
        \/ DropMessage(m)

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* Safety Invariants
\* ============================================================================

\* At most one leader per term [Standard Raft]
ElectionSafety ==
    \A i, j \in Server :
        (state[i] = Leader /\ state[j] = Leader /\ currentTerm[i] = currentTerm[j])
        => i = j

\* If two logs contain an entry with the same index and term,
\* the logs are identical up through that index [Standard Raft]
LogMatching ==
    \A i, j \in Server :
        \A n \in 1..Min2(Len(log[i]), Len(log[j])) :
            log[i][n].term = log[j][n].term =>
                SubSeq(log[i], 1, n) = SubSeq(log[j], 1, n)

\* Committed entries on any server must be present in any leader's log
\* [Standard Raft - Leader Completeness]
LeaderCompleteness ==
    \A ldr \in Server :
        state[ldr] = Leader =>
            \A s \in Server :
                \A idx \in 1..commitIndex[s] :
                    /\ idx <= Len(log[s])
                    /\ idx <= Len(log[ldr])
                    /\ log[ldr][idx] = log[s][idx]

\* Every committed index points to a valid log entry
CommittedEntryExists ==
    \A i \in Server :
        commitIndex[i] <= Len(log[i])

\* ============================================================================
\* State Constraint
\* ============================================================================

StateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= MaxTerm
    /\ \A i \in Server : Len(log[i]) <= MaxLogLength
    /\ configChangeCount <= MaxConfigChanges
    /\ Cardinality(messages) <= MaxMessages

===============================================================================
