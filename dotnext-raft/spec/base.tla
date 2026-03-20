---------------------------- MODULE base ----------------------------
\* TLA+ specification of dotnet/dotNext Raft consensus protocol.
\*
\* Models the implementation faithfully, including dotNext-specific deviations:
\*   1. Conjunctive election restriction (Bug Family 1)
\*      PersistentStateExtensions.cs:29-32 — stricter than Raft paper
\*   2. Sideband config replication (Bug Family 2)
\*      Config is NOT a log entry — replicated via AppendEntries sideband
\*   3. State transition atomicity (Bug Family 3)
\*      Async dispatch modeled via standard TLA+ action interleaving
\*   4. Leader lease timing (Bug Family 4)
\*      Lease renewed on quorum before commit — LeaderState.cs:167-169
\*   5. WAL commit ordering (Bug Family 5)
\*      In-memory vs persisted commit index divergence
\*
\* Source root: src/cluster/DotNext.Net.Cluster/Net/Cluster/Consensus/Raft/
\*
EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs

CONSTANTS Follower,          \* Server states
          Candidate,
          Leader

CONSTANT Nil                 \* Null value (no vote, no-op entry)

CONSTANT Value               \* Set of client request values

CONSTANTS RequestVoteRequest,        \* Message types
          RequestVoteResponse,
          AppendEntriesRequest,
          AppendEntriesResponse

----
\* Variables
----

\* Per-server persistent state (survives crash)
\* Reference: IPersistentState — Term, votedFor persisted atomically
\* WriteAheadLog.NodeState.cs — WriteAsync with WriteThrough
VARIABLE currentTerm         \* [Server -> Nat]
VARIABLE votedFor            \* [Server -> Server \cup {Nil}]
VARIABLE log                 \* [Server -> Seq([term: Nat, value: Value \cup {Nil}])]

