------------------------------- MODULE base -------------------------------
(***************************************************************************)
(* NVFlare client resource ownership across the job lifecycle —           *)
(* Scenarios S3 and S5 of modeling-brief.md (answers Q1, Q2, Q4).          *)
(*                                                                         *)
(* Source: nvflare @ 53ba7ee567468ea7971dad4faccef13c6cb35dc2 (paths under *)
(* nvflare/). Resources are abstracted as identical units per client       *)
(* (ListResourceManager/GPUResourceManager both keep unit bookkeeping in   *)
(* AutoCleanResourceManager, app_common/resource_managers/                 *)
(* auto_clean_resource_manager.py); every job needs one unit per client.   *)
(*                                                                         *)
(* Server side is reduced to the JobRunner branches that decide which      *)
(* client requests are sent and which reservations/allocations are        *)
(* abandoned; the server job-status machine is modeled in models/lifecycle.*)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Jobs, Clients,
    K,            \* resource units per client
    MinSites,     \* job.min_sites
    MaxAttempts,  \* scheduling attempts per job (DefaultJobScheduler.max_schedule_count, abstracted)
    MaxJobs,      \* DefaultJobScheduler.max_jobs
    NoJob

ASSUME MinSites >= 1    \* configs use min_sites >= 1 (min_sites = 0 would dispatch with zero clients)

Attempts == 1..MaxAttempts
Tokens == Jobs \X Attempts               \* reservation token uuid per CHECK (auto_clean...:129)
TokJob(t) == t[1]

\* Runner phases for the current attempt (job_runner.py:633-731, job_scheduler.py:104-261)
RunnerPCs == {"idle", "chkWait", "sched", "deploy", "stat2", "startSJ", "stWait", "exc"}

\* START_JOB handler phases per <<client, job>> (scheduler_cmds.py:100-137 -> client_engine.py:349-382
\* -> client_executor.py:198-334). "none" = no handler running.
StartPhases == {"none", "alloc", "reg"}

\* CJ state per <<client, job>>: registered in JobExecutor.run_processes from "starting" until the waiter pops.
CJStates == {"none", "starting", "running", "exited", "gone"}

VARIABLES
    free,       \* free units per client
    resv,       \* reserved tokens per client (each holds one unit): AutoCleanResourceManager.reserved_resources
    alloc,      \* units allocated to <<c, j>> by allocate_resources (0/1)
    chkReq,     \* CHECK_RESOURCE requests in flight per client (set of tokens)
    chkRep,     \* CHECK replies per <<client, token>>: "none" | "ok" | "no"
    cancelReq,  \* CANCEL_RESOURCE requests in flight per client (set of tokens)
    stReq,      \* START_JOB requests in flight per client (set of tokens)
    stRep,      \* START_JOB reply per <<client, job>>: "none" | "ok" | "err"
    sh,         \* START handler phase per <<client, job>>
    shTok,      \* token carried by the START handler per <<client, job>>
    shAbort,    \* abort recorded on the _PendingJobHandle while STARTING (client_executor.py:65-72)
    cj,         \* CJ process/registration state per <<client, job>>
    deployed,   \* app deployed on client (run dir exists) per <<client, job>>
    abortReq,   \* ABORT requests in flight per client (set of jobs)
    rn,         \* runner state: pc, job, att, ok (clients with reservation), dep (deployable clients)
    attempts,   \* attempts used per job
    jobState,   \* server view: "queued" | "running" | "ended" | "failed" | "aborted"
    srvRun,     \* job is a server job for heartbeat purposes (SJ alive or outcomes pending, fed_server.py:1016-1018)
    scheduled,  \* scheduler admission set
    rejLeak     \* history: a CHECK was rejected while an abandoned reservation held a unit on that client

vars == <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed,
          abortReq, rn, attempts, jobState, srvRun, scheduled, rejLeak>>

