---------------------------- MODULE base ----------------------------
\* TLA+ specification of tikv/raft-rs consensus protocol.
\*
\* Extends standard Raft with raft-rs-specific behaviors:
\*   1. Leader lease / ReadIndex linearizability (Bug Family 1)
\*   2. Election safety / PreVote + CheckQuorum + Priority (Bug Family 2)
\*   3. Configuration change safety / joint consensus (Bug Family 3)
\*   4. Async persistence model (Bug Family 4)
\*
EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs

CONSTANTS Follower,          \* Server states
          Candidate,
          PreCandidate,
          Leader

CONSTANT Nil                 \* Null value

CONSTANTS ValueEntry,        \* Log entry types
          ConfigEntry,
          NoopEntry

CONSTANTS RequestVoteRequest,         \* Message types
          RequestVoteResponse,
          RequestPreVoteRequest,
          RequestPreVoteResponse,
          AppendEntriesRequest,
          AppendEntriesResponse,
          HeartbeatRequest,
          HeartbeatResponse,
          TimeoutNowRequest,
          InstallSnapshotRequest,
          InstallSnapshotResponse

----
\* Variables
----

\* Per-server persistent state (survives restart via stable store)
VARIABLE currentTerm         \* [Server -> Nat]
VARIABLE votedFor            \* [Server -> Server \cup {Nil}]
VARIABLE log                 \* [Server -> Seq([term: Nat, type: EntryType, value: Nat])]

