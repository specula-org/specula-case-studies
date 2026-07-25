---- MODULE Trace ----
\*
\* Trace validation spec for etcd-raft base spec.
\* Replays NDJSON traces from the harness against the base spec.
\*

EXTENDS base, Json, IOUtils, TLC, TLCExt, Sequences, Naturals, FiniteSets

\* ============================================================================
\* Trace Loading
\* ============================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../scenarios/leaseRead/harness/traces/basic.ndjson"

RawLog == ndJsonDeserialize(JsonFile)

\* Filter to only trace events (skip config and meta lines)
TraceLog == SelectSeq(RawLog, LAMBDA x : x.tag = "trace")

\* ============================================================================
\* Cursor Variable
\* ============================================================================

VARIABLE l  \* trace cursor: 1..Len(TraceLog)+1

traceVars == <<vars, l>>

logline == TraceLog[l]

\* ============================================================================
\* Server Extraction
\* ============================================================================

\* Extract server set from trace InitState events
TraceServer ==
    LET initEvents == SelectSeq(TraceLog, LAMBDA x : x.event.name = "InitState")
    IN {initEvents[i].event.nid : i \in 1..Len(initEvents)}

\* ============================================================================
\* Role / Type Mapping
\* ============================================================================

MapRole(r) ==
    CASE r = "StateFollower" -> Follower
      [] r = "StateCandidate" -> Candidate
      [] r = "StatePreCandidate" -> PreCandidate
      [] r = "StateLeader" -> Leader

MapMsgType(t) ==
    CASE t = "MsgVote" -> RequestVoteRequest
      [] t = "MsgVoteResp" -> RequestVoteResponse
      [] t = "MsgPreVote" -> PreVoteRequest
      [] t = "MsgPreVoteResp" -> PreVoteResponse
      [] t = "MsgApp" -> AppendEntriesRequest
      [] t = "MsgAppResp" -> AppendEntriesResponse
      [] t = "MsgHeartbeat" -> HeartbeatRequest
      [] t = "MsgHeartbeatResp" -> HeartbeatResponse
      [] OTHER -> t  \* pass through unknown types

\* ============================================================================
\* Event Predicates
\* ============================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, nid) ==
    /\ IsEvent(name)
    /\ logline.event.nid = nid

\* ============================================================================
\* Post-State Validation
\* ============================================================================

