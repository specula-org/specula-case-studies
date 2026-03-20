---------------------------- MODULE base ----------------------------
\* TLA+ specification of eliben/raft consensus protocol.
\*
\* Models the implementation faithfully, including known bugs:
\*   1. becomeFollower unconditionally resets votedFor on same-term
\*      transitions (Bug Family 1, F1a) — raft.go:536
\*   2. startElection doesn't persist term/votedFor (Bug Family 1, F1b)
\*      — raft.go:471-478 (no persistToStorage call)
\*   3. Non-atomic persistToStorage crash window (Bug Family 1, F1c)
\*      — raft.go:228-246 (3 separate Set() calls)
\*   4. Stale savedCurrentTerm in vote reply handler (Bug Family 2, F2a)
\*      — raft.go:507,511 (compares reply.Term to savedCurrentTerm, not currentTerm)
\*
\* Source: artifact/raft/part3/raft/raft.go (748 lines)
\*
EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs

CONSTANTS Follower,          \* Server states (raft.go:36-41)
          Candidate,
          Leader

CONSTANT Nil                 \* Null value (maps to -1 in the code)

CONSTANTS RequestVoteRequest,         \* Message types
          RequestVoteResponse,
          AppendEntriesRequest,
          AppendEntriesResponse

----
\* Variables
----

\* Per-server persistent state (raft.go:97-100)
\* NOTE: In the code, these survive restart via Storage interface.
VARIABLE currentTerm         \* [Server -> Nat]
VARIABLE votedFor            \* [Server -> Server \cup {Nil}]
VARIABLE log                 \* [Server -> Seq([term: Nat])]

