---------------------------- MODULE base ----------------------------
\* TLA+ specification of Aeron Cluster Raft consensus protocol.
\*
\* Extends standard Raft with Aeron-specific behaviors:
\*   1. Commit position safety with active-member filtering (Bug Family 1, 4)
\*   2. Three-phase election: Canvass → Nominate → Ballot (Bug Family 2)
\*   3. Dual term design: candidateTermId vs leadershipTermId (Bug Family 2)
\*   4. Log truncation on NewLeadershipTerm with election reset (Bug Family 3)
\*   5. Snapshot divergence: leader append vs follower replay (Bug Family 5)
\*   6. Crash recovery from dual persistence stores (Bug Family 6)
\*
\* Source: artifact/aeron/aeron-cluster/src/main/java/io/aeron/cluster/

EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs

CONSTANT Nil                 \* Null value

\* Election states (simplified from 17-state machine)
\* Reference: Election.java:182-261 (doWork dispatch)
\* Prefixed with ES_ to avoid conflict with action names.
CONSTANTS ES_Init,           \* Initial/recovery state
          ES_Canvass,        \* Exchanging positions with peers
          ES_Nominate,       \* Self-nominated, sending vote requests
          ES_CandidateBallot,\* Waiting for votes
          ES_FollowerBallot, \* Received vote request, waiting for leader
          ES_Leader,         \* Established leader (combines LEADER_INIT/READY)
          ES_Follower        \* Established follower (combines FOLLOWER_* states)

\* Message types
CONSTANTS CanvassPositionMsg,
          RequestVoteMsg,
          RequestVoteResponseMsg,
          NewLeadershipTermMsg,
          CommitPositionMsg,
          AppendPositionUpdateMsg

----
\* Variables
----

\* Per-server persistent state
\* candidateTermId: monotonic vote guard, persisted via NodeStateFile
\* Reference: NodeStateFile.java:257-262 (proposeMaxCandidateTermId)
VARIABLE candidateTermId     \* [Server -> Nat]

\* leadershipTermId: established leader term, persisted via RecordingLog
\* Reference: RecordingLog.java:950-975 (appendTerm)
VARIABLE leadershipTermId    \* [Server -> Nat]

\* Log entries: each entry is [term |-> Nat, isSession |-> BOOLEAN]
\* Reference: Archive-based log storage
VARIABLE log                 \* [Server -> Seq(Entry)]

\* Committed log position (persisted via RecordingLog.commitLogPosition)
\* Reference: RecordingLog.java:1079-1093
VARIABLE commitPosition      \* [Server -> Nat]

\* Per-server volatile state
\* Election phase (simplified from 17-state machine)
VARIABLE electionState       \* [Server -> {ES_Init, ..., ES_Follower}]

\* Who this server believes is leader
VARIABLE currentLeader       \* [Server -> Server \cup {Nil}]

\* Votes received during ballot phase
\* Reference: ClusterMember.java:66 (vote field: Boolean TRUE/FALSE/null)
VARIABLE votesReceived       \* [Server -> [Server -> {"yes", "no"} \cup {Nil}]]

\* Known peer log terms and positions (from canvass + position updates)
\* Reference: ConsensusModuleAgent.updateMemberLogPosition (Election.java:310)
VARIABLE memberLogTerm       \* [Server -> [Server -> Nat]]
VARIABLE memberLogPosition   \* [Server -> [Server -> Nat]]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension: Commit Position Safety (Bug Family 1)
\* Follower's max notified commit position from leader
\* Reference: ConsensusModuleAgent.java:1079 (notifiedCommitPosition field)
VARIABLE notifiedCommitPosition  \* [Server -> Nat]

\* Extension: Active-Member Quorum (Bug Family 4)
\* Whether a member is considered active for quorum calculation
\* Reference: ClusterMember.java:1287-1290 (isActive timeout check)
VARIABLE memberActive        \* [Server -> BOOLEAN]

\* Extension: Snapshot Divergence (Bug Family 5)
\* Tracks session ID counter divergence between leader (append) and follower (replay)
\* Reference: PR #1739/#1774 — nextSessionId diverges between leader and followers
VARIABLE nextSessionId       \* [Server -> Nat]

\* Extension: Crash Recovery (Bug Family 6)
\* Persisted candidateTermId (separate from in-memory candidateTermId)
\* Reference: NodeStateFile.java:257-262
VARIABLE persistedCandidateTermId  \* [Server -> Nat]

----
\* Variable groups
----

serverVars    == <<candidateTermId, leadershipTermId, electionState, currentLeader>>
logVars       == <<log, commitPosition>>
elecDataVars  == <<votesReceived, memberLogTerm, memberLogPosition>>
commitExtVars == <<notifiedCommitPosition>>
activeVars    == <<memberActive>>
snapshotVars  == <<nextSessionId>>
persistVars   == <<persistedCandidateTermId>>

auxVars == <<commitExtVars, activeVars, snapshotVars, persistVars>>