\* Per-server volatile state
VARIABLE state               \* [Server -> {Follower, Candidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat]

\* Leader volatile state (reinitialized on election)
\* NOTE: dotNext does NOT have an explicit matchIndex array.
\* Leader uses all-or-nothing quorum counting per heartbeat round.
\* Reference: LeaderState.cs:125-212 (DoHeartbeats)
\* We model matchIndex as derived tracking from successful AE responses
\* for spec clarity; semantics are equivalent for safety properties.
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate state
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension: Sideband configuration (Bug Family 2)
\* Configuration changes are NOT log entries in dotNext. They are
\* replicated as sideband metadata piggybacked on AppendEntries RPCs.
\* Reference: RaftCluster.cs:594 (AppendEntriesAsync accepts IClusterConfiguration)
\*            LeaderState.cs:189-191 (config applied on heartbeat quorum)
\*            RaftCluster.cs:644-667 (follower config processing)
VARIABLE activeConfig        \* [Server -> SUBSET Server]
VARIABLE proposedConfig      \* [Server -> SUBSET Server]
                             \* {} means no proposed config

\* Extension: Leader lease (Bug Family 4)
\* Lease is renewed when quorum of heartbeat responses arrive,
\* BEFORE commit completes. This creates a window where the lease
\* is valid but entries are not yet committed.
\* Reference: LeaderState.cs:167-169 (RenewLease on quorum)
\*            LeaderState.Lease.cs:41-55 (RenewLease timing)
VARIABLE leaseValid          \* [Server -> BOOLEAN]

\* Extension: WAL commit ordering (Bug Family 5)
\* The WAL updates commitIndex in memory before persisting checkpoint.
\* Crash between memory update and checkpoint write can regress commit.
\* Reference: WriteAheadLog.Flusher.cs — checkpoint after page flush
\*            WriteAheadLog.cs:113 — recovery logic
VARIABLE persistedCommitIndex \* [Server -> Nat]

----
\* Variable groups (for UNCHANGED clauses)
----

serverVars    == <<currentTerm, votedFor, state>>
logVars       == <<log, commitIndex>>
leaderVars    == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted>>
configVars    == <<activeConfig, proposedConfig>>
leaseVars     == <<leaseValid>>
walVars       == <<persistedCommitIndex>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          configVars, leaseVars, walVars>>

----
\* Helpers
----

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b

\* Log helpers
LastLogIndex(i) == Len(log[i])
LastLogTerm(i)  == IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term ELSE 0
LogTerm(i, idx) == IF idx > 0 /\ idx <= Len(log[i]) THEN log[i][idx].term ELSE 0

\* Quorum: strict majority
\* Reference: LeaderState.cs:72 — (majority >> 1) + 1
IsQuorum(subset, cfg) == Cardinality(subset) * 2 > Cardinality(cfg)

\* ---- Election restriction check (Bug Family 1) ----
\*
\* PersistentStateExtensions.cs:29-32 — IsUpToDateAsync
\*   var localIndex = auditTrail.LastEntryIndex;
\*   return index >= localIndex
\*       && term >= await auditTrail.GetTermAsync(localIndex, token);
\*
\* The code checks CONJUNCTIVE: index >= localIndex AND term >= localTerm
\* The Raft paper checks DISJUNCTIVE: (term > localTerm) OR (term == localTerm AND index >= localIndex)
\*
\* The conjunctive check is STRICTER: it rejects candidates with higher term
\* but shorter log. E.g., candidate has (term=5, len=2), voter has (term=3, len=5):
\*   Paper: 5 > 3 → ACCEPT     Code: 2 >= 5 → FALSE → REJECT
\* This can prevent valid candidates from being elected (MC-1).

\* dotNext implementation (conjunctive — may block valid elections)
IsUpToDateConjunctive(cIdx, cTerm, vIdx, vTerm) ==
    /\ cIdx >= vIdx
    /\ cTerm >= vTerm

\* Standard Raft paper (disjunctive — reference)
IsUpToDateDisjunctive(cIdx, cTerm, vIdx, vTerm) ==
    \/ cTerm > vTerm
    \/ (cTerm = vTerm /\ cIdx >= vIdx)

\* Default: use the implementation's conjunctive check
\* MC.tla can override with IsUpToDateDisjunctive for comparison
IsUpToDate(cIdx, cTerm, vIdx, vTerm) ==
    IsUpToDateConjunctive(cIdx, cTerm, vIdx, vTerm)

\* ---- Message bag helpers ----
Send(m)    == messages' = messages (+) SetToBag({m})
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
    \* Extension: Sideband config (Family 2)
    /\ activeConfig      = [s \in Server |-> Server]
    /\ proposedConfig    = [s \in Server |-> {}]
    \* Extension: Leader lease (Family 4)
    /\ leaseValid        = [s \in Server |-> FALSE]
    \* Extension: WAL commit ordering (Family 5)
    /\ persistedCommitIndex = [s \in Server |-> 0]

----
\* Timeout: Follower election timeout expires, becomes candidate
\*
\* Reference: FollowerState.cs:24-44 (Track)
\*   Line 27-31: wait for timeout or refresh event
\*   Line 34: timedOut = true
\*   Line 44: MoveToCandidateState()
\*
\* Reference: RaftCluster.cs:1061-1136 (MoveToCandidateState)
\*   Line 1079: check FollowerState.IsExpired && callerState.IsValid
\*   Line 1083: check currentTerm == auditTrail.Term && !IsRefreshRequested
\*   Line 1096: IncrementTermAsync(localMemberId) — atomically set term+vote
\*   Line 1100: StartVoting
\*
\* Bug Family 3: The async dispatch (ThreadPool.UnsafeQueueUserWorkItem)
\* creates a window between timeout and transition. Modeled by standard
\* TLA+ interleaving — other actions can fire between Timeout and
\* any RequestVote action.
----

Timeout(i) ==
    /\ state[i] = Follower
    /\ i \in activeConfig[i]     \* must be in active config
    \* RaftCluster.cs:1096 — IncrementTermAsync: atomically term++ and votedFor=self
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ votedFor'     = [votedFor EXCEPT ![i] = i]
    /\ state'        = [state EXCEPT ![i] = Candidate]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]  \* self-vote
    /\ UNCHANGED <<logVars, leaderVars, messages, configVars, leaseVars, walVars>>

----
\* RequestVote: Candidate sends vote request to a peer
\*
\* Reference: CandidateState.cs:27-75 (VoteAsync)
\*   Line 30-31: lastIndex = auditTrail.LastEntryIndex, lastTerm = GetTermAsync
\*   Line 34: StartVoting — sends to all members in parallel
\*   Line 40-54: creates TaskCompletionPipe, iterates members
----

RequestVote(i, j) ==
    /\ state[i] = Candidate
    /\ j # i
    \* CandidateState.cs:30-31 — reuse lastIndex and lastTerm for all members
    /\ Send([mtype         |-> RequestVoteRequest,
             mterm         |-> currentTerm[i],
             mlastLogTerm  |-> LastLogTerm(i),
             mlastLogIndex |-> LastLogIndex(i),
             msource       |-> i,
             mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, leaseVars, walVars>>

----
\* HandleRequestVote: Server processes incoming vote request
\*
\* Reference: RaftCluster.cs:799-854 (VoteAsync)
\*   Line 801: result.Term = Term (capture local term)
\*   Line 804: PRE-LOCK checks: term, leader stickiness, membership
\*   Line 811: transitionLock.AcquireAsync
\*   Line 814: result.Term = Term (re-read inside lock)
\*   Line 816-832: term comparison branches
\*     816: local > sender → reject
\*     820: local < sender → StepDown(senderTerm), Leader=null
\*     825: local == sender, RefreshableState (follower) → Refresh()
\*     829: local == sender, not follower → reject
\*   Line 834: IsVotedFor(sender) && IsUpToDateAsync (Bug Family 1)
\*   Line 836: UpdateVotedForAsync — persist vote
\*
\* Bug Family 1: IsUpToDate uses CONJUNCTIVE check (line 834)
\* Bug Family 2: membership check on vote requests (line 804)
\*   BUT AppendEntries has NO membership check (MC-3)
----

HandleRequestVote(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ LET
        \* Determine if we should step down (sender has higher term)
        stepDown == m.mterm > currentTerm[i]
        newTerm  == Max(currentTerm[i], m.mterm)
        \* After potential step-down, determine effective votedFor
        \* StepDown resets votedFor for the new term
        effectiveVotedFor == IF stepDown THEN Nil ELSE votedFor[i]
        \* RaftCluster.cs:804 — membership check (sender must be known)
        inConfig == m.msource \in activeConfig[i]
        \* RaftCluster.cs:825-831 — only followers can grant votes at same term
        \* Leaders/Candidates in same term have already voted for themselves
        validState == state[i] = Follower \/ stepDown
        \* RaftCluster.cs:834 — IsVotedFor: no vote yet OR already voted for sender
        voteAvailable == effectiveVotedFor = Nil \/ effectiveVotedFor = m.msource
        \* PersistentStateExtensions.cs:29-32 — IsUpToDateAsync
        \* Bug Family 1: CONJUNCTIVE check
        logOk == IsUpToDate(m.mlastLogIndex, m.mlastLogTerm,
                            LastLogIndex(i), LastLogTerm(i))
        \* Overall grant decision
        grant == m.mterm >= currentTerm[i] /\ inConfig /\ validState
                 /\ voteAvailable /\ logOk
       IN
       \* Update server state
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       /\ state'       = [state EXCEPT ![i] = IF stepDown THEN Follower ELSE state[i]]
       /\ votedFor'    = [votedFor EXCEPT ![i] =
            IF grant THEN m.msource
            ELSE IF stepDown THEN Nil
            ELSE votedFor[i]]
       /\ leaseValid'  = [leaseValid EXCEPT ![i] = IF stepDown THEN FALSE ELSE leaseValid[i]]
       \* Send response
       /\ Reply([mtype        |-> RequestVoteResponse,
                 mterm        |-> newTerm,
                 mvoteGranted |-> grant,
                 msource      |-> i,
                 mdest        |-> m.msource], m)
       /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars, walVars>>

----
\* HandleRequestVoteResponse: Candidate processes vote response
\*
\* Reference: CandidateState.cs:77-139 (EndVoting)
\*   Line 79: votes = 0 (counter starts at 0)
\*   Line 87: destructure (member, term, result)
\*   Line 93-97: higher term → MoveToFollowerState
\*   Line 99-113: count votes (+1 granted, -1 rejected/unavailable)
\*   Line 131: if votes <= 0 → follower (no clear consensus)
\*   Line 137: if votes > 0 → MoveToLeaderState
\*
\* Note: code uses counter (votes += ±1); spec uses set (votesGranted).
\* Equivalent: votes > 0 ⟺ |grants| > N/2 ⟺ IsQuorum(votesGranted).
----

HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ \/ \* Higher term: step down
          \* CandidateState.cs:93-97
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state'       = [state EXCEPT ![i] = Follower]
          /\ votedFor'    = [votedFor EXCEPT ![i] = Nil]
          /\ leaseValid'  = [leaseValid EXCEPT ![i] = FALSE]
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars, walVars>>
       \/ \* Same term, still candidate: count vote
          \* CandidateState.cs:99-113
          /\ m.mterm = currentTerm[i]
          /\ state[i] = Candidate
          /\ IF m.mvoteGranted
             THEN votesGranted' = [votesGranted EXCEPT ![i] = @ \cup {m.msource}]
             ELSE UNCHANGED votesGranted
          /\ UNCHANGED <<serverVars, logVars, leaderVars, configVars, leaseVars, walVars>>
       \/ \* Stale response: discard
          /\ m.mterm < currentTerm[i]
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                        configVars, leaseVars, walVars>>
    /\ Discard(m)

----
\* BecomeLeader: Candidate wins election, transitions to leader
\*
\* Reference: RaftCluster.cs:1139-1166 (MoveToLeaderState)
\*   Line 1150: check CandidateState && callerState.IsValid && Term matches
\*   Line 1152: new LeaderState(this, currentTerm, LeaderLeaseDuration)
\*   Line 1157: UpdateStateAsync(newState)
\*   Line 1158: auditTrail.AppendNoOpEntry — append no-op entry
\*   Line 1161: Leader = newLeader (visible after no-op write barrier)
\*   Line 1164: StartLeading(HeartbeatTimeout, auditTrail, ConfigurationStorage)
\*
\* Reference: LeaderState.cs:240-256 (StartLeading)
\*   Line 244-247: NextIndex = transactionLog.LastEntryIndex + 1L
\*   Line 249-252: initialize all members' replication state
----

BecomeLeader(i) ==
    /\ state[i] = Candidate
    \* CandidateState.cs:131 — votes > 0, equivalent to quorum check
    /\ IsQuorum(votesGranted[i], activeConfig[i])
    \* RaftCluster.cs:1157 — transition to leader
    /\ state' = [state EXCEPT ![i] = Leader]
    \* RaftCluster.cs:1158 — append no-op entry
    /\ LET newLog == Append(log[i], [term |-> currentTerm[i], value |-> Nil])
       IN
       /\ log' = [log EXCEPT ![i] = newLog]
       \* LeaderState.cs:246 — NextIndex = LastEntryIndex + 1
       \* After no-op: LastEntryIndex = Len(newLog), so NextIndex = Len(newLog) + 1
       /\ nextIndex'  = [nextIndex EXCEPT ![i] = [j \in Server |-> Len(newLog) + 1]]
       /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ UNCHANGED <<currentTerm, votedFor, commitIndex, votesGranted, messages,
                   configVars, leaseVars, walVars>>

----
\* ClientRequest: Client appends an entry to the leader's log
\*
\* Reference: PersistentStateExtensions.cs:49-51 (AppendAsync)
\*   Term = state.Term, Content = payload
----

ClientRequest(i, v) ==
    /\ state[i] = Leader
    /\ log' = [log EXCEPT ![i] = Append(@, [term |-> currentTerm[i], value |-> v])]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   configVars, leaseVars, walVars>>

----
\* AppendEntries: Leader sends AppendEntries RPC to a follower
\*
\* Reference: LeaderState.cs:42-75 (ForkHeartbeats)
\*   Line 46-47: commitIndex = LastCommittedEntryIndex, currentIndex = LastEntryIndex
\*   Line 52-68: iterate members, initialize replicators, spawn replication
\*   Line 57: precedingIndex = member.State.PrecedingIndex (= NextIndex - 1)
\*   Line 61: replicator.Initialize(activeConfig, proposedConfig, commitIndex, ...)
\*   Line 72: majority = (majority >> 1) + 1
\*
\* Bug Family 2: config carried as sideband on AppendEntries
\*   ForkHeartbeats reads both active and proposed config
\*   Replicator sends config alongside log entries
----

AppendEntries(i, j) ==
    /\ state[i] = Leader
    /\ j # i
    /\ LET prevLogIdx == nextIndex[i][j] - 1
           prevLogTerm == LogTerm(i, prevLogIdx)
           \* Entries from nextIndex to end of leader's log
           entries == IF nextIndex[i][j] > Len(log[i])
                      THEN <<>>
                      ELSE SubSeq(log[i], nextIndex[i][j], Len(log[i]))
           \* Sideband config (Family 2)
           \* LeaderState.cs:52 — reads both active and proposed config
           \* Sends proposed if exists, else active
           sentConfig == IF proposedConfig[i] # {} THEN proposedConfig[i]
                         ELSE activeConfig[i]
           \* applyConfig = TRUE when leader has no pending proposal
           \* (i.e., leader already applied or never proposed)
           applyConfig == proposedConfig[i] = {}
       IN
       /\ Send([mtype         |-> AppendEntriesRequest,
                mterm         |-> currentTerm[i],
                mprevLogIndex |-> prevLogIdx,
                mprevLogTerm  |-> prevLogTerm,
                mentries      |-> entries,
                mcommitIndex  |-> Min(commitIndex[i], Len(log[i])),
                msource       |-> i,
                mdest         |-> j,
                \* Sideband config (Family 2)
                mconfig       |-> sentConfig,
                mapplyConfig  |-> applyConfig])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, leaseVars, walVars>>

----
\* HandleAppendEntries: Server processes incoming AppendEntries RPC
\*
\* Reference: RaftCluster.cs:594-692 (AppendEntriesAsync)
\*   Line 605: result.Term = Term
\*   Line 606: if (result.Term <= senderTerm) — accept if sender term >= local
\*   Line 608: Timestamp.Refresh(ref lastUpdated)
\*   Line 609: StepDownAsync(senderTerm, consensusReached: true)
\*   Line 610: Leader = TryGetMember(sender)
\*   Line 612: ContainsAsync(prevLogIndex, prevLogTerm) — log match check
\*   Line 636: AppendAndCommitAsync(entries, prevLogIndex+1, skipCommitted=true, commitIndex)
\*   Line 644-667: config processing (sideband)
\*
\* Bug Family 2 (MC-3): NO sender membership check.
\*   Unlike VoteAsync (line 804: members.ContainsKey), AppendEntriesAsync
\*   does not verify the sender is in the members list. A non-member can
\*   send AppendEntries and be accepted as leader.
\*
\* Bug Family 2: config processing (lines 644-667)
\*   fingerprint = (ProposedConfig ?? ActiveConfig).Fingerprint
\*   switch ((config.Fingerprint == fingerprint, applyConfig)):
\*     (true, true)  → ApplyAsync (apply proposed as active)
\*     (false, false) → ProposeAsync (store as proposed)
\*     (false, true)  → Rejected (config mismatch)
----

HandleAppendEntries(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    \* MC-3: NO membership check on sender (unlike HandleRequestVote)
    /\ LET localTerm  == currentTerm[i]
           senderTerm == m.mterm
       IN
       \/ \* Reject: local term > sender term
          \* RaftCluster.cs:606 — result.Term > senderTerm
          /\ localTerm > senderTerm
          /\ Reply([mtype       |-> AppendEntriesResponse,
                    mterm       |-> localTerm,
                    msuccess    |-> FALSE,
                    mmatchIndex |-> 0,
                    msource     |-> i,
                    mdest       |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                        configVars, leaseVars, walVars>>

       \/ \* Accept: sender term >= local term
          \* RaftCluster.cs:606-677
          /\ senderTerm >= localTerm
          \* Step down — RaftCluster.cs:608-609
          \* StepDownAsync(senderTerm, consensusReached: true)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = senderTerm]
          /\ state' = [state EXCEPT ![i] = Follower]
          \* votedFor reset on term change (new term has no vote)
          /\ votedFor' = [votedFor EXCEPT ![i] =
               IF senderTerm > localTerm THEN Nil ELSE votedFor[i]]
          \* Lease invalidated on step down
          /\ leaseValid' = [leaseValid EXCEPT ![i] = FALSE]
          /\ LET
              \* Log match check — RaftCluster.cs:612
              \* PersistentStateExtensions.cs:35-36 (ContainsAsync)
              \*   index <= LastEntryIndex && term == GetTermAsync(index)
              logMatch ==
                  \/ m.mprevLogIndex = 0  \* beginning of log, always matches
                  \/ (m.mprevLogIndex > 0
                      /\ m.mprevLogIndex <= Len(log[i])
                      /\ log[i][m.mprevLogIndex].term = m.mprevLogTerm)
             IN
             \/ \* Log matches — append entries and update commit
                \* RaftCluster.cs:612-675
                /\ logMatch
                /\ LET
                    \* RaftCluster.cs:636 — AppendAndCommitAsync
                    \* skipCommitted=true: don't overwrite committed entries.
                    \* A stale AE may have fewer entries than what's committed.
                    \* Protect committed entries by using Max(prevLogIndex, commitIndex)
                    \* as the truncation point.
                    \* Empty heartbeat (mentries = <<>>) preserves log.
                    safeIdx == Max(m.mprevLogIndex, commitIndex[i])
                    newEntries == SubSeq(m.mentries,
                                    Min(safeIdx - m.mprevLogIndex + 1, Len(m.mentries) + 1),
                                    Len(m.mentries))
                    newLog == IF m.mentries = <<>>
                              THEN log[i]
                              ELSE IF safeIdx >= m.mprevLogIndex + Len(m.mentries)
                                   THEN log[i]  \* all entries already committed
                                   ELSE SubSeq(log[i], 1, safeIdx) \o newEntries
                    newLogLen == Len(newLog)
                    \* Update commit index to leader's, capped by log length
                    newCommitIndex == Max(commitIndex[i],
                                         Min(m.mcommitIndex, newLogLen))
                    \* Config processing (Family 2)
                    \* RaftCluster.cs:644-667
                    localFP == IF proposedConfig[i] # {}
                               THEN proposedConfig[i]
                               ELSE activeConfig[i]
                    fingerMatch == m.mconfig = localFP
                   IN
                   /\ log' = [log EXCEPT ![i] = newLog]
                   /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIndex]
                   /\ Reply([mtype       |-> AppendEntriesResponse,
                             mterm       |-> senderTerm,
                             msuccess    |-> TRUE,
                             mmatchIndex |-> newLogLen,
                             msource     |-> i,
                             mdest       |-> m.msource], m)
                   \* Config sideband processing (Family 2)
                   /\ IF fingerMatch /\ m.mapplyConfig /\ proposedConfig[i] # {}
                      THEN \* (true, true) — apply proposed as active
                           \* RaftCluster.cs:649-656
                           /\ activeConfig' = [activeConfig EXCEPT
                                ![i] = proposedConfig[i]]
                           /\ proposedConfig' = [proposedConfig EXCEPT ![i] = {}]
                      ELSE IF ~fingerMatch /\ ~m.mapplyConfig
                      THEN \* (false, false) — store as proposed
                           \* RaftCluster.cs:658-660
                           /\ proposedConfig' = [proposedConfig EXCEPT
                                ![i] = m.mconfig]
                           /\ UNCHANGED activeConfig
                      ELSE \* (false, true) → rejected or (true, false) → no-op
                           \* RaftCluster.cs:661-666
                           UNCHANGED configVars
                   /\ UNCHANGED walVars

             \/ \* Log mismatch — reject
                \* RaftCluster.cs:612 — ContainsAsync returns false
                /\ ~logMatch
                /\ Reply([mtype       |-> AppendEntriesResponse,
                          mterm       |-> senderTerm,
                          msuccess    |-> FALSE,
                          mmatchIndex |-> 0,
                          msource     |-> i,
                          mdest       |-> m.msource], m)
                /\ UNCHANGED <<log, commitIndex, configVars, walVars>>

          /\ UNCHANGED <<leaderVars, candidateVars>>

----
\* HandleAppendEntriesResponse: Leader processes AppendEntries response
\*
\* Reference: LeaderState.cs:77-110 (ProcessMemberResponse)
\*   Line 84: currentTerm >= result.Term → Successful
\*   Line 86: else → HigherTermDetected
\*
\* Reference: LeaderState.cs:152-176 (DoHeartbeats response loop)
\*   Line 160: MemberResponse.Exception → continue
\*   Line 162-164: HigherTermDetected → MoveToFollowerState(result.Term)
\*   Line 167-169: Successful && quorum → RenewLease, UpdateLeaderStickiness
\*   Line 172: commitQuorum += BitCast<bool,byte>(result.Value)
----

HandleAppendEntriesResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ \/ \* Higher term: step down
          \* LeaderState.cs:86,162-164
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state'       = [state EXCEPT ![i] = Follower]
          /\ votedFor'    = [votedFor EXCEPT ![i] = Nil]
          /\ leaseValid'  = [leaseValid EXCEPT ![i] = FALSE]
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars, walVars>>
       \/ \* Normal response: update replication tracking
          \* LeaderState.cs:84 — currentTerm >= result.Term
          /\ m.mterm = currentTerm[i]
          /\ state[i] = Leader
          /\ IF m.msuccess
             THEN \* Success: advance nextIndex and matchIndex
                  /\ nextIndex'  = [nextIndex EXCEPT
                       ![i][m.msource] = m.mmatchIndex + 1]
                  /\ matchIndex' = [matchIndex EXCEPT
                       ![i][m.msource] = m.mmatchIndex]
             ELSE \* Failure: decrement nextIndex (will retry with earlier entries)
                  /\ nextIndex' = [nextIndex EXCEPT
                       ![i][m.msource] = Max(1, nextIndex[i][m.msource] - 1)]
                  /\ UNCHANGED matchIndex
          /\ UNCHANGED <<serverVars, logVars, candidateVars, configVars,
                        leaseVars, walVars>>
       \/ \* Stale response (lower term): discard
          /\ m.mterm < currentTerm[i]
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                        configVars, leaseVars, walVars>>
    /\ Discard(m)

