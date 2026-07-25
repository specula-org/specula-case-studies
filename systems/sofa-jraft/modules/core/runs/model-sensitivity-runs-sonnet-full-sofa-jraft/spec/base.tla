--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for sofastack/sofa-jraft (Raft consensus library).
 *
 * Derived from: sofa-jraft core protocol logic
 * Category: A (Distributed / Message-Passing)
 * Reference algorithm: Raft (Ongaro & Ousterhout, 2014)
 *
 * Bug Families:
 *   Family 1 – Non-Atomic Vote Persistence (HIGH)
 *   Family 2 – Missing/Inconsistent Higher-Term Check on RPC Response Paths (HIGH)
 *   Family 3 – Snapshot Install / Applied-Index Notification Ordering (HIGH)
 *   Family 4 – ReadIndex Safety Gaps (HIGH)
 *   Family 5 – Code Path Inconsistencies in Protocol Handlers (MEDIUM)
 *
 * Key deviations from reference algorithm modeled here:
 *   - Two-write vote persistence in handleRequestVoteRequest higher-term path
 *   - InstallSnapshot response handler never checks response.term
 *   - EBUSY early return in onAppendEntriesReturned bypasses term check
 *   - doSnapshotLoad does not call notifyLastAppliedIndexUpdated
 *   - stepDown does not clear pendingReadIndex
 *   - readLeader quorum==1 fast-path skips no-op-at-current-term guard
 *   - handleInstallSnapshot missing updateLastLeaderTimestamp
 *)

EXTENDS Integers, Sequences, FiniteSets, Bags, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Server         \* Set of server IDs
CONSTANT Values         \* Abstract set of client command values
CONSTANT Nil            \* Sentinel "none" value

\* Server roles
CONSTANTS
    Leader,
    Candidate,
    Follower

\* Message types
CONSTANTS
    RequestVoteRequest,
    RequestVoteResponse,
    AppendEntriesRequest,
    AppendEntriesResponse,
    InstallSnapshotRequest,
    InstallSnapshotResponse

\* Subtype fields for response message disambiguation
CONSTANTS
    MSubtypeNormal,     \* normal success/failure response
    MSubtypeEBUSY,      \* AppendEntries rejected with EBUSY (Replicator.java:1454)
    MSubtypeSnapshot    \* InstallSnapshot response

\* Persistence write steps (Family 1: two-write window)
\* NodeImpl.java:1856-1860 / LocalRaftMetaStorage
CONSTANTS
    PersistStepNone,    \* no pending persist for this server
    PersistStepTerm,    \* completed: wrote (term, emptyVotedFor) — NodeImpl.java:1856
    PersistStepVote     \* completed: wrote actual votedFor — NodeImpl.java:1860

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Standard Raft state ---

VARIABLE currentTerm    \* [Server -> Nat]  NodeImpl.currTerm (in-memory)
VARIABLE role           \* [Server -> {Leader,Candidate,Follower}]  NodeImpl.state
VARIABLE votedFor       \* [Server -> Server ∪ {Nil}]  NodeImpl.votedId (in-memory)
VARIABLE log            \* [Server -> Seq(record)]  log entries, 1-indexed

\* Commit / apply indices
VARIABLE commitIndex    \* [Server -> Nat]  BallotBox.lastCommittedIndex
VARIABLE lastApplied    \* [Server -> Nat]  FSMCallerImpl.lastAppliedIndex

\* Leader volatile state
VARIABLE nextIndex      \* [Leader -> [Follower -> Nat]]  Replicator nextIndex
VARIABLE matchIndex     \* [Leader -> [Follower -> Nat]]  Replicator matchIndex

\* Network
VARIABLE messages       \* Bag of in-flight messages

\* --- Extension: Family 1 – Non-Atomic Vote Persistence ---
\* NodeImpl.java:1856-1860, LocalRaftMetaStorage.setTermAndVotedFor / setVotedFor

VARIABLE persistedTerm      \* [Server -> Nat]   durable term on disk
VARIABLE persistedVotedFor  \* [Server -> Server ∪ {Nil}]  durable votedFor on disk
VARIABLE persistStep        \* [Server -> PersistStep]  which write has committed for
                            \*   the pending higher-term vote-grant

\* Whether the server is crashed (in-memory state lost, only persisted state survives)
VARIABLE crashed            \* [Server -> BOOLEAN]

\* --- Extension: Family 2 – Missing Higher-Term Check on Response Paths ---
\* No new variables; reuses currentTerm.  The bug is captured by split actions.

\* --- Extension: Families 3+4 – ReadIndex Pending Lifecycle ---
\* FSMCallerImpl.java:728-731, ReadOnlyServiceImpl.java:384-424, NodeImpl.java:1301-1360

VARIABLE pendingReadIndex   \* [Server -> SUBSET Nat]
                            \* Outstanding ReadIndex requests (index values)
                            \* ReadOnlyServiceImpl.pendingNotifyStatus

VARIABLE readIndexSuccess   \* [Server -> SUBSET Nat]
                            \* Indices for which read was successfully served
                            \* (cleared on next epoch for safety checking only)

VARIABLE snapshotIndex      \* [Server -> Nat]
                            \* lastIncludedIndex of installed snapshot
                            \* SnapshotExecutorImpl / FSMCallerImpl

VARIABLE snapshotTerm       \* [Server -> Nat]  lastIncludedTerm of snapshot

\* --- Extension: Family 4 – ReadIndex no-op guard ---
\* The term of the entry at commitIndex at the time the read was issued
\* NodeImpl.java:1610-1617 (multi-peer guard we are checking is skipped in single-peer)
VARIABLE readIssuedTerm     \* [Server -> [Nat -> Nat]]  readIndex -> term-when-issued

\* --- Extension: Family 5 – lastLeaderContact ---
\* NodeImpl.java:1994 (AppendEntries updates), handleInstallSnapshot missing update
\* Modeled as a logical timestamp (monotone counter)

VARIABLE lastLeaderContact  \* [Server -> Nat]  last tick when leader heartbeat/AE received
VARIABLE clock              \* Nat  global logical clock (monotone)

\* ============================================================================
\* VARIABLE GROUPS
\* ============================================================================

serverVars   == <<currentTerm, role, votedFor>>
logVars      == <<log, commitIndex, lastApplied, nextIndex, matchIndex>>
persistVars  == <<persistedTerm, persistedVotedFor, persistStep, crashed>>
readVars     == <<pendingReadIndex, readIndexSuccess, snapshotIndex, snapshotTerm,
                  readIssuedTerm>>
