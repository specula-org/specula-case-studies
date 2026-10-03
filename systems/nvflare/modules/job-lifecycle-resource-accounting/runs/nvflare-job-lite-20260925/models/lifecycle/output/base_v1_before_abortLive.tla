------------------------------- MODULE base -------------------------------
(***************************************************************************)
(* NVFlare job lifecycle (server side) — Scenarios S1, S2, S4 of           *)
(* modeling-brief.md.                                                      *)
(*                                                                         *)
(* Source: nvflare @ 53ba7ee567468ea7971dad4faccef13c6cb35dc2.             *)
(* All paths below are relative to nvflare/.                               *)
(*                                                                         *)
(* Actors (independent threads in the real system):                        *)
(*   - JobRunner.run scheduling loop  (private/fed/server/job_runner.py)   *)
(*   - JobRunner._job_complete_process (one per job step, see note)        *)
(*   - admin command handlers: abort_job, delete_job (server/job_cmds.py)  *)
(*   - SJ process + ServerEngine.wait_for_complete / _remove_run_processes *)
(*   - client parents: START_JOB handling, CJ process, outcome report,     *)
(*     heartbeat reconciliation (fed_server.py:1004-1094)                  *)
(* Client resources are abstracted here (see models/resources).            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Jobs,       \* job ids (all SUBMITTED initially)
    Clients,    \* connected client sites; all applicable to every job
    MaxJobs,    \* DefaultJobScheduler.max_jobs (job_scheduler.py:41)
    MinSites,   \* job.min_sites (same for all jobs)
    NoJob       \* model value

(* Job store statuses, apis/job_def.py:26-39. "DELETED" = object removed    *)
(* from the store (SimpleJobDefManager.delete, job_def_manager.py:354-356). *)
Terminal == {"COMPLETED", "ABORTED", "EXCEPTION", "ABNORMAL", "FAILED"}
Statuses == {"SUBMITTED", "DISPATCHED", "RUNNING"} \cup Terminal
StoreVals == Statuses \cup {"DELETED"}

(* Return-code classes kept in engine.exception_run_processes:            *)
(* "none" = no entry; EXC = CONFIG_ERROR/EXCEPTION/EXECUTION_ERROR/        *)
(* PROCESS_EXE_ERROR; INFRA = INFRASTRUCTURE_ERROR; ABORTED = JobReturnCode.ABORTED *)
Codes == {"none", "EXC", "INFRA", "ABORTED"}

RunnerPCs == {"idle", "listed", "sched", "stat1", "deploy", "setDisp", "umRead", "umWrite",
              "stat2", "startSJ", "stWait", "addRun", "setRun",
              "exc", "excSet", "excMeta", "crashed"}

VARIABLES
    status,        \* job store meta status
    tagged,        \* _ScheduleJobFilter tag (job_def_manager.py:104-120)
    rn,            \* JobRunner.run thread state (job_runner.py:633-734)
    scheduled,     \* DefaultJobScheduler.scheduled_jobs (job_scheduler.py:59, 275-285)
    running,       \* JobRunner.running_jobs
    hasPending,    \* job_id in JobRunner._pending_client_outcomes
    pendingSet,    \* JobRunner._pending_client_outcomes[job_id]
    runAborted,    \* Job.run_aborted (job_runner.py:802-811)
    sj,            \* SJ process: "none" | "running" | "gone"
    sjAbortReq,    \* abort_app_on_server issued, _remove_run_processes pending
    runProc,       \* engine.run_processes keys
    excCode,       \* engine.exception_run_processes[job] return-code class
    participants,  \* run_processes[job][PARTICIPANTS] (job_clients at SJ start)
    comp,          \* _finished_job_states[job].status ("none" if not computed)
    cj,            \* CJ on client: "none" | "running" | "exited" | "gone"
    cjCode,        \* CJ exit-code class reported by the CJ waiter
    cjAbortReq,    \* ABORT admin requests in flight to clients: set of <<c, j>>
    stReq,         \* START_JOB requests in flight per client (set of job ids)
    stRep,         \* START_JOB reply per <<client, job>>: "none" | "ok" | "err"
    abortPc, abortSnap, abortAck,   \* admin abort_job (job_cmds.py:1051-1084)
    delPc, delSnap,                 \* admin delete_job (job_cmds.py:282-316, 507-548)
    launchAfterAck,  \* history: SJ launched after an "aborted before running" ack
    wasTerminal      \* history: status was terminal at some point

serverVars == <<status, tagged, rn, scheduled, running, hasPending, pendingSet, runAborted>>
procVars   == <<sj, sjAbortReq, runProc, excCode, participants, comp>>
clientVars == <<cj, cjCode, cjAbortReq, stReq, stRep>>
adminVars  == <<abortPc, abortSnap, abortAck, delPc, delSnap>>
histVars   == <<launchAfterAck, wasTerminal>>
vars == <<serverVars, procVars, clientVars, adminVars, histVars>>

-----------------------------------------------------------------------------
(* Helpers *)

\* Status that makes wasTerminal sticky
MarkTerminal(j, s) == IF s \in Terminal THEN [wasTerminal EXCEPT ![j] = TRUE] ELSE wasTerminal

\* JobRunner._classify_finished_job_status (job_runner.py:543-572)
Classify(code) ==
    CASE code = "none"    -> "COMPLETED"
      [] code = "INFRA"   -> "ABNORMAL"
      [] code = "ABORTED" -> "ABORTED"
      [] code = "EXC"     -> "EXCEPTION"

\* JobRunner._stop_run (job_runner.py:374-393): only when the SJ is still in run_processes;
\* abort_client_run to participants that are connected (all connected here), then abort_app_on_server.
StopRunCj(j, cur) == IF j \in runProc THEN cur \cup {<<c, j>> : c \in participants[j]} ELSE cur
StopRunSj(j, cur) == IF j \in runProc THEN cur \cup {j} ELSE cur

\* fail_run precedence (job_runner.py:828-832)
FailCode(old, new) == IF old # "INFRA" /\ (old = "none" \/ new # "ABORTED") THEN new ELSE old

\* JobRunner.fail_run (job_runner.py:813-852) as a state update.
\*   active: job in running_jobs or in run_processes
FailRunActive(j) == j \in running \/ j \in runProc

RunnerTo(pc) == rn' = [rn EXCEPT !.pc = pc]
RunnerExc(j, jobIdSet, detail) ==   \* enter the `except Exception` block (job_runner.py:713)
    rn' = [rn EXCEPT !.pc = "exc", !.jobId = jobIdSet, !.detail = detail]
RunnerCrash(why) == rn' = [rn EXCEPT !.pc = "crashed", !.why = why]

-----------------------------------------------------------------------------
Init ==
    /\ status = [j \in Jobs |-> "SUBMITTED"]
    /\ tagged = {}
    /\ rn = [pc |-> "idle", job |-> NoJob, listed |-> {}, cands |-> {}, clients |-> {},
             jobId |-> FALSE, detail |-> FALSE, snap |-> "SUBMITTED", why |-> "none"]
    /\ scheduled = {}
    /\ running = {}
    /\ hasPending = [j \in Jobs |-> FALSE]
    /\ pendingSet = [j \in Jobs |-> {}]
    /\ runAborted = [j \in Jobs |-> FALSE]
    /\ sj = [j \in Jobs |-> "none"]
    /\ sjAbortReq = {}
    /\ runProc = {}
    /\ excCode = [j \in Jobs |-> "none"]
    /\ participants = [j \in Jobs |-> {}]
    /\ comp = [j \in Jobs |-> "none"]
    /\ cj = [x \in Clients \X Jobs |-> "none"]
    /\ cjCode = [x \in Clients \X Jobs |-> "none"]
    /\ cjAbortReq = {}
    /\ stReq = [c \in Clients |-> {}]
    /\ stRep = [x \in Clients \X Jobs |-> "none"]
    /\ abortPc = [j \in Jobs |-> "idle"]
    /\ abortSnap = [j \in Jobs |-> "SUBMITTED"]
    /\ abortAck = [j \in Jobs |-> FALSE]
    /\ delPc = [j \in Jobs |-> "idle"]
    /\ delSnap = [j \in Jobs |-> "SUBMITTED"]
    /\ launchAfterAck = [j \in Jobs |-> FALSE]
    /\ wasTerminal = [j \in Jobs |-> FALSE]

-----------------------------------------------------------------------------
(***************************************************************************)
(* JobRunner.run scheduling loop (job_runner.py:633-734)                   *)
(***************************************************************************)

\* job_runner.py:650 -> SimpleJobDefManager.get_jobs_to_schedule -> _scan (job_def_manager.py:512-531):
\* store.list_objects(uri_root, without_tag=_OBJ_TAG_SCHEDULED) (filesystem_storage.py:277-308)
RunnerScanList ==
    /\ rn.pc = "idle"
    /\ rn' = [rn EXCEPT !.pc = "listed", !.listed = {j \in Jobs : status[j] # "DELETED" /\ j \notin tagged},
                        !.job = NoJob, !.clients = {}, !.jobId = FALSE, !.detail = FALSE]
    /\ UNCHANGED <<status, tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* _scan: for each listed uri, store.get_meta(job_uri) (job_def_manager.py:524-526).