----
\* AdvanceCommitIndex: Leader commits entries replicated to a quorum
\*
\* Reference: LeaderState.cs:178-183 (DoHeartbeats commit section)
\*   Line 178: if (commitQuorum >= majority)
\*   Line 181: auditTrail.CommitAsync(currentIndex, Token)
\*
\* Standard Raft: only commit entries from the leader's current term
\* (prevents committing entries from previous terms without current-term entry).
----

AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ \E newCommit \in (commitIndex[i]+1)..Len(log[i]):
        \* Entry must be from current term (standard Raft safety requirement)
        /\ log[i][newCommit].term = currentTerm[i]
        \* Quorum of servers (including self) have replicated up to this index
        /\ LET agreeServers == {i} \cup
                {j \in Server \ {i} : matchIndex[i][j] >= newCommit}
           IN IsQuorum(agreeServers, activeConfig[i])
        /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommit]
    /\ UNCHANGED <<currentTerm, votedFor, state, log, leaderVars, candidateVars,
                   messages, configVars, leaseVars, walVars>>

----
\* ======== Extension: Sideband Configuration (Bug Family 2) ========
----

----
\* ProposeConfig: Leader proposes a new cluster configuration
\*
\* Reference: RaftCluster.Membership.cs:251-309 (AddMemberAsync)
\*   Line 264-279: catch-up phase with replication rounds
\*   Line 281-290: propose, replicate, apply
\*
\* Reference: RaftCluster.Membership.cs:333-374 (RemoveMemberAsync)
\*   Line 347-354: wait, remove, replicate, commit
\*
\* The proposed config will be replicated as sideband on AppendEntries.
----

