------------------------------ MODULE Trace ------------------------------
(***************************************************************************
 * Category A linear trace replay.  Raw component events are merged by their
 * monotonic sequence/timestamp and enriched by the harness shadow-state
 * reducer described in instrumentation-spec.md.  Every wrapper calls the
 * corresponding full base action and strongly validates every record that the
 * action modifies; there is no unconstrained silent action.
 *************************************************************************)
EXTENDS base, Json, IOUtils, Sequences, TLC

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

VARIABLE l

traceVars == <<l>>
allTraceVars == <<vars, l>>
logline == TraceLog[l]

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name
    /\ "state" \in DOMAIN logline.event

EventAsic(a) ==
    /\ "asic" \in DOMAIN logline.event
    /\ logline.event.asic = a

EventComponent(c) ==
    /\ "component" \in DOMAIN logline.event
    /\ logline.event.component = c

\* Mandatory strong post-state checks.  The schema requires every wrapper to
\* emit the complete modified abstract record; no missing-field/vacuous branch
\* is permitted.
ValidateBackendPost ==
    /\ "backend" \in DOMAIN logline.event.state
    /\ backend' = logline.event.state.backend

TupleToSet(tuple) == {tuple[i] : i \in 1..Len(tuple)}

ValidateShutdownPost ==
    /\ "shutdown" \in DOMAIN logline.event.state
    /\ shutdown' = [logline.event.state.shutdown EXCEPT
          !.stoppedAtCommit = TupleToSet(@)]

ValidateWarmPost ==
    /\ "warm" \in DOMAIN logline.event.state
    /\ warm' = [logline.event.state.warm EXCEPT
          !.required = TupleToSet(@)]

StepTrace == l' = l + 1

(***************************************************************************
 * Backend / host wrappers (Scenarios 1 and 5).
 *************************************************************************)
HandleRebootRequestAcceptIfLogged ==
    /\ IsEvent("HandleRebootRequestAccept")
    /\ HandleRebootRequestAccept
    /\ ValidateBackendPost
    /\ StepTrace

StartThreadLaunchFailureIfLogged ==
    /\ IsEvent("StartThreadLaunchFailure")
    /\ StartThreadLaunchFailure
    /\ ValidateBackendPost
    /\ StepTrace

HostServiceIssueRebootAcceptIfLogged ==
    /\ IsEvent("HostServiceIssueRebootAccept")
    /\ HostServiceIssueRebootAccept
    /\ ValidateBackendPost
    /\ StepTrace

HostServiceIssueRebootRejectIfLogged ==
    /\ IsEvent("HostServiceIssueRebootReject")
    /\ HostServiceIssueRebootReject
    /\ ValidateBackendPost
    /\ StepTrace

HostServiceTransportFailureIfLogged ==
    /\ IsEvent("HostServiceTransportFailure")
    /\ HostServiceTransportFailure
    /\ ValidateBackendPost
    /\ StepTrace

WaitForPlatformRebootStartIfLogged ==
    /\ IsEvent("WaitForPlatformRebootStart")
    /\ WaitForPlatformRebootStart
    /\ ValidateBackendPost
    /\ StepTrace

PlatformRebootDeadlineIfLogged ==
    /\ IsEvent("PlatformRebootDeadline")
    /\ PlatformRebootDeadline
    /\ ValidateBackendPost
    /\ StepTrace

HandleRebootFinishJoinableIfLogged ==
    /\ IsEvent("HandleRebootFinishJoinable")
    /\ HandleRebootFinishJoinable
    /\ ValidateBackendPost
    /\ StepTrace

HandleRebootFinishNonJoinableIfLogged ==
    /\ IsEvent("HandleRebootFinishNonJoinable")
    /\ HandleRebootFinishNonJoinable
    /\ ValidateBackendPost
    /\ StepTrace

BackendCrashIfLogged ==
    /\ IsEvent("BackendCrash")
    /\ BackendCrash
    /\ ValidateBackendPost
    /\ StepTrace

BackendRecoverIfLogged ==
    /\ IsEvent("BackendRecover")
    /\ BackendRecover
    /\ ValidateBackendPost
    /\ StepTrace

HostCompleteIfLogged ==
    /\ IsEvent("HostComplete")
    /\ HostComplete
    /\ ValidateBackendPost
    /\ StepTrace

(***************************************************************************
 * Shutdown / snapshot / restore wrappers (Scenarios 2-4).
 *************************************************************************)
FastRebootBeginIfLogged ==
    /\ IsEvent("FastRebootBegin")
    /\ FastRebootBegin
    /\ ValidateShutdownPost
    /\ ValidateWarmPost
    /\ StepTrace

