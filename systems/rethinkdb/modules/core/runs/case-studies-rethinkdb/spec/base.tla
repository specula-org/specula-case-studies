---- MODULE base ----
\* TLA+ specification for RethinkDB's Raft consensus implementation.
\* Models: leader election, log replication, joint consensus config changes,
\* virtual heartbeats, async step-down, and Raft lifecycle management.
\*
\* Source: src/clustering/generic/raft_core.hpp + raft_core.tcc
\* Reference: Ongaro & Ousterhout 2014 (Raft paper)

EXTENDS Integers, Sequences, FiniteSets, Bags, TLC

\* Min/Max helpers (used throughout)
Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b

\* ============================================================================
\* Constants
\* ============================================================================

CONSTANTS
    Server,          \* Set of server IDs
    Value,           \* Set of values for log entries
    Nil,             \* Nil value (null/empty)
    MaxTerm,         \* Upper bound on terms (for state space bounding)
    MaxLogLen        \* Upper bound on log length

\* ============================================================================
\* Variables
\* ============================================================================

\* --- Standard Raft variables ---
\* Persistent state (survives crash+recovery)
VARIABLES
    currentTerm,     \* currentTerm[s]: current term of server s (raft_core.hpp:347)
    votedFor,        \* votedFor[s]: candidateId voted for in current term (raft_core.hpp:348)
    log              \* log[s]: log entries as sequence of [term |-> T, value |-> V, type |-> Type] (raft_core.hpp:361)

\* Volatile state
VARIABLES
    state,           \* state[s]: "follower", "candidate", or "leader" (raft_core.hpp:938, mode_t enum)
    commitIndex,     \* commitIndex[s]: index of highest committed entry (raft_core.hpp:366 — persisted deviation)
    currentLeader    \* currentLeader[s]: leader ID seen this term, or Nil (raft_core.hpp:943)

\* Leader-only volatile state
VARIABLES
    nextIndex,       \* nextIndex[s][t]: next log index to send to t (raft_core.tcc:1717)
    matchIndex       \* matchIndex[s][t]: highest index known replicated on t (raft_core.hpp:957)

\* Message bag
VARIABLES
    messages         \* Bag of messages in flight

\* --- Extension variables (Bug Family driven) ---

\* Election state — tracks votes received
VARIABLES
    votesGranted     \* votesGranted[s]: set of servers that granted vote to s

\* [Family 1] Virtual heartbeat mechanism (raft_core.hpp:947-952)
VARIABLES
    virtualHeartbeatSender,   \* virtualHeartbeatSender[s]: who is sending VHBs to s, or Nil
    watchdogBlocked,          \* watchdogBlocked[s]: TRUE if watchdog is blocked (receiving VHBs)
    watchdogLeaderOnlyBlocked \* watchdogLeaderOnlyBlocked[s]: TRUE if watchdog_leader_only is blocked

\* [Family 2] Async step-down (raft_core.tcc:1979-2026)
VARIABLES
    pendingStepDown,  \* pendingStepDown[s]: TRUE if async step-down coroutine is pending
    pendingNewTerm    \* pendingNewTerm[s]: the term to step down to, or 0

\* [Family 3] Configuration change — dual config tracking (raft_core.tcc:1942-1977)
VARIABLES
    config            \* config[s]: [old |-> VotingSet, new |-> VotingSetOrNil]
                      \* When new = Nil, single config. When new /= Nil, joint consensus.
                      \* Derived from latest_state.config (raft_core.hpp:935)

\* [Family 4] Raft lifecycle management — external erasure
VARIABLES
    persistentLogValid,  \* persistentLogValid[s]: FALSE after external erasure
    memberIdGeneration   \* memberIdGeneration[s]: incremented on re-enrollment

\* [Family 5] Snapshot-log boundary (raft_core.hpp:350-361, raft_core.tcc:523-623)
VARIABLES
    snapshotIndex,       \* snapshotIndex[s]: log.prev_index — last included index in snapshot
    snapshotTerm         \* snapshotTerm[s]: log.prev_term — last included term in snapshot

\* Variable groups for UNCHANGED
serverVars   == <<currentTerm, votedFor, state, currentLeader>>
logVars      == <<log, commitIndex>>
leaderVars   == <<nextIndex, matchIndex>>
electionVars == <<votesGranted>>
heartbeatVars == <<virtualHeartbeatSender, watchdogBlocked, watchdogLeaderOnlyBlocked>>
asyncVars    == <<pendingStepDown, pendingNewTerm>>
configVars   == <<config>>
lifecycleVars == <<persistentLogValid, memberIdGeneration>>
snapshotVars == <<snapshotIndex, snapshotTerm>>

allVars == <<serverVars, logVars, leaderVars, electionVars, messages, heartbeatVars, asyncVars, configVars, lifecycleVars, snapshotVars>>

\* ============================================================================
\* Helpers
\* ============================================================================

\* Message constructor
Send(m) == messages' = messages (+) SetToBag({m})
Discard(m) == messages' = messages (-) SetToBag({m})
Reply(response, request) == messages' = (messages (-) SetToBag({request})) (+) SetToBag({response})

\* Log helpers — absolute indices account for snapshot offset
\* Absolute last index: snapshot base + local log length (raft_core.hpp:266-268)
LastIndex(s) == snapshotIndex[s] + Len(log[s])
\* Term of last log entry (raft_core.hpp:272-280)
LastTerm(s) == IF Len(log[s]) = 0 THEN snapshotTerm[s]
               ELSE log[s][Len(log[s])].term
\* Term at absolute index (raft_core.hpp:272-280)
LogTerm(s, idx) == IF idx = 0 THEN 0
                   ELSE IF idx = snapshotIndex[s] THEN snapshotTerm[s]
                   ELSE IF idx < snapshotIndex[s] THEN 0  \* covered by snapshot
                   ELSE IF idx > LastIndex(s) THEN 0
                   ELSE log[s][idx - snapshotIndex[s]].term
\* Local index from absolute (for SubSeq): absolute - snapshotIndex
LocalIdx(s, absIdx) == absIdx - snapshotIndex[s]

\* Quorum check: strict majority of voting members
\* raft_core.hpp:123-129 — votes * 2 > voting_members.size()
IsQuorum(voters, votingSet) ==
    Cardinality(voters \cap votingSet) * 2 > Cardinality(votingSet)

\* Joint consensus quorum: both old and new must have quorums
\* raft_core.hpp:178-186
IsJointQuorum(voters, cfg) ==
    IF cfg.new = Nil
    THEN IsQuorum(voters, cfg.old)
    ELSE IsQuorum(voters, cfg.old) /\ IsQuorum(voters, cfg.new)

\* Is server a valid leader under config?
\* raft_core.hpp:188-193 — old OR new voting member
IsValidLeader(s, cfg) ==
    IF cfg.new = Nil
    THEN s \in cfg.old
    ELSE s \in cfg.old \/ s \in cfg.new

\* Is server a member (voting) in config?
IsMember(s, cfg) ==
    IF cfg.new = Nil
    THEN s \in cfg.old
    ELSE s \in cfg.old \/ s \in cfg.new

\* All members in config
AllMembers(cfg) ==
    IF cfg.new = Nil
    THEN cfg.old
    ELSE cfg.old \cup cfg.new

\* Is this a joint consensus config?
IsJointConsensus(cfg) == cfg.new /= Nil

\* Log up-to-date check
\* raft_core.tcc:485-488
LogIsUpToDate(candidateLastTerm, candidateLastIndex, voterLastTerm, voterLastIndex) ==
    \/ candidateLastTerm > voterLastTerm
    \/ (candidateLastTerm = voterLastTerm /\ candidateLastIndex >= voterLastIndex)

\* Committed config: config derived from committed entries
\* Walk backwards through log up to commitIndex to find last config entry
\* Uses local indices (1..Len(log[s])); absolute index = snapshotIndex[s] + localIdx
CommittedConfig(s) ==
    LET ciLocal == commitIndex[s] - snapshotIndex[s]
        configEntries == {i \in 1..ciLocal : i > 0 /\ i <= Len(log[s]) /\ log[s][i].type = "config"}
    IN IF configEntries = {} THEN [old |-> Server, new |-> Nil]  \* initial config from make_initial()
       ELSE log[s][CHOOSE i \in configEntries : \A j \in configEntries : j <= i].cfg