ProposeConfig(i, newConfig) ==
    /\ state[i] = Leader
    /\ proposedConfig[i] = {}    \* no existing proposal
    /\ newConfig # activeConfig[i]  \* must differ from current
    /\ newConfig # {}            \* must have at least one member
    /\ proposedConfig' = [proposedConfig EXCEPT ![i] = newConfig]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   activeConfig, leaseVars, walVars>>

----
\* ApplyConfig: Leader applies proposed config on heartbeat quorum
\*
\* Reference: LeaderState.cs:189-192 (DoHeartbeats)
\*   if (quorum >= majority)
\*       await configurationStorage.ApplyAsync(Token);
\*
\* CRITICAL (MC-2): Config is applied when quorum of heartbeat responses
\* arrive, NOT when the config change is committed to the log.
\* The config is not even a log entry — it's sideband state.
\* This means config can diverge from the committed log state.
----

ApplyConfig(i) ==
    /\ state[i] = Leader
    /\ proposedConfig[i] # {}
    \* Config applied on heartbeat quorum (not log commit!)
    \* LeaderState.cs:189 — if (quorum >= majority)
    /\ LET contacted == {i} \cup
            {j \in Server \ {i} : matchIndex[i][j] > 0}
       IN IsQuorum(contacted, activeConfig[i])
    /\ activeConfig'    = [activeConfig EXCEPT ![i] = proposedConfig[i]]
    /\ proposedConfig'  = [proposedConfig EXCEPT ![i] = {}]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   leaseVars, walVars>>

