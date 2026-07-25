---------------------------- MODULE base ----------------------------
\* TLA+ specification of ebay/nuraft Raft consensus library.
\*
\* Models core Raft protocol with nuraft-specific extensions:
\*   1. Precommit/commit ordering with precommitIndex (Bug Family 1)
\*   2. Non-atomic term/vote persistence with crash window (Bug Family 2)
\*   3. Config change guard (config_changing_) with bypass paths (Bug Family 3)
\*   4. Auto-quorum adjustment for 2-node clusters (Bug Family 4)
\*   5. Missing guards in response handlers (Bug Family 5)
\*   7. Missing Raft Figure 2 commit term check, implicit config barrier (Bug Family 7)
\*
EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs

CONSTANTS Follower,          \* Server roles
          Candidate,
          Leader

CONSTANT Nil                 \* Null value

CONSTANTS ValueEntry,        \* Log entry types
          ConfigEntry

CONSTANTS PreVoteRequest,           \* Message types
          PreVoteResponse,
          RequestVoteRequest,
          RequestVoteResponse,
          AppendEntriesRequest,
          AppendEntriesResponse

----
\* Variables
----

\* Per-server persistent state (survives restart)
VARIABLE currentTerm         \* [Server -> Nat]
VARIABLE votedFor            \* [Server -> Server \cup {Nil}]
VARIABLE log                 \* [Server -> Seq([term: Nat, type: {ValueEntry, ConfigEntry}])]

