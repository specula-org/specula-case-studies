---------------------------- MODULE base ----------------------------
\* TLA+ specification of datafuselabs/openraft Raft consensus protocol.
\*
\* Extends standard Raft with openraft-specific behaviors:
\*   1. Committed-vote leader identity: Vote includes committed flag;
\*      committed vote for self = established leader (Bug Family 1)
\*   2. Leader lease: followers reject VoteRequest while lease active,
\*      deviating from standard Raft (Bug Family 1)
\*   3. Snapshot + log interaction: crash windows between truncate/install/purge
\*      (Bug Family 2)
\*   4. Heartbeat with per-follower matching log ID (Bug Family 3)
\*   5. Joint consensus: two-step membership change with joint quorum
\*      (Bug Family 4)
\*   6. Crash/recovery with leader survival across restart (Bug Family 5)

EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs (subset of Nat for vote ordering)

CONSTANTS Follower,          \* Server states
          Candidate,
          Leader

CONSTANT Nil                 \* Null value

CONSTANTS ValueEntry,        \* Log entry types
          ConfigEntry,
          BlankEntry          \* Leader blank log (engine_impl.rs:671)

CONSTANTS VoteRequest,       \* Message types
          VoteResponse,
          AppendEntriesRequest,
          AppendEntriesResponse,
          InstallSnapshotRequest,
          InstallSnapshotResponse

----
\* Variables
----

\* Per-server persistent state (survives restart via SaveVote / log store)
\* Reference: vote/vote.rs:18-26 — Vote struct {leader_id, committed}
VARIABLE currentTerm         \* [Server -> Nat] — term from vote
VARIABLE votedFor            \* [Server -> Server \cup {Nil}] — node voted for
VARIABLE log                 \* [Server -> Seq(Entry)]

\* Extension 1: Committed-vote leader identity (Bug Family 1)
\* Reference: vote/vote.rs:22 — committed: bool
\* A committed vote for self = established leader (raft_state/mod.rs:464-466)
VARIABLE voteCommitted       \* [Server -> BOOLEAN]