----
\* ======== Extension: Leader Lease (Bug Family 4) ========
----

----
\* RenewLease: Leader renews lease when quorum responds
\*
\* Reference: LeaderState.cs:167-169 (DoHeartbeats)
\*   case MemberResponse.Successful when ++quorum == majority:
\*       RenewLease(startTime.Elapsed);
\*       UpdateLeaderStickiness();
\*
\* Reference: LeaderState.Lease.cs:41-55 (RenewLease)
\*   elapsed = maxLease - elapsed
\*   currentLease.TryRenew(elapsed)
\*
\* CRITICAL (MC-4): Lease is renewed when quorum responds,
\* BEFORE AdvanceCommitIndex runs. This means the lease can be
\* valid while entries are not yet committed — potential stale reads.
----

RenewLease(i) ==
    /\ state[i] = Leader
    \* Quorum has responded (same as heartbeat quorum)
    /\ LET contacted == {i} \cup
            {j \in Server \ {i} : matchIndex[i][j] > 0}
       IN IsQuorum(contacted, activeConfig[i])
    /\ leaseValid' = [leaseValid EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   configVars, walVars>>

----
\* LeaseExpire: Leader lease times out (non-deterministic)
\*
\* Reference: LeaderState.Lease.cs:7-32 (Lease class)
\*   Extends CancellationTokenSource with CancelAfter(leaseTime)
\*   Lease expires when timer fires
----