-----------------------------------------------------------------------------
(* Helpers *)
CurTok == <<rn.job, rn.att>>
\* A reservation is "in use" while the runner is still working with the attempt that created it.
InUse(t) == rn.pc # "idle" /\ t = <<rn.job, rn.att>>
Abandoned(c, t) == t \in resv[c] /\ ~InUse(t)
\* Units held by live START handlers or registered CJs (for AllocationOwned)
Owned(c, j) == sh[c, j] # "none" \/ cj[c, j] \in {"starting", "running", "exited"}

RunnerTo(pc) == rn' = [rn EXCEPT !.pc = pc]
\* JobRunner._stop_run (job_runner.py:374-393) as seen by clients: ABORT to participants (deployable clients).
AbortTo(S, j) == [c \in Clients |-> IF c \in S THEN abortReq[c] \cup {j} ELSE abortReq[c]]

-----------------------------------------------------------------------------
Init ==
    /\ free = [c \in Clients |-> K]
    /\ resv = [c \in Clients |-> {}]
    /\ alloc = [x \in Clients \X Jobs |-> 0]
    /\ chkReq = [c \in Clients |-> {}]
    /\ chkRep = [x \in Clients \X Tokens |-> "none"]
    /\ cancelReq = [c \in Clients |-> {}]
    /\ stReq = [c \in Clients |-> {}]
    /\ stRep = [x \in Clients \X Jobs |-> "none"]
    /\ sh = [x \in Clients \X Jobs |-> "none"]
    /\ shTok = [x \in Clients \X Jobs |-> <<NoJob, 1>>]
    /\ shAbort = [x \in Clients \X Jobs |-> FALSE]
    /\ cj = [x \in Clients \X Jobs |-> "none"]
    /\ deployed = [x \in Clients \X Jobs |-> FALSE]
    /\ abortReq = [c \in Clients |-> {}]
    /\ rn = [pc |-> "idle", job |-> NoJob, att |-> 1, ok |-> {}, dep |-> {}]
    /\ attempts = [j \in Jobs |-> 0]
    /\ jobState = [j \in Jobs |-> "queued"]
    /\ srvRun = {}
    /\ scheduled = {}
    /\ rejLeak = FALSE

-----------------------------------------------------------------------------
(***************************************************************************)
(* Server: scheduler + runner branches                                     *)
(***************************************************************************)

\* _do_schedule_job/_try_job (job_scheduler.py:335-378, 104-199): max_jobs gate, then CHECK_RESOURCE to
\* every applicable client (server_engine.py:1010-1041).
RunnerSendCheck ==
    /\ rn.pc = "idle"
    /\ Cardinality(scheduled) < MaxJobs
    /\ \E j \in Jobs :
         /\ jobState[j] = "queued"
         /\ attempts[j] < MaxAttempts
         /\ LET a == attempts[j] + 1 IN
              /\ attempts' = [attempts EXCEPT ![j] = a]
              /\ chkReq' = [c \in Clients |-> chkReq[c] \cup {<<j, a>>}]
              /\ rn' = [rn EXCEPT !.pc = "chkWait", !.job = j, !.att = a, !.ok = {}, !.dep = {}]
    /\ UNCHANGED <<free, resv, alloc, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed,
                   abortReq, jobState, srvRun, scheduled, rejLeak>>

\* _check_client_resources collects replies (timeout 15 s); a missing reply is (False, "")
\* (server_engine.py:1024-1041). `timedOut` requests stay in flight and may be processed later.
\* job_scheduler.py:207-254: fewer than min_sites OK -> _cancel_resources for OK sites (1052-1066),
\* NO_RESOURCE; otherwise dispatch to OK sites with their tokens.
CollectCheckWith(replied) ==
    LET t == CurTok
        okc == {c \in replied : chkRep[c, t] = "ok"}
    IN
      IF Cardinality(okc) < MinSites
      THEN /\ cancelReq' = [c \in Clients |-> IF c \in okc THEN cancelReq[c] \cup {t} ELSE cancelReq[c]]
           /\ RunnerTo("idle")
      ELSE /\ rn' = [rn EXCEPT !.pc = "sched", !.ok = okc]
           /\ UNCHANGED cancelReq