\* Per-server volatile state
VARIABLE state               \* [Server -> {Follower, Candidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat]

\* Extension 1: Leader lease (Bug Family 1)
\* Reference: utime.rs:148-150 — is_expired check
\* Followers reject VoteRequest while lease active (engine_impl.rs:251-260)
VARIABLE leaseActive         \* [Server -> BOOLEAN]

\* Candidate state
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Leader volatile state
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension 2: Snapshot + purge (Bug Family 2)
\* Reference: raft_state/mod.rs:76 — snapshot_meta
\*            raft_state/mod.rs:92 — purge_upto
VARIABLE snapshot            \* [Server -> [lastIndex |-> Nat, lastTerm |-> Nat]]
VARIABLE purgedUpTo          \* [Server -> Nat]

\* Extension 4: Joint consensus (Bug Family 4)
\* Reference: membership/membership.rs:20-44 — configs: Vec<BTreeSet<NID>>
\* Length 1 = uniform config, Length 2 = joint config
VARIABLE config              \* [Server -> Seq(SUBSET Server)]

\* Extension 5: Crash/recovery (Bug Family 5)
\* Reference: helper.rs:88-225 — get_initial_state recovery
VARIABLE crashed             \* [Server -> BOOLEAN]

----
\* Variable groups
----

serverVars    == <<currentTerm, votedFor, voteCommitted, state>>
logVars       == <<log, commitIndex>>
leaderVars    == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted>>
snapshotVars  == <<snapshot, purgedUpTo>>
configVars    == <<config>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          snapshotVars, configVars, leaseActive, crashed>>

----
\* Helpers
----

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b

SetMax(S) == CHOOSE x \in S : \A y \in S : x >= y

\* Log helpers — log[s] stores entries from purgedUpTo[s]+1 onward
\* Reference: raft_state/mod.rs:287-294 — extend_log_ids
LastLogIndex(i) == Len(log[i]) + purgedUpTo[i]

LastLogTerm(i)  ==
    IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term
    ELSE IF purgedUpTo[i] > 0 THEN snapshot[i].lastTerm
    ELSE 0

LogTerm(i, idx) ==
    IF idx = 0 THEN 0
    ELSE IF idx > LastLogIndex(i) THEN 0
    ELSE IF idx <= purgedUpTo[i] THEN
        IF idx = snapshot[i].lastIndex THEN snapshot[i].lastTerm
        ELSE 0
    ELSE log[i][idx - purgedUpTo[i]].term

HasLogAt(i, idx) == idx > purgedUpTo[i] /\ idx <= LastLogIndex(i)

\* Vote comparison (Bug Family 1)
\* Reference: vote/vote.rs:32-36 — Vote::partial_cmp via RefVote
\* Order: term first, then node_id (Nat), then committed (true > false)
\* Server IDs must be Nat for this ordering to work.
LocalVoteNode(i) == IF votedFor[i] = Nil THEN 0 ELSE votedFor[i]

VoteGEQ(t1, n1, c1, t2, n2, c2) ==
    \/ t1 > t2
    \/ (t1 = t2 /\ n1 > n2)
    \/ (t1 = t2 /\ n1 = n2 /\ (c1 \/ ~c2))

VoteGT(t1, n1, c1, t2, n2, c2) ==
    VoteGEQ(t1, n1, c1, t2, n2, c2) /\ ~(t1 = t2 /\ n1 = n2 /\ c1 = c2)

\* Quorum check: majority of voters
\* Reference: quorum/joint.rs:97-104 — all configs must have quorum
IsQuorum(S, voters) == Cardinality(S) * 2 > Cardinality(voters)

\* Joint quorum: majority in ALL sub-configs
JointQuorumCheck(S, cfgs) ==
    \A k \in 1..Len(cfgs) : IsQuorum(S \cap cfgs[k], cfgs[k])

\* Effective voters: union of all configs
EffectiveVoters(cfgs) == UNION {cfgs[k] : k \in 1..Len(cfgs)}

\* Is server a voter in current config?
IsVoter(i) == i \in EffectiveVoters(config[i])

\* Log up-to-date comparison
\* Reference: engine_impl.rs:265 — req.last_log_id >= my_last_log_id
LogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    \/ cLastTerm > vLastTerm
    \/ (cLastTerm = vLastTerm /\ cLastIdx >= vLastIdx)

\* Message bag helpers
Send(m)    == messages' = messages (+) SetToBag({m})
SendAll(ms) == messages' = messages (+) SetToBag(ms)
Discard(m) == messages' = messages (-) SetToBag({m})
Reply(resp, req) ==
    messages' = (messages (-) SetToBag({req})) (+) SetToBag({resp})

\* At most one uncommitted membership in log (Bug Family 4)
\* Reference: change_handler.rs:54-67 — ensure_committed guard
HasUncommittedMembership(i) ==
    \E k \in 1..Len(log[i]) :
        /\ (k + purgedUpTo[i]) > commitIndex[i]
        /\ log[i][k].type = ConfigEntry

----
\* Init
----

Init ==
    /\ currentTerm    = [s \in Server |-> 0]
    /\ votedFor       = [s \in Server |-> Nil]
    /\ voteCommitted  = [s \in Server |-> FALSE]
    /\ log            = [s \in Server |-> <<>>]
    /\ state          = [s \in Server |-> Follower]
    /\ commitIndex    = [s \in Server |-> 0]
    /\ leaseActive    = [s \in Server |-> FALSE]
    /\ votesGranted   = [s \in Server |-> {}]
    /\ nextIndex      = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex     = [s \in Server |-> [t \in Server |-> 0]]
    /\ messages       = EmptyBag
    /\ snapshot       = [s \in Server |-> [lastIndex |-> 0, lastTerm |-> 0]]
    /\ purgedUpTo     = [s \in Server |-> 0]
    /\ config         = [s \in Server |-> <<Server>>]
    /\ crashed        = [s \in Server |-> FALSE]

----
\* Election Actions (Bug Family 1)
\*
\* openraft uses committed-vote as leader identity:
\*   - Uncommitted vote for self = candidate
\*   - Committed vote for self = established leader
\* Vote comparison uses (term, node_id, committed) total ordering.
----

\* Server i starts election.
\* Reference: engine_impl.rs:200-220 (elect)
Elect(i) ==
    /\ ~crashed[i]
    /\ state[i] \in {Follower, Candidate}
    /\ IsVoter(i)
    /\ LET newTerm == currentTerm[i] + 1
       IN
       \* engine_impl.rs:201 — next term
       /\ currentTerm'   = [currentTerm EXCEPT ![i] = newTerm]
       \* engine_impl.rs:203 — vote for self (uncommitted)
       /\ votedFor'      = [votedFor EXCEPT ![i] = i]
       /\ voteCommitted' = [voteCommitted EXCEPT ![i] = FALSE]
       /\ state'         = [state EXCEPT ![i] = Candidate]
       \* engine_impl.rs:205 — candidate state with self-vote
       /\ votesGranted'  = [votesGranted EXCEPT ![i] = {i}]
       \* engine_impl.rs:215-217 — send VoteRequest to all voters
       /\ SendAll({[mtype        |-> VoteRequest,
                    mterm        |-> newTerm,
                    mlastLogTerm |-> LastLogTerm(i),
                    mlastLogIndex |-> LastLogIndex(i),
                    msource      |-> i,
                    mdest        |-> j] : j \in EffectiveVoters(config[i]) \ {i}})
    /\ UNCHANGED <<logVars, leaderVars, snapshotVars, configVars,
                   leaseActive, crashed>>

\* Server i handles VoteRequest m.
\* Reference: engine_impl.rs:239-290 (handle_vote_req)
HandleVoteRequest(i, m) ==
    /\ ~crashed[i]
    /\ m.mtype = VoteRequest
    /\ m.mdest = i
    /\ LET myLastTerm == LastLogTerm(i)
           myLastIdx  == LastLogIndex(i)
           logOk      == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                     myLastTerm, myLastIdx)
           \* vote_handler/mod.rs:108 — vote >= state.vote
           voteOk     == VoteGEQ(m.mterm, m.msource, FALSE,
                                 currentTerm[i], LocalVoteNode(i),
                                 voteCommitted[i])
       IN
       \/ \* Reject: lease active + committed vote (Bug Family 1)
          \* Reference: engine_impl.rs:251-260
          \* If current vote is committed (we have a leader) and lease not expired
          /\ voteCommitted[i]
          /\ leaseActive[i]
          /\ Reply([mtype        |-> VoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    mlastLogTerm |-> myLastTerm,
                    mlastLogIndex |-> myLastIdx,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>

       \/ \* Reject: log not up-to-date
          \* Reference: engine_impl.rs:265-279
          /\ ~(voteCommitted[i] /\ leaseActive[i])
          /\ ~logOk
          /\ Reply([mtype        |-> VoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    mlastLogTerm |-> myLastTerm,
                    mlastLogIndex |-> myLastIdx,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>

       \/ \* Grant: log OK, vote OK
          \* Reference: engine_impl.rs:283 — vote_handler().update_vote()
          /\ ~(voteCommitted[i] /\ leaseActive[i])
          /\ logOk
          /\ voteOk
          \* vote_handler/mod.rs:130-138 — update vote
          /\ currentTerm'   = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor'      = [votedFor EXCEPT ![i] = m.msource]
          /\ voteCommitted' = [voteCommitted EXCEPT ![i] = FALSE]
          \* vote_handler/mod.rs:152-160 — update_internal_server_state
          /\ state'         = [state EXCEPT ![i] = Follower]
          /\ leaseActive'   = [leaseActive EXCEPT ![i] = TRUE]
          /\ votesGranted'  = [votesGranted EXCEPT ![i] = {}]
          /\ Reply([mtype        |-> VoteResponse,
                    mterm        |-> m.mterm,
                    mvoteGranted |-> TRUE,
                    mlastLogTerm |-> myLastTerm,
                    mlastLogIndex |-> myLastIdx,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, snapshotVars, configVars, crashed>>

       \/ \* Reject: log OK but vote too low
          \* Reference: vote_handler/mod.rs:110-115
          /\ ~(voteCommitted[i] /\ leaseActive[i])
          /\ logOk
          /\ ~voteOk
          /\ Reply([mtype        |-> VoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    mlastLogTerm |-> myLastTerm,
                    mlastLogIndex |-> myLastIdx,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>

\* Server i (candidate) handles VoteResponse m.
\* Reference: engine_impl.rs:293-352 (handle_vote_resp)
HandleVoteResponse(i, m) ==
    /\ ~crashed[i]
    /\ m.mtype = VoteResponse
    /\ m.mdest = i
    /\ state[i] = Candidate
    \* engine_impl.rs:303-307 — guard: must have candidate state
    /\ \/ \* Granted and vote matches candidate's term: count vote
          \* Reference: engine_impl.rs:310-314
          /\ m.mvoteGranted
          /\ m.mterm = currentTerm[i]
          /\ votesGranted' = [votesGranted EXCEPT ![i] = @ \cup {m.msource}]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars,
                         snapshotVars, configVars, leaseActive, crashed>>

       \/ \* Higher vote in response: step down
          \* Reference: engine_impl.rs:348 — convert to non-committed
          /\ VoteGT(m.mterm, m.msource, FALSE,
                    currentTerm[i], LocalVoteNode(i), voteCommitted[i])
          /\ currentTerm'   = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor'      = [votedFor EXCEPT ![i] = m.msource]
          /\ voteCommitted' = [voteCommitted EXCEPT ![i] = FALSE]
          /\ state'         = [state EXCEPT ![i] = Follower]
          /\ leaseActive'   = [leaseActive EXCEPT ![i] = TRUE]
          /\ votesGranted'  = [votesGranted EXCEPT ![i] = {}]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, snapshotVars, configVars, crashed>>

       \/ \* Not granted, no higher vote: discard
          /\ ~m.mvoteGranted
          /\ ~VoteGT(m.mterm, m.msource, FALSE,
                     currentTerm[i], LocalVoteNode(i), voteCommitted[i])
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>

\* Candidate i has quorum, transitions to leader.
\* Reference: engine_impl.rs:646-672 (establish_leader)
\* Commits vote, appends blank log, initializes replication.
EstablishLeader(i) ==
    /\ ~crashed[i]
    /\ state[i] = Candidate
    \* Quorum reached in joint config
    /\ JointQuorumCheck(votesGranted[i], config[i])
    /\ LET blankIdx == LastLogIndex(i) + 1
       IN
       \* engine_impl.rs:663 — commit the vote (vote_handler update_vote)
       /\ voteCommitted' = [voteCommitted EXCEPT ![i] = TRUE]
       /\ state'         = [state EXCEPT ![i] = Leader]
       \* engine_impl.rs:671 — append blank log entry (noop)
       /\ log' = [log EXCEPT ![i] = Append(@, [term  |-> currentTerm[i],
                                                type  |-> BlankEntry,
                                                value |-> Nil])]
       \* vote_handler/mod.rs:199-226 — initialize leader state
       /\ nextIndex'  = [nextIndex EXCEPT ![i] =
                         [j \in Server |-> blankIdx + 1]]
       /\ matchIndex' = [matchIndex EXCEPT ![i] =
                         [j \in Server |-> IF j = i THEN blankIdx ELSE 0]]
    /\ UNCHANGED <<currentTerm, votedFor, commitIndex, messages,
                   candidateVars, snapshotVars, configVars, leaseActive, crashed>>

----
\* Log Replication Actions (Bug Family 3)
\*
\* Bug Family 3: heartbeat uses per-follower matchIndex as prev_log_id.
\* Historical bug 2bdfae5d: used committed log ID instead.
\* Historical bug 54ffb00d: ignored heartbeat conflict responses.
----

\* Leader i appends client value entry.
\* Reference: leader_handler/mod.rs:56-102 (leader_append_entries)
ClientRequest(i) ==
    /\ ~crashed[i]
    /\ state[i] = Leader
    /\ LET entry  == [term  |-> currentTerm[i],
                      type  |-> ValueEntry,
                      value |-> Nil]
           newIdx == LastLogIndex(i) + 1
       IN
       /\ log' = [log EXCEPT ![i] = Append(@, entry)]
       \* leader_handler/mod.rs:78-81 — update local progress
       /\ matchIndex' = [matchIndex EXCEPT ![i][i] = newIdx]
       /\ nextIndex'  = [nextIndex EXCEPT ![i][i] = newIdx + 1]
    /\ UNCHANGED <<serverVars, commitIndex, candidateVars, messages,
                   snapshotVars, configVars, leaseActive, crashed>>

\* Leader i sends heartbeat to all followers.
\* Bug Family 3: uses per-follower matchIndex[i][j] as prev_log_id
\* Reference: leader_handler/mod.rs:105-110 (send_heartbeat)
SendHeartbeat(i) ==
    /\ ~crashed[i]
    /\ state[i] = Leader
    /\ SendAll({[mtype         |-> AppendEntriesRequest,
                 mterm         |-> currentTerm[i],
                 mprevLogIndex |-> matchIndex[i][j],
                 mprevLogTerm  |-> LogTerm(i, matchIndex[i][j]),
                 mentries      |-> <<>>,
                 mcommitIndex  |-> commitIndex[i],
                 msource       |-> i,
                 mdest         |-> j] : j \in EffectiveVoters(config[i]) \ {i}})
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   snapshotVars, configVars, leaseActive, crashed>>

\* Leader i replicates entries to follower j.
\* Reference: replication_handler/mod.rs:347-406 (send_to_target)
ReplicateEntries(i, j) ==
    /\ ~crashed[i]
    /\ state[i] = Leader
    /\ j # i
    /\ j \in EffectiveVoters(config[i])
    \* Can send entries (not purged); else must send snapshot
    /\ nextIndex[i][j] > purgedUpTo[i]
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == LogTerm(i, prevIdx)
           lastIdx  == LastLogIndex(i)
           \* Send entries from nextIndex to end of log
           entries == IF nextIndex[i][j] > lastIdx
                      THEN <<>>
                      ELSE SubSeq(log[i], nextIndex[i][j] - purgedUpTo[i],
                                          lastIdx - purgedUpTo[i])
       IN
       /\ Send([mtype         |-> AppendEntriesRequest,
                mterm         |-> currentTerm[i],
                mprevLogIndex |-> prevIdx,
                mprevLogTerm  |-> prevTerm,
                mentries      |-> entries,
                mcommitIndex  |-> commitIndex[i],
                msource       |-> i,
                mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   snapshotVars, configVars, leaseActive, crashed>>

\* Server i handles AppendEntriesRequest m.
\* Reference: engine_impl.rs:358-400 (handle_append_entries)
\*            following_handler/mod.rs:64-185 (append/truncate)
HandleAppendEntries(i, m) ==
    /\ ~crashed[i]
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ LET \* Incoming leader vote: (term, source, committed=TRUE)
           voteOk == VoteGEQ(m.mterm, m.msource, TRUE,
                             currentTerm[i], LocalVoteNode(i), voteCommitted[i])
       IN
       \/ \* Reject: incoming vote < local vote
          \* Reference: vote_handler/mod.rs:108-115
          /\ ~voteOk
          /\ Reply([mtype       |-> AppendEntriesResponse,
                    mterm       |-> currentTerm[i],
                    msuccess    |-> FALSE,
                    mmatchIndex |-> 0,
                    msource     |-> i,
                    mdest       |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>

       \/ \* Accept vote, check log consistency
          /\ voteOk
          \* Update vote to leader's (vote_handler/mod.rs:130-138)
          /\ currentTerm'   = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor'      = [votedFor EXCEPT ![i] = m.msource]
          /\ voteCommitted' = [voteCommitted EXCEPT ![i] = TRUE]
          /\ state'         = [state EXCEPT ![i] = Follower]
          /\ leaseActive'   = [leaseActive EXCEPT ![i] = TRUE]
          /\ votesGranted'  = [votesGranted EXCEPT ![i] = {}]

          /\ \/ \* Log mismatch at prevLogIndex
                \* Reference: following_handler/mod.rs:120-130
                /\ m.mprevLogIndex > 0
                /\ m.mprevLogIndex > purgedUpTo[i]
                /\ \/ m.mprevLogIndex > LastLogIndex(i)
                   \/ LogTerm(i, m.mprevLogIndex) # m.mprevLogTerm
                /\ Reply([mtype       |-> AppendEntriesResponse,
                          mterm       |-> m.mterm,
                          msuccess    |-> FALSE,
                          mmatchIndex |-> 0,
                          msource     |-> i,
                          mdest       |-> m.msource], m)
                /\ UNCHANGED <<logVars, leaderVars, snapshotVars, configVars>>

             \/ \* Prev log matches or auto-accept: append entries
                \* Reference: following_handler/mod.rs:64-111
                \*   - prevLogIndex = 0: first entry
                \*   - prevLogIndex <= purgedUpTo: committed, auto-accept
                \*     (log_state_reader.rs:23-35 — has_log_id optimization)
                \*   - prevLogIndex in log and term matches
                /\ \/ m.mprevLogIndex = 0
                   \/ m.mprevLogIndex <= purgedUpTo[i]
                   \/ (HasLogAt(i, m.mprevLogIndex)
                       /\ LogTerm(i, m.mprevLogIndex) = m.mprevLogTerm)
                /\ LET \* Truncate at prevLogIndex, append new entries
                       \* Reference: following_handler/mod.rs:83-92 (conflict),
                       \*            following_handler/mod.rs:166-185 (truncate)
                       newLog ==
                         IF m.mprevLogIndex <= purgedUpTo[i]
                         THEN \* Auto-accept: only extend beyond current log
                              LET overlap == LastLogIndex(i) - m.mprevLogIndex
                              IN IF overlap >= Len(m.mentries) THEN log[i]
                                 ELSE log[i] \o SubSeq(m.mentries,
                                                       overlap + 1,
                                                       Len(m.mentries))
                         ELSE \* Normal: truncate at prevLogIndex and append
                              SubSeq(log[i], 1,
                                     m.mprevLogIndex - purgedUpTo[i])
                              \o m.mentries
                       newLastIdx == purgedUpTo[i] + Len(newLog)
                       \* Update commitIndex from leader
                       newCI == Max(commitIndex[i],
                                   Min(m.mcommitIndex, newLastIdx))
                       \* Update config from latest ConfigEntry in entries
                       \* Reference: following_handler/mod.rs:189-208
                       cfgEntries == {k \in 1..Len(m.mentries) :
                                      m.mentries[k].type = ConfigEntry}
                       newCfg == IF cfgEntries = {} THEN config[i]
                                 ELSE m.mentries[SetMax(cfgEntries)].value
                   IN
                   /\ log'         = [log EXCEPT ![i] = newLog]
                   /\ commitIndex' = [commitIndex EXCEPT ![i] = newCI]
                   /\ config'      = [config EXCEPT ![i] = newCfg]
                   /\ Reply([mtype       |-> AppendEntriesResponse,
                             mterm       |-> m.mterm,
                             msuccess    |-> TRUE,
                             mmatchIndex |-> newLastIdx,
                             msource     |-> i,
                             mdest       |-> m.msource], m)
                   /\ UNCHANGED <<leaderVars, snapshotVars>>
          /\ UNCHANGED crashed

\* Leader i handles AppendEntriesResponse m.
\* Reference: replication_handler/mod.rs:171-243
HandleAppendEntriesResponse(i, m) ==
    /\ ~crashed[i]
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ \/ \* Higher term: step down
          /\ m.mterm > currentTerm[i]
          /\ currentTerm'   = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor'      = [votedFor EXCEPT ![i] = Nil]
          /\ voteCommitted' = [voteCommitted EXCEPT ![i] = FALSE]
          /\ state'         = [state EXCEPT ![i] = Follower]
          /\ leaseActive'   = [leaseActive EXCEPT ![i] = FALSE]
          /\ votesGranted'  = [votesGranted EXCEPT ![i] = {}]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, snapshotVars, configVars, crashed>>

       \/ \* Same term, success: update matching
          \* Reference: replication_handler/mod.rs:171-198 (update_matching)
          /\ m.mterm = currentTerm[i]
          /\ state[i] = Leader
          /\ m.msuccess
          /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] =
                            Max(@, m.mmatchIndex)]
          /\ nextIndex'  = [nextIndex EXCEPT ![i][m.msource] =
                            Max(@, m.mmatchIndex + 1)]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>

       \/ \* Same term, failure: decrement nextIndex
          \* Reference: replication_handler/mod.rs:228-243 (update_conflicting)
          /\ m.mterm = currentTerm[i]
          /\ state[i] = Leader
          /\ ~m.msuccess
          /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] =
                           Max(purgedUpTo[i] + 1, @ - 1)]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, matchIndex, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>

       \/ \* Stale response (lower term): discard
          /\ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>

\* Leader i advances commitIndex based on quorum.
\* Reference: replication_handler/mod.rs:204-220 (try_commit_quorum_accepted)
AdvanceCommitIndex(i) ==
    /\ ~crashed[i]
    /\ state[i] = Leader
    /\ LET \* Find highest index agreed by quorum in joint config
           Agree(idx) == {j \in Server : matchIndex[i][j] >= idx}
           agreeIdxs == {idx \in (commitIndex[i]+1)..LastLogIndex(i) :
                         JointQuorumCheck(Agree(idx), config[i])}
       IN
       /\ agreeIdxs # {}
       /\ LET newCI == SetMax(agreeIdxs)
          IN
          \* replication_handler.rs:206-209 — only commit from current term
          /\ LogTerm(i, newCI) = currentTerm[i]
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCI]
    /\ UNCHANGED <<serverVars, log, leaderVars, candidateVars, messages,
                   snapshotVars, configVars, leaseActive, crashed>>

----
\* Snapshot Actions (Bug Family 2)
\*
\* Bug Family 2: crash windows between snapshot install and log cleanup.
\* Historical bug 674e78aa: conflicting logs not deleted before install.
\* Historical bug #511: purged prev_log_id caused false conflict.
\* Historical PR #543: outdated snapshot reverted applied state.
----

\* Server i triggers snapshot at current commitIndex.
\* Reference: snapshot_handler/mod.rs:30-44
TriggerSnapshot(i) ==
    /\ ~crashed[i]
    /\ commitIndex[i] > snapshot[i].lastIndex
    /\ commitIndex[i] > purgedUpTo[i]
    /\ snapshot' = [snapshot EXCEPT ![i] =
                    [lastIndex |-> commitIndex[i],
                     lastTerm  |-> LogTerm(i, commitIndex[i])]]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   purgedUpTo, configVars, leaseActive, crashed>>

