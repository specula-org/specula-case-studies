from pathlib import Path
import json
P=Path(__file__).resolve().parent
A=[]
V=['scheduler','jobs','rm','client','resourceEnv','rpc','network']
SRC={
 'sched':'nvflare/app_common/job_schedulers/job_scheduler.py',
 'runner':'nvflare/private/fed/server/job_runner.py',
 'server':'nvflare/private/fed/server/server_engine.py',
 'processor':'nvflare/private/fed/client/scheduler_cmds.py',
 'engine':'nvflare/private/fed/client/client_engine.py',
 'executor':'nvflare/private/fed/client/client_executor.py',
 'rm':'nvflare/app_common/resource_managers/auto_clean_resource_manager.py',
 'list':'nvflare/app_common/resource_managers/list_resource_manager.py',
 'consumer':'nvflare/app_common/resource_consumers/list_resource_consumer.py',
 'launch':'nvflare/app_common/job_launcher/process_launcher.py',
 'admin':'nvflare/private/fed/server/admin.py',
 'cmd':'nvflare/private/fed/server/job_cmds.py',
 'store':'nvflare/apis/impl/job_def_manager.py',
 'event':'nvflare/apis/utils/event.py',
 'fed':'nvflare/private/fed/server/fed_server.py',
 'comm':'nvflare/private/fed/client/communicator.py',
 'deploy':'nvflare/private/fed/client/training_cmds.py'}
def src(s):
 return '; '.join(SRC[k]+':'+v for k,v in (x.split(':',1) for x in s.split(';')))
def action(name, params, guards, updates, refs, scenario, fault=None, note=''):
 # Each action block has an explicit source anchor, including guards and updates.
 A.append(dict(name=name,params=params,guards=guards,updates=updates,source=src(refs),scenario=scenario,fault=fault,note=note))
def ex(v,*patch):return '['+v+' EXCEPT '+', '.join('!'+k+' = '+val for k,val in patch)+']'
def S(*p):return ex('scheduler',*p)
def J(j,*p):return ex('jobs',*[(f'[{j}]'+k,v) for k,v in p])
def C(*p):return ex('client',*[(f'[s][t]'+k,v) for k,v in p])
def R(*p):return ex('rm',*[(f'[s]'+k,v) for k,v in p])
def Q(*p):return ex('rpc',*[(f'[s][t]'+k,v) for k,v in p])
def msg(k):return f'Msg("{k}", s, t)'
def send(k):return 'network \\cup {'+msg(k)+'}'
def consume(k):return 'network \\ {'+msg(k)+'}'
def reply(k,resp):return '('+consume(k)+') \\cup {'+msg(resp)+'}'
T='CurrentToken'
header=r'''------------------------------ MODULE base ------------------------------
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

'''
# Phase 1: admission, pass ordering, retry semantics.
action('DefaultJobSchedulerBeginPass',[],['scheduler.pc = "idle"','Cardinality(scheduler.scheduled) < MaxJobs'],{'scheduler':S(('.pc','"scan"'),('.candidates','SelectSeq(JobOrder,LAMBDA j : jobs[j].status = "SUBMITTED")'))},'sched:339-346;runner:641-658','5')
action('DefaultJobSchedulerEndPass',[],['scheduler.pc = "scan"','scheduler.candidates = <<>>'],{'scheduler':S(('.pc','"idle"'),('.current','""'))},'sched:377-378','5')
action('DefaultJobSchedulerSkipBackoff',[],['scheduler.pc = "scan"','scheduler.candidates # <<>>','scheduler.cooldown[Head(scheduler.candidates)]'],{'scheduler':S(('.candidates','Tail(scheduler.candidates)'))},'sched:356-362','5')
action('DefaultJobSchedulerBackoffElapsed',['j'],['scheduler.cooldown[j]'],{'scheduler':S(('.cooldown[j]','FALSE'))},'sched:356-362','5',note='Deadline crossing; elapsed seconds must be >= Backoff(j); no normal retry counter bound.')
action('DefaultJobSchedulerExhausted',[],['scheduler.pc = "scan"','scheduler.candidates # <<>>','scheduler.count[Head(scheduler.candidates)] >= MaxScheduleCount'],{'jobs':J('Head(scheduler.candidates)',('.status','"CANT_SCHEDULE"')),'scheduler':S(('.count[Head(scheduler.candidates)]','@+1'),('.history[Head(scheduler.candidates)]','Append(@,"exceeded")'),('.persisted[Head(scheduler.candidates)]','scheduler.count[Head(scheduler.candidates)]+1'),('.candidates','Tail(scheduler.candidates)'))},'sched:298-310;sched:347-354','5',note='The exhausted-candidate metadata write succeeds in this slice.')
action('DefaultJobSchedulerTryJob',[],['scheduler.pc = "scan"','scheduler.candidates # <<>>','~scheduler.cooldown[Head(scheduler.candidates)]','scheduler.count[Head(scheduler.candidates)] < MaxScheduleCount','scheduler.issued[Head(scheduler.candidates)] < AttemptSlots'],{'scheduler':S(('.current','Head(scheduler.candidates)'),('.issued[Head(scheduler.candidates)]','@+1'),('.considered[Head(scheduler.candidates)]','@+1'),('.pc','"sendCheck"'))},'sched:104-199;sched:347-365','1-5',note='Connected valid selected sites pass applicability checks. AttemptSlots is a finite fresh-token universe, not retry policy.')
action('ServerEngineCheckClientResources',[],['scheduler.pc = "sendCheck"'],{'network':r'network \cup {Msg("Check",s,CurrentToken) : s \in Sites}','rpc':r'[s \in Sites |-> [rpc[s] EXCEPT ![CurrentToken].check = "waiting"]]','scheduler':S(('.pc','"checkWait"'))},'server:1010-1024','1-5')
action('CheckResourceProcessorReserve',['s','t'],[msg('Check')+r' \in network','rm[s].free # <<>>'],{'rm':R(('.free','Tail(@)'),('.reserved[t]','<<Head(rm[s].free)>>'),('.ttl[t]','ReservationTTL')),'network':reply('Check','CheckOK')},'processor:67-93;rm:123-138;list:57-75','1,2,4,5')
action('CheckResourceProcessorUnavailable',['s','t'],[msg('Check')+r' \in network','rm[s].free = <<>>'],{'network':reply('Check','CheckNo')},'processor:83-93;rm:123-138;list:57-67','1,4,5')
# Exact waiter association; a late reply changes no current/later attempt.
for stage,pre,ok,no in [('check','Check','CheckOK','CheckNo'),('deploy','Deploy','DeployOK','DeployNo'),('start','Start','StartOK','StartNo'),('cancel','Cancel','CancelAck',None)]:
 for kind,result in [(ok,'ok')]+([(no,'no')] if no else []):
  action('ServerEngineReceive'+kind,['s','t'],[msg(kind)+r' \in network'],{'network':consume(kind),'rpc':Q(('.'+stage,f'IF rpc[s][t].{stage} = "waiting" THEN "{result}" ELSE rpc[s][t].{stage}'))},'server:1025-1041;server:1065-1083;admin:286-339','1,4,5',note='Closed waiters discard late replies; no mutation of another token or lifecycle status.')
 action('Admin'+pre+'Timeout',['t'],[r'\E s \in Sites : rpc[s][t].'+stage+' = "waiting"'],{'rpc':f'[s \\in Sites |-> [rpc[s] EXCEPT ![t].{stage} = IF @ = "waiting" THEN "timeout" ELSE @]]'},'server:1023-1040;server:1065-1083;admin:307-339','1,4,5',fault=stage+'Timeout',note='Actual RPC deadline crossing; commands already sent remain executable.')
