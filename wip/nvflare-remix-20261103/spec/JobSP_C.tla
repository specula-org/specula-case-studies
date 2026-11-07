------------------------------ MODULE JobSP_C ------------------------------
\* Group JobSP, COARSE variant. Process: SP. (Seed JOB_SCHED + JOB_SPENGINE.)
\* Mechanisms: scheduler admission (resource check / cancel / CANT_SCHEDULE),
\* job runner deploy, start claim, DISPATCHED/RUNNING metadata (non-CAS),
\* SJ spawn/registration/exit observation/termination, admin abort command,
\* client outcome receipt, heartbeat reconciliation, completion thread
\* (outcome wait, grace, classification, archive, terminal publication).
\* Writes: jobSP_c, pJobSP, net (sender SP).
\* Anchors: job_scheduler.py:119-430; job_runner.py:136-142,204-589,687-933;
\*          server_engine.py:180-235,322-410,1007-1108; job_cmds.py:1078-1101;
\*          fed_server.py:943-961,1013-1103; job_def_manager.py:459-481.
\* Coarse merges (all port-invisible): admin request waiters (replies are read,
\* not consumed; timeouts are a fault branch), the scheduler pass/retry
\* bookkeeping, deployment evaluation + start claim (into WriteDispatched; the
\* abort command may always find the claim busy), persist-deploy, SJ
\* registration/waiter/pending setup (into Spawn), every startup-failure
\* decision (into Fail), JOB_STARTED/JOB_ABORTED events, outcome-wait vs
\* classify, archive retry/grace, admin acknowledgements, the SJ terminate
\* guards (any stop request implies an ABORT_JOB was sent).
EXTENDS Ports
VARIABLE jobSP_c

InitValue == [handled |-> {}, stage |-> "init",
              registered |-> FALSE, terminated |-> FALSE, running |-> FALSE,
              pending |-> {}, active |-> Sites, outcomeKey |-> FALSE, failed |-> FALSE,
              sAborted |-> FALSE, runAborted |-> FALSE,
              completion |-> "idle", finish |-> "COMPLETED",
              adminPC |-> "idle", aborts |-> 0, shut |-> "none", shutStopped |-> FALSE]
Init == jobSP_c = InitValue

S == jobSP_c
Cmd(kind, c) == Msg(kind, SP, CP(c), <<JobId, c>>, None)
CmdAll(kind, cs) == SendAll(net, {Cmd(kind, c) : c \in cs})
\* ABORT_JOB / CANCEL_RESOURCES carry their sender path (each sends at most once).
CmdAllS(kind, cs, src) == SendAll(net, {Msg(kind, SP, CP(c), <<JobId, c, src>>, None) : c \in cs})
\* HEARTBEAT_STOP: periodic heartbeat replies; a second copy only matters
\* under loss (seq 2), and the sender never reads loss marks.
HBStopKey(c, n) == MsgKey("HEARTBEAT_STOP", SP, CP(c), <<JobId, c, n>>)
HBStopFree(c) == HBStopKey(c, 1) \notin DOMAIN net
                 \/ ("netLoss" \in Faults /\ HBStopKey(c, 2) \notin DOMAIN net)
HBStopMsg(c) == Msg("HEARTBEAT_STOP", SP, CP(c),
                    <<JobId, c, IF HBStopKey(c, 1) \notin DOMAIN net THEN 1 ELSE 2>>, None)
\* Admin request replies are not consumed by coarse: it reads which replies
\* exist (a superset of what the fine waiters received; timeouts are faults).
RepKey(kind, c) == MsgKey(kind, CP(c), SP, <<JobId, c>>)
Rep(kind, c, b) == RepKey(kind, c) \in DOMAIN net /\ net[RepKey(kind, c)].msg.body = b
AllRep(kind, b) == \A c \in Sites : Rep(kind, c, b)
SomeRep(kind, b) == \E c \in Sites : Rep(kind, c, b)
SetStatus(st) == [pJobSP EXCEPT !.status = st, !.terminal =
                    IF st \in JobTerminalStatuses THEN TerminalClass(st) ELSE @]
SJDown == pJobSP.sjLaunched /\ (pJobSP.sjKilled \/ SJExitCode /= "none")
SJCrashed == pJobSP.sjKilled \/ SJExitCode \notin {"none", "exited"}
Stops(cs) == [pJobSP EXCEPT !.abortSent = @ \cup cs]
\* Latest CP job listing from heartbeats (0 = not listed yet; loss ignored).
HBView(c) == LET ps == {ph \in {2, 3} : MsgKey("HEARTBEAT", CP(c), SP, <<JobId, c, ph>>) \in DOMAIN net}
             IN IF ps = {} THEN 0 ELSE IF 3 \in ps THEN 3 ELSE 2