\* Per-server volatile state
VARIABLE state               \* [Server -> {Follower, Candidate, PreCandidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat]
VARIABLE leaderId            \* [Server -> Server \cup {Nil}]

\* Leader volatile state
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate state
VARIABLE votesGranted        \* [Server -> SUBSET Server]
VARIABLE preVotesGranted     \* [Server -> SUBSET Server]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension 1: Leader Lease / ReadIndex (Bug Family 1)
\* raft-rs supports two read modes: Safe (heartbeat quorum) and LeaseBased.
\* Lease-based reads are served immediately from leader's committed state.
\* ReadIndex requires heartbeat confirmation before serving.
\* Reference: raft.rs:2145-2184 (step_leader ReadIndex handling)
\* Reference: raft.rs:2176-2181 (LeaseBased mode — serve immediately)
VARIABLE readIndex           \* [Server -> Nat] -- confirmed ReadIndex value (0 = none)
VARIABLE leaseValid          \* [Server -> BOOLEAN] -- TRUE = leader believes lease is valid
VARIABLE readRequestPending  \* [Server -> BOOLEAN] -- TRUE = waiting for heartbeat quorum

\* Extension 2: Leader Transfer (Bug Family 1)
\* Transfer leadership to target node. In-flight MsgTimeoutNow
\* can create dual-leader window.
\* Reference: raft.rs:1930-1978 (handle_transfer_leader)
\* Reference: raft.rs:1129-1131 (abort_leader_transfer on election timeout)
\* Reference: raft.rs:2398-2418 (follower receives MsgTimeoutNow, hup(true))
VARIABLE transferTarget      \* [Server -> Server \cup {Nil}]

\* Extension 3: CheckQuorum + Election Priority (Bug Family 2)
\* CheckQuorum: leader steps down if no quorum of recently active followers.
\* Priority: non-standard vote guard — priority <= msg.priority required.
\* Reference: raft.rs:2052-2061 (MsgCheckQuorum in step_leader)
\* Reference: tracker.rs:336-351 (quorum_recently_active)
\* Reference: raft.rs:1495 (priority check in vote grant)
VARIABLE recentlyActive      \* [Server -> SUBSET Server] -- leader's set of recently active peers
VARIABLE priority            \* [Server -> Nat] -- election priority (higher = more preferred)

\* Extension 4: Joint Consensus Configuration (Bug Family 3)
\* raft-rs uses joint consensus (enter_joint / leave_joint).
\* At most one pending conf change at a time.
\* auto_leave: after applying enter_joint, leader proposes leave_joint.
\* Reference: raft.rs:2083-2131 (conf change validation in step_leader)
\* Reference: raft.rs:2805-2817 (apply_conf_change)
\* Reference: raft.rs:984-1004 (auto_leave in commit_apply)
VARIABLE config              \* [Server -> SUBSET Server] -- incoming (current) voter set
VARIABLE newConfig           \* [Server -> SUBSET Server \cup {Nil}] -- outgoing voter set (Nil = not joint)
VARIABLE pendingConfIndex    \* [Server -> Nat] -- index of pending conf change (0 = none)

\* Extension 5: Async Persistence (Bug Family 4)
\* Leader sends AppendEntries BEFORE persisting locally.
\* Leader's own pr.matched = persisted (not last_index).
\* Reference: raft.rs:1033 (leader pr.matched = persisted in reset)
\* Reference: raft.rs:1055-1057 (append_entry: "Not update self's pr.matched until on_persist_entries")
\* Reference: raft.rs:1060-1082 (on_persist_entries)
\* Reference: raft_log.rs:540-568 (maybe_persist with first_update_index guard)
VARIABLE persisted           \* [Server -> Nat] -- highest persisted log index

----
\* Variable groups
----

serverVars    == <<currentTerm, votedFor, state, leaderId>>
logVars       == <<log, commitIndex>>
leaderVars    == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted, preVotesGranted>>
leaseVars     == <<readIndex, leaseValid, readRequestPending>>
transferVars  == <<transferTarget>>
electionVars  == <<recentlyActive, priority>>
configVars    == <<config, newConfig, pendingConfIndex>>
persistVars   == <<persisted>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          leaseVars, transferVars, electionVars, configVars, persistVars>>

----
\* Helpers
----

\* Minimum of two values
Min(a, b) == IF a < b THEN a ELSE b
\* Maximum of two values
Max(a, b) == IF a > b THEN a ELSE b

\* Log helpers
LastLogIndex(i) == Len(log[i])
LastLogTerm(i)  == IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term ELSE 0
LogTerm(i, idx) == IF idx > 0 /\ idx <= Len(log[i]) THEN log[i][idx].term ELSE 0

\* Log up-to-date comparison (raft.rs:is_up_to_date)
\* Reference: raft_log.rs:393-399
LogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    \/ cLastTerm > vLastTerm
    \/ (cLastTerm = vLastTerm /\ cLastIdx >= vLastIdx)

\* Configuration helpers — quorum must hold in BOTH incoming and outgoing for joint configs
\* Reference: confchange/changer.rs (joint consensus)
Voters(i) == config[i]
\* In joint consensus, a quorum is needed from both old and new configs
IsQuorum(subset, voters) == Cardinality(subset) * 2 > Cardinality(voters)

\* Joint quorum: requires quorum in both incoming and outgoing (if in joint)
HasQuorum(i, subset) ==
    /\ IsQuorum(subset \intersect config[i], config[i])
    /\ (newConfig[i] = Nil \/ IsQuorum(subset \intersect newConfig[i], newConfig[i]))

\* All voters (union of incoming and outgoing for joint configs)
AllVoters(i) == IF newConfig[i] = Nil THEN config[i]
                ELSE config[i] \union newConfig[i]

\* Is the cluster in joint consensus state?
InJoint(i) == newConfig[i] /= Nil

\* Message bag helpers (using Bags module)
Send(m) == messages' = messages (+) SetToBag({m})
SendAll(ms) == messages' = messages (+) SetToBag(ms)
Discard(m) == messages' = messages (-) SetToBag({m})
Reply(resp, req) == messages' = (messages (-) SetToBag({req})) (+) SetToBag({resp})
DiscardAndSendAll(discard, ms) == messages' = (messages (-) SetToBag({discard})) (+) SetToBag(ms)

\* Check if a server has committed an entry in its current term
\* Reference: raft.rs commit_to_current_term (raft_log.rs:583-587)
CommitToCurrentTerm(i) ==
    /\ commitIndex[i] > 0
    /\ log[i][commitIndex[i]].term = currentTerm[i]

\* Compute committed index from quorum of matchIndex
\* Reference: raft.rs:939-950 (maybe_commit via maximal_committed_index)
ComputeCommitIndex(i) ==
    LET agree(idx) == {i} \union {k \in AllVoters(i) \ {i} : matchIndex[i][k] >= idx}
    IN  IF \E idx \in (commitIndex[i]+1)..LastLogIndex(i) :
            /\ HasQuorum(i, agree(idx))
            /\ LogTerm(i, idx) = currentTerm[i]
        THEN CHOOSE idx \in (commitIndex[i]+1)..LastLogIndex(i) :
            /\ HasQuorum(i, agree(idx))
            /\ LogTerm(i, idx) = currentTerm[i]
            /\ ~\E idx2 \in (idx+1)..LastLogIndex(i) :
                /\ HasQuorum(i, agree(idx2))
                /\ LogTerm(i, idx2) = currentTerm[i]
        ELSE commitIndex[i]

----
\* Actions: State Transitions
----

\* Reset: called by become_follower, become_candidate, become_leader
\* Reference: raft.rs:1008-1037 (reset)
Reset(i, term) ==
    /\ currentTerm' = [currentTerm EXCEPT ![i] = term]
    /\ votedFor' = [votedFor EXCEPT ![i] = IF currentTerm[i] /= term THEN Nil ELSE votedFor[i]]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
    /\ transferTarget' = [transferTarget EXCEPT ![i] = Nil]
    /\ readRequestPending' = [readRequestPending EXCEPT ![i] = FALSE]
    /\ readIndex' = [readIndex EXCEPT ![i] = 0]
    /\ leaseValid' = [leaseValid EXCEPT ![i] = FALSE]
    /\ pendingConfIndex' = [pendingConfIndex EXCEPT ![i] = 0]
    /\ recentlyActive' = [recentlyActive EXCEPT ![i] = {}]

\* BecomeFollower: raft.rs:1148-1168
BecomeFollower(i, term, leader) ==
    /\ Reset(i, term)
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ leaderId' = [leaderId EXCEPT ![i] = leader]
    \* leader -> follower: nextIndex/matchIndex become stale but harmless
    /\ UNCHANGED <<log, commitIndex, nextIndex, matchIndex, messages,
                   config, newConfig, persisted, priority>>

\* BecomePreCandidate: raft.rs:1199-1218
\* Key: does NOT increment term, does NOT change vote.
\* Sets leader_id = INVALID_ID.
BecomePreCandidate(i) ==
    /\ state[i] /= Leader
    /\ state' = [state EXCEPT ![i] = PreCandidate]
    /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
    \* reset_votes + self-vote (raft.rs:1209, then poll(self_id) in campaign)
    /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {i}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    \* Note: messages NOT included in UNCHANGED — caller handles messages (e.g., SendAll)
    /\ UNCHANGED <<currentTerm, votedFor, log, commitIndex, nextIndex, matchIndex,
                   leaseVars, transferTarget, recentlyActive, priority,
                   config, newConfig, pendingConfIndex, persisted>>

\* BecomeCandidate: raft.rs:1176-1192
\* Increments term, votes for self.
BecomeCandidate(i) ==
    /\ state[i] /= Leader
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ state' = [state EXCEPT ![i] = Candidate]
    \* reset_votes + self-vote (raft.rs:1183-1185, then poll(self_id) in campaign)
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
    /\ transferTarget' = [transferTarget EXCEPT ![i] = Nil]
    /\ readRequestPending' = [readRequestPending EXCEPT ![i] = FALSE]
    /\ readIndex' = [readIndex EXCEPT ![i] = 0]
    /\ leaseValid' = [leaseValid EXCEPT ![i] = FALSE]
    /\ pendingConfIndex' = [pendingConfIndex EXCEPT ![i] = 0]
    /\ recentlyActive' = [recentlyActive EXCEPT ![i] = {}]
    \* Note: messages, preVotesGranted NOT set — caller handles them
    /\ UNCHANGED <<log, commitIndex, nextIndex, matchIndex,
                   config, newConfig, persisted, priority>>

\* BecomeLeader: raft.rs:1226-1277
\* Appends noop entry, sets pendingConfIndex to last_index.
\* Key (Bug Family 4): pr.matched for self = persisted (not last_index)
\* Reference: raft.rs:1033 (pr.matched = persisted in reset)
\* Reference: raft.rs:1245 (assert last_index == persisted)
BecomeLeader(i) ==
    /\ state[i] = Candidate
    /\ HasQuorum(i, votesGranted[i])  \* Only after winning election — raft.rs:2269-2276
    /\ LET newEntry == [term |-> currentTerm[i], type |-> NoopEntry, value |-> 0]
           newLog == Append(log[i], newEntry)
       IN
       /\ log' = [log EXCEPT ![i] = newLog]
       /\ state' = [state EXCEPT ![i] = Leader]
       /\ leaderId' = [leaderId EXCEPT ![i] = i]
       \* Reset nextIndex/matchIndex for all peers (raft.rs:1030-1036)
       \* Leader's own matchIndex = persisted (not last_index!)
       \* reset() sets nextIndex = old_last_index + 1 BEFORE noop append (raft.rs:1034)
       \* append_entry only updates leader's own nextIndex (raft.rs:1051-1059)
       /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |->
                            IF j = i THEN Len(newLog) + 1 ELSE Len(log[i]) + 1]]
       /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |->
                            IF j = i THEN persisted[i]   \* raft.rs:1033
                            ELSE 0]]
       \* pending_conf_index = last_index BEFORE noop append (raft.rs:1267)
       /\ pendingConfIndex' = [pendingConfIndex EXCEPT ![i] = Len(log[i])]
       /\ transferTarget' = [transferTarget EXCEPT ![i] = Nil]
       /\ recentlyActive' = [recentlyActive EXCEPT ![i] = {}]
       /\ readRequestPending' = [readRequestPending EXCEPT ![i] = FALSE]
       /\ readIndex' = [readIndex EXCEPT ![i] = 0]
       /\ leaseValid' = [leaseValid EXCEPT ![i] = FALSE]
       \* Note: messages, votesGranted, preVotesGranted NOT in UNCHANGED — caller handles them
       /\ UNCHANGED <<currentTerm, votedFor, commitIndex,
                      config, newConfig, persisted, priority>>

----
\* Actions: Elections
----

\* Timeout: follower/candidate/precandidate triggers election
\* Reference: raft.rs:1103-1113 (tick_election)
\* Reference: raft.rs:1539-1581 (hup)
Timeout(i) ==
    /\ state[i] \in {Follower, Candidate, PreCandidate}
    /\ i \in config[i]  \* must be in config (promotable, raft.rs:2800)
    /\ LET campaign_type == IF state[i] = Follower THEN "PreVote" ELSE "Vote"
       IN TRUE  \* Just establishing variable for clarity
    \* PreVote path: become_pre_candidate + send MsgRequestPreVote (raft.rs:1284-1287)
    /\ IF state[i] = Follower
       THEN \* PreVote election: raft.rs:1576-1577
            /\ BecomePreCandidate(i)
            \* Self-vote included in BecomePreCandidate
            \* Send PreVote requests to all voters
            /\ SendAll({[mtype   |-> RequestPreVoteRequest,
                         mterm   |-> currentTerm[i] + 1,    \* raft.rs:1287 — term+1 for pre-vote
                         msource |-> i,
                         mdest   |-> j,
                         mlastLogTerm  |-> LastLogTerm(i),
                         mlastLogIndex |-> LastLogIndex(i),
                         mcommit      |-> commitIndex[i],
                         mcommitTerm  |-> LogTerm(i, commitIndex[i]),
                         mpriority    |-> priority[i]] : j \in AllVoters(i) \ {i}})
       ELSE \* Regular election: raft.rs:1578-1579
            /\ BecomeCandidate(i)
            /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
            \* Send Vote requests
            /\ SendAll({[mtype   |-> RequestVoteRequest,
                         mterm   |-> currentTerm[i] + 1,    \* after BecomeCandidate increments
                         msource |-> i,
                         mdest   |-> j,
                         mlastLogTerm  |-> LastLogTerm(i),
                         mlastLogIndex |-> LastLogIndex(i),
                         mcommit      |-> commitIndex[i],
                         mcommitTerm  |-> LogTerm(i, commitIndex[i]),
                         mpriority    |-> priority[i]] : j \in AllVoters(i) \ {i}})

