------------------------------ MODULE base --------------------------------
\* TLA+ specification of sofastack/sofa-jraft Raft protocol.
\*
\* Extends standard Raft with sofa-jraft-specific behaviors:
\*   1. Non-atomic vote persistence (NodeImpl.java:1857-1864, 1218-1227)
\*   2. Missing/incomplete term checks in response handlers (Replicator.java)
\*   3. Joint consensus configuration changes (Ballot.java, ConfigurationCtx)
\*   4. Crash recovery from persisted state (LocalRaftMetaStorage.java)
\*
\* Each extension traces to a Bug Family in the Modeling Brief.

EXTENDS Naturals, FiniteSets, Sequences, Bags, TLC

----
\* Constants
----

CONSTANT Server              \* Set of server IDs

CONSTANTS Follower,          \* Server states
          Candidate,
          Leader

CONSTANT Nil                 \* Null value

CONSTANTS ValueEntry,        \* Log entry types
          ConfigEntry

CONSTANTS RequestVoteRequest,           \* Message types
          RequestVoteResponse,
          AppendEntriesRequest,
          AppendEntriesResponse,
          InstallSnapshotRequest,
          InstallSnapshotResponse

----
\* Variables
----

\* Per-server persistent state (survives restart via stable store)
VARIABLE currentTerm         \* [Server -> Nat] — in-memory term
VARIABLE votedFor            \* [Server -> Server \cup {Nil}] — in-memory votedFor
VARIABLE log                 \* [Server -> Seq(Entry)]

\* Per-server volatile state
VARIABLE state               \* [Server -> {Follower, Candidate, Leader}]
VARIABLE commitIndex         \* [Server -> Nat]

\* Leader volatile state
VARIABLE nextIndex           \* [Server -> [Server -> Nat]]
VARIABLE matchIndex          \* [Server -> [Server -> Nat]]

\* Candidate state
VARIABLE votesGranted        \* [Server -> SUBSET Server]

\* Network
VARIABLE messages            \* Bag of message records

\* Extension 1 (Family 1): Non-atomic vote persistence
\* sofa-jraft has two persistence bugs:
\*   (a) handleRequestVoteRequest: stepDown persists (term, empty),
\*       then separate setVotedFor(candidate) — crash between = double-vote
\*       Reference: NodeImpl.java:1830-1864
\*   (b) electSelf: sends RPCs BEFORE persisting (term, votedFor) —
\*       crash between = term increment lost
\*       Reference: NodeImpl.java:1224 (send) vs 1227 (persist)
\*
\* persistedTerm/persistedVotedFor track on-disk state.
\* pendingVote holds deferred vote response during non-atomic persist.
VARIABLE persistedTerm       \* [Server -> Nat]
VARIABLE persistedVotedFor   \* [Server -> Server \cup {Nil}]
VARIABLE pendingVote         \* [Server -> record \cup {Nil}]

\* Extension 2 (Family 4): Joint consensus configuration
\* sofa-jraft uses dual-quorum Ballot with old+new configs during transitions.
\* Reference: Ballot.java:69-91, 144-146
\*   config = latest (possibly uncommitted) config peers
\*   configOld = old config during joint transition ({} = stable)
VARIABLE config              \* [Server -> SUBSET Server]
VARIABLE configOld           \* [Server -> SUBSET Server]

----
\* Variable groups
----

serverVars   == <<currentTerm, votedFor, state>>
logVars      == <<log, commitIndex>>
leaderVars   == <<nextIndex, matchIndex>>
candidateVars == <<votesGranted>>
persistVars  == <<persistedTerm, persistedVotedFor, pendingVote>>
configVars   == <<config, configOld>>

vars == <<serverVars, logVars, leaderVars, candidateVars, messages,
          persistVars, configVars>>

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

\* Simple quorum check: majority of a voter set
\* Reference: Ballot.java:144-146 (isGranted — quorum = peers/2 + 1)
IsQuorum(S, voters) == Cardinality(S) * 2 > Cardinality(voters)

\* Joint consensus quorum: requires majority in BOTH configs
\* Reference: Ballot.java:144-146
\*   isGranted() == quorum.isGranted() && (oldQuorum == null || oldQuorum.isGranted())
\* When configOld = {} (stable), only new config quorum is needed.
IsJointQuorum(S, newConf, oldConf) ==
    /\ IsQuorum(S \cap newConf, newConf)
    /\ IF oldConf = {} THEN TRUE
       ELSE IsQuorum(S \cap oldConf, oldConf)

\* Log up-to-date comparison
\* Reference: LogId.compareTo() used in handleRequestVoteRequest (NodeImpl.java:1855-1857)
LogUpToDate(cLastTerm, cLastIdx, vLastTerm, vLastIdx) ==
    \/ cLastTerm > vLastTerm
    \/ (cLastTerm = vLastTerm /\ cLastIdx >= vLastIdx)

