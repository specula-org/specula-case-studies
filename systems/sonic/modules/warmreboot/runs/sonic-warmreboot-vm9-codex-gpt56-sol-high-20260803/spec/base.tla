------------------------------ MODULE base ------------------------------
(***************************************************************************
 * SONiC warm-reboot base specification (Category A: distributed/message
 * passing).  The three records deliberately preserve the independently
 * owned backend/host, shutdown, and warm-restore state machines.
 *
 * Source paths are relative to sonic-buildimage unless marked as a pinned
 * submodule.  Every action block below cites the implementation evidence
 * whose control flow it abstracts.
 *************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Asics, Components, MaxEpoch, MaxInFlight

ASSUME /\ Asics /= {}
       /\ Components /= {}
       /\ MaxEpoch \in Nat \ {0}
       /\ MaxInFlight \in Nat \ {0}

NoEpoch == 0

BackendManagers == {"idle", "in_progress"}
DbusPhases == {"none", "calling", "delivered", "failed", "finished"}
HostStatuses == {"idle", "accepted", "complete", "rejected"}
FailureClasses == {"none", "retriable", "definitive"}
FailureCauses == {"none", "thread_launch", "transport", "host_reject", "timeout"}
PlatformPhases == {"idle", "precommit", "committed", "rebooted",
                   "restoring", "running", "recovery"}
ProducerStates == {"running", "quiescing", "stopped"}
ConsumerStates == {"running", "drained", "frozen", "stopped"}
SnapshotStates == {"none", "pruned", "valid", "invalid"}
SnapshotSchemas == {"compatible", "incompatible"}
RestoreDecisions == {"none", "warm", "cold"}
ReadinessStates == {"unknown", "ready", "timeout", "malformed"}

VARIABLES
    backend,     \* BackendHostOwnership + FailureClasses (Scenarios 1, 5)
    shutdown,    \* CausalDrain + IrreversibleCommit (Scenario 3)
    warm         \* EpochState + MultiNamespace (Scenarios 2, 4)

vars == <<backend, shutdown, warm>>

BackendInit ==
    [alive          |-> TRUE,
     active         |-> FALSE,
     manager        |-> "idle",
     requestEpoch   |-> NoEpoch,
     nextEpoch      |-> 1,
     dbusPhase      |-> "none",
     localTimer     |-> FALSE,
     hostPending    |-> FALSE,
     hostEpoch      |-> NoEpoch,
     hostStatus     |-> "idle",
     failureClass   |-> "none",
     failureCause   |-> "none",
     threadJoinable |-> FALSE]

ShutdownInit ==
    [platformPhase    |-> "idle",
     rollbackEnabled  |-> TRUE,
     producerState    |-> [a \in Asics |-> "running"],
     inFlight         |-> [a \in Asics |-> 0],
     consumerState    |-> [a \in Asics |-> "running"],
     stoppedAtCommit  |-> {},
     postCommitFailure|-> FALSE]

WarmInit ==
    [bootEpoch          |-> NoEpoch,
     flagEpoch          |-> [a \in Asics |-> NoEpoch],
     snapshotEpoch      |-> [a \in Asics |-> NoEpoch],
     snapshotValidity   |-> [a \in Asics |-> "none"],
     snapshotSchema     |-> [a \in Asics |-> "compatible"],
     copyComplete       |-> [a \in Asics |-> FALSE],
     snapshotQuiescent  |-> [a \in Asics |-> FALSE],
     namespaceFailed    |-> [a \in Asics |-> FALSE],
     restoreDecision    |-> [a \in Asics |-> "none"],
     restoreEpoch       |-> [a \in Asics |-> NoEpoch],
     consumedSnapshotEpoch |-> [a \in Asics |-> NoEpoch],
     restoredEpoch      |-> [c \in Components |-> NoEpoch],
     required           |-> {},
     readiness          |-> [c \in Components |-> "unknown"],
     deadlineExpired    |-> FALSE,
     finalizedNsEpoch   |-> [a \in Asics |-> NoEpoch],
     finalizedEpoch     |-> NoEpoch,
     dbSavedEpoch       |-> NoEpoch]

Init ==
    /\ backend = BackendInit
    /\ shutdown = ShutdownInit
    /\ warm = WarmInit

(***************************************************************************
 * Backend / host ownership actions -- Scenarios 1 and 5.
 *************************************************************************)

\* rebootbe.cpp:143-207 checks RebootAllowed, calls Start, and marks the
\* manager in progress; reboot_thread.cpp:222-295 sets volatile active state.
HandleRebootRequestAccept ==
    /\ backend.alive
    /\ backend.manager = "idle"                    \* rebootbe.cpp:168-193
    /\ ~backend.active                             \* reboot_thread.cpp:224-228
    /\ backend.nextEpoch <= MaxEpoch               \* trace-only correlation
    /\ backend' = [backend EXCEPT
          !.active = TRUE,                          \* reboot_thread.cpp:281-283
          !.manager = "in_progress",               \* rebootbe.cpp:198-205
          !.requestEpoch = backend.nextEpoch,
          !.nextEpoch = @ + 1,
          !.dbusPhase = "calling",                 \* reboot_thread.cpp:144-146
          !.failureClass = "none",
          !.failureCause = "none",
          !.threadJoinable = TRUE]
    /\ UNCHANGED <<shutdown, warm>>