\* ---------------- runner thread (scheduler + JobRunner.run)
SendCheck ==
    /\ S.stage = "init"
    /\ net' = CmdAll("CHECK_RESOURCES", Sites)
    /\ jobSP_c' = [S EXCEPT !.stage = "check"]
    /\ UNCHANGED pJobSP

\* no_resource / reply timeout / admission exception: cancel the reservations
\* the waiter saw (any subset of the ok replies).
AdmitCancel ==
    /\ S.stage = "check"
    /\ SomeRep("RESOURCES_OK", "no") \/ "rpcTimeout" \in Faults \/ "admissionError" \in Faults
    /\ \E D \in SUBSET {c \in Sites : Rep("RESOURCES_OK", c, "ok")} :
          net' = CmdAllS("CANCEL_RESOURCES", D, "admit")
    /\ jobSP_c' = [S EXCEPT !.stage = "blocked"]
    /\ UNCHANGED pJobSP

\* Retry budget exhausted: CANT_SCHEDULE (written without CAS).
Blocked ==
    /\ S.stage = "blocked"
    /\ pJobSP' = SetStatus("CANT_SCHEDULE")
    /\ jobSP_c' = [S EXCEPT !.stage = "idle"]
    /\ UNCHANGED net

DeploySend ==
    /\ S.stage = "check" /\ AllRep("RESOURCES_OK", "ok")
    /\ net' = CmdAll("DEPLOY_JOB", Sites)
    /\ jobSP_c' = [S EXCEPT !.stage = "deploy"]
    /\ UNCHANGED pJobSP

\* Deployment evaluated, start claim taken (status still SUBMITTED), DISPATCHED.
WriteDispatched ==
    /\ S.stage = "deploy" /\ AllRep("DEPLOY_REPLY", "ok") /\ pJobSP.status = "SUBMITTED" /\ ~pJobSP.deleted
    /\ pJobSP' = SetStatus("DISPATCHED")
    /\ jobSP_c' = [S EXCEPT !.stage = "spawn"]
    /\ UNCHANGED net

\* start_app_on_server: spawn SJ, register run_processes, waiter, pending outcomes.
Spawn ==
    /\ S.stage = "spawn"
    /\ pJobSP' = [pJobSP EXCEPT !.sjLaunched = TRUE]
    /\ jobSP_c' = [S EXCEPT !.registered = TRUE, !.pending = Sites,
                            !.outcomeKey = TRUE, !.stage = "start"]
    /\ UNCHANGED net

SendStart ==
    /\ S.stage = "start"
    /\ net' = SendAll(net, {Msg("START_JOB", SP, CP(c), <<JobId, c>>, Token(c, 1)) : c \in Sites})
    /\ pJobSP' = [pJobSP EXCEPT !.startSent = @ \cup Sites]
    /\ jobSP_c' = [S EXCEPT !.stage = "startWait"]

