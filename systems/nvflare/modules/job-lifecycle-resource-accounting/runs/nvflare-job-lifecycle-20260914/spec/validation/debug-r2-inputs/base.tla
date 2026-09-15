------------------------------ MODULE base ------------------------------
EXTENDS Integers, Sequences, FiniteSets, TLC

(***************************************************************************
 Category A, NVFlare 53ba7ee567468ea7971dad4faccef13c6cb35dc2.
 Selected: ListResourceManager(gpu=[0,1], expiration_period=30), valid
 one-unit demands, ListResourceConsumer, default local process launchers.
 Each token <<job, attempt>> denotes a fresh site-local UUID; waiter identity
 additionally includes operation and site. Requests are sent once per attempt.
 Sites stay connected in this slice; delayed/lost traffic remains possible.
 Unbounded real durations are abstracted at deadline crossings. TTL scans
 remain explicit, atomic per site, and are never fault-counter bounded.
 No process crash recovery, workspace contents, GPU computation, arbitrary
 START replay, custom invalid counts, or throwing replacement event dispatch.
 Scenario 5 service-death extensions await TV-2/TV-3. Failure-branch metadata
 operations are successful in this slice; see brief-coverage.md for limits.
***************************************************************************)
CONSTANTS Jobs, JobOrder, Sites, Pool, RequiredSites, MinSites, StrictStart,
          MaxJobs, MaxScheduleCount, MinScheduleInterval, MaxScheduleInterval,
          AttemptSlots, ReservationTTL, OutcomeGrace, ArchiveGrace

Tokens == Jobs \X (1..AttemptSlots)
Units == {Pool[i] : i \in DOMAIN Pool}
SeqSet(q) == {q[i] : i \in DOMAIN q}
Reverse(q) == [i \in 1..Len(q) |-> q[Len(q)-i+1]]
Count(q,u) == Cardinality({i \in DOMAIN q : q[i] = u})
RECURSIVE SumOn(_,_)
SumOn(ds,f) == IF ds = {} THEN 0
              ELSE LET d == CHOOSE x \in ds : TRUE
                   IN f[d] + SumOn(ds \ {d},f)
Min(a,b) == IF a < b THEN a ELSE b
Statuses == {"SUBMITTED","DISPATCHED","RUNNING","ABORTED","COMPLETED",
             "FAILED","FAILED_TO_RUN","CANT_SCHEDULE"}
Terminal == {"ABORTED","COMPLETED","FAILED","FAILED_TO_RUN","CANT_SCHEDULE"}
ReplyStates == {"idle","waiting","ok","no","timeout"}
Kinds == {"Check","CheckOK","CheckNo","Cancel","CancelAck",
          "Deploy","DeployOK","DeployNo","Start","StartOK","StartNo",
          "Stop","OutcomeOK","OutcomeFailed","HeartbeatStop"}
Msg(k,s,t) == [kind |-> k, site |-> s, job |-> t[1], attempt |-> t[2]]
AllMessages == {Msg(k,s,t) : k \in Kinds, s \in Sites, t \in Tokens}

\* Scenarios 1-5: scheduling locals, retry metadata, synchronous event membership.
\* job_scheduler.py:55-60,263-285,320-375; job_runner.py:650-731.
VARIABLE scheduler
\* Scenarios 3-5: independent metadata, runner/process maps, completion/admin PCs.
\* job_runner.py:441-538,661-730; job_cmds.py:1059-1078.
VARIABLE jobs
\* Scenarios 1,2,4: free deque and per-token reserved/allocated payloads.
\* allocated/payload/releases are ownership observer state, not extra RM guards.
\* auto_clean_resource_manager.py:102-172; list_resource_manager.py:52-75.
VARIABLE rm
\* Scenarios 1,2,4: callback/waiter PCs, pending handle, physical child ownership.
\* client_executor.py:299-334,486-545,622-687.
VARIABLE client
\* Scenario 1: shared parent environment, separate immutable child snapshot.
\* list_resource_consumer.py:31-37; process_launcher.py:66-83.
VARIABLE resourceEnv
\* Scenarios 1,4,5: request waiters and in-flight commands/replies; timeout does
\* not cancel execution. server_engine.py:1007-1083; admin.py:286-339.
VARIABLES rpc, network
vars == <<scheduler,jobs,rm,client,resourceEnv,rpc,network>>

EmptyReplies == [check |-> "idle",deploy |-> "idle",start |-> "idle",cancel |-> "idle"]
EmptyClient == [pc |-> "idle", handle |-> "none", alive |-> FALSE,
                spawned |-> FALSE, binding |-> <<>>, waiter |-> FALSE,
                cleanup |-> "none", logical |-> "NOT_STARTED",
                abortRequested |-> FALSE, terminateRequested |-> FALSE,
                pendingAbort |-> FALSE, attached |-> FALSE,
                exitObserved |-> FALSE, exitCode |-> "ok", deployed |-> FALSE]
EmptyJob == [status |-> "SUBMITTED", checked |-> "SUBMITTED",
             dispatch |-> {}, deployed |-> {}, active |-> {}, pending |-> {},
             outcomeKey |-> FALSE, serverAlive |-> FALSE,
             serverSpawned |-> FALSE, serverRegistered |-> FALSE,
             serverWaiter |-> FALSE, serverFailed |-> FALSE,
             serverStop |-> FALSE, serverTerminated |-> FALSE,
             running |-> FALSE, runAborted |-> FALSE, abortAck |-> FALSE,
             adminPC |-> "idle", adminRead |-> "SUBMITTED",
             completion |-> "idle", finishStatus |-> "COMPLETED",
             archiveFailed |-> FALSE, terminalPublished |-> FALSE,
             resurrected |-> FALSE, completedRemoved |-> FALSE]

Init ==
    \* job_scheduler.py:55-60,320-333; a finite submitted workload already exists.
    /\ scheduler = [pc |-> "idle", current |-> "", candidates |-> <<>>,
                     issued |-> [j \in Jobs |-> 0], count |-> [j \in Jobs |-> 0],
                     persisted |-> [j \in Jobs |-> 0],
                     history |-> [j \in Jobs |-> <<>>],
                     cooldown |-> [j \in Jobs |-> FALSE], scheduled |-> {},
                     considered |-> [j \in Jobs |-> 0], result |-> "none",
                     failedPending |-> {}, blockedPending |-> {}, returnTo |-> "idle"]
    \* job_runner.py:101-112; job_def_manager.py:459-481.
    /\ jobs = [j \in Jobs |-> EmptyJob]
    \* list_resource_manager.py:45-50; auto_clean_resource_manager.py:47-49.
    /\ rm = [s \in Sites |-> [free |-> Pool,
                              reserved |-> [t \in Tokens |-> <<>>],
                              ttl |-> [t \in Tokens |-> 0],
                              allocated |-> [t \in Tokens |-> <<>>],
                              payload |-> [t \in Tokens |-> <<>>],
                              releases |-> [t \in Tokens |-> 0]]]
    \* client_executor.py:299-307; list_resource_consumer.py:28-37.
    /\ client = [s \in Sites |-> [t \in Tokens |-> EmptyClient]]
    /\ resourceEnv = [s \in Sites |-> <<>>]
    \* server_engine.py:1011,1055,1069: no requests before scheduling.
    /\ rpc = [s \in Sites |-> [t \in Tokens |-> EmptyReplies]]
    /\ network = {}

CurrentJob == scheduler.current
CurrentToken == <<CurrentJob,scheduler.issued[CurrentJob]>>
Policy(ss) == /\ Cardinality(ss) >= MinSites /\ RequiredSites \subseteq ss
ReplySites(t,k,r) == {s \in Sites : rpc[s][t][k] = r}
WaitDone(t,k,ss) == \A s \in ss : rpc[s][t][k] \notin {"idle","waiting"}
Backoff(j) == Min(MaxScheduleInterval,
                 (2^(IF scheduler.count[j]=0 THEN 0 ELSE scheduler.count[j]-1))*MinScheduleInterval)
RegisteredAtSite(s,j) == \E t \in Tokens : t[1]=j /\ client[s][t].handle # "none"
LiveAtSite(s,j) == \E t \in Tokens : t[1]=j /\ client[s][t].alive

\* auto_clean_resource_manager.py:105-116: scan and deallocation share one lock.
ResourceManagerUnlocked(s) ==
    \A t \in Tokens : rm[s].reserved[t] # <<>> => rm[s].ttl[t] > 0

ConfigJobOrder == IF "job-2" \in Jobs THEN <<"job-1","job-2">> ELSE <<"job-1">>
ConfigPool == <<0,1>>

\* Scenario 5. nvflare/app_common/job_schedulers/job_scheduler.py:339-346; nvflare/private/fed/server/job_runner.py:641-658
DefaultJobSchedulerBeginPass ==
    \* nvflare/app_common/job_schedulers/job_scheduler.py:339-346; nvflare/private/fed/server/job_runner.py:641-658
    /\ scheduler.pc = "idle"
    \* nvflare/app_common/job_schedulers/job_scheduler.py:339-346; nvflare/private/fed/server/job_runner.py:641-658
    /\ Cardinality(scheduler.scheduled) < MaxJobs
    \* nvflare/app_common/job_schedulers/job_scheduler.py:339-346; nvflare/private/fed/server/job_runner.py:641-658
    /\ scheduler' = [scheduler EXCEPT !.pc = "scan", !.candidates = SelectSeq(JobOrder,LAMBDA j : jobs[j].status = "SUBMITTED")]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 5. nvflare/app_common/job_schedulers/job_scheduler.py:377-378
DefaultJobSchedulerEndPass ==
    \* nvflare/app_common/job_schedulers/job_scheduler.py:377-378
    /\ scheduler.pc = "scan"
    \* nvflare/app_common/job_schedulers/job_scheduler.py:377-378
    /\ scheduler.candidates = <<>>
    \* nvflare/app_common/job_schedulers/job_scheduler.py:377-378
    /\ scheduler' = [scheduler EXCEPT !.pc = "persistFailed", !.returnTo = "idle"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 5. nvflare/app_common/job_schedulers/job_scheduler.py:356-362
DefaultJobSchedulerSkipBackoff ==
    \* nvflare/app_common/job_schedulers/job_scheduler.py:356-362
    /\ scheduler.pc = "scan"
    \* nvflare/app_common/job_schedulers/job_scheduler.py:356-362
    /\ scheduler.candidates # <<>>
    \* nvflare/app_common/job_schedulers/job_scheduler.py:356-362
    /\ scheduler.cooldown[Head(scheduler.candidates)]
    \* nvflare/app_common/job_schedulers/job_scheduler.py:356-362
    /\ scheduler.count[Head(scheduler.candidates)] < MaxScheduleCount
    \* nvflare/app_common/job_schedulers/job_scheduler.py:356-362
    /\ scheduler' = [scheduler EXCEPT !.candidates = Tail(scheduler.candidates)]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 5. nvflare/app_common/job_schedulers/job_scheduler.py:356-362
\* Deadline crossing; elapsed seconds must be >= Backoff(j); no normal retry counter bound.
DefaultJobSchedulerBackoffElapsed(j) ==
    \* nvflare/app_common/job_schedulers/job_scheduler.py:356-362
    /\ scheduler.cooldown[j]
    \* nvflare/app_common/job_schedulers/job_scheduler.py:356-362
    /\ scheduler' = [scheduler EXCEPT !.cooldown[j] = FALSE]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 5. nvflare/app_common/job_schedulers/job_scheduler.py:298-310; nvflare/app_common/job_schedulers/job_scheduler.py:347-354
\* The exhausted-candidate metadata write succeeds in this slice.
DefaultJobSchedulerExhausted ==
    \* nvflare/app_common/job_schedulers/job_scheduler.py:298-310; nvflare/app_common/job_schedulers/job_scheduler.py:347-354
    /\ scheduler.pc = "scan"
    \* nvflare/app_common/job_schedulers/job_scheduler.py:298-310; nvflare/app_common/job_schedulers/job_scheduler.py:347-354
    /\ scheduler.candidates # <<>>
    \* nvflare/app_common/job_schedulers/job_scheduler.py:298-310; nvflare/app_common/job_schedulers/job_scheduler.py:347-354
    /\ scheduler.count[Head(scheduler.candidates)] >= MaxScheduleCount
    \* nvflare/app_common/job_schedulers/job_scheduler.py:298-310; nvflare/app_common/job_schedulers/job_scheduler.py:347-354
    /\ scheduler' = [scheduler EXCEPT !.count[Head(scheduler.candidates)] = @+1, !.history[Head(scheduler.candidates)] = Append(@,"exceeded"), !.cooldown[Head(scheduler.candidates)] = TRUE, !.blockedPending = @ \cup {Head(scheduler.candidates)}, !.candidates = Tail(@)]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 1-5. nvflare/app_common/job_schedulers/job_scheduler.py:104-199; nvflare/app_common/job_schedulers/job_scheduler.py:347-365
\* Connected valid selected sites pass applicability checks. AttemptSlots is a finite fresh-token universe, not retry policy.
DefaultJobSchedulerTryJob ==
    \* nvflare/app_common/job_schedulers/job_scheduler.py:104-199; nvflare/app_common/job_schedulers/job_scheduler.py:347-365
    /\ scheduler.pc = "scan"
    \* nvflare/app_common/job_schedulers/job_scheduler.py:104-199; nvflare/app_common/job_schedulers/job_scheduler.py:347-365
    /\ scheduler.candidates # <<>>
    \* nvflare/app_common/job_schedulers/job_scheduler.py:104-199; nvflare/app_common/job_schedulers/job_scheduler.py:347-365
    /\ ~scheduler.cooldown[Head(scheduler.candidates)]
    \* nvflare/app_common/job_schedulers/job_scheduler.py:104-199; nvflare/app_common/job_schedulers/job_scheduler.py:347-365
    /\ scheduler.count[Head(scheduler.candidates)] < MaxScheduleCount
    \* nvflare/app_common/job_schedulers/job_scheduler.py:104-199; nvflare/app_common/job_schedulers/job_scheduler.py:347-365
    /\ scheduler.issued[Head(scheduler.candidates)] < AttemptSlots
    \* nvflare/app_common/job_schedulers/job_scheduler.py:104-199; nvflare/app_common/job_schedulers/job_scheduler.py:347-365
    /\ scheduler' = [scheduler EXCEPT !.current = Head(scheduler.candidates), !.issued[Head(scheduler.candidates)] = @+1, !.considered[Head(scheduler.candidates)] = @+1, !.pc = "sendCheck"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 1-5. nvflare/private/fed/server/server_engine.py:1010-1024
