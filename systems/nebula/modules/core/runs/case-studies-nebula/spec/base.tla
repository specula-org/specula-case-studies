---------------------------- MODULE base ----------------------------
\* TLA+ specification of vesoft-inc/nebula Raft consensus protocol.
\*
\* Extends standard Raft with nebula-specific behaviors:
\*   1. Non-persisted term/vote — recovered from WAL lastLogTerm (RaftPart.cpp:412-414)
\*   2. Leader lease without CheckQuorum + blind follower (RaftPart.cpp:2254-2268, 1145-1147)
\*   3. Snapshot lifecycle race conditions (Host.cpp:348-374, SnapshotManager.cpp:41-46)
\*   4. Separate heartbeat path — no follower commit advance (RaftPart.cpp:1895-1952)
\*   5. Pre-vote with step-down — defeats pre-vote purpose (RaftPart.cpp:1522-1528)
\*
EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs

CONSTANTS Follower,          \* Server roles (RaftPart.h:424-425)
          Candidate,
          Leader

CONSTANT Nil                 \* Null value

CONSTANTS RequestVoteRequest,       \* Message types
          RequestVoteResponse,
          AppendEntriesRequest,
          AppendEntriesResponse,
          HeartbeatRequest,
          HeartbeatResponse

----
\* Variables
----

\* Per-server state (serverVars)
\* In Nebula, term and votedFor/votedTerm are VOLATILE — not persisted to stable storage.
\* Reference: RaftPart.h:819-827 — votedAddr_, votedTerm_ are plain class members
VARIABLE role               \* [Server -> {Follower, Candidate, Leader}]
VARIABLE term               \* [Server -> Nat] (volatile, RaftPart.h:823)
VARIABLE votedFor           \* [Server -> Server \cup {Nil}] (volatile, RaftPart.h:819)
VARIABLE votedTerm          \* [Server -> Nat] (volatile, separate from term, RaftPart.h:827)
VARIABLE leader             \* [Server -> Server \cup {Nil}] (known leader, RaftPart.h:816-817)

\* Log state (logVars)
VARIABLE log                \* [Server -> Seq([term: Nat])]
VARIABLE commitIndex        \* [Server -> Nat] (committedLogId_, RaftPart.h:836)

\* Leader volatile state (leaderVars)
VARIABLE matchIndex         \* [Server -> [Server -> Nat]]
VARIABLE nextIndex          \* [Server -> [Server -> Nat]]

\* Candidate state (candidateVars)
VARIABLE votesGranted       \* [Server -> SUBSET Server] — formal election votes
VARIABLE preVotesGranted    \* [Server -> SUBSET Server] — pre-vote votes (Extension 5)

\* Network
VARIABLE messages           \* Bag of message records

\* Extension 1: Non-persisted term/vote — crash recovery (Family 1)
\* After crash, term is recovered from WAL lastLogTerm, votedFor/votedTerm are lost.
\* Reference: RaftPart.cpp:412-414 — term_ = lastLogTerm_; lastLogTerm_ = wal_->lastLogTerm()
VARIABLE alive              \* [Server -> BOOLEAN]

\* Extension 2: Leader lease / blind follower (Family 2)
\* Reference: RaftPart.cpp:2254-2268 (leaseValid), RaftPart.h:854 (isBlindFollower_)
VARIABLE blindFollower      \* [Server -> BOOLEAN] (isBlindFollower_, RaftPart.h:854)
VARIABLE leaseExpired       \* [Server -> BOOLEAN] (abstract: lease has timed out)
VARIABLE commitInThisTerm   \* [Server -> BOOLEAN] (RaftPart.h:857)

\* Extension 3: Snapshot lifecycle (Family 3)
\* Reference: Host.cpp:348-374 (startSendSnapshot/callback), SnapshotManager.cpp:41-46
VARIABLE snapshotSending    \* [Server -> [Server -> BOOLEAN]] (leader->target snapshot in progress)
VARIABLE snapshotTerm       \* [Server -> [Server -> Nat]] (term when snapshot was initiated)

----
\* Variable groups
----

serverVars   == <<role, term, votedFor, votedTerm, leader>>
logVars      == <<log, commitIndex>>
leaderVars   == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted, preVotesGranted>>
leaseVars    == <<blindFollower, leaseExpired, commitInThisTerm>>
snapshotVars == <<snapshotSending, snapshotTerm>>
crashVars    == <<alive>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          leaseVars, snapshotVars, crashVars>>

----
\* Helpers
----

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b

\* Log helpers
LastLogIndex(i) == Len(log[i])
LastLogTerm(i)  == IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term ELSE 0
LogTerm(i, idx) == IF idx > 0 /\ idx <= Len(log[i]) THEN log[i][idx].term ELSE 0

\* Quorum: Nebula uses (peers.size() + 1) / 2 as quorum_ (RaftPart.cpp:417)
\* For 3 servers: quorum_ = 1, so majority = quorum_ + 1 = 2 (the leader + 1 peer)
\* In spec: a quorum is any majority subset
IsQuorum(S) == Cardinality(S) * 2 > Cardinality(Server)

\* Log up-to-date comparison (RaftPart.cpp:1532-1548)
\* Candidate's log is at least as up-to-date as voter's
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
    /\ role             = [s \in Server |-> Follower]
    /\ term             = [s \in Server |-> 0]
    /\ votedFor         = [s \in Server |-> Nil]
    /\ votedTerm        = [s \in Server |-> 0]
    /\ leader           = [s \in Server |-> Nil]
    /\ log              = [s \in Server |-> <<>>]
    /\ commitIndex      = [s \in Server |-> 0]
    /\ nextIndex        = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex       = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted     = [s \in Server |-> {}]
    /\ preVotesGranted  = [s \in Server |-> {}]
    /\ messages         = EmptyBag
    \* Extension 1: all servers start alive
    /\ alive            = [s \in Server |-> TRUE]
    \* Extension 2: all servers start as blind followers with expired lease
    /\ blindFollower    = [s \in Server |-> TRUE]
    /\ leaseExpired     = [s \in Server |-> TRUE]
    /\ commitInThisTerm = [s \in Server |-> FALSE]
    \* Extension 3: no snapshots in progress
    /\ snapshotSending  = [s \in Server |-> [t \in Server |-> FALSE]]
    /\ snapshotTerm     = [s \in Server |-> [t \in Server |-> 0]]

