-------------------------------- MODULE MC -------------------------------------
\* Model checking wrapper for tarantool Raft base spec.
\* Counter-bounds fault-injection actions; passes through reactive actions.

EXTENDS base

\* Counter-bounded action limits
CONSTANTS
    MaxTerm,            \* Max term any server can reach
    TimeoutLimit,       \* Max election timeouts across all servers
    CrashLimit,         \* Max crash events
    HeartbeatLimit,     \* Max heartbeats sent
    LoseLimit,          \* Max messages lost
    PromoteLimit,       \* Max promote invocations
    VclockAdvanceLimit, \* Max vclock advances
    ResignLimit,        \* Max leader resignations
    NotifyLimit,        \* Max notify leader seen calls
    BroadcastLimit      \* Max broadcast calls

VARIABLES
    timeoutCount,
    crashCount,
    heartbeatCount,
    loseCount,
    promoteCount,
    vclockAdvanceCount,
    resignCount,
    notifyCount,
    broadcastCount

faultVars == <<timeoutCount, crashCount, heartbeatCount, loseCount,
               promoteCount, vclockAdvanceCount, resignCount,
               notifyCount, broadcastCount>>

MCInit ==
    /\ Init
    /\ timeoutCount       = 0
    /\ crashCount         = 0
    /\ heartbeatCount     = 0
    /\ loseCount          = 0
    /\ promoteCount       = 0
    /\ vclockAdvanceCount = 0
    /\ resignCount        = 0
    /\ notifyCount        = 0
    /\ broadcastCount     = 0

\* --- Counter-bounded wrappers (fault-injection actions) ---

MCElectionTimeout(s) ==
    /\ timeoutCount < TimeoutLimit
    /\ volatileTerm[s] < MaxTerm
    /\ ElectionTimeout(s)
    /\ timeoutCount' = timeoutCount + 1
    /\ UNCHANGED <<crashCount, heartbeatCount, loseCount, promoteCount,
                   vclockAdvanceCount, resignCount, notifyCount, broadcastCount>>

MCCrash(s) ==
    /\ crashCount < CrashLimit
    /\ Crash(s)
    /\ crashCount' = crashCount + 1
    /\ UNCHANGED <<timeoutCount, heartbeatCount, loseCount, promoteCount,
                   vclockAdvanceCount, resignCount, notifyCount, broadcastCount>>

MCLeaderSendHeartbeat(s) ==
    /\ heartbeatCount < HeartbeatLimit
    /\ LeaderSendHeartbeat(s)
    /\ heartbeatCount' = heartbeatCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, loseCount, promoteCount,
                   vclockAdvanceCount, resignCount, notifyCount, broadcastCount>>

MCLoseMessage(m) ==
    /\ loseCount < LoseLimit
    /\ LoseMessage(m)
    /\ loseCount' = loseCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, heartbeatCount, promoteCount,
                   vclockAdvanceCount, resignCount, notifyCount, broadcastCount>>

MCPromote(s) ==
    /\ promoteCount < PromoteLimit
    /\ volatileTerm[s] < MaxTerm
    /\ Promote(s)
    /\ promoteCount' = promoteCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, heartbeatCount, loseCount,
                   vclockAdvanceCount, resignCount, notifyCount, broadcastCount>>

MCAdvanceVclock(s) ==
    /\ vclockAdvanceCount < VclockAdvanceLimit
    /\ AdvanceVclock(s)
    /\ vclockAdvanceCount' = vclockAdvanceCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, heartbeatCount, loseCount,
                   promoteCount, resignCount, notifyCount, broadcastCount>>

MCLeaderResign(s) ==
    /\ resignCount < ResignLimit
    /\ LeaderResign(s)
    /\ resignCount' = resignCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, heartbeatCount, loseCount,
                   promoteCount, vclockAdvanceCount, notifyCount, broadcastCount>>

\* --- Unconstrained wrappers (reactive/deterministic actions) ---