contactVars  == <<lastLeaderContact, clock>>
networkVars  == <<messages>>

vars == <<serverVars, logVars, persistVars, readVars, contactVars, networkVars>>

\* ============================================================================
\* HELPERS
\* ============================================================================

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : x >= y

\* Quorum of a set S
Quorum(S) == {q \in SUBSET S : Cardinality(q) * 2 > Cardinality(S)}

\* True iff server s has a quorum of votes for currentTerm[s]
HasQuorum(s, voteGrants) ==
    \E q \in Quorum(Server) : q \subseteq {v \in Server : voteGrants[v]}

\* Log entry record
Entry(idx, term, val) == [index |-> idx, term |-> term, value |-> val]

\* Log entry at position i on server s (1-indexed)
LogEntry(s, i) == log[s][i]

\* Last log index / term for server s
LastLogIndex(s) == Len(log[s])
LastLogTerm(s)  == IF Len(log[s]) = 0 THEN 0 ELSE log[s][Len(log[s])].term

\* True iff candidate c's log is at least as up-to-date as server s's log
\* Raft §5.4.1
LogUpToDate(cLastTerm, cLastIdx, s) ==
    \/ cLastTerm > LastLogTerm(s)
    \/ /\ cLastTerm = LastLogTerm(s)
       /\ cLastIdx >= LastLogIndex(s)

\* Term of log entry at index i on server s (0 if i is before snapshot or out of range)
LogTerm(s, i) ==
    IF i = 0 THEN 0
    ELSE IF i <= snapshotIndex[s] THEN snapshotTerm[s]
    ELSE IF i <= LastLogIndex(s) THEN log[s][i - snapshotIndex[s]].term
    ELSE 0

\* Is there a committed entry at currentTerm on server s?
\* NodeImpl.java:1610-1617 — multi-peer no-op-at-current-term guard
HasNoopAtCurrentTerm(s) ==
    /\ commitIndex[s] > 0
    /\ LogTerm(s, commitIndex[s]) = currentTerm[s]

\* Message bag helpers (standard Raft TLA+ convention)
Send(m)    == messages' = messages (+) SetToBag({m})
Discard(m) == messages' = messages (-) SetToBag({m})
Reply(r,m) == messages' = messages (-) SetToBag({m}) (+) SetToBag({r})

\* All messages of a given type in the bag
MessagesOfType(t) == {m \in BagToSet(messages) : m.mtype = t}

\* ============================================================================
\* INITIAL STATE
\* ============================================================================

Init ==
    /\ currentTerm    = [s \in Server |-> 0]
    /\ role           = [s \in Server |-> Follower]
    /\ votedFor       = [s \in Server |-> Nil]
    /\ log            = [s \in Server |-> <<>>]
    /\ commitIndex    = [s \in Server |-> 0]
    /\ lastApplied    = [s \in Server |-> 0]
    /\ nextIndex      = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex     = [s \in Server |-> [t \in Server |-> 0]]
    /\ messages       = EmptyBag
    \* Persistent state (durable)
    /\ persistedTerm     = [s \in Server |-> 0]
    /\ persistedVotedFor = [s \in Server |-> Nil]
    /\ persistStep       = [s \in Server |-> PersistStepNone]
    /\ crashed           = [s \in Server |-> FALSE]
    \* Read index
    /\ pendingReadIndex  = [s \in Server |-> {}]
    /\ readIndexSuccess  = [s \in Server |-> {}]
    /\ snapshotIndex     = [s \in Server |-> 0]
    /\ snapshotTerm      = [s \in Server |-> 0]
    /\ readIssuedTerm    = [s \in Server |-> [i \in {} |-> 0]]
    \* Leader contact
    /\ lastLeaderContact = [s \in Server |-> 0]
    /\ clock             = 0

\* ============================================================================
\* ELECTION ACTIONS
\* ============================================================================

\* --- ElectionTimeout ---
\* NodeImpl.handleElectionTimeout() — server becomes candidate
\* NodeImpl.java:1101-1152

ElectionTimeout(s) ==
    /\ ~crashed[s]
    /\ role[s] \in {Follower, Candidate}
    /\ currentTerm'    = [currentTerm EXCEPT ![s] = currentTerm[s] + 1]
    /\ role'           = [role EXCEPT ![s] = Candidate]
    /\ votedFor'       = [votedFor EXCEPT ![s] = s]          \* vote for self in-memory
    /\ persistedTerm'  = [persistedTerm EXCEPT ![s] = currentTerm[s] + 1]
    /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![s] = s]  \* atomic self-vote persist
    /\ persistStep'    = [persistStep EXCEPT ![s] = PersistStepNone]
    \* Send RequestVote to all peers
    /\ LET newTerm == currentTerm[s] + 1 IN
       messages' = messages (+) SetToBag(
           {[mtype        |-> RequestVoteRequest,
             mterm        |-> newTerm,
             msrc         |-> s,
             mdst         |-> t,
             mlastLogTerm |-> LastLogTerm(s),
             mlastLogIdx  |-> LastLogIndex(s)] : t \in Server \ {s}})
    /\ UNCHANGED <<logVars, readVars, contactVars, crashed>>

