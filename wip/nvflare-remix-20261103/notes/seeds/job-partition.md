# JOB seed: action-group partition for multi-grained composition

Input: `inputs/seeds/job/spec/` (`base.tla`, current-pin rebase c411a201; 7 variables `scheduler, jobs, rm, client, resourceEnv, rpc, network`; 137 actions). Footprints are machine-extracted from `actions.json` (verified string-identical to the `base.tla` action bodies) with helper-operator expansion; process attribution was cross-checked against `instrumentation-hooks.json` `node` (79+9 server, 45 site, 3 process exits, 1 transport: all consistent). Group, mechanism and trigger labels are manual. Full per-action guards/updates, read/write sets and message footprints are in `job-partition.json`. This is analysis only: no split module was written, parsed or model-checked.

## 1. Proposed groups

| Group | Process | Actions | Owned fields | Content | Bug-prone mechanisms kept inside |
|---|---|---:|---:|---|---|
| `JOB_SCHED` | SP | 79 | 41 | DefaultJobScheduler, JobRunner (run thread, start claim, failure cleanup, completion thread), job_cmds abort_job, FederatedServer outcome/heartbeat handlers, AdminServer waiters, JobDefManager status store | start claim vs pre-run abort (_start_lock; U2/MC-3); non-CAS status store writers: DISPATCHED, RUNNING, FAILED_TO_RUN, terminal, ABORTED, CANT_SCHEDULE (MC-3/MC-4 class); running_jobs registration vs completion publication (MC-4); JOB_STARTED/JOB_ABORTED/JOB_COMPLETED synchronous membership (CR-5 boundary); admission exception/cancel/history (U1, #5191 context); pending-outcome set: start filter, fail_run clear, grace, heartbeat resolution |
| `JOB_SPENGINE` | SP | 9 | 4 | ServerEngine.start_app_on_server / _start_runner_process, wait_for_complete thread, abort_app_on_server | SJ registry lifetime: register -> exit observed or terminate -> remove; terminate branches (10 s grace, already-exited, abort-command error) and no-op remove |
| `JOB_CP` | CP | 45 | 28 | Check/Cancel/StartJobProcessor, AutoCleanResourceManager/ListResourceManager, ListResourceConsumer, ClientEngine.start_app/abort_app, JobExecutor (pending handle, waiter, notify_job_status, restart), ProcessJobLauncher/ProcessHandle, training_cmds deploy | reservation TTL expiry vs allocate under the RM lock (#5191 context); rollback free vs live child (MC-2) and cleanup-waiter handoff; shared parent environment vs per-token snapshot incl. restart re-snapshot (CR-1, Phase-1 MC-8); restart generation vs stale/legacy status and READY reset (U3/U4); one free per allocation; outcome report before free |
| `JOB_PROC` | SJ/CJ | 3 | 2 | SJ and CJ OS processes (physical lifetime only; runner logic belongs to the fedavg seed) | nothing bug-prone; pure environment |
| `ENV_NET` | environment | 1 | 0 | network loss |  |

Adjustments to the candidate cut:

- `JOB_SCHED`: Candidate JOB_SCHED absorbs the admin abort command, outcome reception and heartbeat reconciliation because they read/write the same jobs.status/startClaim/pending/running fields; only the SJ-handle half of "abort" (terminate/remove) goes to JOB_SPENGINE.
- `JOB_SPENGINE`: Candidate abort is split: admin abort/start-claim logic stays in JOB_SCHED; only the SJ-handle termination is here. Weakest of the proposed cuts: fail_run and wait_for_complete share engine.lock and the exit-code record; MC-4 is triggered through serverRegistered. Fallback: merge into JOB_SCHED as JOB_SP (no SP-internal port).
- `JOB_CP`: As candidate. Restart and stale-status handling stay with the executor because generation, handle, waiter and allocation are one record (client[s][t]) and one lock.
- `JOB_PROC`: Candidate JOB_PROC kept as an environment group of 3 actions; the seed has no SJ/CJ-local readiness, only CP-observed status. Its implicit outputs (status notifications, rc, can_restart evidence) are currently chosen inside JOB_CP actions and must move onto the port.

Field classification over 91 fields (variable.field, network split per message kind): 66 private, 21 port (16 message kinds + 5 published state fields), **4 conflict**: `client.alive`, `jobs.serverAlive`, `jobs.serverFailed`, `scheduler.pc`. No shared clock variable exists; every deadline is a group-local untimed crossing.

## 2. Why this cut: alternatives measured on the extracted footprints

Conflict = written by actions of two or more groups (message consumption is not counted as a conflicting write).

| Cut | Conflict fields | Published port-state fields |
|---|---|---:|
| proposed: JOB_SCHED \| JOB_SPENGINE \| JOB_CP \| JOB_PROC \| ENV_NET | 4: client.alive, jobs.serverAlive, jobs.serverFailed, scheduler.pc | 5 |
| merge_spengine: JOB_SP (= SCHED+SPENGINE) \| JOB_CP \| JOB_PROC \| ENV_NET | 3: client.alive, jobs.serverAlive, jobs.serverFailed | 1 |
| absorb_proc: PROC exits as env actions inside SPENGINE/CP | 2: jobs.serverFailed, scheduler.pc | 5 |
| merge_spengine_absorb_proc: physical cut only: SP \| CP | 0: - | 1 |
| split_admission: JOB_SCHED further split into JOB_ADMIT (scheduler pass + check/cancel messaging + membership handlers) and JOB_RUN | 8: client.alive, jobs.completion, jobs.serverAlive, jobs.serverFailed, jobs.status, rpc.cancel, scheduler.pc, scheduler.persisted | 8 |

Reading of the data:

- The pure physical cut (SP | CP, process exits as environment inside each side) has zero conflicts and one published field (`client.handle`, the heartbeat shortcut). The SP/CP boundary is the narrow one: every interaction except the heartbeat read is a message in `network`.
- Splitting admission from the runner (`split_admission`) doubles the conflicts: the non-CAS status store (`jobs.status`: CANT_SCHEDULE vs DISPATCHED/RUNNING/FAILED_TO_RUN/ABORTED/terminal), `jobs.completion` (synchronous JOB_ABORTED/JOB_COMPLETED handlers), `rpc.cancel` (admission and failure cleanup share the cancel waiter), `scheduler.persisted` and the single runner PC. These are exactly the MC-3/MC-4/CR-5 boundaries, so admission, runner, abort command, completion and outcome reception stay in one `JOB_SCHED`.
- `JOB_SPENGINE` costs two conflicts (`scheduler.pc`, `jobs.serverFailed`) plus five published fields, all inside SP. It is kept as a group because it is the SP handle on SJ that an integrated FedAvg/SJ model must drive, and a coarse variant (spawn ok/fail, registered until exit) is much smaller than the 9 fine actions. It is the weakest cut; the fallback is `merge_spengine` (JOB_SP).
- `JOB_PROC` costs the two liveness conflicts (`client.alive`, `jobs.serverAlive`), resolved by a joint spawn step and an Exit event. It exists so that SJ/CJ lifetime can be replaced by the FedAvg runner groups in integrated mixes.

Placement of the bug-prone mechanisms (from `validation-report.md`, `bug-report.md`, `findings.json`, historical `confirmed-bugs.md`, Phase-1 v2 brief):

| Mechanism / lineage | Fine actions | Group | Cross-group dependency |
|---|---|---|---|
| Start claim vs pre-run abort (U2; MC-3 trigger blocked at pin) | JobRunnerClaimStart/ClaimRejected/ReleaseStart, JobCommandAbortRead/PreRunAcknowledge/Starting, JobRunnerWriteDispatched | JOB_SCHED | none (abort request is environment E8) |
| Terminal resurrection (MC-4, reproduced historically) | JobRunnerRegisterRunning/WriteRunning vs JobRunnerSelectCompletion..PublishTerminal | JOB_SCHED | trigger: SJ exit (JOB_PROC) and registry removal ServerEngineObserveExit (JOB_SPENGINE) before WriteRunning |
| Startup-failure store escape (CR-5, reproduced historically; not modelled: failure-branch store succeeds) | JobRunnerFailureStatus -> DefaultJobSchedulerJobAbortedOnStartFailure | JOB_SCHED | none; would need a store fault inside the same group |
| Admission exception cleanup / reservation retention (U1, #5191 context) | DefaultJobSchedulerAdmissionException/Recovered/HistoryFallback, ServerEngineCancelClientResources, CancelResourceProcessorCancel, AutoCleanResourceManager* | JOB_SCHED + JOB_CP | inherently physical: reservation lives at CP, decision at SP; carried by Check/Cancel/Start tokens over P_ADMIN |
| Reservation expiry vs allocate (RM lock) | AutoCleanResourceManagerTick/FinishExpiry, StartJobProcessorAllocate/RejectToken, CheckResourceProcessor* | JOB_CP | SCHED must be able to deliver Start late (after TTL) |
| Rollback free while child live, cleanup handoff (MC-2, reproduced historically) | JobExecutorWaiterInstallationException, StartJobProcessorRollback, PendingJobHandleAttach, JobExecutorInstallCleanupWaiter | JOB_CP | PROC must keep the child alive; SCHED must send Start |
| Shared CP environment vs snapshot (CR-1 reproduced; Phase-1 MC-8 restart re-snapshot) | ListResourceConsumerConsume, ProcessJobLauncherSnapshotEnvironment, JobExecutorRestartClaim | JOB_CP | two concurrent tokens at one site (SCHED MaxJobs=2) |
| Restart generation vs stale/legacy status (U3/U4) | JobExecutorObserveExitCode, ProcessHandleCheckRestart, JobExecutorRestartClaim/Continue/Exception, JobExecutorNotify*/Ignore* | JOB_CP | PROC/CJ runner supplies rc, can_restart evidence and stale READY |
| SJ exit code vs fail_run precedence (engine.lock; server_engine.py:204-234 wait_for_complete, job_runner.py:903-925 fail_run) | ServerChildFailure, ServerEngineObserveExit, ServerEngineReceive{Failure,Aborted}Outcome | JOB_SCHED/JOB_SPENGINE/JOB_PROC | conflict field jobs.serverFailed; seed over-approximates (code recorded at physical exit) |

## 3. Actions

Trigger: internal = enabled by the group's own state; message = consumes a `network` message; fault:k = MC fault budget k; time:x = untimed deadline crossing; env/os-wait/oracle = environment stand-in (section 7). Writes are variable.field; messages are consumed -> sent (`!K` = absence test). The last column lists reads of fields owned by another group.

### JOB_SCHED (79)

| Action | Params | Process | Mechanism | Trigger | Writes | Messages | Foreign reads | Source |
|---|---|---|---|---|---|---|---|---|
| `DefaultJobSchedulerBeginPass` | - | SP | scheduler | internal | scheduler.candidates, scheduler.pc | - | - | job_schedulers/job_scheduler.py:368-375 |
| `DefaultJobSchedulerEndPass` | - | SP | scheduler | internal | scheduler.pc, scheduler.returnTo | - | - | job_schedulers/job_scheduler.py:429-430 |
| `DefaultJobSchedulerSkipBackoff` | - | SP | scheduler | internal | scheduler.candidates | - | - | job_schedulers/job_scheduler.py:385-391 |
| `DefaultJobSchedulerBackoffElapsed` | j | SP | scheduler | time:backoff | scheduler.cooldown | - | - | job_schedulers/job_scheduler.py:385-391 |
| `DefaultJobSchedulerExhausted` | - | SP | scheduler | internal | scheduler.blockedPending, scheduler.candidates, scheduler.cooldown, scheduler.count, scheduler.history | - | - | job_schedulers/job_scheduler.py:327-339 |
| `DefaultJobSchedulerTryJob` | - | SP | scheduler | internal | scheduler.considered, scheduler.current, scheduler.issued, scheduler.pc | - | - | job_schedulers/job_scheduler.py:119-214 |
| `ServerEngineCheckClientResources` | - | SP | admin-rpc send | internal | rpc.check, scheduler.pc | -> Check | - | server/server_engine.py:1011-1025 |
| `ServerEngineReceiveCheckOK` | s,t | SP | admin-rpc reply/waiter | message | rpc.check | CheckOK -> | - | server/server_engine.py:1026-1042 |
| `ServerEngineReceiveCheckNo` | s,t | SP | admin-rpc reply/waiter | message | rpc.check | CheckNo -> | - | server/server_engine.py:1026-1042 |
| `AdminCheckTimeout` | t | SP | admin-rpc timeout | time:rpc-deadline (fault-bounded) | rpc.check | - | - | server/server_engine.py:1024-1041 |
| `ServerEngineReceiveDeployOK` | s,t | SP | admin-rpc reply/waiter | message | rpc.deploy | DeployOK -> | - | server/server_engine.py:1026-1042 |
| `ServerEngineReceiveDeployNo` | s,t | SP | admin-rpc reply/waiter | message | rpc.deploy | DeployNo -> | - | server/server_engine.py:1026-1042 |
| `AdminDeployTimeout` | t | SP | admin-rpc timeout | time:rpc-deadline (fault-bounded) | rpc.deploy | - | - | server/server_engine.py:1024-1041 |
| `ServerEngineReceiveStartOK` | s,t | SP | admin-rpc reply/waiter | message | rpc.start | StartOK -> | - | server/server_engine.py:1026-1042 |
| `ServerEngineReceiveStartNo` | s,t | SP | admin-rpc reply/waiter | message | rpc.start | StartNo -> | - | server/server_engine.py:1026-1042 |
| `AdminStartTimeout` | t | SP | admin-rpc timeout | time:rpc-deadline (fault-bounded) | rpc.start | - | - | server/server_engine.py:1024-1041 |
| `ServerEngineReceiveCancelAck` | s,t | SP | admin-rpc reply/waiter | message | rpc.cancel | CancelAck -> | - | server/server_engine.py:1026-1042 |
| `AdminCancelTimeout` | t | SP | admin-rpc timeout | time:rpc-deadline (fault-bounded) | rpc.cancel | - | - | server/server_engine.py:1024-1041 |
| `DefaultJobSchedulerEvaluateResources` | - | SP | scheduler | internal | jobs.dispatch, scheduler.pc, scheduler.result | - | - | job_schedulers/job_scheduler.py:216-290 |
| `ServerEngineCancelClientResources` | - | SP | admin-rpc send | internal | rpc.cancel, scheduler.pc | -> Cancel | - | job_schedulers/job_scheduler.py:233-290 |
| `DefaultJobSchedulerCancelReturned` | - | SP | scheduler | internal | scheduler.pc | - | - | server/server_engine.py:1054-1093 |
| `DefaultJobSchedulerUpdateHistory` | - | SP | scheduler | internal | scheduler.candidates, scheduler.cooldown, scheduler.count, scheduler.failedPending, scheduler.history, scheduler.pc, scheduler.returnTo | - | - | job_schedulers/job_scheduler.py:349-362 |
| `DefaultJobSchedulerAdmissionException` | - | SP | scheduler | fault:admissionError | jobs.dispatch, scheduler.pc, scheduler.result | - | - | job_schedulers/job_scheduler.py:214-304 |
| `JobRunnerCheckSubmitted` | - | SP | runner deploy/start | internal | jobs.checked, scheduler.pc | - | - | server/job_runner.py:714-723 |
| `JobRunnerDeployJob` | - | SP | runner deploy/start | internal | rpc.deploy, scheduler.pc | -> Deploy | - | server/job_runner.py:204-299 |
| `JobRunnerDeploymentException` | - | SP | runner deploy/start | fault:deployError | scheduler.pc | - | - | server/job_runner.py:225-240 |
| `JobRunnerEvaluateDeployment` | - | SP | runner deploy/start | internal | jobs.deployed, scheduler.pc | - | - | server/job_runner.py:301-336 |
| `JobRunnerWriteDispatched` | - | SP | start claim + status metadata | internal | jobs.status, scheduler.pc | - | - | server/job_runner.py:723-734 |
| `JobRunnerPersistDeploy` | - | SP | runner deploy/start | internal | scheduler.pc, scheduler.persisted | - | - | server/job_runner.py:736-759 |
| `JobRunnerSetPendingOutcomes` | - | SP | runner deploy/start | internal | jobs.outcomeKey, jobs.pending, scheduler.pc | - | - | server/job_runner.py:346-361 |
| `ServerEngineStartClientJob` | - | SP | admin-rpc send | internal | rpc.start, scheduler.pc | -> Start | - | server/server_engine.py:1093-1108 |
| `JobRunnerEvaluateStartReplies` | - | SP | runner deploy/start | internal | jobs.active, scheduler.pc | - | - | server/admin.py:101-142 |
| `JobRunnerFilterPendingOutcomes` | - | SP | runner deploy/start | internal | jobs.pending, scheduler.pc | - | - | server/job_runner.py:406-415 |
| `DefaultJobSchedulerJobStarted` | - | SP | scheduler-event (sync JOB_STARTED/JOB_ABORTED) | internal | scheduler.pc, scheduler.scheduled | - | - | server/job_runner.py:415-423 |
| `JobRunnerRegisterRunning` | - | SP | runner deploy/start | internal | jobs.running, scheduler.pc | - | - | server/job_runner.py:767-768 |
| `JobRunnerWriteRunning` | - | SP | start claim + status metadata | internal | jobs.resurrected, jobs.status, scheduler.pc | - | - | server/job_runner.py:769-770 |
| `JobRunnerStartupStoreError` | - | SP | start claim + status metadata | fault:storeError | scheduler.pc | - | - | server/job_runner.py:734-753 |
| `JobRunnerFailureRemove` | - | SP | runner startup-failure cleanup | internal | jobs.outcomeKey, jobs.pending, jobs.running, scheduler.pc | - | - | server/job_runner.py:771-777 |
| `JobRunnerFailureStop` | - | SP | runner startup-failure cleanup | internal | jobs.serverStop, scheduler.pc | - | jobs.serverRegistered | server/job_runner.py:425-464 |
| `JobRunnerFailureStatus` | - | SP | runner startup-failure cleanup | internal | jobs.status, scheduler.pc | - | - | server/job_runner.py:792-805 |
| `DefaultJobSchedulerJobAbortedOnStartFailure` | - | SP | scheduler-event (sync JOB_STARTED/JOB_ABORTED) | internal | scheduler.pc, scheduler.scheduled | - | - | server/job_runner.py:804-807 |
| `FederatedServerHeartbeatCleanup` | s,t | SP | heartbeat reconciliation | message:heartbeat (implicit) | - | -> HeartbeatStop !HeartbeatStop | client.handle, jobs.serverRegistered | server/fed_server.py:1013-1026 |
| `ServerEngineReceiveOutcome` | s,t | SP | outcome receive (fed_server/fail_run) | message | jobs.pending | OutcomeOK -> | - | server/fed_server.py:943-961 |
| `ServerEngineReceiveFailureOutcome` | s,t | SP | outcome receive (fed_server/fail_run) | message | jobs.outcomeKey, jobs.pending, jobs.serverAborted, jobs.serverFailed, jobs.serverStop | OutcomeFailed -> Stop | jobs.serverRegistered | server/fed_server.py:943-961 |
| `JobCommandAbortRead` | j | SP | abort (admin command, _start_lock) | admin-user (fault-bounded adminAbort) | jobs.adminPC, jobs.adminRead, jobs.status | - | - | server/job_runner.py:815-825 |
| `JobCommandAbortPreRunAcknowledge` | j | SP | abort (admin command) | internal | jobs.abortAck, jobs.adminPC | - | - | server/job_cmds.py:1086-1089 |
| `JobCommandAbortAlreadyTerminal` | j | SP | abort (admin command) | internal | jobs.adminPC | - | - | server/job_cmds.py:1090-1093 |
| `JobCommandAbortRunning` | j | SP | abort (admin command) | internal | jobs.adminPC, jobs.serverStop | - | jobs.serverRegistered | server/job_cmds.py:1094-1101 |
| `JobRunnerMarkAborted` | j | SP | abort (admin command) | internal | jobs.adminPC, jobs.runAborted | - | - | server/job_runner.py:892-901 |
| `JobRunnerSelectCompletion` | j | SP | completion/outcome/metadata | internal | jobs.completion, jobs.outcomeKey, jobs.pending | - | jobs.serverRegistered | server/job_runner.py:494-527 |
| `JobRunnerOutcomesResolved` | j | SP | completion/outcome/metadata | internal | jobs.completion | - | - | server/job_runner.py:502-527 |
| `JobRunnerOutcomeGraceExpired` | j | SP | completion/outcome/metadata | time:outcome-grace (fault-bounded) | jobs.completion, jobs.pending | - | - | server/job_runner.py:517-531 |
| `JobRunnerClassifyCompletion` | j | SP | completion/outcome/metadata | internal | jobs.completion, jobs.finishStatus | -> Stop | - | server/job_runner.py:533-547 |
| `JobRunnerArchiveSuccess` | j | SP | completion/outcome/metadata | internal | jobs.completion | - | - | server/job_runner.py:545-573 |
| `JobRunnerArchiveException` | j | SP | completion/outcome/metadata | fault:archiveError | jobs.archiveFailed, jobs.completion | - | - | server/job_runner.py:546-558 |
| `JobRunnerRetryArchive` | j | SP | completion/outcome/metadata | internal | jobs.completion | - | - | server/job_runner.py:494-495 |
| `JobRunnerArchiveGraceExpired` | j | SP | completion/outcome/metadata | time:archive-grace | jobs.completion | - | - | server/job_runner.py:549-573 |
| `JobRunnerPublishTerminal` | j | SP | completion/outcome/metadata | internal | jobs.completion, jobs.status, jobs.terminalPublished | - | - | server/job_runner.py:574-581 |
| `JobRunnerTerminalStoreException` | j | SP | completion/outcome/metadata | fault:storeError | - | - | - | server/job_runner.py:574-581 |
| `JobRunnerRemoveCompleted` | j | SP | completion/outcome/metadata | internal | jobs.completedRemoved, jobs.completion, jobs.outcomeKey, jobs.pending, jobs.running | - | - | server/job_runner.py:582-589 |
| `DefaultJobSchedulerJobAbortedOnCompletion` | j | SP | scheduler-event (sync JOB_ABORTED/JOB_COMPLETED) | internal | jobs.completion, scheduler.scheduled | - | - | server/job_runner.py:587-588 |
| `DefaultJobSchedulerJobCompleted` | j | SP | scheduler-event (sync JOB_ABORTED/JOB_COMPLETED) | internal | jobs.completion, scheduler.scheduled | - | - | server/job_runner.py:589-589 |
| `DefaultJobSchedulerPersistFailed` | j | SP | scheduler+metadata | internal | scheduler.failedPending, scheduler.persisted | - | - | job_schedulers/job_scheduler.py:327-333 |
| `DefaultJobSchedulerPersistBlocked` | j | SP | scheduler+metadata | internal | jobs.status, scheduler.blockedPending, scheduler.persisted | - | - | job_schedulers/job_scheduler.py:334-339 |
| `DefaultJobSchedulerReturnPass` | - | SP | scheduler | internal | scheduler.pc | - | - | job_schedulers/job_scheduler.py:340-340 |
| `JobRunnerMissingPendingOutcomes` | - | SP | runner deploy/start | internal | scheduler.pc | - | - | server/job_runner.py:410-411 |
| `JobCommandAbortRunningSend` | j | SP | abort (admin command) | internal | jobs.adminPC | -> Stop | jobs.serverRegistered | server/job_runner.py:425-464 |
| `JobRunnerFailureSendStop` | - | SP | runner startup-failure cleanup | internal | scheduler.pc | -> Stop | jobs.serverRegistered | server/job_runner.py:425-464 |
| `ServerEngineReceiveAbortedOutcome` | s,t | SP | outcome receive (fed_server/fail_run) | message | jobs.outcomeKey, jobs.pending, jobs.serverAborted, jobs.serverFailed, jobs.serverStop | OutcomeAborted -> Stop | jobs.serverRegistered | server/fed_server.py:943-961 |
| `ServerEngineIgnoreOutcome` | s,t | SP | outcome receive (fed_server/fail_run) | message | - | OutcomeAborted,OutcomeFailed,OutcomeOK -> | - | server/fed_server.py:943-945 |
| `ServerEngineResolveMissingOutcome` | s,t | SP | heartbeat reconciliation | message:heartbeat (implicit) | jobs.outcomeKey, jobs.pending, jobs.serverAborted, jobs.serverFailed | - | client.handle, jobs.serverRegistered | server/fed_server.py:1054-1103 |
| `DefaultJobSchedulerAdmissionRecovered` | - | SP | scheduler | internal | scheduler.candidates, scheduler.cooldown, scheduler.count, scheduler.failedPending, scheduler.history, scheduler.pc | - | - | job_schedulers/job_scheduler.py:394-420 |
| `DefaultJobSchedulerAdmissionHistoryFallback` | - | SP | scheduler+metadata | fault:storeError | scheduler.candidates, scheduler.cooldown, scheduler.count, scheduler.failedPending, scheduler.history, scheduler.pc | - | - | job_schedulers/job_scheduler.py:394-420 |
| `JobRunnerClaimStart` | - | SP | start claim + status metadata | internal | jobs.checked, jobs.claimEver, jobs.startClaim, scheduler.pc | - | - | server/job_runner.py:726-735 |
| `JobRunnerClaimRejected` | - | SP | start claim + status metadata | internal | jobs.checked, scheduler.pc | - | - | server/job_runner.py:726-734 |
| `JobRunnerReleaseStart` | - | SP | start claim + status metadata | internal | jobs.startClaim, scheduler.pc | - | - | server/job_runner.py:808-810 |
| `JobRunnerFailureCancelResources` | - | SP | runner startup-failure cleanup | internal | rpc.cancel, scheduler.pc | -> Cancel | - | server/job_runner.py:782-791 |
| `JobRunnerFailureCancelReturned` | - | SP | runner startup-failure cleanup | internal | scheduler.pc | - | - | server/job_runner.py:782-791 |
| `JobCommandAbortStarting` | j | SP | abort (admin command) | internal | jobs.adminPC | - | - | server/job_cmds.py:1081-1084 |

### JOB_SPENGINE (9)

| Action | Params | Process | Mechanism | Trigger | Writes | Messages | Foreign reads | Source |
|---|---|---|---|---|---|---|---|---|
| `ServerEngineSpawnJob` | - | SP | server engine spawn/register | call:start_app_on_server (runner thread pc) | jobs.serverAlive, jobs.serverSpawned, scheduler.pc | - | scheduler.current, scheduler.pc | server/server_engine.py:180-196 |
| `ServerEngineRegisterJob` | - | SP | server engine spawn/register | call:start_app_on_server (runner thread pc) | jobs.serverRegistered, scheduler.pc | - | scheduler.current, scheduler.pc | server/server_engine.py:322-327 |
| `ServerEngineInstallWaiter` | - | SP | server engine spawn/register | call:start_app_on_server (runner thread pc) | jobs.serverWaiter, scheduler.pc | - | scheduler.current, scheduler.pc | server/server_engine.py:329-330 |
| `ServerEngineStartupError` | - | SP | server engine spawn/register | fault:preLaunchError | scheduler.pc | - | scheduler.pc | server/server_engine.py:180-194 |
| `ServerEngineObserveExit` | j | SP | server engine wait SJ | os-wait (SJ exit) | jobs.serverRegistered | - | jobs.serverAlive | server/server_engine.py:204-235 |
| `ServerEngineTerminateAfterGrace` | j | SP | server engine abort SJ | call:abort_app_on_server | jobs.serverTerminated | - | jobs.adminPC, jobs.serverStop, scheduler.current, scheduler.pc | server/server_engine.py:386-408 |
| `ServerEngineRemoveAfterTerminate` | j | SP | server engine abort SJ | call:abort_app_on_server | jobs.serverRegistered | - | - | server/server_engine.py:409-410 |
| `ServerEngineTerminateAfterExit` | j | SP | server engine abort SJ | call:abort_app_on_server | jobs.serverTerminated | - | jobs.adminPC, jobs.serverStop, scheduler.current, scheduler.pc | server/server_engine.py:386-410 |
| `ServerEngineTerminateAfterAbortCommandError` | j | SP | server engine abort SJ | fault:serverAbortError | jobs.serverTerminated | - | jobs.adminPC, jobs.serverStop, scheduler.current, scheduler.pc | server/server_engine.py:362-410 |

### JOB_CP (45)

| Action | Params | Process | Mechanism | Trigger | Writes | Messages | Foreign reads | Source |
|---|---|---|---|---|---|---|---|---|
| `CheckResourceProcessorReserve` | s,t | CP | resource manager (reserve) | message | rm.free, rm.reserved, rm.ttl | Check -> CheckOK | - | client/scheduler_cmds.py:67-96 |
| `CheckResourceProcessorUnavailable` | s,t | CP | resource manager (reserve) | message | - | Check -> CheckNo | - | client/scheduler_cmds.py:86-96 |
| `CancelResourceProcessorCancel` | s,t | CP | resource manager (cancel) | message | rm.free, rm.reserved, rm.ttl | Cancel -> CancelAck | - | client/scheduler_cmds.py:152-160 |
| `AutoCleanResourceManagerTick` | s | CP | resource manager (expiry) | time:ttl-scan | rm.ttl | - | - | resource_managers/auto_clean_resource_manager.py:102-113 |
| `AutoCleanResourceManagerFinishExpiry` | s,t | CP | resource manager (expiry) | internal | rm.free, rm.reserved | - | - | resource_managers/auto_clean_resource_manager.py:105-116 |
| `ClientDeploySuccess` | s,t | CP | client deploy | message | client.deployed | Deploy -> DeployOK | - | client/training_cmds.py:100-153 |
| `ClientDeployError` | s,t | CP | client deploy | message+fault:deployError | - | Deploy -> DeployNo | - | client/training_cmds.py:100-153 |
| `StartJobProcessorAllocate` | s,t | CP | resource manager (allocate) + client executor | message | client.pc, rm.allocated, rm.payload, rm.reserved, rm.ttl | Start -> | - | client/scheduler_cmds.py:117-121 |
| `StartJobProcessorRejectToken` | s,t | CP | resource manager (allocate) + client executor | message | client.pc | Start -> StartNo | - | resource_managers/auto_clean_resource_manager.py:156-163 |
| `ListResourceConsumerConsume` | s,t | CP | resource consumer (shared env) | internal | client.pc, resourceEnv | - | - | client/scheduler_cmds.py:122-124 |
| `ClientEngineStartAppCheck` | s,t | CP | client executor (start app) | internal | client.pc | - | - | client/client_engine.py:357-379 |
| `ClientEngineStartAppReturnedError` | s,t | CP | client executor (start app) | internal | client.pc | -> StartNo | - | client/client_engine.py:365-367 |
| `JobExecutorRegisterPendingHandle` | s,t | CP | client executor (launch/handle/waiter) | internal | client.generation, client.handle, client.logical, client.pc | - | - | client/client_executor.py:347-357 |
| `JobExecutorPrepareException` | s,t | CP | client executor (launch/handle/waiter) | fault:preLaunchError | client.pc | - | - | client/scheduler_cmds.py:122-136 |
| `ProcessJobLauncherSnapshotEnvironment` | s,t | CP | launcher (spawn CJ) | internal | client.binding, client.pc | - | - | job_launcher/process_launcher.py:128-155 |
| `ProcessJobLauncherSpawn` | s,t | CP | launcher (spawn CJ) | internal | client.alive, client.pc, client.spawned | - | - | job_launcher/process_launcher.py:157-160 |
| `ProcessJobLauncherSpawnException` | s,t | CP | launcher (spawn CJ) | fault:spawnError | client.handle, client.pc | - | - | client/client_executor.py:359-366 |
| `PendingJobHandleAttach` | s,t | CP | client executor (launch/handle/waiter) | internal | client.attached, client.handle, client.pc | - | - | client/client_executor.py:82-89 |
| `JobExecutorApplyPendingAbort` | s,t | CP | client executor (launch/handle/waiter) | internal | client.pc, client.terminateRequested | - | - | client/client_executor.py:366-366 |
| `JobExecutorAfterJobLaunchEvent` | s,t | CP | client executor (launch/handle/waiter) | internal | client.pc | - | - | client/client_executor.py:366-369 |
| `JobExecutorInstallCleanupWaiter` | s,t | CP | client executor (launch/handle/waiter) | internal | client.cleanup, client.pc, client.waiter | - | - | client/client_executor.py:369-373 |
| `JobExecutorWaiterInstallationException` | s,t | CP | client executor (launch/handle/waiter) | fault:waiterError | client.pc | - | - | client/client_executor.py:369-373 |
| `StartJobProcessorRollback` | s,t | CP | resource manager (free) + client executor rollback | internal | client.pc, rm.allocated, rm.free, rm.releases | -> StartNo | - | client/scheduler_cmds.py:132-140 |
| `StartJobProcessorReplySuccess` | s,t | CP | client executor (start reply) | internal | client.pc | -> StartOK | - | client/client_engine.py:382-382 |
| `JobExecutorNotifyStarted` | s,t,g | CP | client executor (CJ status notification) | message:CJ status (implicit, env-driven) | client.logical | - | - | client/client_executor.py:430-444 |
| `JobExecutorNotifyStopped` | s,t,g | CP | client executor (CJ status notification) | message:CJ status (implicit, env-driven) | client.logical | - | - | client/client_executor.py:430-444 |
| `JobExecutorWaitChildExit` | s,t | CP | launcher/restart (child wait) | internal | client.cleanup, client.exitCode, client.exitObserved | - | client.alive | client/client_executor.py:765-800 |
| `JobExecutorReportOutcome` | s,t | CP | outcome report | internal | client.cleanup | -> OutcomeAborted,OutcomeFailed,OutcomeOK | - | client/client_executor.py:802-818 |
| `JobExecutorOutcomeReportReturned` | s,t | CP | outcome report | internal | client.cleanup | !OutcomeAborted,!OutcomeFailed,!OutcomeOK | - | client/client_executor.py:819-833 |
| `JobExecutorOutcomeReportException` | s,t | CP | outcome report | fault:reportError | client.cleanup | - | - | client/client_executor.py:802-832 |
| `JobExecutorFreeAfterExit` | s,t | CP | resource manager (free after exit) | internal | client.cleanup, rm.allocated, rm.free, rm.releases | - | - | client/client_executor.py:830-833 |
| `JobExecutorRemoveProcess` | s,t | CP | client executor (cleanup) | internal | client.cleanup, client.handle | - | - | client/client_executor.py:834-836 |
| `JobExecutorJobCompletedEvent` | s,t | CP | client executor (cleanup) | internal | client.cleanup | - | - | client/client_executor.py:838-842 |
| `ClientEngineAbortApp` | s,t | CP | abort (CP stop) | message | client.abortRequested | Stop -> | - | client/client_engine.py:390-404 |
| `ClientEngineHeartbeatAbort` | s,t | CP | abort (CP heartbeat stop) | message | client.abortRequested | HeartbeatStop -> | - | client/client_engine.py:390-404 |
| `JobExecutorTerminateAfterGrace` | s,t | CP | abort (CP terminate) | internal | client.terminateRequested | - | - | client/client_executor.py:673-693 |
| `JobExecutorAbortStarting` | s,t | CP | abort (CP terminate) | internal | client.pendingAbort, client.terminateRequested | - | - | client/client_executor.py:589-604 |
| `JobExecutorNotifyReady` | s,t,g | CP | client executor (CJ status notification) | message:CJ status (implicit, env-driven) | client.logical, client.ready, client.restartAttempts | - | - | client/client_executor.py:430-444 |
| `JobExecutorIgnoreStaleStatus` | s,t,g | CP | client executor (CJ status notification) | message:CJ status (implicit, env-driven) | - | - | - | client/client_executor.py:430-444 |
| `JobExecutorIgnoreStoppedStatus` | s,t,g | CP | client executor (CJ status notification) | message:CJ status (implicit, env-driven) | - | - | - | client/client_executor.py:430-435 |
| `JobExecutorObserveExitCode` | s,t,rc | CP | launcher/restart (child wait) | os-wait (CJ exit; rc chosen here; childError fault-bounded) | client.cleanup, client.exitCode, client.rawExit, client.retryable | - | client.alive | client/client_executor.py:765-768 |
| `ProcessHandleCheckRestart` | s,t,safe | CP | launcher/restart | oracle:backend settlement (safe chosen) | client.restartChecked, client.restartSafe | - | - | client/client_executor.py:722-733 |
| `JobExecutorRestartClaim` | s,t | CP | launcher/restart | internal | client.attached, client.cleanup, client.exitObserved, client.generation, client.handle, client.logical, client.pc, client.pendingAbort, client.ready, client.restartAttempts, client.terminateRequested | - | - | client/client_executor.py:734-753 |
| `JobExecutorRestartContinue` | s,t | CP | launcher/restart | internal | client.cleanup, client.exitCode, client.pc, client.rawExit, client.restartChecked, client.restartSafe, client.retryable | - | - | client/client_executor.py:754-761 |
| `JobExecutorRestartException` | s,t | CP | launcher/restart | fault:spawnError | client.cleanup, client.exitCode, client.exitObserved | - | - | client/client_executor.py:771-776 |

### JOB_PROC (3)

| Action | Params | Process | Mechanism | Trigger | Writes | Messages | Foreign reads | Source |
|---|---|---|---|---|---|---|---|---|
| `ClientChildExit` | s,t | CJ | job process exit | env:CJ exits | client.alive | - | - | job_launcher/process_launcher.py:72-79 |
| `ServerChildExit` | j | SJ | job process exit | env:SJ exits | jobs.serverAlive | - | - | server/server_engine.py:204-205 |
| `ServerChildFailure` | j | SJ | job process exit | fault:childError (SJ abnormal exit) | jobs.serverAlive, jobs.serverFailed | - | - | server/server_engine.py:220-234 |

### ENV_NET (1)

| Action | Params | Process | Mechanism | Trigger | Writes | Messages | Foreign reads | Source |
|---|---|---|---|---|---|---|---|---|
| `TransportLoseMessage` | m | environment | transport loss | fault:loss | - | * -> | - | server/admin.py:307-339 |

## 4. Field ownership

Non-private fields (all writers/readers by group; counts are numbers of actions):

| Field | Index | Class | Proposed owner | Writers | Readers | Note / resolution |
|---|---|---|---|---|---|---|
| `client.alive` | per site s x token t | **conflict** | JOB_PROC | JOB_CP:1, JOB_PROC:1 | JOB_PROC:1, JOB_CP:2 | CJ physical liveness. Set TRUE by ProcessJobLauncherSpawn (CP), FALSE by ClientChildExit (CJ); read by CP waiter (process.wait) and invariants. Resolve: JOB_PROC owns cj[s][t].alive with joint spawn; CP observes Exit(s,t,g,rc). |
| `client.handle` | per site s x token t | **port** | JOB_CP | JOB_CP:5 | JOB_CP:11, JOB_SCHED:2 | Executor registry (run_processes at CP). Read by JOB_SCHED heartbeat actions (FederatedServerHeartbeatCleanup, ServerEngineResolveMissingOutcome) = heartbeat job list content read synchronously across processes; make explicit Heartbeat(s, jobs registered at s) message. |
| `jobs.adminPC` | per job j | **port** | JOB_SCHED | JOB_SCHED:7 | JOB_SPENGINE:3, JOB_SCHED:7 | Admin abort command PC. Read by JOB_SPENGINE terminate guards (adminPC="stopWait") = oracle on the caller thread; replace with AbortSJ(j) request. |
| `jobs.serverAlive` | per job j | **conflict** | JOB_PROC | JOB_SPENGINE:1, JOB_PROC:2 | JOB_PROC:2, JOB_SPENGINE:1 | SJ physical liveness. Set TRUE by ServerEngineSpawnJob (SP), FALSE by ServerChildExit/Failure (SJ), read by ServerEngineObserveExit (process.wait). Resolve: JOB_PROC owns sj[j].alive; spawn is a joint SPENGINE/PROC step (Popen returns a live child); ObserveExit consumes an Exit(j,rc) event. |
| `jobs.serverFailed` | per job j | **conflict** | JOB_SCHED | JOB_SCHED:3, JOB_PROC:1 | JOB_SCHED:7 | engine.exception_run_processes[j] (authoritative failure code). Written by fed_server/fail_run outcome receivers + heartbeat ResolveMissingOutcome (JOB_SCHED) and by ServerChildFailure (SJ exit with error; JOB_PROC). In code the SJ code is recorded by wait_for_complete (server_engine.py:220-234) under engine.lock in the same critical section that pops run_processes, with precedence vs fail_run (job_runner.py:903-925). The seed sets it at physical exit (before ObserveExit): over-approximation/shortcut. Resolve: JOB_SCHED owns the record; SJ code arrives with the SPENGINE exit observation as a joint step (ObserveExit + record) -- a separate later consume step would let SelectCompletion classify COMPLETED in between (spurious). |
| `jobs.serverRegistered` | per job j | **port** | JOB_SPENGINE | JOB_SPENGINE:3 | JOB_SCHED:9, JOB_SPENGINE:2 | engine.run_processes membership. Written only by JOB_SPENGINE (Register, ObserveExit, RemoveAfterTerminate); read by 9 JOB_SCHED actions (completion selection, failure cleanup, abort, outcome receivers, heartbeat). Published read-only port state (same process, engine.lock). |
| `jobs.serverStop` | per job j | **port** | JOB_SCHED | JOB_SCHED:4 | JOB_SCHED:4, JOB_SPENGINE:3 | Abort request flag (job_runner._stop_run -> engine.abort_app_on_server). Written by JOB_SCHED (failure stop, admin abort, fail_run); read by JOB_SPENGINE terminate guards. Becomes AbortSJ(j) request message. |
| `network.Cancel` | per (kind, site, job, attempt) record in a set | **port** | JOB_SCHED->JOB_CP | JOB_SCHED:2, JOB_CP:1, ENV_NET:1 | JOB_CP:1 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.CancelAck` | per (kind, site, job, attempt) record in a set | **port** | JOB_CP->JOB_SCHED | JOB_SCHED:1, JOB_CP:1, ENV_NET:1 | JOB_SCHED:1 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.Check` | per (kind, site, job, attempt) record in a set | **port** | JOB_SCHED->JOB_CP | JOB_SCHED:1, JOB_CP:2, ENV_NET:1 | JOB_CP:2 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.CheckNo` | per (kind, site, job, attempt) record in a set | **port** | JOB_CP->JOB_SCHED | JOB_CP:1, JOB_SCHED:1, ENV_NET:1 | JOB_SCHED:1 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.CheckOK` | per (kind, site, job, attempt) record in a set | **port** | JOB_CP->JOB_SCHED | JOB_CP:1, JOB_SCHED:1, ENV_NET:1 | JOB_SCHED:1 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.Deploy` | per (kind, site, job, attempt) record in a set | **port** | JOB_SCHED->JOB_CP | JOB_SCHED:1, JOB_CP:2, ENV_NET:1 | JOB_CP:2 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.DeployNo` | per (kind, site, job, attempt) record in a set | **port** | JOB_CP->JOB_SCHED | JOB_SCHED:1, JOB_CP:1, ENV_NET:1 | JOB_SCHED:1 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.DeployOK` | per (kind, site, job, attempt) record in a set | **port** | JOB_CP->JOB_SCHED | JOB_SCHED:1, JOB_CP:1, ENV_NET:1 | JOB_SCHED:1 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.HeartbeatStop` | per (kind, site, job, attempt) record in a set | **port** | JOB_SCHED->JOB_CP | JOB_CP:1, JOB_SCHED:1, ENV_NET:1 | JOB_CP:1, JOB_SCHED:1 | Sender guard tests the message is not in flight (dedup on the shared medium). |
| `network.OutcomeAborted` | per (kind, site, job, attempt) record in a set | **port** | JOB_CP->JOB_SCHED | JOB_CP:1, JOB_SCHED:2, ENV_NET:1 | JOB_CP:1, JOB_SCHED:2 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.OutcomeFailed` | per (kind, site, job, attempt) record in a set | **port** | JOB_CP->JOB_SCHED | JOB_CP:1, JOB_SCHED:2, ENV_NET:1 | JOB_CP:1, JOB_SCHED:2 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.OutcomeOK` | per (kind, site, job, attempt) record in a set | **port** | JOB_CP->JOB_SCHED | JOB_CP:1, JOB_SCHED:2, ENV_NET:1 | JOB_CP:1, JOB_SCHED:2 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.Start` | per (kind, site, job, attempt) record in a set | **port** | JOB_SCHED->JOB_CP | JOB_SCHED:1, JOB_CP:2, ENV_NET:1 | JOB_CP:2 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.StartNo` | per (kind, site, job, attempt) record in a set | **port** | JOB_CP->JOB_SCHED | JOB_SCHED:1, JOB_CP:3, ENV_NET:1 | JOB_SCHED:1 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.StartOK` | per (kind, site, job, attempt) record in a set | **port** | JOB_CP->JOB_SCHED | JOB_SCHED:1, JOB_CP:1, ENV_NET:1 | JOB_SCHED:1 | Channel: sender adds, consumer removes (consumption is not a conflicting write). |
| `network.Stop` | per (kind, site, job, attempt) record in a set | **port** | JOB_SCHED->JOB_CP | JOB_CP:1, JOB_SCHED:5, ENV_NET:1 | JOB_CP:1 | Five SCHED senders collapse into one set element per (s,t); VSNetwork sequence keys would make duplicates distinct. |
| `scheduler.current` | SP singleton (one JobRunner.run thread) | **port** | JOB_SCHED | JOB_SCHED:1 | JOB_SCHED:31, JOB_SPENGINE:6 | Read by JOB_SPENGINE spawn steps (CurrentJob) and terminate guards (scheduler.current=j). Becomes the job id carried in SpawnSJ/AbortSJ requests; no direct read needed after the split. |
| `scheduler.pc` | SP singleton (one JobRunner.run thread) | **conflict** | JOB_SCHED | JOB_SCHED:37, JOB_SPENGINE:4 | JOB_SCHED:41, JOB_SPENGINE:7 | One PC for the JobRunner.run thread: scheduler pass, deploy, claim, start, failure cleanup AND the synchronous ServerEngine.start_app_on_server steps (serverSpawn/serverRegister/serverWaiter). Resolve with a call/return port SpawnSJ(j)->SpawnReply(j,ok\|error): JOB_SCHED blocks at pc="serverSpawn"; JOB_SPENGINE keeps its own spawn PC. ServerEngineTerminate* also read pc="failStopWait" (see AbortSJ request). |

Private fields per group:

- `JOB_SCHED` (36): `jobs.abortAck`, `jobs.active`, `jobs.adminRead`, `jobs.archiveFailed`, `jobs.checked`, `jobs.claimEver`, `jobs.completedRemoved`, `jobs.completion`, `jobs.deployed`, `jobs.dispatch`, `jobs.finishStatus`, `jobs.outcomeKey`, `jobs.pending`, `jobs.resurrected`, `jobs.runAborted`, `jobs.running`, `jobs.serverAborted`, `jobs.startClaim`, `jobs.status`, `jobs.terminalPublished`, `rpc.cancel`, `rpc.check`, `rpc.deploy`, `rpc.start`, `scheduler.blockedPending`, `scheduler.candidates`, `scheduler.considered`, `scheduler.cooldown`, `scheduler.count`, `scheduler.failedPending`, `scheduler.history`, `scheduler.issued`, `scheduler.persisted`, `scheduler.result`, `scheduler.returnTo`, `scheduler.scheduled`
- `JOB_SPENGINE` (3): `jobs.serverSpawned`, `jobs.serverTerminated`, `jobs.serverWaiter`
- `JOB_CP` (27): `client.abortRequested`, `client.attached`, `client.binding`, `client.cleanup`, `client.deployed`, `client.exitCode`, `client.exitObserved`, `client.generation`, `client.logical`, `client.pc`, `client.pendingAbort`, `client.rawExit`, `client.ready`, `client.restartAttempts`, `client.restartChecked`, `client.restartSafe`, `client.retryable`, `client.spawned`, `client.terminateRequested`, `client.waiter`, `resourceEnv`, `rm.allocated`, `rm.free`, `rm.payload`, `rm.releases`, `rm.reserved`, `rm.ttl`

## 5. Cross-group and cross-process accesses

Class: (a) encodes a real message/notification/call that the split must make explicit; (b) modelling shortcut or oracle a separated group could not observe; (c) shared clock (none found).

| Id | Scope | Accessor (group) | Field | Kind | Class | What it encodes | Port replacement |
|---|---|---|---|---|---|---|---|
| X1 | cross-process | FederatedServerHeartbeatCleanup (JOB_SCHED) | client.handle | read | a | Heartbeat content: CP heartbeat lists the jobs it still runs (fed_server.py:1013-1026; client/communicator.py:729-754). Seed reads it atomically with no heartbeat message/staleness. | Heartbeat(s, jobsAt(s)) CP->SP |
| X2 | cross-process | ServerEngineResolveMissingOutcome (JOB_SCHED) | client.handle (RegisteredAtSite over all tokens of j) | read | a | Heartbeat job list: SP sees job j absent at site s and resolves the pending outcome (fed_server.py:1054-1103). Atomic, never stale; delayed heartbeat snapshots are an explicit projection boundary in the seed. | Heartbeat(s, jobsAt(s)) CP->SP |
| X3 | cross-process | FederatedServerHeartbeatCleanup (JOB_SCHED) | network.HeartbeatStop absent | read | b | Dedup guard: SP may only re-issue a HeartbeatStop once the previous one was consumed by CP or lost. Not a production guard (periodic heartbeat replies repeat); a state bound on the set network. | drop (sequence-keyed network makes repeats distinct) or keep as explicit bound |
| X4 | cross-process | JobExecutorOutcomeReportReturned (JOB_CP) | network.Outcome* absent | read | a | Encodes the SP reply to the outcome report (fed_server returns OK, or request lost/timeout): CP observes that SP consumed its message. No reply message exists in the seed. | OutcomeReply(s,t) SP->CP, or report-RPC timeout |
| X5 | cross-process | ServerChildFailure (JOB_PROC) | jobs.serverFailed | write | b | SJ exit code written straight into the SP exception record at physical exit, before the SP waiter observes the exit. In code wait_for_complete records it under engine.lock when popping run_processes. | Exit(j, rc) SJ->SPENGINE; record at ObserveExit |
| X6 | cross-process | ServerChildExit, ServerChildFailure (JOB_PROC) | jobs.serverAlive | read+write | a | Physical SJ liveness stored in the SP job record; exit flips it. | PROC-owned sj[j].alive; joint spawn |
| X7 | cross-process | ServerEngineObserveExit (JOB_SPENGINE) | jobs.serverAlive | read | a | process.wait() returning (OS exit notification). | Exit(j, rc) event |
| X8 | cross-process | ClientChildExit (JOB_PROC) | client.alive | read+write | a | Physical CJ liveness stored in the CP executor record. | PROC-owned cj[s][t].alive; joint spawn |
| X9 | cross-process | JobExecutorObserveExitCode, JobExecutorWaitChildExit (JOB_CP) | client.alive | read | a | process.wait() in the cleanup waiter (OS exit notification). | Exit(s,t,g,rc) event |
| X10 | cross-process | JobExecutorObserveExitCode(s,t,rc) (JOB_CP) | rc parameter | choice | b | The CJ return code is chosen nondeterministically by the CP observer (childError fault budget), not produced by the exiting CJ. | rc carried in Exit(s,t,g,rc); produced by CJ runner/trainer |
| X11 | cross-process | JobExecutorNotify{Started,Stopped,Ready}, JobExecutorIgnore{Stale,Stopped}Status (s,t,g) (JOB_CP) | (implicit CJ->CP status message, generation g) | trigger | a | CJ status notifications (training_cmds.py:222-226) with physical launch id g, enabled spontaneously whenever CP holds a handle; no message, no causal link to CJ initialization. | Status(s,t,g,kind) CJ->CP (VS READY on job-control, correlation.launch) |
| X12 | cross-process | ProcessHandleCheckRestart(s,t,safe) (JOB_CP) | safe parameter | choice | b | can_restart result: process group gone AND no detached-trainer bootstrap marker; chosen freely. | Settlement(s,t,g, groupGone, bootstrapMarker) from PROC/trainer |
| X13 | intra-SP cross-group | ServerEngineTerminateAfter{Grace,Exit,AbortCommandError} (JOB_SPENGINE) | jobs.adminPC, scheduler.pc, scheduler.current, jobs.serverStop | read | a | In-process synchronous call engine.abort_app_on_server from stop_run / failure cleanup / fail_run, encoded as reads of the caller PCs. | AbortSJ(j) request SCHED->SPENGINE (+ completion if callers must block) |
| X14 | intra-SP cross-group | ServerEngineSpawnJob, ServerEngineRegisterJob, ServerEngineInstallWaiter, ServerEngineStartupError (JOB_SPENGINE) | scheduler.pc (r/w), scheduler.current | read+write | a | start_app_on_server executes on the JobRunner.run thread; the steps advance the runner PC. | SpawnSJ(j) call / SpawnReply(j, ok\|error) |
| X15 | intra-SP cross-group | 9 JOB_SCHED actions (JOB_SCHED) | jobs.serverRegistered | read | a | engine.run_processes membership read by job_runner (completion select, fail_run activity test, stop/abort, heartbeat). | published registered[j] (read-only port state) |
| X16 | checker artifact | MC faults counters (all) | faults.deployError, faults.preLaunchError, faults.childError | read+write | b | Shared fault budgets: deployError (JobRunnerDeploymentException SCHED + ClientDeployError CP), preLaunchError (ServerEngineStartupError SPENGINE + JobExecutorPrepareException CP), childError (ServerChildFailure PROC + JobExecutorObserveExitCode CP). A fault in one group consumes another group's budget. | per-group fault budgets |

Totals: 12 cross-process accesses (8 class a, 4 class b: X3, X5, X10, X12), 3 intra-SP cross-group accesses, 1 checker artifact (shared fault budgets), 0 shared-clock accesses. Worst for splitting: X2/X1 (SP reads the CP executor registry atomically; drives fail_run via ResolveMissingOutcome and HeartbeatStop), X5 (SJ exit code lands in the SP failure record before the SP waiter observes the exit), X4 (outcome reply inferred from message absence), X11 (CJ status with arbitrary generation and no sender), X10/X12 (exit code and can_restart chosen by the observer).

Timing (class c): rpc deadlines, backoff, TTL scan ticks, outcome/archive grace and both 10 s terminate graces are local untimed crossings. Cross-process relative timing (TTL expiry vs a late START, SP outcome grace vs a slow CP report) is an interleaving over-approximation, so it survives the split as long as no variant adds a timing guard.

## 6. Wire encoding and port mapping

Seed encoding: `network` is a SET of records `Msg(kind, site, job, attempt)` where `<<job, attempt>>` is the per-attempt reservation token (a fresh site-local UUID in code). Duplicate sends of the same record collapse (the five Stop senders, repeated HeartbeatStop); VSNetworkV1 keys messages by `<<RunId, channel, from, sendSeq>>`, so duplicates become distinct messages after mapping. SP waiters are `rpc[s][t].{check,deploy,start,cancel}` in {idle, waiting, ok, no, timeout}; a timeout closes the waiter and never retracts the command; late replies are consumed without effect. Outcome acceptance is keyed by `jobs[j].pending` (site set), not by a waiter. Stop/outcome addressing uses `<<j, scheduler.issued[j]>>` (current attempt).

| Kind | Dir | Meaning | Senders | Consumers | Correlation | VSNetworkV1 |
|---|---|---|---|---|---|---|
| Check | SP->CP | admission resource check/reserve | ServerEngineCheckClientResources | CheckResourceProcessorReserve, CheckResourceProcessorUnavailable | site, job, attempt, waiter rpc[s][t].check | no VSNetworkV1 kind (coarse root omits it; Reserve/abort are spontaneous there) |
| Cancel | SP->CP | cancel reservation (never frees an allocation) | ServerEngineCancelClientResources, JobRunnerFailureCancelResources | CancelResourceProcessorCancel | site, job, attempt, waiter rpc[s][t].cancel | no VSNetworkV1 kind (coarse root omits it; Reserve/abort are spontaneous there) |
| Deploy | SP->CP | deploy app to site | JobRunnerDeployJob | ClientDeploySuccess, ClientDeployError | site, job, attempt, waiter rpc[s][t].deploy | no VSNetworkV1 kind (coarse root omits it; Reserve/abort are spontaneous there) |
| Start | SP->CP | START_JOB (allocate token, launch CJ) | ServerEngineStartClientJob | StartJobProcessorAllocate, StartJobProcessorRejectToken | site, job, attempt, waiter rpc[s][t].start | START_JOB (job-control; correlation.job, body.value=Token(c)) |
| Stop | SP->CP | abort/stop job at site (no reply modelled) | ServerEngineReceiveFailureOutcome, JobRunnerClassifyCompletion, JobCommandAbortRunningSend, JobRunnerFailureSendStop, ServerEngineReceiveAbortedOutcome | ClientEngineAbortApp | site, job, attempt | no VSNetworkV1 kind (coarse root omits it; Reserve/abort are spontaneous there) |
| HeartbeatStop | SP->CP | heartbeat response telling CP to abort a job unknown/failed at SP | FederatedServerHeartbeatCleanup | ClientEngineHeartbeatAbort (absence test: FederatedServerHeartbeatCleanup) | site, job, attempt | no VSNetworkV1 kind (coarse root omits it; Reserve/abort are spontaneous there) |
| CheckOK | CP->SP | reservation made (token, 1 unit, TTL) | CheckResourceProcessorReserve | ServerEngineReceiveCheckOK | site, job, attempt, waiter rpc[s][t].check | no VSNetworkV1 kind |
| CheckNo | CP->SP | no free unit | CheckResourceProcessorUnavailable | ServerEngineReceiveCheckNo | site, job, attempt, waiter rpc[s][t].check | no VSNetworkV1 kind |
| CancelAck | CP->SP | cancel processed | CancelResourceProcessorCancel | ServerEngineReceiveCancelAck | site, job, attempt, waiter rpc[s][t].cancel | no VSNetworkV1 kind |
| DeployOK | CP->SP | deployed | ClientDeploySuccess | ServerEngineReceiveDeployOK | site, job, attempt, waiter rpc[s][t].deploy | no VSNetworkV1 kind |
| DeployNo | CP->SP | deploy error | ClientDeployError | ServerEngineReceiveDeployNo | site, job, attempt, waiter rpc[s][t].deploy | no VSNetworkV1 kind |
| StartOK | CP->SP | CJ launched, waiter installed | StartJobProcessorReplySuccess | ServerEngineReceiveStartOK | site, job, attempt, waiter rpc[s][t].start | no VSNetworkV1 kind |
| StartNo | CP->SP | missing/expired token, returned app error, or rollback after prepare/spawn/waiter failure | StartJobProcessorRejectToken, ClientEngineStartAppReturnedError, StartJobProcessorRollback | ServerEngineReceiveStartNo | site, job, attempt, waiter rpc[s][t].start | no VSNetworkV1 kind |
| OutcomeOK | CP->SP | final outcome report ok | JobExecutorReportOutcome | ServerEngineReceiveOutcome, ServerEngineIgnoreOutcome (absence test: JobExecutorOutcomeReportReturned) | site, job, attempt, pending set jobs[j].pending (accept iff s in pending) | OUTCOME body.status="ok" |
| OutcomeFailed | CP->SP | final outcome report failed | JobExecutorReportOutcome | ServerEngineReceiveFailureOutcome, ServerEngineIgnoreOutcome (absence test: JobExecutorOutcomeReportReturned) | site, job, attempt, pending set jobs[j].pending (accept iff s in pending) | OUTCOME (status failed: not in VS profile) |
| OutcomeAborted | CP->SP | final outcome report aborted | JobExecutorReportOutcome | ServerEngineReceiveAbortedOutcome, ServerEngineIgnoreOutcome (absence test: JobExecutorOutcomeReportReturned) | site, job, attempt, pending set jobs[j].pending (accept iff s in pending) | OUTCOME (status aborted: not in VS profile) |

Implicit wires (no message in the seed):

| Wire | Dir | Meaning | Today encoded by | Consumers | Port |
|---|---|---|---|---|---|
| (implicit) CJ status STARTED/READY/STOPPED | CJ->CP | notify_job_status with physical launch id g (0 = legacy no-id) | (none: spontaneous) | JobExecutorNotifyStarted, JobExecutorNotifyReady, JobExecutorNotifyStopped, JobExecutorIgnoreStaleStatus, JobExecutorIgnoreStoppedStatus | P_CJ (JOB_PROC/CJ-runner -> JOB_CP) |
| (implicit) heartbeat job list | CP->SP | client heartbeat lists running jobs; SP replies HeartbeatStop or resolves missing outcome | (none: SP reads client.handle) | FederatedServerHeartbeatCleanup, ServerEngineResolveMissingOutcome | P_ADMIN |
| (implicit) outcome reply | SP->CP | fed_server ack of outcome report; CP infers return from message absence | (none) | JobExecutorOutcomeReportReturned | P_ADMIN |
| (implicit) CJ spawn / exit | CP<->CJ (OS) | Popen of CJ; process.wait() returns | ProcessJobLauncherSpawn (alive:=TRUE), ClientChildExit (alive:=FALSE) | JobExecutorObserveExitCode, JobExecutorWaitChildExit | P_CJ |
| (implicit) SJ spawn / exit | SP<->SJ (OS) | Popen of SJ; wait_for_complete | ServerEngineSpawnJob (serverAlive:=TRUE), ServerChildExit/ServerChildFailure | ServerEngineObserveExit | P_SJ |
| (in-process) start_app_on_server | SCHED->SPENGINE | synchronous call on runner thread | JobRunnerPersistDeploy (pc:=serverSpawn) | ServerEngineSpawnJob, ServerEngineStartupError | P_SJAPI SpawnSJ/SpawnReply |
| (in-process) abort_app_on_server | SCHED->SPENGINE | stop_run/_stop_run from admin abort, startup failure and fail_run | JobCommandAbortRunningSend (adminPC:=stopWait), JobRunnerFailureSendStop (pc:=failStopWait), JobRunnerFailureStop/JobCommandAbortRunning/outcome receivers (serverStop) | ServerEngineTerminateAfterGrace, ServerEngineTerminateAfterExit, ServerEngineTerminateAfterAbortCommandError | P_SJAPI AbortSJ |
| (in-process) run_processes / exception_run_processes | SPENGINE<->SCHED | registry membership and authoritative exit/failure code under engine.lock | ServerEngineRegisterJob, ServerEngineObserveExit, ServerEngineRemoveAfterTerminate, ServerChildFailure, ServerEngineReceive{Failure,Aborted}Outcome, ServerEngineResolveMissingOutcome | JobRunnerSelectCompletion, JobRunnerOutcomesResolved, JobRunnerClassifyCompletion, FederatedServerHeartbeatCleanup, JobRunnerFailureStop, JobRunnerFailureSendStop, JobCommandAbortRunning(Send) | P_SJAPI published state |
| (in-process) JOB_STARTED / JOB_ABORTED / JOB_COMPLETED events | SCHED internal | synchronous scheduler membership update (event.py) | runner pc=startedEvent/failEvent, completion abortedEvent/completedEvent | DefaultJobSchedulerJobStarted, DefaultJobSchedulerJobAbortedOnStartFailure, DefaultJobSchedulerJobAbortedOnCompletion, DefaultJobSchedulerJobCompleted | internal to JOB_SCHED (would be a synchronous port if admission were split; CR-5 lives here) |

Port names used below: **P_ADMIN** (SP JOB_SCHED <-> CP JOB_CP over the network: the 16 message kinds plus explicit Heartbeat and OutcomeReply), **P_SJAPI** (in-process JOB_SCHED <-> JOB_SPENGINE: SpawnSJ/SpawnReply, AbortSJ, published `registered[j]`, exception record), **P_SJ** (JOB_SPENGINE <-> JOB_PROC SJ: joint Spawn, Exit(j, rc)), **P_CJ** (JOB_CP <-> JOB_PROC CJ: joint Spawn(s,t,g,binding), Exit(s,t,g,rc), Status(s,t,g,kind), Settlement(s,t,g,safe)).

## 7. Environment abstractions inside the seed

| Id | Seed element | Stands for | Current behaviour | Should be driven by (integrated) | Port |
|---|---|---|---|---|---|
| E1 | Init: jobs = SUBMITTED for all Jobs; JobOrder fixed | job submission workload (submit_job via admin API, job store) | finite workload present before the scheduler starts; no later submissions | configuration/submission neighbour (NVConfig / admin SDK); integrated root supplies job ids and per-site deploy map | Submit(j, deployMap, resourceSpec) |
| E2 | ClientChildExit(s,t) | CJ process exits (normal end after END_RUN, response to abort/terminate, crash) | enabled any time while alive; independent of terminateRequested, READY or workflow progress | fedavg CJ runner (ReceiveEndRun -> StopClientRunner -> exit) plus terminate/abort; trainer settlement for external trainers | P_CJ Exit(s,t,g,rc) |
| E3 | ServerChildExit(j) / ServerChildFailure(j) | SJ process exits normally / with failure | enabled any time while alive, also before START replies, READY or any workflow step | fedavg SJ runner (WorkflowDone, END_RUN sent to all CJ -> SJ exit), abort_app_on_server terminate | P_SJ Exit(j, rc) |
| E4 | JobExecutorNotify{Started,Ready,Stopped}, Ignore{Stale,Stopped}Status with free g | CJ status notifications carrying physical launch id | spontaneous whenever CP holds a handle; any generation 0..LaunchSlots (stale and legacy included); READY not tied to CJ initialization | fedavg CJ runner (InitializeRunner/RunnerReady/SendReady), network delay for stale generations | P_CJ Status(s,t,g,kind) / VS READY |
| E5 | JobExecutorObserveExitCode rc in {ok,generic,failed,aborted} | CJ return code (job/trainer outcome, infrastructure failure, abort) | chosen by CP at wait; failure codes fault-bounded by childError | CJ runner/trainer outcome (fedavg client result, payload/trainer seed), abort path | rc in P_CJ Exit |
| E6 | ProcessHandleCheckRestart safe in BOOLEAN | ProcessHandle.can_restart: process group gone and no detached-trainer bootstrap marker | free choice | payload/trainer seed (detached trainer bootstrap ownership) and backend settlement evidence | P_CJ Settlement(s,t,g,safe) |
| E7 | ClientDeploySuccess / ClientDeployError; server deploy in JobRunnerDeployJob | workspace deployment (contents not modelled); server resources sufficient | per-site DeployOK or DeployNo; server-side deploy always succeeds except DeploymentException | config/deploy neighbour | Deploy/DeployOK/DeployNo |
| E8 | JobCommandAbortRead(j) (adminAbort budget) | user/SDK abort_job (Session.abort_job retries busy for 30 s) | at most AdminAbortLimit attempts globally; each attempt independent | admin/SDK neighbour (logical caller op + retry attempts) | AbortJob(j) request / busy\|ok\|error reply |
| E9 | TransportLoseMessage(m) | request/reply loss | any message in the set, LossLimit | VSNetworkV1 delivery/drop (sequence-keyed) | ENV_NET |
| E10 | Admin*Timeout, DefaultJobSchedulerBackoffElapsed, AutoCleanResourceManagerTick, JobRunnerOutcomeGraceExpired, JobRunnerArchiveGraceExpired, ServerEngine/JobExecutor TerminateAfterGrace | local clocks / deadline crossings | untimed, each group-local; no shared clock variable | stay group-local (no neighbour); relative timing across processes (TTL vs START delay, outcome grace vs CP report) is an untimed over-approximation | none |
| E11 | Store/archive/deploy/spawn/waiter/report faults (MC fault wrappers) | storage service, archive service, OS/thread failures | global fault counters, some shared across groups | group-local fault budgets; storage neighbour for CR-5/TV-2 | none |
| E12 | FederatedServerHeartbeatCleanup / ServerEngineResolveMissingOutcome reading client.handle | periodic CP heartbeat with its job list | SP reads CP registry directly, never stale | JOB_CP heartbeat sender (communicator) once split | P_ADMIN Heartbeat(s, jobsAt(s)) |
| E13 | absence of workflow/task progress | everything between READY and exit (FedAvg rounds, task pulls, result transfer) | not modelled; exits are spontaneous | fedavg seed (VSComposition W02-W09) and payload seed (W04-W06) | READY consumer (trainer admission gate) and exit producers |
| E14 | resourceEnv[s] only written by ListResourceConsumerConsume | CP process environment (CUDA_VISIBLE_DEVICES) | other env writers/overrides absent; restart re-snapshots without re-consume | config neighbour (study/runtime env overrides) if integrated | none (CP-internal) |

## 8. Ports and coarse-variant obligations per group

### JOB_SCHED

- Sends: Check(s,<<j,n>>) to all Sites; Cancel(s,tok) to dispatch (no_resource, admission error, startup failure); Deploy(s,tok) to dispatch; Start(s,tok) to deployed; Stop(s,<<j,issued[j]>>) to deployed (admin abort RUNNING, startup failure after SJ registered, accepted Failed/Aborted outcome while SJ registered, completion with a failure record serverFailed); HeartbeatStop(s,tok) when CP still lists the token but SP has no registered SJ and no outcome key (or a failure record); SpawnSJ(j) [in-process]; AbortSJ(j) [in-process]
- Consumes: CheckOK/CheckNo, DeployOK/DeployNo, StartOK/StartNo, CancelAck (waiter; late replies discarded after timeout); OutcomeOK/OutcomeFailed/OutcomeAborted (accepted iff s in pending, else ignored); SpawnReply(j, ok|error); Heartbeat(s, jobsAt(s)) [implicit today: reads client.handle]
- Reads foreign state today: jobs.serverRegistered (JOB_SPENGINE); client.handle (JOB_CP, heartbeat); jobs.serverFailed shared with JOB_PROC/SPENGINE
- Publishes: jobs.status / terminalPublished (job metadata; VS terminal); scheduler.scheduled; jobs.serverStop, jobs.adminPC, scheduler.pc, scheduler.current (read by SPENGINE until replaced by AbortSJ/SpawnSJ)
- A coarse variant must still reproduce on its ports: fresh token per scheduling attempt; several attempts for one job reach the same site (stale earlier-attempt reservations must still be possible); Check broadcast, then possibly no Start at all (CANT_SCHEDULE, no_resource, abort, deploy failure) so reservations are left to TTL expiry or Cancel; Start arbitrarily late after CheckOK (expiry window) and only to deployed sites; never a second fresh-token Start for a running job; timeouts close waiters without retracting commands; late replies are tolerated; Stop at any time after Start for abort/failure, including while the CP is still STARTING; HeartbeatStop for jobs not registered at SP; outcome handling: accept once per pending site, ignore unknown, failure/aborted while active clears pending and sends Stop, missing outcome resolved by heartbeat or grace; MaxJobs concurrent tokens at a CP; SpawnSJ may be skipped (startup failure before spawn) and AbortSJ may be requested.
- Fine failure outcomes to preserve as port-visible effects: CANT_SCHEDULE (Exhausted -> PersistBlocked); no_resource -> Cancel + backoff retry; admission exception -> Cancel + recovery/history fallback; deploy exception / DeployNo / deploy timeout -> FAILED_TO_RUN (+Cancel); spawn failure (SpawnReply error) -> FAILED_TO_RUN; StartNo/start timeout (strict or no OK site) -> FAILED_TO_RUN + Stop if registered; store error at DISPATCHED/RUNNING write -> failure path; pre-run abort -> ABORTED, claim rejected, no Start; busy abort while claim held; running abort -> Stop + AbortSJ + ABORTED; outcome grace expiry; archive failure/retry/grace; terminal store exception retry.

### JOB_SPENGINE

- Sends: SpawnReply(j, ok|error); published registered[j] (run_processes); SJ exit code into exception record (joint with ObserveExit after the split); Spawn(j) to JOB_PROC (joint)
- Consumes: SpawnSJ(j); AbortSJ(j) (from admin stopWait, failStopWait, serverStop); Exit(j, rc) from JOB_PROC
- Reads foreign state today: scheduler.pc/current, jobs.adminPC, jobs.serverStop (JOB_SCHED; replace by SpawnSJ/AbortSJ); jobs.serverAlive (JOB_PROC)
- Publishes: jobs.serverRegistered; jobs.serverSpawned (VS serverLaunched)
- A coarse variant must still reproduce on its ports: spawn can fail (before any SJ exists); after a successful spawn the registry entry can disappear at any later point (SJ exit) -- in particular before the runner writes RUNNING and before client outcomes arrive (MC-4 window); termination occurrence is not physical exit; the registry can be removed after terminate while the SJ is still alive (CR-2 boundary); abnormal SJ exit yields a failure code unless fail_run already recorded one (precedence).
- Fine failure outcomes to preserve as port-visible effects: ServerEngineStartupError; ServerChildFailure (via PROC); TerminateAfterAbortCommandError.

### JOB_CP

- Sends: CheckOK/CheckNo, CancelAck, DeployOK/DeployNo, StartOK/StartNo; Outcome{OK,Failed,Aborted}(s,t) once per token after final exit; Heartbeat(s, jobsAt(s)) [implicit]; Spawn(s,t,g,binding) to JOB_PROC (joint)
- Consumes: Check, Cancel, Deploy, Start, Stop, HeartbeatStop; Status(s,t,g,kind) and Exit(s,t,g,rc), Settlement(s,t,g,safe) from JOB_PROC [implicit today]; OutcomeReply [implicit: message absence]
- Reads foreign state today: client.alive (JOB_PROC); network absence of own Outcome message (X4)
- Publishes: client.handle (heartbeat registry); rm.* capacity (via CheckOK/CheckNo only)
- A coarse variant must still reproduce on its ports: CheckOK and CheckNo both possible; capacity returns only after free; a CheckOK reservation can expire so a later Start gets StartNo; Cancel never frees an allocation; StartOK then exactly one eventual outcome report, or a report failure/loss with the job later absent from heartbeat; StartNo after a spawn (MC-2): child still running, still listed in heartbeat, no outcome report, unit freed and reusable by the next Check; StartOK can follow a Stop consumed during STARTING (pending abort); Stop/HeartbeatStop lead to abort, eventual exit and an Aborted/Failed/OK report; restart keeps the token/allocation, emits one final report, may expose READY again for a new generation; outcome kind from exit code: generic rc -> Failed unless abort was requested or the CJ already reported STOPPED (then OK); failed -> Failed; aborted -> Aborted; ok -> OK.
- Fine failure outcomes to preserve as port-visible effects: CheckNo; StartNo via RejectToken (expired/cancelled/missing token); ClientEngineStartAppReturnedError; PrepareException/SpawnException/WaiterInstallationException -> Rollback (+StartNo); abort while STARTING (pending abort); abnormal exit -> restart (eligible) or Failed report; RestartException -> Failed report; OutcomeReportException (no report); reservation expiry.

### JOB_PROC

- Sends: Exit(j, rc) / Exit(s,t,g,rc); Status(s,t,g,STARTED|READY|STOPPED) [implicit]; Settlement(s,t,g,safe) [implicit]
- Consumes: Spawn(j) from JOB_SPENGINE, Spawn(s,t,g,binding) from JOB_CP (joint); terminate requests (no physical effect in the seed)
- Reads foreign state today: jobs.serverAlive / client.alive are stored in SP/CP records
- Publishes: sj[j].alive, cj[s][t].alive (today jobs.serverAlive, client.alive)
- A coarse variant must still reproduce on its ports: CJ/SJ exit at any time after spawn, including before READY/StartOK (early crash) and never-forced (children may outlive rollback, MC-2); failure and aborted exit codes; stale (old-generation) and legacy (g=0) status after replacement; STOPPED followed by late READY; in integrated mixes: READY only after CJ runner init, exits after END_RUN/workflow done (replace with fedavg runner groups).
- Fine failure outcomes to preserve as port-visible effects: ServerChildFailure; CJ failed/aborted/generic exit.

### ENV_NET

- Sends: -
- Consumes: any message
- A coarse variant must still reproduce on its ports: loss of any request/reply/outcome/stop.
- Fine failure outcomes to preserve as port-visible effects: loss.

## 9. Properties: local vs spanning

`groups` = owners of the fields the property reads; `depends on` = groups whose behaviour can make it fail or is needed for it to hold (triggers, fairness).

| Property | Module | Kind | Enabled in | Fields | Groups (state) | Depends on | Note |
|---|---|---|---|---|---|---|---|
| `TypeOK` | base.tla | safety | MCTypeOK in MC.cfg (hunt cfgs omit it) | all variables | JOB_SCHED, JOB_SPENGINE, JOB_CP, JOB_PROC, ENV_NET | JOB_SCHED, JOB_SPENGINE, JOB_CP, JOB_PROC, ENV_NET | Structural; splits into per-group TypeOK conjuncts by variable (scheduler/jobs/rpc -> SP groups; rm/client/resourceEnv -> CP; network shared). |
| `ResourceConservation` | base.tla | safety | all MC/hunt/Update/Trace cfgs | rm.allocated, rm.free, rm.reserved | JOB_CP | JOB_CP | Group-local to JOB_CP (RM deque + token maps). Survives any SCHED variant; coarse CP must keep it. |
| `ProcessBindingMatchesOwnership` | base.tla | safety | MC_hunt_s1_* | client.alive, client.binding, rm.allocated | JOB_CP, JOB_PROC | JOB_CP, JOB_PROC, JOB_SCHED | CP + PROC (alive). CR-1/MC-8 shared-environment race is CP-internal (Consume vs SnapshotEnvironment, restart re-snapshot). Needs PROC to keep children alive concurrently. |
| `NoFreeWhileInUse` | base.tla | safety | MC_hunt_s1_*, s2_cleanup_handoff, s4_exit_cleanup | client.alive, client.binding, rm.allocated, rm.free, rm.reserved | JOB_CP, JOB_PROC | JOB_CP, JOB_PROC, JOB_SCHED | CP + PROC (alive). MC-2 mechanism (rollback after spawn) CP-internal; needs PROC not to force early exit and SCHED to send Start. |
| `CleanupOwnerOrCompleted` | base.tla | safety | MC_hunt_s2_*, s4, s5 | client.alive, client.cleanup, client.pc, client.waiter, rm.allocated, rm.payload | JOB_CP, JOB_PROC | JOB_CP, JOB_PROC, JOB_SCHED | CP + PROC (alive). Cleanup-handoff (MC-2) inside CP. |
| `AcceptedPreRunAbortPersists` | base.tla | safety | MC_hunt_s3_abort_status, all Update cfgs | jobs.abortAck, jobs.status | JOB_SCHED | JOB_SCHED | JOB_SCHED-local (status store, abortAck). MC-3 lineage and CANT_SCHEDULE/ABORTED writers all in SCHED. |
| `NoTerminalResurrection` | base.tla | safety | MC_hunt_s3_terminal_status | jobs.resurrected | JOB_SCHED | JOB_SCHED, JOB_SPENGINE, JOB_PROC | JOB_SCHED-local field, but MC-4 trigger needs SJ exit (PROC) + registry removal (SPENGINE) before WriteRunning: cross-group interaction obligation on coarse SPENGINE/PROC. |
| `SchedulerCapacity` | base.tla | safety | all MC cfgs | scheduler.scheduled | JOB_SCHED | JOB_SCHED | JOB_SCHED-local. |
| `RetryHistoryMatchesCount` | base.tla | safety (historical diagnostic) | none | scheduler.count, scheduler.history | JOB_SCHED | JOB_SCHED | JOB_SCHED-local. |
| `RetryHistoryNotAhead` | base.tla | safety | all MC cfgs | scheduler.count, scheduler.history | JOB_SCHED | JOB_SCHED | JOB_SCHED-local. |
| `SingleSupportedStart` | base.tla | safety | all MC cfgs | client.spawned | JOB_CP | JOB_CP, JOB_SCHED | JOB_CP-local fields (spawned per token; CP blocks a second start only while the first token is registered). Holds because JOB_SCHED sends Start for at most one attempt per job (status leaves SUBMITTED at claim): coarse SCHED must keep one Start-bearing attempt per job. |
| `WaitBeforeNormalFree` | base.tla | safety | all MC cfgs | client.cleanup, client.exitObserved | JOB_CP | JOB_CP | JOB_CP-local. |
| `PendingCompletionRemoval` | base.tla | diagnostic (TV-3) | none | jobs.completion, jobs.running | JOB_SCHED | JOB_SCHED | JOB_SCHED-local. |
| `OtherEligibleJobProgress` | base.tla | liveness | MC_hunt_s5 (with MCFairSpec) | jobs.status, scheduler.considered, scheduler.cooldown, scheduler.count, scheduler.issued, scheduler.scheduled | JOB_SCHED | JOB_SCHED, JOB_SPENGINE, JOB_CP, ENV_NET | Stated on SCHED fields, but the scheduler pass shares the runner thread: progress needs CP replies (rpc timeouts are fault-bounded, not fair), SJ spawn and start completion: spans SCHED+SPENGINE+CP under fairness. |
| `CleanupEventuallyReleased` | base.tla | liveness | MC_hunt_s5 | client.cleanup, client.waiter, rm.allocated | JOB_CP | JOB_CP, JOB_PROC | Stated on CP fields; needs PROC CJ exit fairness (ClientChildExit WF) -> spans CP+PROC. |
| `ReservationEventuallyResolved` | base.tla | liveness | MC_hunt_s5 | rm.reserved | JOB_CP | JOB_CP | CP-local under TTL-tick fairness (expiry drains every reservation regardless of SP). |
| `StartClaimExcludesAcceptedAbort` | Update.tla | safety | Update_* | jobs.abortAck, jobs.claimEver | JOB_SCHED | JOB_SCHED | JOB_SCHED-local (U2). |
| `ReplacementRetainsAllocation` | Update.tla | safety | Update_* | client.cleanup, client.generation, rm.allocated, rm.payload | JOB_CP | JOB_CP, JOB_PROC | JOB_CP-local (U3/U4). |
| `ReadinessAndReplacement` | Update.tla | safety | Update_* | client.ready, client.restartAttempts | JOB_CP | JOB_CP, JOB_PROC | JOB_CP-local (U3); READY trigger from PROC/CJ runner. |
| `RetryBookkeepingProgress` | Update.tla | safety | Update_* | scheduler.count, scheduler.history | JOB_SCHED | JOB_SCHED | JOB_SCHED-local (U1). |
| `NoStartClaimWitness` | Update.tla | reachability canary | Update_witness_start_claim | jobs.claimEver | JOB_SCHED | JOB_SCHED | JOB_SCHED-local witness. |
| `NoReadyReplacementWitness` | Update.tla | reachability canary | Update_witness_restart*, ReplayedMC_witness | client.generation, client.ready | JOB_CP | JOB_CP, JOB_PROC | JOB_CP fields; needs PROC exit with retryable rc + safe restart + READY from new generation: spans CP+PROC. |
| `NoAdmissionRecoveryWitness` | Update.tla | reachability canary | Update_witness_admission | scheduler.history | JOB_SCHED | JOB_SCHED | JOB_SCHED-local witness. |
| `MessageBound` | MC.tla | state constraint | all MC cfgs | network | JOB_SCHED, JOB_CP, ENV_NET | JOB_SCHED, JOB_CP | Global bound on the shared message set; must become a per-port bound or stay a root constraint. |
| `MCSymmetry` | MC.tla | symmetry | MC cfgs | Sites | JOB_SCHED, JOB_SPENGINE, JOB_CP, JOB_PROC, ENV_NET | JOB_SCHED, JOB_SPENGINE, JOB_CP, JOB_PROC, ENV_NET | Permutes sites in every group consistently; port messages carry site ids, so symmetry must be applied at the mix root. |
| `VSJobInterface!Safety` | VSJobInterface.tla | coarse interface safety | JobRefinement refinement.cfg (MappedSafety) | jobI.* | JOB_CP, JOB_SCHED, JOB_SPENGINE, JOB_PROC | JOB_CP, JOB_SCHED, JOB_SPENGINE, JOB_PROC | Abs mixes groups: reserved/allocated/launched/readyNotification/exited/reported/frees <- CP; outcomeSeen <- CP.reported minus SCHED pending; terminal <- SCHED; serverLaunched <- SPENGINE; serverExited <- SPENGINE+PROC. Must be split into per-group port projections before per-group refinement checks. |
| `VSComposition NoFreeBeforeTerminal (witness)` | VSComposition.tla | expected-reachable witness | VS checks | jobState.frees, jobState.terminal | JOB_CP, JOB_SCHED | JOB_CP, JOB_SCHED | CP free and SP terminal publication must remain independently ordered in every mix (no coarse variant may add free-after-terminal coupling). |
| `VSComposition NoPullBeforeReadyNotification (witness)` | VSComposition.tla | expected-reachable witness | VS checks | rpcState.task, jobState.readyNotification | JOB_CP, fedavg CJ runner | JOB_CP, fedavg CJ runner | CJ may pull a task before CP observes READY: CP READY receipt must not gate the CJ runner. |

Behaviourally local (can be checked on one group with a chaotic/coarse environment): `ResourceConservation`, `AcceptedPreRunAbortPersists`, `SchedulerCapacity`, `RetryHistoryMatchesCount`, `RetryHistoryNotAhead`, `WaitBeforeNormalFree`, `PendingCompletionRemoval`, `ReservationEventuallyResolved`, `StartClaimExcludesAcceptedAbort`, `RetryBookkeepingProgress`, `NoStartClaimWitness`, `NoAdmissionRecoveryWitness`. All others need the named neighbours or the mix root.

## 10. Relation to the vertical-slice coarse interface

`VSJobInterface` is one record for the whole job seed, and `JobRefinement.Abs` reads every group: it cannot serve as a per-group coarse variant until it is split into per-group projections. `outcomeSeen` is the worst case: it is computed as `Reported` (CP `client.cleanup`) minus SP `jobs.pending`, so the per-group map must give SCHED an own "accepted outcome from c" set. The coarse root also has no CHECK/CANCEL/DEPLOY/STOP/HEARTBEAT kinds: `Reserve(c)` is spontaneous there, so a mix with fine JOB_CP and coarse JOB_SCHED needs those kinds added to the network vocabulary.

| VS action | Group | Fine actions (JobRefinement Abs field) |
|---|---|---|
| Reserve(c) | JOB_CP | CheckResourceProcessorReserve (triggered by SCHED Check) (`rm.reserved`) |
| ServerLaunch | JOB_SPENGINE | ServerEngineSpawnJob (`jobs.serverSpawned`) |
| SendStart(c) | JOB_SCHED | ServerEngineStartClientJob (`network.Start`) |
| Allocate(c,k) | JOB_CP | StartJobProcessorAllocate (`rm.allocated`) |
| Launch(c) | JOB_CP (+JOB_PROC birth) | ProcessJobLauncherSpawn (`client.spawned`) |
| InitializeRunner/RunnerReady/SendReady(c) | fedavg CJ runner (replaces JOB_PROC status env) | none in seed (`-`) |
| ReceiveReady(c,k) = J!ReadyNotification | JOB_CP | JobExecutorNotifyReady(s,t,1) (`client.ready`) |
| SendEndRun/ReceiveEndRun/StopClientRunner(c) | fedavg SJ/CJ runner | none in seed (stand-in: spontaneous ClientChildExit) (`-`) |
| ObserveChildExit(c) = J!ObserveExit | JOB_CP after JOB_PROC exit | ClientChildExit + JobExecutorObserveExitCode + JobExecutorWaitChildExit (`client.exitObserved`) |
| ServerExit = J!ServerExit | JOB_PROC (SJ) observed by JOB_SPENGINE | ServerChildExit (+ServerEngineObserveExit) (`jobs.serverAlive`) |
| ReportOutcome(c) | JOB_CP | JobExecutorReportOutcome (`client.cleanup=reportWait`) |
| ObserveOutcome(c,k) | JOB_SCHED | ServerEngineReceiveOutcome (`jobs.pending`) |
| OutcomeReportReturned(c) | JOB_CP | JobExecutorOutcomeReportReturned (`client.cleanup=free`) |
| FreeAllocation(c) | JOB_CP | JobExecutorFreeAfterExit (`rm.releases`) |
| FinalizeJob | JOB_SCHED | JobRunnerPublishTerminal (`jobs.terminalPublished`) |

JobRefinement is restricted to the success profile (one token, one unit, no faults/restarts, exits ordered by added guards such as `client.ready /\ pc="returned"` before `ClientChildExit` and `jobs.running` before `ServerChildExit`). Those added guards are exactly the environment ordering that JOB_PROC must expose as a schedule assumption, not as a group guard.

## 11. Hardest problems for the split

1. `scheduler.pc` is one PC for scheduler pass, deploy, claim, start, failure cleanup and the synchronous `start_app_on_server` steps. JOB_SPENGINE needs a call/return port (SpawnSJ -> SpawnReply) and the runner must stay blocked in between, otherwise the call's interleaving points change.
2. `jobs.serverFailed` (engine.exception_run_processes) is written by SJ exit, by fail_run from outcome receivers and by heartbeat resolution, with source-defined precedence under engine.lock (wait_for_complete defers to an existing fail_run record; fail_run overwrites except over INFRASTRUCTURE_ERROR, and does not replace an existing code with ABORTED). Recording the SJ code at ObserveExit must be atomic with the registry pop (joint step); a separate consume step lets `JobRunnerSelectCompletion` classify COMPLETED in between. The seed already over-approximates by setting it at physical exit.
3. MC-4 is SCHED-internal but triggered through SPENGINE/PROC: every coarse SPENGINE/PROC must allow SJ exit and registry removal right after waiter installation, before `JobRunnerWriteRunning`. A coarse SJ that only exits after `running`/workflow completion hides MC-4.
4. Spawn creates liveness in another group (`client.alive`, `jobs.serverAlive`): needs a joint CP/PROC (SPENGINE/PROC) step because Popen returns a live child. Terminate requests have no physical effect in the seed; exit is always spontaneous.
5. Heartbeat is not a message: SP reads `client.handle` across processes (X1, X2), atomically and never stale. Making it explicit adds a periodic CP->SP message with a job list and staleness that the fine seed does not have (new behaviours, e.g. ResolveMissingOutcome on a stale list); keeping it as a read breaks port-only communication.
6. Outcome return is inferred from message absence (X4). An explicit OutcomeReply plus report-RPC timeout must reproduce both "consumed by SP" and "lost" cases.
7. CJ status, exit code and can_restart evidence are chosen inside JOB_CP actions (X10-X12) and must move to P_CJ with the generation id. Stale-generation READY after replacement (U3) then requires delayed Status messages, not free choices.
8. The set-based network collapses duplicate Stop/HeartbeatStop sends and dedups HeartbeatStop by absence test (X3). Moving to sequence-keyed VSNetworkV1 messages multiplies states and needs a decision on per-port buffer bounds (MessageBound is global today).
9. MC fault budgets are shared across groups (deployError SCHED+CP, preLaunchError SPENGINE+CP, childError PROC+CP): mixes need per-group budgets, which changes which fault combinations are reachable relative to the reference MC.
10. Admission cannot be split from the runner without turning the non-CAS status store, the cancel waiter and synchronous membership events (CR-5 boundary) into shared ports (8 conflicts). JOB_SCHED is therefore large (79 actions), and its coarse variant carries most of the state-space savings.

