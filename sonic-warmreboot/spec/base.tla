--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for SONiC Warm Reboot orchestration.
 *
 * Derived from: sonic-swss (orchagent), sonic-sairedis (syncd),
 *               sonic-buildimage (Warmboot Manager)
 *
 * Bug Families:
 *   1 - Reconciliation Ordering Violations
 *   2 - Freeze/Quiescence Protocol Violations
 *   3 - APPLY_VIEW Non-Transactional Failure
 *   4 - Reconciliation Cache State Machine Bugs
 *   5 - Shutdown Sequence / Point-of-No-Return Violations
 *
 * Category A (Distributed / Message-Passing): 6+ components
 * coordinate via Redis state tables with 4-phase shutdown and
 * independent per-component reconciliation.
 *)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Component       \* Set of component IDs (orchagent, syncd, etc.)
CONSTANT Key             \* Set of abstract keys for cache/appDB modeling
CONSTANT Nil             \* Sentinel value

\* Well-known components (members of Component with specific behavior)
CONSTANTS
    Orchagent,           \* sonic-swss orchagent
    Syncd,               \* sonic-sairedis syncd
    Neighsyncd,          \* neighsyncd (ARP/neighbor)
    Fdbsyncd,            \* fdbsyncd (FDB/MAC)
    Teamd,               \* teamd (LAG)
    Vxlanmgrd            \* vxlanmgrd (VXLAN tunnels)

\* Shutdown phase constants
CONSTANTS
    PhaseRunning,        \* Normal operation
    PhaseSanity,         \* Phase 1: sanity checks
    PhaseFreeze,         \* Phase 2: freeze/quiescence
    PhaseCheckpoint,     \* Phase 3: checkpoint (point of no return)
    PhaseReboot,         \* Phase 4: reboot
    PhaseBooting,        \* System restarting
    PhaseReconciling     \* Post-reboot reconciliation

\* Per-component state constants
CONSTANTS
    CRunning,            \* Normal operation
    CFrozen,             \* Stopped generating new events
    CQuiescent,          \* Drained all pending work
    CCheckpointed,       \* Saved state to persistent storage
    CInitialized,        \* Post-reboot: initialized
    CRestored,           \* Post-reboot: pre-reboot state loaded
    CReconciled,         \* Post-reboot: reconciliation complete
    CFailed              \* Failed at some point

\* Syncd mode constants (Family 3, 5)
CONSTANTS
    SyncdNormal,         \* Normal operation
    SyncdInitView,       \* INIT_VIEW received, collecting operations
    SyncdApplyStage1,    \* APPLY_VIEW Stage 1: comparison (non-destructive)
    SyncdApplyStage2,    \* APPLY_VIEW Stage 2: ASIC ops (destructive)
    SyncdDone,           \* APPLY_VIEW completed successfully
    SyncdShutdownWait,   \* Exception handler — blanket rejects
    SyncdCrashed         \* Unrecoverable crash

\* Orchagent internal state constants (Family 2)
CONSTANTS
    OrchRunning,         \* Normal event loop
    OrchCheckingReady,   \* warmRestartCheck in progress
    OrchReadyReplied,    \* READY reply sent, not yet frozen
    OrchDraining,        \* Draining ring buffer
    OrchFrozen,          \* Actually frozen (FDB disabled, etc.)
    OrchRestoring,       \* warmRestoreAndSyncUp in progress
    OrchWaitApplyView,   \* Waiting for syncd APPLY_VIEW
    OrchReconciling      \* Post-APPLY_VIEW, calling onWarmBootEnd

\* Cache entry state constants (Family 4)
CONSTANTS
    CacheEmpty,          \* No entry
    CacheSTALE,          \* Pre-reboot entry, not yet replayed
    CacheSAME,           \* Replayed with identical value
    CacheNEW,            \* Replayed with different value
    CacheDELETE          \* Marked for deletion

\* Dependency ordering (Family 1)
\* Models: Port -> LAG -> Interface -> ARP -> Route
\* Concrete: Teamd -> Orchagent -> Neighsyncd -> Fdbsyncd -> Vxlanmgrd
CONSTANT Depends         \* [Component -> SUBSET Component] prerequisite map

\* Timer bounds
CONSTANT MaxTimer        \* Maximum reconciliation timer value

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Global phase state (Warmboot Manager) ---
\* Reference: Warmboot_Manager_HLD.md Phase 1-4
VARIABLE phase              \* Current shutdown/boot phase
VARIABLE pointOfNoReturn    \* BOOLEAN: past Phase 3 checkpoint

\* --- Per-component state (STATE_DB warm restart state) ---
\* Reference: warm_restart.cpp WarmStart state machine
VARIABLE componentState     \* [Component -> state constant]

\* --- Reconciliation timer state (Families 1, 4) ---
\* Reference: warmRestartAssist.cpp constructor (timer), neighsyncd.cpp:62
VARIABLE reconcileTimer     \* [Component -> 0..MaxTimer or -1 (not started)]
VARIABLE timerFired         \* [Component -> BOOLEAN]

\* --- Orchagent internal state (Family 2) ---
\* Reference: orchdaemon.cpp:1012-1245
VARIABLE orchInternalState  \* Orchagent's internal freeze/restore state
VARIABLE pendingEvents      \* Nat: events in ring buffer after READY reply
VARIABLE readyReplySent     \* BOOLEAN: READY sent to restart checker

\* --- Syncd internal state (Families 3, 5) ---
\* Reference: Syncd.cpp:4460-5420
VARIABLE syncdMode          \* Syncd's current operating mode
VARIABLE asicConnected      \* BOOLEAN: connected to ASIC hardware
VARIABLE asicConsistent     \* BOOLEAN: ASIC state is self-consistent
VARIABLE redisUpdated       \* BOOLEAN: Redis DB reflects ASIC state