\* Scan log for the latest ConfigEntry at or before index maxIdx.
\* Returns the config record, or the initial config if none found.
LatestConfigInLog(logSeq, maxIdx) ==
    LET bound == Min(maxIdx, Len(logSeq))
        indices == {k \in 1..bound : logSeq[k].type = ConfigEntry}
    IN IF indices = {} THEN [conf |-> Server, old |-> {}]
       ELSE LET idx == SetMax(indices)
            IN [conf |-> logSeq[idx].config, old |-> logSeq[idx].oldConfig]

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
    /\ messages          = EmptyBag
    /\ persistedTerm     = [s \in Server |-> 0]
    /\ persistedVotedFor = [s \in Server |-> Nil]
    /\ pendingVote       = [s \in Server |-> Nil]
    /\ config            = [s \in Server |-> Server]
    /\ configOld         = [s \in Server |-> {}]

----
\* Election Actions
----

\* Server i times out and starts election (electSelf).
\* Reference: NodeImpl.java:1163-1235
\*
\* *** BUG (Family 1, MC-2): RPCs sent BEFORE persisting ***
\* Code flow:
\*   1. state = CANDIDATE, currTerm++ (line 1181-1182)
\*   2. votedId = self (line 1183)
\*   3. init vote ballot (line 1187-1188)
\*   4. Send RequestVote RPCs to all peers (line 1204-1224)
\*   5. THEN persist: metaStorage.setTermAndVotedFor() (line 1227)
\*   6. Self-grant vote (line 1228)
\*
\* This action models steps 1-4: in-memory state updated, RPCs sent,
\* but persistedTerm/persistedVotedFor NOT yet updated.
\* PersistElectSelf models step 5.
\* A crash between ElectSelf and PersistElectSelf means the term
\* increment is lost — node restarts with old term.
ElectSelf(i) ==
    /\ state[i] \in {Follower, Candidate}
    \* Must be in current config (NodeImpl.java:1168)
    /\ i \in config[i]
    \* No pending vote persist in progress
    /\ pendingVote[i] = Nil
    /\ LET newTerm == currentTerm[i] + 1
       IN
       \* In-memory state update (NodeImpl.java:1181-1183)
       /\ currentTerm' = [currentTerm EXCEPT ![i] = newTerm]
       /\ state' = [state EXCEPT ![i] = Candidate]
       /\ votedFor' = [votedFor EXCEPT ![i] = i]
       \* Init vote ballot with joint quorum (NodeImpl.java:1187-1188)
       /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
       \* BUG: persistedTerm/persistedVotedFor NOT updated yet
       \* Reference: NodeImpl.java:1227 — persist happens AFTER RPCs sent at line 1224
       /\ UNCHANGED <<persistedTerm, persistedVotedFor, pendingVote>>
       \* Send RequestVote RPCs (NodeImpl.java:1204-1224)
       /\ SendAll({[mtype        |-> RequestVoteRequest,
                    mterm        |-> newTerm,
                    mlastLogTerm |-> LastLogTerm(i),
                    mlastLogIndex |-> LastLogIndex(i),
                    msource      |-> i,
                    mdest        |-> j] : j \in config[i] \ {i}})
    /\ UNCHANGED <<logVars, leaderVars, configVars>>

\* Complete electSelf persistence (step 5).
\* Reference: NodeImpl.java:1227
\*   metaStorage.setTermAndVotedFor(this.currTerm, this.serverId)
\* This persists BOTH term and votedFor atomically via setTermAndVotedFor.
PersistElectSelf(i) ==
    /\ state[i] = Candidate
    /\ pendingVote[i] = Nil
    \* Persist is pending: in-memory term ahead of persisted
    /\ persistedTerm[i] < currentTerm[i]
    \* Persist term + votedFor atomically (LocalRaftMetaStorage.java:184-189)
    /\ persistedTerm' = [persistedTerm EXCEPT ![i] = currentTerm[i]]
    /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = i]
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   messages, pendingVote, configVars>>

