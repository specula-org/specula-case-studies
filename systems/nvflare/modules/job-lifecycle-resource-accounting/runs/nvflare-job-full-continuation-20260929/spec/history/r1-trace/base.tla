------------------------------- MODULE base -------------------------------
(***************************************************************************)
(* NVIDIA FLARE job lifecycle and resource accounting on the default       *)
(* local-process launch path.  Pinned source 53ba7ee5 (2026-09-11).        *)
(*                                                                         *)
(* Category A (distributed, request/reply RPC with timeouts) with          *)
(* concurrent-style action granularity inside the server parent (SP) and   *)
(* client parents (CP): every handler is split at the check-then-act and   *)
(* blocking-I/O boundaries the code keeps separate (modeling brief S1-S5). *)
(*                                                                         *)
(* Actors: SP runner thread (JobRunner.run), SP completion thread          *)
(* (_job_complete_process), SP admin handlers, SP cell handlers, SP        *)
(* per-SJ waiter / abort-cleanup threads, SP dead-client sweeper, per-job  *)
(* server job process (SJ), CP request handlers, CP per-CJ waiter, CP      *)
(* reservation-expiry thread, CP heartbeat, per-(client,job) client job    *)
(* process (CJ), and a lossy network.                                      *)
(*                                                                         *)
(* Source short names used in annotations (all under the source root):    *)
(*   job_runner.py        nvflare/private/fed/server/job_runner.py         *)
(*   job_scheduler.py     nvflare/app_common/job_schedulers/job_scheduler.py *)
(*   server_engine.py     nvflare/private/fed/server/server_engine.py      *)
(*   fed_server.py        nvflare/private/fed/server/fed_server.py         *)
(*   job_cmds.py          nvflare/private/fed/server/job_cmds.py           *)
(*   admin.py             nvflare/private/fed/server/admin.py              *)
(*   message_send.py      nvflare/private/fed/server/message_send.py       *)
(*   client_manager.py    nvflare/private/fed/server/client_manager.py     *)
(*   job_def_manager.py   nvflare/apis/impl/job_def_manager.py             *)
(*   fs_storage.py        nvflare/app_common/storages/filesystem_storage.py *)
(*   scheduler_cmds.py    nvflare/private/fed/client/scheduler_cmds.py     *)
(*   training_cmds.py     nvflare/private/fed/client/training_cmds.py      *)
(*   client_engine.py     nvflare/private/fed/client/client_engine.py      *)
(*   client_executor.py   nvflare/private/fed/client/client_executor.py    *)
(*   communicator.py      nvflare/private/fed/client/communicator.py       *)
(*   client_app_runner.py nvflare/private/fed/client/client_app_runner.py  *)
(*   server_app_runner.py nvflare/private/fed/server/server_app_runner.py  *)
(*   auto_clean.py        nvflare/app_common/resource_managers/auto_clean_resource_manager.py *)
(*   list_rm.py           nvflare/app_common/resource_managers/list_resource_manager.py *)
(*   process_launcher.py  nvflare/app_common/job_launcher/process_launcher.py *)
(*   process_utils.py     nvflare/utils/process_utils.py                   *)
(*   fed_utils.py         nvflare/private/fed/utils/fed_utils.py           *)
(*   server_deployer.py   nvflare/private/fed/app/deployer/server_deployer.py *)
(*                                                                         *)
(* Documented abstractions (see brief-coverage.md for the full list):      *)
(*  - set_status() is modeled as an atomic blind status write.  Its inner  *)
(*    read-modify-write can only revert non-status meta keys, which are    *)
(*    not modeled.  The four non-status meta RMW writers that CAN revert   *)
(*    status (job_scheduler.py:303,307 and job_runner.py:674) are split    *)
(*    into read / write steps (S1, F16); the except-path RMW at            *)
(*    job_runner.py:724 is merged (its only extra behaviour is a           *)
(*    terminal->terminal revert already reachable at :720).                *)
(*  - Resource units follow ListResourceManager semantics (discrete units, *)
(*    Need per client per job); Need = 0 is the provisioned default        *)
(*    GPUResourceManager(num_of_gpus=0): empty reservations, empty         *)
(*    allocations.  Float GPU memory (F8) and CUDA_VISIBLE_DEVICES binding *)
(*    (F13/CL-2/CL-3) are out of the model (brief section 3.2).            *)
(*  - Deployment content, archival, auth/signing and log streaming are     *)
(*    abstracted to "may fail"; workspace archival always succeeds.        *)
(*  - Scheduler back-off is a bounded nondeterministic skip; min/max       *)
(*    intervals are not timed.                                             *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Jobs,              \* job ids
    JobOrder,          \* Seq(Jobs): SUBMIT_TIME order used by job_scheduler.py:344
    Clients,           \* client sites (client parents)
    Units,             \* resource units of every client's resource manager (list_rm.py:47-50)
    Need,              \* units requested per client per job (get_resource_manager_spec, job_scheduler.py:179-182)
    DeploySites,       \* [Jobs -> SUBSET Clients]  deploy_map client sites
    MinSites,          \* [Jobs -> Nat]             meta min_clients (Job.min_sites)
    Required,          \* [Jobs -> SUBSET Clients]  meta mandatory_clients (Job.required_sites)
    MaxJobs,           \* DefaultJobScheduler.max_jobs            (job_scheduler.py:41,263-273)
    MaxScheduleCount,  \* DefaultJobScheduler.max_schedule_count  (job_scheduler.py:42,347-354)
    Expiry,            \* AutoCleanResourceManager.expiration_period in check_period ticks (auto_clean.py:27,102-117)
    PoisonAt,          \* [Jobs -> {"none","pre","post"}]  validator-accepted malformed min_clients (F4):
                       \*   "pre"  = numeric string, TypeError at job_scheduler.py:166 (before CHECK)
                       \*   "post" = null,           TypeError at job_scheduler.py:229 (after CHECK)
    EnableUnsupported, \* BOOLEAN: allow faults outside the supported envelope (F9 app dir removed before START)
    None               \* model value: "absent" (Python None / missing dict entry)

ASSUME Len(JobOrder) = Cardinality(Jobs) /\ {JobOrder[i] : i \in 1..Len(JobOrder)} = Jobs
ASSUME Need \in Nat /\ Need <= Cardinality(Units)
ASSUME \A j \in Jobs : /\ DeploySites[j] \subseteq Clients
                       /\ Required[j] \subseteq DeploySites[j]
                       /\ MinSites[j] \in 1..Cardinality(DeploySites[j])
                       /\ PoisonAt[j] \in {"none", "pre", "post"}
ASSUME MaxJobs \in Nat \ {0} /\ MaxScheduleCount \in Nat \ {0} /\ Expiry \in Nat \ {0}
ASSUME EnableUnsupported \in BOOLEAN

(***************************************************************************)
(* Job status values (nvflare/apis/job_def.py:26-38).  DELETED is a model  *)
(* marker for "object removed from the job store" (fs_storage.py:326-327:  *)
(* get_meta raises StorageException; job_def_manager.py:379-385: get_job   *)
(* returns None).                                                          *)
(***************************************************************************)
SUBMITTED     == "SUBMITTED"
DISPATCHED    == "DISPATCHED"
RUNNING       == "RUNNING"
COMPLETED     == "FINISHED:COMPLETED"
ABORTED       == "FINISHED:ABORTED"
EXEC_EXC      == "FINISHED:EXECUTION_EXCEPTION"
ABNORMAL      == "FINISHED:ABNORMAL"
CANT_SCHED    == "FINISHED:CAN_NOT_SCHEDULE"
FAILED_TO_RUN == "FINISHED:FAILED_TO_RUN"
DELETED       == "DELETED"

Terminal  == {COMPLETED, ABORTED, EXEC_EXC, ABNORMAL, CANT_SCHED, FAILED_TO_RUN}   \* job_cli.py:1926-1936 "FINISHED:*"
StatusVals == {SUBMITTED, DISPATCHED, RUNNING, DELETED} \cup Terminal

(* Return codes: JobReturnCode (job_launcher_spec.py:66-70) and ProcessExitCode (exit_codes.py:16-21). *)
RC_NONE      == 0     \* PROCESS_RETURN_CODE not set (None); rc 0 is never recorded (server_engine.py:217)
RC_EXEC_ERR  == 1     \* JobReturnCode.EXECUTION_ERROR (also every non-{0,1,9} exit, process_launcher.py:51-55)
RC_ABORTED   == 9
RC_EXCEPTION == 101
RC_UNSAFE    == 102
RC_CONFIG    == 103
RC_INFRA     == 104
RCs == {RC_NONE, RC_EXEC_ERR, RC_ABORTED, RC_EXCEPTION, RC_UNSAFE, RC_CONFIG, RC_INFRA}

(* Client job-process status reported to the CP (ClientStatus). *)
STARTING == "STARTING"
STARTED  == "STARTED"
STOPPED  == "STOPPED"

(* CJ leader exit codes as seen through get_return_code (fed_utils.py:547-564): 0, generic 1 (every
   exception/signal exit is normalised to 1 by process_launcher.py:51-55), 102 only via an rc file
   written when non-daemon threads linger (mpm.py:180-199). *)
CjExitCodes == {0, RC_EXEC_ERR, RC_UNSAFE}

(* SJ terminal outcomes <<execution_error flag, normalised exit code>> (server_app_runner.py:55-99):
   normal end; exception (FATAL_SYSTEM_ERROR set, mpm rc 101 -> 1); FATAL flag without exception. *)
SjOutcomes == {<<FALSE, 0>>, <<TRUE, RC_EXEC_ERR>>, <<TRUE, 0>>}

VARIABLES
    \* ---- Job store (SimpleJobDefManager over FilesystemStorage) ----
    status,        \* [Jobs -> StatusVals]      persisted meta "status"
    pCount,        \* [Jobs -> Nat]             persisted meta SCHEDULE_COUNT
    tagged,        \* SUBSET Jobs               "scheduled" tag file (job_def_manager.py:113-120)
    firstTerm,     \* [Jobs -> Terminal \cup {None}] history: first terminal status ever written
    ovw,           \* history: set of [j, w, from, to] status writes that replaced a terminal status
    \* ---- SP runner thread (JobRunner.run + DefaultJobScheduler.schedule_job) ----
    rpc,           \* runner program counter and locals (see RpcIdle)
    \* ---- SP completion thread (_job_complete_process) ----
    cpc,           \* [pc, job]
    \* ---- SP in-memory tables ----
    slots,         \* SUBSET Jobs  DefaultJobScheduler.scheduled_jobs (job_scheduler.py:59,275-285)
    runningJobs,   \* SUBSET Jobs  JobRunner.running_jobs (job_runner.py:105)
    runAborted,    \* [Jobs -> BOOLEAN] Job.run_aborted on the object held in running_jobs (job_runner.py:807)
    pending,       \* [Jobs -> SUBSET Clients \cup {None}] _pending_client_outcomes (job_runner.py:107)
    latched,       \* [Jobs -> Terminal \cup {None}] _finished_job_states status latch (job_runner.py:484-492)
    \* ---- SJ processes and ServerEngine bookkeeping ----
    sj,            \* [Jobs -> {"None","Running","Exited"}] server job process
    sjRC,          \* [Jobs -> RCs] normalised SJ exit code (process_launcher.py:51-55)
    sjErr,         \* [Jobs -> BOOLEAN] history/ground truth: SJ ended with an execution error
    rp,            \* [Jobs -> Rec \cup {None}] ServerEngine.run_processes[job] dict
    exc,           \* [Jobs -> Rec \cup {None}] ServerEngine.exception_run_processes[job] dict
    shared,        \* [Jobs -> BOOLEAN] exc[j] and rp[j] are the same dict object
    wfc,           \* [Jobs -> BOOLEAN] wait_for_complete thread alive (server_engine.py:203,328)
    wfcStale,      \* [Jobs -> Rec \cup {None}] run_processes entry that _remove_run_processes popped while the
                   \*   SJ's wait_for_complete thread was alive (it may already hold it, server_engine.py:205)
    rmp,           \* [Jobs -> Nat] pending _remove_run_processes threads (server_engine.py:374-378)
    \* ---- SP admin / sessions / sweeper ----
    adm,           \* [Jobs -> [pc, snap]] in-flight admin command per job
    sessions,      \* SUBSET Clients  ClientManager.clients (registered, not disabled/removed)
    disabled,      \* SUBSET Clients  ClientManager.disabled_clients
    sweeper,       \* [pc, cl, snap, blocking] BaseServer.client_cleanup thread
    \* ---- Client parents ----
    cpAlive,       \* [Clients -> BOOLEAN] CP process alive
    free,          \* [Clients -> [Units -> Nat]] resource pool as a bag (duplication/loss visible)
    resv,          \* [Clients -> SUBSET [tok, job, units, ttl]] AutoClean reserved_resources
    cst,           \* [Clients -> [Jobs -> [pc, units, tok] \cup {None}]] StartJobProcessor in progress
    cjReg,         \* [Clients -> [Jobs -> [st, attached, pendAbort, abortReq] \cup {None}]] JobExecutor.run_processes
    alloc,         \* [Clients -> [Jobs -> SUBSET Units]] allocation handed to _wait_child_process_finish
    waiter,        \* [Clients -> [Jobs -> BOOLEAN]] _wait_child_process_finish thread alive
    termP,         \* [Clients -> [Jobs -> Nat]] pending _terminate_job threads (client_executor.py:581-601) started by
                   \*   ABORT requests handled on the CP cell worker pool (one thread per abort_app call)
    termHb,        \* [Clients -> [Jobs -> Nat]] pending _terminate_job threads started by heartbeat-cleanup aborts
                   \*   (the heartbeat thread joins them, communicator.py:621-624, 640-646)
    cjAbortMsg,    \* [Clients -> [Jobs -> Nat]] ABORTs fired to the CJ cell, not yet handled (client_executor.py:522-529)
    \* ---- Client job processes ----
    cjProc,        \* [Clients -> [Jobs -> {"None","Alive","Exited"}]] CJ leader process
    cjRC,          \* [Clients -> [Jobs -> Nat]] CJ leader exit code
    grp,           \* [Clients -> [Jobs -> BOOLEAN]] same-process-group descendants alive (F10)
    using,         \* [Clients -> [Jobs -> SUBSET Units]] units the job's processes may still use
    \* ---- Network ----
    msgs,          \* multiset of in-flight messages: [message record -> copies >= 1] (see M, Send, Consume)
    nextAtt,       \* next CHECK attempt id; also the reservation token id
    \* ---- History variables (property bookkeeping only) ----
    ackAbort,      \* [Jobs -> BOOLEAN] admin told "Aborted the job ... before running it." (job_cmds.py:1063)
    ackStop,       \* [Jobs -> BOOLEAN] admin told "Abort signal has been sent" (job_cmds.py:1076-1078)
    launches,      \* [Jobs -> Nat] SJ launches
    postAckLaunch, \* [Jobs -> BOOLEAN] an SJ or CJ of j was launched after ackAbort[j]
    startedEv,     \* [Jobs -> BOOLEAN] JOB_STARTED fired (job_runner.py:364)
    endedEv,       \* [Jobs -> BOOLEAN] JOB_COMPLETED or JOB_ABORTED fired (job_runner.py:537-538,728)
    failAccepted,  \* [Jobs -> BOOLEAN] a client failure report passed process_job_failure's pending check
    exeErrRec,     \* [Jobs -> BOOLEAN] an SJ execution error was recorded by UPDATE_RUN_STATUS
    sjAbortHandled,\* [Jobs -> BOOLEAN] a running SJ ended because it handled an ABORT command
    abortDropped,  \* [Clients -> [Jobs -> BOOLEAN]] a CP ABORT was dropped while a START was in progress (CL-1)
    failRunRec,    \* [Jobs -> BOOLEAN] an active fail_run recorded an authoritative failure code (D8)
    startFailCause,\* [Jobs -> {"none","error","keyerror"}] why _start_run raised (genuine vs KeyError at :360)
    ackInWindow    \* [Jobs -> BOOLEAN] ackAbort happened while the runner held j between :661 and :711 (F1 windows)

storeVars  == <<status, pCount, tagged, firstTerm, ovw>>
tableVars  == <<slots, runningJobs, runAborted, pending, latched>>
sjVars     == <<sj, sjRC, sjErr, rp, exc, shared, wfc, wfcStale, rmp>>
adminVars  == <<adm, sessions, disabled, sweeper>>
cpVars     == <<cpAlive, free, resv, cst, cjReg, alloc, waiter, termP, termHb, cjAbortMsg>>
cjVars     == <<cjProc, cjRC, grp, using>>
netVars    == <<msgs, nextAtt>>
histVars   == <<ackAbort, ackStop, launches, postAckLaunch, startedEv, endedEv,
                failAccepted, exeErrRec, sjAbortHandled, abortDropped, failRunRec, startFailCause,
                ackInWindow>>
vars == <<storeVars, rpc, cpc, tableVars, sjVars, adminVars, cpVars, cjVars, netVars, histVars>>

(* Variables that determine behaviour.  firstTerm, ovw, sjErr and histVars are write-only history: no action
   reads them in a guard or in a non-history update, so a VIEW may drop the ones a check does not read. *)
behVars == <<status, pCount, tagged, rpc, cpc, tableVars, sj, sjRC, rp, exc, shared, wfc, wfcStale, rmp, adminVars,
             cpVars, cjVars, netVars>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

RECURSIVE SumOver(_, _)
SumOver(b, D) == IF D = {} THEN 0 ELSE LET x == CHOOSE y \in D : TRUE IN b[x] + SumOver(b, D \ {x})
BagSize(b) == SumOver(b, Units)
AddUnits(b, S) == [u \in Units |-> b[u] + (IF u \in S THEN 1 ELSE 0)]
TakeUnits(b, S) == [u \in Units |-> b[u] - (IF u \in S THEN 1 ELSE 0)]

(* Uniform message record.  type: CHECK, CHECK_REP, CANCEL, START, START_REP, ABORT, REPORT,
   RUNSTATUS (SJ -> SP UPDATE_RUN_STATUS), SJABORT (SP -> SJ ABORT command). *)
M(t, j, c, a, ok, code, flag) ==
    [type |-> t, job |-> j, cl |-> c, att |-> a, ok |-> ok, code |-> code, flag |-> flag]
CheckReq(j, c, a)     == M("CHECK", j, c, a, FALSE, 0, FALSE)
CheckRep(j, c, a, ok) == M("CHECK_REP", j, c, a, ok, 0, FALSE)
CancelReq(j, c, a)    == M("CANCEL", j, c, a, FALSE, 0, FALSE)
StartReq(j, c, a)     == M("START", j, c, a, FALSE, 0, FALSE)
StartRep(j, c, err)   == M("START_REP", j, c, 0, FALSE, 0, err)
AbortReq(j, c, hb)    == M("ABORT", j, c, 0, FALSE, 0, hb)
Report(j, c, code)    == M("REPORT", j, c, 0, FALSE, code, FALSE)
RunStatus(j, exeErr)  == M("RUNSTATUS", j, None, 0, FALSE, 0, exeErr)
SjAbort(j)            == M("SJABORT", j, None, 0, FALSE, 0, FALSE)
ClientBound == {"CHECK", "CANCEL", "START", "ABORT"}

(* In-flight messages form a multiset.  CellNet does not deduplicate: identical requests sent by independent
   senders are each delivered and processed (e.g. fail_run's _stop_run and the runner's except-path _stop_run
   both send ABORT(j) to every participant and to the SJ, job_runner.py:374-393, 714-719, 843). *)
NoMsgs == [x \in {} |-> 0]
Send(B, S) == [x \in DOMAIN B \cup S |-> (IF x \in DOMAIN B THEN B[x] ELSE 0) + (IF x \in S THEN 1 ELSE 0)]
Consume(B, m) == IF B[m] = 1 THEN [x \in DOMAIN B \ {m} |-> B[x]] ELSE [B EXCEPT ![m] = @ - 1]
ConsumeAll(B, S) == [x \in DOMAIN B \ S |-> B[x]]
Keep(B, S) == [x \in S |-> B[x]]

(* A request to a dead CP is never processed: model it as not delivered. *)
LiveOf(S) == {c \in S : cpAlive[c]}
AbortMsgs(j, S, hb) == {AbortReq(j, c, hb) : c \in LiveOf(S)}

(* ServerEngine run-process dict (RunProcessKey fields that matter here). *)
NewRec(parts) == [finished |-> FALSE, exeErr |-> FALSE, rc |-> RC_NONE, parts |-> parts]

(* JobRunner._classify_finished_job_status (job_runner.py:543-572). *)
Classify(rec) ==
    IF rec = None THEN COMPLETED                                               \* :545-546
    ELSE IF rec.rc = RC_INFRA THEN ABNORMAL                                    \* :550-551
    ELSE IF rec.rc = RC_ABORTED THEN ABORTED                                   \* :552-553
    ELSE IF rec.rc \in {RC_CONFIG, RC_EXCEPTION, RC_UNSAFE, RC_EXEC_ERR}       \* :554-563
         THEN EXEC_EXC
    ELSE IF rec.finished                                                       \* :564-568
         THEN (IF rec.exeErr THEN EXEC_EXC ELSE COMPLETED)
    ELSE EXEC_EXC                                                              \* :569-572 (-9 branch unreachable, U5)

(* fail_run return-code merge rule (job_runner.py:828-832). *)
NewRC(existing, code) ==
    IF existing # RC_INFRA /\ (existing = RC_NONE \/ code # RC_ABORTED) THEN code ELSE existing

(* fail_run is "active" iff the job is in running_jobs or run_processes (job_runner.py:817-820). *)
FailRunActive(j) == j \in runningJobs \/ rp[j] # None

(* The dict fail_run mutates (job_runner.py:823-827) and its updated value. *)
FailRunBase(j) == IF exc[j] # None THEN exc[j] ELSE IF rp[j] # None THEN rp[j] ELSE NewRec({})
FailRunRec(j, code) == [FailRunBase(j) EXCEPT !.rc = NewRC(@, code)]

(* Per-job functional updates of rp / exc / shared for fail_run(j, code) on an active job. *)
FailRunRp(j, code) ==
    IF (exc[j] # None /\ shared[j]) \/ (exc[j] = None /\ rp[j] # None) THEN FailRunRec(j, code) ELSE rp[j]
FailRunShared(j) ==
    IF exc[j] = None THEN rp[j] # None ELSE shared[j]

(* _stop_run (job_runner.py:374-393): only when the SJ is still in run_processes it aborts the
   connected participants (abort_client_run :395-413, 2 s optional, replies ignored) and the SJ
   (abort_app_on_server, server_engine.py:354-383: ABORT command + non-daemon cleanup thread). *)
StopRunMsgs(j) ==
    IF rp[j] # None THEN AbortMsgs(j, rp[j].parts \cap sessions, FALSE) \cup {SjAbort(j)} ELSE {}
StopRunRmp(j) == IF rp[j] # None THEN rmp[j] + 1 ELSE rmp[j]

(* Blind persisted status write by writer w; maintains the firstTerm / ovw history (overwrites of a
   terminal status are recorded with their writer so hunting can separate known seeds from new paths). *)
WriteStatus(j, s, w) ==
    /\ status' = [status EXCEPT ![j] = s]
    /\ firstTerm' = [firstTerm EXCEPT ![j] = IF @ = None /\ s \in Terminal THEN s ELSE @]
    /\ ovw' = IF status[j] \in Terminal /\ s # status[j]
              THEN ovw \cup {[j |-> j, w |-> w, from |-> status[j], to |-> s]}
              ELSE ovw

(* Runner locals.  Unused fields are reset to canonical values. *)
NoCnt == [j \in Jobs |-> 0]
RpcIdle ==
    [pc |-> "Scan", listed |-> {}, queue |-> <<>>, cnt |-> NoCnt, job |-> None, att |-> 0,
     chk |-> {}, failed |-> <<>>, blocked |-> <<>>, fb |-> <<>>, ready |-> None, disp |-> {},
     dep |-> {}, jid |-> FALSE, snap |-> None, sreq |-> {}]

(* job_scheduler.py:298-311 (process failed then blocked jobs), then job_runner.py:660. *)
AfterFB(r) ==
    IF r.ready # None THEN [r EXCEPT !.pc = "ChkSubmitted", !.fb = <<>>, !.snap = None] ELSE RpcIdle
EndSchedule(r) ==
    LET r2 == [r EXCEPT !.fb = r.failed \o r.blocked, !.failed = <<>>, !.blocked = <<>>,
                        !.queue = <<>>, !.job = None, !.chk = {},
                        !.att = IF r.ready # None THEN r.att ELSE 0]
    IN IF r2.fb # <<>> THEN [r2 EXCEPT !.pc = "RefreshRead"] ELSE AfterFB(r2)
NextFB(r) ==
    LET r2 == [r EXCEPT !.fb = Tail(r.fb), !.snap = None]
    IN IF r2.fb # <<>> THEN [r2 EXCEPT !.pc = "RefreshRead"] ELSE AfterFB(r2)

CmpIdle == [pc |-> "Idle", job |-> None]
AdmIdle == [pc |-> "Idle", snap |-> None]
SweepIdle == [pc |-> "Idle", cl |-> None, snap |-> 0, blocking |-> FALSE]

RunnerAlive == rpc.pc # "Dead"

(* Runner holds j as the scheduled job between the SUBMITTED re-check and the RUNNING write (F1 windows). *)
F1Window == {"RefreshRead", "RefreshWrite", "SetCantSched", "ChkSubmitted", "Deploy", "SetDispatched",
             "MetaRead", "MetaWrite", "ChkDispatched", "StartSJ", "StartWait", "InsertRunning", "SetRunning"}

(* Default constant bindings for the plain base.cfg (TLC cfg files cannot spell functions). *)
DefaultJobOrder    == CHOOSE s \in [1..Cardinality(Jobs) -> Jobs] : {s[i] : i \in DOMAIN s} = Jobs
DefaultDeploySites == [j \in Jobs |-> Clients]
DefaultMinSites    == [j \in Jobs |-> 1]
DefaultRequired    == [j \in Jobs |-> {}]
DefaultPoisonAt    == [j \in Jobs |-> "none"]

-----------------------------------------------------------------------------
(***************************************************************************)
(* Initial state: every job SUBMITTED (job_def_manager.py:308-328 create), *)
(* every client registered with a full pool, all threads idle.             *)
(***************************************************************************)
Init ==
    /\ status = [j \in Jobs |-> SUBMITTED]
    /\ pCount = [j \in Jobs |-> 0]
    /\ tagged = {}
    /\ firstTerm = [j \in Jobs |-> None]
    /\ ovw = {}
    /\ rpc = RpcIdle
    /\ cpc = CmpIdle
    /\ slots = {}
    /\ runningJobs = {}
    /\ runAborted = [j \in Jobs |-> FALSE]
    /\ pending = [j \in Jobs |-> None]
    /\ latched = [j \in Jobs |-> None]
    /\ sj = [j \in Jobs |-> "None"]
    /\ sjRC = [j \in Jobs |-> 0]
    /\ sjErr = [j \in Jobs |-> FALSE]
    /\ rp = [j \in Jobs |-> None]
    /\ exc = [j \in Jobs |-> None]
    /\ shared = [j \in Jobs |-> FALSE]
    /\ wfc = [j \in Jobs |-> FALSE]
    /\ wfcStale = [j \in Jobs |-> None]
    /\ rmp = [j \in Jobs |-> 0]
    /\ adm = [j \in Jobs |-> AdmIdle]
    /\ sessions = Clients
    /\ disabled = {}
    /\ sweeper = SweepIdle
    /\ cpAlive = [c \in Clients |-> TRUE]
    /\ free = [c \in Clients |-> [u \in Units |-> 1]]
    /\ resv = [c \in Clients |-> {}]
    /\ cst = [c \in Clients |-> [j \in Jobs |-> None]]
    /\ cjReg = [c \in Clients |-> [j \in Jobs |-> None]]
    /\ alloc = [c \in Clients |-> [j \in Jobs |-> {}]]
    /\ waiter = [c \in Clients |-> [j \in Jobs |-> FALSE]]
    /\ termP = [c \in Clients |-> [j \in Jobs |-> 0]]
    /\ termHb = [c \in Clients |-> [j \in Jobs |-> 0]]
    /\ cjAbortMsg = [c \in Clients |-> [j \in Jobs |-> 0]]
    /\ cjProc = [c \in Clients |-> [j \in Jobs |-> "None"]]
    /\ cjRC = [c \in Clients |-> [j \in Jobs |-> 0]]
    /\ grp = [c \in Clients |-> [j \in Jobs |-> FALSE]]
    /\ using = [c \in Clients |-> [j \in Jobs |-> {}]]
    /\ msgs = NoMsgs
    /\ nextAtt = 1
    /\ ackAbort = [j \in Jobs |-> FALSE]
    /\ ackStop = [j \in Jobs |-> FALSE]
    /\ launches = [j \in Jobs |-> 0]
    /\ postAckLaunch = [j \in Jobs |-> FALSE]
    /\ startedEv = [j \in Jobs |-> FALSE]
    /\ endedEv = [j \in Jobs |-> FALSE]
    /\ failAccepted = [j \in Jobs |-> FALSE]
    /\ exeErrRec = [j \in Jobs |-> FALSE]
    /\ sjAbortHandled = [j \in Jobs |-> FALSE]
    /\ abortDropped = [c \in Clients |-> [j \in Jobs |-> FALSE]]
    /\ failRunRec = [j \in Jobs |-> FALSE]
    /\ startFailCause = [j \in Jobs |-> "none"]
    /\ ackInWindow = [j \in Jobs |-> FALSE]

-----------------------------------------------------------------------------
(***************************************************************************)
(* SP runner thread: JobRunner.run (job_runner.py:633-731), one bare       *)
(* thread started once (server_deployer.py:136,144-145).  Scenario S1/S2.  *)
(***************************************************************************)

OnlyRpc == UNCHANGED <<storeVars, cpc, tableVars, sjVars, adminVars, cpVars, cjVars, netVars, histVars>>

(* :641-650 tick; HotState assumed; no scheduling while no client is registered (:646-648);
   get_jobs_to_schedule -> _scan: list_objects(without_tag="scheduled") (job_def_manager.py:510-519,
   fs_storage.py:277-306). *)
RunnerScanList ==
    /\ rpc.pc = "Scan"
    /\ sessions # {}
    /\ rpc' = [RpcIdle EXCEPT !.pc = "ScanRead",
                              !.listed = {j \in Jobs : status[j] # DELETED /\ j \notin tagged}]
    /\ OnlyRpc

(* _scan reads each listed object's meta (job_def_manager.py:523-530).  A job deleted after the listing
   raises StorageException (fs_storage.py:325-327); :650 is outside the loop's try, so run() dies (RS-1). *)
RunnerScanReadDeleted ==
    /\ rpc.pc = "ScanRead"
    /\ \E j \in rpc.listed : status[j] = DELETED
    /\ rpc' = [RpcIdle EXCEPT !.pc = "Dead"]
    /\ OnlyRpc

(* _ScheduleJobFilter (job_def_manager.py:104-120): SUBMITTED -> candidate, else tag "scheduled".
   Then schedule_job -> _do_schedule_job: _exceed_max_jobs (job_scheduler.py:339-341) and the sort by
   SUBMIT_TIME (:343-344).  The in-memory Job objects carry the persisted SCHEDULE_COUNT. *)
RunnerScanRead ==
    /\ rpc.pc = "ScanRead"
    /\ \A j \in rpc.listed : status[j] # DELETED
    /\ LET cands == {j \in rpc.listed : status[j] = SUBMITTED}
           q == SelectSeq(JobOrder, LAMBDA x : x \in cands)
       IN /\ tagged' = tagged \cup {j \in rpc.listed : status[j] # SUBMITTED}
          /\ rpc' = IF Cardinality(slots) >= MaxJobs \/ q = <<>>
                    THEN RpcIdle
                    ELSE [RpcIdle EXCEPT !.pc = "TryNext", !.queue = q, !.cnt = [j \in Jobs |-> pCount[j]]]
    /\ UNCHANGED <<status, pCount, firstTerm, ovw, cpc, tableVars, sjVars, adminVars, cpVars, cjVars,
                   netVars, histVars>>

(* One candidate of the _do_schedule_job loop (job_scheduler.py:346-365) up to the CHECK_RESOURCE
   fan-out inside _try_job (:104-199; server_engine.py:1010-1024, 15 s). *)
RunnerTryNext ==
    /\ rpc.pc = "TryNext"
    /\ rpc.queue # <<>>
    /\ LET h    == Head(rpc.queue)
           r1   == [rpc EXCEPT !.queue = Tail(rpc.queue)]
           app  == DeploySites[h] \cap sessions                                   \* :106-136 online deploy sites
           bump == [r1 EXCEPT !.cnt[h] = @ + 1]                                   \* :369 -> :320-333 history
           fail == [bump EXCEPT !.failed = Append(@, [k |-> "failed", j |-> h])]  \* :372-373 NO_RESOURCE
       IN IF rpc.cnt[h] >= MaxScheduleCount
          THEN \* :347-354 exceeded max schedule count -> blocked (history updated)
               /\ rpc' = [bump EXCEPT !.blocked = Append(@, [k |-> "blocked", j |-> h])]
               /\ UNCHANGED netVars
          ELSE IF ~(Required[h] \subseteq app)
          THEN \* :160-164 required site not connected -> NO_RESOURCE
               /\ rpc' = fail
               /\ UNCHANGED netVars
          ELSE IF PoisonAt[h] = "pre"
          THEN \* :166 TypeError (int < "2") escapes _try_job; bare except :292-296 swallows it before the
               \* :369 history update: count never advances, later candidates never tried (F4)
               /\ rpc' = EndSchedule([r1 EXCEPT !.ready = None])
               /\ UNCHANGED netVars
          ELSE IF PoisonAt[h] = "none" /\ Cardinality(app) < MinSites[h]
          THEN \* :166-176 connected sites < min_sites -> NO_RESOURCE ("post": min_sites None skips :166)
               /\ rpc' = fail
               /\ UNCHANGED netVars
          ELSE IF app = {}
          THEN \* no CHECK request -> empty result dict -> :203-205 NO_RESOURCE
               /\ rpc' = fail
               /\ UNCHANGED netVars
          ELSE \* :199 _check_client_resources: CHECK_RESOURCE to every applicable registered client
               /\ rpc' = [r1 EXCEPT !.pc = "CheckWait", !.job = h, !.att = nextAtt, !.chk = app]
               /\ msgs' = Send(msgs, {CheckReq(h, c, nextAtt) : c \in LiveOf(app)})
               /\ nextAtt' = nextAtt + 1
    /\ UNCHANGED <<storeVars, cpc, tableVars, sjVars, adminVars, cpVars, cjVars, histVars>>

(* job_scheduler.py:356-362: retry interval (2**n * min_schedule_interval) not elapsed -> continue. *)
RunnerBackoffSkip ==
    /\ rpc.pc = "TryNext"
    /\ rpc.queue # <<>>
    /\ LET h == Head(rpc.queue) IN 0 < rpc.cnt[h] /\ rpc.cnt[h] < MaxScheduleCount
    /\ rpc' = [rpc EXCEPT !.queue = Tail(@)]
    /\ OnlyRpc

(* job_scheduler.py:377-378: loop exhausted, no job scheduled in this pass. *)
RunnerTryDone ==
    /\ rpc.pc = "TryNext"
    /\ rpc.queue = <<>>
    /\ rpc' = EndSchedule([rpc EXCEPT !.ready = None])
    /\ OnlyRpc

CheckReps == {m \in DOMAIN msgs : m.type = "CHECK_REP" /\ m.job = rpc.job /\ m.att = rpc.att}

(* Evaluation of the CHECK results (job_scheduler.py:199-261, then :365-375). *)
RunnerCheckEval(reps) ==
    LET h       == rpc.job
        okSites == {m.cl : m \in {x \in reps : x.ok}}      \* a missing reply is (False, "") (server_engine.py:1039-1040)
        r1      == [rpc EXCEPT !.cnt[h] = @ + 1, !.job = None, !.chk = {}]               \* :369 history
        failR   == [r1 EXCEPT !.pc = "TryNext", !.failed = Append(@, [k |-> "failed", j |-> h])]
        cancels == {CancelReq(h, c, rpc.att) : c \in LiveOf(okSites \cap sessions)}     \* server_engine.py:1052-1066
    IN IF PoisonAt[h] = "post"
       THEN \* :229 TypeError (int < None) after the reservations were made: no cancel, no history (RS-6)
            /\ rpc' = EndSchedule([rpc EXCEPT !.ready = None])
            /\ msgs' = ConsumeAll(msgs, reps)
       ELSE IF Cardinality(okSites) < MinSites[h]
       THEN \* :229-237 not enough sites with resources -> _cancel_resources -> NO_RESOURCE
            /\ rpc' = failR
            /\ msgs' = Send(ConsumeAll(msgs, reps), cancels)
       ELSE IF ~(Required[h] \subseteq okSites)
       THEN \* :239-254 a required site lacks resources -> _cancel_resources -> NO_RESOURCE
            /\ rpc' = failR
            /\ msgs' = Send(ConsumeAll(msgs, reps), cancels)
       ELSE \* :256-261 SCHEDULE_RESULT_OK: dispatch = sites whose check returned is_resource_enough
            /\ rpc' = EndSchedule([r1 EXCEPT !.ready = h, !.disp = okSites, !.att = rpc.att])
            /\ msgs' = ConsumeAll(msgs, reps)

(* All CHECK replies received. *)
RunnerCheckCollect ==
    /\ rpc.pc = "CheckWait"
    /\ {m.cl : m \in CheckReps} = rpc.chk
    /\ RunnerCheckEval(CheckReps)
    /\ UNCHANGED <<storeVars, cpc, tableVars, sjVars, adminVars, cpVars, cjVars, nextAtt, histVars>>

(* send_requests timed out (server_engine.py:1023, 15 s): missing replies count as (False, "");
   an unprocessed CHECK may still be processed later and reserve (late reply, F6). *)
RunnerCheckTimeout ==
    /\ rpc.pc = "CheckWait"
    /\ {m.cl : m \in CheckReps} # rpc.chk
    /\ RunnerCheckEval(CheckReps)
    /\ UNCHANGED <<storeVars, cpc, tableVars, sjVars, adminVars, cpVars, cjVars, nextAtt, histVars>>

(* job_scheduler.py:298-310: refresh_meta(job, schedule keys) for failed then blocked jobs.
   update_meta(replace=False) is an unlocked get_meta -> dict.update -> _write (fs_storage.py:251-275);
   split at the read / write boundary (S1, F16).  Any exception aborts the rest of the list (:309-310). *)
RunnerRefreshRead ==
    /\ rpc.pc = "RefreshRead"
    /\ LET it == Head(rpc.fb) IN
       rpc' = IF status[it.j] = DELETED
              THEN AfterFB(rpc)                                    \* StorageException caught at :309
              ELSE [rpc EXCEPT !.pc = "RefreshWrite", !.snap = status[it.j]]
    /\ OnlyRpc

RunnerRefreshWrite ==
    /\ rpc.pc = "RefreshWrite"
    /\ LET it == Head(rpc.fb) IN
       /\ IF status[it.j] = DELETED
          THEN UNCHANGED <<status, firstTerm, ovw, pCount>>   \* _write re-creates a meta-only dir; object stays absent
          ELSE /\ WriteStatus(it.j, rpc.snap, "RefreshWrite")            \* stale snapshot status written back (fs_storage.py:273-275)
               /\ pCount' = [pCount EXCEPT ![it.j] = rpc.cnt[it.j]]
       /\ rpc' = IF it.k = "blocked" THEN [rpc EXCEPT !.pc = "SetCantSched", !.snap = None] ELSE NextFB(rpc)
    /\ UNCHANGED <<tagged, cpc, tableVars, sjVars, adminVars, cpVars, cjVars, netVars, histVars>>

(* job_scheduler.py:308 set_status(FINISHED_CANT_SCHEDULE): no re-check of the persisted status. *)
RunnerSetCantSched ==
    /\ rpc.pc = "SetCantSched"
    /\ LET it == Head(rpc.fb) IN
       IF status[it.j] = DELETED
       THEN /\ rpc' = AfterFB(rpc)                                 \* StorageException caught at :309
            /\ UNCHANGED <<status, firstTerm, ovw>>
       ELSE /\ WriteStatus(it.j, CANT_SCHED, "SetCantSched")
            /\ rpc' = NextFB(rpc)
    /\ UNCHANGED <<pCount, tagged, cpc, tableVars, sjVars, adminVars, cpVars, cjVars, netVars, histVars>>

(* job_runner.py:660-663, _check_job_status :736-739: outside the try at :666. *)
RunnerCheckSubmitted ==
    /\ rpc.pc = "ChkSubmitted"
    /\ LET j == rpc.ready IN
       rpc' = IF status[j] = DELETED THEN [rpc EXCEPT !.pc = "Dead"]   \* get_job -> None; .meta AttributeError (F2)
              ELSE IF status[j] # SUBMITTED THEN RpcIdle               \* :662-663 skip; dispatched tokens not cancelled (F6)
              ELSE [rpc EXCEPT !.pc = "Deploy"]
    /\ OnlyRpc

(* job_runner.py:666-669 -> _deploy_job (:149-285).  F = clients whose DEPLOY failed or timed out
   (no reply counts as failure, :261-267); a dead-but-registered client always times out. *)
RunnerDeployJob(F) ==
    /\ rpc.pc = "Deploy"
    /\ LET j  == rpc.ready
           cs == rpc.disp            \* client_sites: deploy participants present in the dispatch map (:215-217)
       IN \/ /\ ~(cs \subseteq sessions)
             /\ F = {}
             /\ rpc' = [rpc EXCEPT !.pc = "ExceptStop"]            \* :222-226 "unknown clients"; job_id still None
          \/ /\ cs \subseteq sessions
             /\ F \subseteq cs
             /\ {c \in cs : ~cpAlive[c]} \subseteq F
             /\ LET numOk == Cardinality(cs) - Cardinality(F) IN
                rpc' = IF F # {} /\ (numOk < MinSites[j] \/ F \cap Required[j] # {})    \* :269-282
                       THEN [rpc EXCEPT !.pc = "ExceptStop"]
                       ELSE [rpc EXCEPT !.pc = "SetDispatched", !.jid = TRUE, !.dep = cs \ F]  \* :285, :692-695
    /\ OnlyRpc

(* job_runner.py:670 blind set_status(DISPATCHED) after the multi-second deploy (S1, F1). *)
RunnerSetDispatched ==
    /\ rpc.pc = "SetDispatched"
    /\ LET j == rpc.ready IN
       IF status[j] = DELETED
       THEN /\ rpc' = [rpc EXCEPT !.pc = "ExceptStop"]             \* StorageException inside the try
            /\ UNCHANGED <<status, firstTerm, ovw>>
       ELSE /\ WriteStatus(j, DISPATCHED, "SetDispatched")
            /\ rpc' = [rpc EXCEPT !.pc = "MetaRead"]
    /\ UNCHANGED <<pCount, tagged, cpc, tableVars, sjVars, adminVars, cpVars, cjVars, netVars, histVars>>

(* job_runner.py:672-689 update_meta(deploy detail + schedule keys): RMW read ... *)
RunnerMetaRead ==
    /\ rpc.pc = "MetaRead"
    /\ LET j == rpc.ready IN
       rpc' = IF status[j] = DELETED THEN [rpc EXCEPT !.pc = "ExceptStop"]
              ELSE [rpc EXCEPT !.pc = "MetaWrite", !.snap = status[j]]
    /\ OnlyRpc

(* ... and write back the snapshot (fs_storage.py:273-275). *)
RunnerMetaWrite ==
    /\ rpc.pc = "MetaWrite"
    /\ LET j == rpc.ready IN
       /\ IF status[j] = DELETED
          THEN UNCHANGED <<status, firstTerm, ovw, pCount>>
          ELSE /\ WriteStatus(j, rpc.snap, "MetaWrite")
               /\ pCount' = [pCount EXCEPT ![j] = rpc.cnt[j]]
       /\ rpc' = [rpc EXCEPT !.pc = "ChkDispatched", !.snap = None]
    /\ UNCHANGED <<tagged, cpc, tableVars, sjVars, adminVars, cpVars, cjVars, netVars, histVars>>

(* job_runner.py:697-701 re-check DISPATCHED (inside the try). *)
RunnerCheckDispatched ==
    /\ rpc.pc = "ChkDispatched"
    /\ LET j == rpc.ready IN
       rpc' = IF status[j] = DELETED THEN [rpc EXCEPT !.pc = "ExceptStop"]   \* AttributeError, caught at :713
              ELSE IF status[j] # DISPATCHED THEN RpcIdle                    \* `continue`: no cleanup at all (F6)
              ELSE [rpc EXCEPT !.pc = "StartSJ"]
    /\ OnlyRpc

(* _start_run part 1 (job_runner.py:295-310): start_app_on_server launches the SJ and registers
   run_processes + a wait_for_complete thread (server_engine.py:179-196, 236-329); pending outcomes are
   registered (:308-309); START_JOB goes to every resolvable deployable client (server_engine.py:1068-1083).
   Launch, registration and the START fan-out are one step: no reader of the intermediate state exists
   before any CJ is started. *)
RunnerStartServerApp ==
    /\ rpc.pc = "StartSJ"
    /\ LET j     == rpc.ready
           jc    == rpc.dep \cap sessions                 \* get_job_clients (server_engine.py:331-338)
           parts == IF jc = {} THEN sessions ELSE jc      \* :318-319 empty job_clients -> client_manager.clients
           sreq  == rpc.dep \cap sessions                 \* START only to registered clients (:1077-1079)
       IN IF rp[j] # None
          THEN \* :183-184 "Server run already started." -> RuntimeError (job_runner.py:305-306)
               /\ rpc' = [rpc EXCEPT !.pc = "ExceptStop"]
               /\ UNCHANGED <<sj, sjRC, rp, shared, wfc, wfcStale, launches, postAckLaunch, pending, msgs>>
          ELSE /\ sj' = [sj EXCEPT ![j] = "Running"]
               /\ sjRC' = [sjRC EXCEPT ![j] = 0]
               /\ rp' = [rp EXCEPT ![j] = NewRec(parts)]
               /\ shared' = [shared EXCEPT ![j] = FALSE]
               /\ wfc' = [wfc EXCEPT ![j] = TRUE]
               /\ launches' = [launches EXCEPT ![j] = @ + 1]
               /\ postAckLaunch' = [postAckLaunch EXCEPT ![j] = @ \/ ackAbort[j]]
               /\ pending' = [pending EXCEPT ![j] = rpc.dep]
               /\ msgs' = Send(msgs, {StartReq(j, c, rpc.att) : c \in LiveOf(sreq)})
               /\ rpc' = [rpc EXCEPT !.pc = "StartWait", !.sreq = sreq]
    /\ UNCHANGED <<storeVars, cpc, slots, runningJobs, runAborted, latched, sjErr, exc, rmp, wfcStale, adminVars,
                   cpVars, cjVars, nextAtt, ackAbort, ackStop, startedEv, endedEv, failAccepted, exeErrRec,
                   sjAbortHandled, abortDropped, failRunRec, startFailCause, ackInWindow>>

(* The launcher raises inside _start_runner_process (spawn / launcher error) -> except path (X12). *)
RunnerStartServerAppFail ==
    /\ rpc.pc = "StartSJ"
    /\ rp[rpc.ready] = None
    /\ rpc' = [rpc EXCEPT !.pc = "ExceptStop"]
    /\ OnlyRpc

StartReps == {m \in DOMAIN msgs : m.type = "START_REP" /\ m.job = rpc.ready}

(* _start_run part 2 (job_runner.py:310-364) with check_client_replies (admin.py:80-140),
   strict_start_job_reply_check = False (default, :313-317). *)
RunnerStartEval(reps) ==
    LET j   == rpc.ready
        got == {m.cl : m \in reps}
    IN IF \/ rpc.sreq = {}                                   \* admin.py:102-103 "no replies"
          \/ Cardinality(rpc.sreq) # Cardinality(rpc.dep)    \* admin.py:104-105 "not enough replies" (disconnected)
          \/ \E m \in reps : m.flag                          \* admin.py:131-137 ERROR_MSG_PREFIX body from any client
       THEN /\ rpc' = [rpc EXCEPT !.pc = "ExceptStop"]
            /\ msgs' = ConsumeAll(msgs, reps)
            /\ startFailCause' = [startFailCause EXCEPT ![j] = "error"]
            /\ UNCHANGED <<pending, slots, startedEv>>
       ELSE IF pending[j] = None
       THEN \* :359-360 KeyError: fail_run popped _pending_client_outcomes[job_id] meanwhile (F5)
            /\ rpc' = [rpc EXCEPT !.pc = "ExceptStop"]
            /\ msgs' = ConsumeAll(msgs, reps)
            /\ startFailCause' = [startFailCause EXCEPT ![j] = "keyerror"]
            /\ UNCHANGED <<pending, slots, startedEv>>
       ELSE /\ pending' = [pending EXCEPT ![j] = @ \cap got]   \* :345-360 active = clients that replied
            /\ slots' = slots \cup {j}                          \* :364 JOB_STARTED -> job_scheduler.py:276-280
            /\ startedEv' = [startedEv EXCEPT ![j] = TRUE]
            /\ rpc' = [rpc EXCEPT !.pc = "InsertRunning"]
            /\ msgs' = ConsumeAll(msgs, reps)
            /\ UNCHANGED startFailCause

RunnerStartCollect ==
    /\ rpc.pc = "StartWait"
    /\ {m.cl : m \in StartReps} = rpc.sreq
    /\ RunnerStartEval(StartReps)
    /\ UNCHANGED <<storeVars, cpc, runningJobs, runAborted, latched, sjVars, adminVars, cpVars, cjVars,
                   nextAtt, ackAbort, ackStop, launches, postAckLaunch, endedEv, failAccepted, exeErrRec,
                   sjAbortHandled, abortDropped, failRunRec, ackInWindow>>

(* START_JOB timed out (20 s, server_engine.py:1082): non-strict mode ignores timeouts (:345-353). *)
RunnerStartTimeout ==
    /\ rpc.pc = "StartWait"
    /\ {m.cl : m \in StartReps} # rpc.sreq
    /\ RunnerStartEval(StartReps)
    /\ UNCHANGED <<storeVars, cpc, runningJobs, runAborted, latched, sjVars, adminVars, cpVars, cjVars,
                   nextAtt, ackAbort, ackStop, launches, postAckLaunch, endedEv, failAccepted, exeErrRec,
                   sjAbortHandled, abortDropped, failRunRec, ackInWindow>>

(* job_runner.py:709-710 running_jobs[job_id] = job under self.lock ... *)
RunnerInsertRunning ==
    /\ rpc.pc = "InsertRunning"
    /\ runningJobs' = runningJobs \cup {rpc.ready}
    /\ rpc' = [rpc EXCEPT !.pc = "SetRunning"]
    /\ UNCHANGED <<storeVars, cpc, slots, runAborted, pending, latched, sjVars, adminVars, cpVars, cjVars,
                   netVars, histVars>>

(* ... then :711 blind set_status(RUNNING) outside the lock (S1, F3). *)
RunnerSetRunning ==
    /\ rpc.pc = "SetRunning"
    /\ LET j == rpc.ready IN
       IF status[j] = DELETED
       THEN /\ rpc' = [rpc EXCEPT !.pc = "ExceptStop"]             \* StorageException inside the try
            /\ UNCHANGED <<status, firstTerm, ovw>>
       ELSE /\ WriteStatus(j, RUNNING, "SetRunning")
            /\ rpc' = RpcIdle
    /\ UNCHANGED <<pCount, tagged, cpc, tableVars, sjVars, adminVars, cpVars, cjVars, netVars, histVars>>

(* except path (job_runner.py:713-731), step 1 (:714-719): only when job_id was assigned by _deploy_job. *)
RunnerExceptStop ==
    /\ rpc.pc = "ExceptStop"
    /\ LET j == rpc.ready IN
       IF rpc.jid
       THEN /\ runningJobs' = runningJobs \ {j}
            /\ pending' = [pending EXCEPT ![j] = None]
            /\ msgs' = Send(msgs, StopRunMsgs(j))
            /\ rmp' = [rmp EXCEPT ![j] = StopRunRmp(j)]
       ELSE UNCHANGED <<runningJobs, pending, msgs, rmp>>
    /\ rpc' = [rpc EXCEPT !.pc = "ExceptSetFailed"]
    /\ UNCHANGED <<storeVars, cpc, slots, runAborted, latched, sj, sjRC, sjErr, rp, exc, shared, wfc, wfcStale,
                   adminVars, cpVars, cjVars, nextAtt, histVars>>

(* :720 set_status(FAILED_TO_RUN), unprotected: a StorageException escapes run() (F2). *)
RunnerExceptSetFailed ==
    /\ rpc.pc = "ExceptSetFailed"
    /\ LET j == rpc.ready IN
       IF status[j] = DELETED
       THEN /\ rpc' = [rpc EXCEPT !.pc = "Dead"]
            /\ UNCHANGED <<status, firstTerm, ovw>>
       ELSE /\ WriteStatus(j, FAILED_TO_RUN, "ExceptSetFailed")
            /\ rpc' = [rpc EXCEPT !.pc = "ExceptMeta"]
    /\ UNCHANGED <<pCount, tagged, cpc, tableVars, sjVars, adminVars, cpVars, cjVars, netVars, histVars>>

(* :722-731 update_meta(deploy detail) RMW (merged: it re-writes a status equal to the FAILED_TO_RUN just
   written unless a concurrent writer intervenes, which is already reachable at :720), then JOB_ABORTED. *)
RunnerExceptMeta ==
    /\ rpc.pc = "ExceptMeta"
    /\ LET j == rpc.ready IN
       IF status[j] = DELETED
       THEN /\ rpc' = [rpc EXCEPT !.pc = "Dead"]
            /\ UNCHANGED <<slots, endedEv>>
       ELSE /\ slots' = slots \ {j}                               \* JOB_ABORTED -> job_scheduler.py:281-285
            /\ endedEv' = [endedEv EXCEPT ![j] = TRUE]
            /\ rpc' = RpcIdle
    /\ UNCHANGED <<storeVars, cpc, runningJobs, runAborted, pending, latched, sjVars, adminVars, cpVars,
                   cjVars, netVars, ackAbort, ackStop, launches, postAckLaunch, startedEv, failAccepted,
                   exeErrRec, sjAbortHandled, abortDropped, failRunRec, startFailCause, ackInWindow>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* SP completion thread: JobRunner._job_complete_process                   *)
(* (job_runner.py:441-541), a 1 s loop with no try around its body.        *)
(* Scenario S1 (F3), S2 (slots), S4 (classification / outcome barrier).    *)
(***************************************************************************)

(* :444-492 pick a job in running_jobs whose SJ left run_processes, apply the outcome barrier and latch the
   terminal status once.  The run_aborted read (:486) and the classification (:585) are one step: the only
   blocking call between them (abort_client_run, :584) exists only when an exception record is present. *)
CmpFinalizeBegin(j) ==
    /\ cpc.pc = "Idle"
    /\ j \in runningJobs                                   \* :444-447
    /\ rp[j] = None                                        \* :445 job_id not in engine.run_processes
    /\ LET srvFailed == Classify(exc[j]) \in {EXEC_EXC, ABNORMAL}          \* :448-454
           pend      == IF srvFailed THEN None ELSE pending[j]             \* :457-465 skip the outcome wait
       IN /\ ~(pend # None /\ pend # {} /\ ~runAborted[j])                 \* :466-472 wait (CmpOutcomeDeadline)
          /\ pending' = [pending EXCEPT ![j] = pend]
          /\ IF latched[j] = None
             THEN /\ latched' = [latched EXCEPT ![j] = IF runAborted[j] THEN ABORTED ELSE Classify(exc[j])]
                  /\ msgs' = IF ~runAborted[j] /\ exc[j] # None             \* _get_finished_job_status :574-585
                             THEN Send(msgs, AbortMsgs(j, exc[j].parts \cap sessions, FALSE))
                             ELSE msgs
             ELSE UNCHANGED <<latched, msgs>>
          /\ cpc' = [pc |-> "Publish", job |-> j]
    /\ UNCHANGED <<storeVars, rpc, slots, runningJobs, runAborted, sjVars, adminVars, cpVars, cjVars,
                   nextAtt, histVars>>

(* :466-476 client_outcome_wait_timeout (900 s) elapsed: pending.clear(); finalize from the server outcome. *)
CmpOutcomeDeadline(j) ==
    /\ cpc.pc = "Idle"
    /\ j \in runningJobs
    /\ rp[j] = None
    /\ Classify(exc[j]) \notin {EXEC_EXC, ABNORMAL}
    /\ pending[j] # None /\ pending[j] # {} /\ ~runAborted[j]
    /\ pending' = [pending EXCEPT ![j] = {}]
    /\ UNCHANGED <<storeVars, rpc, cpc, slots, runningJobs, runAborted, latched, sjVars, adminVars, cpVars,
                   cjVars, netVars, histVars>>

(* :493-530 archival (modeled as succeeding), then blind set_status(latched status) at :524. *)
CmpPublish ==
    /\ cpc.pc = "Publish"
    /\ LET j == cpc.job IN
       IF status[j] = DELETED
       THEN /\ cpc' = CmpIdle                     \* :525-530 exception -> `continue`; latch kept, retried next pass
            /\ UNCHANGED <<status, firstTerm, ovw>>
       ELSE /\ WriteStatus(j, latched[j], "CmpPublish")        \* no check of the persisted status
            /\ cpc' = [pc |-> "Remove", job |-> j]
    /\ UNCHANGED <<pCount, tagged, rpc, tableVars, sjVars, adminVars, cpVars, cjVars, netVars, histVars>>

(* :531-540 blind `del self.running_jobs[job_id]`, JOB_ABORTED (if ABORTED) + JOB_COMPLETED, then
   remove_exception_process. *)
CmpRemove ==
    /\ cpc.pc = "Remove"
    /\ LET j == cpc.job IN
       IF j \notin runningJobs
       THEN \* :532 KeyError (the runner's except path removed it): the thread ends (RS-7)
            /\ cpc' = [pc |-> "Dead", job |-> None]
            /\ UNCHANGED <<runningJobs, latched, pending, slots, endedEv, exc, shared>>
       ELSE /\ runningJobs' = runningJobs \ {j}
            /\ latched' = [latched EXCEPT ![j] = None]
            /\ pending' = [pending EXCEPT ![j] = None]
            /\ slots' = slots \ {j}                                 \* :536-538 -> job_scheduler.py:281-285
            /\ endedEv' = [endedEv EXCEPT ![j] = TRUE]
            /\ exc' = [exc EXCEPT ![j] = None]                      \* :540 (server_engine.py:198-201)
            /\ shared' = [shared EXCEPT ![j] = FALSE]
            /\ cpc' = CmpIdle
    /\ UNCHANGED <<storeVars, rpc, runAborted, sj, sjRC, sjErr, rp, wfc, wfcStale, rmp, adminVars, cpVars, cjVars,
                   netVars, ackAbort, ackStop, launches, postAckLaunch, startedEv, failAccepted, exeErrRec,
                   sjAbortHandled, abortDropped, failRunRec, startFailCause, ackInWindow>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* SP admin command handlers (job_cmds.py), one in-flight command per job. *)
(* Scenario S1 (abort / delete windows), S2 (delete kills the runner).     *)
(***************************************************************************)

OnlyAdm == UNCHANGED <<storeVars, rpc, cpc, tableVars, sjVars, sessions, disabled, sweeper, cpVars, cjVars,
                       netVars, histVars>>

(* abort_job (job_cmds.py:1051-1060): fresh get_job, branch on the status read (check-then-act).
   DELETED -> get_job None -> exception reply; FINISHED:* -> "already completed" (no effect). *)
AdminAbortBegin(j) ==
    /\ adm[j].pc = "Idle"
    /\ status[j] \in {SUBMITTED, DISPATCHED, RUNNING}
    /\ adm' = [adm EXCEPT ![j] = [pc |-> IF status[j] \in {SUBMITTED, DISPATCHED} THEN "AbortWrite" ELSE "StopRun",
                                  snap |-> status[j]]]
    /\ OnlyAdm

(* job_cmds.py:1061-1066 SUBMITTED/DISPATCHED: set_status(FINISHED_ABORTED) only; nothing is sent to the
   runner or the clients (X11). *)
AdminAbortWrite(j) ==
    /\ adm[j].pc = "AbortWrite"
    /\ adm' = [adm EXCEPT ![j] = AdmIdle]
    /\ IF status[j] = DELETED
       THEN UNCHANGED <<status, firstTerm, ovw, ackAbort, ackInWindow>> \* StorageException -> error reply
       ELSE /\ WriteStatus(j, ABORTED, "AdminAbortWrite")
            /\ ackAbort' = [ackAbort EXCEPT ![j] = TRUE]          \* "Aborted the job ... before running it."
            /\ ackInWindow' = [ackInWindow EXCEPT ![j] = @ \/ (rpc.ready = j /\ rpc.pc \in F1Window)]
    /\ UNCHANGED <<pCount, tagged, rpc, cpc, tableVars, sjVars, sessions, disabled, sweeper, cpVars, cjVars,
                   netVars, ackStop, launches, postAckLaunch, startedEv, endedEv, failAccepted, exeErrRec,
                   sjAbortHandled, abortDropped, failRunRec, startFailCause>>

(* Otherwise (RUNNING) job_runner.stop_run (job_runner.py:798-800): _stop_run first ... *)
AdminStopRun(j) ==
    /\ adm[j].pc = "StopRun"
    /\ msgs' = Send(msgs, StopRunMsgs(j))
    /\ rmp' = [rmp EXCEPT ![j] = StopRunRmp(j)]
    /\ adm' = [adm EXCEPT ![j] = [pc |-> "MarkAborted", snap |-> adm[j].snap]]
    /\ UNCHANGED <<storeVars, rpc, cpc, tableVars, sj, sjRC, sjErr, rp, exc, shared, wfc, wfcStale, sessions, disabled,
                   sweeper, cpVars, cjVars, nextAtt, histVars>>

(* ... then mark_run_aborted (job_runner.py:802-811) after the ABORT RPCs returned. *)
AdminMarkAborted(j) ==
    /\ adm[j].pc = "MarkAborted"
    /\ adm' = [adm EXCEPT ![j] = AdmIdle]
    /\ IF j \in runningJobs
       THEN /\ runAborted' = [runAborted EXCEPT ![j] = TRUE]
            /\ ackStop' = [ackStop EXCEPT ![j] = TRUE]            \* "Abort signal has been sent to the server app."
       ELSE UNCHANGED <<runAborted, ackStop>>                     \* "Job ... is not running." error reply
    /\ UNCHANGED <<storeVars, rpc, cpc, slots, runningJobs, pending, latched, sjVars, sessions, disabled,
                   sweeper, cpVars, cjVars, netVars, ackAbort, launches, postAckLaunch, startedEv, endedEv,
                   failAccepted, exeErrRec, sjAbortHandled, abortDropped, failRunRec, startFailCause, ackInWindow>>

(* delete_job: authorize_job_id snapshots the job (job_cmds.py:282-316) ... *)
AdminDeleteAuthorize(j) ==
    /\ adm[j].pc = "Idle"
    /\ status[j] # DELETED
    /\ adm' = [adm EXCEPT ![j] = [pc |-> "DeleteExec", snap |-> status[j]]]
    /\ OnlyAdm

(* ... and delete_job (job_cmds.py:507-535) guards on that snapshot only (not DISPATCHED/RUNNING). *)
AdminDeleteExec(j) ==
    /\ adm[j].pc = "DeleteExec"
    /\ adm' = [adm EXCEPT ![j] = AdmIdle]
    /\ IF adm[j].snap \in {DISPATCHED, RUNNING}
       THEN UNCHANGED status                                        \* :516-521 refused
       ELSE status' = [status EXCEPT ![j] = DELETED]                \* job_def_manager.py:354-356 delete_object
    /\ UNCHANGED <<pCount, tagged, firstTerm, ovw, rpc, cpc, tableVars, sjVars, sessions, disabled, sweeper, cpVars,
                   cjVars, netVars, histVars>>

(* disable_clients (server_engine.py:620-644; client_manager.py:117-140): drops the session and blocks the
   client's heartbeats and reports, without notify_dead_client (F12). *)
AdminDisable(c) ==
    /\ c \notin disabled
    /\ sessions' = sessions \ {c}
    /\ disabled' = disabled \cup {c}
    /\ UNCHANGED <<storeVars, rpc, cpc, tableVars, sjVars, adm, sweeper, cpVars, cjVars, netVars, histVars>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* SP cell handlers and per-SJ threads.  Scenario S4.                      *)
(***************************************************************************)

(* UPDATE_RUN_STATUS from the SJ (fed_server.py:594-604), under FederatedServer.lock. *)
SpUpdateRunStatus(m) ==
    /\ m \in DOMAIN msgs
    /\ m.type = "RUNSTATUS"
    /\ msgs' = Consume(msgs, m)
    /\ LET j == m.job IN
       IF rp[j] # None
       THEN LET nr == [rp[j] EXCEPT !.finished = TRUE, !.exeErr = @ \/ m.flag] IN
            /\ rp' = [rp EXCEPT ![j] = nr]
            /\ exc' = IF m.flag \/ shared[j] THEN [exc EXCEPT ![j] = nr] ELSE exc   \* :599-600
            /\ shared' = IF m.flag THEN [shared EXCEPT ![j] = TRUE] ELSE shared
            /\ exeErrRec' = IF m.flag THEN [exeErrRec EXCEPT ![j] = TRUE] ELSE exeErrRec
       ELSE UNCHANGED <<rp, exc, shared, exeErrRec>>        \* entry already popped: the report is ignored (F17)
    /\ UNCHANGED <<storeVars, rpc, cpc, tableVars, sj, sjRC, sjErr, wfc, wfcStale, rmp, adminVars, cpVars, cjVars,
                   nextAtt, ackAbort, ackStop, launches, postAckLaunch, startedEv, endedEv, failAccepted,
                   sjAbortHandled, abortDropped, failRunRec, startFailCause, ackInWindow>>

(* REPORT_JOB_FAILURE from a CP (fed_server.py:906-957). *)
SpProcessJobFailure(m) ==
    /\ m \in DOMAIN msgs
    /\ m.type = "REPORT"
    /\ LET j == m.job
           c == m.cl
           accepted == c \in sessions /\ pending[j] # None /\ c \in pending[j]   \* :916-936 token + pending check
           code == m.code
           fc == IF code = RC_CONFIG THEN RC_EXCEPTION ELSE code                \* :950
       IN IF ~accepted
          THEN /\ msgs' = Consume(msgs, m)                                             \* dropped
               /\ UNCHANGED <<pending, runAborted, rp, exc, shared, rmp, failAccepted, failRunRec>>
          ELSE IF code \in {RC_CONFIG, RC_EXCEPTION, RC_INFRA, RC_ABORTED}
          THEN \* :942-951 fail_run(job, code) (job_runner.py:813-852), then resolve_client_outcome (no-op after pop)
               /\ failAccepted' = [failAccepted EXCEPT ![j] = TRUE]
               /\ UNCHANGED runAborted
               /\ IF FailRunActive(j)
                  THEN /\ exc' = [exc EXCEPT ![j] = FailRunRec(j, fc)]
                       /\ rp' = [rp EXCEPT ![j] = FailRunRp(j, fc)]
                       /\ shared' = [shared EXCEPT ![j] = FailRunShared(j)]
                       /\ pending' = [pending EXCEPT ![j] = None]                 \* :841
                       /\ msgs' = Send(Consume(msgs, m), StopRunMsgs(j))               \* :843 _stop_run
                       /\ rmp' = [rmp EXCEPT ![j] = StopRunRmp(j)]
                       /\ failRunRec' = [failRunRec EXCEPT ![j] = TRUE]
                  ELSE /\ pending' = [pending EXCEPT ![j] = @ \ {c}]             \* "not running": only resolved
                       /\ msgs' = Consume(msgs, m)
                       /\ UNCHANGED <<rp, exc, shared, rmp, failRunRec>>
          ELSE IF code = RC_UNSAFE
          THEN \* :952-955 stop_run: _stop_run + mark_run_aborted (no-op unless in running_jobs), then resolve
               /\ failAccepted' = [failAccepted EXCEPT ![j] = TRUE]
               /\ msgs' = Send(Consume(msgs, m), StopRunMsgs(j))
               /\ rmp' = [rmp EXCEPT ![j] = StopRunRmp(j)]
               /\ runAborted' = IF j \in runningJobs THEN [runAborted EXCEPT ![j] = TRUE] ELSE runAborted
               /\ pending' = [pending EXCEPT ![j] = @ \ {c}]
               /\ UNCHANGED <<rp, exc, shared, failRunRec>>
          ELSE \* other codes (0, 1): only resolve_client_outcome (:956)
               /\ pending' = [pending EXCEPT ![j] = @ \ {c}]
               /\ msgs' = Consume(msgs, m)
               /\ UNCHANGED <<runAborted, rp, exc, shared, rmp, failAccepted, failRunRec>>
    /\ UNCHANGED <<storeVars, rpc, cpc, slots, runningJobs, latched, sj, sjRC, sjErr, wfc, wfcStale, adminVars, cpVars,
                   cjVars, nextAtt, ackAbort, ackStop, launches, postAckLaunch, startedEv, endedEv, exeErrRec,
                   sjAbortHandled, abortDropped, startFailCause, ackInWindow>>

(* ServerEngine.wait_for_complete (server_engine.py:203-234) after the SJ process exits: the <= 2 s wait for
   UPDATE_RUN_STATUS is an interleaving window; a non-zero rc is recorded unless a record exists.  The entry is read
   (:205) BEFORE that wait and recorded from the object read, so when _remove_run_processes popped it in between,
   the rc is still recorded from the stale entry (trace wfc_stale_read_after_pop); when the pop came before the
   read, nothing is recorded (F20).  The read itself is not observable: both outcomes are allowed. *)
SpWaitForComplete(j) ==
    /\ wfc[j]
    /\ sj[j] = "Exited"
    /\ wfc' = [wfc EXCEPT ![j] = FALSE]
    /\ sjRC' = [sjRC EXCEPT ![j] = 0]        \* canonical: the exit code has no reader after this step
    /\ wfcStale' = [wfcStale EXCEPT ![j] = None]
    /\ IF rp[j] # None
       THEN /\ exc' = IF sjRC[j] # 0 /\ exc[j] = None                   \* :218-232
                      THEN [exc EXCEPT ![j] = [rp[j] EXCEPT !.rc = sjRC[j]]]
                      ELSE exc
            /\ rp' = [rp EXCEPT ![j] = None]                            \* :233
            /\ shared' = [shared EXCEPT ![j] = FALSE]
       ELSE /\ UNCHANGED <<rp, shared>>
            /\ \/ UNCHANGED exc                  \* entry popped before the read (:205-206): rc never captured (F20)
               \/ /\ wfcStale[j] # None          \* entry read before _remove_run_processes popped it
                  /\ exc' = IF sjRC[j] # 0 /\ exc[j] = None
                            THEN [exc EXCEPT ![j] = [wfcStale[j] EXCEPT !.rc = sjRC[j]]]
                            ELSE exc
    /\ UNCHANGED <<storeVars, rpc, cpc, tableVars, sj, sjErr, rmp, adminVars, cpVars, cjVars, netVars,
                   histVars>>

(* ServerEngine._remove_run_processes (server_engine.py:385-409), started by every abort_app_on_server:
   waits <= 10 s for the entry to vanish, then always terminate() and pop.  Firing while the SJ still runs
   models the grace expiring (SIGKILL -> -9 -> EXECUTION_ERROR). *)
SpRemoveRunProcesses(j) ==
    /\ rmp[j] > 0
    /\ rmp' = [rmp EXCEPT ![j] = @ - 1]
    /\ IF rp[j] # None
       THEN /\ rp' = [rp EXCEPT ![j] = None]
            /\ shared' = [shared EXCEPT ![j] = FALSE]
            /\ wfcStale' = [wfcStale EXCEPT ![j] = IF wfc[j] THEN rp[j] ELSE None]
            /\ IF sj[j] = "Running"
               THEN /\ sj' = [sj EXCEPT ![j] = "Exited"]
                    /\ sjRC' = [sjRC EXCEPT ![j] = RC_EXEC_ERR]
                    /\ sjErr' = [sjErr EXCEPT ![j] = TRUE]
               ELSE UNCHANGED <<sj, sjRC, sjErr>>
       ELSE UNCHANGED <<rp, shared, sj, sjRC, sjErr, wfcStale>> \* graceful: wait_for_complete already popped
    /\ UNCHANGED <<storeVars, rpc, cpc, tableVars, exc, wfc, adminVars, cpVars, cjVars, netVars, histVars>>

(* Dead-client sweeper BaseServer.client_cleanup (fed_server.py:290-330), no try around its loop.
   Step 1: remove_dead_clients -> logout_client -> notify_dead_client part 1 (:1096-1107): resolve the
   dead client's pending outcomes (fail_run(INFRASTRUCTURE_ERROR) if the SJ and its record are gone). *)
SweepBegin(c) ==
    /\ sweeper.pc = "Idle"
    /\ ~cpAlive[c]
    /\ c \in sessions                      \* last_connect_time older than heart_beat_timeout (:313-315)
    /\ LET outc == {j \in Jobs : pending[j] # None /\ c \in pending[j]}
           frun == {j \in outc : rp[j] = None /\ exc[j] = None /\ j \in runningJobs}
       IN /\ sessions' = sessions \ {c}
          /\ exc' = [j \in Jobs |-> IF j \in frun THEN [NewRec({}) EXCEPT !.rc = RC_INFRA] ELSE exc[j]]
          /\ pending' = [j \in Jobs |-> IF j \in frun THEN None
                                        ELSE IF j \in outc THEN pending[j] \ {c} ELSE pending[j]]
          /\ failRunRec' = [j \in Jobs |-> failRunRec[j] \/ j \in frun]
          /\ sweeper' = [pc |-> "Iter", cl |-> c,
                         snap |-> Cardinality({j \in Jobs : rp[j] # None}),
                         blocking |-> \E j \in Jobs : rp[j] # None /\ c \in rp[j].parts]
    /\ UNCHANGED <<storeVars, rpc, cpc, slots, runningJobs, runAborted, latched, sj, sjRC, sjErr, rp, shared,
                   wfc, wfcStale, rmp, adm, disabled, cpVars, cjVars, netVars, ackAbort, ackStop, launches, postAckLaunch,
                   startedEv, endedEv, failAccepted, exeErrRec, sjAbortHandled, abortDropped, startFailCause, ackInWindow>>

(* Step 2: notify_dead_client part 2 iterates the live engine.run_processes dict (:1109) with a blocking body
   (_notify_dead_job -> send_command_to_child_runner_process) when the client participates in some run: a
   concurrent insert/pop raises "dictionary changed size during iteration" and the thread dies (F7). *)
SweepEnd ==
    /\ sweeper.pc = "Iter"
    /\ sweeper' = IF sweeper.blocking /\ Cardinality({j \in Jobs : rp[j] # None}) # sweeper.snap
                  THEN [SweepIdle EXCEPT !.pc = "Dead"]
                  ELSE SweepIdle
    /\ UNCHANGED <<storeVars, rpc, cpc, tableVars, sjVars, adm, sessions, disabled, cpVars, cjVars, netVars,
                   histVars>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* Server job process (SJ).  Scenario S4.                                  *)
(***************************************************************************)

(* ServerAppRunner.start_server_app (server_app_runner.py:55-99): the run ends; the finally block sends
   UPDATE_RUN_STATUS fire-and-forget (server_engine.py:873-884); the process exits (mpm rc, normalised). *)
SjFinish(j, ee, rc) ==
    /\ sj[j] = "Running"
    /\ <<ee, rc>> \in SjOutcomes
    /\ sj' = [sj EXCEPT ![j] = "Exited"]
    /\ sjRC' = [sjRC EXCEPT ![j] = rc]
    /\ sjErr' = [sjErr EXCEPT ![j] = ee]
    /\ msgs' = Send(msgs, {RunStatus(j, ee)})
    /\ UNCHANGED <<storeVars, rpc, cpc, tableVars, rp, exc, shared, wfc, wfcStale, rmp, adminVars, cpVars, cjVars,
                   nextAtt, histVars>>

(* SJ killed / crashed: no UPDATE_RUN_STATUS; the signal exit is normalised to 1 (process_launcher.py:51-55). *)
SjCrash(j) ==
    /\ sj[j] = "Running"
    /\ sj' = [sj EXCEPT ![j] = "Exited"]
    /\ sjRC' = [sjRC EXCEPT ![j] = RC_EXEC_ERR]
    /\ sjErr' = [sjErr EXCEPT ![j] = TRUE]
    /\ UNCHANGED <<storeVars, rpc, cpc, tableVars, rp, exc, shared, wfc, wfcStale, rmp, adminVars, cpVars, cjVars,
                   netVars, histVars>>

(* ABORT command to the SJ (abort_app_on_server, server_engine.py:361-369): the runner aborts, run() returns
   normally, UPDATE_RUN_STATUS(execution_error=False) is sent and the process exits 0. *)
SjHandleAbort(m) ==
    /\ m \in DOMAIN msgs
    /\ m.type = "SJABORT"
    /\ LET j == m.job IN
       IF sj[j] = "Running"
       THEN /\ sj' = [sj EXCEPT ![j] = "Exited"]
            /\ sjRC' = [sjRC EXCEPT ![j] = 0]
            /\ msgs' = Send(Consume(msgs, m), {RunStatus(j, FALSE)})
            /\ sjAbortHandled' = [sjAbortHandled EXCEPT ![j] = TRUE]
       ELSE /\ msgs' = Consume(msgs, m)                                    \* no SJ cell: the command fails
            /\ UNCHANGED <<sj, sjRC, sjAbortHandled>>
    /\ UNCHANGED <<storeVars, rpc, cpc, tableVars, sjErr, rp, exc, shared, wfc, wfcStale, rmp, adminVars, cpVars, cjVars,
                   nextAtt, ackAbort, ackStop, launches, postAckLaunch, startedEv, endedEv, failAccepted,
                   exeErrRec, abortDropped, failRunRec, startFailCause, ackInWindow>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* Client parent (CP): request handlers run concurrently on the cell frame *)
(* pool; resource-manager calls are atomic under AutoClean._lock.          *)
(* Scenario S3 (ownership chain reserve -> allocate -> free), S5.          *)
(***************************************************************************)

CpUnchanged == <<storeVars, rpc, cpc, tableVars, sjVars, adminVars>>

(* CHECK_RESOURCE (scheduler_cmds.py:61-92) -> check_resources (auto_clean.py:119-137): reserve only when
   enough; ListResourceManager semantics (list_rm.py:57-76).  A reply after the sender's timeout is discarded. *)
CpCheckResource(m) ==
    /\ m \in DOMAIN msgs
    /\ m.type = "CHECK"
    /\ cpAlive[m.cl]
    /\ LET c == m.cl
           live == rpc.pc = "CheckWait" /\ rpc.att = m.att
           Rep(ok) == IF live THEN {CheckRep(m.job, c, m.att, ok)} ELSE {}
       IN IF BagSize(free[c]) >= Need
          THEN \E S \in SUBSET {u \in Units : free[c][u] > 0} :
                 /\ Cardinality(S) = Need
                 /\ free' = [free EXCEPT ![c] = TakeUnits(@, S)]
                 /\ resv' = [resv EXCEPT ![c] = @ \cup {[tok |-> m.att, job |-> m.job, units |-> S, ttl |-> Expiry]}]
                 /\ msgs' = Send(Consume(msgs, m), Rep(TRUE))
          ELSE /\ msgs' = Send(Consume(msgs, m), Rep(FALSE))
               /\ UNCHANGED <<free, resv>>
    /\ UNCHANGED <<CpUnchanged, cpAlive, cst, cjReg, alloc, waiter, termP, termHb, cjAbortMsg, cjVars, nextAtt, histVars>>

(* CANCEL_RESOURCE (scheduler_cmds.py:140-157) -> cancel_resources (auto_clean.py:140-151); unknown or
   expired token is a no-op. *)
CpCancelResource(m) ==
    /\ m \in DOMAIN msgs
    /\ m.type = "CANCEL"
    /\ cpAlive[m.cl]
    /\ msgs' = Consume(msgs, m)
    /\ LET c == m.cl
           hit == {r \in resv[c] : r.tok = m.att}
       IN IF hit # {}
          THEN LET r == CHOOSE x \in hit : TRUE IN
               /\ resv' = [resv EXCEPT ![c] = @ \ {r}]
               /\ free' = [free EXCEPT ![c] = AddUnits(@, r.units)]
          ELSE UNCHANGED <<resv, free>>
    /\ UNCHANGED <<CpUnchanged, cpAlive, cst, cjReg, alloc, waiter, termP, termHb, cjAbortMsg, cjVars, nextAtt, histVars>>

(* Reservation-expiry thread (auto_clean.py:102-117): one check_period tick. *)
CpTick(c) ==
    /\ cpAlive[c]
    /\ resv[c] # {}
    /\ LET dec == {[r EXCEPT !.ttl = @ - 1] : r \in resv[c]}
           expired == {r \in dec : r.ttl = 0}
       IN /\ resv' = [resv EXCEPT ![c] = dec \ expired]
          /\ free' = [free EXCEPT ![c] = [u \in Units |-> @[u] + Cardinality({r \in expired : u \in r.units})]]
    /\ UNCHANGED <<CpUnchanged, cpAlive, cst, cjReg, alloc, waiter, termP, termHb, cjAbortMsg, cjVars, netVars, histVars>>

StartLive(j) == rpc.pc = "StartWait" /\ rpc.ready = j

(* START_JOB (StartJobProcessor, scheduler_cmds.py:100-121): allocate_resources pops the reservation or
   raises (auto_clean.py:153-164); then ClientEngine.start_app's early string returns (client_engine.py:357-367). *)
CpStartAllocate(m) ==
    /\ m \in DOMAIN msgs
    /\ m.type = "START"
    /\ cpAlive[m.cl]
    /\ cst[m.cl][m.job] = None
    /\ LET c == m.cl
           j == m.job
           hit == {r \in resv[c] : r.tok = m.att}
           Rep(err) == IF StartLive(j) THEN {StartRep(j, c, err)} ELSE {}
       IN IF hit = {}
          THEN \* "No reserved resources for token" raised -> ERROR body; nothing allocated (:129-131)
               /\ msgs' = Send(Consume(msgs, m), Rep(TRUE))
               /\ UNCHANGED <<resv, cst>>
          ELSE LET r == CHOOSE x \in hit : TRUE IN
               /\ resv' = [resv EXCEPT ![c] = @ \ {r}]
               /\ IF cjReg[c][j] # None /\ cjReg[c][j].st = STARTED
                  THEN \* :357-359 "Client app already started." (no exception -> no free; not ERROR-prefixed) (F9)
                       /\ msgs' = Send(Consume(msgs, m), Rep(FALSE))
                       /\ UNCHANGED cst
                  ELSE /\ cst' = [cst EXCEPT ![c][j] = [pc |-> "Allocated", units |-> r.units, tok |-> r.tok]]
                       /\ msgs' = Consume(msgs, m)
    /\ UNCHANGED <<CpUnchanged, cpAlive, free, cjReg, alloc, waiter, termP, termHb, cjAbortMsg, cjVars, nextAtt, histVars>>

(* UNSUPPORTED (EnableUnsupported only): deployed app dir removed before START (disabled delete_workspace
   command or manual deletion): client_engine.py:365-367 returns an ERROR string after allocation, so the
   allocation is never freed (F9). *)
CpStartAllocateAppMissing(m) ==
    /\ EnableUnsupported
    /\ m \in DOMAIN msgs
    /\ m.type = "START"
    /\ cpAlive[m.cl]
    /\ cst[m.cl][m.job] = None
    /\ LET c == m.cl
           j == m.job
           hit == {r \in resv[c] : r.tok = m.att}
       IN /\ hit # {}
          /\ ~(cjReg[c][j] # None /\ cjReg[c][j].st = STARTED)
          /\ resv' = [resv EXCEPT ![c] = @ \ {CHOOSE x \in hit : TRUE}]
          /\ msgs' = Send(Consume(msgs, m), (IF StartLive(j) THEN {StartRep(j, c, TRUE)} ELSE {}))
    /\ UNCHANGED <<CpUnchanged, cpAlive, free, cst, cjReg, alloc, waiter, termP, termHb, cjAbortMsg, cjVars, nextAtt,
                   histVars>>

(* JobExecutor.start_app (client_executor.py:222-307): deployed-meta check, get_job_launcher
   (BEFORE_JOB_LAUNCH), then STARTING registration with a _PendingJobHandle under self.lock. *)
CpStartRegister(c, j) ==
    /\ cpAlive[c]
    /\ cst[c][j] # None
    /\ cst[c][j].pc = "Allocated"
    /\ IF cjReg[c][j] # None
       THEN \* :300-301 "still registered" -> exception -> StartJobProcessor frees (scheduler_cmds.py:129-133)
            /\ free' = [free EXCEPT ![c] = AddUnits(@, cst[c][j].units)]
            /\ cst' = [cst EXCEPT ![c][j] = None]
            /\ msgs' = Send(msgs, (IF StartLive(j) THEN {StartRep(j, c, TRUE)} ELSE {}))
            /\ UNCHANGED cjReg
       ELSE /\ cjReg' = [cjReg EXCEPT ![c][j] = [st |-> STARTING, attached |-> FALSE, pendAbort |-> FALSE,
                                                   abortReq |-> FALSE]]
            /\ cst' = [cst EXCEPT ![c][j] = [@ EXCEPT !.pc = "Registered"]]
            /\ UNCHANGED <<free, msgs>>
    /\ UNCHANGED <<CpUnchanged, cpAlive, resv, alloc, waiter, termP, termHb, cjAbortMsg, cjVars, nextAtt, histVars>>

(* launch_job + attach (client_executor.py:308-334): a pending abort is honoured at attach (:318-320);
   the waiter thread takes the allocation; reply "Start the client app..." (client_engine.py:381). *)
CpStartLaunch(c, j) ==
    /\ cpAlive[c]
    /\ cst[c][j] # None
    /\ cst[c][j].pc = "Registered"
    /\ cjReg[c][j] # None
    /\ LET e == cjReg[c][j]
           u == cst[c][j].units
       IN /\ cjReg' = [cjReg EXCEPT ![c][j] = [e EXCEPT !.attached = TRUE]]
          /\ IF e.pendAbort
             THEN \* abort_app -> STARTING -> terminate(): the whole group is killed at once
                  /\ cjProc' = [cjProc EXCEPT ![c][j] = "Exited"]
                  /\ cjRC' = [cjRC EXCEPT ![c][j] = RC_EXEC_ERR]
                  /\ using' = [using EXCEPT ![c][j] = {}]
             ELSE /\ cjProc' = [cjProc EXCEPT ![c][j] = "Alive"]
                  /\ cjRC' = [cjRC EXCEPT ![c][j] = 0]
                  /\ using' = [using EXCEPT ![c][j] = u]
          /\ grp' = [grp EXCEPT ![c][j] = FALSE]
          /\ alloc' = [alloc EXCEPT ![c][j] = u]
          /\ waiter' = [waiter EXCEPT ![c][j] = TRUE]
          /\ cst' = [cst EXCEPT ![c][j] = None]
          /\ postAckLaunch' = [postAckLaunch EXCEPT ![j] = @ \/ ackAbort[j]]
          /\ msgs' = Send(msgs, (IF StartLive(j) THEN {StartRep(j, c, FALSE)} ELSE {}))
    /\ UNCHANGED <<CpUnchanged, cpAlive, free, resv, termP, termHb, cjAbortMsg, nextAtt, ackAbort, ackStop, launches,
                   startedEv, endedEv, failAccepted, exeErrRec, sjAbortHandled, abortDropped, failRunRec, startFailCause, ackInWindow>>

(* launch_job raises (client_executor.py:308-316): the pending entry is removed and the exception makes
   StartJobProcessor free the allocation (scheduler_cmds.py:129-133). *)
CpStartLaunchFail(c, j) ==
    /\ cpAlive[c]
    /\ cst[c][j] # None
    /\ cst[c][j].pc = "Registered"
    /\ cjReg' = [cjReg EXCEPT ![c][j] = None]
    /\ free' = [free EXCEPT ![c] = AddUnits(@, cst[c][j].units)]
    /\ cst' = [cst EXCEPT ![c][j] = None]
    /\ msgs' = Send(msgs, (IF StartLive(j) THEN {StartRep(j, c, TRUE)} ELSE {}))
    /\ UNCHANGED <<CpUnchanged, cpAlive, resv, alloc, waiter, termP, termHb, cjAbortMsg, cjVars, nextAtt, histVars>>

(* ProcessAdapter.terminate -> killpg(getpgid(pid)) (process_utils.py:226-232, 293-316): kills the leader
   (or its unreaped zombie's group) and every same-group descendant. *)
KillGroup(c, j) ==
    /\ cjProc' = [cjProc EXCEPT ![c][j] = IF @ = "Alive" THEN "Exited" ELSE @]
    /\ cjRC' = [cjRC EXCEPT ![c][j] = IF cjProc[c][j] = "Alive" THEN RC_EXEC_ERR ELSE @]
    /\ grp' = [grp EXCEPT ![c][j] = FALSE]
    /\ using' = [using EXCEPT ![c][j] = {}]

(* ABORT (training_cmds.py:37-46) -> ClientEngine.abort_app (client_engine.py:390-404) ->
   JobExecutor.abort_app (client_executor.py:486-547).  Also used for heartbeat cleanup (m.flag). *)
CpAbortApp(m) ==
    /\ m \in DOMAIN msgs
    /\ m.type = "ABORT"
    /\ cpAlive[m.cl]
    /\ msgs' = Consume(msgs, m)
    /\ LET c == m.cl
           j == m.job
           e == cjReg[c][j]
       IN IF e = None
          THEN \* get_status() defaults to STOPPED and the job is not registered: "already stopped" (CL-1)
               /\ abortDropped' = [abortDropped EXCEPT ![c][j] = @ \/ cst[c][j] # None]
               /\ UNCHANGED <<cjReg, termP, termHb, cjAbortMsg, cjVars>>
          ELSE IF e.st = STARTING /\ ~e.attached
          THEN \* _PendingJobHandle.terminate records the request (client_executor.py:65-72)
               /\ cjReg' = [cjReg EXCEPT ![c][j] = [e EXCEPT !.abortReq = TRUE, !.pendAbort = TRUE]]
               /\ UNCHANGED <<termP, termHb, cjAbortMsg, cjVars, abortDropped>>
          ELSE IF e.st = STARTING
          THEN \* :505-510 terminate() immediately
               /\ cjReg' = [cjReg EXCEPT ![c][j] = [e EXCEPT !.abortReq = TRUE]]
               /\ KillGroup(c, j)
               /\ UNCHANGED <<termP, termHb, cjAbortMsg, abortDropped>>
          ELSE \* STARTED: fire ABORT to the CJ and _terminate_job (:522-533); STOPPED: _terminate_job (:511-520)
               /\ cjReg' = [cjReg EXCEPT ![c][j] = [e EXCEPT !.abortReq = TRUE]]
               /\ termP' = IF m.flag THEN termP ELSE [termP EXCEPT ![c][j] = @ + 1]
               /\ termHb' = IF m.flag THEN [termHb EXCEPT ![c][j] = @ + 1] ELSE termHb
               /\ cjAbortMsg' = [cjAbortMsg EXCEPT ![c][j] = @ + (IF e.st = STARTED THEN 1 ELSE 0)]
               /\ UNCHANGED <<cjVars, abortDropped>>
    /\ UNCHANGED <<CpUnchanged, cpAlive, free, resv, cst, alloc, waiter, nextAtt, ackAbort, ackStop, launches,
                   postAckLaunch, startedEv, endedEv, failAccepted, exeErrRec, sjAbortHandled, failRunRec, startFailCause, ackInWindow>>

(* _terminate_job (client_executor.py:581-601) after its <= 10 s grace: returns without killing if the
   entry vanished (leader reaped: same-group descendants survive, CL-5/F10), else terminate(). *)
CpTerminateJob(c, j) ==
    /\ cpAlive[c]
    /\ \/ /\ termP[c][j] > 0
          /\ termP' = [termP EXCEPT ![c][j] = @ - 1]
          /\ UNCHANGED termHb
       \/ /\ termHb[c][j] > 0
          /\ termHb' = [termHb EXCEPT ![c][j] = @ - 1]
          /\ UNCHANGED termP
    /\ IF cjReg[c][j] = None
       THEN UNCHANGED cjVars
       ELSE KillGroup(c, j)
    /\ UNCHANGED <<CpUnchanged, cpAlive, free, resv, cst, cjReg, alloc, waiter, cjAbortMsg, netVars, histVars>>

(* _wait_child_process_finish (client_executor.py:622-688) after the leader is reaped: rc remap
   (:632-643), best-effort REPORT_JOB_FAILURE (:645-674), free the allocation (:676-679), pop the entry
   (:680-681).  Free happens at LEADER exit: descendants may still use the units (F10). *)
CpChildFinished(c, j) ==
    /\ cpAlive[c]
    /\ waiter[c][j]
    /\ cjProc[c][j] = "Exited"
    /\ cjReg[c][j] # None
    /\ LET e == cjReg[c][j]
           rc == IF cjRC[c][j] = RC_EXEC_ERR /\ ~e.abortReq
                 THEN (IF e.st = STARTING THEN RC_INFRA
                       ELSE IF e.st = STARTED THEN RC_EXCEPTION ELSE RC_EXEC_ERR)
                 ELSE cjRC[c][j]
       IN /\ msgs' = Send(msgs, {Report(j, c, rc)})
          /\ free' = [free EXCEPT ![c] = AddUnits(@, alloc[c][j])]
          /\ alloc' = [alloc EXCEPT ![c][j] = {}]
          /\ cjReg' = [cjReg EXCEPT ![c][j] = None]
          /\ waiter' = [waiter EXCEPT ![c][j] = FALSE]
          /\ using' = IF grp[c][j] THEN using ELSE [using EXCEPT ![c][j] = {}]
          /\ cjRC' = [cjRC EXCEPT ![c][j] = 0]        \* canonical: no reader after the waiter
    /\ UNCHANGED <<CpUnchanged, cpAlive, resv, cst, termP, termHb, cjAbortMsg, cjProc, grp, nextAtt, histVars>>

(* Heartbeat (communicator.py:580-649) and the server's _sync_client_jobs (fed_server.py:959-1077):
   jobs listed by the CP but unknown to the server are aborted with heartbeat_cleanup; pending outcomes of
   jobs whose SJ is gone and which the CP no longer lists are resolved (fail_run(INFRA) if no record,
   _resolve_missing_client_outcome :1086-1094).  Dead-job notifications to SJs are not modeled. *)
(* The heartbeat thread processes the previous reply's abort list synchronously before the next heartbeat
   (communicator.py:621-624, 640-646); abort_app joins the _terminate_job thread it starts for a STARTED or
   STOPPED job (client_executor.py:511-533).  So a client sends no heartbeat while one of its cleanup aborts is
   undelivered or blocked in that join. *)
HbBusy(c) == \/ \E m \in DOMAIN msgs : m.type = "ABORT" /\ m.cl = c /\ m.flag
             \/ \E j \in Jobs : termHb[c][j] > 0

Heartbeat(c) ==
    /\ cpAlive[c]
    /\ c \in sessions
    /\ ~HbBusy(c)
    /\ LET cjobs       == {j \in Jobs : cjReg[c][j] # None}                          \* get_all_job_ids
           outcomeJobs == {j \in Jobs : pending[j] # None}                           \* :1011
           serverJobs  == {j \in Jobs : rp[j] # None} \cup {j \in outcomeJobs : exc[j] = None}   \* :1014-1016
           abortList   == cjobs \ serverJobs                                         \* :1017
           missing     == {j \in (serverJobs \cup outcomeJobs) \ cjobs :
                               rp[j] = None /\ pending[j] # None /\ c \in pending[j]} \* :1047-1055
           frun        == {j \in missing : exc[j] = None /\ j \in runningJobs}
       IN /\ exc' = [j \in Jobs |-> IF j \in frun THEN [NewRec({}) EXCEPT !.rc = RC_INFRA] ELSE exc[j]]
          /\ pending' = [j \in Jobs |-> IF j \in frun THEN None
                                        ELSE IF j \in missing THEN pending[j] \ {c} ELSE pending[j]]
          /\ msgs' = Send(msgs, {AbortReq(j, c, TRUE) : j \in abortList})
          /\ failRunRec' = [j \in Jobs |-> failRunRec[j] \/ j \in frun]
    /\ UNCHANGED <<storeVars, rpc, cpc, slots, runningJobs, runAborted, latched, sj, sjRC, sjErr, rp, shared,
                   wfc, wfcStale, rmp, adminVars, cpVars, cjVars, nextAtt, ackAbort, ackStop, launches, postAckLaunch,
                   startedEv, endedEv, failAccepted, exeErrRec, sjAbortHandled, abortDropped, startFailCause, ackInWindow>>

(* CP process crash / exit: in-memory CP state is gone; CJs stop on parent death (app/utils.py:45-50);
   requests addressed to the CP are never processed. *)
ClientCrash(c) ==
    /\ cpAlive[c]
    /\ cpAlive' = [cpAlive EXCEPT ![c] = FALSE]
    /\ cjProc' = [cjProc EXCEPT ![c] = [j \in Jobs |-> IF @[j] = "Alive" THEN "Exited" ELSE @[j]]]
    /\ grp' = [grp EXCEPT ![c] = [j \in Jobs |-> FALSE]]
    /\ using' = [using EXCEPT ![c] = [j \in Jobs |-> {}]]
    /\ msgs' = Keep(msgs, {m \in DOMAIN msgs : ~(m.cl = c /\ m.type \in ClientBound)})
    /\ UNCHANGED <<CpUnchanged, free, resv, cst, cjReg, alloc, waiter, termP, termHb, cjAbortMsg, cjRC, nextAtt, histVars>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* Client job process (CJ) (worker_process.py main, client_app_runner.py). *)
(***************************************************************************)

CjUnchanged == <<storeVars, rpc, cpc, tableVars, sjVars, adminVars, cpAlive, free, resv, cst, alloc, waiter, termP, termHb>>

(* NOTIFY_JOB_STATUS STARTED (client_app_runner.py:71-78 -> client_executor.py:347-350, unlocked write). *)
CjNotifyStarted(c, j) ==
    /\ cpAlive[c]
    /\ cjProc[c][j] = "Alive"
    /\ cjReg[c][j] # None
    /\ cjReg[c][j].st = STARTING
    /\ cjReg' = [cjReg EXCEPT ![c][j] = [@ EXCEPT !.st = STARTED]]
    /\ UNCHANGED <<CjUnchanged, cjAbortMsg, cjVars, netVars, histVars>>

(* NOTIFY_JOB_STATUS STOPPED after the client runner returned (client_app_runner.py:80-88). *)
CjNotifyStopped(c, j) ==
    /\ cpAlive[c]
    /\ cjProc[c][j] = "Alive"
    /\ cjReg[c][j] # None
    /\ cjReg[c][j].st = STARTED
    /\ cjReg' = [cjReg EXCEPT ![c][j] = [@ EXCEPT !.st = STOPPED]]
    /\ UNCHANGED <<CjUnchanged, cjAbortMsg, cjVars, netVars, histVars>>

(* The CJ receives the ABORT fired by the CP: its runner aborts and returns (then STOPPED, then exit). *)
CjHandleAbort(c, j) ==
    /\ cjAbortMsg[c][j] > 0
    /\ cjAbortMsg' = [cjAbortMsg EXCEPT ![c][j] = @ - 1]
    /\ IF cpAlive[c] /\ cjProc[c][j] = "Alive" /\ cjReg[c][j] # None /\ cjReg[c][j].st = STARTED
       THEN cjReg' = [cjReg EXCEPT ![c][j] = [@ EXCEPT !.st = STOPPED]]
       ELSE UNCHANGED cjReg
    /\ UNCHANGED <<CjUnchanged, cjVars, netVars, histVars>>

(* CJ leader exit (mpm.run -> sys.exit / os._exit).  rc 0 after the runner started (STOPPED notify may be
   lost); rc 1 = any exception / crash / signal; rc 102 = UNSAFE_COMPONENT rc file while STARTING.
   desc: same-process-group descendants outlive the leader (user job code; F10). *)
CjExit(c, j, rc, desc) ==
    /\ cpAlive[c]
    /\ cjProc[c][j] = "Alive"
    /\ rc \in CjExitCodes
    /\ desc \in BOOLEAN
    /\ rc = 0 => (cjReg[c][j] # None /\ cjReg[c][j].st \in {STARTED, STOPPED})
    /\ rc = RC_UNSAFE => (cjReg[c][j] # None /\ cjReg[c][j].st = STARTING)
    /\ cjProc' = [cjProc EXCEPT ![c][j] = "Exited"]
    /\ cjRC' = [cjRC EXCEPT ![c][j] = rc]
    /\ grp' = [grp EXCEPT ![c][j] = desc]
    /\ using' = IF desc THEN using ELSE [using EXCEPT ![c][j] = {}]
    /\ UNCHANGED <<CjUnchanged, cjReg, cjAbortMsg, netVars, histVars>>

(* Same-group descendants finally exit. *)
CjGroupExit(c, j) ==
    /\ grp[c][j]
    /\ grp' = [grp EXCEPT ![c][j] = FALSE]
    /\ using' = IF cjProc[c][j] = "Alive" THEN using ELSE [using EXCEPT ![c][j] = {}]
    /\ UNCHANGED <<CjUnchanged, cjReg, cjAbortMsg, cjProc, cjRC, netVars, histVars>>

-----------------------------------------------------------------------------
(* Network: CellNet messages may be lost (optional / fire-and-forget / timed-out requests). *)
LoseMsg(m) ==
    /\ m \in DOMAIN msgs
    /\ msgs' = Consume(msgs, m)
    /\ UNCHANGED <<storeVars, rpc, cpc, tableVars, sjVars, adminVars, cpVars, cjVars, nextAtt, histVars>>

-----------------------------------------------------------------------------
(***************************************************************************)
(* Next-state relation                                                     *)
(***************************************************************************)

RunnerNext ==
    \/ RunnerScanList \/ RunnerScanReadDeleted \/ RunnerScanRead
    \/ RunnerTryNext \/ RunnerBackoffSkip \/ RunnerTryDone
    \/ RunnerCheckCollect \/ RunnerCheckTimeout
    \/ RunnerRefreshRead \/ RunnerRefreshWrite \/ RunnerSetCantSched
    \/ RunnerCheckSubmitted
    \/ \E F \in SUBSET Clients : RunnerDeployJob(F)
    \/ RunnerSetDispatched \/ RunnerMetaRead \/ RunnerMetaWrite \/ RunnerCheckDispatched
    \/ RunnerStartServerApp \/ RunnerStartServerAppFail
    \/ RunnerStartCollect \/ RunnerStartTimeout
    \/ RunnerInsertRunning \/ RunnerSetRunning
    \/ RunnerExceptStop \/ RunnerExceptSetFailed \/ RunnerExceptMeta

CmpNext ==
    \/ \E j \in Jobs : CmpFinalizeBegin(j) \/ CmpOutcomeDeadline(j)
    \/ CmpPublish
    \/ CmpRemove

AdminNext ==
    \/ \E j \in Jobs : \/ AdminAbortBegin(j) \/ AdminAbortWrite(j) \/ AdminStopRun(j) \/ AdminMarkAborted(j)
                       \/ AdminDeleteAuthorize(j) \/ AdminDeleteExec(j)
    \/ \E c \in Clients : AdminDisable(c)

ServerNext ==
    \/ \E m \in DOMAIN msgs : SpUpdateRunStatus(m) \/ SpProcessJobFailure(m)
    \/ \E j \in Jobs : SpWaitForComplete(j) \/ SpRemoveRunProcesses(j)
    \/ \E c \in Clients : SweepBegin(c)
    \/ SweepEnd

SjNext ==
    \/ \E j \in Jobs : \/ \E o \in SjOutcomes : SjFinish(j, o[1], o[2])
                       \/ SjCrash(j)
    \/ \E m \in DOMAIN msgs : SjHandleAbort(m)

CpNext ==
    \/ \E m \in DOMAIN msgs : \/ CpCheckResource(m) \/ CpCancelResource(m) \/ CpStartAllocate(m)
                       \/ CpStartAllocateAppMissing(m) \/ CpAbortApp(m)
    \/ \E c \in Clients, j \in Jobs : \/ CpStartRegister(c, j) \/ CpStartLaunch(c, j) \/ CpStartLaunchFail(c, j)
                                      \/ CpTerminateJob(c, j) \/ CpChildFinished(c, j)
    \/ \E c \in Clients : CpTick(c) \/ Heartbeat(c) \/ ClientCrash(c)

CjNext ==
    \E c \in Clients, j \in Jobs :
        \/ CjNotifyStarted(c, j) \/ CjNotifyStopped(c, j) \/ CjHandleAbort(c, j) \/ CjGroupExit(c, j)
        \/ \E rc \in CjExitCodes, d \in BOOLEAN : CjExit(c, j, rc, d)

NetNext == \E m \in DOMAIN msgs : LoseMsg(m)

Next == RunnerNext \/ CmpNext \/ AdminNext \/ ServerNext \/ SjNext \/ CpNext \/ CjNext \/ NetNext

Spec == Init /\ [][Next]_vars

(* Weak fairness on reactive steps only (no fault, no admin input).  Timeouts are fair only when the
   missing replies can no longer arrive; the outcome deadline and the reservation tick are timers. *)
CheckRepliesLost == \A c \in rpc.chk \ {m.cl : m \in CheckReps} : CheckReq(rpc.job, c, rpc.att) \notin DOMAIN msgs
StartRepliesLost == \A c \in rpc.sreq \ {m.cl : m \in StartReps} :
                        StartReq(rpc.ready, c, rpc.att) \notin DOMAIN msgs /\ cst[c][rpc.ready] = None

Fairness ==
    /\ WF_vars(RunnerScanList \/ RunnerScanReadDeleted \/ RunnerScanRead \/ RunnerTryNext \/ RunnerTryDone
               \/ RunnerCheckCollect \/ (RunnerCheckTimeout /\ CheckRepliesLost)
               \/ RunnerRefreshRead \/ RunnerRefreshWrite \/ RunnerSetCantSched \/ RunnerCheckSubmitted
               \/ RunnerDeployJob({}) \/ RunnerSetDispatched \/ RunnerMetaRead \/ RunnerMetaWrite
               \/ RunnerCheckDispatched \/ RunnerStartServerApp
               \/ RunnerStartCollect \/ (RunnerStartTimeout /\ StartRepliesLost)
               \/ RunnerInsertRunning \/ RunnerSetRunning
               \/ RunnerExceptStop \/ RunnerExceptSetFailed \/ RunnerExceptMeta)
    /\ \A j \in Jobs : WF_vars(CmpFinalizeBegin(j) \/ CmpOutcomeDeadline(j))
    /\ WF_vars(CmpPublish \/ CmpRemove)
    /\ \A j \in Jobs : WF_vars(AdminAbortWrite(j) \/ AdminStopRun(j) \/ AdminMarkAborted(j) \/ AdminDeleteExec(j))
    /\ \A j \in Jobs : WF_vars(SpWaitForComplete(j) \/ SpRemoveRunProcesses(j))
    /\ \A j \in Jobs : WF_vars(SjFinish(j, FALSE, 0))
    /\ WF_vars(\E m \in DOMAIN msgs : SpUpdateRunStatus(m) \/ SpProcessJobFailure(m) \/ SjHandleAbort(m))
    /\ WF_vars(\E c \in Clients : SweepBegin(c)) /\ WF_vars(SweepEnd)
    /\ \A c \in Clients : WF_vars(\E m \in DOMAIN msgs : m.cl = c /\ (CpCheckResource(m) \/ CpCancelResource(m)
                                                           \/ CpStartAllocate(m) \/ CpAbortApp(m)))
    /\ \A c \in Clients, j \in Jobs :
          /\ WF_vars(CpStartRegister(c, j) \/ CpStartLaunch(c, j))
          /\ WF_vars(CpTerminateJob(c, j)) /\ WF_vars(CpChildFinished(c, j))
          /\ WF_vars(CjNotifyStarted(c, j)) /\ WF_vars(CjNotifyStopped(c, j)) /\ WF_vars(CjHandleAbort(c, j))
          /\ WF_vars(CjExit(c, j, 0, FALSE)) /\ WF_vars(CjGroupExit(c, j))
    /\ \A c \in Clients : WF_vars(CpTick(c)) /\ WF_vars(Heartbeat(c))

FairSpec == Spec /\ Fairness

-----------------------------------------------------------------------------
(***************************************************************************)
(* Invariants                                                              *)
(***************************************************************************)

LiveClients == {c \in Clients : cpAlive[c]}

(* ---- Structural ---- *)
TypeOK ==
    /\ status \in [Jobs -> StatusVals]
    /\ pCount \in [Jobs -> Nat]
    /\ tagged \subseteq Jobs
    /\ firstTerm \in [Jobs -> Terminal \cup {None}]
    /\ failRunRec \in [Jobs -> BOOLEAN]
    /\ rpc.pc \in {"Scan", "ScanRead", "TryNext", "CheckWait", "RefreshRead", "RefreshWrite", "SetCantSched",
                   "ChkSubmitted", "Deploy", "SetDispatched", "MetaRead", "MetaWrite", "ChkDispatched",
                   "StartSJ", "StartWait", "InsertRunning", "SetRunning", "ExceptStop", "ExceptSetFailed",
                   "ExceptMeta", "Dead"}
    /\ cpc.pc \in {"Idle", "Publish", "Remove", "Dead"}
    /\ slots \subseteq Jobs /\ runningJobs \subseteq Jobs
    /\ \A j \in Jobs : pending[j] = None \/ pending[j] \subseteq Clients
    /\ \A j \in Jobs : latched[j] \in Terminal \cup {None}
    /\ sj \in [Jobs -> {"None", "Running", "Exited"}]
    /\ \A j \in Jobs : rp[j] = None \/ rp[j].rc \in RCs
    /\ \A j \in Jobs : exc[j] = None \/ exc[j].rc \in RCs
    /\ \A j \in Jobs : wfcStale[j] = None \/ wfcStale[j].rc \in RCs
    /\ sessions \subseteq Clients /\ disabled \subseteq Clients
    /\ \A c \in Clients : free[c] \in [Units -> Nat]
    /\ \A c \in Clients, j \in Jobs : cjProc[c][j] \in {"None", "Alive", "Exited"}
    /\ \A c \in Clients, j \in Jobs : cjReg[c][j] = None \/ cjReg[c][j].st \in {STARTING, STARTED, STOPPED}
    /\ \A m \in DOMAIN msgs : msgs[m] \in Nat \ {0}
    /\ \A c \in Clients, j \in Jobs : termP[c][j] \in Nat /\ termHb[c][j] \in Nat /\ cjAbortMsg[c][j] \in Nat

(* A job in running_jobs was started by the runner: JOB_STARTED fired and the SJ was launched. *)
RunningWasStarted == \A j \in runningJobs : startedEv[j] /\ launches[j] >= 1

(* The completion thread never publishes before latching. *)
PublishHasLatch == cpc.pc \in {"Publish", "Remove"} => latched[cpc.job] \in Terminal

(* Reservations live at most Expiry ticks (by construction of the expiry thread; clocked contract A6). *)
ReservationBounded == \A c \in LiveClients : \A r \in resv[c] : r.ttl \in 1..Expiry

(* ---- S1: status transitions ---- *)

(* Every FINISHED:* status is terminal (job_cli.py:1926-1936, job.rst:342-345); deletion excepted. *)
TerminalStable == \A j \in Jobs : firstTerm[j] # None => status[j] \in {firstTerm[j], DELETED}

(* Hunting residual for MC-1 (NOT a contract): terminal overwrites whose writer/from pair is one of the
   seed mechanisms already confirmed in code (brief section 6.1: F1, F3, F16, RS-3 and the F1 family
   I4/I5) are tolerated so that the search can continue to NEW overwrite paths.  TerminalStable remains the
   contract. *)
KnownOverwrite(o) ==
    \/ o.w \in {"SetDispatched", "MetaWrite"} /\ o.from = ABORTED               \* F1 (A1), I4
    \/ o.w = "SetRunning" /\ o.from \in Terminal                                \* F1 (A2), F3
    \/ o.w = "RefreshWrite" /\ o.from = ABORTED                                 \* F16
    \/ o.w = "SetCantSched" /\ o.from = ABORTED                                 \* RS-3
    \/ o.w = "ExceptSetFailed" /\ o.from = ABORTED                              \* I5 (F1 family)
NoNovelTerminalOverwrite == \A o \in ovw : KnownOverwrite(o)
KnownOverwriteOf(j) == \E o \in ovw : o.j = j /\ KnownOverwrite(o)

(* Hunting residual for MC-1 (NOT a contract): AbortHonored, except for jobs whose abort was acknowledged
   inside the confirmed F1 deploy/start windows or already lost through a known seed overwrite (F16 / RS-3). *)
AbortHonoredNovel ==
    \A j \in Jobs : (ackAbort[j] /\ ~ackInWindow[j] /\ ~KnownOverwriteOf(j))
                     => (status[j] \in {ABORTED, DELETED} /\ ~postAckLaunch[j])

(* abort_job acknowledged "Aborted ... before running it." (job_cmds.py:218-225,1063; operation.rst:42):
   no SJ/CJ of the job is launched afterwards and its status stays FINISHED:ABORTED (or it is deleted). *)
AbortHonored == \A j \in Jobs : ackAbort[j] => (status[j] \in {ABORTED, DELETED} /\ ~postAckLaunch[j])

(* "Once submitted, a job only has one chance to be executed" (job.rst:342-345). *)
OneShot == \A j \in Jobs : launches[j] <= 1

(* A persisted RUNNING status is backed by the runner's running_jobs table (brief S1, F3). *)
RunningIsTracked ==
    \A j \in Jobs : status[j] = RUNNING =>
        \/ j \in runningJobs
        \/ (rpc.ready = j /\ rpc.pc \notin {"Scan", "ScanRead", "Dead"})

(* ---- S2: admission ---- *)

(* scheduled_jobs mirrors JOB_STARTED minus JOB_COMPLETED/JOB_ABORTED; max_jobs respected (job.rst:397-398). *)
SlotBalance ==
    /\ slots = {j \in Jobs : startedEv[j] /\ ~endedEv[j]}
    /\ Cardinality(slots) <= MaxJobs

(* Every held admission slot has a live owner that will release it (MC-2: slot leak). *)
RunnerOwnsSlotPCs == {"InsertRunning", "SetRunning", "ExceptStop", "ExceptSetFailed", "ExceptMeta"}
NoOrphanSlot ==
    \A j \in slots :
        \/ /\ j \in runningJobs
           /\ cpc.pc # "Dead"
           /\ (status[j] # DELETED \/ (cpc.pc = "Remove" /\ cpc.job = j))
        \/ (rpc.ready = j /\ rpc.pc \in RunnerOwnsSlotPCs)

(* Hunting residual for MC-2 (NOT a contract): orphan slots other than those left by a dead runner (the
   confirmed F2 / RS-8 seed). *)
NoOrphanSlotNovel == rpc.pc = "Dead" \/ NoOrphanSlot

(* The single scheduling thread and the completion thread stay alive (F2, RS-1, RS-7). *)
RunnerAliveInv == RunnerAlive
CompletionAlive == cpc.pc # "Dead"
SweeperAlive == sweeper.pc # "Dead"

(* ---- S3: resource ownership ---- *)

HeldBy(c, u) ==      \* number of owners holding unit u on client c
      Cardinality({r \in resv[c] : u \in r.units})
    + Cardinality({j \in Jobs : u \in alloc[c][j]})
    + Cardinality({j \in Jobs : cst[c][j] # None /\ u \in cst[c][j].units})

(* free (+) reserved (+) allocated = capacity, as bags (no loss, no duplication). *)
ResourceConservation == \A c \in LiveClients : \A u \in Units : free[c][u] + HeldBy(c, u) = 1

(* No unit is held by two different jobs through reservations, allocations or live process groups. *)
Holders(c, u) ==
      {r.job : r \in {x \in resv[c] : u \in x.units}}
    \cup {j \in Jobs : u \in alloc[c][j] \/ u \in using[c][j] \/ (cst[c][j] # None /\ u \in cst[c][j].units)}
ExclusiveOwnership == \A c \in LiveClients : \A u \in Units : Cardinality(Holders(c, u)) <= 1

(* A unit re-enters the free pool only when its job's process group is gone (F10). *)
NoFreeWhileGroupAlive ==
    \A c \in LiveClients : \A j \in Jobs : \A u \in using[c][j] : free[c][u] = 0

(* Informational (expected to fail by design, F6): every reservation still has an owner that will consume or
   cancel it; otherwise only the expiry reclaims it. *)
TokenOwned(c, r) ==
    \/ rpc.pc = "CheckWait" /\ rpc.att = r.tok
    \/ /\ rpc.ready = r.job /\ rpc.att = r.tok /\ c \in rpc.disp
       /\ rpc.pc \in {"RefreshRead", "RefreshWrite", "SetCantSched", "ChkSubmitted", "Deploy"}
    \/ /\ rpc.ready = r.job /\ rpc.att = r.tok /\ c \in rpc.dep
       /\ rpc.pc \in {"SetDispatched", "MetaRead", "MetaWrite", "ChkDispatched", "StartSJ"}
    \/ \E m \in DOMAIN msgs : m.att = r.tok /\ m.cl = c /\ m.type \in {"CHECK_REP", "CANCEL", "START"}
PromptCancel == \A c \in LiveClients : \A r \in resv[c] : TokenOwned(c, r)

(* ---- S4: terminal-status composition ---- *)

(* The published terminal status matches the recorded outcome signals (MC-4):
   (a) FINISHED:COMPLETED is never published for a job whose SJ execution error was recorded, whose client
       failure report was accepted, or whose SJ was ended by an ABORT command;
   (b) an authoritative fail_run failure (job_runner.py:837-840, D8) is published as the failure it recorded
       (EXECUTION_EXCEPTION / ABNORMAL / ABORTED by precedence).  The only exception is a start that
       genuinely failed on its own (no / missing / ERROR START replies, admin.py:102-137), where
       FAILED_TO_RUN is also an accurate outcome; an internal KeyError (:360) is not such a failure (F5). *)
FinalMatchesOutcome ==
    \A j \in Jobs :
        /\ status[j] = COMPLETED => (~exeErrRec[j] /\ ~failAccepted[j] /\ ~sjAbortHandled[j])
        /\ (failRunRec[j] /\ status[j] \in Terminal /\ startFailCause[j] # "error")
             => status[j] \in {EXEC_EXC, ABNORMAL, ABORTED}

(* Hunting residual for MC-4 (NOT a contract): clause (b) additionally tolerates the confirmed F5 outcome
   (KeyError at job_runner.py:360 after fail_run, published FINISHED:FAILED_TO_RUN). *)
FinalMatchesOutcomeNovel ==
    \A j \in Jobs :
        /\ status[j] = COMPLETED => (~exeErrRec[j] /\ ~failAccepted[j] /\ ~sjAbortHandled[j])
        /\ (failRunRec[j] /\ status[j] \in Terminal /\ startFailCause[j] = "none")
             => status[j] \in {EXEC_EXC, ABNORMAL, ABORTED}

(* Informational (F17/F20): ground truth, the SJ ended with an execution error. *)
SjErrorNotMasked == \A j \in Jobs : status[j] = COMPLETED => ~sjErr[j]

(* ---- S5: partial start vs site policy (informational, policy question F15) ---- *)
StartFailureMatchesPolicy ==
    [][ (rpc.pc = "StartWait" /\ rpc'.pc = "ExceptStop") =>
          LET j == rpc.ready
              good == {m.cl : m \in {x \in StartReps : ~x.flag}}
          IN Cardinality(good) < MinSites[j] \/ ~(Required[j] \subseteq good) ]_vars

(* ---- Liveness (checked only in small liveness configurations, FairSpec) ---- *)

(* A SUBMITTED well-formed job eventually leaves SUBMITTED (job.rst:365-369; batch-5 contract 10). *)
AdmissionProgress == \A j \in Jobs : PoisonAt[j] = "none" => (status[j] = SUBMITTED ~> status[j] # SUBMITTED)

(* A running job whose SJ exited is eventually finalized (bounded by the 900 s outcome barrier). *)
BoundedFinalization == \A j \in Jobs : (j \in runningJobs /\ sj[j] = "Exited") ~> (j \notin runningJobs)

(* After a terminal status, every live client eventually has no process of the job and none of its units. *)
JobCleanOn(c, j) ==
    \/ ~cpAlive[c]
    \/ /\ cjProc[c][j] # "Alive" /\ ~grp[c][j] /\ alloc[c][j] = {} /\ cst[c][j] = None
       /\ \A r \in resv[c] : r.job # j
EventualCleanup == \A j \in Jobs, c \in Clients : (status[j] \in Terminal) ~> JobCleanOn(c, j)

=============================================================================