\* Server i purges log up to snapshot point.
\* Reference: log_handler/mod.rs:31-49
\*            replication_handler/mod.rs:413-447 (try_purge_log)
PurgeLog(i) ==
    /\ ~crashed[i]
    /\ snapshot[i].lastIndex > purgedUpTo[i]
    /\ LET newPurge   == snapshot[i].lastIndex
           purgeCount == newPurge - purgedUpTo[i]
       IN
       /\ purgeCount <= Len(log[i])
       /\ log'        = [log EXCEPT ![i] = SubSeq(@, purgeCount + 1, Len(@))]
       /\ purgedUpTo' = [purgedUpTo EXCEPT ![i] = newPurge]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   snapshot, configVars, leaseActive, crashed>>

\* Leader i sends snapshot to follower j (entries purged).
\* Reference: replication_handler/mod.rs:391-396 (send_to_target Snapshot)
SendInstallSnapshot(i, j) ==
    /\ ~crashed[i]
    /\ state[i] = Leader
    /\ j # i
    /\ j \in EffectiveVoters(config[i])
    \* Must send snapshot because nextIndex entries are purged
    /\ nextIndex[i][j] <= purgedUpTo[i]
    /\ snapshot[i].lastIndex > 0
    /\ Send([mtype      |-> InstallSnapshotRequest,
             mterm      |-> currentTerm[i],
             mlastIndex |-> snapshot[i].lastIndex,
             mlastTerm  |-> snapshot[i].lastTerm,
             mconfig    |-> config[i],
             msource    |-> i,
             mdest      |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   snapshotVars, configVars, leaseActive, crashed>>

\* Server i handles InstallSnapshotRequest m.
\* Reference: engine_impl.rs:404-433 (handle_install_full_snapshot)
\*            following_handler/mod.rs:244-298 (install_full_snapshot)
HandleInstallSnapshot(i, m) ==
    /\ ~crashed[i]
    /\ m.mtype = InstallSnapshotRequest
    /\ m.mdest = i
    /\ LET snapIdx  == m.mlastIndex
           snapTerm == m.mlastTerm
           voteOk   == VoteGEQ(m.mterm, m.msource, TRUE,
                               currentTerm[i], LocalVoteNode(i),
                               voteCommitted[i])
       IN
       \/ \* Reject: vote too old
          \* Reference: engine_impl.rs:412
          /\ ~voteOk
          /\ Reply([mtype   |-> InstallSnapshotResponse,
                    mterm   |-> currentTerm[i],
                    msource |-> i,
                    mdest   |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>

       \/ \* Accept and install
          /\ voteOk
          \* Update vote to leader's
          /\ currentTerm'   = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor'      = [votedFor EXCEPT ![i] = m.msource]
          /\ voteCommitted' = [voteCommitted EXCEPT ![i] = TRUE]
          /\ state'         = [state EXCEPT ![i] = Follower]
          /\ leaseActive'   = [leaseActive EXCEPT ![i] = TRUE]
          /\ votesGranted'  = [votesGranted EXCEPT ![i] = {}]
          \* following_handler/mod.rs:250 — check if newer than committed
          /\ IF snapIdx > commitIndex[i]
             THEN
                \* Install: update snapshot, truncate, update purge
                \* Reference: following_handler/mod.rs:267-293
                /\ snapshot' = [snapshot EXCEPT ![i] =
                    [lastIndex |-> snapIdx, lastTerm |-> snapTerm]]
                /\ IF snapIdx >= LastLogIndex(i)
                   THEN \* Snapshot covers all logs
                        /\ log'        = [log EXCEPT ![i] = <<>>]
                        /\ purgedUpTo' = [purgedUpTo EXCEPT ![i] = snapIdx]
                   ELSE \* Snapshot in middle — keep entries after
                        \* following_handler/mod.rs:272-278 — truncate conflict
                        /\ LET keepFrom == snapIdx - purgedUpTo[i] + 1
                           IN log' = [log EXCEPT ![i] =
                              IF keepFrom <= Len(@)
                              THEN SubSeq(@, keepFrom, Len(@))
                              ELSE <<>>]
                        /\ purgedUpTo' = [purgedUpTo EXCEPT ![i] = snapIdx]
                /\ commitIndex' = [commitIndex EXCEPT ![i] = Max(@, snapIdx)]
                /\ config' = [config EXCEPT ![i] = m.mconfig]
             ELSE
                \* Snapshot not newer, ignore
                /\ UNCHANGED <<logVars, snapshotVars, configVars>>
          /\ Reply([mtype   |-> InstallSnapshotResponse,
                    mterm   |-> m.mterm,
                    msource |-> i,
                    mdest   |-> m.msource], m)
          /\ UNCHANGED <<leaderVars, crashed>>

\* Leader i handles InstallSnapshotResponse m.
HandleInstallSnapshotResponse(i, m) ==
    /\ ~crashed[i]
    /\ m.mtype = InstallSnapshotResponse
    /\ m.mdest = i
    /\ \/ \* Higher term: step down
          /\ m.mterm > currentTerm[i]
          /\ currentTerm'   = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor'      = [votedFor EXCEPT ![i] = Nil]
          /\ voteCommitted' = [voteCommitted EXCEPT ![i] = FALSE]
          /\ state'         = [state EXCEPT ![i] = Follower]
          /\ leaseActive'   = [leaseActive EXCEPT ![i] = FALSE]
          /\ votesGranted'  = [votesGranted EXCEPT ![i] = {}]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, snapshotVars, configVars, crashed>>

       \/ \* Same term: update follower progress to snapshot point
          /\ m.mterm = currentTerm[i]
          /\ state[i] = Leader
          /\ nextIndex'  = [nextIndex EXCEPT ![i][m.msource] =
                            snapshot[i].lastIndex + 1]
          /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] =
                            snapshot[i].lastIndex]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>

       \/ \* Stale: discard
          /\ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>

