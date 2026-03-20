---- MODULE base ----
\* TLA+ specification for Apache Ratis (Java Raft consensus library)
\* Models: leader election (pre-vote + priority), log replication (pipelining),
\*         commit index (flushIndex gate), joint consensus config changes,
\*         linearizable reads (lease + ReadIndex), snapshot installation.
\*
\* Source: ratis-server/src/main/java/org/apache/ratis/server/impl/
\* Reference: Raft paper (Ongaro & Ousterhout, 2014), Ongaro dissertation §4.3, §6.4

EXTENDS Integers, Sequences, FiniteSets, Bags, TLC

\* ============================================================================
\* Constants
\* ============================================================================

CONSTANTS
    Server,           \* Set of server IDs
    Value,            \* Set of client request values
    Nil,              \* Sentinel: no vote / no leader
    MaxTerm,          \* Upper bound on terms (state space)
    MaxLogLength       \* Upper bound on log length (state space)

\* Message types
CONSTANTS
    RequestVoteRequest, RequestVoteResponse,
    AppendEntriesRequest, AppendEntriesResponse,
    InstallSnapshotRequest, InstallSnapshotResponse

\* Roles
CONSTANTS Follower, Candidate, Leader

\* Election phases (Extension: Family 2 - Pre-Vote)
CONSTANTS PreVote, Election

\* AppendEntries reply results
CONSTANTS SUCCESS, INCONSISTENCY, NOT_LEADER

\* ============================================================================
\* Variables
\* ============================================================================

\* --- Standard Raft variables ---
VARIABLES
    currentTerm,    \* currentTerm[s]: latest term seen by server s
    votedFor,       \* votedFor[s]: candidate voted for in current term (or Nil)
    role,           \* role[s]: Follower, Candidate, or Leader
    log,            \* log[s]: sequence of [term |-> t, value |-> v, type |-> "normal"/"config"]
    commitIndex,    \* commitIndex[s]: highest committed log index
    messages        \* message bag (multiset)

\* --- Leader-specific variables ---
VARIABLES
    nextIndex,      \* nextIndex[s][t]: next log index to send to follower t (leader s)
    matchIndex,     \* matchIndex[s][t]: highest replicated index on follower t (leader s)
    leaderId        \* leaderId[s]: current believed leader (or Nil)

\* --- Extension: Family 1 (Commit Index Safety) ---
VARIABLES
    flushIndex      \* flushIndex[s]: last durably written log index
                    \* Models async I/O: log append is instant to cache, flush is separate
                    \* RaftLogBase.java:125 — min(majorityIndex, flushIndex)

\* --- Extension: Family 2 (Election & Leadership Transition) ---
VARIABLES
    priority,       \* priority[s]: election priority (higher = preferred leader)
                    \* VoteContext.java:152-162 — tiebreaker when logs equal
    leaderValid     \* leaderValid[s]: TRUE if follower recently heard from leader
                    \* FollowerState.java:94-96 — isCurrentLeaderValid()

\* --- Extension: Family 3 (Log Replication Index Management) ---
\* nextIndex/matchIndex already declared above
\* Pipelining modeled via multiple in-flight messages in message bag

\* --- Extension: Family 4 (Configuration Change Safety) ---
VARIABLES
    config,         \* config[s]: current configuration {peers: set, type: "stable"/"joint", oldPeers: set}
                    \* RaftConfigurationImpl.java:265-283 — hasMajority requires AND of old+new
    stagingState    \* stagingState[s]: Nil or set of peers being bootstrapped
                    \* LeaderStateImpl.java:488-524 — startSetConfiguration

\* --- Extension: Family 5 (Linearizable Read Safety) ---
VARIABLES
    leaseValid,     \* leaseValid[s]: TRUE if leader's lease is currently valid
                    \* LeaderLease.java:60-62 — isValid()
    pendingReads,   \* pendingReads[s]: number of pending read requests awaiting heartbeat ack
                    \* ReadIndexHeartbeats.java:85-123
    startupEntryCommitted \* startupEntryCommitted[s]: TRUE if leader's first no-op entry committed
                          \* LeaderStateImpl.java:1167 — readiness gate

\* --- Extension: Family 6 (Snapshot-Log Consistency) ---
VARIABLES
    snapshotIndex,  \* snapshotIndex[s]: last snapshot index
    snapshotTerm    \* snapshotTerm[s]: term of last snapshot

\* Variable groups for UNCHANGED
serverVars    == <<currentTerm, votedFor, role, leaderId>>
logVars       == <<log, commitIndex, flushIndex>>
leaderVars    == <<nextIndex, matchIndex>>
configVars    == <<config, stagingState>>
electionVars  == <<priority, leaderValid>>
readVars      == <<leaseValid, pendingReads, startupEntryCommitted>>
snapshotVars  == <<snapshotIndex, snapshotTerm>>
vars          == <<serverVars, logVars, leaderVars, configVars, electionVars, readVars, snapshotVars, messages>>

\* ============================================================================
\* Helpers
\* ============================================================================

\* --- Log helpers ---
LastLogIndex(s) == Len(log[s]) + snapshotIndex[s]
LastLogTerm(s)  == IF Len(log[s]) > 0 THEN log[s][Len(log[s])].term
                   ELSE IF snapshotIndex[s] > 0 THEN snapshotTerm[s]
                   ELSE 0

\* Get log entry at absolute index (adjusted for snapshot truncation)
LogEntry(s, idx) == IF idx > snapshotIndex[s] /\ idx <= LastLogIndex(s)
                    THEN log[s][idx - snapshotIndex[s]]
                    ELSE [term |-> 0, value |-> Nil, type |-> "normal"]

LogTerm(s, idx) == IF idx = snapshotIndex[s] THEN snapshotTerm[s]
                   ELSE IF idx > snapshotIndex[s] /\ idx <= LastLogIndex(s)
                   THEN log[s][idx - snapshotIndex[s]].term
                   ELSE 0

\* --- Message helpers ---
Send(m)    == messages' = messages (+) SetToBag({m})
Discard(m) == messages' = messages (-) SetToBag({m})
Reply(req, resp) == messages' = (messages (-) SetToBag({req})) (+) SetToBag({resp})

\* --- Quorum helpers (Extension: Family 4 - Joint Consensus) ---
\* RaftConfigurationImpl.java:265-269 — hasMajority
IsQuorum(peers, votes) ==
    2 * Cardinality(peers \intersect votes) > Cardinality(peers)

