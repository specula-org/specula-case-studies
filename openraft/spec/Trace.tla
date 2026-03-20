---------------------------- MODULE Trace ----------------------------
\* Trace validation spec for openraft.
\*
\* Replays NDJSON traces against the base spec to verify that the
\* implementation's state transitions match the spec's actions.
\*
\* Design notes:
\* 1. No primed-variable comparisons against logline fields (TLC bug
\*    with cross-module variable resolution after UNCHANGED processing).
\* 2. Config stays at <<{1}>> (single-node bootstrap). ReplicateEntries
\*    is inlined to allow replication to any server (openraft replicates
\*    to learners, not just voters).
\* 3. Un-traced entries (from add_learner / change_membership during
\*    bootstrap) are added via SilentLeaderAppend.
\* 4. Self-responses (HandleAppendEntriesResponse source=self) are no-ops.

EXTENDS base, Json, IOUtils

----
\* Trace loading
----

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog ==
    ndJsonDeserialize(JsonFile)

----
\* Cursor variable
----

VARIABLE traceIdx        \* Current position in trace (1-indexed)

traceVars == <<vars, traceIdx>>

----
\* Trace helpers
----

\* Check if we've consumed the entire trace
TraceFinished == traceIdx > Len(TraceLog)

\* Role mapping
MapRole(r) ==
    CASE r = "Follower"  -> Follower
      [] r = "Candidate" -> Candidate
      [] r = "Leader"    -> Leader
      [] OTHER           -> Follower

----
\* Trace action wrappers
----

\* Election timeout -> Elect
TraceElect ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "Elect"
       /\ Elect(ll.node)
    /\ traceIdx' = traceIdx + 1

\* Handle incoming VoteRequest
TraceHandleVoteRequest ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "HandleVoteRequest"
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = VoteRequest
           /\ m.mdest = ll.node
           /\ m.msource = ll.source
           /\ HandleVoteRequest(ll.node, m)
    /\ traceIdx' = traceIdx + 1

\* Handle VoteResponse
\* Self-vote response after EstablishLeader: no-op when already Leader.
TraceHandleVoteResponse ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "HandleVoteResponse"
       /\ \/ /\ state[ll.node] = Candidate
             /\ \E m \in DOMAIN messages :
                 /\ m.mtype = VoteResponse
                 /\ m.mdest = ll.node
                 /\ m.msource = ll.source
                 /\ HandleVoteResponse(ll.node, m)
          \/ /\ state[ll.node] = Leader
             /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                            messages, snapshotVars, configVars, leaseActive, crashed>>
    /\ traceIdx' = traceIdx + 1

\* Candidate establishes leadership
\* May be a no-op if SilentEstablishLeader already fired.
TraceEstablishLeader ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "EstablishLeader"
       /\ \/ /\ state[ll.node] = Candidate
             /\ EstablishLeader(ll.node)
          \/ /\ state[ll.node] = Leader
             /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                            messages, snapshotVars, configVars, leaseActive, crashed>>
    /\ traceIdx' = traceIdx + 1

\* Client request
TraceClientRequest ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "ClientRequest"
       /\ ClientRequest(ll.node)
    /\ traceIdx' = traceIdx + 1

\* Send heartbeat — override: broadcast to all servers, not just voters
TraceSendHeartbeat ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "SendHeartbeat"
       /\ LET i == ll.node
          IN
          /\ ~crashed[i]
          /\ state[i] = Leader
          /\ SendAll({[mtype         |-> AppendEntriesRequest,
                       mterm         |-> currentTerm[i],
                       mprevLogIndex |-> matchIndex[i][j],
                       mprevLogTerm  |-> LogTerm(i, matchIndex[i][j]),
                       mentries      |-> <<>>,
                       mcommitIndex  |-> commitIndex[i],
                       msource       |-> i,
                       mdest         |-> j] : j \in Server \ {i}})
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>
    /\ traceIdx' = traceIdx + 1

\* Replicate entries — override: allow any target (openraft replicates
\* to learners, not just voters). Same logic as base ReplicateEntries
\* but without the j \in EffectiveVoters(config[i]) guard.
TraceReplicateEntries ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "ReplicateEntries"
       /\ LET i == ll.node
              j == ll.target
          IN
          /\ ~crashed[i]
          /\ state[i] = Leader
          /\ j # i
          /\ nextIndex[i][j] > purgedUpTo[i]
          /\ LET prevIdx  == nextIndex[i][j] - 1
                 prevTerm == LogTerm(i, prevIdx)
                 lastIdx  == LastLogIndex(i)
                 entries == IF nextIndex[i][j] > lastIdx
                            THEN <<>>
                            ELSE SubSeq(log[i], nextIndex[i][j] - purgedUpTo[i],
                                                lastIdx - purgedUpTo[i])
             IN
             /\ Send([mtype         |-> AppendEntriesRequest,
                      mterm         |-> currentTerm[i],
                      mprevLogIndex |-> prevIdx,
                      mprevLogTerm  |-> prevTerm,
                      mentries      |-> entries,
                      mcommitIndex  |-> commitIndex[i],
                      msource       |-> i,
                      mdest         |-> j])
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>
    /\ traceIdx' = traceIdx + 1