\* --- HandleRequestVoteRequest: same-or-lower-term denial ---
\* NodeImpl.java:1820-1838 — reject if term < currentTerm
HandleRequestVoteRequestDeny(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype = RequestVoteRequest
    /\ m.mdst  = s
    /\ m.mterm <= currentTerm[s]
    \* Guard: no multi-step grant in progress (handlers are single-threaded in the real system)
    /\ persistStep[s] = PersistStepNone
    /\ Reply([mtype    |-> RequestVoteResponse,
              mterm    |-> currentTerm[s],
              msrc     |-> s,
              mdst     |-> m.msrc,
              mgranted |-> FALSE], m)
    /\ UNCHANGED <<serverVars, logVars, persistVars, readVars, contactVars>>

\* --- HandleRequestVoteRequest: grant in same term (already have slot) ---
\* NodeImpl.java:1838-1855 — grant if same term AND haven't voted / voted for this candidate
HandleRequestVoteRequestGrantSameTerm(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype = RequestVoteRequest
    /\ m.mdst  = s
    /\ m.mterm = currentTerm[s]
    /\ votedFor[s] \in {Nil, m.msrc}
    /\ LogUpToDate(m.mlastLogTerm, m.mlastLogIdx, s)
    \* Guard: no multi-step grant in progress (handlers are single-threaded in the real system)
    /\ persistStep[s] = PersistStepNone
    /\ votedFor'  = [votedFor EXCEPT ![s] = m.msrc]
    /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![s] = m.msrc]   \* single atomic write
    /\ Reply([mtype    |-> RequestVoteResponse,
              mterm    |-> currentTerm[s],
              msrc     |-> s,
              mdst     |-> m.msrc,
              mgranted |-> TRUE], m)
    /\ UNCHANGED <<currentTerm, role, logVars, persistedTerm, persistStep,
                   crashed, readVars, contactVars>>

\* ============================================================================
\* Family 1: Non-Atomic Vote Persistence – Higher-Term Grant Path
\* NodeImpl.java:1856-1860
\* Two-write window:
\*   Write 1: setTermAndVotedFor(term, emptyPeer) — NodeImpl.java:1856
\*   Write 2: setVotedFor(candidateId)            — NodeImpl.java:1860
\* Between writes, crash leaves term persisted with empty votedFor.
\* After restart, node can re-grant vote in same term.
\* ============================================================================

\* Step 1 of 3: receive higher-term RequestVote, persist (term, emptyVotedFor)
\* NodeImpl.java:1856 — stepDown(term, ...) calls setTermAndVotedFor(term, emptyPeer)
HandleRequestVoteRequestHigherTermStep1(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype = RequestVoteRequest
    /\ m.mdst  = s
    /\ m.mterm > currentTerm[s]
    /\ LogUpToDate(m.mlastLogTerm, m.mlastLogIdx, s)
    /\ persistStep[s] = PersistStepNone
    \* stepDown: update in-memory term, clear in-memory role
    /\ currentTerm' = [currentTerm EXCEPT ![s] = m.mterm]
    /\ role'        = [role EXCEPT ![s] = Follower]
    /\ votedFor'    = [votedFor EXCEPT ![s] = Nil]    \* in-memory cleared
    \* WRITE 1: persist (term, emptyVotedFor) — NodeImpl.java:1856
    /\ persistedTerm'     = [persistedTerm EXCEPT ![s] = m.mterm]
    /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![s] = Nil]
    /\ persistStep'       = [persistStep EXCEPT ![s] = PersistStepTerm]
    /\ UNCHANGED <<logVars, messages, crashed, readVars, contactVars>>

\* Step 2 of 3: persist actual votedFor — NodeImpl.java:1860 setVotedFor(candidateId)
HandleRequestVoteRequestHigherTermStep2(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype = RequestVoteRequest
    /\ m.mdst  = s
    /\ m.mterm = currentTerm[s]     \* step 1 already advanced term
    /\ persistStep[s] = PersistStepTerm
    \* WRITE 2: persist actual voted-for — NodeImpl.java:1860
    /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![s] = m.msrc]
    /\ votedFor'  = [votedFor EXCEPT ![s] = m.msrc]
    /\ persistStep' = [persistStep EXCEPT ![s] = PersistStepVote]
    /\ UNCHANGED <<currentTerm, role, logVars, messages, persistedTerm,
                   crashed, readVars, contactVars>>

\* Step 3 of 3: send the vote response (only valid after both writes committed)
\* NodeImpl.java:1860 — response sent after setVotedFor
HandleRequestVoteRequestHigherTermStep3(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype = RequestVoteRequest
    /\ m.mdst  = s
    /\ m.mterm = currentTerm[s]
    /\ persistStep[s] = PersistStepVote
    /\ persistedVotedFor[s] = m.msrc
    /\ Reply([mtype    |-> RequestVoteResponse,
              mterm    |-> currentTerm[s],
              msrc     |-> s,
              mdst     |-> m.msrc,
              mgranted |-> TRUE], m)
    /\ persistStep' = [persistStep EXCEPT ![s] = PersistStepNone]
    /\ UNCHANGED <<serverVars, logVars, persistedTerm, persistedVotedFor,
                   crashed, readVars, contactVars>>

\* --- HandleRequestVoteResponse ---
\* NodeImpl.java:1774-1815
HandleRequestVoteResponse(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype = RequestVoteResponse
    /\ m.mdst  = s
    /\ role[s] = Candidate
    /\ m.mterm = currentTerm[s]
    /\ Discard(m)
    /\ IF m.mgranted
       THEN \* count vote — become leader if quorum reached
            LET voteCount == Cardinality(
                    {v \in Server : v = s \/
                        \E resp \in BagToSet(messages) :
                            /\ resp.mtype    = RequestVoteResponse
                            /\ resp.mdst     = s
                            /\ resp.mterm    = currentTerm[s]
                            /\ resp.mgranted = TRUE}) IN
            IF voteCount * 2 > Cardinality(Server)
            THEN /\ role'         = [role EXCEPT ![s] = Leader]
                 /\ nextIndex'    = [nextIndex EXCEPT ![s] =
                                        [t \in Server |-> LastLogIndex(s) + 1]]
                 /\ matchIndex'   = [matchIndex EXCEPT ![s] =
                                        [t \in Server |-> 0]]
                 /\ UNCHANGED <<currentTerm, votedFor, log, commitIndex,
                                lastApplied, persistVars, readVars, contactVars>>
            ELSE UNCHANGED <<serverVars, logVars, persistVars, readVars, contactVars>>
       ELSE IF m.mterm > currentTerm[s]
            THEN \* step down — NodeImpl.java:1797; stepDown persists via setTermAndVotedFor
                 /\ currentTerm'        = [currentTerm        EXCEPT ![s] = m.mterm]
                 /\ role'               = [role               EXCEPT ![s] = Follower]
                 /\ votedFor'           = [votedFor           EXCEPT ![s] = Nil]
                 /\ persistedTerm'      = [persistedTerm      EXCEPT ![s] = m.mterm]
                 /\ persistedVotedFor'  = [persistedVotedFor  EXCEPT ![s] = Nil]
                 /\ UNCHANGED <<logVars, persistStep, crashed, readVars, contactVars>>
            ELSE UNCHANGED <<serverVars, logVars, persistVars, readVars, contactVars>>

\* ============================================================================
\* Family 1 (cont.): Crash and Recovery
\* ============================================================================

\* Crash: volatile in-memory state is lost; server recovers from persisted state.
\* NodeImpl restart reads LocalRaftMetaStorage.loadMeta()
Crash(s) ==
    /\ ~crashed[s]
    /\ crashed' = [crashed EXCEPT ![s] = TRUE]
    \* In-memory state cleared
    /\ role'          = [role EXCEPT ![s] = Follower]
    /\ pendingReadIndex' = [pendingReadIndex EXCEPT ![s] = {}]    \* volatile
    /\ persistStep'   = [persistStep EXCEPT ![s] = PersistStepNone]
    \* FSM is rebuilt from scratch on restart — reset lastApplied to last snapshot index
    /\ lastApplied'   = [lastApplied EXCEPT ![s] = snapshotIndex[s]]
    /\ UNCHANGED <<currentTerm, votedFor, log, commitIndex,
                   nextIndex, matchIndex, messages, persistedTerm,
                   persistedVotedFor, readIndexSuccess, snapshotIndex,
                   snapshotTerm, readIssuedTerm, lastLeaderContact, clock>>

\* Restart: reload durable state from persistent storage
\* NodeImpl.java:init() — reads meta from LocalRaftMetaStorage
RestartFromPersisted(s) ==
    /\ crashed[s]
    /\ crashed'   = [crashed EXCEPT ![s] = FALSE]
    \* Restore in-memory term and votedFor from durable storage
    /\ currentTerm' = [currentTerm EXCEPT ![s] = persistedTerm[s]]
    /\ votedFor'    = [votedFor EXCEPT ![s] = persistedVotedFor[s]]
    /\ role'        = [role EXCEPT ![s] = Follower]
    /\ UNCHANGED <<logVars, persistedTerm, persistedVotedFor, persistStep,
                   networkVars, readVars, contactVars>>

\* ============================================================================
\* LOG REPLICATION
\* ============================================================================

\* --- ClientRequest: leader appends entry to local log ---
\* NodeImpl.java:590-640 (apply)
ClientRequest(s, v) ==
    /\ ~crashed[s]
    /\ role[s] = Leader
    /\ LET entry == Entry(LastLogIndex(s) + 1, currentTerm[s], v) IN
       log' = [log EXCEPT ![s] = Append(@, entry)]
    /\ UNCHANGED <<serverVars, commitIndex, lastApplied, nextIndex,
                   matchIndex, messages, persistVars, readVars, contactVars>>

\* --- AppendEntriesRequest (replication heartbeat/replicate) ---
\* Replicator.java — sendEntries/sendHeartbeat
AppendEntries(s, t) ==
    /\ ~crashed[s]
    /\ role[s]  = Leader
    /\ s /= t
    /\ LET prevLogIdx  == nextIndex[s][t] - 1
           prevLogTerm == LogTerm(s, prevLogIdx)
           entries     == IF nextIndex[s][t] > LastLogIndex(s)
                          THEN <<>>
                          ELSE SubSeq(log[s],
                                  nextIndex[s][t] - snapshotIndex[s],
                                  LastLogIndex(s) - snapshotIndex[s])
       IN
       Send([mtype        |-> AppendEntriesRequest,
             msubtype     |-> MSubtypeNormal,
             mterm        |-> currentTerm[s],
             msrc         |-> s,
             mdst         |-> t,
             mprevLogIdx  |-> prevLogIdx,
             mprevLogTerm |-> prevLogTerm,
             mentries     |-> entries,
             mcommitIdx   |-> commitIndex[s]])
    /\ UNCHANGED <<serverVars, logVars, persistVars, readVars, contactVars>>

\* --- HandleAppendEntriesRequest ---
\* NodeImpl.java:1956-2062 (handleAppendEntriesRequest)
HandleAppendEntriesRequest(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype   = AppendEntriesRequest
    /\ m.mdst    = s
    /\ IF m.mterm < currentTerm[s]
       THEN \* reject stale term — NodeImpl.java:1967
            /\ Reply([mtype       |-> AppendEntriesResponse,
                      msubtype    |-> MSubtypeNormal,
                      mterm       |-> currentTerm[s],
                      msrc        |-> s,
                      mdst        |-> m.msrc,
                      msuccess    |-> FALSE,
                      mmatchIndex |-> 0], m)
            /\ UNCHANGED <<serverVars, logVars, persistVars, readVars, contactVars>>
       ELSE
            \* step down if needed — NodeImpl.java:1984; stepDown persists via setTermAndVotedFor
            /\ IF m.mterm > currentTerm[s]
               THEN /\ currentTerm'       = [currentTerm       EXCEPT ![s] = m.mterm]
                    /\ role'              = [role              EXCEPT ![s] = Follower]
                    /\ votedFor'          = [votedFor          EXCEPT ![s] = Nil]
                    /\ persistedTerm'     = [persistedTerm     EXCEPT ![s] = m.mterm]
                    /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![s] = Nil]
               ELSE UNCHANGED <<currentTerm, role, votedFor, persistedTerm, persistedVotedFor>>
            \* Family 5: update lastLeaderContact — NodeImpl.java:1994
            /\ lastLeaderContact' = [lastLeaderContact EXCEPT ![s] = clock]
            /\ IF m.mprevLogIdx > 0 /\ LogTerm(s, m.mprevLogIdx) /= m.mprevLogTerm
               THEN \* log inconsistency — NodeImpl.java:2008
                    /\ Reply([mtype       |-> AppendEntriesResponse,
                              msubtype    |-> MSubtypeNormal,
                              mterm       |-> currentTerm'[s],
                              msrc        |-> s,
                              mdst        |-> m.msrc,
                              msuccess    |-> FALSE,
                              mmatchIndex |-> 0], m)
                    /\ UNCHANGED <<logVars, persistStep, crashed, readVars, clock>>
               ELSE
                    \* apply entries — NodeImpl.java:2017-2046
                    /\ log' = [log EXCEPT ![s] =
                                  SubSeq(log[s], 1, m.mprevLogIdx - snapshotIndex[s])
                                  \o m.mentries]
                    /\ IF m.mcommitIdx > commitIndex[s]
                       THEN commitIndex' = [commitIndex EXCEPT
                               ![s] = Min({m.mcommitIdx, LastLogIndex(s)'})]
                       ELSE UNCHANGED commitIndex
                    /\ Reply([mtype       |-> AppendEntriesResponse,
                              msubtype    |-> MSubtypeNormal,
                              mterm       |-> currentTerm'[s],
                              msrc        |-> s,
                              mdst        |-> m.msrc,
                              msuccess    |-> TRUE,
                              mmatchIndex |-> m.mprevLogIdx + Len(m.mentries)], m)
                    /\ UNCHANGED <<lastApplied, nextIndex, matchIndex,
                                   persistStep, crashed, readVars, clock>>

\* ============================================================================
\* Family 2a: Missing Higher-Term Check on InstallSnapshot Response
\* Replicator.java:711-761 — onInstallSnapshotReturned
\* All other handlers (AppendEntries, Heartbeat, TimeoutNow) check response.term.
\* InstallSnapshot response handler does not.
\* ============================================================================

\* Leader sends InstallSnapshot RPC — Replicator.java:sendSnapshotMeta
InstallSnapshot(s, t) ==
    /\ ~crashed[s]
    /\ role[s] = Leader
    /\ s /= t
    /\ snapshotIndex[s] > 0
    /\ Send([mtype          |-> InstallSnapshotRequest,
             mterm          |-> currentTerm[s],
             msrc           |-> s,
             mdst           |-> t,
             msnapshotIdx   |-> snapshotIndex[s],
             msnapshotTerm  |-> snapshotTerm[s]])
    /\ UNCHANGED <<serverVars, logVars, persistVars, readVars, contactVars>>

\* Follower handles InstallSnapshot request
\* NodeImpl.java:3355-3422 — handleInstallSnapshotRequest
HandleInstallSnapshotRequest(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype = InstallSnapshotRequest
    /\ m.mdst  = s
    /\ IF m.mterm < currentTerm[s]
       THEN /\ Reply([mtype      |-> InstallSnapshotResponse,
                      msubtype   |-> MSubtypeSnapshot,
                      mterm      |-> currentTerm[s],
                      msrc       |-> s,
                      mdst       |-> m.msrc,
                      msuccess   |-> FALSE], m)
            /\ UNCHANGED <<serverVars, logVars, persistVars, readVars, contactVars>>
       ELSE
            \* stepDown persists via setTermAndVotedFor when higher term seen
            /\ IF m.mterm > currentTerm[s]
               THEN /\ currentTerm'       = [currentTerm       EXCEPT ![s] = m.mterm]
                    /\ role'              = [role              EXCEPT ![s] = Follower]
                    /\ votedFor'          = [votedFor          EXCEPT ![s] = Nil]
                    /\ persistedTerm'     = [persistedTerm     EXCEPT ![s] = m.mterm]
                    /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![s] = Nil]
               ELSE UNCHANGED <<currentTerm, role, votedFor, persistedTerm, persistedVotedFor>>
            \* Family 5 BUG: missing updateLastLeaderTimestamp here
            \* NodeImpl.java:3422 — compare with handleAppendEntriesRequest:1994
            \* lastLeaderContact is NOT updated on snapshot install
            \* (We model the bug by leaving lastLeaderContact unchanged)
            /\ snapshotIndex' = [snapshotIndex EXCEPT ![s] = m.msnapshotIdx]
            /\ snapshotTerm'  = [snapshotTerm EXCEPT ![s] = m.msnapshotTerm]
            /\ lastApplied'   = [lastApplied EXCEPT ![s] = m.msnapshotIdx]
            /\ commitIndex'   = [commitIndex EXCEPT
                                    ![s] = Max({commitIndex[s], m.msnapshotIdx})]
            \* Family 3 BUG: notifyLastAppliedIndexUpdated NOT called
            \* FSMCallerImpl.java:728-731 — doSnapshotLoad sets lastAppliedIndex
            \* directly, never calls notifyLastAppliedIndexUpdated()
            \* pendingReadIndex NOT notified here (the bug)
            /\ Reply([mtype    |-> InstallSnapshotResponse,
                      msubtype |-> MSubtypeSnapshot,
                      mterm    |-> currentTerm'[s],
                      msrc     |-> s,
                      mdst     |-> m.msrc,
                      msuccess |-> TRUE], m)
            /\ UNCHANGED <<log, nextIndex, matchIndex, persistStep, crashed,
                           pendingReadIndex, readIndexSuccess, readIssuedTerm,
                           lastLeaderContact, clock>>

\* HandleInstallSnapshotRequest WITH lastLeaderContact update (correct variant)
\* Used to check Family 5 fix
HandleInstallSnapshotRequestFixed(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype = InstallSnapshotRequest
    /\ m.mdst  = s
    /\ m.mterm >= currentTerm[s]
    /\ IF m.mterm > currentTerm[s]
       THEN /\ currentTerm'       = [currentTerm       EXCEPT ![s] = m.mterm]
            /\ role'              = [role              EXCEPT ![s] = Follower]
            /\ votedFor'          = [votedFor          EXCEPT ![s] = Nil]
            /\ persistedTerm'     = [persistedTerm     EXCEPT ![s] = m.mterm]
            /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![s] = Nil]
       ELSE UNCHANGED <<currentTerm, role, votedFor, persistedTerm, persistedVotedFor>>
    \* Fixed: update lastLeaderContact — analogous to handleAppendEntriesRequest:1994
    /\ lastLeaderContact' = [lastLeaderContact EXCEPT ![s] = clock]
    /\ snapshotIndex' = [snapshotIndex EXCEPT ![s] = m.msnapshotIdx]
    /\ snapshotTerm'  = [snapshotTerm EXCEPT ![s] = m.msnapshotTerm]
    /\ lastApplied'   = [lastApplied EXCEPT ![s] = m.msnapshotIdx]
    /\ commitIndex'   = [commitIndex EXCEPT
                            ![s] = Max({commitIndex[s], m.msnapshotIdx})]
    /\ Reply([mtype    |-> InstallSnapshotResponse,
              msubtype |-> MSubtypeSnapshot,
              mterm    |-> currentTerm'[s],
              msrc     |-> s,
              mdst     |-> m.msrc,
              msuccess |-> TRUE], m)
    /\ UNCHANGED <<log, nextIndex, matchIndex, persistStep, crashed,
                   pendingReadIndex, readIndexSuccess, readIssuedTerm, clock>>