\* HandleRequestPreVoteRequest: raft.rs:1485-1529 (pre-vote path)
\* Pre-votes do NOT change term or votedFor.
HandleRequestPreVoteRequest(i, m) ==
    /\ m.mtype = RequestPreVoteRequest
    /\ m.mdest = i
    /\ LET grant ==
           \* Can grant PreVote if:
           \* 1. msg.term > self.term (future term pre-vote) — raft.rs:1491
           /\ m.mterm > currentTerm[i]
           \* 2. Log is up-to-date — raft.rs:1494
           /\ LogUpToDate(m.mlastLogTerm, m.mlastLogIndex, LastLogTerm(i), LastLogIndex(i))
           \* 3. Priority check — raft.rs:1495
           /\ (m.mlastLogIndex > LastLogIndex(i) \/ priority[i] <= m.mpriority)
       IN
       \* Lease protection (CheckQuorum): reject if within election timeout of known leader
       \* Reference: raft.rs:1354-1383 (in_lease check)
       IF m.mterm > currentTerm[i]
          /\ ~grant  \* If not granting and term is higher, normal PreVote rejection
       THEN
            /\ Reply([mtype    |-> RequestPreVoteResponse,
                      mterm    |-> currentTerm[i],
                      msource  |-> i,
                      mdest    |-> m.msource,
                      mreject  |-> TRUE,
                      mcommit  |-> commitIndex[i],
                      mcommitTerm |-> LogTerm(i, commitIndex[i])], m)
            /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                           leaseVars, transferVars, electionVars, configVars, persistVars>>
       ELSE IF grant
       THEN
            \* Grant PreVote — raft.rs:1506-1511
            \* Response carries m.term (not self.term) — raft.rs:1510
            /\ Reply([mtype    |-> RequestPreVoteResponse,
                      mterm    |-> m.mterm,
                      msource  |-> i,
                      mdest    |-> m.msource,
                      mreject  |-> FALSE,
                      mcommit  |-> commitIndex[i],
                      mcommitTerm |-> LogTerm(i, commitIndex[i])], m)
            \* PreVote does NOT record vote or reset election timer — raft.rs:1512-1516
            /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                           leaseVars, transferVars, electionVars, configVars, persistVars>>
       ELSE
            \* Reject PreVote — raft.rs:1517-1528
            /\ Reply([mtype    |-> RequestPreVoteResponse,
                      mterm    |-> currentTerm[i],
                      msource  |-> i,
                      mdest    |-> m.msource,
                      mreject  |-> TRUE,
                      mcommit  |-> commitIndex[i],
                      mcommitTerm |-> LogTerm(i, commitIndex[i])], m)
            \* maybe_commit_by_vote on rejection — raft.rs:1527
            /\ LET newCI == IF m.mcommit > 0 /\ m.mcommitTerm > 0
                               /\ m.mcommit > commitIndex[i]
                               /\ state[i] /= Leader
                               /\ LogTerm(i, m.mcommit) = m.mcommitTerm
                            THEN m.mcommit
                            ELSE commitIndex[i]
               IN commitIndex' = [commitIndex EXCEPT ![i] = newCI]
            /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, log,
                           leaderVars, candidateVars,
                           leaseVars, transferVars, electionVars, configVars, persistVars>>

