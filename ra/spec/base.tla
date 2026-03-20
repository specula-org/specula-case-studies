---- MODULE base ----
\*
\* TLA+ specification for rabbitmq/ra -- Erlang Raft consensus library
\* Models: leader election (with pre-vote), log replication, commit advancement,
\*         heartbeat-based consistent queries, single-server membership changes,
\*         and simplified snapshot installation.
\*
\* Source: artifact/ra/src/ra_server.erl (4190 lines)
\*
EXTENDS Integers, Sequences, FiniteSets, Bags, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANTS
    Server,         \* Set of server IDs
    Value,          \* Set of client request values
    Nil,            \* Sentinel value for "no vote" / "no leader"
    NilEntry        \* Sentinel for empty log entry

\* Server states
CONSTANTS
    Follower, PreVote, Candidate, Leader, ReceiveSnapshot, AwaitCondition

\* Message types
CONSTANTS
    PreVoteRequest, PreVoteResponse,
    RequestVoteRequest, RequestVoteResponse,
    AppendEntriesRequest, AppendEntriesResponse,
    HeartbeatRequest, HeartbeatResponse,
    InstallSnapshotRequest, InstallSnapshotResponse

\* Membership types
CONSTANTS
    MemberVoter, MemberNonVoter, MemberPromotable

\* Log entry types
CONSTANTS
    ValueEntry, ConfigEntry, NoopEntry

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Standard Raft persistent state (survives crashes) ---
VARIABLES
    currentTerm,    \* [Server -> Nat] current term
    votedFor,       \* [Server -> Server ∪ {Nil}] voted for in current term
    log             \* [Server -> Seq(Entry)] log entries [{term, value, type}]

\* --- Standard Raft volatile state ---
VARIABLES
    state,          \* [Server -> {Follower, PreVote, Candidate, Leader, ...}]
    commitIndex,    \* [Server -> Nat] highest committed index
    lastApplied     \* [Server -> Nat] highest applied index

\* --- Leader volatile state ---
VARIABLES
    nextIndex,      \* [Server -> [Server -> Nat]] next index to send to peer
    matchIndex      \* [Server -> [Server -> Nat]] highest replicated index per peer

\* --- Candidate state ---
VARIABLES
    votesGranted,       \* [Server -> SUBSET Server] votes received (real election)
    preVotesGranted     \* [Server -> SUBSET Server] pre-votes received

\* --- Network ---
VARIABLES
    messages        \* Bag of in-flight messages

\* --- Extension 1: Consistent Query Protocol [Bug Family 3] ---
\* Ra uses heartbeat-based linearizable reads: leader records commitIndex at query
\* time, sends heartbeats with query_index, waits for quorum of replies.
\* ra_server.erl:846-869 (consistent_query handler)
\* ra_server.erl:3747-3782 (heartbeat_rpc_quorum)
VARIABLES
    queryIndex,             \* [Server -> Nat] monotonic query counter
    peerQueryIndex,         \* [Server -> [Server -> Nat]] last confirmed query_index per peer
    queriesWaiting,         \* [Server -> Seq({qi, readCommitIdx})] pending queries
    clusterChangePermitted  \* [Server -> BOOLEAN] gates consistent queries + config changes

\* --- Extension 2: Non-Voter Membership [Bug Family 2] ---
\* Non-voters should not participate in elections or quorum.
\* ra_server.erl:3946-3959 (required_quorum, count_voters)
\* ra_server.erl:1448-1452 (follower ignores vote if non-voter)
VARIABLES
    membership      \* [Server -> {MemberVoter, MemberNonVoter, MemberPromotable}]

\* --- Extension 3: Pre-Vote Token [Bug Family 2] ---
\* Token-based correlation prevents stale pre-vote results from counting.
\* ra_server.erl:2860-2876 (call_for_election pre_vote with make_ref)
\* ra_server.erl:1154-1170 (token matching in handle_pre_vote)
VARIABLES
    preVoteToken    \* [Server -> Nat] unique token per pre-vote round (modeled as counter)

\* --- Extension 4: Snapshot Lifecycle [Bug Family 4] ---
\* Concurrent local snapshot write + remote install can corrupt state.
\* ra_server.erl:1503-1573, ra_log.erl:1004-1087
VARIABLES
    snapshotIndex,              \* [Server -> Nat] index covered by current snapshot
    snapshotTerm,               \* [Server -> Nat] term of entry at snapshotIndex (for LogTerm after truncation)
    pendingSnapshotWritten      \* [Server -> BOOLEAN] background snapshot write pending

\* --- Extension 5: Cluster Change Gating [Bug Family 5] ---
\* Single-server membership changes gated by clusterChangePermitted.
\* ra_server.erl:3538-3562 (append_cluster_change)
\* ra_server.erl:3290-3309 (apply_with cluster_change)
VARIABLES
    config,             \* [Server -> SUBSET Server] current cluster config
    previousConfig      \* [Server -> SUBSET Server ∪ {Nil}] for rollback on overwrite

\* --- Extension 6: Leader ID tracking ---
VARIABLES
    leaderId        \* [Server -> Server ∪ {Nil}] known leader

\* ============================================================================
\* VARIABLE GROUPS (for UNCHANGED clauses)
\* ============================================================================

serverVars      == <<currentTerm, votedFor, state, leaderId>>
logVars         == <<log, commitIndex, lastApplied>>
leaderVars      == <<nextIndex, matchIndex>>
candidateVars   == <<votesGranted, preVotesGranted>>
queryVars       == <<queryIndex, peerQueryIndex, queriesWaiting, clusterChangePermitted>>
membershipVars  == <<membership>>
preVoteVars     == <<preVoteToken>>
snapshotVars    == <<snapshotIndex, snapshotTerm, pendingSnapshotWritten>>
configVars      == <<config, previousConfig>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          queryVars, membershipVars, preVoteVars, snapshotVars, configVars>>

\* ============================================================================
\* HELPERS
\* ============================================================================

\* --- Utility ---
Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b

\* --- Log Helpers ---
\* Offset-based log model: after snapshot install at index S, log[i] contains
\* only entries after S. Physical log[i][k] = logical entry at index S+k.
\* LastLogIndex returns the logical index of the last entry.
LastLogIndex(i) == snapshotIndex[i] + Len(log[i])
LastLogTerm(i)  == IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term
                   ELSE snapshotTerm[i]

\* LogTerm returns the term at a given logical index.
\* Entries at indices <= snapshotIndex are covered by the snapshot.
LogTerm(i, idx) ==
    IF idx = snapshotIndex[i] /\ snapshotIndex[i] > 0 THEN snapshotTerm[i]
    ELSE IF idx < 1 \/ idx > LastLogIndex(i) \/ idx <= snapshotIndex[i] THEN 0
    ELSE log[i][idx - snapshotIndex[i]].term

\* An entry record
Entry(t, v, ty) == [term |-> t, value |-> v, type |-> ty]

\* --- Message Bag Helpers ---
Send(m) == messages' = messages (+) SetToBag({m})
SendAll(ms) == messages' = messages (+) SetToBag(ms)
Discard(m) == messages' = messages (-) SetToBag({m})
Reply(resp, req) ==
    messages' = (messages (-) SetToBag({req})) (+) SetToBag({resp})
DiscardAndSendAll(discard, sends) ==
    messages' = (messages (-) SetToBag({discard})) (+) SetToBag(sends)