----
\* Membership Change Actions (Bug Family 4)
\*
\* Joint consensus: two-step change with quorum in ALL sub-configs.
\* Historical bug 37d69439: joint never flattened with concurrent changes.
\* Historical bug c8fccb22: learner added without committed membership.
\* Reference: change_handler.rs:39-67, membership.rs:304-413
----

\* Leader i proposes membership change to newVoters.
\* Step 1: current uniform → joint (old ∪ new)
\* Reference: change_handler.rs:39-67 (apply + ensure_committed)
ProposeConfigChange(i, newVoters) ==
    /\ ~crashed[i]
    /\ state[i] = Leader
    \* change_handler.rs:54-67 — at most one uncommitted membership
    /\ ~HasUncommittedMembership(i)
    \* Must be in uniform config (length 1) to start change
    /\ Len(config[i]) = 1
    /\ newVoters # config[i][1]
    /\ LET jointCfg == <<config[i][1], newVoters>>
           entry    == [term  |-> currentTerm[i],
                        type  |-> ConfigEntry,
                        value |-> jointCfg]
           newIdx   == LastLogIndex(i) + 1
       IN
       \* replication_handler/mod.rs:63-91 — append membership
       /\ log' = [log EXCEPT ![i] = Append(@, entry)]
       /\ config' = [config EXCEPT ![i] = jointCfg]
       /\ matchIndex' = [matchIndex EXCEPT ![i][i] = newIdx]
       /\ nextIndex'  = [nextIndex EXCEPT ![i][i] = newIdx + 1]
    /\ UNCHANGED <<serverVars, commitIndex, candidateVars, messages,
                   snapshotVars, leaseActive, crashed>>

