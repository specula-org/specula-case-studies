--------------------------- MODULE Trace ---------------------------
\* Trace validation spec for dotnet/dotNext Raft.
\*
\* Reads an NDJSON trace file produced by the instrumentation harness,
\* and replays each event against the base spec to verify
\* the implementation matches the specification.
\*
\* Key design decisions for trace gaps:
\*   - BecomeLeader: skip quorum check (external votes often untraced)
\*   - AdvanceCommitIndex: skip quorum check (replication often untraced)
\*   - HandleRequestVote: relax term check (trace captures pre-step-down)
\*   - Silent actions bridge unobserved replication/log state

EXTENDS base, Json, IOUtils, Sequences, TLC

----
\* Trace loading
----

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x))

ASSUME Len(TraceLog) > 0

----
\* Trace cursor
----

VARIABLE l       \* Current position in TraceLog (1-indexed)

traceVars == <<l>>

logline == TraceLog[l]

----
\* Role mapping
\* Maps implementation role strings to spec constants
----

RaftRole ==
    "Follower"  :> Follower  @@
    "Candidate" :> Candidate @@
    "Leader"    :> Leader

----
\* Server extraction from trace
\*
\* Derive the set of servers that appear in the trace.
\* Each event has a "nid" field for the node, and message events
\* have "msg.from" / "msg.to" fields.
----

TraceServer == TLCEval(
    UNION {
        {TraceLog[k].event.nid}
        \cup (IF "msg" \in DOMAIN TraceLog[k].event
              THEN {TraceLog[k].event.msg.from, TraceLog[k].event.msg.to}
                    \ {""}
              ELSE {})
        : k \in 1..Len(TraceLog)
    })

ASSUME TraceServer /= {}
ASSUME TraceServer \subseteq Server

----
\* Bootstrap state
\*
\* dotNext Raft starts with term=0 and empty log.
\* Reference: IPersistentState — Term property default is 0
----

TraceInit ==
    /\ l = 1
    /\ currentTerm      = [s \in Server |-> 0]
    /\ votedFor          = [s \in Server |-> Nil]
    /\ log               = [s \in Server |-> <<>>]
    /\ state             = [s \in Server |-> Follower]
    /\ commitIndex       = [s \in Server |-> 0]
    /\ nextIndex         = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex        = [s \in Server |-> [t \in Server |-> 0]]
    /\ votesGranted      = [s \in Server |-> {}]
    /\ messages          = EmptyBag
    \* Extension vars
    /\ activeConfig      = [s \in Server |-> Server]
    /\ proposedConfig    = [s \in Server |-> {}]
    /\ leaseValid        = [s \in Server |-> FALSE]
    /\ persistedCommitIndex = [s \in Server |-> 0]

----
\* Event predicates
----

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.event.nid = i

IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ "msg" \in DOMAIN logline.event
    /\ logline.event.msg.from = from
    /\ logline.event.msg.to = to

----
\* Post-state validation
\*
\* Strong: validates term, role, commitIndex, lastLogIndex, lastLogTerm.
\* Use for events where trace captures full state AFTER the action.
\*
\* Weak: validates only term and role.
\* Use for events where trace may not capture full state (async/concurrent).
\*
\* RelaxedTerm: like Strong but allows spec term >= trace term.
\* Used for HandleRequestVote where trace captures pre-step-down term.
----

ValidatePostState(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]
    /\ commitIndex'[i] = logline.event.state.commitIndex
    /\ LastLogIndex(i)' = logline.event.state.lastLogIndex
    /\ LastLogTerm(i)' = logline.event.state.lastLogTerm

ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]

ValidatePostStateCommit(i) ==
    /\ currentTerm'[i] = logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]
    /\ commitIndex'[i] = logline.event.state.commitIndex

\* Relaxed term validation for HandleRequestVote.
\* The trace captures result.Term BEFORE step-down (RaftCluster.cs:814),
\* but the spec updates currentTerm during HandleRequestVote.
\* Allow spec term >= trace term to handle this.
ValidatePostStateRelaxedTerm(i) ==
    /\ currentTerm'[i] >= logline.event.state.term
    /\ state'[i] = RaftRole[logline.event.state.role]
    /\ commitIndex'[i] = logline.event.state.commitIndex
    /\ LastLogIndex(i)' = logline.event.state.lastLogIndex
    /\ LastLogTerm(i)' = logline.event.state.lastLogTerm