\* HandleRequestPreVoteResponse: raft.rs:2316-2329 (step_candidate, PreVote response)
HandleRequestPreVoteResponse(i, m) ==
    /\ m.mtype = RequestPreVoteResponse
    /\ m.mdest = i
    /\ state[i] = PreCandidate
    \* Only handle PreVote responses when PreCandidate — raft.rs:2320-2321
    /\ IF ~m.mreject
       THEN \* PreVote granted
            /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = @ \union {m.msource}]
            \* Check if won PreVote quorum — raft.rs:2269-2276
            /\ IF HasQuorum(i, preVotesGranted'[i])
               THEN \* Won PreVote: start real election — raft.rs:2272
                    \* campaign(CAMPAIGN_ELECTION) calls become_candidate + send votes
                    /\ BecomeCandidate(i)
                    \* Self-vote included in BecomeCandidate
                    \* Discard PreVoteResponse m and broadcast VoteRequests
                    /\ DiscardAndSendAll(m,
                         {[mtype   |-> RequestVoteRequest,
                           mterm   |-> currentTerm'[i],
                           msource |-> i,
                           mdest   |-> j,
                           mlastLogTerm  |-> LastLogTerm(i),
                           mlastLogIndex |-> LastLogIndex(i),
                           mcommit      |-> commitIndex[i],
                           mcommitTerm  |-> LogTerm(i, commitIndex[i]),
                           mpriority    |-> priority[i]] : j \in AllVoters(i) \ {i}})
                    \* configVars split: pendingConfIndex set by BecomeCandidate, config/newConfig unchanged
                    /\ UNCHANGED <<logVars, leaderVars, config, newConfig, persistVars>>
               ELSE \* Not yet quorum — keep waiting
                    /\ Discard(m)
                    /\ UNCHANGED <<serverVars, logVars, leaderVars, votesGranted,
                                   leaseVars, transferVars, electionVars, configVars, persistVars>>
       ELSE \* PreVote rejected
            \* If rejected with higher term, become follower — handled in step() term check
            \* raft.rs:1387-1397: PreVoteResponse with reject=true means term was higher
            /\ IF m.mterm > currentTerm[i]
               THEN /\ BecomeFollower(i, m.mterm, Nil)
                    /\ Discard(m)
               ELSE \* Check if lost quorum — raft.rs:2278-2283
                    LET rejects == {j \in AllVoters(i) : j /= i /\ j \notin preVotesGranted[i]}
                    IN IF ~HasQuorum(i, rejects \union {m.msource})
                       THEN \* Not lost yet
                            /\ Discard(m)
                            /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                                           leaseVars, transferVars, electionVars, configVars, persistVars>>
                       ELSE \* Lost: become follower — raft.rs:2281-2282
                            /\ BecomeFollower(i, currentTerm[i], Nil)
                            /\ Discard(m)
            /\ UNCHANGED <<logVars, leaderVars, preVotesGranted, votesGranted,
                           configVars, persistVars>>

\* HandleRequestVoteRequest: raft.rs:1346-1529 (vote request handling)
\* Includes term handling and vote grant logic.
HandleRequestVoteRequest(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ \* Term handling — raft.rs:1347-1478
       IF m.mterm > currentTerm[i]
       THEN \* Higher term: step down (unless lease protection blocks it)
            \* Lease protection check — raft.rs:1354-1383
            LET force == FALSE  \* Regular vote (not transfer); CAMPAIGN_TRANSFER checked separately
                in_lease == leaderId[i] /= Nil
            IN
            IF ~force /\ in_lease
            THEN \* Reject: within lease — raft.rs:1382
                 /\ Reply([mtype    |-> RequestVoteResponse,
                           mterm    |-> currentTerm[i],
                           msource  |-> i,
                           mdest    |-> m.msource,
                           mreject  |-> TRUE,
                           mcommit  |-> commitIndex[i],
                           mcommitTerm |-> LogTerm(i, commitIndex[i])], m)
                 /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                                leaseVars, transferVars, electionVars, configVars, persistVars>>
            ELSE \* Not in lease: step down then evaluate vote — raft.rs:1412-1414
                 /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
                 /\ state' = [state EXCEPT ![i] = Follower]
                 /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
                 \* After step-down: votedFor=Nil, leaderId=Nil → canVote is always TRUE
                 \* Only LogUpToDate and priority determine grant
                 /\ LET grant ==
                           /\ LogUpToDate(m.mlastLogTerm, m.mlastLogIndex, LastLogTerm(i), LastLogIndex(i))
                           /\ (m.mlastLogIndex > LastLogIndex(i) \/ priority[i] <= m.mpriority)
                    IN
                    IF grant
                    THEN /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
                         /\ Reply([mtype    |-> RequestVoteResponse,
                                   mterm    |-> m.mterm,
                                   msource  |-> i,
                                   mdest    |-> m.msource,
                                   mreject  |-> FALSE,
                                   mcommit  |-> commitIndex[i],
                                   mcommitTerm |-> LogTerm(i, commitIndex[i])], m)
                    ELSE /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
                         /\ Reply([mtype    |-> RequestVoteResponse,
                                   mterm    |-> m.mterm,
                                   msource  |-> i,
                                   mdest    |-> m.msource,
                                   mreject  |-> TRUE,
                                   mcommit  |-> commitIndex[i],
                                   mcommitTerm |-> LogTerm(i, commitIndex[i])], m)
                 /\ UNCHANGED <<log, commitIndex, leaderVars, candidateVars,
                                leaseVars, transferVars, electionVars, configVars, persistVars>>
       ELSE IF m.mterm = currentTerm[i]
       THEN \* Same term: evaluate vote — raft.rs:1483-1529
            LET canVote ==
                    \* Can vote if: already voted for them, or haven't voted and no leader — raft.rs:1487-1491
                    \/ votedFor[i] = m.msource
                    \/ (votedFor[i] = Nil /\ leaderId[i] = Nil)
                grant ==
                    /\ canVote
                    /\ LogUpToDate(m.mlastLogTerm, m.mlastLogIndex, LastLogTerm(i), LastLogIndex(i))
                    /\ (m.mlastLogIndex > LastLogIndex(i) \/ priority[i] <= m.mpriority)
            IN
            IF grant
            THEN /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
                 /\ Reply([mtype    |-> RequestVoteResponse,
                           mterm    |-> m.mterm,
                           msource  |-> i,
                           mdest    |-> m.msource,
                           mreject  |-> FALSE,
                           mcommit  |-> commitIndex[i],
                           mcommitTerm |-> LogTerm(i, commitIndex[i])], m)
                 /\ UNCHANGED <<currentTerm, state, leaderId, log, commitIndex,
                                leaderVars, candidateVars,
                                leaseVars, transferVars, electionVars, configVars, persistVars>>
            ELSE /\ Reply([mtype    |-> RequestVoteResponse,
                           mterm    |-> currentTerm[i],
                           msource  |-> i,
                           mdest    |-> m.msource,
                           mreject  |-> TRUE,
                           mcommit  |-> commitIndex[i],
                           mcommitTerm |-> LogTerm(i, commitIndex[i])], m)
                 \* maybe_commit_by_vote on rejection — raft.rs:1527
                 /\ LET newCI == IF m.mcommit > 0 /\ m.mcommitTerm > 0
                                    /\ m.mcommit > commitIndex[i]
                                    /\ state[i] /= Leader
                                    /\ LogTerm(i, m.mcommit) = m.mcommitTerm
                                 THEN m.mcommit
                                 ELSE commitIndex[i]
                    IN commitIndex' = [commitIndex EXCEPT ![i] = newCI]
                 /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, log,
                                leaderVars, candidateVars,
                                leaseVars, transferVars, electionVars, configVars, persistVars>>
       ELSE \* Lower term: reject — raft.rs:1416-1478
            \* For pre-vote requests at lower term, respond with reject — raft.rs:1462-1465
            /\ Reply([mtype    |-> RequestVoteResponse,
                      mterm    |-> currentTerm[i],
                      msource  |-> i,
                      mdest    |-> m.msource,
                      mreject  |-> TRUE,
                      mcommit  |-> commitIndex[i],
                      mcommitTerm |-> LogTerm(i, commitIndex[i])], m)
            /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                           leaseVars, transferVars, electionVars, configVars, persistVars>>

\* HandleRequestVoteResponse: raft.rs:2316-2329 (step_candidate, Vote response)
HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ state[i] = Candidate
    \* Term check: higher term means step down — raft.rs:1350-1414
    /\ IF m.mterm > currentTerm[i]
       THEN /\ BecomeFollower(i, m.mterm, Nil)
            /\ Discard(m)
            /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars, persistVars>>
       ELSE IF m.mterm = currentTerm[i]
       THEN
            /\ IF ~m.mreject
               THEN \* Vote granted — raft.rs:2328 (poll)
                    /\ votesGranted' = [votesGranted EXCEPT ![i] = @ \union {m.msource}]
                    \* Check if won election — raft.rs:2269-2276
                    /\ IF HasQuorum(i, votesGranted'[i])
                       THEN \* Won: become leader — raft.rs:2273-2275
                            /\ BecomeLeader(i)
                            /\ UNCHANGED preVotesGranted
                            \* Broadcast AppendEntries — raft.rs:2275
                            \* Discard VoteResponse m and broadcast AppendEntries — raft.rs:2275
                            /\ DiscardAndSendAll(m,
                                 {[mtype        |-> AppendEntriesRequest,
                                   mterm        |-> currentTerm[i],
                                   msource      |-> i,
                                   mdest        |-> j,
                                   mprevLogIndex |-> nextIndex'[i][j] - 1,
                                   mprevLogTerm  |-> LogTerm(i, nextIndex'[i][j] - 1),
                                   mentries      |-> SubSeq(log'[i], nextIndex'[i][j], Len(log'[i])),
                                   mcommitIndex  |-> commitIndex[i]] : j \in AllVoters(i) \ {i}})
                       ELSE /\ Discard(m)
                            /\ UNCHANGED <<serverVars, logVars, leaderVars, preVotesGranted,
                                           leaseVars, transferVars, electionVars, configVars, persistVars>>
               ELSE \* Vote rejected
                    /\ Discard(m)
                    \* maybe_commit_by_vote — raft.rs:2329
                    /\ LET newCI == IF m.mcommit > 0 /\ m.mcommitTerm > 0
                                       /\ m.mcommit > commitIndex[i]
                                       /\ state[i] /= Leader
                                       /\ LogTerm(i, m.mcommit) = m.mcommitTerm
                                    THEN m.mcommit
                                    ELSE commitIndex[i]
                       IN commitIndex' = [commitIndex EXCEPT ![i] = newCI]
                    \* Check if lost — raft.rs:2278-2283
                    /\ LET rejects == AllVoters(i) \ (votesGranted[i] \union {m.msource})
                       IN IF HasQuorum(i, rejects)
                          THEN BecomeFollower(i, currentTerm[i], Nil)
                          ELSE UNCHANGED <<currentTerm, votedFor, state, leaderId,
                                           leaderVars, leaseVars, transferVars, electionVars,
                                           configVars, persistVars>>
                    /\ UNCHANGED <<log, preVotesGranted, votesGranted>>
       ELSE \* Stale response — discard
            /\ Discard(m)
            /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                           leaseVars, transferVars, electionVars, configVars, persistVars>>

----
\* Actions: Leader operations
----

\* ClientRequest: leader appends a new entry
\* Reference: raft.rs:2063-2143 (MsgPropose in step_leader)
ClientRequest(i) ==
    /\ state[i] = Leader
    /\ transferTarget[i] = Nil  \* raft.rs:2073 — reject if transfer in progress
    /\ i \in config[i]          \* raft.rs:2067 — must be in config
    /\ LET newEntry == [term |-> currentTerm[i], type |-> ValueEntry, value |-> 0]
           newLog == Append(log[i], newEntry)
       IN
       /\ log' = [log EXCEPT ![i] = newLog]
       \* Leader does NOT update own matchIndex here — raft.rs:1055
       \* matchIndex updated only after persist via on_persist_entries
       /\ UNCHANGED matchIndex
       /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |->
                            IF j = i THEN Len(newLog) + 1 ELSE nextIndex[i][j]]]
       \* Broadcast AppendEntries — raft.rs:2142
       /\ SendAll({[mtype        |-> AppendEntriesRequest,
                    mterm        |-> currentTerm[i],
                    msource      |-> i,
                    mdest        |-> j,
                    mprevLogIndex |-> nextIndex[i][j] - 1,
                    mprevLogTerm  |-> LogTerm(i, nextIndex[i][j] - 1),
                    mentries      |-> SubSeq(newLog, nextIndex[i][j], Len(newLog)),
                    mcommitIndex  |-> commitIndex[i]] : j \in AllVoters(i) \ {i}})
    /\ UNCHANGED <<serverVars, commitIndex, candidateVars,
                   leaseVars, transferVars, electionVars, configVars, persistVars>>

\* SendHeartbeat: leader sends heartbeat to a specific follower
\* Reference: raft.rs:919-935 (bcast_heartbeat)
SendHeartbeat(i, j) ==
    /\ state[i] = Leader
    /\ j /= i
    /\ j \in AllVoters(i)
    /\ Send([mtype        |-> HeartbeatRequest,
             mterm        |-> currentTerm[i],
             msource      |-> i,
             mdest        |-> j,
             mcommitIndex |-> Min(commitIndex[i], matchIndex[i][j])])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, transferVars, electionVars, configVars, persistVars>>

\* AdvanceCommitIndex: leader computes new commit index from quorum of matchIndex
\* Reference: raft.rs:939-950 (maybe_commit)
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET newCI == ComputeCommitIndex(i)
       IN /\ newCI > commitIndex[i]
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCI]
    /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, log,
                   leaderVars, candidateVars, messages,
                   leaseVars, transferVars, electionVars, configVars, persistVars>>

\* PersistEntries: models asynchronous persistence completing
\* Reference: raft.rs:1060-1082 (on_persist_entries)
\* Leader's own matchIndex advances when persist completes.
PersistEntries(i) ==
    /\ persisted[i] < LastLogIndex(i)
    /\ LET newPersisted == persisted[i] + 1
       IN
       /\ persisted' = [persisted EXCEPT ![i] = newPersisted]
       \* If leader, advance own matchIndex — raft.rs:1076-1078
       /\ IF state[i] = Leader
          THEN matchIndex' = [matchIndex EXCEPT ![i][i] = newPersisted]
          ELSE UNCHANGED matchIndex
    /\ UNCHANGED <<serverVars, logVars, log, candidateVars, messages,
                   leaseVars, transferVars, electionVars, configVars, nextIndex>>

----
\* Actions: Log Replication
----

\* HandleAppendEntriesRequest: raft.rs:2499-2558 (handle_append_entries)
\* Also includes follower step handling — raft.rs:2371-2377
HandleAppendEntriesRequest(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ IF m.mterm < currentTerm[i]
       THEN \* Stale leader: reject — raft.rs:1416-1443
            \* If check_quorum, send AppendResponse to help old leader — raft.rs:1442-1443
            /\ Reply([mtype    |-> AppendEntriesResponse,
                      mterm    |-> currentTerm[i],
                      msource  |-> i,
                      mdest    |-> m.msource,
                      mreject  |-> TRUE,
                      mindex   |-> 0,
                      mcommit  |-> commitIndex[i]], m)
            /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                           leaseVars, transferVars, electionVars, configVars, persistVars>>
       ELSE \* m.mterm >= currentTerm[i]
            \* Step down if needed — raft.rs:1407-1414
            /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
            /\ state' = [state EXCEPT ![i] = Follower]
            /\ leaderId' = [leaderId EXCEPT ![i] = m.msource]
            /\ votedFor' = [votedFor EXCEPT ![i] = IF m.mterm > currentTerm[i] THEN Nil ELSE votedFor[i]]
            \* Reset lease and transfer state on term change
            /\ leaseValid' = [leaseValid EXCEPT ![i] = FALSE]
            /\ readRequestPending' = [readRequestPending EXCEPT ![i] = FALSE]
            /\ readIndex' = [readIndex EXCEPT ![i] = 0]
            /\ transferTarget' = [transferTarget EXCEPT ![i] = Nil]
            /\ recentlyActive' = [recentlyActive EXCEPT ![i] = {}]
            \* Append entries — raft.rs:2499-2558
            /\ IF m.mprevLogIndex > 0 /\ m.mprevLogIndex <= LastLogIndex(i) /\ LogTerm(i, m.mprevLogIndex) /= m.mprevLogTerm
               THEN \* Log doesn't match at prevLogIndex: reject — raft.rs:2527-2555
                    /\ Reply([mtype    |-> AppendEntriesResponse,
                              mterm    |-> m.mterm,
                              msource  |-> i,
                              mdest    |-> m.msource,
                              mreject  |-> TRUE,
                              mindex   |-> m.mprevLogIndex,
                              mcommit  |-> commitIndex[i]], m)
                    /\ UNCHANGED <<log, commitIndex, leaderVars, persisted>>
               ELSE IF m.mprevLogIndex > LastLogIndex(i)
               THEN \* Missing entries: reject — raft.rs:2527
                    /\ Reply([mtype    |-> AppendEntriesResponse,
                              mterm    |-> m.mterm,
                              msource  |-> i,
                              mdest    |-> m.msource,
                              mreject  |-> TRUE,
                              mindex   |-> m.mprevLogIndex,
                              mcommit  |-> commitIndex[i]], m)
                    /\ UNCHANGED <<log, commitIndex, leaderVars, persisted>>
               ELSE \* Success: append — raft.rs:2522-2526
                    LET prevIdx == m.mprevLogIndex
                        existingEntries == SubSeq(log[i], 1, prevIdx)
                        newLog == existingEntries \o m.mentries
                        \* Truncation may decrease persisted — raft_log.rs:282-285
                        newPersisted == IF persisted[i] > prevIdx
                                           /\ Len(m.mentries) > 0
                                           /\ \E k \in 1..Len(m.mentries) :
                                              /\ prevIdx + k <= Len(log[i])
                                              /\ log[i][prevIdx + k].term /= m.mentries[k].term
                                        THEN Min(persisted[i], prevIdx)
                                        ELSE persisted[i]
                        lastNewIdx == prevIdx + Len(m.mentries)
                        newCI == Max(commitIndex[i], Min(m.mcommitIndex, lastNewIdx))
                    IN
                    /\ log' = [log EXCEPT ![i] = newLog]
                    /\ commitIndex' = [commitIndex EXCEPT ![i] = newCI]
                    /\ persisted' = [persisted EXCEPT ![i] = newPersisted]
                    /\ Reply([mtype    |-> AppendEntriesResponse,
                              mterm    |-> m.mterm,
                              msource  |-> i,
                              mdest    |-> m.msource,
                              mreject  |-> FALSE,
                              mindex   |-> lastNewIdx,
                              mcommit  |-> newCI], m)
                    /\ UNCHANGED leaderVars
            /\ UNCHANGED <<candidateVars, pendingConfIndex,
                           config, newConfig, priority>>

\* HandleAppendEntriesResponse: raft.rs:2188-2190, 1769-1863 (handle_append_response)
HandleAppendEntriesResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ m.mterm = currentTerm[i]
    /\ IF m.mreject
       THEN \* Rejected: decrease nextIndex — raft.rs:1769-1806
            /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] = Max(1, m.mindex)]
            /\ Discard(m)
            /\ UNCHANGED <<serverVars, logVars, matchIndex, candidateVars,
                           leaseVars, transferVars, electionVars, configVars, persistVars>>
       ELSE \* Accepted: update matchIndex and nextIndex — raft.rs:1808-1841
            \* maybe_update semantics (raft.rs:1828): only advance, never decrease
            /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] = Max(matchIndex[i][m.msource], m.mindex)]
            /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] = Max(nextIndex[i][m.msource], m.mindex + 1)]
            \* Mark follower as recently active
            /\ recentlyActive' = [recentlyActive EXCEPT ![i] = @ \union {m.msource}]
            \* Check if transfer target matched — raft.rs:1852-1863
            /\ IF transferTarget[i] = m.msource /\ m.mindex >= LastLogIndex(i)
               THEN \* Send MsgTimeoutNow — raft.rs:1861
                    /\ DiscardAndSendAll(m,
                         {[mtype   |-> TimeoutNowRequest,
                           mterm   |-> currentTerm[i],
                           msource |-> i,
                           mdest   |-> m.msource]})
               ELSE /\ Discard(m)
            /\ UNCHANGED <<serverVars, logVars, candidateVars,
                           leaseVars, transferTarget, priority, configVars, persistVars>>