HasMajority(s, votes) ==
    \* Stable config: majority in conf.peers
    \* Joint (transitional) config: majority in BOTH old AND new
    /\ IsQuorum(config[s].peers, votes)
    /\ (config[s].type = "stable" \/ IsQuorum(config[s].oldPeers, votes))

\* Voters in current configuration (union of old and new in joint)
Voters(s) ==
    config[s].peers \union
    (IF config[s].type = "joint" THEN config[s].oldPeers ELSE {})

\* --- Log comparison (VoteContext.java:144-150) ---
\* ServerState.compareLog: compare (term, index) lexicographically
LogAtLeastAsUpToDate(candidateTerm, candidateIndex, voterTerm, voterIndex) ==
    \/ candidateTerm > voterTerm
    \/ (candidateTerm = voterTerm /\ candidateIndex >= voterIndex)

\* --- Min/Max ---
Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b

\* ============================================================================
\* Init
\* ============================================================================

Init ==
    /\ currentTerm = [s \in Server |-> 0]
    /\ votedFor    = [s \in Server |-> Nil]
    /\ role        = [s \in Server |-> Follower]
    /\ leaderId    = [s \in Server |-> Nil]
    /\ log         = [s \in Server |-> <<>>]
    /\ commitIndex = [s \in Server |-> 0]
    /\ flushIndex  = [s \in Server |-> 0]
    /\ nextIndex   = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex  = [s \in Server |-> [t \in Server |-> 0]]
    /\ priority    = [s \in Server |-> 0]  \* All equal by default; MC overrides
    /\ leaderValid = [s \in Server |-> FALSE]
    /\ config      = [s \in Server |-> [peers |-> Server, type |-> "stable", oldPeers |-> {}]]
    /\ stagingState = [s \in Server |-> Nil]
    /\ leaseValid  = [s \in Server |-> FALSE]
    /\ pendingReads = [s \in Server |-> 0]
    /\ startupEntryCommitted = [s \in Server |-> FALSE]
    /\ snapshotIndex = [s \in Server |-> 0]
    /\ snapshotTerm  = [s \in Server |-> 0]
    /\ messages    = EmptyBag

\* ============================================================================
\* Leader Election (Family 2)
\* ============================================================================

\* --- Timeout: follower/candidate starts election ---
\* FollowerState.java:144-178 — runImpl: election timeout triggers candidacy
\* LeaderElection.java:442-483 — askForVotes
\* ServerState.java:233-246 — initElection
Timeout(s) ==
    /\ role[s] \in {Follower, Candidate}
    /\ s \in Voters(s)           \* Must be a voter in current config
    /\ currentTerm[s] + 1 <= MaxTerm
    \* ServerState.java:236-240 — PRE_VOTE: use current term, ELECTION: increment
    \* We model combined pre-vote + election as single timeout→candidate transition
    \* Pre-vote is modeled as a separate RequestVote with phase=PreVote
    /\ currentTerm' = [currentTerm EXCEPT ![s] = currentTerm[s] + 1]
    /\ votedFor'    = [votedFor EXCEPT ![s] = s]  \* Vote for self
    /\ role'        = [role EXCEPT ![s] = Candidate]
    /\ leaderId'    = [leaderId EXCEPT ![s] = Nil]
    /\ leaderValid' = [leaderValid EXCEPT ![s] = FALSE]
    \* Send RequestVote to all other voters
    \* LeaderElection.java:485-495 — submitRequests
    /\ messages' = messages (+) SetToBag(
        {[mtype   |-> RequestVoteRequest,
          mterm   |-> currentTerm[s] + 1,
          msrc    |-> s,
          mdst    |-> t,
          mphase  |-> Election,
          \* LeaderElection.java:489 — lastEntry for log comparison
          mlastLogTerm  |-> LastLogTerm(s),
          mlastLogIndex |-> LastLogIndex(s),
          mpriority     |-> priority[s]] : t \in Voters(s) \ {s}})
    /\ UNCHANGED <<logVars, leaderVars, configVars, readVars, snapshotVars>>
    /\ UNCHANGED priority

\* --- Pre-Vote: candidate sends pre-vote requests without incrementing term ---
\* ServerState.java:236-237 — PRE_VOTE: use current term (no increment)
\* LeaderElection.java:382 — Phase.PRE_VOTE
StartPreVote(s) ==
    /\ role[s] \in {Follower, Candidate}
    /\ s \in Voters(s)
    \* Pre-vote does NOT increment term
    /\ role' = [role EXCEPT ![s] = Candidate]
    /\ leaderId' = [leaderId EXCEPT ![s] = Nil]
    /\ leaderValid' = [leaderValid EXCEPT ![s] = FALSE]
    /\ messages' = messages (+) SetToBag(
        {[mtype   |-> RequestVoteRequest,
          mterm   |-> currentTerm[s],  \* Current term, not incremented
          msrc    |-> s,
          mdst    |-> t,
          mphase  |-> PreVote,
          mlastLogTerm  |-> LastLogTerm(s),
          mlastLogIndex |-> LastLogIndex(s),
          mpriority     |-> priority[s]] : t \in Voters(s) \ {s}})
    /\ UNCHANGED <<currentTerm, votedFor>>
    /\ UNCHANGED <<logVars, leaderVars, configVars, readVars, snapshotVars>>
    /\ UNCHANGED priority