\* Strict start ok -> JOB_STARTED -> running_jobs registration (the completion
\* thread may finish the job before RUNNING is written: #5301).
RegisterRunning ==
    /\ S.stage = "startWait"
    /\ AllRep("START_REPLY", "ok") \/ ("nonStrictStart" \in Profile /\ "rpcTimeout" \in Faults)
    /\ jobSP_c' = [S EXCEPT !.running = TRUE, !.stage = "started"]
    /\ UNCHANGED <<pJobSP, net>>

\* Non-strict reply check (profile nonStrictStart, job_runner.py:396-411): a
\* timed-out START reply drops the site from the active sites (a subset of the
\* ok replies in net; port startDropped), and then, in a separate step, the
\* pending outcomes shrink to the active sites (intersection_update, 410-411).
\* An OUTCOME arriving between the two is still handled as pending.
StartEval ==
    /\ S.stage = "startWait"
    /\ "nonStrictStart" \in Profile /\ "rpcTimeout" \in Faults /\ pJobSP.startDropped = {}
    /\ \E D \in SUBSET {c \in Sites : Rep("START_REPLY", c, "ok")} :
          /\ D /= Sites
          /\ jobSP_c' = [S EXCEPT !.active = D]
          /\ pJobSP' = [pJobSP EXCEPT !.startDropped = Sites \ D]
    /\ UNCHANGED net

FilterPending ==
    /\ S.stage = "startWait" /\ pJobSP.startDropped /= {}
    /\ jobSP_c' = [S EXCEPT !.pending = @ \cap S.active]
    /\ UNCHANGED <<pJobSP, net>>

\* RUNNING metadata write after the claim lock section (no CAS).
WriteRunning ==
    /\ S.stage = "started"
    /\ pJobSP' = SetStatus("RUNNING")
    /\ jobSP_c' = [S EXCEPT !.stage = "idle"]
    /\ UNCHANGED net

\* Startup failure (deploy/start reply no or timeout, deployment/store/SJ
\* startup exception, pending outcomes cleared): remove running/pending.
\* Once registered in running_jobs ("started"), only the RUNNING metadata write
\* can still fail (job_runner.py:769-771, fine JobRunnerStartupStoreError at
\* writeRunning); without this, an always-on rpcTimeout let the coarse runner
\* "fail startup" after the job had run and cleared its pending outcomes
\* (bfs2 lead: FINISHED with a live CJ in every JobSP = C mix).
Fail ==
    /\ S.stage \in {"check", "deploy", "spawn", "startWait", "started"}
    /\ IF S.stage = "started" THEN "storeError" \in Faults ELSE
       \/ SomeRep("DEPLOY_REPLY", "no") \/ SomeRep("START_REPLY", "no")
       \/ (S.stage = "startWait" /\ ~S.outcomeKey)
       \/ Faults \cap {"rpcTimeout", "deployError", "storeError", "launchError"} /= {}
       \/ pJobSP.deleted
    /\ jobSP_c' = [S EXCEPT !.running = FALSE, !.pending = {}, !.outcomeKey = FALSE,
                            !.stage = "failStop"]
    /\ UNCHANGED <<pJobSP, net>>

FailStop ==
    /\ S.stage = "failStop" /\ S.registered
    /\ net' = CmdAllS("ABORT_JOB", Sites, "fail")
    /\ pJobSP' = Stops(Sites)
    /\ jobSP_c' = [S EXCEPT !.stage = "failCancel"]

FailCancel ==
    /\ S.stage = "failCancel" \/ (S.stage = "failStop" /\ ~S.registered)
    /\ net' = CmdAllS("CANCEL_RESOURCES", Sites, "fail")
    /\ jobSP_c' = [S EXCEPT !.stage = "failWait"]
    /\ UNCHANGED pJobSP

FailStatus ==
    /\ S.stage = "failWait"
    /\ IF pJobSP.deleted
       \* the except branch's _check_job_status raises: the loop dies (T1-b)
       THEN /\ pJobSP' = [pJobSP EXCEPT !.schedulerCrashed = TRUE]
            /\ jobSP_c' = [S EXCEPT !.stage = "crashed"]
       ELSE /\ pJobSP' = SetStatus(IF pJobSP.status = "ABORTED" THEN "ABORTED" ELSE "FAILED_TO_RUN")
            /\ jobSP_c' = [S EXCEPT !.stage = "idle"]
    /\ UNCHANGED net

\* Admin delete_job of a queued (or still deploying, SUBMITTED) job; when it
\* lands inside the scheduling scan, or before the runner's status check, the
\* scheduling loop dies (T1; fine JobRunnerScanDeleted / CheckSubmitted).
Delete ==
    /\ "deleteJob" \in Faults /\ ~pJobSP.deleted /\ pJobSP.status = "SUBMITTED"
    /\ \/ /\ pJobSP' = [pJobSP EXCEPT !.deleted = TRUE]
          /\ UNCHANGED jobSP_c
       \/ /\ S.stage \in {"init", "check", "blocked"}
          /\ pJobSP' = [pJobSP EXCEPT !.deleted = TRUE, !.schedulerCrashed = TRUE]
          /\ jobSP_c' = [S EXCEPT !.stage = "crashed"]
    /\ UNCHANGED net

\* SP process crash and restart (fault spCrash): only the job store survives;
\* no startup recovery (R1); the SJ dies with its parent (Ports SJAlive).
SPCrashRestart ==
    /\ "spCrash" \in Faults /\ ~pJobSP.spRestarted
    /\ pJobSP.status \in {"DISPATCHED", "RUNNING"}
    /\ jobSP_c' = [InitValue EXCEPT !.handled = S.handled, !.aborts = S.aborts, !.stage = "idle"]
    /\ pJobSP' = [pJobSP EXCEPT !.spRestarted = TRUE, !.completionCrashed = FALSE,
                                !.startDropped = {}, !.schedulerCrashed = FALSE, !.deleted = FALSE,
                                !.other = IF @ \in {"running", "exited"} THEN "stale" ELSE @]
    /\ UNCHANGED net