\* --- Quorum Helpers ---
\* ra_server.erl:3946-3959 -- only voters counted in quorum
\* [Bug Family 2] Non-voter exclusion
VoterSet(cfg) == {s \in cfg : membership[s] = MemberVoter}

IsQuorum(subset, cfg) ==
    LET voters == VoterSet(cfg)
    IN 2 * Cardinality(subset \cap voters) > Cardinality(voters)

\* ra_server.erl:3946 -- required_quorum = trunc(Voters / 2) + 1
RequiredQuorum(cfg) ==
    LET voters == VoterSet(cfg)
    IN (Cardinality(voters) \div 2) + 1

\* --- Log Comparison ---
\* ra_server.erl: is_candidate_log_up_to_date/3
\* Standard Raft: candidate log must be at least as up-to-date
IsLogUpToDate(candidateLastTerm, candidateLastIdx, myLastTerm, myLastIdx) ==
    \/ candidateLastTerm > myLastTerm
    \/ (candidateLastTerm = myLastTerm /\ candidateLastIdx >= myLastIdx)

\* --- Agreed Commit (median of match indexes) ---
\* ra_server.erl:3598-3607 (increment_commit_index)
\* ra_server.erl:3570-3596 (agreed_commit via sorted median)
AgreedCommit(i) ==
    LET matchSet == {matchIndex[i][s] : s \in config[i] \ {i}} \cup {LastLogIndex(i)}
        voters   == VoterSet(config[i])
        voterMatchSet == {matchIndex[i][s] : s \in (voters \ {i})} \cup {LastLogIndex(i)}
    IN  CHOOSE idx \in voterMatchSet :
            /\ 2 * Cardinality({s \in voters :
                    (IF s = i THEN LastLogIndex(i) ELSE matchIndex[i][s]) >= idx})
               > Cardinality(voters)
            /\ \A idx2 \in voterMatchSet :
                (2 * Cardinality({s \in voters :
                    (IF s = i THEN LastLogIndex(i) ELSE matchIndex[i][s]) >= idx2})
                 > Cardinality(voters))
                => idx >= idx2

\* --- Query Index Quorum ---
\* ra_server.erl:3770-3782 (get_current_query_quorum)
\* [Bug Family 3] Uses same agreed_commit pattern on query indexes
QueryQuorum(i) ==
    LET voters == VoterSet(config[i])
        qiSet  == {peerQueryIndex[i][s] : s \in (voters \ {i})} \cup {queryIndex[i]}
    IN  CHOOSE qi \in qiSet :
            /\ 2 * Cardinality({s \in voters :
                    (IF s = i THEN queryIndex[i] ELSE peerQueryIndex[i][s]) >= qi})
               > Cardinality(voters)
            /\ \A qi2 \in qiSet :
                (2 * Cardinality({s \in voters :
                    (IF s = i THEN queryIndex[i] ELSE peerQueryIndex[i][s]) >= qi2})
                 > Cardinality(voters))
                => qi >= qi2

\* --- Peer set helper ---
PeerIds(i) == config[i] \ {i}

\* ============================================================================
\* INITIAL STATE
\* ============================================================================

Init ==
    /\ currentTerm  = [s \in Server |-> 0]
    /\ votedFor     = [s \in Server |-> Nil]
    /\ log          = [s \in Server |-> <<>>]
    /\ state        = [s \in Server |-> Follower]
    /\ commitIndex  = [s \in Server |-> 0]
    /\ lastApplied  = [s \in Server |-> 0]
    /\ nextIndex    = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex   = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted     = [s \in Server |-> {}]
    /\ preVotesGranted  = [s \in Server |-> {}]
    /\ messages     = EmptyBag
    \* Extension 1: Consistent Query [Bug Family 3]
    /\ queryIndex           = [s \in Server |-> 0]
    /\ peerQueryIndex       = [s \in Server |-> [t \in Server |-> 0]]
    /\ queriesWaiting       = [s \in Server |-> <<>>]
    /\ clusterChangePermitted = [s \in Server |-> FALSE]
    \* Extension 2: Membership [Bug Family 2]
    /\ membership   = [s \in Server |-> MemberVoter]
    \* Extension 3: Pre-Vote Token [Bug Family 2]
    /\ preVoteToken = [s \in Server |-> 0]
    \* Extension 4: Snapshot [Bug Family 4]
    /\ snapshotIndex            = [s \in Server |-> 0]
    /\ snapshotTerm             = [s \in Server |-> 0]
    /\ pendingSnapshotWritten   = [s \in Server |-> FALSE]
    \* Extension 5: Cluster Change [Bug Family 5]
    /\ config           = [s \in Server |-> Server]
    /\ previousConfig   = [s \in Server |-> Nil]
    \* Extension 6: Leader tracking
    /\ leaderId     = [s \in Server |-> Nil]

\* ============================================================================
\* TERM UPDATE
\* ============================================================================

\* ra_server.erl:2945-2965 -- update_term / update_term_and_voted_for
\* Term change atomically clears voted_for (DETS batch via ra_log_meta)
UpdateTerm(i, term) ==
    /\ currentTerm' = [currentTerm EXCEPT ![i] = term]
    /\ votedFor'    = [votedFor EXCEPT ![i] = Nil]

UpdateTermAndVotedFor(i, term, candidate) ==
    /\ currentTerm' = [currentTerm EXCEPT ![i] = term]
    /\ votedFor'    = [votedFor EXCEPT ![i] = candidate]

\* ============================================================================
\* ELECTIONS: PRE-VOTE PHASE [Bug Family 2]
\* ============================================================================

\* --- CallForElection(pre_vote) ---
\* ra_server.erl:2860-2880 -- call_for_election(pre_vote, ...)
\* Pre-vote does NOT increment term (line 2866: term = Term, not Term+1)
\* Generates unique token via make_ref() (line 2862)
\* Sets voted_for to self even in pre_vote (line 2876)
CallForPreVote(i) ==
    /\ state[i] \in {Follower, PreVote, Candidate}
    /\ membership[i] = MemberVoter  \* ra_server.erl:1164 -- voter guard
    /\ LET newToken == preVoteToken[i] + 1
       IN
       /\ state' = [state EXCEPT ![i] = PreVote]
       /\ preVoteToken' = [preVoteToken EXCEPT ![i] = newToken]
       /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {i}]  \* self-vote
       /\ votedFor' = [votedFor EXCEPT ![i] = i]  \* ra_server.erl:2876
       /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
       /\ SendAll({[mtype        |-> PreVoteRequest,
                    mterm        |-> currentTerm[i],  \* current term, NOT incremented
                    mlastLogTerm |-> LastLogTerm(i),
                    mlastLogIndex|-> LastLogIndex(i),
                    mtoken       |-> newToken,
                    msource      |-> i,
                    mdest        |-> j] : j \in PeerIds(i)})
       /\ UNCHANGED <<currentTerm, log, commitIndex, lastApplied,
                       leaderVars, votesGranted, queryVars,
                       membershipVars, snapshotVars, configVars>>