TraceVotedFor(i) ==
    LET v == logline.event.state.votedFor
    IN IF v = "" THEN Nil ELSE v

ValidateVotedFor(i) ==
    votedFor'[i] = TraceVotedFor(i)

----
\* Step trace cursor
----

StepTrace == l' = l + 1

----
\* Log entries from trace
\*
\* Trace entries: [{term: N, value: V}, ...]
\* Convert to spec format: <<[term |-> N, value |-> V], ...>>
----

TraceEntries(entries) ==
    LET entry(k) == [term  |-> entries[k].term,
                     value |-> IF "value" \in DOMAIN entries[k]
                               THEN entries[k].value
                               ELSE Nil]
    IN [k \in 1..Len(entries) |-> entry(k)]

----
\* Silent actions (no trace event consumed)
\*
\* All silent actions MUST:
\*   1. Check l <= Len(TraceLog) to prevent unbounded exploration
\*   2. Constrain based on the NEXT trace event (what state is needed)
\*   3. UNCHANGED l
----

\* Fill log gap: leader has fewer entries than trace expects.
\* Triggers from:
\*   - lastLogIndex in event state (BecomeLeader, ClientRequest, HandleAE)
\*   - commitIndex target (AdvanceCommitIndex)
\*   - prevLogIndex + entriesCount (AppendEntries)
\* Appends one no-op entry per firing; may fire multiple times.
FillLogGap ==
    /\ l <= Len(TraceLog)
    /\ LET nid == logline.event.nid
           \* From explicit lastLogIndex (full capture events)
           fromLLI == logline.event.state.lastLogIndex
           \* From commitIndex target (AdvanceCommitIndex events)
           fromCI == IF logline.event.name = "AdvanceCommitIndex"
                     THEN logline.event.state.commitIndex
                     ELSE 0
           \* From AppendEntries: prevLogIndex + entriesCount
           fromAE == IF logline.event.name = "AppendEntries"
                        /\ "msg" \in DOMAIN logline.event
                     THEN logline.event.msg.prevLogIndex +
                          (IF "entriesCount" \in DOMAIN logline.event.msg
                           THEN logline.event.msg.entriesCount
                           ELSE 0)
                     ELSE 0
           needed == Max(Max(fromLLI, fromCI), fromAE)
       IN
       /\ nid \in Server
       /\ state[nid] = Leader
       /\ needed > 0
       /\ Len(log[nid]) < needed
       /\ log' = [log EXCEPT ![nid] = Append(@,
              [term |-> currentTerm[nid], value |-> Nil])]
       /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars,
                     messages, configVars, leaseVars, walVars>>
    /\ UNCHANGED l

\* Sync nextIndex before AppendEntries events.
\* The implementation's nextIndex may differ from the spec's because
\* AE responses that update nextIndex are often untraced.
\* Sets nextIndex[leader][follower] = trace.prevLogIndex + 1.
SilentSyncNextIndex ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "AppendEntries"
    /\ "msg" \in DOMAIN logline.event
    /\ LET nid == logline.event.nid
           j == logline.event.msg.to
           targetNext == logline.event.msg.prevLogIndex + 1
       IN
       /\ nid \in Server
       /\ j \in Server
       /\ state[nid] = Leader
       /\ nextIndex[nid][j] # targetNext
       /\ nextIndex' = [nextIndex EXCEPT ![nid][j] = targetNext]
       /\ UNCHANGED <<currentTerm, votedFor, state, log, commitIndex,
                     matchIndex, votesGranted, messages, configVars,
                     leaseVars, walVars>>
    /\ UNCHANGED l

\* Set follower log state before HandleAppendEntries events.
\* When the trace shows a successful HandleAppendEntries on a follower,
\* the follower may need entries it hasn't yet received (because earlier
\* AE processing was untraced). Copy entries from the leader's log.
SilentSetFollowerLog ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleAppendEntries"
    /\ "msg" \in DOMAIN logline.event
    /\ logline.event.msg.success = TRUE
    /\ LET nid == logline.event.nid
           prevLogIdx == logline.event.msg.prevLogIndex
       IN
       /\ nid \in Server
       /\ prevLogIdx > LastLogIndex(nid)
       \* Find a server whose log has the entries we need
       /\ \E src \in Server :
           /\ Len(log[src]) >= prevLogIdx
           /\ log' = [log EXCEPT ![nid] = SubSeq(log[src], 1, prevLogIdx)]
       /\ UNCHANGED <<serverVars, commitIndex, leaderVars, candidateVars,
                     messages, configVars, leaseVars, walVars>>
    /\ UNCHANGED l