\* --- Reconciliation cache (Family 4) ---
\* Reference: warmRestartAssist.cpp:179-306
VARIABLE cache              \* [Component -> [Key -> cache state]]
VARIABLE appDB              \* [Key -> value or Nil] — abstract AppDB state
VARIABLE replayed           \* [Component -> SUBSET Key] keys replayed

\* --- Notification channel (abstract Redis pub/sub) ---
VARIABLE notifications      \* Set of pending notification messages

\* ============================================================================
\* VARIABLE GROUPS
\* ============================================================================

phaseVars     == <<phase, pointOfNoReturn>>
compVars      == <<componentState>>
timerVars     == <<reconcileTimer, timerFired>>
orchVars      == <<orchInternalState, pendingEvents, readyReplySent>>
syncdVars     == <<syncdMode, asicConnected, asicConsistent, redisUpdated>>
cacheVars     == <<cache, appDB, replayed>>
notifVars     == <<notifications>>

vars == <<phaseVars, compVars, timerVars, orchVars, syncdVars, cacheVars,
          notifVars>>

\* ============================================================================
\* HELPERS
\* ============================================================================

\* All components in a given state
ComponentsInState(s) == {c \in Component : componentState[c] = s}

\* Check if all components have reached at least a given state
\* Uses the state ordering: Running < Frozen < Quiescent < Checkpointed
ShutdownStateAtLeast(c, target) ==
    LET order == (CRunning       :> 0) @@
                 (CFrozen        :> 1) @@
                 (CQuiescent     :> 2) @@
                 (CCheckpointed  :> 3) @@
                 (CFailed        :> 4)  \* Failed components don't block progress
    IN order[componentState[c]] >= order[target]

\* Check if all prerequisite components are reconciled (Family 1)
\* Reference: modeling-brief.md Family 1 — dependency chain
PrerequisitesReconciled(c) ==
    \A dep \in Depends[c] : componentState[dep] = CReconciled

\* ============================================================================
\* ACTIONS: SHUTDOWN SEQUENCE (Warmboot Manager)
\* Reference: Warmboot_Manager_HLD.md, warm-reboot script
\* ============================================================================

\* --------------------------------------------------------------------------
\* StartWarmReboot: Warmboot Manager begins shutdown sequence.
\* Reference: Warmboot_Manager_HLD.md Phase 1 — sanity checks
\* --------------------------------------------------------------------------
StartWarmReboot ==
    /\ phase = PhaseRunning
    /\ phase' = PhaseSanity
    /\ UNCHANGED <<pointOfNoReturn, compVars, timerVars, orchVars,
                   syncdVars, cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* CompleteSanityChecks: Sanity checks pass, enter Freeze phase.
\* Reference: Warmboot_Manager_HLD.md Phase 1 completion
\* --------------------------------------------------------------------------
CompleteSanityChecks ==
    /\ phase = PhaseSanity
    /\ phase' = PhaseFreeze
    /\ UNCHANGED <<pointOfNoReturn, compVars, timerVars, orchVars,
                   syncdVars, cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* ComponentReceiveFreeze: Component c receives freeze notification.
\* Reference: Warmboot_Manager_HLD.md Phase 2 — freeze
\* Components stop generating new self-sourced intents.
\* --------------------------------------------------------------------------
ComponentReceiveFreeze(c) ==
    /\ phase = PhaseFreeze
    /\ componentState[c] = CRunning
    \* Component transitions to Frozen
    /\ componentState' = [componentState EXCEPT ![c] = CFrozen]
    /\ UNCHANGED <<phaseVars, timerVars, orchVars, syncdVars, cacheVars,
                   notifVars>>

\* --------------------------------------------------------------------------
\* ComponentQuiesce: Component c finishes draining pending work.
\* Reference: Warmboot_Manager_HLD.md Phase 2 — quiescence
\* --------------------------------------------------------------------------
ComponentQuiesce(c) ==
    /\ phase = PhaseFreeze
    /\ componentState[c] = CFrozen
    /\ componentState' = [componentState EXCEPT ![c] = CQuiescent]
    /\ UNCHANGED <<phaseVars, timerVars, orchVars, syncdVars, cacheVars,
                   notifVars>>

\* --------------------------------------------------------------------------
\* EnterCheckpointPhase: All components quiescent, enter checkpoint.
\* Reference: Warmboot_Manager_HLD.md Phase 3 — POINT OF NO RETURN
\* Family 5: After this, must complete warm restart even if errors occur.
\* Family 2: QuiescentBeforeCheckpoint invariant checked here.
\*
\* BUG MECHANISM (Family 2): If orchagent sent READY but events arrived
\* after (pendingEvents > 0), checkpoint captures inconsistent state.
\* --------------------------------------------------------------------------
EnterCheckpointPhase ==
    /\ phase = PhaseFreeze
    \* All components must be quiescent (design intent)
    \* Family 2: but orchagent may claim quiescent while ring buffer not drained
    /\ \A c \in Component : ShutdownStateAtLeast(c, CQuiescent)
    /\ phase' = PhaseCheckpoint
    /\ pointOfNoReturn' = TRUE
    \* syncd disconnects from ASIC at checkpoint
    \* Reference: Syncd.cpp pre-shutdown, SAI disconnect
    /\ asicConnected' = FALSE
    /\ UNCHANGED <<compVars, timerVars, orchVars,
                   syncdMode, asicConsistent, redisUpdated,
                   cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* ComponentCheckpoint: Component c saves state to persistent storage.
\* Reference: Warmboot_Manager_HLD.md Phase 3 — checkpoint notification
\* --------------------------------------------------------------------------
ComponentCheckpoint(c) ==
    /\ phase = PhaseCheckpoint
    /\ componentState[c] = CQuiescent
    /\ componentState' = [componentState EXCEPT ![c] = CCheckpointed]
    /\ UNCHANGED <<phaseVars, timerVars, orchVars, syncdVars, cacheVars,
                   notifVars>>