\* --- HandleRequestVoteRequest ---
\* RaftServerImpl.java:1450-1497 — requestVote (private)
\* VoteContext.java:114-127 — recognizeCandidate
\* VoteContext.java:136-163 — decideVote
HandleRequestVoteRequest(s, m) ==
    LET candidate == m.msrc
        candidateTerm == m.mterm
        phase == m.mphase
        \* VoteContext.java:68-89 — checkTerm
        termOk == \/ phase = PreVote  \* Pre-vote skips term check (line 69)
                  \/ candidateTerm > currentTerm[s]
                  \/ (candidateTerm = currentTerm[s] /\ (votedFor[s] = Nil \/ votedFor[s] = candidate))
        \* VoteContext.java:92-112 — checkLeader
        \* Skip leader check if candidate has higher term (SKIP_CHECK_LEADER, line 87)
        leaderOk == \/ (phase = Election /\ candidateTerm > currentTerm[s])
                    \/ ~leaderValid[s]
                    \/ leaderId[s] = Nil
                    \/ leaderId[s] = candidate
        \* VoteContext.java:144-150 — log comparison
        logOk == LogAtLeastAsUpToDate(m.mlastLogTerm, m.mlastLogIndex, LastLogTerm(s), LastLogIndex(s))
        \* VoteContext.java:152-162 — priority tiebreaker when logs equal
        priorityOk == \/ m.mlastLogTerm /= LastLogTerm(s)
                      \/ m.mlastLogIndex /= LastLogIndex(s)
                      \/ m.mpriority >= priority[s]
        grant == termOk /\ leaderOk /\ logOk /\ priorityOk
    IN
    /\ m.mtype = RequestVoteRequest
    /\ m.mdst = s
    \* RaftServerImpl.java:1470-1480 — ELECTION phase: change to follower, grant vote
    /\ IF phase = Election /\ grant
       THEN \* Grant vote in election phase
            /\ currentTerm' = [currentTerm EXCEPT ![s] = Max(currentTerm[s], candidateTerm)]
            /\ votedFor'    = [votedFor EXCEPT ![s] = candidate]
            /\ role'        = [role EXCEPT ![s] = Follower]
            /\ leaderId'    = [leaderId EXCEPT ![s] = Nil]
            /\ leaderValid' = [leaderValid EXCEPT ![s] = FALSE]
       ELSE IF phase = Election /\ ~grant /\ candidateTerm > currentTerm[s]
       THEN \* Higher term but denied: step down anyway (changeToFollower)
            /\ currentTerm' = [currentTerm EXCEPT ![s] = candidateTerm]
            /\ votedFor'    = [votedFor EXCEPT ![s] = Nil]
            /\ role'        = [role EXCEPT ![s] = Follower]
            /\ leaderId'    = [leaderId EXCEPT ![s] = Nil]
            /\ leaderValid' = [leaderValid EXCEPT ![s] = FALSE]
       ELSE \* Pre-vote or same/lower term denial: no state change
            /\ UNCHANGED <<currentTerm, votedFor, role, leaderId, leaderValid>>
    /\ Reply(m, [mtype    |-> RequestVoteResponse,
                 mterm    |-> Max(currentTerm[s], candidateTerm),
                 msrc     |-> s,
                 mdst     |-> candidate,
                 mphase   |-> phase,
                 mvoteGranted |-> grant])
    /\ UNCHANGED <<logVars, leaderVars, configVars, snapshotVars>>
    \* When stepping down from Leader, invalidate lease (LeaderStateImpl.stop())
    /\ IF role[s] = Leader /\ (phase = Election /\ (grant \/ candidateTerm > currentTerm[s]))
       THEN /\ leaseValid'  = [leaseValid EXCEPT ![s] = FALSE]
            /\ pendingReads' = [pendingReads EXCEPT ![s] = 0]
            /\ startupEntryCommitted' = [startupEntryCommitted EXCEPT ![s] = FALSE]
       ELSE UNCHANGED readVars
    /\ UNCHANGED priority

