------------------------------- MODULE MC -------------------------------
EXTENDS base
Base == INSTANCE base

CONSTANTS AdminAbortLimit, AdmissionErrorLimit, ArchiveErrorLimit, CancelTimeoutLimit, CheckTimeoutLimit, ChildErrorLimit, DeployErrorLimit, DeployTimeoutLimit, HeartbeatLimit, LossLimit, OutcomeTimeoutLimit, PreLaunchErrorLimit, ReportErrorLimit, SpawnErrorLimit, StartTimeoutLimit, StoreErrorLimit, WaiterErrorLimit, MaxMessageBuffer
VARIABLE faults
mcvars == <<vars,faults>>

Limits == [adminAbort |-> AdminAbortLimit, admissionError |-> AdmissionErrorLimit, archiveError |-> ArchiveErrorLimit, cancelTimeout |-> CancelTimeoutLimit, checkTimeout |-> CheckTimeoutLimit, childError |-> ChildErrorLimit, deployError |-> DeployErrorLimit, deployTimeout |-> DeployTimeoutLimit, heartbeat |-> HeartbeatLimit, loss |-> LossLimit, outcomeTimeout |-> OutcomeTimeoutLimit, preLaunchError |-> PreLaunchErrorLimit, reportError |-> ReportErrorLimit, spawnError |-> SpawnErrorLimit, startTimeout |-> StartTimeoutLimit, storeError |-> StoreErrorLimit, waiterError |-> WaiterErrorLimit]
MCInit == Base!Init /\ faults = [k \in DOMAIN Limits |-> 0]

\* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339; Scenario 1,4,5.
MCAdminCheckTimeout(t) ==
    /\ faults.checkTimeout < Limits.checkTimeout
    /\ Base!AdminCheckTimeout(t)
    /\ faults' = [faults EXCEPT !.checkTimeout = @+1]

\* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339; Scenario 1,4,5.
MCAdminDeployTimeout(t) ==
    /\ faults.deployTimeout < Limits.deployTimeout
    /\ Base!AdminDeployTimeout(t)
    /\ faults' = [faults EXCEPT !.deployTimeout = @+1]

\* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339; Scenario 1,4,5.
MCAdminStartTimeout(t) ==
    /\ faults.startTimeout < Limits.startTimeout
    /\ Base!AdminStartTimeout(t)
    /\ faults' = [faults EXCEPT !.startTimeout = @+1]

\* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339; Scenario 1,4,5.
MCAdminCancelTimeout(t) ==
    /\ faults.cancelTimeout < Limits.cancelTimeout
    /\ Base!AdminCancelTimeout(t)
    /\ faults' = [faults EXCEPT !.cancelTimeout = @+1]

\* nvflare/app_common/job_schedulers/job_scheduler.py:292-310; nvflare/app_common/job_schedulers/job_scheduler.py:364-369; Scenario 5.
MCDefaultJobSchedulerAdmissionException ==
    /\ faults.admissionError < Limits.admissionError
    /\ Base!DefaultJobSchedulerAdmissionException
    /\ faults' = [faults EXCEPT !.admissionError = @+1]

\* nvflare/private/fed/server/job_runner.py:194-209; nvflare/private/fed/server/job_runner.py:224-226; nvflare/private/fed/server/job_runner.py:713-728; Scenario 2,5.
MCJobRunnerDeploymentException ==
    /\ faults.deployError < Limits.deployError
    /\ Base!JobRunnerDeploymentException
    /\ faults' = [faults EXCEPT !.deployError = @+1]

\* nvflare/private/fed/client/training_cmds.py:99-140; nvflare/private/fed/client/client_engine.py:462-480; nvflare/private/fed/server/job_runner.py:250-267; Scenario 2.
MCClientDeployError(s,t) ==
    /\ faults.deployError < Limits.deployError
    /\ Base!ClientDeployError(s,t)
    /\ faults' = [faults EXCEPT !.deployError = @+1]

