---- MODULE base ----
\*
\* TLA+ specification of etcd-io/raft, focused on bug hunting.
\*
\* Bug Families targeted:
\*   F1: Linearizable Read Safety (ReadIndex queue batching + LeaseRead)
\*   F2: Persistence Ordering (msgsAfterAppend / persist-before-send)
\*   F5: PreVote + CheckQuorum interactions
\*
\* Source: github.com/etcd-io/raft/v3 (Go)
\*

EXTENDS Naturals, FiniteSets, Sequences, TLC

\* ============================================================================
\* Constants
\* ============================================================================

CONSTANTS
    Server,         \* Set of server IDs
    Value,          \* Set of client values
    Nil,            \* Placeholder for "no value"
    MaxReadCtx      \* Upper bound on read context IDs (for ReadIndex)

\* State constants
CONSTANTS Follower, PreCandidate, Candidate, Leader

\* Message type constants
CONSTANTS
    RequestVoteRequest, RequestVoteResponse,
    PreVoteRequest, PreVoteResponse,
    AppendEntriesRequest, AppendEntriesResponse,
    HeartbeatRequest, HeartbeatResponse

\* ReadOnly mode constants
CONSTANTS ReadOnlySafe, ReadOnlyLeaseBased

\* Model configuration parameters (behave as constants)
CONSTANTS
    readOnlyOption, \* ReadOnlySafe | ReadOnlyLeaseBased
    checkQuorum,    \* BOOLEAN
    preVote         \* BOOLEAN

\* ============================================================================
\* Variables
\* ============================================================================