DeletedCrash ==
    /\ pJobSP.deleted /\ ~pJobSP.schedulerCrashed /\ S.stage \in {"init", "check", "blocked"}
    /\ pJobSP' = [pJobSP EXCEPT !.schedulerCrashed = TRUE]
    /\ jobSP_c' = [S EXCEPT !.stage = "crashed"]
    /\ UNCHANGED net

\* ---------------- server engine: SJ wait and termination
ObserveSJExit ==
    /\ S.registered /\ SJDown
    /\ jobSP_c' = [S EXCEPT !.registered = FALSE, !.failed = @ \/ SJCrashed]
    /\ UNCHANGED <<pJobSP, net>>
\* L13 (statusLost): a panicked SJ's exit (code 0) observed without its status
\* message: not recorded as a failure.
ObserveSJExitStatusLost ==
    /\ "statusLost" \in Faults
    /\ S.registered /\ SJDown /\ ~pJobSP.sjKilled /\ SJExitCode = "error"
    /\ jobSP_c' = [S EXCEPT !.registered = FALSE]
    /\ UNCHANGED <<pJobSP, net>>

\* abort_app_on_server after a stop request (abort, startup failure, fail_run):
\* terminate after the grace period (kills a live SJ) or after it exited.
\* Timing T2 (PortsJob): during an admin stop, only after the SJ's exit was
\* observed (run_processes pop) or on the 0 s abortCmdError path.
Terminate ==
    /\ pJobSP.abortSent /= {} /\ pJobSP.sjLaunched
    /\ \/ TimingOK(Faults, "slowAdminStop", T2Holds(S.adminPC = "stop" /\ S.registered))
       \/ "abortCmdError" \in Faults
    /\ jobSP_c' = [S EXCEPT !.terminated = TRUE]
    \* kill after the grace period, or terminate an SJ that is already gone
    \* (fine TerminateAfterExit needs ~registered). v5: the no-kill branch used
    \* to allow a registered live SJ, so RemoveAfterTerminate unregistered a
    \* live SJ and the job went terminal with it running (hunt5 smoke, zoom-in
    \* with JobSP fine: gone).
    /\ \/ pJobSP' = [pJobSP EXCEPT !.sjKilled = @ \/ SJAlive]
       \/ /\ ~S.registered \/ ~SJAlive
          /\ UNCHANGED pJobSP
    /\ UNCHANGED net

RemoveAfterTerminate ==
    /\ S.terminated /\ S.registered
    /\ jobSP_c' = [S EXCEPT !.registered = FALSE]
    /\ UNCHANGED <<pJobSP, net>>

\* ---------------- admin abort command (one attempt)
\* Pre-run abort (unless the start claim is held: busy), running abort, or no-op.
AbortRead ==
    /\ "abort" \in Faults /\ S.aborts = 0 /\ S.adminPC = "idle"
    /\ \/ /\ pJobSP.status \in {"SUBMITTED", "DISPATCHED"}
          /\ pJobSP' = SetStatus("ABORTED")
          /\ jobSP_c' = [S EXCEPT !.aborts = 1]
       \/ /\ pJobSP.status = "RUNNING"
          /\ jobSP_c' = [S EXCEPT !.aborts = 1, !.adminPC = "read"]
          /\ UNCHANGED pJobSP
       \/ /\ jobSP_c' = [S EXCEPT !.aborts = 1]
          /\ UNCHANGED pJobSP
    /\ UNCHANGED net

AbortRunningSend ==
    /\ S.adminPC = "read" /\ S.registered
    /\ net' = CmdAllS("ABORT_JOB", Sites, "admin")
    /\ pJobSP' = Stops(Sites)
    /\ jobSP_c' = [S EXCEPT !.adminPC = "stop"]

AbortRunningNoSJ ==
    /\ S.adminPC = "read" /\ ~S.registered
    /\ jobSP_c' = [S EXCEPT !.adminPC = "stop"]
    /\ UNCHANGED <<pJobSP, net>>