\* Per-server volatile state (raft.go:103-106)
VARIABLE state               \* [Server -> {Follower, Candidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat]

\* Leader volatile state (raft.go:109-110)
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate volatile state
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension: Persistence tracking (Bug Family 1)
\* Tracks persisted vs volatile state for crash-recovery analysis.
\* Key: startElection (raft.go:471-478) does NOT call persistToStorage(),
\* so persistedTerm/persistedVotedFor may lag behind volatile state.
\* persistToStorage (raft.go:228-246) writes term, votedFor, log in 3
\* separate Set() calls — crash between writes is modeled by MC fault injection.
VARIABLE persistedTerm       \* [Server -> Nat]
VARIABLE persistedVotedFor   \* [Server -> Server \cup {Nil}]

----
\* Variable groups
----

serverVars    == <<currentTerm, state, votedFor>>
logVars       == <<log, commitIndex>>
leaderVars    == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted>>
persistVars   == <<persistedTerm, persistedVotedFor>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages, persistVars>>

----
\* Helpers
----

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b

SetMax(S) == CHOOSE x \in S : \A y \in S : x >= y

\* Log helpers — 1-indexed TLA+ sequences
\* Code uses 0-indexed Go slices; mapping: code_index = tla_index - 1
LastLogIndex(i) == Len(log[i])
LastLogTerm(i)  == IF Len(log[i]) > 0 THEN log[i][Len(log[i])].term ELSE 0
LogTerm(i, idx) == IF idx > 0 /\ idx <= Len(log[i]) THEN log[i][idx].term ELSE 0

\* Quorum check: strict majority
\* Reference: raft.go:514, 659 — votesReceived*2 > len(peerIds)+1
IsQuorum(S) == Cardinality(S) * 2 > Cardinality(Server)

\* Log up-to-date comparison (raft.go:286-287)
\* (args.LastLogTerm > lastLogTerm ||
\*  (args.LastLogTerm == lastLogTerm && args.LastLogIndex >= lastLogIndex))
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

\* Reference: raft.go:117-150 (NewConsensusModule)
\* state = Follower (line 126), votedFor = -1 (line 127) → Nil
\* commitIndex = -1 (line 128) → 0 in TLA+ (1-indexed)
\* currentTerm = 0 (default)
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
    /\ persistedTerm     = [s \in Server |-> 0]
    /\ persistedVotedFor = [s \in Server |-> Nil]

----
\* Election Actions
----

\* Server i times out and starts an election.
\* Reference: raft.go:471-528 (startElection)
\*
\* *** BUG F1b: No persistToStorage() call ***
\* Lines 471-478 modify currentTerm and votedFor in memory
\* but never call persistToStorage(). A crash after this point
\* recovers stale term/votedFor from disk, allowing re-voting.
\*
\* Note: RV goroutines read lastLogIndex/lastLogTerm lazily
\* (raft.go:484-486, inside per-peer goroutines). We model this
\* atomically, reading log state at election start time.
Timeout(i) ==
    /\ state[i] \in {Follower, Candidate}    \* raft.go:446
    \* raft.go:472: state = Candidate
    /\ state' = [state EXCEPT ![i] = Candidate]
    \* raft.go:473: currentTerm += 1
    /\ currentTerm' = [currentTerm EXCEPT ![i] = @ + 1]
    \* raft.go:476: votedFor = cm.id (self-vote)
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    \* raft.go:479: votesReceived = 1 (self-vote)
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    \* raft.go:482-523: send RequestVote RPCs to all peers
    \* RV carries savedCurrentTerm (line 474) as mterm
    /\ SendAll({[mtype         |-> RequestVoteRequest,
                 mterm         |-> currentTerm[i] + 1,
                 mlastLogTerm  |-> LastLogTerm(i),
                 mlastLogIndex |-> LastLogIndex(i),
                 msource       |-> i,
                 mdest         |-> j] : j \in Server \ {i}})
    \* *** F1b: NO persist — persistVars UNCHANGED ***
    /\ UNCHANGED <<persistVars, logVars, leaderVars>>

\* Server i handles a RequestVote RPC.
\* Reference: raft.go:270-298
\*
\* Flow:
\*   1. If args.Term > currentTerm: becomeFollower(args.Term) (line 279-282)
\*      → state=Follower, currentTerm=args.Term, votedFor=Nil
\*   2. Check grant conditions (line 284-287):
\*      currentTerm == args.Term && (votedFor == -1 || votedFor == candidateId)
\*      && log up-to-date → grant
\*   3. persistToStorage() (line 295)
\*
\* Note: becomeFollower at step 1 resets votedFor to Nil. This is CORRECT
\* here (new term → fresh vote). The F1a bug is in HandleAppendEntriesRequest.
HandleRequestVoteRequest(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ LET logOk == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                LastLogTerm(i), LastLogIndex(i))
           \* Compute state after potential becomeFollower (raft.go:279-282)
           newTerm     == Max(currentTerm[i], m.mterm)
           newVotedFor == IF m.mterm > currentTerm[i]
                          THEN Nil            \* becomeFollower resets votedFor
                          ELSE votedFor[i]
           newState    == IF m.mterm > currentTerm[i]
                          THEN Follower       \* becomeFollower
                          ELSE state[i]
           \* Grant conditions (raft.go:284-287)
           canGrant == /\ newTerm = m.mterm
                       /\ newVotedFor \in {Nil, m.msource}
                       /\ logOk
       IN
       \/ \* Grant vote (raft.go:288-290)
          /\ canGrant
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]   \* raft.go:289
          /\ state' = [state EXCEPT ![i] = newState]
          \* persistToStorage() at raft.go:295
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
          /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = m.msource]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> m.mterm,
                    mvoteGranted |-> TRUE,
                    \* F2a: msavedTerm carries election term for
                    \* stale-reply comparison in HandleRequestVoteResponse
                    msavedTerm   |-> m.mterm,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars>>

       \/ \* Reject vote (raft.go:291-293)
          /\ ~canGrant
          /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
          /\ votedFor' = [votedFor EXCEPT ![i] = newVotedFor]
          /\ state' = [state EXCEPT ![i] = newState]
          \* persistToStorage() at raft.go:295
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = newTerm]
          /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = newVotedFor]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> newTerm,
                    mvoteGranted |-> FALSE,
                    msavedTerm   |-> m.mterm,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars>>