action('DefaultJobSchedulerEvaluateResources',[],['scheduler.pc = "checkWait"','WaitDone(CurrentToken,"check",Sites)'],{'scheduler':S(('.pc','IF Policy(ReplySites(CurrentToken,"check","ok")) THEN "history" ELSE "cancelSend"'),('.result','IF Policy(ReplySites(CurrentToken,"check","ok")) THEN "scheduled" ELSE "no_resource"')),'jobs':J('CurrentJob',('.dispatch','ReplySites(CurrentToken,"check","ok")'))},'sched:203-261','1,2,5')
action('ServerEngineCancelClientResources',[],['scheduler.pc = "cancelSend"'],{'network':r'network \cup {Msg("Cancel",s,CurrentToken) : s \in jobs[CurrentJob].dispatch}','rpc':r'[s \in Sites |-> [rpc[s] EXCEPT ![CurrentToken].cancel = IF s \in jobs[CurrentJob].dispatch THEN "waiting" ELSE @]]','scheduler':S(('.pc','"cancelWait"'))},'sched:229-247;server:1052-1066','4,5')
action('CancelResourceProcessorCancel',['s','t'],[msg('Cancel')+r' \in network'],{'rm':R(('.free','Reverse(rm[s].reserved[t]) \\o @'),('.reserved[t]','<<>>'),('.ttl[t]','0')),'network':reply('Cancel','CancelAck')},'processor:149-157;rm:140-151;list:52-55','4,5',note='Only existing reservations are returned. Missing or already allocated tokens are a no-op.')
action('DefaultJobSchedulerCancelReturned',[],['scheduler.pc = "cancelWait"','WaitDone(CurrentToken,"cancel",jobs[CurrentJob].dispatch)'],{'scheduler':S(('.pc','"history"'))},'server:1065-1066;sched:229-254','5',note='Pinned implementation discards cancellation acknowledgements, including timeout/no reply.')
action('DefaultJobSchedulerUpdateHistory',[],['scheduler.pc = "history"'],{'scheduler':S(('.count[CurrentJob]','@+1'),('.history[CurrentJob]','Append(@,scheduler.result)'),('.cooldown[CurrentJob]','TRUE'),('.pc','IF scheduler.result = "scheduled" THEN "checkSubmitted" ELSE "persistRetry"'))},'sched:320-333;sched:364-375','5')
action('DefaultJobSchedulerPersistRetry',[],['scheduler.pc = "persistRetry"'],{'scheduler':S(('.persisted[CurrentJob]','scheduler.count[CurrentJob]'),('.candidates','Tail(@)'),('.pc','"scan"'))},'sched:298-310;sched:372-375','5')
action('DefaultJobSchedulerAdmissionException',[],['scheduler.pc \\in {"checkWait","history"}'],{'scheduler':S(('.pc','"idle"'),('.current','""'),('.candidates','<<>>'))},'sched:292-310;sched:364-369','5',fault='admissionError',note='Known #5191 context: whole pass exits, no new cancellation/history; TTL remains.')
# Expiry order over simultaneously expired entries is abstracted nondeterministically.
action('AutoCleanResourceManagerTick',['s'],[r'\E t \in Tokens : rm[s].ttl[t] > 0'],{'rm':R(('.ttl','[t \\in Tokens |-> IF rm[s].ttl[t]>0 THEN rm[s].ttl[t]-1 ELSE 0]'))},'rm:102-113','1,4,5',note='One cleanup scan tick. Expired entries are drained under the same RM lock by FinishExpiry; other RM operations are disabled while an expired entry exists.')
action('AutoCleanResourceManagerFinishExpiry',['s','t'],['rm[s].reserved[t] # <<>>','rm[s].ttl[t] = 0'],{'rm':R(('.free','Reverse(rm[s].reserved[t]) \\o @'),('.reserved[t]','<<>>'))},'rm:105-116;list:52-55','1,4,5',note='Internal lock-held scan continuation, not a release/reacquire window. Drain order over tokens overapproximates insertion order; unit conservation is order-independent.')
# Runner read / deploy / write windows.
action('JobRunnerCheckSubmitted',[],['scheduler.pc = "checkSubmitted"'],{'jobs':J('CurrentJob',('.checked','jobs[CurrentJob].status')),'scheduler':S(('.pc','IF jobs[CurrentJob].status = "SUBMITTED" THEN "deploySend" ELSE "idle"'))},'runner:660-669','3',note='Status read and subsequent DISPATCHED publication are separate.')
action('JobRunnerDeployJob',[],['scheduler.pc = "deploySend"'],{'network':r'network \cup {Msg("Deploy",s,CurrentToken) : s \in jobs[CurrentJob].dispatch}','rpc':r'[s \in Sites |-> [rpc[s] EXCEPT ![CurrentToken].deploy = IF s \in jobs[CurrentJob].dispatch THEN "waiting" ELSE @]]','scheduler':S(('.pc','"deployWait"'))},'runner:173-248','1-3',note='Server deployment succeeds here; DeploymentException models the raised/returned-error path.')
action('JobRunnerDeploymentException',[],['scheduler.pc \\in {"deploySend","deployWait"}'],{'scheduler':S(('.pc','"failRemove"'))},'runner:194-209;runner:224-226;runner:713-728','2,5',fault='deployError')
action('ClientDeploySuccess',['s','t'],[msg('Deploy')+r' \in network'],{'client':C(('.deployed','TRUE')),'network':reply('Deploy','DeployOK')},'runner:250-267','2',note='Boundary abstraction of successful client deployment; no workspace content modeled.')
action('ClientDeployError',['s','t'],[msg('Deploy')+r' \in network'],{'network':reply('Deploy','DeployNo')},'runner:250-267','2',fault='deployError',note='Client deployment returns non-OK; already successful sites remain deployed.')
action('JobRunnerEvaluateDeployment',[],['scheduler.pc = "deployWait"','WaitDone(CurrentToken,"deploy",jobs[CurrentJob].dispatch)'],{'jobs':J('CurrentJob',('.deployed','ReplySites(CurrentToken,"deploy","ok")')),'scheduler':S(('.pc','IF Policy(ReplySites(CurrentToken,"deploy","ok")) THEN "writeDispatched" ELSE "failRemove"'))},'runner:250-285','2,3')
action('JobRunnerWriteDispatched',[],['scheduler.pc = "writeDispatched"'],{'jobs':J('CurrentJob',('.status','"DISPATCHED"')),'scheduler':S(('.pc','"persistDeploy"'))},'runner:669-670;store:459-481','3')
action('JobRunnerPersistDeploy',[],['scheduler.pc = "persistDeploy"'],{'scheduler':S(('.persisted[CurrentJob]','scheduler.count[CurrentJob]'),('.pc','"checkDispatched"'))},'runner:672-695','3,5')
action('JobRunnerCheckDispatched',[],['scheduler.pc = "checkDispatched"'],{'jobs':J('CurrentJob',('.checked','jobs[CurrentJob].status')),'scheduler':S(('.pc','IF jobs[CurrentJob].status = "DISPATCHED" THEN "serverSpawn" ELSE "idle"'))},'runner:697-707','3')
action('ServerEngineSpawnJob',[],['scheduler.pc = "serverSpawn"','~jobs[CurrentJob].serverSpawned'],{'jobs':J('CurrentJob',('.serverAlive','TRUE'),('.serverSpawned','TRUE')),'scheduler':S(('.pc','"serverRegister"'))},'server:179-195;server:314-316','2,3',note='Default local server spawn; physical exit remains a separate event.')
action('ServerEngineRegisterJob',[],['scheduler.pc = "serverRegister"'],{'jobs':J('CurrentJob',('.serverRegistered','TRUE')),'scheduler':S(('.pc','"serverWaiter"'))},'server:321-326','2-4')
action('ServerEngineInstallWaiter',[],['scheduler.pc = "serverWaiter"'],{'jobs':J('CurrentJob',('.serverWaiter','TRUE')),'scheduler':S(('.pc','"pendingOutcomes"'))},'server:328-329','2-4',note='Server waiter thread creation succeeds in this slice; the targeted installation failure is client-side.')
action('JobRunnerSetPendingOutcomes',[],['scheduler.pc = "pendingOutcomes"'],{'jobs':J('CurrentJob',('.pending','jobs[CurrentJob].deployed'),('.outcomeKey','TRUE')),'scheduler':S(('.pc','"startSend"'))},'runner:295-310','1-4')
action('ServerEngineStartClientJob',[],['scheduler.pc = "startSend"'],{'network':r'network \cup {Msg("Start",s,CurrentToken) : s \in jobs[CurrentJob].deployed}','rpc':r'[s \in Sites |-> [rpc[s] EXCEPT ![CurrentToken].start = IF s \in jobs[CurrentJob].deployed THEN "waiting" ELSE @]]','scheduler':S(('.pc','"startWait"'))},'server:1068-1083','1,2')
action('JobRunnerEvaluateStartReplies',[],['scheduler.pc = "startWait"','WaitDone(CurrentToken,"start",jobs[CurrentJob].deployed)'],{'jobs':J('CurrentJob',('.active','ReplySites(CurrentToken,"start","ok")')),'scheduler':S(('.pc','IF ReplySites(CurrentToken,"start","no") # {} \\/ jobs[CurrentJob].deployed = {} \\/ (StrictStart /\\ ~Policy(ReplySites(CurrentToken,"start","ok"))) THEN "failRemove" ELSE "filterOutcomes"'))},'admin:101-142;runner:313-358','1,2',note='All connected targets produce a reply slot. Non-strict timeout is excluded from active metadata without rechecking participant policy. Normal START errors have ERROR_MSG_PREFIX bodies.')
action('JobRunnerFilterPendingOutcomes',[],['scheduler.pc = "filterOutcomes"','jobs[CurrentJob].outcomeKey'],{'jobs':J('CurrentJob',('.pending','@ \\cap jobs[CurrentJob].active')),'scheduler':S(('.pc','"startedEvent"'))},'runner:355-364','1,4')
action('DefaultJobSchedulerJobStarted',[],['scheduler.pc = "startedEvent"'],{'scheduler':S(('.scheduled','@ \\cup {CurrentJob}'),('.pc','"registerRunning"'))},'runner:364-372;sched:275-280;event:54-84','1,3,4',note='Synchronous production event dispatch, explicit job ID, set-like idempotent membership; ordinary component exceptions do not propagate.')
action('JobRunnerRegisterRunning',[],['scheduler.pc = "registerRunning"'],{'jobs':J('CurrentJob',('.running','TRUE')),'scheduler':S(('.pc','"writeRunning"'))},'runner:709-710','3')
action('JobRunnerWriteRunning',[],['scheduler.pc = "writeRunning"'],{'jobs':J('CurrentJob',('.status','"RUNNING"'),('.resurrected','@ \\/ jobs[CurrentJob].terminalPublished')),'scheduler':S(('.pc','"idle"'))},'runner:711-712;store:459-481','3',note='No expected-state guard; terminalPublished is a history observer for this attempt.')
action('JobRunnerStartupStoreError',[],['scheduler.pc \\in {"writeDispatched","persistDeploy","writeRunning"}'],{'scheduler':S(('.pc','"failRemove"'))},'runner:670-689;runner:711-713','2,3,5',fault='storeError')
action('ServerEngineStartupError',[],['scheduler.pc = "serverSpawn"'],{'scheduler':S(('.pc','"failRemove"'))},'server:179-193;runner:304-306','2',fault='preLaunchError')
action('JobRunnerFailureRemove',[],['scheduler.pc = "failRemove"'],{'jobs':J('CurrentJob',('.running','FALSE'),('.pending','{}'),('.outcomeKey','FALSE')),'scheduler':S(('.pc','"failStop"'))},'runner:713-719','2,5')
action('JobRunnerFailureStop',[],['scheduler.pc = "failStop"'],{'jobs':J('CurrentJob',('.serverStop','@ \\/ jobs[CurrentJob].serverRegistered')),'network':r'network \cup (IF jobs[CurrentJob].serverRegistered THEN {Msg("Stop",s,CurrentToken) : s \in jobs[CurrentJob].deployed} ELSE {})','scheduler':S(('.pc','"failStatus"'))},'runner:374-413;runner:719-720','2,4,5',note='Stop is sent only when server run_processes contains the job; it does not reclaim reservations.')
action('JobRunnerFailureStatus',[],['scheduler.pc = "failStatus"'],{'jobs':J('CurrentJob',('.status','"FAILED_TO_RUN"')),'scheduler':S(('.pc','"failEvent"'))},'runner:720-726','2,5',note='Failure-branch store failure is TV-2 first, not injected here.')
action('DefaultJobSchedulerJobAbortedOnStartFailure',[],['scheduler.pc = "failEvent"'],{'scheduler':S(('.scheduled','@ \\ {CurrentJob}'),('.pc','"idle"'))},'runner:728-731;sched:281-285;event:54-84','2,4,5')
# Client resource allocation is before consumer and ClientEngine.start_app.
action('StartJobProcessorAllocate',['s','t'],[msg('Start')+r' \in network','rm[s].reserved[t] # <<>>'],{'rm':R(('.allocated[t]','rm[s].reserved[t]'),('.payload[t]','rm[s].reserved[t]'),('.reserved[t]','<<>>'),('.ttl[t]','0')),'client':C(('.pc','"allocated"')),'network':consume('Start')},'processor:114-118;rm:153-164','1,2,4')
action('StartJobProcessorRejectToken',['s','t'],[msg('Start')+r' \in network','rm[s].reserved[t] = <<>>'],{'client':C(('.pc','"error"')),'network':reply('Start','StartNo')},'rm:156-163;processor:129-137','1,4',note='Fixed missing-token rejection; no fallback allocation and no rollback when allocation never succeeded.')
action('ListResourceConsumerConsume',['s','t'],['client[s][t].pc = "allocated"'],{'resourceEnv':ex('resourceEnv',('[s]','rm[s].payload[t]')),'client':C(('.pc','"consumed"'))},'processor:119-121;consumer:31-37;consumer:49-52','1')
action('ClientEngineStartAppCheck',['s','t'],['client[s][t].pc = "consumed"','client[s][t].deployed','~RegisteredAtSite(s,t[1])'],{'client':C(('.pc','"checked"'))},'engine:357-379','2',note='Valid fresh start after acknowledged deployment; early-return alternative is preserved separately.')
action('ClientEngineStartAppReturnedError',['s','t'],['client[s][t].pc = "consumed"','~client[s][t].deployed'],{'client':C(('.pc','"returnedError"')),'network':send('StartNo')},'engine:365-367;processor:122-137','2',note='CR-1 boundary: cannot be reached by the selected successful-deploy START chain. No arbitrary deletion fault added; returned error does not free allocation.')
action('JobExecutorRegisterPendingHandle',['s','t'],['client[s][t].pc = "checked"','~RegisteredAtSite(s,t[1])'],{'client':C(('.pc','"registered"'),('.handle','"pending"'),('.logical','"STARTING"'))},'executor:299-307','1,2,4')
action('JobExecutorPrepareException',['s','t'],['client[s][t].pc \\in {"allocated","consumed","checked"}'],{'client':C(('.pc','"rollback"'))},'processor:119-133;executor:224-258','2',fault='preLaunchError',note='Ordinary preparation/metadata I/O exception before spawn; no fabricated invalid input.')
action('ProcessJobLauncherSnapshotEnvironment',['s','t'],['client[s][t].pc = "registered"'],{'client':C(('.binding','resourceEnv[s]'),('.pc','"snapshotted"'))},'launch:66-78','1')
action('ProcessJobLauncherSpawn',['s','t'],['client[s][t].pc = "snapshotted"'],{'client':C(('.alive','TRUE'),('.spawned','TRUE'),('.pc','"spawned"'))},'launch:80-83;executor:309-311','1,2')
action('ProcessJobLauncherSpawnException',['s','t'],['client[s][t].pc \\in {"registered","snapshotted"}'],{'client':C(('.pc','"rollback"'),('.handle','"none"'))},'launch:68-83;executor:308-316','2',fault='spawnError',note='Failure before a returned live handle; post-spawn handle-constructor failure is outside this slice.')
action('PendingJobHandleAttach',['s','t'],['client[s][t].pc = "spawned"'],{'client':C(('.pc','IF client[s][t].pendingAbort THEN "attachedAbort" ELSE "attached"'),('.handle','"attached"'),('.attached','TRUE'))},'executor:60-63;executor:318-320','1,2,4')
action('JobExecutorApplyPendingAbort',['s','t'],['client[s][t].pc = "attachedAbort"'],{'client':C(('.terminateRequested','TRUE'),('.pc','"attached"'))},'executor:318-320;executor:505-512','2,4')
action('JobExecutorAfterJobLaunchEvent',['s','t'],['client[s][t].pc = "attached"'],{'client':C(('.pc','"afterEvent"'))},'executor:324-330;event:54-84','2',note='Real event dispatch catches ordinary handler exceptions; no exceptional rollback edge from such handlers.')
action('JobExecutorInstallCleanupWaiter',['s','t'],['client[s][t].pc = "afterEvent"'],{'client':C(('.pc','"replyReady"'),('.waiter','TRUE'),('.cleanup','"wait"'))},'executor:330-334','2,4')
action('JobExecutorWaiterInstallationException',['s','t'],['client[s][t].pc = "afterEvent"'],{'client':C(('.pc','"rollback"'))},'executor:330-334;processor:129-133','2',fault='waiterError',note='Ordinary Thread construction/start exception before waiter execution. Live attached handle is retained; no invented double-free thread.')
action('StartJobProcessorRollback',['s','t'],['client[s][t].pc = "rollback"','rm[s].payload[t] # <<>>'],{'rm':R(('.free','Reverse(rm[s].payload[t]) \\o @'),('.allocated[t]','<<>>'),('.releases[t]','@+1')),'client':C(('.pc','"error"')),'network':send('StartNo')},'processor:129-137;rm:166-172;list:52-55','2',note='Rollback calls free(payload) regardless of child liveness or handle ownership. No fictitious token guard on free.')
action('StartJobProcessorReplySuccess',['s','t'],['client[s][t].pc = "replyReady"'],{'client':C(('.pc','"returned"')),'network':send('StartOK')},'engine:382;processor:135-137','1,2')
# Physical exit is independent of logical STOPPED and abort acknowledgement.
action('JobExecutorNotifyStarted',['s','t'],['client[s][t].alive','client[s][t].handle # "none"','client[s][t].logical = "STARTING"'],{'client':C(('.logical','"STARTED"'))},'executor:347-350','4')
action('JobExecutorNotifyStopped',['s','t'],['client[s][t].alive','client[s][t].handle # "none"','client[s][t].logical = "STARTED"'],{'client':C(('.logical','"STOPPED"'))},'executor:347-350;engine:390-404','4')
action('ClientChildExit',['s','t'],['client[s][t].alive'],{'client':C(('.alive','FALSE'))},'launch:51-58;executor:625-630','2,4',note='Ordinary completion or response to a stop; no guaranteed success under a permanently non-terminating process.')
action('ClientChildFailure',['s','t'],['client[s][t].alive'],{'client':C(('.alive','FALSE'),('.exitCode','"failed"'))},'executor:630-647','2,4',fault='childError',note='Abstract reportable ordinary process failure; generic teardown RC classifications are not expanded.')
action('JobExecutorWaitChildExit',['s','t'],['client[s][t].cleanup = "wait"','~client[s][t].alive','client[s][t].spawned','client[s][t].attached'],{'client':C(('.exitObserved','TRUE'),('.cleanup','"report"'))},'executor:625-647','2,4')
action('JobExecutorReportOutcome',['s','t'],['client[s][t].cleanup = "report"'],{'network':r'network \cup {Msg(IF client[s][t].exitCode = "ok" THEN "OutcomeOK" ELSE "OutcomeFailed",s,t)}','client':C(('.cleanup','"reportWait"'))},'executor:648-664','4')
action('JobExecutorOutcomeReportReturned',['s','t'],['client[s][t].cleanup = "reportWait"',r'Msg("OutcomeOK",s,t) \notin network',r'Msg("OutcomeFailed",s,t) \notin network'],{'client':C(('.cleanup','"free"'))},'executor:665-679','4',note='Reply success or already consumed/lost request followed by return; ReportTimeout covers still-in-flight requests.')
action('JobExecutorOutcomeReportException',['s','t'],['client[s][t].cleanup \\in {"report","reportWait"}'],{'client':C(('.cleanup','"free"'))},'executor:648-678','4',fault='reportError',note='Report exception/timeout is caught; it never bypasses normal resource release.')
action('JobExecutorFreeAfterExit',['s','t'],['client[s][t].cleanup = "free"'],{'rm':R(('.free','Reverse(rm[s].payload[t]) \\o @'),('.allocated[t]','<<>>'),('.releases[t]','@+1')),'client':C(('.cleanup','"pop"'))},'executor:676-679;rm:166-172;list:52-55','2,4',note='Uses retained payload; deliberately no allocated/token test that would conceal repeated free.')
action('JobExecutorRemoveProcess',['s','t'],['client[s][t].cleanup = "pop"'],{'client':C(('.handle','"none"'),('.cleanup','"event"'))},'executor:680-682','4')
action('JobExecutorJobCompletedEvent',['s','t'],['client[s][t].cleanup = "event"'],{'client':C(('.cleanup','"done"'))},'executor:684-688;event:54-84','4',note='Site-local completion event does not call the server scheduler. Explicit job identity is preserved.')
# Abort requests and heartbeat commands are identities derived from live registries.
for kind,name in [('Stop','ClientEngineAbortApp'),('HeartbeatStop','ClientEngineHeartbeatAbort')]:
 action(name,['s','t'],[msg(kind)+r' \in network'],{'network':consume(kind),'client':C(('.abortRequested','@ \\/ client[s][t].handle # "none"'),('.pendingAbort','@ \\/ client[s][t].handle = "pending"'),('.terminateRequested','@ \\/ (client[s][t].handle = "attached" /\\ client[s][t].logical = "STARTING")'),('.logical','client[s][t].logical'))},'engine:390-404;executor:497-534;executor:65-77','4',note='STOPPED retains handle/resources. STARTING pending handle records abort; started/stopped termination waits for grace.')