\* Per-server volatile state
VARIABLE state               \* [Server -> {Follower, Candidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat] -- quick_commit_index_ in nuraft
VARIABLE smCommitIndex       \* [Server -> Nat] -- sm_commit_index_ in nuraft

\* Extension 1: Precommit tracking (Bug Family 1)
\* precommit_index_ is updated via CAS after log append + pre_commit callback.
\* Commit thread fatally exits if smCommitIndex > precommitIndex.
\* Reference: handle_append_entries.cxx:1146-1167 (try_update_precommit_index)
\*            handle_commit.cxx:363-369 (N23_precommit_order_inversion check)
VARIABLE precommitIndex      \* [Server -> Nat]

\* Leader volatile state
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate/PreVote state
VARIABLE votesGranted        \* [Server -> SUBSET Server]
VARIABLE preVotesGranted     \* [Server -> SUBSET Server] -- pre-vote "dead" votes

\* Extension 2: Non-atomic persistence (Bug Family 2)
\* inc_term() and set_voted_for() happen in memory before save_state().
\* Crash between them leaves stale persisted state.
\* Reference: handle_vote.cxx:241-261 (initiate_vote: inc_term..save_state gap)
\*            raft_server.cxx:1554-1585 (update_term: set_term..save_state gap)
VARIABLE persistedTerm       \* [Server -> Nat]
VARIABLE persistedVotedFor   \* [Server -> Server \cup {Nil}]

\* Extension 3: Config change guard (Bug Family 3)
\* config_changing_ flag prevents concurrent config changes.
\* set_priority() bypasses this guard (handle_priority.cxx:39-107).
\* Reference: handle_join_leave.cxx, raft_server.cxx
VARIABLE configChanging      \* [Server -> BOOLEAN]

\* Extension 4: Auto-quorum adjustment (Bug Family 4)
\* In 2-node clusters, quorum can be reduced to 1 when peer unresponsive.
\* Both nodes can independently adjust, causing split-brain.
\* Reference: handle_vote.cxx:105-123, handle_append_entries.cxx:195-243
VARIABLE customQuorumSize    \* [Server -> Nat] -- 0 = use default

\* Heartbeat alive tracking (for pre-vote mechanism)
\* Reference: handle_vote.cxx:467 (hb_alive_ check in handle_prevote_req)
VARIABLE hbAlive             \* [Server -> BOOLEAN]

\* Network
VARIABLE messages            \* Bag of message records

----
\* Variable groups
----

serverVars    == <<currentTerm, votedFor, state>>
logVars       == <<log, commitIndex, smCommitIndex>>
precommitVars == <<precommitIndex>>
leaderVars    == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted, preVotesGranted>>
persistVars   == <<persistedTerm, persistedVotedFor>>
configVars    == <<configChanging>>
quorumVars    == <<customQuorumSize>>
hbVars        == <<hbAlive>>

vars == <<serverVars, logVars, precommitVars, leaderVars, candidateVars,
          persistVars, configVars, quorumVars, hbVars, messages>>

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

\* Quorum helpers
\* Reference: raft_server.cxx:588-634 (get_num_voting_members, get_quorum_for_*)
\* get_quorum_for_election/commit returns #peers needed EXCLUDING leader.
\* With N servers: default = N/2. custom_size S: returns S-1.
NumVotingMembers == Cardinality(Server)

\* Returns number of peers (excluding self) needed for commit/election.
\* Reference: raft_server.cxx:613-634
GetQuorumForCommit(i) ==
    IF customQuorumSize[i] = 0 \/ customQuorumSize[i] > NumVotingMembers
    THEN NumVotingMembers \div 2
    ELSE customQuorumSize[i] - 1

GetQuorumForElection(i) ==
    IF customQuorumSize[i] = 0 \/ customQuorumSize[i] > NumVotingMembers
    THEN NumVotingMembers \div 2
    ELSE customQuorumSize[i] - 1

\* Quorum check: S must have > quorum members (i.e., S >= quorum + 1).
\* This matches code: votes_granted_ >= get_quorum_for_election() + 1
\* and the sorted matched_indexes[quorum_idx] logic.
IsCommitQuorum(S, i)   == Cardinality(S) > GetQuorumForCommit(i)
IsElectionQuorum(S, i) == Cardinality(S) > GetQuorumForElection(i)

\* Log up-to-date comparison
\* Reference: handle_vote.cxx:334-337
LogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    \/ cLastTerm > vLastTerm
    \/ (cLastTerm = vLastTerm /\ cLastIdx >= vLastIdx)

\* Message bag helpers
Send(m) == messages' = messages (+) SetToBag({m})
SendAll(ms) == messages' = messages (+) SetToBag(ms)
Discard(m) == messages' = messages (-) SetToBag({m})
Reply(resp, req) ==
    messages' = (messages (-) SetToBag({req})) (+) SetToBag({resp})

----
\* Init
----

Init ==
    /\ currentTerm      = [s \in Server |-> 0]
    /\ votedFor          = [s \in Server |-> Nil]
    /\ log               = [s \in Server |-> <<>>]
    /\ state             = [s \in Server |-> Follower]
    /\ commitIndex       = [s \in Server |-> 0]
    /\ smCommitIndex     = [s \in Server |-> 0]
    /\ precommitIndex    = [s \in Server |-> 0]
    /\ nextIndex         = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex        = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted      = [s \in Server |-> {}]
    /\ preVotesGranted   = [s \in Server |-> {}]
    /\ persistedTerm     = [s \in Server |-> 0]
    /\ persistedVotedFor = [s \in Server |-> Nil]
    /\ configChanging    = [s \in Server |-> FALSE]
    /\ customQuorumSize  = [s \in Server |-> 0]
    /\ hbAlive           = [s \in Server |-> FALSE]
    /\ messages          = EmptyBag

----
\* Pre-Vote Actions
\*
\* nuraft uses pre-vote to prevent disruption of stable leaders.
\* Pre-vote does NOT change term or votedFor.
----

\* Server i starts pre-vote phase (election timeout).
\* Reference: handle_vote.cxx:48-197 (request_prevote)
\* Sets hb_alive_ = false (line 126), role_ = candidate (line 128),
\* pre_vote_.dead_++ for self (line 132), sends PreVoteRequest to peers.
Timeout(i) ==
    /\ state[i] \in {Follower, Candidate}
    \* handle_vote.cxx:126-132
    /\ hbAlive' = [hbAlive EXCEPT ![i] = FALSE]
    /\ state' = [state EXCEPT ![i] = Candidate]
    /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {i}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    \* Send PreVoteRequest to all peers
    \* handle_vote.cxx:159-166
    /\ SendAll({[mtype         |-> PreVoteRequest,
                 mterm         |-> currentTerm[i],
                 mlastLogTerm  |-> LastLogTerm(i),
                 mlastLogIndex |-> LastLogIndex(i),
                 msource       |-> i,
                 mdest         |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<currentTerm, votedFor, logVars, precommitVars,
                   leaderVars, persistVars, configVars, quorumVars>>

\* Server i handles PreVoteRequest m.
\* Reference: handle_vote.cxx:431-479 (handle_prevote_req)
\*
\* *** Bug Family 5 (CR-1): NO log up-to-dateness check! ***
\* Deviation from Ongaro thesis §9.6.
\* Grants based solely on hb_alive_ status (line 467).
HandlePreVoteRequest(i, m) ==
    /\ m.mtype = PreVoteRequest
    /\ m.mdest = i
    /\ LET \* handle_vote.cxx:451-457: response with current term
           resp == [mtype        |-> PreVoteResponse,
                    mterm        |-> m.mterm,
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource]
       IN
       \/ \* Grant: hb_alive_ is false (line 467-469)
          \* Bug Family 5 (CR-1): no LogUpToDate check here!
          /\ ~hbAlive[i]
          /\ Reply([resp EXCEPT !.mvoteGranted = TRUE], m)
          /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                         candidateVars, persistVars, configVars, quorumVars, hbVars>>

       \/ \* Deny: hb_alive_ is true (line 470-476)
          /\ hbAlive[i]
          /\ Reply(resp, m)
          /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                         candidateVars, persistVars, configVars, quorumVars, hbVars>>

\* Server i handles PreVoteResponse m.
\* Reference: handle_vote.cxx:481-558 (handle_prevote_resp)
HandlePreVoteResponse(i, m) ==
    /\ m.mtype = PreVoteResponse
    /\ m.mdest = i
    /\ \/ \* Different term: ignore (line 482-490)
          /\ m.mterm /= currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                         candidateVars, persistVars, configVars, quorumVars, hbVars>>
       \/ \* Granted (line 492-494): add to dead set
          /\ m.mterm = currentTerm[i]
          /\ m.mvoteGranted
          /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = @ \cup {m.msource}]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                         votesGranted, persistVars, configVars, quorumVars, hbVars>>
       \/ \* Denied (line 495-503): ignore
          /\ m.mterm = currentTerm[i]
          /\ ~m.mvoteGranted
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                         candidateVars, persistVars, configVars, quorumVars, hbVars>>

----
\* Election Actions
----

\* Server i transitions from pre-vote success to real election.
\* Reference: handle_vote.cxx:199-314 (initiate_vote + request_vote)
\*
\* *** Bug Family 2: Non-atomic persistence ***
\* initiate_vote (line 241-243): inc_term, set_voted_for(-1) [in-memory]
\* request_vote (line 260-261): set_voted_for(self), save_state [persist]
\* Crash between line 243 and line 261 leaves stale persisted state.
\*
\* In the spec, we update in-memory state but NOT persistedTerm/persistedVotedFor.
\* PersistState action performs the actual persistence.
InitiateVote(i) ==
    /\ state[i] = Candidate
    /\ IsElectionQuorum(preVotesGranted[i], i)
    /\ LET newTerm == currentTerm[i] + 1
       IN
       \* handle_vote.cxx:241-243: inc_term, role = candidate
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       /\ state' = [state EXCEPT ![i] = Candidate]
       \* handle_vote.cxx:260: set_voted_for(self)
       /\ votedFor' = [votedFor EXCEPT ![i] = i]
       \* handle_vote.cxx:262-263: self-vote
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
       /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
       \* Bug Family 2: persisted state NOT updated yet!
       \* save_state happens in PersistState action
       /\ UNCHANGED <<persistedTerm, persistedVotedFor>>
       \* handle_vote.cxx:278-313: send VoteRequest to peers
       /\ SendAll({[mtype         |-> RequestVoteRequest,
                    mterm         |-> newTerm,
                    mlastLogTerm  |-> LastLogTerm(i),
                    mlastLogIndex |-> LastLogIndex(i),
                    msource       |-> i,
                    mdest         |-> j] : j \in Server \ {i}})
    /\ UNCHANGED <<logVars, precommitVars, leaderVars,
                   configVars, quorumVars, hbVars>>

\* Server i persists its current term and votedFor to stable storage.
\* Reference: handle_vote.cxx:261 (save_state in request_vote)
\*            raft_server.cxx:1580 (save_state in update_term)
\* Bug Family 2: This is the "completion" of the non-atomic persist.
PersistState(i) ==
    /\ \/ persistedTerm[i] /= currentTerm[i]
       \/ persistedVotedFor[i] /= votedFor[i]
    /\ persistedTerm' = [persistedTerm EXCEPT ![i] = currentTerm[i]]
    /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = votedFor[i]]
    /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                   candidateVars, messages, configVars, quorumVars, hbVars>>

\* Server i handles RequestVoteRequest m.
\* Reference: handle_vote.cxx:316-388 (handle_vote_req)
HandleVoteRequest(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ LET \* handle_vote.cxx:334-337: log comparison
           logOk == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                LastLogTerm(i), LastLogIndex(i))
           \* handle_vote.cxx:339-343: grant conditions
           grant == /\ m.mterm = currentTerm[i]
                    /\ logOk
                    /\ (votedFor[i] = m.msource \/ votedFor[i] = Nil)
       IN
       \/ \* Higher term: update_term first, then check grant
          \* raft_server.cxx:1554-1585 (update_term called before handler dispatch)
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          \* update_term resets election state (votes_granted_, election_completed_)
          /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
          /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
          \* After update_term, votedFor is reset to Nil, so grant if logOk
          /\ IF logOk
             THEN /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
                  \* handle_vote.cxx:381-382: persist on grant
                  /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
                  /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = m.msource]
                  /\ Reply([mtype        |-> RequestVoteResponse,
                            mterm        |-> m.mterm,
                            mvoteGranted |-> TRUE,
                            msource      |-> i,
                            mdest        |-> m.msource], m)
             ELSE /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
                  /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
                  /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = Nil]
                  /\ Reply([mtype        |-> RequestVoteResponse,
                            mterm        |-> m.mterm,
                            mvoteGranted |-> FALSE,
                            msource      |-> i,
                            mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, precommitVars, leaderVars,
                         configVars, quorumVars, hbVars>>

       \/ \* Same term: check grant conditions
          /\ m.mterm = currentTerm[i]
          /\ IF grant
             THEN \* Grant: handle_vote.cxx:378-382
                  /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
                  /\ persistedTerm' = [persistedTerm EXCEPT ![i] = currentTerm[i]]
                  /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = m.msource]
                  /\ Reply([mtype        |-> RequestVoteResponse,
                            mterm        |-> currentTerm[i],
                            mvoteGranted |-> TRUE,
                            msource      |-> i,
                            mdest        |-> m.msource], m)
             ELSE \* Deny: handle_vote.cxx:383-385
                  /\ Reply([mtype        |-> RequestVoteResponse,
                            mterm        |-> currentTerm[i],
                            mvoteGranted |-> FALSE,
                            msource      |-> i,
                            mdest        |-> m.msource], m)
                  /\ UNCHANGED <<votedFor, persistVars>>
          /\ UNCHANGED <<currentTerm, state, logVars, precommitVars, leaderVars,
                         candidateVars, configVars, quorumVars, hbVars>>

       \/ \* Lower term: deny without stepping down
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                         candidateVars, persistVars, configVars, quorumVars, hbVars>>

\* Server i handles RequestVoteResponse m.
\* Reference: handle_vote.cxx:390-429 (handle_vote_resp)
\*
\* *** Bug Family 5 (MC-4): NO role check! ***
\* Code checks election_completed_ and term match (lines 391-402),
\* but does NOT check role_ == candidate (line 390 has no role check).
\* A follower that received same-term AE (became follower via
\* handle_append_entries.cxx:735-736) can still accumulate votes.
HandleVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    \* Bug Family 5: NO role check! handle_vote.cxx:390 has no role_ == candidate check
    /\ \/ \* Different term: ignore (handle_vote.cxx:396-402)
          /\ m.mterm /= currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                         candidateVars, persistVars, configVars, quorumVars, hbVars>>
       \/ \* Same term: tally vote (handle_vote.cxx:403-428)
          /\ m.mterm = currentTerm[i]
          /\ IF m.mvoteGranted
             THEN votesGranted' = [votesGranted EXCEPT ![i] = @ \cup {m.msource}]
             ELSE UNCHANGED votesGranted
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                         preVotesGranted, persistVars, configVars, quorumVars, hbVars>>

\* Candidate i becomes leader after receiving quorum of votes.
\* Reference: raft_server.cxx:1122-1220 (become_leader)
\*
\* *** Bug Family 5 (MC-4): Code does not gate on role_ == Candidate ***
\* handle_vote.cxx:423 checks votes_granted_ >= quorum but not role.
\*
\* *** Bug Family 7: Appends config entry on become_leader ***
\* raft_server.cxx:1183-1195: clone config, append as ConfigEntry.
\* This acts as Raft §5.4.2 barrier (entries from previous terms
\* only committed after this current-term entry commits).
BecomeLeader(i) ==
    /\ state[i] /= Leader
    \* Bug Family 5: no Candidate role check, matching code
    /\ IsElectionQuorum(votesGranted[i], i)
    \* raft_server.cxx:1132-1134
    /\ state' = [state EXCEPT ![i] = Leader]
    \* raft_server.cxx:1156: pp->set_next_log_idx(log_store_->next_slot())
    /\ nextIndex'  = [nextIndex  EXCEPT ![i] = [j \in Server |-> LastLogIndex(i) + 2]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    \* Bug Family 7: append config entry (raft_server.cxx:1183-1195)
    \* This is the implicit Raft §5.4.2 noop barrier
    /\ LET entry == [term |-> currentTerm[i], type |-> ConfigEntry]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    \* raft_server.cxx:1139: precommit_index_ = log_store_->next_slot() - 1
    /\ precommitIndex' = [precommitIndex EXCEPT ![i] = LastLogIndex(i) + 1]
    \* raft_server.cxx:1196: config_changing_ = true
    /\ configChanging' = [configChanging EXCEPT ![i] = TRUE]
    \* Bug Family 4: restore quorum on become_leader is NOT done here
    \* (it's done in become_follower only)
    /\ UNCHANGED <<currentTerm, votedFor, commitIndex, smCommitIndex,
                   candidateVars, persistVars, quorumVars, hbVars, messages>>

----
\* Log Replication Actions
----

\* Leader i appends a client request to its log.
\* Reference: handle_client_request.cxx:85-142 (handle_cli_req)
\* Bug Family 1: append + pre_commit + try_update_precommit_index
\* are atomic under cli_lock_ (lines 116-142).
ClientRequest(i) ==
    /\ state[i] = Leader
    /\ LET entry == [term |-> currentTerm[i], type |-> ValueEntry]
       IN
       \* handle_client_request.cxx:121: store_log_entry
       /\ log' = [log EXCEPT ![i] = Append(@, entry)]
       \* handle_client_request.cxx:128-129: pre_commit_ext (implicit)
       \* handle_client_request.cxx:142: try_update_precommit_index
       /\ precommitIndex' = [precommitIndex EXCEPT ![i] = LastLogIndex(i) + 1]
    /\ UNCHANGED <<serverVars, commitIndex, smCommitIndex, leaderVars,
                   candidateVars, messages, persistVars, configVars, quorumVars, hbVars>>

\* Leader i sends AppendEntries to server j.
\* Reference: handle_append_entries.cxx:466-666 (create_append_entries_req)
\* Sends log entries from nextIndex[i][j] to end of log.
AppendEntries(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == LogTerm(i, prevIdx)
           lastIdx  == LastLogIndex(i)
           \* handle_append_entries.cxx:478: cur_nxt_idx = precommit_index_ + 1
           \* Only send up to precommitIndex (not beyond)
           sendUpTo == Min(lastIdx, precommitIndex[i])
           entries  == IF nextIndex[i][j] > sendUpTo THEN <<>>
                       ELSE SubSeq(log[i], nextIndex[i][j], sendUpTo)
       IN Send([mtype         |-> AppendEntriesRequest,
                mterm         |-> currentTerm[i],
                mprevLogIndex |-> prevIdx,
                mprevLogTerm  |-> prevTerm,
                mentries      |-> entries,
                mcommitIndex  |-> commitIndex[i],
                msource       |-> i,
                mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                   candidateVars, persistVars, configVars, quorumVars, hbVars>>

\* Server i handles AppendEntriesRequest m (follower side).
\* Reference: handle_append_entries.cxx:668-1144 (handle_append_entries)
HandleAppendEntries(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ LET logOk ==
               \/ m.mprevLogIndex = 0
               \/ /\ m.mprevLogIndex > 0
                  /\ m.mprevLogIndex <= LastLogIndex(i)
                  /\ LogTerm(i, m.mprevLogIndex) = m.mprevLogTerm
       IN
       \/ \* Reject: term too low (handle_append_entries.cxx:810-811)
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype       |-> AppendEntriesResponse,
                    mterm       |-> currentTerm[i],
                    msuccess    |-> FALSE,
                    mmatchIndex |-> 0,
                    msource     |-> i,
                    mdest       |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                         candidateVars, persistVars, configVars, quorumVars, hbVars>>

       \/ \* Reject: log inconsistency (handle_append_entries.cxx:810-812)
          /\ m.mterm >= currentTerm[i]
          /\ ~logOk
          /\ Reply([mtype       |-> AppendEntriesResponse,
                    mterm       |-> m.mterm,
                    msuccess    |-> FALSE,
                    mmatchIndex |-> 0,
                    msource     |-> i,
                    mdest       |-> m.msource], m)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = IF m.mterm > currentTerm[i]
                                           THEN Follower ELSE state[i]]
          /\ votedFor' = IF m.mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ IF m.mterm > currentTerm[i]
             THEN /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
                  /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = Nil]
                  /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
                  /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
             ELSE /\ UNCHANGED persistVars
                  /\ UNCHANGED candidateVars
          \* handle_append_entries.cxx:884: reset last_rcvd_valid timer (hb_alive)
          /\ hbAlive' = [hbAlive EXCEPT ![i] = TRUE]
          /\ UNCHANGED <<logVars, precommitVars, leaderVars,
                         configVars, quorumVars>>

       \/ \* Accept: log matches at prevLogIndex
          \* handle_append_entries.cxx:840-1097
          /\ m.mterm >= currentTerm[i]
          /\ logOk
          /\ LET \* Compute new log: truncate ONLY on conflict + append new
                 \* handle_append_entries.cxx:886-1024
                 \* Raft §5.3: "If an existing entry conflicts with a new one
                 \* (same index but different terms), delete the existing entry
                 \* and all that follow it." Matching entries are kept.
                 conflictExists ==
                     /\ Len(m.mentries) > 0
                     /\ \E k \in 1..Len(m.mentries) :
                         /\ m.mprevLogIndex + k <= Len(log[i])
                         /\ log[i][m.mprevLogIndex + k].term /= m.mentries[k].term
                 newLog == IF Len(m.mentries) = 0
                           THEN log[i]
                           ELSE IF conflictExists
                                   \/ m.mprevLogIndex + Len(m.mentries) > Len(log[i])
                                \* Conflict or new entries beyond log: truncate + append
                                THEN SubSeq(log[i], 1, m.mprevLogIndex) \o m.mentries
                                \* All entries match existing log: keep longer log
                                ELSE log[i]
                 newLastIdx == Len(newLog)
                 \* handle_append_entries.cxx:1080-1081: target_precommit_index
                 targetPC == m.mprevLogIndex + Len(m.mentries)
                 \* handle_append_entries.cxx:1094: commit(min(commit_idx, target))
                 newCommitIdx == IF m.mcommitIndex > commitIndex[i]
                                 THEN Min(m.mcommitIndex, targetPC)
                                 ELSE commitIndex[i]
             IN
             /\ log' = [log EXCEPT ![i] = newLog]
             /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
             \* handle_append_entries.cxx:1089: try_update_precommit_index
             /\ precommitIndex' = [precommitIndex EXCEPT ![i] = Max(@, targetPC)]
             /\ Reply([mtype       |-> AppendEntriesResponse,
                       mterm       |-> m.mterm,
                       msuccess    |-> TRUE,
                       mmatchIndex |-> newLastIdx,
                       msource     |-> i,
                       mdest       |-> m.msource], m)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          \* handle_append_entries.cxx:734-736: candidate -> follower on same-term AE
          /\ state' = [state EXCEPT ![i] = IF m.mterm > currentTerm[i] \/ state[i] = Candidate
                                           THEN Follower ELSE @]
          /\ votedFor' = IF m.mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ IF m.mterm > currentTerm[i]
             THEN /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
                  /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = Nil]
                  /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
                  /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
             ELSE /\ UNCHANGED persistVars
                  /\ UNCHANGED candidateVars
          \* handle_append_entries.cxx:1049: leader_ = req.get_src()
          \* handle_append_entries.cxx:1113-1116: restart election timer (hb_alive)
          /\ hbAlive' = [hbAlive EXCEPT ![i] = TRUE]
          /\ UNCHANGED <<smCommitIndex, leaderVars,
                         configVars, quorumVars>>

\* Leader i handles AppendEntriesResponse m.
\* Reference: handle_append_entries.cxx:1169-1508 (handle_append_entries_resp)
\*
\* *** Bug Family 5 (MC-3): NO term comparison in response handler! ***
\* The dispatch code calls update_term (raft_server.cxx) which handles
\* higher-term responses. But stale responses (lower term) are NOT filtered.
\* A stale accepted response can update matched_idx with outdated data.
HandleAppendEntriesResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ \/ \* Higher term: update_term step-down
          \* (handled before reaching this handler in actual code)
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
          /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = Nil]
          \* update_term resets election state
          /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
          /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
          \* Bug Family 4: restore quorum on become_follower
          \* raft_server.cxx:1533-1542
          /\ customQuorumSize' = IF Cardinality(Server) = 2
                                    /\ customQuorumSize[i] > 0
                                 THEN [customQuorumSize EXCEPT ![i] = 0]
                                 ELSE customQuorumSize
          /\ Discard(m)
          /\ UNCHANGED <<logVars, precommitVars, leaderVars,
                         configVars, hbVars>>

       \/ \* Same or lower term: process response
          \* *** Bug Family 5: processes stale (lower term) responses too! ***
          \* handle_append_entries.cxx:1169 does not check m.mterm == currentTerm
          /\ m.mterm <= currentTerm[i]
          /\ IF m.msuccess
             THEN \* handle_append_entries.cxx:1204-1304
                  /\ nextIndex'  = [nextIndex  EXCEPT ![i][m.msource] = m.mmatchIndex + 1]
                  /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] = m.mmatchIndex]
             ELSE \* handle_append_entries.cxx:1334-1340: fast rewind
                  /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] =
                                       Max(1, nextIndex[i][m.msource] - 1)]
                  /\ UNCHANGED matchIndex
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, precommitVars, candidateVars,
                         persistVars, configVars, quorumVars, hbVars>>