RunnerCollectCheck ==
    /\ rn.pc = "chkWait"
    /\ \A c \in Clients : chkRep[c, CurTok] # "none"
    /\ CollectCheckWith(Clients)
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, stReq, stRep, sh, shTok, shAbort, cj, deployed,
                   abortReq, attempts, jobState, srvRun, scheduled, rejLeak>>

RunnerCollectCheckTimeout ==     \* fault: some CHECK replies time out
    /\ rn.pc = "chkWait"
    /\ LET replied == {c \in Clients : chkRep[c, CurTok] # "none"} IN
         /\ replied # Clients
         /\ CollectCheckWith(replied)
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, stReq, stRep, sh, shTok, shAbort, cj, deployed,
                   abortReq, attempts, jobState, srvRun, scheduled, rejLeak>>

\* job_runner.py:661-663: job no longer SUBMITTED (e.g. aborted by admin) -> `continue`:
\* reservations of this attempt are neither used nor cancelled.
RunnerSkipNotSubmitted ==
    /\ rn.pc = "sched"
    /\ jobState' = [jobState EXCEPT ![rn.job] = "aborted"]
    /\ RunnerTo("idle")
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed,
                   abortReq, attempts, srvRun, scheduled, rejLeak>>

\* job_runner.py:669 _deploy_job succeeds on the dispatched clients (app dir created on each client,
\* client_engine.py:462-480 / app_deployer.py).
RunnerDeploy ==
    /\ rn.pc = "sched"
    /\ deployed' = [x \in Clients \X Jobs |-> IF x[2] = rn.job /\ x[1] \in rn.ok THEN TRUE ELSE deployed[x]]
    /\ rn' = [rn EXCEPT !.pc = "stat2", !.dep = rn.ok]
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj,
                   abortReq, attempts, jobState, srvRun, scheduled, rejLeak>>

\* Some client deploys fail (fault): job_runner.py:251-282 — abort (RuntimeError, job_id None) if fewer than
\* min_sites remain, else continue with deployable clients only; failed clients keep their reservation.
RunnerDeployPartial ==
    /\ rn.pc = "sched"
    /\ \E failed \in (SUBSET rn.ok) \ {{}} :
         LET okc == rn.ok \ failed IN
           /\ deployed' = [x \in Clients \X Jobs |-> IF x[2] = rn.job /\ x[1] \in okc THEN TRUE ELSE deployed[x]]
           /\ IF Cardinality(okc) < MinSites
              THEN /\ rn' = [rn EXCEPT !.pc = "exc", !.dep = {}]
              ELSE /\ rn' = [rn EXCEPT !.pc = "stat2", !.dep = okc]
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj,
                   abortReq, attempts, jobState, srvRun, scheduled, rejLeak>>

\* Server-side deploy failure (job_runner.py:194-209) -> except with job_id None.
RunnerServerDeployFail ==
    /\ rn.pc = "sched"
    /\ rn' = [rn EXCEPT !.pc = "exc", !.dep = {}]
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed,
                   abortReq, attempts, jobState, srvRun, scheduled, rejLeak>>

\* job_runner.py:697-701: job no longer DISPATCHED (aborted) -> `continue` (deployed, reservations unused).
RunnerSkipNotDispatched ==
    /\ rn.pc = "stat2"
    /\ jobState' = [jobState EXCEPT ![rn.job] = "aborted"]
    /\ RunnerTo("idle")
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed,
                   abortReq, attempts, srvRun, scheduled, rejLeak>>

RunnerPassDispatched ==
    /\ rn.pc = "stat2"
    /\ RunnerTo("startSJ")
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed,
                   abortReq, attempts, jobState, srvRun, scheduled, rejLeak>>

\* _start_run: SJ launched (server job for heartbeat), START_JOB with each client's token
\* (server_engine.py:1068-1083).
RunnerStartJob ==
    /\ rn.pc = "startSJ"
    /\ srvRun' = srvRun \cup {rn.job}
    /\ stReq' = [c \in Clients |-> IF c \in rn.dep THEN stReq[c] \cup {CurTok} ELSE stReq[c]]
    /\ stRep' = [x \in Clients \X Jobs |-> IF x[2] = rn.job THEN "none" ELSE stRep[x]]
    /\ RunnerTo("stWait")
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, sh, shTok, shAbort, cj, deployed,
                   abortReq, attempts, jobState, scheduled, rejLeak>>

\* SJ launch failure (fault): except with job_id set, nothing to stop yet (job_runner.py:304-306, 713-719).
RunnerStartSJFail ==
    /\ rn.pc = "startSJ"
    /\ RunnerTo("exc")
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed,
                   abortReq, attempts, jobState, srvRun, scheduled, rejLeak>>

\* START replies (20 s): any explicit error -> except -> _stop_run -> ABORT to participants
\* (job_runner.py:318-323, 713-719, 374-393); timed-out clients are excluded (non-strict).
CollectStartWith(replied) ==
    LET j == rn.job
        errs == {c \in replied : stRep[c, j] = "err"}
    IN
      IF errs # {}
      THEN /\ abortReq' = AbortTo(rn.dep, j)
           /\ srvRun' = srvRun \ {j}
           /\ jobState' = [jobState EXCEPT ![j] = "failed"]
           /\ rn' = [rn EXCEPT !.pc = "idle"]
           /\ UNCHANGED scheduled
      ELSE /\ jobState' = [jobState EXCEPT ![j] = "running"]
           /\ scheduled' = scheduled \cup {j}
           /\ rn' = [rn EXCEPT !.pc = "idle"]
           /\ UNCHANGED <<abortReq, srvRun>>

RunnerCollectStart ==
    /\ rn.pc = "stWait"
    /\ \A c \in rn.dep : stRep[c, rn.job] # "none"
    /\ CollectStartWith(rn.dep)
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed,
                   attempts, rejLeak>>

RunnerCollectStartTimeout ==     \* fault
    /\ rn.pc = "stWait"
    /\ LET replied == {c \in rn.dep : stRep[c, rn.job] # "none"} IN
         /\ replied # rn.dep
         /\ CollectStartWith(replied)
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed,
                   attempts, rejLeak>>

\* except block (job_runner.py:713-731): FAILED_TO_RUN; no cancel of reservations anywhere.
RunnerExc ==
    /\ rn.pc = "exc"
    /\ jobState' = [jobState EXCEPT ![rn.job] = "failed"]
    /\ RunnerTo("idle")
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed,
                   abortReq, attempts, srvRun, scheduled, rejLeak>>

\* The running job ends on the server (SJ exit + completion loop): server abort of clients happens for
\* failed/aborted runs (stop_run / fail_run / _get_finished_job_status), normal end relies on END_RUN.
ServerJobEnd(j) ==
    /\ jobState[j] = "running"
    /\ \E aborting \in BOOLEAN :
         /\ abortReq' = IF aborting THEN AbortTo(Clients, j) ELSE abortReq
    /\ jobState' = [jobState EXCEPT ![j] = "ended"]
    /\ srvRun' = srvRun \ {j}
    /\ scheduled' = scheduled \ {j}
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed,
                   rn, attempts, rejLeak>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* Client: resource manager (AutoCleanResourceManager, one lock)           *)
(***************************************************************************)

\* CheckResourceProcessor (scheduler_cmds.py:61-93) -> check_resources (auto_clean...:119-138):
\* reserve one unit if available, token returned; else (False, "").
ClientCheck(c, t) ==
    /\ t \in chkReq[c]
    /\ chkReq' = [chkReq EXCEPT ![c] = @ \ {t}]
    /\ IF free[c] >= 1
       THEN /\ free' = [free EXCEPT ![c] = @ - 1]
            /\ resv' = [resv EXCEPT ![c] = @ \cup {t}]
            /\ chkRep' = [chkRep EXCEPT ![c, t] = "ok"]
            /\ UNCHANGED rejLeak
       ELSE /\ chkRep' = [chkRep EXCEPT ![c, t] = "no"]
            /\ rejLeak' = (rejLeak \/ \E u \in resv[c] : ~InUse(u) /\ TokJob(u) # TokJob(t))
            /\ UNCHANGED <<free, resv>>
    /\ UNCHANGED <<alloc, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed, abortReq, rn, attempts,
                   jobState, srvRun, scheduled>>

\* CancelResourceProcessor (scheduler_cmds.py:144-157) -> cancel_resources (auto_clean...:140-151).
ClientCancel(c, t) ==
    /\ t \in cancelReq[c]
    /\ cancelReq' = [cancelReq EXCEPT ![c] = @ \ {t}]
    /\ IF t \in resv[c]
       THEN /\ resv' = [resv EXCEPT ![c] = @ \ {t}]
            /\ free' = [free EXCEPT ![c] = @ + 1]
       ELSE UNCHANGED <<resv, free>>
    /\ UNCHANGED <<alloc, chkReq, chkRep, stReq, stRep, sh, shTok, shAbort, cj, deployed, abortReq, rn, attempts,
                   jobState, srvRun, scheduled, rejLeak>>

\* _check_expired (auto_clean...:102-117): a reservation not allocated within expiration_period is released.
\* Abandoned reservations (the runner no longer uses them) expire freely.
ExpireAbandoned(c, t) ==
    /\ Abandoned(c, t)
    /\ resv' = [resv EXCEPT ![c] = @ \ {t}]
    /\ free' = [free EXCEPT ![c] = @ + 1]
    /\ UNCHANGED <<alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed, abortReq, rn,
                   attempts, jobState, srvRun, scheduled, rejLeak>>

\* Fault: a reservation the runner still intends to use expires (scheduling->START took longer than
\* expiration_period, e.g. slow deploy).
ExpireInUse(c, t) ==
    /\ t \in resv[c]
    /\ InUse(t)
    /\ resv' = [resv EXCEPT ![c] = @ \ {t}]
    /\ free' = [free EXCEPT ![c] = @ + 1]
    /\ UNCHANGED <<alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, cj, deployed, abortReq, rn,
                   attempts, jobState, srvRun, scheduled, rejLeak>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* Client: START_JOB handler (scheduler_cmds.py:100-137)                   *)