\* Server i handles a RequestVote response.
\* Reference: raft.go:497-521 (inside startElection goroutine)
\*
\* *** BUG F2a: Uses savedCurrentTerm instead of currentTerm ***
\* At raft.go:507,511, the handler compares reply.Term against
\* savedCurrentTerm (captured at election start, raft.go:474),
\* NOT against the node's current cm.currentTerm.
\* If a term change occurred between election start and reply arrival,
\* savedCurrentTerm != currentTerm, enabling:
\*   - Counting stale votes from a previous election term
\*   - Term regression via becomeFollower(reply.Term) when reply.Term < currentTerm
\*
\* In the message model, msavedTerm represents savedCurrentTerm.
\* The handler compares m.mterm (voter's reply) against m.msavedTerm
\* (election's term) instead of against currentTerm[i].
HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ state[i] = Candidate                        \* raft.go:502
    /\ \/ \* Higher term: step down (raft.go:507-510)
          \* *** F2a: compares m.mterm > m.msavedTerm ***
          \* Correct code would check: m.mterm > currentTerm[i]
          /\ m.mterm > m.msavedTerm
          \* becomeFollower(reply.Term) — raft.go:509
          \* *** May REGRESS term if m.msavedTerm < currentTerm[i]
          \*     and m.mterm is between them ***
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ Discard(m)
          \* No persistToStorage call in this code path
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, persistVars>>

       \/ \* Vote granted, count it (raft.go:511-520)
          \* *** F2a: compares m.mterm = m.msavedTerm ***
          \* Correct code would check: m.mterm = currentTerm[i]
          /\ m.mterm = m.msavedTerm
          /\ m.mvoteGranted
          /\ votesGranted' = [votesGranted EXCEPT ![i] = @ \cup {m.msource}]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, persistVars>>

       \/ \* Vote not granted (raft.go:511 else — implicit)
          /\ m.mterm = m.msavedTerm
          /\ ~m.mvoteGranted
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars>>

       \/ \* Stale response: reply.Term < savedCurrentTerm (implicit drop-through)
          /\ m.mterm < m.msavedTerm
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars>>

\* Candidate i becomes leader after receiving quorum of votes.
\* Reference: raft.go:544-597 (startLeader)
\* Called from HandleRequestVoteResponse when votesReceived reaches majority.
\* Modeled as separate action so quorum check is explicit.
BecomeLeader(i) ==
    /\ state[i] = Candidate
    /\ IsQuorum(votesGranted[i])
    \* raft.go:545: state = Leader
    /\ state' = [state EXCEPT ![i] = Leader]
    \* raft.go:547-550: initialize nextIndex and matchIndex
    \* Code: nextIndex[peerId] = len(cm.log)  → TLA+ Len(log[i]) + 1 (1-indexed)
    \* Code: matchIndex[peerId] = -1           → TLA+ 0
    /\ nextIndex'  = [nextIndex  EXCEPT ![i] =
                       [j \in Server |-> LastLogIndex(i) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                       [j \in Server |-> 0]]
    \* No persistToStorage call in startLeader
    /\ UNCHANGED <<currentTerm, votedFor, logVars, candidateVars, messages,
                   persistVars>>

----
\* Log Replication Actions
----

\* Leader i receives a client request and appends to log.
\* Reference: raft.go:164-179 (Submit)
ClientRequest(i) ==
    /\ state[i] = Leader                        \* raft.go:167
    \* raft.go:169: append entry with currentTerm
    /\ log' = [log EXCEPT ![i] = Append(@, [term |-> currentTerm[i]])]
    \* raft.go:170: persistToStorage()
    /\ persistedTerm' = [persistedTerm EXCEPT ![i] = currentTerm[i]]
    /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = votedFor[i]]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars, messages>>

\* Leader i sends AppendEntries to server j.
\* Reference: raft.go:601-701 (leaderSendAEs)
\*
\* Note: raft.go:607 captures savedCurrentTerm before per-peer goroutines.
\* raft.go:622 uses savedCurrentTerm as the AE's Term field.
\* We model this atomically — AE carries currentTerm[i] at action time.
\* The msavedTerm field in the response enables stale-term detection.
AppendEntries(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == LogTerm(i, prevIdx)
           lastIdx  == LastLogIndex(i)
           \* raft.go:619: entries = cm.log[ni:]
           entries  == IF nextIndex[i][j] > lastIdx
                       THEN <<>>
                       ELSE SubSeq(log[i], nextIndex[i][j], lastIdx)
       IN Send([mtype         |-> AppendEntriesRequest,
                mterm         |-> currentTerm[i],        \* raft.go:622
                mprevLogIndex |-> prevIdx,               \* raft.go:614
                mprevLogTerm  |-> prevTerm,              \* raft.go:617
                mentries      |-> entries,               \* raft.go:619
                mleaderCommit |-> commitIndex[i],        \* raft.go:627
                msource       |-> i,
                mdest         |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars, persistVars>>

\* Server i handles an AppendEntries request.
\* Reference: raft.go:321-408
\*
\* *** BUG F1a: becomeFollower votedFor reset on same-term transition ***
\* At raft.go:336-337, if args.Term == currentTerm and state != Follower,
\* the code calls becomeFollower(args.Term). Since becomeFollower
\* unconditionally resets votedFor to -1 (raft.go:536), this erases the
\* node's vote record for the current term. The node can then grant a
\* vote to a different candidate in the same term, enabling two leaders.
\*
\* Attack scenario (3 servers A, B, C):
\*   1. A starts election term 2, votes for self
\*   2. A wins election, becomes leader term 2
\*   3. A sends AE to B (candidate term 2)
\*   4. B receives AE: term==currentTerm, state!=Follower
\*      → becomeFollower(2) → votedFor = Nil  [F1a!]
\*   5. C starts election term 2, sends RV to B
\*   6. B grants vote to C (votedFor was Nil)
\*   7. C wins → two leaders in term 2!
HandleAppendEntriesRequest(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ LET logOk == \/ m.mprevLogIndex = 0
                    \/ /\ m.mprevLogIndex > 0
                       /\ m.mprevLogIndex <= LastLogIndex(i)
                       /\ LogTerm(i, m.mprevLogIndex) = m.mprevLogTerm
       IN
       \/ \* Reject: term too low (raft.go:329 — args.Term < currentTerm)
          \* No state changes; reply with failure and current term.
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype       |-> AppendEntriesResponse,
                    mterm       |-> currentTerm[i],
                    msuccess    |-> FALSE,
                    mmatchIndex |-> 0,
                    msavedTerm  |-> m.mterm,
                    msource     |-> i,
                    mdest       |-> m.msource], m)
          \* persistToStorage() at raft.go:405 — persists current volatile state
          \* This may "catch up" stale persisted state from unpersisted Timeout
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = currentTerm[i]]
          /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = votedFor[i]]
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars>>

       \/ \* Accept/Reject with term >= currentTerm
          /\ m.mterm >= currentTerm[i]
          \* Combined effect of:
          \*   raft.go:329-332: if args.Term > currentTerm → becomeFollower
          \*   raft.go:336-337: if args.Term == currentTerm && state != Follower
          \*                    → becomeFollower (*** F1a ***)
          /\ LET \* Compute new votedFor after potential becomeFollower calls
                  newVotedFor ==
                     IF m.mterm > currentTerm[i]
                     THEN Nil                   \* Higher term → reset (correct per Raft)
                     ELSE IF state[i] /= Follower
                          THEN Nil              \* *** F1a: same-term reset! ***
                          ELSE votedFor[i]      \* Already follower → keep
             IN
             /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
             /\ state' = [state EXCEPT ![i] = Follower]
             /\ votedFor' = [votedFor EXCEPT ![i] = newVotedFor]
             \* Process log entries
             /\ \/ \* Accept: log matches (raft.go:344-380)
                   /\ logOk
                   /\ LET \* raft.go:351-373: find insertion point and append
                           \* Only truncate at the first conflict point. If new entries
                           \* match existing entries (no term mismatch), keep the longer log.
                           \* This prevents committed entries from being truncated by
                           \* a stale AE with fewer entries.
                           newLog == IF Len(m.mentries) > 0
                                     THEN LET truncated == SubSeq(log[i], 1, m.mprevLogIndex)
                                                            \o m.mentries
                                          IN IF Len(truncated) < Len(log[i])
                                                /\ \A k \in 1..Len(m.mentries) :
                                                   log[i][m.mprevLogIndex + k].term
                                                    = m.mentries[k].term
                                             THEN log[i]  \* No conflict, keep longer log
                                             ELSE truncated
                                     ELSE log[i]
                           \* raft.go:376-380: update commitIndex
                           newCommitIdx ==
                              IF m.mleaderCommit > commitIndex[i]
                              THEN Min(m.mleaderCommit, Len(newLog))
                              ELSE commitIndex[i]
                      IN
                      /\ log' = [log EXCEPT ![i] = newLog]
                      /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
                      /\ Reply([mtype       |-> AppendEntriesResponse,
                                mterm       |-> m.mterm,
                                msuccess    |-> TRUE,
                                mmatchIndex |-> Len(newLog),
                                msavedTerm  |-> m.mterm,
                                msource     |-> i,
                                mdest       |-> m.msource], m)

                \/ \* Reject: log mismatch (raft.go:381-401)
                   /\ ~logOk
                   /\ Reply([mtype       |-> AppendEntriesResponse,
                             mterm       |-> m.mterm,
                             msuccess    |-> FALSE,
                             mmatchIndex |-> 0,
                             msavedTerm  |-> m.mterm,
                             msource     |-> i,
                             mdest       |-> m.msource], m)
                   /\ UNCHANGED <<log, commitIndex>>
             \* persistToStorage() at raft.go:405
             /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
             /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = newVotedFor]
             /\ UNCHANGED <<leaderVars, candidateVars>>