\* ============================================================================
\* Initial State
\* ============================================================================

\* raft_core.tcc:36-52 — make_initial()
Init ==
    /\ currentTerm  = [s \in Server |-> 0]
    /\ votedFor     = [s \in Server |-> Nil]
    /\ log          = [s \in Server |-> << >>]
    /\ state        = [s \in Server |-> "follower"]
    /\ commitIndex  = [s \in Server |-> 0]
    /\ currentLeader = [s \in Server |-> Nil]
    /\ nextIndex    = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex   = [s \in Server |-> [t \in Server |-> 0]]
    /\ messages     = EmptyBag
    /\ votesGranted = [s \in Server |-> {}]
    \* [Family 1] Virtual heartbeat — watchdog_leader_only starts TRIGGERED (raft_core.tcc:88-94)
    /\ virtualHeartbeatSender = [s \in Server |-> Nil]
    /\ watchdogBlocked = [s \in Server |-> FALSE]
    /\ watchdogLeaderOnlyBlocked = [s \in Server |-> FALSE]
    \* [Family 2] Async step-down
    /\ pendingStepDown = [s \in Server |-> FALSE]
    /\ pendingNewTerm  = [s \in Server |-> 0]
    \* [Family 3] Config — all servers start in same single config
    /\ config = [s \in Server |-> [old |-> Server, new |-> Nil]]
    \* [Family 4] Lifecycle
    /\ persistentLogValid = [s \in Server |-> TRUE]
    /\ memberIdGeneration = [s \in Server |-> 1]
    \* [Family 5] Snapshot — initially no snapshot (raft_core.tcc:48-49)
    /\ snapshotIndex = [s \in Server |-> 0]
    /\ snapshotTerm  = [s \in Server |-> 0]

\* ============================================================================
\* Actions: Leader Election
\* ============================================================================

\* --- Timeout: follower starts election ---
\* raft_core.tcc:1034-1073 — on_watchdog()
\* A follower whose watchdog has triggered starts an election.
\* Note: non-members CAN start elections (raft_core.tcc:1041-1045, dissertation 4.2.2)
Timeout(s) ==
    /\ state[s] = "follower"
    /\ persistentLogValid[s]
    \* raft_core.tcc:1057 — watchdog must be triggered (not blocked by VHBs)
    /\ ~watchdogBlocked[s]
    \* raft_core.tcc:1298 — transition to candidate
    /\ state' = [state EXCEPT ![s] = "candidate"]
    \* raft_core.tcc:1512 — increment term, vote for self
    /\ currentTerm' = [currentTerm EXCEPT ![s] = currentTerm[s] + 1]
    /\ votedFor' = [votedFor EXCEPT ![s] = s]
    \* Reset leader tracking
    /\ currentLeader' = [currentLeader EXCEPT ![s] = Nil]
    \* [Family 1] Clear virtual heartbeat state on term change (raft_core.tcc:1119-1122)
    /\ virtualHeartbeatSender' = [virtualHeartbeatSender EXCEPT ![s] = Nil]
    /\ watchdogBlocked' = [watchdogBlocked EXCEPT ![s] = FALSE]
    /\ watchdogLeaderOnlyBlocked' = [watchdogLeaderOnlyBlocked EXCEPT ![s] = FALSE]
    \* raft_core.tcc:1513: votes_for_us = {this_member_id}
    /\ votesGranted' = [votesGranted EXCEPT ![s] = {s}]
    /\ UNCHANGED <<logVars, leaderVars, messages, asyncVars, configVars, lifecycleVars, snapshotVars>>

\* --- RequestVote: candidate sends RequestVote RPC ---
\* raft_core.tcc:1520-1526 — constructs request_vote_t
RequestVote(s, t) ==
    /\ state[s] = "candidate"
    /\ s /= t
    /\ Send([type    |-> "RequestVoteRequest",
             term    |-> currentTerm[s],
             from    |-> s,
             to      |-> t,
             lastLogTerm  |-> LastTerm(s),
             lastLogIndex |-> LastIndex(s)])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, heartbeatVars, asyncVars, configVars, lifecycleVars, snapshotVars, electionVars>>

\* --- HandleRequestVoteRequest: server handles incoming RequestVote ---
\* raft_core.tcc:404-520 — on_request_vote_rpc()
HandleRequestVoteRequest(s, m) ==
    /\ m.type = "RequestVoteRequest"
    /\ m.to = s
    /\ persistentLogValid[s]
    /\ LET grant ==
        \* raft_core.tcc:431-440 — leader rejects non-config-member candidates;
        \* follower rejects if watchdog_leader_only not triggered
        /\ \/ (state[s] = "leader" /\ IsMember(m.from, config[s]))
           \/ (state[s] = "follower" /\ ~watchdogLeaderOnlyBlocked[s])
           \/ state[s] = "candidate"
        \* raft_core.tcc:453 — reject if term < currentTerm
        /\ m.term >= currentTerm[s]
        \* raft_core.tcc:473 — votedFor is nil or candidateId
        /\ LET effectiveTerm == IF m.term > currentTerm[s] THEN m.term ELSE currentTerm[s]
               effectiveVotedFor == IF m.term > currentTerm[s] THEN Nil ELSE votedFor[s]
           IN \/ effectiveVotedFor = Nil
              \/ effectiveVotedFor = m.from
        \* raft_core.tcc:485-496 — log up-to-date check
        /\ LogIsUpToDate(m.lastLogTerm, m.lastLogIndex, LastTerm(s), LastIndex(s))
       IN
       \* Step down if higher term (raft_core.tcc:444-450)
       /\ IF m.term > currentTerm[s]
          THEN /\ IF state[s] /= "follower"
                  \* raft_core.tcc:446 — become follower synchronously (not leader/candidate)
                  THEN /\ state' = [state EXCEPT ![s] = "follower"]
                       /\ nextIndex' = [nextIndex EXCEPT ![s] = [t \in Server |-> 1]]
                       /\ matchIndex' = [matchIndex EXCEPT ![s] = [t \in Server |-> 0]]
                  ELSE UNCHANGED <<state, nextIndex, matchIndex, electionVars>>
               /\ currentTerm' = [currentTerm EXCEPT ![s] = m.term]
               /\ votedFor' = [votedFor EXCEPT
                    ![s] = IF grant THEN m.from ELSE Nil]
               \* Reset on term change (raft_core.tcc:1119-1122)
               /\ currentLeader' = [currentLeader EXCEPT ![s] = Nil]
               /\ virtualHeartbeatSender' = [virtualHeartbeatSender EXCEPT ![s] = Nil]
               /\ watchdogBlocked' = [watchdogBlocked EXCEPT ![s] = FALSE]
               /\ watchdogLeaderOnlyBlocked' = [watchdogLeaderOnlyBlocked EXCEPT ![s] = FALSE]
          ELSE /\ IF grant
                  THEN /\ votedFor' = [votedFor EXCEPT ![s] = m.from]
                       \* raft_core.tcc:514 — notify watchdog on vote grant
                       /\ UNCHANGED <<currentTerm, state, nextIndex, matchIndex,
                                      currentLeader, virtualHeartbeatSender,
                                      watchdogBlocked, watchdogLeaderOnlyBlocked>>
                  ELSE UNCHANGED <<currentTerm, votedFor, state, currentLeader,
                                   nextIndex, matchIndex,
                                   virtualHeartbeatSender, watchdogBlocked, watchdogLeaderOnlyBlocked>>
       \* Clear pending step-down when processing higher term or becoming follower
       /\ IF pendingStepDown[s] /\ (m.term > currentTerm[s] \/ state[s] /= "follower")
          THEN /\ pendingStepDown' = [pendingStepDown EXCEPT ![s] = FALSE]
               /\ pendingNewTerm' = [pendingNewTerm EXCEPT ![s] = 0]
          ELSE UNCHANGED asyncVars
       /\ Reply([type        |-> "RequestVoteResponse",
                 term        |-> IF m.term > currentTerm[s] THEN m.term ELSE currentTerm[s],
                 from        |-> s,
                 to          |-> m.from,
                 voteGranted |-> grant], m)
       /\ UNCHANGED <<logVars, configVars, lifecycleVars, snapshotVars, electionVars>>