\* reboot_thread.cpp:281-293 sets active before std::thread construction and
\* notifies completion on construction failure.
StartThreadLaunchFailure ==
    /\ backend.alive
    /\ backend.manager = "idle"
    /\ ~backend.active
    /\ backend.nextEpoch <= MaxEpoch
    /\ backend' = [backend EXCEPT
          !.active = TRUE,                          \* reboot_thread.cpp:281-283
          !.manager = "in_progress",               \* rebootbe.cpp:198-205
          !.requestEpoch = backend.nextEpoch,
          !.nextEpoch = @ + 1,
          !.dbusPhase = "finished",
          !.failureClass = "retriable",            \* reboot_thread.cpp:284-293
          !.failureCause = "thread_launch",
          !.threadJoinable = FALSE]
    /\ UNCHANGED <<shutdown, warm>>

\* pinned sonic-host-services/host_modules/reboot.py:83-97,140-251 accepts
\* into a separate in-memory worker after the synchronous D-Bus handoff.
HostServiceIssueRebootAccept ==
    /\ backend.alive
    /\ backend.dbusPhase = "calling"                \* reboot_thread.cpp:144-152
    /\ ~backend.hostPending
    /\ backend' = [backend EXCEPT
          !.dbusPhase = "delivered",
          !.hostPending = TRUE,
          !.hostEpoch = backend.requestEpoch,
          !.hostStatus = "accepted"]
    /\ UNCHANGED <<shutdown, warm>>

\* interfaces.cpp:35-48 maps a host application rejection to DBUS_FAIL;
\* reboot_thread.cpp:148-150 records it as a non-retriable failure.
HostServiceIssueRebootReject ==
    /\ backend.alive
    /\ backend.dbusPhase = "calling"
    /\ backend.hostPending
    /\ backend' = [backend EXCEPT
          !.dbusPhase = "failed",
          !.hostStatus = "rejected",
          !.failureClass = "definitive",
          !.failureCause = "host_reject"]
    /\ UNCHANGED <<shutdown, warm>>

\* interfaces.cpp:35-41 catches transport errors; interfaces.cpp:43-48 and
\* reboot_thread.cpp:148-150 collapse transport and rejection classifications.
HostServiceTransportFailure ==
    /\ backend.alive
    /\ backend.dbusPhase = "calling"
    /\ backend' = [backend EXCEPT
          !.dbusPhase = "failed",
          !.failureClass = "definitive",
          !.failureCause = "transport"]
    /\ UNCHANGED <<shutdown, warm>>

\* reboot_thread.cpp:91-103 creates/starts the timer only after D-Bus returns.
WaitForPlatformRebootStart ==
    /\ backend.alive
    /\ backend.dbusPhase = "delivered"
    /\ ~backend.localTimer
    /\ backend' = [backend EXCEPT !.localTimer = TRUE]
    /\ UNCHANGED <<shutdown, warm>>

\* reboot_thread.cpp:64-103,155-209 treats timer expiry as platform failure.
PlatformRebootDeadline ==
    /\ backend.alive
    /\ backend.localTimer
    /\ backend' = [backend EXCEPT
          !.localTimer = FALSE,
          !.dbusPhase = "finished",
          !.failureClass = "definitive",
          !.failureCause = "timeout"]
    /\ UNCHANGED <<shutdown, warm>>

\* reboot_thread.cpp:212-219 notifies; rebootbe.cpp:302-309 joins and clears
\* the manager.  reboot_thread.cpp:48-51 clears active on a successful join.
HandleRebootFinishJoinable ==
    /\ backend.alive
    /\ backend.dbusPhase \in {"failed", "finished"}
    /\ backend.threadJoinable
    /\ backend' = [backend EXCEPT
          !.active = FALSE,
          !.manager = "idle",
          !.requestEpoch = NoEpoch,
          !.threadJoinable = FALSE]
    /\ UNCHANGED <<shutdown, warm>>