----
\* Actions: Heartbeat
----

\* HandleHeartbeatRequest: raft.rs:2562-2573 (handle_heartbeat)
HandleHeartbeatRequest(i, m) ==
    /\ m.mtype = HeartbeatRequest
    /\ m.mdest = i
    /\ IF m.mterm < currentTerm[i]
       THEN \* Stale: respond to help leader step down — raft.rs:1442-1443
            /\ Reply([mtype    |-> AppendEntriesResponse,
                      mterm    |-> currentTerm[i],
                      msource  |-> i,
                      mdest    |-> m.msource,
                      mreject  |-> TRUE,
                      mindex   |-> 0,
                      mcommit  |-> commitIndex[i]], m)
            /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                           leaseVars, transferVars, electionVars, configVars, persistVars>>
       ELSE \* Accept heartbeat
            \* Step down if needed — raft.rs:1407-1414
            /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
            /\ state' = [state EXCEPT ![i] = Follower]
            /\ leaderId' = [leaderId EXCEPT ![i] = m.msource]
            /\ votedFor' = [votedFor EXCEPT ![i] = IF m.mterm > currentTerm[i] THEN Nil ELSE votedFor[i]]
            \* Commit to heartbeat's commit — raft.rs:2563
            /\ commitIndex' = [commitIndex EXCEPT ![i] = Max(commitIndex[i], Min(m.mcommitIndex, LastLogIndex(i)))]
            /\ Reply([mtype    |-> HeartbeatResponse,
                      mterm    |-> m.mterm,
                      msource  |-> i,
                      mdest    |-> m.msource,
                      mcommit  |-> commitIndex'[i]], m)
            /\ UNCHANGED <<log, leaderVars, candidateVars,
                           leaseVars, transferVars, electionVars, configVars, persistVars>>

\* HandleHeartbeatResponse: raft.rs:1866-1910 (handle_heartbeat_response)
HandleHeartbeatResponse(i, m) ==
    /\ m.mtype = HeartbeatResponse
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ m.mterm = currentTerm[i]
    /\ recentlyActive' = [recentlyActive EXCEPT ![i] = @ \union {m.msource}]
    /\ leaseValid' = [leaseValid EXCEPT ![i] = TRUE]  \* Heartbeat response confirms lease
    /\ Discard(m)
    /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, logVars, leaderVars,
                   candidateVars, readIndex, readRequestPending,
                   transferVars, priority, configVars, persistVars>>

----
\* Actions: CheckQuorum (Bug Family 2)
----

\* CheckQuorum: leader checks if quorum of followers are recently active
\* Reference: raft.rs:2052-2061 (MsgCheckQuorum in step_leader)
\* Reference: tracker.rs:336-351 (quorum_recently_active)
CheckQuorum(i) ==
    /\ state[i] = Leader
    /\ LET active == recentlyActive[i] \union {i}   \* self always active — tracker.rs:340-342
       IN IF HasQuorum(i, active)
          THEN \* Still have quorum: reset tracking, renew lease
               /\ recentlyActive' = [recentlyActive EXCEPT ![i] = {}]
               /\ leaseValid' = [leaseValid EXCEPT ![i] = TRUE]
               /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, logVars,
                              leaderVars, candidateVars, messages,
                              readIndex, readRequestPending, transferVars,
                              priority, configVars, persistVars>>
          ELSE \* Lost quorum: step down — raft.rs:2058-2059
               /\ BecomeFollower(i, currentTerm[i], Nil)
               /\ UNCHANGED <<logVars, leaderVars, candidateVars, messages,
                              configVars, persistVars>>

----
\* Actions: Leader Transfer (Bug Family 1)
----

\* TransferLeadership: leader begins transferring to target
\* Reference: raft.rs:1924-1978 (handle_transfer_leader)
TransferLeadership(i, j) ==
    /\ state[i] = Leader
    /\ j /= i
    /\ j \in AllVoters(i)
    /\ transferTarget[i] = Nil  \* Not already transferring
    /\ transferTarget' = [transferTarget EXCEPT ![i] = j]
    \* If target's log is up-to-date, send TimeoutNow immediately — raft.rs:1968-1969
    /\ IF matchIndex[i][j] >= LastLogIndex(i)
       THEN Send([mtype   |-> TimeoutNowRequest,
                  mterm   |-> currentTerm[i],
                  msource |-> i,
                  mdest   |-> j])
       ELSE UNCHANGED messages  \* Will send after log catches up — raft.rs:1976
    /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, logVars,
                   leaderVars, candidateVars,
                   leaseVars, electionVars, configVars, persistVars>>

\* AbortLeaderTransfer: transfer timeout — raft.rs:1129-1131
AbortLeaderTransfer(i) ==
    /\ state[i] = Leader
    /\ transferTarget[i] /= Nil
    /\ transferTarget' = [transferTarget EXCEPT ![i] = Nil]
    /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, logVars,
                   leaderVars, candidateVars, messages,
                   leaseVars, electionVars, configVars, persistVars>>

\* HandleTimeoutNowRequest: follower receives MsgTimeoutNow, campaigns immediately
\* Reference: raft.rs:2398-2418
\* Key: skips PreVote, uses CAMPAIGN_TRANSFER directly — raft.rs:2409-2410
HandleTimeoutNowRequest(i, m) ==
    /\ m.mtype = TimeoutNowRequest
    /\ m.mdest = i
    /\ state[i] = Follower
    /\ i \in config[i]  \* Must be promotable — raft.rs:2399
    \* Campaign with CAMPAIGN_TRANSFER (skip PreVote) — raft.rs:2410 (hup(true))
    \* This is CAMPAIGN_TRANSFER: raft.rs:1574-1575
    /\ BecomeCandidate(i)
    \* Self-vote included in BecomeCandidate
    \* Send vote requests with transfer context — raft.rs:1321-1323
    /\ DiscardAndSendAll(m,
         {[mtype   |-> RequestVoteRequest,
           mterm   |-> currentTerm'[i],
           msource |-> i,
           mdest   |-> j,
           mlastLogTerm  |-> LastLogTerm(i),
           mlastLogIndex |-> LastLogIndex(i),
           mcommit      |-> commitIndex[i],
           mcommitTerm  |-> LogTerm(i, commitIndex[i]),
           mpriority    |-> priority[i]] : j \in AllVoters(i) \ {i}})
    /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
    \* configVars split: pendingConfIndex set by BecomeCandidate
    /\ UNCHANGED <<logVars, leaderVars, config, newConfig, persistVars>>

----
\* Actions: ReadIndex / Lease-based reads (Bug Family 1)
----

\* ProposeReadIndex: leader receives ReadIndex request (Safe mode)
\* Reference: raft.rs:2145-2184 (step_leader, MsgReadIndex)
\* Requires: committed in current term — raft.rs:2146
ProposeReadIndex(i) ==
    /\ state[i] = Leader
    /\ CommitToCurrentTerm(i)  \* raft.rs:2146
    /\ readRequestPending' = [readRequestPending EXCEPT ![i] = TRUE]
    /\ readIndex' = [readIndex EXCEPT ![i] = commitIndex[i]]
    \* In Safe mode, broadcasts heartbeat for confirmation — raft.rs:2169-2174
    /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, logVars,
                   leaderVars, candidateVars, messages,
                   leaseValid, transferVars, electionVars, configVars, persistVars>>

\* ConfirmReadIndex: heartbeat quorum received, read can be served
\* This abstracts the read_only.recv_ack + has_quorum check — raft.rs:1898-1899
ConfirmReadIndex(i) ==
    /\ state[i] = Leader
    /\ readRequestPending[i] = TRUE
    /\ leaseValid[i] = TRUE    \* Heartbeat responses received (quorum confirmed)
    /\ readRequestPending' = [readRequestPending EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, logVars,
                   leaderVars, candidateVars, messages,
                   readIndex, leaseValid, transferVars, electionVars, configVars, persistVars>>

\* ServeLeaseBasedRead: leader serves read immediately in LeaseBased mode
\* Reference: raft.rs:2176-2181 (LeaseBased branch)
\* Key risk: if lease is stale (e.g., after transfer), read may be stale
ServeLeaseBasedRead(i) ==
    /\ state[i] = Leader
    /\ CommitToCurrentTerm(i)
    /\ readIndex' = [readIndex EXCEPT ![i] = commitIndex[i]]
    /\ UNCHANGED <<currentTerm, votedFor, state, leaderId, logVars,
                   leaderVars, candidateVars, messages,
                   leaseValid, readRequestPending, transferVars, electionVars, configVars, persistVars>>

----
\* Actions: Configuration Change (Bug Family 3)
----

\* ProposeConfChange: leader proposes a configuration change
\* Reference: raft.rs:2083-2131 (conf change validation)
ProposeConfChange(i, newVoters) ==
    /\ state[i] = Leader
    /\ transferTarget[i] = Nil  \* raft.rs:2073
    /\ i \in config[i]          \* raft.rs:2067
    /\ ~InJoint(i)              \* raft.rs:2108 — can't add change in joint state
    /\ pendingConfIndex[i] <= commitIndex[i]  \* raft.rs:2103 — no pending conf change
    /\ newVoters /= config[i]   \* Actual change
    /\ LET newEntry == [term |-> currentTerm[i], type |-> ConfigEntry, value |-> 0]
           newLog == Append(log[i], newEntry)
       IN
       /\ log' = [log EXCEPT ![i] = newLog]
       /\ pendingConfIndex' = [pendingConfIndex EXCEPT ![i] = Len(newLog)]
       /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |->
                            IF j = i THEN Len(newLog) + 1 ELSE nextIndex[i][j]]]
       \* Enter joint consensus — raft.rs:2809-2810 (enter_joint)
       /\ newConfig' = [newConfig EXCEPT ![i] = config[i]]  \* outgoing = old config
       /\ config' = [config EXCEPT ![i] = newVoters]         \* incoming = new config
       \* Broadcast
       /\ SendAll({[mtype        |-> AppendEntriesRequest,
                    mterm        |-> currentTerm[i],
                    msource      |-> i,
                    mdest        |-> j,
                    mprevLogIndex |-> nextIndex[i][j] - 1,
                    mprevLogTerm  |-> LogTerm(i, nextIndex[i][j] - 1),
                    mentries      |-> SubSeq(newLog, nextIndex[i][j], Len(newLog)),
                    mcommitIndex  |-> commitIndex[i]] : j \in (newVoters \union config[i]) \ {i}})
    /\ UNCHANGED <<serverVars, commitIndex, matchIndex, candidateVars,
                   leaseVars, transferVars, electionVars, persistVars>>