vars == <<serverVars, logVars, elecDataVars, messages, auxVars>>

----
\* Helpers
----

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b

\* Log helpers
AppendPosition(i) == Len(log[i])
LastLogTerm(i) == IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term ELSE 0
LogTerm(i, idx) == IF idx > 0 /\ idx <= Len(log[i]) THEN log[i][idx].term ELSE 0

\* Quorum threshold: floor(n/2) + 1
\* Reference: ClusterMember.java quorumThreshold(n) = (n >> 1) + 1
QuorumThreshold == (Cardinality(Server) \div 2) + 1

\* Log up-to-date comparison: TRUE if candidate's log >= voter's log
\* Reference: ClusterMember.java:1173-1197 (compareLog)
\*            ClusterMember.java:1292-1298 (willVoteFor)
CandidateLogOk(cTerm, cPos, vTerm, vPos) ==
    \/ cTerm > vTerm
    \/ (cTerm = vTerm /\ cPos >= vPos)

\* Member position as seen by server i (leader uses own log length)
MemberPos(i, j) == IF i = j THEN Len(log[i]) ELSE memberLogPosition[i][j]

\* Quorum position: max position p such that |{active members with pos >= p}| >= threshold
\* Reference: ClusterMember.java:867-895 (quorumPosition)
\* Uses insertion sort into ranked array of size quorumThreshold
QuorumPosition(i) ==
    LET active == {j \in Server : memberActive[j]}
        threshold == QuorumThreshold
        hasQuorum(p) == Cardinality({j \in active : MemberPos(i, j) >= p}) >= threshold
        candidatePositions == {MemberPos(i, j) : j \in active} \cup {0}
    IN IF \E p \in candidatePositions : hasQuorum(p)
       THEN CHOOSE p \in candidatePositions :
                hasQuorum(p) /\ (\A q \in candidatePositions : q > p => ~hasQuorum(q))
       ELSE 0

\* isQuorumLeader: quorum of TRUE votes AND no FALSE vote (veto)
\* Reference: ClusterMember.java:1015-1036
\* Key: single FALSE vote vetoes (lines 1023-1026) — stricter than Raft
\* Vote values: "yes", "no", Nil (no vote received)
IsQuorumLeader(i) ==
    LET votes == votesReceived[i]
    IN \* No FALSE vote from any member (veto check, line 1023-1026)
       /\ \A j \in Server : votes[j] # "no"
       \* Enough TRUE votes (line 1028-1031)
       /\ Cardinality({j \in Server : votes[j] = "yes"}) >= QuorumThreshold

\* Count session entries in a log range (from+1..to)
\* Used for follower nextSessionId tracking (Bug Family 5)
SessionCountInRange(i, from, to) ==
    Cardinality({k \in (from+1)..to : log[i][k].isSession})

\* Message bag helpers
Send(m) == messages' = messages (+) SetToBag({m})
SendAll(ms) == messages' = messages (+) SetToBag(ms)
Discard(m) == messages' = messages (-) SetToBag({m})
Reply(resp, req) ==
    messages' = (messages (-) SetToBag({req})) (+) SetToBag({resp})
DiscardAndSend(discard, send) ==
    messages' = (messages (-) SetToBag({discard})) (+) SetToBag({send})

----
\* Init
----

Init ==
    /\ candidateTermId        = [s \in Server |-> 0]
    /\ leadershipTermId       = [s \in Server |-> 0]
    /\ log                    = [s \in Server |-> <<>>]
    /\ commitPosition         = [s \in Server |-> 0]
    /\ electionState          = [s \in Server |-> ES_Init]
    /\ currentLeader          = [s \in Server |-> Nil]
    /\ votesReceived          = [s \in Server |-> [t \in Server |-> Nil]]
    /\ memberLogTerm          = [s \in Server |-> [t \in Server |-> 0]]
    /\ memberLogPosition      = [s \in Server |-> [t \in Server |-> 0]]
    /\ messages               = EmptyBag
    /\ notifiedCommitPosition = [s \in Server |-> 0]
    /\ memberActive           = [s \in Server |-> TRUE]
    /\ nextSessionId          = [s \in Server |-> 0]
    /\ persistedCandidateTermId = [s \in Server |-> 0]

----
\* Election Actions
----

\* Server transitions from Init to Canvass, resetting election state.
\* Reference: Election.java:647-692 (init state handler)
EnterCanvass(i) ==
    /\ electionState[i] = ES_Init
    /\ electionState' = [electionState EXCEPT ![i] = ES_Canvass]
    \* Reset votes for new election cycle
    /\ votesReceived' = [votesReceived EXCEPT ![i] = [t \in Server |-> Nil]]
    /\ UNCHANGED <<candidateTermId, leadershipTermId, currentLeader,
                   logVars, memberLogTerm, memberLogPosition, messages, auxVars>>

