------------------------------ MODULE MC ------------------------------
\* Model checking wrapper for Aeron Cluster consensus specification.
\* Adds counter-bounded fault injection, symmetry reduction,
\* message buffer constraints, and structural invariants.
\*
\* Counter-bounded actions: Timeout, Crash, ClientRequest, LoseMessage,
\*   MemberBecomeInactive, LeaderAppendSessionOpen, PublishCommitPosition
\* Unconstrained (reactive): all message handlers, BecomeLeader,
\*   FollowerReplicateLog, LeaderAdvanceCommitPosition, EnterCanvass,
\*   SendCanvassPosition, SendAppendPositionUpdate, DropStaleMessage

EXTENDS base

\* Counter limits (tuned via cfg overrides)
CONSTANTS MaxTimeoutLimit,       \* Election timeouts per server
          MaxCrashLimit,         \* Crash-recovery cycles
          MaxRequestLimit,       \* Client requests (log entries)
          MaxLoseLimit,          \* Messages lost
          MaxInactiveLimit,      \* Member inactivity events
          MaxSessionLimit,       \* Session-open appends (Family 5)
          MaxPublishLimit,       \* Commit position broadcasts
          MaxTermLimit           \* Max candidateTermId (state space bound)

\* Counter record
VARIABLE mc
mcVars == <<mc>>

MCInit ==
    /\ Init
    /\ mc = [timeouts    |-> [s \in Server |-> 0],
             crashes     |-> [s \in Server |-> 0],
             requests    |-> 0,
             loses       |-> 0,
             inactives   |-> 0,
             sessions    |-> 0,
             publishes   |-> [s \in Server |-> 0]]

\* --- Counter-bounded wrappers ---

MCTimeout(i) ==
    /\ mc.timeouts[i] < MaxTimeoutLimit
    /\ Timeout(i)
    /\ mc' = [mc EXCEPT !.timeouts[i] = mc.timeouts[i] + 1]

MCCrash(i) ==
    /\ mc.crashes[i] < MaxCrashLimit
    /\ Crash(i)
    /\ mc' = [mc EXCEPT !.crashes[i] = mc.crashes[i] + 1]

MCClientRequest(i) ==
    /\ mc.requests < MaxRequestLimit
    /\ ClientRequest(i)
    /\ mc' = [mc EXCEPT !.requests = mc.requests + 1]

MCLoseMessage(m) ==
    /\ mc.loses < MaxLoseLimit
    /\ LoseMessage(m)
    /\ mc' = [mc EXCEPT !.loses = mc.loses + 1]

MCMemberBecomeInactive(i) ==
    /\ mc.inactives < MaxInactiveLimit
    /\ MemberBecomeInactive(i)
    /\ mc' = [mc EXCEPT !.inactives = mc.inactives + 1]

MCLeaderAppendSessionOpen(i) ==
    /\ mc.sessions < MaxSessionLimit
    /\ LeaderAppendSessionOpen(i)
    /\ mc' = [mc EXCEPT !.sessions = mc.sessions + 1]

MCPublishCommitPosition(i) ==
    /\ mc.publishes[i] < MaxPublishLimit
    /\ PublishCommitPosition(i)
    /\ mc' = [mc EXCEPT !.publishes[i] = mc.publishes[i] + 1]

\* --- Unconstrained wrappers (reactive/deterministic actions) ---