\* ApplyConfChange: server applies a committed config change entry
\* Reference: raft.rs:2805-2817 (apply_conf_change)
ApplyConfChange(i) ==
    /\ \E idx \in 1..commitIndex[i] :
        /\ log[i][idx].type = ConfigEntry
        /\ idx > pendingConfIndex[i] \/ pendingConfIndex[i] = 0
    /\ UNCHANGED vars  \* Placeholder — actual config application is complex

\* AutoLeaveJoint: leader proposes leave-joint after enter-joint is applied
\* Reference: raft.rs:984-1004 (auto_leave in commit_apply)
\* Condition: in joint state AND pending conf change has been applied (committed >= pendingConfIndex)
AutoLeaveJoint(i) ==
    /\ state[i] = Leader
    /\ InJoint(i)  \* raft.rs:985 (auto_leave)
    /\ commitIndex[i] >= pendingConfIndex[i]  \* raft.rs:987 (applied >= pending)
    /\ LET newEntry == [term |-> currentTerm[i], type |-> ConfigEntry, value |-> 0]
           newLog == Append(log[i], newEntry)
       IN
       /\ log' = [log EXCEPT ![i] = newLog]
       /\ pendingConfIndex' = [pendingConfIndex EXCEPT ![i] = Len(newLog)]
       /\ newConfig' = [newConfig EXCEPT ![i] = Nil]  \* Leave joint: clear outgoing
       /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |->
                            IF j = i THEN Len(newLog) + 1 ELSE nextIndex[i][j]]]
       /\ SendAll({[mtype        |-> AppendEntriesRequest,
                    mterm        |-> currentTerm[i],
                    msource      |-> i,
                    mdest        |-> j,
                    mprevLogIndex |-> nextIndex[i][j] - 1,
                    mprevLogTerm  |-> LogTerm(i, nextIndex[i][j] - 1),
                    mentries      |-> SubSeq(newLog, nextIndex[i][j], Len(newLog)),
                    mcommitIndex  |-> commitIndex[i]] : j \in AllVoters(i) \ {i}})
    /\ UNCHANGED <<serverVars, commitIndex, matchIndex, candidateVars,
                   config, leaseVars, transferVars, electionVars, persistVars>>