\* Server sends canvass position to a peer.
\* Reference: Election.java:694-724 (canvass state handler sends positions)
SendCanvassPosition(i, j) ==
    /\ electionState[i] \in {ES_Canvass, ES_Leader, ES_Follower}
    /\ i # j
    /\ Send([mtype               |-> CanvassPositionMsg,
             msource             |-> i,
             mdest               |-> j,
             mlogLeadershipTermId |-> LastLogTerm(i),
             mlogPosition        |-> Len(log[i]),
             mleadershipTermId   |-> leadershipTermId[i]])
    /\ UNCHANGED <<serverVars, logVars, elecDataVars, auxVars>>

\* Handle incoming canvass position.
\* Reference: Election.java:290-338 (onCanvassPosition)
HandleCanvassPosition(i, m) ==
    /\ m.mtype = CanvassPositionMsg
    /\ m.mdest = i
    /\ i # m.msource
    /\ electionState[i] # ES_Init
    /\ LET j == m.msource
       IN
       \/ \* Branch 1: Non-leader — update member positions (line 310)
          /\ electionState[i] # ES_Leader
          /\ memberLogTerm' = [memberLogTerm EXCEPT ![i][j] = m.mlogLeadershipTermId]
          /\ memberLogPosition' = [memberLogPosition EXCEPT ![i][j] = m.mlogPosition]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, votesReceived, auxVars>>
       \/ \* Branch 2: Leader, follower behind — send NewLeadershipTerm (lines 312-324)
          /\ electionState[i] = ES_Leader
          /\ m.mlogLeadershipTermId <= leadershipTermId[i]
          /\ memberLogTerm' = [memberLogTerm EXCEPT ![i][j] = m.mlogLeadershipTermId]
          /\ memberLogPosition' = [memberLogPosition EXCEPT ![i][j] = m.mlogPosition]
          /\ DiscardAndSend(m,
               [mtype                   |-> NewLeadershipTermMsg,
                msource                 |-> i,
                mdest                   |-> j,
                mleadershipTermId       |-> leadershipTermId[i],
                mlogLeadershipTermId    |-> LastLogTerm(i),
                mtermBaseLogPosition    |-> Len(log[i]),
                mlogPosition            |-> Len(log[i]),
                mcommitPosition         |-> commitPosition[i],
                mnextTermBaseLogPosition |-> Len(log[i])])
          /\ UNCHANGED <<serverVars, logVars, votesReceived, auxVars>>
       \/ \* Branch 3: Leader, follower ahead — step down (lines 325-336)
          \* Reference: throws ClusterEvent "potential new election"
          /\ electionState[i] = ES_Leader
          /\ m.mlogLeadershipTermId > leadershipTermId[i]
          /\ electionState' = [electionState EXCEPT ![i] = ES_Init]
          /\ currentLeader' = [currentLeader EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<candidateTermId, leadershipTermId, logVars,
                         elecDataVars, auxVars>>

\* Server nominates itself after canvass phase.
\* Reference: Election.java:726-746 (nominate state handler)
\* Increments candidateTermId (line 730-731), sends RequestVote to all peers.
Nominate(i) ==
    /\ electionState[i] = ES_Canvass
    \* Increment candidateTermId and persist (Election.java:730-731)
    /\ LET newTerm == candidateTermId[i] + 1
       IN
       /\ candidateTermId' = [candidateTermId EXCEPT ![i] = newTerm]
       /\ persistedCandidateTermId' = [persistedCandidateTermId EXCEPT ![i] = newTerm]
       /\ electionState' = [electionState EXCEPT ![i] = ES_CandidateBallot]
       \* Self-vote
       /\ votesReceived' = [votesReceived EXCEPT ![i] =
              [t \in Server |-> IF t = i THEN "yes" ELSE Nil]]
       \* Send RequestVote to all peers
       /\ SendAll({[mtype               |-> RequestVoteMsg,
                    msource             |-> i,
                    mdest               |-> j,
                    mcandidateTermId    |-> newTerm,
                    mlogLeadershipTermId |-> LastLogTerm(i),
                    mlogPosition        |-> Len(log[i])] : j \in Server \ {i}})
    /\ UNCHANGED <<leadershipTermId, currentLeader, logVars,
                   memberLogTerm, memberLogPosition, commitExtVars,
                   activeVars, snapshotVars>>