\* get_meta raises StorageException if the object vanished (filesystem_storage.py:326-327);
\* job_runner.py:650 is outside the try block (666) and ServerDeployer._start_job_runner
\* (app/deployer/server_deployer.py:144-145) has no handler -> the scheduling thread ends.
\* _ScheduleJobFilter keeps SUBMITTED jobs and tags the others (job_def_manager.py:113-120).
RunnerScanRead ==
    /\ rn.pc = "listed"
    /\ IF \E j \in rn.listed : status[j] = "DELETED"
       THEN /\ RunnerCrash("scan:get_meta")
            /\ UNCHANGED tagged
       ELSE /\ rn' = [rn EXCEPT !.pc = "sched", !.cands = {j \in rn.listed : status[j] = "SUBMITTED"}]
            /\ tagged' = tagged \cup {j \in rn.listed : status[j] # "SUBMITTED"}
    /\ UNCHANGED <<status, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* DefaultJobScheduler.schedule_job -> _do_schedule_job (job_scheduler.py:287-378).
\* _exceed_max_jobs (263-273) uses scheduled_jobs. Candidate order/backoff abstracted: any candidate.
\* _try_job (104-261): resource check succeeds on a set `ok` of clients (|ok| >= MinSites), or the
\* job gets SCHEDULE_RESULT_NO_RESOURCE (bounded in MC via RunnerNoResource).
RunnerSchedule ==
    /\ rn.pc = "sched"
    /\ Cardinality(scheduled) < MaxJobs
    /\ \E j \in rn.cands, ok \in SUBSET Clients :
          /\ ok # {}
          /\ Cardinality(ok) >= MinSites
          /\ rn' = [rn EXCEPT !.pc = "stat1", !.job = j, !.clients = ok]
    /\ UNCHANGED <<status, tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* No job scheduled this round (max_jobs reached, no candidates, or NO_RESOURCE for all).
RunnerNoSchedule ==
    /\ rn.pc = "sched"
    /\ (Cardinality(scheduled) >= MaxJobs \/ rn.cands = {})
    /\ RunnerTo("idle")
    /\ UNCHANGED <<status, tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* A candidate gets NO_RESOURCE (reservations cancelled, job_scheduler.py:229-254); try next.