----
\* Actions: Crash and Recovery (Bug Family 4)
----

\* Crash: server crashes and restarts with persisted state
\* Reference: raft.rs:1148-1168 (become_follower on restart)
\* Volatile state is lost; persistent state (term, votedFor, log) restored from disk.
\* Entries after persisted index are lost.
Crash(i) ==
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
    \* Restore to persisted state
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i]]  \* term is persisted
    /\ votedFor' = [votedFor EXCEPT ![i] = votedFor[i]]            \* votedFor is persisted
    \* Truncate log to persisted entries — entries after persisted are lost
    /\ log' = [log EXCEPT ![i] = SubSeq(log[i], 1, persisted[i])]
    \* Volatile state reset
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
    /\ readIndex' = [readIndex EXCEPT ![i] = 0]
    /\ leaseValid' = [leaseValid EXCEPT ![i] = FALSE]
    /\ readRequestPending' = [readRequestPending EXCEPT ![i] = FALSE]
    /\ transferTarget' = [transferTarget EXCEPT ![i] = Nil]
    /\ recentlyActive' = [recentlyActive EXCEPT ![i] = {}]
    /\ pendingConfIndex' = [pendingConfIndex EXCEPT ![i] = 0]
    \* persisted stays the same (it's the source of truth)
    /\ UNCHANGED <<messages, config, newConfig, persisted, priority>>

----
\* Actions: Network Faults
----

\* LoseMessage: message is lost from the network
LoseMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, transferVars, electionVars, configVars, persistVars>>

\* DropStaleMessage: discard message with stale term
DropStaleMessage(m) ==
    /\ m.mterm < currentTerm[m.mdest]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, transferVars, electionVars, configVars, persistVars>>

----
\* Init and Next
----

Init ==
    /\ currentTerm      = [s \in Server |-> 0]
    /\ votedFor          = [s \in Server |-> Nil]
    /\ log               = [s \in Server |-> <<>>]
    /\ state             = [s \in Server |-> Follower]
    /\ commitIndex       = [s \in Server |-> 0]
    /\ leaderId          = [s \in Server |-> Nil]
    /\ nextIndex         = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex        = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted      = [s \in Server |-> {}]
    /\ preVotesGranted   = [s \in Server |-> {}]
    /\ messages          = EmptyBag
    /\ readIndex         = [s \in Server |-> 0]
    /\ leaseValid        = [s \in Server |-> FALSE]
    /\ readRequestPending = [s \in Server |-> FALSE]
    /\ transferTarget    = [s \in Server |-> Nil]
    /\ recentlyActive    = [s \in Server |-> {}]
    /\ priority          = [s \in Server |-> 1]   \* Default priority = 1
    /\ config            = [s \in Server |-> Server]
    /\ newConfig         = [s \in Server |-> Nil]
    /\ pendingConfIndex  = [s \in Server |-> 0]
    /\ persisted         = [s \in Server |-> 0]

Next ==
    \* Per-server actions
    \/ \E i \in Server :
        \/ Timeout(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ AdvanceCommitIndex(i)
        \/ PersistEntries(i)
        \/ CheckQuorum(i)
        \/ ProposeReadIndex(i)
        \/ ConfirmReadIndex(i)
        \/ ServeLeaseBasedRead(i)
        \/ AbortLeaderTransfer(i)
        \/ AutoLeaveJoint(i)
        \/ Crash(i)
    \* Two-server actions
    \/ \E i, j \in Server :
        \/ SendHeartbeat(i, j)
        \/ TransferLeadership(i, j)
    \* Config change actions (bounded set of new configs)
    \/ \E i \in Server :
        \E S \in SUBSET Server :
            /\ S /= {}
            /\ ProposeConfChange(i, S)
    \* Message handlers
    \/ \E m \in DOMAIN messages :
        \/ HandleRequestPreVoteRequest(m.mdest, m)
        \/ HandleRequestPreVoteResponse(m.mdest, m)
        \/ HandleRequestVoteRequest(m.mdest, m)
        \/ HandleRequestVoteResponse(m.mdest, m)
        \/ HandleAppendEntriesRequest(m.mdest, m)
        \/ HandleAppendEntriesResponse(m.mdest, m)
        \/ HandleHeartbeatRequest(m.mdest, m)
        \/ HandleHeartbeatResponse(m.mdest, m)
        \/ HandleTimeoutNowRequest(m.mdest, m)
        \/ LoseMessage(m)
        \/ DropStaleMessage(m)

Spec == Init /\ [][Next]_vars

----
\* Invariants
----

\* ===== STANDARD SAFETY PROPERTIES =====

\* ElectionSafety: at most one leader per term
ElectionSafety ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ state[s2] = Leader /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* LogMatching: if two logs have entries with same term at same index,
\* all preceding entries are identical.
LogMatching ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(LastLogIndex(s1), LastLogIndex(s2)) :
            LogTerm(s1, idx) = LogTerm(s2, idx) =>
                \A k \in 1..idx : LogTerm(s1, k) = LogTerm(s2, k)

\* LeaderCompleteness: committed entries appear in all future leaders' logs
\* A leader must have all entries committed by previous leaders.
LeaderCompleteness ==
    \A leader \in Server :
        state[leader] = Leader =>
            \A s \in Server :
                \A idx \in 1..commitIndex[s] :
                    /\ idx <= LastLogIndex(leader)
                    /\ LogTerm(leader, idx) = LogTerm(s, idx)

\* ===== STRUCTURAL INVARIANTS =====

\* CommitIndex never exceeds log length
CommitIndexBoundInv ==
    \A i \in Server : commitIndex[i] <= LastLogIndex(i)

\* Persisted index never exceeds log length
PersistedBoundInv ==
    \A i \in Server : persisted[i] <= LastLogIndex(i)

\* At most one pending conf change per server
SinglePendingConfInv ==
    \A i \in Server : pendingConfIndex[i] <= LastLogIndex(i)

\* Only leaders can have non-empty recentlyActive or transferTarget
LeaderOnlyFieldsInv ==
    \A i \in Server :
        state[i] /= Leader =>
            /\ recentlyActive[i] = {}
            /\ transferTarget[i] = Nil

\* VotedFor consistency: if votedFor is set, it must match some server
VotedForConsistencyInv ==
    \A i \in Server : votedFor[i] /= Nil => votedFor[i] \in Server

\* ===== EXTENSION INVARIANTS (Bug Family targets — commented out in MC.cfg) =====

\* LeaseLinearizability (Bug Family 1):
\* If a read is served via lease (readIndex > 0 on a leader), no other leader
\* at a higher term has committed entries that would make the read stale.
\* Specifically: if leader L1 serves readIndex=R at term T1, no leader L2
\* at term T2 > T1 should have commitIndex >= R before L1 serves the read.
LeaseLinearizability ==
    \A s1, s2 \in Server :
        /\ state[s1] = Leader
        /\ state[s2] = Leader
        /\ s1 /= s2
        /\ readIndex[s1] > 0
        => currentTerm[s1] /= currentTerm[s2]

\* NoStaleReadAfterTransfer (Bug Family 1):
\* After a leader starts transfer, it should not serve new reads.
NoStaleReadAfterTransfer ==
    \A i \in Server :
        (state[i] = Leader /\ transferTarget[i] /= Nil)
        => readIndex[i] = 0

\* AsyncPersistSafety (Bug Family 4):
\* Leader's own matchIndex should never exceed persisted.
\* This ensures the leader can't count its own unpersisted entries toward commit.
\* Reference: raft.rs:1033 (pr.matched = persisted for leader's self)
AsyncPersistSafety ==
    \A i \in Server :
        state[i] = Leader => matchIndex[i][i] <= persisted[i]

\* CrashRecoverySafety (Bug Family 4):
\* All entries up to commitIndex on any server must be persisted on a quorum.
\* (This is the safety argument for async persistence.)
CrashRecoverySafety ==
    \A i \in Server :
        \A idx \in 1..commitIndex[i] :
            LET persisted_on == {s \in Server : persisted[s] >= idx /\ LogTerm(s, idx) = LogTerm(i, idx)}
            IN HasQuorum(i, persisted_on)

\* CommitByVoteSafety (Bug Family 3):
\* Commit fast-forward via vote messages should not commit incorrect entries.
\* Specifically: committed entries must have matching terms.
CommitByVoteSafety ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(commitIndex[s1], commitIndex[s2]) :
            LogTerm(s1, idx) = LogTerm(s2, idx)

\* PreVoteSafety (Bug Family 2):
\* A PreCandidate should not disrupt a stable leader — specifically,
\* a PreCandidate should not have a term higher than any active leader.
\* (PreVote uses term+1 in messages, but the node's actual term doesn't change.)
PreVoteSafety ==
    \A i \in Server :
        state[i] = PreCandidate =>
            \A j \in Server :
                state[j] = Leader => currentTerm[j] >= currentTerm[i]

\* ConfChangeSafety (Bug Family 3):
\* At most one uncommitted conf change at a time per server.
ConfChangeSafety ==
    \A i \in Server :
        (pendingConfIndex[i] > 0 /\ pendingConfIndex[i] > commitIndex[i])
        => ~\E idx \in (commitIndex[i]+1)..(pendingConfIndex[i]-1) :
              log[i][idx].type = ConfigEntry

====