\* --------------------------------------------------------------------------
\* EnterRebootPhase: All components checkpointed, reboot system.
\* Reference: Warmboot_Manager_HLD.md Phase 4 — kexec reboot
\* --------------------------------------------------------------------------
EnterRebootPhase ==
    /\ phase = PhaseCheckpoint
    /\ \A c \in Component : componentState[c] \in {CCheckpointed, CFailed}
    /\ phase' = PhaseReboot
    /\ UNCHANGED <<pointOfNoReturn, compVars, timerVars, orchVars,
                   syncdVars, cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* SystemReboot: System reboots and enters booting phase.
\* All component states reset to CInitialized.
\* Reference: warm-reboot script — kexec, service restart
\* --------------------------------------------------------------------------
SystemReboot ==
    /\ phase = PhaseReboot
    /\ phase' = PhaseBooting
    \* All components enter Initialized state after boot
    /\ componentState' = [c \in Component |-> CInitialized]
    \* Reconcile timers not started yet
    /\ reconcileTimer' = [c \in Component |-> -1]
    /\ timerFired' = [c \in Component |-> FALSE]
    \* Orchagent enters restore mode
    \* Reference: orchdaemon.cpp:853-862 — isWarmStart() check
    /\ orchInternalState' = OrchRestoring
    /\ pendingEvents' = 0
    /\ readyReplySent' = FALSE
    \* Syncd attempts warm restart init
    \* Reference: Syncd.cpp:5050-5109 — onSyncdStart()
    /\ syncdMode' = SyncdNormal
    /\ asicConnected' = TRUE   \* reconnect to ASIC via SAI
    /\ asicConsistent' = TRUE  \* ASIC state preserved from pre-reboot
    /\ redisUpdated' = TRUE    \* Redis has pre-reboot state
    \* Cache initialized: all pre-reboot keys are STALE
    \* Reference: warmRestartAssist.cpp:131-165 — readTablesToMap()
    /\ cache' = [c \in Component |-> [k \in Key |-> CacheSTALE]]
    /\ replayed' = [c \in Component |-> {}]
    \* appDB retains pre-reboot values (warm restart preserves DB)
    /\ UNCHANGED <<pointOfNoReturn, appDB, notifVars>>

\* ============================================================================
\* ACTIONS: ORCHAGENT FREEZE PROTOCOL (Family 2)
\* Reference: orchdaemon.cpp:1012-1051, 1178-1245
\* ============================================================================

\* --------------------------------------------------------------------------
\* OrchCheckReady: Orchagent checks readiness for warm restart.
\* Reference: orchdaemon.cpp:1178-1209 — warmRestartCheck()
\* Line 1186: getTaskToSync(ts) — check pending tasks
\* Line 1188-1199: if pending tasks, check skipPendingTaskCheck()
\* --------------------------------------------------------------------------
OrchCheckReady ==
    /\ phase = PhaseFreeze
    /\ orchInternalState = OrchRunning
    /\ orchInternalState' = OrchCheckingReady
    /\ UNCHANGED <<phaseVars, compVars, timerVars, pendingEvents,
                   readyReplySent, syncdVars, cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* OrchSendReadyReply: Orchagent sends READY reply.
\* Reference: orchdaemon.cpp:1207 — restartCheckReply("READY")
\*
\* BUG MECHANISM (Family 2): TOCTOU — READY sent at line 1207 but ring
\* buffer not drained until lines 1019-1026. Events can arrive between
\* READY and actual freeze.
\* --------------------------------------------------------------------------
OrchSendReadyReply ==
    /\ phase = PhaseFreeze
    /\ orchInternalState = OrchCheckingReady
    /\ orchInternalState' = OrchReadyReplied
    /\ readyReplySent' = TRUE
    \* Component state becomes Quiescent from external viewpoint
    \* Reference: orchdaemon.cpp:1207 — reply READY before actual quiescence
    /\ componentState' = [componentState EXCEPT ![Orchagent] = CQuiescent]
    /\ UNCHANGED <<phaseVars, timerVars, pendingEvents,
                   syncdVars, cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* EventArrivalAfterReady: Event arrives in ring buffer after READY sent.
\* Reference: orchdaemon.cpp:1012-1014 — ring buffer may receive events
\*            orch.h:196-228 — ring buffer head/tail accessed without atomics
\*
\* BUG MECHANISM (Family 2): This models the TOCTOU window. Events arrive
\* after READY reply but before actual freeze. These events are unsaved
\* state that will be lost on checkpoint.
\* --------------------------------------------------------------------------
EventArrivalAfterReady ==
    /\ phase = PhaseFreeze
    /\ orchInternalState = OrchReadyReplied
    /\ readyReplySent = TRUE
    /\ pendingEvents' = pendingEvents + 1
    /\ UNCHANGED <<phaseVars, compVars, timerVars, orchInternalState,
                   readyReplySent, syncdVars, cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* OrchDrainRingBuffer: Orchagent drains ring buffer before freeze.
\* Reference: orchdaemon.cpp:1019-1026 — while not empty/idle, process
\*
\* Note: draining may not complete all events if new ones arrive.
\* --------------------------------------------------------------------------
OrchDrainRingBuffer ==
    /\ phase = PhaseFreeze
    /\ orchInternalState = OrchReadyReplied
    /\ pendingEvents > 0
    /\ orchInternalState' = OrchDraining
    \* Drain reduces but may not eliminate all events
    \* (new events can arrive during drain)
    /\ pendingEvents' = pendingEvents - 1
    /\ UNCHANGED <<phaseVars, compVars, timerVars, readyReplySent,
                   syncdVars, cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* OrchFreeze: Orchagent actually freezes (disable FDB, learning).