RunnerNoResource ==
    /\ rn.pc = "sched"
    /\ Cardinality(scheduled) < MaxJobs
    /\ \E j \in rn.cands : rn' = [rn EXCEPT !.cands = rn.cands \ {j}]
    /\ UNCHANGED <<status, tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* job_runner.py:661-663: `if self._check_job_status(job_manager, ready_job.job_id, SUBMITTED)` — outside try.
\* _check_job_status (736-739): reload_job = job_manager.get_job(...) -> None for a deleted job
\* (job_def_manager.py:379-385) -> `reload_job.meta` AttributeError escapes run().
RunnerCheckSubmitted ==
    /\ rn.pc = "stat1"
    /\ LET j == rn.job IN
         CASE status[j] = "DELETED"   -> RunnerCrash("stat1:get_job_none")
           [] status[j] # "SUBMITTED" -> RunnerTo("idle")          \* 662-663 `continue`
           [] OTHER                   -> RunnerTo("deploy")
    /\ UNCHANGED <<status, tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* job_runner.py:669 `_deploy_job` (149-285), one atomic step here (it never reads status):
\*   174 job.get_application(...) reads job data from the store -> exception if deleted (deploy_detail still []).
\*   184-214 server deploy, 241-267 client deploy replies. All clients OK here; job_id assigned (669).
RunnerDeploy ==
    /\ rn.pc = "deploy"
    /\ LET j == rn.job IN
         IF status[j] = "DELETED"
         THEN RunnerExc(j, FALSE, FALSE)
         ELSE rn' = [rn EXCEPT !.pc = "setDisp", !.jobId = TRUE, !.detail = TRUE]
    /\ UNCHANGED <<status, tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* Some clients fail/time out during deploy (fault): 251-267 failed_clients; 269-282 abort (RuntimeError,
\* job_id None) if num_ok_sites < min_sites, else continue with deployable clients only (692-695).
RunnerClientDeployFail ==
    /\ rn.pc = "deploy"
    /\ status[rn.job] # "DELETED"
    /\ \E failed \in (SUBSET rn.clients) \ {{}} :
          LET okc == rn.clients \ failed IN
            IF MinSites > 0 /\ Cardinality(okc) < MinSites
            THEN RunnerExc(rn.job, FALSE, TRUE)
            ELSE rn' = [rn EXCEPT !.pc = "setDisp", !.clients = okc, !.jobId = TRUE, !.detail = TRUE]
    /\ UNCHANGED <<status, tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* Server-side deploy failure (job_runner.py:194-209): RuntimeError, job_id None, deploy_detail non-empty.
RunnerServerDeployFail ==
    /\ rn.pc = "deploy"
    /\ status[rn.job] # "DELETED"
    /\ RunnerExc(rn.job, FALSE, TRUE)
    /\ UNCHANGED <<status, tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* job_runner.py:670 set_status(DISPATCHED): unconditional read-modify-write of the meta
\* (job_def_manager.py:459-481 -> filesystem_storage.update_meta 251-275). Raises StorageException
\* if the object is gone (267-268) -> except with job_id set.
RunnerSetDispatched ==
    /\ rn.pc = "setDisp"
    /\ LET j == rn.job IN
         IF status[j] = "DELETED"
         THEN /\ RunnerExc(j, TRUE, TRUE)
              /\ UNCHANGED <<status, wasTerminal>>
         ELSE /\ status' = [status EXCEPT ![j] = "DISPATCHED"]
              /\ RunnerTo("umRead")
              /\ UNCHANGED wasTerminal
    /\ UNCHANGED <<tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, launchAfterAck>>

\* job_runner.py:672-689 update_meta(deploy detail, schedule history) -> store.update_meta(replace=False):
\* prev_meta = get_meta(uri) (filesystem_storage.py:273) ...
RunnerUpdateMetaRead ==
    /\ rn.pc = "umRead"
    /\ LET j == rn.job IN
         IF status[j] = "DELETED"
         THEN RunnerExc(j, TRUE, TRUE)
         ELSE rn' = [rn EXCEPT !.pc = "umWrite", !.snap = status[j]]
    /\ UNCHANGED <<status, tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* ... prev_meta.update(meta); _write(META, prev_meta) (filesystem_storage.py:274-275): the whole meta,
\* including the status read in RunnerUpdateMetaRead, is written back. A deleted object stays invisible
\* (_write re-creates only the meta file; _object_exists needs data+meta, filesystem_storage.py:103-107).
RunnerUpdateMetaWrite ==
    /\ rn.pc = "umWrite"
    /\ LET j == rn.job IN
         /\ status' = IF status[j] = "DELETED" THEN status ELSE [status EXCEPT ![j] = rn.snap]
         /\ wasTerminal' = IF status[j] = "DELETED" THEN wasTerminal ELSE MarkTerminal(j, rn.snap)
    /\ RunnerTo("stat2")
    /\ UNCHANGED <<tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, launchAfterAck>>

\* job_runner.py:697-701 _check_job_status(DISPATCHED) inside try: deleted -> AttributeError -> except.
RunnerCheckDispatched ==
    /\ rn.pc = "stat2"
    /\ LET j == rn.job IN
         CASE status[j] = "DELETED"    -> RunnerExc(j, TRUE, TRUE)
           [] status[j] # "DISPATCHED" -> RunnerTo("idle")           \* 698-701 `continue`
           [] OTHER                    -> RunnerTo("startSJ")
    /\ UNCHANGED <<status, tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* _start_run (287-364), part 1:
\*   304 engine.start_app_on_server -> _start_runner_process (server_engine.py:236-329): SJ launched,
\*       run_processes[job] = {JOB_HANDLE, PARTICIPANTS=job_clients} (321-326), wait_for_complete thread.
\*   308-309 _pending_client_outcomes[job] = set(client_sites)
\*   310 engine.start_client_job -> START_JOB to each deployable client (server_engine.py:1068-1083).
RunnerStartSJ ==
    /\ rn.pc = "startSJ"
    /\ LET j == rn.job IN
         /\ sj' = [sj EXCEPT ![j] = "running"]
         /\ runProc' = runProc \cup {j}
         /\ participants' = [participants EXCEPT ![j] = rn.clients]
         /\ hasPending' = [hasPending EXCEPT ![j] = TRUE]
         /\ pendingSet' = [pendingSet EXCEPT ![j] = rn.clients]
         /\ stReq' = [c \in Clients |-> IF c \in rn.clients THEN stReq[c] \cup {j} ELSE stReq[c]]
         /\ stRep' = [x \in Clients \X Jobs |-> IF x[2] = j THEN "none" ELSE stRep[x]]
         /\ launchAfterAck' = [launchAfterAck EXCEPT ![j] = @ \/ abortAck[j]]
    /\ RunnerTo("stWait")
    /\ UNCHANGED <<status, tagged, scheduled, running, runAborted, sjAbortReq, excCode, comp,
                   cj, cjCode, cjAbortReq, adminVars, wasTerminal>>

\* SJ launch failure (launcher exception / "Server app does not exist", server_engine.py:179-196):
\* RuntimeError in _start_run -> except with job_id set; nothing in run_processes yet.
RunnerStartSJFail ==
    /\ rn.pc = "startSJ"
    /\ RunnerExc(rn.job, TRUE, TRUE)
    /\ UNCHANGED <<status, tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* _start_run part 2 (job_runner.py:311-364), default non-strict mode (STRICT_START_JOB_REPLY_CHECK=False):
\*   check_client_replies(strict=False) raises on explicit error replies (admin.py:133-140);
\*   timed-out clients are silently excluded: active = clients with a reply (345-353).
\*   359-360 `_pending_client_outcomes[job_id].intersection_update(...)` -> KeyError if fail_run popped it.
\*   364 JOB_STARTED -> DefaultJobScheduler.handle_event adds to scheduled_jobs (275-280).
CollectStartWith(replied) ==
    LET j == rn.job
        errs == {c \in replied : stRep[c, j] = "err"}
    IN
      IF errs # {}
      THEN /\ RunnerExc(j, TRUE, TRUE)
           /\ UNCHANGED <<pendingSet, scheduled>>
      ELSE IF ~hasPending[j]
           THEN /\ RunnerExc(j, TRUE, TRUE)        \* KeyError at 360
                /\ UNCHANGED <<pendingSet, scheduled>>
           ELSE /\ pendingSet' = [pendingSet EXCEPT ![j] = @ \cap replied]
                /\ scheduled' = scheduled \cup {j}
                /\ RunnerTo("addRun")

\* All START_JOB replies received within the 20 s timeout (server_engine.py:1081).
RunnerCollectStart ==
    /\ rn.pc = "stWait"
    /\ \A c \in rn.clients : stRep[c, rn.job] # "none"
    /\ CollectStartWith(rn.clients)
    /\ UNCHANGED <<status, tagged, running, hasPending, runAborted, procVars, clientVars, adminVars, histVars>>

\* Some START_JOB replies timed out (fault); the requests may still be processed later (late start).
RunnerCollectStartTimeout ==
    /\ rn.pc = "stWait"
    /\ LET replied == {c \in rn.clients : stRep[c, rn.job] # "none"} IN
         /\ replied # rn.clients
         /\ CollectStartWith(replied)
    /\ UNCHANGED <<status, tagged, running, hasPending, runAborted, procVars, clientVars, adminVars, histVars>>

\* job_runner.py:709-710 running_jobs[job_id] = ready_job
RunnerAddRunning ==
    /\ rn.pc = "addRun"
    /\ running' = running \cup {rn.job}
    /\ RunnerTo("setRun")
    /\ UNCHANGED <<status, tagged, scheduled, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* job_runner.py:711 set_status(RUNNING): unconditional; StorageException if deleted -> except.
RunnerSetRunning ==
    /\ rn.pc = "setRun"
    /\ LET j == rn.job IN
         IF status[j] = "DELETED"
         THEN /\ RunnerExc(j, TRUE, TRUE)
              /\ UNCHANGED status
         ELSE /\ status' = [status EXCEPT ![j] = "RUNNING"]
              /\ RunnerTo("idle")
    /\ UNCHANGED <<tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

\* except block, part 1 (job_runner.py:714-719): if job_id: drop running/pending, _stop_run(job_id).
RunnerExcCleanup ==
    /\ rn.pc = "exc"
    /\ LET j == rn.job IN
         IF rn.jobId
         THEN /\ running' = running \ {j}
              /\ hasPending' = [hasPending EXCEPT ![j] = FALSE]
              /\ cjAbortReq' = StopRunCj(j, cjAbortReq)
              /\ sjAbortReq' = StopRunSj(j, sjAbortReq)
         ELSE UNCHANGED <<running, hasPending, cjAbortReq, sjAbortReq>>
    /\ RunnerTo("excSet")
    /\ UNCHANGED <<status, tagged, scheduled, pendingSet, runAborted, sj, runProc, excCode, participants, comp,
                   cj, cjCode, stReq, stRep, adminVars, histVars>>

\* except block, part 2 (job_runner.py:720) set_status(FAILED_TO_RUN): StorageException for a deleted job
\* is raised inside the except block -> escapes run() -> scheduling thread ends.
RunnerExcSetFailed ==
    /\ rn.pc = "excSet"
    /\ LET j == rn.job IN
         IF status[j] = "DELETED"
         THEN /\ RunnerCrash("except:set_status")
              /\ UNCHANGED <<status, wasTerminal>>
         ELSE /\ status' = [status EXCEPT ![j] = "FAILED"]
              /\ wasTerminal' = [wasTerminal EXCEPT ![j] = TRUE]
              /\ RunnerTo("excMeta")
    /\ UNCHANGED <<tagged, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, launchAfterAck>>

\* except block, part 3 (job_runner.py:722-728): update_meta(deploy detail) if non-empty
\* (raises for a deleted job), then JOB_ABORTED -> scheduler removes the job (281-285).
RunnerExcFinish ==
    /\ rn.pc = "excMeta"
    /\ LET j == rn.job IN
         IF rn.detail /\ status[j] = "DELETED"
         THEN /\ RunnerCrash("except:update_meta")
              /\ UNCHANGED scheduled
         ELSE /\ scheduled' = scheduled \ {j}
              /\ RunnerTo("idle")
    /\ UNCHANGED <<status, tagged, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, adminVars, histVars>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* JobRunner._job_complete_process (job_runner.py:441-541)                 *)