ServerEngineCheckClientResources ==
    \* nvflare/private/fed/server/server_engine.py:1010-1024
    /\ scheduler.pc = "sendCheck"
    \* nvflare/private/fed/server/server_engine.py:1010-1024
    /\ network' = network \cup {Msg("Check",s,CurrentToken) : s \in Sites}
    \* nvflare/private/fed/server/server_engine.py:1010-1024
    /\ rpc' = [s \in Sites |-> [rpc[s] EXCEPT ![CurrentToken].check = "waiting"]]
    \* nvflare/private/fed/server/server_engine.py:1010-1024
    /\ scheduler' = [scheduler EXCEPT !.pc = "checkWait"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv>>

\* Scenario 1,2,4,5. nvflare/private/fed/client/scheduler_cmds.py:67-93; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:123-138; nvflare/app_common/resource_managers/list_resource_manager.py:57-75
CheckResourceProcessorReserve(s,t) ==
    \* nvflare/private/fed/client/scheduler_cmds.py:67-93; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:123-138; nvflare/app_common/resource_managers/list_resource_manager.py:57-75
    /\ ResourceManagerUnlocked(s)
    \* nvflare/private/fed/client/scheduler_cmds.py:67-93; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:123-138; nvflare/app_common/resource_managers/list_resource_manager.py:57-75
    /\ Msg("Check", s, t) \in network
    \* nvflare/private/fed/client/scheduler_cmds.py:67-93; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:123-138; nvflare/app_common/resource_managers/list_resource_manager.py:57-75
    /\ rm[s].free # <<>>
    \* nvflare/private/fed/client/scheduler_cmds.py:67-93; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:123-138; nvflare/app_common/resource_managers/list_resource_manager.py:57-75
    /\ rm' = [rm EXCEPT ![s].free = Tail(@), ![s].reserved[t] = <<Head(rm[s].free)>>, ![s].ttl[t] = ReservationTTL]
    \* nvflare/private/fed/client/scheduler_cmds.py:67-93; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:123-138; nvflare/app_common/resource_managers/list_resource_manager.py:57-75
    /\ network' = (network \ {Msg("Check", s, t)}) \cup {Msg("CheckOK", s, t)}
    /\ UNCHANGED <<scheduler,jobs,client,resourceEnv,rpc>>

\* Scenario 1,4,5. nvflare/private/fed/client/scheduler_cmds.py:83-93; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:123-138; nvflare/app_common/resource_managers/list_resource_manager.py:57-67
CheckResourceProcessorUnavailable(s,t) ==
    \* nvflare/private/fed/client/scheduler_cmds.py:83-93; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:123-138; nvflare/app_common/resource_managers/list_resource_manager.py:57-67
    /\ ResourceManagerUnlocked(s)
    \* nvflare/private/fed/client/scheduler_cmds.py:83-93; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:123-138; nvflare/app_common/resource_managers/list_resource_manager.py:57-67
    /\ Msg("Check", s, t) \in network
    \* nvflare/private/fed/client/scheduler_cmds.py:83-93; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:123-138; nvflare/app_common/resource_managers/list_resource_manager.py:57-67
    /\ rm[s].free = <<>>
    \* nvflare/private/fed/client/scheduler_cmds.py:83-93; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:123-138; nvflare/app_common/resource_managers/list_resource_manager.py:57-67
    /\ network' = (network \ {Msg("Check", s, t)}) \cup {Msg("CheckNo", s, t)}
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv,rpc>>

\* Scenario 1,4,5. nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
\* Closed waiters discard late replies; no mutation of another token or lifecycle status.
ServerEngineReceiveCheckOK(s,t) ==
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ Msg("CheckOK", s, t) \in network
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ network' = network \ {Msg("CheckOK", s, t)}
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ rpc' = [rpc EXCEPT ![s][t].check = IF rpc[s][t].check = "waiting" THEN "ok" ELSE rpc[s][t].check]
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv>>

\* Scenario 1,4,5. nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
\* Closed waiters discard late replies; no mutation of another token or lifecycle status.
ServerEngineReceiveCheckNo(s,t) ==
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ Msg("CheckNo", s, t) \in network
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ network' = network \ {Msg("CheckNo", s, t)}
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ rpc' = [rpc EXCEPT ![s][t].check = IF rpc[s][t].check = "waiting" THEN "no" ELSE rpc[s][t].check]
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv>>

\* Scenario 1,4,5. nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339
\* Actual RPC deadline crossing; commands already sent remain executable.
AdminCheckTimeout(t) ==
    \* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339
    /\ \E s \in Sites : rpc[s][t].check = "waiting"
    \* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339
    /\ rpc' = [s \in Sites |-> [rpc[s] EXCEPT ![t].check = IF @ = "waiting" THEN "timeout" ELSE @]]
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv,network>>

\* Scenario 1,4,5. nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
\* Closed waiters discard late replies; no mutation of another token or lifecycle status.
ServerEngineReceiveDeployOK(s,t) ==
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ Msg("DeployOK", s, t) \in network
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ network' = network \ {Msg("DeployOK", s, t)}
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ rpc' = [rpc EXCEPT ![s][t].deploy = IF rpc[s][t].deploy = "waiting" THEN "ok" ELSE rpc[s][t].deploy]
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv>>

\* Scenario 1,4,5. nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
\* Closed waiters discard late replies; no mutation of another token or lifecycle status.
ServerEngineReceiveDeployNo(s,t) ==
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ Msg("DeployNo", s, t) \in network
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ network' = network \ {Msg("DeployNo", s, t)}
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ rpc' = [rpc EXCEPT ![s][t].deploy = IF rpc[s][t].deploy = "waiting" THEN "no" ELSE rpc[s][t].deploy]
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv>>

\* Scenario 1,4,5. nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339
\* Actual RPC deadline crossing; commands already sent remain executable.
AdminDeployTimeout(t) ==
    \* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339
    /\ \E s \in Sites : rpc[s][t].deploy = "waiting"
    \* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339
    /\ rpc' = [s \in Sites |-> [rpc[s] EXCEPT ![t].deploy = IF @ = "waiting" THEN "timeout" ELSE @]]
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv,network>>

\* Scenario 1,4,5. nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
\* Closed waiters discard late replies; no mutation of another token or lifecycle status.
ServerEngineReceiveStartOK(s,t) ==
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ Msg("StartOK", s, t) \in network
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ network' = network \ {Msg("StartOK", s, t)}
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ rpc' = [rpc EXCEPT ![s][t].start = IF rpc[s][t].start = "waiting" THEN "ok" ELSE rpc[s][t].start]
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv>>

\* Scenario 1,4,5. nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
\* Closed waiters discard late replies; no mutation of another token or lifecycle status.
ServerEngineReceiveStartNo(s,t) ==
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ Msg("StartNo", s, t) \in network
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ network' = network \ {Msg("StartNo", s, t)}
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ rpc' = [rpc EXCEPT ![s][t].start = IF rpc[s][t].start = "waiting" THEN "no" ELSE rpc[s][t].start]
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv>>

\* Scenario 1,4,5. nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339
\* Actual RPC deadline crossing; commands already sent remain executable.
AdminStartTimeout(t) ==
    \* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339
    /\ \E s \in Sites : rpc[s][t].start = "waiting"
    \* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339
    /\ rpc' = [s \in Sites |-> [rpc[s] EXCEPT ![t].start = IF @ = "waiting" THEN "timeout" ELSE @]]
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv,network>>

\* Scenario 1,4,5. nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
\* Closed waiters discard late replies; no mutation of another token or lifecycle status.
ServerEngineReceiveCancelAck(s,t) ==
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ Msg("CancelAck", s, t) \in network
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ network' = network \ {Msg("CancelAck", s, t)}
    \* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339
    /\ rpc' = [rpc EXCEPT ![s][t].cancel = IF rpc[s][t].cancel = "waiting" THEN "ok" ELSE rpc[s][t].cancel]
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv>>

\* Scenario 1,4,5. nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339
\* Actual RPC deadline crossing; commands already sent remain executable.
AdminCancelTimeout(t) ==
    \* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339
    /\ \E s \in Sites : rpc[s][t].cancel = "waiting"
    \* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339
    /\ rpc' = [s \in Sites |-> [rpc[s] EXCEPT ![t].cancel = IF @ = "waiting" THEN "timeout" ELSE @]]
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv,network>>

\* Scenario 1,2,5. nvflare/app_common/job_schedulers/job_scheduler.py:203-261
DefaultJobSchedulerEvaluateResources ==
    \* nvflare/app_common/job_schedulers/job_scheduler.py:203-261
    /\ scheduler.pc = "checkWait"
    \* nvflare/app_common/job_schedulers/job_scheduler.py:203-261
    /\ WaitDone(CurrentToken,"check",Sites)
    \* nvflare/app_common/job_schedulers/job_scheduler.py:203-261
    /\ scheduler' = [scheduler EXCEPT !.pc = IF Policy(ReplySites(CurrentToken,"check","ok")) THEN "history" ELSE "cancelSend", !.result = IF Policy(ReplySites(CurrentToken,"check","ok")) THEN "scheduled" ELSE "no_resource"]
    \* nvflare/app_common/job_schedulers/job_scheduler.py:203-261
    /\ jobs' = [jobs EXCEPT ![CurrentJob].dispatch = ReplySites(CurrentToken,"check","ok")]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 4,5. nvflare/app_common/job_schedulers/job_scheduler.py:229-247; nvflare/private/fed/server/server_engine.py:1052-1066
ServerEngineCancelClientResources ==
    \* nvflare/app_common/job_schedulers/job_scheduler.py:229-247; nvflare/private/fed/server/server_engine.py:1052-1066
    /\ scheduler.pc = "cancelSend"
    \* nvflare/app_common/job_schedulers/job_scheduler.py:229-247; nvflare/private/fed/server/server_engine.py:1052-1066
    /\ network' = network \cup {Msg("Cancel",s,CurrentToken) : s \in jobs[CurrentJob].dispatch}
    \* nvflare/app_common/job_schedulers/job_scheduler.py:229-247; nvflare/private/fed/server/server_engine.py:1052-1066
    /\ rpc' = [s \in Sites |-> [rpc[s] EXCEPT ![CurrentToken].cancel = IF s \in jobs[CurrentJob].dispatch THEN "waiting" ELSE @]]
    \* nvflare/app_common/job_schedulers/job_scheduler.py:229-247; nvflare/private/fed/server/server_engine.py:1052-1066
    /\ scheduler' = [scheduler EXCEPT !.pc = "cancelWait"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv>>

\* Scenario 4,5. nvflare/private/fed/client/scheduler_cmds.py:149-157; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:140-151; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
\* Only existing reservations are returned. Missing or already allocated tokens are a no-op.
CancelResourceProcessorCancel(s,t) ==
    \* nvflare/private/fed/client/scheduler_cmds.py:149-157; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:140-151; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ ResourceManagerUnlocked(s)
    \* nvflare/private/fed/client/scheduler_cmds.py:149-157; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:140-151; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ Msg("Cancel", s, t) \in network
    \* nvflare/private/fed/client/scheduler_cmds.py:149-157; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:140-151; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ rm' = [rm EXCEPT ![s].free = Reverse(rm[s].reserved[t]) \o @, ![s].reserved[t] = <<>>, ![s].ttl[t] = 0]
    \* nvflare/private/fed/client/scheduler_cmds.py:149-157; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:140-151; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ network' = (network \ {Msg("Cancel", s, t)}) \cup {Msg("CancelAck", s, t)}
    /\ UNCHANGED <<scheduler,jobs,client,resourceEnv,rpc>>

\* Scenario 5. nvflare/private/fed/server/server_engine.py:1065-1066; nvflare/app_common/job_schedulers/job_scheduler.py:229-254
\* Pinned implementation discards cancellation acknowledgements, including timeout/no reply.
DefaultJobSchedulerCancelReturned ==
    \* nvflare/private/fed/server/server_engine.py:1065-1066; nvflare/app_common/job_schedulers/job_scheduler.py:229-254
    /\ scheduler.pc = "cancelWait"
    \* nvflare/private/fed/server/server_engine.py:1065-1066; nvflare/app_common/job_schedulers/job_scheduler.py:229-254
    /\ WaitDone(CurrentToken,"cancel",jobs[CurrentJob].dispatch)
    \* nvflare/private/fed/server/server_engine.py:1065-1066; nvflare/app_common/job_schedulers/job_scheduler.py:229-254
    /\ scheduler' = [scheduler EXCEPT !.pc = "history"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 5. nvflare/app_common/job_schedulers/job_scheduler.py:320-333; nvflare/app_common/job_schedulers/job_scheduler.py:364-375
DefaultJobSchedulerUpdateHistory ==
    \* nvflare/app_common/job_schedulers/job_scheduler.py:320-333; nvflare/app_common/job_schedulers/job_scheduler.py:364-375
    /\ scheduler.pc = "history"
    \* nvflare/app_common/job_schedulers/job_scheduler.py:320-333; nvflare/app_common/job_schedulers/job_scheduler.py:364-375
    /\ scheduler' = [scheduler EXCEPT !.count[CurrentJob] = @+1, !.history[CurrentJob] = Append(@,scheduler.result), !.cooldown[CurrentJob] = TRUE, !.pc = IF scheduler.result="scheduled" THEN "persistFailed" ELSE "scan", !.returnTo = IF scheduler.result="scheduled" THEN "checkSubmitted" ELSE "idle", !.failedPending = IF scheduler.result="scheduled" THEN @ ELSE @ \cup {CurrentJob}, !.candidates = IF scheduler.result="scheduled" THEN @ ELSE Tail(@)]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 5. nvflare/app_common/job_schedulers/job_scheduler.py:292-310; nvflare/app_common/job_schedulers/job_scheduler.py:364-369