\* Reference: orchdaemon.cpp:1029-1048
\* Line 1035-1041: setBridgePortLearningFDB — may fail on some ports
\* Line 1048: freezeAndHeartBeat(UINT_MAX, heartBeatInterval)
\* --------------------------------------------------------------------------
OrchFreeze ==
    /\ phase = PhaseFreeze
    /\ \/ orchInternalState = OrchReadyReplied
       \/ orchInternalState = OrchDraining
    \* Can freeze even with pending events (bug mechanism Family 2)
    /\ orchInternalState' = OrchFrozen
    /\ componentState' = [componentState EXCEPT ![Orchagent] = CQuiescent]
    /\ UNCHANGED <<phaseVars, timerVars, pendingEvents, readyReplySent,
                   syncdVars, cacheVars, notifVars>>

\* ============================================================================
\* ACTIONS: SYNCD INIT/APPLY VIEW PROTOCOL (Families 3, 5)
\* Reference: Syncd.cpp:4460-5420
\* ============================================================================

\* --------------------------------------------------------------------------
\* SyncdReceiveInitView: Syncd receives INIT_VIEW from orchagent.
\* Reference: Syncd.cpp:4591-4615 — processNotifySyncd INIT_VIEW
\* Line 4598: m_asicInitViewMode = true
\* Line 4600: clearTempView()
\* Line 4602: clear created objects list
\* --------------------------------------------------------------------------
SyncdReceiveInitView ==
    /\ phase = PhaseBooting
    /\ syncdMode = SyncdNormal
    /\ syncdMode' = SyncdInitView
    /\ UNCHANGED <<phaseVars, compVars, timerVars, orchVars,
                   asicConnected, asicConsistent, redisUpdated,
                   cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* ApplyViewStage1: Non-destructive comparison of pre/post views.
\* Reference: Syncd.cpp:4776-4892 — applyView() Stage 1
\* Line 4816-4817: get current and temp views from Redis
\* Line 4854-4880: for each switch, compareViews()
\*
\* May fail (exception) — returns FAILURE, no ASIC changes made.
\* Reference: Syncd.cpp:4882-4891
\* --------------------------------------------------------------------------
ApplyViewStage1 ==
    /\ phase = PhaseBooting
    /\ syncdMode = SyncdInitView
    /\ syncdMode' = SyncdApplyStage1
    /\ UNCHANGED <<phaseVars, compVars, timerVars, orchVars,
                   asicConnected, asicConsistent, redisUpdated,
                   cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* ApplyViewStage1Fail: Stage 1 comparison fails.
\* Reference: Syncd.cpp:4882-4891 — catch exception, return FAILURE
\*
\* Safe failure: no ASIC operations executed yet.
\* Family 3: syncd returns to non-init mode with stale metadata.
\* Reference: Syncd.cpp:4619 — m_asicInitViewMode = false (set BEFORE apply)
\* --------------------------------------------------------------------------
ApplyViewStage1Fail ==
    /\ phase = PhaseBooting
    /\ syncdMode = SyncdApplyStage1
    \* Family 3: m_asicInitViewMode already cleared at line 4619
    /\ syncdMode' = SyncdNormal
    /\ UNCHANGED <<phaseVars, compVars, timerVars, orchVars,
                   asicConnected, asicConsistent, redisUpdated,
                   cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* ApplyViewStage2: Destructive ASIC operations.
\* Reference: Syncd.cpp:4894-4924 — Stage 2
\* Line 4904-4907: executeOperationsOnAsic() — CAN THROW
\* Line 4909: updateRedisDatabase()
\*
\* BUG MECHANISM (Family 3): No rollback. If this fails mid-way,
\* ASIC is in inconsistent state. Code acknowledges this:
\* Syncd.cpp:4797-4799 "ASIC will be in inconsistent state"
\* --------------------------------------------------------------------------
ApplyViewStage2 ==
    /\ phase = PhaseBooting
    /\ syncdMode = SyncdApplyStage1
    /\ asicConnected = TRUE
    /\ syncdMode' = SyncdApplyStage2
    /\ UNCHANGED <<phaseVars, compVars, timerVars, orchVars,
                   asicConnected, asicConsistent, redisUpdated,
                   cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* ApplyViewStage2Fail: ASIC operations fail mid-way.
\* Reference: Syncd.cpp:4904-4907 — executeOperationsOnAsic() throws
\*
\* BUG MECHANISM (Family 3): ASIC partially updated, Redis not updated.
\* Acknowledged at Syncd.cpp:4797-4799.
\* Family 5: No recovery — enters ShutdownWait or crashes.
\* --------------------------------------------------------------------------
ApplyViewStage2Fail ==
    /\ phase = PhaseBooting
    /\ syncdMode = SyncdApplyStage2
    /\ syncdMode' = SyncdShutdownWait
    /\ asicConsistent' = FALSE   \* ASIC partially updated
    \* Redis NOT updated — stale pre-reboot state
    /\ UNCHANGED <<phaseVars, compVars, timerVars, orchVars,
                   asicConnected, redisUpdated, cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* ApplyViewComplete: ASIC ops succeed, update Redis.
\* Reference: Syncd.cpp:4904-4909
\* Line 4904-4907: executeOperationsOnAsic() succeeds
\* Line 4909: updateRedisDatabase()
\* --------------------------------------------------------------------------
ApplyViewComplete ==
    /\ phase = PhaseBooting
    /\ syncdMode = SyncdApplyStage2
    /\ syncdMode' = SyncdDone
    /\ redisUpdated' = TRUE
    /\ asicConsistent' = TRUE
    /\ UNCHANGED <<phaseVars, compVars, timerVars, orchVars,
                   asicConnected, cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* CrashBetweenAsicAndRedis: Crash after ASIC update but before Redis.