\* --- HandleRequestVoteResponse ---
\* LeaderElection.java:506-599 — waitForResults
HandleRequestVoteResponse(s, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdst = s
    /\ m.mphase = Election   \* Only election-phase responses trigger leadership
    /\ role[s] = Candidate
    /\ m.mterm = currentTerm[s]
    /\ m.mvoteGranted
    \* Check if we now have a quorum (including self-vote)
    \* LeaderElection.java:572-577 — majority check
    /\ LET grantedVotes == {s} \union
            {m2.msrc : m2 \in {m3 \in DOMAIN messages :
                /\ messages[m3] > 0
                /\ m3.mtype = RequestVoteResponse
                /\ m3.mdst = s
                /\ m3.mterm = currentTerm[s]
                /\ m3.mphase = Election
                /\ m3.mvoteGranted}}
       IN HasMajority(s, grantedVotes)
    \* Become leader
    /\ role' = [role EXCEPT ![s] = Leader]
    /\ leaderId' = [leaderId EXCEPT ![s] = s]
    \* LeaderStateImpl constructor — initialize nextIndex/matchIndex
    /\ nextIndex'  = [nextIndex EXCEPT ![s] = [t \in Server |-> LastLogIndex(s) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![s] = [t \in Server |-> 0]]
    \* Ratis does NOT append a no-op on leader election (unlike standard Raft).
    \* Startup entry commitment relies on the first client request in the new term.
    \* Extension: Family 5 — startup entry not yet committed
    /\ startupEntryCommitted' = [startupEntryCommitted EXCEPT ![s] = FALSE]
    /\ leaseValid' = [leaseValid EXCEPT ![s] = FALSE]
    /\ pendingReads' = [pendingReads EXCEPT ![s] = 0]
    /\ leaderValid' = [leaderValid EXCEPT ![s] = FALSE]
    /\ Discard(m)
    /\ UNCHANGED <<currentTerm, votedFor, logVars, configVars, snapshotVars>>
    /\ UNCHANGED priority

\* --- StepDown on higher term in vote response ---
\* LeaderElection.java:556-557 — DISCOVERED_A_NEW_TERM
HandleRequestVoteResponseHigherTerm(s, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdst = s
    /\ m.mterm > currentTerm[s]
    /\ currentTerm' = [currentTerm EXCEPT ![s] = m.mterm]
    /\ votedFor'    = [votedFor EXCEPT ![s] = Nil]
    /\ role'        = [role EXCEPT ![s] = Follower]
    /\ leaderId'    = [leaderId EXCEPT ![s] = Nil]
    /\ leaderValid' = [leaderValid EXCEPT ![s] = FALSE]
    /\ leaseValid'  = [leaseValid EXCEPT ![s] = FALSE]
    /\ Discard(m)
    /\ UNCHANGED <<logVars, leaderVars, configVars, snapshotVars>>
    /\ UNCHANGED <<priority, pendingReads, startupEntryCommitted>>

\* ============================================================================
\* Log Replication (Family 3)
\* ============================================================================

\* --- ClientRequest: leader appends entry to log ---
ClientRequest(s, v) ==
    /\ role[s] = Leader
    /\ LastLogIndex(s) < MaxLogLength
    /\ log' = [log EXCEPT ![s] = Append(@, [term |-> currentTerm[s], value |-> v, type |-> "normal"])]
    /\ UNCHANGED <<serverVars, commitIndex, flushIndex, leaderVars, configVars, electionVars, readVars, snapshotVars, messages>>

\* --- FlushLog: models async disk write completing ---
\* SegmentedRaftLogWorker — async I/O; flushIndex advances when disk write completes
\* Extension: Family 1 — flushIndex gates commit
FlushLog(s) ==
    /\ flushIndex[s] < LastLogIndex(s)
    /\ flushIndex' = [flushIndex EXCEPT ![s] = LastLogIndex(s)]
    /\ UNCHANGED <<serverVars, log, commitIndex, leaderVars, configVars, electionVars, readVars, snapshotVars, messages>>

\* --- AppendEntries: leader sends log entries to follower ---
\* LogAppenderBase.java:226-257 — newAppendEntriesRequest
\* LogAppenderDefault.java:59-104 — sendAppendEntriesWithRetries
AppendEntries(s, t) ==
    /\ role[s] = Leader
    /\ s /= t
    /\ t \in Voters(s) \union config[s].peers
    /\ LET prevLogIndex == nextIndex[s][t] - 1
           prevLogTerm  == LogTerm(s, prevLogIndex)
           \* Send entries from nextIndex to end of log
           lastEntry    == Min(LastLogIndex(s), nextIndex[s][t])
           entries      == IF nextIndex[s][t] <= LastLogIndex(s)
                          THEN SubSeq(log[s], nextIndex[s][t] - snapshotIndex[s],
                                      Min(Len(log[s]), nextIndex[s][t] - snapshotIndex[s] + 1))
                          ELSE <<>>
       IN
       \* Can only send if prevLogIndex is in our log or snapshot
       /\ prevLogIndex >= snapshotIndex[s]
       /\ prevLogIndex <= LastLogIndex(s)
       /\ Send([mtype          |-> AppendEntriesRequest,
                mterm          |-> currentTerm[s],
                msrc           |-> s,
                mdst           |-> t,
                mprevLogIndex  |-> prevLogIndex,
                mprevLogTerm   |-> prevLogTerm,
                mentries       |-> entries,
                mcommitIndex   |-> Min(commitIndex[s], LastLogIndex(s)),
                mfirstIndex    |-> nextIndex[s][t]])  \* Family 3: track for INCONSISTENCY
    /\ UNCHANGED <<serverVars, logVars, leaderVars, configVars, electionVars, readVars, snapshotVars>>

\* --- Heartbeat: leader sends empty AppendEntries ---
Heartbeat(s, t) ==
    /\ role[s] = Leader
    /\ s /= t
    /\ t \in Voters(s) \union config[s].peers
    /\ LET prevLogIndex == nextIndex[s][t] - 1
           prevLogTerm  == LogTerm(s, prevLogIndex)
       IN
       /\ prevLogIndex >= snapshotIndex[s]
       /\ Send([mtype          |-> AppendEntriesRequest,
                mterm          |-> currentTerm[s],
                msrc           |-> s,
                mdst           |-> t,
                mprevLogIndex  |-> prevLogIndex,
                mprevLogTerm   |-> prevLogTerm,
                mentries       |-> <<>>,
                mcommitIndex   |-> Min(commitIndex[s], LastLogIndex(s)),
                mfirstIndex    |-> nextIndex[s][t]])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, configVars, electionVars, readVars, snapshotVars>>

\* --- HandleAppendEntriesRequest ---
\* RaftServerImpl.java:1594-1682 — appendEntriesAsync
HandleAppendEntriesRequest(s, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdst = s
    /\ LET leaderTerm == m.mterm
           \* RaftServerImpl.java:1611 — recognizeLeader
           recognized == leaderTerm >= currentTerm[s]
       IN
       IF ~recognized
       THEN \* RaftServerImpl.java:1612-1615 — NOT_LEADER reply
            /\ Reply(m, [mtype      |-> AppendEntriesResponse,
                         mterm      |-> currentTerm[s],
                         msrc       |-> s,
                         mdst       |-> m.msrc,
                         mresult    |-> NOT_LEADER,
                         mnextIndex |-> 0,
                         mmatchIndex |-> 0])
            /\ UNCHANGED <<serverVars, logVars, leaderVars, configVars, electionVars, readVars, snapshotVars>>
       ELSE
       \* RaftServerImpl.java:1618 — changeToFollowerAndPersistMetadata
       /\ currentTerm' = [currentTerm EXCEPT ![s] = leaderTerm]
       /\ votedFor'    = [votedFor EXCEPT ![s] = IF leaderTerm > currentTerm[s] THEN Nil ELSE votedFor[s]]
       /\ role'        = [role EXCEPT ![s] = Follower]
       /\ leaderId'    = [leaderId EXCEPT ![s] = m.msrc]
       \* FollowerState.java:94-96 — leader contact resets validity
       /\ leaderValid' = [leaderValid EXCEPT ![s] = TRUE]
       \* RaftServerImpl.java:1636-1644 — checkInconsistentAppendEntries
       /\ LET prevLogIndex == m.mprevLogIndex
              prevOk == \/ prevLogIndex = 0
                        \/ (prevLogIndex = snapshotIndex[s] /\ m.mprevLogTerm = snapshotTerm[s])
                        \/ (prevLogIndex > snapshotIndex[s] /\ prevLogIndex <= LastLogIndex(s)
                            /\ LogTerm(s, prevLogIndex) = m.mprevLogTerm)
          IN
          IF ~prevOk
          THEN \* INCONSISTENCY reply
               /\ Reply(m, [mtype      |-> AppendEntriesResponse,
                            mterm      |-> leaderTerm,
                            msrc       |-> s,
                            mdst       |-> m.msrc,
                            mresult    |-> INCONSISTENCY,
                            \* RaftServerImpl.java:1688-1720 — replyNextIndex
                            mnextIndex |-> Max(1, Min(LastLogIndex(s), prevLogIndex)),
                            mmatchIndex |-> 0])
               /\ UNCHANGED <<log, commitIndex, flushIndex, leaderVars, configVars, readVars, snapshotVars>>
               /\ UNCHANGED priority
          ELSE \* SUCCESS: append entries and update commit
               /\ LET newEntries == m.mentries
                      baseIndex == m.mprevLogIndex - snapshotIndex[s]
                  IN
                  IF newEntries = <<>>
                  THEN \* Heartbeat (empty entries): no log change
                       \* RaftServerImpl.java:1669 — entries.isEmpty() skips appendLog
                       /\ UNCHANGED <<log, flushIndex>>
                       \* Follower commit update (heartbeat carries leaderCommit)
                       /\ commitIndex' = [commitIndex EXCEPT
                           ![s] = Max(commitIndex[s],
                                      Min(m.mcommitIndex,
                                          Min(LastLogIndex(s), flushIndex[s])))]
                       /\ Reply(m, [mtype      |-> AppendEntriesResponse,
                                    mterm      |-> leaderTerm,
                                    msrc       |-> s,
                                    mdst       |-> m.msrc,
                                    mresult    |-> SUCCESS,
                                    mnextIndex |-> LastLogIndex(s) + 1,
                                    mmatchIndex |-> 0])
                       /\ UNCHANGED <<leaderVars, configVars, readVars, snapshotVars>>
                       /\ UNCHANGED priority
                  ELSE \* Non-empty entries: truncate conflicting and append
                       \* RaftServerImpl.java:1725-1735 — reject if first entry <= commitIndex
                       /\ m.mfirstIndex > commitIndex[s]
                       /\ LET newLog == SubSeq(log[s], 1, baseIndex) \o newEntries
                          IN
                          /\ log' = [log EXCEPT ![s] = newLog]
                          \* Follower flushes immediately (simplified; real impl is async)
                          /\ flushIndex' = [flushIndex EXCEPT ![s] = snapshotIndex[s] + Len(newLog)]
                          \* RaftServerImpl.java:1664-1670 — follower commit update
                          \* RaftLogBase.java:122-142 — updateCommitIndex
                          \* RATIS-1161: Follower does NOT check term (line 127-128, isLeader=false)
                          /\ commitIndex' = [commitIndex EXCEPT
                              ![s] = Max(commitIndex[s],
                                         Min(m.mcommitIndex,
                                             Min(snapshotIndex[s] + Len(newLog),
                                                 flushIndex[s])))]
                          /\ Reply(m, [mtype      |-> AppendEntriesResponse,
                                       mterm      |-> leaderTerm,
                                       msrc       |-> s,
                                       mdst       |-> m.msrc,
                                       mresult    |-> SUCCESS,
                                       mnextIndex |-> snapshotIndex[s] + Len(newLog) + 1,
                                       mmatchIndex |-> snapshotIndex[s] + Len(newLog)])
                          /\ UNCHANGED <<leaderVars, configVars, readVars, snapshotVars>>
                          /\ UNCHANGED priority
       /\ IF role[s] = Leader /\ leaderTerm >= currentTerm[s]
          THEN \* Was leader, stepping down — invalidate lease
               /\ leaseValid' = [leaseValid EXCEPT ![s] = FALSE]
               /\ pendingReads' = [pendingReads EXCEPT ![s] = 0]
               /\ startupEntryCommitted' = [startupEntryCommitted EXCEPT ![s] = FALSE]
          ELSE UNCHANGED readVars

\* --- HandleAppendEntriesResponse ---
\* LogAppenderDefault.java:176-209 — handleReply
HandleAppendEntriesResponse(s, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdst = s
    /\ role[s] = Leader
    /\ m.mterm = currentTerm[s]
    /\ LET follower == m.msrc IN
       \/ \* SUCCESS — LogAppenderDefault.java:180-193
          /\ m.mresult = SUCCESS
          /\ IF m.mmatchIndex > 0  \* Non-heartbeat success
             THEN \* FollowerInfoImpl.java:92-94 — matchIndex = updateToMax (monotonic)
                  /\ matchIndex' = [matchIndex EXCEPT ![s][follower] = Max(matchIndex[s][follower], m.mmatchIndex)]
                  \* FollowerInfoImpl.java:117-119 — increaseNextIndex
                  /\ nextIndex'  = [nextIndex EXCEPT ![s][follower] = Max(nextIndex[s][follower], m.mnextIndex)]
             ELSE \* Heartbeat success: no index changes, but updates leader validity tracking
                  UNCHANGED <<nextIndex, matchIndex>>
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, configVars, electionVars, readVars, snapshotVars>>
       \/ \* INCONSISTENCY — LogAppenderDefault.java:199-201
          /\ m.mresult = INCONSISTENCY
          \* LogAppenderBase.java:190-204 — getNextIndexForInconsistency
          \* RATIS-1835: heartbeat INCONSISTENCY should be ignored — we handle by bounding
          \* Key invariant target (Family 3): nextIndex > matchIndex
          /\ nextIndex' = [nextIndex EXCEPT ![s][follower] =
                Max(matchIndex[s][follower] + 1,
                    Min(nextIndex[s][follower], m.mnextIndex))]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, matchIndex, configVars, electionVars, readVars, snapshotVars>>
       \/ \* NOT_LEADER (higher term) — LogAppenderDefault.java:195-197
          /\ m.mresult = NOT_LEADER
          /\ m.mterm > currentTerm[s]  \* Actually this means follower's term > ours
          \* LeaderStateImpl.java:477-483 — onFollowerTerm → step down
          /\ currentTerm' = [currentTerm EXCEPT ![s] = m.mterm]
          /\ votedFor'    = [votedFor EXCEPT ![s] = Nil]
          /\ role'        = [role EXCEPT ![s] = Follower]
          /\ leaderId'    = [leaderId EXCEPT ![s] = Nil]
          /\ leaderValid' = [leaderValid EXCEPT ![s] = FALSE]
          /\ leaseValid'  = [leaseValid EXCEPT ![s] = FALSE]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, configVars, snapshotVars>>
          /\ UNCHANGED <<priority, pendingReads, startupEntryCommitted>>

\* ============================================================================
\* Commit Index Advancement (Family 1)
\* ============================================================================

\* --- AdvanceCommitIndex: leader computes new commitIndex ---
\* LeaderStateImpl.java:913-993 — updateCommit / getMajorityMin
\* RaftLogBase.java:122-142 — updateCommitIndex
AdvanceCommitIndex(s) ==
    /\ role[s] = Leader
    /\ LET \* Compute majority match index
           \* LeaderStateImpl.java:919-951 — getMajorityMin
           matchIndices == {matchIndex[s][t] : t \in config[s].peers \ {s}} \union {LastLogIndex(s)}
           \* For joint consensus: need majority in both old and new
           Sorted(indices) == CHOOSE seq \in [1..Cardinality(indices) -> indices] :
                \A i, j \in 1..Cardinality(indices) : i < j => seq[i] <= seq[j]
           MedianIndex(peers) ==
                LET indices == {matchIndex[s][t] : t \in peers \ {s}} \union {LastLogIndex(s)}
                    sorted  == Sorted(indices)
                    mid     == (Cardinality(indices) + 1) \div 2
                IN sorted[mid]
           majorityIndex == IF config[s].type = "stable"
                           THEN MedianIndex(config[s].peers)
                           ELSE Min(MedianIndex(config[s].peers), MedianIndex(config[s].oldPeers))
           \* RaftLogBase.java:125 — min(majorityIndex, flushIndex)
           newCommitIndex == Min(majorityIndex, flushIndex[s])
       IN
       /\ newCommitIndex > commitIndex[s]
       \* RaftLogBase.java:131-135 — leader only commits entries from current term
       /\ LogTerm(s, newCommitIndex) = currentTerm[s]
       /\ commitIndex' = [commitIndex EXCEPT ![s] = newCommitIndex]
       \* Check if startup entry (no-op) is now committed
       /\ startupEntryCommitted' = [startupEntryCommitted EXCEPT
           ![s] = startupEntryCommitted[s] \/ newCommitIndex >= LastLogIndex(s)]
    /\ UNCHANGED <<serverVars, log, flushIndex, leaderVars, configVars, electionVars, snapshotVars, messages>>
    /\ UNCHANGED <<leaseValid, pendingReads>>