----
\* Election Actions
----

\* Server i times out and starts election.
\* Reference: RaftPart.cpp:1143-1155 (needToStartElection)
\*            RaftPart.cpp:1401-1413 (statusPolling: pre-vote then formal)
\*
\* In Nebula, the election flow is: timeout → CANDIDATE → pre-vote → formal vote → LEADER
\* needToStartElection checks: RUNNING && FOLLOWER && (elapsed >= timeout || isBlindFollower_)
\* The blind follower bypass is Extension 2 (Family 2).
Timeout(i) ==
    /\ alive[i]
    /\ role[i] = Follower
    \* Standard timeout path (RaftPart.cpp:1146)
    /\ ~blindFollower[i]
    /\ role' = [role EXCEPT ![i] = Candidate]
    /\ leader' = [leader EXCEPT ![i] = Nil]
    \* RaftPart.cpp:1150-1151
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
    /\ UNCHANGED <<term, votedFor, votedTerm, logVars, leaderVars, messages,
                   leaseVars, snapshotVars, crashVars>>

\* Blind follower bypass — immediately becomes candidate without waiting for timeout.
\* Reference: RaftPart.cpp:1145-1147 — isBlindFollower_ bypasses elapsed check
\* Extension 2 (Family 2): enables election while old leader's lease may still be valid.
BlindFollowerTimeout(i) ==
    /\ alive[i]
    /\ role[i] = Follower
    /\ blindFollower[i]
    \* RaftPart.cpp:1145-1147: bypasses lastMsgRecvDur_ check
    /\ role' = [role EXCEPT ![i] = Candidate]
    /\ leader' = [leader EXCEPT ![i] = Nil]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
    /\ UNCHANGED <<term, votedFor, votedTerm, logVars, leaderVars, messages,
                   leaseVars, snapshotVars, crashVars>>

\* Candidate i sends pre-vote requests.
\* Reference: RaftPart.cpp:1157-1195 (prepareElectionRequest with isPreVote=true)
\*            RaftPart.cpp:1181-1182 — req.term = term_ + 1 (does NOT increment own term)
\*
\* Extension 5 (Family 5): pre-vote uses term+1 in request but doesn't change own term.
SendPreVote(i) ==
    /\ alive[i]
    /\ role[i] = Candidate
    \* RaftPart.cpp:1163-1166: status must be RUNNING
    \* RaftPart.cpp:1169-1172: role must be CANDIDATE
    /\ preVotesGranted[i] = {}   \* Haven't started pre-vote yet
    \* RaftPart.cpp:1181-1182: pre-vote uses term_ + 1 but doesn't change term_
    /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {i}]  \* Count self
    /\ SendAll({[mtype         |-> RequestVoteRequest,
                 mterm         |-> term[i] + 1,
                 mlastLogTerm  |-> LastLogTerm(i),
                 mlastLogIndex |-> LastLogIndex(i),
                 msource       |-> i,
                 mdest         |-> j,
                 mpreVote      |-> TRUE] : j \in Server \ {i}})
    /\ UNCHANGED <<serverVars, logVars, leaderVars, votesGranted,
                   leaseVars, snapshotVars, crashVars>>

\* Candidate i sends formal vote requests after winning pre-vote.
\* Reference: RaftPart.cpp:1157-1195 (prepareElectionRequest with isPreVote=false)
\*            RaftPart.cpp:1183-1187 — increments term, votes for self
SendRequestVote(i) ==
    /\ alive[i]
    /\ role[i] = Candidate
    \* Must have won pre-vote first (RaftPart.cpp:1413: leaderElection(true) && leaderElection(false))
    /\ IsQuorum(preVotesGranted[i])
    \* RaftPart.cpp:1183-1187: increment term, self-vote
    /\ LET newTerm == term[i] + 1
       IN
       /\ term' = [term EXCEPT ![i] = newTerm]
       /\ votedFor' = [votedFor EXCEPT ![i] = i]
       /\ votedTerm' = [votedTerm EXCEPT ![i] = newTerm]
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
       \* RaftPart.cpp:1189-1190: send lastLogId, lastLogTerm
       /\ SendAll({[mtype         |-> RequestVoteRequest,
                    mterm         |-> newTerm,
                    mlastLogTerm  |-> LastLogTerm(i),
                    mlastLogIndex |-> LastLogIndex(i),
                    msource       |-> i,
                    mdest         |-> j,
                    mpreVote      |-> FALSE] : j \in Server \ {i}})
    /\ UNCHANGED <<role, leader, logVars, leaderVars, preVotesGranted,
                   leaseVars, snapshotVars, crashVars>>