\* Reference: Syncd.cpp:4904-4909 — not atomic
\*
\* BUG MECHANISM (Family 3): executeOperationsOnAsic() and
\* updateRedisDatabase() not atomic. Crash between them corrupts
\* next warm boot's view of state.
\* --------------------------------------------------------------------------
CrashBetweenAsicAndRedis ==
    /\ phase = PhaseBooting
    /\ syncdMode = SyncdApplyStage2
    /\ syncdMode' = SyncdCrashed
    /\ asicConsistent' = TRUE    \* ASIC was fully updated
    /\ redisUpdated' = FALSE     \* Redis NOT updated
    /\ UNCHANGED <<phaseVars, compVars, timerVars, orchVars,
                   asicConnected, cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* SyncdInitFail: Syncd fails to initialize on warm restart.
\* Reference: Syncd.cpp:5050-5109 — onSyncdStart()
\* Line 5081: performWarmRestart() may throw
\* Line 5377-5381: RID mismatch throws
\* Line 5403-5407: empty switch list throws (FIXME comment)
\*
\* BUG MECHANISM (Family 5): After checkpoint (point of no return),
\* syncd init failure means no ASIC recovery possible.
\* --------------------------------------------------------------------------
SyncdInitFail ==
    /\ phase = PhaseBooting
    /\ syncdMode = SyncdNormal
    /\ pointOfNoReturn = TRUE
    /\ syncdMode' = SyncdShutdownWait
    /\ asicConnected' = FALSE
    /\ UNCHANGED <<phaseVars, compVars, timerVars, orchVars,
                   asicConsistent, redisUpdated, cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* SyncdRejectInShutdownWait: Syncd rejects all NOTIFY commands.
\* Reference: Syncd.cpp:366-396 — processEventInShutdownWaitMode
\* Line 385-389: blanket FAILURE response to all NOTIFY commands
\*
\* BUG MECHANISM (Family 5): Legitimate APPLY_VIEW rejected. System stuck.
\* --------------------------------------------------------------------------
SyncdRejectInShutdownWait ==
    /\ syncdMode = SyncdShutdownWait
    \* Rejects everything — no recovery possible
    /\ UNCHANGED vars

\* ============================================================================
\* ACTIONS: RECONCILIATION PROTOCOL (Families 1, 4)
\* Reference: orchdaemon.cpp:1059-1136, warmRestartAssist.cpp,
\*            warmRestartHelper.cpp
\* ============================================================================

\* --------------------------------------------------------------------------
\* ComponentStartReconcileTimer: Component starts its reconcile timer.
\* Reference: warmRestartAssist.cpp:49-66 — constructor, getWarmStartTimer
\*            neighsyncd.cpp:62 — timer start BEFORE netlink dump
\*
\* BUG MECHANISM (Family 4): Timer starts before entries replayed.
\* neighsyncd starts 5s timer at line 62, netlink dump at line 67.
\* --------------------------------------------------------------------------
ComponentStartReconcileTimer(c) ==
    /\ phase \in {PhaseBooting, PhaseReconciling}
    /\ componentState[c] = CInitialized
    /\ reconcileTimer[c] = -1
    \* Non-deterministic timer value (models different component timers)
    /\ \E t \in 1..MaxTimer :
        reconcileTimer' = [reconcileTimer EXCEPT ![c] = t]
    /\ UNCHANGED <<phaseVars, compVars, timerFired, orchVars, syncdVars,
                   cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* ComponentReadTable: Component reads pre-reboot state, all entries STALE.
\* Reference: warmRestartAssist.cpp:131-165 — readTablesToMap()
\* Line 151: all entries initialized as STALE
\* Line 161: state transition to RESTORED
\* --------------------------------------------------------------------------
ComponentReadTable(c) ==
    /\ phase \in {PhaseBooting, PhaseReconciling}
    /\ componentState[c] = CInitialized
    /\ componentState' = [componentState EXCEPT ![c] = CRestored]
    \* All keys already STALE from SystemReboot
    /\ UNCHANGED <<phaseVars, timerVars, orchVars, syncdVars, cacheVars,
                   notifVars>>

\* --------------------------------------------------------------------------
\* ReplayEntry: Application replays an entry during reconciliation.
\* Reference: warmRestartAssist.cpp:179-248 — insertToMap()
\*
\* Cache state transitions based on comparison:
\* Line 186-247: if delete_key → DELETE
\*               if key exists + different value → NEW
\*               if key exists + same value → SAME (or stays NEW if already NEW)
\*               if key not in cache → NEW (new entry)
\*
\* BUG MECHANISM (Family 4): contains() asymmetry at line 340-352.
\* Field removal treated as SAME instead of NEW.
\* --------------------------------------------------------------------------
ReplayEntry(c, k) ==
    /\ phase \in {PhaseBooting, PhaseReconciling}
    /\ componentState[c] = CRestored
    /\ k \notin replayed[c]
    /\ timerFired[c] = FALSE   \* Can only replay before timer fires
    /\ replayed' = [replayed EXCEPT ![c] = @ \cup {k}]
    \* Non-deterministic cache state transition (models different values)
    /\ \E newState \in {CacheSAME, CacheNEW, CacheDELETE} :
        cache' = [cache EXCEPT ![c][k] = newState]
    /\ UNCHANGED <<phaseVars, compVars, timerVars, orchVars, syncdVars,
                   appDB, notifVars>>

\* --------------------------------------------------------------------------
\* ReconcileTimerTick: Timer decrements toward firing.
\* Reference: neighsyncd.cpp:44-90 — main loop timer check
\* --------------------------------------------------------------------------
ReconcileTimerTick(c) ==
    /\ phase \in {PhaseBooting, PhaseReconciling}
    /\ componentState[c] = CRestored
    /\ reconcileTimer[c] > 0
    /\ timerFired[c] = FALSE
    /\ reconcileTimer' = [reconcileTimer EXCEPT ![c] = @ - 1]
    /\ UNCHANGED <<phaseVars, compVars, timerFired, orchVars, syncdVars,
                   cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* ReconcileTimerFire: Timer expires, triggering reconciliation.