\* Known #5191 context: whole pass exits, no new cancellation/history; TTL remains.
DefaultJobSchedulerAdmissionException ==
    \* nvflare/app_common/job_schedulers/job_scheduler.py:292-310; nvflare/app_common/job_schedulers/job_scheduler.py:364-369
    /\ scheduler.pc \in {"checkWait","history"}
    \* nvflare/app_common/job_schedulers/job_scheduler.py:292-310; nvflare/app_common/job_schedulers/job_scheduler.py:364-369
    /\ scheduler' = [scheduler EXCEPT !.pc = "persistFailed", !.returnTo = "idle", !.candidates = <<>>]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 1,4,5. nvflare/app_common/resource_managers/auto_clean_resource_manager.py:102-113
\* One cleanup scan tick. Expired entries are drained under the same RM lock by FinishExpiry; other RM operations are disabled while an expired entry exists.
AutoCleanResourceManagerTick(s) ==
    \* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:102-113
    /\ ResourceManagerUnlocked(s)
    \* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:102-113
    /\ \E t \in Tokens : rm[s].ttl[t] > 0
    \* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:102-113
    /\ rm' = [rm EXCEPT ![s].ttl = [t \in Tokens |-> IF rm[s].ttl[t]>0 THEN rm[s].ttl[t]-1 ELSE 0]]
    /\ UNCHANGED <<scheduler,jobs,client,resourceEnv,rpc,network>>

\* Scenario 1,4,5. nvflare/app_common/resource_managers/auto_clean_resource_manager.py:105-116; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
\* Internal lock-held scan continuation, not a release/reacquire window. Drain order over tokens overapproximates insertion order; unit conservation is order-independent.
AutoCleanResourceManagerFinishExpiry(s,t) ==
    \* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:105-116; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ rm[s].reserved[t] # <<>>
    \* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:105-116; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ rm[s].ttl[t] = 0
    \* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:105-116; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ rm' = [rm EXCEPT ![s].free = Reverse(rm[s].reserved[t]) \o @, ![s].reserved[t] = <<>>]
    /\ UNCHANGED <<scheduler,jobs,client,resourceEnv,rpc,network>>

\* Scenario 3. nvflare/private/fed/server/job_runner.py:660-669
\* Status read and subsequent DISPATCHED publication are separate.
JobRunnerCheckSubmitted ==
    \* nvflare/private/fed/server/job_runner.py:660-669
    /\ scheduler.pc = "checkSubmitted"
    \* nvflare/private/fed/server/job_runner.py:660-669
    /\ jobs' = [jobs EXCEPT ![CurrentJob].checked = jobs[CurrentJob].status]
    \* nvflare/private/fed/server/job_runner.py:660-669
    /\ scheduler' = [scheduler EXCEPT !.pc = IF jobs[CurrentJob].status = "SUBMITTED" THEN "deploySend" ELSE "idle"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 1-3. nvflare/private/fed/server/job_runner.py:173-248
\* Server deployment succeeds here; DeploymentException models the raised/returned-error path.
JobRunnerDeployJob ==
    \* nvflare/private/fed/server/job_runner.py:173-248
    /\ scheduler.pc = "deploySend"
    \* nvflare/private/fed/server/job_runner.py:173-248
    /\ network' = network \cup {Msg("Deploy",s,CurrentToken) : s \in jobs[CurrentJob].dispatch}
    \* nvflare/private/fed/server/job_runner.py:173-248
    /\ rpc' = [s \in Sites |-> [rpc[s] EXCEPT ![CurrentToken].deploy = IF s \in jobs[CurrentJob].dispatch THEN "waiting" ELSE @]]
    \* nvflare/private/fed/server/job_runner.py:173-248
    /\ scheduler' = [scheduler EXCEPT !.pc = "deployWait"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv>>

\* Scenario 2,5. nvflare/private/fed/server/job_runner.py:194-209; nvflare/private/fed/server/job_runner.py:224-226; nvflare/private/fed/server/job_runner.py:713-728
JobRunnerDeploymentException ==
    \* nvflare/private/fed/server/job_runner.py:194-209; nvflare/private/fed/server/job_runner.py:224-226; nvflare/private/fed/server/job_runner.py:713-728
    /\ scheduler.pc \in {"deploySend","deployWait"}
    \* nvflare/private/fed/server/job_runner.py:194-209; nvflare/private/fed/server/job_runner.py:224-226; nvflare/private/fed/server/job_runner.py:713-728
    /\ scheduler' = [scheduler EXCEPT !.pc = "failRemove"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 2. nvflare/private/fed/client/training_cmds.py:99-140; nvflare/private/fed/client/client_engine.py:462-480; nvflare/private/fed/server/job_runner.py:250-267
\* Boundary abstraction of successful client deployment; no workspace content modeled.
ClientDeploySuccess(s,t) ==
    \* nvflare/private/fed/client/training_cmds.py:99-140; nvflare/private/fed/client/client_engine.py:462-480; nvflare/private/fed/server/job_runner.py:250-267
    /\ Msg("Deploy", s, t) \in network
    \* nvflare/private/fed/client/training_cmds.py:99-140; nvflare/private/fed/client/client_engine.py:462-480; nvflare/private/fed/server/job_runner.py:250-267
    /\ client' = [client EXCEPT ![s][t].deployed = TRUE]
    \* nvflare/private/fed/client/training_cmds.py:99-140; nvflare/private/fed/client/client_engine.py:462-480; nvflare/private/fed/server/job_runner.py:250-267
    /\ network' = (network \ {Msg("Deploy", s, t)}) \cup {Msg("DeployOK", s, t)}
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc>>

\* Scenario 2. nvflare/private/fed/client/training_cmds.py:99-140; nvflare/private/fed/client/client_engine.py:462-480; nvflare/private/fed/server/job_runner.py:250-267
\* Client deployment returns non-OK; already successful sites remain deployed.
ClientDeployError(s,t) ==
    \* nvflare/private/fed/client/training_cmds.py:99-140; nvflare/private/fed/client/client_engine.py:462-480; nvflare/private/fed/server/job_runner.py:250-267
    /\ Msg("Deploy", s, t) \in network
    \* nvflare/private/fed/client/training_cmds.py:99-140; nvflare/private/fed/client/client_engine.py:462-480; nvflare/private/fed/server/job_runner.py:250-267
    /\ network' = (network \ {Msg("Deploy", s, t)}) \cup {Msg("DeployNo", s, t)}
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv,rpc>>

\* Scenario 2,3. nvflare/private/fed/server/job_runner.py:250-285
JobRunnerEvaluateDeployment ==
    \* nvflare/private/fed/server/job_runner.py:250-285
    /\ scheduler.pc = "deployWait"
    \* nvflare/private/fed/server/job_runner.py:250-285
    /\ WaitDone(CurrentToken,"deploy",jobs[CurrentJob].dispatch)
    \* nvflare/private/fed/server/job_runner.py:250-285
    /\ jobs' = [jobs EXCEPT ![CurrentJob].deployed = ReplySites(CurrentToken,"deploy","ok")]
    \* nvflare/private/fed/server/job_runner.py:250-285
    /\ scheduler' = [scheduler EXCEPT !.pc = IF Policy(ReplySites(CurrentToken,"deploy","ok")) THEN "writeDispatched" ELSE "failRemove"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 3. nvflare/private/fed/server/job_runner.py:669-670; nvflare/apis/impl/job_def_manager.py:459-481
JobRunnerWriteDispatched ==
    \* nvflare/private/fed/server/job_runner.py:669-670; nvflare/apis/impl/job_def_manager.py:459-481
    /\ scheduler.pc = "writeDispatched"
    \* nvflare/private/fed/server/job_runner.py:669-670; nvflare/apis/impl/job_def_manager.py:459-481
    /\ jobs' = [jobs EXCEPT ![CurrentJob].status = "DISPATCHED"]
    \* nvflare/private/fed/server/job_runner.py:669-670; nvflare/apis/impl/job_def_manager.py:459-481
    /\ scheduler' = [scheduler EXCEPT !.pc = "persistDeploy"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 3,5. nvflare/private/fed/server/job_runner.py:672-695
JobRunnerPersistDeploy ==
    \* nvflare/private/fed/server/job_runner.py:672-695
    /\ scheduler.pc = "persistDeploy"
    \* nvflare/private/fed/server/job_runner.py:672-695
    /\ scheduler' = [scheduler EXCEPT !.persisted[CurrentJob] = scheduler.count[CurrentJob], !.pc = "checkDispatched"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 3. nvflare/private/fed/server/job_runner.py:697-707
JobRunnerCheckDispatched ==
    \* nvflare/private/fed/server/job_runner.py:697-707
    /\ scheduler.pc = "checkDispatched"
    \* nvflare/private/fed/server/job_runner.py:697-707
    /\ jobs' = [jobs EXCEPT ![CurrentJob].checked = jobs[CurrentJob].status]
    \* nvflare/private/fed/server/job_runner.py:697-707
    /\ scheduler' = [scheduler EXCEPT !.pc = IF jobs[CurrentJob].status = "DISPATCHED" THEN "serverSpawn" ELSE "idle"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 2,3. nvflare/private/fed/server/server_engine.py:179-195; nvflare/private/fed/server/server_engine.py:314-316
\* Default local server spawn; physical exit remains a separate event.
ServerEngineSpawnJob ==
    \* nvflare/private/fed/server/server_engine.py:179-195; nvflare/private/fed/server/server_engine.py:314-316
    /\ scheduler.pc = "serverSpawn"
    \* nvflare/private/fed/server/server_engine.py:179-195; nvflare/private/fed/server/server_engine.py:314-316
    /\ ~jobs[CurrentJob].serverSpawned
    \* nvflare/private/fed/server/server_engine.py:179-195; nvflare/private/fed/server/server_engine.py:314-316
    /\ jobs' = [jobs EXCEPT ![CurrentJob].serverAlive = TRUE, ![CurrentJob].serverSpawned = TRUE]
    \* nvflare/private/fed/server/server_engine.py:179-195; nvflare/private/fed/server/server_engine.py:314-316
    /\ scheduler' = [scheduler EXCEPT !.pc = "serverRegister"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 2-4. nvflare/private/fed/server/server_engine.py:321-326
ServerEngineRegisterJob ==
    \* nvflare/private/fed/server/server_engine.py:321-326
    /\ scheduler.pc = "serverRegister"
    \* nvflare/private/fed/server/server_engine.py:321-326
    /\ jobs' = [jobs EXCEPT ![CurrentJob].serverRegistered = TRUE]
    \* nvflare/private/fed/server/server_engine.py:321-326
    /\ scheduler' = [scheduler EXCEPT !.pc = "serverWaiter"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 2-4. nvflare/private/fed/server/server_engine.py:328-329
\* Server waiter thread creation succeeds in this slice; the targeted installation failure is client-side.
ServerEngineInstallWaiter ==
    \* nvflare/private/fed/server/server_engine.py:328-329
    /\ scheduler.pc = "serverWaiter"
    \* nvflare/private/fed/server/server_engine.py:328-329
    /\ jobs' = [jobs EXCEPT ![CurrentJob].serverWaiter = TRUE]
    \* nvflare/private/fed/server/server_engine.py:328-329
    /\ scheduler' = [scheduler EXCEPT !.pc = "pendingOutcomes"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 1-4. nvflare/private/fed/server/job_runner.py:295-310
JobRunnerSetPendingOutcomes ==
    \* nvflare/private/fed/server/job_runner.py:295-310
    /\ scheduler.pc = "pendingOutcomes"
    \* nvflare/private/fed/server/job_runner.py:295-310
    /\ jobs' = [jobs EXCEPT ![CurrentJob].pending = jobs[CurrentJob].deployed, ![CurrentJob].outcomeKey = TRUE]
    \* nvflare/private/fed/server/job_runner.py:295-310
    /\ scheduler' = [scheduler EXCEPT !.pc = "startSend"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 1,2. nvflare/private/fed/server/server_engine.py:1068-1083
ServerEngineStartClientJob ==
    \* nvflare/private/fed/server/server_engine.py:1068-1083
    /\ scheduler.pc = "startSend"
    \* nvflare/private/fed/server/server_engine.py:1068-1083
    /\ network' = network \cup {Msg("Start",s,CurrentToken) : s \in jobs[CurrentJob].deployed}
    \* nvflare/private/fed/server/server_engine.py:1068-1083
    /\ rpc' = [s \in Sites |-> [rpc[s] EXCEPT ![CurrentToken].start = IF s \in jobs[CurrentJob].deployed THEN "waiting" ELSE @]]
    \* nvflare/private/fed/server/server_engine.py:1068-1083
    /\ scheduler' = [scheduler EXCEPT !.pc = "startWait"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv>>

\* Scenario 1,2. nvflare/private/fed/server/admin.py:101-142; nvflare/private/fed/server/job_runner.py:313-358
\* check_client_replies and strict participant errors raise before filtering the initialized deployed-site list (runner:313-358).
JobRunnerEvaluateStartReplies ==
    \* nvflare/private/fed/server/admin.py:101-142; nvflare/private/fed/server/job_runner.py:313-358
    /\ scheduler.pc = "startWait"
    \* nvflare/private/fed/server/admin.py:101-142; nvflare/private/fed/server/job_runner.py:313-358
    /\ WaitDone(CurrentToken,"start",jobs[CurrentJob].deployed)
    \* nvflare/private/fed/server/admin.py:101-142; nvflare/private/fed/server/job_runner.py:313-358
    /\ jobs' = [jobs EXCEPT ![CurrentJob].active = IF ReplySites(CurrentToken,"start","no") # {} \/ jobs[CurrentJob].deployed = {} \/ (StrictStart /\ ~Policy(ReplySites(CurrentToken,"start","ok"))) THEN jobs[CurrentJob].deployed ELSE ReplySites(CurrentToken,"start","ok")]
    \* nvflare/private/fed/server/admin.py:101-142; nvflare/private/fed/server/job_runner.py:313-358
    /\ scheduler' = [scheduler EXCEPT !.pc = IF ReplySites(CurrentToken,"start","no") # {} \/ jobs[CurrentJob].deployed = {} \/ (StrictStart /\ ~Policy(ReplySites(CurrentToken,"start","ok"))) THEN "failRemove" ELSE "filterOutcomes"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 1,4. nvflare/private/fed/server/job_runner.py:355-364