\* Leader i handles an AppendEntries response.
\* Reference: raft.go:632-698 (inside leaderSendAEs goroutine)
\*
\* Note: raft.go:645 checks savedCurrentTerm == reply.Term (not currentTerm).
\* We model this via msavedTerm in the response message.
HandleAppendEntriesResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = i
    /\ \/ \* Higher term: step down (raft.go:638-643)
          \* This check uses cm.currentTerm (correct), not savedCurrentTerm
          /\ m.mterm > currentTerm[i]
          \* becomeFollower(reply.Term) — no persist call!
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, persistVars>>

       \/ \* Process response while still leader (raft.go:645)
          \* Code: cm.state == Leader && savedCurrentTerm == reply.Term
          /\ m.mterm <= currentTerm[i]
          /\ state[i] = Leader
          /\ m.msavedTerm = m.mterm       \* savedCurrentTerm == reply.Term
          /\ IF m.msuccess
             THEN \* Success (raft.go:646-675)
                  \* raft.go:647: nextIndex[peerId] = ni + len(entries)
                  \* raft.go:648: matchIndex[peerId] = nextIndex[peerId] - 1
                  /\ nextIndex'  = [nextIndex  EXCEPT ![i][m.msource] =
                                    m.mmatchIndex + 1]
                  /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] =
                                    m.mmatchIndex]
             ELSE \* Failure (raft.go:676-694): backtrack nextIndex
                  \* Simplified: decrement by 1 (code uses conflict optimization)
                  /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] =
                                   Max(1, nextIndex[i][m.msource] - 1)]
                  /\ UNCHANGED matchIndex
          /\ Discard(m)
          \* No persistToStorage call
          /\ UNCHANGED <<serverVars, logVars, candidateVars, persistVars>>

       \/ \* Stale or mismatched response: ignore (raft.go:696-698)
          /\ m.mterm <= currentTerm[i]
          /\ \/ state[i] /= Leader
             \/ m.msavedTerm /= m.mterm
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars>>

