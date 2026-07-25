--------------------------- MODULE Trace ---------------------------
(*
 * Trace-validation spec for MongoRaftReconfig (Category A — single linear trace).
 *
 * Replays a recorded execution of a real 5-node MongoDB replica set against
 * base.tla, verifying the base spec can reproduce every observed config/term/role
 * transition. Traces are produced by LOG PARSING (no C++ instrumentation): MongoDB
 * LOGV2 structured logs (replication verbosity 3) are filtered to the reconfig-
 * relevant log IDs and emitted as NDJSON (see instrumentation-spec.md and
 * case-studies/mongodb-shared-harness.md).
 *
 * Trace format (one JSON object per line):
 *   { "tag":"trace", "ts":"<iso>",
 *     "event": {
 *       "name":  "<action>",          \* BecomeLeader | StepUpReconfig | ...
 *       "nid":   "<node id>",         \* n1..n5
 *       "state": { "term":<int>, "role":"Primary"|"Secondary",
 *                  "configVersion":<int>, "configTerm":<int>,
 *                  "commitIndex":<int> },
 *       "cfg":   { "version":<int>, "term":<int>,            \* config-install events
 *                  "voters":[..ids..], "arbiters":[..ids..] }
 *     } }
 *
 * Only config/term/role transitions are reliably observable from logs; the oplog
 * substrate (client writes, replication, commit-point advancement, the
 * unobservable de-atomized ReconfigCheck/Persist steps) is driven by tightly
 * constrained SILENT actions that fire only to enable the next observed event.
 *)

EXTENDS base, Json, IOUtils, Sequences, TLC

\* ============================================================================
\* TRACE LOADING
\* ============================================================================

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

\* ============================================================================
\* TRACE CURSOR
\* ============================================================================

VARIABLE l         \* current position in TraceLog (1-indexed)

logline == TraceLog[l]

\* ============================================================================
\* HELPERS: trace value mapping
\* ============================================================================

\* Convert a JSON array (function over 1..n) to a TLA+ set.
SeqToSet(s) == { s[i] : i \in DOMAIN s }

\* Build a base-spec config record from a trace "cfg" object.
TraceCfg(c) ==
    [version  |-> c.version,
     term     |-> c.term,
     voters   |-> SeqToSet(c.voters),
     arbiters |-> SeqToSet(c.arbiters)]