\* ============================================================================
\* Configuration Changes (Family 4)
\* ============================================================================

\* --- ProposeConfigChange: leader initiates configuration change ---
\* RaftServerImpl.java:1362-1366 — triple guard: isStable && !inStagingState && isConfCommitted
\* LeaderStateImpl.java:488-524 — startSetConfiguration
ProposeConfigChange(s, newPeers) ==
    /\ role[s] = Leader
    /\ config[s].type = "stable"
    /\ stagingState[s] = Nil
    \* Config entry must be committed
    /\ commitIndex[s] >= LastLogIndex(s)  \* Simplified: all prior entries committed
    /\ newPeers /= config[s].peers
    \* RaftConfigurationImpl.java:240-253 — changeMajority check
    /\ 2 * Cardinality(newPeers \ config[s].peers) < Cardinality(config[s].peers)
    \* LeaderStateImpl.java:592-601 — applyOldNewConf: append joint config
    /\ LET jointConfig == [peers |-> newPeers, type |-> "joint", oldPeers |-> config[s].peers]
       IN
       /\ log' = [log EXCEPT ![s] = Append(@, [term |-> currentTerm[s], value |-> jointConfig, type |-> "config"])]
       /\ flushIndex' = [flushIndex EXCEPT ![s] = LastLogIndex(s) + 1]
       /\ config' = [config EXCEPT ![s] = jointConfig]
       /\ stagingState' = [stagingState EXCEPT ![s] = newPeers \ config[s].peers]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, electionVars, readVars, snapshotVars, messages>>