\* reboot_thread.cpp:40-46 returns without clearing active for a non-joinable
\* thread; rebootbe.cpp:302-309 nevertheless resets the manager to IDLE.
HandleRebootFinishNonJoinable ==
    /\ backend.alive
    /\ backend.dbusPhase = "finished"
    /\ ~backend.threadJoinable
    /\ backend' = [backend EXCEPT !.manager = "idle"]
    /\ UNCHANGED <<shutdown, warm>>

\* Process termination destroys only volatile backend ownership.  The STATE_DB
\* connector is unused for request recovery (reboot_thread.cpp:28-32;
\* rebootbe.cpp:23-30,41-46).
BackendCrash ==
    /\ backend.alive
    /\ backend' = [backend EXCEPT
          !.alive = FALSE,
          !.active = FALSE,
          !.manager = "idle",
          !.requestEpoch = NoEpoch,
          !.dbusPhase = "none",
          !.localTimer = FALSE,
          !.threadJoinable = FALSE]
    /\ UNCHANGED <<shutdown, warm>>

\* rebootbe.h:47-49 initializes IDLE; rebootbe.cpp:41-46 does not reconstruct
\* a request from STATE_DB or query host ownership.
BackendRecover ==
    /\ ~backend.alive
    /\ backend' = [backend EXCEPT
          !.alive = TRUE,
          !.active = FALSE,
          !.manager = "idle",
          !.requestEpoch = NoEpoch,
          !.dbusPhase = "none",
          !.localTimer = FALSE,
          !.threadJoinable = FALSE]
    /\ UNCHANGED <<shutdown, warm>>

\* pinned sonic-host-services/host_modules/reboot.py:140-251 completes its
\* independent worker; completion may be later than the backend timer/restart.
HostComplete ==
    /\ backend.hostPending
    /\ backend' = [backend EXCEPT
          !.hostPending = FALSE,
          !.hostStatus = "complete"]
    /\ UNCHANGED <<shutdown, warm>>

(***************************************************************************
 * Warm epoch, causal shutdown, and namespace snapshot actions --
 * Scenarios 2, 3, and 4.
 *************************************************************************)

\* pinned sonic-utilities/scripts/fast-reboot:979-992 begins per-namespace
\* warm enablement after the host has accepted the warm reboot.
FastRebootBegin ==
    /\ backend.hostPending
    /\ backend.hostEpoch > NoEpoch
    /\ shutdown.platformPhase = "idle"
    /\ shutdown' = [shutdown EXCEPT !.platformPhase = "precommit"]
    /\ warm' = [warm EXCEPT
          !.bootEpoch = backend.hostEpoch,
          !.required = {},
          !.restoredEpoch = [c \in Components |-> NoEpoch],
          !.readiness = [c \in Components |-> "unknown"],
          !.deadlineExpired = FALSE,
          !.finalizedNsEpoch = [a \in Asics |-> NoEpoch],
          !.finalizedEpoch = NoEpoch,
          !.dbSavedEpoch = NoEpoch,
          !.restoreDecision = [a \in Asics |-> "none"],
          !.restoreEpoch = [a \in Asics |-> NoEpoch],
          !.consumedSnapshotEpoch = [a \in Asics |-> NoEpoch],
          !.namespaceFailed = [a \in Asics |-> FALSE]]
    /\ UNCHANGED backend

\* fast-reboot:979-992 executes warm enablement independently per namespace.
EnableWarmRestart(a) ==
    /\ a \in Asics
    /\ shutdown.platformPhase = "precommit"
    /\ warm.flagEpoch[a] /= warm.bootEpoch
    /\ warm' = [warm EXCEPT !.flagEpoch[a] = warm.bootEpoch]
    /\ UNCHANGED <<backend, shutdown>>

\* fast-reboot:101-148 continues individual namespace commands under force.
NamespaceCommandFailure(a) ==
    /\ a \in Asics
    /\ shutdown.platformPhase \in {"precommit", "committed"}
    /\ ~warm.namespaceFailed[a]
    /\ warm' = [warm EXCEPT !.namespaceFailed[a] = TRUE]
    /\ UNCHANGED <<backend, shutdown>>

\* fast-reboot:387-449 requests pre-shutdown; :1075-1156 starts keepalive/CPA
\* and begins the orchagent freeze sequence.
PreShutdownProducer(a) ==
    /\ a \in Asics
    /\ shutdown.platformPhase = "precommit"
    /\ shutdown.producerState[a] = "running"
    /\ shutdown' = [shutdown EXCEPT !.producerState[a] = "quiescing"]
    /\ UNCHANGED <<backend, warm>>