\* Servers that appear in the trace (must be a subset of the model's Server set).
TraceServer == TLCEval(
    UNION { {TraceLog[k].event.nid} : k \in 1..Len(TraceLog) })

ASSUME TraceServer /= {}
ASSUME TraceServer \subseteq Server

RoleMapping == "Primary" :> Primary @@ "Secondary" :> Secondary

\* ============================================================================
\* EVENT PREDICATES
\* ============================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.event.nid = i

\* ============================================================================
\* POST-STATE VALIDATION (MANDATORY — checks the fields logs reliably carry)
\* ============================================================================

\* Strong validation: election term, role, and installed config (version,term).
ValidatePostState(i) ==
    /\ term'[i]               = logline.event.state.term
    /\ role'[i]               = RoleMapping[logline.event.state.role]
    /\ config'[i].version     = logline.event.state.configVersion
    /\ config'[i].term        = logline.event.state.configTerm

\* Config-install validation: also check the installed membership matches the
\* logged config object (voters / arbiters).
ValidateConfig(i) ==
    /\ ValidatePostState(i)
    /\ config'[i].voters   = SeqToSet(logline.event.cfg.voters)
    /\ config'[i].arbiters = SeqToSet(logline.event.cfg.arbiters)

\* Term-only validation (for term-update events on secondaries).
ValidateTerm(i) ==
    /\ term'[i] = logline.event.state.term
    /\ role'[i] = RoleMapping[logline.event.state.role]

StepTrace == l' = l + 1

\* ============================================================================
\* ACTION WRAPPERS (consume one trace event each)
\* ============================================================================

\* --- BecomeLeader: a node won an election and became primary in a new term. ---
\* The vote quorum is not observable; the base action picks a valid one.
\* Reference: election success (LOGV2 23913 "Election succeeded" / 21358).
BecomeLeaderIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("BecomeLeader", i)
        /\ \E Q \in SUBSET Server : BecomeLeader(i, Q)
        /\ ValidateTerm(i)
        /\ StepTrace

\* --- CompletePrimaryDrain: new primary finished drain (writable). ---
\* Reference: LOGV2 "transition to primary complete" / completeTransitionToPrimary.
CompletePrimaryDrainIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CompletePrimaryDrain", i)
        /\ CompletePrimaryDrain(i)
        /\ ValidateTerm(i)
        /\ StepTrace

\* --- StepUpReconfig: optimized step-up reconfig bumped configTerm to term. ---
\* Reference: doOptimizedReconfig; LOGV2 21392 "New replica set config in use".
StepUpReconfigIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("StepUpReconfig", i)
        /\ StepUpBumpConfigTerm(i)
        /\ ValidateConfig(i)
        /\ StepTrace

\* --- ConfigInstallCmd: command (non-force) reconfig install. ---
\* The de-atomized ReconfigCheck/Persist are not separately observable, so they
\* are driven by silent actions (below) gated on this being the next event; this
\* wrapper consumes the install (ReconfigInstall).
\* Reference: LOGV2 21392 / 9626616 "ReplSetReconfig succeeded".
ConfigInstallCmdIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ConfigInstallCmd", i)
        /\ ReconfigInstall(i)
        /\ ValidateConfig(i)
        /\ StepTrace

\* --- ConfigInstallHB: heartbeat reconfig install of a peer's newer config. ---
\* Reference: LOGV2 4615622 / 9626611 "Heartbeat Reconfig succeeded".
ConfigInstallHBIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ConfigInstallHB", i)
        /\ \E q \in Server : InstallConfigViaHeartbeat(i, q)
        /\ ValidateConfig(i)
        /\ StepTrace

\* --- UpdateTerm: a node's election term changed (LOGV2 21827 "Updating term"). ---
\* 21827 is logged by a SECONDARY (updateTerm's kUpdatedTerm path, topology_coordinator
\* :3308-3309) — either a candidate bumping its OWN term to START an election (the first
\* node to reach the new term; _startRealElection -> updateTerm, elect_v1.cpp:329), or a
\* voter/peer ADOPTING an existing higher term. An OLD PRIMARY that learns a higher term
\* does NOT log 21827 (updateTerm returns kTriggerStepDown FIRST, :3305-3306, no log); it
\* steps down and its new term only surfaces post-stepdown. So three faithful mappings,
\* validated on TERM — the role at a 21827 line is a laggy post-event poll (the candidate
\* reads Primary because the poll caught it after winning; see INSTRUMENTATION.md §7).
UpdateTermIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("UpdateTerm", i)
        /\ LET T == logline.event.state.term IN
              \/ \* (a) candidate STARTS an election: first node to reach T (no peer has it).
                 /\ role[i] = Secondary
                 /\ term[i] < T
                 /\ \A q \in Server : term[q] < T
                 /\ StartElection(i)
                 /\ term'[i] = T
              \/ \* (b) secondary ADOPTS an existing higher term T held by a peer (kUpdatedTerm).
                 /\ role[i] = Secondary
                 /\ term[i] < T
                 /\ \E q \in Server : LearnHigherTerm(i, q)
                 /\ term'[i] = T
              \/ \* (c) old PRIMARY that already entered async step-down (via SilentLearnHigherTerm)
                 \* now completes it, adopting T as a clean secondary (the vote-path stepdown).
                 /\ role[i] = Primary
                 /\ primaryState[i] = SteppingDown
                 /\ CompleteStepDown(i)
                 /\ term'[i] = T
        /\ StepTrace

\* --- StepDown: a primary relinquished primary (LOGV2 21475/21355). Two faithful
\* mappings: (i) the async higher-term step-down completing (CompleteStepDown, from
\* the SteppingDown sub-state), or (ii) the term-INDEPENDENT lost-quorum / partition
\* step-down (PrimaryStepDown) — checkMemberTimeouts "Can't see a majority of the set,
\* relinquishing primary" (topology_coordinator.cpp:1465, LOGV2 21809 -> StepDownSelf
\* -> ..._heartbeat.cpp:498 LOGV2 21475), which keeps the node's current term. ---
StepDownIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("StepDown", i)
        /\ \/ CompleteStepDown(i)      \* async higher-term step-down (from SteppingDown)
           \/ PrimaryStepDown(i)       \* lost-quorum / partition step-down (current term)
        /\ ValidateTerm(i)
        /\ StepTrace

\* ============================================================================
\* SILENT ACTIONS (no trace event consumed — drive the oplog substrate and the
\* unobservable de-atomized reconfig steps). All are tightly constrained: they
\* fire only when needed to enable the NEXT observed event.
\* ============================================================================