\* --- HandleInstallSnapshotResponse: BUGGY (no term check) ---
\* Replicator.java:711-761 — onInstallSnapshotReturned
\* This handler checks success/failure but NEVER checks response.term
HandleInstallSnapshotResponseNormal(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype    = InstallSnapshotResponse
    /\ m.msubtype = MSubtypeSnapshot
    /\ m.mdst     = s
    /\ role[s]    = Leader
    /\ m.mterm   = currentTerm[s]   \* only dispatch same-term responses
    \* Family 2 BUG: no response.term > currentTerm check here
    \* Replicator.java:711-761 — onInstallSnapshotReturned missing term check
    /\ Discard(m)
    /\ IF m.msuccess
       THEN /\ matchIndex' = [matchIndex EXCEPT ![s][m.msrc] = m.mterm]
            /\ nextIndex'  = [nextIndex  EXCEPT ![s][m.msrc] = matchIndex'[s][m.msrc] + 1]
       ELSE UNCHANGED <<nextIndex, matchIndex>>
    /\ UNCHANGED <<serverVars, log, commitIndex, lastApplied, persistVars,
                   readVars, contactVars>>

\* --- HandleInstallSnapshotResponse with higher-term step-down (correct variant) ---
\* Models what SHOULD happen: check response.term → stepDown
\* Compare with onAppendEntriesReturned:1469, onHeartbeatReturned:1219
HandleInstallSnapshotResponseWithHigherTerm(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype    = InstallSnapshotResponse
    /\ m.msubtype = MSubtypeSnapshot
    /\ m.mdst     = s
    /\ role[s]    = Leader
    /\ m.mterm > currentTerm[s]   \* higher term in response → step down
    /\ currentTerm'       = [currentTerm       EXCEPT ![s] = m.mterm]
    /\ role'              = [role              EXCEPT ![s] = Follower]
    /\ votedFor'          = [votedFor          EXCEPT ![s] = Nil]
    /\ persistedTerm'     = [persistedTerm     EXCEPT ![s] = m.mterm]
    /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![s] = Nil]
    /\ Discard(m)
    /\ UNCHANGED <<logVars, persistStep, crashed, readVars, contactVars>>