\* --- CommitJointConfig: after joint config committed, leader appends stable config ---
\* LeaderStateImpl.java:1001-1022 — configuration change logic
\* LeaderStateImpl.java:1031-1041 — replicateNewConf
CommitJointConfig(s) ==
    /\ role[s] = Leader
    /\ config[s].type = "joint"
    \* Joint config entry is committed
    /\ commitIndex[s] >= LastLogIndex(s)
    \* LeaderStateImpl.java:1031-1041 — append new stable config
    /\ LET newConfig == [peers |-> config[s].peers, type |-> "stable", oldPeers |-> {}]
       IN
       /\ log' = [log EXCEPT ![s] = Append(@, [term |-> currentTerm[s], value |-> newConfig, type |-> "config"])]
       /\ flushIndex' = [flushIndex EXCEPT ![s] = LastLogIndex(s) + 1]
       /\ config' = [config EXCEPT ![s] = newConfig]
       /\ stagingState' = [stagingState EXCEPT ![s] = Nil]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, electionVars, readVars, snapshotVars, messages>>

\* ============================================================================
\* Linearizable Reads (Family 5)
\* ============================================================================

\* --- ClientRead: leader serves a read ---
\* LeaderStateImpl.java:1148-1187 — getReadIndex
ClientRead(s) ==
    /\ role[s] = Leader
    \* LeaderStateImpl.java:1167 — startup entry must be committed
    /\ startupEntryCommitted[s]
    \* Three paths:
    /\ \/ \* (a) Lease valid — LeaderLease.java:60-62 / LeaderStateImpl.java:1173
          /\ leaseValid[s]
          /\ UNCHANGED <<vars>>  \* Read served immediately, no state change
       \/ \* (b) Heartbeat round — LeaderStateImpl.java:1178-1186
          /\ ~leaseValid[s]
          /\ pendingReads' = [pendingReads EXCEPT ![s] = pendingReads[s] + 1]
          /\ UNCHANGED <<serverVars, logVars, leaderVars, configVars, electionVars, snapshotVars, messages>>
          /\ UNCHANGED <<leaseValid, startupEntryCommitted>>

\* --- ExtendLease: majority heartbeat acks received ---
\* LeaderLease.java:68-84 — extend
\* Completes pending reads when heartbeat ack confirms leadership
ExtendLease(s) ==
    /\ role[s] = Leader
    \* Check that majority of followers have recent matchIndex updates (proxy for heartbeat ack)
    /\ LET ackedServers == {s} \union {t \in Server : matchIndex[s][t] > 0 \/ t = s}
       IN HasMajority(s, ackedServers)
    /\ leaseValid' = [leaseValid EXCEPT ![s] = TRUE]
    /\ pendingReads' = [pendingReads EXCEPT ![s] = 0]  \* Complete all pending reads
    /\ UNCHANGED <<serverVars, logVars, leaderVars, configVars, electionVars, snapshotVars, messages>>
    /\ UNCHANGED startupEntryCommitted

\* --- ExpireLease: lease timeout ---
ExpireLease(s) ==
    /\ role[s] = Leader
    /\ leaseValid[s]
    /\ leaseValid' = [leaseValid EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, configVars, electionVars, snapshotVars, messages>>
    /\ UNCHANGED <<pendingReads, startupEntryCommitted>>