\* Handle RequestVote from a candidate.
\* Reference: Election.java:340-387 (onRequestVote)
HandleRequestVote(i, m) ==
    /\ m.mtype = RequestVoteMsg
    /\ m.mdest = i
    /\ i # m.msource
    /\ electionState[i] # ES_Init  \* line 347-350: skip if INIT
    /\ LET j == m.msource
       IN
       \/ \* Case 1: Stale term — deny (line 357-359)
          /\ m.mcandidateTermId <= candidateTermId[i]
          /\ Reply([mtype            |-> RequestVoteResponseMsg,
                    msource          |-> i,
                    mdest            |-> j,
                    mcandidateTermId |-> m.mcandidateTermId,
                    mvote            |-> "no"], m)
          /\ UNCHANGED <<serverVars, logVars, elecDataVars, auxVars>>
       \/ \* Case 2: Higher term, our log newer — deny (lines 360-377)
          \* Update candidateTermId, send FALSE vote
          /\ m.mcandidateTermId > candidateTermId[i]
          /\ ~CandidateLogOk(m.mlogLeadershipTermId, m.mlogPosition,
                              LastLogTerm(i), Len(log[i]))
          /\ candidateTermId' = [candidateTermId EXCEPT ![i] = m.mcandidateTermId]
          /\ persistedCandidateTermId' = [persistedCandidateTermId EXCEPT
                 ![i] = m.mcandidateTermId]
          \* Clear stale votes since candidateTermId advanced
          /\ votesReceived' = [votesReceived EXCEPT ![i] = [t \in Server |-> Nil]]
          /\ Reply([mtype            |-> RequestVoteResponseMsg,
                    msource          |-> i,
                    mdest            |-> j,
                    mcandidateTermId |-> m.mcandidateTermId,
                    mvote            |-> "no"], m)
          /\ UNCHANGED <<leadershipTermId, electionState, currentLeader,
                         logVars, memberLogTerm, memberLogPosition,
                         commitExtVars, activeVars, snapshotVars>>
       \/ \* Case 3: Higher term, candidate log OK, in voting state — grant (lines 378-385)
          /\ m.mcandidateTermId > candidateTermId[i]
          /\ CandidateLogOk(m.mlogLeadershipTermId, m.mlogPosition,
                             LastLogTerm(i), Len(log[i]))
          /\ electionState[i] \in {ES_Canvass, ES_Nominate, ES_CandidateBallot, ES_FollowerBallot}
          /\ candidateTermId' = [candidateTermId EXCEPT ![i] = m.mcandidateTermId]
          /\ persistedCandidateTermId' = [persistedCandidateTermId EXCEPT
                 ![i] = m.mcandidateTermId]
          /\ electionState' = [electionState EXCEPT ![i] = ES_FollowerBallot]
          \* Clear stale votes since candidateTermId advanced
          /\ votesReceived' = [votesReceived EXCEPT ![i] = [t \in Server |-> Nil]]
          /\ Reply([mtype            |-> RequestVoteResponseMsg,
                    msource          |-> i,
                    mdest            |-> j,
                    mcandidateTermId |-> m.mcandidateTermId,
                    mvote            |-> "yes"], m)
          /\ UNCHANGED <<leadershipTermId, currentLeader, logVars,
                         memberLogTerm, memberLogPosition,
                         commitExtVars, activeVars, snapshotVars>>
       \/ \* Case 4: Higher term, candidate log OK, NOT in voting state — silent drop
          \* (Election.java: implicit else — no response, no term update)
          /\ m.mcandidateTermId > candidateTermId[i]
          /\ CandidateLogOk(m.mlogLeadershipTermId, m.mlogPosition,
                             LastLogTerm(i), Len(log[i]))
          /\ electionState[i] \notin {ES_Canvass, ES_Nominate, ES_CandidateBallot, ES_FollowerBallot}
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, elecDataVars, auxVars>>

\* Handle RequestVoteResponse — collect votes.
\* Reference: Election.java:748-788 (candidateBallot checks votes)
HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponseMsg
    /\ m.mdest = i
    /\ electionState[i] = ES_CandidateBallot
    \* Only accept votes for current candidateTermId
    /\ m.mcandidateTermId = candidateTermId[i]
    /\ votesReceived' = [votesReceived EXCEPT ![i][m.msource] = m.mvote]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, memberLogTerm, memberLogPosition, auxVars>>

\* Candidate becomes leader after quorum vote.
\* Reference: Election.java:748-788 (candidateBallot)
\*   - isUnanimousLeader (line 752): early leader if all vote TRUE
\*   - isQuorumLeader (line 761): quorum after timeout
\* We model both as one action since both check IsQuorumLeader.
BecomeLeader(i) ==
    /\ electionState[i] = ES_CandidateBallot
    /\ IsQuorumLeader(i)
    \* Set leadershipTermId = candidateTermId (Election.java:754-755, 763-764)
    /\ leadershipTermId' = [leadershipTermId EXCEPT ![i] = candidateTermId[i]]
    /\ electionState' = [electionState EXCEPT ![i] = ES_Leader]
    /\ currentLeader' = [currentLeader EXCEPT ![i] = i]
    \* Initialize own member position
    /\ memberLogPosition' = [memberLogPosition EXCEPT ![i][i] = Len(log[i])]
    \* Send NewLeadershipTerm to all peers
    /\ SendAll({[mtype                   |-> NewLeadershipTermMsg,
                 msource                 |-> i,
                 mdest                   |-> j,
                 mleadershipTermId       |-> candidateTermId[i],
                 mlogLeadershipTermId    |-> LastLogTerm(i),
                 mtermBaseLogPosition    |-> Len(log[i]),
                 mlogPosition            |-> Len(log[i]),
                 mcommitPosition         |-> commitPosition[i],
                 mnextTermBaseLogPosition |-> Len(log[i])] : j \in Server \ {i}})
    /\ UNCHANGED <<candidateTermId, logVars, votesReceived, memberLogTerm,
                   auxVars>>