----
\* Commit Actions
----

\* Leader i advances commitIndex based on quorum.
\* Reference: handle_append_entries.cxx:1523-1608 (get_expected_committed_log_idx)
\*
\* *** Bug Family 7: NO term check on entries! ***
\* Code at line 1523-1608 is purely quorum-based: sorts matched indices,
\* picks the quorum-th largest. Does NOT verify log[idx].term == currentTerm.
\* Relies on config entry from BecomeLeader as implicit barrier (Family 7).
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET \* handle_append_entries.cxx:1529-1540: collect matched indices
           Agree(idx) == {i} \cup {s \in Server \ {i} : matchIndex[i][s] >= idx}
           \* Bug Family 7: no log[i][idx].term = currentTerm[i] check!
           agreeIdxs == {idx \in (commitIndex[i]+1)..LastLogIndex(i) :
                          IsCommitQuorum(Agree(idx), i)}
       IN
       /\ agreeIdxs /= {}
       /\ LET newCommitIdx == SetMax(agreeIdxs)
          IN commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
    /\ UNCHANGED <<serverVars, log, smCommitIndex, precommitVars, leaderVars,
                   candidateVars, messages, persistVars, configVars, quorumVars, hbVars>>

\* Background commit thread advances smCommitIndex by one entry.
\* Reference: handle_commit.cxx:184-319 (commit_in_bg_exec)
\*
\* *** Bug Family 1: checks precommitIndex >= smCommitIndex ***
\* handle_commit.cxx:363-369: fatal exit N23_precommit_order_inversion
\* if precommit_index < commit_index.
CommitEntry(i) ==
    /\ smCommitIndex[i] < commitIndex[i]
    /\ smCommitIndex[i] < LastLogIndex(i)
    /\ LET idxToCommit == smCommitIndex[i] + 1
       IN
       \* Bug Family 1: precommit ordering check (handle_commit.cxx:363-369)
       \* In real code, this is a fatal assertion. In the spec, we model it
       \* as a precondition (if violated, the system would crash).
       /\ precommitIndex[i] >= idxToCommit
       \* handle_commit.cxx:270-278: commit entry (app_log or conf)
       /\ smCommitIndex' = [smCommitIndex EXCEPT ![i] = idxToCommit]
       \* handle_commit.cxx:273-274: if conf entry, commit_conf
       /\ IF log[i][idxToCommit].type = ConfigEntry
          THEN configChanging' = [configChanging EXCEPT ![i] = FALSE]
          ELSE UNCHANGED configChanging
    /\ UNCHANGED <<serverVars, log, commitIndex, precommitVars, leaderVars,
                   candidateVars, messages, persistVars, quorumVars, hbVars>>