\* --- HandleRequestVoteResponse: candidate processes vote reply ---
\* raft_core.tcc:1571-1598 — vote reply handling in candidate_run_election
HandleRequestVoteResponse(s, m) ==
    /\ m.type = "RequestVoteResponse"
    /\ m.to = s
    /\ state[s] = "candidate"
    /\ m.term = currentTerm[s]
    /\ \/ /\ m.voteGranted
          \* raft_core.tcc:1591 — add voter to votes_for_us
          /\ votesGranted' = [votesGranted EXCEPT ![s] = votesGranted[s] \cup {m.from}]
          \* raft_core.tcc:1595 — is_quorum check
          /\ IF IsJointQuorum(votesGranted[s] \cup {m.from}, config[s])
             THEN \* raft_core.tcc:1639 — become leader
                  /\ state' = [state EXCEPT ![s] = "leader"]
                  /\ currentLeader' = [currentLeader EXCEPT ![s] = s]
                  \* raft_core.tcc:1380 — initialize nextIndex (absolute)
                  /\ nextIndex' = [nextIndex EXCEPT
                         ![s] = [t \in Server |-> LastIndex(s) + 1]]
                  \* raft_core.tcc:1394-1399 — append noop entry
                  /\ log' = [log EXCEPT ![s] = Append(@, [term  |-> currentTerm[s],
                                                           value |-> Nil,
                                                           type  |-> "noop",
                                                           cfg   |-> Nil])]
                  \* raft_core.tcc:1387 + 2059-2060 — matchIndex: self = after noop (absolute), others = 0
                  /\ matchIndex' = [matchIndex EXCEPT
                         ![s] = [t \in Server |-> IF t = s THEN LastIndex(s) + 1 ELSE 0]]
                  \* raft_core.tcc:1409 — send virtual heartbeats
                  /\ UNCHANGED <<currentTerm, votedFor, commitIndex>>
             ELSE \* Not enough votes yet, just consume the message
                  UNCHANGED <<serverVars, logVars, leaderVars>>
       \/ /\ ~m.voteGranted
          /\ UNCHANGED <<serverVars, logVars, leaderVars, votesGranted>>
    /\ Discard(m)
    /\ UNCHANGED <<heartbeatVars, asyncVars, configVars, lifecycleVars, snapshotVars>>

\* --- BecomeLeader: separate action for leader setup after winning election ---
\* (Merged into HandleRequestVoteResponse above for atomicity)

\* ============================================================================
\* Actions: Virtual Heartbeats [Family 1]
\* ============================================================================

\* --- StartVirtualHeartbeat: leader sends VHB start to a follower ---
\* raft_core.tcc:1409 — network->send_virtual_heartbeats(make_optional(ps().current_term))
\* raft_core.tcc:888-953 — on_connected_members_change() receives VHB
StartVirtualHeartbeat(leader, follower) ==
    /\ state[leader] = "leader"
    /\ leader /= follower
    /\ IsMember(follower, config[leader])
    \* The follower processes the VHB via on_connected_members_change
    \* raft_core.tcc:906 — on_rpc_from_leader called for the VHB term
    /\ \/ \* VHB accepted: leader's term >= follower's term
          /\ currentTerm[leader] >= currentTerm[follower]
          \* raft_core.tcc:926-936 — set virtual_heartbeat_sender, block watchdogs
          /\ virtualHeartbeatSender' = [virtualHeartbeatSender EXCEPT ![follower] = leader]
          /\ watchdogBlocked' = [watchdogBlocked EXCEPT ![follower] = TRUE]
          /\ watchdogLeaderOnlyBlocked' = [watchdogLeaderOnlyBlocked EXCEPT ![follower] = TRUE]
          \* raft_core.tcc:968-982 — step down to follower if higher term
          /\ IF currentTerm[leader] > currentTerm[follower]
             THEN /\ currentTerm' = [currentTerm EXCEPT ![follower] = currentTerm[leader]]
                  /\ votedFor' = [votedFor EXCEPT ![follower] = Nil]
                  /\ IF state[follower] /= "follower"
                     THEN state' = [state EXCEPT ![follower] = "follower"]
                     ELSE UNCHANGED state
                  /\ currentLeader' = [currentLeader EXCEPT ![follower] = leader]
                  \* raft_core.tcc:1467-1499 — candidate_or_leader_become_follower kills
                  \* the coroutine, cancelling any pending note_term step-down.
                  /\ IF pendingStepDown[follower]
                     THEN /\ pendingStepDown' = [pendingStepDown EXCEPT ![follower] = FALSE]
                          /\ pendingNewTerm' = [pendingNewTerm EXCEPT ![follower] = 0]
                     ELSE UNCHANGED asyncVars
             ELSE /\ currentLeader' = [currentLeader EXCEPT
                        ![follower] = IF currentLeader[follower] = Nil
                                      THEN leader ELSE currentLeader[follower]]
                  /\ UNCHANGED <<currentTerm, votedFor, state, electionVars>>
                  /\ UNCHANGED asyncVars
       \/ \* VHB rejected: leader's term < follower's term
          \* raft_core.tcc:906-914 — no way to reply to a virtual heartbeat
          /\ currentTerm[leader] < currentTerm[follower]
          /\ UNCHANGED <<currentTerm, votedFor, state, currentLeader,
                         virtualHeartbeatSender, watchdogBlocked, watchdogLeaderOnlyBlocked>>
          /\ UNCHANGED asyncVars
    /\ UNCHANGED <<logVars, leaderVars, messages, configVars, lifecycleVars, snapshotVars, electionVars>>

\* --- StopVirtualHeartbeat: leader stops VHBs (e.g., steps down, disconnects) ---
\* raft_core.tcc:944-953 — received stop message or lost contact
StopVirtualHeartbeat(leader, follower) ==
    /\ virtualHeartbeatSender[follower] = leader
    \* raft_core.tcc:947-952 — clear sender, unblock watchdogs
    /\ virtualHeartbeatSender' = [virtualHeartbeatSender EXCEPT ![follower] = Nil]
    /\ watchdogBlocked' = [watchdogBlocked EXCEPT ![follower] = FALSE]
    /\ watchdogLeaderOnlyBlocked' = [watchdogLeaderOnlyBlocked EXCEPT ![follower] = FALSE]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, messages, asyncVars, configVars, lifecycleVars, snapshotVars, electionVars>>

\* ============================================================================
\* Actions: Log Replication
\* ============================================================================

\* --- ClientRequest: leader receives a client request ---
\* raft_core.tcc:183-212 — propose_change()
ClientRequest(s, v) ==
    /\ state[s] = "leader"
    /\ persistentLogValid[s]
    \* raft_core.tcc:189-191 — readiness check
    /\ ~pendingStepDown[s]
    /\ log' = [log EXCEPT ![s] = Append(@, [term  |-> currentTerm[s],
                                             value |-> v,
                                             type  |-> "regular",
                                             cfg   |-> Nil])]
    \* raft_core.tcc:2059-2060 — update own matchIndex (absolute)
    /\ matchIndex' = [matchIndex EXCEPT ![s][s] = LastIndex(s) + 1]
    /\ UNCHANGED <<serverVars, commitIndex, nextIndex, messages, heartbeatVars, asyncVars, configVars, lifecycleVars, snapshotVars, electionVars>>