\* Leader i finalizes membership: joint committed → uniform.
\* Step 2: joint → new uniform config
\* Reference: membership.rs:304-319 (next_coherent)
CommitConfigChange(i) ==
    /\ ~crashed[i]
    /\ state[i] = Leader
    \* Must be in joint config (length 2)
    /\ Len(config[i]) = 2
    \* Joint config must be committed
    /\ ~HasUncommittedMembership(i)
    /\ LET uniformCfg == <<config[i][2]>>
           entry      == [term  |-> currentTerm[i],
                          type  |-> ConfigEntry,
                          value |-> uniformCfg]
           newIdx     == LastLogIndex(i) + 1
       IN
       /\ log' = [log EXCEPT ![i] = Append(@, entry)]
       /\ config' = [config EXCEPT ![i] = uniformCfg]
       /\ matchIndex' = [matchIndex EXCEPT ![i][i] = newIdx]
       /\ nextIndex'  = [nextIndex EXCEPT ![i][i] = newIdx + 1]
    /\ UNCHANGED <<serverVars, commitIndex, candidateVars, messages,
                   snapshotVars, leaseActive, crashed>>

----
\* Crash/Recovery Actions (Bug Family 2, 5)
\*
\* Bug Family 5: leader survival across restart — committed vote for self
\*   means resume as leader without re-election (non-standard).
\* Historical: Issue #1511 (OPEN) — stale state machine after restart.
\* Historical: Issue #1246 — missing log replay on single-node restart.
\* Historical: PR #884 — leader restart didn't restore progress.
----