LeaseExpire(i) ==
    /\ leaseValid[i] = TRUE
    /\ leaseValid' = [leaseValid EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   configVars, walVars>>

----
\* ======== Extension: WAL Commit Ordering (Bug Family 5) ========
----

----
\* PersistCommitIndex: Flush in-memory commitIndex to persistent checkpoint
\*
\* Reference: WriteAheadLog.Flusher.cs — checkpoint written AFTER page flush
\*   Pages flushed first, then checkpoint updated
\*   In-memory commitIndex may be ahead of persisted checkpoint
----

PersistCommitIndex(i) ==
    /\ persistedCommitIndex[i] < commitIndex[i]
    /\ persistedCommitIndex' = [persistedCommitIndex EXCEPT ![i] = commitIndex[i]]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   configVars, leaseVars>>

----
\* ======== Fault Actions ========
----

----
\* Crash: Server crashes, loses volatile state
\*
\* Persistent (survives): currentTerm, votedFor, log,
\*   activeConfig, proposedConfig, persistedCommitIndex
\* Volatile (lost): state → Follower, commitIndex → persistedCommitIndex,
\*   leaseValid → FALSE, nextIndex/matchIndex → default, votesGranted → {}
\*
\* Bug Family 5: commitIndex regresses to persistedCommitIndex on crash.
\* If persistedCommitIndex < commitIndex at crash time, the server
\* loses committed entries visibility until they are re-committed.
----