\* Handle AppendEntries on follower
TraceHandleAppendEntries ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "HandleAppendEntries"
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = AppendEntriesRequest
           /\ m.mdest = ll.node
           /\ m.msource = ll.source
           /\ HandleAppendEntries(ll.node, m)
    /\ traceIdx' = traceIdx + 1

\* Handle AppendEntries response on leader.
\* Self-responses (source == node) are no-ops — the leader already
\* tracks its own matchIndex via ClientRequest/EstablishLeader.
TraceHandleAppendEntriesResponse ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "HandleAppendEntriesResponse"
       /\ \/ \* Remote response: find message in bag
             /\ ll.source # ll.node
             /\ \E m \in DOMAIN messages :
                 /\ m.mtype = AppendEntriesResponse
                 /\ m.mdest = ll.node
                 /\ m.msource = ll.source
                 /\ HandleAppendEntriesResponse(ll.node, m)
          \/ \* Self-response: no-op
             /\ ll.source = ll.node
             /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                            messages, snapshotVars, configVars, leaseActive, crashed>>
    /\ traceIdx' = traceIdx + 1

\* Advance commit index
TraceAdvanceCommitIndex ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "AdvanceCommitIndex"
       /\ AdvanceCommitIndex(ll.node)
    /\ traceIdx' = traceIdx + 1

\* Trigger snapshot
TraceTriggerSnapshot ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "TriggerSnapshot"
       /\ TriggerSnapshot(ll.node)
    /\ traceIdx' = traceIdx + 1

\* Purge log
TracePurgeLog ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "PurgeLog"
       /\ PurgeLog(ll.node)
    /\ traceIdx' = traceIdx + 1

\* Send install snapshot — override: allow any target (not just voters)
TraceSendInstallSnapshot ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "SendInstallSnapshot"
       /\ LET i == ll.node
              j == ll.target
          IN
          /\ ~crashed[i]
          /\ state[i] = Leader
          /\ j # i
          /\ nextIndex[i][j] <= purgedUpTo[i]
          /\ snapshot[i].lastIndex > 0
          /\ Send([mtype      |-> InstallSnapshotRequest,
                   mterm      |-> currentTerm[i],
                   mlastIndex |-> snapshot[i].lastIndex,
                   mlastTerm  |-> snapshot[i].lastTerm,
                   mconfig    |-> config[i],
                   msource    |-> i,
                   mdest      |-> j])
          /\ UNCHANGED <<serverVars, logVars, leaderVars, candidateVars,
                         snapshotVars, configVars, leaseActive, crashed>>
    /\ traceIdx' = traceIdx + 1

\* Handle install snapshot on follower
TraceHandleInstallSnapshot ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "HandleInstallSnapshot"
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = InstallSnapshotRequest
           /\ m.mdest = ll.node
           /\ m.msource = ll.source
           /\ HandleInstallSnapshot(ll.node, m)
    /\ traceIdx' = traceIdx + 1

\* Handle install snapshot response
TraceHandleInstallSnapshotResponse ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "HandleInstallSnapshotResponse"
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = InstallSnapshotResponse
           /\ m.mdest = ll.node
           /\ m.msource = ll.source
           /\ HandleInstallSnapshotResponse(ll.node, m)
    /\ traceIdx' = traceIdx + 1

\* Propose config change
TraceProposeConfigChange ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "ProposeConfigChange"
       /\ LET newVoters == {ll.newVoters[k] : k \in DOMAIN ll.newVoters}
          IN ProposeConfigChange(ll.node, newVoters)
    /\ traceIdx' = traceIdx + 1

\* Commit config change
TraceCommitConfigChange ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "CommitConfigChange"
       /\ CommitConfigChange(ll.node)
    /\ traceIdx' = traceIdx + 1

\* Lease expire
TraceLeaseExpire ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "LeaseExpire"
       /\ LeaseExpire(ll.node)
    /\ traceIdx' = traceIdx + 1

\* Crash
TraceCrash ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "Crash"
       /\ Crash(ll.node)
    /\ traceIdx' = traceIdx + 1

\* Restart
TraceRestart ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "Restart"
       /\ Restart(ll.node)
    /\ traceIdx' = traceIdx + 1