\* Server i crashes. Volatile state lost, persistent state preserved.
Crash(i) ==
    /\ ~crashed[i]
    /\ crashed' = [crashed EXCEPT ![i] = TRUE]
    \* Reset volatile state
    /\ state'       = [state EXCEPT ![i] = Follower]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    /\ leaseActive' = [leaseActive EXCEPT ![i] = FALSE]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex'   = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'  = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    \* Persistent: currentTerm, votedFor, voteCommitted, log, snapshot,
    \*             purgedUpTo, config
    /\ UNCHANGED <<currentTerm, votedFor, voteCommitted, log, messages,
                   snapshotVars, configVars>>

\* Server i restarts after crash.
\* Reference: helper.rs:88-225 (get_initial_state)
\* Bug Family 5: committed vote for self → resume as leader
Restart(i) ==
    /\ crashed[i]
    /\ crashed' = [crashed EXCEPT ![i] = FALSE]
    /\ LET \* raft_state/mod.rs:464-466 — is_leader
           isLeaderSurvivor ==
               votedFor[i] = i /\ voteCommitted[i] /\ IsVoter(i)
       IN
       \* raft_state/mod.rs:415-439 — calc_server_state
       /\ state' = [state EXCEPT ![i] =
                    IF isLeaderSurvivor THEN Leader ELSE Follower]
       \* helper.rs:116-118 — committed recovery
       \* Without save_committed, commitIndex = 0 (Issue #1511)
       /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
       /\ leaseActive'  = [leaseActive EXCEPT ![i] = FALSE]
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
       \* PR #884 — restore leader state
       /\ IF isLeaderSurvivor
          THEN /\ nextIndex'  = [nextIndex EXCEPT ![i] =
                    [j \in Server |-> LastLogIndex(i) + 1]]
               /\ matchIndex' = [matchIndex EXCEPT ![i] =
                    [j \in Server |-> IF j = i
                                      THEN LastLogIndex(i) ELSE 0]]
          ELSE UNCHANGED leaderVars
    /\ UNCHANGED <<currentTerm, votedFor, voteCommitted, log, messages,
                   snapshotVars, configVars>>

