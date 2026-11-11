------------------------------ MODULE PortsJob ------------------------------
\* Port shapes, message kinds and faults of the JOB component groups
\* (JobSP, JobCP, RunCJ). Owned by the job component; others only read.
\*
\* Message kinds (owner group; key id; body):
\* JobSP -> CP(c): CHECK_RESOURCES, CANCEL_RESOURCES, DEPLOY_JOB, START_JOB,
\* ABORT_JOB (seed "Stop"), HEARTBEAT_STOP; id <<JobId, c>>, except
\* ABORT_JOB and CANCEL_RESOURCES: <<JobId, c, src>> (sender path
\* "fail"|"admin"|"outcome"|"complete" resp. "admit"|"fail") and
\* HEARTBEAT_STOP: <<JobId, c, n>>, n in 1..2 (repeated replies)
\* JobCP -> SP : RESOURCES_OK (body "ok"|"no" = seed CheckOK|CheckNo),
\* CANCEL_ACK, DEPLOY_REPLY ("ok"|"no"), START_REPLY ("ok"|"no"),
\* OUTCOME ("ok"|"failed"|"aborted"); id <<JobId, c>>
\* HEARTBEAT: id <<JobId, c, ph>>, body ph: the job entered (2)
\* or left (3) CP's run_processes listing; sent with the
\* registry change, SP reads the latest one (no staleness, as
\* the seed's atomic read of client.handle, /)
\* RunCJ -> CP(c): STARTED, READY, STOPPED; id <<JobId, c, l>>, body l
\* (the CJ launch id; notify_job_status)
\* Faults (JobFaults): cjCrash (RunCJ), abort (JobSP admin abort),
\* abortCmdError (the ABORT command to the SJ raised, so terminate runs with
\* graceful_wait = 0), outcomeReportFail (JobCP report exception), deployError
\* (SP deployment exception / CP deploy error), launchError (SP SJ startup
\* error; CP prepare/spawn/waiter/restart exceptions), storeError (SP job
\* metadata store), rpcTimeout (SP admin request timeouts), outcomeTimeout
\* (SP client-outcome grace expiry), archiveError (SP workspace archive),
\* admissionError (SP scheduler admission exception), resExpiry (CP reservation
\* TTL expiry before START arrives: a timing assumption made explicit; the seed
\* leaves the TTL scan unconstrained, which random simulation then hits first).
EXTENDS Consts
JobSPKinds == {"CHECK_RESOURCES", "CANCEL_RESOURCES", "DEPLOY_JOB", "START_JOB",
               "ABORT_JOB", "HEARTBEAT_STOP"}
JobCPKinds == {"RESOURCES_OK", "CANCEL_ACK", "DEPLOY_REPLY", "START_REPLY",
               "OUTCOME", "HEARTBEAT"}
RunCJKinds == {"STARTED", "READY", "STOPPED"}
\* Timing assumption TA1 (measured in poc-h30/REPORT.md): with default settings the
\* SJ's own DownloadService.shutdown follows END_RUN by ~1 ms (server_runner.py:
\* 208-237), while a CJ reaches its run-finally DS shutdown only after the END_RUN
\* abort path (>= 0.7 s; 5 s task_check_interval sleep when mid-submit,
\* client_runner.py:175,679,814-821). Untimed, the model would let the CJ win.
\* Unless "slowSJTeardown" (end-run readiness held / slow SJ teardown) is enabled,
\* a CJ's DS shutdown waits for the SJ's (or for the SJ to be gone).
\* (the guard is Timing!TA1Holds, used as TimingOK(Faults, "slowSJTeardown", ...))
\* Timing assumption TA2 (source reading, checks/findings/ABORT_classified_completed.md):
\* abort_app_on_server sends ABORT, starts the cleanup thread and returns at once
\* (server_engine.py:355-382); stop_run then calls mark_run_aborted
\* (job_runner.py:888-890). The cleanup thread kills the SJ only after
\* graceful_wait = 10 s, so run_aborted is set long before. Unless
\* "slowAdminStop" is enabled, the graceful terminate waits for the admin stop
\* thread to finish (the 0 s path is the separate fault abortCmdError).
JobKinds == JobSPKinds \cup JobCPKinds \cup RunCJKinds
JobFaults == {"slowSJTeardown", "slowAdminStop", "statusLost", "abortCmdError", "cjCrash", "abort", "outcomeReportFail", "deployError", "launchError",
              "storeError", "rpcTimeout", "outcomeTimeout", "archiveError",
              "admissionError", "resExpiry", "deleteJob", "spCrash", "cpCrash",
              "spShutdown", "slowShutdownAbort",
              \* v11 E: K8s Pod delete fails; publish_results handler outlives its requester;
              \* G: the new SJ cannot get the participants from SP (#15)
              "podDeleteFail", "slowPublish", "sjSyncFail",
              \* another job's START handler runs between our consume and our spawn
              "startOverlap"}
JobStatuses == {"SUBMITTED", "DISPATCHED", "RUNNING", "ABORTED", "COMPLETED",
                "FAILED", "FAILED_TO_RUN", "CANT_SCHEDULE"}
JobTerminalStatuses == {"ABORTED", "COMPLETED", "FAILED", "FAILED_TO_RUN", "CANT_SCHEDULE"}
\* terminal: class of the last terminal status written to the job store
\* ("FINISHED" = COMPLETED); status: the job store value (non-CAS, user-visible);
\* sjKilled: SP terminated the SJ process (abort_app_on_server).
TerminalClass(st) == IF st = "COMPLETED" THEN "FINISHED" ELSE "ABORTED_OR_FAILED"
\* outcomeSeen: sites whose OUTCOME report the server has handled (recorded or
\* ignored); the CP's report request returns only then, or on its timeout.
\* completionCrashed: the completion thread (_job_complete_process) died of an
\* exception; no later job would be finalized. startDropped: sites the
\* non-strict START reply check left out of the active sites (no ok reply seen
\* by the waiter; job_runner.py:396-411); their outcome is not awaited and a
\* later OUTCOME from them is dropped (fed_server.py:943-945).
\* schedulerCrashed: "no", or the ledger id of the operation whose exception ended the
\* JobRunner.run scheduling loop;
\* deleted: the job was removed from the job store by an admin delete_job;
\* spRestarted: the SP process crashed and restarted (fault spCrash).
JobSPPortInit == [sjLaunched |-> FALSE, sjKilled |-> FALSE, startSent |-> {},
                  abortSent |-> {}, outcomes |-> [c \in Sites |-> "none"],
                  terminal |-> "none", status |-> "SUBMITTED", outcomeSeen |-> {},
                  completionCrashed |-> "no", startDropped |-> {},
                  schedulerCrashed |-> "no", deleted |-> FALSE, spRestarted |-> FALSE,
                  \* stopReq: an admin abort or an SP shutdown/restart accepted for this job
                  \* (none | admin | shutdown); spDown: the SP process exited after a shutdown
                  stopReq |-> "none", spDown |-> FALSE,
                  \* cause records (STANDARD 10: written by the action that embodies the cause, as
                  \* the ledger id of that operation; "none" otherwise): overwrite = the status write
                  \* that replaced a terminal status; statusGen = the SP incarnation (0, 1 after a
                  \* restart) that wrote the current status; exitObs = how the SJ exit was observed;
                  \* termEarly = a terminate that overtook an admin stop in progress; unfinalized = a
                  \* shutdown stopped the completion thread with a stopped job not finalized
                  overwrite |-> "none", statusGen |-> 0, exitObs |-> "none", termEarly |-> "none",
                  unfinalized |-> "none",
                  \* staleBy: the stored status was written by an SP incarnation that is gone (set on
                  \* restart, cleared by the next status write); failBy: the operation that marked the
                  \* running job failed
                  staleBy |-> "none", failBy |-> "none",
                  \* stopSkipped: the shutdown loop ended without stopping a registered job (it
                  \* raised mid-way); lateStart: a scheduling round that began before the shutdown
                  \* started the job after it (ask_to_stop is read only at the loop top)
                  stopSkipped |-> "none", lateStart |-> "none",
                  \* exitUnseen: the run entry was removed by a terminate before the SJ's exit status
                  \* was recorded
                  exitUnseen |-> "none",
                  \* v8 (profile multiJob): summary of a second job J2 that lives only in
                  \* the SP ("none" | "queued" | "running" | "exited" | "done" | "deleted" | "stale")
                  other |-> IF "multiJob" \in Profile THEN "queued" ELSE "none"]
\* launch: current CJ launch generation (0 = none); killed: launches CP
\* terminated; exitSeen[l]: exit status CP's waiter observed for launch l
\* ("ok"|"crash"|"killed"); freed: resource releases; reported: outcome the CP
\* tried to report ("none"|"ok"|"failed"|"aborted").
\* env: the CP-global CUDA_VISIBLE_DEVICES (process-global state, written by every
\* START's resource consume): 0 unset, 1 our job's unit, 2 the second job's unit;
\* gpu[l]: the unit launch l of our CJ actually uses (copied from env at spawn for a
\* process CJ; from the allocation for a container CJ).
JobCPPortBase == [launch |-> 0, killed |-> {},
                  exitSeen |-> [l \in Launches |-> "none"], freed |-> 0,
                  allocated |-> FALSE, reported |-> "none", cpRestarted |-> FALSE,
                  env |-> 0, gpu |-> [l \in Launches |-> 0],
                  \* cause records: freedBy = the operation that freed the allocation; endBy = the
                  \* operation that declared the current launch ended without its exit
                  freedBy |-> "none", endBy |-> "none",
                  \* allocLost: a restart dropped the allocation of a CJ that outlives it; gpuBy: a
                  \* launch took its device from another job's write of the CP-global environment;
                  \* wsRemovedBy: a publish handler removed the transfer record of another launch
                  allocLost |-> "none", gpuBy |-> "none", wsRemovedBy |-> "none",
                  \* orphanBy: a launch the CP spawned after its relaunch submission raised (no handle)
                  orphanBy |-> "none"]
\* v11 (k8sJob; DESIGN 16.9): ws = the launch whose workspace-transfer record is
\* registered (WorkspaceTransferManager.jobs[job_id]; 0 = none); pub[l] = the
\* publish_results handler of launch l: none | running | done; wsLost = launches
\* whose results publication found no record (results not returned).
K8sJob == "k8sJob" \in Profile
\* v11 (multiJobCP; DESIGN 16.9 F): j2 = a second job J2 on this CP with its own
\* allocation (the site's single resource unit) and CJ: st none | running |
\* exited | freed, launch = its CJ launch generation, alloc = it holds the unit.
MultiJobCP == "multiJobCP" \in Profile
J2Init == [st |-> "none", launch |-> 0, alloc |-> FALSE, gpu |-> 0]
JobCPExtra == (IF K8sJob THEN {"ws", "pub", "wsLost"} ELSE {}) \cup (IF MultiJobCP THEN {"j2"} ELSE {})
JobCPPortInit == [c \in Sites |->
    IF JobCPExtra = {} THEN JobCPPortBase
    ELSE [f \in DOMAIN JobCPPortBase \cup JobCPExtra |->
            CASE f = "ws" -> 0
              [] f = "pub" -> [l \in Launches |-> "none"]
              [] f = "wsLost" -> {}
              [] f = "j2" -> J2Init
              [] OTHER -> JobCPPortBase[f]]]
\* state: "none" -> "initialized" (init_run) -> "running" (main loop) ->
\* "stopping" (left the loop: run_abort_signal) -> "exited";
\* ready: main loop started (after on_ready); abort: run_abort_signal
\* triggered (END_RUN); dsDown: run-finally DownloadService.shutdown done;
\* exit: "none" | "ok" | "crash" | "killed" (the parent's kill landed).
RunCJPortInit == [c \in Sites |-> [l \in Launches |->
                  [state |-> "none", ready |-> FALSE, exit |-> "none",
                   abort |-> FALSE, dsDown |-> FALSE]]]
=============================================================================