\* Leader step down
TraceLeaderStepDown ==
    /\ ~TraceFinished
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "LeaderStepDown"
       /\ LeaderStepDown(ll.node)
    /\ traceIdx' = traceIdx + 1

----
\* Silent actions
----

\* Silent: advance commit when next event requires higher commitIndex.
\* Guard: don't fire when next event IS AdvanceCommitIndex — let the
\* traced action handle it to avoid overshooting commitIndex.
SilentAdvanceCommitIndex ==
    /\ ~TraceFinished
    /\ traceIdx <= Len(TraceLog)
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event # "AdvanceCommitIndex"
       /\ \E i \in Server :
            /\ state[i] = Leader
            /\ ~crashed[i]
            /\ "post" \in DOMAIN ll
            /\ "commitIndex" \in DOMAIN ll.post
            /\ ll.node = i
            /\ ll.post.commitIndex > commitIndex[i]
            /\ AdvanceCommitIndex(i)
    /\ UNCHANGED traceIdx

\* Silent: establish leader when next event expects Leader state.
\* Guard: don't fire when next event IS EstablishLeader.
SilentEstablishLeader ==
    /\ ~TraceFinished
    /\ traceIdx <= Len(TraceLog)
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event # "EstablishLeader"
       /\ \E i \in Server :
            /\ state[i] = Candidate
            /\ ~crashed[i]
            /\ "post" \in DOMAIN ll
            /\ "state" \in DOMAIN ll.post
            /\ ll.node = i
            /\ ll.post.state = "Leader"
            /\ EstablishLeader(i)
    /\ UNCHANGED traceIdx

\* Silent: purge log (may happen between any two events)
SilentPurgeLog ==
    /\ ~TraceFinished
    /\ traceIdx <= Len(TraceLog)
    /\ \E i \in Server :
        /\ ~crashed[i]
        /\ snapshot[i].lastIndex > purgedUpTo[i]
        /\ PurgeLog(i)
    /\ UNCHANGED traceIdx

\* Silent: leader appends un-traced entries (membership/learner entries
\* from bootstrap that are not instrumented).
\* Constrained: only fires when the NEXT event for this node expects
\* a higher lastLogIndex than the current spec state.
SilentLeaderAppend ==
    /\ ~TraceFinished
    /\ traceIdx <= Len(TraceLog)
    /\ LET ll == TraceLog[traceIdx]
       IN
       \E i \in Server :
        /\ state[i] = Leader
        /\ ~crashed[i]
        /\ ll.node = i
        /\ "post" \in DOMAIN ll
        /\ "lastLogIndex" \in DOMAIN ll.post
        /\ ll.post.lastLogIndex > LastLogIndex(i)
        /\ LET entry == [term  |-> currentTerm[i],
                          type  |-> ValueEntry,
                          value |-> Nil]
               newIdx == LastLogIndex(i) + 1
           IN
           /\ log' = [log EXCEPT ![i] = Append(@, entry)]
           /\ matchIndex' = [matchIndex EXCEPT ![i][i] = newIdx]
           /\ nextIndex'  = [nextIndex EXCEPT ![i][i] = newIdx + 1]
        /\ UNCHANGED <<serverVars, commitIndex, candidateVars, messages,
                       snapshotVars, configVars, leaseActive, crashed>>
    /\ UNCHANGED traceIdx