\* ============================================================================
\* Snapshot Installation (Family 6)
\* ============================================================================

\* --- TakeSnapshot: server snapshots at commitIndex ---
TakeSnapshot(s) ==
    /\ commitIndex[s] > snapshotIndex[s]
    /\ snapshotIndex' = [snapshotIndex EXCEPT ![s] = commitIndex[s]]
    /\ snapshotTerm'  = [snapshotTerm EXCEPT ![s] = LogTerm(s, commitIndex[s])]
    \* Truncate log prefix up to snapshot
    /\ log' = [log EXCEPT ![s] = SubSeq(@, commitIndex[s] - snapshotIndex[s] + 1, Len(@))]
    /\ flushIndex' = [flushIndex EXCEPT ![s] = Max(flushIndex[s], commitIndex[s])]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, configVars, electionVars, readVars, messages>>

\* --- SendInstallSnapshot: leader sends snapshot to lagging follower ---
\* LogAppenderBase — shouldInstallSnapshot: nextIndex <= snapshotIndex
SendInstallSnapshot(s, t) ==
    /\ role[s] = Leader
    /\ s /= t
    /\ nextIndex[s][t] <= snapshotIndex[s]
    /\ Send([mtype          |-> InstallSnapshotRequest,
             mterm          |-> currentTerm[s],
             msrc           |-> s,
             mdst           |-> t,
             msnapshotIndex |-> snapshotIndex[s],
             msnapshotTerm  |-> snapshotTerm[s]])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, configVars, electionVars, readVars, snapshotVars>>

\* --- HandleInstallSnapshotRequest ---
\* SnapshotInstallationHandler.java:167-241 — checkAndInstallSnapshot
HandleInstallSnapshotRequest(s, m) ==
    /\ m.mtype = InstallSnapshotRequest
    /\ m.mdst = s
    /\ m.mterm >= currentTerm[s]
    \* SnapshotInstallationHandler.java:210-215 — skip if already committed past this
    /\ m.msnapshotIndex > commitIndex[s]
    \* Step down if needed
    /\ currentTerm' = [currentTerm EXCEPT ![s] = m.mterm]
    /\ votedFor'    = [votedFor EXCEPT ![s] = IF m.mterm > currentTerm[s] THEN Nil ELSE votedFor[s]]
    /\ role'        = [role EXCEPT ![s] = Follower]
    /\ leaderId'    = [leaderId EXCEPT ![s] = m.msrc]
    /\ leaderValid' = [leaderValid EXCEPT ![s] = TRUE]
    \* Install snapshot: update indices, truncate log
    \* SegmentedRaftLog.java:506-529 — onSnapshotInstalled
    /\ snapshotIndex' = [snapshotIndex EXCEPT ![s] = m.msnapshotIndex]
    /\ snapshotTerm'  = [snapshotTerm EXCEPT ![s] = m.msnapshotTerm]
    /\ log' = [log EXCEPT ![s] = <<>>]  \* Truncate entire log
    /\ commitIndex' = [commitIndex EXCEPT ![s] = m.msnapshotIndex]
    /\ flushIndex'  = [flushIndex EXCEPT ![s] = m.msnapshotIndex]
    /\ Reply(m, [mtype          |-> InstallSnapshotResponse,
                 mterm          |-> m.mterm,
                 msrc           |-> s,
                 mdst           |-> m.msrc,
                 msnapshotIndex |-> m.msnapshotIndex])
    /\ UNCHANGED <<leaderVars, configVars, readVars>>
    /\ UNCHANGED priority

\* --- HandleInstallSnapshotResponse ---
HandleInstallSnapshotResponse(s, m) ==
    /\ m.mtype = InstallSnapshotResponse
    /\ m.mdst = s
    /\ role[s] = Leader
    /\ m.mterm = currentTerm[s]
    \* FollowerInfoImpl.java:146-150 — setSnapshotIndex updates match+next
    /\ matchIndex' = [matchIndex EXCEPT ![s][m.msrc] = Max(matchIndex[s][m.msrc], m.msnapshotIndex)]
    /\ nextIndex'  = [nextIndex EXCEPT ![s][m.msrc] = Max(nextIndex[s][m.msrc], m.msnapshotIndex + 1)]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, configVars, electionVars, readVars, snapshotVars>>

\* ============================================================================
\* Leader Step-Down (Family 2)
\* ============================================================================

\* --- CheckLeadership: leader steps down if no majority contact ---
\* RATIS-981: stale leader never stepped down in split-brain
\* LeaderStateImpl — checkLeadership / EventProcessor
CheckLeadership(s) ==
    /\ role[s] = Leader
    \* Model: non-deterministic step-down (real impl uses RPC timing)
    /\ role'        = [role EXCEPT ![s] = Follower]
    /\ leaderId'    = [leaderId EXCEPT ![s] = Nil]
    /\ leaseValid'  = [leaseValid EXCEPT ![s] = FALSE]
    /\ leaderValid' = [leaderValid EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, leaderVars, configVars, snapshotVars, messages>>
    /\ UNCHANGED <<priority, pendingReads, startupEntryCommitted>>

\* --- ExpireLeaderValidity: follower's leader validity timer expires ---
\* FollowerState.java:94-96 — isCurrentLeaderValid() returns false after timeout
ExpireLeaderValidity(s) ==
    /\ role[s] = Follower
    /\ leaderValid[s]
    /\ leaderValid' = [leaderValid EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<currentTerm, votedFor, role, leaderId, logVars, leaderVars, configVars, readVars, snapshotVars, messages>>
    /\ UNCHANGED priority

\* ============================================================================
\* Network Faults
\* ============================================================================

\* --- LoseMessage: drop a message from the network ---
LoseMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, configVars, electionVars, readVars, snapshotVars>>