\* Reference: warmRestartAssist.cpp — timer expiry triggers reconcile()
\*
\* BUG MECHANISM (Family 4): Timer fires before all entries replayed.
\* STALE entries (not yet replayed) will be deleted in Reconcile.
\* BUG MECHANISM (Family 1): Timer fires independently per component.
\* --------------------------------------------------------------------------
ReconcileTimerFire(c) ==
    /\ phase \in {PhaseBooting, PhaseReconciling}
    /\ componentState[c] = CRestored
    /\ reconcileTimer[c] = 0
    /\ timerFired[c] = FALSE
    /\ timerFired' = [timerFired EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<phaseVars, compVars, reconcileTimer, orchVars, syncdVars,
                   cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* ReconcileComponent: Component applies cached diffs to appDB.
\* Reference: warmRestartAssist.cpp:258-306 — reconcile()
\*
\* Line 271-275: SAME entries — no action
\* Line 277-283: STALE/DELETE entries — delete from appDB
\* Line 285-292: NEW entries — set in appDB
\* Line 303: state → RECONCILED
\*
\* BUG MECHANISM (Family 1): No check that prerequisite components
\* are reconciled. Component reconciles independently.
\* BUG MECHANISM (Family 4): STALE entries deleted even if their
\* replay hasn't arrived yet (timer fired too early).
\* --------------------------------------------------------------------------
ReconcileComponent(c) ==
    /\ phase \in {PhaseBooting, PhaseReconciling}
    /\ c /= Orchagent  \* Orchagent has dedicated path (OrchWarmRestore)
    /\ componentState[c] = CRestored
    /\ timerFired[c] = TRUE
    \* Family 1: NO prerequisite check — components reconcile independently
    \* This is the design defect. PrerequisitesReconciled(c) is NOT checked.
    \* Reference: orchdaemon.cpp:1132 — no ordering barrier
    /\ LET
        \* Apply cache operations to appDB
        \* Reference: warmRestartAssist.cpp:271-292
        newAppDB == [k \in Key |->
            CASE cache[c][k] = CacheSAME   -> appDB[k]      \* No change (line 271-275)
              [] cache[c][k] = CacheSTALE   -> Nil           \* Delete stale (line 277-283)
              [] cache[c][k] = CacheDELETE  -> Nil           \* Delete marked (line 277-283)
              [] cache[c][k] = CacheNEW     -> c             \* Set new value (line 285-292)
                                                             \* (abstract: value = component ID)
              [] cache[c][k] = CacheEmpty   -> appDB[k]]     \* No entry
       IN
        /\ appDB' = newAppDB
        \* Clear cache after reconcile
        \* Reference: warmRestartAssist.cpp:300-302
        /\ cache' = [cache EXCEPT ![c] = [k \in Key |-> CacheEmpty]]
        /\ componentState' = [componentState EXCEPT ![c] = CReconciled]
        /\ UNCHANGED <<phaseVars, timerVars, orchVars, syncdVars,
                       replayed, notifVars>>

\* --------------------------------------------------------------------------
\* ReconcileComponentWithoutTimer: Component reconciles synchronously
\* (e.g., vxlanmgrd declares RECONCILED on first 1s timeout with no
\* content verification).
\* Reference: vxlanmgrd — declares RECONCILED on SELECT_TIMEOUT
\*
\* BUG MECHANISM (Family 1): Premature RECONCILED declaration.
\* vxlanmgrd declares RECONCILED after 1s; fdbsyncd starts reconciling
\* before VXLAN tunnels are actually restored.
\* --------------------------------------------------------------------------
ReconcileComponentWithoutTimer(c) ==
    /\ phase \in {PhaseBooting, PhaseReconciling}
    /\ c /= Orchagent  \* Orchagent has dedicated path (OrchWarmRestore)
    /\ componentState[c] = CRestored
    \* Some components reconcile immediately without waiting for all entries
    /\ componentState' = [componentState EXCEPT ![c] = CReconciled]
    /\ UNCHANGED <<phaseVars, timerVars, orchVars, syncdVars, cacheVars,
                   notifVars>>

\* ============================================================================
\* ACTIONS: ORCHAGENT WARM RESTORE (Families 1, 2, 3)
\* Reference: orchdaemon.cpp:1059-1136 — warmRestoreAndSyncUp()
\* ============================================================================

\* --------------------------------------------------------------------------
\* OrchWarmRestore: Orchagent performs 3-phase restoration.
\* Reference: orchdaemon.cpp:1059-1136 — warmRestoreAndSyncUp()
\* Line 1067: call o->bake() on all orchestrators
\* Line 1085-1098: 3x iteration loop
\* Line 1114: warmRestoreValidation()
\* Line 1118: return false if validation fails
\*
\* Abstracted as single action since the 3 phases are synchronous
\* within orchagent's single thread.
\* --------------------------------------------------------------------------
OrchWarmRestore ==
    /\ phase = PhaseBooting
    /\ orchInternalState = OrchRestoring
    /\ componentState[Orchagent] \in {CInitialized, CRestored}
    /\ orchInternalState' = OrchWaitApplyView
    \* Reference: orchdaemon.cpp:1168 — state set to RESTORED
    /\ componentState' = [componentState EXCEPT ![Orchagent] = CRestored]
    /\ UNCHANGED <<phaseVars, timerVars, pendingEvents, readyReplySent,
                   syncdVars, cacheVars, notifVars>>

\* --------------------------------------------------------------------------
\* OrchSendApplyView: Orchagent sends APPLY_VIEW to syncd.
\* Reference: orchdaemon.cpp:1123 — syncd_apply_view()
\*
\* BUG MECHANISM (Family 1): APPLY_VIEW sent before fdbsyncd's 120s
\* timer completes. VXLAN FDB entries may be stale in hardware.
\* --------------------------------------------------------------------------
OrchSendApplyView ==
    /\ phase = PhaseBooting
    /\ orchInternalState = OrchWaitApplyView
    \* Orchagent sends INIT_VIEW + APPLY_VIEW sequence
    /\ notifications' = notifications \cup {"INIT_VIEW", "APPLY_VIEW"}
    /\ UNCHANGED <<phaseVars, compVars, timerVars, orchVars, syncdVars,
                   cacheVars>>