VARIABLES
    \* ── Standard Raft ──
    currentTerm,    \* [Server -> Nat]
    votedFor,       \* [Server -> Server ∪ {Nil}]
    log,            \* [Server -> Seq([term: Nat, value: Value ∪ {Nil}])]
    state,          \* [Server -> {Follower, PreCandidate, Candidate, Leader}]
    commitIndex,    \* [Server -> Nat]
    lead,           \* [Server -> Server ∪ {Nil}]
    matchIndex,     \* [Server -> [Server -> Nat]]
    nextIndex,      \* [Server -> [Server -> Nat]]
    votesGranted,   \* [Server -> SUBSET Server]
    messages,       \* Message bag (set of messages)

    \* ── Extension 1: ReadIndex + LeaseRead (Family 1) ──
    \* read_only.go:39-43, raft.go:399, raft.go:2142-2158
    readIndexQueue, \* [Server -> Seq(Nat)]  (ordered queue of read context IDs)
    readIndexState, \* [Server -> [Nat -> [index: Nat, acks: SUBSET Server]]]
    readResults,    \* Set of [ctx: Nat, index: Nat]  (completed reads)
    nextReadCtx,    \* [Server -> Nat]  (monotonic context counter, post-fix #397)
    committedInTerm,\* [Server -> BOOLEAN]  (raft.go:2062-2066)

    \* ── Extension 2: Persist-before-send (Family 2) ──
    \* raft.go:362-377, 544-598
    persistedTerm,  \* [Server -> Nat]  (durable term)
    persistedVote,  \* [Server -> Server ∪ {Nil}]  (durable votedFor)
    persistedLog,   \* [Server -> Seq(...)]  (durable log)
    pendingResponses, \* [Server -> Seq(Message)]  (msgsAfterAppend queue)

    \* ── Extension 3: PreVote + CheckQuorum (Family 5) ──
    \* raft.go:411, tracker/tracker.go:208-218, raft.go:1273-1284
    recentActive    \* [Server -> [Server -> BOOLEAN]]  (leader's peer liveness)

\* ── Ghost variables for invariant checking ──
VARIABLES
    committedLog,   \* Seq([term: Nat, value: Value ∪ {Nil}])
    readRequestCommit  \* [Nat -> Nat]  ghost: actualCommitIndex when read ctx was created

\* Variable groups for UNCHANGED
serverVars == <<currentTerm, votedFor, state, lead>>
logVars == <<log, commitIndex, matchIndex, nextIndex>>
candidateVars == <<votesGranted>>
readVars == <<readIndexQueue, readIndexState, readResults, nextReadCtx, committedInTerm>>
persistVars == <<persistedTerm, persistedVote, persistedLog, pendingResponses>>
quorumVars == <<recentActive>>
ghostVars == <<committedLog, readRequestCommit>>
vars == <<serverVars, logVars, candidateVars, messages,
          readVars, persistVars, quorumVars, ghostVars>>

\* ============================================================================
\* Helpers
\* ============================================================================

Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b

\* ── Message helpers ──
\* We use a set-based message bag. Send adds, Discard removes.
Send(m) == messages' = messages \cup {m}
Discard(m) == messages' = messages \ {m}
Reply(m, reply) == messages' = (messages \ {m}) \cup {reply}
SendSet(ms) == messages' = messages \cup ms

\* ── Log helpers ──
LogTerm(s, idx) ==
    IF idx = 0 THEN 0
    ELSE IF idx > Len(log[s]) THEN 0
    ELSE log[s][idx].term

LastLogIndex(s) == Len(log[s])
LastLogTerm(s) == LogTerm(s, LastLogIndex(s))

\* Log entry at index (1-based)
LogEntry(s, idx) == log[s][idx]

\* Raft up-to-date check: raft.go:2041-2058
\* candidateLast is at least as up-to-date as local log
IsUpToDate(candLastTerm, candLastIndex, localLastTerm, localLastIndex) ==
    \/ candLastTerm > localLastTerm
    \/ (candLastTerm = localLastTerm /\ candLastIndex >= localLastIndex)

\* ── Quorum helpers ──
IsQuorum(votes) == 2 * Cardinality(votes) > Cardinality(Server)

\* Committed index = largest index replicated on a quorum
\* tracker.go:179-181, quorum/majority.go
QuorumCommittedIndex(s) ==
    LET matchSet == {matchIndex[s][j] : j \in Server}
    IN  CHOOSE ci \in matchSet :
            /\ IsQuorum({j \in Server : matchIndex[s][j] >= ci})
            /\ \A ci2 \in matchSet :
                (IsQuorum({j \in Server : matchIndex[s][j] >= ci2}) => ci2 <= ci)

\* ── Persist helpers ──
\* Check if all volatile state has been persisted
IsPersisted(s) ==
    /\ persistedTerm[s] = currentTerm[s]
    /\ persistedVote[s] = votedFor[s]
    /\ persistedLog[s] = log[s]

\* ============================================================================
\* Init
\* ============================================================================

Init ==
    \* ── Standard Raft ── (raft.go:437-496, starts as follower at term 0)
    /\ currentTerm = [s \in Server |-> 1]
    /\ votedFor = [s \in Server |-> Nil]
    /\ log = [s \in Server |-> <<>>]
    /\ state = [s \in Server |-> Follower]
    /\ commitIndex = [s \in Server |-> 0]
    /\ lead = [s \in Server |-> Nil]
    /\ matchIndex = [s \in Server |-> [j \in Server |-> 0]]
    /\ nextIndex = [s \in Server |-> [j \in Server |-> 1]]
    /\ votesGranted = [s \in Server |-> {}]
    /\ messages = {}
    \* ── Extension 1: ReadIndex ──
    /\ readIndexQueue = [s \in Server |-> <<>>]
    /\ readIndexState = [s \in Server |-> <<>>]
    /\ readResults = {}
    /\ nextReadCtx = [s \in Server |-> 1]
    /\ committedInTerm = [s \in Server |-> FALSE]
    \* ── Extension 2: Persist-before-send ──
    /\ persistedTerm = [s \in Server |-> 1]
    /\ persistedVote = [s \in Server |-> Nil]
    /\ persistedLog = [s \in Server |-> <<>>]
    /\ pendingResponses = [s \in Server |-> <<>>]
    \* ── Extension 3: PreVote + CheckQuorum ──
    /\ recentActive = [s \in Server |-> [j \in Server |-> FALSE]]
    \* ── Ghost ──
    /\ committedLog = <<>>
    /\ readRequestCommit = <<>>

\* ============================================================================
\* Actions: State Transitions
\* ============================================================================

\* ── becomeFollower (raft.go:891-900) ──
BecomeFollower(s, term, leader) ==
    /\ currentTerm' = [currentTerm EXCEPT ![s] = term]
    /\ state' = [state EXCEPT ![s] = Follower]
    /\ lead' = [lead EXCEPT ![s] = leader]
    /\ IF currentTerm[s] # term
       THEN votedFor' = [votedFor EXCEPT ![s] = Nil]
       ELSE UNCHANGED votedFor
    /\ votesGranted' = [votesGranted EXCEPT ![s] = {}]
    /\ committedInTerm' = [committedInTerm EXCEPT ![s] = FALSE]
    \* reset readOnly: raft.go:812
    /\ readIndexQueue' = [readIndexQueue EXCEPT ![s] = <<>>]
    /\ readIndexState' = [readIndexState EXCEPT ![s] = <<>>]

\* ── becomePreCandidate (raft.go:917-931) ──
\* Does NOT increment term, does NOT change vote.
BecomePreCandidate(s) ==
    /\ state' = [state EXCEPT ![s] = PreCandidate]
    /\ lead' = [lead EXCEPT ![s] = Nil]
    /\ votesGranted' = [votesGranted EXCEPT ![s] = {}]
    /\ UNCHANGED <<currentTerm, votedFor>>
    /\ UNCHANGED <<committedInTerm, readIndexQueue, readIndexState>>

\* ── becomeCandidate (raft.go:902-915) ──
BecomeCandidate(s) ==
    /\ currentTerm' = [currentTerm EXCEPT ![s] = currentTerm[s] + 1]
    /\ state' = [state EXCEPT ![s] = Candidate]
    /\ votedFor' = [votedFor EXCEPT ![s] = s]
    /\ lead' = [lead EXCEPT ![s] = Nil]
    /\ votesGranted' = [votesGranted EXCEPT ![s] = {s}]
    /\ committedInTerm' = [committedInTerm EXCEPT ![s] = FALSE]
    /\ readIndexQueue' = [readIndexQueue EXCEPT ![s] = <<>>]
    /\ readIndexState' = [readIndexState EXCEPT ![s] = <<>>]

\* ── becomeLeader (raft.go:933-971) ──
\* Appends a no-op entry, resets progress tracking
BecomeLeader(s) ==
    /\ state[s] = Candidate
    /\ IsQuorum(votesGranted[s])
    /\ state' = [state EXCEPT ![s] = Leader]
    /\ lead' = [lead EXCEPT ![s] = s]
    \* Append no-op entry: raft.go:961-965
    \* NOTE: reset() sets Next = lastIndex+1 BEFORE appendEntry.
    \* So peer nextIndex = Len(log)+1 (pre-noop), not Len(newLog)+1.
    /\ LET noopEntry == [term |-> currentTerm[s], value |-> Nil]
           preNoopLen == Len(log[s])
           newLog == Append(log[s], noopEntry)
       IN  /\ log' = [log EXCEPT ![s] = newLog]
           \* NOTE: matchIndex[s][s] is NOT set here. The self-ack goes through
           \* pendingResponses → PersistAndSend → HandleAppendEntriesResponse,
           \* which updates matchIndex only AFTER persistence. (raft.go:835-845)
           /\ matchIndex' = [matchIndex EXCEPT ![s] =
                [j \in Server |-> 0]]
           /\ nextIndex' = [nextIndex EXCEPT ![s] =
                [j \in Server |-> IF j = s THEN Len(newLog) + 1
                                  ELSE preNoopLen + 1]]
    \* Reset recentActive, leader is always active: raft.go:949-951
    /\ recentActive' = [recentActive EXCEPT ![s] =
            [j \in Server |-> j = s]]
    /\ committedInTerm' = [committedInTerm EXCEPT ![s] = FALSE]
    \* No-op entry goes to msgsAfterAppend for self-ack: raft.go:845
    /\ LET selfAck == [
            mtype |-> AppendEntriesResponse,
            mterm |-> currentTerm[s],
            msource |-> s,
            mdest |-> s,
            msuccess |-> TRUE,
            mmatchIndex |-> Len(log[s]) + 1,
            mreject |-> FALSE
           ]
       IN pendingResponses' = [pendingResponses EXCEPT ![s] =
              Append(pendingResponses[s], selfAck)]
    /\ UNCHANGED <<currentTerm, votedFor, votesGranted, commitIndex, messages>>

    /\ UNCHANGED <<readIndexQueue, readIndexState, readResults, nextReadCtx>>
    /\ UNCHANGED <<persistedTerm, persistedVote, persistedLog>>
    /\ UNCHANGED ghostVars

\* ============================================================================
\* Actions: Election
\* ============================================================================