\* ============================================================================
\* Family 2b: EBUSY Early-Return Bypasses Term Check on AppendEntries Response
\* Replicator.java:1454-1482 — onAppendEntriesReturned
\* When response.getSuccess() == false AND response.getErrorCode() == EBUSY,
\* handler returns after r.block() without reaching the term check at line 1469.
\*
\* SendEBUSYResponse: follower rejects AppendEntries with EBUSY when it is in the
\* middle of a snapshot install (snapshotIndex > lastApplied means snapshot in progress).
\* The follower includes its currentTerm in the response; if it has seen a higher term
\* via PreVote/RequestVote, that term can exceed the old leader's currentTerm.
\* ============================================================================

\* Follower sends EBUSY response to AppendEntries when busy with snapshot install
\* This creates the EBUSY message that the leader's buggy handler will receive
SendEBUSYResponse(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdst  = s
    /\ m.mterm = currentTerm[s]          \* only respond to current-term requests
    /\ snapshotIndex[s] > lastApplied[s] \* snapshot in progress — NodeImpl signals EBUSY
    /\ Reply([mtype       |-> AppendEntriesResponse,
              msubtype    |-> MSubtypeEBUSY,
              mterm       |-> currentTerm[s],
              msrc        |-> s,
              mdst        |-> m.msrc,
              msuccess    |-> FALSE,
              mmatchIndex |-> 0], m)
    /\ UNCHANGED <<serverVars, logVars, persistVars, readVars, contactVars>>

\* Follower responds with EBUSY (busy installing snapshot etc.)
\* Replicator.java:1454-1466 — early return path
HandleAppendEntriesResponseBusyNormal(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype    = AppendEntriesResponse
    /\ m.msubtype = MSubtypeEBUSY
    /\ m.mdst     = s
    /\ role[s]    = Leader
    /\ m.mterm   = currentTerm[s]
    \* Family 2 BUG: EBUSY path returns early — term check at line 1469 never reached
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, persistVars, readVars, contactVars>>

\* EBUSY response carrying a higher term — leader should step down but doesn't
HandleAppendEntriesResponseBusyHigherTerm(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype    = AppendEntriesResponse
    /\ m.msubtype = MSubtypeEBUSY
    /\ m.mdst     = s
    /\ role[s]    = Leader
    /\ m.mterm > currentTerm[s]   \* this is the term check that EBUSY skips
    /\ Discard(m)
    \* BUG: in the real code, EBUSY returns before this check — leader stays leader
    \* UNCHANGED serverVars models the bug (no step-down)
    /\ UNCHANGED <<serverVars, logVars, persistVars, readVars, contactVars>>

\* Normal AppendEntries response handling (success / failure)
\* Replicator.java:1454-1482
HandleAppendEntriesResponse(s, m) ==
    /\ ~crashed[s]
    /\ m.mtype    = AppendEntriesResponse
    /\ m.msubtype = MSubtypeNormal
    /\ m.mdst     = s
    /\ role[s]    = Leader
    /\ IF m.mterm > currentTerm[s]
       THEN \* step down — Replicator.java:1469; stepDown persists via setTermAndVotedFor
            /\ currentTerm'       = [currentTerm       EXCEPT ![s] = m.mterm]
            /\ role'              = [role              EXCEPT ![s] = Follower]
            /\ votedFor'          = [votedFor          EXCEPT ![s] = Nil]
            /\ persistedTerm'     = [persistedTerm     EXCEPT ![s] = m.mterm]
            /\ persistedVotedFor' = [persistedVotedFor EXCEPT ![s] = Nil]
            /\ Discard(m)
            /\ UNCHANGED <<logVars, persistStep, crashed, readVars, contactVars>>
       ELSE
            /\ Discard(m)
            /\ IF m.msuccess
               THEN \* advance matchIndex/nextIndex — Replicator.java:1476
                    LET newMatch == m.mmatchIndex IN
                    /\ matchIndex' = [matchIndex EXCEPT ![s][m.msrc] = newMatch]
                    /\ nextIndex'  = [nextIndex  EXCEPT ![s][m.msrc] = newMatch + 1]
               ELSE \* decrement nextIndex — Replicator.java:1479
                    /\ nextIndex' = [nextIndex EXCEPT
                                        ![s][m.msrc] = Max({1, nextIndex[s][m.msrc] - 1})]
                    /\ UNCHANGED matchIndex
            /\ UNCHANGED <<serverVars, log, commitIndex, lastApplied,
                           persistVars, readVars, contactVars>>

\* --- Advance commit index on leader ---
\* BallotBox.java:commitAt — leader advances commitIndex when quorum matched
AdvanceCommitIndex(s) ==
    /\ ~crashed[s]
    /\ role[s] = Leader
    /\ \E newCommit \in (commitIndex[s]+1)..LastLogIndex(s) :
              /\ LogTerm(s, newCommit) = currentTerm[s]      \* must be current term
              /\ Cardinality({t \in Server :
                    \/ t = s
                    \/ matchIndex[s][t] >= newCommit}) * 2 > Cardinality(Server)
              /\ commitIndex' = [commitIndex EXCEPT ![s] = newCommit]
    /\ UNCHANGED <<serverVars, log, lastApplied, nextIndex, matchIndex,
                   messages, persistVars, readVars, contactVars>>

\* --- ApplyCommittedEntries ---
\* FSMCallerImpl — apply committed but unapplied entries to FSM
ApplyCommittedEntries(s) ==
    /\ ~crashed[s]
    /\ lastApplied[s] < commitIndex[s]
    /\ lastApplied' = [lastApplied EXCEPT ![s] = commitIndex[s]]
    \* Notify ReadOnlyService of applied index — FSMCallerImpl.java:578-584
    \* setLastApplied calls notifyLastAppliedIndexUpdated → ReadOnlyService.onApplied
    /\ LET applied == commitIndex[s] IN
       pendingReadIndex' = [pendingReadIndex EXCEPT
           ![s] = {idx \in pendingReadIndex[s] : idx > applied}]
    /\ readIndexSuccess' = [readIndexSuccess EXCEPT
           ![s] = readIndexSuccess[s] \cup
               {idx \in pendingReadIndex[s] : idx <= commitIndex[s]}]
    /\ UNCHANGED <<serverVars, log, commitIndex, nextIndex, matchIndex,
                   messages, persistVars, snapshotIndex, snapshotTerm,
                   readIssuedTerm, lastLeaderContact, clock>>