(* Modeled per job (the loop handles jobs one at a time; different jobs'   *)
(* completion steps do not share state except running/scheduled sets).    *)
(***************************************************************************)

\* 444-492: job in running_jobs and not in run_processes. server_failed (451-454) clears pending;
\* if pending and not run_aborted, wait (466-472) unless the outcome deadline expired (see
\* CompleteAfterOutcomeDeadline). Final status computed once and cached (484-492); if the run is in
\* exception_run_processes, clients are asked to abort (_get_finished_job_status 574-585).
CompleteClassifyCore(j) ==
    LET st == IF runAborted[j] THEN "ABORTED" ELSE Classify(excCode[j]) IN
      /\ comp' = [comp EXCEPT ![j] = st]
      /\ cjAbortReq' = IF excCode[j] # "none"
                       THEN cjAbortReq \cup {<<c, j>> : c \in participants[j]}
                       ELSE cjAbortReq
      /\ hasPending' = IF excCode[j] \in {"EXC", "INFRA"} THEN [hasPending EXCEPT ![j] = FALSE] ELSE hasPending

CompleteClassify(j) ==
    /\ j \in running
    /\ j \notin runProc
    /\ comp[j] = "none"
    /\ \/ excCode[j] \in {"EXC", "INFRA"}              \* server_failed
       \/ ~hasPending[j] \/ pendingSet[j] = {} \/ runAborted[j]
    /\ CompleteClassifyCore(j)
    /\ UNCHANGED <<status, tagged, rn, scheduled, running, pendingSet, runAborted,
                   sj, sjAbortReq, runProc, excCode, participants,
                   cj, cjCode, stReq, stRep, adminVars, histVars>>

\* 471-476: client_outcome_wait_timeout (default 900 s) expired with outcomes still pending.
CompleteAfterOutcomeDeadline(j) ==
    /\ j \in running
    /\ j \notin runProc
    /\ comp[j] = "none"
    /\ hasPending[j] /\ pendingSet[j] # {} /\ ~runAborted[j]
    /\ excCode[j] \notin {"EXC", "INFRA"}
    /\ CompleteClassifyCore(j)
    /\ UNCHANGED <<status, tagged, rn, scheduled, running, pendingSet, runAborted,
                   sj, sjAbortReq, runProc, excCode, participants,
                   cj, cjCode, stReq, stRep, adminVars, histVars>>

\* 494-539: workspace saved (abstracted), job_manager.set_status(final) (524); on exception `continue`
\* (retry next loop, 525-530). Success: drop running/pending, JOB_ABORTED/JOB_COMPLETED (536-538)
\* -> scheduler removes the job; 540 remove_exception_process.
CompletePublish(j) ==
    /\ comp[j] # "none"
    /\ j \in running
    /\ status[j] # "DELETED"        \* a deleted job's set_status keeps failing (retried forever)
    /\ status' = [status EXCEPT ![j] = comp[j]]
    /\ wasTerminal' = [wasTerminal EXCEPT ![j] = TRUE]
    /\ running' = running \ {j}
    /\ hasPending' = [hasPending EXCEPT ![j] = FALSE]
    /\ scheduled' = scheduled \ {j}
    /\ excCode' = [excCode EXCEPT ![j] = "none"]
    /\ comp' = [comp EXCEPT ![j] = "none"]
    /\ UNCHANGED <<tagged, rn, pendingSet, runAborted, sj, sjAbortReq, runProc, participants,
                   clientVars, adminVars, launchAfterAck>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* SJ process (server_engine.py:203-234, 354-409)                          *)
(***************************************************************************)

\* wait_for_complete: after process exit, if still in run_processes record a non-zero return code
\* unless an entry already exists (218-232), then pop run_processes (233).
SJExitWith(j, code) ==
    /\ sj[j] = "running"
    /\ sj' = [sj EXCEPT ![j] = "gone"]
    /\ IF j \in runProc
       THEN /\ runProc' = runProc \ {j}
            /\ excCode' = IF code # "none" /\ excCode[j] = "none" THEN [excCode EXCEPT ![j] = code] ELSE excCode
       ELSE UNCHANGED <<runProc, excCode>>
    /\ sjAbortReq' = sjAbortReq \ {j}
    /\ UNCHANGED <<serverVars, participants, comp, clientVars, adminVars, histVars>>

\* Normal SJ completion (return code 0).
SJExitNormal(j) == SJExitWith(j, "none")

\* SJ failure (config error / exception) — fault.
SJExitFail(j) == SJExitWith(j, "EXC")