\* --- HandlePreVoteRequest ---
\* ra_server.erl:2927-2990 -- process_pre_vote (called from follower/candidate/pre_vote/etc)
\* Leaders handle pre-vote differently: see LeaderStepDown (higher term) and
\* LeaderIgnorePreVote (same/lower term) -- ra_server.erl:949-969
\* Checks: term >= currentTerm, log up-to-date, membership compatibility
HandlePreVoteRequest(i, m) ==
    /\ m.mtype = PreVoteRequest
    /\ state[i] /= Leader  \* Leaders have separate handlers (lines 949-969)
    /\ LET grant == /\ m.mterm >= currentTerm[i]
                     /\ membership[i] = MemberVoter  \* ra_server.erl:2920
                     /\ IsLogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                      LastLogTerm(i), LastLogIndex(i))
           reply == [mtype        |-> PreVoteResponse,
                     mterm        |-> currentTerm[i],
                     mvoteGranted |-> grant,
                     mtoken       |-> m.mtoken,
                     msource      |-> i,
                     mdest        |-> m.msource]
       IN
       /\ Reply(reply, m)
       \* ra_server.erl:2956 -- sets voted_for to candidate on grant
       /\ IF grant
          THEN votedFor' = [votedFor EXCEPT ![i] = m.msource]
          ELSE UNCHANGED votedFor
       \* ra_server.erl:2938 -- update_term: update term if higher
       /\ IF m.mterm > currentTerm[i]
          THEN /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
               \* Term change invalidates any in-progress election votes.
               \* In impl, stale vote_results are rejected by term matching in
               \* handle_candidate (line 1044: current_term := Term pattern match).
               \* In spec, we clear votesGranted/preVotesGranted to prevent
               \* BecomeLeader from firing with stale votes.
               /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
               /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
          ELSE UNCHANGED <<currentTerm, votesGranted, preVotesGranted>>
       /\ UNCHANGED <<state, leaderId, log, commitIndex, lastApplied,
                       leaderVars, queryVars,
                       membershipVars, preVoteVars, snapshotVars, configVars>>

\* --- HandlePreVoteResponse ---
\* ra_server.erl:1206-1238 -- handle_pre_vote(#pre_vote_result{...})
\* Erlang pattern matching order: higher-term check (1206) fires before vote counting (1216)
\* Token MUST match (line 1221: pre_vote_token := Token)
HandlePreVoteResponse(i, m) ==
    /\ m.mtype = PreVoteResponse
    /\ state[i] = PreVote
    /\ \/ \* Case 1: Higher term -- step down to follower
          \* ra_server.erl:1206-1211 -- pre_vote_result with Term > CurTerm
          /\ m.mterm > currentTerm[i]
          /\ UpdateTerm(i, m.mterm)
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<log, commitIndex, lastApplied, leaderVars,
                          candidateVars, queryVars, membershipVars,
                          preVoteVars, snapshotVars, configVars>>
       \/ \* Case 2: Vote granted with matching term + token
          \* ra_server.erl:1216-1237 -- term = currentTerm, vote_granted = true, token match
          /\ m.mterm = currentTerm[i]
          /\ m.mvoteGranted = TRUE
          /\ m.mtoken = preVoteToken[i]  \* Token correlation [Bug Family 2]
          /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = @ \cup {m.msource}]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, votesGranted,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>
       \/ \* Case 3: Not granted, token mismatch, or stale term -- ignore
          \* ra_server.erl:1238 -- catch-all for other pre_vote_results
          /\ m.mterm = currentTerm[i]
          /\ \/ m.mvoteGranted = FALSE
             \/ m.mtoken /= preVoteToken[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>

\* --- WinPreVote -- escalate to real election ---
\* ra_server.erl:1163-1170 -- NewVotes matches required_quorum → call_for_election(candidate)
WinPreVote(i) ==
    /\ state[i] = PreVote
    /\ membership[i] = MemberVoter
    /\ IsQuorum(preVotesGranted[i], config[i])
    \* Escalate: call_for_election(candidate) increments term
    \* ra_server.erl:2834-2858
    /\ LET newTerm == currentTerm[i] + 1
       IN
       /\ UpdateTermAndVotedFor(i, newTerm, i)
       /\ state' = [state EXCEPT ![i] = Candidate]
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]  \* self-vote
       /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
       /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
       /\ SendAll({[mtype        |-> RequestVoteRequest,
                    mterm        |-> newTerm,
                    mlastLogTerm |-> LastLogTerm(i),
                    mlastLogIndex|-> LastLogIndex(i),
                    msource      |-> i,
                    mdest        |-> j] : j \in PeerIds(i)})
       /\ UNCHANGED <<log, commitIndex, lastApplied, leaderVars,
                       queryVars, membershipVars, preVoteVars,
                       snapshotVars, configVars>>

\* ============================================================================
\* ELECTIONS: REAL VOTE PHASE
\* ============================================================================