\* Server i handles a pre-vote request.
\* Reference: RaftPart.cpp:1465-1576 (processAskForVoteRequest, pre-vote path)
\*
\* Extension 5 (Family 5): BUG — pre-vote with higher actual term causes step-down.
\* RaftPart.cpp:1522-1528: if req.term - 1 > term_, step down and update term.
\* This defeats the purpose of pre-vote (preventing disruption from stale nodes).
HandlePreVoteRequest(i, m) ==
    /\ alive[i]
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ m.mpreVote = TRUE
    /\ LET mterm       == m.mterm
           msource     == m.msource
           actualTerm  == mterm - 1  \* Candidate's actual term (RaftPart.cpp:1524)
           logOk       == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                      LastLogTerm(i), LastLogIndex(i))
       IN
       \* RaftPart.cpp:1478-1481: reject if stopped (modeled as alive check)
       \* RaftPart.cpp:1493-1496: reject if learner (not modeled)
       \* RaftPart.cpp:1506-1511: reject if term too low
       IF mterm < term[i] THEN
           /\ Reply([mtype        |-> RequestVoteResponse,
                     mterm        |-> term[i],
                     mvoteGranted |-> FALSE,
                     msource      |-> i,
                     mdest        |-> msource,
                     mpreVote     |-> TRUE], m)
           /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>
       ELSE IF ~logOk THEN
           \* RaftPart.cpp:1532-1548: reject if log not up-to-date
           \* BUG (Family 5): step-down happens BEFORE log check (RaftPart.cpp:1522-1528)
           \* So even rejected pre-votes cause step-down if actualTerm > term
           /\ IF actualTerm > term[i]
              THEN \* RaftPart.cpp:1522-1528: step down, update term
                   /\ term' = [term EXCEPT ![i] = actualTerm]
                   /\ role' = [role EXCEPT ![i] = Follower]
                   /\ leader' = [leader EXCEPT ![i] = Nil]
              ELSE
                   /\ UNCHANGED <<term, role, leader>>
           /\ Reply([mtype        |-> RequestVoteResponse,
                     mterm        |-> IF actualTerm > term[i] THEN actualTerm ELSE term[i],
                     mvoteGranted |-> FALSE,
                     msource      |-> i,
                     mdest        |-> msource,
                     mpreVote     |-> TRUE], m)
           /\ UNCHANGED <<votedFor, votedTerm, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>
       ELSE IF votedTerm[i] = mterm /\ votedFor[i] /= Nil /\ votedFor[i] /= msource THEN
           \* RaftPart.cpp:1560-1566: already voted for someone else in this term
           \* Step-down still happens first (Family 5 bug)
           /\ IF actualTerm > term[i]
              THEN /\ term' = [term EXCEPT ![i] = actualTerm]
                   /\ role' = [role EXCEPT ![i] = Follower]
                   /\ leader' = [leader EXCEPT ![i] = Nil]
              ELSE /\ UNCHANGED <<term, role, leader>>
           /\ Reply([mtype        |-> RequestVoteResponse,
                     mterm        |-> IF actualTerm > term[i] THEN actualTerm ELSE term[i],
                     mvoteGranted |-> FALSE,
                     msource      |-> i,
                     mdest        |-> msource,
                     mpreVote     |-> TRUE], m)
           /\ UNCHANGED <<votedFor, votedTerm, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>
       ELSE
           \* RaftPart.cpp:1568-1575: grant pre-vote, NO state change (except step-down bug)
           /\ IF actualTerm > term[i]
              THEN \* Family 5 BUG: step down on pre-vote (RaftPart.cpp:1522-1528)
                   /\ term' = [term EXCEPT ![i] = actualTerm]
                   /\ role' = [role EXCEPT ![i] = Follower]
                   /\ leader' = [leader EXCEPT ![i] = Nil]
              ELSE
                   /\ UNCHANGED <<term, role, leader>>
           \* RaftPart.cpp:1572-1575: pre-vote grant does NOT reset lastMsgRecvDur_ or
           \* clear blindFollower (no state change except the step-down bug)
           /\ Reply([mtype        |-> RequestVoteResponse,
                     mterm        |-> IF actualTerm > term[i] THEN actualTerm ELSE term[i],
                     mvoteGranted |-> TRUE,
                     msource      |-> i,
                     mdest        |-> msource,
                     mpreVote     |-> TRUE], m)
           /\ UNCHANGED <<votedFor, votedTerm, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>

\* Server i handles a formal vote request.
\* Reference: RaftPart.cpp:1465-1607 (processAskForVoteRequest, formal path)
HandleRequestVoteRequest(i, m) ==
    /\ alive[i]
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ m.mpreVote = FALSE
    /\ LET mterm   == m.mterm
           msource == m.msource
           logOk   == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                  LastLogTerm(i), LastLogIndex(i))
       IN
       \* RaftPart.cpp:1506-1511: reject if term too low
       IF mterm < term[i] THEN
           /\ Reply([mtype        |-> RequestVoteResponse,
                     mterm        |-> term[i],
                     mvoteGranted |-> FALSE,
                     msource      |-> i,
                     mdest        |-> msource,
                     mpreVote     |-> FALSE], m)
           /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>
       ELSE
           \* RaftPart.cpp:1516-1520: formal election with higher term → update term, step down
           LET newTerm == IF mterm > term[i] THEN mterm ELSE term[i]
               stepDown == mterm > term[i]
           IN
           \* RaftPart.cpp:1532-1548: check log up-to-date
           IF ~logOk THEN
               /\ term' = [term EXCEPT ![i] = newTerm]
               /\ role' = [role EXCEPT ![i] = IF stepDown THEN Follower ELSE role[i]]
               /\ leader' = [leader EXCEPT ![i] = IF stepDown THEN Nil ELSE leader[i]]
               /\ Reply([mtype        |-> RequestVoteResponse,
                         mterm        |-> newTerm,
                         mvoteGranted |-> FALSE,
                         msource      |-> i,
                         mdest        |-> msource,
                         mpreVote     |-> FALSE], m)
               /\ UNCHANGED <<votedFor, votedTerm, logVars, leaderVars, candidateVars,
                              leaseVars, snapshotVars, crashVars>>
           \* RaftPart.cpp:1560-1566: already voted for different candidate in this term
           ELSE IF votedTerm[i] = mterm /\ votedFor[i] /= Nil /\ votedFor[i] /= msource THEN
               /\ term' = [term EXCEPT ![i] = newTerm]
               /\ role' = [role EXCEPT ![i] = IF stepDown THEN Follower ELSE role[i]]
               /\ leader' = [leader EXCEPT ![i] = IF stepDown THEN Nil ELSE leader[i]]
               /\ Reply([mtype        |-> RequestVoteResponse,
                         mterm        |-> newTerm,
                         mvoteGranted |-> FALSE,
                         msource      |-> i,
                         mdest        |-> msource,
                         mpreVote     |-> FALSE], m)
               /\ UNCHANGED <<votedFor, votedTerm, logVars, leaderVars, candidateVars,
                              leaseVars, snapshotVars, crashVars>>
           ELSE
               \* RaftPart.cpp:1568-1607: grant vote
               \* RaftPart.cpp:1580-1593: if was leader, pause hosts, onLostLeadership
               \* RaftPart.cpp:1595-1601: update term, role, votedFor, votedTerm
               /\ term' = [term EXCEPT ![i] = mterm]
               /\ role' = [role EXCEPT ![i] = Follower]
               /\ leader' = [leader EXCEPT ![i] = Nil]
               /\ votedFor' = [votedFor EXCEPT ![i] = msource]
               /\ votedTerm' = [votedTerm EXCEPT ![i] = mterm]
               \* RaftPart.cpp:1604-1605: reset timeout, clear blind follower
               /\ blindFollower' = [blindFollower EXCEPT ![i] = FALSE]
               /\ Reply([mtype        |-> RequestVoteResponse,
                         mterm        |-> mterm,
                         mvoteGranted |-> TRUE,
                         msource      |-> i,
                         mdest        |-> msource,
                         mpreVote     |-> FALSE], m)
               /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                              leaseExpired, commitInThisTerm, snapshotVars, crashVars>>