MarkAborted ==
    /\ S.adminPC = "stop"
    /\ jobSP_c' = [S EXCEPT !.runAborted = @ \/ S.running, !.adminPC = "idle"]
    /\ UNCHANGED <<pJobSP, net>>

\* ---------------- SP shutdown / restart (fault spShutdown, v9): stop_all_runs. Coarse
\* abstracts the loop: it may stop this job (abort to the clients if the SJ is
\* registered, mark aborted) or end without it (RuntimeError or the job not listed).
ShutStart ==
    /\ "spShutdown" \in Faults /\ S.shut = "none" /\ ~pJobSP.spRestarted
    /\ jobSP_c' = [S EXCEPT !.shut = "loop"]
    /\ UNCHANGED <<pJobSP, net>>
ShutStop ==
    /\ S.shut = "loop" /\ ~S.shutStopped
    /\ jobSP_c' = [S EXCEPT !.shutStopped = TRUE, !.runAborted = @ \/ S.running]
    /\ \/ /\ S.registered
          /\ net' = CmdAllS("ABORT_JOB", Sites, "shutdown")
          /\ pJobSP' = Stops(Sites)
       \/ UNCHANGED <<pJobSP, net>>
ShutDone ==
    /\ S.shut = "loop"
    /\ jobSP_c' = [S EXCEPT !.shut = "done"]
    /\ UNCHANGED <<pJobSP, net>>

\* ---------------- client outcome receipt (fed_server / fail_run)
RecvOutcome(c, k) ==
    /\ InInbox(k, SP, "OUTCOME") /\ M(k).from = CP(c) /\ k \notin S.handled
    /\ LET b == M(k).body
           act == S.registered \/ S.running
           seen == [pJobSP EXCEPT !.outcomeSeen = @ \cup {c}] IN
       IF c \notin S.pending
       THEN /\ jobSP_c' = [S EXCEPT !.handled = @ \cup {k}]
            /\ pJobSP' = seen
            /\ UNCHANGED net
       ELSE IF b = "ok"
       THEN /\ jobSP_c' = [S EXCEPT !.handled = @ \cup {k}, !.pending = @ \ {c}]
            /\ pJobSP' = [seen EXCEPT !.outcomes[c] = b]
            /\ UNCHANGED net
       ELSE /\ jobSP_c' = [S EXCEPT !.handled = @ \cup {k},
                 !.pending = IF act THEN {} ELSE @ \ {c},
                 !.outcomeKey = IF act THEN FALSE ELSE @,
                 !.failed = @ \/ act,
                 !.sAborted = IF b = "failed"
                              THEN (IF act THEN FALSE ELSE @)
                              ELSE (IF act /\ ~S.failed THEN TRUE ELSE @)]
            /\ IF S.registered
               THEN /\ net' = CmdAllS("ABORT_JOB", Sites, "outcome")
                    /\ pJobSP' = [seen EXCEPT !.outcomes[c] = b, !.abortSent = @ \cup Sites]
               ELSE /\ pJobSP' = [seen EXCEPT !.outcomes[c] = b]
                    /\ UNCHANGED net

\* ---------------- heartbeat reconciliation (CP job listing)
HeartbeatStop(c) ==
    /\ HBView(c) = 2 /\ ~S.registered /\ (~S.outcomeKey \/ S.failed) /\ HBStopFree(c)
    /\ net' = Send(net, HBStopMsg(c))
    /\ UNCHANGED <<jobSP_c, pJobSP>>

ResolveMissingOutcome(c) ==
    /\ ~S.registered /\ c \in S.pending /\ HBView(c) \in {0, 3}
    /\ LET r == S.running /\ ~S.failed IN
       jobSP_c' = [S EXCEPT !.pending = IF r THEN {} ELSE @ \ {c},
                            !.outcomeKey = IF r THEN FALSE ELSE @,
                            !.failed = @ \/ S.running,
                            !.sAborted = IF r THEN FALSE ELSE @]
    /\ UNCHANGED <<pJobSP, net>>

\* ---------------- completion thread
SelectCompletion ==
    /\ S.running /\ ~S.registered /\ S.completion = "idle"
    /\ LET f == S.failed /\ ~S.sAborted IN
       jobSP_c' = [S EXCEPT !.completion = "wait",
                            !.pending = IF f THEN {} ELSE @,
                            !.outcomeKey = IF f THEN FALSE ELSE @]
    /\ UNCHANGED <<pJobSP, net>>