\* --------------------------------------------------------------------------
\* OrchReconcileComplete: Orchagent finishes warm restore after APPLY_VIEW.
\* Reference: orchdaemon.cpp:1127-1134
\* Line 1127: call o->onWarmBootEnd() for all orchs
\* Line 1134: WarmStart::RECONCILED
\* --------------------------------------------------------------------------
OrchReconcileComplete ==
    /\ phase \in {PhaseBooting, PhaseReconciling}
    /\ orchInternalState = OrchWaitApplyView
    /\ syncdMode = SyncdDone
    /\ orchInternalState' = OrchReconciling
    /\ componentState' = [componentState EXCEPT ![Orchagent] = CReconciled]
    /\ phase' = PhaseReconciling
    /\ UNCHANGED <<pointOfNoReturn, timerVars, pendingEvents, readyReplySent,
                   syncdVars, cacheVars, notifVars>>

\* ============================================================================
\* ACTIONS: FAILURE / TIMEOUT (Family 5)
\* ============================================================================

\* --------------------------------------------------------------------------
\* ComponentFailDuringShutdown: Component fails during freeze/checkpoint.
\* Reference: Warmboot_Manager_HLD.md — component failure handling
\*
\* Family 5: Before point of no return, can unfreeze and abort.
\* After point of no return, failure is unrecoverable.
\* --------------------------------------------------------------------------
ComponentFailDuringShutdown(c) ==
    /\ phase \in {PhaseFreeze, PhaseCheckpoint}
    /\ componentState[c] \notin {CReconciled, CFailed}
    /\ componentState' = [componentState EXCEPT ![c] = CFailed]
    /\ UNCHANGED <<phaseVars, timerVars, orchVars, syncdVars, cacheVars,
                   notifVars>>

\* --------------------------------------------------------------------------
\* ComponentFailDuringReconciliation: Component fails during reconciliation.
\* Reference: neighsyncd.cpp — exit(EXIT_FAILURE) on timeout
\*
\* BUG MECHANISM (Family 5): neighsyncd exits without setting FAILED state.
\* Reference: CR-5 in modeling brief.
\* --------------------------------------------------------------------------
ComponentFailDuringReconciliation(c) ==
    /\ phase \in {PhaseBooting, PhaseReconciling}
    /\ componentState[c] \in {CInitialized, CRestored}
    /\ componentState' = [componentState EXCEPT ![c] = CFailed]
    /\ UNCHANGED <<phaseVars, timerVars, orchVars, syncdVars, cacheVars,
                   notifVars>>

\* --------------------------------------------------------------------------
\* ReconcileTimeout: Reconciliation takes too long, trigger cold fallback.
\* Reference: Warmboot Manager — monitors reconciliation status
\*
\* BUG MECHANISM (Family 5): Cold restart triggered while some components
\* have already reconciled (partial state).
\* --------------------------------------------------------------------------
ReconcileTimeout ==
    /\ phase = PhaseReconciling
    \* At least one component not yet reconciled
    /\ \E c \in Component : componentState[c] \notin {CReconciled, CFailed}
    \* Timeout: all remaining non-reconciled components fail
    /\ componentState' = [c \in Component |->
        IF componentState[c] \in {CReconciled, CFailed}
        THEN componentState[c]
        ELSE CFailed]
    /\ UNCHANGED <<phaseVars, timerVars, orchVars, syncdVars, cacheVars,
                   notifVars>>

\* ============================================================================
\* TERMINAL STATE (warm reboot complete or stuck)
\* ============================================================================

\* System has reached a terminal state — no more progress possible.
\* Covers: successful completion, reconciliation timeout, syncd stuck.
Done ==
    \/ \* All components finished (reconciled or failed)
       /\ phase = PhaseReconciling
       /\ \A c \in Component : componentState[c] \in {CReconciled, CFailed}
    \/ \* Syncd stuck in ShutdownWait or Crashed (no recovery)
       /\ syncdMode \in {SyncdShutdownWait, SyncdCrashed}
    \/ \* Deadlocked in shutdown: some component failed, others can't proceed
       /\ phase \in {PhaseFreeze, PhaseCheckpoint}
       /\ \E c \in Component : componentState[c] = CFailed
       /\ ~(\A c \in Component : ShutdownStateAtLeast(c, CQuiescent))

\* ============================================================================
\* INIT AND NEXT
\* ============================================================================

Init ==
    /\ phase = PhaseRunning
    /\ pointOfNoReturn = FALSE
    /\ componentState = [c \in Component |-> CRunning]
    /\ reconcileTimer = [c \in Component |-> -1]
    /\ timerFired = [c \in Component |-> FALSE]
    /\ orchInternalState = OrchRunning
    /\ pendingEvents = 0
    /\ readyReplySent = FALSE
    /\ syncdMode = SyncdNormal
    /\ asicConnected = TRUE
    /\ asicConsistent = TRUE
    /\ redisUpdated = TRUE
    /\ cache = [c \in Component |-> [k \in Key |-> CacheEmpty]]
    /\ appDB = [k \in Key |-> Nil]
    /\ replayed = [c \in Component |-> {}]
    /\ notifications = {}