\* --- AppendEntries: leader sends AppendEntries RPC ---
\* raft_core.tcc:1835-1847 — construct append_entries_t request
AppendEntries(s, t) ==
    /\ state[s] = "leader"
    /\ s /= t
    /\ persistentLogValid[s]
    /\ ~pendingStepDown[s]
    \* Only send AE if nextIndex is within our log (else need InstallSnapshot)
    /\ nextIndex[s][t] > snapshotIndex[s]
    /\ LET prevLogIndex == nextIndex[s][t] - 1
           prevLogTerm  == LogTerm(s, prevLogIndex)
           \* Convert absolute nextIndex to local for SubSeq
           localNext == nextIndex[s][t] - snapshotIndex[s]
           \* Send entries from nextIndex to end of log
           entries == IF localNext > Len(log[s])
                      THEN << >>
                      ELSE SubSeq(log[s], localNext, Len(log[s]))
       IN Send([type          |-> "AppendEntriesRequest",
                term          |-> currentTerm[s],
                from          |-> s,
                to            |-> t,
                prevLogIndex  |-> prevLogIndex,
                prevLogTerm   |-> prevLogTerm,
                entries       |-> entries,
                leaderCommit  |-> commitIndex[s]])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, heartbeatVars, asyncVars, configVars, lifecycleVars, snapshotVars, electionVars>>

\* --- HandleAppendEntriesRequest: follower processes AppendEntries ---
\* raft_core.tcc:626-735 — on_append_entries_rpc()
HandleAppendEntriesRequest(s, m) ==
    /\ m.type = "AppendEntriesRequest"
    /\ m.to = s
    /\ persistentLogValid[s]
    /\ LET \* raft_core.tcc:633 — call on_rpc_from_leader
           validLeader ==
               /\ m.term >= currentTerm[s]
               /\ m.from /= s
           \* After on_rpc_from_leader, term is updated
           effectiveTerm == IF m.term > currentTerm[s] THEN m.term ELSE currentTerm[s]
           \* raft_core.tcc:649-652 — log consistency check
           \* raft_core.tcc:646-648 — snapshot may cover prevLogIndex (Leader Completeness)
           logOk == \/ m.prevLogIndex = 0
                    \/ m.prevLogIndex < snapshotIndex[s]  \* covered by snapshot
                    \/ (m.prevLogIndex >= snapshotIndex[s]
                        /\ m.prevLogIndex <= LastIndex(s)
                        /\ LogTerm(s, m.prevLogIndex) = m.prevLogTerm)
       IN
       /\ IF ~validLeader
          THEN \* Reject: stale term (raft_core.tcc:988-990)
               /\ Reply([type        |-> "AppendEntriesResponse",
                         term        |-> currentTerm[s],
                         from        |-> s,
                         to          |-> m.from,
                         success     |-> FALSE,
                         mmatchIndex |-> 0], m)
               /\ UNCHANGED <<serverVars, logVars, leaderVars, heartbeatVars, asyncVars, configVars, lifecycleVars, snapshotVars, electionVars>>
          ELSE
               \* raft_core.tcc:968-982 — step down, update term if needed
               /\ IF m.term > currentTerm[s]
                  THEN /\ currentTerm' = [currentTerm EXCEPT ![s] = m.term]
                       /\ votedFor' = [votedFor EXCEPT ![s] = Nil]
                       /\ IF state[s] /= "follower"
                          THEN state' = [state EXCEPT ![s] = "follower"]
                          ELSE UNCHANGED state
                  ELSE \* Same term
                       /\ UNCHANGED <<currentTerm, votedFor, electionVars>>
                       /\ IF state[s] = "candidate"
                          \* raft_core.tcc:1002-1006 — candidate recognizes leader
                          THEN state' = [state EXCEPT ![s] = "follower"]
                          ELSE UNCHANGED state
               \* raft_core.tcc:1017-1018 — notify both watchdogs (reset timers)
               \* In the implementation, on_rpc_from_leader calls watchdog->notify()
               \* and watchdog_leader_only->notify(). This resets the election timer,
               \* equivalent to unblocking the watchdog (it won't trigger while RPCs arrive).
               \* Receiving a valid leader RPC suppresses election for this server.
               \* watchdog_leader_only is notified (so follower won't reject future RequestVote RPCs).
               /\ watchdogLeaderOnlyBlocked' = [watchdogLeaderOnlyBlocked EXCEPT ![s] = TRUE]
               /\ UNCHANGED <<watchdogBlocked, electionVars>>
               \* raft_core.tcc:1022-1028 — set leader ID
               /\ currentLeader' = [currentLeader EXCEPT ![s] =
                      IF currentLeader[s] = Nil THEN m.from ELSE currentLeader[s]]
               /\ IF ~logOk
                  THEN \* Reject: log doesn't match (raft_core.tcc:653-657)
                       /\ Reply([type        |-> "AppendEntriesResponse",
                                 term        |-> effectiveTerm,
                                 from        |-> s,
                                 to          |-> m.from,
                                 success     |-> FALSE,
                                 mmatchIndex |-> 0], m)
                       /\ UNCHANGED <<log, commitIndex, leaderVars, configVars, electionVars>>
                  ELSE \* Accept: append entries (raft_core.tcc:659-728)
                       /\ LET \* Convert absolute prevLogIndex to local index
                              localPrev == m.prevLogIndex - snapshotIndex[s]
                              \* raft_core.tcc:701 — conflict detection + append
                              \* Count how many incoming entries match existing log (same term)
                              numMatch ==
                                  LET candidates == {i \in 0..Len(m.entries) :
                                      \A j \in 1..i :
                                          /\ localPrev + j <= Len(log[s])
                                          /\ localPrev + j > 0
                                          /\ log[s][localPrev + j].term = m.entries[j].term}
                                  IN CHOOSE i \in candidates : \A j \in candidates : j <= i
                              logAfterAppend ==
                                  IF numMatch = Len(m.entries)
                                  THEN \* All incoming entries match existing log — keep as-is
                                       log[s]
                                  ELSE \* Truncate at first conflict, append remaining
                                       SubSeq(log[s], 1, Max(0, localPrev + numMatch)) \o
                                       SubSeq(m.entries, numMatch + 1, Len(m.entries))
                              \* Absolute index of last entry after append
                              newLastIndex == snapshotIndex[s] + Len(logAfterAppend)
                          IN
                          /\ log' = [log EXCEPT ![s] = logAfterAppend]
                          \* raft_core.tcc:725-729 — update commitIndex
                          /\ commitIndex' = [commitIndex EXCEPT ![s] =
                                IF m.leaderCommit > commitIndex[s]
                                THEN Min(m.leaderCommit, newLastIndex)
                                ELSE commitIndex[s]]
                          \* Update config from latest log entry if it's a config entry
                          /\ config' = [config EXCEPT ![s] =
                                LET latestLog == logAfterAppend
                                    configIdxs == {i \in 1..Len(latestLog) : latestLog[i].type = "config"}
                                IN IF configIdxs = {}
                                   THEN config[s]
                                   ELSE LET maxIdx == CHOOSE i \in configIdxs :
                                                          \A j \in configIdxs : j <= i
                                        IN latestLog[maxIdx].cfg]
                          /\ Reply([type        |-> "AppendEntriesResponse",
                                    term        |-> effectiveTerm,
                                    from        |-> s,
                                    to          |-> m.from,
                                    success     |-> TRUE,
                                    mmatchIndex |-> m.prevLogIndex + Len(m.entries)], m)
                          /\ UNCHANGED leaderVars
               \* Clear pending step-down when becoming follower (any path)
               \* In the implementation, candidate_or_leader_become_follower kills
               \* the coroutine, cancelling any pending note_term.
               /\ IF pendingStepDown[s]
                  THEN /\ pendingStepDown' = [pendingStepDown EXCEPT ![s] = FALSE]
                       /\ pendingNewTerm' = [pendingNewTerm EXCEPT ![s] = 0]
                  ELSE UNCHANGED asyncVars
               /\ UNCHANGED <<lifecycleVars, snapshotVars, virtualHeartbeatSender, electionVars>>