(***************************************************************************)

\* allocate_resources (auto_clean...:153-164): pops the reservation; RuntimeError if the token is unknown
\* -> except (allocated_resources None, nothing freed) -> error reply.
ClientStartAlloc(c, t) ==
    LET j == TokJob(t) IN
    /\ t \in stReq[c]
    /\ sh[c, j] = "none"
    /\ stReq' = [stReq EXCEPT ![c] = @ \ {t}]
    /\ IF t \in resv[c]
       THEN /\ resv' = [resv EXCEPT ![c] = @ \ {t}]
            /\ alloc' = [alloc EXCEPT ![c, j] = @ + 1]
            /\ sh' = [sh EXCEPT ![c, j] = "alloc"]
            /\ shTok' = [shTok EXCEPT ![c, j] = t]
            /\ UNCHANGED stRep
       ELSE /\ stRep' = [stRep EXCEPT ![c, j] = "err"]
            /\ UNCHANGED <<resv, alloc, sh, shTok>>
    /\ UNCHANGED <<free, chkReq, chkRep, cancelReq, shAbort, cj, deployed, abortReq, rn, attempts, jobState, srvRun,
                   scheduled, rejLeak>>

\* ClientEngine.start_app early returns (client_engine.py:357-367) — returned strings, not exceptions, so
\* StartJobProcessor does NOT free the allocation (scheduler_cmds.py:122-137).
\*   357-359: status == STARTED -> "Client app already started."
\*   365-367: app dir missing -> ERROR string
ClientStartAppEarlyReturn(c, j) ==
    /\ sh[c, j] = "alloc"
    /\ \/ cj[c, j] = "running"
       \/ ~deployed[c, j]
    /\ sh' = [sh EXCEPT ![c, j] = "none"]
    /\ stRep' = [stRep EXCEPT ![c, j] = IF cj[c, j] = "running" THEN "ok" ELSE "err"]
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, shTok, shAbort, cj, deployed, abortReq, rn,
                   attempts, jobState, srvRun, scheduled, rejLeak>>