Crash(i) ==
    /\ state' = [state EXCEPT ![i] = Follower]
    \* Family 5: commitIndex regresses to persisted checkpoint
    /\ commitIndex' = [commitIndex EXCEPT ![i] = persistedCommitIndex[i]]
    /\ leaseValid'  = [leaseValid EXCEPT ![i] = FALSE]
    /\ nextIndex'   = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'  = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    \* Persistent state survives crash
    /\ UNCHANGED <<currentTerm, votedFor, log, messages,
                   activeConfig, proposedConfig, persistedCommitIndex>>

----
\* LoseMessage: Network drops a message
----

LoseMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, leaseVars, walVars>>

----
\* Next state relation and specification
----

Next ==
    \/ \E i \in Server :
        \/ Timeout(i)
        \/ BecomeLeader(i)
        \/ AdvanceCommitIndex(i)
        \/ ApplyConfig(i)
        \/ RenewLease(i)
        \/ LeaseExpire(i)
        \/ PersistCommitIndex(i)
        \/ Crash(i)
        \/ \E j \in Server : RequestVote(i, j)
        \/ \E j \in Server : AppendEntries(i, j)
        \/ \E v \in Value : ClientRequest(i, v)
        \/ \E newConfig \in (SUBSET Server \ {{}}) : ProposeConfig(i, newConfig)
    \/ \E m \in BagToSet(messages) :
        \/ HandleRequestVote(m.mdest, m)
        \/ HandleRequestVoteResponse(m.mdest, m)
        \/ HandleAppendEntries(m.mdest, m)
        \/ HandleAppendEntriesResponse(m.mdest, m)
        \/ LoseMessage(m)