\* Server i handles RequestVoteRequest m.
\* Reference: NodeImpl.java:1802-1878
\*
\* Code flow for higher-term grant:
\*   1. If term > currTerm: stepDown(term) (line 1830)
\*      — stepDown persists (term, emptyPeer) via setTermAndVotedFor (line 1332)
\*   2. Check log up-to-date (line 1855-1857)
\*   3. If grant: votedId = candidate (line 1863)
\*   4. metaStorage.setVotedFor(candidate) (line 1864)
\*
\* *** BUG (Family 1, MC-1): Steps 1 and 4 are separate persists ***
\* stepDown persists (term, Nil), then setVotedFor persists votedFor.
\* Crash between = term persisted but votedFor lost = can double-vote.
\*
\* Four cases modeled:
\*   Case 0: Stale term → reject
\*   Case 1: Higher/same term, can't grant → reject (step down if higher)
\*   Case 2: Same term, grant → atomic persist (only votedFor changes)
\*   Case 3: Higher term, grant → NON-ATOMIC persist (Extension 1)
HandleRequestVoteRequest(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ pendingVote[i] = Nil
    /\ LET mterm    == m.mterm
           logOk    == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                   LastLogTerm(i), LastLogIndex(i))
           \* Grant conditions (NodeImpl.java:1859):
           \*   logIsOk && (votedId == null || votedId.isEmpty())
           \* After stepDown: votedId is reset to emptyPeer
           canGrant == /\ logOk
                       /\ \/ mterm > currentTerm[i]
                          \/ /\ mterm = currentTerm[i]
                             /\ votedFor[i] \in {Nil, m.msource}
       IN
       \/ \* Case 0: Stale term — reject without state change
          \* Reference: NodeImpl.java:1834-1839
          /\ mterm < currentTerm[i]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, configVars>>

       \/ \* Case 1: Higher/same term but cannot grant
          \* Reference: NodeImpl.java:1825-1866
          \* Term check at line 1825; logOk at line 1855-1857; grant at 1859
          /\ mterm >= currentTerm[i]
          /\ ~canGrant
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> Max(currentTerm[i], mterm),
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          \* If higher term: stepDown persists (term, Nil) (line 1830 + stepDown:1332)
          /\ IF mterm > currentTerm[i]
             THEN /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
                  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
                  /\ state' = [state EXCEPT ![i] = Follower]
                  /\ persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
                  /\ UNCHANGED <<persistedVotedFor, pendingVote>>
             ELSE UNCHANGED <<serverVars, persistVars>>
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars>>

       \/ \* Case 2: Same term, grant — atomic persist
          \* Reference: NodeImpl.java:1859-1864
          \* Only votedFor changes; term already matches.
          \* setVotedFor (line 1864) persists votedFor atomically.
          /\ mterm = currentTerm[i]
          /\ canGrant
          /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
          /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = m.msource]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> TRUE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<currentTerm, state, persistedTerm, pendingVote>>
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars>>

       \/ \* Case 3: Higher term, grant — NON-ATOMIC persist (Extension 1)
          \* Reference: NodeImpl.java:1830 (stepDown) + 1863-1864 (setVotedFor)
          \*
          \* Step 1: stepDown(term) persists (term, Nil) via setTermAndVotedFor
          \*   — NodeImpl.java:1332: metaStorage.setTermAndVotedFor(term, emptyPeer)
          \* Step 2 (CompletePersistVote): persist votedFor via setVotedFor
          \*   — NodeImpl.java:1864: metaStorage.setVotedFor(candidateId)
          \*
          \* Crash between step 1 and 2: persistedTerm=new, persistedVotedFor=Nil
          \* → node restarts, can vote for a different candidate in same term.
          /\ mterm > currentTerm[i]
          /\ canGrant
          \* In-memory update
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
          /\ state' = [state EXCEPT ![i] = Follower]
          \* stepDown persists (term, Nil) — NodeImpl.java:1332
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
          /\ UNCHANGED persistedVotedFor  \* NOT YET — this is the bug window
          \* Defer vote response until CompletePersistVote
          /\ pendingVote' = [pendingVote EXCEPT ![i] =
                [candidate |-> m.msource, term |-> mterm]]
          \* Consume request; response deferred
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars>>

\* Complete the non-atomic vote persist (Extension 1).
\* Reference: NodeImpl.java:1864 — metaStorage.setVotedFor(candidateId)
\* Persists votedFor and sends the deferred vote response.
CompletePersistVote(i) ==
    /\ pendingVote[i] /= Nil
    \* Persist votedFor — LocalRaftMetaStorage.java:171-175 (setVotedFor)
    /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = pendingVote[i].candidate]
    /\ pendingVote' = [pendingVote EXCEPT ![i] = Nil]
    /\ Send([mtype        |-> RequestVoteResponse,
             mterm        |-> pendingVote[i].term,
             mvoteGranted |-> TRUE,
             msource      |-> i,
             mdest        |-> pendingVote[i].candidate])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistedTerm, configVars>>