\* Brief finding #12257: a CONFIG_DB update may remain in transit across the
\* restart-check/freeze barrier (fast-reboot:1075-1156).
QueueConfigurationUpdate(a) ==
    /\ a \in Asics
    /\ shutdown.platformPhase = "precommit"
    /\ shutdown.producerState[a] /= "stopped"
    /\ shutdown.inFlight[a] < MaxInFlight
    /\ shutdown' = [shutdown EXCEPT !.inFlight[a] = @ + 1]
    /\ UNCHANGED <<backend, warm>>

\* Normal database propagation makes one causally prior update visible.
\* Evidence boundary: fast-reboot:387-449 and brief finding #12257.
DeliverConfigurationUpdate(a) ==
    /\ a \in Asics
    /\ shutdown.inFlight[a] > 0
    /\ shutdown' = [shutdown EXCEPT !.inFlight[a] = @ - 1]
    /\ UNCHANGED <<backend, warm>>

\* fast-reboot:1187-1217 follows generated service order and can continue
\* after stop failures; each producer stop remains a separate namespace step.
StopProducer(a) ==
    /\ a \in Asics
    /\ shutdown.platformPhase = "precommit"
    /\ shutdown.producerState[a] = "quiescing"
    /\ shutdown' = [shutdown EXCEPT !.producerState[a] = "stopped"]
    /\ UNCHANGED <<backend, warm>>

\* A consumer drain acknowledgement is safe only after producer stop and
\* propagation (fast-reboot:387-449; causal requirement from brief §2 S3).
DrainConsumer(a) ==
    /\ a \in Asics
    /\ shutdown.producerState[a] = "stopped"
    /\ shutdown.inFlight[a] = 0
    /\ shutdown.consumerState[a] = "running"
    /\ shutdown' = [shutdown EXCEPT !.consumerState[a] = "drained"]
    /\ UNCHANGED <<backend, warm>>

\* fast-reboot:1130-1156 may force continuation after a per-ASIC freeze wait;
\* the implementation's local readiness does not establish causal visibility.
FreezeOrchagent(a) ==
    /\ a \in Asics
    /\ shutdown.platformPhase = "precommit"
    /\ shutdown.consumerState[a] \in {"running", "drained"}
    /\ shutdown' = [shutdown EXCEPT !.consumerState[a] = "frozen"]
    /\ UNCHANGED <<backend, warm>>

\* fast-reboot:452-506 destructively prunes STATE_DB before dump.rdb copy.
PruneNamespaceState(a) ==
    /\ a \in Asics
    /\ shutdown.platformPhase = "precommit"
    /\ warm.snapshotValidity[a] /= "pruned"
    /\ warm' = [warm EXCEPT
          !.snapshotValidity[a] = "pruned",
          !.copyComplete[a] = FALSE,
          !.snapshotQuiescent[a] = FALSE]
    /\ UNCHANGED <<backend, shutdown>>

\* Schema compatibility is an environment choice motivated by issue #11824;
\* restore consumers use the resulting file at docker_image_ctl.j2:107-114.
SelectIncompatibleSnapshotSchema(a) ==
    /\ a \in Asics
    /\ warm.snapshotValidity[a] = "pruned"
    /\ warm.snapshotSchema[a] = "compatible"
    /\ warm' = [warm EXCEPT !.snapshotSchema[a] = "incompatible"]
    /\ UNCHANGED <<backend, shutdown>>

\* fast-reboot:1219-1221 copies the snapshot after service shutdown.
SnapshotCopySuccess(a) ==
    /\ a \in Asics
    /\ warm.snapshotValidity[a] = "pruned"
    /\ shutdown.producerState[a] = "stopped"
    /\ warm.snapshotSchema[a] = "compatible"
    /\ warm' = [warm EXCEPT
          !.snapshotValidity[a] = "valid",
          !.snapshotEpoch[a] = warm.bootEpoch,
          !.copyComplete[a] = TRUE,
          !.snapshotQuiescent[a] = TRUE]
    /\ UNCHANGED <<backend, shutdown>>

\* fast-reboot:1163-1180 ignores post-commit errors and :1219-1221 can leave
\* an old/partial dump artifact at the expected path after copy failure.
SnapshotCopyFailureLeavesArtifact(a) ==
    /\ a \in Asics
    /\ warm.snapshotValidity[a] = "pruned"
    /\ warm' = [warm EXCEPT
          !.snapshotValidity[a] = "valid",
          !.snapshotEpoch[a] = warm.bootEpoch,
          !.copyComplete[a] = FALSE,
          !.snapshotQuiescent[a] =
              (shutdown.producerState[a] = "stopped")]
    /\ UNCHANGED <<backend, shutdown>>