\* --- HandleRequestVoteRequest ---
\* ra_server.erl:1448-1494 -- handle_follower(#request_vote_rpc{...})
\* [Bug Family 2] Non-voters silently ignore (line 1448-1452)
HandleRequestVoteRequest(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ \/ \* Case 1: Non-voter ignores vote request
          \* ra_server.erl:1448-1452
          /\ membership[i] /= MemberVoter
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>
       \/ \* Case 2: Lower term -- reject
          /\ membership[i] = MemberVoter
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>
       \/ \* Case 3: Same term, already voted for different candidate
          \* ra_server.erl:1456-1460
          /\ membership[i] = MemberVoter
          /\ m.mterm = currentTerm[i]
          /\ votedFor[i] /= Nil
          /\ votedFor[i] /= m.msource
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>
       \/ \* Case 4: Grant vote (term >= current, log up-to-date, haven't voted for someone else)
          \* ra_server.erl:1462-1486
          /\ membership[i] = MemberVoter
          /\ m.mterm >= currentTerm[i]
          /\ \/ votedFor[i] = Nil
             \/ votedFor[i] = m.msource
             \/ m.mterm > currentTerm[i]  \* higher term clears votedFor
          /\ IsLogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                           LastLogTerm(i), LastLogIndex(i))
          /\ UpdateTermAndVotedFor(i, m.mterm, m.msource)
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> m.mterm,
                    mvoteGranted |-> TRUE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<log, commitIndex, lastApplied, leaderVars,
                          candidateVars, queryVars, membershipVars,
                          preVoteVars, snapshotVars, configVars>>
       \/ \* Case 5: Reject vote (term >= current but log not up-to-date)
          \* ra_server.erl:1488-1494
          /\ membership[i] = MemberVoter
          /\ m.mterm >= currentTerm[i]
          /\ ~IsLogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                            LastLogTerm(i), LastLogIndex(i))
          /\ IF m.mterm > currentTerm[i]
             THEN /\ UpdateTerm(i, m.mterm)
                  /\ state' = [state EXCEPT ![i] = Follower]
                  /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
             ELSE UNCHANGED <<currentTerm, votedFor, state, leaderId>>
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> m.mterm,
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<log, commitIndex, lastApplied, leaderVars,
                          candidateVars, queryVars, membershipVars,
                          preVoteVars, snapshotVars, configVars>>

\* --- HandleRequestVoteResponse ---
\* ra_server.erl:1026-1065 -- handle_candidate(#request_vote_result{...})
HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ state[i] = Candidate
    /\ \/ \* Case 1: Higher term -- step down
          \* ra_server.erl:1046-1058
          /\ m.mterm > currentTerm[i]
          /\ UpdateTerm(i, m.mterm)
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<log, commitIndex, lastApplied, leaderVars,
                          candidateVars, queryVars, membershipVars,
                          preVoteVars, snapshotVars, configVars>>
       \/ \* Case 2: Vote granted in current term
          \* ra_server.erl:1028-1044
          /\ m.mterm = currentTerm[i]
          /\ m.mvoteGranted = TRUE
          /\ votesGranted' = [votesGranted EXCEPT ![i] = @ \cup {m.msource}]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, preVotesGranted,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>
       \/ \* Case 3: Vote denied or stale term
          /\ \/ m.mvoteGranted = FALSE
             \/ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>

\* --- BecomeLeader ---
\* ra_server.erl:1037-1045 -- exact quorum match (NewVotes pattern match)
\* ra_server.erl:2973-2995 -- initialise_peers
BecomeLeader(i) ==
    /\ state[i] = Candidate
    /\ membership[i] = MemberVoter  \* [Bug Family 2] defense-in-depth
    /\ IsQuorum(votesGranted[i], config[i])
    /\ state' = [state EXCEPT ![i] = Leader]
    /\ leaderId' = [leaderId EXCEPT ![i] = i]
    \* ra_server.erl:2980 -- nextIndex = ra_log:next_index(Log) = Len(log)+1
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> LastLogIndex(i) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    \* Noop appended separately via LeaderAppendNoop (trace captures it as client_request)
    /\ UNCHANGED log
    \* [Bug Family 3] ra_server.erl:342 -- cluster_change_permitted := false on new leader
    \* Must commit noop before permitting config changes or consistent queries
    /\ clusterChangePermitted' = [clusterChangePermitted EXCEPT ![i] = FALSE]
    \* [Bug Family 3] ra_server.erl:3719-3722 -- reset_query_index
    /\ queryIndex' = [queryIndex EXCEPT ![i] = 0]
    /\ peerQueryIndex' = [peerQueryIndex EXCEPT ![i] =
                            [j \in Server |-> 0]]
    /\ queriesWaiting' = [queriesWaiting EXCEPT ![i] = <<>>]
    /\ UNCHANGED <<currentTerm, votedFor, commitIndex, lastApplied,
                    candidateVars, messages, membershipVars, preVoteVars,
                    snapshotVars, configVars>>

\* --- CandidateStepDown ---
\* ra_server.erl:1066-1090 -- candidate receives AER with term >= current
CandidateStepDown(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ state[i] = Candidate
    /\ m.mterm >= currentTerm[i]
    \* ra_server.erl:1070 -- update_term_and_voted_for(Term, undefined, ...)
    /\ UpdateTerm(i, m.mterm)
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ leaderId' = [leaderId EXCEPT ![i] = m.msource]
    \* Re-process as follower (modeled by leaving message in bag)
    /\ UNCHANGED <<log, commitIndex, lastApplied, leaderVars, candidateVars,
                    messages, queryVars, membershipVars, preVoteVars,
                    snapshotVars, configVars>>

\* ============================================================================
\* LOG REPLICATION
\* ============================================================================

\* --- ClientRequest ---
\* Leader appends a new value entry
ClientRequest(i, v) ==
    /\ state[i] = Leader
    /\ log' = [log EXCEPT ![i] = Append(@, Entry(currentTerm[i], v, ValueEntry))]
    /\ UNCHANGED <<serverVars, commitIndex, lastApplied, leaderVars,
                    candidateVars, messages, queryVars, membershipVars,
                    preVoteVars, snapshotVars, configVars>>

\* --- ReplicateEntries ---
\* ra_server.erl: leader sends AppendEntriesRPC to a peer
\* Includes prevLogIndex, prevLogTerm, entries, commitIndex
ReplicateEntries(i, j) ==
    /\ state[i] = Leader
    /\ j \in PeerIds(i)
    /\ j /= i
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == LogTerm(i, prevIdx)
           \* Physical indices: log[i][k] is logical index snapshotIndex[i]+k
           entries  == IF nextIndex[i][j] > LastLogIndex(i)
                       THEN <<>>
                       ELSE IF nextIndex[i][j] <= snapshotIndex[i]
                       THEN <<>>  \* entries before snapshot -- use InstallSnapshot instead
                       ELSE SubSeq(log[i], nextIndex[i][j] - snapshotIndex[i], Len(log[i]))
       IN
       Send([mtype         |-> AppendEntriesRequest,
             mterm         |-> currentTerm[i],
             mprevLogIndex |-> prevIdx,
             mprevLogTerm  |-> prevTerm,
             mentries      |-> entries,
             mcommitIndex  |-> commitIndex[i],
             msource       |-> i,
             mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                    queryVars, membershipVars, preVoteVars, snapshotVars,
                    configVars>>

\* --- HandleAppendEntriesRequest ---
\* ra_server.erl:1247-1405 -- handle_follower(#append_entries_rpc{...})
\* [Bug Family 1] Key deviation: commit_index set directly from LeaderCommit
\* without min(LeaderCommit, lastNewEntryIndex) -- bounded at apply time
HandleAppendEntriesRequest(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ state[i] \in {Follower, AwaitCondition, PreVote, Candidate}
    /\ \/ \* Case 1: Lower term -- reject
          \* ra_server.erl:1405-1410
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype     |-> AppendEntriesResponse,
                    mterm     |-> currentTerm[i],
                    msuccess  |-> FALSE,
                    mmatchIndex |-> 0,
                    msource   |-> i,
                    mdest     |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>
       \/ \* Case 2: Term OK but prevLog doesn't match -- reject
          \* ra_server.erl:1359-1390 -- {missing, _} or {term_mismatch, _, _}
          /\ m.mterm >= currentTerm[i]
          /\ \/ m.mprevLogIndex > LastLogIndex(i)
             \/ (m.mprevLogIndex > 0 /\ LogTerm(i, m.mprevLogIndex) /= m.mprevLogTerm)
          /\ IF m.mterm > currentTerm[i]
             THEN UpdateTerm(i, m.mterm)
             ELSE UNCHANGED <<currentTerm, votedFor>>
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ leaderId' = [leaderId EXCEPT ![i] = m.msource]
          /\ Reply([mtype     |-> AppendEntriesResponse,
                    mterm     |-> m.mterm,
                    msuccess  |-> FALSE,
                    mmatchIndex |-> 0,
                    msource   |-> i,
                    mdest     |-> m.msource], m)
          /\ UNCHANGED <<log, commitIndex, lastApplied, leaderVars,
                          candidateVars, queryVars, membershipVars,
                          preVoteVars, snapshotVars, configVars>>
       \/ \* Case 3: Accept entries
          \* ra_server.erl:1260-1357 -- {entry_ok, _} path
          /\ m.mterm >= currentTerm[i]
          \* prevLogIndex must be at or after snapshot point (entries before snapshot
          \* no longer exist; use InstallSnapshot for those)
          /\ m.mprevLogIndex >= snapshotIndex[i]
          /\ \/ m.mprevLogIndex = 0
             \/ (m.mprevLogIndex <= LastLogIndex(i)
                 /\ LogTerm(i, m.mprevLogIndex) = m.mprevLogTerm)
          /\ IF m.mterm > currentTerm[i]
             THEN UpdateTerm(i, m.mterm)
             ELSE UNCHANGED <<currentTerm, votedFor>>
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ leaderId' = [leaderId EXCEPT ![i] = m.msource]
          \* Merge entries: Raft paper §5.3 steps 3-4
          \* ra_server.erl:1263-1275 -- drop_existing + write
          \* Step 3: If existing entry conflicts (same index, different term), delete it
          \* Step 4: Append new entries not already in the log
          \* Must handle stale AERs: if entries already present with matching terms,
          \* do NOT truncate (stale AER from before leader appended more entries)
          \* Offset model: log[i][k] is logical index snapshotIndex[i]+k
          /\ IF Len(m.mentries) = 0
             THEN UNCHANGED log  \* No entries: heartbeat AER, log unchanged
             ELSE LET baseIdx == m.mprevLogIndex
                      \* Physical base: number of existing log entries before new entries
                      physBase == baseIdx - snapshotIndex[i]
                      \* Check if log already has all incoming entries with matching terms
                      alreadyPresent ==
                          /\ baseIdx + Len(m.mentries) <= LastLogIndex(i)
                          /\ \A k \in 1..Len(m.mentries) :
                                log[i][physBase + k].term = m.mentries[k].term
                  IN IF alreadyPresent
                     THEN UNCHANGED log  \* All entries match, stale AER
                     ELSE LET newLog == [idx \in 1..(physBase + Len(m.mentries)) |->
                                            IF idx <= physBase
                                            THEN log[i][idx]
                                            ELSE m.mentries[idx - physBase]]
                          IN log' = [log EXCEPT ![i] = newLog]
          \* [Bug Family 1] ra_server.erl:1296,1330 -- commit_index := LeaderCommit
          \* Paper deviation: no min(LeaderCommit, lastNewEntry)
          /\ commitIndex' = [commitIndex EXCEPT ![i] = m.mcommitIndex]
          /\ Reply([mtype     |-> AppendEntriesResponse,
                    mterm     |-> m.mterm,
                    msuccess  |-> TRUE,
                    mmatchIndex |-> m.mprevLogIndex + Len(m.mentries),
                    msource   |-> i,
                    mdest     |-> m.msource], m)
          /\ UNCHANGED <<lastApplied, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>

\* --- HandleAppendEntriesResponse ---
\* ra_server.erl: leader handles follower's AER reply
HandleAppendEntriesResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ state[i] = Leader
    /\ \/ \* Case 1: Higher term -- step down
          /\ m.mterm > currentTerm[i]
          /\ UpdateTerm(i, m.mterm)
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<log, commitIndex, lastApplied, leaderVars,
                          candidateVars, queryVars, membershipVars,
                          preVoteVars, snapshotVars, configVars>>
       \/ \* Case 2: Success in current term -- update matchIndex/nextIndex
          /\ m.mterm = currentTerm[i]
          /\ m.msuccess = TRUE
          /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] =
                                IF m.mmatchIndex > @ THEN m.mmatchIndex ELSE @]
          /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] =
                                IF m.mmatchIndex + 1 > @ THEN m.mmatchIndex + 1 ELSE @]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, log, commitIndex, lastApplied,
                          candidateVars, queryVars, membershipVars,
                          preVoteVars, snapshotVars, configVars>>
       \/ \* Case 3: Failure in current term -- decrement nextIndex
          /\ m.mterm = currentTerm[i]
          /\ m.msuccess = FALSE
          /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] =
                                IF @ > 1 THEN @ - 1 ELSE 1]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, log, commitIndex, lastApplied,
                          matchIndex, candidateVars, queryVars,
                          membershipVars, preVoteVars, snapshotVars,
                          configVars>>
       \/ \* Case 4: Stale term -- ignore
          /\ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>