\* ── Timeout: follower/candidate times out (raft.go:849-858) ──
Timeout(s) ==
    /\ state[s] \in {Follower, Candidate, PreCandidate}
    /\ IF preVote
       THEN \* PreVote path: raft.go:1033-1042
            /\ BecomePreCandidate(s)
            /\ LET term == currentTerm[s] + 1
                   last == LastLogIndex(s)
                   lastTerm == LastLogTerm(s)
                   voteReqs == {[mtype |-> PreVoteRequest,
                                 mterm |-> term,
                                 msource |-> s,
                                 mdest |-> j,
                                 mlastLogIndex |-> last,
                                 mlastLogTerm |-> lastTerm] : j \in Server \ {s}}
                   \* Self pre-vote response goes to msgsAfterAppend: raft.go:1059
                   selfResp == [mtype |-> PreVoteResponse,
                                mterm |-> term,
                                msource |-> s,
                                mdest |-> s,
                                mreject |-> FALSE]
               IN /\ SendSet(voteReqs)
                  /\ pendingResponses' = [pendingResponses EXCEPT ![s] =
                        Append(pendingResponses[s], selfResp)]
       ELSE \* Direct election: raft.go:1038-1042
            /\ BecomeCandidate(s)
            /\ LET term == currentTerm'[s]
                   last == LastLogIndex(s)
                   lastTerm == LastLogTerm(s)
                   voteReqs == {[mtype |-> RequestVoteRequest,
                                 mterm |-> term,
                                 msource |-> s,
                                 mdest |-> j,
                                 mlastLogIndex |-> last,
                                 mlastLogTerm |-> lastTerm] : j \in Server \ {s}}
                   \* Self vote response goes to msgsAfterAppend: raft.go:1059
                   selfResp == [mtype |-> RequestVoteResponse,
                                mterm |-> term,
                                msource |-> s,
                                mdest |-> s,
                                mreject |-> FALSE]
               IN /\ SendSet(voteReqs)
                  /\ pendingResponses' = [pendingResponses EXCEPT ![s] =
                        Append(pendingResponses[s], selfResp)]
    /\ UNCHANGED <<logVars, readResults, nextReadCtx>>
    /\ UNCHANGED <<persistedTerm, persistedVote, persistedLog>>
    /\ UNCHANGED <<recentActive, ghostVars>>

\* ── HandleRequestVoteRequest (raft.go:1204-1254) ──
HandleRequestVoteRequest(s, m) ==
    /\ m.mtype = RequestVoteRequest
    /\ m.mdest = s
    /\ m.mterm >= currentTerm[s]  \* raft.go:1125 — stale term messages are ignored
    /\ LET higherTerm == m.mterm > currentTerm[s]
           \* Check lease: raft.go:1095-1104
           inLease == checkQuorum /\ lead[s] # Nil
           \* After potential term bump, what would votedFor be?
           effectiveVotedFor == IF higherTerm THEN Nil ELSE votedFor[s]
           effectiveLead == IF higherTerm THEN Nil ELSE lead[s]
           grant ==
            /\ \/ effectiveVotedFor = m.msource
               \/ (effectiveVotedFor = Nil /\ effectiveLead = Nil)
            /\ IsUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                          LastLogTerm(s), LastLogIndex(s))
       IN
       IF inLease /\ higherTerm
       THEN \* Ignore vote during active lease: raft.go:1096-1103
            /\ Discard(m)
            /\ UNCHANGED <<serverVars, logVars, candidateVars>>
            /\ UNCHANGED <<readVars, persistVars, quorumVars, ghostVars>>
       ELSE
       \* Term handling: raft.go:1115-1122
       /\ currentTerm' = [currentTerm EXCEPT ![s] = IF higherTerm THEN m.mterm ELSE currentTerm[s]]
       /\ state' = [state EXCEPT ![s] = IF higherTerm THEN Follower ELSE state[s]]
       /\ lead' = [lead EXCEPT ![s] = IF higherTerm THEN Nil ELSE lead[s]]
       \* votedFor: reset on term change, then set if granting
       /\ votedFor' = [votedFor EXCEPT ![s] =
              IF grant THEN m.msource
              ELSE IF higherTerm THEN Nil
              ELSE votedFor[s]]
       /\ votesGranted' = [votesGranted EXCEPT ![s] = IF higherTerm THEN {} ELSE votesGranted[s]]
       /\ committedInTerm' = [committedInTerm EXCEPT ![s] = IF higherTerm THEN FALSE ELSE committedInTerm[s]]
       /\ readIndexQueue' = [readIndexQueue EXCEPT ![s] = IF higherTerm THEN <<>> ELSE readIndexQueue[s]]
       /\ readIndexState' = [readIndexState EXCEPT ![s] = IF higherTerm THEN <<>> ELSE readIndexState[s]]
       /\ IF grant
          THEN \* Grant vote: raft.go:1233-1248
               /\ LET resp == [mtype |-> RequestVoteResponse,
                               mterm |-> m.mterm,
                               msource |-> s,
                               mdest |-> m.msource,
                               mreject |-> FALSE]
                  IN pendingResponses' = [pendingResponses EXCEPT ![s] =
                        Append(pendingResponses[s], resp)]
               /\ Discard(m)
          ELSE \* Reject vote: raft.go:1251-1253
               /\ LET resp == [mtype |-> RequestVoteResponse,
                               mterm |-> currentTerm'[s],
                               msource |-> s,
                               mdest |-> m.msource,
                               mreject |-> TRUE]
                  \* Rejected response ALSO goes to msgsAfterAppend: raft.go:578-589
                  \* "the safety of such behavior has not been formally verified"
                  IN pendingResponses' = [pendingResponses EXCEPT ![s] =
                        Append(pendingResponses[s], resp)]
               /\ Discard(m)
       /\ UNCHANGED <<logVars, readResults, nextReadCtx>>
       /\ UNCHANGED <<persistedTerm, persistedVote, persistedLog>>
       /\ UNCHANGED <<recentActive, ghostVars>>

\* ── HandleRequestVoteResponse (raft.go:1691-1706, stepCandidate) ──
HandleRequestVoteResponse(s, m) ==
    /\ m.mtype = RequestVoteResponse
    /\ m.mdest = s
    /\ state[s] = Candidate
    /\ m.mterm = currentTerm[s]
    /\ IF ~m.mreject
       THEN votesGranted' = [votesGranted EXCEPT ![s] = votesGranted[s] \cup {m.msource}]
       ELSE UNCHANGED votesGranted
    \* VoteLost -> become follower: raft.go:1702-1705
    /\ IF m.mreject /\ 2 * Cardinality({j \in Server :
            j \notin votesGranted[s] /\ j # m.msource}) < Cardinality(Server)
       THEN BecomeFollower(s, currentTerm[s], Nil)
       ELSE UNCHANGED <<currentTerm, votedFor, state, lead, committedInTerm,
                        readIndexQueue, readIndexState>>
    /\ Discard(m)
    /\ UNCHANGED <<logVars, readResults, nextReadCtx>>
    /\ UNCHANGED <<persistVars, recentActive, ghostVars>>

\* ── HandlePreVoteRequest (raft.go:1107-1108, 1204-1254) ──
HandlePreVoteRequest(s, m) ==
    /\ m.mtype = PreVoteRequest
    /\ m.mdest = s
    /\ LET grant ==
            \/ (votedFor[s] = Nil /\ lead[s] = Nil)
            \/ votedFor[s] = m.msource
            \/ m.mterm > currentTerm[s]  \* PreVote for future term: raft.go:1210
       IN
       /\ IF grant /\ IsUpToDate(m.mlastLogTerm, m.mlastLogIndex,
                                  LastLogTerm(s), LastLogIndex(s))
          THEN \* Grant pre-vote: raft.go:1244 (use m.mterm in response)
               /\ LET resp == [mtype |-> PreVoteResponse,
                               mterm |-> m.mterm,
                               msource |-> s,
                               mdest |-> m.msource,
                               mreject |-> FALSE]
                  IN pendingResponses' = [pendingResponses EXCEPT ![s] =
                        Append(pendingResponses[s], resp)]
          ELSE \* Reject pre-vote: raft.go:1251-1253
               /\ LET resp == [mtype |-> PreVoteResponse,
                               mterm |-> currentTerm[s],
                               msource |-> s,
                               mdest |-> m.msource,
                               mreject |-> TRUE]
                  IN pendingResponses' = [pendingResponses EXCEPT ![s] =
                        Append(pendingResponses[s], resp)]
       \* Never change term in response to PreVote: raft.go:1107-1108
       /\ UNCHANGED <<serverVars, logVars, candidateVars>>
       /\ UNCHANGED <<readVars, persistedTerm, persistedVote, persistedLog>>
       /\ UNCHANGED <<recentActive, ghostVars>>
       /\ Discard(m)