\* JobExecutor.start_app up to registration (client_executor.py:221-307): registered STARTING with a
\* pending handle; if already registered -> RuntimeError -> StartJobProcessor frees the allocation.
ClientStartRegister(c, j) ==
    /\ sh[c, j] = "alloc"
    /\ cj[c, j] # "running"
    /\ deployed[c, j]
    /\ IF cj[c, j] \in {"starting", "exited"}      \* still registered (301-302)
       THEN /\ sh' = [sh EXCEPT ![c, j] = "none"]
            /\ alloc' = [alloc EXCEPT ![c, j] = @ - 1]
            /\ free' = [free EXCEPT ![c] = @ + 1]
            /\ stRep' = [stRep EXCEPT ![c, j] = "err"]
            /\ UNCHANGED <<cj, shAbort>>
       ELSE /\ sh' = [sh EXCEPT ![c, j] = "reg"]
            /\ cj' = [cj EXCEPT ![c, j] = "starting"]
            /\ shAbort' = [shAbort EXCEPT ![c, j] = FALSE]
            /\ UNCHANGED <<alloc, free, stRep>>
    /\ UNCHANGED <<resv, chkReq, chkRep, cancelReq, stReq, shTok, deployed, abortReq, rn, attempts, jobState, srvRun,
                   scheduled, rejLeak>>