----
\* Configuration Change Actions (Bug Family 3)
----

\* Leader i proposes a configuration change (add/remove server).
\* Reference: handle_join_leave.cxx, raft_server.cxx
\*
\* *** Bug Family 3: guarded by config_changing_ == false ***
\* This models the one-change-at-a-time constraint.
ProposeConfigChange(i) ==
    /\ state[i] = Leader
    \* Bug Family 3: config_changing_ guard
    /\ configChanging[i] = FALSE
    /\ LET entry == [term |-> currentTerm[i], type |-> ConfigEntry]
       IN
       /\ log' = [log EXCEPT ![i] = Append(@, entry)]
       /\ precommitIndex' = [precommitIndex EXCEPT ![i] = LastLogIndex(i) + 1]
       /\ configChanging' = [configChanging EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<serverVars, commitIndex, smCommitIndex, leaderVars,
                   candidateVars, messages, persistVars, quorumVars, hbVars>>

\* set_priority bypasses config_changing_ guard.
\* Reference: handle_priority.cxx:39-107 -- no config_changing_ check!
\*
\* *** Bug Family 3 (MC-5): This action creates concurrent config changes ***
BypassConfigGuard(i) ==
    /\ state[i] = Leader
    \* Bug Family 3: NO config_changing_ check! (handle_priority.cxx has no guard)
    /\ LET entry == [term |-> currentTerm[i], type |-> ConfigEntry]
       IN
       /\ log' = [log EXCEPT ![i] = Append(@, entry)]
       /\ precommitIndex' = [precommitIndex EXCEPT ![i] = LastLogIndex(i) + 1]
       /\ configChanging' = [configChanging EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<serverVars, commitIndex, smCommitIndex, leaderVars,
                   candidateVars, messages, persistVars, quorumVars, hbVars>>