\* Sync follower term before HandleAppendEntries events.
\* Followers may have their term updated by earlier untraced AE processing.
SilentSyncFollowerTerm ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleAppendEntries"
    /\ "msg" \in DOMAIN logline.event
    /\ LET nid == logline.event.nid
           from == logline.event.msg.from
       IN
       /\ nid \in Server
       /\ from \in Server
       /\ currentTerm[from] > currentTerm[nid]
       /\ currentTerm' = [currentTerm EXCEPT ![nid] = currentTerm[from]]
       /\ state' = [state EXCEPT ![nid] = Follower]
       /\ votedFor' = [votedFor EXCEPT ![nid] = Nil]
       /\ leaseValid' = [leaseValid EXCEPT ![nid] = FALSE]
       /\ UNCHANGED <<log, commitIndex, leaderVars, candidateVars,
                     messages, configVars, walVars>>
    /\ UNCHANGED l

\* Sync follower commitIndex before HandleAppendEntries events.
\* Followers may have their commitIndex updated by earlier untraced AE.
SilentSyncFollowerCommit ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "HandleAppendEntries"
    /\ "msg" \in DOMAIN logline.event
    /\ LET nid == logline.event.nid
           \* HandleAppendEntries updates commitIndex.
           \* The trace post-state has the final value.
           \* If current commitIndex is behind what prior untraced AEs set,
           \* this makes the AE handler's Max(commitIndex, ...) produce the
           \* right result.
           traceCI == logline.event.state.commitIndex
       IN
       /\ nid \in Server
       /\ commitIndex[nid] < traceCI
       /\ Len(log[nid]) >= traceCI
       /\ commitIndex' = [commitIndex EXCEPT ![nid] = traceCI]
       /\ UNCHANGED <<currentTerm, votedFor, state, log, leaderVars,
                     candidateVars, messages, configVars, leaseVars, walVars>>
    /\ UNCHANGED l

\* Silent lease renewal: lease state changes aren't traced directly.
SilentRenewLease ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ RenewLease(i)
        /\ UNCHANGED l

\* Silent lease expire: lease expiry isn't traced.
SilentLeaseExpire ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ LeaseExpire(i)
        /\ UNCHANGED l

\* Silent persist commit: WAL checkpoint isn't traced at event level.
SilentPersistCommitIndex ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ PersistCommitIndex(i)
        /\ UNCHANGED l

\* Silent apply config: config applied as part of heartbeat processing.
SilentApplyConfig ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
        /\ ApplyConfig(i)
        /\ UNCHANGED l

----
\* Action wrappers
\*
\* Each wrapper: match event → call base action → validate post-state → advance cursor
----

\* Timeout → Timeout(i)
\* Reference: FollowerState.cs:44 (MoveToCandidateState)
TimeoutIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Timeout", i)
        /\ Timeout(i)
        /\ ValidatePostState(i)
        /\ ValidateVotedFor(i)
        /\ StepTrace

\* RequestVote → RequestVote(i, j)
\* Reference: CandidateState.cs:34 (StartVoting)
RequestVoteIfLogged ==
    \E i \in Server :
        /\ IsEvent("RequestVote")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ LET j == logline.event.msg.to IN
            /\ j \in Server
            /\ RequestVote(i, j)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* HandleRequestVote → HandleRequestVote(i, m)
\* Reference: RaftCluster.cs:799-854 (VoteAsync)
\*
\* Uses ValidatePostStateRelaxedTerm because the trace captures
\* result.Term at line 814 (before step-down at line 820).
\* When sender term > local term, the spec updates to sender's term
\* but the trace reports the old term.
HandleRequestVoteIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleRequestVote")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in BagToSet(messages) :
            /\ m.mtype = RequestVoteRequest
            /\ m.msource = logline.event.msg.from
            /\ m.mdest = i
            /\ HandleRequestVote(i, m)
            /\ ValidatePostStateRelaxedTerm(i)
            /\ StepTrace

