------------------------------- MODULE MC -------------------------------
(***************************************************************************
 * Counter-bounded exhaustive model for SONiC warm reboot.  Only injected
 * choices are bounded; deterministic/reactive completion remains unbounded.
 *************************************************************************)
EXTENDS base

baseSpec == INSTANCE base

CONSTANTS
    AcceptLimit, LaunchFailureLimit, DbusLossLimit, BackendCrashLimit,
    PlatformDeadlineLimit, WarmBeginLimit, ConfigUpdateLimit,
    NamespaceFailureLimit, SchemaMismatchLimit, SnapshotFailureLimit,
    ResurrectLimit, PostCommitFailureLimit, FinalizerDeadlineLimit,
    ReadinessFaultLimit

VARIABLE faultCounts

faultVars == <<faultCounts>>
mcVars == <<vars, faultCounts>>

MCInit ==
    /\ Init
    /\ faultCounts =
        [accept          |-> 0,
         launchFailure   |-> 0,
         dbusLoss        |-> 0,
         backendCrash    |-> 0,
         platformDeadline|-> 0,
         warmBegin       |-> 0,
         configUpdate    |-> 0,
         namespaceFailure|-> 0,
         schemaMismatch  |-> 0,
         snapshotFailure |-> 0,
         resurrect       |-> 0,
         postCommitFailure |-> 0,
         finalizerDeadline |-> 0,
         readinessFault  |-> 0]

(***************************************************************************
 * Counter-bounded injected choices.  Config operator overrides connect each
 * base alias to the corresponding wrapper below.
 *************************************************************************)
MCAcceptRequest ==
    /\ faultCounts.accept < AcceptLimit
    /\ baseSpec!AcceptRequest
    /\ faultCounts' = [faultCounts EXCEPT !.accept = @ + 1]

MCLaunchFailure ==
    /\ faultCounts.launchFailure < LaunchFailureLimit
    /\ baseSpec!LaunchFailure
    /\ faultCounts' = [faultCounts EXCEPT !.launchFailure = @ + 1]

MCLoseDbus ==
    /\ faultCounts.dbusLoss < DbusLossLimit
    /\ baseSpec!LoseDbus
    /\ faultCounts' = [faultCounts EXCEPT !.dbusLoss = @ + 1]

MCCrashBackend ==
    /\ faultCounts.backendCrash < BackendCrashLimit
    /\ baseSpec!CrashBackend
    /\ faultCounts' = [faultCounts EXCEPT !.backendCrash = @ + 1]

MCExpirePlatformTimer ==
    /\ faultCounts.platformDeadline < PlatformDeadlineLimit
    /\ baseSpec!ExpirePlatformTimer
    /\ faultCounts' = [faultCounts EXCEPT !.platformDeadline = @ + 1]

MCBeginWarmReboot ==
    /\ faultCounts.warmBegin < WarmBeginLimit
    /\ baseSpec!BeginWarmReboot
    /\ faultCounts' = [faultCounts EXCEPT !.warmBegin = @ + 1]

MCInjectConfigUpdate(a) ==
    /\ faultCounts.configUpdate < ConfigUpdateLimit
    /\ baseSpec!InjectConfigUpdate(a)
    /\ faultCounts' = [faultCounts EXCEPT !.configUpdate = @ + 1]

MCFailNamespaceCommand(a) ==
    /\ faultCounts.namespaceFailure < NamespaceFailureLimit
    /\ baseSpec!FailNamespaceCommand(a)
    /\ faultCounts' = [faultCounts EXCEPT !.namespaceFailure = @ + 1]

MCChooseIncompatibleSchema(a) ==
    /\ faultCounts.schemaMismatch < SchemaMismatchLimit
    /\ baseSpec!ChooseIncompatibleSchema(a)
    /\ faultCounts' = [faultCounts EXCEPT !.schemaMismatch = @ + 1]