\* ============================================================================
\* COMMIT ADVANCEMENT
\* ============================================================================

\* --- AdvanceCommitIndex (leader) ---
\* ra_server.erl:3598-3607 -- increment_commit_index
\* ra_server.erl:3570-3596 -- agreed_commit via sorted median
\* Standard Raft §5.4.2: only commit entries from current term
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET voters == VoterSet(config[i])
           si == snapshotIndex[i]
           \* Find highest index agreed by majority of voters
           \* Only check entries in physical log (after snapshot)
           newCommitIdx ==
               CHOOSE idx \in 0..LastLogIndex(i) :
                   /\ \/ idx = 0
                      \/ /\ idx > si
                         /\ log[i][idx - si].term = currentTerm[i]
                         /\ 2 * Cardinality({s \in voters :
                               (IF s = i THEN LastLogIndex(i)
                                ELSE matchIndex[i][s]) >= idx})
                            > Cardinality(voters)
                   /\ \A idx2 \in (si+1)..LastLogIndex(i) :
                       (/\ log[i][idx2 - si].term = currentTerm[i]
                        /\ 2 * Cardinality({s \in voters :
                               (IF s = i THEN LastLogIndex(i)
                                ELSE matchIndex[i][s]) >= idx2})
                            > Cardinality(voters))
                       => idx >= idx2
       IN
       /\ newCommitIdx > commitIndex[i]
       /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
       \* [Bug Family 5] ra_server.erl:3290-3309 -- cluster_change_permitted := true on commit
       /\ IF \E idx \in (commitIndex[i]+1)..newCommitIdx :
                idx > si /\ log[i][idx - si].type = ConfigEntry
          THEN clusterChangePermitted' = [clusterChangePermitted EXCEPT ![i] = TRUE]
          ELSE UNCHANGED clusterChangePermitted
    /\ UNCHANGED <<serverVars, log, lastApplied, leaderVars, candidateVars,
                    messages, queryIndex, peerQueryIndex, queriesWaiting,
                    membershipVars, preVoteVars, snapshotVars, configVars>>

\* --- ApplyEntries (follower/leader) ---
\* ra_server.erl:2212-2246 -- evaluate_commit_index_follower
\* [Bug Family 1] ApplyTo = min(Idx, CommitIndex) -- bounded at apply time
ApplyEntries(i) ==
    /\ lastApplied[i] < commitIndex[i]
    /\ lastApplied[i] < LastLogIndex(i)
    /\ LET applyTo == IF commitIndex[i] < LastLogIndex(i)
                       THEN commitIndex[i]
                       ELSE LastLogIndex(i)
       IN
       /\ lastApplied' = [lastApplied EXCEPT ![i] = applyTo]
       \* [Bug Family 3] If leader commits noop, enable cluster changes + queries
       /\ IF /\ state[i] = Leader
             /\ \E idx \in (lastApplied[i]+1)..applyTo :
                   idx > snapshotIndex[i] /\ log[i][idx - snapshotIndex[i]].type = NoopEntry
          THEN clusterChangePermitted' = [clusterChangePermitted EXCEPT ![i] = TRUE]
          ELSE UNCHANGED clusterChangePermitted
    /\ UNCHANGED <<serverVars, log, commitIndex, leaderVars, candidateVars,
                    messages, queryIndex, peerQueryIndex, queriesWaiting,
                    membershipVars, preVoteVars, snapshotVars, configVars>>

\* ============================================================================
\* CONSISTENT QUERIES [Bug Family 3]
\* ============================================================================

\* --- ConsistentQuery ---
\* ra_server.erl:846-869 -- handle_leader({consistent_query, ...})
\* Leader records commitIndex and sends heartbeats with incremented queryIndex
ConsistentQuery(i) ==
    /\ state[i] = Leader
    /\ clusterChangePermitted[i] = TRUE  \* ra_server.erl:846 guard
    /\ LET newQI == queryIndex[i] + 1
       IN
       /\ queryIndex' = [queryIndex EXCEPT ![i] = newQI]
       /\ queriesWaiting' = [queriesWaiting EXCEPT ![i] =
                                Append(@, [qi |-> newQI,
                                           readCommitIdx |-> commitIndex[i]])]
       \* ra_server.erl:3681-3697 -- send heartbeats with query_index
       /\ SendAll({[mtype   |-> HeartbeatRequest,
                    mterm   |-> currentTerm[i],
                    mqueryIndex |-> newQI,
                    msource |-> i,
                    mdest   |-> j] : j \in PeerIds(i)})
       /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                       peerQueryIndex, clusterChangePermitted,
                       membershipVars, preVoteVars, snapshotVars, configVars>>