\* Silent: process failure AppendEntriesResponse to decrement nextIndex.
\* This handles the case where the implementation retries after a log
\* mismatch. The failure response isn't a traced event — it's handled
\* internally by the replication task.
\* Guard: only fire when next event is NOT HandleAppendEntriesResponse
\* (to avoid stealing traced events' messages).
SilentHandleFailResponse ==
    /\ ~TraceFinished
    /\ traceIdx <= Len(TraceLog)
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event # "HandleAppendEntriesResponse"
       /\ \E m \in DOMAIN messages :
           /\ m.mtype = AppendEntriesResponse
           /\ ~m.msuccess
           /\ m.mterm = currentTerm[m.mdest]
           /\ state[m.mdest] = Leader
           /\ HandleAppendEntriesResponse(m.mdest, m)
    /\ UNCHANGED traceIdx

\* Silent: leader sends AppendEntries to follower when the next event
\* requires a message that doesn't exist. Covers:
\* - HandleAppendEntries (follower needs a request)
\* - HandleAppendEntriesResponse from remote (need request→handle→response chain)
SilentReplicateEntries ==
    /\ ~TraceFinished
    /\ traceIdx <= Len(TraceLog)
    /\ LET ll == TraceLog[traceIdx]
       IN
       \* Determine leader and target based on event type
       /\ \E i \in Server, j \in Server :
          /\ state[i] = Leader
          /\ ~crashed[i]
          /\ j # i
          /\ \/ /\ ll.event = "HandleAppendEntries"
                /\ ll.source = i /\ ll.node = j
             \/ /\ ll.event = "HandleAppendEntriesResponse"
                /\ ll.source # ll.node  \* Not self-response
                /\ ll.node = i /\ ll.source = j
          \* Only send if no matching message already exists
          /\ ~(\E m \in DOMAIN messages :
                m.mtype = AppendEntriesRequest /\ m.mdest = j /\ m.msource = i)
          /\ nextIndex[i][j] > purgedUpTo[i]
          /\ LET prevIdx  == nextIndex[i][j] - 1
                 prevTerm == LogTerm(i, prevIdx)
                 lastIdx  == LastLogIndex(i)
                 entries == IF nextIndex[i][j] > lastIdx
                            THEN <<>>
                            ELSE SubSeq(log[i], nextIndex[i][j] - purgedUpTo[i],
                                                lastIdx - purgedUpTo[i])
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
                         snapshotVars, configVars, leaseActive, crashed>>
    /\ UNCHANGED traceIdx

\* Silent: process AppendEntries for a follower when the next event is
\* HandleAppendEntriesResponse but no response exists yet.
\* This bridges the gap where the implementation's replication task
\* handles the message exchange internally without separate trace events.
SilentHandleAppendEntries ==
    /\ ~TraceFinished
    /\ traceIdx <= Len(TraceLog)
    /\ LET ll == TraceLog[traceIdx]
       IN
       /\ ll.event = "HandleAppendEntriesResponse"
       /\ LET src == ll.source
              dest == ll.node
          IN
          \* Need a response from src, but don't have one
          /\ ~(\E resp \in DOMAIN messages :
                resp.mtype = AppendEntriesResponse
                /\ resp.msource = src /\ resp.mdest = dest)
          \* Process a pending request for src
          /\ \E m \in DOMAIN messages :
              /\ m.mtype = AppendEntriesRequest
              /\ m.mdest = src
              /\ HandleAppendEntries(src, m)
    /\ UNCHANGED traceIdx

----
\* TraceInit
----

\* Initial state: single-node bootstrap (node 1 only).
\* Config stays at <<{1}>> — openraft replicates to learners without
\* requiring voter membership. ReplicateEntries is overridden above.
TraceInit ==
    /\ currentTerm    = [s \in Server |-> 0]
    /\ votedFor       = [s \in Server |-> Nil]
    /\ voteCommitted  = [s \in Server |-> FALSE]
    /\ log            = [s \in Server |-> <<>>]
    /\ state          = [s \in Server |-> Follower]
    /\ commitIndex    = [s \in Server |-> 0]
    /\ leaseActive    = [s \in Server |-> FALSE]
    /\ votesGranted   = [s \in Server |-> {}]
    /\ nextIndex      = [s \in Server |-> [t \in Server |-> 1]]
    /\ matchIndex     = [s \in Server |-> [t \in Server |-> 0]]
    /\ messages       = EmptyBag
    /\ snapshot       = [s \in Server |-> [lastIndex |-> 0, lastTerm |-> 0]]
    /\ purgedUpTo     = [s \in Server |-> 0]
    /\ config         = [s \in Server |-> <<{1}>>]
    /\ crashed        = [s \in Server |-> FALSE]
    /\ traceIdx       = 1

----
\* TraceNext
----

TraceNext ==
    \* Traced actions
    \/ TraceElect
    \/ TraceHandleVoteRequest
    \/ TraceHandleVoteResponse
    \/ TraceEstablishLeader
    \/ TraceClientRequest
    \/ TraceSendHeartbeat
    \/ TraceReplicateEntries
    \/ TraceHandleAppendEntries
    \/ TraceHandleAppendEntriesResponse
    \/ TraceAdvanceCommitIndex
    \/ TraceTriggerSnapshot
    \/ TracePurgeLog
    \/ TraceSendInstallSnapshot
    \/ TraceHandleInstallSnapshot
    \/ TraceHandleInstallSnapshotResponse
    \/ TraceProposeConfigChange
    \/ TraceCommitConfigChange
    \/ TraceLeaseExpire
    \/ TraceCrash
    \/ TraceRestart
    \/ TraceLeaderStepDown
    \* Silent actions
    \/ SilentAdvanceCommitIndex
    \/ SilentEstablishLeader
    \/ SilentPurgeLog
    \/ SilentLeaderAppend
    \/ SilentHandleFailResponse
    \/ SilentReplicateEntries
    \/ SilentHandleAppendEntries

TraceSpec == TraceInit /\ [][TraceNext]_traceVars

----
\* Trace completion check
----

TraceMatched == <>(traceIdx > Len(TraceLog))

====