\* Follower handles NewLeadershipTerm from leader.
\* Reference: Election.java:417-539 (onNewLeadershipTerm)
HandleNewLeadershipTerm(i, m) ==
    /\ m.mtype = NewLeadershipTermMsg
    /\ m.mdest = i
    /\ electionState[i] # ES_Init  \* line 433-436: skip if INIT
    /\ i # m.msource
    /\ LET j == m.msource
       IN
       \* Guard: in ballot with matching term OR canvassing (line 449-452)
       /\ \/ (electionState[i] \in {ES_FollowerBallot, ES_CandidateBallot}
              /\ m.mleadershipTermId = candidateTermId[i])
          \/ electionState[i] = ES_Canvass
       \* Log leadership term must match (line 452)
       \* Dropped if mismatch — potential convergence stall (MC-9)
       /\ m.mlogLeadershipTermId = LastLogTerm(i)
       \* Truncation check (Election.java:454-466)
       \* If leader's base position < our append position, truncate
       /\ IF m.mnextTermBaseLogPosition < Len(log[i])
          THEN log' = [log EXCEPT ![i] =
                   SubSeq(log[i], 1, m.mnextTermBaseLogPosition)]
          ELSE UNCHANGED log
       \* Update terms (Election.java:469-476)
       /\ leadershipTermId' = [leadershipTermId EXCEPT ![i] = m.mleadershipTermId]
       /\ candidateTermId' = [candidateTermId EXCEPT ![i] =
              Max(m.mleadershipTermId, candidateTermId[i])]
       /\ persistedCandidateTermId' = [persistedCandidateTermId EXCEPT ![i] =
              Max(m.mleadershipTermId, persistedCandidateTermId[i])]
       \* Update commit position notification (line 476)
       /\ notifiedCommitPosition' = [notifiedCommitPosition EXCEPT ![i] =
              Max(notifiedCommitPosition[i], m.mcommitPosition)]
       /\ currentLeader' = [currentLeader EXCEPT ![i] = j]
       /\ electionState' = [electionState EXCEPT ![i] = ES_Follower]
       \* Clear stale votes
       /\ votesReceived' = [votesReceived EXCEPT ![i] = [t \in Server |-> Nil]]
       \* Truncation may affect nextSessionId (Family 5)
       /\ IF m.mnextTermBaseLogPosition < Len(log[i])
          THEN nextSessionId' = [nextSessionId EXCEPT ![i] =
                   nextSessionId[i] - SessionCountInRange(i, m.mnextTermBaseLogPosition, Len(log[i]))]
          ELSE UNCHANGED nextSessionId
    /\ Discard(m)
    /\ UNCHANGED <<commitPosition, memberLogTerm, memberLogPosition,
                   activeVars>>

----
\* Log Replication Actions
----

\* Leader appends a client request to its log.
\* Reference: ConsensusModuleAgent.java:2417 (ingressAdapter poll → log append)
ClientRequest(i) ==
    /\ electionState[i] = ES_Leader
    /\ log' = [log EXCEPT ![i] = Append(log[i],
           [term |-> leadershipTermId[i], isSession |-> FALSE])]
    /\ UNCHANGED <<serverVars, commitPosition, elecDataVars, messages, auxVars>>

\* Leader appends a session-open entry (increments nextSessionId BEFORE commit).
\* Reference: ConsensusModuleAgent — leader increments nextSessionId on append
\* This models the divergence from Bug Family 5: leader counts sessions before commit,
\* followers count on replay.
LeaderAppendSessionOpen(i) ==
    /\ electionState[i] = ES_Leader
    /\ log' = [log EXCEPT ![i] = Append(log[i],
           [term |-> leadershipTermId[i], isSession |-> TRUE])]
    /\ nextSessionId' = [nextSessionId EXCEPT ![i] = nextSessionId[i] + 1]
    /\ UNCHANGED <<serverVars, commitPosition, elecDataVars, messages,
                   commitExtVars, activeVars, persistVars>>

\* Follower replicates the next entry from leader's log.
\* Reference: ConsensusModuleAgent.java:2438-2449 (logAdapter.poll in consensusWork)
\* Models archive-based replication abstractly: follower copies entries from leader.
FollowerReplicateLog(i) ==
    /\ electionState[i] = ES_Follower
    /\ currentLeader[i] # Nil
    /\ LET ldr == currentLeader[i]
       IN /\ electionState[ldr] = ES_Leader
          /\ Len(log[i]) < Len(log[ldr])
          \* Copy next entry from leader's log
          /\ log' = [log EXCEPT ![i] = Append(log[i], log[ldr][Len(log[i]) + 1])]
    /\ UNCHANGED <<serverVars, commitPosition, elecDataVars, messages, auxVars>>