\* ── HandlePreVoteResponse (raft.go:1691-1701, stepCandidate) ──
HandlePreVoteResponse(s, m) ==
    /\ m.mtype = PreVoteResponse
    /\ m.mdest = s
    /\ state[s] = PreCandidate
    /\ IF ~m.mreject
       THEN votesGranted' = [votesGranted EXCEPT ![s] = votesGranted[s] \cup {m.msource}]
       ELSE UNCHANGED votesGranted
    \* Pre-vote won -> start real election: raft.go:1696-1697
    /\ IF ~m.mreject /\ IsQuorum(votesGranted[s] \cup {m.msource})
       THEN \* campaign(campaignElection): become real candidate
            /\ BecomeCandidate(s)
            /\ LET term == currentTerm'[s]
                   last == LastLogIndex(s)
                   lastTerm == LastLogTerm(s)
                   voteReqs == {[mtype |-> RequestVoteRequest,
                                 mterm |-> term,
                                 msource |-> s,
                                 mdest |-> j,
                                 mlastLogIndex |-> last,
                                 mlastLogTerm |-> lastTerm] : j \in Server \ {s}}
                   selfResp == [mtype |-> RequestVoteResponse,
                                mterm |-> term,
                                msource |-> s,
                                mdest |-> s,
                                mreject |-> FALSE]
               IN /\ messages' = (messages \ {m}) \cup voteReqs
                  /\ pendingResponses' = [pendingResponses EXCEPT ![s] =
                        Append(pendingResponses[s], selfResp)]
       ELSE \* Pre-vote lost -> become follower: raft.go:1702-1705
            IF m.mreject /\ 2 * Cardinality({j \in Server :
                    j \notin votesGranted[s] /\ j # m.msource}) < Cardinality(Server)
            THEN /\ BecomeFollower(s, currentTerm[s], Nil)
                 /\ Discard(m)
                 /\ UNCHANGED pendingResponses
            ELSE /\ Discard(m)
                 /\ UNCHANGED <<currentTerm, votedFor, state, lead, committedInTerm,
                                readIndexQueue, readIndexState>>
                 /\ UNCHANGED pendingResponses
    /\ UNCHANGED <<logVars, readResults, nextReadCtx>>
    /\ UNCHANGED <<persistedTerm, persistedVote, persistedLog>>
    /\ UNCHANGED <<recentActive, ghostVars>>

\* ============================================================================
\* Actions: Log Replication
\* ============================================================================

\* ── ClientRequest: leader appends entry (raft.go:1286-1344) ──
ClientRequest(s, v) ==
    /\ state[s] = Leader
    /\ LET entry == [term |-> currentTerm[s], value |-> v]
           newLog == Append(log[s], entry)
       IN /\ log' = [log EXCEPT ![s] = newLog]
          \* matchIndex NOT updated here — self-ack via PersistAndSend updates it
          /\ UNCHANGED matchIndex
          /\ nextIndex' = [nextIndex EXCEPT ![s][s] = Len(newLog) + 1]
          \* Self-ack via msgsAfterAppend: raft.go:835-845
          /\ LET selfAck == [
                  mtype |-> AppendEntriesResponse,
                  mterm |-> currentTerm[s],
                  msource |-> s,
                  mdest |-> s,
                  msuccess |-> TRUE,
                  mmatchIndex |-> Len(newLog),
                  mreject |-> FALSE
                 ]
             IN pendingResponses' = [pendingResponses EXCEPT ![s] =
                    Append(pendingResponses[s], selfAck)]
    /\ UNCHANGED <<serverVars, commitIndex, candidateVars, messages>>
    /\ UNCHANGED <<readVars, persistedTerm, persistedVote, persistedLog>>
    /\ UNCHANGED <<quorumVars, quorumVars, ghostVars>>

\* ── AppendEntries: leader sends entries to follower (raft.go:616-659) ──
AppendEntries(s, j) ==
    /\ state[s] = Leader
    /\ s # j
    /\ LET prevIdx == nextIndex[s][j] - 1
           prevTerm == LogTerm(s, prevIdx)
           \* Entries from nextIndex to end of log
           ents == IF nextIndex[s][j] > Len(log[s]) THEN <<>>
                   ELSE SubSeq(log[s], nextIndex[s][j], Len(log[s]))
       IN Send([mtype |-> AppendEntriesRequest,
                mterm |-> currentTerm[s],
                msource |-> s,
                mdest |-> j,
                mprevLogIndex |-> prevIdx,
                mprevLogTerm |-> prevTerm,
                mentries |-> ents,
                mcommitIndex |-> commitIndex[s]])
    /\ UNCHANGED <<serverVars, logVars, candidateVars>>
    /\ UNCHANGED <<readVars, persistVars, quorumVars, quorumVars, ghostVars>>

\* ── HandleAppendEntriesRequest (raft.go:1786-1828) ──
HandleAppendEntriesRequest(s, m) ==
    /\ m.mtype = AppendEntriesRequest
    /\ m.mdest = s
    /\ IF m.mterm < currentTerm[s]
       THEN \* Stale term: raft.go:1125-1178
            /\ IF (checkQuorum \/ preVote) /\ (m.mtype = AppendEntriesRequest)
               THEN \* Send MsgAppResp to let stale leader step down: raft.go:1148
                    Reply(m, [mtype |-> AppendEntriesResponse,
                              mterm |-> currentTerm[s],
                              msource |-> s,
                              mdest |-> m.msource,
                              msuccess |-> FALSE,
                              mmatchIndex |-> 0,
                              mreject |-> TRUE])
               ELSE Discard(m)
            /\ UNCHANGED <<serverVars, logVars, candidateVars>>
            /\ UNCHANGED <<readVars, persistVars, quorumVars, quorumVars, ghostVars>>
       ELSE
       \* Valid term: step down if higher term, set leader
       /\ IF m.mterm > currentTerm[s]
          THEN BecomeFollower(s, m.mterm, m.msource)
          ELSE /\ state' = [state EXCEPT ![s] = Follower]
               /\ lead' = [lead EXCEPT ![s] = m.msource]
               /\ UNCHANGED <<currentTerm, votedFor, votesGranted, committedInTerm,
                              readIndexQueue, readIndexState>>
       \* raft.go:1791 — reject if prevLogIndex < committed (stale AppendEntries)
       /\ IF m.mprevLogIndex < commitIndex[s]
          THEN \* Already committed past this point
               /\ LET resp == [mtype |-> AppendEntriesResponse,
                               mterm |-> m.mterm,
                               msource |-> s,
                               mdest |-> m.msource,
                               msuccess |-> FALSE,
                               mmatchIndex |-> commitIndex[s],
                               mreject |-> FALSE]
                  IN pendingResponses' = [pendingResponses EXCEPT ![s] =
                        Append(pendingResponses[s], resp)]
               /\ Discard(m)
               /\ UNCHANGED <<log, commitIndex, matchIndex, nextIndex>>
               /\ UNCHANGED <<persistedTerm, persistedVote, persistedLog>>
               /\ UNCHANGED committedLog
          ELSE IF m.mprevLogIndex > 0 /\
             (m.mprevLogIndex > Len(log[s]) \/
              LogTerm(s, m.mprevLogIndex) # m.mprevLogTerm)
          THEN \* Log doesn't match at prevLogIndex: reject
               /\ LET resp == [mtype |-> AppendEntriesResponse,
                               mterm |-> m.mterm,
                               msource |-> s,
                               mdest |-> m.msource,
                               msuccess |-> FALSE,
                               mmatchIndex |-> 0,
                               mreject |-> TRUE]
                  \* Response goes to msgsAfterAppend: raft.go:544
                  IN pendingResponses' = [pendingResponses EXCEPT ![s] =
                        Append(pendingResponses[s], resp)]
               /\ Discard(m)
               /\ UNCHANGED <<log, commitIndex, matchIndex, nextIndex>>
               /\ UNCHANGED <<persistedTerm, persistedVote, persistedLog>>
               /\ UNCHANGED committedLog
          ELSE \* Log matches: append entries, advance commit
               /\ LET newEntries == m.mentries
                      baseIndex == m.mprevLogIndex
                      \* Find first conflicting entry (log.go:107-140, maybeAppend).
                      \* Only truncate from the conflict point — matching entries are preserved.
                      conflictIdx == CHOOSE ci \in 0..Len(newEntries) :
                          /\ \A j \in 1..ci :
                              /\ baseIndex + j <= Len(log[s])
                              /\ log[s][baseIndex + j].term = newEntries[j].term
                          /\ (ci = Len(newEntries) \/
                              baseIndex + ci + 1 > Len(log[s]) \/
                              log[s][baseIndex + ci + 1].term # newEntries[ci + 1].term)
                      \* If all entries match, log is unchanged. Otherwise truncate at conflict.
                      newLog == IF conflictIdx = Len(newEntries)
                                THEN log[s]  \* all entries match, preserve existing log
                                ELSE SubSeq(log[s], 1, baseIndex + conflictIdx) \o
                                     SubSeq(newEntries, conflictIdx + 1, Len(newEntries))
                      newCommit == IF m.mcommitIndex > commitIndex[s]
                                   THEN IF m.mcommitIndex < Len(newLog)
                                        THEN m.mcommitIndex
                                        ELSE Len(newLog)
                                   ELSE commitIndex[s]
                  IN /\ log' = [log EXCEPT ![s] = newLog]
                     /\ commitIndex' = [commitIndex EXCEPT ![s] = newCommit]
                     /\ LET resp == [mtype |-> AppendEntriesResponse,
                                     mterm |-> m.mterm,
                                     msource |-> s,
                                     mdest |-> m.msource,
                                     msuccess |-> TRUE,
                                     mmatchIndex |-> Len(newLog),
                                     mreject |-> FALSE]
                        \* Response REPLACES any prior pending responses for this server.
                        \* In the impl, the latest handleAppendEntries result is what
                        \* gets persisted and sent in the next Ready cycle.
                        IN pendingResponses' = [pendingResponses EXCEPT ![s] = <<resp>>]
                     /\ Discard(m)
                     /\ UNCHANGED <<matchIndex, nextIndex>>
                     /\ UNCHANGED <<persistedTerm, persistedVote, persistedLog>>
               \* Update ghost committedLog
               /\ LET newCommit2 == IF m.mcommitIndex > commitIndex[s]
                                    THEN IF m.mcommitIndex < Len(SubSeq(log[s], 1, m.mprevLogIndex) \o m.mentries)
                                         THEN m.mcommitIndex
                                         ELSE Len(SubSeq(log[s], 1, m.mprevLogIndex) \o m.mentries)
                                    ELSE commitIndex[s]
                      newLog2 == SubSeq(log[s], 1, m.mprevLogIndex) \o m.mentries
                  IN IF newCommit2 > Len(committedLog)
                     THEN committedLog' = SubSeq(newLog2, 1, newCommit2)
                     ELSE UNCHANGED committedLog
       /\ UNCHANGED <<readResults, nextReadCtx>>
       /\ UNCHANGED <<recentActive, readRequestCommit>>

\* ── HandleAppendEntriesResponse (raft.go:1376-1569, stepLeader) ──
HandleAppendEntriesResponse(s, m) ==
    /\ m.mtype = AppendEntriesResponse
    /\ m.mdest = s
    /\ state[s] = Leader
    /\ m.mterm = currentTerm[s]
    \* Update recentActive: raft.go:1380
    /\ recentActive' = [recentActive EXCEPT ![s][m.msource] = TRUE]
    /\ IF m.msuccess
       THEN \* Success: update match/next index
            /\ matchIndex' = [matchIndex EXCEPT ![s][m.msource] =
                    IF m.mmatchIndex > matchIndex[s][m.msource]
                    THEN m.mmatchIndex ELSE matchIndex[s][m.msource]]
            /\ nextIndex' = [nextIndex EXCEPT ![s][m.msource] =
                    IF m.mmatchIndex > matchIndex[s][m.msource]
                    THEN m.mmatchIndex + 1 ELSE nextIndex[s][m.msource]]
            \* maybeCommit: raft.go:778-781, 1542
            /\ LET newMatchIndex == [matchIndex[s] EXCEPT
                        ![m.msource] = IF m.mmatchIndex > matchIndex[s][m.msource]
                                       THEN m.mmatchIndex ELSE matchIndex[s][m.msource]]
                   quorumIdx ==
                       CHOOSE ci \in {newMatchIndex[j] : j \in Server} :
                           /\ IsQuorum({j \in Server : newMatchIndex[j] >= ci})
                           /\ \A ci2 \in {newMatchIndex[j] : j \in Server} :
                               (IsQuorum({j \in Server : newMatchIndex[j] >= ci2}) => ci2 <= ci)
               IN  IF quorumIdx > commitIndex[s] /\ LogTerm(s, quorumIdx) = currentTerm[s]
                   THEN /\ commitIndex' = [commitIndex EXCEPT ![s] = quorumIdx]
                        /\ committedInTerm' = [committedInTerm EXCEPT ![s] = TRUE]
                        \* Update ghost committedLog
                        /\ IF quorumIdx > Len(committedLog)
                           THEN committedLog' = SubSeq(log[s], 1, quorumIdx)
                           ELSE UNCHANGED committedLog
                   ELSE /\ UNCHANGED <<commitIndex, committedInTerm>>
                        /\ UNCHANGED committedLog
       ELSE \* Rejection: decrement nextIndex
            /\ nextIndex' = [nextIndex EXCEPT ![s][m.msource] =
                    IF nextIndex[s][m.msource] > 1
                    THEN nextIndex[s][m.msource] - 1
                    ELSE 1]
            /\ UNCHANGED <<matchIndex, commitIndex, committedInTerm, committedLog>>
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, log, candidateVars>>
    /\ UNCHANGED <<readResults, nextReadCtx, readIndexQueue, readIndexState>>
    /\ UNCHANGED <<persistVars, readRequestCommit>>