----
\* Quorum Adjustment Actions (Bug Family 4)
----

\* Server i adjusts quorum to 1 for a 2-node cluster.
\* Reference: handle_vote.cxx:105-123 (in request_prevote, candidate side)
\*            handle_append_entries.cxx:195-243 (in request_append_entries, leader side)
\*
\* *** Bug Family 4 (MC-1): Both nodes can independently lower quorum ***
\* In a 2-node cluster, both nodes can set custom_commit_quorum_size_ = 1,
\* enabling single-node commits and potential split-brain.
AdjustQuorum(i) ==
    /\ Cardinality(Server) = 2
    /\ customQuorumSize[i] = 0
    \* Models both leader path (handle_append_entries.cxx:195-243)
    \* and candidate path (handle_vote.cxx:105-123)
    /\ state[i] \in {Leader, Candidate}
    \* handle_vote.cxx:119-123, handle_append_entries.cxx:222-225
    /\ customQuorumSize' = [customQuorumSize EXCEPT ![i] = 1]
    /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                   candidateVars, messages, persistVars, configVars, hbVars>>

\* Server i restores default quorum.
\* Reference: raft_server.cxx:1533-1542 (in become_follower)
\*            handle_append_entries.cxx:233-243 (peer responding again)
RestoreQuorum(i) ==
    /\ Cardinality(Server) = 2
    /\ customQuorumSize[i] > 0
    /\ customQuorumSize' = [customQuorumSize EXCEPT ![i] = 0]
    /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                   candidateVars, messages, persistVars, configVars, hbVars>>