\* Exit after an ABORT command: graceful 0, ABORTED, or killed (-9 -> EXECUTION_ERROR via
\* process_launcher.py:29,51-55).
SJExitAborted(j) ==
    /\ j \in sjAbortReq
    /\ \E code \in {"none", "ABORTED", "EXC"} : SJExitWith(j, code)

\* _remove_run_processes (385-409): after the graceful wait, terminate the handle and pop
\* run_processes even if wait_for_complete has not yet observed the exit.
RemoveRunProcesses(j) ==
    /\ j \in sjAbortReq
    /\ j \in runProc
    /\ runProc' = runProc \ {j}
    /\ sj' = [sj EXCEPT ![j] = "gone"]
    /\ sjAbortReq' = sjAbortReq \ {j}
    /\ UNCHANGED <<serverVars, excCode, participants, comp, clientVars, adminVars, histVars>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* Client side (coarse): START_JOB, CJ exit, terminal-outcome report,     *)
(* ABORT handling, heartbeat reconciliation.                               *)
(***************************************************************************)

\* StartJobProcessor.process (client/scheduler_cmds.py:100-137) -> ClientEngine.start_app
\* (client/client_engine.py:349-382) -> JobExecutor.start_app (client/client_executor.py:198-334).
\* "ok": CJ launched; "err": explicit error reply (e.g. expired reservation, launcher failure).
\* The request may be processed after the server stopped waiting (late start).
ClientStartOk(c, j) ==
    /\ j \in stReq[c]
    /\ stReq' = [stReq EXCEPT ![c] = @ \ {j}]
    /\ cj' = [cj EXCEPT ![c, j] = "running"]
    /\ stRep' = [stRep EXCEPT ![c, j] = "ok"]
    /\ UNCHANGED <<serverVars, procVars, cjCode, cjAbortReq, adminVars, histVars>>

ClientStartErr(c, j) ==
    /\ j \in stReq[c]
    /\ stReq' = [stReq EXCEPT ![c] = @ \ {j}]
    /\ stRep' = [stRep EXCEPT ![c, j] = "err"]
    /\ UNCHANGED <<serverVars, procVars, cj, cjCode, cjAbortReq, adminVars, histVars>>

\* CJ process exit; code class seen by _wait_child_process_finish (client_executor.py:622-647).
CJExitWith(c, j, code) ==
    /\ cj[c, j] = "running"
    /\ cj' = [cj EXCEPT ![c, j] = "exited"]
    /\ cjCode' = [cjCode EXCEPT ![c, j] = code]
    /\ UNCHANGED <<serverVars, procVars, cjAbortReq, stReq, stRep, adminVars, histVars>>

CJExitNormal(c, j) == CJExitWith(c, j, "none")
CJExitFail(c, j) == CJExitWith(c, j, "EXC")

\* CJ waiter reports the terminal outcome (client_executor.py:648-674) ->
\* FederatedServer.process_job_failure (fed_server.py:906-957): if the client outcome is pending,
\* failure codes -> fail_run (then the client is resolved).
CJReport(c, j) ==
    /\ cj[c, j] = "exited"
    /\ cj' = [cj EXCEPT ![c, j] = "gone"]
    /\ LET code == cjCode[c, j]
           tracked == hasPending[j] /\ c \in pendingSet[j]
           fail == tracked /\ code \in {"EXC", "INFRA", "ABORTED"} /\ FailRunActive(j)
       IN
         /\ excCode' = IF fail THEN [excCode EXCEPT ![j] = FailCode(excCode[j], code)] ELSE excCode
         /\ hasPending' = IF fail THEN [hasPending EXCEPT ![j] = FALSE] ELSE hasPending
         /\ pendingSet' = IF tracked THEN [pendingSet EXCEPT ![j] = @ \ {c}] ELSE pendingSet
         /\ cjAbortReq' = IF fail THEN StopRunCj(j, cjAbortReq) ELSE cjAbortReq
         /\ sjAbortReq' = IF fail THEN StopRunSj(j, sjAbortReq) ELSE sjAbortReq
    /\ UNCHANGED <<status, tagged, rn, scheduled, running, runAborted, sj, runProc, participants, comp,
                   cjCode, stReq, stRep, adminVars, histVars>>

\* The report is not delivered (client communication stopped / timeout, client_executor.py:665-674).
CJReportLost(c, j) ==
    /\ cj[c, j] = "exited"
    /\ cj' = [cj EXCEPT ![c, j] = "gone"]
    /\ UNCHANGED <<serverVars, procVars, cjCode, cjAbortReq, stReq, stRep, adminVars, histVars>>

\* AbortAppProcessor -> ClientEngine.abort_app (client_engine.py:390-404) -> JobExecutor.abort_app:
\* a registered CJ is terminated; an unregistered one is ignored ("already stopped").
ClientAbort(c, j) ==
    /\ <<c, j>> \in cjAbortReq
    /\ cjAbortReq' = cjAbortReq \ {<<c, j>>}
    /\ IF cj[c, j] = "running"
       THEN /\ cj' = [cj EXCEPT ![c, j] = "exited"]
            /\ cjCode' = [cjCode EXCEPT ![c, j] = "ABORTED"]
       ELSE UNCHANGED <<cj, cjCode>>
    /\ UNCHANGED <<serverVars, procVars, stReq, stRep, adminVars, histVars>>