\* fast-reboot:1163-1180 disables rollback before later stop/snapshot commands.
CommitNoRollback ==
    /\ shutdown.platformPhase = "precommit"
    /\ shutdown' = [shutdown EXCEPT
          !.platformPhase = "committed",
          !.rollbackEnabled = FALSE,
          !.stoppedAtCommit =
              {a \in Asics : shutdown.producerState[a] = "stopped"}]
    /\ UNCHANGED <<backend, warm>>

\* Delayed service timers can resurrect stopped units (brief S3; historical
\* issue #2750 generalizes the timer mechanism, not a regression action).
TimerResurrectProducer(a) ==
    /\ a \in Asics
    /\ shutdown.platformPhase = "committed"
    /\ shutdown.producerState[a] = "stopped"
    /\ shutdown' = [shutdown EXCEPT !.producerState[a] = "running"]
    /\ UNCHANGED <<backend, warm>>

\* fast-reboot:1163-1180 ignores failures after rollback is disabled.
PostCommitStopFailure ==
    /\ shutdown.platformPhase = "committed"
    /\ ~shutdown.postCommitFailure
    /\ shutdown' = [shutdown EXCEPT !.postCommitFailure = TRUE]
    /\ UNCHANGED <<backend, warm>>

\* Physical reboot is the normal terminal progress after fast-reboot:1187-1221.
PhysicalReboot ==
    /\ shutdown.platformPhase = "committed"
    /\ ~shutdown.postCommitFailure
    /\ shutdown' = [shutdown EXCEPT !.platformPhase = "rebooted"]
    /\ UNCHANGED <<backend, warm>>

\* A defined explicit recovery terminal is the required alternative for an
\* ignored post-commit failure; current fast-reboot:1163-1180 has no automatic
\* transition, so this action is deliberately enabled only by external repair.
EnterExplicitRecovery ==
    /\ shutdown.platformPhase = "committed"
    /\ shutdown.postCommitFailure
    /\ shutdown.rollbackEnabled
    /\ shutdown' = [shutdown EXCEPT !.platformPhase = "recovery"]
    /\ UNCHANGED <<backend, warm>>

\* Startup restore consumes per-namespace files independently
\* (docker_image_ctl.j2:107-114,296-314).
StartRestore ==
    /\ shutdown.platformPhase = "rebooted"
    /\ shutdown' = [shutdown EXCEPT !.platformPhase = "restoring"]
    /\ UNCHANGED <<backend, warm>>

\* docker_image_ctl.j2:107-114 consumes a present warm dump per namespace.
RestoreNamespaceWarm(a) ==
    /\ a \in Asics
    /\ shutdown.platformPhase = "restoring"
    /\ warm.restoreDecision[a] = "none"
    /\ ~warm.namespaceFailed[a]
    /\ warm.flagEpoch[a] = warm.bootEpoch
    /\ warm.snapshotValidity[a] = "valid"
    /\ warm' = [warm EXCEPT
          !.restoreDecision[a] = "warm",
          !.restoreEpoch[a] = warm.bootEpoch,
          !.consumedSnapshotEpoch[a] = warm.snapshotEpoch[a]]
    /\ UNCHANGED <<backend, shutdown>>

\* docker_image_ctl.j2:112-114 creates an empty DB when warm input is absent;
\* a failed namespace therefore enters cold recovery independently.
RestoreNamespaceCold(a) ==
    /\ a \in Asics
    /\ shutdown.platformPhase = "restoring"
    /\ warm.restoreDecision[a] = "none"
    /\ \/ warm.namespaceFailed[a]
       \/ warm.flagEpoch[a] /= warm.bootEpoch
       \/ warm.snapshotValidity[a] /= "valid"
    /\ warm' = [warm EXCEPT
          !.restoreDecision[a] = "cold",
          !.restoreEpoch[a] = warm.bootEpoch,
          !.consumedSnapshotEpoch[a] = NoEpoch]
    /\ UNCHANGED <<backend, shutdown>>

\* Completion of all independent namespace restores exposes the global mode.
\* Evidence: docker_image_ctl.j2:107-114,296-314 and finalizer:268-300.
CompleteRestore ==
    /\ shutdown.platformPhase = "restoring"
    /\ \A a \in Asics : warm.restoreDecision[a] /= "none"
    /\ shutdown' = [shutdown EXCEPT !.platformPhase = "running"]
    /\ UNCHANGED <<backend, warm>>

(***************************************************************************
 * Finalizer actions -- Scenario 2 (and per-namespace part of Scenario 4).
 *************************************************************************)