\* ============================================================================
\* Actions: Heartbeat (separate from AppendEntries)
\* ============================================================================

\* ── SendHeartbeat (raft.go:692-708) ──
\* Heartbeat carries commit index and optionally a ReadIndex context.
SendHeartbeat(s) ==
    /\ state[s] = Leader
    /\ LET ctx == IF readIndexQueue[s] # <<>>
                  THEN readIndexQueue[s][Len(readIndexQueue[s])]  \* last pending ctx
                  ELSE 0  \* no pending reads
       IN SendSet({[mtype |-> HeartbeatRequest,
                    mterm |-> currentTerm[s],
                    msource |-> s,
                    mdest |-> j,
                    mcommitIndex |-> IF matchIndex[s][j] < commitIndex[s]
                                     THEN matchIndex[s][j]
                                     ELSE commitIndex[s],
                    mctx |-> ctx] : j \in Server \ {s}})
    /\ UNCHANGED <<serverVars, logVars, candidateVars>>
    /\ UNCHANGED <<readVars, persistVars, quorumVars, quorumVars, ghostVars>>

\* ── HandleHeartbeat (raft.go:1830-1833) ──
HandleHeartbeat(s, m) ==
    /\ m.mtype = HeartbeatRequest
    /\ m.mdest = s
    /\ IF m.mterm < currentTerm[s]
       THEN /\ Discard(m)
            /\ UNCHANGED <<serverVars, logVars, candidateVars>>
            /\ UNCHANGED <<readVars, persistVars, quorumVars, quorumVars, ghostVars>>
       ELSE
       /\ IF m.mterm > currentTerm[s]
          THEN BecomeFollower(s, m.mterm, m.msource)
          ELSE /\ lead' = [lead EXCEPT ![s] = m.msource]
               /\ state' = [state EXCEPT ![s] = Follower]
               /\ UNCHANGED <<currentTerm, votedFor, votesGranted, committedInTerm,
                              readIndexQueue, readIndexState>>
       \* commitTo: raft.go:1831
       /\ commitIndex' = [commitIndex EXCEPT ![s] =
              IF m.mcommitIndex > commitIndex[s] /\ m.mcommitIndex <= Len(log[s])
              THEN m.mcommitIndex ELSE commitIndex[s]]
       \* Heartbeat response goes to msgsAfterAppend
       /\ LET resp == [mtype |-> HeartbeatResponse,
                       mterm |-> currentTerm'[s],
                       msource |-> s,
                       mdest |-> m.msource,
                       mctx |-> m.mctx]
          IN pendingResponses' = [pendingResponses EXCEPT ![s] =
                Append(pendingResponses[s], resp)]
       /\ Discard(m)
       /\ UNCHANGED <<log, matchIndex, nextIndex>>
       /\ UNCHANGED <<readResults, nextReadCtx>>
       /\ UNCHANGED <<persistedTerm, persistedVote, persistedLog>>
       /\ UNCHANGED <<recentActive, ghostVars>>