\* Heartbeat reconciliation, one job at a time (fed_server.py:1004-1076):
\* client reports its registered jobs; jobs not in server_jobs are aborted (heartbeat_cleanup).
HeartbeatAbort(c, j) ==
    /\ cj[c, j] \in {"running", "exited"}
    /\ LET serverJobs == runProc \cup {k \in Jobs : hasPending[k] /\ excCode[k] = "none"} IN
         j \notin serverJobs
    /\ cj[c, j] = "running"
    /\ cj' = [cj EXCEPT ![c, j] = "exited"]
    /\ cjCode' = [cjCode EXCEPT ![c, j] = "ABORTED"]
    /\ UNCHANGED <<serverVars, procVars, cjAbortReq, stReq, stRep, adminVars, histVars>>

\* Missing outcome: SJ gone, outcome still pending for c, but c no longer reports the job
\* (fed_server.py:1047-1073 -> _resolve_missing_client_outcome 1086-1094).
HeartbeatMissing(c, j) ==
    /\ hasPending[j] /\ c \in pendingSet[j]
    /\ j \notin runProc
    /\ cj[c, j] \in {"none", "gone"}      \* not in the client's run_processes (a START still in flight is not reported either)
    /\ LET fail == excCode[j] = "none" /\ FailRunActive(j) IN
         /\ excCode' = IF fail THEN [excCode EXCEPT ![j] = FailCode(excCode[j], "INFRA")] ELSE excCode
         /\ hasPending' = IF fail THEN [hasPending EXCEPT ![j] = FALSE] ELSE hasPending
         /\ cjAbortReq' = IF fail THEN StopRunCj(j, cjAbortReq) ELSE cjAbortReq
         /\ sjAbortReq' = IF fail THEN StopRunSj(j, sjAbortReq) ELSE sjAbortReq
    /\ pendingSet' = [pendingSet EXCEPT ![j] = @ \ {c}]
    /\ UNCHANGED <<status, tagged, rn, scheduled, running, runAborted, sj, runProc, participants, comp,
                   cj, cjCode, stReq, stRep, adminVars, histVars>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* Admin commands (server/job_cmds.py) — run in admin handler threads.    *)
(***************************************************************************)