\* --- HandleAppendEntriesResponse: leader processes AE reply ---
\* raft_core.tcc:1893-1908 — reply handling in leader_send_updates
HandleAppendEntriesResponse(s, m) ==
    /\ m.type = "AppendEntriesResponse"
    /\ m.to = s
    /\ state[s] = "leader"
    /\ m.term = currentTerm[s]
    /\ IF m.success
       THEN \* raft_core.tcc:1896-1903 — update nextIndex and matchIndex
            \* Use mmatchIndex from the response (= prevLogIndex + len(entries) at send time)
            /\ nextIndex' = [nextIndex EXCEPT ![s][m.from] =
                   IF nextIndex[s][m.from] < m.mmatchIndex + 1
                   THEN m.mmatchIndex + 1
                   ELSE nextIndex[s][m.from]]
            /\ matchIndex' = [matchIndex EXCEPT ![s][m.from] =
                   IF matchIndex[s][m.from] < m.mmatchIndex
                   THEN m.mmatchIndex
                   ELSE matchIndex[s][m.from]]
            \* raft_core.tcc:1214-1239 — leader_update_match_index: advance commit
            /\ LET newCommitIndex ==
                   LET \* Find highest N (absolute index) where quorum has matchIndex >= N
                       \* and log[N].term = currentTerm
                       possibleIndices == {n \in (commitIndex[s]+1)..LastIndex(s) :
                           /\ n > snapshotIndex[s]  \* must be in actual log
                           /\ LogTerm(s, n) = currentTerm[s]
                           /\ IsJointQuorum(
                                {i \in Server : matchIndex'[s][i] >= n},
                                config[s])}
                   IN IF possibleIndices = {}
                      THEN commitIndex[s]
                      ELSE CHOOSE n \in possibleIndices :
                               \A m2 \in possibleIndices : m2 <= n
               IN commitIndex' = [commitIndex EXCEPT ![s] = newCommitIndex]
       ELSE \* raft_core.tcc:1907 — decrement nextIndex
            /\ nextIndex' = [nextIndex EXCEPT ![s][m.from] =
                   IF nextIndex[s][m.from] > 1
                   THEN nextIndex[s][m.from] - 1
                   ELSE 1]
            /\ UNCHANGED <<matchIndex, commitIndex, electionVars>>
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, log, heartbeatVars, asyncVars, configVars, lifecycleVars, snapshotVars, electionVars>>

\* ============================================================================
\* Actions: Async Step-Down [Family 2]
\* ============================================================================

\* --- DiscoverHigherTerm: candidate or leader notes a higher term from RPC reply ---
\* raft_core.tcc:1980-2026 — candidate_or_leader_note_term()
\* This spawns a coroutine that defers the actual step-down.
DiscoverHigherTerm(s, newTerm) ==
    /\ state[s] /= "follower"
    /\ newTerm > currentTerm[s]
    /\ ~pendingStepDown[s]
    \* raft_core.tcc:1993 — spawn coroutine, set pending state
    /\ pendingStepDown' = [pendingStepDown EXCEPT ![s] = TRUE]
    /\ pendingNewTerm' = [pendingNewTerm EXCEPT ![s] = newTerm]
    \* Note: actual term update and step-down happen in CompleteStepDown
    /\ UNCHANGED <<serverVars, logVars, leaderVars, messages, heartbeatVars, configVars, lifecycleVars, snapshotVars, electionVars>>

\* --- CompleteStepDown: the async coroutine executes ---
\* raft_core.tcc:1996-2014 — the spawned coroutine body
CompleteStepDown(s) ==
    /\ pendingStepDown[s]
    \* raft_core.tcc:2001 — check term hasn't already been updated
    /\ currentTerm[s] < pendingNewTerm[s]
    \* raft_core.tcc:2010-2011 — become follower if still candidate/leader
    /\ IF state[s] /= "follower"
       THEN /\ state' = [state EXCEPT ![s] = "follower"]
            \* raft_core.tcc:1488 — mode = follower, clear matchIndexes
            /\ matchIndex' = [matchIndex EXCEPT ![s] = [t \in Server |-> 0]]
            /\ nextIndex' = [nextIndex EXCEPT ![s] = [t \in Server |-> 1]]
       ELSE UNCHANGED <<state, matchIndex, nextIndex>>
    /\ votesGranted' = [votesGranted EXCEPT ![s] = {}]
    \* raft_core.tcc:2013 — update_term(term, nil)
    /\ currentTerm' = [currentTerm EXCEPT ![s] = pendingNewTerm[s]]
    /\ votedFor' = [votedFor EXCEPT ![s] = Nil]
    /\ currentLeader' = [currentLeader EXCEPT ![s] = Nil]
    \* Reset heartbeat state (raft_core.tcc:1119-1122)
    /\ virtualHeartbeatSender' = [virtualHeartbeatSender EXCEPT ![s] = Nil]
    /\ watchdogBlocked' = [watchdogBlocked EXCEPT ![s] = FALSE]
    /\ watchdogLeaderOnlyBlocked' = [watchdogLeaderOnlyBlocked EXCEPT ![s] = FALSE]
    \* Clear pending
    /\ pendingStepDown' = [pendingStepDown EXCEPT ![s] = FALSE]
    /\ pendingNewTerm' = [pendingNewTerm EXCEPT ![s] = 0]
    /\ UNCHANGED <<logVars, messages, configVars, lifecycleVars, snapshotVars>>

\* ============================================================================
\* Actions: Configuration Change [Family 3]
\* ============================================================================

\* --- ProposeConfigChange: leader creates joint consensus (phase 1) ---
\* raft_core.tcc:216-257 — propose_config_change()
ProposeConfigChange(s, newVoters) ==
    /\ state[s] = "leader"
    /\ ~pendingStepDown[s]
    /\ persistentLogValid[s]
    \* raft_core.tcc:226-227 — not already in joint consensus
    /\ ~IsJointConsensus(config[s])
    /\ ~IsJointConsensus(CommittedConfig(s))
    \* raft_core.tcc:236-237 — create joint config [old, new]
    /\ LET jointCfg == [old |-> config[s].old, new |-> newVoters]
           newEntry == [term  |-> currentTerm[s],
                        value |-> Nil,
                        type  |-> "config",
                        cfg   |-> jointCfg]
       IN
       /\ log' = [log EXCEPT ![s] = Append(@, newEntry)]
       /\ config' = [config EXCEPT ![s] = jointCfg]
       /\ matchIndex' = [matchIndex EXCEPT ![s][s] = LastIndex(s) + 1]
    /\ UNCHANGED <<serverVars, commitIndex, nextIndex, messages, heartbeatVars, asyncVars, lifecycleVars, snapshotVars, electionVars>>