MCReceiveMessage(s, m) ==
    /\ ReceiveMessage(s, m)
    /\ UNCHANGED faultVars

MCReceiveHeartbeat(s, m) ==
    /\ ReceiveHeartbeat(s, m)
    /\ UNCHANGED faultVars

MCBroadcastRaftState(s) ==
    /\ broadcastCount < BroadcastLimit
    /\ BroadcastRaftState(s)
    /\ broadcastCount' = broadcastCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, heartbeatCount, loseCount,
                   promoteCount, vclockAdvanceCount, resignCount, notifyCount>>

MCWalWriteTermOnly(s) ==
    /\ WalWriteTermOnly(s)
    /\ UNCHANGED faultVars

MCWalWriteTermAndVote(s) ==
    /\ WalWriteTermAndVote(s)
    /\ UNCHANGED faultVars

MCWalWriteRevokeVote(s) ==
    /\ WalWriteRevokeVote(s)
    /\ UNCHANGED faultVars

MCWalWriteTermOnlyNonVote(s) ==
    /\ WalWriteTermOnlyNonVote(s)
    /\ UNCHANGED faultVars

MCCompleteWalWrite(s) ==
    /\ CompleteWalWrite(s)
    /\ UNCHANGED faultVars

MCNotifyLeaderSeen(s, source, isSeen) ==
    /\ notifyCount < NotifyLimit
    /\ NotifyLeaderSeen(s, source, isSeen)
    /\ notifyCount' = notifyCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, heartbeatCount, loseCount,
                   promoteCount, vclockAdvanceCount, resignCount, broadcastCount>>

\* --- MCNext ---

MCNext ==
    \/ \E s \in Server :
        \/ MCElectionTimeout(s)
        \/ MCBroadcastRaftState(s)
        \/ MCLeaderSendHeartbeat(s)
        \/ MCCrash(s)
        \/ MCPromote(s)
        \/ MCLeaderResign(s)
        \/ MCAdvanceVclock(s)
        \/ MCWalWriteTermOnly(s)
        \/ MCWalWriteTermAndVote(s)
        \/ MCWalWriteRevokeVote(s)
        \/ MCWalWriteTermOnlyNonVote(s)
        \/ MCCompleteWalWrite(s)
    \/ \E s \in Server, m \in messages :
        \/ MCReceiveMessage(s, m)
        \/ MCReceiveHeartbeat(s, m)
    \/ \E m \in messages : MCLoseMessage(m)
    \* External callers (replica_on_disconnect, replica_update_applier_health)
    \* only pass FALSE to raft_notify_is_leader_seen. TRUE is only from
    \* raft_process_msg which is already handled by MCReceiveMessage.
    \/ \E s \in Server, source \in Server :
        MCNotifyLeaderSeen(s, source, FALSE)

MCSpec == MCInit /\ [][MCNext]_<<allVars, faultVars>>

\* --- Symmetry ---

ModelSymmetry == Permutations(Server)

\* --- State space constraint ---

MaxMsgBuffer == Cardinality(messages) <= 6

\* --- Structural Invariants ---

MCElectionSafety     == ElectionSafety
MCWalWriteSafety     == WalWriteSafety
MCTermMonotonicity   == TermMonotonicity
MCLeaderKnowsSelf    == LeaderKnowsSelf
MCNotWritingWhenLeader == NotWritingWhenLeader
MCWitnessMapBounded  == WitnessMapBounded
MCCandidateVotedForSelf == CandidateVotedForSelf

\* --- Extension Invariants (for bug hunting) ---

MCOneVotePerTerm        == OneVotePerTerm
MCNoStaleVoteAfterCrash == NoStaleVoteAfterCrash
MCWitnessMapAccuracy    == WitnessMapAccuracy
MCPromoteNotDuringWrite == PromoteNotDuringWrite
MCLeaderHasVotedForSelf == LeaderHasVotedForSelf
MCVoteConsistency       == VoteConsistency

====