JobRunnerFilterPendingOutcomes ==
    \* nvflare/private/fed/server/job_runner.py:355-364
    /\ scheduler.pc = "filterOutcomes"
    \* nvflare/private/fed/server/job_runner.py:355-364
    /\ jobs[CurrentJob].outcomeKey
    \* nvflare/private/fed/server/job_runner.py:355-364
    /\ jobs' = [jobs EXCEPT ![CurrentJob].pending = @ \cap jobs[CurrentJob].active]
    \* nvflare/private/fed/server/job_runner.py:355-364
    /\ scheduler' = [scheduler EXCEPT !.pc = "startedEvent"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 1,3,4. nvflare/private/fed/server/job_runner.py:364-372; nvflare/app_common/job_schedulers/job_scheduler.py:275-280; nvflare/apis/utils/event.py:54-84
\* Synchronous production event dispatch, explicit job ID, set-like idempotent membership; ordinary component exceptions do not propagate.
DefaultJobSchedulerJobStarted ==
    \* nvflare/private/fed/server/job_runner.py:364-372; nvflare/app_common/job_schedulers/job_scheduler.py:275-280; nvflare/apis/utils/event.py:54-84
    /\ scheduler.pc = "startedEvent"
    \* nvflare/private/fed/server/job_runner.py:364-372; nvflare/app_common/job_schedulers/job_scheduler.py:275-280; nvflare/apis/utils/event.py:54-84
    /\ scheduler' = [scheduler EXCEPT !.scheduled = @ \cup {CurrentJob}, !.pc = "registerRunning"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 3. nvflare/private/fed/server/job_runner.py:709-710
JobRunnerRegisterRunning ==
    \* nvflare/private/fed/server/job_runner.py:709-710
    /\ scheduler.pc = "registerRunning"
    \* nvflare/private/fed/server/job_runner.py:709-710
    /\ jobs' = [jobs EXCEPT ![CurrentJob].running = TRUE]
    \* nvflare/private/fed/server/job_runner.py:709-710
    /\ scheduler' = [scheduler EXCEPT !.pc = "writeRunning"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 3. nvflare/private/fed/server/job_runner.py:711-712; nvflare/apis/impl/job_def_manager.py:459-481
\* No expected-state guard; terminalPublished is a history observer for this attempt.
JobRunnerWriteRunning ==
    \* nvflare/private/fed/server/job_runner.py:711-712; nvflare/apis/impl/job_def_manager.py:459-481
    /\ scheduler.pc = "writeRunning"
    \* nvflare/private/fed/server/job_runner.py:711-712; nvflare/apis/impl/job_def_manager.py:459-481
    /\ jobs' = [jobs EXCEPT ![CurrentJob].status = "RUNNING", ![CurrentJob].resurrected = @ \/ jobs[CurrentJob].terminalPublished]
    \* nvflare/private/fed/server/job_runner.py:711-712; nvflare/apis/impl/job_def_manager.py:459-481
    /\ scheduler' = [scheduler EXCEPT !.pc = "idle"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 2,3,5. nvflare/private/fed/server/job_runner.py:670-689; nvflare/private/fed/server/job_runner.py:711-713
JobRunnerStartupStoreError ==
    \* nvflare/private/fed/server/job_runner.py:670-689; nvflare/private/fed/server/job_runner.py:711-713
    /\ scheduler.pc \in {"writeDispatched","persistDeploy","writeRunning"}
    \* nvflare/private/fed/server/job_runner.py:670-689; nvflare/private/fed/server/job_runner.py:711-713
    /\ scheduler' = [scheduler EXCEPT !.pc = "failRemove"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 2. nvflare/private/fed/server/server_engine.py:179-193; nvflare/private/fed/server/job_runner.py:304-306
ServerEngineStartupError ==
    \* nvflare/private/fed/server/server_engine.py:179-193; nvflare/private/fed/server/job_runner.py:304-306
    /\ scheduler.pc = "serverSpawn"
    \* nvflare/private/fed/server/server_engine.py:179-193; nvflare/private/fed/server/job_runner.py:304-306
    /\ scheduler' = [scheduler EXCEPT !.pc = "failRemove"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 2,5. nvflare/private/fed/server/job_runner.py:713-719
JobRunnerFailureRemove ==
    \* nvflare/private/fed/server/job_runner.py:713-719
    /\ scheduler.pc = "failRemove"
    \* nvflare/private/fed/server/job_runner.py:713-719
    /\ jobs' = [jobs EXCEPT ![CurrentJob].running = FALSE, ![CurrentJob].pending = {}, ![CurrentJob].outcomeKey = FALSE]
    \* nvflare/private/fed/server/job_runner.py:713-719
    /\ scheduler' = [scheduler EXCEPT !.pc = "failStop"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 2,4,5. nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:719-720
\* Stop is sent only when server run_processes contains the job; it does not reclaim reservations.
JobRunnerFailureStop ==
    \* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:719-720
    /\ scheduler.pc="failStopWait" \/ (scheduler.pc="failStop" /\ ~jobs[CurrentJob].serverRegistered)
    \* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:719-720
    /\ jobs' = [jobs EXCEPT ![CurrentJob].serverStop = @ \/ jobs[CurrentJob].serverRegistered]
    \* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:719-720
    /\ scheduler' = [scheduler EXCEPT !.pc = "failStatus"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 2,5. nvflare/private/fed/server/job_runner.py:720-726
\* Failure-branch store failure is TV-2 first, not injected here.
JobRunnerFailureStatus ==
    \* nvflare/private/fed/server/job_runner.py:720-726
    /\ scheduler.pc = "failStatus"
    \* nvflare/private/fed/server/job_runner.py:720-726
    /\ jobs' = [jobs EXCEPT ![CurrentJob].status = "FAILED_TO_RUN"]
    \* nvflare/private/fed/server/job_runner.py:720-726
    /\ scheduler' = [scheduler EXCEPT !.pc = "failEvent"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 2,4,5. nvflare/private/fed/server/job_runner.py:728-731; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84
DefaultJobSchedulerJobAbortedOnStartFailure ==
    \* nvflare/private/fed/server/job_runner.py:728-731; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84
    /\ scheduler.pc = "failEvent"
    \* nvflare/private/fed/server/job_runner.py:728-731; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84
    /\ scheduler' = [scheduler EXCEPT !.scheduled = @ \ {CurrentJob}, !.pc = "idle"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 1,2,4. nvflare/private/fed/client/scheduler_cmds.py:114-118; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:153-164
StartJobProcessorAllocate(s,t) ==
    \* nvflare/private/fed/client/scheduler_cmds.py:114-118; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:153-164
    /\ ResourceManagerUnlocked(s)
    \* nvflare/private/fed/client/scheduler_cmds.py:114-118; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:153-164
    /\ Msg("Start", s, t) \in network
    \* nvflare/private/fed/client/scheduler_cmds.py:114-118; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:153-164
    /\ rm[s].reserved[t] # <<>>
    \* nvflare/private/fed/client/scheduler_cmds.py:114-118; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:153-164
    /\ rm' = [rm EXCEPT ![s].allocated[t] = rm[s].reserved[t], ![s].payload[t] = rm[s].reserved[t], ![s].reserved[t] = <<>>, ![s].ttl[t] = 0]
    \* nvflare/private/fed/client/scheduler_cmds.py:114-118; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:153-164
    /\ client' = [client EXCEPT ![s][t].pc = "allocated"]
    \* nvflare/private/fed/client/scheduler_cmds.py:114-118; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:153-164
    /\ network' = network \ {Msg("Start", s, t)}
    /\ UNCHANGED <<scheduler,jobs,resourceEnv,rpc>>

\* Scenario 1,4. nvflare/app_common/resource_managers/auto_clean_resource_manager.py:156-163; nvflare/private/fed/client/scheduler_cmds.py:129-137
\* Fixed missing-token rejection; no fallback allocation and no rollback when allocation never succeeded.
StartJobProcessorRejectToken(s,t) ==
    \* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:156-163; nvflare/private/fed/client/scheduler_cmds.py:129-137
    /\ ResourceManagerUnlocked(s)
    \* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:156-163; nvflare/private/fed/client/scheduler_cmds.py:129-137
    /\ Msg("Start", s, t) \in network
    \* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:156-163; nvflare/private/fed/client/scheduler_cmds.py:129-137
    /\ rm[s].reserved[t] = <<>>
    \* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:156-163; nvflare/private/fed/client/scheduler_cmds.py:129-137
    /\ client' = [client EXCEPT ![s][t].pc = "error"]
    \* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:156-163; nvflare/private/fed/client/scheduler_cmds.py:129-137
    /\ network' = (network \ {Msg("Start", s, t)}) \cup {Msg("StartNo", s, t)}
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc>>

\* Scenario 1. nvflare/private/fed/client/scheduler_cmds.py:119-121; nvflare/app_common/resource_consumers/list_resource_consumer.py:31-37; nvflare/app_common/resource_consumers/list_resource_consumer.py:49-52
ListResourceConsumerConsume(s,t) ==
    \* nvflare/private/fed/client/scheduler_cmds.py:119-121; nvflare/app_common/resource_consumers/list_resource_consumer.py:31-37; nvflare/app_common/resource_consumers/list_resource_consumer.py:49-52
    /\ client[s][t].pc = "allocated"
    \* nvflare/private/fed/client/scheduler_cmds.py:119-121; nvflare/app_common/resource_consumers/list_resource_consumer.py:31-37; nvflare/app_common/resource_consumers/list_resource_consumer.py:49-52
    /\ resourceEnv' = [resourceEnv EXCEPT ![s] = rm[s].payload[t]]
    \* nvflare/private/fed/client/scheduler_cmds.py:119-121; nvflare/app_common/resource_consumers/list_resource_consumer.py:31-37; nvflare/app_common/resource_consumers/list_resource_consumer.py:49-52
    /\ client' = [client EXCEPT ![s][t].pc = "consumed"]
    /\ UNCHANGED <<scheduler,jobs,rm,rpc,network>>

\* Scenario 2. nvflare/private/fed/client/client_engine.py:357-379
\* Valid fresh start after acknowledged deployment; early-return alternative is preserved separately.
ClientEngineStartAppCheck(s,t) ==
    \* nvflare/private/fed/client/client_engine.py:357-379
    /\ client[s][t].pc = "consumed"
    \* nvflare/private/fed/client/client_engine.py:357-379
    /\ client[s][t].deployed
    \* nvflare/private/fed/client/client_engine.py:357-379
    /\ ~RegisteredAtSite(s,t[1])
    \* nvflare/private/fed/client/client_engine.py:357-379
    /\ client' = [client EXCEPT ![s][t].pc = "checked"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 2. nvflare/private/fed/client/client_engine.py:365-367; nvflare/private/fed/client/scheduler_cmds.py:122-137
\* CR-1 boundary: cannot be reached by the selected successful-deploy START chain. No arbitrary deletion fault added; returned error does not free allocation.
ClientEngineStartAppReturnedError(s,t) ==
    \* nvflare/private/fed/client/client_engine.py:365-367; nvflare/private/fed/client/scheduler_cmds.py:122-137
    /\ client[s][t].pc = "consumed"
    \* nvflare/private/fed/client/client_engine.py:365-367; nvflare/private/fed/client/scheduler_cmds.py:122-137
    /\ ~client[s][t].deployed
    \* nvflare/private/fed/client/client_engine.py:365-367; nvflare/private/fed/client/scheduler_cmds.py:122-137
    /\ client' = [client EXCEPT ![s][t].pc = "returnedError"]
    \* nvflare/private/fed/client/client_engine.py:365-367; nvflare/private/fed/client/scheduler_cmds.py:122-137
    /\ network' = network \cup {Msg("StartNo", s, t)}
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc>>