action('JobExecutorTerminateAfterGrace',['s','t'],['client[s][t].abortRequested','client[s][t].handle = "attached"','~client[s][t].terminateRequested'],{'client':C(('.terminateRequested','TRUE'))},'executor:581-601','4',note='10s bounded graceful wait before terminate; physical process exit remains separate.')
action('FederatedServerHeartbeatCleanup',['s','t'],['client[s][t].handle # "none"','~jobs[t[1]].serverRegistered','~jobs[t[1]].outcomeKey \\/ jobs[t[1]].serverFailed',msg('HeartbeatStop')+r' \notin network'],{'network':send('HeartbeatStop')},'fed:1004-1017;comm:621-646','2,4',fault='heartbeat',note='Outcome-map key protects normally completing jobs even when pending set is empty. Repeated heartbeat requests never free resources.')
action('ServerEngineReceiveOutcome',['s','t'],[msg('OutcomeOK')+r' \in network'],{'network':consume('OutcomeOK'),'jobs':J('t[1]',('.pending','@ \\ {s}'))},'runner:114-120','4',note='Idempotent discard for exact job/site. Receiver authentication and reporter classification are boundary assumptions.')
action('ServerEngineReceiveFailureOutcome',['s','t'],[msg('OutcomeFailed')+r' \in network'],{'network':consume('OutcomeFailed'),'jobs':J('t[1]',('.pending','IF jobs[t[1]].serverRegistered \\/ jobs[t[1]].running THEN {} ELSE @ \\ {s}'),('.outcomeKey','IF jobs[t[1]].serverRegistered \\/ jobs[t[1]].running THEN FALSE ELSE @'),('.serverFailed','@ \\/ jobs[t[1]].serverRegistered \\/ jobs[t[1]].running'),('.serverStop','@ \\/ jobs[t[1]].serverRegistered'))},'runner:114-120;runner:813-843','4',note='Authoritative failure bypasses the outcome barrier. Late failure after final removal does not resurrect a job.')
action('ServerChildExit',['j'],['jobs[j].serverAlive'],{'jobs':J('j',('.serverAlive','FALSE'))},'server:203-204','3,4')
action('ServerChildFailure',['j'],['jobs[j].serverAlive'],{'jobs':J('j',('.serverAlive','FALSE'),('.serverFailed','TRUE'))},'server:219-233','4',fault='childError')
action('ServerEngineObserveExit',['j'],['jobs[j].serverWaiter','jobs[j].serverRegistered','~jobs[j].serverAlive'],{'jobs':J('j',('.serverRegistered','FALSE'))},'server:203-234','3,4',note='Includes finite <=2s UPDATE_RUN_STATUS grace; process already exited.')
action('ServerEngineTerminateAfterGrace',['j'],['jobs[j].serverStop','jobs[j].serverSpawned','~jobs[j].serverTerminated'],{'jobs':J('j',('.serverTerminated','TRUE'))},'server:385-407','4',note='Captured local handle termination after grace; does not assert OS exit.')
action('ServerEngineRemoveAfterTerminate',['j'],['jobs[j].serverTerminated','jobs[j].serverRegistered'],{'jobs':J('j',('.serverRegistered','FALSE'))},'server:408-409','4',note='CR-2 boundary retained. No injected permanently ineffective SIGKILL or process-count invariant.')
# Supported admin status read/write/ack branches.
action('JobCommandAbortRead',['j'],['jobs[j].adminPC = "idle"'],{'jobs':J('j',('.adminRead','jobs[j].status'),('.adminPC','"read"'))},'cmd:1055-1061','3,4',fault='adminAbort')
action('JobCommandAbortPreRunWrite',['j'],['jobs[j].adminPC = "read"','jobs[j].adminRead \\in {"SUBMITTED","DISPATCHED"}'],{'jobs':J('j',('.status','"ABORTED"'),('.adminPC','"ackPreRun"'))},'cmd:1061-1063;store:459-481','3')
action('JobCommandAbortPreRunAcknowledge',['j'],['jobs[j].adminPC = "ackPreRun"'],{'jobs':J('j',('.abortAck','TRUE'),('.adminPC','"idle"'))},'cmd:1063-1066','3',note='Acknowledges the saved branch, without rereading status or sending process stop.')
action('JobCommandAbortAlreadyTerminal',['j'],['jobs[j].adminPC = "read"','jobs[j].adminRead \\in Terminal'],{'jobs':J('j',('.adminPC','"idle"'))},'cmd:1067-1070','4')
action('JobCommandAbortRunning',['j'],['jobs[j].adminPC = "read"','jobs[j].adminRead = "RUNNING"'],{'jobs':J('j',('.serverStop','@ \\/ jobs[j].serverRegistered'),('.adminPC','"markAborted"')),'network':r'network \cup (IF jobs[j].serverRegistered THEN {Msg("Stop",s,<<j,scheduler.issued[j]>>) : s \in jobs[j].deployed} ELSE {})'},'cmd:1071-1078;runner:374-413;runner:798-800','4')
action('JobRunnerMarkAborted',['j'],['jobs[j].adminPC = "markAborted"'],{'jobs':J('j',('.runAborted','@ \\/ jobs[j].running'),('.adminPC','"idle"'))},'runner:802-811','4',note='Only an existing running_jobs entry receives run_aborted; missing entry returns an error.')
# Completion thread holds saved job reference across archive and status publication.
action('JobRunnerSelectCompletion',['j'],['jobs[j].running','~jobs[j].serverRegistered','jobs[j].completion = "idle"'],{'jobs':J('j',('.completion','IF jobs[j].pending # {} /\\ ~jobs[j].runAborted /\\ ~jobs[j].serverFailed THEN "outcomeWait" ELSE "classify"'),('.pending','IF jobs[j].serverFailed THEN {} ELSE @'),('.outcomeKey','IF jobs[j].serverFailed THEN FALSE ELSE @'))},'runner:443-476','3,4')
action('JobRunnerOutcomesResolved',['j'],['jobs[j].completion = "outcomeWait"','jobs[j].pending = {} \\/ jobs[j].runAborted \\/ jobs[j].serverFailed'],{'jobs':J('j',('.completion','"classify"'))},'runner:451-476','3,4')
action('JobRunnerOutcomeGraceExpired',['j'],['jobs[j].completion = "outcomeWait"','jobs[j].pending # {}'],{'jobs':J('j',('.pending','{}'),('.completion','"classify"'))},'runner:466-480','3,4',fault='outcomeTimeout',note='Crossing the real OutcomeGrace (900s) deadline. No inference that clients have exited.')
action('JobRunnerClassifyCompletion',['j'],['jobs[j].completion = "classify"'],{'jobs':J('j',('.finishStatus','IF jobs[j].runAborted THEN "ABORTED" ELSE IF jobs[j].serverFailed THEN "FAILED" ELSE "COMPLETED"'),('.completion','"archive"')),'network':r'network \cup (IF jobs[j].serverFailed THEN {Msg("Stop",s,<<j,scheduler.issued[j]>>) : s \in jobs[j].deployed} ELSE {})'},'runner:482-496;runner:574-585','3,4',note='Completion retains a saved reference/status; failure requests client stop independently.')
action('JobRunnerArchiveSuccess',['j'],['jobs[j].completion = "archive"'],{'jobs':J('j',('.completion','"publish"'))},'runner:494-522','3,4')
action('JobRunnerArchiveException',['j'],['jobs[j].completion = "archive"'],{'jobs':J('j',('.archiveFailed','TRUE'),('.completion','"archiveRetry"'))},'runner:495-507','3,4',fault='archiveError',note='Retry yields to other jobs; contents omitted, error grace retained.')
action('JobRunnerRetryArchive',['j'],['jobs[j].completion = "archiveRetry"'],{'jobs':J('j',('.completion','"archive"'))},'runner:443-444;runner:501-507;runner:541','4,5')
action('JobRunnerArchiveGraceExpired',['j'],['jobs[j].archiveFailed','jobs[j].completion \\in {"archive","archiveRetry"}'],{'jobs':J('j',('.completion','"publish"'))},'runner:498-522','4,5',note='An archive call fails at/after the 60s grace. Reactive completion of prior error, not a newly injected independent fault.')
action('JobRunnerPublishTerminal',['j'],['jobs[j].completion = "publish"'],{'jobs':J('j',('.status','jobs[j].finishStatus'),('.terminalPublished','TRUE'),('.completion','"remove"'))},'runner:523-530;store:459-481','3')
action('JobRunnerTerminalStoreException',['j'],['jobs[j].completion = "publish"'],{'jobs':'jobs'},'runner:523-530','4,5',fault='storeError',note='Caught store error retries; finite injected errors do not kill completion service.')
action('JobRunnerRemoveCompleted',['j'],['jobs[j].completion = "remove"','jobs[j].running'],{'jobs':J('j',('.running','FALSE'),('.pending','{}'),('.outcomeKey','FALSE'),('.completedRemoved','TRUE'),('.completion','IF jobs[j].finishStatus = "ABORTED" THEN "abortedEvent" ELSE "completedEvent"'))},'runner:531-538','3,4',note='TV-3 missing-key race is not silently repaired: if running was removed by failure path this action is disabled; see PendingCompletionRemoval structural diagnostic, not a service-death model.')
action('DefaultJobSchedulerJobAbortedOnCompletion',['j'],['jobs[j].completion = "abortedEvent"'],{'jobs':J('j',('.completion','"completedEvent"')),'scheduler':S(('.scheduled','@ \\ {j}'))},'runner:536-537;sched:281-285;event:54-84','4',note='ABORTED then COMPLETED are two supported notifications for the same job.')
action('DefaultJobSchedulerJobCompleted',['j'],['jobs[j].completion = "completedEvent"'],{'jobs':J('j',('.completion','"done"')),'scheduler':S(('.scheduled','@ \\ {j}'))},'runner:538;sched:281-285;event:54-84','3,4')
action('TransportLoseMessage',['m'],['m \\in network'],{'network':r'network \ {m}'},'admin:307-339;server:1007-1008;executor:657-674','1,4,5',fault='loss',note='Ordinary request/reply loss, no forgery. Tokens and late messages are never reassociated.')
# Hold the RM lock through all expiry decrements/removals. No other RM
# operation can observe the internal zero-TTL but not-yet-returned phase.
for a in A:
 if 'rm' in a['updates'] and a['name']!='AutoCleanResourceManagerFinishExpiry':
  a['guards'].insert(0,'ResourceManagerUnlocked(s)')