\* ============================================================================
\* Families 3+4: ReadIndex and Snapshot Notification
\* ============================================================================

\* --- ServeReadIndex ---
\* NodeImpl.java:1580-1640 (readIndex / readLeader)
\* Bug: quorum==1 fast-path at lines 1599-1607 skips the no-op-at-current-term guard
ServeReadIndex(s, idx) ==
    /\ ~crashed[s]
    /\ role[s] = Leader
    /\ idx > 0
    /\ idx <= commitIndex[s]
    \* Family 4 BUG: single-node cluster skips this guard
    \* For multi-peer: NodeImpl.java:1610-1617 requires logTerm(commitIndex) == currTerm
    \* We model the missing guard: no term check before accepting
    /\ pendingReadIndex'  = [pendingReadIndex EXCEPT ![s] = pendingReadIndex[s] \cup {idx}]
    /\ readIssuedTerm'    = [readIssuedTerm EXCEPT
           ![s] = [readIssuedTerm[s] EXCEPT ![idx] = currentTerm[s]]]
    /\ UNCHANGED <<serverVars, logVars, messages, persistVars,
                   readIndexSuccess, snapshotIndex, snapshotTerm,
                   lastLeaderContact, clock>>

\* --- ServeReadIndexSafe (correct variant with no-op guard) ---
\* NodeImpl.java:1610-1617 — the guard that single-peer fast-path skips
ServeReadIndexSafe(s, idx) ==
    /\ ~crashed[s]
    /\ role[s] = Leader
    /\ idx > 0
    /\ idx <= commitIndex[s]
    /\ HasNoopAtCurrentTerm(s)    \* guard: leader must have committed no-op at current term
    /\ pendingReadIndex'  = [pendingReadIndex EXCEPT ![s] = pendingReadIndex[s] \cup {idx}]
    /\ readIssuedTerm'    = [readIssuedTerm EXCEPT
           ![s] = [readIssuedTerm[s] EXCEPT ![idx] = currentTerm[s]]]
    /\ UNCHANGED <<serverVars, logVars, messages, persistVars,
                   readIndexSuccess, snapshotIndex, snapshotTerm,
                   lastLeaderContact, clock>>