\* HandleRequestVoteResponse → HandleRequestVoteResponse(i, m)
\* Reference: CandidateState.cs:77-139 (EndVoting)
HandleRequestVoteResponseIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleRequestVoteResponse")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Self-vote: already counted in Timeout
              /\ logline.event.msg.from = i
              /\ UNCHANGED vars
              /\ StepTrace
           \/ \* Remote vote
              /\ logline.event.msg.from # i
              /\ \/ \E m \in BagToSet(messages) :
                       /\ m.mtype = RequestVoteResponse
                       /\ m.msource = logline.event.msg.from
                       /\ m.mdest = i
                       /\ HandleRequestVoteResponse(i, m)
                       /\ ValidatePostStateWeak(i)
                       /\ StepTrace
                 \/ \* Transport failure: message not in bag
                    /\ ~ \E m \in BagToSet(messages) :
                            /\ m.mtype = RequestVoteResponse
                            /\ m.msource = logline.event.msg.from
                            /\ m.mdest = i
                    /\ UNCHANGED vars
                    /\ StepTrace

\* BecomeLeader: direct transition (no quorum check)
\*
\* The trace often skips external vote responses (only self-vote is traced).
\* Instead of requiring IsQuorum(votesGranted), we trust the trace and
\* directly transition to Leader with the no-op append.
\*
\* Reference: RaftCluster.cs:1139-1166 (MoveToLeaderState)
BecomeLeaderIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("BecomeLeader", i)
        /\ state[i] = Candidate
        \* Skip quorum check — votes may have been received but not traced
        /\ UNCHANGED <<currentTerm, votedFor, commitIndex, votesGranted,
                       messages, configVars, leaseVars, walVars>>
        /\ LET newLog == Append(log[i], [term |-> currentTerm[i], value |-> Nil])
           IN
           /\ log' = [log EXCEPT ![i] = newLog]
           /\ state' = [state EXCEPT ![i] = Leader]
           /\ nextIndex'  = [nextIndex EXCEPT ![i] =
                [j \in Server |-> Len(newLog) + 1]]
           /\ matchIndex' = [matchIndex EXCEPT ![i] =
                [j \in Server |-> 0]]
        /\ ValidatePostState(i)
        /\ StepTrace

\* AppendEntries → AppendEntries(i, j)
\* Reference: LeaderState.cs:42-75 (ForkHeartbeats)
\*
\* Relies on SilentSyncNextIndex having set nextIndex to match
\* the trace's prevLogIndex + 1 before this fires.
AppendEntriesIfLogged ==
    \E i \in Server :
        /\ IsEvent("AppendEntries")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ LET j == logline.event.msg.to IN
            /\ j \in Server
            \* Require nextIndex to match trace's prevLogIndex + 1.
            \* This forces SilentSyncNextIndex to fire first if needed,
            \* ensuring the AE message has the correct prevLogIndex.
            /\ nextIndex[i][j] = logline.event.msg.prevLogIndex + 1
            /\ AppendEntries(i, j)
            /\ ValidatePostStateWeak(i)
            /\ StepTrace

\* HandleAppendEntries → HandleAppendEntries(i, m)
\* Reference: RaftCluster.cs:594-692 (AppendEntriesAsync)
\*
\* Matches AE request messages by prevLogIndex to disambiguate
\* when multiple AE messages exist in the bag from the same sender.
HandleAppendEntriesIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleAppendEntries")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ LET from == logline.event.msg.from
               tracePrevLogIdx == logline.event.msg.prevLogIndex
           IN
           \E m \in BagToSet(messages) :
               /\ m.mtype = AppendEntriesRequest
               /\ m.msource = from
               /\ m.mdest = i
               /\ m.mprevLogIndex = tracePrevLogIdx
               /\ HandleAppendEntries(i, m)
               /\ ValidatePostStateRelaxedTerm(i)
               /\ StepTrace