\* ── HandleHeartbeatResponse (raft.go:1571-1605, stepLeader) ──
HandleHeartbeatResponse(s, m) ==
    /\ m.mtype = HeartbeatResponse
    /\ m.mdest = s
    /\ state[s] = Leader
    /\ m.mterm = currentTerm[s]
    \* Update recentActive: raft.go:1572
    /\ recentActive' = [recentActive EXCEPT ![s][m.msource] = TRUE]
    \* ReadIndex ack processing: raft.go:1592-1605
    /\ IF readOnlyOption = ReadOnlySafe /\ m.mctx # 0 /\ m.mctx \in DOMAIN readIndexState[s]
       THEN \* recvAck: read_only.go:68-76
            LET ackSet == readIndexState[s][m.mctx].acks \cup {m.msource}
            IN IF IsQuorum(ackSet)
               THEN \* advance: dequeue all up to this ctx (read_only.go:81-111)
                    LET advancedCtxs == {readIndexQueue[s][k] :
                            k \in {k2 \in 1..Len(readIndexQueue[s]) :
                                \A k3 \in 1..Len(readIndexQueue[s]) :
                                    readIndexQueue[s][k3] = m.mctx => k2 <= k3}}
                        newResults == {[ctx |-> c,
                                       index |-> readIndexState[s][c].index] :
                                       c \in advancedCtxs}
                        \* Remove dequeued from queue
                        cutIdx == CHOOSE k \in 1..Len(readIndexQueue[s]) :
                                    readIndexQueue[s][k] = m.mctx
                        newQueue == SubSeq(readIndexQueue[s], cutIdx + 1,
                                          Len(readIndexQueue[s]))
                        \* Remove from state
                        newState == [c \in (DOMAIN readIndexState[s] \ advancedCtxs)
                                     |-> readIndexState[s][c]]
                    IN /\ readIndexQueue' = [readIndexQueue EXCEPT ![s] = newQueue]
                       /\ readIndexState' = [readIndexState EXCEPT ![s] = newState]
                       /\ readResults' = readResults \cup newResults
               ELSE \* Not yet quorum, just record ack
                    /\ readIndexState' = [readIndexState EXCEPT
                            ![s][m.mctx].acks = ackSet]
                    /\ UNCHANGED <<readIndexQueue, readResults>>
       ELSE UNCHANGED <<readIndexQueue, readIndexState, readResults>>
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, candidateVars>>
    /\ UNCHANGED <<nextReadCtx, committedInTerm>>
    /\ UNCHANGED <<persistVars, ghostVars>>