\* finalize-warmboot.sh:12-27 builds static and dynamic component registry.
RegisterWarmComponent(c) ==
    /\ c \in Components
    /\ warm.bootEpoch > NoEpoch
    /\ c \notin warm.required
    /\ warm' = [warm EXCEPT !.required = @ \cup {c}]
    /\ UNCHANGED <<backend, shutdown>>

\* finalize-warmboot.sh:139-155,237-254 observes "reconciled" for a component.
WarmComponentReconciled(c) ==
    /\ c \in Components
    /\ c \in warm.required
    /\ warm.readiness[c] = "unknown"
    /\ warm' = [warm EXCEPT
          !.readiness[c] = "ready",
          !.restoredEpoch[c] = warm.bootEpoch]
    /\ UNCHANGED <<backend, shutdown>>

\* A harness fault probe observes timeout/malformed data at the wait boundary
\* (finalize-warmboot.sh:255-287).  The implementation accepts readiness only
\* on exact "reconciled", so observing a timeout must not claim restoration.
FinalizerTimeoutAsReady(c) ==
    /\ c \in Components
    /\ c \in warm.required
    /\ warm.readiness[c] = "unknown"
    /\ warm' = [warm EXCEPT
          !.readiness[c] = "timeout"]
    /\ UNCHANGED <<backend, shutdown>>

\* finalize-warmboot.sh:246-258 exits the wait loop after its fixed deadline.
FinalizerDeadline ==
    /\ warm.bootEpoch > NoEpoch
    /\ ~warm.deadlineExpired
    /\ warm' = [warm EXCEPT !.deadlineExpired = TRUE]
    /\ UNCHANGED <<backend, shutdown>>

AllRequiredRestored ==
    \A c \in warm.required : warm.restoredEpoch[c] = warm.bootEpoch

\* finalize-warmboot.sh:268-290 finalizes each namespace even after its wait
\* function merely logged incomplete components at lines 256-258.
FinalizeNamespace(a) ==
    /\ a \in Asics
    /\ warm.bootEpoch > NoEpoch
    /\ warm.finalizedNsEpoch[a] /= warm.bootEpoch
    /\ (warm.deadlineExpired \/ AllRequiredRestored)
    /\ warm' = [warm EXCEPT
          !.finalizedNsEpoch[a] = warm.bootEpoch,
          !.flagEpoch[a] = NoEpoch]                 \* finalizer:165-190
    /\ UNCHANGED <<backend, shutdown>>

\* finalize-warmboot.sh:293-302 waits for child processes then unconditionally
\* finalizes global warm/fast state.
FinalizeGlobal ==
    /\ warm.bootEpoch > NoEpoch
    /\ \A a \in Asics : warm.finalizedNsEpoch[a] = warm.bootEpoch
    /\ warm.finalizedEpoch /= warm.bootEpoch
    /\ warm' = [warm EXCEPT !.finalizedEpoch = warm.bootEpoch]
    /\ UNCHANGED <<backend, shutdown>>

\* finalize-warmboot.sh:308-310 saves the DB after unconditional finalization.
SaveDatabase ==
    /\ warm.finalizedEpoch = warm.bootEpoch
    /\ warm.dbSavedEpoch /= warm.bootEpoch
    /\ warm' = [warm EXCEPT !.dbSavedEpoch = warm.bootEpoch]
    /\ UNCHANGED <<backend, shutdown>>

(***************************************************************************
 * Fault aliases separate injected choices from reactive implementation steps.
 * MC.tla overrides these aliases with counter-bounded wrappers.
 *************************************************************************)
AcceptRequest == HandleRebootRequestAccept
LaunchFailure == StartThreadLaunchFailure
LoseDbus == HostServiceTransportFailure
CrashBackend == BackendCrash
ExpirePlatformTimer == PlatformRebootDeadline
BeginWarmReboot == FastRebootBegin
InjectConfigUpdate(a) == QueueConfigurationUpdate(a)
FailNamespaceCommand(a) == NamespaceCommandFailure(a)
ChooseIncompatibleSchema(a) == SelectIncompatibleSnapshotSchema(a)
LeavePartialSnapshot(a) == SnapshotCopyFailureLeavesArtifact(a)
ResurrectProducer(a) == TimerResurrectProducer(a)
FailAfterCommit == PostCommitStopFailure
ExpireFinalizer == FinalizerDeadline
MisreadReadiness(c) == FinalizerTimeoutAsReady(c)

