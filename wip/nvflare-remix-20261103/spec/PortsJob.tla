------------------------------ MODULE PortsJob ------------------------------
\* Port shapes, message kinds and faults of the JOB component groups
\* (JobSP, JobCP, RunCJ). Owned by the job component; others only read.
\*
\* Message kinds (owner group; key id; body):
\*   JobSP -> CP(c): CHECK_RESOURCES, CANCEL_RESOURCES, DEPLOY_JOB, START_JOB,
\*                   ABORT_JOB (seed "Stop"), HEARTBEAT_STOP; id <<JobId, c>>, except
\*                   ABORT_JOB and CANCEL_RESOURCES: <<JobId, c, src>> (sender path
\*                   "fail"|"admin"|"outcome"|"complete" resp. "admit"|"fail") and
\*                   HEARTBEAT_STOP: <<JobId, c, n>>, n in 1..2 (repeated replies)
\*   JobCP -> SP   : RESOURCES_OK (body "ok"|"no" = seed CheckOK|CheckNo),
\*                   CANCEL_ACK, DEPLOY_REPLY ("ok"|"no"), START_REPLY ("ok"|"no"),
\*                   OUTCOME ("ok"|"failed"|"aborted"); id <<JobId, c>>
\*                   HEARTBEAT: id <<JobId, c, ph>>, body ph: the job entered (2)
\*                   or left (3) CP's run_processes listing; sent with the
\*                   registry change, SP reads the latest one (no staleness, as
\*                   the seed's atomic read of client.handle, X1/X2)
\*   RunCJ -> CP(c): STARTED, READY, STOPPED; id <<JobId, c, l>>, body l
\*                   (the CJ launch id; notify_job_status)
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
\* Timing assumption T1 (measured in poc-h30/REPORT.md): with default settings the
\* SJ's own DownloadService.shutdown follows END_RUN by ~1 ms (server_runner.py:
\* 208-237), while a CJ reaches its run-finally DS shutdown only after the END_RUN
\* abort path (>= 0.7 s; 5 s task_check_interval sleep when mid-submit,
\* client_runner.py:175,679,814-821). Untimed, the model would let the CJ win.
\* Unless "slowSJTeardown" (end-run readiness held / slow SJ teardown) is enabled,
\* a CJ's DS shutdown waits for the SJ's (or for the SJ to be gone).
\* (the guard is Timing!T1Holds, used as TimingOK(Faults, "slowSJTeardown", ...))
\* Timing assumption T2 (source reading, checks/findings/ABORT_classified_completed.md):
\* abort_app_on_server sends ABORT, starts the cleanup thread and returns at once
\* (server_engine.py:355-382); stop_run then calls mark_run_aborted
\* (job_runner.py:888-890). The cleanup thread kills the SJ only after
\* graceful_wait = 10 s, so run_aborted is set long before. Unless
\* "slowAdminStop" is enabled, the graceful terminate waits for the admin stop
\* thread to finish (the 0 s path is the separate fault abortCmdError).
JobKinds == JobSPKinds \cup JobCPKinds \cup RunCJKinds
JobFaults == {"slowSJTeardown", "slowAdminStop", "statusLost", "abortCmdError", "cjCrash", "abort", "outcomeReportFail", "deployError", "launchError",
              "storeError", "rpcTimeout", "outcomeTimeout", "archiveError",
              "admissionError", "resExpiry", "deleteJob", "spCrash", "cpCrash"}
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
\* schedulerCrashed: the JobRunner.run scheduling loop died of an exception (T1);
\* deleted: the job was removed from the job store by an admin delete_job;
\* spRestarted: the SP process crashed and restarted (fault spCrash).
JobSPPortInit == [sjLaunched |-> FALSE, sjKilled |-> FALSE, startSent |-> {},
                  abortSent |-> {}, outcomes |-> [c \in Sites |-> "none"],
                  terminal |-> "none", status |-> "SUBMITTED", outcomeSeen |-> {},
                  completionCrashed |-> FALSE, startDropped |-> {},
                  schedulerCrashed |-> FALSE, deleted |-> FALSE, spRestarted |-> FALSE,
                  \* v8 (profile multiJob): summary of a second job J2 that lives only in
                  \* the SP ("none" | "queued" | "running" | "exited" | "done" | "deleted" | "stale")
                  other |-> IF "multiJob" \in Profile THEN "queued" ELSE "none"]
\* launch: current CJ launch generation (0 = none); killed: launches CP
\* terminated; exitSeen[l]: exit status CP's waiter observed for launch l
\* ("ok"|"crash"|"killed"); freed: resource releases; reported: outcome the CP
\* tried to report ("none"|"ok"|"failed"|"aborted").
JobCPPortInit == [c \in Sites |-> [launch |-> 0, killed |-> {},
                  exitSeen |-> [l \in Launches |-> "none"], freed |-> 0,
                  allocated |-> FALSE, reported |-> "none", cpRestarted |-> FALSE]]
\* state: "none" -> "initialized" (init_run) -> "running" (main loop) ->
\*        "stopping" (left the loop: run_abort_signal) -> "exited";
\* ready: main loop started (after on_ready); abort: run_abort_signal
\* triggered (END_RUN); dsDown: run-finally DownloadService.shutdown done;
\* exit: "none" | "ok" | "crash" | "killed" (the parent's kill landed).
RunCJPortInit == [c \in Sites |-> [l \in Launches |->
                  [state |-> "none", ready |-> FALSE, exit |-> "none",
                   abort |-> FALSE, dsDown |-> FALSE]]]
=============================================================================