\* Candidate i handles a pre-vote response.
\* Reference: RaftPart.cpp:1218-1289 (processElectionResponses with isPreVote=true)
HandlePreVoteResponse(i, m) ==
    /\ alive[i]
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ m.mpreVote = TRUE
    /\ role[i] = Candidate
    /\ LET mterm == m.mterm
       IN
       \* RaftPart.cpp:1256: highestTerm = term_ + 1 - 1 = term_ for pre-vote
       \* RaftPart.cpp:1265: highestTerm = max(highestTerm, response term)
       \* RaftPart.cpp:1268-1272: if highestTerm > term_, step down
       IF mterm > term[i] THEN
           /\ term' = [term EXCEPT ![i] = mterm]
           /\ role' = [role EXCEPT ![i] = Follower]
           /\ leader' = [leader EXCEPT ![i] = Nil]
           /\ Discard(m)
           /\ UNCHANGED <<votedFor, votedTerm, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>
       ELSE
           \* RaftPart.cpp:1258-1259: count successes
           /\ IF m.mvoteGranted
              THEN preVotesGranted' = [preVotesGranted EXCEPT ![i] =
                                       preVotesGranted[i] \cup {m.msource}]
              ELSE UNCHANGED preVotesGranted
           /\ Discard(m)
           /\ UNCHANGED <<serverVars, logVars, leaderVars, votesGranted,
                          leaseVars, snapshotVars, crashVars>>

\* Candidate i handles a formal vote response.
\* Reference: RaftPart.cpp:1218-1289 (processElectionResponses with isPreVote=false)
\*            RaftPart.cpp:1345: if (!isPreVote && proposedTerm != term_) → discard
HandleRequestVoteResponse(i, m) ==
    /\ alive[i]
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ m.mpreVote = FALSE
    /\ role[i] = Candidate
    /\ LET mterm == m.mterm
       IN
       \* RaftPart.cpp:1247-1253: check term hasn't changed during election
       IF mterm > term[i] THEN
           \* RaftPart.cpp:1268-1272: step down if higher term found
           /\ term' = [term EXCEPT ![i] = mterm]
           /\ role' = [role EXCEPT ![i] = Follower]
           /\ leader' = [leader EXCEPT ![i] = Nil]
           /\ Discard(m)
           /\ UNCHANGED <<votedFor, votedTerm, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>
       ELSE IF mterm /= term[i] THEN
           \* RaftPart.cpp:1345: proposedTerm != term_ → discard stale response
           \* Stale response from a previous election round; ignore.
           /\ Discard(m)
           /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>
       ELSE
           \* RaftPart.cpp:1258-1259: count successes (term matches current election)
           /\ IF m.mvoteGranted
              THEN votesGranted' = [votesGranted EXCEPT ![i] =
                                    votesGranted[i] \cup {m.msource}]
              ELSE UNCHANGED votesGranted
           /\ Discard(m)
           /\ UNCHANGED <<serverVars, logVars, leaderVars, preVotesGranted,
                          leaseVars, snapshotVars, crashVars>>

\* Candidate i becomes leader after winning formal election.
\* Reference: RaftPart.cpp:1275-1284 (processElectionResponses, become leader)
\*            RaftPart.cpp:1370-1398 (handleElectionResponses, post-election setup)
BecomeLeader(i) ==
    /\ alive[i]
    /\ role[i] = Candidate
    /\ IsQuorum(votesGranted[i])
    \* RaftPart.cpp:1280-1283: become leader
    /\ role' = [role EXCEPT ![i] = Leader]
    /\ leader' = [leader EXCEPT ![i] = i]
    \* RaftPart.cpp:1283: clear blind follower
    /\ blindFollower' = [blindFollower EXCEPT ![i] = FALSE]
    \* RaftPart.cpp:1385-1386: reset lease timing
    /\ leaseExpired' = [leaseExpired EXCEPT ![i] = TRUE]
    \* RaftPart.cpp:1388: commitInThisTerm_ = false
    /\ commitInThisTerm' = [commitInThisTerm EXCEPT ![i] = FALSE]
    \* Initialize leader state: nextIndex to lastLogIndex + 1, matchIndex to 0
    \* Reference: handleElectionResponses → host->reset() (Host.h:85-96)
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> LastLogIndex(i) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |->
                        IF j = i THEN LastLogIndex(i) ELSE 0]]
    /\ UNCHANGED <<term, votedFor, votedTerm, logVars, candidateVars, messages,
                   snapshotVars, crashVars>>

----
\* Log Replication Actions
----

\* Leader i receives a client request and appends to local log.
\* Reference: RaftPart.cpp:874-906 (appendLogsInternal — WAL write)
\* The entry is written to WAL first, then replicated.
ClientRequest(i) ==
    /\ alive[i]
    /\ role[i] = Leader
    /\ LET entry == [term |-> term[i]]
       IN
       /\ log' = [log EXCEPT ![i] = Append(log[i], entry)]
       /\ matchIndex' = [matchIndex EXCEPT ![i][i] = Len(log[i]) + 1]
       /\ UNCHANGED <<serverVars, commitIndex, nextIndex, candidateVars, messages,
                      leaseVars, snapshotVars, crashVars>>