Spec == Init /\ [][Next]_vars

----
\* Invariants
----

\* ---- Standard Protocol Invariants ----

\* ElectionSafety: at most one leader per term
ElectionSafety ==
    \A i, j \in Server :
        (state[i] = Leader /\ state[j] = Leader /\ currentTerm[i] = currentTerm[j])
        => i = j

\* LogMatching: if two logs have the same term at the same index,
\* the logs are identical up through that index
LogMatching ==
    \A i, j \in Server :
        \A idx \in 1..Min(Len(log[i]), Len(log[j])) :
            log[i][idx].term = log[j][idx].term =>
                \A k \in 1..idx : log[i][k] = log[j][k]

\* StateMachineSafety: committed entries agree across all servers
StateMachineSafety ==
    \A i, j \in Server :
        \A idx \in 1..Min(commitIndex[i], commitIndex[j]) :
            log[i][idx] = log[j][idx]

\* ---- Structural Invariants ----

\* CommitIndex never exceeds log length
CommitIndexBound ==
    \A i \in Server : commitIndex[i] <= Len(log[i])

\* Persisted commit index never exceeds in-memory commit index
PersistedCommitBound ==
    \A i \in Server : persistedCommitIndex[i] <= commitIndex[i]

\* matchIndex bounded by leader's log length
MatchIndexBound ==
    \A i \in Server :
        state[i] = Leader =>
            \A j \in Server : matchIndex[i][j] <= Len(log[i])

\* ---- Extension Invariants (Bug Family targets) ----

\* Family 2: Config commit consistency
\* If leader applied a config (no pending proposal), a quorum should agree
ConfigCommitConsistency ==
    \A i \in Server :
        state[i] = Leader /\ proposedConfig[i] = {} =>
            LET agreeServers == {j \in Server : activeConfig[j] = activeConfig[i]}
            IN IsQuorum(agreeServers, activeConfig[i])

\* Family 4: No stale leader with valid lease
\* If lease is valid on server i, then:
\*   1. i must be a leader
\*   2. no other server can be leader with a higher term
NoStaleLeaderWithLease ==
    \A i \in Server :
        leaseValid[i] =>
            /\ state[i] = Leader
            /\ ~\E j \in Server \ {i} :
                state[j] = Leader /\ currentTerm[j] > currentTerm[i]

\* Family 5: Commit monotonicity (crash recovery)
\* persistedCommitIndex is always <= commitIndex
CommitMonotonicity == PersistedCommitBound

\* ---- Temporal Properties ----

\* Family 1: Election liveness — a leader is eventually elected (under fairness)
\* Requires WF_vars(Next) or SF_vars(Next) to be meaningful
ElectionLiveness == <>(\E i \in Server : state[i] = Leader)

====