EnableWarmRestartIfLogged ==
    \E a \in Asics :
      /\ IsEvent("EnableWarmRestart")
      /\ EventAsic(a)
      /\ EnableWarmRestart(a)
      /\ ValidateWarmPost
      /\ StepTrace

NamespaceCommandFailureIfLogged ==
    \E a \in Asics :
      /\ IsEvent("NamespaceCommandFailure")
      /\ EventAsic(a)
      /\ NamespaceCommandFailure(a)
      /\ ValidateWarmPost
      /\ StepTrace

PreShutdownProducerIfLogged ==
    \E a \in Asics :
      /\ IsEvent("PreShutdownProducer")
      /\ EventAsic(a)
      /\ PreShutdownProducer(a)
      /\ ValidateShutdownPost
      /\ StepTrace

QueueConfigurationUpdateIfLogged ==
    \E a \in Asics :
      /\ IsEvent("QueueConfigurationUpdate")
      /\ EventAsic(a)
      /\ QueueConfigurationUpdate(a)
      /\ ValidateShutdownPost
      /\ StepTrace

DeliverConfigurationUpdateIfLogged ==
    \E a \in Asics :
      /\ IsEvent("DeliverConfigurationUpdate")
      /\ EventAsic(a)
      /\ DeliverConfigurationUpdate(a)
      /\ ValidateShutdownPost
      /\ StepTrace

StopProducerIfLogged ==
    \E a \in Asics :
      /\ IsEvent("StopProducer")
      /\ EventAsic(a)
      /\ StopProducer(a)
      /\ ValidateShutdownPost
      /\ StepTrace

DrainConsumerIfLogged ==
    \E a \in Asics :
      /\ IsEvent("DrainConsumer")
      /\ EventAsic(a)
      /\ DrainConsumer(a)
      /\ ValidateShutdownPost
      /\ StepTrace

FreezeOrchagentIfLogged ==
    \E a \in Asics :
      /\ IsEvent("FreezeOrchagent")
      /\ EventAsic(a)
      /\ FreezeOrchagent(a)
      /\ ValidateShutdownPost
      /\ StepTrace

PruneNamespaceStateIfLogged ==
    \E a \in Asics :
      /\ IsEvent("PruneNamespaceState")
      /\ EventAsic(a)
      /\ PruneNamespaceState(a)
      /\ ValidateWarmPost
      /\ StepTrace

SelectIncompatibleSnapshotSchemaIfLogged ==
    \E a \in Asics :
      /\ IsEvent("SelectIncompatibleSnapshotSchema")
      /\ EventAsic(a)
      /\ SelectIncompatibleSnapshotSchema(a)
      /\ ValidateWarmPost
      /\ StepTrace

SnapshotCopySuccessIfLogged ==
    \E a \in Asics :
      /\ IsEvent("SnapshotCopySuccess")
      /\ EventAsic(a)
      /\ SnapshotCopySuccess(a)
      /\ ValidateWarmPost
      /\ StepTrace

SnapshotCopyFailureLeavesArtifactIfLogged ==
    \E a \in Asics :
      /\ IsEvent("SnapshotCopyFailureLeavesArtifact")
      /\ EventAsic(a)
      /\ SnapshotCopyFailureLeavesArtifact(a)
      /\ ValidateWarmPost
      /\ StepTrace

CommitNoRollbackIfLogged ==
    /\ IsEvent("CommitNoRollback")
    /\ CommitNoRollback
    /\ ValidateShutdownPost
    /\ StepTrace

TimerResurrectProducerIfLogged ==
    \E a \in Asics :
      /\ IsEvent("TimerResurrectProducer")
      /\ EventAsic(a)
      /\ TimerResurrectProducer(a)
      /\ ValidateShutdownPost
      /\ StepTrace

PostCommitStopFailureIfLogged ==
    /\ IsEvent("PostCommitStopFailure")
    /\ PostCommitStopFailure
    /\ ValidateShutdownPost
    /\ StepTrace

PhysicalRebootIfLogged ==
    /\ IsEvent("PhysicalReboot")
    /\ PhysicalReboot
    /\ ValidateShutdownPost
    /\ StepTrace

EnterExplicitRecoveryIfLogged ==
    /\ IsEvent("EnterExplicitRecovery")
    /\ EnterExplicitRecovery
    /\ ValidateShutdownPost
    /\ StepTrace

StartRestoreIfLogged ==
    /\ IsEvent("StartRestore")
    /\ StartRestore
    /\ ValidateShutdownPost
    /\ StepTrace

RestoreNamespaceWarmIfLogged ==
    \E a \in Asics :
      /\ IsEvent("RestoreNamespaceWarm")
      /\ EventAsic(a)
      /\ RestoreNamespaceWarm(a)
      /\ ValidateWarmPost
      /\ StepTrace