\* The de-atomized command reconfig's gate + persist are not separately logged.
\* When the next event is a command install on node i, allow the gate (using the
\* upcoming event's target config) and the persist to fire silently first.
SilentReconfigCheck ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "ConfigInstallCmd"
    /\ LET i == logline.event.nid
           c == TraceCfg(logline.event.cfg)
       IN /\ reconfigPhase[i] = PhaseIdle
          /\ ReconfigCheck(i, c.voters, c.arbiters)
          /\ UNCHANGED l

SilentReconfigPersist ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "ConfigInstallCmd"
    /\ LET i == logline.event.nid IN
       /\ reconfigPhase[i] = PhaseChecked
       /\ ReconfigPersist(i)
       /\ UNCHANGED l

\* Client writes are not individually traced; allow a primary to append an entry
\* when a later observed event (commit/reconfig) needs oplog content.
SilentClientRequest ==
    /\ l <= Len(TraceLog)
    /\ \E p \in Server : ClientRequest(p)
    /\ UNCHANGED l

\* Replication of oplog entries between nodes (unobserved).
SilentGetEntries ==
    /\ l <= Len(TraceLog)
    /\ \E s, q \in Server : GetEntries(s, q)
    /\ UNCHANGED l

\* Commit-point advancement (observable only via commitIndex in status, not as a
\* distinct event); fire to satisfy Q1/Q2 preconditions of an upcoming reconfig.
SilentAdvanceCommitPoint ==
    /\ l <= Len(TraceLog)
    /\ \E p \in Server : AdvanceCommitPoint(p)
    /\ UNCHANGED l

\* An OLD PRIMARY enters async step-down upon learning a higher term that an upcoming
\* observed StepDown/UpdateTerm event for it reflects (the heartbeat/vote that raised the
\* term is not separately logged with full state). GATED: fires only for the node the NEXT
\* event targets, only while it is still a non-stepping-down primary, and only when a peer
\* genuinely holds a higher term — so it cannot explode the search.
SilentLearnHigherTerm ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server :
         /\ logline.event.nid = i
         /\ logline.event.name \in {"UpdateTerm", "StepDown"}
         /\ role[i] = Primary
         /\ primaryState[i] \in {LeaderElect, WritablePrimary}
         /\ \E q \in Server : LearnHigherTerm(i, q)
    /\ UNCHANGED l

\* A non-observed node installs a newer config via heartbeat (config propagation
\* needed so a config becomes $configMajority-committed for the next reconfig).
SilentInstallConfigViaHeartbeat ==
    /\ l <= Len(TraceLog)
    /\ \E p, q \in Server : InstallConfigViaHeartbeat(p, q)
    /\ UNCHANGED l

\* ============================================================================
\* TRACE INIT (matches the bootstrap state: genesis config v1, term 1)
\* ============================================================================

\* The trace window opens AFTER bootstrap settles: setup_genesis.js pins rcfg1 (=n1,
\* priority 2) as the deterministic bootstrap primary in term 1 (INSTRUMENTATION.md §4b).
\* So n1 starts as a WritablePrimary in term 1 with the genesis config and its first
\* (new-primary no-op) oplog entry already written + commit-pointed.
TraceInit ==
    /\ l = 1
    /\ term          = [n \in Server |-> 1]
    /\ role          = [n \in Server |-> IF n = "n1" THEN Primary ELSE Secondary]
    /\ primaryState  = [n \in Server |-> IF n = "n1" THEN WritablePrimary ELSE NotPrimary]
    /\ lastVoteTerm  = [n \in Server |-> 1]
    /\ config        = [n \in Server |-> GenesisCfg]
    /\ log           = [n \in Server |-> IF n = "n1" THEN << 1 >> ELSE << >>]
    /\ commitPoint   = [n \in Server |-> ZeroOpTime]
    /\ committedInPrev = [n \in Server |-> ZeroOpTime]
    /\ firstOpTime   = [n \in Server |-> IF n = "n1" THEN OpTimeRec(1,1) ELSE ZeroOpTime]
    /\ reconfigPhase = [n \in Server |-> PhaseIdle]
    /\ pendingCfg    = [n \in Server |-> NoCfg]
    /\ pendingStepDown = [n \in Server |-> FALSE]
    /\ pendingTerm   = [n \in Server |-> 0]
    /\ committed     = {}
    /\ leaderHistory = [t \in 1..MaxTerm |-> IF t = 1 THEN {"n1"} ELSE {}]
    /\ installedConfigs = {GenesisCfg}
    /\ reconfigPairs = {}

\* ============================================================================
\* TRACE NEXT
\* ============================================================================

TraceDone ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED <<l, vars>>

TraceNext ==
    \/ TraceDone
    \* Observed-event wrappers
    \/ BecomeLeaderIfLogged
    \/ CompletePrimaryDrainIfLogged
    \/ StepUpReconfigIfLogged
    \/ ConfigInstallCmdIfLogged
    \/ ConfigInstallHBIfLogged
    \/ UpdateTermIfLogged
    \/ StepDownIfLogged
    \* Silent substrate actions — only the two reconfig-gate silents are needed by the
    \* four harness traces (their sole command reconfig is the genesis v1->v2 reconfig,
    \* where Q2 is skipped, so no oplog substrate must be driven). The 5 "heavy" silents
    \* below are UNGATED (\E p : Action(p), UNCHANGED l) and explode the search
    \* (INSTRUMENTATION.md §4c); disabled until a trace genuinely needs them (gated).
    \/ SilentReconfigCheck
    \/ SilentReconfigPersist
    \/ SilentLearnHigherTerm   \* gated: old-primary async step-down before its observed event
    \* \/ SilentClientRequest
    \* \/ SilentGetEntries
    \* \/ SilentAdvanceCommitPoint
    \* \/ SilentInstallConfigViaHeartbeat

\* Weak fairness on TraceNext eliminates the trivial infinite-stutter counterexample
\* to the TraceMatched liveness property (INSTRUMENTATION.md §4d). The two enabled
\* silents (ReconfigCheck/Persist) advance reconfigPhase monotonically idle->checked->
\* persisted and then enable the cursor-advancing install, so there is no infinite
\* non-progress loop: every fair behavior consumes the whole trace (l reaches Len+1).
TraceSpec == TraceInit /\ [][TraceNext]_<<l, vars>> /\ WF_<<l, vars>>(TraceNext)

\* ============================================================================
\* PSA VARIANT (family3_arbiter): genesis config already has arbiter n5
\* ============================================================================
\* The family3 scenario bootstraps a Primary-Secondary-Arbiter set (rcfg5=n5 is an
\* arbiter, priority 0), so its genesis config carries arbiters={n5} — it does NOT
\* match the all-voting GenesisCfg (INSTRUMENTATION.md §6). Same post-bootstrap state
\* as TraceInit (n1 = genesis primary), but the genesis config has n5 as an arbiter.
GenesisCfgPSA == [version |-> 1, term |-> 1, voters |-> Server, arbiters |-> {"n5"}]

TraceInitPSA ==
    /\ l = 1
    /\ term          = [n \in Server |-> 1]
    /\ role          = [n \in Server |-> IF n = "n1" THEN Primary ELSE Secondary]
    /\ primaryState  = [n \in Server |-> IF n = "n1" THEN WritablePrimary ELSE NotPrimary]
    /\ lastVoteTerm  = [n \in Server |-> 1]
    /\ config        = [n \in Server |-> GenesisCfgPSA]
    /\ log           = [n \in Server |-> IF n = "n1" THEN << 1 >> ELSE << >>]
    /\ commitPoint   = [n \in Server |-> ZeroOpTime]
    /\ committedInPrev = [n \in Server |-> ZeroOpTime]
    /\ firstOpTime   = [n \in Server |-> IF n = "n1" THEN OpTimeRec(1,1) ELSE ZeroOpTime]
    /\ reconfigPhase = [n \in Server |-> PhaseIdle]
    /\ pendingCfg    = [n \in Server |-> NoCfg]
    /\ pendingStepDown = [n \in Server |-> FALSE]
    /\ pendingTerm   = [n \in Server |-> 0]
    /\ committed     = {}
    /\ leaderHistory = [t \in 1..MaxTerm |-> IF t = 1 THEN {"n1"} ELSE {}]
    /\ installedConfigs = {GenesisCfgPSA}
    /\ reconfigPairs = {}

TraceSpecPSA == TraceInitPSA /\ [][TraceNext]_<<l, vars>> /\ WF_<<l, vars>>(TraceNext)

\* ============================================================================
\* TRACE COMPLETION PROPERTY (MANDATORY)
\* ============================================================================

TraceMatched == <>(l > Len(TraceLog))

\* ============================================================================
\* ALIAS (for debugging trace failures)
\* ============================================================================

TraceAlias ==
    [
        cursor   |-> l,
        traceLen |-> Len(TraceLog),
        event    |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
        nid      |-> IF l <= Len(TraceLog) THEN logline.event.nid ELSE "DONE",
        tState   |-> IF l <= Len(TraceLog) THEN logline.event.state ELSE "DONE",
        term     |-> term,
        role     |-> role,
        cfgVT    |-> [n \in Server |-> [v |-> config[n].version, t |-> config[n].term]],
        cfgMem   |-> [n \in Server |-> [vo |-> config[n].voters, ar |-> config[n].arbiters]],
        phase    |-> reconfigPhase
    ]

====
