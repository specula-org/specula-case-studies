---- MODULE Trace ----
\* Trace.tla — Trace validation spec for MongoDB Raft Reconfig
\* Category A: single-cursor linear trace replay against base.tla
\*
\* Drives TLC through a recorded execution trace from the MongoDB implementation,
\* verifying that the base spec can reproduce every observed state transition.
\*
\* Trace file format: NDJSON (one JSON object per line)
\* Default location: ../traces/trace.ndjson
\* Override: set environment variable JSON=<path>

EXTENDS base, Json, IOUtils, Sequences, FiniteSets, Naturals, Integers, TLC

\* =========================================================
\* TRACE LOADING
\* =========================================================

\* Trace file selection: environment override or default path
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load NDJSON trace; each line is a JSON object (one trace event)
TraceLog == ndJsonDeserialize(JsonFile)

\* Cursor variable: walks through trace events (1-indexed)
VARIABLE l

\* Current trace event
logline == TraceLog[l]

\* =========================================================
\* BOOTSTRAP: derive Server set and initial mapping from trace
\* =========================================================

\* Extract Server set from all node IDs that appear as "node" in trace events
TraceServer == { e.node : e \in { TraceLog[i] : i \in 1..Len(TraceLog) } }

\* Map implementation role strings to spec constants
ToRole(s) ==
    CASE s = "PRIMARY"   -> Leader
      [] s = "SECONDARY" -> Follower
      [] s = "STARTUP2"  -> Follower
      [] s = "STARTUP"   -> Follower
      [] s = "CANDIDATE" -> Candidate
      [] OTHER           -> Follower

\* Map implementation configState strings to spec constants
ToConfigState(s) ==
    CASE s = "kConfigSteady"          -> Steady
      [] s = "kConfigReconfiguring"   -> Reconfiguring
      [] s = "kConfigHBReconfiguring" -> HBReconfiguring
      [] s = "PostSwap"               -> PostSwap
      [] OTHER                        -> Steady

\* Parse a configVersionAndTerm from a trace field {version, term}
\* configTerm may be -1 (UNINITIALIZED) or a non-negative integer
ToConfigTerm(t) == IF t = -1 THEN UNINITIALIZED ELSE t

\* =========================================================
\* TRACE INIT
\* =========================================================

\* TraceInit: match the first trace event's state as the spec's initial state.
\* The implementation starts with a bootstrap config (all nodes in Server).
TraceInit ==
    /\ l = 1
    /\ Init

\* =========================================================
\* EVENT PREDICATES
\* =========================================================

\* True iff the current logline is a named event for node n
IsNodeEvent(name, n) ==
    /\ logline.event = name
    /\ logline.node  = n

\* True iff the current logline is a message event from -> to
IsMsgEvent(name, from, to) ==
    /\ logline.event = name
    /\ logline.from  = from
    /\ logline.to    = to

\* =========================================================
\* POST-STATE VALIDATION
\* Post-state fields: captured in the trace AFTER the action completes.
\* Every wrapper must validate the key fields the action modifies.
\* Fields not captured by the harness are skipped with a comment explaining why.
\* =========================================================