header+=r'''\* auto_clean_resource_manager.py:105-116: scan and deallocation share one lock.
ResourceManagerUnlocked(s) ==
    \A t \in Tokens : rm[s].reserved[t] # <<>> => rm[s].ttl[t] > 0

'''
# Type domains keep all implementation PCs explicit and catch malformed traces.
invariants=r'''
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
 "failRemove","failStop","failStatus","failEvent","persistFailed"}
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
     /\ jobs[j].adminPC \in {"idle","read","ackPreRun","markAborted"}
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
'''
def invocation(a,prefix=''):
 return prefix+a['name']+('('+','.join(a['params'])+')' if a['params'] else '')
def quantified(a,call):
 domains={'s':'Sites','t':'Tokens','j':'Jobs','m':'network'}
 return (r'\E '+', '.join(p+' \\in '+domains[p] for p in a['params'])+' : '+call) if a['params'] else call

def write_base():
 out=header
 for a in A:
  out+='\\* Scenario '+a['scenario']+'. '+a['source']+'\n'
  if a['note']:out+='\\* '+a['note']+'\n'
  out+=invocation(a)+' ==\n'
  for g in a['guards']:out+='    \\* '+a['source']+'\n    /\\ '+g+'\n'
  for v,e in a['updates'].items():out+='    \\* '+a['source']+'\n    /\\ '+v+"' = "+e+'\n'
  unchanged=[v for v in V if v not in a['updates']]
  if unchanged:out+='    /\\ UNCHANGED <<'+','.join(unchanged)+'>>\n'
  out+='\n'
 out+='Next ==\n'+ '\n'.join('    \\/ '+quantified(a,invocation(a)) for a in A)+'\n\n'
 out+='Spec == Init /\\ [][Next]_vars\n\n'+invariants+'\n=============================================================================\n'
 (P/'base.tla').write_text(out)
 (P/'actions.json').write_text(json.dumps(A,indent=2)+'\n')