InjectedNext ==
    \/ AcceptRequest
    \/ LaunchFailure
    \/ LoseDbus
    \/ CrashBackend
    \/ ExpirePlatformTimer
    \/ BeginWarmReboot
    \/ \E a \in Asics : InjectConfigUpdate(a)
    \/ \E a \in Asics : FailNamespaceCommand(a)
    \/ \E a \in Asics : ChooseIncompatibleSchema(a)
    \/ \E a \in Asics : LeavePartialSnapshot(a)
    \/ \E a \in Asics : ResurrectProducer(a)
    \/ FailAfterCommit
    \/ ExpireFinalizer
    \/ \E c \in Components : MisreadReadiness(c)

ReactiveNext ==
    \/ HostServiceIssueRebootAccept
    \/ HostServiceIssueRebootReject
    \/ WaitForPlatformRebootStart
    \/ HandleRebootFinishJoinable
    \/ HandleRebootFinishNonJoinable
    \/ BackendRecover
    \/ HostComplete
    \/ \E a \in Asics : EnableWarmRestart(a)
    \/ \E a \in Asics : PreShutdownProducer(a)
    \/ \E a \in Asics : DeliverConfigurationUpdate(a)
    \/ \E a \in Asics : StopProducer(a)
    \/ \E a \in Asics : DrainConsumer(a)
    \/ \E a \in Asics : FreezeOrchagent(a)
    \/ \E a \in Asics : PruneNamespaceState(a)
    \/ \E a \in Asics : SnapshotCopySuccess(a)
    \/ CommitNoRollback
    \/ PhysicalReboot
    \/ EnterExplicitRecovery
    \/ StartRestore
    \/ \E a \in Asics : RestoreNamespaceWarm(a)
    \/ \E a \in Asics : RestoreNamespaceCold(a)
    \/ CompleteRestore
    \/ \E c \in Components : RegisterWarmComponent(c)
    \/ \E c \in Components : WarmComponentReconciled(c)
    \/ \E a \in Asics : FinalizeNamespace(a)
    \/ FinalizeGlobal
    \/ SaveDatabase

Next == InjectedNext \/ ReactiveNext

Spec == Init /\ [][Next]_vars

(***************************************************************************
 * Structural and core safety properties.
 *************************************************************************)
TypeOK ==
    /\ backend.alive \in BOOLEAN
    /\ backend.active \in BOOLEAN
    /\ backend.manager \in BackendManagers
    /\ backend.requestEpoch \in 0..MaxEpoch
    /\ backend.nextEpoch \in 1..(MaxEpoch + 1)
    /\ backend.dbusPhase \in DbusPhases
    /\ backend.localTimer \in BOOLEAN
    /\ backend.hostPending \in BOOLEAN
    /\ backend.hostEpoch \in 0..MaxEpoch
    /\ backend.hostStatus \in HostStatuses
    /\ backend.failureClass \in FailureClasses
    /\ backend.failureCause \in FailureCauses
    /\ backend.threadJoinable \in BOOLEAN
    /\ shutdown.platformPhase \in PlatformPhases
    /\ shutdown.rollbackEnabled \in BOOLEAN
    /\ shutdown.producerState \in [Asics -> ProducerStates]
    /\ shutdown.inFlight \in [Asics -> 0..MaxInFlight]
    /\ shutdown.consumerState \in [Asics -> ConsumerStates]
    /\ shutdown.stoppedAtCommit \subseteq Asics
    /\ shutdown.postCommitFailure \in BOOLEAN
    /\ warm.bootEpoch \in 0..MaxEpoch
    /\ warm.flagEpoch \in [Asics -> 0..MaxEpoch]
    /\ warm.snapshotEpoch \in [Asics -> 0..MaxEpoch]
    /\ warm.snapshotValidity \in [Asics -> SnapshotStates]
    /\ warm.snapshotSchema \in [Asics -> SnapshotSchemas]
    /\ warm.copyComplete \in [Asics -> BOOLEAN]
    /\ warm.snapshotQuiescent \in [Asics -> BOOLEAN]
    /\ warm.namespaceFailed \in [Asics -> BOOLEAN]
    /\ warm.restoreDecision \in [Asics -> RestoreDecisions]
    /\ warm.restoreEpoch \in [Asics -> 0..MaxEpoch]
    /\ warm.consumedSnapshotEpoch \in [Asics -> 0..MaxEpoch]
    /\ warm.restoredEpoch \in [Components -> 0..MaxEpoch]
    /\ warm.required \subseteq Components
    /\ warm.readiness \in [Components -> ReadinessStates]
    /\ warm.deadlineExpired \in BOOLEAN
    /\ warm.finalizedNsEpoch \in [Asics -> 0..MaxEpoch]
    /\ warm.finalizedEpoch \in 0..MaxEpoch
    /\ warm.dbSavedEpoch \in 0..MaxEpoch

CoreManagerSafety == backend.manager = "in_progress" => backend.active