\* nvflare/private/fed/server/job_runner.py:670-689; nvflare/private/fed/server/job_runner.py:711-713; Scenario 2,3,5.
MCJobRunnerStartupStoreError ==
    /\ faults.storeError < Limits.storeError
    /\ Base!JobRunnerStartupStoreError
    /\ faults' = [faults EXCEPT !.storeError = @+1]

\* nvflare/private/fed/server/server_engine.py:179-193; nvflare/private/fed/server/job_runner.py:304-306; Scenario 2.
MCServerEngineStartupError ==
    /\ faults.preLaunchError < Limits.preLaunchError
    /\ Base!ServerEngineStartupError
    /\ faults' = [faults EXCEPT !.preLaunchError = @+1]

\* nvflare/private/fed/client/scheduler_cmds.py:119-133; nvflare/private/fed/client/client_executor.py:224-258; Scenario 2.
MCJobExecutorPrepareException(s,t) ==
    /\ faults.preLaunchError < Limits.preLaunchError
    /\ Base!JobExecutorPrepareException(s,t)
    /\ faults' = [faults EXCEPT !.preLaunchError = @+1]

\* nvflare/app_common/job_launcher/process_launcher.py:68-83; nvflare/private/fed/client/client_executor.py:308-316; Scenario 2.
MCProcessJobLauncherSpawnException(s,t) ==
    /\ faults.spawnError < Limits.spawnError
    /\ Base!ProcessJobLauncherSpawnException(s,t)
    /\ faults' = [faults EXCEPT !.spawnError = @+1]

\* nvflare/private/fed/client/client_executor.py:330-334; nvflare/private/fed/client/scheduler_cmds.py:129-133; Scenario 2.
MCJobExecutorWaiterInstallationException(s,t) ==
    /\ faults.waiterError < Limits.waiterError
    /\ Base!JobExecutorWaiterInstallationException(s,t)
    /\ faults' = [faults EXCEPT !.waiterError = @+1]

\* nvflare/private/fed/client/client_executor.py:630-647; Scenario 2,4.
MCClientChildFailure(s,t) ==
    /\ faults.childError < Limits.childError
    /\ Base!ClientChildFailure(s,t)
    /\ faults' = [faults EXCEPT !.childError = @+1]

\* nvflare/private/fed/client/client_executor.py:648-678; Scenario 4.
MCJobExecutorOutcomeReportException(s,t) ==
    /\ faults.reportError < Limits.reportError
    /\ Base!JobExecutorOutcomeReportException(s,t)
    /\ faults' = [faults EXCEPT !.reportError = @+1]

\* nvflare/private/fed/server/fed_server.py:1004-1017; nvflare/private/fed/client/communicator.py:621-646; Scenario 2,4.
MCFederatedServerHeartbeatCleanup(s,t) ==
    /\ faults.heartbeat < Limits.heartbeat
    /\ Base!FederatedServerHeartbeatCleanup(s,t)
    /\ faults' = [faults EXCEPT !.heartbeat = @+1]

\* nvflare/private/fed/server/server_engine.py:219-233; Scenario 4.
MCServerChildFailure(j) ==
    /\ faults.childError < Limits.childError
    /\ Base!ServerChildFailure(j)
    /\ faults' = [faults EXCEPT !.childError = @+1]

\* nvflare/private/fed/server/job_cmds.py:1055-1061; Scenario 3,4.
MCJobCommandAbortRead(j) ==
    /\ faults.adminAbort < Limits.adminAbort
    /\ Base!JobCommandAbortRead(j)
    /\ faults' = [faults EXCEPT !.adminAbort = @+1]

\* nvflare/private/fed/server/job_runner.py:466-480; Scenario 3,4.
MCJobRunnerOutcomeGraceExpired(j) ==
    /\ faults.outcomeTimeout < Limits.outcomeTimeout
    /\ Base!JobRunnerOutcomeGraceExpired(j)
    /\ faults' = [faults EXCEPT !.outcomeTimeout = @+1]