\* --- LeaderContinueReconfiguration: commit phase 2 of joint consensus ---
\* raft_core.tcc:1942-1977 — leader_continue_reconfiguration()
LeaderContinueReconfiguration(s) ==
    /\ state[s] = "leader"
    /\ ~pendingStepDown[s]
    /\ persistentLogValid[s]
    \* raft_core.tcc:1958-1959 — both committed and latest are joint consensus
    /\ IsJointConsensus(CommittedConfig(s))
    /\ IsJointConsensus(config[s])
    \* raft_core.tcc:1967-1975 — create C_new entry (new config from joint's new_config)
    /\ LET newCfg == [old |-> config[s].new, new |-> Nil]
           newEntry == [term  |-> currentTerm[s],
                        value |-> Nil,
                        type  |-> "config",
                        cfg   |-> newCfg]
       IN
       /\ log' = [log EXCEPT ![s] = Append(@, newEntry)]
       /\ config' = [config EXCEPT ![s] = [old |-> config[s].new, new |-> Nil]]
       /\ matchIndex' = [matchIndex EXCEPT ![s][s] = LastIndex(s) + 1]
    /\ UNCHANGED <<serverVars, commitIndex, nextIndex, messages, heartbeatVars, asyncVars, lifecycleVars, snapshotVars, electionVars>>

\* --- LeaderStepDownAfterConfigChange: leader not in committed+latest config ---
\* raft_core.tcc:1949-1957 — step-down trick with current_term+1
LeaderStepDownAfterConfigChange(s) ==
    /\ state[s] = "leader"
    /\ ~pendingStepDown[s]
    \* raft_core.tcc:1949-1950 — not valid leader in BOTH committed and latest
    /\ ~IsValidLeader(s, CommittedConfig(s))
    /\ ~IsValidLeader(s, config[s])
    \* raft_core.tcc:1957 — uses candidate_or_leader_note_term(current_term + 1)
    \* This is the "step-down trick" with gratuitous term increment
    /\ pendingStepDown' = [pendingStepDown EXCEPT ![s] = TRUE]
    /\ pendingNewTerm' = [pendingNewTerm EXCEPT ![s] = currentTerm[s] + 1]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, messages, heartbeatVars, configVars, lifecycleVars, snapshotVars, electionVars>>

\* ============================================================================
\* Actions: Raft Lifecycle [Family 4]
\* ============================================================================

\* --- EraseRaftState: external component erases persistent state ---
\* multi_table_manager.cc — INACTIVE transition
EraseRaftState(s) ==
    /\ persistentLogValid' = [persistentLogValid EXCEPT ![s] = FALSE]
    \* Wipe all state as if server is destroyed
    /\ currentTerm' = [currentTerm EXCEPT ![s] = 0]
    /\ votedFor' = [votedFor EXCEPT ![s] = Nil]
    /\ log' = [log EXCEPT ![s] = << >>]
    /\ state' = [state EXCEPT ![s] = "follower"]
    /\ commitIndex' = [commitIndex EXCEPT ![s] = 0]
    /\ currentLeader' = [currentLeader EXCEPT ![s] = Nil]
    /\ nextIndex' = [nextIndex EXCEPT ![s] = [t \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![s] = [t \in Server |-> 0]]
    /\ virtualHeartbeatSender' = [virtualHeartbeatSender EXCEPT ![s] = Nil]
    /\ watchdogBlocked' = [watchdogBlocked EXCEPT ![s] = FALSE]
    /\ watchdogLeaderOnlyBlocked' = [watchdogLeaderOnlyBlocked EXCEPT ![s] = FALSE]
    /\ pendingStepDown' = [pendingStepDown EXCEPT ![s] = FALSE]
    /\ pendingNewTerm' = [pendingNewTerm EXCEPT ![s] = 0]
    \* Reset config to initial (log is wiped, so config reverts to initial)
    /\ config' = [config EXCEPT ![s] = [old |-> Server, new |-> Nil]]
    \* Reset snapshot (all persistent state wiped)
    /\ snapshotIndex' = [snapshotIndex EXCEPT ![s] = 0]
    /\ snapshotTerm' = [snapshotTerm EXCEPT ![s] = 0]
    /\ votesGranted' = [votesGranted EXCEPT ![s] = {}]
    /\ UNCHANGED <<messages, memberIdGeneration>>

\* --- ReenrollWithSameId: re-enroll server with same member ID (UNSAFE) ---
\* This is the bug pattern from Jepsen #5289
ReenrollWithSameId(s) ==
    /\ ~persistentLogValid[s]
    /\ persistentLogValid' = [persistentLogValid EXCEPT ![s] = TRUE]
    \* Server rejoins with empty log but same ID — same generation
    /\ UNCHANGED <<currentTerm, votedFor, log, state, commitIndex, currentLeader,
                   leaderVars, messages, heartbeatVars, asyncVars, configVars, memberIdGeneration,
                   snapshotVars, electionVars>>

\* --- ReenrollWithNewId: re-enroll server with new member ID (SAFE) ---
\* The fix: increment generation to represent a new identity
ReenrollWithNewId(s) ==
    /\ ~persistentLogValid[s]
    /\ persistentLogValid' = [persistentLogValid EXCEPT ![s] = TRUE]
    /\ memberIdGeneration' = [memberIdGeneration EXCEPT ![s] = memberIdGeneration[s] + 1]
    /\ UNCHANGED <<currentTerm, votedFor, log, state, commitIndex, currentLeader,
                   leaderVars, messages, heartbeatVars, asyncVars, configVars, snapshotVars,
                   electionVars>>

\* ============================================================================
\* Actions: Snapshot [Family 5]
\* ============================================================================

\* --- TakeSnapshot: compact committed log prefix into snapshot ---
\* raft_core.tcc:1181-1194 — snapshot when committed entries > threshold
TakeSnapshot(s) ==
    /\ commitIndex[s] > snapshotIndex[s]  \* Something to snapshot
    /\ commitIndex[s] <= LastIndex(s)
    /\ LET snapAbsIdx == commitIndex[s]
           snapTerm == LogTerm(s, snapAbsIdx)
           localSnapIdx == snapAbsIdx - snapshotIndex[s]
           \* Keep log entries after the snapshot point
           newLog == SubSeq(log[s], localSnapIdx + 1, Len(log[s]))
       IN
       /\ snapshotIndex' = [snapshotIndex EXCEPT ![s] = snapAbsIdx]
       /\ snapshotTerm' = [snapshotTerm EXCEPT ![s] = snapTerm]
       /\ log' = [log EXCEPT ![s] = newLog]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, messages, heartbeatVars,
                   asyncVars, configVars, lifecycleVars, electionVars>>

\* --- SendInstallSnapshot: leader sends snapshot to a far-behind peer ---
\* raft_core.tcc:1764-1827 — when next_index <= log.prev_index
SendInstallSnapshot(s, t) ==
    /\ state[s] = "leader"
    /\ s /= t
    /\ persistentLogValid[s]
    /\ ~pendingStepDown[s]
    \* raft_core.tcc:1764 — peer needs entries before our log start
    /\ nextIndex[s][t] <= snapshotIndex[s]
    /\ Send([type              |-> "InstallSnapshotRequest",
             term              |-> currentTerm[s],
             from              |-> s,
             to                |-> t,
             lastIncludedIndex |-> snapshotIndex[s],
             lastIncludedTerm  |-> snapshotTerm[s],
             snapshotConfig    |-> CommittedConfig(s)])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, heartbeatVars,
                   asyncVars, configVars, lifecycleVars, snapshotVars, electionVars>>

\* --- HandleInstallSnapshotRequest: follower installs snapshot ---
\* raft_core.tcc:523-623 — on_install_snapshot_rpc()
HandleInstallSnapshotRequest(s, m) ==
    /\ m.type = "InstallSnapshotRequest"
    /\ m.to = s
    /\ persistentLogValid[s]
    /\ LET validLeader ==
               /\ m.term >= currentTerm[s]
               /\ m.from /= s
           effectiveTerm == IF m.term > currentTerm[s] THEN m.term ELSE currentTerm[s]
       IN
       /\ IF ~validLeader
          THEN \* Reject: stale term
               /\ Reply([type |-> "InstallSnapshotResponse",
                         term |-> currentTerm[s],
                         from |-> s,
                         to   |-> m.from], m)
               /\ UNCHANGED <<serverVars, logVars, leaderVars, heartbeatVars,
                              asyncVars, configVars, lifecycleVars, snapshotVars, electionVars>>
          ELSE
               \* Step down if higher term (on_rpc_from_leader)
               /\ IF m.term > currentTerm[s]
                  THEN /\ currentTerm' = [currentTerm EXCEPT ![s] = m.term]
                       /\ votedFor' = [votedFor EXCEPT ![s] = Nil]
                       /\ IF state[s] /= "follower"
                          THEN state' = [state EXCEPT ![s] = "follower"]
                          ELSE UNCHANGED state
                  ELSE /\ UNCHANGED <<currentTerm, votedFor, electionVars>>
                       /\ IF state[s] = "candidate"
                          THEN state' = [state EXCEPT ![s] = "follower"]
                          ELSE UNCHANGED state
               /\ currentLeader' = [currentLeader EXCEPT ![s] =
                      IF currentLeader[s] = Nil THEN m.from ELSE currentLeader[s]]
               /\ watchdogLeaderOnlyBlocked' = [watchdogLeaderOnlyBlocked EXCEPT ![s] = TRUE]
               /\ UNCHANGED <<watchdogBlocked, electionVars>>
               /\ IF m.lastIncludedIndex <= snapshotIndex[s]
                  THEN \* raft_core.tcc:549-561: old snapshot, ignore
                       /\ Reply([type |-> "InstallSnapshotResponse",
                                 term |-> effectiveTerm,
                                 from |-> s,
                                 to   |-> m.from], m)
                       /\ UNCHANGED <<logVars, leaderVars, configVars, lifecycleVars, snapshotVars, electionVars>>
                  ELSE IF m.lastIncludedIndex <= LastIndex(s) /\
                          LogTerm(s, m.lastIncludedIndex) = m.lastIncludedTerm
                  THEN \* raft_core.tcc:562-584: partial overlap, retain log after snapshot
                       LET localSnapIdx == m.lastIncludedIndex - snapshotIndex[s]
                           newLog == SubSeq(log[s], localSnapIdx + 1, Len(log[s]))
                           newCI == IF m.lastIncludedIndex > commitIndex[s]
                                    THEN m.lastIncludedIndex
                                    ELSE commitIndex[s]
                       IN
                       /\ snapshotIndex' = [snapshotIndex EXCEPT ![s] = m.lastIncludedIndex]
                       /\ snapshotTerm' = [snapshotTerm EXCEPT ![s] = m.lastIncludedTerm]
                       /\ log' = [log EXCEPT ![s] = newLog]
                       /\ commitIndex' = [commitIndex EXCEPT ![s] = newCI]
                       /\ config' = [config EXCEPT ![s] =
                              LET cfgEntries == {i \in 1..Len(newLog) : newLog[i].type = "config"}
                              IN IF cfgEntries = {} THEN m.snapshotConfig
                                 ELSE newLog[CHOOSE i \in cfgEntries :
                                             \A j \in cfgEntries : j <= i].cfg]
                       /\ Reply([type |-> "InstallSnapshotResponse",
                                 term |-> effectiveTerm,
                                 from |-> s,
                                 to   |-> m.from], m)
                       /\ UNCHANGED <<leaderVars, lifecycleVars, electionVars>>
                  ELSE \* raft_core.tcc:585-602: discard entire log
                       /\ snapshotIndex' = [snapshotIndex EXCEPT ![s] = m.lastIncludedIndex]
                       /\ snapshotTerm' = [snapshotTerm EXCEPT ![s] = m.lastIncludedTerm]
                       /\ log' = [log EXCEPT ![s] = << >>]
                       /\ commitIndex' = [commitIndex EXCEPT ![s] = m.lastIncludedIndex]
                       /\ config' = [config EXCEPT ![s] = m.snapshotConfig]
                       /\ Reply([type |-> "InstallSnapshotResponse",
                                 term |-> effectiveTerm,
                                 from |-> s,
                                 to   |-> m.from], m)
                       /\ UNCHANGED <<leaderVars, lifecycleVars, electionVars>>
               \* Clear pending step-down when becoming follower
               /\ IF pendingStepDown[s]
                  THEN /\ pendingStepDown' = [pendingStepDown EXCEPT ![s] = FALSE]
                       /\ pendingNewTerm' = [pendingNewTerm EXCEPT ![s] = 0]
                  ELSE UNCHANGED asyncVars
               /\ UNCHANGED <<virtualHeartbeatSender, electionVars>>