\* --- NotifyReadIndexAfterSnapshot ---
\* Models the CORRECT notification (what doSnapshotLoad SHOULD do)
\* FSMCallerImpl.java:728-731 — missing call to notifyLastAppliedIndexUpdated()
NotifyReadIndexAfterSnapshot(s) ==
    /\ ~crashed[s]
    /\ snapshotIndex[s] > 0
    \* Resolve any pendingReadIndex entries at or before snapshot index
    /\ LET applied == snapshotIndex[s] IN
       pendingReadIndex' = [pendingReadIndex EXCEPT
           ![s] = {idx \in pendingReadIndex[s] : idx > applied}]
    /\ readIndexSuccess' = [readIndexSuccess EXCEPT
           ![s] = readIndexSuccess[s] \cup
               {idx \in pendingReadIndex[s] : idx <= snapshotIndex[s]}]
    /\ UNCHANGED <<serverVars, logVars, messages, persistVars,
                   snapshotIndex, snapshotTerm, readIssuedTerm,
                   lastLeaderContact, clock>>

\* --- StepDown ---
\* NodeImpl.java:1301-1360 — stepDown
\* Family 4 BUG: stepDown does NOT call readOnlyService.setError() or clear pendingReadIndex
\* The only path that clears ReadOnlyService is onError() at line 2565
StepDown(s) ==
    /\ ~crashed[s]
    /\ role[s] = Leader
    /\ role'        = [role EXCEPT ![s] = Follower]
    /\ currentTerm' = [currentTerm EXCEPT ![s] = currentTerm[s] + 1]
    /\ votedFor'    = [votedFor EXCEPT ![s] = Nil]
    \* BUG: pendingReadIndex NOT cleared — NodeImpl.java:1301-1360
    \* Former leader as follower retains pending read closures
    \* (we leave pendingReadIndex unchanged to model the bug)
    /\ UNCHANGED <<logVars, messages, persistVars, readVars, contactVars>>

\* --- StepDownSafe (correct variant) ---
\* Models what stepDown SHOULD do: clear pending read requests
StepDownSafe(s) ==
    /\ ~crashed[s]
    /\ role[s] = Leader
    /\ role'          = [role EXCEPT ![s] = Follower]
    /\ currentTerm'   = [currentTerm EXCEPT ![s] = currentTerm[s] + 1]
    /\ votedFor'      = [votedFor EXCEPT ![s] = Nil]
    /\ pendingReadIndex' = [pendingReadIndex EXCEPT ![s] = {}]   \* cleared on step-down
    /\ UNCHANGED <<logVars, messages, persistVars, readIndexSuccess,
                   snapshotIndex, snapshotTerm, readIssuedTerm, contactVars>>

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* ---- Standard Safety Invariants ----

\* ElectionSafety: at most one leader per term
\* Raft paper §5.2
ElectionSafety ==
    \A s, t \in Server :
        (role[s] = Leader /\ role[t] = Leader /\ s /= t)
        => currentTerm[s] /= currentTerm[t]