----
\* Crash and Recovery (Bug Families 2, 3)
----

\* Server i crashes. All volatile state is lost.
\* Recovers from persisted state.
\*
\* *** Bug Family 2: If InitiateVote ran but PersistState didn't,
\* the node recovers with STALE term/votedFor. ***
\* It can then vote for a different candidate in the "new" term.
\*
\* *** Bug Family 3: configChanging_ is volatile, reset on crash. ***
Crash(i) ==
    \* Recover from persisted state (Bug Family 2)
    /\ currentTerm' = [currentTerm EXCEPT ![i] = persistedTerm[i]]
    /\ votedFor'    = [votedFor    EXCEPT ![i] = persistedVotedFor[i]]
    /\ state' = [state EXCEPT ![i] = Follower]
    \* Volatile state reset
    /\ commitIndex'    = [commitIndex    EXCEPT ![i] = 0]
    /\ smCommitIndex'  = [smCommitIndex  EXCEPT ![i] = 0]
    /\ precommitIndex' = [precommitIndex EXCEPT ![i] = LastLogIndex(i)]
    /\ nextIndex'      = [nextIndex      EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'     = [matchIndex     EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted'   = [votesGranted   EXCEPT ![i] = {}]
    /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
    \* Bug Family 3: configChanging_ is volatile
    /\ configChanging' = [configChanging EXCEPT ![i] = FALSE]
    \* Bug Family 4: quorum adjustment is volatile (params reset)
    /\ customQuorumSize' = [customQuorumSize EXCEPT ![i] = 0]
    /\ hbAlive' = [hbAlive EXCEPT ![i] = FALSE]
    \* Log and persisted state survive crash
    /\ UNCHANGED <<log, persistVars, messages>>

----
\* Network Failures
----

LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                   candidateVars, persistVars, configVars, quorumVars, hbVars>>

DropStaleMessage(m) ==
    /\ m \in DOMAIN messages
    /\ m.mtype \in {AppendEntriesRequest, AppendEntriesResponse,
                    RequestVoteRequest, RequestVoteResponse,
                    PreVoteRequest, PreVoteResponse}
    /\ m.mterm < currentTerm[m.mdest]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, precommitVars, leaderVars,
                   candidateVars, persistVars, configVars, quorumVars, hbVars>>

----
\* Spec
----

Next ==
    \/ \E i \in Server :
        \/ Timeout(i)
        \/ InitiateVote(i)
        \/ PersistState(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ AdvanceCommitIndex(i)
        \/ CommitEntry(i)
        \/ ProposeConfigChange(i)
        \/ BypassConfigGuard(i)
        \/ AdjustQuorum(i)
        \/ RestoreQuorum(i)
        \/ Crash(i)
    \/ \E i, j \in Server :
        \/ AppendEntries(i, j)
    \/ \E m \in DOMAIN messages :
        \/ HandlePreVoteRequest(m.mdest, m)
        \/ HandlePreVoteResponse(m.mdest, m)
        \/ HandleVoteRequest(m.mdest, m)
        \/ HandleVoteResponse(m.mdest, m)
        \/ HandleAppendEntries(m.mdest, m)
        \/ HandleAppendEntriesResponse(m.mdest, m)
        \/ DropStaleMessage(m)
        \/ LoseMessage(m)

Spec == Init /\ [][Next]_vars

----
\* Invariants
----

\* === Standard Raft Invariants ===

\* At most one leader per term.
ElectionSafety ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ state[s2] = Leader /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* If two logs have the same term at the same index,
\* the logs are identical up to that point.
LogMatching ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(LastLogIndex(s1), LastLogIndex(s2)) :
            log[s1][idx].term = log[s2][idx].term =>
                \A k \in 1..idx : log[s1][k].term = log[s2][k].term

\* Committed entries appear in all future leaders' logs.
LeaderCompleteness ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ smCommitIndex[s2] > 0) =>
            \A idx \in 1..smCommitIndex[s2] :
                /\ idx <= LastLogIndex(s1)
                /\ log[s1][idx].term = log[s2][idx].term

\* === Extension Invariants (Bug Family Targets) ===

\* Bug Family 1: Precommit ordering.
\* sm_commit_index <= precommit_index (the N23_precommit_order_inversion check).
\* NOTE: precommit_index CAN transiently exceed log length after conflict
\* truncation in HandleAppendEntries, because try_update_precommit_index
\* (handle_append_entries.cxx:1146-1167) only advances via CAS, never decreases.
\* This is safe because committed entries are never truncated (Raft guarantee).
PrecommitOrdering ==
    \A s \in Server :
        smCommitIndex[s] <= precommitIndex[s]

\* Bug Family 2: Vote uniqueness across crashes.
\* If persisted votedFor is set, the in-memory votedFor should match
\* or the term should have advanced.
VoteUniqueness ==
    \A s \in Server :
        persistedVotedFor[s] /= Nil =>
            \/ votedFor[s] = persistedVotedFor[s]
            \/ currentTerm[s] > persistedTerm[s]

\* Bug Family 2: Crash recovery consistency.
\* After recovery, persisted term >= any term the node previously persisted.
\* (This is a structural invariant; the real check is ElectionSafety.)
CrashRecoveryConsistency ==
    \A s \in Server :
        persistedTerm[s] <= currentTerm[s]

\* Bug Family 3: Config change atomicity.
\* At most one uncommitted config change at a time.
ConfigChangeAtomicity ==
    \A s \in Server :
        state[s] = Leader =>
            LET configIndices == {idx \in (smCommitIndex[s]+1)..LastLogIndex(s) :
                                    log[s][idx].type = ConfigEntry}
            IN Cardinality(configIndices) <= 1

\* Bug Family 4: No split-brain commit.
\* No two servers sm-commit different values at the same index.
NoSplitBrainCommit ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(smCommitIndex[s1], smCommitIndex[s2]) :
            log[s1][idx] = log[s2][idx]

\* Bug Family 5: No stale response commit.
\* If a leader's matchIndex says peer has matched up to M,
\* the peer should actually have that entry.
NoStaleMatchIndex ==
    \A s \in Server :
        state[s] = Leader =>
            \A t \in Server \ {s} :
                matchIndex[s][t] > 0 =>
                    /\ matchIndex[s][t] <= LastLogIndex(t)
                    /\ matchIndex[s][t] <= LastLogIndex(s)
                    /\ LogTerm(t, matchIndex[s][t]) = LogTerm(s, matchIndex[s][t])

\* === Structural Invariants ===

\* commitIndex should not exceed log length.
CommitIndexBound ==
    \A s \in Server :
        /\ commitIndex[s] <= LastLogIndex(s) \/ commitIndex[s] = 0
        /\ smCommitIndex[s] <= commitIndex[s] \/ TRUE

\* Log entries have positive terms.
LogTermPositive ==
    \A s \in Server :
        \A idx \in 1..LastLogIndex(s) :
            log[s][idx].term > 0

\* Current term is non-decreasing (within a single execution, no crashes).
TermMonotonicity ==
    \A s \in Server :
        currentTerm[s] >= 0

=============================================================================