UCEnterCanvass(i) == EnterCanvass(i) /\ UNCHANGED mcVars
UCNominate(i) == Nominate(i) /\ UNCHANGED mcVars
UCBecomeLeader(i) == BecomeLeader(i) /\ UNCHANGED mcVars
UCFollowerReplicateLog(i) == FollowerReplicateLog(i) /\ UNCHANGED mcVars
UCSendAppendPositionUpdate(i) == SendAppendPositionUpdate(i) /\ UNCHANGED mcVars
UCLeaderAdvanceCommitPosition(i) == LeaderAdvanceCommitPosition(i) /\ UNCHANGED mcVars
UCMemberBecomeActive(i) == MemberBecomeActive(i) /\ UNCHANGED mcVars
UCSendCanvassPosition(i, j) == SendCanvassPosition(i, j) /\ UNCHANGED mcVars
UCHandleCanvassPosition(i, m) == HandleCanvassPosition(i, m) /\ UNCHANGED mcVars
UCHandleRequestVote(i, m) == HandleRequestVote(i, m) /\ UNCHANGED mcVars
UCHandleRequestVoteResponse(i, m) == HandleRequestVoteResponse(i, m) /\ UNCHANGED mcVars
UCHandleNewLeadershipTerm(i, m) == HandleNewLeadershipTerm(i, m) /\ UNCHANGED mcVars
UCHandleAppendPositionUpdate(i, m) == HandleAppendPositionUpdate(i, m) /\ UNCHANGED mcVars
UCFollowerReceiveCommitPosition(i, m) == FollowerReceiveCommitPosition(i, m) /\ UNCHANGED mcVars
UCElectionReceiveCommitPosition(i, m) == ElectionReceiveCommitPosition(i, m) /\ UNCHANGED mcVars
UCLeaderDetectHigherTerm(i, m) == LeaderDetectHigherTerm(i, m) /\ UNCHANGED mcVars
UCDropStaleMessage(m) == DropStaleMessage(m) /\ UNCHANGED mcVars

\* --- MCNext ---

MCNext ==
    \/ \E i \in Server :
        \/ UCEnterCanvass(i)
        \/ UCNominate(i)
        \/ UCBecomeLeader(i)
        \/ MCClientRequest(i)
        \/ MCLeaderAppendSessionOpen(i)
        \/ UCFollowerReplicateLog(i)
        \/ UCSendAppendPositionUpdate(i)
        \/ UCLeaderAdvanceCommitPosition(i)
        \/ MCPublishCommitPosition(i)
        \/ MCTimeout(i)
        \/ MCCrash(i)
        \/ UCMemberBecomeActive(i)
        \/ MCMemberBecomeInactive(i)
    \/ \E i, j \in Server :
        /\ i # j
        /\ UCSendCanvassPosition(i, j)
    \/ \E m \in DOMAIN messages :
        \/ UCHandleCanvassPosition(m.mdest, m)
        \/ UCHandleRequestVote(m.mdest, m)
        \/ UCHandleRequestVoteResponse(m.mdest, m)
        \/ UCHandleNewLeadershipTerm(m.mdest, m)
        \/ UCHandleAppendPositionUpdate(m.mdest, m)
        \/ UCFollowerReceiveCommitPosition(m.mdest, m)
        \/ UCElectionReceiveCommitPosition(m.mdest, m)
        \/ UCLeaderDetectHigherTerm(m.mdest, m)
        \/ MCLoseMessage(m)
        \/ UCDropStaleMessage(m)

MCSpec == MCInit /\ [][MCNext]_<<vars, mcVars>>

\* --- Symmetry ---

MCSymmetry == Permutations(Server)

\* --- State space constraint ---

\* Bound candidateTermId to prevent unbounded term inflation
TermBound == \A i \in Server : candidateTermId[i] <= MaxTermLimit

\* Bound message buffer to prevent state explosion
MaxMsgBufferLimit == 12
MsgBufferConstraint == BagCardinality(messages) <= MaxMsgBufferLimit

StateConstraint == TermBound /\ MsgBufferConstraint

\* --- Structural invariants (always checked) ---

\* All structural invariants from base spec
MCElectionSafety == ElectionSafety
MCLogMatching == LogMatching
MCTruncationSafety == TruncationSafety
MCCommitBound == CommitBound
MCTermConsistency == TermConsistency
MCVoteRecovery == VoteRecovery
MCNotifiedCommitBound == NotifiedCommitBound

\* --- Extension invariants (bug-family specific, commented out in MC.cfg) ---
\* Enable selectively in hunting configs.

MCLeaderCompleteness == LeaderCompleteness
MCCommitBoundedByQuorum == CommitBoundedByQuorum
MCNoUncommittedReplay == NoUncommittedReplay
MCVoteUniqueness == VoteUniqueness
MCSnapshotConsistency == SnapshotConsistency

\* --- Temporal properties ---

\* commitPosition never decreases for any server
CommitPositionNeverDecreases ==
    [][\A i \in Server : commitPosition'[i] >= commitPosition[i]]_<<commitPosition>>

\* candidateTermId never decreases (Family 2, 6)
CandidateTermNeverDecreases ==
    [][\A i \in Server : candidateTermId'[i] >= candidateTermId[i]]_<<candidateTermId>>

====