----
\* Leader Lease Actions (Bug Family 1)
----

\* Lease expires on server i (non-deterministic).
\* Reference: utime.rs:148-150 — is_expired check
\* After expiry, followers will grant VoteRequests from higher-term candidates.
LeaseExpire(i) ==
    /\ ~crashed[i]
    /\ leaseActive[i]
    /\ leaseActive' = [leaseActive EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   snapshotVars, configVars, crashed>>

----
\* Leader Step Down (Bug Family 4)
----

\* Leader i steps down when not in current config.
\* Reference: engine_impl.rs:446-464 (leader_step_down)
LeaderStepDown(i) ==
    /\ ~crashed[i]
    /\ state[i] = Leader
    \* engine_impl.rs:461 — membership without self is committed
    /\ ~IsVoter(i)
    /\ state'         = [state EXCEPT ![i] = Follower]
    /\ voteCommitted' = [voteCommitted EXCEPT ![i] = FALSE]
    /\ leaseActive'   = [leaseActive EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, leaderVars, candidateVars,
                   messages, snapshotVars, configVars, crashed>>

----
\* Next
----

Next ==
    \/ \E i \in Server :
        \/ Elect(i)
        \/ EstablishLeader(i)
        \/ ClientRequest(i)
        \/ SendHeartbeat(i)
        \/ AdvanceCommitIndex(i)
        \/ TriggerSnapshot(i)
        \/ PurgeLog(i)
        \/ Crash(i)
        \/ Restart(i)
        \/ LeaseExpire(i)
        \/ LeaderStepDown(i)
    \/ \E i \in Server, j \in Server :
        \/ ReplicateEntries(i, j)
        \/ SendInstallSnapshot(i, j)
    \/ \E i \in Server :
        \E newVoters \in SUBSET Server \ {{}} :
            ProposeConfigChange(i, newVoters)
    \/ \E i \in Server :
        CommitConfigChange(i)
    \/ \E m \in DOMAIN messages :
        \/ HandleVoteRequest(m.mdest, m)
        \/ HandleVoteResponse(m.mdest, m)
        \/ HandleAppendEntries(m.mdest, m)
        \/ HandleAppendEntriesResponse(m.mdest, m)
        \/ HandleInstallSnapshot(m.mdest, m)
        \/ HandleInstallSnapshotResponse(m.mdest, m)