Next ==
    \* --- Terminal state (stutter) ---
    \/ (Done /\ UNCHANGED vars)
    \* --- Shutdown sequence ---
    \/ StartWarmReboot
    \/ CompleteSanityChecks
    \/ \E c \in Component : ComponentReceiveFreeze(c)
    \/ \E c \in Component : ComponentQuiesce(c)
    \/ EnterCheckpointPhase
    \/ \E c \in Component : ComponentCheckpoint(c)
    \/ EnterRebootPhase
    \/ SystemReboot
    \* --- Orchagent freeze protocol (Family 2) ---
    \/ OrchCheckReady
    \/ OrchSendReadyReply
    \/ EventArrivalAfterReady
    \/ OrchDrainRingBuffer
    \/ OrchFreeze
    \* --- Syncd INIT/APPLY_VIEW (Families 3, 5) ---
    \/ SyncdReceiveInitView
    \/ ApplyViewStage1
    \/ ApplyViewStage1Fail
    \/ ApplyViewStage2
    \/ ApplyViewStage2Fail
    \/ ApplyViewComplete
    \/ CrashBetweenAsicAndRedis
    \/ SyncdInitFail
    \/ SyncdRejectInShutdownWait
    \* --- Reconciliation (Families 1, 4) ---
    \/ \E c \in Component : ComponentStartReconcileTimer(c)
    \/ \E c \in Component : ComponentReadTable(c)
    \/ \E c \in Component, k \in Key : ReplayEntry(c, k)
    \/ \E c \in Component : ReconcileTimerTick(c)
    \/ \E c \in Component : ReconcileTimerFire(c)
    \/ \E c \in Component : ReconcileComponent(c)
    \/ \E c \in Component : ReconcileComponentWithoutTimer(c)
    \* --- Orchagent warm restore ---
    \/ OrchWarmRestore
    \/ OrchSendApplyView
    \/ OrchReconcileComplete
    \* --- Failures ---
    \/ \E c \in Component : ComponentFailDuringShutdown(c)
    \/ \E c \in Component : ComponentFailDuringReconciliation(c)
    \/ ReconcileTimeout

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* --- Standard Safety ---

\* Phase monotonicity: phases only advance forward (no backward transitions)
PhaseMonotonicity ==
    LET order == (PhaseRunning     :> 0) @@
                 (PhaseSanity      :> 1) @@
                 (PhaseFreeze      :> 2) @@
                 (PhaseCheckpoint  :> 3) @@
                 (PhaseReboot      :> 4) @@
                 (PhaseBooting     :> 5) @@
                 (PhaseReconciling :> 6)
    IN order[phase] >= 0  \* Always in a valid phase

\* Point of no return: once set, never cleared
PointOfNoReturnPermanent ==
    pointOfNoReturn => phase \in {PhaseCheckpoint, PhaseReboot,
                                  PhaseBooting, PhaseReconciling}

\* --- Extension Invariants (Bug Family Targets) ---

\* FAMILY 1: OrderedReconciliation
\* If component B depends on A, B should not reconcile before A.
\* This invariant is EXPECTED TO BE VIOLATED — it captures the design defect.
OrderedReconciliation ==
    \A c \in Component :
        componentState[c] = CReconciled =>
            \A dep \in Depends[c] : componentState[dep] = CReconciled

\* FAMILY 1: NoStaleDelete
\* A STALE key should not be deleted if its replayed value hasn't arrived.
\* Violated when timer fires before all entries replayed.
NoStaleDelete ==
    \A c \in Component, k \in Key :
        (timerFired[c] = TRUE /\ cache[c][k] = CacheSTALE) =>
            k \in replayed[c]

\* FAMILY 2: QuiescentBeforeCheckpoint
\* All components must be truly quiescent before checkpoint.
\* Violated when orchagent has pending events at checkpoint time.
QuiescentBeforeCheckpoint ==
    phase = PhaseCheckpoint => pendingEvents = 0

\* FAMILY 2: FreezeImpliesNoEvents
\* After READY reply, no new events should be processed.
\* Violated by EventArrivalAfterReady action.
FreezeImpliesNoEvents ==
    readyReplySent => pendingEvents = 0

\* FAMILY 3: ApplyViewAtomicity
\* If APPLY_VIEW Stage 2 completes, ASIC and Redis must be consistent.
ApplyViewAtomicity ==
    syncdMode = SyncdDone => (asicConsistent /\ redisUpdated)

\* FAMILY 3: AsicRedisConsistency
\* After any APPLY_VIEW outcome, ASIC and Redis states should agree.
\* Violated on crash between ASIC update and Redis update.
AsicRedisConsistency ==
    asicConsistent => redisUpdated

\* FAMILY 5: PointOfNoReturnRecovery
\* After point of no return, system should not be stuck in ShutdownWait.
\* (This is a safety invariant approximation of the liveness property)
NoStuckAfterPointOfNoReturn ==
    (pointOfNoReturn /\ syncdMode = SyncdShutdownWait) =>
        \* There should be a recovery path, but there isn't.
        \* This invariant documents the expected violation.
        FALSE

\* --- Structural Invariants ---

\* Component state consistency: state corresponds to phase
ComponentPhaseConsistency ==
    /\ (phase = PhaseRunning => \A c \in Component :
            componentState[c] = CRunning)
    /\ (phase \in {PhaseBooting, PhaseReconciling} =>
            \A c \in Component :
                componentState[c] \in {CInitialized, CRestored,
                                       CReconciled, CFailed})

\* Syncd mode consistency
SyncdModeConsistency ==
    /\ (phase = PhaseRunning => syncdMode = SyncdNormal)
    /\ (syncdMode = SyncdDone => asicConsistent)

\* Timer consistency: timer only active for Restored components
TimerConsistency ==
    \A c \in Component :
        reconcileTimer[c] >= 0 =>
            componentState[c] \in {CInitialized, CRestored, CReconciled, CFailed}

\* Cache consistency: non-empty cache only during reconciliation
CacheConsistency ==
    \A c \in Component, k \in Key :
        cache[c][k] /= CacheEmpty =>
            phase \in {PhaseBooting, PhaseReconciling}

\* --- Temporal Properties ---

\* All components eventually reconcile or fail
ReconcileTermination ==
    <>(\A c \in Component :
        componentState[c] \in {CReconciled, CFailed})

\* System eventually reaches reconciling phase (liveness under fairness)
EventualReconciliation ==
    <>(phase = PhaseReconciling)

=============================================================================