RestoreNamespaceColdIfLogged ==
    \E a \in Asics :
      /\ IsEvent("RestoreNamespaceCold")
      /\ EventAsic(a)
      /\ RestoreNamespaceCold(a)
      /\ ValidateWarmPost
      /\ StepTrace

CompleteRestoreIfLogged ==
    /\ IsEvent("CompleteRestore")
    /\ CompleteRestore
    /\ ValidateShutdownPost
    /\ StepTrace

(***************************************************************************
 * Finalizer wrappers (Scenario 2).
 *************************************************************************)
RegisterWarmComponentIfLogged ==
    \E c \in Components :
      /\ IsEvent("RegisterWarmComponent")
      /\ EventComponent(c)
      /\ RegisterWarmComponent(c)
      /\ ValidateWarmPost
      /\ StepTrace

WarmComponentReconciledIfLogged ==
    \E c \in Components :
      /\ IsEvent("WarmComponentReconciled")
      /\ EventComponent(c)
      /\ WarmComponentReconciled(c)
      /\ ValidateWarmPost
      /\ StepTrace

FinalizerTimeoutAsReadyIfLogged ==
    \E c \in Components :
      /\ IsEvent("FinalizerTimeoutAsReady")
      /\ EventComponent(c)
      /\ FinalizerTimeoutAsReady(c)
      /\ ValidateWarmPost
      /\ StepTrace

FinalizerDeadlineIfLogged ==
    /\ IsEvent("FinalizerDeadline")
    /\ FinalizerDeadline
    /\ ValidateWarmPost
    /\ StepTrace

FinalizeNamespaceIfLogged ==
    \E a \in Asics :
      /\ IsEvent("FinalizeNamespace")
      /\ EventAsic(a)
      /\ FinalizeNamespace(a)
      /\ ValidateWarmPost
      /\ StepTrace

FinalizeGlobalIfLogged ==
    /\ IsEvent("FinalizeGlobal")
    /\ FinalizeGlobal
    /\ ValidateWarmPost
    /\ StepTrace

SaveDatabaseIfLogged ==
    /\ IsEvent("SaveDatabase")
    /\ SaveDatabase
    /\ ValidateWarmPost
    /\ StepTrace

MatchLoggedAction ==
    \/ HandleRebootRequestAcceptIfLogged
    \/ StartThreadLaunchFailureIfLogged
    \/ HostServiceIssueRebootAcceptIfLogged
    \/ HostServiceIssueRebootRejectIfLogged
    \/ HostServiceTransportFailureIfLogged
    \/ WaitForPlatformRebootStartIfLogged
    \/ PlatformRebootDeadlineIfLogged
    \/ HandleRebootFinishJoinableIfLogged
    \/ HandleRebootFinishNonJoinableIfLogged
    \/ BackendCrashIfLogged
    \/ BackendRecoverIfLogged
    \/ HostCompleteIfLogged
    \/ FastRebootBeginIfLogged
    \/ EnableWarmRestartIfLogged
    \/ NamespaceCommandFailureIfLogged
    \/ PreShutdownProducerIfLogged
    \/ QueueConfigurationUpdateIfLogged
    \/ DeliverConfigurationUpdateIfLogged
    \/ StopProducerIfLogged
    \/ DrainConsumerIfLogged
    \/ FreezeOrchagentIfLogged
    \/ PruneNamespaceStateIfLogged
    \/ SelectIncompatibleSnapshotSchemaIfLogged
    \/ SnapshotCopySuccessIfLogged
    \/ SnapshotCopyFailureLeavesArtifactIfLogged
    \/ CommitNoRollbackIfLogged
    \/ TimerResurrectProducerIfLogged
    \/ PostCommitStopFailureIfLogged
    \/ PhysicalRebootIfLogged
    \/ EnterExplicitRecoveryIfLogged
    \/ StartRestoreIfLogged
    \/ RestoreNamespaceWarmIfLogged
    \/ RestoreNamespaceColdIfLogged
    \/ CompleteRestoreIfLogged
    \/ RegisterWarmComponentIfLogged
    \/ WarmComponentReconciledIfLogged
    \/ FinalizerTimeoutAsReadyIfLogged
    \/ FinalizerDeadlineIfLogged
    \/ FinalizeNamespaceIfLogged
    \/ FinalizeGlobalIfLogged
    \/ SaveDatabaseIfLogged

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ MatchLoggedAction
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED allTraceVars

\* Weak fairness removes the otherwise legal infinite stutter at a valid next
\* event.  If the event/action/post-state does not match, MatchLoggedAction is
\* disabled and TraceMatched still reports the mismatch.
TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_allTraceVars
    /\ WF_allTraceVars(MatchLoggedAction)

TraceMatched == <>(l > Len(TraceLog))

=============================================================================