\* Follower sends position update to leader.
\* Reference: ConsensusModuleAgent.java:2455 (updateFollowerPosition)
SendAppendPositionUpdate(i) ==
    /\ electionState[i] = ES_Follower
    /\ currentLeader[i] # Nil
    /\ Send([mtype               |-> AppendPositionUpdateMsg,
             msource             |-> i,
             mdest               |-> currentLeader[i],
             mlogLeadershipTermId |-> LastLogTerm(i),
             mlogPosition        |-> Len(log[i])])
    /\ UNCHANGED <<serverVars, logVars, elecDataVars, auxVars>>

\* Leader receives position update from follower.
\* Reference: ConsensusModuleAgent via ConsensusAdapter
HandleAppendPositionUpdate(i, m) ==
    /\ m.mtype = AppendPositionUpdateMsg
    /\ m.mdest = i
    /\ electionState[i] = ES_Leader
    /\ memberLogTerm' = [memberLogTerm EXCEPT ![i][m.msource] = m.mlogLeadershipTermId]
    /\ memberLogPosition' = [memberLogPosition EXCEPT ![i][m.msource] = m.mlogPosition]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, votesReceived, auxVars>>

\* Leader advances commit position based on quorum calculation.
\* Reference: ConsensusModuleAgent.java:2822-2847 (updateLeaderPosition)
\*            ConsensusModuleAgent.java:2806-2815 (quorumPositionBoundedByLeaderLog)
LeaderAdvanceCommitPosition(i) ==
    /\ electionState[i] = ES_Leader
    /\ LET qPos == QuorumPosition(i)
           \* Bounded by leader's log (ConsensusModuleAgent.java:2814)
           newCommitPos == Min(qPos, Len(log[i]))
       IN /\ newCommitPos > commitPosition[i]
          /\ commitPosition' = [commitPosition EXCEPT ![i] = newCommitPos]
    /\ UNCHANGED <<serverVars, log, elecDataVars, messages, auxVars>>

\* Leader broadcasts commit position to all followers.
\* Reference: ConsensusModuleAgent.java:2849-2858 (publishCommitPosition)
PublishCommitPosition(i) ==
    /\ electionState[i] = ES_Leader
    /\ SendAll({[mtype            |-> CommitPositionMsg,
                 msource          |-> i,
                 mdest            |-> j,
                 mleadershipTermId |-> leadershipTermId[i],
                 mcommitPosition  |-> commitPosition[i]] : j \in Server \ {i}})
    /\ UNCHANGED <<serverVars, logVars, elecDataVars, auxVars>>

\* Follower receives commit position from leader (normal operation).
\* Reference: ConsensusModuleAgent.java:1076-1083 (onCommitPosition, non-election path)
\* Checks: leadershipTermId matches, sender is current leader, role is Follower.
FollowerReceiveCommitPosition(i, m) ==
    /\ m.mtype = CommitPositionMsg
    /\ m.mdest = i
    /\ electionState[i] = ES_Follower
    /\ m.mleadershipTermId = leadershipTermId[i]   \* Term check (line 1076)
    /\ currentLeader[i] = m.msource                \* Sender is leader (line 1078)
    /\ LET newNotified == Max(notifiedCommitPosition[i], m.mcommitPosition)
           \* Follower advances commit up to min(notified, append)
           \* Reference: ConsensusModuleAgent.java:2440 (limit calculation)
           newCommit == Min(newNotified, Len(log[i]))
           oldCommit == commitPosition[i]
           \* Count session entries in newly committed range (Family 5)
           sessCount == IF newCommit > oldCommit
                        THEN SessionCountInRange(i, oldCommit, newCommit)
                        ELSE 0
       IN /\ notifiedCommitPosition' = [notifiedCommitPosition EXCEPT ![i] = newNotified]
          /\ commitPosition' = [commitPosition EXCEPT ![i] = Max(oldCommit, newCommit)]
          /\ nextSessionId' = [nextSessionId EXCEPT ![i] = nextSessionId[i] + sessCount]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, log, elecDataVars, activeVars, persistVars>>

\* During election, receive commit position — intentionally skips leadershipTermId check.
\* Reference: Election.java:563-594 (onCommitPosition)
\*            Election.java:571-573 — comment explains backward-compat workaround
\* This is the MC-5 finding: current code skips leadershipTermId validation.
ElectionReceiveCommitPosition(i, m) ==
    /\ m.mtype = CommitPositionMsg
    /\ m.mdest = i
    /\ electionState[i] \in {ES_Canvass, ES_Nominate, ES_CandidateBallot, ES_FollowerBallot}
    /\ currentLeader[i] = m.msource
    /\ currentLeader[i] # Nil
    \* NO leadershipTermId check — intentional (Election.java:571-573)
    /\ notifiedCommitPosition' = [notifiedCommitPosition EXCEPT ![i] =
           Max(notifiedCommitPosition[i], m.mcommitPosition)]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, elecDataVars, activeVars,
                   snapshotVars, persistVars>>