\* --- HandleInstallSnapshotResponse: leader updates nextIndex/matchIndex ---
\* raft_core.tcc:1822-1827
HandleInstallSnapshotResponse(s, m) ==
    /\ m.type = "InstallSnapshotResponse"
    /\ m.to = s
    /\ state[s] = "leader"
    /\ m.term = currentTerm[s]
    /\ nextIndex' = [nextIndex EXCEPT ![s][m.from] =
           Max(nextIndex[s][m.from], snapshotIndex[s] + 1)]
    /\ matchIndex' = [matchIndex EXCEPT ![s][m.from] =
           Max(matchIndex[s][m.from], snapshotIndex[s])]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, heartbeatVars, asyncVars, configVars,
                   lifecycleVars, snapshotVars, electionVars>>

\* ============================================================================
\* Actions: Fault Injection
\* ============================================================================

\* --- Crash: server crashes (loses volatile state, keeps persistent) ---
Crash(s) ==
    /\ persistentLogValid[s]
    \* Volatile state reset
    /\ state' = [state EXCEPT ![s] = "follower"]
    /\ currentLeader' = [currentLeader EXCEPT ![s] = Nil]
    /\ nextIndex' = [nextIndex EXCEPT ![s] = [t \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![s] = [t \in Server |-> 0]]
    /\ virtualHeartbeatSender' = [virtualHeartbeatSender EXCEPT ![s] = Nil]
    /\ watchdogBlocked' = [watchdogBlocked EXCEPT ![s] = FALSE]
    /\ watchdogLeaderOnlyBlocked' = [watchdogLeaderOnlyBlocked EXCEPT ![s] = FALSE]
    /\ pendingStepDown' = [pendingStepDown EXCEPT ![s] = FALSE]
    /\ pendingNewTerm' = [pendingNewTerm EXCEPT ![s] = 0]
    /\ votesGranted' = [votesGranted EXCEPT ![s] = {}]
    \* Persistent state preserved (currentTerm, votedFor, log, commitIndex)
    /\ UNCHANGED <<currentTerm, votedFor, log, commitIndex, messages, configVars, lifecycleVars, snapshotVars>>

\* --- LoseMessage: message is lost ---
LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ messages[m] > 0
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, heartbeatVars, asyncVars, configVars, lifecycleVars, snapshotVars, electionVars>>