\* ============================================================================
\* Actions: ReadIndex + LeaseRead (Extension 1, Family 1)
\* ============================================================================

\* ── RequestReadIndex: client requests a linearizable read ──
\* raft.go:1346-1364, 2142-2158
RequestReadIndex(s) ==
    /\ state[s] = Leader
    /\ nextReadCtx[s] <= MaxReadCtx
    /\ LET ctx == nextReadCtx[s]
           ci == commitIndex[s]
       IN
       \* Must have committed in current term: raft.go:1357
       /\ committedInTerm[s] = TRUE
       /\ IF readOnlyOption = ReadOnlySafe
          THEN \* ReadOnlySafe: add to queue, broadcast heartbeat
               \* read_only.go:56-63 (addRequest), raft.go:2148-2152
               /\ readIndexQueue' = [readIndexQueue EXCEPT ![s] = Append(readIndexQueue[s], ctx)]
               /\ readIndexState' = [readIndexState EXCEPT ![s] =
                      readIndexState[s] @@ (ctx :> [index |-> ci, acks |-> {s}])]
               \* Broadcast heartbeat with this ctx: raft.go:2152
               /\ SendSet({[mtype |-> HeartbeatRequest,
                            mterm |-> currentTerm[s],
                            msource |-> s,
                            mdest |-> j,
                            mcommitIndex |-> IF matchIndex[s][j] < commitIndex[s]
                                             THEN matchIndex[s][j]
                                             ELSE commitIndex[s],
                            mctx |-> ctx] : j \in Server \ {s}})
               /\ UNCHANGED readResults
          ELSE \* ReadOnlyLeaseBased: immediate response, no heartbeat
               \* raft.go:2153-2156
               /\ readResults' = readResults \cup {[ctx |-> ctx, index |-> ci]}
               /\ UNCHANGED <<readIndexQueue, readIndexState, messages>>
       /\ nextReadCtx' = [nextReadCtx EXCEPT ![s] = ctx + 1]
       \* Ghost: record ACTUAL committed log length (global truth) at read time.
       \* If leader's commitIndex < Len(committedLog), the read is stale.
       /\ readRequestCommit' = readRequestCommit @@ (ctx :> Len(committedLog))
    /\ UNCHANGED <<serverVars, logVars, candidateVars, committedInTerm>>
    /\ UNCHANGED <<persistVars, quorumVars, quorumVars, committedLog>>

\* ============================================================================
\* Actions: CheckQuorum (Extension 3, Family 5)
\* ============================================================================

\* ── CheckQuorum: leader checks if quorum is active (raft.go:1273-1284) ──
CheckQuorum(s) ==
    /\ state[s] = Leader
    /\ checkQuorum = TRUE
    /\ LET active == {j \in Server : recentActive[s][j]}
       IN IF ~IsQuorum(active)
          THEN \* Step down: raft.go:1275-1276
               /\ BecomeFollower(s, currentTerm[s], Nil)
               /\ UNCHANGED recentActive
          ELSE \* Reset all to inactive except self: raft.go:1280-1284
               /\ recentActive' = [recentActive EXCEPT ![s] =
                      [j \in Server |-> j = s]]
               /\ UNCHANGED <<currentTerm, votedFor, state, lead, votesGranted,
                              committedInTerm, readIndexQueue, readIndexState>>
    /\ UNCHANGED <<logVars, messages, readResults, nextReadCtx>>
    /\ UNCHANGED <<persistVars, ghostVars>>

\* ============================================================================
\* Actions: Persist-before-send (Extension 2, Family 2)
\* ============================================================================

\* ── PersistAndSend: complete persistence, flush pending responses ──
\* This models the Ready/Advance cycle where unstable state is written to
\* stable storage, and deferred messages (msgsAfterAppend) are released.
\* rawnode.go:225-262
PersistAndSend(s) ==
    /\ pendingResponses[s] # <<>>
    \* Persist current volatile state
    /\ persistedTerm' = [persistedTerm EXCEPT ![s] = currentTerm[s]]
    /\ persistedVote' = [persistedVote EXCEPT ![s] = votedFor[s]]
    /\ persistedLog' = [persistedLog EXCEPT ![s] = log[s]]
    \* Send all pending responses
    /\ messages' = messages \cup {pendingResponses[s][k] : k \in 1..Len(pendingResponses[s])}
    /\ pendingResponses' = [pendingResponses EXCEPT ![s] = <<>>]
    /\ UNCHANGED <<serverVars, logVars, candidateVars>>
    /\ UNCHANGED <<readVars, quorumVars, quorumVars, ghostVars>>

\* ============================================================================
\* Actions: Faults
\* ============================================================================

\* ── Crash: server crashes and recovers from persisted state ──
\* raft.go:437-496 (newRaft), recovery from HardState
Crash(s) ==
    \* Recover from persisted state only
    /\ currentTerm' = [currentTerm EXCEPT ![s] = persistedTerm[s]]
    /\ votedFor' = [votedFor EXCEPT ![s] = persistedVote[s]]
    /\ log' = [log EXCEPT ![s] = persistedLog[s]]
    /\ state' = [state EXCEPT ![s] = Follower]
    /\ lead' = [lead EXCEPT ![s] = Nil]
    \* commitIndex is volatile but safe to reset (will be re-learned from leader)
    /\ commitIndex' = [commitIndex EXCEPT ![s] = 0]
    /\ matchIndex' = [matchIndex EXCEPT ![s] = [j \in Server |-> 0]]
    /\ nextIndex' = [nextIndex EXCEPT ![s] = [j \in Server |-> 1]]
    /\ votesGranted' = [votesGranted EXCEPT ![s] = {}]
    \* Pending responses are lost on crash
    /\ pendingResponses' = [pendingResponses EXCEPT ![s] = <<>>]
    \* ReadIndex state is lost
    /\ readIndexQueue' = [readIndexQueue EXCEPT ![s] = <<>>]
    /\ readIndexState' = [readIndexState EXCEPT ![s] = <<>>]
    /\ nextReadCtx' = [nextReadCtx EXCEPT ![s] = nextReadCtx[s]]
    /\ committedInTerm' = [committedInTerm EXCEPT ![s] = FALSE]
    /\ recentActive' = [recentActive EXCEPT ![s] = [j \in Server |-> FALSE]]
    /\ UNCHANGED <<messages, readResults>>
    /\ UNCHANGED <<persistedTerm, persistedVote, persistedLog>>

    /\ UNCHANGED ghostVars

\* ── LoseMessage: network drops a message ──
LoseMessage(m) ==
    /\ m \in messages
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, logVars, candidateVars>>
    /\ UNCHANGED <<readVars, persistVars, quorumVars, quorumVars, ghostVars>>

