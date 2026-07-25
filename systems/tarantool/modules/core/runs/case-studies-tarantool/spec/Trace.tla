------------------------------- MODULE Trace -----------------------------------
\* Trace validation spec for Tarantool Raft.
\* Replays NDJSON traces against the base spec to verify consistency.

EXTENDS base, Json, IOUtils, Sequences, TLC, Integers, FiniteSets

\* --- Trace Loading ---

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTraceLog == ndJsonDeserialize(JsonFile)

\* Filter to only raft events (exclude non-raft trace lines)
TraceLog == SelectSeq(RawTraceLog, LAMBDA e : "event" \in DOMAIN e)

\* --- Cursor Variable ---

VARIABLE l   \* Trace cursor: walks from 1 to Len(TraceLog)+1

traceVars == <<l>>

\* Current log line
logline == TraceLog[l]

\* --- Server Set Extraction ---
\* Derive Server set from trace: all unique "node" fields
TraceServer == {TraceLog[i].node : i \in 1..Len(TraceLog)}

\* --- Role Mapping ---
MapState(s) ==
    CASE s = "follower"  -> "Follower"
      [] s = "candidate" -> "Candidate"
      [] s = "leader"    -> "Leader"
      [] OTHER           -> "Follower"

\* --- Event Predicates ---

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

IsNodeEvent(name, s) ==
    /\ IsEvent(name)
    /\ logline.node = s

IsMsgEvent(name, from, to) ==
    /\ IsEvent(name)
    /\ logline.from = from
    /\ logline.to = to

\* --- Post-State Validation ---

\* Strong validation: check state, term, vote, leader
ValidatePostState(s) ==
    /\ IF "state" \in DOMAIN logline
       THEN state'[s] = MapState(logline.state) ELSE TRUE
    /\ IF "volatileTerm" \in DOMAIN logline
       THEN volatileTerm'[s] = logline.volatileTerm ELSE TRUE
    /\ IF "volatileVote" \in DOMAIN logline
       THEN volatileVote'[s] = logline.volatileVote ELSE TRUE
    /\ IF "leader" \in DOMAIN logline
       THEN leader'[s] = logline.leader ELSE TRUE

\* Weak validation: check only state and term
ValidatePostStateWeak(s) ==
    /\ IF "state" \in DOMAIN logline
       THEN state'[s] = MapState(logline.state) ELSE TRUE
    /\ IF "volatileTerm" \in DOMAIN logline
       THEN volatileTerm'[s] = logline.volatileTerm ELSE TRUE

\* --- Action Wrappers ---

\* Each wrapper: match event → call base action → validate → advance cursor

TraceElectionTimeout ==
    /\ IsEvent("election_timeout")
    /\ LET s == logline.node IN
       /\ ElectionTimeout(s)
       /\ ValidatePostState(s)
       /\ l' = l + 1

TraceReceiveMessage ==
    /\ IsEvent("receive_message")
    /\ LET s == logline.to IN
       /\ \E m \in messages :
            /\ m.type = RaftMessage
            /\ m.from = logline.from
            /\ ReceiveMessage(s, m)
       /\ ValidatePostState(s)
       /\ l' = l + 1

TraceReceiveHeartbeat ==
    /\ IsEvent("receive_heartbeat")
    /\ LET s == logline.to IN
       /\ \E m \in messages :
            /\ m.type = Heartbeat
            /\ m.from = logline.from
            /\ ReceiveHeartbeat(s, m)
       /\ ValidatePostStateWeak(s)
       /\ l' = l + 1

TraceWalWriteTermOnly ==
    /\ IsEvent("wal_write_term_only")
    /\ LET s == logline.node IN
       /\ WalWriteTermOnly(s)
       /\ ValidatePostStateWeak(s)
       /\ l' = l + 1

TraceWalWriteTermAndVote ==
    /\ IsEvent("wal_write_term_and_vote")
    /\ LET s == logline.node IN
       /\ WalWriteTermAndVote(s)
       /\ ValidatePostStateWeak(s)
       /\ l' = l + 1

TraceWalWriteRevokeVote ==
    /\ IsEvent("wal_write_revoke_vote")
    /\ LET s == logline.node IN
       /\ WalWriteRevokeVote(s)
       /\ ValidatePostState(s)
       /\ l' = l + 1

TraceWalWriteTermOnlyNonVote ==
    /\ IsEvent("wal_write_term_no_vote")
    /\ LET s == logline.node IN
       /\ WalWriteTermOnlyNonVote(s)
       /\ ValidatePostStateWeak(s)
       /\ l' = l + 1

TraceCompleteWalWrite ==
    /\ IsEvent("complete_wal_write")
    /\ LET s == logline.node IN
       /\ CompleteWalWrite(s)
       /\ ValidatePostState(s)
       /\ l' = l + 1

TraceBroadcastRaftState ==
    /\ IsEvent("broadcast_state")
    /\ LET s == logline.node IN
       /\ BroadcastRaftState(s)
       /\ l' = l + 1

TraceLeaderSendHeartbeat ==
    /\ IsEvent("send_heartbeat")
    /\ LET s == logline.node IN
       /\ LeaderSendHeartbeat(s)
       /\ l' = l + 1

TraceCrash ==
    /\ IsEvent("crash")
    /\ LET s == logline.node IN
       /\ Crash(s)
       /\ l' = l + 1