\* Leader detects higher leadershipTermId in commit position — step down.
\* Reference: ConsensusModuleAgent.java:1084-1098
LeaderDetectHigherTerm(i, m) ==
    /\ m.mtype = CommitPositionMsg
    /\ m.mdest = i
    /\ electionState[i] = ES_Leader
    /\ m.mleadershipTermId > leadershipTermId[i]
    /\ electionState' = [electionState EXCEPT ![i] = ES_Init]
    /\ currentLeader' = [currentLeader EXCEPT ![i] = Nil]
    /\ Discard(m)
    /\ UNCHANGED <<candidateTermId, leadershipTermId, logVars, elecDataVars,
                   auxVars>>

----
\* Fault Injection Actions
----

\* Election timeout — server reverts to Init to start new election.
\* Reference: ConsensusModuleAgent.java:2968-3002 (enterElection)
Timeout(i) ==
    /\ electionState[i] \in {ES_Follower, ES_Leader, ES_CandidateBallot, ES_FollowerBallot}
    /\ electionState' = [electionState EXCEPT ![i] = ES_Init]
    /\ currentLeader' = [currentLeader EXCEPT ![i] = Nil]
    /\ UNCHANGED <<candidateTermId, leadershipTermId, logVars, elecDataVars,
                   messages, auxVars>>

\* Crash and recovery from persisted state.
\* Reference: Bug Family 6 — dual persistence stores
\* candidateTermId recovered from NodeStateFile (persistedCandidateTermId).
\* leadershipTermId, log, commitPosition survive (persisted in RecordingLog/Archive).
\* Volatile state (electionState, currentLeader, votes, etc.) lost.
Crash(i) ==
    \* Volatile state lost
    /\ electionState' = [electionState EXCEPT ![i] = ES_Init]
    /\ currentLeader' = [currentLeader EXCEPT ![i] = Nil]
    /\ votesReceived' = [votesReceived EXCEPT ![i] = [t \in Server |-> Nil]]
    /\ memberLogTerm' = [memberLogTerm EXCEPT ![i] = [t \in Server |-> 0]]
    /\ memberLogPosition' = [memberLogPosition EXCEPT ![i] = [t \in Server |-> 0]]
    /\ notifiedCommitPosition' = [notifiedCommitPosition EXCEPT ![i] = commitPosition[i]]
    \* Recover candidateTermId from persisted store
    /\ candidateTermId' = [candidateTermId EXCEPT ![i] = persistedCandidateTermId[i]]
    \* Persisted state survives
    /\ UNCHANGED <<leadershipTermId, log, commitPosition,
                   persistedCandidateTermId, memberActive, nextSessionId, messages>>