def constants(jobs=2,strict=False,maxjobs=2,minsites=1,attempts=11):
 return f'''CONSTANTS
 Jobs = {{{', '.join('"job-'+str(i)+'"' for i in range(1,jobs+1))}}}
 JobOrder <- ConfigJobOrder
 Sites = {{"site-1", "site-2"}}
 Pool <- ConfigPool
 RequiredSites = {{"site-1"}}
 MinSites = {minsites}
 StrictStart = {str(strict).upper()}
 MaxJobs = {maxjobs}
 MaxScheduleCount = 10
 MinScheduleInterval = 10
 MaxScheduleInterval = 600
 AttemptSlots = {attempts}
 ReservationTTL = 30
 OutcomeGrace = 900
 ArchiveGrace = 60
'''
# Config operators avoid relying on nonstandard sequence syntax in .cfg files.
header+=r'''ConfigJobOrder == IF "job-2" \in Jobs THEN <<"job-1","job-2">> ELSE <<"job-1">>
ConfigPool == <<0,1>>

'''

# Preserve the candidate scan before schedule_job's deferred metadata writes.
byname={a['name']:a for a in A}
byname['DefaultJobSchedulerEndPass']['updates']['scheduler']=S(('.pc','"persistFailed"'),('.returnTo','"idle"'))
byname['DefaultJobSchedulerExhausted']['updates']={'scheduler':S(('.count[Head(scheduler.candidates)]','@+1'),('.history[Head(scheduler.candidates)]','Append(@,"exceeded")'),('.blockedPending','@ \\cup {Head(scheduler.candidates)}'),('.candidates','Tail(@)'))}
byname['DefaultJobSchedulerUpdateHistory']['updates']['scheduler']=S(('.count[CurrentJob]','@+1'),('.history[CurrentJob]','Append(@,scheduler.result)'),('.cooldown[CurrentJob]','TRUE'),('.pc','IF scheduler.result="scheduled" THEN "persistFailed" ELSE "scan"'),('.returnTo','IF scheduler.result="scheduled" THEN "checkSubmitted" ELSE "idle"'),('.failedPending','IF scheduler.result="scheduled" THEN @ ELSE @ \\cup {CurrentJob}'),('.candidates','IF scheduler.result="scheduled" THEN @ ELSE Tail(@)'))
A.remove(byname['DefaultJobSchedulerPersistRetry'])
byname['DefaultJobSchedulerAdmissionException']['updates']['scheduler']=S(('.pc','"persistFailed"'),('.returnTo','"idle"'),('.candidates','<<>>'))
action('DefaultJobSchedulerPersistFailed',['j'],['scheduler.pc="persistFailed"','j \\in scheduler.failedPending'],{'scheduler':S(('.persisted[j]','scheduler.count[j]'),('.failedPending','@ \\ {j}'))},'sched:298-304','5',note='Deferred end-of-pass failed-job metadata write; successful store boundary.')
action('DefaultJobSchedulerPersistBlocked',['j'],['scheduler.pc="persistFailed"','scheduler.failedPending={}','j \\in scheduler.blockedPending'],{'scheduler':S(('.persisted[j]','scheduler.count[j]'),('.blockedPending','@ \\ {j}')),'jobs':J('j',('.status','"CANT_SCHEDULE"'))},'sched:305-310','5',note='Deferred blocked-job metadata/status processing; successful store boundary.')
action('DefaultJobSchedulerReturnPass',[],['scheduler.pc="persistFailed"','scheduler.failedPending={}','scheduler.blockedPending={}'],{'scheduler':S(('.pc','scheduler.returnTo'))},'sched:311','5')
action('JobRunnerMissingPendingOutcomes',[],['scheduler.pc="filterOutcomes"','~jobs[CurrentJob].outcomeKey'],{'scheduler':S(('.pc','"failRemove"'))},'runner:359-360;runner:713-719','2,4',note='Reactive KeyError path if authoritative failure removed the map during startup. Do not counter-bound an existing-state response.')
for name in ['StartJobProcessorRejectToken','CheckResourceProcessorUnavailable']:
 byname[name]['guards'].insert(0,'ResourceManagerUnlocked(s)')
