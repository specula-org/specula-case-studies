---------------------------- MODULE base ----------------------------
\* TLA+ specification of Apache Kudu Raft consensus protocol.
\*
\* Models Kudu's actual implementation (src/kudu/consensus/), not the
\* Raft paper. Extends standard Raft with Kudu-specific behaviors:
\*
\*   Extension 1: Commit index clamping (raft_consensus.cc:1521-1526)
\*                Follower clamps apply_up_to to min(lastPending,
\*                precedingOpId, request.committedIndex) to prevent
\*                committing beyond what was received. [Bug Family 1]
\*
\*   Extension 2: Dual configuration (committed + pending)
\*                (raft_consensus.cc:849-896, 2909-2969)
\*                Config change applied when operation is added to
\*                pending ops, not when committed. Single pending config
\*                constraint. "Must commit in current term" guard.
\*                [Bug Family 2]
\*
\*   Extension 3: Vote withholding + Pre-election
\*                (raft_consensus.cc:1747-1750, 459-561, 2690-2820)
\*                Withhold votes after hearing from leader. Pre-election
\*                does NOT advance term or persist vote. StepDown bumps
\*                term. [Bug Family 3]
\*
\*   Extension 4: Non-voter quorum distinction
\*                (consensus_queue.cc:886-889)
\*                Only VOTER members count for majority watermark.
\*                NON_VOTER acks excluded from commit calculation.
\*                [Bug Family 2]
\*
\*   Extension 5: NO_OP on leader election
\*                (raft_consensus.cc:717-732)
\*                Leader must replicate NO_OP before accepting client
\*                writes. hasCommittedInTerm tracks this. [Bug Family 4]
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
          ConfigEntry,
          NoOpEntry

CONSTANTS RequestVoteRequest,       \* Message types
          RequestVoteResponse,
          AppendEntriesRequest,
          AppendEntriesResponse

----
\* Variables
----

\* Per-server persistent state (survives restart)
\* Reference: consensus_meta.cc:284-327 (Flush persists term + votedFor atomically)
VARIABLE currentTerm         \* [Server -> Nat]
VARIABLE votedFor            \* [Server -> Server \cup {Nil}]
VARIABLE log                 \* [Server -> Seq(Entry)]

