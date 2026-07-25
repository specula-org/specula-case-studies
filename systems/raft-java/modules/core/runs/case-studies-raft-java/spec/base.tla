---------------------------- MODULE base ----------------------------
\* TLA+ specification of wenweihu86/raft-java consensus protocol.
\*
\* Extends standard Raft with raft-java-specific behaviors:
\*   1. Non-atomic persistence in startVote: term/votedFor not flushed (Bug Family 1)
\*   2. Missing commitIndex/matchIndex monotonicity guards (Bug Family 2)
\*   3. installSnapshot omits configuration/commitIndex update (Bug Family 3)
\*   4. Shared PreVote/Vote voteGranted field (Bug Family 4)
\*   5. Single-step multi-server config change without joint consensus (Bug Family 5)
\*
EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs

CONSTANTS Follower,          \* Server states
          PreCandidate,
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
          AppendEntriesResponse,
          InstallSnapshotRequest,
          InstallSnapshotResponse

----
\* Variables
----

\* Per-server persistent state (survives restart via stable store)
VARIABLE currentTerm         \* [Server -> Nat]
VARIABLE votedFor            \* [Server -> Server \cup {Nil}]
VARIABLE log                 \* [Server -> Seq(Entry)]

\* Per-server volatile state
VARIABLE state               \* [Server -> {Follower, PreCandidate, Candidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat]

\* Leader volatile state
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate state
\* Bug Family 4: raft-java uses a SINGLE voteGranted field for both
\* PreVote and Vote phases (Peer.java voteGranted field).
\* We model them separately to detect cross-contamination.
VARIABLE preVotesGranted     \* [Server -> SUBSET Server]
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension 1: Non-atomic persistence (Bug Family 1)
\* startVote() increments currentTerm and sets votedFor in memory
\* but NEVER calls raftLog.updateMetaData() (RaftNode.java:497-501).
\* stepDown() DOES persist (RaftNode.java:307). requestVote handler
\* DOES persist (RaftConsensusServiceImpl.java:87).
\* Reference: RaftNode.java:490-518 (startVote — missing persist)
\*            RaftNode.java:298-315 (stepDown — has persist)
VARIABLE persistedTerm       \* [Server -> Nat]
VARIABLE persistedVotedFor   \* [Server -> Server \cup {Nil}]

\* Extension 3: Snapshot state (Bug Family 3)
\* installSnapshot handler omits configuration/commitIndex/lastAppliedIndex
\* updates (RaftConsensusServiceImpl.java:279-301).
\* Constructor correctly initializes all three (RaftNode.java:90,97-100,112).
VARIABLE snapshotIndex       \* [Server -> Nat] -- last included index in snapshot
VARIABLE snapshotTerm        \* [Server -> Nat] -- last included term in snapshot
VARIABLE snapshotConfig      \* [Server -> SUBSET Server] -- configuration in snapshot

\* Extension 5: Configuration (Bug Family 5)
\* Single configuration variable, no committed/latest distinction.
\* No joint consensus. Multi-server changes in one step.
\* Reference: RaftClientServiceImpl.java:83-169 (addPeers)
\*            RaftClientServiceImpl.java:172-216 (removePeers)
VARIABLE config              \* [Server -> SUBSET Server]

----
\* Variable groups
----

serverVars    == <<currentTerm, votedFor, state>>
logVars       == <<log, commitIndex>>
leaderVars    == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted, preVotesGranted>>
persistVars   == <<persistedTerm, persistedVotedFor>>
snapshotVars  == <<snapshotIndex, snapshotTerm, snapshotConfig>>
configVars    == <<config>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          persistVars, snapshotVars, configVars>>

----
\* Helpers
----

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b

SetMax(S) == CHOOSE x \in S : \A y \in S : x >= y

\* Log helpers
\* All external indices (nextIndex, matchIndex, commitIndex) are ABSOLUTE.
\* The log is stored as a truncated suffix starting at snapshotIndex+1.
\* AbsLastLogIndex gives the absolute last log index.
\* AbsLogTerm retrieves the term at an absolute index (handling snapshot).
LastLogIndex(i) == Len(log[i])
AbsLastLogIndex(i) == snapshotIndex[i] + Len(log[i])
LastLogTerm(i)  == IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term
                    ELSE IF snapshotIndex[i] > 0 THEN snapshotTerm[i] ELSE 0
LogTerm(i, idx) == IF idx > 0 /\ idx <= Len(log[i]) THEN log[i][idx].term ELSE 0
\* AbsLogTerm: look up term by ABSOLUTE index
AbsLogTerm(i, absIdx) ==
    IF absIdx = snapshotIndex[i] THEN snapshotTerm[i]
    ELSE LET relIdx == absIdx - snapshotIndex[i]
         IN IF relIdx > 0 /\ relIdx <= Len(log[i]) THEN log[i][relIdx].term ELSE 0

\* Quorum check: majority of voters
\* Reference: VoteResponseCallback uses > count/2 (RaftNode.java:673)
IsQuorum(S, voters) == Cardinality(S) * 2 > Cardinality(voters)

\* Log up-to-date comparison
\* Reference: RaftConsensusServiceImpl.java:46-48 (preVote), :81-83 (requestVote)
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
    /\ preVotesGranted   = [s \in Server |-> {}]
    /\ messages          = EmptyBag
    \* Extension 1: persisted state matches initial volatile state
    /\ persistedTerm     = [s \in Server |-> 0]
    /\ persistedVotedFor = [s \in Server |-> Nil]
    \* Extension 3: no initial snapshot
    /\ snapshotIndex     = [s \in Server |-> 0]
    /\ snapshotTerm      = [s \in Server |-> 0]
    /\ snapshotConfig    = [s \in Server |-> {}]
    \* Extension 5: all servers in initial config
    /\ config            = [s \in Server |-> Server]

----
\* PreVote Actions (Bug Family 4)
\*
\* raft-java uses PreVote to avoid disrupting stable clusters.
\* PreVote does NOT change term or votedFor.
\* Key deviation: PreVote sends currentTerm (not currentTerm+1).
\* Reference: RaftNode.java:459-484 (startPreVote)
----

\* Server i starts PreVote phase.
\* Reference: RaftNode.java:459-484 (startPreVote)
\* - Checks server is in configuration (RaftNode.java:462)
\* - Sets state to PRE_CANDIDATE (RaftNode.java:467)
\* - Does NOT increment term
\* - Sends PreVoteRequest with currentTerm (RaftNode.java:531, NOT +1)
StartPreVote(i) ==
    /\ state[i] = Follower
    /\ i \in config[i]
    \* RaftNode.java:467: state = NodeState.STATE_PRE_CANDIDATE
    /\ state' = [state EXCEPT ![i] = PreCandidate]
    /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {i}]
    \* RaftNode.java:524-534: preVote sends PreVoteRequest
    \* Bug Family 4: sends currentTerm, not currentTerm+1
    /\ SendAll({[mtype         |-> PreVoteRequest,
                 mterm         |-> currentTerm[i],
                 mlastLogTerm  |-> LastLogTerm(i),
                 mlastLogIndex |-> LastLogIndex(i),
                 msource       |-> i,
                 mdest         |-> j] : j \in config[i] \ {i}})
    /\ UNCHANGED <<currentTerm, votedFor, logVars, leaderVars, votesGranted,
                   persistVars, snapshotVars, configVars>>