\* HandleAppendEntriesResponse → HandleAppendEntriesResponse(i, m)
\* Reference: LeaderState.cs:152-176 (DoHeartbeats response processing)
HandleAppendEntriesResponseIfLogged ==
    \E i \in Server :
        /\ IsEvent("HandleAppendEntriesResponse")
        /\ logline.event.nid = i
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \E m \in BagToSet(messages) :
                  /\ m.mtype = AppendEntriesResponse
                  /\ m.msource = logline.event.msg.from
                  /\ m.mdest = i
                  /\ HandleAppendEntriesResponse(i, m)
                  /\ ValidatePostStateWeak(i)
                  /\ StepTrace
           \/ \* Transport failure or self-response
              /\ ~ \E m \in BagToSet(messages) :
                      /\ m.mtype = AppendEntriesResponse
                      /\ m.msource = logline.event.msg.from
                      /\ m.mdest = i
              /\ UNCHANGED vars
              /\ StepTrace

\* AdvanceCommitIndex: direct commit (no quorum check)
\*
\* The trace often skips AE responses that establish quorum.
\* Instead of requiring quorum via matchIndex, we trust the trace
\* and directly set commitIndex. Only requires log length >= target.
\*
\* Reference: LeaderState.cs:178-183 (DoHeartbeats commit section)
AdvanceCommitIndexIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("AdvanceCommitIndex", i)
        /\ state[i] = Leader
        /\ UNCHANGED <<currentTerm, votedFor, state, log, leaderVars,
                       candidateVars, messages, configVars, leaseVars, walVars>>
        /\ LET newCI == logline.event.state.commitIndex IN
           /\ newCI >= commitIndex[i]  \* allow idempotent (redundant commit events)
           /\ Len(log[i]) >= newCI
           /\ commitIndex' = [commitIndex EXCEPT ![i] = newCI]
        /\ ValidatePostStateCommit(i)
        /\ StepTrace

\* ClientRequest → ClientRequest(i, v)
\* Reference: PersistentStateExtensions.cs:49-51 (AppendAsync)
ClientRequestIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ClientRequest", i)
        /\ LET v == IF "value" \in DOMAIN logline.event
                     THEN logline.event.value
                     ELSE Nil
           IN ClientRequest(i, v)
        /\ ValidatePostState(i)
        /\ StepTrace

\* Crash → Crash(i)
CrashIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Crash", i)
        /\ Crash(i)
        /\ StepTrace

\* ProposeConfig → ProposeConfig(i, newConfig)
ProposeConfigIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ProposeConfig", i)
        /\ "config" \in DOMAIN logline.event
        /\ LET newConfig == {logline.event.config[k] :
                k \in DOMAIN logline.event.config}
           IN ProposeConfig(i, newConfig)
        /\ StepTrace

\* ApplyConfig → ApplyConfig(i)
ApplyConfigIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ApplyConfig", i)
        /\ ApplyConfig(i)
        /\ StepTrace

----
\* TraceNext — all wrappers + silent actions
----

TraceNext ==
    \* Action wrappers (consume one trace event)
    \/ TimeoutIfLogged
    \/ RequestVoteIfLogged
    \/ HandleRequestVoteIfLogged
    \/ HandleRequestVoteResponseIfLogged
    \/ BecomeLeaderIfLogged
    \/ AppendEntriesIfLogged
    \/ HandleAppendEntriesIfLogged
    \/ HandleAppendEntriesResponseIfLogged
    \/ AdvanceCommitIndexIfLogged
    \/ ClientRequestIfLogged
    \/ CrashIfLogged
    \/ ProposeConfigIfLogged
    \/ ApplyConfigIfLogged
    \* Silent actions (no trace event consumed)
    \/ FillLogGap
    \/ SilentSyncNextIndex
    \/ SilentSetFollowerLog
    \/ SilentSyncFollowerTerm
    \/ SilentSyncFollowerCommit
    \/ SilentRenewLease
    \/ SilentLeaseExpire
    \/ SilentPersistCommitIndex
    \/ SilentApplyConfig

----
\* Trace completion — verify entire trace was consumed
\*
\* Uses deadlock-based checking: TLC terminates when l > Len(TraceLog)
\* and no more actions are enabled. If TLC reports deadlock at the
\* expected position, the trace is fully matched.
----

TraceFinished == l > Len(TraceLog)

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>>

\* Temporal property: entire trace consumed (requires fairness)
TraceMatched == <>(TraceFinished)

====