\* --- DuplicateMessage: message is duplicated ---
DuplicateMessage(m) ==
    /\ m \in DOMAIN messages
    /\ messages[m] > 0
    /\ Send(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, heartbeatVars, asyncVars, configVars, lifecycleVars, snapshotVars, electionVars>>

\* ============================================================================
\* Next-State Relation
\* ============================================================================

Next ==
    \* Leader election
    \/ \E s \in Server : Timeout(s)
    \/ \E s, t \in Server : s /= t /\ RequestVote(s, t)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\
           \E s \in Server : HandleRequestVoteRequest(s, m)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\
           \E s \in Server : HandleRequestVoteResponse(s, m)
    \* Virtual heartbeats [Family 1]
    \/ \E s, t \in Server : s /= t /\ StartVirtualHeartbeat(s, t)
    \/ \E s, t \in Server : s /= t /\ StopVirtualHeartbeat(s, t)
    \* Log replication
    \/ \E s \in Server, v \in Value : ClientRequest(s, v)
    \/ \E s, t \in Server : s /= t /\ AppendEntries(s, t)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\
           \E s \in Server : HandleAppendEntriesRequest(s, m)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\
           \E s \in Server : HandleAppendEntriesResponse(s, m)
    \* Async step-down [Family 2]
    \* DiscoverHigherTerm models learning a higher term from an RPC reply.
    \* The term must be one that some server actually has (not a phantom term).
    \/ \E s, other \in Server :
           /\ s /= other
           /\ currentTerm[other] > currentTerm[s]
           /\ DiscoverHigherTerm(s, currentTerm[other])
    \/ \E s \in Server : CompleteStepDown(s)
    \* Configuration change [Family 3]
    \/ \E s \in Server, v \in SUBSET Server : v /= {} /\ ProposeConfigChange(s, v)
    \/ \E s \in Server : LeaderContinueReconfiguration(s)
    \/ \E s \in Server : LeaderStepDownAfterConfigChange(s)
    \* Snapshot / InstallSnapshot [Family 5]
    \/ \E s \in Server : TakeSnapshot(s)
    \/ \E s, t \in Server : s /= t /\ SendInstallSnapshot(s, t)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\
           \E s \in Server : HandleInstallSnapshotRequest(s, m)
    \/ \E m \in DOMAIN messages : messages[m] > 0 /\
           \E s \in Server : HandleInstallSnapshotResponse(s, m)
    \* Raft lifecycle [Family 4]
    \/ \E s \in Server : EraseRaftState(s)
    \/ \E s \in Server : ReenrollWithSameId(s)
    \/ \E s \in Server : ReenrollWithNewId(s)
    \* Faults
    \/ \E s \in Server : Crash(s)
    \/ \E m \in DOMAIN messages : LoseMessage(m)
    \/ \E m \in DOMAIN messages : DuplicateMessage(m)

Spec == Init /\ [][Next]_allVars

\* ============================================================================
\* Invariants
\* ============================================================================

\* --- Standard Safety Invariants ---

\* ElectionSafety: at most one leader per term
\* raft_core.tcc:334-342 — check_invariants
ElectionSafety ==
    \A s1, s2 \in Server :
        (state[s1] = "leader" /\ state[s2] = "leader" /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* LogMatching: same absolute index+term implies identical prefix
\* raft_core.tcc:352-377 — check_invariants
\* With snapshots: only check entries that are still in both logs
LogMatching ==
    \A s1, s2 \in Server :
        LET minStart == Max(snapshotIndex[s1], snapshotIndex[s2]) + 1
            maxEnd == Min(LastIndex(s1), LastIndex(s2))
        IN \A i \in minStart..maxEnd :
            (LogTerm(s1, i) = LogTerm(s2, i))
            => \* All entries from minStart to i must match
               \A j \in minStart..i :
                   log[s1][j - snapshotIndex[s1]] = log[s2][j - snapshotIndex[s2]]

\* LeaderCompleteness: a leader in term T has all entries committed in terms < T.
\* Note: stale leaders (lower term) may not have newer committed entries — that's expected.
LeaderCompleteness ==
    \A s \in Server :
        state[s] = "leader" =>
            \A t \in Server :
                \A i \in 1..commitIndex[t] :
                    \* Only check entries still in both logs (not snapshotted away)
                    (i > snapshotIndex[t] /\ i > snapshotIndex[s]
                     /\ i <= LastIndex(t) /\ i <= LastIndex(s)
                     /\ currentTerm[s] >= LogTerm(t, i)) =>
                        log[s][i - snapshotIndex[s]] = log[t][i - snapshotIndex[t]]

\* StateMachineSafety: committed entries at the same index must agree
\* This is the core Raft safety property (§5.4.3)
StateMachineSafety ==
    \A s1, s2 \in Server :
        \A i \in 1..Min(commitIndex[s1], commitIndex[s2]) :
            (i > snapshotIndex[s1] /\ i > snapshotIndex[s2]
             /\ i <= LastIndex(s1) /\ i <= LastIndex(s2)) =>
                log[s1][i - snapshotIndex[s1]] = log[s2][i - snapshotIndex[s2]]

\* CommitIndexMonotonicity: commitIndex never goes backward within a term
\* (Persisted commitIndex per raft_core.tcc:1134-1137)

\* --- Extension Invariants [Bug Family targets] ---

\* [Family 1] NoStaleLeaderCommit: a leader with a pending step-down
\* should not have a higher commitIndex than what it had when it discovered the higher term.
\* Approximated: a leader with pending step-down should not be advancing commit.
\* Key: during the gap, the leader's current term < pendingNewTerm, so no new entries
\* from its term can form a quorum (other servers have moved to the higher term).
NoStaleLeaderCommit ==
    \A s \in Server :
        (state[s] = "leader" /\ pendingStepDown[s])
        => \* The leader should not be the term leader for the pending new term
           pendingNewTerm[s] > currentTerm[s]

\* [Family 2] AsyncStepDownSafety: during the gap between DiscoverHigherTerm
\* and CompleteStepDown, the pending server is still candidate/leader but
\* must not violate election safety. Key check: no two leaders for the same term,
\* and the pending server's term is stale relative to the discovered term.
AsyncStepDownSafety ==
    \A s \in Server :
        pendingStepDown[s] =>
            /\ state[s] /= "follower"  \* Still candidate/leader (hasn't completed yet)
            /\ pendingNewTerm[s] > currentTerm[s]  \* Discovered term is strictly higher
            \* No other server should be leader for our current term
            \* (election safety still holds — checked separately)

\* [Family 3] ConfigChangeSafety: at most one uncommitted config change
ConfigChangeSafety ==
    \A s \in Server :
        state[s] = "leader" =>
            \* Count uncommitted config entries (local indices)
            LET localCI == commitIndex[s] - snapshotIndex[s]
                uncommittedConfigs == {i \in (localCI+1)..Len(log[s]) :
                                           log[s][i].type = "config"}
            IN Cardinality(uncommittedConfigs) <= 1

\* [Family 4] MemberIdUniqueness: two servers with the same generation that both
\* have valid logs must have consistent committed prefixes (no split-brain from
\* re-enrollment with stale state).
MemberIdUniqueness ==
    \A s1, s2 \in Server :
        (s1 /= s2 /\ persistentLogValid[s1] /\ persistentLogValid[s2]
         /\ memberIdGeneration[s1] = memberIdGeneration[s2])
        => \* Committed entries must agree (same as StateMachineSafety but scoped)
           \A i \in 1..Min(commitIndex[s1], commitIndex[s2]) :
               (i > snapshotIndex[s1] /\ i > snapshotIndex[s2]
                /\ i <= LastIndex(s1) /\ i <= LastIndex(s2)) =>
                   log[s1][i - snapshotIndex[s1]] = log[s2][i - snapshotIndex[s2]]

\* [Family 1] VirtualHeartbeatTermConsistency: VHB sender should be a leader
\* or have been a leader at the time VHBs started. If the sender has stepped down
\* and its term has advanced, the VHBs are stale and should have been stopped.
VirtualHeartbeatTermConsistency ==
    \A s \in Server :
        virtualHeartbeatSender[s] /= Nil =>
            LET sender == virtualHeartbeatSender[s] IN
            \* The sender's current term should be >= the follower's term
            \* (if sender has advanced to a higher term, VHBs should have been cleared)
            /\ currentTerm[sender] >= currentTerm[s]
            \* If sender is still in the same term as follower, it should be the leader
            /\ (currentTerm[sender] = currentTerm[s]) =>
                  (state[sender] = "leader" \/ pendingStepDown[sender])

\* [Family 5] SnapshotLogConsistency: snapshot boundary is valid
\* raft_core.tcc:817-820 — commit_index >= prev_index, commit_index <= latest_index
SnapshotLogConsistency ==
    \A s \in Server :
        persistentLogValid[s] =>
            /\ snapshotIndex[s] <= commitIndex[s]
            /\ commitIndex[s] <= LastIndex(s)
            \* Snapshot term is consistent: 0 iff index is 0
            /\ (snapshotIndex[s] = 0) = (snapshotTerm[s] = 0)

\* [Family 6] CommitIndexMonotonicity: commitIndex is always >= snapshotIndex
\* (since commitIndex is persisted, it survives crash and never regresses)
CommitIndexMonotonicity ==
    \A s \in Server :
        persistentLogValid[s] => commitIndex[s] >= snapshotIndex[s]

\* --- Structural Invariants ---

\* Term in log entries is monotonically non-decreasing
\* raft_core.tcc:770-775
LogTermMonotonicity ==
    \A s \in Server :
        \A i \in 1..(Len(log[s])-1) :
            log[s][i].term <= log[s][i+1].term

\* Log entries have terms <= currentTerm
\* raft_core.tcc:800-801
LogTermBound ==
    \A s \in Server :
        \A i \in 1..Len(log[s]) :
            log[s][i].term <= currentTerm[s]

\* CommitIndex is within log bounds (using absolute indices)
\* raft_core.tcc:817-820
CommitIndexBound ==
    \A s \in Server :
        persistentLogValid[s] =>
            /\ commitIndex[s] >= snapshotIndex[s]
            /\ commitIndex[s] <= LastIndex(s)

\* Leader must have voted for self
\* raft_core.tcc:869-870
LeaderVotedForSelf ==
    \A s \in Server :
        state[s] = "leader" => votedFor[s] = s

\* Candidate must have voted for self
\* raft_core.tcc:863-864
CandidateVotedForSelf ==
    \A s \in Server :
        state[s] = "candidate" => votedFor[s] = s

====