\* Scenario 1,2,4. nvflare/private/fed/client/client_executor.py:299-307
JobExecutorRegisterPendingHandle(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:299-307
    /\ client[s][t].pc = "checked"
    \* nvflare/private/fed/client/client_executor.py:299-307
    /\ ~RegisteredAtSite(s,t[1])
    \* nvflare/private/fed/client/client_executor.py:299-307
    /\ client' = [client EXCEPT ![s][t].pc = "registered", ![s][t].handle = "pending", ![s][t].logical = "STARTING"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 2. nvflare/private/fed/client/scheduler_cmds.py:119-133; nvflare/private/fed/client/client_executor.py:224-258
\* Ordinary preparation/metadata I/O exception before spawn; no fabricated invalid input.
JobExecutorPrepareException(s,t) ==
    \* nvflare/private/fed/client/scheduler_cmds.py:119-133; nvflare/private/fed/client/client_executor.py:224-258
    /\ client[s][t].pc \in {"allocated","consumed","checked"}
    \* nvflare/private/fed/client/scheduler_cmds.py:119-133; nvflare/private/fed/client/client_executor.py:224-258
    /\ client' = [client EXCEPT ![s][t].pc = "rollback"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 1. nvflare/app_common/job_launcher/process_launcher.py:66-78
ProcessJobLauncherSnapshotEnvironment(s,t) ==
    \* nvflare/app_common/job_launcher/process_launcher.py:66-78
    /\ client[s][t].pc = "registered"
    \* nvflare/app_common/job_launcher/process_launcher.py:66-78
    /\ client' = [client EXCEPT ![s][t].binding = resourceEnv[s], ![s][t].pc = "snapshotted"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 1,2. nvflare/app_common/job_launcher/process_launcher.py:80-83; nvflare/private/fed/client/client_executor.py:309-311
ProcessJobLauncherSpawn(s,t) ==
    \* nvflare/app_common/job_launcher/process_launcher.py:80-83; nvflare/private/fed/client/client_executor.py:309-311
    /\ client[s][t].pc = "snapshotted"
    \* nvflare/app_common/job_launcher/process_launcher.py:80-83; nvflare/private/fed/client/client_executor.py:309-311
    /\ client' = [client EXCEPT ![s][t].alive = TRUE, ![s][t].spawned = TRUE, ![s][t].pc = "spawned"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 2. nvflare/app_common/job_launcher/process_launcher.py:68-83; nvflare/private/fed/client/client_executor.py:308-316
\* Failure before a returned live handle; post-spawn handle-constructor failure is outside this slice.
ProcessJobLauncherSpawnException(s,t) ==
    \* nvflare/app_common/job_launcher/process_launcher.py:68-83; nvflare/private/fed/client/client_executor.py:308-316
    /\ client[s][t].pc \in {"registered","snapshotted"}
    \* nvflare/app_common/job_launcher/process_launcher.py:68-83; nvflare/private/fed/client/client_executor.py:308-316
    /\ client' = [client EXCEPT ![s][t].pc = "rollback", ![s][t].handle = "none"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 1,2,4. nvflare/private/fed/client/client_executor.py:60-63; nvflare/private/fed/client/client_executor.py:318-320
PendingJobHandleAttach(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:60-63; nvflare/private/fed/client/client_executor.py:318-320
    /\ client[s][t].pc = "spawned"
    \* nvflare/private/fed/client/client_executor.py:60-63; nvflare/private/fed/client/client_executor.py:318-320
    /\ client' = [client EXCEPT ![s][t].pc = IF client[s][t].pendingAbort THEN "attachedAbort" ELSE "attached", ![s][t].handle = "attached", ![s][t].attached = TRUE]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 2,4. nvflare/private/fed/client/client_executor.py:318-320; nvflare/private/fed/client/client_executor.py:505-512
JobExecutorApplyPendingAbort(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:318-320; nvflare/private/fed/client/client_executor.py:505-512
    /\ client[s][t].pc = "attachedAbort"
    \* nvflare/private/fed/client/client_executor.py:318-320; nvflare/private/fed/client/client_executor.py:505-512
    /\ client' = [client EXCEPT ![s][t].terminateRequested = TRUE, ![s][t].pc = "attached"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 2. nvflare/private/fed/client/client_executor.py:324-330; nvflare/apis/utils/event.py:54-84
\* Real event dispatch catches ordinary handler exceptions; no exceptional rollback edge from such handlers.
JobExecutorAfterJobLaunchEvent(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:324-330; nvflare/apis/utils/event.py:54-84
    /\ client[s][t].pc = "attached"
    \* nvflare/private/fed/client/client_executor.py:324-330; nvflare/apis/utils/event.py:54-84
    /\ client' = [client EXCEPT ![s][t].pc = "afterEvent"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 2,4. nvflare/private/fed/client/client_executor.py:330-334
JobExecutorInstallCleanupWaiter(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:330-334
    /\ client[s][t].pc = "afterEvent"
    \* nvflare/private/fed/client/client_executor.py:330-334
    /\ client' = [client EXCEPT ![s][t].pc = "replyReady", ![s][t].waiter = TRUE, ![s][t].cleanup = "wait"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 2. nvflare/private/fed/client/client_executor.py:330-334; nvflare/private/fed/client/scheduler_cmds.py:129-133
\* Ordinary Thread construction/start exception before waiter execution. Live attached handle is retained; no invented double-free thread.
JobExecutorWaiterInstallationException(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:330-334; nvflare/private/fed/client/scheduler_cmds.py:129-133
    /\ client[s][t].pc = "afterEvent"
    \* nvflare/private/fed/client/client_executor.py:330-334; nvflare/private/fed/client/scheduler_cmds.py:129-133
    /\ client' = [client EXCEPT ![s][t].pc = "rollback"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 2. nvflare/private/fed/client/scheduler_cmds.py:129-137; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
\* Rollback calls free(payload) regardless of child liveness or handle ownership. No fictitious token guard on free.
StartJobProcessorRollback(s,t) ==
    \* nvflare/private/fed/client/scheduler_cmds.py:129-137; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ ResourceManagerUnlocked(s)
    \* nvflare/private/fed/client/scheduler_cmds.py:129-137; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ client[s][t].pc = "rollback"
    \* nvflare/private/fed/client/scheduler_cmds.py:129-137; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ rm[s].payload[t] # <<>>
    \* nvflare/private/fed/client/scheduler_cmds.py:129-137; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ rm' = [rm EXCEPT ![s].free = Reverse(rm[s].payload[t]) \o @, ![s].allocated[t] = <<>>, ![s].releases[t] = @+1]
    \* nvflare/private/fed/client/scheduler_cmds.py:129-137; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ client' = [client EXCEPT ![s][t].pc = "error"]
    \* nvflare/private/fed/client/scheduler_cmds.py:129-137; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ network' = network \cup {Msg("StartNo", s, t)}
    /\ UNCHANGED <<scheduler,jobs,resourceEnv,rpc>>

\* Scenario 1,2. nvflare/private/fed/client/client_engine.py:382; nvflare/private/fed/client/scheduler_cmds.py:135-137
StartJobProcessorReplySuccess(s,t) ==
    \* nvflare/private/fed/client/client_engine.py:382; nvflare/private/fed/client/scheduler_cmds.py:135-137
    /\ client[s][t].pc = "replyReady"
    \* nvflare/private/fed/client/client_engine.py:382; nvflare/private/fed/client/scheduler_cmds.py:135-137
    /\ client' = [client EXCEPT ![s][t].pc = "returned"]
    \* nvflare/private/fed/client/client_engine.py:382; nvflare/private/fed/client/scheduler_cmds.py:135-137
    /\ network' = network \cup {Msg("StartOK", s, t)}
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc>>

\* Scenario 4. nvflare/private/fed/client/client_executor.py:347-350
JobExecutorNotifyStarted(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:347-350
    /\ client[s][t].alive
    \* nvflare/private/fed/client/client_executor.py:347-350
    /\ client[s][t].handle # "none"
    \* nvflare/private/fed/client/client_executor.py:347-350
    /\ client[s][t].logical = "STARTING"
    \* nvflare/private/fed/client/client_executor.py:347-350
    /\ client' = [client EXCEPT ![s][t].logical = "STARTED"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 4. nvflare/private/fed/client/client_executor.py:347-350; nvflare/private/fed/client/client_engine.py:390-404
JobExecutorNotifyStopped(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:347-350; nvflare/private/fed/client/client_engine.py:390-404
    /\ client[s][t].alive
    \* nvflare/private/fed/client/client_executor.py:347-350; nvflare/private/fed/client/client_engine.py:390-404
    /\ client[s][t].handle # "none"
    \* nvflare/private/fed/client/client_executor.py:347-350; nvflare/private/fed/client/client_engine.py:390-404
    /\ client[s][t].logical = "STARTED"
    \* nvflare/private/fed/client/client_executor.py:347-350; nvflare/private/fed/client/client_engine.py:390-404
    /\ client' = [client EXCEPT ![s][t].logical = "STOPPED"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 2,4. nvflare/app_common/job_launcher/process_launcher.py:51-58; nvflare/private/fed/client/client_executor.py:625-630
\* Ordinary completion or response to a stop; no guaranteed success under a permanently non-terminating process.
ClientChildExit(s,t) ==
    \* nvflare/app_common/job_launcher/process_launcher.py:51-58; nvflare/private/fed/client/client_executor.py:625-630
    /\ client[s][t].alive
    \* nvflare/app_common/job_launcher/process_launcher.py:51-58; nvflare/private/fed/client/client_executor.py:625-630
    /\ client' = [client EXCEPT ![s][t].alive = FALSE]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 2,4. nvflare/private/fed/client/client_executor.py:630-647
\* Abstract reportable ordinary process failure; generic teardown RC classifications are not expanded.
ClientChildFailure(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:630-647
    /\ client[s][t].alive
    \* nvflare/private/fed/client/client_executor.py:630-647
    /\ client' = [client EXCEPT ![s][t].alive = FALSE, ![s][t].exitCode = "failed"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 2,4. nvflare/private/fed/client/client_executor.py:625-647
JobExecutorWaitChildExit(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:625-647
    /\ client[s][t].cleanup = "wait"
    \* nvflare/private/fed/client/client_executor.py:625-647
    /\ ~client[s][t].alive
    \* nvflare/private/fed/client/client_executor.py:625-647
    /\ client[s][t].spawned
    \* nvflare/private/fed/client/client_executor.py:625-647
    /\ client[s][t].attached
    \* nvflare/private/fed/client/client_executor.py:625-647
    /\ client' = [client EXCEPT ![s][t].exitObserved = TRUE, ![s][t].cleanup = "report"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 4. nvflare/private/fed/client/client_executor.py:648-664
JobExecutorReportOutcome(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:648-664
    /\ client[s][t].cleanup = "report"
    \* nvflare/private/fed/client/client_executor.py:648-664
    /\ network' = network \cup {Msg(IF client[s][t].exitCode = "ok" THEN "OutcomeOK" ELSE "OutcomeFailed",s,t)}
    \* nvflare/private/fed/client/client_executor.py:648-664
    /\ client' = [client EXCEPT ![s][t].cleanup = "reportWait"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc>>

\* Scenario 4. nvflare/private/fed/client/client_executor.py:665-679
\* Reply success or already consumed/lost request followed by return; ReportTimeout covers still-in-flight requests.
JobExecutorOutcomeReportReturned(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:665-679
    /\ client[s][t].cleanup = "reportWait"
    \* nvflare/private/fed/client/client_executor.py:665-679
    /\ Msg("OutcomeOK",s,t) \notin network
    \* nvflare/private/fed/client/client_executor.py:665-679
    /\ Msg("OutcomeFailed",s,t) \notin network
    \* nvflare/private/fed/client/client_executor.py:665-679
    /\ client' = [client EXCEPT ![s][t].cleanup = "free"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 4. nvflare/private/fed/client/client_executor.py:648-678
\* Report exception/timeout is caught; it never bypasses normal resource release.
JobExecutorOutcomeReportException(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:648-678
    /\ client[s][t].cleanup \in {"report","reportWait"}
    \* nvflare/private/fed/client/client_executor.py:648-678
    /\ client' = [client EXCEPT ![s][t].cleanup = "free"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 2,4. nvflare/private/fed/client/client_executor.py:676-679; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
\* Uses retained payload; deliberately no allocated/token test that would conceal repeated free.
JobExecutorFreeAfterExit(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:676-679; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ ResourceManagerUnlocked(s)
    \* nvflare/private/fed/client/client_executor.py:676-679; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ client[s][t].cleanup = "free"
    \* nvflare/private/fed/client/client_executor.py:676-679; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ rm' = [rm EXCEPT ![s].free = Reverse(rm[s].payload[t]) \o @, ![s].allocated[t] = <<>>, ![s].releases[t] = @+1]
    \* nvflare/private/fed/client/client_executor.py:676-679; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55
    /\ client' = [client EXCEPT ![s][t].cleanup = "pop"]
    /\ UNCHANGED <<scheduler,jobs,resourceEnv,rpc,network>>

\* Scenario 4. nvflare/private/fed/client/client_executor.py:680-682
JobExecutorRemoveProcess(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:680-682
    /\ client[s][t].cleanup = "pop"
    \* nvflare/private/fed/client/client_executor.py:680-682
    /\ client' = [client EXCEPT ![s][t].handle = "none", ![s][t].cleanup = "event"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 4. nvflare/private/fed/client/client_executor.py:684-688; nvflare/apis/utils/event.py:54-84
\* Site-local completion event does not call the server scheduler. Explicit job identity is preserved.
JobExecutorJobCompletedEvent(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:684-688; nvflare/apis/utils/event.py:54-84
    /\ client[s][t].cleanup = "event"
    \* nvflare/private/fed/client/client_executor.py:684-688; nvflare/apis/utils/event.py:54-84
    /\ client' = [client EXCEPT ![s][t].cleanup = "done"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 4. nvflare/private/fed/client/client_engine.py:390-404; nvflare/private/fed/client/client_executor.py:497-534; nvflare/private/fed/client/client_executor.py:65-77
\* At executor abort ownership update under lock, or ClientEngine no-op early return; termination and wait completion are separate.
ClientEngineAbortApp(s,t) ==
    \* nvflare/private/fed/client/client_engine.py:390-404; nvflare/private/fed/client/client_executor.py:497-534; nvflare/private/fed/client/client_executor.py:65-77
    /\ Msg("Stop", s, t) \in network
    \* nvflare/private/fed/client/client_engine.py:390-404; nvflare/private/fed/client/client_executor.py:497-534; nvflare/private/fed/client/client_executor.py:65-77
    /\ network' = network \ {Msg("Stop", s, t)}
    \* nvflare/private/fed/client/client_engine.py:390-404; nvflare/private/fed/client/client_executor.py:497-534; nvflare/private/fed/client/client_executor.py:65-77
    /\ client' = [client EXCEPT ![s][t].abortRequested = @ \/ client[s][t].handle # "none"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc>>

\* Scenario 4. nvflare/private/fed/client/client_engine.py:390-404; nvflare/private/fed/client/client_executor.py:497-534; nvflare/private/fed/client/client_executor.py:65-77
\* At executor abort ownership update under lock, or ClientEngine no-op early return; termination and wait completion are separate.
ClientEngineHeartbeatAbort(s,t) ==
    \* nvflare/private/fed/client/client_engine.py:390-404; nvflare/private/fed/client/client_executor.py:497-534; nvflare/private/fed/client/client_executor.py:65-77
    /\ Msg("HeartbeatStop", s, t) \in network
    \* nvflare/private/fed/client/client_engine.py:390-404; nvflare/private/fed/client/client_executor.py:497-534; nvflare/private/fed/client/client_executor.py:65-77
    /\ network' = network \ {Msg("HeartbeatStop", s, t)}
    \* nvflare/private/fed/client/client_engine.py:390-404; nvflare/private/fed/client/client_executor.py:497-534; nvflare/private/fed/client/client_executor.py:65-77
    /\ client' = [client EXCEPT ![s][t].abortRequested = @ \/ client[s][t].handle # "none"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc>>

\* Scenario 4. nvflare/private/fed/client/client_executor.py:581-601
\* 10s bounded graceful wait before terminate; physical process exit remains separate.
JobExecutorTerminateAfterGrace(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:581-601
    /\ client[s][t].abortRequested
    \* nvflare/private/fed/client/client_executor.py:581-601
    /\ client[s][t].handle = "attached"
    \* nvflare/private/fed/client/client_executor.py:581-601
    /\ ~client[s][t].terminateRequested
    \* nvflare/private/fed/client/client_executor.py:581-601
    /\ client' = [client EXCEPT ![s][t].terminateRequested = TRUE]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

\* Scenario 2,4. nvflare/private/fed/server/fed_server.py:1004-1017; nvflare/private/fed/client/communicator.py:621-646
\* Outcome-map key protects normally completing jobs even when pending set is empty. Repeated heartbeat requests never free resources.
FederatedServerHeartbeatCleanup(s,t) ==
    \* nvflare/private/fed/server/fed_server.py:1004-1017; nvflare/private/fed/client/communicator.py:621-646
    /\ client[s][t].handle # "none"
    \* nvflare/private/fed/server/fed_server.py:1004-1017; nvflare/private/fed/client/communicator.py:621-646
    /\ ~jobs[t[1]].serverRegistered
    \* nvflare/private/fed/server/fed_server.py:1004-1017; nvflare/private/fed/client/communicator.py:621-646
    /\ ~jobs[t[1]].outcomeKey \/ jobs[t[1]].serverFailed
    \* nvflare/private/fed/server/fed_server.py:1004-1017; nvflare/private/fed/client/communicator.py:621-646
    /\ Msg("HeartbeatStop", s, t) \notin network
    \* nvflare/private/fed/server/fed_server.py:1004-1017; nvflare/private/fed/client/communicator.py:621-646
    /\ network' = network \cup {Msg("HeartbeatStop", s, t)}
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv,rpc>>

\* Scenario 4. nvflare/private/fed/server/job_runner.py:114-120
\* Idempotent discard for exact job/site. Receiver authentication and reporter classification are boundary assumptions.
ServerEngineReceiveOutcome(s,t) ==
    \* nvflare/private/fed/server/job_runner.py:114-120
    /\ Msg("OutcomeOK", s, t) \in network
    \* nvflare/private/fed/server/job_runner.py:114-120
    /\ network' = network \ {Msg("OutcomeOK", s, t)}
    \* nvflare/private/fed/server/job_runner.py:114-120
    /\ jobs' = [jobs EXCEPT ![t[1]].pending = @ \ {s}]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc>>

\* Scenario 4. nvflare/private/fed/server/job_runner.py:114-120; nvflare/private/fed/server/job_runner.py:813-843
\* Authoritative failure bypasses the outcome barrier. Late failure after final removal does not resurrect a job.
ServerEngineReceiveFailureOutcome(s,t) ==
    \* nvflare/private/fed/server/job_runner.py:114-120; nvflare/private/fed/server/job_runner.py:813-843
    /\ Msg("OutcomeFailed", s, t) \in network
    \* nvflare/private/fed/server/job_runner.py:114-120; nvflare/private/fed/server/job_runner.py:813-843
    /\ network' = (network \ {Msg("OutcomeFailed",s,t)}) \cup (IF jobs[t[1]].serverRegistered THEN {Msg("Stop",v,t) : v \in jobs[t[1]].deployed} ELSE {})
    \* nvflare/private/fed/server/job_runner.py:114-120; nvflare/private/fed/server/job_runner.py:813-843
    /\ jobs' = [jobs EXCEPT ![t[1]].pending = IF jobs[t[1]].serverRegistered \/ jobs[t[1]].running THEN {} ELSE @ \ {s}, ![t[1]].outcomeKey = IF jobs[t[1]].serverRegistered \/ jobs[t[1]].running THEN FALSE ELSE @, ![t[1]].serverFailed = @ \/ jobs[t[1]].serverRegistered \/ jobs[t[1]].running, ![t[1]].serverStop = @ \/ jobs[t[1]].serverRegistered]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc>>

\* Scenario 3,4. nvflare/private/fed/server/server_engine.py:203-204
ServerChildExit(j) ==
    \* nvflare/private/fed/server/server_engine.py:203-204
    /\ jobs[j].serverAlive
    \* nvflare/private/fed/server/server_engine.py:203-204
    /\ jobs' = [jobs EXCEPT ![j].serverAlive = FALSE]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 4. nvflare/private/fed/server/server_engine.py:219-233
ServerChildFailure(j) ==
    \* nvflare/private/fed/server/server_engine.py:219-233
    /\ jobs[j].serverAlive
    \* nvflare/private/fed/server/server_engine.py:219-233
    /\ jobs' = [jobs EXCEPT ![j].serverAlive = FALSE, ![j].serverFailed = TRUE]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 3,4. nvflare/private/fed/server/server_engine.py:203-234
\* Includes finite <=2s UPDATE_RUN_STATUS grace; process already exited.
ServerEngineObserveExit(j) ==
    \* nvflare/private/fed/server/server_engine.py:203-234
    /\ jobs[j].serverWaiter
    \* nvflare/private/fed/server/server_engine.py:203-234
    /\ jobs[j].serverRegistered
    \* nvflare/private/fed/server/server_engine.py:203-234
    /\ ~jobs[j].serverAlive
    \* nvflare/private/fed/server/server_engine.py:203-234
    /\ jobs' = [jobs EXCEPT ![j].serverRegistered = FALSE]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 4. nvflare/private/fed/server/server_engine.py:385-407
\* Captured local handle termination after grace; does not assert OS exit.
ServerEngineTerminateAfterGrace(j) ==
    \* nvflare/private/fed/server/server_engine.py:385-407
    /\ jobs[j].serverStop
    \* nvflare/private/fed/server/server_engine.py:385-407
    /\ jobs[j].serverSpawned
    \* nvflare/private/fed/server/server_engine.py:385-407
    /\ ~jobs[j].serverTerminated
    \* nvflare/private/fed/server/server_engine.py:385-407
    /\ jobs' = [jobs EXCEPT ![j].serverTerminated = TRUE]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 4. nvflare/private/fed/server/server_engine.py:408-409
\* CR-2 boundary retained. No injected permanently ineffective SIGKILL or process-count invariant.
ServerEngineRemoveAfterTerminate(j) ==
    \* nvflare/private/fed/server/server_engine.py:408-409
    /\ jobs[j].serverTerminated
    \* nvflare/private/fed/server/server_engine.py:408-409
    /\ jobs[j].serverRegistered
    \* nvflare/private/fed/server/server_engine.py:408-409
    /\ jobs' = [jobs EXCEPT ![j].serverRegistered = FALSE]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 3,4. nvflare/private/fed/server/job_cmds.py:1055-1061
JobCommandAbortRead(j) ==
    \* nvflare/private/fed/server/job_cmds.py:1055-1061
    /\ jobs[j].adminPC = "idle"
    \* nvflare/private/fed/server/job_cmds.py:1055-1061
    /\ jobs' = [jobs EXCEPT ![j].adminRead = jobs[j].status, ![j].adminPC = "read"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 3. nvflare/private/fed/server/job_cmds.py:1061-1063; nvflare/apis/impl/job_def_manager.py:459-481
JobCommandAbortPreRunWrite(j) ==
    \* nvflare/private/fed/server/job_cmds.py:1061-1063; nvflare/apis/impl/job_def_manager.py:459-481
    /\ jobs[j].adminPC = "read"
    \* nvflare/private/fed/server/job_cmds.py:1061-1063; nvflare/apis/impl/job_def_manager.py:459-481
    /\ jobs[j].adminRead \in {"SUBMITTED","DISPATCHED"}
    \* nvflare/private/fed/server/job_cmds.py:1061-1063; nvflare/apis/impl/job_def_manager.py:459-481
    /\ jobs' = [jobs EXCEPT ![j].status = "ABORTED", ![j].adminPC = "ackPreRun"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 3. nvflare/private/fed/server/job_cmds.py:1063-1066
\* Acknowledges the saved branch, without rereading status or sending process stop.
JobCommandAbortPreRunAcknowledge(j) ==
    \* nvflare/private/fed/server/job_cmds.py:1063-1066
    /\ jobs[j].adminPC = "ackPreRun"
    \* nvflare/private/fed/server/job_cmds.py:1063-1066
    /\ jobs' = [jobs EXCEPT ![j].abortAck = TRUE, ![j].adminPC = "idle"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 4. nvflare/private/fed/server/job_cmds.py:1067-1070
JobCommandAbortAlreadyTerminal(j) ==
    \* nvflare/private/fed/server/job_cmds.py:1067-1070
    /\ jobs[j].adminPC = "read"
    \* nvflare/private/fed/server/job_cmds.py:1067-1070
    /\ jobs[j].adminRead \in Terminal
    \* nvflare/private/fed/server/job_cmds.py:1067-1070
    /\ jobs' = [jobs EXCEPT ![j].adminPC = "idle"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 4. nvflare/private/fed/server/job_cmds.py:1071-1078; nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:798-800
JobCommandAbortRunning(j) ==
    \* nvflare/private/fed/server/job_cmds.py:1071-1078; nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:798-800
    /\ jobs[j].adminPC="stopWait" \/ (jobs[j].adminPC="read" /\ jobs[j].adminRead="RUNNING" /\ ~jobs[j].serverRegistered)
    \* nvflare/private/fed/server/job_cmds.py:1071-1078; nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:798-800
    /\ jobs' = [jobs EXCEPT ![j].serverStop = @ \/ jobs[j].serverRegistered, ![j].adminPC = "markAborted"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 4. nvflare/private/fed/server/job_runner.py:802-811
\* Only an existing running_jobs entry receives run_aborted; missing entry returns an error.
JobRunnerMarkAborted(j) ==
    \* nvflare/private/fed/server/job_runner.py:802-811
    /\ jobs[j].adminPC = "markAborted"
    \* nvflare/private/fed/server/job_runner.py:802-811
    /\ jobs' = [jobs EXCEPT ![j].runAborted = @ \/ jobs[j].running, ![j].adminPC = "idle"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 3,4. nvflare/private/fed/server/job_runner.py:443-476
JobRunnerSelectCompletion(j) ==
    \* nvflare/private/fed/server/job_runner.py:443-476
    /\ jobs[j].running
    \* nvflare/private/fed/server/job_runner.py:443-476
    /\ ~jobs[j].serverRegistered
    \* nvflare/private/fed/server/job_runner.py:443-476
    /\ jobs[j].completion = "idle"
    \* nvflare/private/fed/server/job_runner.py:443-476
    /\ jobs' = [jobs EXCEPT ![j].completion = IF jobs[j].pending # {} /\ ~jobs[j].runAborted /\ ~jobs[j].serverFailed THEN "outcomeWait" ELSE "classify", ![j].pending = IF jobs[j].serverFailed THEN {} ELSE @, ![j].outcomeKey = IF jobs[j].serverFailed THEN FALSE ELSE @]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 3,4. nvflare/private/fed/server/job_runner.py:451-476
JobRunnerOutcomesResolved(j) ==
    \* nvflare/private/fed/server/job_runner.py:451-476
    /\ jobs[j].completion = "outcomeWait"
    \* nvflare/private/fed/server/job_runner.py:451-476
    /\ jobs[j].pending = {} \/ jobs[j].runAborted \/ jobs[j].serverFailed
    \* nvflare/private/fed/server/job_runner.py:451-476
    /\ jobs' = [jobs EXCEPT ![j].completion = "classify"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 3,4. nvflare/private/fed/server/job_runner.py:466-480
\* Crossing the real OutcomeGrace (900s) deadline. No inference that clients have exited.
JobRunnerOutcomeGraceExpired(j) ==
    \* nvflare/private/fed/server/job_runner.py:466-480
    /\ jobs[j].completion = "outcomeWait"
    \* nvflare/private/fed/server/job_runner.py:466-480
    /\ jobs[j].pending # {}
    \* nvflare/private/fed/server/job_runner.py:466-480
    /\ jobs' = [jobs EXCEPT ![j].pending = {}, ![j].completion = "classify"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 3,4. nvflare/private/fed/server/job_runner.py:482-496; nvflare/private/fed/server/job_runner.py:574-585
\* Completion retains a saved reference/status; failure requests client stop independently.
JobRunnerClassifyCompletion(j) ==
    \* nvflare/private/fed/server/job_runner.py:482-496; nvflare/private/fed/server/job_runner.py:574-585
    /\ jobs[j].completion = "classify"
    \* nvflare/private/fed/server/job_runner.py:482-496; nvflare/private/fed/server/job_runner.py:574-585
    /\ jobs' = [jobs EXCEPT ![j].finishStatus = IF jobs[j].runAborted THEN "ABORTED" ELSE IF jobs[j].serverFailed THEN "FAILED" ELSE "COMPLETED", ![j].completion = "archive"]
    \* nvflare/private/fed/server/job_runner.py:482-496; nvflare/private/fed/server/job_runner.py:574-585
    /\ network' = network \cup (IF jobs[j].serverFailed THEN {Msg("Stop",s,<<j,scheduler.issued[j]>>) : s \in jobs[j].deployed} ELSE {})
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc>>

\* Scenario 3,4. nvflare/private/fed/server/job_runner.py:494-522
JobRunnerArchiveSuccess(j) ==
    \* nvflare/private/fed/server/job_runner.py:494-522
    /\ jobs[j].completion = "archive"
    \* nvflare/private/fed/server/job_runner.py:494-522
    /\ jobs' = [jobs EXCEPT ![j].completion = "publish"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 3,4. nvflare/private/fed/server/job_runner.py:495-507
\* Retry yields to other jobs; contents omitted, error grace retained.
JobRunnerArchiveException(j) ==
    \* nvflare/private/fed/server/job_runner.py:495-507
    /\ jobs[j].completion = "archive"
    \* nvflare/private/fed/server/job_runner.py:495-507
    /\ jobs' = [jobs EXCEPT ![j].archiveFailed = TRUE, ![j].completion = "archiveRetry"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 4,5. nvflare/private/fed/server/job_runner.py:443-444; nvflare/private/fed/server/job_runner.py:501-507; nvflare/private/fed/server/job_runner.py:541
JobRunnerRetryArchive(j) ==
    \* nvflare/private/fed/server/job_runner.py:443-444; nvflare/private/fed/server/job_runner.py:501-507; nvflare/private/fed/server/job_runner.py:541
    /\ jobs[j].completion = "archiveRetry"
    \* nvflare/private/fed/server/job_runner.py:443-444; nvflare/private/fed/server/job_runner.py:501-507; nvflare/private/fed/server/job_runner.py:541
    /\ jobs' = [jobs EXCEPT ![j].completion = "archive"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 4,5. nvflare/private/fed/server/job_runner.py:498-522
\* An archive call fails at/after the 60s grace. Reactive completion of prior error, not a newly injected independent fault.
JobRunnerArchiveGraceExpired(j) ==
    \* nvflare/private/fed/server/job_runner.py:498-522
    /\ jobs[j].archiveFailed
    \* nvflare/private/fed/server/job_runner.py:498-522
    /\ jobs[j].completion \in {"archive","archiveRetry"}
    \* nvflare/private/fed/server/job_runner.py:498-522
    /\ jobs' = [jobs EXCEPT ![j].completion = "publish"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 3. nvflare/private/fed/server/job_runner.py:523-530; nvflare/apis/impl/job_def_manager.py:459-481
JobRunnerPublishTerminal(j) ==
    \* nvflare/private/fed/server/job_runner.py:523-530; nvflare/apis/impl/job_def_manager.py:459-481
    /\ jobs[j].completion = "publish"
    \* nvflare/private/fed/server/job_runner.py:523-530; nvflare/apis/impl/job_def_manager.py:459-481
    /\ jobs' = [jobs EXCEPT ![j].status = jobs[j].finishStatus, ![j].terminalPublished = TRUE, ![j].completion = "remove"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 4,5. nvflare/private/fed/server/job_runner.py:523-530
\* Caught store error retries; finite injected errors do not kill completion service.
JobRunnerTerminalStoreException(j) ==
    \* nvflare/private/fed/server/job_runner.py:523-530
    /\ jobs[j].completion = "publish"
    \* nvflare/private/fed/server/job_runner.py:523-530
    /\ jobs' = jobs
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 3,4. nvflare/private/fed/server/job_runner.py:531-538
\* TV-3 missing-key race is not silently repaired: if running was removed by failure path this action is disabled; see PendingCompletionRemoval structural diagnostic, not a service-death model.
JobRunnerRemoveCompleted(j) ==
    \* nvflare/private/fed/server/job_runner.py:531-538
    /\ jobs[j].completion = "remove"
    \* nvflare/private/fed/server/job_runner.py:531-538
    /\ jobs[j].running
    \* nvflare/private/fed/server/job_runner.py:531-538
    /\ jobs' = [jobs EXCEPT ![j].running = FALSE, ![j].pending = {}, ![j].outcomeKey = FALSE, ![j].completedRemoved = TRUE, ![j].completion = IF jobs[j].finishStatus = "ABORTED" THEN "abortedEvent" ELSE "completedEvent"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc,network>>

\* Scenario 4. nvflare/private/fed/server/job_runner.py:536-537; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84
\* ABORTED then COMPLETED are two supported notifications for the same job.
DefaultJobSchedulerJobAbortedOnCompletion(j) ==
    \* nvflare/private/fed/server/job_runner.py:536-537; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84
    /\ jobs[j].completion = "abortedEvent"
    \* nvflare/private/fed/server/job_runner.py:536-537; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84
    /\ jobs' = [jobs EXCEPT ![j].completion = "completedEvent"]
    \* nvflare/private/fed/server/job_runner.py:536-537; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84
    /\ scheduler' = [scheduler EXCEPT !.scheduled = @ \ {j}]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 3,4. nvflare/private/fed/server/job_runner.py:538; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84
DefaultJobSchedulerJobCompleted(j) ==
    \* nvflare/private/fed/server/job_runner.py:538; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84
    /\ jobs[j].completion = "completedEvent"
    \* nvflare/private/fed/server/job_runner.py:538; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84
    /\ jobs' = [jobs EXCEPT ![j].completion = "done"]
    \* nvflare/private/fed/server/job_runner.py:538; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84
    /\ scheduler' = [scheduler EXCEPT !.scheduled = @ \ {j}]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 1,4,5. nvflare/private/fed/server/admin.py:307-339; nvflare/private/fed/server/server_engine.py:1007-1008; nvflare/private/fed/client/client_executor.py:657-674
\* Ordinary request/reply loss, no forgery. Tokens and late messages are never reassociated.
TransportLoseMessage(m) ==
    \* nvflare/private/fed/server/admin.py:307-339; nvflare/private/fed/server/server_engine.py:1007-1008; nvflare/private/fed/client/client_executor.py:657-674
    /\ m \in network
    \* nvflare/private/fed/server/admin.py:307-339; nvflare/private/fed/server/server_engine.py:1007-1008; nvflare/private/fed/client/client_executor.py:657-674
    /\ network' = network \ {m}
    /\ UNCHANGED <<scheduler,jobs,rm,client,resourceEnv,rpc>>

\* Scenario 5. nvflare/app_common/job_schedulers/job_scheduler.py:298-304
\* Deferred end-of-pass failed-job metadata write; successful store boundary.
DefaultJobSchedulerPersistFailed(j) ==
    \* nvflare/app_common/job_schedulers/job_scheduler.py:298-304
    /\ scheduler.pc="persistFailed"
    \* nvflare/app_common/job_schedulers/job_scheduler.py:298-304
    /\ j \in scheduler.failedPending
    \* nvflare/app_common/job_schedulers/job_scheduler.py:298-304
    /\ scheduler' = [scheduler EXCEPT !.persisted[j] = scheduler.count[j], !.failedPending = @ \ {j}]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 5. nvflare/app_common/job_schedulers/job_scheduler.py:305-310
\* Deferred blocked-job metadata/status processing; successful store boundary.
DefaultJobSchedulerPersistBlocked(j) ==
    \* nvflare/app_common/job_schedulers/job_scheduler.py:305-310
    /\ scheduler.pc="persistFailed"
    \* nvflare/app_common/job_schedulers/job_scheduler.py:305-310
    /\ scheduler.failedPending={}
    \* nvflare/app_common/job_schedulers/job_scheduler.py:305-310
    /\ j \in scheduler.blockedPending
    \* nvflare/app_common/job_schedulers/job_scheduler.py:305-310
    /\ scheduler' = [scheduler EXCEPT !.persisted[j] = scheduler.count[j], !.blockedPending = @ \ {j}]
    \* nvflare/app_common/job_schedulers/job_scheduler.py:305-310
    /\ jobs' = [jobs EXCEPT ![j].status = "CANT_SCHEDULE"]
    /\ UNCHANGED <<rm,client,resourceEnv,rpc,network>>

\* Scenario 5. nvflare/app_common/job_schedulers/job_scheduler.py:311
DefaultJobSchedulerReturnPass ==
    \* nvflare/app_common/job_schedulers/job_scheduler.py:311
    /\ scheduler.pc="persistFailed"
    \* nvflare/app_common/job_schedulers/job_scheduler.py:311
    /\ scheduler.failedPending={}
    \* nvflare/app_common/job_schedulers/job_scheduler.py:311
    /\ scheduler.blockedPending={}
    \* nvflare/app_common/job_schedulers/job_scheduler.py:311
    /\ scheduler' = [scheduler EXCEPT !.pc = scheduler.returnTo]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 2,4. nvflare/private/fed/server/job_runner.py:359-360; nvflare/private/fed/server/job_runner.py:713-719
\* Reactive KeyError path if authoritative failure removed the map during startup. Do not counter-bound an existing-state response.
JobRunnerMissingPendingOutcomes ==
    \* nvflare/private/fed/server/job_runner.py:359-360; nvflare/private/fed/server/job_runner.py:713-719
    /\ scheduler.pc="filterOutcomes"
    \* nvflare/private/fed/server/job_runner.py:359-360; nvflare/private/fed/server/job_runner.py:713-719
    /\ ~jobs[CurrentJob].outcomeKey
    \* nvflare/private/fed/server/job_runner.py:359-360; nvflare/private/fed/server/job_runner.py:713-719
    /\ scheduler' = [scheduler EXCEPT !.pc = "failRemove"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc,network>>

\* Scenario 3,4. nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_cmds.py:1071-1078
\* Actual client stop send; blocking return and server abort are later.
JobCommandAbortRunningSend(j) ==
    \* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_cmds.py:1071-1078
    /\ jobs[j].adminPC="read"
    \* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_cmds.py:1071-1078
    /\ jobs[j].adminRead="RUNNING"
    \* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_cmds.py:1071-1078
    /\ jobs[j].serverRegistered
    \* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_cmds.py:1071-1078
    /\ network' = network \cup {Msg("Stop",s,<<j,scheduler.issued[j]>>) : s \in jobs[j].deployed}
    \* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_cmds.py:1071-1078
    /\ jobs' = [jobs EXCEPT ![j].adminPC = "stopWait"]
    /\ UNCHANGED <<scheduler,rm,client,resourceEnv,rpc>>

\* Scenario 2,4,5. nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:719-720
\* Failure cleanup sends client stops before blocking return.
JobRunnerFailureSendStop ==
    \* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:719-720
    /\ scheduler.pc="failStop"
    \* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:719-720
    /\ jobs[CurrentJob].serverRegistered
    \* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:719-720
    /\ network' = network \cup {Msg("Stop",s,CurrentToken) : s \in jobs[CurrentJob].deployed}
    \* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:719-720
    /\ scheduler' = [scheduler EXCEPT !.pc = "failStopWait"]
    /\ UNCHANGED <<jobs,rm,client,resourceEnv,rpc>>

\* Scenario 4. nvflare/private/fed/client/client_executor.py:497-512; nvflare/private/fed/client/client_executor.py:65-77
\* STARTING branch invokes pending/attached handle termination after ownership flag update.
JobExecutorAbortStarting(s,t) ==
    \* nvflare/private/fed/client/client_executor.py:497-512; nvflare/private/fed/client/client_executor.py:65-77
    /\ client[s][t].abortRequested
    \* nvflare/private/fed/client/client_executor.py:497-512; nvflare/private/fed/client/client_executor.py:65-77
    /\ client[s][t].logical="STARTING"
    \* nvflare/private/fed/client/client_executor.py:497-512; nvflare/private/fed/client/client_executor.py:65-77
    /\ client[s][t].handle # "none"
    \* nvflare/private/fed/client/client_executor.py:497-512; nvflare/private/fed/client/client_executor.py:65-77
    /\ ~client[s][t].terminateRequested
    \* nvflare/private/fed/client/client_executor.py:497-512; nvflare/private/fed/client/client_executor.py:65-77
    /\ ~client[s][t].pendingAbort
    \* nvflare/private/fed/client/client_executor.py:497-512; nvflare/private/fed/client/client_executor.py:65-77
    /\ client' = [client EXCEPT ![s][t].pendingAbort = client[s][t].handle="pending", ![s][t].terminateRequested = client[s][t].handle="attached"]
    /\ UNCHANGED <<scheduler,jobs,rm,resourceEnv,rpc,network>>

Next ==
    \/ DefaultJobSchedulerBeginPass
    \/ DefaultJobSchedulerEndPass
    \/ DefaultJobSchedulerSkipBackoff
    \/ \E j \in Jobs : DefaultJobSchedulerBackoffElapsed(j)
    \/ DefaultJobSchedulerExhausted
    \/ DefaultJobSchedulerTryJob
    \/ ServerEngineCheckClientResources
    \/ \E s \in Sites, t \in Tokens : CheckResourceProcessorReserve(s,t)
    \/ \E s \in Sites, t \in Tokens : CheckResourceProcessorUnavailable(s,t)
    \/ \E s \in Sites, t \in Tokens : ServerEngineReceiveCheckOK(s,t)
    \/ \E s \in Sites, t \in Tokens : ServerEngineReceiveCheckNo(s,t)
    \/ \E t \in Tokens : AdminCheckTimeout(t)
    \/ \E s \in Sites, t \in Tokens : ServerEngineReceiveDeployOK(s,t)
    \/ \E s \in Sites, t \in Tokens : ServerEngineReceiveDeployNo(s,t)
    \/ \E t \in Tokens : AdminDeployTimeout(t)
    \/ \E s \in Sites, t \in Tokens : ServerEngineReceiveStartOK(s,t)
    \/ \E s \in Sites, t \in Tokens : ServerEngineReceiveStartNo(s,t)
    \/ \E t \in Tokens : AdminStartTimeout(t)
    \/ \E s \in Sites, t \in Tokens : ServerEngineReceiveCancelAck(s,t)
    \/ \E t \in Tokens : AdminCancelTimeout(t)
    \/ DefaultJobSchedulerEvaluateResources
    \/ ServerEngineCancelClientResources
    \/ \E s \in Sites, t \in Tokens : CancelResourceProcessorCancel(s,t)
    \/ DefaultJobSchedulerCancelReturned
    \/ DefaultJobSchedulerUpdateHistory
    \/ DefaultJobSchedulerAdmissionException
    \/ \E s \in Sites : AutoCleanResourceManagerTick(s)
    \/ \E s \in Sites, t \in Tokens : AutoCleanResourceManagerFinishExpiry(s,t)
    \/ JobRunnerCheckSubmitted
    \/ JobRunnerDeployJob
    \/ JobRunnerDeploymentException
    \/ \E s \in Sites, t \in Tokens : ClientDeploySuccess(s,t)
    \/ \E s \in Sites, t \in Tokens : ClientDeployError(s,t)
    \/ JobRunnerEvaluateDeployment
    \/ JobRunnerWriteDispatched
    \/ JobRunnerPersistDeploy
    \/ JobRunnerCheckDispatched
    \/ ServerEngineSpawnJob
    \/ ServerEngineRegisterJob
    \/ ServerEngineInstallWaiter
    \/ JobRunnerSetPendingOutcomes
    \/ ServerEngineStartClientJob
    \/ JobRunnerEvaluateStartReplies
    \/ JobRunnerFilterPendingOutcomes
    \/ DefaultJobSchedulerJobStarted
    \/ JobRunnerRegisterRunning
    \/ JobRunnerWriteRunning
    \/ JobRunnerStartupStoreError
    \/ ServerEngineStartupError
    \/ JobRunnerFailureRemove
    \/ JobRunnerFailureStop
    \/ JobRunnerFailureStatus
    \/ DefaultJobSchedulerJobAbortedOnStartFailure
    \/ \E s \in Sites, t \in Tokens : StartJobProcessorAllocate(s,t)
    \/ \E s \in Sites, t \in Tokens : StartJobProcessorRejectToken(s,t)
    \/ \E s \in Sites, t \in Tokens : ListResourceConsumerConsume(s,t)
    \/ \E s \in Sites, t \in Tokens : ClientEngineStartAppCheck(s,t)
    \/ \E s \in Sites, t \in Tokens : ClientEngineStartAppReturnedError(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorRegisterPendingHandle(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorPrepareException(s,t)
    \/ \E s \in Sites, t \in Tokens : ProcessJobLauncherSnapshotEnvironment(s,t)
    \/ \E s \in Sites, t \in Tokens : ProcessJobLauncherSpawn(s,t)
    \/ \E s \in Sites, t \in Tokens : ProcessJobLauncherSpawnException(s,t)
    \/ \E s \in Sites, t \in Tokens : PendingJobHandleAttach(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorApplyPendingAbort(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorAfterJobLaunchEvent(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorInstallCleanupWaiter(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorWaiterInstallationException(s,t)
    \/ \E s \in Sites, t \in Tokens : StartJobProcessorRollback(s,t)
    \/ \E s \in Sites, t \in Tokens : StartJobProcessorReplySuccess(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorNotifyStarted(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorNotifyStopped(s,t)
    \/ \E s \in Sites, t \in Tokens : ClientChildExit(s,t)
    \/ \E s \in Sites, t \in Tokens : ClientChildFailure(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorWaitChildExit(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorReportOutcome(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorOutcomeReportReturned(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorOutcomeReportException(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorFreeAfterExit(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorRemoveProcess(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorJobCompletedEvent(s,t)
    \/ \E s \in Sites, t \in Tokens : ClientEngineAbortApp(s,t)
    \/ \E s \in Sites, t \in Tokens : ClientEngineHeartbeatAbort(s,t)
    \/ \E s \in Sites, t \in Tokens : JobExecutorTerminateAfterGrace(s,t)
    \/ \E s \in Sites, t \in Tokens : FederatedServerHeartbeatCleanup(s,t)
    \/ \E s \in Sites, t \in Tokens : ServerEngineReceiveOutcome(s,t)
    \/ \E s \in Sites, t \in Tokens : ServerEngineReceiveFailureOutcome(s,t)
    \/ \E j \in Jobs : ServerChildExit(j)
    \/ \E j \in Jobs : ServerChildFailure(j)
    \/ \E j \in Jobs : ServerEngineObserveExit(j)
    \/ \E j \in Jobs : ServerEngineTerminateAfterGrace(j)
    \/ \E j \in Jobs : ServerEngineRemoveAfterTerminate(j)
    \/ \E j \in Jobs : JobCommandAbortRead(j)
    \/ \E j \in Jobs : JobCommandAbortPreRunWrite(j)
    \/ \E j \in Jobs : JobCommandAbortPreRunAcknowledge(j)
    \/ \E j \in Jobs : JobCommandAbortAlreadyTerminal(j)
    \/ \E j \in Jobs : JobCommandAbortRunning(j)
    \/ \E j \in Jobs : JobRunnerMarkAborted(j)
    \/ \E j \in Jobs : JobRunnerSelectCompletion(j)
    \/ \E j \in Jobs : JobRunnerOutcomesResolved(j)
    \/ \E j \in Jobs : JobRunnerOutcomeGraceExpired(j)
    \/ \E j \in Jobs : JobRunnerClassifyCompletion(j)
    \/ \E j \in Jobs : JobRunnerArchiveSuccess(j)
    \/ \E j \in Jobs : JobRunnerArchiveException(j)
    \/ \E j \in Jobs : JobRunnerRetryArchive(j)
    \/ \E j \in Jobs : JobRunnerArchiveGraceExpired(j)
    \/ \E j \in Jobs : JobRunnerPublishTerminal(j)
    \/ \E j \in Jobs : JobRunnerTerminalStoreException(j)
    \/ \E j \in Jobs : JobRunnerRemoveCompleted(j)
    \/ \E j \in Jobs : DefaultJobSchedulerJobAbortedOnCompletion(j)
    \/ \E j \in Jobs : DefaultJobSchedulerJobCompleted(j)
    \/ \E m \in network : TransportLoseMessage(m)
    \/ \E j \in Jobs : DefaultJobSchedulerPersistFailed(j)
    \/ \E j \in Jobs : DefaultJobSchedulerPersistBlocked(j)
    \/ DefaultJobSchedulerReturnPass
    \/ JobRunnerMissingPendingOutcomes
    \/ \E j \in Jobs : JobCommandAbortRunningSend(j)
    \/ JobRunnerFailureSendStop
    \/ \E s \in Sites, t \in Tokens : JobExecutorAbortStarting(s,t)

Spec == Init /\ [][Next]_vars


\* Core resource contract: count multiplicities in deques and retained payloads.
\* auto_clean_resource_manager.py:123-172; list_resource_manager.py:52-75.
OwnershipCount(s,u) == Count(rm[s].free,u) +
    SumOn(Tokens,[t \in Tokens |-> Count(rm[s].reserved[t],u)+Count(rm[s].allocated[t],u)])
ResourceConservation == \A s \in Sites, u \in Units : OwnershipCount(s,u)=1

\* Scenario 1 / MC-1: actual child env copy, not allocation arguments alone.
\* list_resource_consumer.py:37; process_launcher.py:68-83.
ProcessBindingMatchesOwnership ==
    \A s \in Sites, t \in Tokens : client[s][t].alive =>
      /\ client[s][t].binding = rm[s].allocated[t]
      /\ \A u \in Tokens \ {t} : client[s][u].alive =>
             SeqSet(client[s][t].binding) \cap SeqSet(client[s][u].binding) = {}

\* Scenarios 1,2 / MC-1,MC-2. Logical STOPPED never appears in this guard.
\* client_executor.py:513-519,626-679; scheduler_cmds.py:129-133.
NoFreeWhileInUse ==
    \A s \in Sites, t \in Tokens : client[s][t].alive =>
      \A u \in SeqSet(client[s][t].binding) :
        /\ Count(rm[s].free,u)=0
        /\ \A v \in Tokens \ {t} :
             Count(rm[s].reserved[v],u)+Count(rm[s].allocated[v],u)=0

\* Startup owns rollback until the waiter starts. An exited/released child
\* qualifies as completed; an allocated, live child with no waiter does not.
\* client_executor.py:299-334,622-687; scheduler_cmds.py:129-133.
StartupOwns(s,t) == client[s][t].pc \in
    {"allocated","consumed","checked","registered","snapshotted","spawned",
     "attachedAbort","attached","afterEvent","rollback"}
WaiterOwns(s,t) == client[s][t].waiter /\ client[s][t].cleanup # "done"
CleanupOwnerOrCompleted ==
    \A s \in Sites, t \in Tokens : rm[s].payload[t] # <<>> =>
      \/ StartupOwns(s,t)
      \/ WaiterOwns(s,t)
      \/ /\ ~client[s][t].alive /\ rm[s].allocated[t] = <<>>

\* Scenario 3 / MC-3: observer records actual successful pre-run CLI reply.
\* job_cmds.py:1061-1066; job_runner.py:670,711.
AcceptedPreRunAbortPersists ==
    \A j \in Jobs : jobs[j].abortAck => jobs[j].status="ABORTED"
\* Scenario 3 / MC-4: terminal publication is per supported attempt.
NoTerminalResurrection == \A j \in Jobs : ~jobs[j].resurrected

ClientPCs == {"idle","allocated","consumed","checked","registered",
 "snapshotted","spawned","attachedAbort","attached","afterEvent",
 "rollback","replyReady","returned","returnedError","error"}
SchedulerPCs == {"idle","scan","sendCheck","checkWait","history",
 "cancelSend","cancelWait","persistRetry","checkSubmitted","deploySend",
 "deployWait","writeDispatched","persistDeploy","checkDispatched",
 "serverSpawn","serverRegister","serverWaiter","pendingOutcomes","startSend",
 "startWait","filterOutcomes","startedEvent","registerRunning","writeRunning",
 "failRemove","failStop","failStopWait","failStatus","failEvent","persistFailed"}
CompletionPCs == {"idle","outcomeWait","classify","archive","archiveRetry",
 "publish","remove","abortedEvent","completedEvent","done"}
ValidUnitSequence(q) == /\ q \in Seq(Units)
                        /\ Len(q) <= Len(Pool)+2*Cardinality(Tokens)
TypeOK ==
 /\ DOMAIN scheduler = {"pc","current","candidates","issued","count",
     "persisted","history","cooldown","scheduled","considered","result",
     "failedPending","blockedPending","returnTo"}
 /\ scheduler.pc \in SchedulerPCs
 /\ scheduler.current \in Jobs \cup {""}
 /\ scheduler.candidates \in Seq(Jobs)
 /\ scheduler.scheduled \subseteq Jobs
 /\ scheduler.failedPending \subseteq Jobs
 /\ scheduler.blockedPending \subseteq Jobs
 /\ scheduler.returnTo \in {"idle","checkSubmitted"}
 /\ scheduler.issued \in [Jobs -> 0..AttemptSlots]
 /\ scheduler.count \in [Jobs -> 0..(MaxScheduleCount+1)]
 /\ scheduler.persisted \in [Jobs -> 0..(MaxScheduleCount+1)]
 /\ scheduler.considered \in [Jobs -> 0..AttemptSlots]
 /\ scheduler.cooldown \in [Jobs -> BOOLEAN]
 /\ \A j \in Jobs : scheduler.history[j] \in Seq({"scheduled","no_resource","exceeded"})
 /\ scheduler.result \in {"none","scheduled","no_resource"}
 /\ DOMAIN jobs = Jobs
 /\ \A j \in Jobs :
     /\ DOMAIN jobs[j] = DOMAIN EmptyJob
     /\ jobs[j].status \in Statuses /\ jobs[j].checked \in Statuses
     /\ jobs[j].finishStatus \in Terminal /\ jobs[j].adminRead \in Statuses
     /\ jobs[j].completion \in CompletionPCs
     /\ jobs[j].adminPC \in {"idle","read","ackPreRun","markAborted","stopWait"}
     /\ \A f \in {"dispatch","deployed","active","pending"} : jobs[j][f] \subseteq Sites
     /\ \A f \in DOMAIN EmptyJob \ {"status","checked","finishStatus","adminRead",
          "completion","adminPC","dispatch","deployed","active","pending"} : jobs[j][f] \in BOOLEAN
 /\ DOMAIN rm = Sites /\ DOMAIN client = Sites /\ DOMAIN rpc = Sites
 /\ \A s \in Sites :
     /\ DOMAIN rm[s] = {"free","reserved","ttl","allocated","payload","releases"}
     /\ ValidUnitSequence(rm[s].free)
     /\ rm[s].ttl \in [Tokens -> 0..ReservationTTL]
     /\ rm[s].releases \in [Tokens -> 0..2]
     /\ \A f \in {"reserved","allocated","payload"} :
          /\ DOMAIN rm[s][f] = Tokens
          /\ \A t \in Tokens : rm[s][f][t] \in {<<>>} \cup {<<u>> : u \in Units}
     /\ DOMAIN client[s] = Tokens /\ DOMAIN rpc[s] = Tokens
     /\ \A t \in Tokens :
         /\ DOMAIN client[s][t] = DOMAIN EmptyClient
         /\ client[s][t].pc \in ClientPCs
         /\ client[s][t].handle \in {"none","pending","attached"}
         /\ client[s][t].binding \in {<<>>} \cup {<<u>> : u \in Units}
         /\ client[s][t].logical \in {"NOT_STARTED","STARTING","STARTED","STOPPED"}
         /\ client[s][t].cleanup \in {"none","wait","report","reportWait","free","pop","event","done"}
         /\ client[s][t].exitCode \in {"ok","failed"}
         /\ \A f \in DOMAIN EmptyClient \ {"pc","handle","binding","logical","cleanup","exitCode"} : client[s][t][f] \in BOOLEAN
         /\ rpc[s][t] \in [ {"check","deploy","start","cancel"} -> ReplyStates ]
 /\ resourceEnv \in [Sites -> ({<<>>} \cup {<<u>> : u \in Units})]
 /\ network \subseteq AllMessages

SchedulerCapacity == Cardinality(scheduler.scheduled) <= MaxJobs
RetryHistoryMatchesCount == \A j \in Jobs : Len(scheduler.history[j]) = scheduler.count[j]
SingleSupportedStart == \A j \in Jobs, s \in Sites :
    Cardinality({t \in Tokens : t[1]=j /\ client[s][t].spawned}) <= 1
WaitBeforeNormalFree == \A s \in Sites,t \in Tokens :
    client[s][t].cleanup \in {"free","pop","event","done"} => client[s][t].exitObserved
\* Diagnostic for TV-3, not enabled before the test-verifiable extension.
PendingCompletionRemoval == \A j \in Jobs : jobs[j].completion="remove" => jobs[j].running

\* Conditional progress: no theorem for permanently down services/sites or
\* failed waiter installation. Scheduling's fair service assumption is made
\* explicit, not smuggled into Init or the safety transition relation.
Eligible(j) == /\ jobs[j].status="SUBMITTED"
               /\ scheduler.count[j] < MaxScheduleCount
               /\ scheduler.issued[j] < AttemptSlots
               /\ ~scheduler.cooldown[j]
               /\ Cardinality(scheduler.scheduled) < MaxJobs
OtherEligibleJobProgress == \A j \in Jobs :
    \A n \in 0..(AttemptSlots-1) :
      (Eligible(j) /\ scheduler.considered[j]=n) ~>
        (scheduler.considered[j]>n \/ jobs[j].status # "SUBMITTED" \/
         scheduler.count[j]>=MaxScheduleCount)
CleanupEventuallyReleased == \A s \in Sites,t \in Tokens :
    (rm[s].allocated[t] # <<>> /\ WaiterOwns(s,t)) ~> (rm[s].allocated[t] = <<>>)
ReservationEventuallyResolved == \A s \in Sites,t \in Tokens :
    (rm[s].reserved[t] # <<>>) ~> (rm[s].reserved[t] = <<>>)

=============================================================================
