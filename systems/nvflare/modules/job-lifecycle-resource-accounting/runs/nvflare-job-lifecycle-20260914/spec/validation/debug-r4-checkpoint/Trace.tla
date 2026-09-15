------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils
Base == INSTANCE base
VARIABLE l
tracevars == <<vars,l>>

JsonFile == IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
            ELSE "../traces/trace.ndjson"
RawTrace == ndJsonDeserialize(JsonFile)
Manifest == RawTrace[1]
TraceLog == SelectSeq(RawTrace,LAMBDA e :
    IF "tag" \in DOMAIN e THEN e.tag="trace" ELSE FALSE)
TraceJobs == SeqSet(Manifest.jobOrder)
TraceJobOrder == Manifest.jobOrder
TraceSites == SeqSet(Manifest.sites)
TracePool == Manifest.pool
TraceRequiredSites == SeqSet(Manifest.requiredSites)
TraceMinSites == Manifest.minSites
TraceStrictStart == Manifest.strictStart
TraceMaxJobs == Manifest.maxJobs
TraceMaxScheduleCount == Manifest.maxScheduleCount
TraceMinScheduleInterval == Manifest.minScheduleInterval
TraceMaxScheduleInterval == Manifest.maxScheduleInterval
TraceAttemptSlots == Manifest.attemptSlots
TraceReservationTTL == Manifest.reservationTTL
TraceOutcomeGrace == Manifest.outcomeGrace
TraceArchiveGrace == Manifest.archiveGrace

ManifestOK ==
 /\ Manifest.tag = "config"
 /\ Manifest.sourceRevision = "53ba7ee567468ea7971dad4faccef13c6cb35dc2"
 /\ Manifest.resourceManager = "ListResourceManager"
 /\ Manifest.resourceConsumer = "ListResourceConsumer"
 /\ Manifest.launcher = "ProcessJobLauncher"
 /\ Jobs # {} /\ "" \notin Jobs
 /\ Len(JobOrder) = Cardinality(Jobs)
 /\ Sites # {} /\ RequiredSites \subseteq Sites
 /\ Len(Manifest.sites)=Cardinality(Sites)
 /\ Len(Manifest.requiredSites)=Cardinality(RequiredSites)
 /\ MinSites \in 1..Cardinality(Sites)
 /\ MaxJobs > 0 /\ StrictStart \in BOOLEAN
 /\ MaxScheduleCount=10 /\ MinScheduleInterval=10 /\ MaxScheduleInterval=600
 /\ ReservationTTL=30 /\ OutcomeGrace=900 /\ ArchiveGrace=60
 /\ Len(Pool)=Cardinality(Units) /\ Len(Pool)>0
 /\ Manifest.demandPerJobSite=1
 /\ Manifest.attemptSlots > 0

\* Rows use actual UUID -> <<job, attempt>> aliases from the independent
\* instrumentation ledger. Reject absent/duplicate rows before indexing them.
RowsOK(q) ==
 /\ Len(q)=Cardinality(Tokens)
 /\ {<<q[i].job,q[i].attempt>> : i \in DOMAIN q}=Tokens
IndexRows(q) == [t \in Tokens |-> CHOOSE r \in SeqSet(q) :
                                r.job=t[1] /\ r.attempt=t[2]]
SetArrayOK(q) == Cardinality(SeqSet(q))=Len(q)
SchedulerSetArraysOK(x) == \A k \in {"scheduled","failedPending","blockedPending"} : SetArrayOK(x[k])
JobSetArraysOK(x) == \A j \in Jobs, k \in {"dispatch","deployed","active","pending"} : SetArrayOK(x[j][k])
SchedulerSnapshot(x) == [x EXCEPT !.scheduled=SeqSet(@),
                                 !.failedPending=SeqSet(@), !.blockedPending=SeqSet(@)]
JobSnapshots(x) == [j \in Jobs |-> [x[j] EXCEPT !.dispatch=SeqSet(@),
                        !.deployed=SeqSet(@), !.active=SeqSet(@), !.pending=SeqSet(@)]]
RMRowsOK(x) ==
 /\ DOMAIN x=Sites
 /\ \A s \in Sites :
     /\ DOMAIN x[s]={"free","tokens"}
     /\ RowsOK(x[s].tokens)
     /\ \A i \in DOMAIN x[s].tokens : DOMAIN x[s].tokens[i]=
            {"job","attempt","reserved","ttl","allocated","payload","releases"}
RMSnapshot(x) == [s \in Sites |->
    LET rows == IndexRows(x[s].tokens) IN
    [free |-> x[s].free,
     reserved |-> [t \in Tokens |-> rows[t].reserved],
     ttl |-> [t \in Tokens |-> rows[t].ttl],
     allocated |-> [t \in Tokens |-> rows[t].allocated],
     payload |-> [t \in Tokens |-> rows[t].payload],
     releases |-> [t \in Tokens |-> rows[t].releases]]]
ValueRowsOK(x) ==
 /\ DOMAIN x=Sites
 /\ \A s \in Sites :
     /\ RowsOK(x[s])
     /\ \A i \in DOMAIN x[s] : DOMAIN x[s][i]={"job","attempt","value"}
ValueSnapshot(x) == [s \in Sites |->
    LET rows == IndexRows(x[s]) IN [t \in Tokens |-> rows[t].value]]
StateFields == {"scheduler","jobs","rm","client","resourceEnv","rpc","network"}

\* Mandatory, non-vacuous checks. Each wrapper also requires the EXACT set of
\* fields modified by its base action. Nothing captured in post is ignored.
ValidatePostState(e) ==
 /\ DOMAIN e.post \subseteq StateFields
 /\ \A k \in DOMAIN e.post :
     CASE k="scheduler" ->
             /\ DOMAIN e.post.scheduler=DOMAIN scheduler'
             /\ SchedulerSetArraysOK(e.post.scheduler)
             /\ scheduler'=SchedulerSnapshot(e.post.scheduler)
       [] k="jobs" ->
             /\ DOMAIN e.post.jobs=Jobs
             /\ JobSetArraysOK(e.post.jobs)
             /\ jobs'=JobSnapshots(e.post.jobs)
       [] k="rm" -> /\ RMRowsOK(e.post.rm) /\ rm'=RMSnapshot(e.post.rm)
       [] k="client" -> /\ ValueRowsOK(e.post.client)
                          /\ client'=ValueSnapshot(e.post.client)
       [] k="resourceEnv" -> resourceEnv'=e.post.resourceEnv
       [] k="rpc" -> /\ ValueRowsOK(e.post.rpc) /\ rpc'=ValueSnapshot(e.post.rpc)
       [] k="network" ->
            /\ Cardinality(SeqSet(e.post.network))=Len(e.post.network)
            /\ network'=SeqSet(e.post.network)