\* --- HandleHeartbeatRequest ---
\* ra_server.erl: follower receives heartbeat, echoes query_index
HandleHeartbeatRequest(i, m) ==
    /\ m.mtype = HeartbeatRequest
    /\ \/ \* Case 1: Valid heartbeat (term >= current)
          /\ m.mterm >= currentTerm[i]
          /\ IF m.mterm > currentTerm[i]
             THEN UpdateTerm(i, m.mterm)
             ELSE UNCHANGED <<currentTerm, votedFor>>
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ leaderId' = [leaderId EXCEPT ![i] = m.msource]
          /\ Reply([mtype       |-> HeartbeatResponse,
                    mterm       |-> m.mterm,
                    mqueryIndex |-> m.mqueryIndex,
                    msource     |-> i,
                    mdest       |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>
       \/ \* Case 2: Stale heartbeat (term < current) -- reject
          \* ra_server.erl:1450-1455 -- echoes actual queryIndex back, not 0
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype       |-> HeartbeatResponse,
                    mterm       |-> currentTerm[i],
                    mqueryIndex |-> m.mqueryIndex,
                    msource     |-> i,
                    mdest       |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>

\* --- HandleHeartbeatResponse ---
\* ra_server.erl:3747-3782 -- heartbeat_rpc_quorum
\* [Bug Family 3] Update peerQueryIndex, check for query quorum
HandleHeartbeatResponse(i, m) ==
    /\ m.mtype = HeartbeatResponse
    /\ state[i] = Leader
    /\ \/ \* Case 1: Higher term -- step down
          /\ m.mterm > currentTerm[i]
          /\ UpdateTerm(i, m.mterm)
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>
       \/ \* Case 2: Current term -- update query index tracking
          \* ra_server.erl:3753 -- update_peer_query_index
          /\ m.mterm = currentTerm[i]
          /\ peerQueryIndex' = [peerQueryIndex EXCEPT ![i][m.msource] =
                                    IF m.mqueryIndex > @ THEN m.mqueryIndex ELSE @]
          \* Release queries whose qi <= consensus query index
          /\ LET consensusQI ==
                    LET voters == VoterSet(config[i])
                        pqi    == [peerQueryIndex EXCEPT ![i][m.msource] =
                                      IF m.mqueryIndex > peerQueryIndex[i][m.msource]
                                      THEN m.mqueryIndex
                                      ELSE peerQueryIndex[i][m.msource]]
                        qiSet  == {pqi[i][s] : s \in (voters \ {i})} \cup {queryIndex[i]}
                    IN CHOOSE qi \in qiSet :
                        /\ 2 * Cardinality({s \in voters :
                                (IF s = i THEN queryIndex[i] ELSE pqi[i][s]) >= qi})
                           > Cardinality(voters)
                        /\ \A qi2 \in qiSet :
                            (2 * Cardinality({s \in voters :
                                (IF s = i THEN queryIndex[i] ELSE pqi[i][s]) >= qi2})
                             > Cardinality(voters))
                            => qi >= qi2
             IN
             \* Release all waiting queries with qi <= consensusQI
             /\ queriesWaiting' = [queriesWaiting EXCEPT ![i] =
                    SelectSeq(@, LAMBDA q : q.qi > consensusQI)]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          queryIndex, clusterChangePermitted,
                          membershipVars, preVoteVars, snapshotVars,
                          configVars>>
       \/ \* Case 3: Stale term -- ignore
          /\ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>

\* ============================================================================
\* SNAPSHOT INSTALLATION [Bug Family 4]
\* ============================================================================

\* --- SendInstallSnapshot ---
\* ra_server.erl: leader sends snapshot to lagging follower
SendInstallSnapshot(i, j) ==
    /\ state[i] = Leader
    /\ j \in PeerIds(i)
    /\ snapshotIndex[i] > 0
    /\ nextIndex[i][j] <= snapshotIndex[i]
    /\ Send([mtype          |-> InstallSnapshotRequest,
             mterm          |-> currentTerm[i],
             msnapshotIndex |-> snapshotIndex[i],
             msnapshotTerm  |-> snapshotTerm[i],
             msource        |-> i,
             mdest          |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                    queryVars, membershipVars, preVoteVars, snapshotVars,
                    configVars>>

\* --- HandleInstallSnapshotRequest ---
\* ra_server.erl:1503-1573 -- handle_follower(#install_snapshot_rpc{...})
\* [Bug Family 4] Snapshot installation resets log and state
HandleInstallSnapshotRequest(i, m) ==
    /\ m.mtype = InstallSnapshotRequest
    /\ \/ \* Case 1: Lower term -- reject
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype     |-> InstallSnapshotResponse,
                    mterm     |-> currentTerm[i],
                    msuccess  |-> FALSE,
                    msource   |-> i,
                    mdest     |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>
       \/ \* Case 2: Snapshot at or below lastApplied -- skip
          \* ra_server.erl:1565-1573
          /\ m.mterm >= currentTerm[i]
          /\ m.msnapshotIndex <= lastApplied[i]
          /\ IF m.mterm > currentTerm[i]
             THEN UpdateTerm(i, m.mterm)
             ELSE UNCHANGED <<currentTerm, votedFor>>
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ leaderId' = [leaderId EXCEPT ![i] = m.msource]
          /\ Reply([mtype     |-> InstallSnapshotResponse,
                    mterm     |-> m.mterm,
                    msuccess  |-> FALSE,
                    msource   |-> i,
                    mdest     |-> m.msource], m)
          /\ UNCHANGED <<log, commitIndex, lastApplied, leaderVars,
                          candidateVars, queryVars, membershipVars,
                          preVoteVars, snapshotVars, configVars>>
       \/ \* Case 3: Accept snapshot -- install
          \* ra_server.erl:1513-1560 -- begin + complete accept
          \* Simplified: atomic install (skipping multi-phase chunking)
          /\ m.mterm >= currentTerm[i]
          /\ m.msnapshotIndex > lastApplied[i]
          /\ IF m.mterm > currentTerm[i]
             THEN UpdateTerm(i, m.mterm)
             ELSE UNCHANGED <<currentTerm, votedFor>>
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ leaderId' = [leaderId EXCEPT ![i] = m.msource]
          \* Reset log to snapshot point; snapshotTerm preserves the term
          \* for LogTerm lookups after truncation
          /\ log' = [log EXCEPT ![i] = <<>>]
          /\ commitIndex' = [commitIndex EXCEPT ![i] = m.msnapshotIndex]
          /\ lastApplied' = [lastApplied EXCEPT ![i] = m.msnapshotIndex]
          /\ snapshotIndex' = [snapshotIndex EXCEPT ![i] = m.msnapshotIndex]
          /\ snapshotTerm' = [snapshotTerm EXCEPT ![i] = m.msnapshotTerm]
          /\ Reply([mtype     |-> InstallSnapshotResponse,
                    mterm     |-> m.mterm,
                    msuccess  |-> TRUE,
                    msource   |-> i,
                    mdest     |-> m.msource], m)
          /\ UNCHANGED <<leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          pendingSnapshotWritten, configVars>>

\* --- HandleInstallSnapshotResponse ---
\* Leader handles snapshot response
HandleInstallSnapshotResponse(i, m) ==
    /\ m.mtype = InstallSnapshotResponse
    /\ state[i] = Leader
    /\ \/ \* Case 1: Higher term -- step down
          /\ m.mterm > currentTerm[i]
          /\ UpdateTerm(i, m.mterm)
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>
       \/ \* Case 2: Success -- advance nextIndex past snapshot
          /\ m.mterm = currentTerm[i]
          /\ m.msuccess = TRUE
          /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] =
                              snapshotIndex[i] + 1]
          /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] =
                              snapshotIndex[i]]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>
       \/ \* Case 3: Failure or stale -- ignore
          /\ \/ m.msuccess = FALSE
             \/ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          queryVars, membershipVars, preVoteVars,
                          snapshotVars, configVars>>