TracePromote ==
    /\ IsEvent("promote")
    /\ LET s == logline.node IN
       /\ Promote(s)
       /\ ValidatePostState(s)
       /\ l' = l + 1

TraceLeaderResign ==
    /\ IsEvent("leader_resign")
    /\ LET s == logline.node IN
       /\ LeaderResign(s)
       /\ ValidatePostState(s)
       /\ l' = l + 1

TraceNotifyLeaderSeen ==
    /\ IsEvent("notify_leader_seen")
    /\ LET s == logline.node
           source == logline.source
           isSeen == logline.isLeaderSeen
       IN
       /\ NotifyLeaderSeen(s, source, isSeen)
       /\ l' = l + 1

TraceAdvanceVclock ==
    /\ IsEvent("advance_vclock")
    /\ LET s == logline.node IN
       /\ AdvanceVclock(s)
       /\ l' = l + 1

\* --- Silent Actions ---
\* Fire base actions without consuming a trace event.
\* MUST be tightly constrained to avoid state space explosion.
\*
\* Key constraint: a silent action for server s must NOT fire if the
\* current trace event is the same action type for that server.
\* Otherwise silent actions race with trace events and consume the
\* spec transition before the trace event can match.

\* Helper: is the current trace event a WAL/complete event for server s?
IsCurrentWalEventFor(s) ==
    /\ l <= Len(TraceLog)
    /\ logline.node = s
    /\ logline.event \in {"wal_write_term_only", "wal_write_term_and_vote",
                           "wal_write_revoke_vote", "wal_write_term_no_vote",
                           "complete_wal_write"}

IsCurrentBroadcastFor(s) ==
    /\ l <= Len(TraceLog)
    /\ logline.node = s
    /\ logline.event = "broadcast_state"

SilentBroadcastRaftState ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Server :
        /\ ~isWriteInProgress[s]
        /\ ~IsCurrentBroadcastFor(s)
        /\ BroadcastRaftState(s)
    /\ UNCHANGED l

SilentLoseMessage ==
    /\ l <= Len(TraceLog)
    /\ \E m \in messages :
        /\ LoseMessage(m)
    /\ UNCHANGED l

SilentCompleteWalWrite ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Server :
        /\ isWriteInProgress[s]
        /\ IsFullyOnDisk(s)
        /\ ~IsCurrentWalEventFor(s)
        /\ CompleteWalWrite(s)
    /\ UNCHANGED l

SilentWalWriteTermOnly ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Server :
        /\ isWriteInProgress[s]
        /\ ~IsFullyOnDisk(s)
        /\ volatileVote[s] # Nil
        /\ volatileVote[s] # s
        /\ volatileTerm[s] > persistedTerm[s]
        /\ ~IsCurrentWalEventFor(s)
        /\ WalWriteTermOnly(s)
    /\ UNCHANGED l

SilentWalWriteTermAndVote ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Server :
        /\ isWriteInProgress[s]
        /\ ~IsFullyOnDisk(s)
        /\ volatileVote[s] # Nil
        /\ \/ volatileVote[s] = s
           \/ /\ volatileTerm[s] = persistedTerm[s]
              /\ CanVoteFor(s, candidateVclock[s])
        /\ ~IsCurrentWalEventFor(s)
        /\ WalWriteTermAndVote(s)
    /\ UNCHANGED l

SilentWalWriteTermOnlyNonVote ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Server :
        /\ isWriteInProgress[s]
        /\ ~IsFullyOnDisk(s)
        /\ volatileVote[s] = Nil
        /\ ~IsCurrentWalEventFor(s)
        /\ WalWriteTermOnlyNonVote(s)
    /\ UNCHANGED l

\* --- TraceInit ---

TraceInit ==
    /\ Init
    /\ l = 1

\* --- TraceNext ---

TraceNext ==
    \/ TraceElectionTimeout
    \/ TraceReceiveMessage
    \/ TraceReceiveHeartbeat
    \/ TraceWalWriteTermOnly
    \/ TraceWalWriteTermAndVote
    \/ TraceWalWriteRevokeVote
    \/ TraceWalWriteTermOnlyNonVote
    \/ TraceCompleteWalWrite
    \/ TraceBroadcastRaftState
    \/ TraceLeaderSendHeartbeat
    \/ TraceCrash
    \/ TracePromote
    \/ TraceLeaderResign
    \/ TraceNotifyLeaderSeen
    \/ TraceAdvanceVclock
    \* Silent actions
    \/ SilentBroadcastRaftState
    \/ SilentLoseMessage
    \/ SilentCompleteWalWrite
    \/ SilentWalWriteTermOnly
    \/ SilentWalWriteTermAndVote
    \/ SilentWalWriteTermOnlyNonVote

TraceSpec == TraceInit /\ [][TraceNext]_<<allVars, traceVars>>

\* --- Trace Completeness ---

TraceMatched == <>(l = Len(TraceLog) + 1)

\* Alias for debugging
TraceAlias ==
    [
        cursor     |-> l,
        event      |-> IF l <= Len(TraceLog) THEN logline.event ELSE "DONE",
        traceLen   |-> Len(TraceLog),
        state      |-> state,
        volTerm    |-> volatileTerm,
        volVote    |-> volatileVote,
        perTerm    |-> persistedTerm,
        perVote    |-> persistedVote,
        leader     |-> leader,
        witnessMap |-> leaderWitnessMap,
        wip        |-> isWriteInProgress,
        msgCount   |-> Cardinality(messages)
    ]

====