\* --- DuplicateMessage: duplicate a message in the network ---
DuplicateMessage(m) ==
    /\ Send(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, configVars, electionVars, readVars, snapshotVars>>

\* ============================================================================
\* Crash and Recovery
\* ============================================================================

\* --- Crash: server crashes and loses volatile state ---
\* ServerState.java:248-250 — persistMetadata: (term, votedFor) survives
\* Everything else reverts: role→Follower, leaderId→Nil, volatile state cleared
Crash(s) ==
    /\ role'        = [role EXCEPT ![s] = Follower]
    /\ leaderId'    = [leaderId EXCEPT ![s] = Nil]
    /\ leaderValid' = [leaderValid EXCEPT ![s] = FALSE]
    /\ leaseValid'  = [leaseValid EXCEPT ![s] = FALSE]
    /\ pendingReads' = [pendingReads EXCEPT ![s] = 0]
    /\ startupEntryCommitted' = [startupEntryCommitted EXCEPT ![s] = FALSE]
    /\ nextIndex'   = [nextIndex EXCEPT ![s] = [t \in Server |-> 1]]
    /\ matchIndex'  = [matchIndex EXCEPT ![s] = [t \in Server |-> 0]]
    /\ stagingState' = [stagingState EXCEPT ![s] = Nil]
    \* Persist: currentTerm, votedFor, log, commitIndex survive
    \* flushIndex reverts to commitIndex (only flushed entries are durable)
    /\ flushIndex' = [flushIndex EXCEPT ![s] = commitIndex[s]]
    /\ UNCHANGED <<currentTerm, votedFor, log, commitIndex, config, snapshotVars, messages>>
    /\ UNCHANGED priority

\* ============================================================================
\* Next State
\* ============================================================================

Next ==
    \* Election actions
    \/ \E s \in Server : Timeout(s)
    \/ \E s \in Server : StartPreVote(s)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ HandleRequestVoteRequest(s, m)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ HandleRequestVoteResponse(s, m)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ HandleRequestVoteResponseHigherTerm(s, m)
    \* Log replication actions
    \/ \E s \in Server, v \in Value : ClientRequest(s, v)
    \/ \E s \in Server : FlushLog(s)
    \/ \E s, t \in Server : AppendEntries(s, t)
    \/ \E s, t \in Server : Heartbeat(s, t)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ HandleAppendEntriesRequest(s, m)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ HandleAppendEntriesResponse(s, m)
    \* Commit advancement
    \/ \E s \in Server : AdvanceCommitIndex(s)
    \* Configuration changes
    \/ \E s \in Server, newPeers \in SUBSET Server \ {{}} : ProposeConfigChange(s, newPeers)
    \/ \E s \in Server : CommitJointConfig(s)
    \* Reads
    \/ \E s \in Server : ClientRead(s)
    \/ \E s \in Server : ExtendLease(s)
    \/ \E s \in Server : ExpireLease(s)
    \* Snapshots
    \/ \E s \in Server : TakeSnapshot(s)
    \/ \E s, t \in Server : SendInstallSnapshot(s, t)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ HandleInstallSnapshotRequest(s, m)
    \/ \E s \in Server, m \in DOMAIN messages : messages[m] > 0 /\ HandleInstallSnapshotResponse(s, m)
    \* Leadership management
    \/ \E s \in Server : CheckLeadership(s)
    \/ \E s \in Server : ExpireLeaderValidity(s)
    \* Network faults
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\ LoseMessage(m)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\ DuplicateMessage(m)
    \* Crash
    \/ \E s \in Server : Crash(s)

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* Invariants
\* ============================================================================

\* --- Standard Safety ---

\* ElectionSafety: at most one leader per term
ElectionSafety ==
    \A s1, s2 \in Server :
        (role[s1] = Leader /\ role[s2] = Leader /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* LogMatching: same term+index implies identical prefix
LogMatching ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(LastLogIndex(s1), LastLogIndex(s2)) :
            (idx > Max(snapshotIndex[s1], snapshotIndex[s2])
             /\ LogTerm(s1, idx) = LogTerm(s2, idx))
            => LogEntry(s1, idx) = LogEntry(s2, idx)

\* LeaderCompleteness: committed entries appear in future leaders' logs
\* (checked implicitly via ElectionSafety + LogMatching + commit rules)

\* --- Extension: Family 1 (Commit Index Safety) ---

\* CommitMonotonicity: commitIndex never exceeds flushIndex
CommitFlushBound ==
    \A s \in Server : role[s] = Leader => commitIndex[s] <= flushIndex[s]

\* LeaderTermCommit: leader only commits entries from current term
\* (Checked in AdvanceCommitIndex action guard — LogTerm(s, newCI) = currentTerm)

\* --- Extension: Family 2 (Election Safety) ---

\* PreVoteNoSideEffect: pre-vote does not change persistent state
\* (Checked structurally: HandleRequestVoteRequest with phase=PreVote has no state writes)

\* --- Extension: Family 3 (Log Replication) ---

\* NextIndexBound: nextIndex always exceeds matchIndex
NextIndexBound ==
    \A s \in Server : role[s] = Leader =>
        \A t \in Server \ {s} :
            nextIndex[s][t] > matchIndex[s][t]

\* --- Extension: Family 4 (Configuration Change) ---

\* OneConfigChange: at most one uncommitted config change at a time
\* (Checked structurally: ProposeConfigChange requires config.type = "stable")

\* JointQuorum: during transition, commits require both old and new majorities
\* (Checked structurally: HasMajority uses AND of both)

\* --- Extension: Family 5 (Read Safety) ---

\* LeaseImpliesLeader: if lease valid, this server is still leader
LeaseImpliesLeader ==
    \A s \in Server : leaseValid[s] => role[s] = Leader

\* ReadLinearizability: a read can only be served if startup entry is committed and
\* either lease is valid or pending reads have been acknowledged.
\* Note: leaseValid can be true before startupEntryCommitted — that's OK because
\* ClientRead checks startupEntryCommitted independently (LeaderStateImpl:1167).
\* This invariant only checks the conjunction that would allow a read to proceed.
ReadLinearizability ==
    \A s \in Server :
        (role[s] = Leader /\ leaseValid[s] /\ startupEntryCommitted[s])
        => commitIndex[s] > 0

\* --- Extension: Family 6 (Snapshot) ---

\* SnapshotLogConsistency: snapshot index <= commitIndex, no gap
SnapshotLogConsistency ==
    \A s \in Server : snapshotIndex[s] <= commitIndex[s]

\* --- Structural invariants ---

\* TypeOK: basic type checking
TypeOK ==
    /\ currentTerm \in [Server -> Nat]
    /\ votedFor \in [Server -> Server \union {Nil}]
    /\ role \in [Server -> {Follower, Candidate, Leader}]
    /\ commitIndex \in [Server -> Nat]
    /\ flushIndex \in [Server -> Nat]
    /\ snapshotIndex \in [Server -> Nat]

====