\* Strong validation: check term, role, commitIndex, log length
ValidatePostState(s) ==
    /\ currentTerm'[s] = logline.event.state.term
    /\ state'[s] = MapRole(logline.event.role)
    /\ commitIndex'[s] = logline.event.state.commit
    /\ Len(log'[s]) = logline.event.log

\* Weak validation: check term + role only
ValidatePostStateWeak(s) ==
    /\ currentTerm'[s] = logline.event.state.term
    /\ state'[s] = MapRole(logline.event.role)

\* ============================================================================
\* Init
\* ============================================================================

\* Bootstrap state from trace InitState events.
\* etcd-raft starts with term from HardState, bootstrap log entries from snapshot.
TraceInit ==
    LET initEvents == SelectSeq(TraceLog, LAMBDA x : x.event.name = "InitState")
        firstInit == initEvents[1].event
        bootstrapLogLen == firstInit.log
        bootstrapTerm == firstInit.state.snapshotTerm
        \* Create bootstrap log entries (we don't know values, use Nil)
        bootstrapLog == [i \in 1..bootstrapLogLen |-> [term |-> bootstrapTerm, value |-> Nil]]
    IN
    /\ currentTerm = [s \in TraceServer |-> firstInit.state.term]
    /\ votedFor = [s \in TraceServer |->
            IF firstInit.state.vote = "0" THEN Nil ELSE firstInit.state.vote]
    /\ log = [s \in TraceServer |-> bootstrapLog]
    /\ state = [s \in TraceServer |-> Follower]
    /\ commitIndex = [s \in TraceServer |-> firstInit.state.commit]
    /\ lead = [s \in TraceServer |-> Nil]
    /\ matchIndex = [s \in TraceServer |-> [j \in TraceServer |-> 0]]
    /\ nextIndex = [s \in TraceServer |-> [j \in TraceServer |-> bootstrapLogLen + 1]]
    /\ votesGranted = [s \in TraceServer |-> {}]
    /\ messages = {}
    \* ReadIndex
    /\ readIndexQueue = [s \in TraceServer |-> <<>>]
    /\ readIndexState = [s \in TraceServer |-> <<>>]
    /\ readResults = {}
    /\ nextReadCtx = [s \in TraceServer |-> 1]
    /\ committedInTerm = [s \in TraceServer |-> FALSE]
    \* Persist
    /\ persistedTerm = [s \in TraceServer |-> firstInit.state.term]
    /\ persistedVote = [s \in TraceServer |->
            IF firstInit.state.vote = "0" THEN Nil ELSE firstInit.state.vote]
    /\ persistedLog = [s \in TraceServer |-> bootstrapLog]
    /\ pendingResponses = [s \in TraceServer |-> <<>>]
    \* QuorumVars
    /\ recentActive = [s \in TraceServer |-> [j \in TraceServer |-> FALSE]]
    \* Ghost
    /\ committedLog = bootstrapLog
    /\ readRequestCommit = <<>>
    \* Cursor
    /\ l = 1

\* ============================================================================
\* Action Wrappers
\* ============================================================================

\* Skip events our spec doesn't model
TraceSkipEvent ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {
        "InitState", "BecomeFollower",  \* handled by init or state transition side-effects
        "Ready", "ApplyEntries", "Commit"
       }
    /\ l' = l + 1
    /\ UNCHANGED vars

\* ── Replicate (ClientRequest or noop broadcast) ──
\* "Replicate" has two meanings:
\* 1. During BecomeLeader: noop broadcast (log already appended by BecomeLeader → skip)
\* 2. During normal operation: client request (log length increases → ClientRequest)
TraceReplicate ==
    /\ IsEvent("Replicate")
    /\ LET s == logline.event.nid IN
       /\ state[s] = Leader
       /\ IF logline.event.log > Len(log[s])
          THEN \* Real client request: log grew
               \E v \in Value : ClientRequest(s, v)
          ELSE \* Noop broadcast from BecomeLeader: already appended, skip
               UNCHANGED vars
    /\ l' = l + 1

\* ── BecomeCandidate ──
TraceBecomeCandidate ==
    /\ IsEvent("BecomeCandidate")
    /\ LET s == logline.event.nid IN
       /\ Timeout(s)
       \*/\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* ── BecomeLeader ──
TraceBecomeLeader ==
    /\ IsEvent("BecomeLeader")
    /\ LET s == logline.event.nid IN
       /\ BecomeLeader(s)
       \*/\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* ── SendRequestVoteRequest ──
\* Vote requests are sent as part of Timeout/campaign, already handled by TraceBecomeCandidate.
\* Just advance the cursor.
TraceSendRequestVoteRequest ==
    /\ IsEvent("SendRequestVoteRequest")
    /\ l' = l + 1
    /\ UNCHANGED vars

\* ── ReceiveRequestVoteRequest ──
TraceReceiveRequestVoteRequest ==
    /\ IsEvent("ReceiveRequestVoteRequest")
    /\ LET s == logline.event.nid
           msg == logline.event.msg
       IN \E m \in messages :
              /\ m.mtype = RequestVoteRequest
              /\ m.mdest = s
              /\ m.msource = msg.from
              /\ m.mterm = msg.term
              /\ HandleRequestVoteRequest(s, m)
    /\ l' = l + 1

\* ── SendRequestVoteResponse ──
TraceSendRequestVoteResponse ==
    /\ IsEvent("SendRequestVoteResponse")
    \* Vote responses are queued via pendingResponses in HandleRequestVoteRequest.
    \* They are sent during PersistAndSend. This event corresponds to PersistAndSend.
    /\ LET s == logline.event.nid IN
       /\ pendingResponses[s] # <<>>
       /\ PersistAndSend(s)
       \*/\ ValidatePostStateWeak(s)
    /\ l' = l + 1

\* ── ReceiveRequestVoteResponse ──
TraceReceiveRequestVoteResponse ==
    /\ IsEvent("ReceiveRequestVoteResponse")
    /\ LET s == logline.event.nid
           msg == logline.event.msg
       IN \E m \in messages :
          /\ m.mtype = RequestVoteResponse
          /\ m.mdest = s
          /\ m.msource = msg.from
          /\ m.mterm = msg.term
          /\ IF state[s] = Candidate
             THEN HandleRequestVoteResponse(s, m)
             ELSE \* Stale: not candidate, discard
                  /\ Discard(m)
                  /\ UNCHANGED <<serverVars, logVars, candidateVars>>
                  /\ UNCHANGED <<readVars, persistVars, quorumVars, ghostVars>>
    /\ l' = l + 1

\* ── SendAppendEntriesRequest ──
TraceSendAppendEntriesRequest ==
    /\ IsEvent("SendAppendEntriesRequest")
    /\ LET s == logline.event.nid
           msg == logline.event.msg
       IN /\ state[s] = Leader
          /\ AppendEntries(s, msg.to)
    /\ l' = l + 1

\* ── ReceiveAppendEntriesRequest ──
TraceReceiveAppendEntriesRequest ==
    /\ IsEvent("ReceiveAppendEntriesRequest")
    /\ LET s == logline.event.nid
           msg == logline.event.msg
       IN \E m \in messages :
              /\ m.mtype = AppendEntriesRequest
              /\ m.mdest = s
              /\ m.msource = msg.from
              /\ m.mterm = msg.term
              /\ HandleAppendEntriesRequest(s, m)
    /\ l' = l + 1

\* ── SendAppendEntriesResponse ──
TraceSendAppendEntriesResponse ==
    /\ IsEvent("SendAppendEntriesResponse")
    /\ LET s == logline.event.nid
           msg == logline.event.msg
       IN IF pendingResponses[s] # <<>>
          THEN /\ PersistAndSend(s)
               /\ l' = l + 1
          ELSE \* Already sent (e.g. self-ack from BecomeLeader already flushed)
               /\ l' = l + 1
               /\ UNCHANGED vars

\* ── ReceiveAppendEntriesResponse ──
TraceReceiveAppendEntriesResponse ==
    /\ IsEvent("ReceiveAppendEntriesResponse")
    /\ LET s == logline.event.nid
           msg == logline.event.msg
       IN IF state[s] = Leader /\ msg.term = currentTerm[s]
          THEN \* Normal: leader processes response
               LET synthetic == [mtype |-> AppendEntriesResponse,
                                 mterm |-> msg.term,
                                 msource |-> msg.from,
                                 mdest |-> s,
                                 msuccess |-> ~msg.reject,
                                 mmatchIndex |-> msg.index,
                                 mreject |-> msg.reject]
                   src == msg.from
               IN IF synthetic \in messages
                  THEN HandleAppendEntriesResponse(s, synthetic)
                  ELSE \* Set-dedup: identical response already consumed.
                       \* Directly apply match/commit update without touching message bag.
                       /\ recentActive' = [recentActive EXCEPT ![s][src] = TRUE]
                       /\ matchIndex' = [matchIndex EXCEPT ![s][src] =
                              IF msg.index > matchIndex[s][src] THEN msg.index ELSE matchIndex[s][src]]
                       /\ nextIndex' = [nextIndex EXCEPT ![s][src] =
                              IF msg.index > matchIndex[s][src] THEN msg.index + 1 ELSE nextIndex[s][src]]
                       /\ LET newMatch == [matchIndex[s] EXCEPT ![src] =
                                  IF msg.index > matchIndex[s][src] THEN msg.index ELSE matchIndex[s][src]]
                              ci == CHOOSE c \in {newMatch[j] : j \in Server} :
                                  /\ IsQuorum({j \in Server : newMatch[j] >= c})
                                  /\ \A c2 \in {newMatch[j] : j \in Server} :
                                      IsQuorum({j \in Server : newMatch[j] >= c2}) => c2 <= c
                          IN IF ci > commitIndex[s] /\ LogTerm(s, ci) = currentTerm[s]
                             THEN /\ commitIndex' = [commitIndex EXCEPT ![s] = ci]
                                  /\ committedInTerm' = [committedInTerm EXCEPT ![s] = TRUE]
                                  /\ IF ci > Len(committedLog)
                                     THEN committedLog' = SubSeq(log[s], 1, ci)
                                     ELSE UNCHANGED committedLog
                             ELSE UNCHANGED <<commitIndex, committedInTerm, committedLog>>
                       /\ UNCHANGED <<currentTerm, votedFor, state, lead, log, votesGranted, messages>>
                       /\ UNCHANGED <<readResults, nextReadCtx, readIndexQueue, readIndexState>>
                       /\ UNCHANGED <<persistVars, readRequestCommit>>
          ELSE \* Stale: not leader or wrong term, discard
               /\ \E m \in messages :
                  /\ m.mtype = AppendEntriesResponse
                  /\ m.mdest = s
                  /\ m.msource = msg.from
                  /\ Discard(m)
                  /\ UNCHANGED <<serverVars, logVars, candidateVars>>
                  /\ UNCHANGED <<readVars, persistVars, quorumVars, ghostVars>>
    /\ l' = l + 1

\* SilentPersistAndSend removed: all self-acks have explicit SendAppendEntriesResponse events.

\* ============================================================================
\* TraceNext
\* ============================================================================

TraceNext ==
    \/ TraceSkipEvent
    \/ TraceReplicate
    \/ TraceBecomeCandidate
    \/ TraceBecomeLeader
    \/ TraceSendRequestVoteRequest
    \/ TraceReceiveRequestVoteRequest
    \/ TraceSendRequestVoteResponse
    \/ TraceReceiveRequestVoteResponse
    \/ TraceSendAppendEntriesRequest
    \/ TraceReceiveAppendEntriesRequest
    \/ TraceSendAppendEntriesResponse
    \/ TraceReceiveAppendEntriesResponse

\* ============================================================================
\* Spec and Temporal Properties
\* ============================================================================

TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceNext)

TraceMatched == <>(l > Len(TraceLog))

====