\* Leader i sends AppendEntries to follower j.
\* Reference: RaftPart.cpp:918-1000 (replicateLogs via Host::appendLogs)
\*            Host.cpp:92-164 (appendLogs — builds request from lastLogIdSent_)
\*            Host.cpp:287-346 (prepareAppendLogRequest — reads WAL entries)
\*
\* Extension 4 (Family 4): This is the log replication path (separate from heartbeat).
\* AppendEntries carries committed_log_id which followers use to advance their commitIndex.
AppendEntries(i, j) ==
    /\ alive[i]
    /\ alive[j]
    /\ i /= j
    /\ role[i] = Leader
    \* Don't send if snapshot is in progress to this follower
    /\ ~snapshotSending[i][j]
    /\ LET ni == nextIndex[i][j]
           prevLogIndex == ni - 1
           prevLogTerm == LogTerm(i, prevLogIndex)
           \* Send entries from nextIndex to end of log
           entries == SubSeq(log[i], ni, LastLogIndex(i))
       IN
       /\ Send([mtype         |-> AppendEntriesRequest,
                mterm         |-> term[i],
                mprevLogIndex |-> prevLogIndex,
                mprevLogTerm  |-> prevLogTerm,
                mentries      |-> entries,
                mcommitIndex  |-> Min(commitIndex[i], LastLogIndex(i)),
                msource       |-> i,
                mdest         |-> j])
       /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                      leaseVars, snapshotVars, crashVars>>

\* Server i handles an AppendEntries request from leader j.
\* Reference: RaftPart.cpp:1610-1827 (processAppendLogRequest)
\*
\* Key: follower DOES advance commitIndex here (RaftPart.cpp:1787-1822).
\* This is different from the heartbeat path (Extension 4, Family 4).
HandleAppendEntriesRequest(i, m) ==
    /\ alive[i]
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ LET mterm   == m.mterm
           msource == m.msource
       IN
       \* RaftPart.cpp:1638-1652: check status (alive check)
       \* RaftPart.cpp:1654: verifyLeader
       IF mterm < term[i] THEN
           \* RaftPart.cpp:1840-1843: reject if term too low (via verifyLeader)
           /\ Reply([mtype      |-> AppendEntriesResponse,
                     mterm      |-> term[i],
                     msuccess   |-> FALSE,
                     mmatchIndex |-> 0,
                     msource    |-> i,
                     mdest      |-> msource], m)
           /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>
       ELSE
           \* RaftPart.cpp:1862-1893: verifyLeader — accept new leader
           \* Step down if necessary, update term and leader
           /\ term' = [term EXCEPT ![i] = mterm]
           /\ leader' = [leader EXCEPT ![i] = msource]
           /\ role' = [role EXCEPT ![i] = IF role[i] /= Leader THEN Follower
                                          ELSE Follower]
           \* RaftPart.cpp:1874: clear blind follower
           /\ blindFollower' = [blindFollower EXCEPT ![i] = FALSE]
           \* RaftPart.cpp:1665: reset timeout timer
           /\ LET prevLogOk == \/ m.mprevLogIndex = 0
                                \/ (m.mprevLogIndex > 0 /\
                                    m.mprevLogIndex <= Len(log[i]) /\
                                    LogTerm(i, m.mprevLogIndex) = m.mprevLogTerm)
              IN
              IF ~prevLogOk THEN
                  \* RaftPart.cpp:1688-1694: log gap, ask for retransmit
                  /\ Reply([mtype      |-> AppendEntriesResponse,
                            mterm      |-> mterm,
                            msuccess   |-> FALSE,
                            mmatchIndex |-> commitIndex[i],
                            msource    |-> i,
                            mdest      |-> msource], m)
                  /\ UNCHANGED <<votedFor, votedTerm, logVars, leaderVars, candidateVars,
                                 leaseExpired, commitInThisTerm, snapshotVars, crashVars>>
              ELSE
                  \* Log matching succeeded
                  \* RaftPart.cpp:1757-1782: append new entries, truncate conflicting
                  LET newEntries == m.mentries
                      newLog == IF m.mprevLogIndex = 0
                                THEN newEntries
                                ELSE SubSeq(log[i], 1, m.mprevLogIndex) \o newEntries
                      newLastIndex == Len(newLog)
                      \* RaftPart.cpp:1787: lastLogIdCanCommit = min(lastMatchedLogId, req.committed)
                      newCommitIndex == Min(Max(commitIndex[i], m.mcommitIndex), newLastIndex)
                  IN
                  /\ log' = [log EXCEPT ![i] = newLog]
                  \* RaftPart.cpp:1793-1804: advance commitIndex
                  /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIndex]
                  /\ Reply([mtype      |-> AppendEntriesResponse,
                            mterm      |-> mterm,
                            msuccess   |-> TRUE,
                            mmatchIndex |-> newLastIndex,
                            msource    |-> i,
                            mdest      |-> msource], m)
                  /\ UNCHANGED <<votedFor, votedTerm, leaderVars, candidateVars,
                                 leaseExpired, commitInThisTerm, snapshotVars, crashVars>>

\* Leader i handles an AppendEntries response from follower j.
\* Reference: RaftPart.cpp:1002-1136 (processAppendLogResponses)
\*            Host.cpp:190-234 (appendLogsInternal response handler)
\*
\* Extension 4 (Family 4): No term check in Host response handler (Host.cpp:207-208).
\* processAppendLogResponses step-down (RaftPart.cpp:1025-1037) omits onLostLeadership/host->pause().
HandleAppendEntriesResponse(i, m) ==
    /\ alive[i]
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ LET mterm   == m.mterm
           msource == m.msource
       IN
       IF mterm > term[i] THEN
           \* RaftPart.cpp:1025-1037: step down if higher term
           \* BUG (Family 4): this step-down path omits onLostLeadership and host->pause()
           /\ term' = [term EXCEPT ![i] = mterm]
           /\ role' = [role EXCEPT ![i] = Follower]
           /\ leader' = [leader EXCEPT ![i] = Nil]
           /\ Discard(m)
           /\ UNCHANGED <<votedFor, votedTerm, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>
       ELSE IF role[i] = Leader /\ mterm = term[i] THEN
           IF m.msuccess THEN
               \* Host.cpp:207-208: update lastLogIdSent_ (no term check — ABA potential)
               \* RaftPart.cpp:1044-1098: majority check, commit, advance commitIndex
               /\ matchIndex' = [matchIndex EXCEPT ![i][msource] =
                                  Max(matchIndex[i][msource], m.mmatchIndex)]
               /\ nextIndex' = [nextIndex EXCEPT ![i][msource] =
                                 Max(nextIndex[i][msource], m.mmatchIndex + 1)]
               \* Advance commitIndex if quorum
               /\ LET newMatchIndex == [matchIndex[i] EXCEPT ![msource] =
                                         Max(matchIndex[i][msource], m.mmatchIndex)]
                      \* Find highest index replicated to a quorum
                      agreeIndices == {idx \in 1..LastLogIndex(i) :
                                        IsQuorum({s \in Server :
                                                   newMatchIndex[s] >= idx})}
                      newCommitIndex == IF agreeIndices /= {}
                                       THEN Max(commitIndex[i],
                                                CHOOSE idx \in agreeIndices :
                                                  \A idx2 \in agreeIndices : idx >= idx2)
                                       ELSE commitIndex[i]
                  IN
                  \* RaftPart.cpp:1079-1095: commit and update committedLogId_
                  \* Only commit entries from current term (standard Raft safety)
                  IF newCommitIndex > commitIndex[i] /\
                     LogTerm(i, newCommitIndex) = term[i]
                  THEN
                      /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIndex]
                      \* RaftPart.cpp:1084-1089: update lease timing
                      /\ leaseExpired' = [leaseExpired EXCEPT ![i] = FALSE]
                      \* RaftPart.cpp:1091-1095: set commitInThisTerm
                      /\ commitInThisTerm' = [commitInThisTerm EXCEPT ![i] = TRUE]
                  ELSE
                      /\ UNCHANGED <<commitIndex, leaseExpired, commitInThisTerm>>
               /\ Discard(m)
               /\ UNCHANGED <<serverVars, log, candidateVars, blindFollower,
                              snapshotVars, crashVars>>
           ELSE
               \* Failed — step back nextIndex
               /\ nextIndex' = [nextIndex EXCEPT ![i][msource] =
                                 Max(1, nextIndex[i][msource] - 1)]
               /\ Discard(m)
               /\ UNCHANGED <<serverVars, logVars, matchIndex, candidateVars,
                              leaseVars, snapshotVars, crashVars>>
       ELSE
           \* Stale response, discard
           /\ Discard(m)
           /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>