\* nvflare/app_common/job_schedulers/job_scheduler.py:339-346; nvflare/private/fed/server/job_runner.py:641-658; Scenario 5.
TraceDefaultJobSchedulerBeginPass(e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerBeginPass"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerBeginPass
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_schedulers/job_scheduler.py:377-378; Scenario 5.
TraceDefaultJobSchedulerEndPass(e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerEndPass"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerEndPass
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_schedulers/job_scheduler.py:356-362; Scenario 5.
TraceDefaultJobSchedulerSkipBackoff(e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerSkipBackoff"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerSkipBackoff
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_schedulers/job_scheduler.py:356-362; Scenario 5.
TraceDefaultJobSchedulerBackoffElapsed(j,e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerBackoffElapsed"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds >= Backoff(j)
    /\ Base!DefaultJobSchedulerBackoffElapsed(j)
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_schedulers/job_scheduler.py:298-310; nvflare/app_common/job_schedulers/job_scheduler.py:347-354; Scenario 5.
TraceDefaultJobSchedulerExhausted(e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerExhausted"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerExhausted
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_schedulers/job_scheduler.py:104-199; nvflare/app_common/job_schedulers/job_scheduler.py:347-365; Scenario 1-5.
TraceDefaultJobSchedulerTryJob(e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerTryJob"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerTryJob
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1010-1024; Scenario 1-5.
TraceServerEngineCheckClientResources(e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineCheckClientResources"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineCheckClientResources
    /\ DOMAIN e.post={"network","rpc","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/scheduler_cmds.py:67-93; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:123-138; nvflare/app_common/resource_managers/list_resource_manager.py:57-75; Scenario 1,2,4,5.
TraceCheckResourceProcessorReserve(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="CheckResourceProcessorReserve"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!CheckResourceProcessorReserve(s,t)
    /\ DOMAIN e.post={"rm","network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/scheduler_cmds.py:83-93; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:123-138; nvflare/app_common/resource_managers/list_resource_manager.py:57-67; Scenario 1,4,5.
TraceCheckResourceProcessorUnavailable(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="CheckResourceProcessorUnavailable"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!CheckResourceProcessorUnavailable(s,t)
    /\ DOMAIN e.post={"network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339; Scenario 1,4,5.
TraceServerEngineReceiveCheckOK(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineReceiveCheckOK"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineReceiveCheckOK(s,t)
    /\ DOMAIN e.post={"network","rpc"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339; Scenario 1,4,5.
TraceServerEngineReceiveCheckNo(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineReceiveCheckNo"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineReceiveCheckNo(s,t)
    /\ DOMAIN e.post={"network","rpc"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339; Scenario 1,4,5.
TraceAdminCheckTimeout(t,e) ==
    /\ e.tag="trace"
    /\ e.event="AdminCheckTimeout"
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[t |-> t]
    /\ e.elapsedSeconds >= 15
    /\ Base!AdminCheckTimeout(t)
    /\ DOMAIN e.post={"rpc"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339; Scenario 1,4,5.
TraceServerEngineReceiveDeployOK(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineReceiveDeployOK"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineReceiveDeployOK(s,t)
    /\ DOMAIN e.post={"network","rpc"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339; Scenario 1,4,5.
TraceServerEngineReceiveDeployNo(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineReceiveDeployNo"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineReceiveDeployNo(s,t)
    /\ DOMAIN e.post={"network","rpc"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339; Scenario 1,4,5.
TraceAdminDeployTimeout(t,e) ==
    /\ e.tag="trace"
    /\ e.event="AdminDeployTimeout"
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[t |-> t]
    /\ e.elapsedSeconds >= 10
    /\ Base!AdminDeployTimeout(t)
    /\ DOMAIN e.post={"rpc"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339; Scenario 1,4,5.
TraceServerEngineReceiveStartOK(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineReceiveStartOK"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineReceiveStartOK(s,t)
    /\ DOMAIN e.post={"network","rpc"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339; Scenario 1,4,5.
TraceServerEngineReceiveStartNo(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineReceiveStartNo"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineReceiveStartNo(s,t)
    /\ DOMAIN e.post={"network","rpc"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339; Scenario 1,4,5.
TraceAdminStartTimeout(t,e) ==
    /\ e.tag="trace"
    /\ e.event="AdminStartTimeout"
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[t |-> t]
    /\ e.elapsedSeconds >= 20
    /\ Base!AdminStartTimeout(t)
    /\ DOMAIN e.post={"rpc"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1025-1041; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:286-339; Scenario 1,4,5.
TraceServerEngineReceiveCancelAck(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineReceiveCancelAck"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineReceiveCancelAck(s,t)
    /\ DOMAIN e.post={"network","rpc"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1023-1040; nvflare/private/fed/server/server_engine.py:1065-1083; nvflare/private/fed/server/admin.py:307-339; Scenario 1,4,5.
TraceAdminCancelTimeout(t,e) ==
    /\ e.tag="trace"
    /\ e.event="AdminCancelTimeout"
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[t |-> t]
    /\ e.elapsedSeconds >= 10
    /\ Base!AdminCancelTimeout(t)
    /\ DOMAIN e.post={"rpc"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_schedulers/job_scheduler.py:203-261; Scenario 1,2,5.
TraceDefaultJobSchedulerEvaluateResources(e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerEvaluateResources"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerEvaluateResources
    /\ DOMAIN e.post={"scheduler","jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_schedulers/job_scheduler.py:229-247; nvflare/private/fed/server/server_engine.py:1052-1066; Scenario 4,5.
TraceServerEngineCancelClientResources(e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineCancelClientResources"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineCancelClientResources
    /\ DOMAIN e.post={"network","rpc","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/scheduler_cmds.py:149-157; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:140-151; nvflare/app_common/resource_managers/list_resource_manager.py:52-55; Scenario 4,5.
TraceCancelResourceProcessorCancel(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="CancelResourceProcessorCancel"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!CancelResourceProcessorCancel(s,t)
    /\ DOMAIN e.post={"rm","network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1065-1066; nvflare/app_common/job_schedulers/job_scheduler.py:229-254; Scenario 5.
TraceDefaultJobSchedulerCancelReturned(e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerCancelReturned"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerCancelReturned
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_schedulers/job_scheduler.py:320-333; nvflare/app_common/job_schedulers/job_scheduler.py:364-375; Scenario 5.
TraceDefaultJobSchedulerUpdateHistory(e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerUpdateHistory"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerUpdateHistory
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_schedulers/job_scheduler.py:292-310; nvflare/app_common/job_schedulers/job_scheduler.py:364-369; Scenario 5.
TraceDefaultJobSchedulerAdmissionException(e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerAdmissionException"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerAdmissionException
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:102-113; Scenario 1,4,5.
TraceAutoCleanResourceManagerTick(s,e) ==
    /\ e.tag="trace"
    /\ e.event="AutoCleanResourceManagerTick"
    /\ s \in Sites
    /\ e.node=s
    /\ e.args=[s |-> s]
    /\ e.elapsedSeconds >= 1
    /\ Base!AutoCleanResourceManagerTick(s)
    /\ DOMAIN e.post={"rm"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:105-116; nvflare/app_common/resource_managers/list_resource_manager.py:52-55; Scenario 1,4,5.
TraceAutoCleanResourceManagerFinishExpiry(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="AutoCleanResourceManagerFinishExpiry"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!AutoCleanResourceManagerFinishExpiry(s,t)
    /\ DOMAIN e.post={"rm"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:660-669; Scenario 3.
TraceJobRunnerCheckSubmitted(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerCheckSubmitted"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerCheckSubmitted
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:173-248; Scenario 1-3.
TraceJobRunnerDeployJob(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerDeployJob"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerDeployJob
    /\ DOMAIN e.post={"network","rpc","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:194-209; nvflare/private/fed/server/job_runner.py:224-226; nvflare/private/fed/server/job_runner.py:713-728; Scenario 2,5.
TraceJobRunnerDeploymentException(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerDeploymentException"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerDeploymentException
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/training_cmds.py:99-140; nvflare/private/fed/client/client_engine.py:462-480; nvflare/private/fed/server/job_runner.py:250-267; Scenario 2.
TraceClientDeploySuccess(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ClientDeploySuccess"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ClientDeploySuccess(s,t)
    /\ DOMAIN e.post={"client","network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/training_cmds.py:99-140; nvflare/private/fed/client/client_engine.py:462-480; nvflare/private/fed/server/job_runner.py:250-267; Scenario 2.
TraceClientDeployError(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ClientDeployError"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ClientDeployError(s,t)
    /\ DOMAIN e.post={"network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:250-285; Scenario 2,3.
TraceJobRunnerEvaluateDeployment(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerEvaluateDeployment"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerEvaluateDeployment
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:669-670; nvflare/apis/impl/job_def_manager.py:459-481; Scenario 3.
TraceJobRunnerWriteDispatched(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerWriteDispatched"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerWriteDispatched
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:672-695; Scenario 3,5.
TraceJobRunnerPersistDeploy(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerPersistDeploy"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerPersistDeploy
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:697-707; Scenario 3.
TraceJobRunnerCheckDispatched(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerCheckDispatched"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerCheckDispatched
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:179-195; nvflare/private/fed/server/server_engine.py:314-316; Scenario 2,3.
TraceServerEngineSpawnJob(e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineSpawnJob"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineSpawnJob
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:321-326; Scenario 2-4.
TraceServerEngineRegisterJob(e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineRegisterJob"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineRegisterJob
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:328-329; Scenario 2-4.
TraceServerEngineInstallWaiter(e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineInstallWaiter"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineInstallWaiter
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:295-310; Scenario 1-4.
TraceJobRunnerSetPendingOutcomes(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerSetPendingOutcomes"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerSetPendingOutcomes
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:1068-1083; Scenario 1,2.
TraceServerEngineStartClientJob(e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineStartClientJob"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineStartClientJob
    /\ DOMAIN e.post={"network","rpc","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/admin.py:101-142; nvflare/private/fed/server/job_runner.py:313-358; Scenario 1,2.
TraceJobRunnerEvaluateStartReplies(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerEvaluateStartReplies"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerEvaluateStartReplies
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:355-364; Scenario 1,4.
TraceJobRunnerFilterPendingOutcomes(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerFilterPendingOutcomes"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerFilterPendingOutcomes
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:364-372; nvflare/app_common/job_schedulers/job_scheduler.py:275-280; nvflare/apis/utils/event.py:54-84; Scenario 1,3,4.
TraceDefaultJobSchedulerJobStarted(e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerJobStarted"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerJobStarted
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:709-710; Scenario 3.
TraceJobRunnerRegisterRunning(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerRegisterRunning"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerRegisterRunning
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:711-712; nvflare/apis/impl/job_def_manager.py:459-481; Scenario 3.
TraceJobRunnerWriteRunning(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerWriteRunning"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerWriteRunning
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:670-689; nvflare/private/fed/server/job_runner.py:711-713; Scenario 2,3,5.
TraceJobRunnerStartupStoreError(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerStartupStoreError"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerStartupStoreError
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:179-193; nvflare/private/fed/server/job_runner.py:304-306; Scenario 2.
TraceServerEngineStartupError(e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineStartupError"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineStartupError
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:713-719; Scenario 2,5.
TraceJobRunnerFailureRemove(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerFailureRemove"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerFailureRemove
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:719-720; Scenario 2,4,5.
TraceJobRunnerFailureStop(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerFailureStop"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerFailureStop
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:720-726; Scenario 2,5.
TraceJobRunnerFailureStatus(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerFailureStatus"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerFailureStatus
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:728-731; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84; Scenario 2,4,5.
TraceDefaultJobSchedulerJobAbortedOnStartFailure(e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerJobAbortedOnStartFailure"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerJobAbortedOnStartFailure
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/scheduler_cmds.py:114-118; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:153-164; Scenario 1,2,4.
TraceStartJobProcessorAllocate(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="StartJobProcessorAllocate"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!StartJobProcessorAllocate(s,t)
    /\ DOMAIN e.post={"rm","client","network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/resource_managers/auto_clean_resource_manager.py:156-163; nvflare/private/fed/client/scheduler_cmds.py:129-137; Scenario 1,4.
TraceStartJobProcessorRejectToken(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="StartJobProcessorRejectToken"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!StartJobProcessorRejectToken(s,t)
    /\ DOMAIN e.post={"client","network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/scheduler_cmds.py:119-121; nvflare/app_common/resource_consumers/list_resource_consumer.py:31-37; nvflare/app_common/resource_consumers/list_resource_consumer.py:49-52; Scenario 1.
TraceListResourceConsumerConsume(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ListResourceConsumerConsume"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ListResourceConsumerConsume(s,t)
    /\ DOMAIN e.post={"resourceEnv","client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_engine.py:357-379; Scenario 2.
TraceClientEngineStartAppCheck(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ClientEngineStartAppCheck"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ClientEngineStartAppCheck(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_engine.py:365-367; nvflare/private/fed/client/scheduler_cmds.py:122-137; Scenario 2.
TraceClientEngineStartAppReturnedError(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ClientEngineStartAppReturnedError"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ClientEngineStartAppReturnedError(s,t)
    /\ DOMAIN e.post={"client","network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:299-307; Scenario 1,2,4.
TraceJobExecutorRegisterPendingHandle(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorRegisterPendingHandle"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorRegisterPendingHandle(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/scheduler_cmds.py:119-133; nvflare/private/fed/client/client_executor.py:224-258; Scenario 2.
TraceJobExecutorPrepareException(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorPrepareException"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorPrepareException(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_launcher/process_launcher.py:66-78; Scenario 1.
TraceProcessJobLauncherSnapshotEnvironment(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ProcessJobLauncherSnapshotEnvironment"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ProcessJobLauncherSnapshotEnvironment(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_launcher/process_launcher.py:80-83; nvflare/private/fed/client/client_executor.py:309-311; Scenario 1,2.
TraceProcessJobLauncherSpawn(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ProcessJobLauncherSpawn"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ProcessJobLauncherSpawn(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_launcher/process_launcher.py:68-83; nvflare/private/fed/client/client_executor.py:308-316; Scenario 2.
TraceProcessJobLauncherSpawnException(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ProcessJobLauncherSpawnException"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ProcessJobLauncherSpawnException(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:60-63; nvflare/private/fed/client/client_executor.py:318-320; Scenario 1,2,4.
TracePendingJobHandleAttach(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="PendingJobHandleAttach"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!PendingJobHandleAttach(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:318-320; nvflare/private/fed/client/client_executor.py:505-512; Scenario 2,4.
TraceJobExecutorApplyPendingAbort(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorApplyPendingAbort"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorApplyPendingAbort(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:324-330; nvflare/apis/utils/event.py:54-84; Scenario 2.
TraceJobExecutorAfterJobLaunchEvent(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorAfterJobLaunchEvent"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorAfterJobLaunchEvent(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:330-334; Scenario 2,4.
TraceJobExecutorInstallCleanupWaiter(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorInstallCleanupWaiter"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorInstallCleanupWaiter(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:330-334; nvflare/private/fed/client/scheduler_cmds.py:129-133; Scenario 2.
TraceJobExecutorWaiterInstallationException(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorWaiterInstallationException"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorWaiterInstallationException(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/scheduler_cmds.py:129-137; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55; Scenario 2.
TraceStartJobProcessorRollback(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="StartJobProcessorRollback"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!StartJobProcessorRollback(s,t)
    /\ DOMAIN e.post={"rm","client","network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_engine.py:382; nvflare/private/fed/client/scheduler_cmds.py:135-137; Scenario 1,2.
TraceStartJobProcessorReplySuccess(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="StartJobProcessorReplySuccess"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!StartJobProcessorReplySuccess(s,t)
    /\ DOMAIN e.post={"client","network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:347-350; Scenario 4.
TraceJobExecutorNotifyStarted(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorNotifyStarted"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorNotifyStarted(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:347-350; nvflare/private/fed/client/client_engine.py:390-404; Scenario 4.
TraceJobExecutorNotifyStopped(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorNotifyStopped"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorNotifyStopped(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_launcher/process_launcher.py:51-58; nvflare/private/fed/client/client_executor.py:625-630; Scenario 2,4.
TraceClientChildExit(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ClientChildExit"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ClientChildExit(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:630-647; Scenario 2,4.
TraceClientChildFailure(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ClientChildFailure"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ClientChildFailure(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:625-647; Scenario 2,4.
TraceJobExecutorWaitChildExit(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorWaitChildExit"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorWaitChildExit(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:648-664; Scenario 4.
TraceJobExecutorReportOutcome(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorReportOutcome"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorReportOutcome(s,t)
    /\ DOMAIN e.post={"network","client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:665-679; Scenario 4.
TraceJobExecutorOutcomeReportReturned(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorOutcomeReportReturned"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorOutcomeReportReturned(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:648-678; Scenario 4.
TraceJobExecutorOutcomeReportException(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorOutcomeReportException"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorOutcomeReportException(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:676-679; nvflare/app_common/resource_managers/auto_clean_resource_manager.py:166-172; nvflare/app_common/resource_managers/list_resource_manager.py:52-55; Scenario 2,4.
TraceJobExecutorFreeAfterExit(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorFreeAfterExit"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorFreeAfterExit(s,t)
    /\ DOMAIN e.post={"rm","client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:680-682; Scenario 4.
TraceJobExecutorRemoveProcess(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorRemoveProcess"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorRemoveProcess(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:684-688; nvflare/apis/utils/event.py:54-84; Scenario 4.
TraceJobExecutorJobCompletedEvent(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorJobCompletedEvent"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorJobCompletedEvent(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_engine.py:390-404; nvflare/private/fed/client/client_executor.py:497-534; nvflare/private/fed/client/client_executor.py:65-77; Scenario 4.
TraceClientEngineAbortApp(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ClientEngineAbortApp"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ClientEngineAbortApp(s,t)
    /\ DOMAIN e.post={"network","client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_engine.py:390-404; nvflare/private/fed/client/client_executor.py:497-534; nvflare/private/fed/client/client_executor.py:65-77; Scenario 4.
TraceClientEngineHeartbeatAbort(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ClientEngineHeartbeatAbort"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ClientEngineHeartbeatAbort(s,t)
    /\ DOMAIN e.post={"network","client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:581-601; Scenario 4.
TraceJobExecutorTerminateAfterGrace(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorTerminateAfterGrace"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds >= 10
    /\ Base!JobExecutorTerminateAfterGrace(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/fed_server.py:1004-1017; nvflare/private/fed/client/communicator.py:621-646; Scenario 2,4.
TraceFederatedServerHeartbeatCleanup(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="FederatedServerHeartbeatCleanup"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!FederatedServerHeartbeatCleanup(s,t)
    /\ DOMAIN e.post={"network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/fed_server.py:938-956; nvflare/private/fed/server/job_runner.py:114-120; Scenario 4.
TraceServerEngineReceiveOutcome(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineReceiveOutcome"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineReceiveOutcome(s,t)
    /\ DOMAIN e.post={"network","jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/fed_server.py:938-956; nvflare/private/fed/server/job_runner.py:114-120; nvflare/private/fed/server/job_runner.py:813-843; Scenario 4.
TraceServerEngineReceiveFailureOutcome(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineReceiveFailureOutcome"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineReceiveFailureOutcome(s,t)
    /\ DOMAIN e.post={"network","jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:203-204; Scenario 3,4.
TraceServerChildExit(j,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerChildExit"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerChildExit(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:219-233; Scenario 4.
TraceServerChildFailure(j,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerChildFailure"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerChildFailure(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:203-234; Scenario 3,4.
TraceServerEngineObserveExit(j,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineObserveExit"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineObserveExit(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:385-407; Scenario 4.
TraceServerEngineTerminateAfterGrace(j,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineTerminateAfterGrace"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds >= 10
    /\ Base!ServerEngineTerminateAfterGrace(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:408-409; Scenario 4.
TraceServerEngineRemoveAfterTerminate(j,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineRemoveAfterTerminate"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineRemoveAfterTerminate(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_cmds.py:1055-1061; Scenario 3,4.
TraceJobCommandAbortRead(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobCommandAbortRead"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobCommandAbortRead(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_cmds.py:1061-1063; nvflare/apis/impl/job_def_manager.py:459-481; Scenario 3.
TraceJobCommandAbortPreRunWrite(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobCommandAbortPreRunWrite"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobCommandAbortPreRunWrite(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_cmds.py:1063-1066; Scenario 3.
TraceJobCommandAbortPreRunAcknowledge(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobCommandAbortPreRunAcknowledge"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobCommandAbortPreRunAcknowledge(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_cmds.py:1067-1070; Scenario 4.
TraceJobCommandAbortAlreadyTerminal(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobCommandAbortAlreadyTerminal"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobCommandAbortAlreadyTerminal(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_cmds.py:1071-1078; nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:798-800; Scenario 4.
TraceJobCommandAbortRunning(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobCommandAbortRunning"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobCommandAbortRunning(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:802-811; Scenario 4.
TraceJobRunnerMarkAborted(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerMarkAborted"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerMarkAborted(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:443-476; Scenario 3,4.
TraceJobRunnerSelectCompletion(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerSelectCompletion"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerSelectCompletion(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:451-476; Scenario 3,4.
TraceJobRunnerOutcomesResolved(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerOutcomesResolved"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerOutcomesResolved(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:466-480; Scenario 3,4.
TraceJobRunnerOutcomeGraceExpired(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerOutcomeGraceExpired"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds >= OutcomeGrace
    /\ Base!JobRunnerOutcomeGraceExpired(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:482-496; nvflare/private/fed/server/job_runner.py:574-585; Scenario 3,4.
TraceJobRunnerClassifyCompletion(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerClassifyCompletion"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerClassifyCompletion(j)
    /\ DOMAIN e.post={"jobs","network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:494-522; Scenario 3,4.
TraceJobRunnerArchiveSuccess(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerArchiveSuccess"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerArchiveSuccess(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:495-507; Scenario 3,4.
TraceJobRunnerArchiveException(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerArchiveException"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerArchiveException(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:443-444; nvflare/private/fed/server/job_runner.py:501-507; nvflare/private/fed/server/job_runner.py:541; Scenario 4,5.
TraceJobRunnerRetryArchive(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerRetryArchive"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerRetryArchive(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:498-522; Scenario 4,5.
TraceJobRunnerArchiveGraceExpired(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerArchiveGraceExpired"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds >= ArchiveGrace
    /\ Base!JobRunnerArchiveGraceExpired(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:523-530; nvflare/apis/impl/job_def_manager.py:459-481; Scenario 3.
TraceJobRunnerPublishTerminal(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerPublishTerminal"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerPublishTerminal(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:523-530; Scenario 4,5.
TraceJobRunnerTerminalStoreException(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerTerminalStoreException"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerTerminalStoreException(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:531-538; Scenario 3,4.
TraceJobRunnerRemoveCompleted(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerRemoveCompleted"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerRemoveCompleted(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:536-537; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84; Scenario 4.
TraceDefaultJobSchedulerJobAbortedOnCompletion(j,e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerJobAbortedOnCompletion"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerJobAbortedOnCompletion(j)
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:538; nvflare/app_common/job_schedulers/job_scheduler.py:281-285; nvflare/apis/utils/event.py:54-84; Scenario 3,4.
TraceDefaultJobSchedulerJobCompleted(j,e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerJobCompleted"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerJobCompleted(j)
    /\ DOMAIN e.post={"jobs","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/admin.py:307-339; nvflare/private/fed/server/server_engine.py:1007-1008; nvflare/private/fed/client/client_executor.py:657-674; Scenario 1,4,5.
TraceTransportLoseMessage(m,e) ==
    /\ e.tag="trace"
    /\ e.event="TransportLoseMessage"
    /\ m \in AllMessages
    /\ e.node="transport"
    /\ e.args=[m |-> m]
    /\ e.elapsedSeconds = 0
    /\ Base!TransportLoseMessage(m)
    /\ DOMAIN e.post={"network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_schedulers/job_scheduler.py:298-304; Scenario 5.
TraceDefaultJobSchedulerPersistFailed(j,e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerPersistFailed"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerPersistFailed(j)
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_schedulers/job_scheduler.py:305-310; Scenario 5.
TraceDefaultJobSchedulerPersistBlocked(j,e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerPersistBlocked"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerPersistBlocked(j)
    /\ DOMAIN e.post={"scheduler","jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/app_common/job_schedulers/job_scheduler.py:311; Scenario 5.
TraceDefaultJobSchedulerReturnPass(e) ==
    /\ e.tag="trace"
    /\ e.event="DefaultJobSchedulerReturnPass"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!DefaultJobSchedulerReturnPass
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:359-360; nvflare/private/fed/server/job_runner.py:713-719; Scenario 2,4.
TraceJobRunnerMissingPendingOutcomes(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerMissingPendingOutcomes"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerMissingPendingOutcomes
    /\ DOMAIN e.post={"scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_cmds.py:1071-1078; Scenario 3,4.
TraceJobCommandAbortRunningSend(j,e) ==
    /\ e.tag="trace"
    /\ e.event="JobCommandAbortRunningSend"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!JobCommandAbortRunningSend(j)
    /\ DOMAIN e.post={"network","jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/job_runner.py:374-413; nvflare/private/fed/server/job_runner.py:719-720; Scenario 2,4,5.
TraceJobRunnerFailureSendStop(e) ==
    /\ e.tag="trace"
    /\ e.event="JobRunnerFailureSendStop"
    /\ e.node="server"
    /\ DOMAIN e.args={}
    /\ e.elapsedSeconds = 0
    /\ Base!JobRunnerFailureSendStop
    /\ DOMAIN e.post={"network","scheduler"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:497-512; nvflare/private/fed/client/client_executor.py:65-77; Scenario 4.
TraceJobExecutorAbortStarting(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorAbortStarting"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorAbortStarting(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/fed_server.py:938-956; nvflare/private/fed/server/job_runner.py:813-843; Scenario 3,4.
TraceServerEngineReceiveAbortedOutcome(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineReceiveAbortedOutcome"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineReceiveAbortedOutcome(s,t)
    /\ DOMAIN e.post={"network","jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/fed_server.py:938-940; Scenario 4.
TraceServerEngineIgnoreOutcome(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineIgnoreOutcome"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineIgnoreOutcome(s,t)
    /\ DOMAIN e.post={"network"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/fed_server.py:1045-1094; nvflare/private/fed/server/job_runner.py:813-843; nvflare/private/fed/server/job_runner.py:114-120; Scenario 4.
TraceServerEngineResolveMissingOutcome(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineResolveMissingOutcome"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node="server"
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineResolveMissingOutcome(s,t)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/client/client_executor.py:630-647; Scenario 4.
TraceJobExecutorClassifyAbortedExit(s,t,e) ==
    /\ e.tag="trace"
    /\ e.event="JobExecutorClassifyAbortedExit"
    /\ s \in Sites
    /\ t \in Tokens
    /\ e.node=s
    /\ e.args=[s |-> s, t |-> t]
    /\ e.elapsedSeconds = 0
    /\ Base!JobExecutorClassifyAbortedExit(s,t)
    /\ DOMAIN e.post={"client"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:385-409; Scenario 4.
TraceServerEngineTerminateAfterExit(j,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineTerminateAfterExit"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineTerminateAfterExit(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

\* nvflare/private/fed/server/server_engine.py:361-409; Scenario 4.
TraceServerEngineTerminateAfterAbortCommandError(j,e) ==
    /\ e.tag="trace"
    /\ e.event="ServerEngineTerminateAfterAbortCommandError"
    /\ j \in Jobs
    /\ e.node="server"
    /\ e.args=[j |-> j]
    /\ e.elapsedSeconds = 0
    /\ Base!ServerEngineTerminateAfterAbortCommandError(j)
    /\ DOMAIN e.post={"jobs"}
    /\ ValidatePostState(e)
    /\ l'=l+1

MatchEvent(e) ==
    CASE e.event="DefaultJobSchedulerBeginPass" -> TraceDefaultJobSchedulerBeginPass(e)
      [] e.event="DefaultJobSchedulerEndPass" -> TraceDefaultJobSchedulerEndPass(e)
      [] e.event="DefaultJobSchedulerSkipBackoff" -> TraceDefaultJobSchedulerSkipBackoff(e)
      [] e.event="DefaultJobSchedulerBackoffElapsed" -> TraceDefaultJobSchedulerBackoffElapsed(e.args.j,e)
      [] e.event="DefaultJobSchedulerExhausted" -> TraceDefaultJobSchedulerExhausted(e)
      [] e.event="DefaultJobSchedulerTryJob" -> TraceDefaultJobSchedulerTryJob(e)
      [] e.event="ServerEngineCheckClientResources" -> TraceServerEngineCheckClientResources(e)
      [] e.event="CheckResourceProcessorReserve" -> TraceCheckResourceProcessorReserve(e.args.s,e.args.t,e)
      [] e.event="CheckResourceProcessorUnavailable" -> TraceCheckResourceProcessorUnavailable(e.args.s,e.args.t,e)
      [] e.event="ServerEngineReceiveCheckOK" -> TraceServerEngineReceiveCheckOK(e.args.s,e.args.t,e)
      [] e.event="ServerEngineReceiveCheckNo" -> TraceServerEngineReceiveCheckNo(e.args.s,e.args.t,e)
      [] e.event="AdminCheckTimeout" -> TraceAdminCheckTimeout(e.args.t,e)
      [] e.event="ServerEngineReceiveDeployOK" -> TraceServerEngineReceiveDeployOK(e.args.s,e.args.t,e)
      [] e.event="ServerEngineReceiveDeployNo" -> TraceServerEngineReceiveDeployNo(e.args.s,e.args.t,e)
      [] e.event="AdminDeployTimeout" -> TraceAdminDeployTimeout(e.args.t,e)
      [] e.event="ServerEngineReceiveStartOK" -> TraceServerEngineReceiveStartOK(e.args.s,e.args.t,e)
      [] e.event="ServerEngineReceiveStartNo" -> TraceServerEngineReceiveStartNo(e.args.s,e.args.t,e)
      [] e.event="AdminStartTimeout" -> TraceAdminStartTimeout(e.args.t,e)
      [] e.event="ServerEngineReceiveCancelAck" -> TraceServerEngineReceiveCancelAck(e.args.s,e.args.t,e)
      [] e.event="AdminCancelTimeout" -> TraceAdminCancelTimeout(e.args.t,e)
      [] e.event="DefaultJobSchedulerEvaluateResources" -> TraceDefaultJobSchedulerEvaluateResources(e)
      [] e.event="ServerEngineCancelClientResources" -> TraceServerEngineCancelClientResources(e)
      [] e.event="CancelResourceProcessorCancel" -> TraceCancelResourceProcessorCancel(e.args.s,e.args.t,e)
      [] e.event="DefaultJobSchedulerCancelReturned" -> TraceDefaultJobSchedulerCancelReturned(e)
      [] e.event="DefaultJobSchedulerUpdateHistory" -> TraceDefaultJobSchedulerUpdateHistory(e)
      [] e.event="DefaultJobSchedulerAdmissionException" -> TraceDefaultJobSchedulerAdmissionException(e)
      [] e.event="AutoCleanResourceManagerTick" -> TraceAutoCleanResourceManagerTick(e.args.s,e)
      [] e.event="AutoCleanResourceManagerFinishExpiry" -> TraceAutoCleanResourceManagerFinishExpiry(e.args.s,e.args.t,e)
      [] e.event="JobRunnerCheckSubmitted" -> TraceJobRunnerCheckSubmitted(e)
      [] e.event="JobRunnerDeployJob" -> TraceJobRunnerDeployJob(e)
      [] e.event="JobRunnerDeploymentException" -> TraceJobRunnerDeploymentException(e)
      [] e.event="ClientDeploySuccess" -> TraceClientDeploySuccess(e.args.s,e.args.t,e)
      [] e.event="ClientDeployError" -> TraceClientDeployError(e.args.s,e.args.t,e)
      [] e.event="JobRunnerEvaluateDeployment" -> TraceJobRunnerEvaluateDeployment(e)
      [] e.event="JobRunnerWriteDispatched" -> TraceJobRunnerWriteDispatched(e)
      [] e.event="JobRunnerPersistDeploy" -> TraceJobRunnerPersistDeploy(e)
      [] e.event="JobRunnerCheckDispatched" -> TraceJobRunnerCheckDispatched(e)
      [] e.event="ServerEngineSpawnJob" -> TraceServerEngineSpawnJob(e)
      [] e.event="ServerEngineRegisterJob" -> TraceServerEngineRegisterJob(e)
      [] e.event="ServerEngineInstallWaiter" -> TraceServerEngineInstallWaiter(e)
      [] e.event="JobRunnerSetPendingOutcomes" -> TraceJobRunnerSetPendingOutcomes(e)
      [] e.event="ServerEngineStartClientJob" -> TraceServerEngineStartClientJob(e)
      [] e.event="JobRunnerEvaluateStartReplies" -> TraceJobRunnerEvaluateStartReplies(e)
      [] e.event="JobRunnerFilterPendingOutcomes" -> TraceJobRunnerFilterPendingOutcomes(e)
      [] e.event="DefaultJobSchedulerJobStarted" -> TraceDefaultJobSchedulerJobStarted(e)
      [] e.event="JobRunnerRegisterRunning" -> TraceJobRunnerRegisterRunning(e)
      [] e.event="JobRunnerWriteRunning" -> TraceJobRunnerWriteRunning(e)
      [] e.event="JobRunnerStartupStoreError" -> TraceJobRunnerStartupStoreError(e)
      [] e.event="ServerEngineStartupError" -> TraceServerEngineStartupError(e)
      [] e.event="JobRunnerFailureRemove" -> TraceJobRunnerFailureRemove(e)
      [] e.event="JobRunnerFailureStop" -> TraceJobRunnerFailureStop(e)
      [] e.event="JobRunnerFailureStatus" -> TraceJobRunnerFailureStatus(e)
      [] e.event="DefaultJobSchedulerJobAbortedOnStartFailure" -> TraceDefaultJobSchedulerJobAbortedOnStartFailure(e)
      [] e.event="StartJobProcessorAllocate" -> TraceStartJobProcessorAllocate(e.args.s,e.args.t,e)
      [] e.event="StartJobProcessorRejectToken" -> TraceStartJobProcessorRejectToken(e.args.s,e.args.t,e)
      [] e.event="ListResourceConsumerConsume" -> TraceListResourceConsumerConsume(e.args.s,e.args.t,e)
      [] e.event="ClientEngineStartAppCheck" -> TraceClientEngineStartAppCheck(e.args.s,e.args.t,e)
      [] e.event="ClientEngineStartAppReturnedError" -> TraceClientEngineStartAppReturnedError(e.args.s,e.args.t,e)
      [] e.event="JobExecutorRegisterPendingHandle" -> TraceJobExecutorRegisterPendingHandle(e.args.s,e.args.t,e)
      [] e.event="JobExecutorPrepareException" -> TraceJobExecutorPrepareException(e.args.s,e.args.t,e)
      [] e.event="ProcessJobLauncherSnapshotEnvironment" -> TraceProcessJobLauncherSnapshotEnvironment(e.args.s,e.args.t,e)
      [] e.event="ProcessJobLauncherSpawn" -> TraceProcessJobLauncherSpawn(e.args.s,e.args.t,e)
      [] e.event="ProcessJobLauncherSpawnException" -> TraceProcessJobLauncherSpawnException(e.args.s,e.args.t,e)
      [] e.event="PendingJobHandleAttach" -> TracePendingJobHandleAttach(e.args.s,e.args.t,e)
      [] e.event="JobExecutorApplyPendingAbort" -> TraceJobExecutorApplyPendingAbort(e.args.s,e.args.t,e)
      [] e.event="JobExecutorAfterJobLaunchEvent" -> TraceJobExecutorAfterJobLaunchEvent(e.args.s,e.args.t,e)
      [] e.event="JobExecutorInstallCleanupWaiter" -> TraceJobExecutorInstallCleanupWaiter(e.args.s,e.args.t,e)
      [] e.event="JobExecutorWaiterInstallationException" -> TraceJobExecutorWaiterInstallationException(e.args.s,e.args.t,e)
      [] e.event="StartJobProcessorRollback" -> TraceStartJobProcessorRollback(e.args.s,e.args.t,e)
      [] e.event="StartJobProcessorReplySuccess" -> TraceStartJobProcessorReplySuccess(e.args.s,e.args.t,e)
      [] e.event="JobExecutorNotifyStarted" -> TraceJobExecutorNotifyStarted(e.args.s,e.args.t,e)
      [] e.event="JobExecutorNotifyStopped" -> TraceJobExecutorNotifyStopped(e.args.s,e.args.t,e)
      [] e.event="ClientChildExit" -> TraceClientChildExit(e.args.s,e.args.t,e)
      [] e.event="ClientChildFailure" -> TraceClientChildFailure(e.args.s,e.args.t,e)
      [] e.event="JobExecutorWaitChildExit" -> TraceJobExecutorWaitChildExit(e.args.s,e.args.t,e)
      [] e.event="JobExecutorReportOutcome" -> TraceJobExecutorReportOutcome(e.args.s,e.args.t,e)
      [] e.event="JobExecutorOutcomeReportReturned" -> TraceJobExecutorOutcomeReportReturned(e.args.s,e.args.t,e)
      [] e.event="JobExecutorOutcomeReportException" -> TraceJobExecutorOutcomeReportException(e.args.s,e.args.t,e)
      [] e.event="JobExecutorFreeAfterExit" -> TraceJobExecutorFreeAfterExit(e.args.s,e.args.t,e)
      [] e.event="JobExecutorRemoveProcess" -> TraceJobExecutorRemoveProcess(e.args.s,e.args.t,e)
      [] e.event="JobExecutorJobCompletedEvent" -> TraceJobExecutorJobCompletedEvent(e.args.s,e.args.t,e)
      [] e.event="ClientEngineAbortApp" -> TraceClientEngineAbortApp(e.args.s,e.args.t,e)
      [] e.event="ClientEngineHeartbeatAbort" -> TraceClientEngineHeartbeatAbort(e.args.s,e.args.t,e)
      [] e.event="JobExecutorTerminateAfterGrace" -> TraceJobExecutorTerminateAfterGrace(e.args.s,e.args.t,e)
      [] e.event="FederatedServerHeartbeatCleanup" -> TraceFederatedServerHeartbeatCleanup(e.args.s,e.args.t,e)
      [] e.event="ServerEngineReceiveOutcome" -> TraceServerEngineReceiveOutcome(e.args.s,e.args.t,e)
      [] e.event="ServerEngineReceiveFailureOutcome" -> TraceServerEngineReceiveFailureOutcome(e.args.s,e.args.t,e)
      [] e.event="ServerChildExit" -> TraceServerChildExit(e.args.j,e)
      [] e.event="ServerChildFailure" -> TraceServerChildFailure(e.args.j,e)
      [] e.event="ServerEngineObserveExit" -> TraceServerEngineObserveExit(e.args.j,e)
      [] e.event="ServerEngineTerminateAfterGrace" -> TraceServerEngineTerminateAfterGrace(e.args.j,e)
      [] e.event="ServerEngineRemoveAfterTerminate" -> TraceServerEngineRemoveAfterTerminate(e.args.j,e)
      [] e.event="JobCommandAbortRead" -> TraceJobCommandAbortRead(e.args.j,e)
      [] e.event="JobCommandAbortPreRunWrite" -> TraceJobCommandAbortPreRunWrite(e.args.j,e)
      [] e.event="JobCommandAbortPreRunAcknowledge" -> TraceJobCommandAbortPreRunAcknowledge(e.args.j,e)
      [] e.event="JobCommandAbortAlreadyTerminal" -> TraceJobCommandAbortAlreadyTerminal(e.args.j,e)
      [] e.event="JobCommandAbortRunning" -> TraceJobCommandAbortRunning(e.args.j,e)
      [] e.event="JobRunnerMarkAborted" -> TraceJobRunnerMarkAborted(e.args.j,e)
      [] e.event="JobRunnerSelectCompletion" -> TraceJobRunnerSelectCompletion(e.args.j,e)
      [] e.event="JobRunnerOutcomesResolved" -> TraceJobRunnerOutcomesResolved(e.args.j,e)
      [] e.event="JobRunnerOutcomeGraceExpired" -> TraceJobRunnerOutcomeGraceExpired(e.args.j,e)
      [] e.event="JobRunnerClassifyCompletion" -> TraceJobRunnerClassifyCompletion(e.args.j,e)
      [] e.event="JobRunnerArchiveSuccess" -> TraceJobRunnerArchiveSuccess(e.args.j,e)
      [] e.event="JobRunnerArchiveException" -> TraceJobRunnerArchiveException(e.args.j,e)
      [] e.event="JobRunnerRetryArchive" -> TraceJobRunnerRetryArchive(e.args.j,e)
      [] e.event="JobRunnerArchiveGraceExpired" -> TraceJobRunnerArchiveGraceExpired(e.args.j,e)
      [] e.event="JobRunnerPublishTerminal" -> TraceJobRunnerPublishTerminal(e.args.j,e)
      [] e.event="JobRunnerTerminalStoreException" -> TraceJobRunnerTerminalStoreException(e.args.j,e)
      [] e.event="JobRunnerRemoveCompleted" -> TraceJobRunnerRemoveCompleted(e.args.j,e)
      [] e.event="DefaultJobSchedulerJobAbortedOnCompletion" -> TraceDefaultJobSchedulerJobAbortedOnCompletion(e.args.j,e)
      [] e.event="DefaultJobSchedulerJobCompleted" -> TraceDefaultJobSchedulerJobCompleted(e.args.j,e)
      [] e.event="TransportLoseMessage" -> TraceTransportLoseMessage(e.args.m,e)
      [] e.event="DefaultJobSchedulerPersistFailed" -> TraceDefaultJobSchedulerPersistFailed(e.args.j,e)
      [] e.event="DefaultJobSchedulerPersistBlocked" -> TraceDefaultJobSchedulerPersistBlocked(e.args.j,e)
      [] e.event="DefaultJobSchedulerReturnPass" -> TraceDefaultJobSchedulerReturnPass(e)
      [] e.event="JobRunnerMissingPendingOutcomes" -> TraceJobRunnerMissingPendingOutcomes(e)
      [] e.event="JobCommandAbortRunningSend" -> TraceJobCommandAbortRunningSend(e.args.j,e)
      [] e.event="JobRunnerFailureSendStop" -> TraceJobRunnerFailureSendStop(e)
      [] e.event="JobExecutorAbortStarting" -> TraceJobExecutorAbortStarting(e.args.s,e.args.t,e)
      [] e.event="ServerEngineReceiveAbortedOutcome" -> TraceServerEngineReceiveAbortedOutcome(e.args.s,e.args.t,e)
      [] e.event="ServerEngineIgnoreOutcome" -> TraceServerEngineIgnoreOutcome(e.args.s,e.args.t,e)
      [] e.event="ServerEngineResolveMissingOutcome" -> TraceServerEngineResolveMissingOutcome(e.args.s,e.args.t,e)
      [] e.event="JobExecutorClassifyAbortedExit" -> TraceJobExecutorClassifyAbortedExit(e.args.s,e.args.t,e)
      [] e.event="ServerEngineTerminateAfterExit" -> TraceServerEngineTerminateAfterExit(e.args.j,e)
      [] e.event="ServerEngineTerminateAfterAbortCommandError" -> TraceServerEngineTerminateAfterAbortCommandError(e.args.j,e)
      [] OTHER -> FALSE

TraceInit ==
/\ l = 128
/\ rm = ( "site-1" :>
      [ free |-> <<0>>,
        reserved |->
            ( <<"job-2", 1>> :> <<>> @@
              <<"job-2", 2>> :> <<>> @@
              <<"job-2", 3>> :> <<>> @@
              <<"job-2", 4>> :> <<>> @@
              <<"job-2", 5>> :> <<>> @@
              <<"job-2", 6>> :> <<>> @@
              <<"job-2", 7>> :> <<>> @@
              <<"job-2", 8>> :> <<>> @@
              <<"job-2", 9>> :> <<>> @@
              <<"job-2", 10>> :> <<>> @@
              <<"job-2", 11>> :> <<>> @@
              <<"job-1", 1>> :> <<>> @@
              <<"job-1", 2>> :> <<>> @@
              <<"job-1", 3>> :> <<>> @@
              <<"job-1", 4>> :> <<>> @@
              <<"job-1", 5>> :> <<>> @@
              <<"job-1", 6>> :> <<>> @@
              <<"job-1", 7>> :> <<>> @@
              <<"job-1", 8>> :> <<>> @@
              <<"job-1", 9>> :> <<>> @@
              <<"job-1", 10>> :> <<>> @@
              <<"job-1", 11>> :> <<>> @@
              <<"job-3", 1>> :> <<>> @@
              <<"job-3", 2>> :> <<>> @@
              <<"job-3", 3>> :> <<>> @@
              <<"job-3", 4>> :> <<>> @@
              <<"job-3", 5>> :> <<>> @@
              <<"job-3", 6>> :> <<>> @@
              <<"job-3", 7>> :> <<>> @@
              <<"job-3", 8>> :> <<>> @@
              <<"job-3", 9>> :> <<>> @@
              <<"job-3", 10>> :> <<>> @@
              <<"job-3", 11>> :> <<>> ),
        ttl |->
            ( <<"job-2", 1>> :> 0 @@
              <<"job-2", 2>> :> 0 @@
              <<"job-2", 3>> :> 0 @@
              <<"job-2", 4>> :> 0 @@
              <<"job-2", 5>> :> 0 @@
              <<"job-2", 6>> :> 0 @@
              <<"job-2", 7>> :> 0 @@
              <<"job-2", 8>> :> 0 @@
              <<"job-2", 9>> :> 0 @@
              <<"job-2", 10>> :> 0 @@
              <<"job-2", 11>> :> 0 @@
              <<"job-1", 1>> :> 0 @@
              <<"job-1", 2>> :> 0 @@
              <<"job-1", 3>> :> 0 @@
              <<"job-1", 4>> :> 0 @@
              <<"job-1", 5>> :> 0 @@
              <<"job-1", 6>> :> 0 @@
              <<"job-1", 7>> :> 0 @@
              <<"job-1", 8>> :> 0 @@
              <<"job-1", 9>> :> 0 @@
              <<"job-1", 10>> :> 0 @@
              <<"job-1", 11>> :> 0 @@
              <<"job-3", 1>> :> 0 @@
              <<"job-3", 2>> :> 0 @@
              <<"job-3", 3>> :> 0 @@
              <<"job-3", 4>> :> 0 @@
              <<"job-3", 5>> :> 0 @@
              <<"job-3", 6>> :> 0 @@
              <<"job-3", 7>> :> 0 @@
              <<"job-3", 8>> :> 0 @@
              <<"job-3", 9>> :> 0 @@
              <<"job-3", 10>> :> 0 @@
              <<"job-3", 11>> :> 0 ),
        allocated |->
            ( <<"job-2", 1>> :> <<>> @@
              <<"job-2", 2>> :> <<>> @@
              <<"job-2", 3>> :> <<>> @@
              <<"job-2", 4>> :> <<>> @@
              <<"job-2", 5>> :> <<>> @@
              <<"job-2", 6>> :> <<>> @@
              <<"job-2", 7>> :> <<>> @@
              <<"job-2", 8>> :> <<>> @@
              <<"job-2", 9>> :> <<>> @@
              <<"job-2", 10>> :> <<>> @@
              <<"job-2", 11>> :> <<>> @@
              <<"job-1", 1>> :> <<>> @@
              <<"job-1", 2>> :> <<>> @@
              <<"job-1", 3>> :> <<>> @@
              <<"job-1", 4>> :> <<>> @@
              <<"job-1", 5>> :> <<>> @@
              <<"job-1", 6>> :> <<>> @@
              <<"job-1", 7>> :> <<>> @@
              <<"job-1", 8>> :> <<>> @@
              <<"job-1", 9>> :> <<>> @@
              <<"job-1", 10>> :> <<>> @@
              <<"job-1", 11>> :> <<>> @@
              <<"job-3", 1>> :> <<>> @@
              <<"job-3", 2>> :> <<>> @@
              <<"job-3", 3>> :> <<>> @@
              <<"job-3", 4>> :> <<>> @@
              <<"job-3", 5>> :> <<>> @@
              <<"job-3", 6>> :> <<>> @@
              <<"job-3", 7>> :> <<>> @@
              <<"job-3", 8>> :> <<>> @@
              <<"job-3", 9>> :> <<>> @@
              <<"job-3", 10>> :> <<>> @@
              <<"job-3", 11>> :> <<>> ),
        payload |->
            ( <<"job-2", 1>> :> <<>> @@
              <<"job-2", 2>> :> <<>> @@
              <<"job-2", 3>> :> <<>> @@
              <<"job-2", 4>> :> <<>> @@
              <<"job-2", 5>> :> <<>> @@
              <<"job-2", 6>> :> <<>> @@
              <<"job-2", 7>> :> <<>> @@
              <<"job-2", 8>> :> <<>> @@
              <<"job-2", 9>> :> <<>> @@
              <<"job-2", 10>> :> <<>> @@
              <<"job-2", 11>> :> <<>> @@
              <<"job-1", 1>> :> <<0>> @@
              <<"job-1", 2>> :> <<>> @@
              <<"job-1", 3>> :> <<>> @@
              <<"job-1", 4>> :> <<>> @@
              <<"job-1", 5>> :> <<>> @@
              <<"job-1", 6>> :> <<>> @@
              <<"job-1", 7>> :> <<>> @@
              <<"job-1", 8>> :> <<>> @@
              <<"job-1", 9>> :> <<>> @@
              <<"job-1", 10>> :> <<>> @@
              <<"job-1", 11>> :> <<>> @@
              <<"job-3", 1>> :> <<>> @@
              <<"job-3", 2>> :> <<>> @@
              <<"job-3", 3>> :> <<>> @@
              <<"job-3", 4>> :> <<>> @@
              <<"job-3", 5>> :> <<>> @@
              <<"job-3", 6>> :> <<>> @@
              <<"job-3", 7>> :> <<>> @@
              <<"job-3", 8>> :> <<>> @@
              <<"job-3", 9>> :> <<>> @@
              <<"job-3", 10>> :> <<>> @@
              <<"job-3", 11>> :> <<>> ),
        releases |->
            ( <<"job-2", 1>> :> 0 @@
              <<"job-2", 2>> :> 0 @@
              <<"job-2", 3>> :> 0 @@
              <<"job-2", 4>> :> 0 @@
              <<"job-2", 5>> :> 0 @@
              <<"job-2", 6>> :> 0 @@
              <<"job-2", 7>> :> 0 @@
              <<"job-2", 8>> :> 0 @@
              <<"job-2", 9>> :> 0 @@
              <<"job-2", 10>> :> 0 @@
              <<"job-2", 11>> :> 0 @@
              <<"job-1", 1>> :> 1 @@
              <<"job-1", 2>> :> 0 @@
              <<"job-1", 3>> :> 0 @@
              <<"job-1", 4>> :> 0 @@
              <<"job-1", 5>> :> 0 @@
              <<"job-1", 6>> :> 0 @@
              <<"job-1", 7>> :> 0 @@
              <<"job-1", 8>> :> 0 @@
              <<"job-1", 9>> :> 0 @@
              <<"job-1", 10>> :> 0 @@
              <<"job-1", 11>> :> 0 @@
              <<"job-3", 1>> :> 0 @@
              <<"job-3", 2>> :> 0 @@
              <<"job-3", 3>> :> 0 @@
              <<"job-3", 4>> :> 0 @@
              <<"job-3", 5>> :> 0 @@
              <<"job-3", 6>> :> 0 @@
              <<"job-3", 7>> :> 0 @@
              <<"job-3", 8>> :> 0 @@
              <<"job-3", 9>> :> 0 @@
              <<"job-3", 10>> :> 0 @@
              <<"job-3", 11>> :> 0 ) ] @@
  "site-2" :>
      [ free |-> <<0>>,
        reserved |->
            ( <<"job-2", 1>> :> <<>> @@
              <<"job-2", 2>> :> <<>> @@
              <<"job-2", 3>> :> <<>> @@
              <<"job-2", 4>> :> <<>> @@
              <<"job-2", 5>> :> <<>> @@
              <<"job-2", 6>> :> <<>> @@
              <<"job-2", 7>> :> <<>> @@
              <<"job-2", 8>> :> <<>> @@
              <<"job-2", 9>> :> <<>> @@
              <<"job-2", 10>> :> <<>> @@
              <<"job-2", 11>> :> <<>> @@
              <<"job-1", 1>> :> <<>> @@
              <<"job-1", 2>> :> <<>> @@
              <<"job-1", 3>> :> <<>> @@
              <<"job-1", 4>> :> <<>> @@
              <<"job-1", 5>> :> <<>> @@
              <<"job-1", 6>> :> <<>> @@
              <<"job-1", 7>> :> <<>> @@
              <<"job-1", 8>> :> <<>> @@
              <<"job-1", 9>> :> <<>> @@
              <<"job-1", 10>> :> <<>> @@
              <<"job-1", 11>> :> <<>> @@
              <<"job-3", 1>> :> <<>> @@
              <<"job-3", 2>> :> <<>> @@
              <<"job-3", 3>> :> <<>> @@
              <<"job-3", 4>> :> <<>> @@
              <<"job-3", 5>> :> <<>> @@
              <<"job-3", 6>> :> <<>> @@
              <<"job-3", 7>> :> <<>> @@
              <<"job-3", 8>> :> <<>> @@
              <<"job-3", 9>> :> <<>> @@
              <<"job-3", 10>> :> <<>> @@
              <<"job-3", 11>> :> <<>> ),
        ttl |->
            ( <<"job-2", 1>> :> 0 @@
              <<"job-2", 2>> :> 0 @@
              <<"job-2", 3>> :> 0 @@
              <<"job-2", 4>> :> 0 @@
              <<"job-2", 5>> :> 0 @@
              <<"job-2", 6>> :> 0 @@
              <<"job-2", 7>> :> 0 @@
              <<"job-2", 8>> :> 0 @@
              <<"job-2", 9>> :> 0 @@
              <<"job-2", 10>> :> 0 @@
              <<"job-2", 11>> :> 0 @@
              <<"job-1", 1>> :> 0 @@
              <<"job-1", 2>> :> 0 @@
              <<"job-1", 3>> :> 0 @@
              <<"job-1", 4>> :> 0 @@
              <<"job-1", 5>> :> 0 @@
              <<"job-1", 6>> :> 0 @@
              <<"job-1", 7>> :> 0 @@
              <<"job-1", 8>> :> 0 @@
              <<"job-1", 9>> :> 0 @@
              <<"job-1", 10>> :> 0 @@
              <<"job-1", 11>> :> 0 @@
              <<"job-3", 1>> :> 0 @@
              <<"job-3", 2>> :> 0 @@
              <<"job-3", 3>> :> 0 @@
              <<"job-3", 4>> :> 0 @@
              <<"job-3", 5>> :> 0 @@
              <<"job-3", 6>> :> 0 @@
              <<"job-3", 7>> :> 0 @@
              <<"job-3", 8>> :> 0 @@
              <<"job-3", 9>> :> 0 @@
              <<"job-3", 10>> :> 0 @@
              <<"job-3", 11>> :> 0 ),
        allocated |->
            ( <<"job-2", 1>> :> <<>> @@
              <<"job-2", 2>> :> <<>> @@
              <<"job-2", 3>> :> <<>> @@
              <<"job-2", 4>> :> <<>> @@
              <<"job-2", 5>> :> <<>> @@
              <<"job-2", 6>> :> <<>> @@
              <<"job-2", 7>> :> <<>> @@
              <<"job-2", 8>> :> <<>> @@
              <<"job-2", 9>> :> <<>> @@
              <<"job-2", 10>> :> <<>> @@
              <<"job-2", 11>> :> <<>> @@
              <<"job-1", 1>> :> <<>> @@
              <<"job-1", 2>> :> <<>> @@
              <<"job-1", 3>> :> <<>> @@
              <<"job-1", 4>> :> <<>> @@
              <<"job-1", 5>> :> <<>> @@
              <<"job-1", 6>> :> <<>> @@
              <<"job-1", 7>> :> <<>> @@
              <<"job-1", 8>> :> <<>> @@
              <<"job-1", 9>> :> <<>> @@
              <<"job-1", 10>> :> <<>> @@
              <<"job-1", 11>> :> <<>> @@
              <<"job-3", 1>> :> <<>> @@
              <<"job-3", 2>> :> <<>> @@
              <<"job-3", 3>> :> <<>> @@
              <<"job-3", 4>> :> <<>> @@
              <<"job-3", 5>> :> <<>> @@
              <<"job-3", 6>> :> <<>> @@
              <<"job-3", 7>> :> <<>> @@
              <<"job-3", 8>> :> <<>> @@
              <<"job-3", 9>> :> <<>> @@
              <<"job-3", 10>> :> <<>> @@
              <<"job-3", 11>> :> <<>> ),
        payload |->
            ( <<"job-2", 1>> :> <<>> @@
              <<"job-2", 2>> :> <<>> @@
              <<"job-2", 3>> :> <<>> @@
              <<"job-2", 4>> :> <<>> @@
              <<"job-2", 5>> :> <<>> @@
              <<"job-2", 6>> :> <<>> @@
              <<"job-2", 7>> :> <<>> @@
              <<"job-2", 8>> :> <<>> @@
              <<"job-2", 9>> :> <<>> @@
              <<"job-2", 10>> :> <<>> @@
              <<"job-2", 11>> :> <<>> @@
              <<"job-1", 1>> :> <<0>> @@
              <<"job-1", 2>> :> <<>> @@
              <<"job-1", 3>> :> <<>> @@
              <<"job-1", 4>> :> <<>> @@
              <<"job-1", 5>> :> <<>> @@
              <<"job-1", 6>> :> <<>> @@
              <<"job-1", 7>> :> <<>> @@
              <<"job-1", 8>> :> <<>> @@
              <<"job-1", 9>> :> <<>> @@
              <<"job-1", 10>> :> <<>> @@
              <<"job-1", 11>> :> <<>> @@
              <<"job-3", 1>> :> <<>> @@
              <<"job-3", 2>> :> <<>> @@
              <<"job-3", 3>> :> <<>> @@
              <<"job-3", 4>> :> <<>> @@
              <<"job-3", 5>> :> <<>> @@
              <<"job-3", 6>> :> <<>> @@
              <<"job-3", 7>> :> <<>> @@
              <<"job-3", 8>> :> <<>> @@
              <<"job-3", 9>> :> <<>> @@
              <<"job-3", 10>> :> <<>> @@
              <<"job-3", 11>> :> <<>> ),
        releases |->
            ( <<"job-2", 1>> :> 0 @@
              <<"job-2", 2>> :> 0 @@
              <<"job-2", 3>> :> 0 @@
              <<"job-2", 4>> :> 0 @@
              <<"job-2", 5>> :> 0 @@
              <<"job-2", 6>> :> 0 @@
              <<"job-2", 7>> :> 0 @@
              <<"job-2", 8>> :> 0 @@
              <<"job-2", 9>> :> 0 @@
              <<"job-2", 10>> :> 0 @@
              <<"job-2", 11>> :> 0 @@
              <<"job-1", 1>> :> 1 @@
              <<"job-1", 2>> :> 0 @@
              <<"job-1", 3>> :> 0 @@
              <<"job-1", 4>> :> 0 @@
              <<"job-1", 5>> :> 0 @@
              <<"job-1", 6>> :> 0 @@
              <<"job-1", 7>> :> 0 @@
              <<"job-1", 8>> :> 0 @@
              <<"job-1", 9>> :> 0 @@
              <<"job-1", 10>> :> 0 @@
              <<"job-1", 11>> :> 0 @@
              <<"job-3", 1>> :> 0 @@
              <<"job-3", 2>> :> 0 @@
              <<"job-3", 3>> :> 0 @@
              <<"job-3", 4>> :> 0 @@
              <<"job-3", 5>> :> 0 @@
              <<"job-3", 6>> :> 0 @@
              <<"job-3", 7>> :> 0 @@
              <<"job-3", 8>> :> 0 @@
              <<"job-3", 9>> :> 0 @@
              <<"job-3", 10>> :> 0 @@
              <<"job-3", 11>> :> 0 ) ] )
/\ network = {}
/\ resourceEnv = ("site-1" :> <<0>> @@ "site-2" :> <<0>>)
/\ rpc = ( "site-1" :>
      ( <<"job-2", 1>> :>
            [ check |-> "no",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 2>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 3>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 4>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 5>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 6>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 7>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 8>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 9>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 10>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 11>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 1>> :>
            [ check |-> "ok",
              deploy |-> "ok",
              start |-> "ok",
              cancel |-> "idle" ] @@
        <<"job-1", 2>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 3>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 4>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 5>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 6>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 7>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 8>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 9>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 10>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 11>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 1>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 2>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 3>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 4>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 5>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 6>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 7>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 8>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 9>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 10>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 11>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] ) @@
  "site-2" :>
      ( <<"job-2", 1>> :>
            [ check |-> "no",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 2>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 3>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 4>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 5>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 6>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 7>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 8>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 9>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 10>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-2", 11>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 1>> :>
            [ check |-> "ok",
              deploy |-> "ok",
              start |-> "ok",
              cancel |-> "idle" ] @@
        <<"job-1", 2>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 3>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 4>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 5>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 6>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 7>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 8>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 9>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 10>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-1", 11>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 1>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 2>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 3>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 4>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 5>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 6>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 7>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 8>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 9>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 10>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] @@
        <<"job-3", 11>> :>
            [ check |-> "idle",
              deploy |-> "idle",
              start |-> "idle",
              cancel |-> "idle" ] ) )
/\ scheduler = [ scheduled |-> {"job-1"},
  failedPending |-> {},
  blockedPending |-> {},
  pc |-> "idle",
  current |-> "job-2",
  candidates |-> <<>>,
  issued |-> ("job-2" :> 1 @@ "job-1" :> 1 @@ "job-3" :> 0),
  count |-> ("job-2" :> 1 @@ "job-1" :> 1 @@ "job-3" :> 0),
  persisted |-> ("job-2" :> 1 @@ "job-1" :> 1 @@ "job-3" :> 0),
  history |->
      ( "job-2" :> <<"no_resource">> @@
        "job-1" :> <<"scheduled">> @@
        "job-3" :> <<>> ),
  cooldown |-> ("job-2" :> TRUE @@ "job-1" :> TRUE @@ "job-3" :> FALSE),
  considered |-> ("job-2" :> 1 @@ "job-1" :> 1 @@ "job-3" :> 0),
  result |-> "no_resource",
  returnTo |-> "idle" ]
/\ jobs = ( "job-2" :>
      [ dispatch |-> {},
        deployed |-> {},
        active |-> {},
        pending |-> {},
        status |-> "SUBMITTED",
        checked |-> "SUBMITTED",
        outcomeKey |-> FALSE,
        serverAlive |-> FALSE,
        serverSpawned |-> FALSE,
        serverRegistered |-> FALSE,
        serverWaiter |-> FALSE,
        serverFailed |-> FALSE,
        serverAborted |-> FALSE,
        serverStop |-> FALSE,
        serverTerminated |-> FALSE,
        running |-> FALSE,
        runAborted |-> FALSE,
        abortAck |-> FALSE,
        adminPC |-> "idle",
        adminRead |-> "SUBMITTED",
        completion |-> "idle",
        finishStatus |-> "COMPLETED",
        archiveFailed |-> FALSE,
        terminalPublished |-> FALSE,
        resurrected |-> FALSE,
        completedRemoved |-> FALSE ] @@
  "job-1" :>
      [ dispatch |-> {"site-1", "site-2"},
        deployed |-> {"site-1", "site-2"},
        active |-> {"site-1", "site-2"},
        pending |-> {},
        status |-> "RUNNING",
        checked |-> "DISPATCHED",
        outcomeKey |-> TRUE,
        serverAlive |-> FALSE,
        serverSpawned |-> TRUE,
        serverRegistered |-> FALSE,
        serverWaiter |-> TRUE,
        serverFailed |-> FALSE,
        serverAborted |-> FALSE,
        serverStop |-> TRUE,
        serverTerminated |-> TRUE,
        running |-> TRUE,
        runAborted |-> TRUE,
        abortAck |-> FALSE,
        adminPC |-> "idle",
        adminRead |-> "RUNNING",
        completion |-> "idle",
        finishStatus |-> "COMPLETED",
        archiveFailed |-> FALSE,
        terminalPublished |-> FALSE,
        resurrected |-> FALSE,
        completedRemoved |-> FALSE ] @@
  "job-3" :>
      [ dispatch |-> {},
        deployed |-> {},
        active |-> {},
        pending |-> {},
        status |-> "ABORTED",
        checked |-> "SUBMITTED",
        outcomeKey |-> FALSE,
        serverAlive |-> FALSE,
        serverSpawned |-> FALSE,
        serverRegistered |-> FALSE,
        serverWaiter |-> FALSE,
        serverFailed |-> FALSE,
        serverAborted |-> FALSE,
        serverStop |-> FALSE,
        serverTerminated |-> FALSE,
        running |-> FALSE,
        runAborted |-> FALSE,
        abortAck |-> TRUE,
        adminPC |-> "idle",
        adminRead |-> "ABORTED",
        completion |-> "idle",
        finishStatus |-> "COMPLETED",
        archiveFailed |-> FALSE,
        terminalPublished |-> FALSE,
        resurrected |-> FALSE,
        completedRemoved |-> FALSE ] )
/\ client = ( "site-1" :>
      ( <<"job-2", 1>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 2>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 3>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 4>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 5>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 6>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 7>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 8>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 9>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 10>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 11>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 1>> :>
            [ deployed |-> TRUE,
              pc |-> "returned",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> TRUE,
              binding |-> <<0>>,
              waiter |-> TRUE,
              cleanup |-> "done",
              logical |-> "STOPPED",
              abortRequested |-> TRUE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> TRUE,
              exitObserved |-> TRUE,
              exitCode |-> "ok" ] @@
        <<"job-1", 2>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 3>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 4>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 5>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 6>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 7>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 8>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 9>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 10>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 11>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 1>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 2>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 3>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 4>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 5>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 6>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 7>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 8>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 9>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 10>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 11>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] ) @@
  "site-2" :>
      ( <<"job-2", 1>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 2>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 3>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 4>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 5>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 6>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 7>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 8>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 9>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 10>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-2", 11>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 1>> :>
            [ deployed |-> TRUE,
              pc |-> "returned",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> TRUE,
              binding |-> <<0>>,
              waiter |-> TRUE,
              cleanup |-> "done",
              logical |-> "STOPPED",
              abortRequested |-> TRUE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> TRUE,
              exitObserved |-> TRUE,
              exitCode |-> "ok" ] @@
        <<"job-1", 2>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 3>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 4>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 5>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 6>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 7>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 8>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 9>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 10>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-1", 11>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 1>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 2>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 3>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 4>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 5>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 6>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 7>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 8>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 9>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 10>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] @@
        <<"job-3", 11>> :>
            [ deployed |-> FALSE,
              pc |-> "idle",
              handle |-> "none",
              alive |-> FALSE,
              spawned |-> FALSE,
              binding |-> <<>>,
              waiter |-> FALSE,
              cleanup |-> "none",
              logical |-> "NOT_STARTED",
              abortRequested |-> FALSE,
              terminateRequested |-> FALSE,
              pendingAbort |-> FALSE,
              attached |-> FALSE,
              exitObserved |-> FALSE,
              exitCode |-> "ok" ] ) )
\* All semantic steps have hook points. No silent action can invent execution
\* or consume traffic. Unknown/missing events fail rather than repairing state.
TraceNext ==
    \/ /\ l <= Len(TraceLog) /\ MatchEvent(TraceLog[l])
    \/ /\ l > Len(TraceLog) /\ UNCHANGED tracevars
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(TraceNext)
TraceMatched == <>(l > Len(TraceLog))
=============================================================================