for name in ['ClientDeploySuccess','ClientDeployError']:
 byname[name]['source'] = src('deploy:99-140;engine:462-480;runner:250-267')
# fail_run -> _stop_run sends actual client aborts as well as stopping the server.
byname['ServerEngineReceiveFailureOutcome']['updates']['network']=r'(network \ {Msg("OutcomeFailed",s,t)}) \cup (IF jobs[t[1]].serverRegistered THEN {Msg("Stop",v,t) : v \in jobs[t[1]].deployed} ELSE {})'

byname['DefaultJobSchedulerSkipBackoff']['guards'].append('scheduler.count[Head(scheduler.candidates)] < MaxScheduleCount')
byname['DefaultJobSchedulerExhausted']['updates']['scheduler']=S(('.count[Head(scheduler.candidates)]','@+1'),('.history[Head(scheduler.candidates)]','Append(@,"exceeded")'),('.cooldown[Head(scheduler.candidates)]','TRUE'),('.blockedPending','@ \\cup {Head(scheduler.candidates)}'),('.candidates','Tail(@)'))

# Trace round 1: source-verified blocking-call boundaries and exceptional locals.
byname['JobRunnerEvaluateStartReplies']['updates']['jobs']=J('CurrentJob',('.active','IF ReplySites(CurrentToken,"start","no") # {} \\/ jobs[CurrentJob].deployed = {} \\/ (StrictStart /\\ ~Policy(ReplySites(CurrentToken,"start","ok"))) THEN jobs[CurrentJob].deployed ELSE ReplySites(CurrentToken,"start","ok")'))
byname['JobRunnerEvaluateStartReplies']['note']='check_client_replies and strict participant errors raise before filtering the initialized deployed-site list (runner:313-358).'
action('JobCommandAbortRunningSend',['j'],['jobs[j].adminPC="read"','jobs[j].adminRead="RUNNING"','jobs[j].serverRegistered'],{'network':r'network \cup {Msg("Stop",s,<<j,scheduler.issued[j]>>) : s \in jobs[j].deployed}','jobs':J('j',('.adminPC','"stopWait"'))},'runner:374-413;cmd:1071-1078','3,4',note='Actual client stop send; blocking return and server abort are later.')
byname['JobCommandAbortRunning']['guards']=['jobs[j].adminPC="stopWait" \\/ (jobs[j].adminPC="read" /\\ jobs[j].adminRead="RUNNING" /\\ ~jobs[j].serverRegistered)']
del byname['JobCommandAbortRunning']['updates']['network']
action('JobRunnerFailureSendStop',[],['scheduler.pc="failStop"','jobs[CurrentJob].serverRegistered'],{'network':r'network \cup {Msg("Stop",s,CurrentToken) : s \in jobs[CurrentJob].deployed}','scheduler':S(('.pc','"failStopWait"'))},'runner:374-413;runner:719-720','2,4,5',note='Failure cleanup sends client stops before blocking return.')
byname['JobRunnerFailureStop']['guards']=['scheduler.pc="failStopWait" \\/ (scheduler.pc="failStop" /\\ ~jobs[CurrentJob].serverRegistered)']
del byname['JobRunnerFailureStop']['updates']['network']
invariants=invariants.replace('"failRemove","failStop","failStatus"','"failRemove","failStop","failStopWait","failStatus"').replace('{"idle","read","ackPreRun","markAborted"}','{"idle","read","ackPreRun","markAborted","stopWait"}')
# Capture abort ownership under its existing lock before the graceful wait.
for name in ['ClientEngineAbortApp','ClientEngineHeartbeatAbort']:
 byname[name]['updates']['client']=C(('.abortRequested','@ \\/ client[s][t].handle # "none"'))
 byname[name]['note']='At executor abort ownership update under lock, or ClientEngine no-op early return; termination and wait completion are separate.'
action('JobExecutorAbortStarting',['s','t'],['client[s][t].abortRequested','client[s][t].logical="STARTING"','client[s][t].handle # "none"','~client[s][t].terminateRequested','~client[s][t].pendingAbort'],{'client':C(('.pendingAbort','client[s][t].handle="pending"'),('.terminateRequested','client[s][t].handle="attached"'))},'executor:497-512;executor:65-77','4',note='STARTING branch invokes pending/attached handle termination after ownership flag update.')

if __name__=='__main__':
 write_base()
 (P/'base.cfg').write_text('SPECIFICATION Spec\n'+constants()+'INVARIANTS TypeOK ResourceConservation SchedulerCapacity RetryHistoryMatchesCount SingleSupportedStart WaitBeforeNormalFree\nCHECK_DEADLOCK FALSE\n')
 print('wrote base.tla/base.cfg;',len(A),'actions')