ValidateServerState(n) ==
    \* Check currentTerm and role match trace post-state (primed = next state after action)
    /\ ("currentTerm" \in DOMAIN logline.post => currentTerm'[n] = logline.post.currentTerm)
    /\ ("role"        \in DOMAIN logline.post => role'[n] = ToRole(logline.post.role))

ValidateConfigState(n) ==
    /\ ("configVersion" \in DOMAIN logline.post => configVersion'[n] = logline.post.configVersion)
    /\ ("configTerm"    \in DOMAIN logline.post => configTerm'[n] = ToConfigTerm(logline.post.configTerm))
    /\ ("configState"   \in DOMAIN logline.post => configState'[n] = ToConfigState(logline.post.configState))

ValidateVoteState(n) ==
    /\ ("inMemVoteTerm" \in DOMAIN logline.post => inMemVote'[n].term = logline.post.inMemVoteTerm)
    /\ ("durableVoteTerm" \in DOMAIN logline.post => durableVote'[n].term = logline.post.durableVoteTerm)

ValidateBarrier(n) ==
    /\ ("lastCommittedInPrevConfig" \in DOMAIN logline.post =>
           lastCommittedInPrevConfig'[n] = logline.post.lastCommittedInPrevConfig)

ValidateCommitIndex(n) ==
    /\ ("commitIndex" \in DOMAIN logline.post => commitIndex'[n] = logline.post.commitIndex)

\* =========================================================
\* ACTION WRAPPERS
\* Each wrapper: match event -> call base action -> validate post-state -> advance l
\* =========================================================

\* --- Timeout ---
TraceTimeout(n) ==
    /\ IsNodeEvent("Timeout", n)
    /\ Timeout(n)
    /\ ValidateServerState(n)
    /\ l' = l + 1

\* --- RequestVotes ---
TraceRequestVotes(n) ==
    /\ IsNodeEvent("RequestVotes", n)
    /\ RequestVotes(n)
    /\ ValidateServerState(n)
    /\ l' = l + 1

\* --- HandleRequestVote (voter grants or denies) ---
\* replication_coordinator_impl.cpp:processReplSetRequestVotes
TraceHandleRequestVote(voter) ==
    /\ logline.event = "HandleRequestVote"
    /\ logline.node  = voter
    /\ LET m == CHOOSE msg \in messages :
                    /\ msg.mtype = M_RequestVote
                    /\ msg.mto   = voter
                    /\ msg.mfrom = logline.from
                    /\ msg.mterm = logline.msgTerm
       IN HandleRequestVote(voter, m)
    /\ ValidateServerState(voter)
    /\ ValidateVoteState(voter)
    /\ l' = l + 1

\* --- PersistVote ---
\* replication_coordinator_impl.cpp:storeLocalLastVoteDocument
TracePersistVote(n) ==
    /\ IsNodeEvent("PersistVote", n)
    /\ PersistVote(n)
    /\ ValidateVoteState(n)
    /\ l' = l + 1

\* --- BecomeLeader ---
TraceBecomeLeader(n) ==
    /\ IsNodeEvent("BecomeLeader", n)
    /\ BecomeLeader(n)
    /\ ValidateServerState(n)
    /\ ("autoReconfigPending" \in DOMAIN logline.post =>
            autoReconfigPending'[n] = logline.post.autoReconfigPending)
    /\ l' = l + 1

\* --- AutoReconfig ---
\* replication_coordinator_impl.cpp:1468-1514
TraceAutoReconfig(n) ==
    /\ IsNodeEvent("AutoReconfig", n)
    /\ AutoReconfig(n)
    /\ ValidateConfigState(n)
    /\ ("autoReconfigPending" \in DOMAIN logline.post =>
            autoReconfigPending'[n] = logline.post.autoReconfigPending)
    /\ l' = l + 1

\* --- AutoReconfigPreempted ---
TraceAutoReconfigPreempted(n) ==
    /\ IsNodeEvent("AutoReconfigPreempted", n)
    /\ AutoReconfigPreempted(n)
    /\ ("autoReconfigPending" \in DOMAIN logline.post =>
            autoReconfigPending'[n] = logline.post.autoReconfigPending)
    /\ l' = l + 1

\* --- ForceReconfig ---
\* replication_coordinator_impl.cpp:3425
\* n must be in the new config: in the traces n1 remains leader after force-reconfig,
\* so it must be in its own config to form a quorum for subsequent AdvanceCommitIndex.
TraceForceReconfig(n) ==
    /\ IsNodeEvent("ForceReconfig", n)
    /\ \E newCfg \in SUBSET Server, newVer \in 1..MaxConfigVersion :
           /\ n \in newCfg  \* leader stays in new config
           /\ ("newConfigVersion" \in DOMAIN logline =>
                  newVer = logline.newConfigVersion)
           /\ ForceReconfig(n, newCfg, newVer)
    /\ ValidateConfigState(n)
    /\ l' = l + 1

\* --- SafeReconfigStart ---
\* replication_coordinator_impl.cpp:_doReplSetReconfig entry
\* n must be in the new config for the same reason as TraceForceReconfig.
TraceSafeReconfigStart(n) ==
    /\ IsNodeEvent("SafeReconfigStart", n)
    /\ \E newCfg \in SUBSET Server : n \in newCfg /\ SafeReconfigStart(n, newCfg)
    /\ ValidateConfigState(n)
    /\ l' = l + 1

\* --- SafeReconfigSwap (_setCurrentRSConfig, line 3997) ---
\* n must be in the new config: leader stays in the quorum after reconfig.
TraceSafeReconfigSwap(n) ==
    /\ IsNodeEvent("SafeReconfigSwap", n)
    /\ \E newCfg \in SUBSET Server : n \in newCfg /\ SafeReconfigSwap(n, newCfg)
    /\ ValidateConfigState(n)
    /\ l' = l + 1

\* --- SafeReconfigCaptureBarrier (updateLastCommittedInPrevConfig, line 4003) ---
TraceSafeReconfigCaptureBarrier(n) ==
    /\ IsNodeEvent("SafeReconfigCaptureBarrier", n)
    /\ SafeReconfigCaptureBarrier(n)
    /\ ValidateConfigState(n)
    /\ ValidateBarrier(n)
    /\ l' = l + 1

\* --- HBReconfigSchedule ---
\* replication_coordinator_impl_heartbeat.cpp:689
\* When the trace provides schedVer/schedTerm/schedCfg the existential is eliminated,
\* avoiding the O(|SUBSET Server| * MaxConfigVersion * MaxTerm) state-space blow-up.
TraceHBReconfigSchedule(n) ==
    /\ IsNodeEvent("HBReconfigSchedule", n)
    /\ IF "schedVer" \in DOMAIN logline
       THEN LET newCfg == {m \in Server :
                    \E i \in DOMAIN logline.schedCfg : logline.schedCfg[i] = m}
            IN HBReconfigSchedule(n, newCfg, logline.schedVer, ToConfigTerm(logline.schedTerm))
       ELSE \E newCfg \in SUBSET Server, v \in 1..MaxConfigVersion,
                  t \in ({UNINITIALIZED} \cup 0..MaxTerm) :
                  HBReconfigSchedule(n, newCfg, v, t)
    /\ ValidateConfigState(n)
    /\ l' = l + 1

\* --- HBReconfigFinish ---
\* replication_coordinator_impl_heartbeat.cpp:_heartbeatReconfigFinish
TraceHBReconfigFinish(n) ==
    /\ IsNodeEvent("HBReconfigFinish", n)
    /\ HBReconfigFinish(n)
    /\ ValidateConfigState(n)
    /\ l' = l + 1

\* --- AppendEntry ---
TraceAppendEntry(n) ==
    /\ IsNodeEvent("AppendEntry", n)
    /\ AppendEntry(n)
    /\ ("logLen" \in DOMAIN logline.post => Len(log'[n]) = logline.post.logLen)
    /\ l' = l + 1

\* --- AdvanceCommitIndex ---
TraceAdvanceCommitIndex(n) ==
    /\ IsNodeEvent("AdvanceCommitIndex", n)
    /\ AdvanceCommitIndex(n)
    /\ ValidateCommitIndex(n)
    /\ l' = l + 1

\* =========================================================
\* SILENT ACTIONS
\* Handle spec steps without corresponding trace events.
\* Must be tightly constrained to prevent state space explosion.
\* =========================================================

\* Silent: send heartbeat (heartbeat sending is high-frequency; not individually traced)
\* Not triggered on "HBReconfigSchedule": HBReconfigSchedule is a spec action that fires
\* directly on state (no message needed). Firing SilentHandleHeartbeat before it would
\* call HandleHeartbeat which ALSO sets configState=HBReconfiguring, blocking the traced action.
SilentSendHeartbeat ==
    /\ l <= Len(TraceLog)
    /\ logline.event \in {"HBReconfigFinish", "HandleHeartbeat"}
    /\ \E from \in Server, to \in Server : from /= to /\ SendHeartbeat(from, to)
    /\ UNCHANGED l

\* Silent: send AppendEntries (replication is not always individually traced)
SilentSendAppendEntries ==
    /\ l <= Len(TraceLog)
    /\ logline.event \in {"AdvanceCommitIndex", "HandleAppendEntries"}
    /\ \E leader \in Server, follower \in Server :
           leader /= follower /\ SendAppendEntries(leader, follower)
    /\ UNCHANGED l

\* Silent: HandleHeartbeat that triggers no config change (pure term update)
\* Not triggered on "HBReconfigSchedule": see SilentSendHeartbeat comment above.
SilentHandleHeartbeat ==
    /\ l <= Len(TraceLog)
    /\ logline.event \in {"BecomeLeader"}
    /\ \E m \in messages : m.mtype = M_Heartbeat /\ HandleHeartbeat(m.mto, m)
    /\ UNCHANGED l

\* Silent: HandleAppendEntries (log replication between traced commit events)
SilentHandleAppendEntries ==
    /\ l <= Len(TraceLog)
    /\ logline.event \in {"AdvanceCommitIndex", "BecomeLeader"}
    /\ \E m \in messages : m.mtype = M_AppendEntries /\ HandleAppendEntries(m.mto, m)
    /\ UNCHANGED l

\* =========================================================
\* TRACE NEXT
\* =========================================================

\* Terminal step: trace fully consumed; no-op self-loop prevents TLC deadlock reports.
TraceTerminated ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED <<vars, l>>

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ \/ \E n \in Server : TraceTimeout(n)
          \/ \E n \in Server : TraceRequestVotes(n)
          \/ \E n \in Server : TraceHandleRequestVote(n)
          \/ \E n \in Server : TracePersistVote(n)
          \/ \E n \in Server : TraceBecomeLeader(n)
          \/ \E n \in Server : TraceAutoReconfig(n)
          \/ \E n \in Server : TraceAutoReconfigPreempted(n)
          \/ \E n \in Server : TraceForceReconfig(n)
          \/ \E n \in Server : TraceSafeReconfigStart(n)
          \/ \E n \in Server : TraceSafeReconfigSwap(n)
          \/ \E n \in Server : TraceSafeReconfigCaptureBarrier(n)
          \/ \E n \in Server : TraceHBReconfigSchedule(n)
          \/ \E n \in Server : TraceHBReconfigFinish(n)
          \/ \E n \in Server : TraceAppendEntry(n)
          \/ \E n \in Server : TraceAdvanceCommitIndex(n)
          \/ SilentSendHeartbeat
          \/ SilentSendAppendEntries
          \/ SilentHandleHeartbeat
          \/ SilentHandleAppendEntries
    \/ TraceTerminated

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>>

\* TracedActions: the subset of TraceNext that advances l.
\* Every branch here does l' = l+1.
\* MUST guard with l <= Len(TraceLog) first: SF evaluation of ENABLED TracedActions
\* happens for all states including l > Len(TraceLog), where logline access would OOB.
TracedActions ==
    /\ l <= Len(TraceLog)
    /\ (\/ \E n \in Server : TraceTimeout(n)
        \/ \E n \in Server : TraceRequestVotes(n)
        \/ \E n \in Server : TraceHandleRequestVote(n)
        \/ \E n \in Server : TracePersistVote(n)
        \/ \E n \in Server : TraceBecomeLeader(n)
        \/ \E n \in Server : TraceAutoReconfig(n)
        \/ \E n \in Server : TraceAutoReconfigPreempted(n)
        \/ \E n \in Server : TraceForceReconfig(n)
        \/ \E n \in Server : TraceSafeReconfigStart(n)
        \/ \E n \in Server : TraceSafeReconfigSwap(n)
        \/ \E n \in Server : TraceSafeReconfigCaptureBarrier(n)
        \/ \E n \in Server : TraceHBReconfigSchedule(n)
        \/ \E n \in Server : TraceHBReconfigFinish(n)
        \/ \E n \in Server : TraceAppendEntry(n)
        \/ \E n \in Server : TraceAdvanceCommitIndex(n))

\* FairTraceSpec: TraceSpec with strong fairness on TracedActions.
\* SF ensures that if a traced l-advancing action is infinitely often enabled,
\* it eventually fires. This prevents TLC from finding spurious counterexamples
\* where silent actions oscillate (e.g. repeatedly re-sending AppendEntries)
\* while a traced action is perpetually enabled but never taken.
\* WF on silent replication ensures followers receive the log before commit can advance.
FairTraceSpec ==
    /\ TraceSpec
    /\ SF_<<vars, l>>(TracedActions)
    /\ WF_<<vars, l>>(SilentSendAppendEntries)
    /\ WF_<<vars, l>>(SilentHandleAppendEntries)

\* =========================================================
\* TRACE COMPLETION
\* =========================================================

\* The entire trace must be consumed (l advances past the last event)
TraceMatched == <>(l > Len(TraceLog))

\* =========================================================
\* INVARIANTS FOR TRACE VALIDATION
\* Only safety invariants that should hold on every real execution.
\* Fault-injection invariants are excluded (VoteOnce, CommitPointSafety require
\* fault injection to be enabled, which does not apply to recorded traces).
\* =========================================================

TraceElectionSafety       == ElectionSafety
TraceLogMatching          == LogMatching
TraceConfigVersionPositive == ConfigVersionPositive
TraceConfigStateValid     == ConfigStateValid
TraceVoteTermMonotone     == VoteTermMonotone
TraceConfigTermBelowElectionTerm == ConfigTermBelowElectionTerm
TraceCommitBarrierConsistency    == CommitBarrierConsistency

====
