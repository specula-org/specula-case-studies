from pathlib import Path
import json
O=Path(__file__).resolve().parent.parent
cfg=dict(revision='0c010ce5fe8c0180aa7573c72fe8fc87c6df7025',backend='SQL',ioConcurrency=1,historyLimit=16,startMapPresent=True,scannerAfterRequestDeadline=True,runs=['a','b','c'],ops=['p'],resetIDs=['reset1'],startIDs=['start1'],updateIDs=['u1','u2'],payloads=['x','y'])
def tla(v):
 if isinstance(v,bool):return str(v).upper()
 if isinstance(v,str):return json.dumps(v)
 if isinstance(v,int):return str(v)
 if isinstance(v,list):return '<<'+','.join(map(tla,v))+'>>'
 if isinstance(v,dict):return '['+', '.join(k+' |-> '+tla(vv) for k,vv in v.items())+']'
s=[('StartWorkflowExecution',dict(p='p',r='a',id='start1')),
('CreateWorkflowExecution_Start',dict(p='p')),('AppendHistoryNodes',dict(r='a')),('CommitWorkflowExecution',dict(r='a')),
('PersistenceReturn',dict(r='a')),('Invoke_ReturnSuccess',dict(p='p')),('ReleaseWorkflowLease_Success',dict(p='p')),('ReceiveResetResponse',dict(p='p')),('AddWorkflowTaskStartedEvent',dict(r='a')),
('ResetWorkflowExecution',dict(p='p',q='reset1',b='a',cut=2,ex=[])),('GetWorkflowLease_Base',dict(p='p')),('GetCurrentWorkflowRunID',dict(p='p')),('GetWorkflowLease_Current',dict(p='p')),('Invoke_Deduplicate',dict(p='p')),('Invoke_NewRunID',dict(p='p',r='b')),('ResetWorkflow_UpdateResetRunID',dict(p='p')),('ForkHistoryBranch',dict(p='p')),('Rebuild',dict(p='p')),('ReadHistoryBranch',dict(p='p')),('ReapplyEventsFromBranch_NextRun',dict(p='p')),('ScheduleWorkflowTask',dict(p='p')),('UpdateWorkflowExecution_WithNew',dict(p='p')),('AppendHistoryNodes_Current',dict(r='b')),('AppendHistoryNodes',dict(r='b')),('CommitWorkflowExecution',dict(r='b')),('PersistenceReturn',dict(r='b')),('Invoke_ReturnSuccess',dict(p='p')),('ReleaseWorkflowLease_Success',dict(p='p')),('ReceiveResetResponse',dict(p='p'))]
t='''--------------------------- MODULE Fixture --------------------------------
EXTENDS base, Json
VARIABLE step
fvars == <<vars,step>>
Snapshot == [db |-> db,op |-> op,pending |-> pending,rt |-> rt,audit |-> audit,deletion |-> deletion,used |-> used]
'''
t+='FInit == /\\ Init /\\ step = 1 /\\ PrintT(ToJson([tag |-> "temporal-reset",event |-> "Bootstrap", config |-> '+tla(cfg)+',state |-> Snapshot]))\n'
t+='FNext ==\n'
for i,(n,a) in enumerate(s,1):
 args=','.join(('{}' if k=='ex' else tla(v)) for k,v in a.items())
 t+='    \\/ /\\ step = '+str(i)+'\n       /\\ '+n+'('+args+')\n       /\\ step\' = step+1\n'
 t+='       /\\ PrintT(ToJson([tag |-> "temporal-reset",event |-> '+tla(n)+',args |-> '+tla(a)+',state |-> Snapshot\']))\n'
t+='    \\/ /\\ step = '+str(len(s)+1)+'\n       /\\ UNCHANGED fvars\n=============================================================================\n'
(O/'Fixture.tla').write_text(t)
c=(O/'base.cfg').read_text().replace('INIT Init','INIT FInit').replace('NEXT Next','NEXT FNext').replace('"a", "b", "c", "d", "e", "f", "g"','"a", "b", "c"').replace('"p", "q"','"p"').replace('"reset1", "reset2"','"reset1"').replace('"start1", "start2"','"start1"')
(O/'validation'/'Fixture.cfg').write_text(c)