OutcomeGraceExpired ==
    /\ "outcomeTimeout" \in Faults /\ S.completion = "wait" /\ S.pending /= {}
    /\ jobSP_c' = [S EXCEPT !.pending = {}]
    /\ UNCHANGED <<pJobSP, net>>

\* infra/abort precedence: run_aborted or aborted outcome > failure > completed.
Classify ==
    /\ S.completion = "wait"
    /\ S.pending = {} \/ S.runAborted \/ (S.failed /\ ~S.sAborted)
    /\ jobSP_c' = [S EXCEPT !.completion = "publish", !.finish =
          IF S.runAborted \/ S.sAborted THEN "ABORTED"
          ELSE IF S.failed THEN "FAILED" ELSE "COMPLETED"]
    /\ IF S.failed
       THEN /\ net' = CmdAllS("ABORT_JOB", Sites, "complete")
            /\ pJobSP' = Stops(Sites)
       ELSE UNCHANGED <<pJobSP, net>>

\* Terminal status after the workspace archive (success, retry or grace).
PublishTerminal ==
    /\ S.completion = "publish"
    /\ pJobSP' = SetStatus(S.finish)
    /\ jobSP_c' = [S EXCEPT !.completion = "remove"]
    /\ UNCHANGED net

RemoveCompleted ==
    /\ S.completion = "remove" /\ S.running
    /\ jobSP_c' = [S EXCEPT !.running = FALSE, !.pending = {}, !.outcomeKey = FALSE,
                            !.completion = "done"]
    /\ UNCHANGED <<pJobSP, net>>

\* The job was already removed by the start-failure path: the unguarded del
\* raises KeyError and the completion thread dies (job_runner.py:582-583).
RemoveCompletedMissing ==
    /\ S.completion = "remove" /\ ~S.running
    /\ jobSP_c' = [S EXCEPT !.completion = "crashed"]
    /\ pJobSP' = [pJobSP EXCEPT !.completionCrashed = TRUE]
    /\ UNCHANGED net

\* ---- J2 (profile multiJob), v8: the second SP-only job, port summary only
OtherLaunch ==
    /\ pJobSP.other = "queued" /\ ~pJobSP.schedulerCrashed
    /\ pJobSP' = [pJobSP EXCEPT !.other = "running"]
    /\ UNCHANGED <<jobSP_c, net>>
OtherExit ==
    /\ pJobSP.other = "running"
    /\ pJobSP' = [pJobSP EXCEPT !.other = "exited"]
    /\ UNCHANGED <<jobSP_c, net>>
OtherComplete ==
    /\ pJobSP.other = "exited" /\ ~pJobSP.completionCrashed
    /\ pJobSP' = [pJobSP EXCEPT !.other = "done"]
    /\ UNCHANGED <<jobSP_c, net>>
OtherDelete ==
    /\ "deleteJob" \in Faults /\ pJobSP.other = "queued"
    /\ \/ /\ pJobSP' = [pJobSP EXCEPT !.other = "deleted"]
          /\ UNCHANGED jobSP_c
       \/ /\ ~pJobSP.schedulerCrashed
          /\ pJobSP' = [pJobSP EXCEPT !.other = "deleted", !.schedulerCrashed = TRUE]
          /\ jobSP_c' = [S EXCEPT !.stage = "crashed"]
    /\ UNCHANGED net

Next ==
    \/ SendCheck \/ AdmitCancel \/ Blocked \/ DeploySend \/ WriteDispatched \/ Spawn
    \/ SendStart \/ RegisterRunning \/ StartEval \/ FilterPending \/ WriteRunning \/ Fail \/ FailStop \/ FailCancel \/ FailStatus
    \/ OtherLaunch \/ OtherExit \/ OtherComplete \/ OtherDelete
    \/ ObserveSJExit \/ ObserveSJExitStatusLost \/ Terminate \/ RemoveAfterTerminate
    \/ AbortRead \/ AbortRunningSend \/ AbortRunningNoSJ \/ MarkAborted
    \/ ShutStart \/ ShutStop \/ ShutDone
    \/ SelectCompletion \/ OutcomeGraceExpired \/ Classify \/ PublishTerminal \/ RemoveCompleted
    \/ RemoveCompletedMissing \/ Delete \/ DeletedCrash \/ SPCrashRestart
    \/ \E c \in Sites : HeartbeatStop(c) \/ ResolveMissingOutcome(c)
    \/ \E c \in Sites, k \in DOMAIN net : RecvOutcome(c, k)
=============================================================================