\* --- TakeSnapshot ---
\* Leader/follower takes a local snapshot at lastApplied
\* Truncates log entries covered by the new snapshot to maintain offset model.
TakeSnapshot(i) ==
    /\ lastApplied[i] > snapshotIndex[i]
    /\ LET newSI == lastApplied[i]
           entriesToRemove == newSI - snapshotIndex[i]
       IN
       /\ snapshotIndex' = [snapshotIndex EXCEPT ![i] = newSI]
       /\ snapshotTerm' = [snapshotTerm EXCEPT ![i] = LogTerm(i, newSI)]
       /\ log' = [log EXCEPT ![i] = SubSeq(@, entriesToRemove + 1, Len(@))]
       /\ pendingSnapshotWritten' = [pendingSnapshotWritten EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<serverVars, commitIndex, lastApplied, leaderVars, candidateVars,
                    messages, queryVars, membershipVars, preVoteVars, configVars>>

\* --- SnapshotWritten ---
\* Background snapshot write completes
\* [Bug Family 4] Stale snapshot_written after remote install can corrupt
SnapshotWritten(i) ==
    /\ pendingSnapshotWritten[i] = TRUE
    /\ pendingSnapshotWritten' = [pendingSnapshotWritten EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                    queryVars, membershipVars, preVoteVars, snapshotIndex,
                    snapshotTerm, configVars>>

\* ============================================================================
\* MEMBERSHIP CHANGES [Bug Family 5]
\* ============================================================================

\* --- ProposeConfigChange ---
\* ra_server.erl:3538-3562 -- append_cluster_change
\* Single-server change: add or remove one server at a time
ProposeConfigChange(i, newConfig) ==
    /\ state[i] = Leader
    /\ clusterChangePermitted[i] = TRUE  \* ra_server.erl:3538 guard
    /\ newConfig /= config[i]
    \* One server difference constraint
    /\ \/ \E s \in newConfig : newConfig = config[i] \cup {s}
       \/ \E s \in config[i] : newConfig = config[i] \ {s}
    /\ log' = [log EXCEPT ![i] = Append(@, Entry(currentTerm[i], newConfig, ConfigEntry))]
    \* ra_server.erl:3547 -- cluster_change_permitted := false
    /\ clusterChangePermitted' = [clusterChangePermitted EXCEPT ![i] = FALSE]
    \* ra_server.erl:3543-3546 -- immediate config update + save previous
    /\ config' = [config EXCEPT ![i] = newConfig]
    /\ previousConfig' = [previousConfig EXCEPT ![i] = config[i]]
    /\ UNCHANGED <<serverVars, commitIndex, lastApplied, leaderVars,
                    candidateVars, messages, queryIndex, peerQueryIndex,
                    queriesWaiting, membershipVars, preVoteVars, snapshotVars>>

\* ============================================================================
\* LEADER STEP-DOWN ON HIGHER TERM
\* ============================================================================

\* --- LeaderStepDown ---
\* ra_server.erl:800-840 -- handle_leader receives higher term AER/ISR/HBR
\* ra_server.erl:949-962 -- handle_leader receives higher term pre_vote_rpc (abdicates)
LeaderStepDown(i, m) ==
    /\ m.mtype \in {AppendEntriesRequest, InstallSnapshotRequest, HeartbeatRequest, PreVoteRequest}
    /\ state[i] = Leader
    /\ m.mterm > currentTerm[i]
    /\ UpdateTerm(i, m.mterm)
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ leaderId' = [leaderId EXCEPT ![i] = Nil]
    \* [Bug Family 3] Reset query state on step-down
    /\ queryIndex' = [queryIndex EXCEPT ![i] = 0]
    /\ peerQueryIndex' = [peerQueryIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ queriesWaiting' = [queriesWaiting EXCEPT ![i] = <<>>]
    /\ clusterChangePermitted' = [clusterChangePermitted EXCEPT ![i] = FALSE]
    \* Leave message for follower to process
    /\ UNCHANGED <<log, commitIndex, lastApplied, leaderVars, candidateVars,
                    messages, membershipVars, preVoteVars, snapshotVars,
                    configVars>>

\* --- LeaderIgnorePreVote ---
\* ra_server.erl:964-969 -- handle_leader receives same/lower-term pre_vote_rpc
\* Leader enforces leadership (make_all_rpcs) and ignores the pre-vote.
\* Does NOT reply with pre_vote_result. Does NOT update votedFor.
LeaderIgnorePreVote(i, m) ==
    /\ m.mtype = PreVoteRequest
    /\ state[i] = Leader
    /\ m.mterm <= currentTerm[i]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                    queryVars, membershipVars, preVoteVars, snapshotVars,
                    configVars>>

\* ============================================================================
\* LEADER AUXILIARY ACTIONS
\* ============================================================================

\* --- LeaderAppendNoop ---
\* ra_server.erl:3003 -- append noop entry in initialise_peers
\* Separated from BecomeLeader to match implementation trace ordering
LeaderAppendNoop(i) ==
    /\ state[i] = Leader
    \* Only one noop per term (use physical index range)
    /\ ~\E pIdx \in 1..Len(log[i]) :
          /\ log[i][pIdx].type = NoopEntry
          /\ log[i][pIdx].term = currentTerm[i]
    /\ log' = [log EXCEPT ![i] = Append(@, Entry(currentTerm[i], Nil, NoopEntry))]
    /\ UNCHANGED <<serverVars, commitIndex, lastApplied, leaderVars,
                    candidateVars, messages, queryVars, membershipVars,
                    preVoteVars, snapshotVars, configVars>>

\* --- SendHeartbeat ---
\* ra_server_proc.erl: periodic heartbeat sending (separate from ConsistentQuery)
\* Carries current queryIndex for query protocol
SendHeartbeat(i) ==
    /\ state[i] = Leader
    /\ SendAll({[mtype       |-> HeartbeatRequest,
                 mterm       |-> currentTerm[i],
                 mqueryIndex |-> queryIndex[i],
                 msource     |-> i,
                 mdest       |-> j] : j \in PeerIds(i)})
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                    queryVars, membershipVars, preVoteVars, snapshotVars,
                    configVars>>

\* ============================================================================
\* NETWORK ACTIONS
\* ============================================================================