\* nvflare/private/fed/server/job_runner.py:495-507; Scenario 3,4.
MCJobRunnerArchiveException(j) ==
    /\ faults.archiveError < Limits.archiveError
    /\ Base!JobRunnerArchiveException(j)
    /\ faults' = [faults EXCEPT !.archiveError = @+1]

\* nvflare/private/fed/server/job_runner.py:523-530; Scenario 4,5.
MCJobRunnerTerminalStoreException(j) ==
    /\ faults.storeError < Limits.storeError
    /\ Base!JobRunnerTerminalStoreException(j)
    /\ faults' = [faults EXCEPT !.storeError = @+1]

\* nvflare/private/fed/server/admin.py:307-339; nvflare/private/fed/server/server_engine.py:1007-1008; nvflare/private/fed/client/client_executor.py:657-674; Scenario 1,4,5.
MCTransportLoseMessage(m) ==
    /\ faults.loss < Limits.loss
    /\ Base!TransportLoseMessage(m)
    /\ faults' = [faults EXCEPT !.loss = @+1]

NormalNext ==
    \/ Base!DefaultJobSchedulerBeginPass
    \/ Base!DefaultJobSchedulerEndPass
    \/ Base!DefaultJobSchedulerSkipBackoff
    \/ \E j \in Jobs : Base!DefaultJobSchedulerBackoffElapsed(j)
    \/ Base!DefaultJobSchedulerExhausted
    \/ Base!DefaultJobSchedulerTryJob
    \/ Base!ServerEngineCheckClientResources
    \/ \E s \in Sites, t \in Tokens : Base!CheckResourceProcessorReserve(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!CheckResourceProcessorUnavailable(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ServerEngineReceiveCheckOK(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ServerEngineReceiveCheckNo(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ServerEngineReceiveDeployOK(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ServerEngineReceiveDeployNo(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ServerEngineReceiveStartOK(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ServerEngineReceiveStartNo(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ServerEngineReceiveCancelAck(s,t)
    \/ Base!DefaultJobSchedulerEvaluateResources
    \/ Base!ServerEngineCancelClientResources
    \/ \E s \in Sites, t \in Tokens : Base!CancelResourceProcessorCancel(s,t)
    \/ Base!DefaultJobSchedulerCancelReturned
    \/ Base!DefaultJobSchedulerUpdateHistory
    \/ \E s \in Sites : Base!AutoCleanResourceManagerTick(s)
    \/ \E s \in Sites, t \in Tokens : Base!AutoCleanResourceManagerFinishExpiry(s,t)
    \/ Base!JobRunnerCheckSubmitted
    \/ Base!JobRunnerDeployJob
    \/ \E s \in Sites, t \in Tokens : Base!ClientDeploySuccess(s,t)
    \/ Base!JobRunnerEvaluateDeployment
    \/ Base!JobRunnerWriteDispatched
    \/ Base!JobRunnerPersistDeploy
    \/ Base!JobRunnerCheckDispatched
    \/ Base!ServerEngineSpawnJob
    \/ Base!ServerEngineRegisterJob
    \/ Base!ServerEngineInstallWaiter
    \/ Base!JobRunnerSetPendingOutcomes
    \/ Base!ServerEngineStartClientJob
    \/ Base!JobRunnerEvaluateStartReplies
    \/ Base!JobRunnerFilterPendingOutcomes
    \/ Base!DefaultJobSchedulerJobStarted
    \/ Base!JobRunnerRegisterRunning
    \/ Base!JobRunnerWriteRunning
    \/ Base!JobRunnerFailureRemove
    \/ Base!JobRunnerFailureStop
    \/ Base!JobRunnerFailureStatus
    \/ Base!DefaultJobSchedulerJobAbortedOnStartFailure
    \/ \E s \in Sites, t \in Tokens : Base!StartJobProcessorAllocate(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!StartJobProcessorRejectToken(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ListResourceConsumerConsume(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ClientEngineStartAppCheck(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ClientEngineStartAppReturnedError(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!JobExecutorRegisterPendingHandle(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ProcessJobLauncherSnapshotEnvironment(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ProcessJobLauncherSpawn(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!PendingJobHandleAttach(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!JobExecutorApplyPendingAbort(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!JobExecutorAfterJobLaunchEvent(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!JobExecutorInstallCleanupWaiter(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!StartJobProcessorRollback(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!StartJobProcessorReplySuccess(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!JobExecutorNotifyStarted(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!JobExecutorNotifyStopped(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ClientChildExit(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!JobExecutorWaitChildExit(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!JobExecutorReportOutcome(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!JobExecutorOutcomeReportReturned(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!JobExecutorFreeAfterExit(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!JobExecutorRemoveProcess(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!JobExecutorJobCompletedEvent(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ClientEngineAbortApp(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ClientEngineHeartbeatAbort(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!JobExecutorTerminateAfterGrace(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ServerEngineReceiveOutcome(s,t)
    \/ \E s \in Sites, t \in Tokens : Base!ServerEngineReceiveFailureOutcome(s,t)
    \/ \E j \in Jobs : Base!ServerChildExit(j)
    \/ \E j \in Jobs : Base!ServerEngineObserveExit(j)
    \/ \E j \in Jobs : Base!ServerEngineTerminateAfterGrace(j)
    \/ \E j \in Jobs : Base!ServerEngineRemoveAfterTerminate(j)
    \/ \E j \in Jobs : Base!JobCommandAbortPreRunWrite(j)
    \/ \E j \in Jobs : Base!JobCommandAbortPreRunAcknowledge(j)
    \/ \E j \in Jobs : Base!JobCommandAbortAlreadyTerminal(j)
    \/ \E j \in Jobs : Base!JobCommandAbortRunning(j)
    \/ \E j \in Jobs : Base!JobRunnerMarkAborted(j)
    \/ \E j \in Jobs : Base!JobRunnerSelectCompletion(j)
    \/ \E j \in Jobs : Base!JobRunnerOutcomesResolved(j)
    \/ \E j \in Jobs : Base!JobRunnerClassifyCompletion(j)
    \/ \E j \in Jobs : Base!JobRunnerArchiveSuccess(j)
    \/ \E j \in Jobs : Base!JobRunnerRetryArchive(j)
    \/ \E j \in Jobs : Base!JobRunnerArchiveGraceExpired(j)
    \/ \E j \in Jobs : Base!JobRunnerPublishTerminal(j)
    \/ \E j \in Jobs : Base!JobRunnerRemoveCompleted(j)
    \/ \E j \in Jobs : Base!DefaultJobSchedulerJobAbortedOnCompletion(j)
    \/ \E j \in Jobs : Base!DefaultJobSchedulerJobCompleted(j)
    \/ \E j \in Jobs : Base!DefaultJobSchedulerPersistFailed(j)
    \/ \E j \in Jobs : Base!DefaultJobSchedulerPersistBlocked(j)
    \/ Base!DefaultJobSchedulerReturnPass
    \/ Base!JobRunnerMissingPendingOutcomes

FaultNext ==
    \/ \E t \in Tokens : MCAdminCheckTimeout(t)
    \/ \E t \in Tokens : MCAdminDeployTimeout(t)
    \/ \E t \in Tokens : MCAdminStartTimeout(t)
    \/ \E t \in Tokens : MCAdminCancelTimeout(t)
    \/ MCDefaultJobSchedulerAdmissionException
    \/ MCJobRunnerDeploymentException
    \/ \E s \in Sites, t \in Tokens : MCClientDeployError(s,t)
    \/ MCJobRunnerStartupStoreError
    \/ MCServerEngineStartupError
    \/ \E s \in Sites, t \in Tokens : MCJobExecutorPrepareException(s,t)
    \/ \E s \in Sites, t \in Tokens : MCProcessJobLauncherSpawnException(s,t)
    \/ \E s \in Sites, t \in Tokens : MCJobExecutorWaiterInstallationException(s,t)
    \/ \E s \in Sites, t \in Tokens : MCClientChildFailure(s,t)
    \/ \E s \in Sites, t \in Tokens : MCJobExecutorOutcomeReportException(s,t)
    \/ \E s \in Sites, t \in Tokens : MCFederatedServerHeartbeatCleanup(s,t)
    \/ \E j \in Jobs : MCServerChildFailure(j)
    \/ \E j \in Jobs : MCJobCommandAbortRead(j)
    \/ \E j \in Jobs : MCJobRunnerOutcomeGraceExpired(j)
    \/ \E j \in Jobs : MCJobRunnerArchiveException(j)
    \/ \E j \in Jobs : MCJobRunnerTerminalStoreException(j)
    \/ \E m \in network : MCTransportLoseMessage(m)

MCNext == \/ /\ NormalNext /\ UNCHANGED faults
          \/ FaultNext

MCSpec == MCInit /\ [][MCNext]_mcvars

\* Concrete fairness assumptions for the optional progress configuration.
\* Includes normal exit, delivery, cleanup ticks, retries and each service step.
\* TV-2/TV-3 service death and permanently unavailable components are outside it.
NormalFairness ==
    /\ WF_mcvars(Base!DefaultJobSchedulerBeginPass /\ UNCHANGED faults)
    /\ WF_mcvars(Base!DefaultJobSchedulerEndPass /\ UNCHANGED faults)
    /\ WF_mcvars(Base!DefaultJobSchedulerSkipBackoff /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!DefaultJobSchedulerBackoffElapsed(j) /\ UNCHANGED faults)
    /\ WF_mcvars(Base!DefaultJobSchedulerExhausted /\ UNCHANGED faults)
    /\ WF_mcvars(Base!DefaultJobSchedulerTryJob /\ UNCHANGED faults)
    /\ WF_mcvars(Base!ServerEngineCheckClientResources /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!CheckResourceProcessorReserve(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!CheckResourceProcessorUnavailable(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ServerEngineReceiveCheckOK(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ServerEngineReceiveCheckNo(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ServerEngineReceiveDeployOK(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ServerEngineReceiveDeployNo(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ServerEngineReceiveStartOK(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ServerEngineReceiveStartNo(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ServerEngineReceiveCancelAck(s,t) /\ UNCHANGED faults)
    /\ WF_mcvars(Base!DefaultJobSchedulerEvaluateResources /\ UNCHANGED faults)
    /\ WF_mcvars(Base!ServerEngineCancelClientResources /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!CancelResourceProcessorCancel(s,t) /\ UNCHANGED faults)
    /\ WF_mcvars(Base!DefaultJobSchedulerCancelReturned /\ UNCHANGED faults)
    /\ WF_mcvars(Base!DefaultJobSchedulerUpdateHistory /\ UNCHANGED faults)
    /\ \A s \in Sites : WF_mcvars(Base!AutoCleanResourceManagerTick(s) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!AutoCleanResourceManagerFinishExpiry(s,t) /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerCheckSubmitted /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerDeployJob /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ClientDeploySuccess(s,t) /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerEvaluateDeployment /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerWriteDispatched /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerPersistDeploy /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerCheckDispatched /\ UNCHANGED faults)
    /\ WF_mcvars(Base!ServerEngineSpawnJob /\ UNCHANGED faults)
    /\ WF_mcvars(Base!ServerEngineRegisterJob /\ UNCHANGED faults)
    /\ WF_mcvars(Base!ServerEngineInstallWaiter /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerSetPendingOutcomes /\ UNCHANGED faults)
    /\ WF_mcvars(Base!ServerEngineStartClientJob /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerEvaluateStartReplies /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerFilterPendingOutcomes /\ UNCHANGED faults)
    /\ WF_mcvars(Base!DefaultJobSchedulerJobStarted /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerRegisterRunning /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerWriteRunning /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerFailureRemove /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerFailureStop /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerFailureStatus /\ UNCHANGED faults)
    /\ WF_mcvars(Base!DefaultJobSchedulerJobAbortedOnStartFailure /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!StartJobProcessorAllocate(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!StartJobProcessorRejectToken(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ListResourceConsumerConsume(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ClientEngineStartAppCheck(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ClientEngineStartAppReturnedError(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!JobExecutorRegisterPendingHandle(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ProcessJobLauncherSnapshotEnvironment(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ProcessJobLauncherSpawn(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!PendingJobHandleAttach(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!JobExecutorApplyPendingAbort(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!JobExecutorAfterJobLaunchEvent(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!JobExecutorInstallCleanupWaiter(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!StartJobProcessorRollback(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!StartJobProcessorReplySuccess(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!JobExecutorNotifyStarted(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!JobExecutorNotifyStopped(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ClientChildExit(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!JobExecutorWaitChildExit(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!JobExecutorReportOutcome(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!JobExecutorOutcomeReportReturned(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!JobExecutorFreeAfterExit(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!JobExecutorRemoveProcess(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!JobExecutorJobCompletedEvent(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ClientEngineAbortApp(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ClientEngineHeartbeatAbort(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!JobExecutorTerminateAfterGrace(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ServerEngineReceiveOutcome(s,t) /\ UNCHANGED faults)
    /\ \A s \in Sites, t \in Tokens : WF_mcvars(Base!ServerEngineReceiveFailureOutcome(s,t) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!ServerChildExit(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!ServerEngineObserveExit(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!ServerEngineTerminateAfterGrace(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!ServerEngineRemoveAfterTerminate(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!JobCommandAbortPreRunWrite(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!JobCommandAbortPreRunAcknowledge(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!JobCommandAbortAlreadyTerminal(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!JobCommandAbortRunning(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!JobRunnerMarkAborted(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!JobRunnerSelectCompletion(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!JobRunnerOutcomesResolved(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!JobRunnerClassifyCompletion(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!JobRunnerArchiveSuccess(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!JobRunnerRetryArchive(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!JobRunnerArchiveGraceExpired(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!JobRunnerPublishTerminal(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!JobRunnerRemoveCompleted(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!DefaultJobSchedulerJobAbortedOnCompletion(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!DefaultJobSchedulerJobCompleted(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!DefaultJobSchedulerPersistFailed(j) /\ UNCHANGED faults)
    /\ \A j \in Jobs : WF_mcvars(Base!DefaultJobSchedulerPersistBlocked(j) /\ UNCHANGED faults)
    /\ WF_mcvars(Base!DefaultJobSchedulerReturnPass /\ UNCHANGED faults)
    /\ WF_mcvars(Base!JobRunnerMissingPendingOutcomes /\ UNCHANGED faults)

MCFairSpec == MCSpec /\ NormalFairness

\* Preserve the required-site role. MC uses model values for site identities.
\* With two sites and one mandatory site this is identity; a supplied three-site
\* config reduces the two interchangeable optional sites. Disable for liveness.
MCSymmetry == {p \in Permutations(Sites) : \A s \in RequiredSites : p[s]=s}
MessageBound == Cardinality(network) <= MaxMessageBuffer
MCTypeOK == TypeOK /\ DOMAIN faults=DOMAIN Limits /\
            (\A k \in DOMAIN Limits : faults[k] \in 0..Limits[k])
\* Available display projection; deliberately NOT enabled as TLC VIEW because
\* counter values affect future enabled faults and erasing them can prune paths.
MCView == vars
=============================================================================