PendingEpochs ==
    (IF backend.active /\ backend.requestEpoch > NoEpoch
     THEN {backend.requestEpoch} ELSE {})
    \cup
    (IF backend.hostPending /\ backend.hostEpoch > NoEpoch
     THEN {backend.hostEpoch} ELSE {})

(***************************************************************************
 * Scenario invariants -- the primary bug-detection properties.
 *************************************************************************)

\* Scenario 1: one logical epoch may appear in both owners; two epochs may not.
SinglePendingReboot == Cardinality(PendingEpochs) <= 1

\* Scenario 1: recovered IDLE is unsafe while an uncorrelated host worker owns
\* an accepted reboot.
OwnershipRecovery ==
    ~(/\ backend.alive
      /\ backend.manager = "idle"
      /\ backend.hostPending
      /\ ~backend.active)

\* Scenarios 2/4: state actually consumed or claimed together is epoch-scoped.
EpochConsistency ==
    /\ \A a \in Asics :
          /\ warm.flagEpoch[a] \in {NoEpoch, warm.bootEpoch}
          /\ warm.restoreEpoch[a] \in {NoEpoch, warm.bootEpoch}
          /\ warm.finalizedNsEpoch[a] \in {NoEpoch, warm.bootEpoch}
          /\ warm.restoreDecision[a] = "warm" =>
                warm.consumedSnapshotEpoch[a] = warm.bootEpoch
    /\ \A c \in Components :
          warm.restoredEpoch[c] \in {NoEpoch, warm.bootEpoch}
    /\ warm.finalizedEpoch \in {NoEpoch, warm.bootEpoch}
    /\ warm.dbSavedEpoch \in {NoEpoch, warm.bootEpoch}

\* Scenario 2: timeout cannot authorize a success claim while required input
\* or a causally prior update remains incomplete.
NoPrematureFinalization ==
    warm.finalizedEpoch = NoEpoch \/
      /\ AllRequiredRestored
      /\ \A a \in Asics : shutdown.inFlight[a] = 0

\* Scenario 3: pausing orchagent precedes service stop in fast-reboot
\* (lines 1159-1185 versus 1235-1246), so producer liveness alone is not an
\* error.  The implementation-backed safety obligation is that all causally
\* prior updates have become visible before the consumer freezes.
CausalFreeze ==
    \A a \in Asics :
      shutdown.consumerState[a] \in {"frozen", "stopped"} =>
        shutdown.inFlight[a] = 0

\* Scenario 3 safety half: once commit records a stopped producer, it cannot
\* be resurrected.  ShutdownTermination below supplies the temporal half.
ShutdownMonotonicity ==
    \A a \in shutdown.stoppedAtCommit :
      shutdown.producerState[a] /= "running"

\* Scenario 4: validity is evidence of complete, compatible, quiescent copy.
SnapshotSafety ==
    \A a \in Asics : warm.snapshotValidity[a] = "valid" =>
      /\ warm.copyComplete[a]
      /\ warm.snapshotQuiescent[a]
      /\ warm.snapshotSchema[a] = "compatible"
      /\ warm.snapshotEpoch[a] = warm.bootEpoch

\* Scenario 4: evaluate coherence only when all independent restore steps have
\* exposed the global running decision, avoiding transient false positives.
CrossNamespaceCoherence ==
    shutdown.platformPhase = "running" =>
      Cardinality({warm.restoreDecision[a] : a \in Asics}) = 1

\* Scenario 2 / open PR #26911.
TimeoutIsNotReadiness ==
    \A c \in Components :
      warm.readiness[c] \in {"timeout", "malformed"} =>
        warm.restoredEpoch[c] /= warm.bootEpoch

\* Scenario 5 refinement: transport loss is retriable; explicit host rejection
\* is definitive; launch failure is retriable.  The current collapsed C++ path
\* violates the first implication.
FailureClassification ==
    /\ backend.failureCause = "transport" =>
          backend.failureClass = "retriable"
    /\ backend.failureCause = "host_reject" =>
          backend.failureClass = "definitive"
    /\ backend.failureCause = "thread_launch" =>
          backend.failureClass = "retriable"

(***************************************************************************
 * Temporal properties from brief §5.  MC.tla supplies fairness around the
 * relevant reactive completion actions for hunting configs.
 *************************************************************************)
RetryLiveness ==
    [](backend.failureClass = "retriable" =>
       <>(~backend.active /\ backend.manager = "idle"))

ShutdownTermination ==
    [](shutdown.platformPhase = "committed" =>
       <>(shutdown.platformPhase \in {"rebooted", "recovery"}))

=============================================================================