\* --- Timeout ---
\* Server times out and starts pre-vote (Ra's default election path)
\* Candidates and pre_vote servers also timeout and restart election
Timeout(i) ==
    /\ state[i] \in {Follower, PreVote, Candidate, AwaitCondition}
    /\ membership[i] = MemberVoter
    /\ CallForPreVote(i)

\* --- LoseMessage ---
LoseMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                    queryVars, membershipVars, preVoteVars, snapshotVars,
                    configVars>>

\* --- DropStaleMessage ---
\* Discard messages with term < receiver's current term
DropStaleMessage(m) ==
    /\ m.mterm < currentTerm[m.mdest]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                    queryVars, membershipVars, preVoteVars, snapshotVars,
                    configVars>>

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

Next ==
    \/ \E i \in Server :
        \/ Timeout(i)
        \/ BecomeLeader(i)
        \/ WinPreVote(i)
        \/ LeaderAppendNoop(i)
        \/ \E v \in Value : ClientRequest(i, v)
        \/ AdvanceCommitIndex(i)
        \/ ApplyEntries(i)
        \/ ConsistentQuery(i)
        \/ SendHeartbeat(i)
        \/ TakeSnapshot(i)
        \/ SnapshotWritten(i)
    \/ \E i, j \in Server :
        /\ i /= j
        /\ \/ ReplicateEntries(i, j)
           \/ SendInstallSnapshot(i, j)
    \/ \E m \in BagToSet(messages) :
        \/ HandlePreVoteRequest(m.mdest, m)
        \/ HandlePreVoteResponse(m.mdest, m)
        \/ HandleRequestVoteRequest(m.mdest, m)
        \/ HandleRequestVoteResponse(m.mdest, m)
        \/ HandleAppendEntriesRequest(m.mdest, m)
        \/ HandleAppendEntriesResponse(m.mdest, m)
        \/ HandleHeartbeatRequest(m.mdest, m)
        \/ HandleHeartbeatResponse(m.mdest, m)
        \/ HandleInstallSnapshotRequest(m.mdest, m)
        \/ HandleInstallSnapshotResponse(m.mdest, m)
        \/ CandidateStepDown(m.mdest, m)
        \/ LeaderStepDown(m.mdest, m)
        \/ LeaderIgnorePreVote(m.mdest, m)
        \/ DropStaleMessage(m)
        \/ LoseMessage(m)
    \/ \E i \in Server, nc \in SUBSET Server :
        ProposeConfigChange(i, nc)

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* --- Standard Raft Safety Invariants ---

\* At most one leader per term
ElectionSafety ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ state[s2] = Leader /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* Same index+term implies identical prefix
\* Only compare entries present in both physical logs (after snapshot)
LogMatching ==
    \A s1, s2 \in Server :
        LET minStart == Max(snapshotIndex[s1], snapshotIndex[s2]) + 1
        IN \A idx \in minStart..Min(LastLogIndex(s1), LastLogIndex(s2)) :
            log[s1][idx - snapshotIndex[s1]].term = log[s2][idx - snapshotIndex[s2]].term =>
                \A k \in minStart..idx :
                    log[s1][k - snapshotIndex[s1]].term = log[s2][k - snapshotIndex[s2]].term

\* Committed entries appear in all future leaders' logs
\* Only check entries present in both physical logs
LeaderCompleteness ==
    \A leader \in Server :
        state[leader] = Leader =>
            \A other \in Server :
                \A idx \in 1..commitIndex[other] :
                    (/\ idx <= LastLogIndex(leader)
                     /\ idx > snapshotIndex[leader]
                     /\ idx > snapshotIndex[other]
                     /\ log[other][idx - snapshotIndex[other]].term <= currentTerm[leader])
                    => log[leader][idx - snapshotIndex[leader]].term = log[other][idx - snapshotIndex[other]].term

\* --- Extension Invariants (Bug Hunting) ---

\* [Bug Family 1] Commit index bounded by log for leaders
\* Followers can exceed due to paper deviation (commit_index := LeaderCommit without min)
\* but must be bounded at apply time. Monotonicity is temporal; see MC.tla MonotonicCommitIndex.
CommitIndexSafety ==
    \A s \in Server :
        state[s] = Leader => commitIndex[s] <= LastLogIndex(s)

\* [Bug Family 2] Only voters can be leaders
VoterOnlyElection ==
    \A s \in Server :
        state[s] = Leader => membership[s] = MemberVoter

\* [Bug Family 2] Only voters appear in vote/pre-vote sets
\* Non-voters should never grant votes (ra_server.erl:1448-1452, 2920)
VoterOnlyQuorum ==
    \A s \in Server :
        /\ \A v \in votesGranted[s] : membership[v] = MemberVoter
        /\ \A v \in preVotesGranted[s] : membership[v] = MemberVoter

\* [Bug Family 2] Votes from cluster members only
\* Impl uses integer counter (votes + 1); spec uses set for dedup detection (MC-1)
NoDuplicateVoteCounting ==
    \A s \in Server :
        /\ votesGranted[s] \subseteq config[s]
        /\ preVotesGranted[s] \subseteq config[s]

\* [Bug Family 3] Consistent query linearizability
\* A released query must reflect all writes committed at query issue time
\* Modeled as: no query released while leader's lastApplied < readCommitIdx
ConsistentQuerySafety ==
    \A s \in Server :
        state[s] = Leader =>
            \A idx \in 1..Len(queriesWaiting[s]) :
                queriesWaiting[s][idx].readCommitIdx <= commitIndex[s]

\* [Bug Family 3] Heartbeat quorum only counts peers in current term
\* Stale query_index from prior term must not count
NoPhantomHeartbeatQuorum ==
    \A s \in Server :
        state[s] = Leader =>
            \A j \in PeerIds(s) :
                peerQueryIndex[s][j] <= queryIndex[s]

\* [Bug Family 4] Snapshot index never exceeds lastApplied;
\* and snapshotTerm is consistent (non-zero when snapshotIndex > 0)
SnapshotLogConsistency ==
    \A s \in Server :
        /\ snapshotIndex[s] <= lastApplied[s]
        /\ (snapshotIndex[s] > 0) => (snapshotTerm[s] > 0)

\* [Bug Family 5] At most one uncommitted config change in leader's log
OneClusterChangeAtATime ==
    \A s \in Server :
        state[s] = Leader =>
            Cardinality({idx \in (commitIndex[s]+1)..LastLogIndex(s) :
                         idx > snapshotIndex[s] /\ log[s][idx - snapshotIndex[s]].type = ConfigEntry}) <= 1

\* --- Structural Invariants (always hold) ---

\* Terms are non-negative
TermNonNegative == \A s \in Server : currentTerm[s] >= 0

\* CommitIndex <= last log index for leaders (followers can exceed due to paper deviation)
LeaderCommitBound ==
    \A s \in Server :
        state[s] = Leader => commitIndex[s] <= LastLogIndex(s)

\* LastApplied <= max(LastLogIndex, snapshotIndex)
\* After snapshot install, log may be truncated but lastApplied = snapshotIndex.
\* Note: lastApplied <= commitIndex does NOT hold because Ra's paper deviation
\* (commit_index set directly from LeaderCommit without max guard) can regress
\* commitIndex below lastApplied when stale AERs arrive. This applies to both
\* followers and leaders (former followers that became leader with regressed commitIndex).
AppliedBound ==
    \A s \in Server : lastApplied[s] <= Max(LastLogIndex(s), snapshotIndex[s])

\* Match index consistency
MatchIndexBound ==
    \A s \in Server :
        state[s] = Leader =>
            \A j \in PeerIds(s) :
                matchIndex[s][j] <= LastLogIndex(j)

\* Leader's nextIndex >= 1 for all peers
NextIndexPositive ==
    \A s \in Server :
        state[s] = Leader =>
            \A j \in PeerIds(s) : nextIndex[s][j] >= 1

====