\* launch_job returns a handle (309-334): attach; a pending abort is forwarded (318-320) -> the CJ is
\* terminated; the waiter thread owns the allocation from here on.
ClientStartLaunch(c, j) ==
    /\ sh[c, j] = "reg"
    /\ sh' = [sh EXCEPT ![c, j] = "none"]
    /\ cj' = [cj EXCEPT ![c, j] = IF shAbort[c, j] THEN "exited" ELSE "running"]
    /\ stRep' = [stRep EXCEPT ![c, j] = "ok"]
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, shTok, shAbort, deployed, abortReq, rn,
                   attempts, jobState, srvRun, scheduled, rejLeak>>

\* launch_job raises (fault): registration removed (312-316), exception -> allocation freed (129-133).
ClientStartLaunchFail(c, j) ==
    /\ sh[c, j] = "reg"
    /\ sh' = [sh EXCEPT ![c, j] = "none"]
    /\ cj' = [cj EXCEPT ![c, j] = "none"]
    /\ alloc' = [alloc EXCEPT ![c, j] = @ - 1]
    /\ free' = [free EXCEPT ![c] = @ + 1]
    /\ stRep' = [stRep EXCEPT ![c, j] = "err"]
    /\ UNCHANGED <<resv, chkReq, chkRep, cancelReq, stReq, shTok, shAbort, deployed, abortReq, rn, attempts, jobState,
                   srvRun, scheduled, rejLeak>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* Client: CJ lifecycle, waiter, ABORT, heartbeat cleanup                  *)
(***************************************************************************)

\* The CJ finishes (END_RUN or failure).
CJExit(c, j) ==
    /\ cj[c, j] = "running"
    /\ cj' = [cj EXCEPT ![c, j] = "exited"]
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, deployed, abortReq,
                   rn, attempts, jobState, srvRun, scheduled, rejLeak>>

\* _wait_child_process_finish (client_executor.py:622-688): after the terminal-outcome report, free the
\* allocation (676-679) then pop run_processes (680-681). (Report handling is in models/lifecycle.)
WaiterFree(c, j) ==
    /\ cj[c, j] = "exited"
    /\ cj' = [cj EXCEPT ![c, j] = "gone"]
    /\ free' = [free EXCEPT ![c] = @ + alloc[c, j]]
    /\ alloc' = [alloc EXCEPT ![c, j] = 0]
    /\ UNCHANGED <<resv, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, deployed, abortReq, rn, attempts,
                   jobState, srvRun, scheduled, rejLeak>>