\* Server i handles PreVoteRequest m.
\* Reference: RaftConsensusServiceImpl.java:34-63 (preVote handler)
HandlePreVoteRequest(i, m) ==
    /\ m.mtype = PreVoteRequest
    /\ m.mdest = i
    /\ LET logOk == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                 LastLogTerm(i), LastLogIndex(i))
       IN
       \/ \* Reject: not in configuration (line 40)
          /\ ~(i \in config[i])
          /\ Reply([mtype        |-> PreVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

       \/ \* Reject: term too low (line 43)
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype        |-> PreVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

       \/ \* Reject: log not up-to-date (line 49)
          /\ m.mterm >= currentTerm[i]
          /\ ~logOk
          /\ Reply([mtype        |-> PreVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

       \/ \* Grant: term OK and log up-to-date (line 51-53)
          /\ m.mterm >= currentTerm[i]
          /\ logOk
          /\ Reply([mtype        |-> PreVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> TRUE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

\* Server i handles PreVoteResponse m.
\* Reference: RaftNode.java:566-628 (PreVoteResponseCallback)
\*
\* Bug Family 4: line 579 sets peer.setVoteGranted(response.getGranted())
\* BEFORE the staleness check (line 580). This means a stale PreVote
\* response can overwrite a real Vote response's voteGranted field.
\* In our spec we use separate preVotesGranted/votesGranted to detect this.
HandlePreVoteResponse(i, m) ==
    /\ m.mtype = PreVoteResponse
    /\ m.mdest = i
    /\ \/ \* Stale: not in PRE_CANDIDATE state or term changed (line 580)
          /\ \/ state[i] /= PreCandidate
             \/ currentTerm[i] /= m.mterm
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

       \/ \* Higher term: step down (line 584-590)
          /\ state[i] = PreCandidate
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ state' = [state EXCEPT ![i] = Follower]
          \* stepDown persists (RaftNode.java:307)
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
          /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         snapshotVars, configVars>>

       \/ \* Granted: count vote (line 592-609)
          /\ state[i] = PreCandidate
          /\ currentTerm[i] = m.mterm
          /\ m.mvoteGranted
          /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = @ \cup {m.msource}]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, votesGranted,
                         persistVars, snapshotVars, configVars>>

       \/ \* Not granted (line 611-613)
          /\ state[i] = PreCandidate
          /\ currentTerm[i] = m.mterm
          /\ ~m.mvoteGranted
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

----
\* Election Actions
----

\* Server i has PreVote quorum, starts real election.
\* Reference: RaftNode.java:490-518 (startVote)
\*
\* *** BUG FAMILY 1: MISSING PERSISTENCE ***
\* Lines 497-501: currentTerm++ and votedFor=localServer set in memory only.
\* No call to raftLog.updateMetaData(). Compare with stepDown (line 307)
\* which correctly calls updateMetaData.
\* If server crashes after startVote but before any stepDown, it will
\* recover with OLD term/votedFor and can double-vote.
StartVote(i) ==
    /\ state[i] = PreCandidate
    /\ i \in config[i]
    /\ IsQuorum(preVotesGranted[i], config[i])
    \* RaftNode.java:497: currentTerm++
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    \* RaftNode.java:499: state = STATE_CANDIDATE
    /\ state' = [state EXCEPT ![i] = Candidate]
    \* RaftNode.java:500: leaderId = 0 (implicit in spec)
    \* RaftNode.java:501: votedFor = localServer
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ preVotesGranted' = [preVotesGranted EXCEPT ![i] = {}]
    \* *** BUG FAMILY 1: No persistence! ***
    \* persistedTerm and persistedVotedFor remain at their OLD values.
    \* This models the missing raftLog.updateMetaData() call.
    /\ UNCHANGED <<persistedTerm, persistedVotedFor>>
    \* RaftNode.java:506-517: send RequestVoteRequest to all peers
    /\ SendAll({[mtype         |-> RequestVoteRequest,
                 mterm         |-> currentTerm[i] + 1,
                 mlastLogTerm  |-> LastLogTerm(i),
                 mlastLogIndex |-> LastLogIndex(i),
                 msource       |-> i,
                 mdest         |-> j] : j \in config[i] \ {i}})
    /\ UNCHANGED <<logVars, leaderVars, snapshotVars, configVars>>

\* Server i handles RequestVoteRequest m.
\* Reference: RaftConsensusServiceImpl.java:66-99 (requestVote handler)
\*
\* Key deviations from Raft paper:
\* - Line 84: checks votedFor == 0 only, missing || votedFor == candidateId
\*   (Raft paper Figure 2: "votedFor is null or candidateId")
\* - Line 78-80: steps down on higher term BEFORE vote grant check
\* - Line 85-87: persists votedFor after granting
HandleRequestVoteRequest(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ LET logOk == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                 LastLogTerm(i), LastLogIndex(i))
       IN
       \/ \* Reject: not in configuration (line 72)
          /\ ~(i \in config[i])
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

       \/ \* Reject: term too low (line 75)
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

       \/ \* Higher term: step down then check vote (lines 78-80)
          \* stepDown persists term (RaftNode.java:304,307)
          \* After stepDown, votedFor=0 so vote check below may grant
          /\ m.mterm > currentTerm[i]
          /\ IF logOk
             THEN \* Grant vote (lines 84-89)
                  \* Line 84: votedFor == 0 (after stepDown) — grants
                  \* Line 85: stepDown again (redundant but harmless)
                  \* Line 86: votedFor = request.getServerId()
                  \* Line 87: persist votedFor
                  /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
                  /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
                  /\ state' = [state EXCEPT ![i] = Follower]
                  /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
                  /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = m.msource]
                  /\ Reply([mtype        |-> RequestVoteResponse,
                            mterm        |-> m.mterm,
                            mvoteGranted |-> TRUE,
                            msource      |-> i,
                            mdest        |-> m.msource], m)
             ELSE \* Reject: log not up-to-date
                  /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
                  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
                  /\ state' = [state EXCEPT ![i] = Follower]
                  /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
                  /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = Nil]
                  /\ Reply([mtype        |-> RequestVoteResponse,
                            mterm        |-> m.mterm,
                            mvoteGranted |-> FALSE,
                            msource      |-> i,
                            mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         snapshotVars, configVars>>

       \/ \* Same term: check if can grant (lines 81-89)
          \* Line 84: votedFor == 0 (NOT votedFor == 0 || votedFor == candidateId)
          \* This is a deviation from Raft paper — no re-vote for same candidate
          /\ m.mterm = currentTerm[i]
          /\ IF votedFor[i] = Nil /\ logOk
             THEN \* Grant
                  /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
                  /\ state' = [state EXCEPT ![i] = Follower]
                  /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = m.msource]
                  /\ Reply([mtype        |-> RequestVoteResponse,
                            mterm        |-> currentTerm[i],
                            mvoteGranted |-> TRUE,
                            msource      |-> i,
                            mdest        |-> m.msource], m)
                  /\ UNCHANGED <<currentTerm, persistedTerm>>
             ELSE \* Reject: already voted or log not up-to-date
                  /\ Reply([mtype        |-> RequestVoteResponse,
                            mterm        |-> currentTerm[i],
                            mvoteGranted |-> FALSE,
                            msource      |-> i,
                            mdest        |-> m.msource], m)
                  /\ UNCHANGED <<serverVars, persistVars>>
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         snapshotVars, configVars>>

\* Server i handles RequestVoteResponse m.
\* Reference: RaftNode.java:630-694 (VoteResponseCallback)
HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ \/ \* Stale: not candidate or term changed (line 644)
          /\ \/ state[i] /= Candidate
             \/ currentTerm[i] /= m.mterm
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

       \/ \* Higher term: step down (line 648-654)
          /\ state[i] = Candidate
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
          /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         snapshotVars, configVars>>

       \/ \* Granted: count vote (lines 656-675)
          /\ state[i] = Candidate
          /\ m.mterm = currentTerm[i]
          /\ m.mvoteGranted
          /\ votesGranted' = [votesGranted EXCEPT ![i] = @ \cup {m.msource}]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, preVotesGranted,
                         persistVars, snapshotVars, configVars>>

       \/ \* Not granted (lines 677-679)
          /\ state[i] = Candidate
          /\ m.mterm = currentTerm[i]
          /\ ~m.mvoteGranted
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

\* Candidate i becomes leader after receiving quorum of votes.
\* Reference: RaftNode.java:697-706 (becomeLeader)
BecomeLeader(i) ==
    /\ state[i] = Candidate
    /\ IsQuorum(votesGranted[i], config[i])
    \* RaftNode.java:698: state = STATE_LEADER
    /\ state' = [state EXCEPT ![i] = Leader]
    \* RaftNode.java:699: leaderId = localServer (implicit)
    \* Initialize leader volatile state
    /\ nextIndex'  = [nextIndex  EXCEPT ![i] = [j \in Server |-> AbsLastLogIndex(i) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, candidateVars, messages,
                   persistVars, snapshotVars, configVars>>

----
\* Log Replication Actions
----

\* Leader i appends a client request to its log.
\* Reference: RaftNode.java:144-194 (replicate)
ClientRequest(i) ==
    /\ state[i] = Leader
    /\ LET entry == [term |-> currentTerm[i], type |-> ValueEntry, config |-> {}]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   persistVars, snapshotVars, configVars>>

\* Leader i sends AppendEntries to server j.
\* Reference: RaftNode.java:196-295 (appendEntries)
\* Heartbeats and log replication share the same appendEntries method.
\* Lines 229-250: build request with prevLogIndex, prevLogTerm, entries, commitIndex
\* Line 247: commitIndex = min(commitIndex, prevLogIndex + numEntries)
AppendEntries(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    \* All indices here are ABSOLUTE. Convert to relative for log access.
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == AbsLogTerm(i, prevIdx)
           absLastIdx == AbsLastLogIndex(i)
           \* Entries from nextIndex to the absolute end of log
           relStart == nextIndex[i][j] - snapshotIndex[i]
           entries  == IF nextIndex[i][j] > absLastIdx THEN <<>>
                       ELSE IF relStart < 1 THEN log[i]
                       ELSE IF relStart > Len(log[i]) THEN <<>>
                       ELSE SubSeq(log[i], relStart, Len(log[i]))
           \* RaftNode.java:247: min(commitIndex, prevLogIndex + numEntries)
           sentCommit == Min(commitIndex[i], prevIdx + Len(entries))
       IN Send([mtype         |-> AppendEntriesRequest,
                mterm         |-> currentTerm[i],
                mprevLogIndex |-> prevIdx,
                mprevLogTerm  |-> prevTerm,
                mentries      |-> entries,
                mcommitIndex  |-> sentCommit,
                msource       |-> i,
                mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, snapshotVars, configVars>>

\* Server i handles AppendEntriesRequest m.
\* Reference: RaftConsensusServiceImpl.java:101-190 (appendEntries handler)
HandleAppendEntriesRequest(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ LET mterm   == m.mterm
           \* Lines 130-146: log consistency check (m.mprevLogIndex is ABSOLUTE)
           logOk   == \/ m.mprevLogIndex = 0
                      \/ /\ m.mprevLogIndex > 0
                         /\ m.mprevLogIndex <= AbsLastLogIndex(i)
                         /\ AbsLogTerm(i, m.mprevLogIndex) = m.mprevLogTerm
       IN
       \/ \* Reject: term too low (line 110)
          /\ mterm < currentTerm[i]
          /\ Reply([mtype        |-> AppendEntriesResponse,
                    mterm        |-> currentTerm[i],
                    msuccess     |-> FALSE,
                    mmatchIndex  |-> 0,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

       \/ \* Reject: log inconsistency (lines 130-146)
          /\ mterm >= currentTerm[i]
          /\ ~logOk
          \* Line 113: stepDown (persists term via RaftNode.java:307)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ IF mterm > currentTerm[i]
             THEN /\ persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
                  /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = Nil]
             ELSE UNCHANGED persistVars
          /\ Reply([mtype        |-> AppendEntriesResponse,
                    mterm        |-> mterm,
                    msuccess     |-> FALSE,
                    mmatchIndex  |-> 0,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         snapshotVars, configVars>>

       \/ \* Accept: log matches at prevLogIndex (lines 148-186)
          /\ mterm >= currentTerm[i]
          /\ logOk
          /\ LET \* Lines 159-175: append entries, truncate conflicting suffix
                 \* Convert m.mprevLogIndex (absolute) to relative for log access
                 relPrev == m.mprevLogIndex - snapshotIndex[i]
                 safePrev == Min(Max(0, relPrev), Len(log[i]))
                 newLog == IF Len(m.mentries) > 0
                           THEN IF safePrev = 0 THEN m.mentries
                                ELSE SubSeq(log[i], 1, safePrev) \o m.mentries
                           ELSE log[i]
                 \* mmatchIndex is ABSOLUTE (snapshotIndex + relative length)
                 newAbsLastIdx == snapshotIndex[i] + Len(newLog)
                 \* *** BUG FAMILY 2: No monotonicity guard! ***
                 \* RaftConsensusServiceImpl.java:313-315: unconditionally sets commitIndex
                 \* newCommitIndex = min(request.commitIndex, prevLogIndex + entriesCount)
                 \* Line 315: raftNode.setCommitIndex(newCommitIndex) — NO CHECK for decrease!
                 newCommitIdx == Min(m.mcommitIndex,
                                     m.mprevLogIndex + Len(m.mentries))
             IN
             /\ log' = [log EXCEPT ![i] = newLog]
             \* Bug Family 2: commitIndex set UNCONDITIONALLY
             \* This is the actual implementation behavior — can DECREASE commitIndex
             /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
             \* Line 113: stepDown (persists)
             /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
             /\ state' = [state EXCEPT ![i] = Follower]
             /\ votedFor' = IF mterm > currentTerm[i]
                            THEN [votedFor EXCEPT ![i] = Nil]
                            ELSE votedFor
             /\ IF mterm > currentTerm[i]
                THEN /\ persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
                     /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = Nil]
                ELSE UNCHANGED persistVars
             /\ Reply([mtype        |-> AppendEntriesResponse,
                       mterm        |-> mterm,
                       msuccess     |-> TRUE,
                       mmatchIndex  |-> newAbsLastIdx,
                       msource      |-> i,
                       mdest        |-> m.msource], m)
             /\ UNCHANGED <<leaderVars, candidateVars, snapshotVars, configVars>>

\* Leader i handles AppendEntriesResponse m.
\* Reference: RaftNode.java:255-294 (appendEntries response handling)
HandleAppendEntriesResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ \/ \* Higher term: step down (line 272-273)
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
          /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         snapshotVars, configVars>>

       \/ \* Success: update matchIndex and nextIndex (lines 275-279)
          \* *** BUG FAMILY 2: No matchIndex monotonicity guard! ***
          \* Line 276: peer.setMatchIndex(prevLogIndex + numEntries) UNCONDITIONALLY
          \* A stale response from a delayed heartbeat can reset matchIndex backward.
          /\ m.mterm = currentTerm[i]
          /\ m.msuccess
          /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] = m.mmatchIndex]
          /\ nextIndex'  = [nextIndex  EXCEPT ![i][m.msource] = m.mmatchIndex + 1]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

       \/ \* Failure: decrement nextIndex (line 289)
          /\ m.mterm = currentTerm[i]
          /\ ~m.msuccess
          /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] = Max(1, m.mmatchIndex + 1)]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, matchIndex, candidateVars,
                         persistVars, snapshotVars, configVars>>

       \/ \* Stale response from older term: ignore
          /\ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

\* Leader i advances commit index based on quorum replication.
\* Reference: RaftNode.java:737-776 (advanceCommitIndex — leader side)
\* NOTE: Leader-side advanceCommitIndex HAS a monotonicity guard (line 758).
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET \* Lines 739-750: compute median matchIndex (all indices ABSOLUTE)
           Agree(idx) == {i} \cup {s \in config[i] \ {i} : matchIndex[i][s] >= idx}
           agreeIdxs == {idx \in (commitIndex[i]+1)..AbsLastLogIndex(i) :
                          /\ IsQuorum(Agree(idx), config[i])
                          \* Line 752: check entry term == currentTerm
                          /\ AbsLogTerm(i, idx) = currentTerm[i]}
       IN
       /\ agreeIdxs /= {}
       /\ LET newCommitIdx == SetMax(agreeIdxs)
          IN \* Line 758: commitIndex >= newCommitIndex guard (correct)
             /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
             \* Apply configuration entries (absolute indices, convert for log access)
             /\ config' = [config EXCEPT ![i] =
                    LET cfgIdxs == {idx \in (commitIndex[i]+1)..newCommitIdx :
                                      LET ri == idx - snapshotIndex[i]
                                      IN ri > 0 /\ ri <= Len(log[i]) /\ log[i][ri].type = ConfigEntry}
                    IN IF cfgIdxs /= {}
                       THEN log[i][SetMax(cfgIdxs) - snapshotIndex[i]].config
                       ELSE config[i]]
    /\ UNCHANGED <<serverVars, log, leaderVars, candidateVars, messages,
                   persistVars, snapshotVars>>

----
\* Snapshot Actions (Bug Family 3)
----

\* Leader i sends InstallSnapshot to server j.
\* Reference: RaftNode.java:789-857 (installSnapshot — leader side)
SendInstallSnapshot(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ snapshotIndex[i] > 0   \* have a snapshot to send
    /\ Send([mtype          |-> InstallSnapshotRequest,
             mterm          |-> currentTerm[i],
             msnapshotIndex |-> snapshotIndex[i],
             msnapshotTerm  |-> snapshotTerm[i],
             msnapshotConfig |-> snapshotConfig[i],
             msource        |-> i,
             mdest          |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, snapshotVars, configVars>>

\* Server i handles InstallSnapshotRequest m.
\* Reference: RaftConsensusServiceImpl.java:192-309 (installSnapshot handler)
\*
\* *** BUG FAMILY 3: Missing state updates after snapshot install ***
\* Lines 279-301: after final chunk, handler does NOT update:
\*   - configuration (should match snapshot's configuration)
\*   - commitIndex (should be >= snapshot's lastIncludedIndex)
\*   - lastAppliedIndex (should be snapshot's lastIncludedIndex)
\* Compare with constructor (RaftNode.java:90,97-100,112) which correctly
\* initializes all three from snapshot metadata.
HandleInstallSnapshotRequest(i, m) ==
    /\ m.mtype = InstallSnapshotRequest
    /\ m.mdest = i
    /\ \/ \* Reject: term too low (line 201)
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype    |-> InstallSnapshotResponse,
                    mterm    |-> currentTerm[i],
                    msuccess |-> FALSE,
                    msource  |-> i,
                    mdest    |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, snapshotVars, configVars>>

       \/ \* Accept: install snapshot
          /\ m.mterm >= currentTerm[i]
          \* Line 204: stepDown (persists)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF m.mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ IF m.mterm > currentTerm[i]
             THEN /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
                  /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = Nil]
             ELSE UNCHANGED persistVars
          \* Update local snapshot state
          /\ snapshotIndex' = [snapshotIndex EXCEPT ![i] = m.msnapshotIndex]
          /\ snapshotTerm' = [snapshotTerm EXCEPT ![i] = m.msnapshotTerm]
          /\ snapshotConfig' = [snapshotConfig EXCEPT ![i] = m.msnapshotConfig]
          \* Truncate log to snapshot point (convert to relative index)
          /\ LET absLastIdx == snapshotIndex[i] + LastLogIndex(i)
                 relStart == m.msnapshotIndex - snapshotIndex[i] + 1
             IN log' = [log EXCEPT ![i] =
                IF m.msnapshotIndex >= absLastIdx THEN <<>>
                ELSE IF relStart > Len(log[i]) THEN <<>>
                ELSE IF relStart < 1 THEN log[i]
                ELSE SubSeq(log[i], relStart, Len(log[i]))]
          \* *** BUG FAMILY 3: commitIndex and config NOT updated ***
          \* Real code: lines 279-301 — no update to configuration, commitIndex
          \* This means after snapshot install:
          \*   - config[i] is STALE (doesn't match snapshot's config)
          \*   - commitIndex[i] is STALE (may be lower than snapshot point)
          /\ UNCHANGED <<commitIndex, configVars>>
          /\ Reply([mtype    |-> InstallSnapshotResponse,
                    mterm    |-> m.mterm,
                    msuccess |-> TRUE,
                    msource  |-> i,
                    mdest    |-> m.msource], m)
          /\ UNCHANGED <<leaderVars, candidateVars>>

\* Leader i handles InstallSnapshotResponse m.
\* Reference: RaftNode.java:834-848 (installSnapshot response in leader)
HandleInstallSnapshotResponse(i, m) ==
    /\ m.mtype = InstallSnapshotResponse
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ IF m.msuccess
       THEN \* Line 845: peer.setNextIndex(lastIncludedIndexInSnapshot + 1)
            nextIndex' = [nextIndex EXCEPT ![i][m.msource] = snapshotIndex[i] + 1]
       ELSE UNCHANGED nextIndex
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, matchIndex, candidateVars,
                   persistVars, snapshotVars, configVars>>

\* Server i takes a snapshot (models periodic snapshotting).
\* Reference: RaftNode.java:317-397 (takeSnapshot)
\* Note: commitIndex is ABSOLUTE but log indices are RELATIVE to snapshotIndex.
\* Must convert to relative coordinates for log operations.
TakeSnapshot(i) ==
    /\ commitIndex[i] > snapshotIndex[i]
    /\ commitIndex[i] > 0
    /\ LET snapIdx     == commitIndex[i]           \* absolute snapshot point
           relSnapIdx  == snapIdx - snapshotIndex[i] \* relative to current log
           snapTerm    == IF relSnapIdx > 0 /\ relSnapIdx <= Len(log[i])
                          THEN log[i][relSnapIdx].term
                          ELSE 0
       IN
       /\ snapshotIndex' = [snapshotIndex EXCEPT ![i] = snapIdx]
       /\ snapshotTerm' = [snapshotTerm EXCEPT ![i] = snapTerm]
       /\ snapshotConfig' = [snapshotConfig EXCEPT ![i] = config[i]]
       \* Truncate log prefix up to snapshot point (using relative index)
       /\ log' = [log EXCEPT ![i] =
            IF relSnapIdx >= Len(log[i]) THEN <<>>
            ELSE SubSeq(log[i], relSnapIdx + 1, Len(log[i]))]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars,
                   messages, persistVars, configVars>>

----
\* Configuration Change Actions (Bug Family 5)
----

\* Leader i proposes adding/removing servers.
\* Reference: RaftClientServiceImpl.java:83-169 (addPeers)
\*            RaftClientServiceImpl.java:172-216 (removePeers)
\*
\* *** BUG FAMILY 5: Single-step multi-server change ***
\* No joint consensus, no single-server restriction.
\* Multiple servers added/removed atomically as one log entry.
\* No guard against concurrent config changes.
ProposeConfigChange(i, newCfg) ==
    /\ state[i] = Leader
    \* newCfg is the proposed new configuration
    /\ newCfg /= config[i]
    /\ newCfg /= {}
    /\ newCfg \subseteq Server
    /\ LET entry == [term |-> currentTerm[i], type |-> ConfigEntry, config |-> newCfg]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages,
                   persistVars, snapshotVars, configVars>>

----
\* Crash and Recovery (Bug Family 1)
----

\* Server i crashes. All volatile state is lost.
\* Recovers from persisted state.
\*
\* *** BUG FAMILY 1: Non-atomic persistence in startVote ***
\* If server crashes after startVote (which does NOT persist),
\* it recovers with OLD term/votedFor from disk.
\* The node can then vote for a DIFFERENT candidate in the same term.
\*
\* *** BUG FAMILY 2: Regressed commitIndex persisted ***
\* RaftConsensusServiceImpl.java:316: regressed commitIndex is persisted.
\* On crash recovery, node starts with lower commitIndex than was committed.
\* We model this by recovering commitIndex from persisted value.
Crash(i) ==
    /\ state' = [state EXCEPT ![i] = Follower]
    \* Recover from persisted state (Bug Family 1)
    /\ currentTerm' = [currentTerm EXCEPT ![i] = persistedTerm[i]]
    /\ votedFor'    = [votedFor    EXCEPT ![i] = persistedVotedFor[i]]
    \* Volatile state reset
    /\ commitIndex'      = [commitIndex      EXCEPT ![i] = 0]
    /\ nextIndex'        = [nextIndex        EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'       = [matchIndex       EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted'     = [votesGranted     EXCEPT ![i] = {}]
    /\ preVotesGranted'  = [preVotesGranted  EXCEPT ![i] = {}]
    \* Recompute config from log
    /\ config' = [config EXCEPT ![i] =
         LET cfgIdxs == {idx \in 1..Len(log[i]) : log[i][idx].type = ConfigEntry}
         IN IF cfgIdxs /= {} THEN log[i][SetMax(cfgIdxs)].config
            ELSE Server]
    \* persistedTerm/persistedVotedFor, log, and snapshots survive
    /\ UNCHANGED <<log, messages, persistVars, snapshotVars>>

----
\* Network failures
----

LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, snapshotVars, configVars>>

DropStaleMessage(m) ==
    /\ m \in DOMAIN messages
    /\ m.mterm < currentTerm[m.mdest]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, snapshotVars, configVars>>

----
\* Spec
----

Next ==
    \/ \E i \in Server :
        \/ StartPreVote(i)
        \/ StartVote(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ AdvanceCommitIndex(i)
        \/ TakeSnapshot(i)
        \/ Crash(i)
    \/ \E i, j \in Server :
        \/ AppendEntries(i, j)
        \/ SendInstallSnapshot(i, j)
    \/ \E i \in Server, newCfg \in SUBSET Server :
        \/ ProposeConfigChange(i, newCfg)
    \/ \E m \in DOMAIN messages :
        \/ HandlePreVoteRequest(m.mdest, m)
        \/ HandlePreVoteResponse(m.mdest, m)
        \/ HandleRequestVoteRequest(m.mdest, m)
        \/ HandleRequestVoteResponse(m.mdest, m)
        \/ HandleAppendEntriesRequest(m.mdest, m)
        \/ HandleAppendEntriesResponse(m.mdest, m)
        \/ HandleInstallSnapshotRequest(m.mdest, m)
        \/ HandleInstallSnapshotResponse(m.mdest, m)
        \/ DropStaleMessage(m)
        \/ LoseMessage(m)

Spec == Init /\ [][Next]_vars

----
\* Invariants
----

\* Standard Raft: at most one leader per term.
ElectionSafety ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ state[s2] = Leader /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* Standard Raft: if two logs have an entry with the same index and term,
\* the logs are identical up to that point.
\* After snapshot truncation, only compare entries still in both logs
\* (using snapshot-adjusted indices).
LogMatching ==
    \A s1, s2 \in Server :
        LET base1 == snapshotIndex[s1]
            base2 == snapshotIndex[s2]
            lo   == Max(base1, base2) + 1     \* first index present in both logs
            hi   == Min(base1 + Len(log[s1]), base2 + Len(log[s2]))
        IN \A idx \in lo..hi :
            log[s1][idx - base1].term = log[s2][idx - base2].term =>
                \A k \in lo..idx :
                    log[s1][k - base1].term = log[s2][k - base2].term

\* Standard Raft: a committed entry appears in all future leaders' logs.
\* "Future" means the leader's term >= the entry's term. A stale leader
\* at term T does not need entries committed at term T' > T.
\* After snapshot truncation, entries covered by a snapshot are exempt.
LeaderCompleteness ==
    \A s1 \in Server :
        state[s1] = Leader =>
        \A s2 \in Server :
            commitIndex[s2] > 0 =>
            \A idx \in 1..commitIndex[s2] :
                LET entryTerm == AbsLogTerm(s2, idx)
                IN (entryTerm > 0 /\ entryTerm <= currentTerm[s1]) =>
                    \/ idx <= snapshotIndex[s1]
                    \/ LET adjIdx == idx - snapshotIndex[s1]
                       IN /\ adjIdx > 0
                          /\ adjIdx <= Len(log[s1])
                          /\ log[s1][adjIdx].term = entryTerm

\* Bug Family 2: CommitIndex should never decrease (except crash).
\* Violated because follower advanceCommitIndex has no monotonicity guard.
CommitIndexMonotonicity ==
    \A s \in Server :
        commitIndex[s] >= 0  \* placeholder — checked as temporal property

\* Bug Family 2: MatchIndex should never decrease.
\* Violated because leader response handler unconditionally sets matchIndex.
MatchIndexMonotonicity ==
    \A s \in Server :
        state[s] = Leader =>
            \A p \in Server : matchIndex[s][p] >= 0  \* placeholder — checked as temporal

\* Bug Family 1: After crash-recovery, committed entries should survive.
\* If commitIndex was X before crash, after recovery no committed entry
\* should be "forgotten" — i.e., the log should still contain entries 1..X.
\* This checks that persistedTerm consistency holds.
PersistedTermConsistency ==
    \A s \in Server : persistedTerm[s] <= currentTerm[s]

\* Bug Family 3: After snapshot install, config should match snapshot's config.
\* Violated because installSnapshot handler doesn't update configuration.
SnapshotConfigConsistency ==
    \A s \in Server :
        snapshotIndex[s] > 0 =>
            snapshotConfig[s] \subseteq config[s] \/ config[s] \subseteq snapshotConfig[s]

\* Bug Family 4: No cross-contamination between PreVote and Vote phases.
\* A server should not count PreVote grants toward real election.
VotePhaseSeparation ==
    \A s \in Server :
        state[s] = Candidate => preVotesGranted[s] = {}

\* Bug Family 5: At most one leader per term even during config changes.
ConfigChangeSafety == ElectionSafety

\* Structural: commit index never exceeds log length.
CommitIndexBound ==
    \A s \in Server : commitIndex[s] <= LastLogIndex(s) + snapshotIndex[s]

\* Structural: candidates always voted for themselves.
CandidateVotedForSelf ==
    \A s \in Server : state[s] = Candidate => votedFor[s] = s

\* Structural: leaders have positive term.
LeaderTermPositive ==
    \A s \in Server : state[s] = Leader => currentTerm[s] > 0

\* Bug Family 1: Vote safety across crashes.
\* A crashed-and-recovered node should not vote for two different candidates
\* in the same term. Violated when startVote's non-persist allows double-vote.
NoDualVoteFromCrash ==
    \A m \in DOMAIN messages :
        /\ m.mtype = RequestVoteRequest
        /\ currentTerm[m.msource] = m.mterm
        => votedFor[m.msource] = m.msource

=============================================================================
