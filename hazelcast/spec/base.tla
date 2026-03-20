---------------------------- MODULE base ----------------------------
\* TLA+ specification of Hazelcast CP Subsystem (Raft)
\*
\* Models the Raft consensus protocol as implemented in Hazelcast,
\* with extensions for:
\*   1. Leader lease / vote preservation (Bug Family 1)
\*   2. Pre-applied membership changes (Bug Family 2)
\*   3. Stale leader detection (Bug Family 3)
\*   4. PreVote protocol (Bug Family 4)
\*   5. Linearizable reads (Bug Family 5)
\*
\* Source: hazelcast/hazelcast @ f2fa6ae842
\* Key files:
\*   - RaftNodeImpl.java (1498 lines)
\*   - RaftState.java (607 lines)
\*   - handler/*.java (request/response handlers)
\*   - task/*.java (election, replication tasks)
\*   - state/*.java (leader, follower, candidate, query state)

EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of all possible server IDs

CONSTANTS Follower,          \* Server roles (RaftRole.java)
          Candidate,
          Leader

CONSTANT Nil                 \* Null value

CONSTANTS ValueEntry,        \* Log entry types
          ConfigEntry

\* Message types
CONSTANTS PreVoteRequestMsg,
          PreVoteResponseMsg,
          VoteRequestMsg,
          VoteResponseMsg,
          AppendEntriesRequestMsg,
          AppendSuccessResponseMsg,
          AppendFailureResponseMsg

\* Extension constant (Family 1: MC-1)
\* Models production mode where JVM asserts are disabled (-da)
\* Reference: AppendSuccessResponseHandlerTask.java:64 (assert-only term check)
CONSTANT AssertsDisabled

----
\* Variables
----

\* Per-server persistent state (survives crash)
\* Reference: RaftState.java:91,119,125
VARIABLE currentTerm         \* [Server -> Nat]
VARIABLE votedFor            \* [Server -> Server \cup {Nil}]
VARIABLE log                 \* [Server -> Seq(Entry)]

\* Per-server volatile state
\* Reference: RaftState.java:84,103
VARIABLE state               \* [Server -> {Follower, Candidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat]

\* Leader volatile state
\* Reference: LeaderState.java, FollowerState.java
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate state
\* Reference: CandidateState.java
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension 1+3: Leader lease tracking (Family 1, 3)
\* Models followers that have ACKed the leader's AppendEntries.
\* Reference: FollowerState.appendRequestAckTimestamp,
\*            LeaderState.majorityAppendRequestAckTimestamp (line 1374)
VARIABLE leaseContact        \* [Server -> SUBSET Server]

\* Extension 2: Pre-applied membership changes (Family 2)
\* committedConfig = committedGroupMembers (RaftState.java:74)
\* latestConfig = lastGroupMembers (RaftState.java:79)
\* Pre-apply: latestConfig updated before commit
\* Revert: latestConfig = committedConfig on log truncation
VARIABLE committedConfig     \* [Server -> SUBSET Server]
VARIABLE latestConfig        \* [Server -> SUBSET Server]

\* Extension 4: PreVote protocol (Family 4)
\* Tracks pre-vote grants received. {} = not pre-voting.
\* Reference: RaftState.preCandidateState (line 136)
VARIABLE preVote             \* [Server -> SUBSET Server]

\* Extension 5: Linearizable reads (Family 5)
\* Reference: QueryState.java (lines 45-181)
VARIABLE queryRound          \* [Server -> Nat]
VARIABLE queryCommitIndex    \* [Server -> Nat]
VARIABLE queryAcks           \* [Server -> SUBSET Server]
VARIABLE queryPending        \* [Server -> BOOLEAN]

----
\* Variable groups (for UNCHANGED clauses)
----

serverVars    == <<currentTerm, votedFor, state>>
logVars       == <<log, commitIndex>>
leaderVars    == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted>>
leaseVars     == <<leaseContact>>
configVars    == <<committedConfig, latestConfig>>
preVoteVars   == <<preVote>>
queryVars     == <<queryRound, queryCommitIndex, queryAcks, queryPending>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          leaseVars, configVars, preVoteVars, queryVars>>

----
\* Helpers
----

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b

MinSet(S) == CHOOSE x \in S : \A y \in S : x <= y
SetMax(S) == CHOOSE x \in S : \A y \in S : x >= y

\* Log helpers
LastLogIndex(i) == Len(log[i])
LastLogTerm(i)  == IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term ELSE 0
LogTerm(i, idx) == IF idx > 0 /\ idx <= Len(log[i]) THEN log[i][idx].term ELSE 0

\* Quorum check against a configuration
\* Reference: RaftGroupMembers.majority() — (memberCount / 2) + 1
IsQuorum(S, config) == Cardinality(S) * 2 > Cardinality(config)

\* Log up-to-date comparison
\* Reference: VoteRequestHandlerTask.java:106-116
LogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    \/ cLastTerm > vLastTerm
    \/ (cLastTerm = vLastTerm /\ cLastIdx >= vLastIdx)

\* Entry constructors
MakeEntry(t) == [term |-> t, type |-> ValueEntry, config |-> {}]
MakeConfigEntry(t, c) == [term |-> t, type |-> ConfigEntry, config |-> c]

\* Log conflict resolution for AppendEntries
\* Reference: AppendRequestHandlerTask.innerRun (lines 135-165)
\* Find the first index (1-based into entries) where entries and local log diverge.
\* Returns Len(entries)+1 if all entries match.
FindDivergence(localLog, prevIdx, entries) ==
    LET matchable == Max(0, Min(Len(entries), Len(localLog) - prevIdx))
        conflicts == {k \in 1..matchable : localLog[prevIdx + k].term /= entries[k].term}
    IN IF conflicts = {} THEN matchable + 1
       ELSE MinSet(conflicts)

\* Compute new log after AppendEntries
\* Reference: AppendRequestHandlerTask.innerRun (lines 131-185)
ComputeNewLog(localLog, prevIdx, entries) ==
    IF entries = <<>> THEN localLog
    ELSE LET d == FindDivergence(localLog, prevIdx, entries)
         IN IF d > Len(entries) THEN localLog
            ELSE SubSeq(localLog, 1, prevIdx + d - 1) \o SubSeq(entries, d, Len(entries))

\* Check if entries contain a ConfigEntry
HasConfigEntry(entries) ==
    \E k \in 1..Len(entries) : entries[k].type = ConfigEntry

\* Get the config from the first ConfigEntry in a sequence of entries
GetConfig(entries) ==
    LET idx == CHOOSE k \in 1..Len(entries) : entries[k].type = ConfigEntry
    IN entries[idx].config

\* Compute configs after crash recovery by replaying group commands from log
\* Reference: RaftNodeImpl.applyRestoredRaftGroupCommands (lines 1089-1128)
\* If N config entries: first N-1 committed, Nth pre-applied
CrashRecoveryState(logSeq) ==
    LET cfgIndices == {idx \in 1..Len(logSeq) : logSeq[idx].type = ConfigEntry}
    IN IF cfgIndices = {}
       THEN [ci |-> 0, cc |-> Server, lc |-> Server]
       ELSE LET lastIdx == SetMax(cfgIndices)
                others == cfgIndices \ {lastIdx}
            IN IF others = {}
               THEN [ci |-> 0, cc |-> Server, lc |-> logSeq[lastIdx].config]
               ELSE LET committedIdx == SetMax(others)
                    IN [ci |-> committedIdx,
                        cc |-> logSeq[committedIdx].config,
                        lc |-> logSeq[lastIdx].config]

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
    /\ currentTerm    = [s \in Server |-> 0]
    /\ votedFor       = [s \in Server |-> Nil]
    /\ log            = [s \in Server |-> <<>>]
    /\ state          = [s \in Server |-> Follower]
    /\ commitIndex    = [s \in Server |-> 0]
    /\ nextIndex      = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex     = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted   = [s \in Server |-> {}]
    /\ messages       = EmptyBag
    /\ leaseContact   = [s \in Server |-> {}]
    /\ committedConfig = [s \in Server |-> Server]
    /\ latestConfig   = [s \in Server |-> Server]
    /\ preVote        = [s \in Server |-> {}]
    /\ queryRound     = [s \in Server |-> 0]
    /\ queryCommitIndex = [s \in Server |-> 0]
    /\ queryAcks      = [s \in Server |-> {}]
    /\ queryPending   = [s \in Server |-> FALSE]

----
\* Election Actions
----

\* Server i starts pre-vote phase.
\* Reference: PreVoteTask.innerRun (lines 46-78)
\* Precondition: follower, no known leader (modeled by not having a leader),
\*               not already pre-voting, term matches (guard against stale timeout)
\* Sends PreVoteRequests with nextTerm = term + 1 (does NOT increment term)
Timeout(i) ==
    \* Only followers/candidates can start pre-vote (line 46-55)
    /\ state[i] \in {Follower, Candidate}
    /\ i \in latestConfig[i]
    \* Initialize pre-candidate state with self-vote (line 63)
    \* Reference: RaftState.initPreCandidateState (lines 466-469)
    /\ preVote' = [preVote EXCEPT ![i] = {i}]
    \* Send PreVoteRequests to all remote members (lines 73-75)
    /\ LET nextTerm == currentTerm[i] + 1
       IN SendAll({[mtype        |-> PreVoteRequestMsg,
                    mterm        |-> nextTerm,
                    mlastLogTerm |-> LastLogTerm(i),
                    mlastLogIndex |-> LastLogIndex(i),
                    msource      |-> i,
                    mdest        |-> j] : j \in latestConfig[i] \ {i}})
    \* If was candidate, demote to follower first (implicit in Timeout re-entering pre-vote)
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, leaderVars, candidateVars,
                   leaseVars, configVars, queryVars>>

\* Server i handles a PreVoteRequest from a candidate.
\* Reference: PreVoteRequestHandlerTask.innerRun (lines 51-84)
\* This is a READ-ONLY operation: no state is mutated.
\* Grants pre-vote if: term not stale, no leader stickiness, log up-to-date.
HandlePreVoteRequest(i, m) ==
    /\ m.mtype = PreVoteRequestMsg
    /\ m.mdest = i
    /\ LET nextTerm == m.mterm
           \* Check if our log is at least as up-to-date (lines 70-80)
           logOk == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                LastLogTerm(i), LastLogIndex(i))
           \* Grant if term is not stale and log is up-to-date (lines 56-83)
           grant == /\ nextTerm >= currentTerm[i] + 1  \* line 56: state.term() <= req.nextTerm()
                    /\ logOk
       IN Reply([mtype        |-> PreVoteResponseMsg,
                 mterm        |-> IF nextTerm > currentTerm[i] THEN nextTerm ELSE currentTerm[i],
                 mvoteGranted |-> grant,
                 msource      |-> i,
                 mdest        |-> m.msource], m)
    \* No state mutation (read-only)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, configVars, preVoteVars, queryVars>>

\* Server i handles a PreVoteResponse.
\* Reference: PreVoteResponseHandlerTask.handleResponse (lines 45-75)
\* If majority grants pre-vote, starts real election via LeaderElectionTask.
\* KEY (Family 4): Does NOT demote on higher-term response (line 53 — intentional).
HandlePreVoteResponse(i, m) ==
    /\ m.mtype = PreVoteResponseMsg
    /\ m.mdest = i
    \* Must be follower (line 48)
    /\ state[i] = Follower
    \* Not stale (line 53): resp.term() >= state.term()
    \* Note: does NOT demote on higher term (unlike VoteResponseHandler)
    /\ m.mterm >= currentTerm[i]
    \* Must be pre-voting (line 58-64)
    /\ preVote[i] /= {}
    /\ LET newPreVote == IF m.mvoteGranted
                         THEN preVote[i] \cup {m.msource}
                         ELSE preVote[i]
           majority == IsQuorum(newPreVote, latestConfig[i])
       IN
       \/ \* Sub-case 1: No majority yet — just record vote (lines 66-69)
          /\ ~majority
          /\ preVote' = [preVote EXCEPT ![i] = newPreVote]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         leaseVars, configVars, queryVars>>

       \/ \* Sub-case 2: Majority reached — start real election (lines 71-73)
          \* Reference: LeaderElectionTask.innerRun (lines 46-63)
          \* Transitions to Candidate via RaftState.toCandidate (lines 423-434)
          /\ majority
          /\ LET newTerm == currentTerm[i] + 1
             IN
             \* toCandidate: increment term, self-vote (RaftState.java:423-434)
             /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
             /\ state' = [state EXCEPT ![i] = Candidate]
             /\ votedFor' = [votedFor EXCEPT ![i] = i]
             \* persistVote: atomic (term, votedFor) persist (RaftState.java:394-399)
             /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
             /\ preVote' = [preVote EXCEPT ![i] = {}]
             \* Send VoteRequests to all remote members (LeaderElectionTask:59-61)
             /\ DiscardAndSendAll(m,
                    {[mtype        |-> VoteRequestMsg,
                      mterm        |-> newTerm,
                      mlastLogTerm |-> LastLogTerm(i),
                      mlastLogIndex |-> LastLogIndex(i),
                      mdisruptive  |-> FALSE,
                      msource      |-> i,
                      mdest        |-> j] : j \in latestConfig[i] \ {i}})
          /\ UNCHANGED <<logVars, leaderVars, leaseVars, configVars, queryVars>>

\* Server i handles a VoteRequest from a candidate.
\* Reference: VoteRequestHandlerTask.innerRun (lines 54-122)
\* Four outcomes: reject (stale term / already voted / log not up-to-date), grant.
\* KEY (Family 1): toFollower with same-term preserves votedFor (RaftState.setTerm:436-441)
HandleVoteRequest(i, m) ==
    /\ m.mtype = VoteRequestMsg
    /\ m.mdest = i
    /\ LET mterm    == m.mterm
           logOk    == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                   LastLogTerm(i), LastLogIndex(i))
           \* Can grant if log is up-to-date and either higher term or same term with no/same vote
           \* Reference: VoteRequestHandlerTask lines 94-116
           canGrant == /\ logOk
                       /\ \/ mterm > currentTerm[i]
                          \/ /\ mterm = currentTerm[i]
                             /\ votedFor[i] \in {Nil, m.msource}
       IN
       \/ \* Case 1: Reject — term too low (line 71)
          /\ mterm < currentTerm[i]
          /\ Reply([mtype        |-> VoteResponseMsg,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         leaseVars, configVars, preVoteVars, queryVars>>

       \/ \* Case 2: Reject — higher or same term but can't grant (voted for other or log not up-to-date)
          /\ mterm >= currentTerm[i]
          /\ ~canGrant
          \* If higher term: demote to follower (line 77-86)
          \* toFollower clears preCandidateState (RaftState.java:409)
          /\ IF mterm > currentTerm[i]
             THEN /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
                  /\ state' = [state EXCEPT ![i] = Follower]
                  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]   \* setTerm clears votedFor (line 440)
                  /\ preVote' = [preVote EXCEPT ![i] = {}]
             ELSE UNCHANGED <<currentTerm, state, votedFor, preVote>>
          /\ Reply([mtype        |-> VoteResponseMsg,
                    mterm        |-> mterm,
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, leaseVars, configVars, queryVars>>

       \/ \* Case 3: Grant vote (lines 118-121)
          /\ mterm >= currentTerm[i]
          /\ canGrant
          \* If higher term: demote first (line 77-86)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
          \* persistVote: atomic (term, votedFor) (RaftState.java:394-399, 561-567)
          /\ preVote' = [preVote EXCEPT ![i] = {}]
          /\ Reply([mtype        |-> VoteResponseMsg,
                    mterm        |-> mterm,
                    mvoteGranted |-> TRUE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, leaseVars, configVars, queryVars>>

\* Server i handles a VoteResponse.
\* Reference: VoteResponseHandlerTask.handleResponse (lines 55-85)
\* If majority grants, becomes leader via RaftState.toLeader (lines 448-454)
HandleVoteResponse(i, m) ==
    /\ m.mtype = VoteResponseMsg
    /\ m.mdest = i
    /\ state[i] = Candidate          \* line 58
    /\ \/ \* Sub-case 1: Higher term — demote (line 63-67)
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ preVote' = [preVote EXCEPT ![i] = {}]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         leaseVars, configVars, queryVars>>

       \/ \* Sub-case 2: Stale response — ignore (line 70-72)
          /\ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         leaseVars, configVars, preVoteVars, queryVars>>

       \/ \* Sub-case 3: Same term — process vote (lines 75-84)
          /\ m.mterm = currentTerm[i]
          /\ LET newGrants == IF m.mvoteGranted
                              THEN votesGranted[i] \cup {m.msource}
                              ELSE votesGranted[i]
             IN
             \/ \* 3a: No majority yet — just record
                /\ ~IsQuorum(newGrants, latestConfig[i])
                /\ votesGranted' = [votesGranted EXCEPT ![i] = newGrants]
                /\ Discard(m)
                /\ UNCHANGED <<serverVars, logVars, leaderVars,
                               leaseVars, configVars, preVoteVars, queryVars>>

             \/ \* 3b: Majority — become leader (lines 81-83)
                \* Reference: RaftState.toLeader (lines 448-454)
                \* Reference: RaftNodeImpl.toLeader (lines 1241-1247)
                /\ IsQuorum(newGrants, latestConfig[i])
                /\ state' = [state EXCEPT ![i] = Leader]
                /\ votesGranted' = [votesGranted EXCEPT ![i] = newGrants]
                /\ preVote' = [preVote EXCEPT ![i] = {}]
                \* Initialize leader state (LeaderState constructor)
                \* nextIndex = lastLogOrSnapshotIndex + 1 for all followers
                /\ LET lastIdx == LastLogIndex(i)
                   IN
                   /\ nextIndex' = [nextIndex EXCEPT ![i] =
                       [j \in Server |-> lastIdx + 1]]
                   /\ matchIndex' = [matchIndex EXCEPT ![i] =
                       [j \in Server |-> 0]]
                   \* Append noop entry after leader election (line 1243)
                   \* Reference: RaftNodeImpl.appendEntryAfterLeaderElection (lines 1339-1344)
                   /\ log' = [log EXCEPT ![i] = Append(@, MakeEntry(currentTerm[i]))]
                /\ leaseContact' = [leaseContact EXCEPT ![i] = {}]
                \* Reset query state for new leader
                /\ queryRound' = [queryRound EXCEPT ![i] = 0]
                /\ queryCommitIndex' = [queryCommitIndex EXCEPT ![i] = 0]
                /\ queryAcks' = [queryAcks EXCEPT ![i] = {}]
                /\ queryPending' = [queryPending EXCEPT ![i] = FALSE]
                /\ Discard(m)
                /\ UNCHANGED <<currentTerm, votedFor, commitIndex, configVars>>

----
\* Replication Actions
----

\* Leader i receives a client request and appends a new entry.
\* Reference: ReplicateTask.run (lines 65-107)
\* Precondition: leader, can replicate (line 78)
ClientRequest(i) ==
    /\ state[i] = Leader
    \* canReplicateNewEntry checks (lines 520-549)
    /\ i \in latestConfig[i]
    \* Append a new value entry (line 96)
    /\ log' = [log EXCEPT ![i] = Append(@, MakeEntry(currentTerm[i]))]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars,
                   messages, leaseVars, configVars, preVoteVars, queryVars>>

\* Leader i sends AppendEntries to follower j.
\* Reference: RaftNodeImpl.sendAppendRequest (lines 663-763)
\* Creates an AppendEntriesRequest message with entries from nextIndex[i][j].
AppendEntries(i, j) ==
    /\ state[i] = Leader
    /\ j \in latestConfig[i] \ {i}
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == LogTerm(i, prevIdx)
           \* Send entries from nextIndex to end of log (lines 718-723)
           entries  == IF nextIndex[i][j] <= LastLogIndex(i)
                       THEN SubSeq(log[i], nextIndex[i][j], LastLogIndex(i))
                       ELSE <<>>
       IN Send([mtype        |-> AppendEntriesRequestMsg,
                mterm        |-> currentTerm[i],
                mprevLogTerm |-> prevTerm,
                mprevLogIndex |-> prevIdx,
                mentries     |-> entries,
                mcommitIndex |-> commitIndex[i],
                mqueryRound  |-> queryRound[i],
                msource      |-> i,
                mdest        |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, configVars, preVoteVars, queryVars>>

\* Server i handles an AppendEntriesRequest from the leader.
\* Reference: AppendRequestHandlerTask.innerRun (lines 64-218)
\* Handles: term check, log matching, entry append/truncate, commit update,
\*          config pre-apply/revert (Family 2), query round ACK (Family 5).
HandleAppendRequest(i, m) ==
    /\ m.mtype = AppendEntriesRequestMsg
    /\ m.mdest = i
    /\ \/ \* Case 1: Stale term — reject (line 72)
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype             |-> AppendFailureResponseMsg,
                    mterm             |-> currentTerm[i],
                    mexpectedNextIndex |-> m.mprevLogIndex + 1,
                    msource           |-> i,
                    mdest             |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         leaseVars, configVars, preVoteVars, queryVars>>

       \/ \* Case 2+3: Valid term — process (lines 82-217)
          /\ m.mterm >= currentTerm[i]
          \* Demote if higher term or not already follower (line 82-87)
          \* Reference: RaftState.toFollower (lines 406-415)
          \* KEY (Family 1): setTerm only clears votedFor when newTerm > term (line 438-441)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] =
                IF m.mterm > currentTerm[i] THEN Nil ELSE votedFor[i]]
          \* Clear pre-vote state (toFollower clears preCandidateState, line 409)
          /\ preVote' = [preVote EXCEPT ![i] = {}]
          \* Check log matching (lines 97-126)
          /\ LET logOk == \/ m.mprevLogIndex = 0
                           \/ /\ m.mprevLogIndex > 0
                              /\ m.mprevLogIndex <= LastLogIndex(i)
                              /\ LogTerm(i, m.mprevLogIndex) = m.mprevLogTerm
             IN
             \/ \* Case 2: Log mismatch — reject (lines 107-125)
                /\ ~logOk
                /\ Reply([mtype             |-> AppendFailureResponseMsg,
                          mterm             |-> m.mterm,
                          mexpectedNextIndex |-> m.mprevLogIndex + 1,
                          msource           |-> i,
                          mdest             |-> m.msource], m)
                /\ UNCHANGED <<log, commitIndex, leaderVars, candidateVars,
                               leaseVars, configVars, queryVars>>

             \/ \* Case 3: Log matches — accept, append, update commit (lines 128-217)
                /\ logOk
                /\ LET \* Compute new log (handle conflicts + append)
                       \* Reference: lines 131-185
                       newLog == ComputeNewLog(log[i], m.mprevLogIndex, m.mentries)

                       \* Determine which entries were truncated
                       oldLen == Len(log[i])
                       newLen == Len(newLog)
                       divergeAt == FindDivergence(log[i], m.mprevLogIndex, m.mentries)

                       \* Check config changes (Family 2)
                       \* Reference: revertPreAppliedRaftGroupCmd (lines 243-262)
                       hadPendingConfig == latestConfig[i] /= committedConfig[i]
                       truncatedRange == IF m.mentries /= <<>> /\ divergeAt <= Len(m.mentries)
                                         THEN (m.mprevLogIndex + divergeAt)..oldLen
                                         ELSE {}
                       truncatedHadConfig == hadPendingConfig /\
                           \E idx \in truncatedRange :
                               idx <= oldLen /\ log[i][idx].type = ConfigEntry

                       \* After possible revert, check for new config entries
                       \* Reference: preApplyRaftGroupCmd (lines 221-241)
                       baseConfig == IF truncatedHadConfig
                                     THEN committedConfig[i]
                                     ELSE latestConfig[i]
                       \* New uncommitted config entries
                       newEntryRange == IF m.mentries /= <<>>
                                        THEN {k \in 1..Len(m.mentries) :
                                                m.mentries[k].type = ConfigEntry /\
                                                m.mprevLogIndex + k > m.mcommitIndex}
                                        ELSE {}
                       newLatestConfig ==
                           IF newEntryRange /= {}
                           THEN m.mentries[CHOOSE k \in newEntryRange : TRUE].config
                           ELSE baseConfig

                       \* Update commit index (lines 195-202)
                       lastLogIdx == m.mprevLogIndex + Len(m.mentries)
                       newCommitIndex ==
                           IF m.mcommitIndex > commitIndex[i]
                           THEN Min(m.mcommitIndex, lastLogIdx)
                           ELSE commitIndex[i]

                       \* Check if newly committed entries include config (for commit)
                       newlyCommitted == (commitIndex[i]+1)..newCommitIndex
                       configCommitted == \E idx \in newlyCommitted :
                           idx <= Len(newLog) /\ newLog[idx].type = ConfigEntry
                       newCommittedConfig ==
                           IF configCommitted THEN newLatestConfig
                           ELSE committedConfig[i]

                   IN
                   /\ log' = [log EXCEPT ![i] = newLog]
                   /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIndex]
                   /\ latestConfig' = [latestConfig EXCEPT ![i] = newLatestConfig]
                   /\ committedConfig' = [committedConfig EXCEPT ![i] = newCommittedConfig]
                   \* Send success response (lines 207-209)
                   /\ Reply([mtype        |-> AppendSuccessResponseMsg,
                             mterm        |-> m.mterm,
                             mlastLogIndex |-> lastLogIdx,
                             mqueryRound  |-> m.mqueryRound,
                             msource      |-> i,
                             mdest        |-> m.msource], m)
                   /\ UNCHANGED <<leaderVars, candidateVars, leaseVars, queryVars>>

\* Leader i handles an AppendSuccessResponse from follower j.
\* Reference: AppendSuccessResponseHandlerTask.handleResponse (lines 56-79)
\* KEY (Family 1, MC-1): Term check at line 64 is ASSERT-ONLY.
\* In production (asserts disabled), a stale response with higher term
\* bypasses demotion, unlike AppendFailureResponseHandler which has a runtime check.
HandleAppendSuccessResponse(i, m) ==
    /\ m.mtype = AppendSuccessResponseMsg
    /\ m.mdest = i
    /\ state[i] = Leader              \* line 59
    \* KEY (Family 1): assert-only term check (line 64)
    \* assert resp.term() <= state.term()
    \* In production: this check is SKIPPED (AssertsDisabled = TRUE)
    \* In development: this check prevents processing (AssertsDisabled = FALSE)
    /\ IF AssertsDisabled
       THEN TRUE                       \* No runtime check — proceed regardless
       ELSE m.mterm <= currentTerm[i]  \* Assert check active
    /\ LET follower == m.msource
           followerLastLogIndex == m.mlastLogIndex
       IN
       \* Update matchIndex and nextIndex (lines 82-118)
       /\ IF followerLastLogIndex > matchIndex[i][follower]
          THEN /\ matchIndex' = [matchIndex EXCEPT ![i][follower] = followerLastLogIndex]
               /\ nextIndex' = [nextIndex EXCEPT ![i][follower] = followerLastLogIndex + 1]
          ELSE UNCHANGED <<nextIndex, matchIndex>>
       \* Update lease contact (Family 1, 3)
       \* Reference: FollowerState.appendRequestAckReceived (line 100)
       /\ leaseContact' = [leaseContact EXCEPT ![i] = @ \cup {follower}]
       \* Handle query round ACK (Family 5)
       \* Reference: QueryState.tryAck (lines 105-116)
       /\ IF queryPending[i] /\ m.mqueryRound = queryRound[i]
          THEN queryAcks' = [queryAcks EXCEPT ![i] = @ \cup {follower}]
          ELSE UNCHANGED queryAcks
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, log, commitIndex, candidateVars,
                   configVars, preVoteVars, queryRound, queryCommitIndex, queryPending>>

\* Leader i handles an AppendFailureResponse from follower j.
\* Reference: AppendFailureResponseHandlerTask.handleResponse (lines 55-108)
\* KEY difference from AppendSuccessResponse: has RUNTIME term check (line 63).
HandleAppendFailureResponse(i, m) ==
    /\ m.mtype = AppendFailureResponseMsg
    /\ m.mdest = i
    /\ state[i] = Leader              \* line 58
    /\ \/ \* Sub-case 1: Higher term — demote (line 63-67)
          \* This is a RUNTIME check (if, not assert) — always active
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ preVote' = [preVote EXCEPT ![i] = {}]
          \* Clear query state on demotion
          /\ queryPending' = [queryPending EXCEPT ![i] = FALSE]
          /\ queryAcks' = [queryAcks EXCEPT ![i] = {}]
          /\ Discard(m)
          /\ UNCHANGED <<log, commitIndex, leaderVars, candidateVars,
                         leaseVars, configVars, queryRound, queryCommitIndex>>

       \/ \* Sub-case 2: Valid response — decrement nextIndex (lines 79-107)
          /\ m.mterm <= currentTerm[i]
          /\ LET follower == m.msource
                 curNextIndex == nextIndex[i][follower]
             IN
             \* Only decrement if expectedNextIndex matches (line 91)
             IF m.mexpectedNextIndex = curNextIndex
             THEN /\ nextIndex' = [nextIndex EXCEPT ![i][follower] =
                       Max(1, curNextIndex - 1)]
                  /\ Discard(m)
             ELSE \* Stale response, ignore (line 107)
                  /\ Discard(m)
                  /\ UNCHANGED nextIndex
          /\ UNCHANGED <<serverVars, log, commitIndex, matchIndex, candidateVars,
                         leaseVars, configVars, preVoteVars, queryVars>>

\* Leader i advances commit index based on quorum of matchIndex.
\* Reference: RaftNodeImpl.tryAdvanceCommitIndex (lines 1275-1294)
\* Also handles membership commit (Family 2).
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET config == latestConfig[i]
           \* Leader's own match index is its log length
           \* Reference: findQuorumMatchIndex (lines 1249-1273)
           Agree(idx) == {s \in config :
               IF s = i THEN LastLogIndex(i) >= idx
               ELSE matchIndex[i][s] >= idx}
           \* Find highest index where quorum agrees and entry is from current term
           \* (§5.3, §5.4): only commit entries from current term
           canCommit == {idx \in (commitIndex[i]+1)..LastLogIndex(i) :
                            /\ IsQuorum(Agree(idx), config)
                            /\ log[i][idx].term = currentTerm[i]}
       IN
       /\ canCommit /= {}
       /\ LET newCI == SetMax(canCommit)
              \* Check if newly committed entries include a config entry (Family 2)
              \* Reference: RaftNodeImpl.applyLogEntry for UpdateRaftGroupMembersCmd (lines 823-846)
              configCommitted == \E idx \in (commitIndex[i]+1)..newCI :
                  log[i][idx].type = ConfigEntry
          IN
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCI]
          /\ IF configCommitted
             THEN committedConfig' = [committedConfig EXCEPT ![i] = latestConfig[i]]
             ELSE UNCHANGED committedConfig
    /\ UNCHANGED <<currentTerm, votedFor, state, log, nextIndex, matchIndex,
                   candidateVars, messages, leaseVars, latestConfig,
                   preVoteVars, queryVars>>

----
\* Heartbeat / Lease Actions (Family 1, 3)
----

\* Leader i self-demotion due to majority not responding.
\* Reference: RaftNodeImpl.HeartbeatTask.innerRun (lines 1374-1378)
\* KEY (Family 1): toFollower(state.term()) — SAME TERM, votedFor PRESERVED.
\* This action models the case where majority hasn't ACKed and heartbeat timed out.
LeaderCheckLease(i) ==
    /\ state[i] = Leader
    \* Demotion: toFollower(state.term()) (line 1376)
    \* Reference: RaftState.toFollower (lines 406-415)
    \* setTerm(term) with same term does NOT clear votedFor (line 438-441)
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ preVote' = [preVote EXCEPT ![i] = {}]
    /\ leaseContact' = [leaseContact EXCEPT ![i] = {}]
    \* Clear query state on demotion (RaftNodeImpl:1207-1211)
    /\ queryPending' = [queryPending EXCEPT ![i] = FALSE]
    /\ queryAcks' = [queryAcks EXCEPT ![i] = {}]
    \* votedFor preserved (same term — KEY for Family 1)
    /\ UNCHANGED <<currentTerm, votedFor, logVars, leaderVars, candidateVars,
                   messages, configVars, queryRound, queryCommitIndex>>

----
\* Membership Actions (Family 2)
----

\* Leader i proposes a membership change (remove a member).
\* Reference: MembershipChangeTask.run (lines 83-133)
\*            ReplicateTask.run (lines 65-107)
\*            ReplicateTask.preApplyRaftGroupCmd (lines 124-135)
\* Pre-applies the config change before commit (updates latestConfig).
ProposeMembershipChange(i) ==
    /\ state[i] = Leader
    \* No pending membership change (RaftState.updateGroupMembers:497 assert)
    /\ latestConfig[i] = committedConfig[i]
    \* Must have committed entry in current term (lines 538-546)
    /\ commitIndex[i] > 0
    /\ log[i][commitIndex[i]].term = currentTerm[i]
    \* canReplicateNewEntry checks (lines 520-549)
    /\ i \in latestConfig[i]
    \* Choose a member to remove (non-leader)
    /\ \E member \in latestConfig[i] \ {i} :
       LET newConfig == latestConfig[i] \ {member}
           newEntry  == MakeConfigEntry(currentTerm[i], newConfig)
       IN
       \* Append config entry and pre-apply (ReplicateTask:96, preApplyRaftGroupCmd:127-134)
       /\ log' = [log EXCEPT ![i] = Append(@, newEntry)]
       /\ latestConfig' = [latestConfig EXCEPT ![i] = newConfig]
       /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars,
                      messages, leaseVars, committedConfig, preVoteVars, queryVars>>

----
\* Linearizable Read Actions (Family 5)
----

\* Leader i submits a linearizable read query.
\* Reference: QueryTask.handleLinearizableRead (lines 112-140)
\* Records the current commitIndex and starts a new heartbeat round.
SubmitLinearizableRead(i) ==
    /\ state[i] = Leader
    \* canQueryLinearizable checks (lines 568-590)
    \* Must have committed entry in current term (line 577-583)
    /\ commitIndex[i] > 0
    /\ log[i][commitIndex[i]].term = currentTerm[i]
    \* Record query (QueryState.addQuery lines 80-97)
    /\ IF ~queryPending[i]
       THEN \* First query: increment round (line 93)
            /\ queryRound' = [queryRound EXCEPT ![i] = @ + 1]
            /\ queryCommitIndex' = [queryCommitIndex EXCEPT ![i] = commitIndex[i]]
            /\ queryAcks' = [queryAcks EXCEPT ![i] = {}]
            /\ queryPending' = [queryPending EXCEPT ![i] = TRUE]
       ELSE \* Additional query: update commit index if higher (line 86-87)
            /\ queryCommitIndex' = [queryCommitIndex EXCEPT ![i] = Max(@, commitIndex[i])]
            /\ UNCHANGED <<queryRound, queryAcks, queryPending>>
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   messages, leaseVars, configVars, preVoteVars>>

\* Leader i runs pending queries after majority ack.
\* Reference: RaftNodeImpl.tryRunQueries (lines 1313-1337)
\* Precondition: queries pending, majority ACKed, commitIndex >= queryCommitIndex.
RunQueries(i) ==
    /\ state[i] = Leader
    /\ queryPending[i]
    \* Check majority ACKed (QueryState.isMajorityAcked lines 145-151)
    \* ackCount = acks.size + 1 (leader counts self, line 158)
    /\ IsQuorum(queryAcks[i] \cup {i}, latestConfig[i])
    \* commitIndex must be >= queryCommitIndex (line 146-148)
    /\ commitIndex[i] >= queryCommitIndex[i]
    \* Execute queries and reset state (QueryState.reset line 171-174)
    /\ queryPending' = [queryPending EXCEPT ![i] = FALSE]
    /\ queryAcks' = [queryAcks EXCEPT ![i] = {}]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   messages, leaseVars, configVars, preVoteVars,
                   queryRound, queryCommitIndex>>

----
\* Fault Actions
----

\* Server i crashes and recovers with persistent state.
\* Reference: RaftState constructor with RestoredRaftState (lines 165-189)
\*            RaftNodeImpl.applyRestoredRaftGroupCommands (lines 1089-1128)
\* Persistent: currentTerm, votedFor, log
\* Volatile (reset): state, commitIndex, nextIndex, matchIndex, etc.
Crash(i) ==
    /\ LET recovery == CrashRecoveryState(log[i])
       IN
       \* Volatile state reset
       /\ state' = [state EXCEPT ![i] = Follower]
       /\ commitIndex' = [commitIndex EXCEPT ![i] = recovery.ci]
       /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
       /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
       /\ leaseContact' = [leaseContact EXCEPT ![i] = {}]
       /\ preVote' = [preVote EXCEPT ![i] = {}]
       \* Restore membership from log replay (lines 1089-1128)
       /\ committedConfig' = [committedConfig EXCEPT ![i] = recovery.cc]
       /\ latestConfig' = [latestConfig EXCEPT ![i] = recovery.lc]
       \* Reset query state
       /\ queryRound' = [queryRound EXCEPT ![i] = 0]
       /\ queryCommitIndex' = [queryCommitIndex EXCEPT ![i] = 0]
       /\ queryAcks' = [queryAcks EXCEPT ![i] = {}]
       /\ queryPending' = [queryPending EXCEPT ![i] = FALSE]
    \* Persistent state preserved
    /\ UNCHANGED <<currentTerm, votedFor, log, messages>>

\* A message is lost from the network.
LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, configVars, preVoteVars, queryVars>>

----
\* Next state relation
----

Next ==
    \* Election actions
    \/ \E i \in Server : Timeout(i)
    \/ \E m \in DOMAIN messages : HandlePreVoteRequest(m.mdest, m)
    \/ \E m \in DOMAIN messages : HandlePreVoteResponse(m.mdest, m)
    \/ \E m \in DOMAIN messages : HandleVoteRequest(m.mdest, m)
    \/ \E m \in DOMAIN messages : HandleVoteResponse(m.mdest, m)
    \* Replication actions
    \/ \E i \in Server : ClientRequest(i)
    \/ \E i \in Server, j \in Server : AppendEntries(i, j)
    \/ \E m \in DOMAIN messages : HandleAppendRequest(m.mdest, m)
    \/ \E m \in DOMAIN messages : HandleAppendSuccessResponse(m.mdest, m)
    \/ \E m \in DOMAIN messages : HandleAppendFailureResponse(m.mdest, m)
    \/ \E i \in Server : AdvanceCommitIndex(i)
    \* Heartbeat / Lease (Family 1, 3)
    \/ \E i \in Server : LeaderCheckLease(i)
    \* Membership (Family 2)
    \/ \E i \in Server : ProposeMembershipChange(i)
    \* Linearizable reads (Family 5)
    \/ \E i \in Server : SubmitLinearizableRead(i)
    \/ \E i \in Server : RunQueries(i)
    \* Fault actions
    \/ \E i \in Server : Crash(i)
    \/ \E m \in DOMAIN messages : LoseMessage(m)

Spec == Init /\ [][Next]_vars

----
\* Invariants
----

\* Standard Raft safety: at most one leader per term
\* Reference: Raft paper §5.2
ElectionSafety ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ state[s2] = Leader /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* Standard Raft safety: matching term at same index implies identical prefix
\* Reference: Raft paper §5.3
LogMatching ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(Len(log[s1]), Len(log[s2])) :
            log[s1][idx].term = log[s2][idx].term =>
                \A j \in 1..idx : log[s1][j] = log[s2][j]

\* Standard Raft safety: committed entries present in the current leader's log
\* Reference: Raft paper §5.4
\* Only checked for the leader with the highest term (stale leaders may have
\* divergent uncommitted entries that will be overwritten on demotion).
LeaderCompleteness ==
    \A leader \in Server :
        /\ state[leader] = Leader
        /\ ~\E other \in Server : state[other] = Leader /\ currentTerm[other] > currentTerm[leader]
        =>
        \A s \in Server :
            \A idx \in 1..commitIndex[s] :
                /\ idx <= Len(log[leader])
                /\ log[leader][idx] = log[s][idx]

\* Extension: votedFor never cleared within same term (Family 1)
\* A follower that has voted for a candidate cannot vote for a different one in the same term.
\* Note: two different candidates CAN each self-vote in the same term (split vote) —
\* the invariant only applies to non-candidate voters.
VoteSafety ==
    \A s1, s2 \in Server :
        (currentTerm[s1] = currentTerm[s2] /\
         votedFor[s1] /= Nil /\ votedFor[s2] /= Nil /\
         state[s1] /= Candidate /\ state[s2] /= Candidate)
        => votedFor[s1] = votedFor[s2]

\* Extension: at most one uncommitted config change at a time (Family 2)
\* Reference: RaftState.updateGroupMembers:497 assert
SingleMembershipChange ==
    \A s \in Server :
        Cardinality({idx \in (commitIndex[s]+1)..Len(log[s]) :
                      log[s][idx].type = ConfigEntry}) <= 1

\* Extension: if no uncommitted config entry, configs match (Family 2)
\* Reference: RaftState.resetGroupMembers (lines 538-543)
MembershipRevertConsistency ==
    \A s \in Server :
        (\A idx \in (commitIndex[s]+1)..Len(log[s]) :
            log[s][idx].type /= ConfigEntry)
        => latestConfig[s] = committedConfig[s]

\* Extension: pre-vote doesn't inflate persisted term (Family 4)
\* While pre-voting, the server should be a follower and term is unchanged.
PreVoteNoTermInflation ==
    \A s \in Server :
        preVote[s] /= {} => state[s] = Follower

\* Extension: leader lease contacts only from followers with term <= leader term (Family 1, 3)
\* If violated, leader trusts stale contacts from followers that moved on.
NoPhantomLeaseContact ==
    \A s \in Server :
        state[s] = Leader =>
            \A f \in leaseContact[s] : currentTerm[f] <= currentTerm[s]

\* Structural: commitIndex never exceeds log length
CommitIndexBound ==
    \A s \in Server : commitIndex[s] <= Len(log[s])

\* Structural: leader's nextIndex is within valid range
NextIndexValid ==
    \A s \in Server : state[s] = Leader =>
        \A t \in latestConfig[s] \ {s} :
            /\ nextIndex[s][t] >= 1
            /\ nextIndex[s][t] <= Len(log[s]) + 1

\* Structural: latestConfig is either committedConfig or the config from
\* the last uncommitted config entry
ConfigConsistency ==
    \A s \in Server :
        LET uncommittedCfg == {idx \in (commitIndex[s]+1)..Len(log[s]) :
                                log[s][idx].type = ConfigEntry}
        IN IF uncommittedCfg /= {}
           THEN latestConfig[s] = log[s][SetMax(uncommittedCfg)].config
           ELSE latestConfig[s] = committedConfig[s]

\* Read linearizability (Family 5): when queries are satisfied,
\* the leader's commitIndex >= queryCommitIndex.
\* This is a structural invariant on the query mechanism.
QuerySafety ==
    \A s \in Server :
        (state[s] = Leader /\ queryPending[s]) =>
            queryCommitIndex[s] <= commitIndex[s] \/ ~IsQuorum(queryAcks[s] \cup {s}, latestConfig[s])

====