\* Leader i advances commit index based on quorum replication.
\* Reference: raft.go:651-663 (inside HandleAppendEntriesResponse success path)
\* Separated as independent action for cleaner modeling.
\*
\* Key: raft.go:652 — only commit entries from current term (Section 5.4.2).
\* This is the safety mechanism that prevents old-term entries from being
\* committed directly; they are committed indirectly when a current-term
\* entry at a higher index commits.
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET \* raft.go:653-661: for each log index, count servers with matchIndex >= idx
           Agree(idx) == {i} \cup {s \in Server \ {i} : matchIndex[i][s] >= idx}
           \* raft.go:652: if cm.log[i].Term == cm.currentTerm
           agreeIdxs == {idx \in (commitIndex[i]+1)..LastLogIndex(i) :
                          /\ IsQuorum(Agree(idx))
                          /\ log[i][idx].term = currentTerm[i]}
       IN
       /\ agreeIdxs /= {}
       /\ commitIndex' = [commitIndex EXCEPT ![i] = SetMax(agreeIdxs)]
    /\ UNCHANGED <<serverVars, log, leaderVars, candidateVars, messages,
                   persistVars>>

----
\* Crash and Recovery (Bug Family 1)
----

\* Server i crashes. All volatile state is lost; recovers from persisted state.
\* Reference: raft.go:197-224 (restoreFromStorage)
\*
\* Bug Family 1 mechanism:
\*   If Timeout (startElection) ran without persisting (F1b), persistedTerm
\*   and persistedVotedFor are stale. Recovery restores the pre-election
\*   term/votedFor, so the node may vote again in the same effective term.
\*
\*   If persistToStorage was interrupted (F1c, modeled by MC fault injection),
\*   persistedTerm may be updated but persistedVotedFor is stale, causing
\*   inconsistency on recovery.
Crash(i) ==
    \* Recover from persisted state (raft.go:200-223)
    /\ currentTerm' = [currentTerm EXCEPT ![i] = persistedTerm[i]]
    /\ votedFor'    = [votedFor    EXCEPT ![i] = persistedVotedFor[i]]
    /\ state'       = [state       EXCEPT ![i] = Follower]
    \* Volatile state reset (raft.go:127-131)
    /\ commitIndex'  = [commitIndex  EXCEPT ![i] = 0]
    /\ nextIndex'    = [nextIndex    EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'   = [matchIndex   EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    \* Persisted state and log survive crash
    /\ UNCHANGED <<log, messages, persistVars>>

----
\* Network faults
----

\* Message is lost in transit.
LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars>>

\* Drop messages with stale terms (optimization to reduce state space).
\* These messages would be rejected by the handler anyway.
DropStaleMessage(m) ==
    /\ m \in DOMAIN messages
    /\ m.mterm < currentTerm[m.mdest]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars>>

----
\* Spec
----

Next ==
    \/ \E i \in Server :
        \/ Timeout(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ AdvanceCommitIndex(i)
        \/ Crash(i)
    \/ \E i, j \in Server :
        \/ AppendEntries(i, j)
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
\* Primary detection invariant for F1a (votedFor reset) and F2a (stale votes).
ElectionSafety ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ state[s2] = Leader
         /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* Standard Raft: if two logs have an entry with same index and term,
\* the logs are identical up to that point.
LogMatching ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(LastLogIndex(s1), LastLogIndex(s2)) :
            log[s1][idx].term = log[s2][idx].term =>
                \A k \in 1..idx : log[s1][k].term = log[s2][k].term

\* Standard Raft: a committed entry appears in all future leaders' logs.
LeaderCompleteness ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ commitIndex[s2] > 0) =>
            \A idx \in 1..commitIndex[s2] :
                /\ idx <= LastLogIndex(s1)
                /\ log[s1][idx].term = log[s2][idx].term

\* Structural: a candidate has voted for itself.
\* Should hold because Timeout always sets votedFor = i when becoming Candidate.
CandidateVotedForSelf ==
    \A s \in Server :
        state[s] = Candidate => votedFor[s] = s

\* Structural: commit index doesn't exceed log length.
CommitIndexBound ==
    \A s \in Server :
        commitIndex[s] <= LastLogIndex(s)

\* Structural: leader's term is positive.
LeaderTermPositive ==
    \A s \in Server :
        state[s] = Leader => currentTerm[s] > 0

\* Structural: nextIndex is always positive.
NextIndexPositive ==
    \A s, t \in Server :
        state[s] = Leader => nextIndex[s][t] >= 1

\* Structural: persisted term never exceeds volatile term.
\* This can be violated by F2a term regression (becomeFollower with stale term).
PersistedTermConsistency ==
    \A s \in Server :
        persistedTerm[s] <= currentTerm[s]

=============================================================================