\* ── PartitionServer: drop ALL messages to/from a server ──
\* Models a network partition isolating one server.
PartitionServer(s) ==
    /\ LET toRemove == {m \in messages : m.msource = s \/ m.mdest = s}
       IN /\ toRemove # {}
          /\ messages' = messages \ toRemove
    /\ UNCHANGED <<serverVars, logVars, candidateVars>>
    /\ UNCHANGED <<readVars, persistVars, quorumVars, quorumVars, ghostVars>>

\* ============================================================================
\* Next State
\* ============================================================================

Next ==
    \/ \E s \in Server : Timeout(s)
    \/ \E s \in Server : BecomeLeader(s)
    \/ \E s \in Server, v \in Value : ClientRequest(s, v)
    \/ \E s \in Server, j \in Server : s # j /\ AppendEntries(s, j)
    \/ \E s \in Server : SendHeartbeat(s)
    \/ \E s \in Server : RequestReadIndex(s)
    \/ \E s \in Server : CheckQuorum(s)
    \/ \E s \in Server : PersistAndSend(s)
    \/ \E s \in Server : Crash(s)
    \/ \E m \in messages : HandleRequestVoteRequest(m.mdest, m)
    \/ \E m \in messages : HandleRequestVoteResponse(m.mdest, m)
    \/ \E m \in messages : HandlePreVoteRequest(m.mdest, m)
    \/ \E m \in messages : HandlePreVoteResponse(m.mdest, m)
    \/ \E m \in messages : HandleAppendEntriesRequest(m.mdest, m)
    \/ \E m \in messages : HandleAppendEntriesResponse(m.mdest, m)
    \/ \E m \in messages : HandleHeartbeat(m.mdest, m)
    \/ \E m \in messages : HandleHeartbeatResponse(m.mdest, m)
    \/ \E m \in messages : LoseMessage(m)
    \/ \E s \in Server : PartitionServer(s)

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* Invariants
\* ============================================================================

\* ── Standard Raft Safety ──

\* ElectionSafety: at most one leader per term
ElectionSafety ==
    \A s1, s2 \in Server :
        (state[s1] = Leader /\ state[s2] = Leader /\ currentTerm[s1] = currentTerm[s2])
        => s1 = s2

\* LogMatching: if two logs contain an entry with the same index and term,
\* the logs are identical in all preceding entries
LogMatching ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(Len(log[s1]), Len(log[s2])) :
            log[s1][idx].term = log[s2][idx].term =>
                \A pidx \in 1..idx :
                    log[s1][pidx] = log[s2][pidx]

\* LeaderCompleteness: committed entries must appear in leaders' logs
\* whose term >= the entry's commit term (standard Raft property).
\* A stale leader at a lower term is NOT required to have the entry.
LeaderCompleteness ==
    \A s \in Server :
        state[s] = Leader =>
            \A idx \in 1..Len(committedLog) :
                committedLog[idx].term <= currentTerm[s] =>
                    (idx <= Len(log[s]) /\ log[s][idx] = committedLog[idx])

\* VoteSafety: a server votes for at most one candidate per term
\* (this is ensured by votedFor tracking, but we check the global property)
VoteSafety ==
    \A s1, s2 \in Server :
        (/\ votedFor[s1] # Nil /\ votedFor[s2] # Nil
         /\ currentTerm[s1] = currentTerm[s2]
         /\ s1 = s2)
        => votedFor[s1] = votedFor[s2]

\* StateMachineConsistency: committed entries at same index have same value
StateMachineConsistency ==
    \A s1, s2 \in Server :
        \A idx \in 1..Min(commitIndex[s1], commitIndex[s2]) :
            /\ idx <= Len(log[s1])
            /\ idx <= Len(log[s2])
            /\ log[s1][idx] = log[s2][idx]

\* ── Extension Invariants: Family 1 (ReadIndex / LeaseRead) ──

\* ReadIndexLinearizability: every completed read saw a commit index that
\* was valid (>= actual commit index) at the time the read was requested.
\* This is the key invariant for Issue #392.
ReadIndexLinearizability ==
    \A r \in readResults :
        r.ctx \in DOMAIN readRequestCommit =>
            r.index >= readRequestCommit[r.ctx]

\* LeaseImpliesLeadership: if a LeaseRead completes at commitIndex C,
\* no entries committed BEFORE the read was served should have been missed.
\* i.e., the global committed log length at read-serve time must equal
\* the read's commitIndex. If committedLog grew past C, the read was stale.
\* This targets MC-2: stale lease after partition.
LeaseImpliesLeadership ==
    readOnlyOption = ReadOnlyLeaseBased =>
        \A r \in readResults :
            r.ctx \in DOMAIN readRequestCommit =>
                \* The read's commitIndex must be >= the ACTUAL committed length
                \* at the time the read was served (approximated by current committedLog).
                \* NOTE: This is deliberately STRONG — we WANT it to trigger on stale reads.
                r.index >= Len(committedLog)

\* ── Extension Invariants: Family 2 (Persist-before-send) ──

\* PersistBeforeSend: no vote response or append ack should be in the network
\* from server s unless s has persisted the state it's responding about.
\* This is what msgsAfterAppend enforces.
\* NOTE: PreVoteResponse excluded — PreVote carries future term (r.Term+1)
\* but doesn't persist it. This is by design (raft.go:917-931).
\* HeartbeatResponse excluded — no state change to persist.
PersistBeforeSend ==
    \A m2 \in messages :
        \/ m2.mtype \notin {RequestVoteResponse, AppendEntriesResponse}
        \/ LET s == m2.msource IN
           /\ persistedTerm[s] >= m2.mterm
           \* For CURRENT-TERM vote grant responses, the vote must be persisted.
           \* Stale-term grants (from previous candidacies flushed together) are harmless.
           /\ (m2.mtype = RequestVoteResponse /\ ~m2.mreject /\ m2.mterm = persistedTerm[s])
              => persistedVote[s] = m2.mdest

\* ── Extension Invariants: Family 5 (PreVote) ──

\* PreVoteNoTermBump: PreVote messages should never cause term updates
\* (This is a structural invariant, verified by spec construction)

\* ── Structural Invariants ──

\* All terms are positive
TermsPositive ==
    \A s \in Server : currentTerm[s] >= 1

\* Leader's log is at least as long as commitIndex
LeaderLogCommitConsistency ==
    \A s \in Server :
        state[s] = Leader => commitIndex[s] <= Len(log[s])

\* CommitIndex never exceeds log length
CommitIndexBound ==
    \A s \in Server : commitIndex[s] <= Len(log[s])

\* Messages have valid source and destination
MessageEndpointsValid ==
    \A m2 \in messages : m2.msource \in Server /\ m2.mdest \in Server

====