\* abort_job 1057-1060: job = job_manager.get_job(job_id); job_status = job.meta[STATUS]
\* (a deleted job -> None.meta -> caught by the handler's broad except, 1080-1084).
AdminAbortRead(j) ==
    /\ abortPc[j] = "idle"
    /\ IF status[j] = "DELETED"
       THEN abortPc' = [abortPc EXCEPT ![j] = "done"] /\ UNCHANGED abortSnap
       ELSE abortPc' = [abortPc EXCEPT ![j] = "read"] /\ abortSnap' = [abortSnap EXCEPT ![j] = status[j]]
    /\ UNCHANGED <<serverVars, procVars, clientVars, abortAck, delPc, delSnap, histVars>>

\* abort_job 1061-1079:
\*   SUBMITTED/DISPATCHED -> set_status(FINISHED_ABORTED), reply "Aborted the job ... before running it."
\*   FINISHED:*           -> "already completed"
\*   otherwise            -> job_runner.stop_run (798-800): _stop_run then mark_run_aborted
AdminAbortAct(j) ==
    /\ abortPc[j] = "read"
    /\ CASE abortSnap[j] \in {"SUBMITTED", "DISPATCHED"} ->
              IF status[j] = "DELETED"      \* update_meta raises -> handler except, no ack
              THEN /\ abortPc' = [abortPc EXCEPT ![j] = "done"]
                   /\ UNCHANGED <<status, abortAck, wasTerminal, cjAbortReq, sjAbortReq>>
              ELSE /\ status' = [status EXCEPT ![j] = "ABORTED"]
                   /\ wasTerminal' = [wasTerminal EXCEPT ![j] = TRUE]
                   /\ abortAck' = [abortAck EXCEPT ![j] = TRUE]
                   /\ abortPc' = [abortPc EXCEPT ![j] = "done"]
                   /\ UNCHANGED <<cjAbortReq, sjAbortReq>>
         [] abortSnap[j] \in Terminal ->
              /\ abortPc' = [abortPc EXCEPT ![j] = "done"]
              /\ UNCHANGED <<status, abortAck, wasTerminal, cjAbortReq, sjAbortReq>>
         [] OTHER ->                               \* RUNNING: stop_run -> _stop_run
              /\ cjAbortReq' = StopRunCj(j, cjAbortReq)
              /\ sjAbortReq' = StopRunSj(j, sjAbortReq)
              /\ abortPc' = [abortPc EXCEPT ![j] = "mark"]
              /\ UNCHANGED <<status, abortAck, wasTerminal>>
    /\ UNCHANGED <<tagged, rn, scheduled, running, hasPending, pendingSet, runAborted,
                   sj, runProc, excCode, participants, comp, cj, cjCode, stReq, stRep,
                   abortSnap, delPc, delSnap, launchAfterAck>>

\* mark_run_aborted (802-811): sets run_aborted only if the job is still in running_jobs.
AdminAbortMark(j) ==
    /\ abortPc[j] = "mark"
    /\ runAborted' = IF j \in running THEN [runAborted EXCEPT ![j] = TRUE] ELSE runAborted
    /\ abortPc' = [abortPc EXCEPT ![j] = "done"]
    /\ UNCHANGED <<status, tagged, rn, scheduled, running, hasPending, pendingSet,
                   procVars, clientVars, abortSnap, abortAck, delPc, delSnap, histVars>>

\* delete_job: pre-authz authorize_job_id loads the job (282-316) — snapshot of its status.
AdminDeleteSnap(j) ==
    /\ delPc[j] = "idle"
    /\ status[j] # "DELETED"
    /\ delPc' = [delPc EXCEPT ![j] = "snap"]
    /\ delSnap' = [delSnap EXCEPT ![j] = status[j]]
    /\ UNCHANGED <<serverVars, procVars, clientVars, abortPc, abortSnap, abortAck, histVars>>

\* delete_job 516-528: refused if the snapshot status is DISPATCHED/RUNNING; else
\* job_def_manager.delete -> store.delete_object (filesystem_storage.py:415-433).
AdminDeleteAct(j) ==
    /\ delPc[j] = "snap"
    /\ delPc' = [delPc EXCEPT ![j] = "done"]
    /\ status' = IF delSnap[j] \notin {"DISPATCHED", "RUNNING"} /\ status[j] # "DELETED"
                 THEN [status EXCEPT ![j] = "DELETED"] ELSE status
    /\ UNCHANGED <<tagged, rn, scheduled, running, hasPending, pendingSet, runAborted,
                   procVars, clientVars, abortPc, abortSnap, abortAck, delSnap, histVars>>

-----------------------------------------------------------------------------
Next ==
    \/ RunnerScanList \/ RunnerScanRead \/ RunnerSchedule \/ RunnerNoSchedule \/ RunnerNoResource
    \/ RunnerCheckSubmitted \/ RunnerDeploy \/ RunnerClientDeployFail \/ RunnerServerDeployFail
    \/ RunnerSetDispatched \/ RunnerUpdateMetaRead \/ RunnerUpdateMetaWrite \/ RunnerCheckDispatched
    \/ RunnerStartSJ \/ RunnerStartSJFail \/ RunnerCollectStart \/ RunnerCollectStartTimeout
    \/ RunnerAddRunning \/ RunnerSetRunning
    \/ RunnerExcCleanup \/ RunnerExcSetFailed \/ RunnerExcFinish
    \/ \E j \in Jobs :
          \/ CompleteClassify(j) \/ CompleteAfterOutcomeDeadline(j) \/ CompletePublish(j)
          \/ SJExitNormal(j) \/ SJExitFail(j) \/ SJExitAborted(j) \/ RemoveRunProcesses(j)
          \/ AdminAbortRead(j) \/ AdminAbortAct(j) \/ AdminAbortMark(j)
          \/ AdminDeleteSnap(j) \/ AdminDeleteAct(j)
    \/ \E c \in Clients :
          \/ \E j \in Jobs :
                \/ ClientStartOk(c, j) \/ ClientStartErr(c, j)
                \/ CJExitNormal(c, j) \/ CJExitFail(c, j) \/ CJReport(c, j) \/ CJReportLost(c, j)
                \/ ClientAbort(c, j) \/ HeartbeatAbort(c, j) \/ HeartbeatMissing(c, j)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

TypeOK ==
    /\ status \in [Jobs -> StoreVals]
    /\ tagged \subseteq Jobs
    /\ rn.pc \in RunnerPCs
    /\ scheduled \subseteq Jobs
    /\ running \subseteq Jobs
    /\ hasPending \in [Jobs -> BOOLEAN]
    /\ pendingSet \in [Jobs -> SUBSET Clients]
    /\ runAborted \in [Jobs -> BOOLEAN]
    /\ sj \in [Jobs -> {"none", "running", "gone"}]
    /\ sjAbortReq \subseteq Jobs
    /\ runProc \subseteq Jobs
    /\ excCode \in [Jobs -> Codes]
    /\ comp \in [Jobs -> {"none"} \cup Terminal]
    /\ cj \in [Clients \X Jobs -> {"none", "running", "exited", "gone"}]
    /\ cjAbortReq \subseteq Clients \X Jobs
    /\ stReq \in [Clients -> SUBSET Jobs]
    /\ stRep \in [Clients \X Jobs -> {"none", "ok", "err"}]

\* S1 / MC-1: once the admin was told "Aborted the job ... before running it", the job must not be
\* launched afterwards and its status must remain FINISHED:ABORTED (flare_api.py:569-571:
\* "If job is not started yet, it will be cancelled and won't be scheduled").
AbortHonored ==
    \A j \in Jobs : abortAck[j] => (~launchAfterAck[j] /\ status[j] \in {"ABORTED", "DELETED"})

\* S1/S4: a terminal (FINISHED:*) status is never replaced by a non-terminal status.
TerminalStatusStable ==
    \A j \in Jobs : wasTerminal[j] => status[j] \in Terminal \cup {"DELETED"}

\* S2 / MC-2: the JobRunner scheduling loop never ends on an unhandled exception.
RunnerAlive == rn.pc # "crashed"

\* S2/S4: scheduled_jobs holds only jobs the runner or the completion path still owns.
NoStaleAdmission ==
    \A j \in scheduled :
        \/ j \in running
        \/ (rn.job = j /\ rn.pc \in {"addRun", "setRun", "exc", "excSet", "excMeta"})

\* S4 diagnostic: a job the admin successfully marked aborted while running ends FINISHED:ABORTED.
AckedRunAbortEndsAborted ==
    \A j \in Jobs : (runAborted[j] /\ ~(j \in running)) => status[j] \in {"ABORTED", "DELETED"}

\* ---- Diagnostic variants used to enumerate distinct counterexample paths (not contracts) ----
\* S1: the job is launched after the "aborted before running" acknowledgement.
AbortedNotLaunched == \A j \in Jobs : abortAck[j] => ~launchAfterAck[j]
\* S1: abort acknowledged while the job was DISPATCHED (runner in _start_run window).
AbortFromDispatchedHonored ==
    \A j \in Jobs : (abortAck[j] /\ abortSnap[j] = "DISPATCHED") => status[j] \in {"ABORTED", "DELETED"}
\* S2: runner crashes other than the list->get_meta scan race.
RunnerAliveExceptScan == rn.pc = "crashed" => rn.why = "scan:get_meta"
RunnerAliveExceptScanStat1 == rn.pc = "crashed" => rn.why \in {"scan:get_meta", "stat1:get_job_none"}
=============================================================================