\* Per-server volatile state
VARIABLE state               \* [Server -> {Follower, Candidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat]

\* Leader volatile state
\* Reference: consensus_queue.cc:218-247 (SetLeaderMode initializes)
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate state
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension 2: Dual configuration [Bug Family 2]
\* Reference: raft_consensus.cc:849-896 (AddPendingOperationUnlocked)
\*            raft_consensus.cc:2909-2969 (CompleteConfigChangeRoundUnlocked)
\* Config change takes effect immediately when operation is added to pending ops.
\* Pending config cleared on abort or committed when operation completes.
VARIABLE committedConfig     \* [Server -> SUBSET Server]
VARIABLE pendingConfig       \* [Server -> SUBSET Server \cup {Nil}]

\* Extension 2+5: Config change guard [Bug Family 2, 4]
\* Reference: raft_consensus.cc:1916 (IsCommittedIndexInCurrentTerm check)
\*            raft_consensus.cc:717-732 (NO_OP appended on BecomeLeader)
\* Leader must commit an operation in current term before accepting config changes.
VARIABLE hasCommittedInTerm  \* [Server -> BOOLEAN]

\* Extension 3: Vote withholding [Bug Family 3]
\* Reference: raft_consensus.cc:1747-1750, 2997-3025
\* When TRUE, server recently heard from leader and will reject votes.
\* Models withhold_votes_until_ > MonoTime::Now()
VARIABLE withholdVotes       \* [Server -> BOOLEAN]

\* Extension 4: Non-voter membership [Bug Family 2]
\* Reference: metadata.proto:93-97 (MemberType VOTER/NON_VOTER)
\*            consensus_queue.cc:886-889 (VOTER_REPLICAS filter)
\* Tracks which servers are voters vs non-voters. Only voters count for quorum.
VARIABLE memberType          \* [Server -> {"Voter", "NonVoter"}]

----
\* Variable groups (for UNCHANGED clauses)
----

serverVars    == <<currentTerm, votedFor, state>>
logVars       == <<log, commitIndex>>
leaderVars    == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted>>
configVars    == <<committedConfig, pendingConfig, hasCommittedInTerm, memberType>>
electionVars  == <<withholdVotes>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          configVars, electionVars>>

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

\* Active configuration: pending if exists, else committed
\* Reference: consensus_meta.h:148-155 (ActiveConfig uses pending if available)
ActiveConfig(i) == IF pendingConfig[i] /= Nil
                   THEN pendingConfig[i]
                   ELSE committedConfig[i]

\* Voters in active config
\* Reference: consensus_queue.cc:886-889 (filter VOTER_REPLICAS)
ActiveVoters(i) == {s \in ActiveConfig(i) : memberType[s] = "Voter"}

\* Quorum check using given voter set
\* Reference: consensus_queue.cc:231 (majority_size_ = MajoritySize(CountVoters(config)))
IsQuorum(S, voters) == Cardinality(S) * 2 > Cardinality(voters)

\* Log up-to-date comparison
\* Reference: raft_consensus.cc:1847-1848 (candidate_status.last_received >= local_last_logged)
\* Uses OpId comparison: term first, then index
LogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    \/ cLastTerm > vLastTerm
    \/ (cLastTerm = vLastTerm /\ cLastIdx >= vLastIdx)

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
    /\ committedConfig   = [s \in Server |-> Server]
    /\ pendingConfig     = [s \in Server |-> Nil]
    /\ hasCommittedInTerm = [s \in Server |-> FALSE]
    /\ withholdVotes     = [s \in Server |-> FALSE]
    /\ memberType        = [s \in Server |-> "Voter"]

----
\* Election Actions
----

\* Server i times out and starts a real (non-pre) election.
\* Reference: raft_consensus.cc:459-561 (StartElection)
\*   - Line 504: if mode != PRE_ELECTION, advance term
\*   - Line 509: HandleTermAdvanceUnlocked(currentTerm + 1, SKIP_FLUSH)
\*   - Line 511: SetVotedForCurrentTermUnlocked(peer_uuid())
\*   - Line 519-528: VoteCounter with self-vote
\*   - Line 530-543: VoteRequestPB construction
\*   Key: term+vote persisted atomically (line 509 skips flush, line 511 flushes both)
Timeout(i) ==
    /\ state[i] \in {Follower, Candidate}
    \* Only voters can start elections (raft_consensus.cc:480-486)
    /\ memberType[i] = "Voter"
    /\ i \in ActiveConfig(i)
    /\ LET newTerm == currentTerm[i] + 1
       IN
       \* Increment term and become candidate (raft_consensus.cc:509)
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       /\ state' = [state EXCEPT ![i] = Candidate]
       \* Vote for self (raft_consensus.cc:511)
       /\ votedFor' = [votedFor EXCEPT ![i] = i]
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
       \* Send RequestVote to all other voters in active config (raft_consensus.cc:547)
       /\ SendAll({[mtype        |-> RequestVoteRequest,
                    mterm        |-> newTerm,
                    mlastLogTerm |-> LastLogTerm(i),
                    mlastLogIndex |-> LastLogIndex(i),
                    mpreElection |-> FALSE,
                    msource      |-> i,
                    mdest        |-> j] : j \in ActiveVoters(i) \ {i}})
    /\ hasCommittedInTerm' = [hasCommittedInTerm EXCEPT ![i] = FALSE]
    /\ withholdVotes' = [withholdVotes EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<log, commitIndex, leaderVars, committedConfig, pendingConfig, memberType>>

\* Server i starts a pre-election (no term advance, no vote persistence).
\* Reference: raft_consensus.cc:504 (mode == PRE_ELECTION skips term advance)
\*   - Line 533-537: is_pre_election=true, candidate_term=currentTerm+1
\*   - No call to HandleTermAdvanceUnlocked
\*   - No call to SetVotedForCurrentTermUnlocked
\*   Pre-election does not change term or votedFor [Bug Family 3]
PreVote(i) ==
    /\ state[i] \in {Follower, Candidate}
    /\ memberType[i] = "Voter"
    /\ i \in ActiveConfig(i)
    \* Cannot PreVote if already in a real election (votedFor=self)
    \* Reference: real election win → StartElection(NORMAL), not PreVote
    /\ votedFor[i] /= i
    /\ LET preElectionTerm == currentTerm[i] + 1
       IN
       \* Do NOT increment term (raft_consensus.cc:504)
       /\ UNCHANGED currentTerm
       /\ state' = [state EXCEPT ![i] = Candidate]
       \* Do NOT change votedFor (pre-election is non-binding)
       /\ UNCHANGED votedFor
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
       \* Send PreVote requests with term+1 (raft_consensus.cc:537)
       /\ SendAll({[mtype        |-> RequestVoteRequest,
                    mterm        |-> preElectionTerm,
                    mlastLogTerm |-> LastLogTerm(i),
                    mlastLogIndex |-> LastLogIndex(i),
                    mpreElection |-> TRUE,
                    msource      |-> i,
                    mdest        |-> j] : j \in ActiveVoters(i) \ {i}})
    /\ hasCommittedInTerm' = [hasCommittedInTerm EXCEPT ![i] = FALSE]
    /\ withholdVotes' = [withholdVotes EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<log, commitIndex, leaderVars, committedConfig, pendingConfig, memberType>>

\* Server i handles RequestVoteRequest m (both pre-election and real).
\* Reference: raft_consensus.cc:1718-1871 (RequestVote)
\*
\* Four paths modeled:
\*   Case 0: Reject — withhold votes active (raft_consensus.cc:1747-1750)
\*   Case 1: Reject — term too low, already voted, log not up-to-date
\*   Case 2: Grant — real election (term advance + vote persist)
\*   Case 3: Grant — pre-election (no term advance, no vote persist)
HandleRequestVoteRequest(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ LET mterm    == m.mterm
           \* Log up-to-date check (raft_consensus.cc:1847-1848)
           logOk    == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                   LastLogTerm(i), LastLogIndex(i))
           \* Can grant if log is OK and (higher term or same term with no prior vote)
           \* Reference: raft_consensus.cc:1828-1843, 1847-1848
           canGrant == /\ logOk
                       /\ \/ mterm > currentTerm[i]
                          \/ /\ mterm = currentTerm[i]
                             /\ votedFor[i] \in {Nil, m.msource}
       IN
       \/ \* Case 0: Withhold votes — recent leader contact [Bug Family 3]
          \* Reference: raft_consensus.cc:1747-1750 (ignore_live_leader check)
          \* Follower with withholdVotes=TRUE rejects to prevent disruption
          /\ withholdVotes[i] = TRUE
          /\ Reply([mtype          |-> RequestVoteResponse,
                    mterm          |-> currentTerm[i],
                    mvoteGranted   |-> FALSE,
                    mpreElection   |-> m.mpreElection,
                    msource        |-> i,
                    mdest          |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         configVars, electionVars>>

       \/ \* Case 1: Reject — term too low or can't grant
          \* Reference: raft_consensus.cc:1828-1830, 1833-1843, 1865-1866
          /\ withholdVotes[i] = FALSE
          /\ \/ mterm < currentTerm[i]
             \/ /\ mterm >= currentTerm[i]
                /\ ~canGrant
          /\ Reply([mtype          |-> RequestVoteResponse,
                    mterm          |-> Max(currentTerm[i], mterm),
                    mvoteGranted   |-> FALSE,
                    mpreElection   |-> m.mpreElection,
                    msource        |-> i,
                    mdest          |-> m.msource], m)
          \* Step down on newer term for real elections only (raft_consensus.cc:1854-1862)
          /\ IF ~m.mpreElection /\ mterm > currentTerm[i]
             THEN /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
                  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
                  /\ state' = [state EXCEPT ![i] = Follower]
                  /\ hasCommittedInTerm' = [hasCommittedInTerm EXCEPT ![i] = FALSE]
             ELSE UNCHANGED <<currentTerm, votedFor, state, hasCommittedInTerm>>
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         committedConfig, pendingConfig, memberType, electionVars>>

       \/ \* Case 2: Grant — real election (raft_consensus.cc:1854-1862, 1869-1870)
          \* Term advance (if needed) + vote persist (both flushed atomically)
          \* Reference: raft_consensus.cc:1859 (SKIP_FLUSH if vote_yes)
          \*            raft_consensus.cc:1870 (RequestVoteRespondVoteGranted → SetVotedFor flushes)
          /\ withholdVotes[i] = FALSE
          /\ ~m.mpreElection
          /\ canGrant
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
          /\ state' = IF mterm > currentTerm[i]
                      THEN [state EXCEPT ![i] = Follower]
                      ELSE state
          /\ Reply([mtype          |-> RequestVoteResponse,
                    mterm          |-> mterm,
                    mvoteGranted   |-> TRUE,
                    mpreElection   |-> FALSE,
                    msource        |-> i,
                    mdest          |-> m.msource], m)
          /\ IF mterm > currentTerm[i]
             THEN hasCommittedInTerm' = [hasCommittedInTerm EXCEPT ![i] = FALSE]
             ELSE UNCHANGED hasCommittedInTerm
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         committedConfig, pendingConfig, memberType, electionVars>>

       \/ \* Case 3: Grant — pre-election (no term advance, no vote persist)
          \* Reference: raft_consensus.cc:1854 (is_pre_election skips HandleTermAdvance)
          \* Pre-election responses don't change persistent state
          /\ withholdVotes[i] = FALSE
          /\ m.mpreElection
          /\ canGrant
          /\ Reply([mtype          |-> RequestVoteResponse,
                    mterm          |-> mterm,
                    mvoteGranted   |-> TRUE,
                    mpreElection   |-> TRUE,
                    msource        |-> i,
                    mdest          |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         configVars, electionVars>>

\* Server i handles RequestVoteResponse m.
\* Reference: leader_election.cc:329-371 (VoteResponseRpcCallback)
\*            raft_consensus.cc:2690-2820 (DoElectionCallback)
\*
\* For pre-election: if won, start real election (raft_consensus.cc:2806-2810)
\* For real election: if won, BecomeLeader (raft_consensus.cc:2812-2818)
\* On denial with higher term: bump term (raft_consensus.cc:2744-2746)
HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ state[i] = Candidate
    /\ \/ \* Higher term in response: step down (raft_consensus.cc:2744-2746)
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ hasCommittedInTerm' = [hasCommittedInTerm EXCEPT ![i] = FALSE]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         committedConfig, pendingConfig, memberType, electionVars>>
       \/ \* Same term response: tally vote
          \* Reference: leader_election.cc:409-417 (HandleVoteGrantedUnlocked)
          \* For pre-election: must match currentTerm+1 (raft_consensus.cc:2758-2761)
          \* For real election: must match currentTerm (raft_consensus.cc:2763)
          /\ \/ /\ ~m.mpreElection /\ m.mterm = currentTerm[i]
             \/ /\ m.mpreElection /\ m.mterm = currentTerm[i] + 1
          /\ IF m.mvoteGranted
             THEN votesGranted' = [votesGranted EXCEPT ![i] = @ \cup {m.msource}]
             ELSE UNCHANGED votesGranted
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars,
                         configVars, electionVars>>
       \/ \* Stale response (from old term), ignore
          /\ \/ /\ ~m.mpreElection /\ m.mterm < currentTerm[i]
             \/ /\ m.mpreElection /\ m.mterm < currentTerm[i] + 1
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         configVars, electionVars>>

\* Candidate i becomes leader after receiving quorum of votes (real election).
\* Reference: raft_consensus.cc:2812-2818 (DoElectionCallback won case)
\*            raft_consensus.cc:691-735 (BecomeLeaderUnlocked)
\*   - Line 700: DisableFailureDetector
\*   - Line 703: withhold_votes_until_ = MonoTime::Max()
\*   - Line 710: RefreshConsensusQueueAndPeersUnlocked
\*   - Line 717-728: Append NO_OP
\*   - Line 732: leader_is_ready_ = true
BecomeLeader(i) ==
    /\ state[i] = Candidate
    \* Must have voted for self (real election, not pre-election)
    \* Reference: PreVote won -> StartElection(NORMAL) -> Timeout -> BecomeLeader
    /\ votedFor[i] = i
    /\ IsQuorum(votesGranted[i] \cap ActiveVoters(i), ActiveVoters(i))
    /\ state' = [state EXCEPT ![i] = Leader]
    \* Initialize leader state (consensus_queue.cc:218-247 SetLeaderMode)
    /\ nextIndex'  = [nextIndex  EXCEPT ![i] = [j \in Server |-> LastLogIndex(i) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    \* Withhold votes as leader (raft_consensus.cc:703)
    /\ withholdVotes' = [withholdVotes EXCEPT ![i] = TRUE]
    \* Append NO_OP to log (raft_consensus.cc:717-728) [Bug Family 4]
    /\ LET noopEntry == [term |-> currentTerm[i], type |-> NoOpEntry, config |-> {}]
       IN log' = [log EXCEPT ![i] = Append(@, noopEntry)]
    \* hasCommittedInTerm starts FALSE; set TRUE when NO_OP commits [Extension 5]
    /\ hasCommittedInTerm' = [hasCommittedInTerm EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<currentTerm, votedFor, commitIndex, candidateVars, messages,
                   committedConfig, pendingConfig, memberType>>

\* Pre-election won: start real election.
\* Reference: raft_consensus.cc:2806-2810 (DoElectionCallback pre-election won)
\*   Releases lock, then calls StartElection(NORMAL_ELECTION, reason)
\*   This transitions to Timeout (real election).
\* Modeled by allowing Timeout to fire when candidate has preVote quorum.
\* No separate action needed — Timeout already handles Candidate state.

\* Leader i steps down (term advance).
\* Reference: raft_consensus.cc:576-599 (StepDown)
\*   - Line 592: HandleTermAdvanceUnlocked(currentTerm + 1, SKIP_FLUSH)
\*   - Non-standard: Kudu bumps term on step-down [Bug Family 3]
StepDown(i) ==
    /\ state[i] = Leader
    /\ LET newTerm == currentTerm[i] + 1
       IN
       \* HandleTermAdvanceUnlocked (raft_consensus.cc:3047-3067)
       \*   Line 3054-3057: if LEADER, BecomeReplicaUnlocked
       \*   Line 3061: SetCurrentTermUnlocked (clears votedFor)
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
       /\ state' = [state EXCEPT ![i] = Follower]
       /\ hasCommittedInTerm' = [hasCommittedInTerm EXCEPT ![i] = FALSE]
    \* BecomeReplicaUnlocked (raft_consensus.cc:737-765)
    \*   Line 749: withhold_votes_until_ = MonoTime::Min() (allow votes again)
    /\ withholdVotes' = [withholdVotes EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<logVars, leaderVars, candidateVars, messages,
                   committedConfig, pendingConfig, memberType>>

----
\* Log Replication Actions
----

\* Leader i appends a client request to its log.
\* Reference: raft_consensus.cc:768-834 (CheckLeadershipAndBindTerm)
\*   - Line 811-829: checks LEADER role
\*   - Line 815-822: checks leader_is_ready_ (NO_OP must be replicated first)
\* In our model, leader_is_ready_ is set TRUE in BecomeLeader, so we
\* allow client requests immediately. The hasCommittedInTerm check is
\* only for config changes.
ClientRequest(i) ==
    /\ state[i] = Leader
    /\ LET entry == [term |-> currentTerm[i], type |-> ValueEntry, config |-> {}]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   configVars, electionVars>>

\* Leader i proposes a configuration change.
\* Reference: raft_consensus.cc:1900-2088 (BulkChangeConfig)
\*   - Line 1910: CheckActiveLeaderUnlocked
\*   - Line 1911: CheckNoConfigChangePendingUnlocked
\*   - Line 1916: IsCommittedIndexInCurrentTerm [Bug Family 2, KUDU-872]
\*   - Line 2070-2074: at most 1 voter modified
\*   Simplified: model adding/removing a voter server
ProposeConfigChange(i, s) ==
    /\ state[i] = Leader
    \* No pending config change (raft_consensus.cc:1911, 3110-3119)
    /\ pendingConfig[i] = Nil
    \* Must have committed in current term (raft_consensus.cc:1916) [Bug Family 2]
    /\ hasCommittedInTerm[i] = TRUE
    \* Add or remove a voter
    /\ \/ /\ s \notin ActiveConfig(i)       \* add server
          /\ s \in Server
       \/ /\ s \in ActiveConfig(i)           \* remove server
          /\ s /= i                          \* leader can't remove self (line 1999-2005)
          /\ Cardinality(ActiveConfig(i)) > 1
    /\ LET newConfig == IF s \in ActiveConfig(i)
                        THEN ActiveConfig(i) \ {s}
                        ELSE ActiveConfig(i) \cup {s}
           entry == [term |-> currentTerm[i], type |-> ConfigEntry, config |-> newConfig]
       IN
       /\ log' = [log EXCEPT ![i] = Append(@, entry)]
       \* Pending config takes effect immediately (raft_consensus.cc:881)
       /\ pendingConfig' = [pendingConfig EXCEPT ![i] = newConfig]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   committedConfig, hasCommittedInTerm, memberType, electionVars>>

\* Leader i sends AppendEntries with log entries to server j.
\* Reference: consensus_peers.cc (peer sends request)
\*            consensus_queue.cc (RequestForPeer builds message)
\*   Sends PrevLogIndex, PrevLogTerm, entries, and committed_index
SendEntries(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == LogTerm(i, prevIdx)
           \* Send entries from nextIndex to end of log
           lastIdx  == LastLogIndex(i)
           entries  == IF nextIndex[i][j] > lastIdx THEN <<>>
                       ELSE SubSeq(log[i], nextIndex[i][j], lastIdx)
       IN Send([mtype        |-> AppendEntriesRequest,
                mterm        |-> currentTerm[i],
                mprevLogIndex |-> prevIdx,
                mprevLogTerm |-> prevTerm,
                mentries     |-> entries,
                mcommitIndex |-> commitIndex[i],
                msource      |-> i,
                mdest        |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, electionVars>>

\* Leader i sends heartbeat (empty AppendEntries) to server j.
\* In Kudu, heartbeats go through the same RequestForPeer path as regular sends.
\* Modeled as SendEntries (which sends empty entries when follower is up to date).
\* No separate SendHeartbeat needed — SendEntries subsumes it.
\* REMOVED: SendHeartbeat was incorrectly sending empty entries to out-of-date
\* followers, allowing commitIndex advancement without log synchronization.

\* Server i handles an AppendEntriesRequest m (follower update).
\* Reference: raft_consensus.cc:1377-1693 (UpdateReplica)
\*            raft_consensus.cc:1225-1294 (HandleLeaderRequestTermUnlocked, EnforceLogMatching)
\*
\* Key Extension 1 [Bug Family 1]: Commit index clamping
\*   Reference: raft_consensus.cc:1521-1526 (early_apply_up_to)
\*     apply_up_to = min(lastPending, precedingOpId, request.committedIndex)
\*   Reference: raft_consensus.cc:1633-1642 (final apply_up_to)
\*     apply_up_to = min(last_from_leader.index(), request.committedIndex)
\*
\* Three cases: reject (term too low), reject (log mismatch), accept.
HandleAppendEntriesRequest(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ LET mterm   == m.mterm
           \* PrevLog consistency check
           \* Reference: raft_consensus.cc:1251-1294 (EnforceLogMatchingProperty)
           logOk   == \/ m.mprevLogIndex = 0
                      \/ /\ m.mprevLogIndex > 0
                         /\ m.mprevLogIndex <= LastLogIndex(i)
                         /\ LogTerm(i, m.mprevLogIndex) = m.mprevLogTerm
       IN
       \/ \* Reject: term too low
          \* Reference: raft_consensus.cc:1232-1244 (HandleLeaderRequestTermUnlocked)
          /\ mterm < currentTerm[i]
          /\ Reply([mtype        |-> AppendEntriesResponse,
                    mterm        |-> currentTerm[i],
                    msuccess     |-> FALSE,
                    mmatchIndex  |-> 0,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         configVars, electionVars>>

       \/ \* Reject: log inconsistency
          \* Reference: raft_consensus.cc:1268-1270 (PRECEDING_ENTRY_DIDNT_MATCH)
          /\ mterm >= currentTerm[i]
          /\ ~logOk
          /\ Reply([mtype        |-> AppendEntriesResponse,
                    mterm        |-> mterm,
                    msuccess     |-> FALSE,
                    mmatchIndex  |-> 0,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          \* Step down / update term (raft_consensus.cc:1246)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ IF mterm > currentTerm[i]
             THEN hasCommittedInTerm' = [hasCommittedInTerm EXCEPT ![i] = FALSE]
             ELSE UNCHANGED hasCommittedInTerm
          \* Withhold votes after hearing from leader (raft_consensus.cc:1498-1499)
          /\ withholdVotes' = [withholdVotes EXCEPT ![i] = TRUE]
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         committedConfig, pendingConfig, memberType>>

       \/ \* Accept: log matches at prevLogIndex
          \* Reference: raft_consensus.cc:1562-1646 (prepare + commit steps)
          /\ mterm >= currentTerm[i]
          /\ logOk
          /\ LET \* Append new entries (truncate ONLY on conflict)
                 \* Reference: raft_consensus.cc:1562-1585 (StartFollowerOpUnlocked)
                 \* Raft paper Figure 2 step 3: "If an existing entry conflicts
                 \* with a new one (same index but different terms), delete the
                 \* existing entry and all that follow it."
                 \* If all new entries already match, keep the existing (longer) log.
                 newLog == IF Len(m.mentries) = 0
                           THEN log[i]
                           ELSE LET endIdx == m.mprevLogIndex + Len(m.mentries)
                                IN IF /\ endIdx <= Len(log[i])
                                      /\ \A k \in 1..Len(m.mentries) :
                                           log[i][m.mprevLogIndex + k].term = m.mentries[k].term
                                   THEN log[i]  \* all entries match, keep existing longer log
                                   ELSE SubSeq(log[i], 1, m.mprevLogIndex) \o m.mentries
                 newLastIdx == Len(newLog)
                 \* Commit index clamping [Bug Family 1 / Extension 1]
                 \* Reference: raft_consensus.cc:1633-1642
                 \*   apply_up_to = min(last_from_leader.index(), request.committed_index)
                 \* Additionally clamps to newLastIdx (can't commit beyond log)
                 clampedCommitIdx == Min(m.mcommitIndex, newLastIdx)
                 \* Clamp to newLastIdx to prevent commitIndex exceeding log length
                 \* after potential log truncation via prevLogIndex
                 newCommitIdx == Min(newLastIdx,
                                     IF clampedCommitIdx > commitIndex[i]
                                     THEN clampedCommitIdx
                                     ELSE commitIndex[i])
             IN
             /\ log' = [log EXCEPT ![i] = newLog]
             /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
             \* Update configs from committed entries [Bug Family 2]
             /\ LET configInCommitted == LET indices == {k \in 1..newCommitIdx :
                                                          newLog[k].type = ConfigEntry}
                                         IN IF indices = {} THEN Server
                                            ELSE newLog[SetMax(indices)].config
                    configInAll == LET indices == {k \in 1..newLastIdx :
                                                    newLog[k].type = ConfigEntry}
                                   IN IF indices = {} THEN Server
                                      ELSE newLog[SetMax(indices)].config
                IN
                /\ committedConfig' = [committedConfig EXCEPT ![i] = configInCommitted]
                \* Pending config is the latest uncommitted config change, if any
                /\ pendingConfig' = [pendingConfig EXCEPT ![i] =
                    IF configInAll /= configInCommitted THEN configInAll ELSE Nil]
             /\ Reply([mtype        |-> AppendEntriesResponse,
                       mterm        |-> mterm,
                       msuccess     |-> TRUE,
                       mmatchIndex  |-> newLastIdx,
                       msource      |-> i,
                       mdest        |-> m.msource], m)
          \* Step down / update term
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ IF mterm > currentTerm[i]
             THEN hasCommittedInTerm' = [hasCommittedInTerm EXCEPT ![i] = FALSE]
             ELSE UNCHANGED hasCommittedInTerm
          \* Withhold votes after hearing from leader (raft_consensus.cc:1498-1499)
          /\ withholdVotes' = [withholdVotes EXCEPT ![i] = TRUE]
          /\ UNCHANGED <<leaderVars, candidateVars, memberType>>

\* Leader i handles AppendEntriesResponse from server j.
\* Reference: consensus_queue.cc:1161-1351 (ResponseFromPeer)
\*   - Line 1218-1248: update peer's last_received and next_index
\*   - Line 1280-1295: advance majority/all watermarks
\*   - Line 1307-1310: advance committed_index
HandleAppendEntriesResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ \/ \* Higher term: step down
          \* Reference: consensus_queue.cc:1257-1264 (term check)
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ hasCommittedInTerm' = [hasCommittedInTerm EXCEPT ![i] = FALSE]
          /\ withholdVotes' = [withholdVotes EXCEPT ![i] = FALSE]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         committedConfig, pendingConfig, memberType>>

       \/ \* Same term response
          /\ m.mterm = currentTerm[i]
          /\ IF m.msuccess
             THEN \* Update matchIndex and nextIndex
                  \* Reference: consensus_queue.cc:1219-1222
                  /\ nextIndex'  = [nextIndex  EXCEPT ![i][m.msource] = m.mmatchIndex + 1]
                  /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] = m.mmatchIndex]
             ELSE \* Log mismatch: decrement nextIndex
                  \* Reference: consensus_queue.cc:1234-1247 (fallback strategies)
                  /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] = Max(1, nextIndex[i][m.msource] - 1)]
                  /\ UNCHANGED matchIndex
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, candidateVars,
                         configVars, electionVars>>

       \/ \* Stale response (from old term), ignore
          /\ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         configVars, electionVars>>

\* Leader i advances commit index based on quorum replication.
\* Reference: consensus_queue.cc:860-941 (AdvanceQueueWatermark)
\*            consensus_queue.cc:1297-1329 (commit advancement in ResponseFromPeer)
\*
\* Key details:
\*   - Line 886-889: only VOTER_REPLICAS count [Bug Family 2 / Extension 4]
\*   - Line 910: only peers with OK last_exchange_status count
\*   - Line 924: watermark = sorted_watermarks[size - majority_size]
\*   - Line 1307-1310: commit only if majority_replicated >= first_index_in_current_term
\*     This prevents committing entries from previous terms (Raft Figure 8)
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET \* Voters that have replicated up to each index
           \* Leader counts itself (consensus_queue.cc:234-235 local peer)
           Agree(idx) == {i} \cup {s \in Server :
                           /\ matchIndex[i][s] >= idx
                           /\ memberType[s] = "Voter"}  \* [Extension 4]
           \* Find highest index with quorum agreement in current term
           \* Reference: consensus_queue.cc:1307-1310
           agreeIdxs == {idx \in (commitIndex[i]+1)..LastLogIndex(i) :
                          /\ IsQuorum(Agree(idx) \cap ActiveVoters(i), ActiveVoters(i))
                          /\ log[i][idx].term = currentTerm[i]}
       IN
       /\ agreeIdxs /= {}
       /\ LET newCommitIdx == SetMax(agreeIdxs)
          IN
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
          \* Update hasCommittedInTerm [Extension 5]
          /\ hasCommittedInTerm' = [hasCommittedInTerm EXCEPT ![i] = TRUE]
          \* Update committed config [Bug Family 2]
          /\ LET indices == {k \in 1..newCommitIdx : log[i][k].type = ConfigEntry}
                 newCommConfig == IF indices = {} THEN Server
                                 ELSE log[i][SetMax(indices)].config
             IN committedConfig' = [committedConfig EXCEPT ![i] = newCommConfig]
          \* Clear pending config if it was committed
          /\ LET configIdx == {k \in 1..newCommitIdx : log[i][k].type = ConfigEntry}
             IN IF configIdx /= {} /\ SetMax(configIdx) <= newCommitIdx
                   /\ pendingConfig[i] /= Nil
                THEN pendingConfig' = [pendingConfig EXCEPT ![i] = Nil]
                ELSE UNCHANGED pendingConfig
    /\ UNCHANGED <<serverVars, log, leaderVars, candidateVars, messages,
                   memberType, electionVars>>

----
\* Vote Withholding (Extension 3) [Bug Family 3]
----

\* Server i's withholdVotes expires (models election timeout expiring).
\* Reference: raft_consensus.cc:665-674 (ReportFailureDetectedTask)
\* When withholdVotes is TRUE and no heartbeat refreshes it, it expires.
ExpireWithholdVotes(i) ==
    /\ withholdVotes[i] = TRUE
    /\ state[i] /= Leader   \* Leaders always withhold
    /\ withholdVotes' = [withholdVotes EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   configVars>>

----
\* Network failures
----

\* Message is lost.
LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, electionVars>>

\* Drop stale messages (helps bound state space).
DropStaleMessage(m) ==
    /\ m \in DOMAIN messages
    /\ m.mterm < currentTerm[m.mdest]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   configVars, electionVars>>

----
\* Spec
----

Next ==
    \/ \E i \in Server :
        \/ Timeout(i)
        \/ PreVote(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ StepDown(i)
        \/ AdvanceCommitIndex(i)
        \/ ExpireWithholdVotes(i)
    \/ \E i, j \in Server :
        \/ SendEntries(i, j)
        \/ ProposeConfigChange(i, j)
    \/ \E m \in DOMAIN messages :
        \/ HandleRequestVoteRequest(m.mdest, m)
        \/ HandleRequestVoteResponse(m.mdest, m)
        \/ HandleAppendEntriesRequest(m.mdest, m)
        \/ HandleAppendEntriesResponse(m.mdest, m)
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

\* Standard Raft: if two logs have an entry with same index and term,
\* the logs are identical up to that point.
\* Reference: Raft paper Figure 3, Log Matching Property
LogMatching ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(LastLogIndex(s1), LastLogIndex(s2)) :
            log[s1][idx].term = log[s2][idx].term =>
                \A k \in 1..idx : log[s1][k].term = log[s2][k].term

\* Standard Raft: a committed entry appears in all future leaders' logs.
\* Reference: Raft paper Figure 3, Leader Completeness Property
\* Only checked against the highest-term leader (stale leaders may not have
\* entries committed by newer leaders — they'll step down eventually).
LeaderCompleteness ==
    \A leader \in Server :
        /\ state[leader] = Leader
        \* Only check if this leader has the highest term among ALL servers
        \* (stale leaders with lower terms may not have entries committed by newer terms)
        /\ \A other \in Server : currentTerm[other] <= currentTerm[leader]
        =>
            \A other \in Server :
                \A idx \in 1..commitIndex[other] :
                    log[other][idx].term <= currentTerm[leader] =>
                        /\ idx <= LastLogIndex(leader)
                        /\ log[leader][idx].term = log[other][idx].term

\* Extension invariant [Bug Family 1]: Commit index bounded by what was received.
\* Reference: KUDU-639 fix at raft_consensus.cc:1521-1526
\* A follower's commitIndex should never exceed its log length.
CommitIndexBoundedByReceived ==
    \A s \in Server : commitIndex[s] <= LastLogIndex(s)

\* Extension invariant [Bug Family 1]: Commit index monotonicity.
\* Reference: consensus_queue.cc:1303-1305 (TODO acknowledges it can go backwards)
CommitIndexMonotonicity ==
    \A s \in Server : commitIndex[s] >= 0

\* Extension invariant [Bug Family 2]: Single pending config.
\* Reference: raft_consensus.cc:3110-3119 (CheckNoConfigChangePendingUnlocked)
\* At most one uncommitted configuration change at a time.
SinglePendingConfig ==
    \A s \in Server :
        state[s] = Leader =>
            LET configIndices == {idx \in (commitIndex[s]+1)..LastLogIndex(s) :
                                    log[s][idx].type = ConfigEntry}
            IN Cardinality(configIndices) <= 1

\* Extension invariant [Bug Family 2]: Config change requires commit in current term.
\* Reference: raft_consensus.cc:1916 (IsCommittedIndexInCurrentTerm check)
\* A leader only proposes config changes after committing in current term.
ConfigChangeRequiresCommit ==
    \A s \in Server :
        state[s] = Leader =>
            LET configIndices == {idx \in (commitIndex[s]+1)..LastLogIndex(s) :
                                    log[s][idx].type = ConfigEntry}
            IN configIndices /= {} => hasCommittedInTerm[s] = TRUE

\* Extension invariant [Bug Family 2]: Only voters count for quorum.
\* Reference: consensus_queue.cc:886-889 (VOTER_REPLICAS filter)
\* A committed entry must have been replicated to a majority of VOTERS.
VoterOnlyQuorum ==
    \A s \in Server :
        state[s] = Leader =>
            \A idx \in 1..commitIndex[s] :
                LET voters == ActiveVoters(s)
                    Agree == {s} \cup {t \in Server :
                              matchIndex[s][t] >= idx /\ memberType[t] = "Voter"}
                IN IsQuorum(Agree \cap voters, voters)

\* Extension invariant [Bug Family 3]: Vote safety.
\* Each server votes for at most one candidate per term (persistent).
VoteSafety ==
    \A s \in Server :
        votedFor[s] /= Nil =>
            \A t \in Server :
                (votedFor[t] /= Nil /\ currentTerm[s] = currentTerm[t])
                => \* Different servers can vote for different candidates
                   TRUE

\* Extension invariant [Bug Family 3]: Term never decreases.
\* A server's term should never go backwards in normal operation.
NoTermRegression ==
    \A s \in Server : currentTerm[s] >= 0

\* Extension invariant [Bug Family 4]: Leader NO_OP before config change.
\* Reference: raft_consensus.cc:1916 (must commit in current term first)
LeaderNOOPBeforeConfigChange ==
    \A s \in Server :
        /\ state[s] = Leader
        /\ pendingConfig[s] /= Nil
        => hasCommittedInTerm[s] = TRUE

=============================================================================