\* AbortAppProcessor -> ClientEngine.abort_app (client_engine.py:390-404) -> JobExecutor.abort_app
\* (client_executor.py:486-547): STARTING -> pending-handle terminate (recorded until attach);
\* STARTED -> terminate after grace; unregistered -> ignored.
ClientAbort(c, j) ==
    /\ j \in abortReq[c]
    /\ abortReq' = [abortReq EXCEPT ![c] = @ \ {j}]
    /\ CASE cj[c, j] = "starting" /\ sh[c, j] = "reg" -> shAbort' = [shAbort EXCEPT ![c, j] = TRUE] /\ UNCHANGED cj
         [] cj[c, j] = "running" -> cj' = [cj EXCEPT ![c, j] = "exited"] /\ UNCHANGED shAbort
         [] OTHER -> UNCHANGED <<cj, shAbort>>
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, deployed, rn, attempts,
                   jobState, srvRun, scheduled, rejLeak>>

\* Heartbeat: jobs registered on the client but not server jobs are aborted with heartbeat_cleanup
\* (fed_server.py:1004-1018, communicator.py:622-651).
HeartbeatAbort(c, j) ==
    /\ cj[c, j] = "running"
    /\ j \notin srvRun
    /\ cj' = [cj EXCEPT ![c, j] = "exited"]
    /\ UNCHANGED <<free, resv, alloc, chkReq, chkRep, cancelReq, stReq, stRep, sh, shTok, shAbort, deployed, abortReq,
                   rn, attempts, jobState, srvRun, scheduled, rejLeak>>

-----------------------------------------------------------------------------
Next ==
    \/ RunnerSendCheck \/ RunnerCollectCheck \/ RunnerCollectCheckTimeout
    \/ RunnerSkipNotSubmitted \/ RunnerDeploy \/ RunnerDeployPartial \/ RunnerServerDeployFail
    \/ RunnerSkipNotDispatched \/ RunnerPassDispatched
    \/ RunnerStartJob \/ RunnerStartSJFail \/ RunnerCollectStart \/ RunnerCollectStartTimeout \/ RunnerExc
    \/ \E j \in Jobs : ServerJobEnd(j)
    \/ \E c \in Clients :
          \/ \E t \in Tokens : ClientCheck(c, t) \/ ClientCancel(c, t) \/ ExpireAbandoned(c, t)
                               \/ ExpireInUse(c, t) \/ ClientStartAlloc(c, t)
          \/ \E j \in Jobs : ClientStartAppEarlyReturn(c, j) \/ ClientStartRegister(c, j)
                             \/ ClientStartLaunch(c, j) \/ ClientStartLaunchFail(c, j)
                             \/ CJExit(c, j) \/ WaiterFree(c, j) \/ ClientAbort(c, j) \/ HeartbeatAbort(c, j)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)
TypeOK ==
    /\ free \in [Clients -> 0..(K + 1)]
    /\ \A c \in Clients : resv[c] \subseteq Tokens
    /\ alloc \in [Clients \X Jobs -> 0..2]
    /\ sh \in [Clients \X Jobs -> StartPhases]
    /\ cj \in [Clients \X Jobs -> CJStates]
    /\ rn.pc \in RunnerPCs

\* Q1: free + reserved + allocated units equals capacity on every client (no duplicate/lost unit).
ResourceConservation ==
    \A c \in Clients : free[c] + Cardinality(resv[c]) + (LET S == {j \in Jobs : alloc[c, j] > 0}
                                                           IN Cardinality(S) + Cardinality({j \in S : alloc[c, j] > 1}))
                       = K

\* Q1: no unit is double-allocated to one job and free never exceeds capacity.
NoOverAllocation == \A c \in Clients : free[c] <= K /\ \A j \in Jobs : alloc[c, j] <= 1

\* Q1/Q2/Q4: every allocation is owned by a live START handler or a registered CJ whose waiter will free
\* it (otherwise it is lost for good — nothing else frees allocations).
AllocationOwned == \A c \in Clients, j \in Jobs : alloc[c, j] > 0 => Owned(c, j)

\* Q4 diagnostic (transient by design — released by expiry): every reservation belongs to the attempt the
\* runner is still working on.
ReservationTracked == \A c \in Clients : \A t \in resv[c] : InUse(t)

\* Q4 diagnostic: a later job's resource check was rejected while an abandoned reservation held a unit.
NoRejectionByLeftoverReservation == ~rejLeak
=============================================================================
