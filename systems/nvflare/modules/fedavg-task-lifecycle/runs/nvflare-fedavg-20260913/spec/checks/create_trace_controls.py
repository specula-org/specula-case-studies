from pathlib import Path
import json,copy
D=Path(__file__).resolve().parent.parent
R,K=2,2; clients=['c1','c2']
empty_used=dict(params=[[] for _ in range(K)],stats=[[] for _ in range(K)],paramHistory=[],metrics=[],metricStats=[],metricHistory=[],allMetrics=True,count=0,counted=[])
aggr=dict(task=0,applied=[[] for _ in range(K)],stats=[[] for _ in range(K)],paramHistory=[],metricApplied=[],metricStats=[],metricHistory=[],allMetrics=True,receivedCount=0,counted=[],failedClients=[])
ct=dict(assigned=False,headerId=[0,''],headerRound=-1,inputVersion=-1,delivery='none',result='none',metricKind='none',receipt=False,decision='pending',invocations=0)
task=dict(scheduled=False,standing=False,status='NEW',sourceAtSchedule=-1,broadcastVersion=-1,assignedOrder=[],age=0,cleaned=False,retiredStatus='NEW',retiredOutstanding=[])
s=dict(wf=dict(round=0,pc='start',sourceVersion=0,started=[],abort=False,outcome='running',open=True),
 task=[copy.deepcopy(task) for _ in range(R)],ct=[{c:copy.deepcopy(ct) for c in clients} for _ in range(R)],net=[{c:[] for c in clients} for _ in range(R)],
 comm=dict(kind='free',pc='idle',id=[0,''],attempt=0,key=1,accepted=False,exit='LIVE',writeStatus=False,pending=[],deadView=[]),
 runner=dict(kind='free',pc='idle',client='',id=[0,''],attempt=0),requested=[],aggr=aggr,scratch=copy.deepcopy(empty_used),used=[copy.deepcopy(empty_used) for _ in range(R)],
 committed=[],saved=[],completed=[],unknownSeen=[],dead={c:dict(reported=False,age=0,disconnected=False) for c in clients},
 mon=dict(pc='idle',pending=[],deadView=[],reportAges={c:0 for c in clients}))
config=dict(Clients=clients,Selected=clients,NumRounds=R,NumKeys=K,HistoryLimit=4,ErrorMode='dynamic',OutboundFilter=False,LazyOffload=False,AllocationFailure=False,ConversionFailure=False,BeforeSendFailure=False,AllowEmpty=True,MetricKinds=['present'],MinSites=2,RequiredSites=[],AllowPartialCompletion=False)
rows=[dict(tag='specula-meta',schema=1,sourceHead='53ba7ee567468ea7971dad4faccef13c6cb35dc2',origin='synthetic-test',config=config,initial=copy.deepcopy(s))]
def emit(name):rows.append(dict(tag='trace',event=dict(name=name,nid='server',args=[],seq=len(rows),state=copy.deepcopy(s))))
s['wf'].update(round=1,pc='reset',started=[1]);emit('FedAvgRoundStarted')
s['aggr']['task']=1;s['wf']['pc']='schedule';emit('FedAvgResetAggregation')
s['task'][0].update(scheduled=True,standing=True,status='LIVE',sourceAtSchedule=0);s['wf']['pc']='wait';emit('WFCommScheduleTask')
for variant in ['positive','bad_state','unknown_event']:
 r=copy.deepcopy(rows)
 if variant=='bad_state':r[-1]['event']['state']['task'][0]['broadcastVersion']=1
 if variant=='unknown_event':r[-1]['event']['name']='UnmodeledEvent'
 (D/'checks'/('trace-'+variant+'.ndjson')).write_text(''.join(json.dumps(x,separators=(',',':'))+'\n' for x in r))
 cfg=(D/'Trace.cfg').read_text()+'\nCONSTANTS\n    ControlPath = "checks/trace-'+variant+'.ndjson"\n    JsonFile <- ControlJsonFile\n'
 (D/'checks'/('Trace-'+variant+'.cfg')).write_text(cfg)
(D/'TraceControl.tla').write_text('''-------------------------- MODULE TraceControl --------------------------
EXTENDS Trace
CONSTANT ControlPath
ControlJsonFile == ControlPath
=============================================================================
''')
print('Created three explicitly synthetic replay controls, using complete initial/post-state images.')
