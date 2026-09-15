from pathlib import Path
import importlib.util
P=Path(__file__).resolve().parent
sp=importlib.util.spec_from_file_location('gen',P/'generate.py');g=importlib.util.module_from_spec(sp);sp.loader.exec_module(g)
A=g.A
server_prefixes=('ServerEngine','DefaultJobScheduler','JobRunner','JobCommand','Admin','FederatedServer','ServerChild')
def node(a):
 if a['name']=='TransportLoseMessage':return '"transport"'
 if a['name'].startswith(server_prefixes):return '"server"'
 return 's'
def elapsed(a):
 n=a['name']
 return {'AdminCheckTimeout':'15','AdminDeployTimeout':'10','AdminStartTimeout':'20','AdminCancelTimeout':'10','DefaultJobSchedulerBackoffElapsed':'Backoff(j)','AutoCleanResourceManagerTick':'1','JobExecutorTerminateAfterGrace':'10','ServerEngineTerminateAfterGrace':'10','JobRunnerOutcomeGraceExpired':'OutcomeGrace','JobRunnerArchiveGraceExpired':'ArchiveGrace'}.get(n,'0')
head=r'''------------------------------ MODULE Trace ------------------------------
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

'''
out=head
for a in A:
 args=a['params']+['e']
 out+='\\* '+a['source']+'; Scenario '+a['scenario']+'.\n'
 out+='Trace'+a['name']+'('+','.join(args)+') ==\n'
 out+='    /\\ e.tag="trace"\n    /\\ e.event="'+a['name']+'"\n'
 dom={'s':'Sites','t':'Tokens','j':'Jobs','m':'AllMessages'}
 for p in a['params']:out+='    /\\ '+p+' \\in '+dom[p]+'\n'
 out+='    /\\ e.node='+node(a)+'\n'
 if a['params']:out+='    /\\ e.args=['+', '.join(p+' |-> '+p for p in a['params'])+']\n'
 else:out+='    /\\ DOMAIN e.args={}\n'
 out+='    /\\ e.elapsedSeconds '+('=' if elapsed(a)=='0' else '>=')+' '+elapsed(a)+'\n'
 out+='    /\\ '+g.invocation(a,'Base!')+'\n'
 out+='    /\\ DOMAIN e.post={'+','.join('"'+v+'"' for v in a['updates'])+'}\n'
 out+='    /\\ ValidatePostState(e)\n    /\\ l\'=l+1\n\n'
out+='MatchEvent(e) ==\n'
for i,a in enumerate(A):
 call='Trace'+a['name']+'('+','.join(['e.args.'+p for p in a['params']]+['e'])+')'
 out+=('    CASE ' if i==0 else '      [] ')+'e.event="'+a['name']+'" -> '+call+'\n'
out+='      [] OTHER -> FALSE\n\n'
out+=r'''TraceInit == /\ ManifestOK /\ Len(TraceLog)>0 /\ Base!Init /\ l=1
\* All semantic steps have hook points. No silent action can invent execution
\* or consume traffic. Unknown/missing events fail rather than repairing state.
TraceNext ==
    \/ /\ l <= Len(TraceLog) /\ MatchEvent(TraceLog[l])
    \/ /\ l > Len(TraceLog) /\ UNCHANGED tracevars
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(TraceNext)
TraceMatched == <>(l > Len(TraceLog))
=============================================================================
'''
(P/'Trace.tla').write_text(out)
constants=['Jobs','JobOrder','Sites','Pool','RequiredSites','MinSites','StrictStart','MaxJobs','MaxScheduleCount','MinScheduleInterval','MaxScheduleInterval','AttemptSlots','ReservationTTL','OutcomeGrace','ArchiveGrace']
cfg='SPECIFICATION TraceSpec\nCONSTANTS\n'+''.join(' '+c+' <- Trace'+c+'\n' for c in constants)
cfg+='\nINVARIANTS TypeOK ResourceConservation SchedulerCapacity RetryHistoryMatchesCount SingleSupportedStart WaitBeforeNormalFree\nPROPERTIES TraceMatched\nCHECK_DEADLOCK FALSE\n'
(P/'Trace.cfg').write_text(cfg)
(P/'trace-actions.json').write_text(__import__('json').dumps([{**a,'node':node(a),'minimumElapsedSeconds':elapsed(a)} for a in A],indent=2)+'\n')
print('wrote Trace.tla / Trace.cfg with',len(A),'wrappers and mandatory post-state validation')