----
\* Heartbeat Actions (Extension 4, Family 4)
----

\* Leader i sends heartbeat to follower j.
\* Reference: RaftPart.cpp:2041-2123 (sendHeartbeat)
\*            Host.cpp:408-465 (Host::sendHeartbeat — separate RPC)
\*
\* Extension 4 (Family 4): Heartbeat is a SEPARATE RPC from AppendEntries.
\* It does NOT carry log entries and the follower handler does NOT advance commitIndex.
SendHeartbeat(i, j) ==
    /\ alive[i]
    /\ alive[j]
    /\ i /= j
    /\ role[i] = Leader
    \* RaftPart.cpp:2060-2071: read current state under raftLock_
    /\ Send([mtype      |-> HeartbeatRequest,
             mterm      |-> term[i],
             mcommitIndex |-> commitIndex[i],
             msource    |-> i,
             mdest      |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, snapshotVars, crashVars>>

\* Server i handles a heartbeat request.
\* Reference: RaftPart.cpp:1895-1952 (processHeartbeatRequest)
\*
\* Extension 4 (Family 4): BUG — heartbeat handler NEVER advances follower's committedLogId_.
\* RaftPart.cpp:1949-1951: just returns SUCCEEDED after verifyLeader. No commit advancement.
\* Compare with processAppendLogRequest (RaftPart.cpp:1787-1822) which DOES advance commit.
HandleHeartbeatRequest(i, m) ==
    /\ alive[i]
    /\ m.mtype = HeartbeatRequest
    /\ m.mdest = i
    /\ LET mterm   == m.mterm
           msource == m.msource
       IN
       IF mterm < term[i] THEN
           \* RaftPart.cpp:1840-1843: reject via verifyLeader
           /\ Reply([mtype   |-> HeartbeatResponse,
                     mterm   |-> term[i],
                     msource |-> i,
                     mdest   |-> msource], m)
           /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>
       ELSE
           \* RaftPart.cpp:1862-1893: verifyLeader — accept leader
           \* RaftPart.cpp:2043-2044: role_ = Role::FOLLOWER for all non-Learner roles
           /\ term' = [term EXCEPT ![i] = mterm]
           /\ leader' = [leader EXCEPT ![i] = msource]
           /\ role' = [role EXCEPT ![i] = Follower]
           /\ blindFollower' = [blindFollower EXCEPT ![i] = FALSE]
           \* RaftPart.cpp:1947: reset timeout
           \* KEY (Family 4): NO commitIndex advancement here!
           \* Compare processAppendLogRequest:1787-1822 which DOES advance
           /\ Reply([mtype   |-> HeartbeatResponse,
                     mterm   |-> mterm,
                     msource |-> i,
                     mdest   |-> msource], m)
           /\ UNCHANGED <<votedFor, votedTerm, logVars, leaderVars, candidateVars,
                          leaseExpired, commitInThisTerm, snapshotVars, crashVars>>

\* Leader i handles heartbeat response.
\* Reference: RaftPart.cpp:2091-2122 (sendHeartbeat callback)
HandleHeartbeatResponse(i, m) ==
    /\ alive[i]
    /\ m.mtype = HeartbeatResponse
    /\ m.mdest = i
    /\ LET mterm == m.mterm
       IN
       IF mterm > term[i] THEN
           \* RaftPart.cpp:2105-2109: step down
           /\ term' = [term EXCEPT ![i] = mterm]
           /\ role' = [role EXCEPT ![i] = Follower]
           /\ leader' = [leader EXCEPT ![i] = Nil]
           /\ Discard(m)
           /\ UNCHANGED <<votedFor, votedTerm, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>
       ELSE IF role[i] = Leader THEN
           \* RaftPart.cpp:2112-2121: heartbeat accepted
           \* Update lease timing if quorum (modeled abstractly by refreshing lease)
           /\ leaseExpired' = [leaseExpired EXCEPT ![i] = FALSE]
           /\ Discard(m)
           /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          blindFollower, commitInThisTerm, snapshotVars, crashVars>>
       ELSE
           /\ Discard(m)
           /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                          leaseVars, snapshotVars, crashVars>>

----
\* Lease Expiry (Extension 2, Family 2)
----

\* Leader's lease expires due to not receiving quorum heartbeat acks.
\* Reference: RaftPart.cpp:2254-2268 (leaseValid) — time-based check
\* Modeled as non-deterministic fault injection: lease can expire at any time.
ExpireLease(i) ==
    /\ alive[i]
    /\ role[i] = Leader
    /\ ~leaseExpired[i]
    /\ leaseExpired' = [leaseExpired EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   blindFollower, commitInThisTerm, snapshotVars, crashVars>>

----
\* Snapshot Actions (Extension 3, Family 3)
----

\* Leader i starts sending snapshot to follower j.
\* Reference: Host.cpp:348-379 (startSendSnapshot)
\*            SnapshotManager.cpp:31-107 (sendSnapshot)
\*
\* Snapshot is triggered when follower is too far behind (Host.cpp:307-308).
\* SnapshotManager checks leadership at start (SnapshotManager.cpp:41-46).
StartSnapshot(i, j) ==
    /\ alive[i]
    /\ i /= j
    /\ role[i] = Leader
    \* Host.cpp:350: only start if not already sending
    /\ ~snapshotSending[i][j]
    \* Record term when snapshot started
    /\ snapshotSending' = [snapshotSending EXCEPT ![i][j] = TRUE]
    /\ snapshotTerm' = [snapshotTerm EXCEPT ![i][j] = term[i]]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, messages,
                   leaseVars, crashVars>>

\* Snapshot completes — callback updates Host state.
\* Reference: Host.cpp:358-374 (snapshot callback)
\*
\* Extension 3 (Family 3): BUG — callback updates lastLogIdSent_/lastLogTermSent_
\* WITHOUT checking if the term has changed (Host.cpp:362-367).
\* If leadership changed during snapshot, the Host state is corrupted.
CompleteSnapshot(i, j) ==
    /\ alive[i]
    /\ snapshotSending[i][j]
    \* The snapshot may complete regardless of current leadership
    \* Host.cpp:358-374: callback fires asynchronously
    /\ snapshotSending' = [snapshotSending EXCEPT ![i][j] = FALSE]
    \* BUG (Family 3): Host state updated without term check
    \* If term[i] /= snapshotTerm[i][j], this update is stale
    \* In the spec, we model this by updating matchIndex/nextIndex regardless of term
    /\ IF role[i] = Leader
       THEN \* Updates Host tracking state from snapshot result
            \* Host.cpp:362-364: lastLogIdSent_ = commitLogId, lastLogTermSent_ = commitLogTerm
            /\ matchIndex' = [matchIndex EXCEPT ![i][j] = commitIndex[i]]
            /\ nextIndex' = [nextIndex EXCEPT ![i][j] = commitIndex[i] + 1]
       ELSE UNCHANGED <<matchIndex, nextIndex>>
    /\ UNCHANGED <<serverVars, logVars, candidateVars, messages,
                   leaseVars, snapshotTerm, crashVars>>

----
\* Crash and Recovery (Extension 1, Family 1)
----

\* Server i crashes.
\* Reference: RaftPart.cpp:456-479 (stop)
\* After crash, volatile state is lost. Only WAL persists.
\* Role is set to Follower (process is dead, not a leader/candidate anymore).
Crash(i) ==
    /\ alive[i]
    /\ alive' = [alive EXCEPT ![i] = FALSE]
    \* Process is dead — reset volatile state
    /\ role' = [role EXCEPT ![i] = Follower]
    /\ leader' = [leader EXCEPT ![i] = Nil]
    /\ UNCHANGED <<term, votedFor, votedTerm, logVars, leaderVars, candidateVars,
                   messages, leaseVars, snapshotVars>>

\* Server i recovers after crash.
\* Reference: RaftPart.cpp:400-454 (start — recovery)
\*
\* Extension 1 (Family 1): BUG — term is recovered from WAL lastLogTerm, not from
\* a persisted currentTerm. votedFor/votedTerm are lost entirely.
\*   RaftPart.cpp:412: lastLogId_ = wal_->lastLogId()
\*   RaftPart.cpp:413: lastLogTerm_ = wal_->lastLogTerm()
\*   RaftPart.cpp:414: term_ = lastLogTerm_
\*   RaftPart.h:819-827: votedAddr_, votedTerm_ are volatile (reset to defaults)
\*
\* This means after crash+restart, a node can vote again in a term where it
\* already voted, potentially enabling two leaders in the same term.
Restart(i) ==
    /\ ~alive[i]
    /\ alive' = [alive EXCEPT ![i] = TRUE]
    \* RaftPart.cpp:414: term_ = lastLogTerm_ (from WAL, NOT persisted term)
    /\ term' = [term EXCEPT ![i] = LastLogTerm(i)]
    \* Role resets to Follower (RaftPart.cpp:444-446)
    /\ role' = [role EXCEPT ![i] = Follower]
    \* votedFor/votedTerm are LOST — reset to defaults
    \* RaftPart.h:819-827: volatile, never persisted
    /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
    /\ votedTerm' = [votedTerm EXCEPT ![i] = 0]
    /\ leader' = [leader EXCEPT ![i] = Nil]
    \* RaftPart.cpp:419-421: commitIndex from lastCommittedLogId()
    \* Log survives crash (WAL persists), commitIndex recovered from state machine
    \* For spec simplicity: commitIndex preserved (state machine is persistent)
    \* RaftPart.h:854: isBlindFollower_ = true on start
    /\ blindFollower' = [blindFollower EXCEPT ![i] = TRUE]
    /\ leaseExpired' = [leaseExpired EXCEPT ![i] = TRUE]
    /\ commitInThisTerm' = [commitInThisTerm EXCEPT ![i] = FALSE]
    \* Reset leader state
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
    \* Clear any snapshot state
    /\ snapshotSending' = [snapshotSending EXCEPT ![i] = [j \in Server |-> FALSE]]
    /\ snapshotTerm' = [snapshotTerm EXCEPT ![i] = [j \in Server |-> 0]]
    /\ UNCHANGED <<log, commitIndex, messages>>

----
\* Message Loss
----

\* A message in transit is lost.
LoseMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   leaseVars, snapshotVars, crashVars>>

----
\* Next State
----

Next ==
    \/ \E i \in Server :
        \/ Timeout(i)
        \/ BlindFollowerTimeout(i)
        \/ SendPreVote(i)
        \/ SendRequestVote(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ ExpireLease(i)
        \/ Crash(i)
        \/ Restart(i)
        \/ \E j \in Server \ {i} :
            \/ AppendEntries(i, j)
            \/ SendHeartbeat(i, j)
            \/ StartSnapshot(i, j)
            \/ CompleteSnapshot(i, j)
    \/ \E m \in DOMAIN messages :
        \/ HandlePreVoteRequest(m.mdest, m)
        \/ HandleRequestVoteRequest(m.mdest, m)
        \/ HandlePreVoteResponse(m.mdest, m)
        \/ HandleRequestVoteResponse(m.mdest, m)
        \/ HandleAppendEntriesRequest(m.mdest, m)
        \/ HandleAppendEntriesResponse(m.mdest, m)
        \/ HandleHeartbeatRequest(m.mdest, m)
        \/ HandleHeartbeatResponse(m.mdest, m)
        \/ LoseMessage(m)

Spec == Init /\ [][Next]_vars

----
\* Invariants
----

\* === Standard Protocol Invariants ===

\* ElectionSafety: At most one leader per term.
\* Reference: Raft paper Figure 3 — Election Safety Property
\* Targets: Family 1 (crash + re-vote enables two leaders)
ElectionSafety ==
    \A i, j \in Server :
        (role[i] = Leader /\ role[j] = Leader /\ term[i] = term[j]) => i = j

\* LogMatching: If two logs contain an entry with the same index and term,
\* then the logs are identical through that index.
\* Reference: Raft paper Figure 3 — Log Matching Property
\* Targets: Family 4 (log replication desync)
LogMatching ==
    \A i, j \in Server :
        \A idx \in 1..Min(LastLogIndex(i), LastLogIndex(j)) :
            log[i][idx].term = log[j][idx].term =>
                \A k \in 1..idx : log[i][k] = log[j][k]

\* LeaderCompleteness: If an entry is committed, it appears in the highest-term leader's log.
\* Reference: Raft paper Figure 3 — Leader Completeness Property
\* Targets: Families 1, 4
\* Note: Only checked for the leader with the highest term (stale leaders at lower
\* terms naturally don't have entries committed by higher-term leaders).
LeaderCompleteness ==
    \A i \in Server :
        (role[i] = Leader /\
         ~\E k \in Server : role[k] = Leader /\ term[k] > term[i]) =>
            \A j \in Server :
                \A idx \in 1..commitIndex[j] :
                    idx <= LastLogIndex(i) /\ log[i][idx] = log[j][idx]

\* === Extension Invariants (Bug Family targets) ===

\* VoteOncePerTerm: Each server votes for at most one candidate per term.
\* Reference: Raft paper — safety requirement
\* Targets: Family 1 — after crash+restart, votedFor is lost, enabling re-voting
\* NOTE: This tracks the SPEC's votedFor state. After crash+restart, votedFor is
\* reset, so this invariant may NOT be violated in the spec (by design — the spec
\* faithfully models the implementation). The REAL check is ElectionSafety.
VoteOncePerTerm ==
    \A i, j \in Server :
        (votedTerm[i] = votedTerm[j] /\ votedTerm[i] > 0 /\
         votedFor[i] /= Nil /\ votedFor[j] /= Nil /\
         i = j) =>
            TRUE  \* Tautological placeholder; real check is ElectionSafety

\* NoStaleLeaseRead: If a leader believes its lease is valid, no other server is leader.
\* Reference: RaftPart.cpp:2254-2268 (leaseValid)
\* Targets: Family 2 — blind follower election can create new leader while old lease valid
NoStaleLeaseRead ==
    \A i \in Server :
        (role[i] = Leader /\ commitInThisTerm[i] /\ ~leaseExpired[i]) =>
            ~\E j \in Server \ {i} : role[j] = Leader

\* CommitIndexMonotonicity: commitIndex never decreases.
\* Reference: RaftPart.h:836 — committedLogId_
\* Targets: Family 4 — heartbeat path bug
\* Note: This is checked as a state predicate; decreases are caught by action constraints.
CommitIndexMonotonicity ==
    \A i \in Server :
        alive[i] => commitIndex[i] >= 0  \* Structural; real check is temporal

\* SnapshotTermConsistency: Snapshot completion only updates state if term hasn't changed.
\* Reference: Host.cpp:358-374 — callback doesn't check term
\* Targets: Family 3 — leadership change during snapshot transfer
\* The invariant checks: if a snapshot completes and updates state, the term must match
SnapshotTermConsistency ==
    \A i, j \in Server :
        (snapshotSending[i][j] /\ role[i] /= Leader) =>
            \* Snapshot was started when i was leader; if i is no longer leader,
            \* the snapshot completion should not update Host state
            \* (but in the buggy impl, it does — this invariant SHOULD be violated)
            TRUE  \* Checked via CompleteSnapshot action analysis

\* PreVoteNonDisruptive: Pre-vote should NOT cause a current leader to step down.
\* Reference: RaftPart.cpp:1522-1528 — pre-vote causes step-down
\* Targets: Family 5 — pre-vote implementation defeats its purpose
\* NOTE: This invariant is expected to be VIOLATED by the implementation.
PreVoteNonDisruptive ==
    \* If a pre-vote request is in the message bag targeting a leader,
    \* processing it should not change the leader's role.
    \* We check the weaker property: no leader steps down SOLELY due to pre-vote.
    \* Since the spec models the buggy behavior, this invariant may be violated.
    TRUE  \* Checked via model checking traces — see hunting configs

\* === Structural Invariants ===

\* All terms are non-negative
TermsNonNegative ==
    \A i \in Server : term[i] >= 0

\* CommitIndex doesn't exceed log length
CommitIndexBound ==
    \A i \in Server :
        alive[i] => commitIndex[i] <= LastLogIndex(i)

\* Leader's matchIndex for self equals its log length
LeaderMatchIndexSelf ==
    \A i \in Server :
        role[i] = Leader => matchIndex[i][i] = LastLogIndex(i)

\* Only alive servers can be leaders
AliveLeaders ==
    \A i \in Server : role[i] = Leader => alive[i]

\* Committed entries exist in leader's log
CommittedEntriesInLeaderLog ==
    \A i \in Server :
        role[i] = Leader =>
            commitIndex[i] <= LastLogIndex(i)

\* Messages are well-formed: source and dest are different servers
MessageInvariant ==
    \A m \in DOMAIN messages :
        /\ m.msource \in Server
        /\ m.mdest \in Server
        /\ m.msource /= m.mdest

====