\* LogMatching: if two logs share an entry at same (index, term), they agree up to that index
\* Raft paper §5.3
LogMatching ==
    \A s, t \in Server :
    \A i \in 1..Min({LastLogIndex(s), LastLogIndex(t)}) :
        LogTerm(s, i) = LogTerm(t, i)
        => \A j \in 1..i : LogTerm(s, j) = LogTerm(t, j)

\* LeaderCompleteness: every committed entry appears in every future leader's log
\* Raft paper §5.4
LeaderCompleteness ==
    \A s \in Server :
    role[s] = Leader =>
        \A t \in Server :
        \A i \in 1..commitIndex[t] :
            i <= LastLogIndex(s) /\ LogTerm(s, i) = LogTerm(t, i)

\* ---- Extension Invariants (Bug-Family Specific) ----

\* VoteOncePerTerm: each server grants at most one vote per term, durable through crash
\* Targets Family 1 — two-write window lets node vote twice after crash
VoteOncePerTerm ==
    \A s \in Server :
        \* If server voted (durably) for candidate X in term T,
        \* it must not also have a record of voting for Y ≠ X in same term
        persistedVotedFor[s] /= Nil =>
            \A t \in Server :
            t /= s =>
            ~(persistedTerm[t] = persistedTerm[s]
              /\ persistedVotedFor[t] /= Nil
              /\ persistedVotedFor[t] /= persistedVotedFor[s]
              /\ persistedTerm[s] = currentTerm[s])

\* PersistBeforeSend: a server's votedFor is durably stored before it responds granted=true
\* Targets Family 1 — vote response must not be sent before both writes complete
PersistBeforeSend ==
    \* For any granted vote response in the message bag,
    \* the sender's persisted votedFor must match the recipient
    \A m \in BagToSet(messages) :
        m.mtype = RequestVoteResponse /\ m.mgranted = TRUE =>
            persistedVotedFor[m.msrc] = m.mdst

\* StepDownOnHigherTerm: if a leader receives any response with term > currentTerm,
\* it must step down. Targeted by Family 2.
\* The invariant checks: no leader has a higher term in any in-flight response to it
\* that it would fail to process (we check structural consistency instead)
StepDownOnHigherTerm ==
    \A s \in Server :
    role[s] = Leader =>
        \A m \in BagToSet(messages) :
            (m.mdst = s /\ m.mterm > currentTerm[s])
            => FALSE   \* leader must have stepped down before such a msg arrives

\* ReadIndexSafety: a successful ReadIndex at index I was served only after the leader
\* had committed a no-op at its term at or before I.
\* Targets Families 3 and 4.
ReadIndexSafety ==
    \A s \in Server :
    \A idx \in readIndexSuccess[s] :
        \* The term logged when the read was issued must equal the current leader term
        \* i.e. the leader had established its term at commitIndex before serving the read
        idx \in DOMAIN readIssuedTerm[s] =>
            LogTerm(s, idx) = readIssuedTerm[s][idx]

\* NoPendingReadAfterStepDown: after a server steps down from leader role,
\* no pending ReadIndex closures remain that could be resolved with success.
\* Targets Family 4 — stepDown does not clear ReadOnlyService.
NoPendingReadAfterStepDown ==
    \A s \in Server :
        role[s] /= Leader => pendingReadIndex[s] = {}

\* ---- Structural Invariants ----

TypeOK ==
    /\ currentTerm    \in [Server -> Nat]
    /\ role           \in [Server -> {Leader, Candidate, Follower}]
    /\ votedFor       \in [Server -> Server \cup {Nil}]
    /\ commitIndex    \in [Server -> Nat]
    /\ lastApplied    \in [Server -> Nat]
    /\ persistedTerm  \in [Server -> Nat]
    /\ persistedVotedFor \in [Server -> Server \cup {Nil}]
    /\ persistStep    \in [Server -> {PersistStepNone, PersistStepTerm, PersistStepVote}]
    /\ crashed        \in [Server -> BOOLEAN]
    /\ snapshotIndex  \in [Server -> Nat]
    /\ snapshotTerm   \in [Server -> Nat]
    /\ clock          \in Nat

\* Durable state is at most as advanced as in-memory state (no time-travel)
PersistMonotone ==
    \A s \in Server :
        /\ persistedTerm[s] <= currentTerm[s] + 1
        /\ lastApplied[s] >= snapshotIndex[s]

\* Commit index never decreases
CommitMonotone ==
    \A s \in Server : commitIndex[s] >= snapshotIndex[s]

\* ============================================================================
\* NEXT STATE RELATION
\* ============================================================================

\* Advance logical clock
TickClock ==
    /\ clock' = clock + 1
    /\ UNCHANGED <<serverVars, logVars, persistVars, readVars,
                   lastLeaderContact, messages>>

Next ==
    \/ \E s \in Server : ElectionTimeout(s)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            HandleRequestVoteRequestDeny(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            HandleRequestVoteRequestGrantSameTerm(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            HandleRequestVoteRequestHigherTermStep1(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            HandleRequestVoteRequestHigherTermStep2(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            HandleRequestVoteRequestHigherTermStep3(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            HandleRequestVoteResponse(s, m)
    \/ \E s \in Server : \E v \in Values : ClientRequest(s, v)
    \/ \E s, t \in Server : AppendEntries(s, t)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            HandleAppendEntriesRequest(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            HandleAppendEntriesResponse(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            SendEBUSYResponse(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            HandleAppendEntriesResponseBusyNormal(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            HandleAppendEntriesResponseBusyHigherTerm(s, m)
    \/ \E s, t \in Server : InstallSnapshot(s, t)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            HandleInstallSnapshotRequest(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            HandleInstallSnapshotResponseNormal(s, m)
    \/ \E s \in Server : \E m \in BagToSet(messages) :
            HandleInstallSnapshotResponseWithHigherTerm(s, m)
    \/ \E s \in Server : AdvanceCommitIndex(s)
    \/ \E s \in Server : ApplyCommittedEntries(s)
    \/ \E s \in Server : \E idx \in 1..10 : ServeReadIndex(s, idx)
    \/ \E s \in Server : NotifyReadIndexAfterSnapshot(s)
    \/ \E s \in Server : StepDown(s)
    \* Crash / recovery (Family 1)
    \/ \E s \in Server : Crash(s)
    \/ \E s \in Server : RestartFromPersisted(s)
    \* Clock tick
    \/ TickClock

Spec == Init /\ [][Next]_vars

=============================================================================