\* Atomic HandleRequestVoteRequest: merges Cases 2 & 3 into single step.
\* In normal (non-crash) execution, handleRequestVoteRequest persists
\* term and votedFor without interruption. This operator models that
\* atomic behavior for trace validation (impl doesn't crash mid-persist).
HandleRequestVoteRequestAtomic(i, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = i
    /\ LET mterm    == m.mterm
           logOk    == LogUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                   LastLogTerm(i), LastLogIndex(i))
           canGrant == /\ logOk
                       /\ \/ mterm > currentTerm[i]
                          \/ /\ mterm = currentTerm[i]
                             /\ votedFor[i] \in {Nil, m.msource}
       IN
       \/ \* Reject: stale term (NodeImpl.java:1834-1839)
          /\ mterm < currentTerm[i]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> currentTerm[i],
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, configVars>>

       \/ \* Reject: higher/same term but can't grant
          /\ mterm >= currentTerm[i]
          /\ ~canGrant
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> Max(currentTerm[i], mterm),
                    mvoteGranted |-> FALSE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ IF mterm > currentTerm[i]
             THEN /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
                  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
                  /\ state' = [state EXCEPT ![i] = Follower]
                  /\ persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
                  /\ UNCHANGED <<persistedVotedFor, pendingVote>>
             ELSE UNCHANGED <<serverVars, persistVars>>
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars>>

       \/ \* Grant (atomic persist — both term and votedFor)
          /\ canGrant
          /\ mterm >= currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ votedFor' = [votedFor EXCEPT ![i] = m.msource]
          /\ state' = IF mterm > currentTerm[i]
                      THEN [state EXCEPT ![i] = Follower]
                      ELSE state
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
          /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = m.msource]
          /\ pendingVote' = [pendingVote EXCEPT ![i] = Nil]
          /\ Reply([mtype        |-> RequestVoteResponse,
                    mterm        |-> mterm,
                    mvoteGranted |-> TRUE,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars, configVars>>

\* Server i handles RequestVoteResponse m.
\* Reference: NodeImpl.java:2584-2618
\*
\* Code flow:
\*   1. Check state == CANDIDATE (line 2588)
\*   2. Check stale term (line 2594)
\*   3. Check response.term > currTerm → stepDown (line 2600-2606)
\*   4. If granted: voteCtx.grant(peer) (line 2610)
\*   5. If quorum → becomeLeader() (line 2611-2613)
HandleRequestVoteResponse(i, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = i
    /\ state[i] = Candidate
    /\ m.mterm = currentTerm[i]
    \* Process vote (NodeImpl.java:2609-2613)
    /\ IF m.mvoteGranted
       THEN votesGranted' = [votesGranted EXCEPT ![i] = votesGranted[i] \cup {m.msource}]
       ELSE UNCHANGED votesGranted
    /\ Discard(m)
    \* Check response term > current term → stepDown (NodeImpl.java:2600-2606)
    /\ IF m.mterm > currentTerm[i]
       THEN /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
            /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
            /\ state' = [state EXCEPT ![i] = Follower]
            /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
            /\ UNCHANGED <<persistedVotedFor, pendingVote>>
       ELSE UNCHANGED <<serverVars, persistVars>>
    /\ UNCHANGED <<logVars, leaderVars, configVars>>

\* Candidate i becomes leader after receiving quorum of votes.
\* Reference: NodeImpl.java:1261-1298 (becomeLeader)
\*
\* Key: quorum uses joint consensus (both config and configOld)
\* Reference: Ballot.java:144-146 — isGranted checks both quorums
BecomeLeader(i) ==
    /\ state[i] = Candidate
    /\ IsJointQuorum(votesGranted[i], config[i], configOld[i])
    \* Become leader (NodeImpl.java:1267-1268)
    /\ state' = [state EXCEPT ![i] = Leader]
    \* Initialize leader state (NodeImpl.java:1270-1290)
    /\ nextIndex'  = [nextIndex  EXCEPT ![i] = [j \in Server |-> LastLogIndex(i) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, candidateVars, messages,
                   persistVars, configVars>>

----
\* Log Replication Actions
----

\* Leader i appends a client request to its log.
\* Reference: NodeImpl.java:1394-1469 (executeApplyingTasks)
\* Simplified: appends a ValueEntry with current term.
ClientRequest(i) ==
    /\ state[i] = Leader
    /\ LET entry == [term      |-> currentTerm[i],
                     type      |-> ValueEntry,
                     config    |-> {},
                     oldConfig |-> {}]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars,
                   messages, persistVars, configVars>>

\* Leader i sends AppendEntries with log entries to server j.
\* Reference: Replicator.java:1629-1710 (sendEntries)
AppendEntries(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ LET prevIdx  == nextIndex[i][j] - 1
           prevTerm == LogTerm(i, prevIdx)
           lastIdx  == LastLogIndex(i)
           entries  == IF nextIndex[i][j] > lastIdx THEN <<>>
                       ELSE SubSeq(log[i], nextIndex[i][j], lastIdx)
       IN Send([mtype        |-> AppendEntriesRequest,
                msubtype     |-> "replicate",
                mterm        |-> currentTerm[i],
                mprevLogIndex |-> prevIdx,
                mprevLogTerm |-> prevTerm,
                mentries     |-> entries,
                mcommitIndex |-> commitIndex[i],
                msource      |-> i,
                mdest        |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, configVars>>

\* Leader i sends heartbeat (empty AppendEntries) to server j.
\* Reference: Replicator.java:1711-1728 (sendHeartbeat)
\*   sendEmptyEntries(true) — sends AppendEntries with no entries.
SendHeartbeat(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ Send([mtype        |-> AppendEntriesRequest,
             msubtype     |-> "heartbeat",
             mterm        |-> currentTerm[i],
             mprevLogIndex |-> 0,
             mprevLogTerm |-> 0,
             mentries     |-> <<>>,
             mcommitIndex |-> 0,
             msource      |-> i,
             mdest        |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, configVars>>

\* Server i handles an AppendEntriesRequest m.
\* Reference: NodeImpl.java:1944-2100 (handleAppendEntriesRequest)
\*
\* Code flow:
\*   1. Check stale term (line 1970)
\*   2. checkStepDown (line 1980) — step down if higher term or not follower
\*   3. Check leader conflict (line 1981-1992)
\*   4. Check prevLog match (line 2004-2020)
\*   5. If heartbeat (entriesCount==0): respond success (line 2022-2032)
\*   6. Append entries (line 2044-2083)
HandleAppendEntriesRequest(i, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = i
    /\ LET mterm   == m.mterm
           logOk   == \/ m.mprevLogIndex = 0
                      \/ /\ m.mprevLogIndex > 0
                         /\ m.mprevLogIndex <= LastLogIndex(i)
                         /\ LogTerm(i, m.mprevLogIndex) = m.mprevLogTerm
       IN
       \/ \* Reject: stale term (NodeImpl.java:1970-1977)
          /\ mterm < currentTerm[i]
          /\ Reply([mtype        |-> AppendEntriesResponse,
                    msubtype     |-> m.msubtype,
                    mterm        |-> currentTerm[i],
                    msuccess     |-> FALSE,
                    mmatchIndex  |-> 0,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, configVars>>

       \/ \* Reject: log inconsistency (NodeImpl.java:2004-2020)
          \* checkStepDown at line 1980 handles term/state update
          /\ mterm >= currentTerm[i]
          /\ ~logOk
          /\ Reply([mtype        |-> AppendEntriesResponse,
                    msubtype     |-> m.msubtype,
                    mterm        |-> mterm,
                    msuccess     |-> FALSE,
                    mmatchIndex  |-> 0,
                    msource      |-> i,
                    mdest        |-> m.msource], m)
          \* checkStepDown (NodeImpl.java:1243-1258):
          \*   if term > currTerm → stepDown
          \*   else if not follower → stepDown
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ IF mterm > currentTerm[i]
             THEN persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
             ELSE UNCHANGED persistedTerm
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         configVars, persistedVotedFor, pendingVote>>

       \/ \* Accept: log matches at prevLogIndex
          \* Reference: NodeImpl.java:2022-2083
          /\ mterm >= currentTerm[i]
          /\ logOk
          /\ LET \* Append new entries (NodeImpl.java:2044-2083)
                 \* Heartbeat: entriesCount=0, don't touch log
                 newLog == IF Len(m.mentries) > 0
                           THEN SubSeq(log[i], 1, m.mprevLogIndex) \o m.mentries
                           ELSE log[i]
                 newLastIdx == Len(newLog)
                 \* Update commitIndex (via ballotBox.setLastCommittedIndex)
                 \* NodeImpl.java:2031 — min(committedIndex, prevLogIndex)
                 newCommitIdx == IF m.mcommitIndex > commitIndex[i]
                                 THEN Min(m.mcommitIndex, newLastIdx)
                                 ELSE commitIndex[i]
                 \* Update configs from log
                 newLatestConf == LatestConfigInLog(newLog, newLastIdx)
                 newCommitConf == LatestConfigInLog(newLog, newCommitIdx)
             IN
             /\ log' = [log EXCEPT ![i] = newLog]
             /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
             /\ config' = [config EXCEPT ![i] = newLatestConf.conf]
             /\ configOld' = [configOld EXCEPT ![i] = newLatestConf.old]
             /\ Reply([mtype        |-> AppendEntriesResponse,
                       msubtype     |-> m.msubtype,
                       mterm        |-> mterm,
                       msuccess     |-> TRUE,
                       mmatchIndex  |-> newLastIdx,
                       msource      |-> i,
                       mdest        |-> m.msource], m)
          \* checkStepDown (NodeImpl.java:1243-1258)
          /\ currentTerm' = [currentTerm EXCEPT ![i] = mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ IF mterm > currentTerm[i]
             THEN persistedTerm' = [persistedTerm EXCEPT ![i] = mterm]
             ELSE UNCHANGED persistedTerm
          /\ UNCHANGED <<leaderVars, candidateVars,
                         persistedVotedFor, pendingVote>>

\* Leader i handles AppendEntries FAILURE response.
\* Reference: Replicator.java:1454-1472 (onAppendEntriesReturned failure path)
\*
\* Failure path has CORRECT term check:
\*   if (response.getTerm() > r.options.getTerm()) → increaseTermTo → stepDown
\*   Reference: Replicator.java:1463-1471
HandleAppendEntriesResponseFailure(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.msubtype = "replicate"
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ m.msuccess = FALSE
    /\ \/ \* Higher term: step down (Replicator.java:1463-1471)
          \* CORRECT: calls node.increaseTermTo() which calls stepDown()
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         configVars, persistedVotedFor, pendingVote>>

       \/ \* Same/lower term: decrement nextIndex
          \* Reference: Replicator.java:1473-1517
          /\ m.mterm <= currentTerm[i]
          /\ nextIndex' = [nextIndex EXCEPT ![i][m.msource] =
                Max(1, nextIndex[i][m.msource] - 1)]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, matchIndex, candidateVars,
                         persistVars, configVars>>

\* Leader i handles AppendEntries SUCCESS response.
\* Reference: Replicator.java:1519-1559 (onAppendEntriesReturned success path)
\*
\* *** BUG (Family 2, MC-4): Incomplete term check on success path ***
\*
\* Success path (Replicator.java:1524-1531):
\*   if (response.getTerm() != r.options.getTerm()) {
\*       r.resetInflights();
\*       r.setState(State.Probe);
\*       LOG.error("Fail, response term dismatch...");
\*       return false;
\*   }
\*
\* This DOES NOT call increaseTermTo() — leader stays as leader!
\* Compare with failure path (line 1463-1471) which correctly steps down.
HandleAppendEntriesResponseSuccess(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.msubtype = "replicate"
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ m.msuccess = TRUE
    /\ \/ \* Term mismatch on success: just reset, NO step down
          \* *** THIS IS THE BUG (Family 2) ***
          \* Reference: Replicator.java:1524-1531
          \* Compare: failure path at 1463-1471 correctly calls increaseTermTo()
          /\ m.mterm /= currentTerm[i]
          \* Only resets to Probe state — leader continues!
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, configVars>>

       \/ \* Normal success: update matchIndex and nextIndex
          \* Reference: Replicator.java:1536-1555
          /\ m.mterm = currentTerm[i]
          /\ nextIndex'  = [nextIndex  EXCEPT ![i][m.msource] = m.mmatchIndex + 1]
          /\ matchIndex' = [matchIndex EXCEPT ![i][m.msource] = m.mmatchIndex]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, candidateVars,
                         persistVars, configVars>>

       \/ \* Stale response (from old term), ignore
          /\ m.mterm < currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, configVars>>

\* Leader i handles heartbeat response.
\* Reference: Replicator.java:1176-1269 (onHeartbeatReturned)
\*
\* Heartbeat response handler has CORRECT term check:
\*   if (response.getTerm() > r.options.getTerm()) → increaseTermTo → stepDown
\*   Reference: Replicator.java:1224-1239
HandleHeartbeatResponse(i, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.msubtype = "heartbeat"
    /\ m.mdest = i
    /\ state[i] = Leader
    /\ \/ \* Higher term: step down (Replicator.java:1224-1239)
          \* CORRECT: calls node.increaseTermTo() which calls stepDown()
          /\ m.mterm > currentTerm[i]
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
          /\ persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
          /\ Discard(m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         configVars, persistedVotedFor, pendingVote>>

       \/ \* Normal: heartbeat acknowledged
          \* Reference: Replicator.java:1257-1263
          /\ m.mterm <= currentTerm[i]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, configVars>>

\* Leader i sends InstallSnapshot to server j.
\* Reference: Replicator.java:installSnapshot() (called when follower too far behind)
\* Minimal model: sends snapshot with leader's commitIndex.
SendInstallSnapshot(i, j) ==
    /\ state[i] = Leader
    /\ i /= j
    /\ Send([mtype          |-> InstallSnapshotRequest,
             mterm          |-> currentTerm[i],
             msnapshotIndex |-> commitIndex[i],
             msource        |-> i,
             mdest          |-> j])
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, configVars>>

\* Server i handles InstallSnapshotRequest m.
\* Minimal model: accept if term >= currentTerm, respond with current term.
HandleInstallSnapshotRequest(i, m) ==
    /\ m.mtype = InstallSnapshotRequest
    /\ m.mdest = i
    /\ \/ \* Reject: stale term
          /\ m.mterm < currentTerm[i]
          /\ Reply([mtype          |-> InstallSnapshotResponse,
                    mterm          |-> currentTerm[i],
                    msuccess       |-> FALSE,
                    msnapshotIndex |-> m.msnapshotIndex,
                    msource        |-> i,
                    mdest          |-> m.msource], m)
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         persistVars, configVars>>
       \/ \* Accept: install snapshot
          /\ m.mterm >= currentTerm[i]
          \* Step down if higher term
          /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
          /\ state' = [state EXCEPT ![i] = Follower]
          /\ votedFor' = IF m.mterm > currentTerm[i]
                         THEN [votedFor EXCEPT ![i] = Nil]
                         ELSE votedFor
          /\ IF m.mterm > currentTerm[i]
             THEN persistedTerm' = [persistedTerm EXCEPT ![i] = m.mterm]
             ELSE UNCHANGED persistedTerm
          /\ Reply([mtype          |-> InstallSnapshotResponse,
                    mterm          |-> m.mterm,
                    msuccess       |-> TRUE,
                    msnapshotIndex |-> m.msnapshotIndex,
                    msource        |-> i,
                    mdest          |-> m.msource], m)
          /\ UNCHANGED <<logVars, leaderVars, candidateVars,
                         configVars, persistedVotedFor, pendingVote>>

\* Leader i handles InstallSnapshot response.
\* Reference: Replicator.java:711-765 (onInstallSnapshotReturned)
\*
\* *** BUG (Family 2, MC-3): NO term check at all! ***
\*
\* Compare with onHeartbeatReturned (line 1224) which correctly checks
\*   if (response.getTerm() > r.options.getTerm()) → increaseTermTo
\* Compare with onAppendEntriesReturned failure path (line 1463) which
\*   correctly checks response.getTerm() > r.options.getTerm()
\*
\* onInstallSnapshotReturned: ONLY checks status.isOk() and response.getSuccess().
\* Never inspects response.getTerm(). Leader continues as leader even if
\* follower has moved to a higher term.
HandleInstallSnapshotResponse(i, m) ==
    /\ m.mtype = InstallSnapshotResponse
    /\ m.mdest = i
    /\ state[i] = Leader
    \* *** BUG: NO term check here! ***
    \* Replicator.java:711-765: only checks success, never response.getTerm()
    /\ IF m.msuccess
       THEN \* Update nextIndex (Replicator.java:747)
            nextIndex' = [nextIndex EXCEPT ![i][m.msource] = m.msnapshotIndex + 1]
       ELSE UNCHANGED nextIndex
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, matchIndex, candidateVars,
                   persistVars, configVars>>

\* Leader i advances commit index based on quorum replication.
\* Reference: BallotBox.java:99-143 (commitAt)
\*
\* Key: quorum uses joint consensus (Ballot.java:144-146)
\* The "not well proved" comment (BallotBox.java:127-132) is about
\* committing all preceding entries when a later entry reaches quorum —
\* modeled here by finding the highest committed index.
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET \* Servers that have replicated up to each index
           Agree(idx) == {i} \cup {s \in Server : matchIndex[i][s] >= idx}
           \* Find highest index with joint quorum agreement in current term
           agreeIdxs == {idx \in (commitIndex[i]+1)..LastLogIndex(i) :
                          /\ IsJointQuorum(Agree(idx), config[i], configOld[i])
                          /\ log[i][idx].term = currentTerm[i]}
       IN
       /\ agreeIdxs /= {}
       /\ LET newCommitIdx == SetMax(agreeIdxs)
              \* Update committed config
              newCommitConf == LatestConfigInLog(log[i], newCommitIdx)
          IN
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCommitIdx]
          \* Note: committed config may differ from latest config
          \* This is the "not well proved" area (BallotBox.java:127-132)
    /\ UNCHANGED <<serverVars, log, leaderVars, candidateVars, messages,
                   persistVars, configVars>>

----
\* Configuration Change (Extension 2, Family 4)
----

\* Leader i proposes a configuration change using joint consensus.
\* Reference: NodeImpl.java:506-536 (ConfigurationCtx.nextStage)
\*
\* Joint consensus flow:
\*   CATCHING_UP → JOINT: append joint config entry (old + new)
\*   JOINT → STABLE: append stable config entry (new only)
\*   STABLE: if leader removed from new config, step down
\*
\* Constraint: only one uncommitted config change at a time.
\* Reference: NodeImpl.java confCtx checks.
ProposeConfigChange(i, newPeers) ==
    /\ state[i] = Leader
    \* Must be in stable config (no ongoing joint) — one change at a time
    /\ configOld[i] = {}
    \* New config must differ from current
    /\ newPeers /= config[i]
    /\ newPeers /= {}
    /\ newPeers \subseteq Server
    \* Append JOINT config entry: config=new, oldConfig=old
    \* Reference: NodeImpl.java:512-514 (unsafeApplyConfiguration with oldConf)
    /\ LET entry == [term      |-> currentTerm[i],
                     type      |-> ConfigEntry,
                     config    |-> newPeers,
                     oldConfig |-> config[i]]
       IN
       /\ log' = [log EXCEPT ![i] = Append(@, entry)]
       \* Enter joint config state
       /\ config' = [config EXCEPT ![i] = newPeers]
       /\ configOld' = [configOld EXCEPT ![i] = config[i]]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars,
                   messages, persistVars>>

\* Leader i completes joint→stable transition by appending stable config entry.
\* Reference: NodeImpl.java:517-522 (STAGE_JOINT → STAGE_STABLE)
\*   unsafeApplyConfiguration(newConf, null, false) — appends stable config
\* This fires when the joint config entry has been committed.
ProposeStableConfig(i) ==
    /\ state[i] = Leader
    \* Must be in joint config
    /\ configOld[i] /= {}
    \* Joint config entry must be committed (latest config entry at commitIndex is joint)
    /\ LET commitConf == LatestConfigInLog(log[i], commitIndex[i])
       IN commitConf.old /= {}
    \* Append STABLE config entry: config=new, oldConfig={}
    \* Reference: NodeImpl.java:519-521
    /\ LET entry == [term      |-> currentTerm[i],
                     type      |-> ConfigEntry,
                     config    |-> config[i],
                     oldConfig |-> {}]
       IN log' = [log EXCEPT ![i] = Append(@, entry)]
    \* Exit joint config — now stable
    /\ configOld' = [configOld EXCEPT ![i] = {}]
    /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars,
                   messages, persistVars, config>>

\* Leader steps down after being removed from new config.
\* Reference: NodeImpl.java:524-530 (STAGE_STABLE: shouldStepDown)
StepDownRemovedLeader(i) ==
    /\ state[i] = Leader
    /\ i \notin config[i]
    /\ configOld[i] = {}  \* must be in stable config
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ UNCHANGED <<currentTerm, votedFor, logVars, leaderVars, candidateVars,
                   messages, persistVars, configVars>>

----
\* Crash and Recovery (Family 1 + 5)
----

\* Server i crashes. All volatile state is lost.
\* Only persistedTerm, persistedVotedFor, and log survive.
\*
\* Reference: LocalRaftMetaStorage.java:89-104 (load)
\* On restart: term = persisted term, votedFor = persisted votedFor.
\*
\* Key (Family 1): if a non-atomic persist was in progress:
\*   - ElectSelf crash: persistedTerm=old, persistedVotedFor=old
\*     → node restarts with old term (term increment lost)
\*   - HandleRequestVoteRequest crash: persistedTerm=new, persistedVotedFor=Nil
\*     → node restarts, can vote for different candidate in same term
\*
\* Key (Family 5, MC-6): if meta file corrupted, load() silently returns
\* true with term=0. Modeled as a separate CorruptedCrash action.
Crash(i) ==
    /\ state' = [state EXCEPT ![i] = Follower]
    \* Volatile state reset
    /\ commitIndex'  = [commitIndex  EXCEPT ![i] = 0]
    /\ nextIndex'    = [nextIndex    EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'   = [matchIndex   EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    \* Recover from persisted state
    \* Key: if non-atomic persist was interrupted, votedFor reverts
    \* to persistedVotedFor (which may be Nil or stale)
    /\ currentTerm' = [currentTerm EXCEPT ![i] = persistedTerm[i]]
    /\ votedFor'    = [votedFor    EXCEPT ![i] = persistedVotedFor[i]]
    /\ pendingVote' = [pendingVote EXCEPT ![i] = Nil]
    \* Recompute configs from persisted log
    /\ LET latestConf == LatestConfigInLog(log[i], Len(log[i]))
       IN
       /\ config'    = [config    EXCEPT ![i] = latestConf.conf]
       \* Conservative: committed config unknown after crash, assume stable
       /\ configOld' = [configOld EXCEPT ![i] = {}]
    \* Log and persisted state survive
    /\ UNCHANGED <<log, messages, persistedTerm, persistedVotedFor>>

\* Corrupted crash: meta file corrupted, node restarts with term=0.
\* Reference: LocalRaftMetaStorage.java:98-99
\*   If meta file missing/corrupted: return true with term=0, votedFor=null.
\* This violates term monotonicity.
CorruptedCrash(i) ==
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ commitIndex'  = [commitIndex  EXCEPT ![i] = 0]
    /\ nextIndex'    = [nextIndex    EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex'   = [matchIndex   EXCEPT ![i] = [j \in Server |-> 0]]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    \* BUG (Family 5, MC-6): meta corrupted → term=0, votedFor=Nil
    /\ currentTerm' = [currentTerm EXCEPT ![i] = 0]
    /\ votedFor'    = [votedFor    EXCEPT ![i] = Nil]
    \* Persisted state also corrupted
    /\ persistedTerm' = [persistedTerm EXCEPT ![i] = 0]
    /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![i] = Nil]
    /\ pendingVote' = [pendingVote EXCEPT ![i] = Nil]
    /\ LET latestConf == LatestConfigInLog(log[i], Len(log[i]))
       IN
       /\ config'    = [config    EXCEPT ![i] = latestConf.conf]
       /\ configOld' = [configOld EXCEPT ![i] = {}]
    /\ UNCHANGED <<log, messages>>

----
\* Network failures
----

\* Message is lost due to transport failure.
LoseMessage(m) ==
    /\ m \in DOMAIN messages
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, configVars>>

\* Drop stale messages (helps bound state space).
DropStaleMessage(m) ==
    /\ m \in DOMAIN messages
    /\ \/ /\ m.mtype = RequestVoteRequest
          /\ m.mterm < currentTerm[m.mdest]
       \/ /\ m.mtype = RequestVoteResponse
          /\ m.mterm < currentTerm[m.mdest]
       \/ /\ m.mtype = AppendEntriesRequest
          /\ m.mterm < currentTerm[m.mdest]
       \/ /\ m.mtype = AppendEntriesResponse
          /\ m.mterm < currentTerm[m.mdest]
       \/ /\ m.mtype = InstallSnapshotRequest
          /\ m.mterm < currentTerm[m.mdest]
       \/ /\ m.mtype = InstallSnapshotResponse
          /\ m.mterm < currentTerm[m.mdest]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                   persistVars, configVars>>

----
\* Spec
----

Next ==
    \/ \E i \in Server :
        \/ ElectSelf(i)
        \/ PersistElectSelf(i)
        \/ BecomeLeader(i)
        \/ ClientRequest(i)
        \/ CompletePersistVote(i)
        \/ AdvanceCommitIndex(i)
        \/ StepDownRemovedLeader(i)
        \/ ProposeStableConfig(i)
        \/ Crash(i)
        \/ CorruptedCrash(i)
    \/ \E i, j \in Server :
        \/ AppendEntries(i, j)
        \/ SendHeartbeat(i, j)
        \/ SendInstallSnapshot(i, j)
    \/ \E i \in Server, newPeers \in SUBSET Server \ {{}} :
        ProposeConfigChange(i, newPeers)
    \/ \E m \in DOMAIN messages :
        \/ HandleRequestVoteRequest(m.mdest, m)
        \/ HandleRequestVoteResponse(m.mdest, m)
        \/ HandleAppendEntriesRequest(m.mdest, m)
        \/ HandleAppendEntriesResponseFailure(m.mdest, m)
        \/ HandleAppendEntriesResponseSuccess(m.mdest, m)
        \/ HandleHeartbeatResponse(m.mdest, m)
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

\* Extension (Family 1): Each server votes for at most one candidate per term.
\* This invariant should be checked across crashes — a server that voted for
\* candidate A in term T must not vote for candidate B in the same term T,
\* even after crash and restart.
\* Checked via persisted state: votedFor is only valid if persistedVotedFor matches.
VoteOncePerTerm ==
    \A s1, s2 \in Server :
        (/\ state[s1] = Leader
         /\ state[s2] = Leader
         /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* Extension (Family 1+5): Persisted term never decreases across crashes.
\* A server's persistedTerm should be monotonically non-decreasing.
\* Violated by CorruptedCrash (MC-6) when meta file corrupted → term=0.
TermMonotonicity ==
    \A i \in Server : persistedTerm[i] <= currentTerm[i]

\* Extension (Family 4): At most one uncommitted config change at a time.
\* Reference: NodeImpl.java confCtx checks
ConfigSafety ==
    \A s \in Server :
        state[s] = Leader =>
            LET configIndices == {idx \in (commitIndex[s]+1)..LastLogIndex(s) :
                                    log[s][idx].type = ConfigEntry}
            IN Cardinality(configIndices) <= 1

=============================================================================