Spec == Init /\ [][Next]_vars

----
\* Invariants
----

\* openraft Election Safety: vote ordering by (term, node_id) means multiple
\* leaders CAN exist transiently in the same term. The highest-node-id leader
\* wins because followers reject AppendEntries from lower-node-id leaders.
\* Standard Raft's "at most one leader per term" does NOT hold in openraft.
\* The actual safety invariant is CommitSafety (no conflicting commits).
ElectionSafety ==
    \A i, j \in Server :
        (state[i] = Leader /\ state[j] = Leader
         /\ currentTerm[i] = currentTerm[j] /\ ~crashed[i] /\ ~crashed[j])
        => i = j

\* Commit Safety: committed log entries are consistent across all servers.
\* This is the real safety invariant for openraft (replaces ElectionSafety).
CommitSafety ==
    \A i, j \in Server :
        (~crashed[i] /\ ~crashed[j]) =>
            \A idx \in 1..Min(commitIndex[i], commitIndex[j]) :
                (HasLogAt(i, idx) /\ HasLogAt(j, idx))
                => LogTerm(i, idx) = LogTerm(j, idx)

\* Standard Safety: matching index+term implies matching prefix
\* Only checked for non-purged entries
LogMatching ==
    \A i, j \in Server :
        \A idx \in 1..Min(LastLogIndex(i), LastLogIndex(j)) :
            (HasLogAt(i, idx) /\ HasLogAt(j, idx)
             /\ LogTerm(i, idx) = LogTerm(j, idx)
             /\ idx > 1 /\ HasLogAt(i, idx-1) /\ HasLogAt(j, idx-1))
            => LogTerm(i, idx-1) = LogTerm(j, idx-1)

\* Standard Safety: committed entries appear in all future leaders' logs
\* Simplified: a leader has all committed entries of any non-crashed server
LeaderCompleteness ==
    \A i \in Server :
        (state[i] = Leader /\ ~crashed[i]) =>
            \A j \in Server :
                \A idx \in 1..commitIndex[j] :
                    (HasLogAt(i, idx) /\ HasLogAt(j, idx))
                    => LogTerm(i, idx) = LogTerm(j, idx)

\* Extension (Bug Family 2): no conflicting logs below snapshot
SnapshotLogConsistency ==
    \A i \in Server :
        ~crashed[i] /\ snapshot[i].lastIndex > 0 =>
            (HasLogAt(i, snapshot[i].lastIndex)
             => LogTerm(i, snapshot[i].lastIndex) = snapshot[i].lastTerm)

\* Extension (Bug Family 2): committed entries never deleted
\* (only purged after snapshot covers them)
NoCommittedLogDeletion ==
    \A i \in Server :
        ~crashed[i] =>
            purgedUpTo[i] <= snapshot[i].lastIndex

\* Extension (Bug Family 4): at most one uncommitted membership
AtMostOneUncommittedMembership ==
    \A i \in Server :
        (state[i] = Leader /\ ~crashed[i]) =>
            Cardinality({k \in 1..Len(log[i]) :
                         (k + purgedUpTo[i]) > commitIndex[i]
                          /\ log[i][k].type = ConfigEntry}) <= 1

\* Extension (Bug Family 1): vote-state consistency
VoteStateConsistency ==
    \A i \in Server :
        ~crashed[i] =>
            /\ (state[i] = Leader =>
                    votedFor[i] = i /\ voteCommitted[i])
            /\ (state[i] = Candidate =>
                    votedFor[i] = i /\ ~voteCommitted[i])

\* Extension (Bug Family 1): lease implies recent leader contact
\* A node with active lease and committed vote believes leader was recently
\* alive. The leader may have crashed since (in-transit heartbeats), but it
\* MUST have been a leader in this term at some point. The voted-for node
\* must have currentTerm matching and have committed its own vote.
LeaseImpliesLeadership ==
    \A i \in Server :
        (~crashed[i] /\ leaseActive[i] /\ voteCommitted[i]
         /\ votedFor[i] # i) =>
            \E j \in Server :
                /\ j = votedFor[i]
                /\ currentTerm[j] = currentTerm[i]
                /\ voteCommitted[j]
                /\ (state[j] = Leader \/ crashed[j])

\* Extension (Bug Family 3): commitIndex never exceeds leader's
CommitIndexBound ==
    \A i \in Server :
        ~crashed[i] => commitIndex[i] <= LastLogIndex(i)

\* Extension (Bug Family 5): a restarted leader has all committed entries
\* This is the key invariant for Issue #1511
RestartedLeaderSafety ==
    \A i \in Server :
        (state[i] = Leader /\ ~crashed[i]) =>
            \A j \in Server :
                \A idx \in 1..commitIndex[j] :
                    (~crashed[j] /\ HasLogAt(j, idx) /\ HasLogAt(i, idx))
                    => LogTerm(i, idx) = LogTerm(j, idx)

====