MCLeavePartialSnapshot(a) ==
    /\ faultCounts.snapshotFailure < SnapshotFailureLimit
    /\ baseSpec!LeavePartialSnapshot(a)
    /\ faultCounts' = [faultCounts EXCEPT !.snapshotFailure = @ + 1]

MCResurrectProducer(a) ==
    /\ faultCounts.resurrect < ResurrectLimit
    /\ baseSpec!ResurrectProducer(a)
    /\ faultCounts' = [faultCounts EXCEPT !.resurrect = @ + 1]

MCFailAfterCommit ==
    /\ faultCounts.postCommitFailure < PostCommitFailureLimit
    /\ baseSpec!FailAfterCommit
    /\ faultCounts' = [faultCounts EXCEPT !.postCommitFailure = @ + 1]

MCExpireFinalizer ==
    /\ faultCounts.finalizerDeadline < FinalizerDeadlineLimit
    /\ baseSpec!ExpireFinalizer
    /\ faultCounts' = [faultCounts EXCEPT !.finalizerDeadline = @ + 1]

MCMisreadReadiness(c) ==
    /\ faultCounts.readinessFault < ReadinessFaultLimit
    /\ baseSpec!MisreadReadiness(c)
    /\ faultCounts' = [faultCounts EXCEPT !.readinessFault = @ + 1]

\* Operator substitutions make InjectedNext use the wrappers above.  Reactive
\* actions do not consume counters and therefore remain fully enabled.
MCNext ==
    \/ /\ ReactiveNext
       /\ UNCHANGED faultVars
    \/ InjectedNext

MCSpec == MCInit /\ [][MCNext]_mcVars

\* Fair completion used only by liveness hunting configs.  A join attempt is
\* forced when enabled, as is a normal terminal transition after commit.
MCFinishProgress ==
    /\ (baseSpec!HandleRebootFinishJoinable \/
        baseSpec!HandleRebootFinishNonJoinable)
    /\ UNCHANGED faultVars

MCTerminalProgress ==
    /\ (baseSpec!PhysicalReboot \/ baseSpec!EnterExplicitRecovery)
    /\ UNCHANGED faultVars

MCFairSpec ==
    /\ MCInit
    /\ [][MCNext]_mcVars
    /\ WF_mcVars(MCFinishProgress)
    /\ WF_mcVars(MCTerminalProgress)

Symmetry == Permutations(Asics)
MCView == vars

MCTypeOK ==
    /\ TypeOK
    /\ faultCounts.accept \in 0..AcceptLimit
    /\ faultCounts.launchFailure \in 0..LaunchFailureLimit
    /\ faultCounts.dbusLoss \in 0..DbusLossLimit
    /\ faultCounts.backendCrash \in 0..BackendCrashLimit
    /\ faultCounts.platformDeadline \in 0..PlatformDeadlineLimit
    /\ faultCounts.warmBegin \in 0..WarmBeginLimit
    /\ faultCounts.configUpdate \in 0..ConfigUpdateLimit
    /\ faultCounts.namespaceFailure \in 0..NamespaceFailureLimit
    /\ faultCounts.schemaMismatch \in 0..SchemaMismatchLimit
    /\ faultCounts.snapshotFailure \in 0..SnapshotFailureLimit
    /\ faultCounts.resurrect \in 0..ResurrectLimit
    /\ faultCounts.postCommitFailure \in 0..PostCommitFailureLimit
    /\ faultCounts.finalizerDeadline \in 0..FinalizerDeadlineLimit
    /\ faultCounts.readinessFault \in 0..ReadinessFaultLimit

CounterShape ==
    DOMAIN faultCounts =
      {"accept", "launchFailure", "dbusLoss", "backendCrash",
       "platformDeadline", "warmBegin", "configUpdate",
       "namespaceFailure", "schemaMismatch", "snapshotFailure",
       "resurrect", "postCommitFailure", "finalizerDeadline",
       "readinessFault"}

=============================================================================