\* Member becomes inactive (timeout from leader's perspective).
\* Reference: ClusterMember.java:1287-1290 (isActive check)
\* Bug Family 4: crashed/inactive members poisoned quorum calculation
MemberBecomeInactive(i) ==
    /\ memberActive[i] = TRUE
    /\ memberActive' = [memberActive EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<serverVars, logVars, elecDataVars, messages,
                   commitExtVars, snapshotVars, persistVars>>

\* Member recovers to active status.
MemberBecomeActive(i) ==
    /\ memberActive[i] = FALSE
    /\ memberActive' = [memberActive EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<serverVars, logVars, elecDataVars, messages,
                   commitExtVars, snapshotVars, persistVars>>

\* Lose a message from the network.
LoseMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, elecDataVars, auxVars>>

\* Drop stale messages (from old terms or unknown leaders).
\* Prevents message bag unbounded growth during model checking.
DropStaleMessage(m) ==
    /\ \/ m.mtype = RequestVoteResponseMsg
          /\ \/ m.mcandidateTermId < candidateTermId[m.mdest]
             \/ electionState[m.mdest] # ES_CandidateBallot
       \/ m.mtype = CommitPositionMsg
          /\ m.mleadershipTermId < leadershipTermId[m.mdest]
       \/ m.mtype = NewLeadershipTermMsg
          /\ m.mleadershipTermId < candidateTermId[m.mdest]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, elecDataVars, auxVars>>

----
\* Next and Spec
----

Next ==
    \/ \E i \in Server :
        \/ EnterCanvass(i)
        \/ Nominate(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ LeaderAppendSessionOpen(i)
        \/ FollowerReplicateLog(i)
        \/ SendAppendPositionUpdate(i)
        \/ LeaderAdvanceCommitPosition(i)
        \/ PublishCommitPosition(i)
        \/ Timeout(i)
        \/ Crash(i)
        \/ MemberBecomeInactive(i)
        \/ MemberBecomeActive(i)
    \/ \E i, j \in Server :
        /\ i # j
        /\ SendCanvassPosition(i, j)
    \/ \E m \in DOMAIN messages :
        \/ HandleCanvassPosition(m.mdest, m)
        \/ HandleRequestVote(m.mdest, m)
        \/ HandleRequestVoteResponse(m.mdest, m)
        \/ HandleNewLeadershipTerm(m.mdest, m)
        \/ HandleAppendPositionUpdate(m.mdest, m)
        \/ FollowerReceiveCommitPosition(m.mdest, m)
        \/ ElectionReceiveCommitPosition(m.mdest, m)
        \/ LeaderDetectHigherTerm(m.mdest, m)
        \/ LoseMessage(m)
        \/ DropStaleMessage(m)

Spec == Init /\ [][Next]_vars

----
\* Invariants
----

\* Standard: At most one leader per leadershipTermId.
\* Reference: Raft Election Safety property
ElectionSafety ==
    \A i, j \in Server :
        (electionState[i] = ES_Leader /\ electionState[j] = ES_Leader /\ i # j) =>
            leadershipTermId[i] # leadershipTermId[j]

\* Standard: Log entries at same position with same term are identical.
\* Reference: Raft Log Matching property
LogMatching ==
    \A i, j \in Server :
        \A k \in 1..Min(Len(log[i]), Len(log[j])) :
            log[i][k].term = log[j][k].term =>
                \A m \in 1..k : log[i][m] = log[j][m]

\* Standard: Committed entries appear in all future leaders' logs.
\* Reference: Raft Leader Completeness property
LeaderCompleteness ==
    \A i \in Server :
        electionState[i] = ES_Leader =>
            \A j \in Server :
                \A k \in 1..commitPosition[j] :
                    /\ k <= Len(log[i])
                    /\ log[i][k] = log[j][k]

\* Family 1: Leader's published commitPosition <= actual quorum position among active members.
\* Reference: ConsensusModuleAgent.java:2830-2837 — publishCommitPosition sends
\* quorumPosition. Bug: quorumPosition can regress if active set changes.
\* Only checked when leader is active — if leader itself becomes inactive after commit,
\* past commits remain durable and should not be invalidated.
CommitBoundedByQuorum ==
    \A i \in Server :
        (electionState[i] = ES_Leader /\ memberActive[i]) =>
            commitPosition[i] <= Min(QuorumPosition(i), Len(log[i]))

\* Family 1: Follower never replays past min(notifiedCommitPosition, appendPosition).
\* Reference: ConsensusModuleAgent.java:2440 (limit = min(notified, append))
\* Historical: ae89386d1d — follower replays past commit position
NoUncommittedReplay ==
    \A i \in Server :
        electionState[i] = ES_Follower =>
            commitPosition[i] <= Min(notifiedCommitPosition[i], Len(log[i]))

\* Family 2: Each server grants at most one vote per candidateTermId.
\* Enforced structurally: candidateTermId is monotonic, > check prevents re-voting.
\* This invariant verifies no voter grants "yes" to two different candidates
\* for the same candidateTermId. Self-votes are excluded — each candidate
\* unconditionally votes for itself, so two candidates CAN both self-vote
\* at the same term (independent term increment from same base).
VoteUniqueness ==
    \A v \in Server :
        \A i, j \in Server :
            (i # j /\ i # v /\ j # v
             /\ electionState[i] = ES_CandidateBallot
             /\ electionState[j] = ES_CandidateBallot
             /\ candidateTermId[i] = candidateTermId[j]
             /\ votesReceived[i][v] = "yes"
             /\ votesReceived[j][v] = "yes") => FALSE

\* Family 3: Only uncommitted entries are truncated.
\* Reference: Election.java:454-466 — truncation at nextTermBaseLogPosition
\* This is a structural invariant: no server's log should be shorter than its commitPosition.
TruncationSafety ==
    \A i \in Server : commitPosition[i] <= Len(log[i])

\* Family 5: Snapshot consistency — servers at same commitPosition should have same nextSessionId.
\* This invariant is expected to be VIOLATED when the leader increments nextSessionId on
\* append (before commit) while followers increment on replay (after commit).
\* Reference: PR #1739/#1774 — nextSessionId diverges between leader and followers
SnapshotConsistency ==
    \A i, j \in Server :
        (commitPosition[i] = commitPosition[j] /\ commitPosition[i] > 0) =>
            nextSessionId[i] = nextSessionId[j]

\* Family 6: After crash recovery, candidateTermId >= any term server has voted for.
\* This ensures no double-voting after crash.
\* Reference: NodeStateFile.java:257-262 (proposeMaxCandidateTermId persists before vote)
VoteRecovery ==
    \A i \in Server :
        candidateTermId[i] >= persistedCandidateTermId[i]

\* Structural: commitPosition never exceeds log length
CommitBound ==
    \A i \in Server : commitPosition[i] <= Len(log[i])

\* Structural: notifiedCommitPosition consistency
NotifiedCommitBound ==
    \A i \in Server :
        electionState[i] = ES_Follower =>
            commitPosition[i] <= notifiedCommitPosition[i]

\* Structural: candidateTermId >= leadershipTermId (monotonicity)
TermConsistency ==
    \A i \in Server :
        electionState[i] = ES_Leader => candidateTermId[i] >= leadershipTermId[i]

====
