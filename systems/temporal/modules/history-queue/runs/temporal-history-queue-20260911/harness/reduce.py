#!/usr/bin/env python3
"""Project measured hook snapshots; never run a model action or predict queue state."""
import argparse, copy, json, pathlib
C=dict(task_count=6,owner_count=2,groups=['g1','g2'],slice_slots=24,exec_slots=24,snapshot_slots=2,batch_size=1,max_epoch=2,move_threshold=2,predicate_limit=0,shrink_keys=2,unexpected_limit=2,dlq_enabled=False)
def cp(x):return copy.deepcopy(x)
def eqs():return dict(high=8,readers=[[],[]])
def ez():return dict(id=0,lo=0,hi=0,pred=[],iters=[],tracked=[])
def ep():return dict(owner=0,epoch=0,key=0,group='none',kind='none',phase='unused',reply='none',pending=False)
def ee():return dict(task=0,owner=0,state='free',pc='idle',terminal=False,unexpected=0,result='none')
def es():return dict(owner=0,epoch=0,data=eqs(),phase='free',caller='other')
def eo():return dict(epoch=0,mode='absent',next=0,renewPC='idle',expected=0,renewData=eqs(),fresh=False)
def eq():return dict(high=8,deleteMin=8,lastRange=0,lists=[[],[]],cursor=[0,0],detached=[ez(),ez()],pc='idle',captured=eqs(),moveGroups=[],moved=[],deleteResult='none',memory=eqs(),clearReader=0,clearID=0,cancelTodo=[])

class Reducer:
 def __init__(self,manifest):
  self.manifest=manifest;self.origin=manifest['key_origin'];self.groups=manifest['group_mapping']
  self.s=dict(db={**{k:[] for k in ['rows','workflow','published','matching','started','obsolete','terminal','dlq','completed','deleted','acked','protected']},'range':1,'owner':1,'queue':eqs()},pub=[ep() for _ in range(6)],own=[eo(),eo()],q=[eq(),eq()],ex=[ee() for _ in range(24)],snaps=[es(),es()],notice=[False,False])
  self.ids={};self.execs={};self.taskkeys={};self.workflowids={};self.previous_rows=set()
 def key(self,k):
  if k==0:return 0
  assert k>=self.origin, ('key precedes observed modeled frontier',k,self.origin)
  return 16+(k-(2<<20)) if k>=2<<20 else k-self.origin+8
 def pred(self,p):
  kind=p['predicate_type'];attrs=p.get('Attributes',{})
  if kind==1:return C['groups'][:]
  if kind==2:return []
  if kind==6:return sorted(self.groups[x] for x in attrs['NamespaceIdPredicateAttributes'].get('namespace_ids',[]))
  if 'NamespaceIdPredicateAttributes' in attrs:return sorted(self.groups[x] for x in (attrs['NamespaceIdPredicateAttributes'] or {}).get('namespace_ids',[]))
  if 'AndPredicateAttributes' in attrs:
   ps=[set(self.pred(x)) for x in attrs['AndPredicateAttributes']['predicates']];return sorted(set.intersection(*ps))
  if 'OrPredicateAttributes' in attrs:
   return sorted(set().union(*(self.pred(x) for x in attrs['OrPredicateAttributes']['predicates'])))
  if 'NotPredicateAttributes' in attrs:return sorted(set(C['groups'])-set(self.pred(attrs['NotPredicateAttributes']['predicate'])))
  raise ValueError(p)
 def scope(self,z):return dict(lo=self.key(z['lo']),hi=self.key(z['hi']),pred=self.pred(z['predicate']))
 def qs(self,p):
  assert p is not None,'missing queue-state observation'
  readers=[]
  for rid in ['0','1']:
   readers.append([self.scope(dict(lo=z['range']['inclusive_min'].get('task_id',0),hi=z['range']['exclusive_max'].get('task_id',0),predicate=z['predicate'])) for z in p.get('reader_states',{}).get(rid,{}).get('scopes',[])])
  return dict(high=self.key(p['exclusive_reader_high_watermark']['task_id']),readers=readers)
 def alloc(self,ptr,reserved=None):
  if ptr not in self.ids:
   used=set(self.ids.values()) if reserved is None else reserved
   self.ids[ptr]=next(i for i in range(1,25) if i not in used)
  return self.ids[ptr]
 def z(self,z):return dict(id=self.ids[z['address']],**self.scope(z['scope']),iters=[dict(lo=self.key(i['lo']),hi=self.key(i['hi'])) for i in z['iters']],tracked=sorted(self.execs[x] for x in z['tracked']))
 def consume(self,r):
  n=r['event'];a=cp(r['args']);d=r['detail'];raw=r['raw'];oi=r['context']['owner']-1;q=self.s['q'][oi];db=self.s['db'];sh=raw['shard' if oi==0 else 'shard2'];qr=raw['queue' if oi==0 else 'queue2'];dr=raw['db'];fresh_before=oi==1 and n in ['AcquireShardBegin','RenewRangeLockedCommit']
  queue_present=qr is not None
  if qr is None:qr=dict(readers=[dict(id=i,lists=[],cursor='',detached=None) for i in range(2)],executables=[],high=self.origin,deleteMin=self.origin,lastRange=-1,notice=False)
  t=a.get('t',0)
  if n=='SetAndTrackTaskKeys':
   assert len(d['tasks'])==1,'atomic bundle requires model extension'
   task=d['tasks'][0];key=task['TaskID'];self.taskkeys[key]=t;self.workflowids[task['WorkflowID']]=t
   wf=next(w for w in dr['workflows'] if w['id']==t)
   self.s['pub'][t-1]=dict(owner=a['o'],epoch=d['range'],key=self.key(key),group=self.groups[task['NamespaceID']],kind=wf['kind'],phase='allocated',reply='none',pending=True)
   a.update(g=self.groups[task['NamespaceID']],k=wf['kind'])
  elif n in ['AppendHistoryNodes','UpdateWorkflowExecutionCommit','UpdateWorkflowExecutionFail','UpdateWorkflowExecutionFenced']:
   self.s['pub'][t-1]['phase']={'AppendHistoryNodes':'appended','UpdateWorkflowExecutionCommit':'committed','UpdateWorkflowExecutionFail':'failed','UpdateWorkflowExecutionFenced':'failed'}[n]
   if n=='AppendHistoryNodes':assert d['history_batches']>0
  elif n=='TaskRequestCompletion':self.s['pub'][t-1]['reply']='ok' if not d['error'] else 'error'
  elif n=='TaskRequestTimeout':self.s['pub'][t-1]['reply']='unknown'
  for p in self.s['pub']:
   if p['owner']==1:p['pending']=any(self.key(k)==p['key'] for k in raw['shard']['pending_keys'])
  self.s['own'][oi].update(epoch=0 if fresh_before else sh['epoch'],mode={0:'absent',1:'acquiring',2:'active',3:'stopped',4:'stopped'}[sh['context_state']],next=0 if fresh_before else self.key(sh['next']))
  if n=='AcquireShardBegin':self.s['own'][oi].update(renewPC='store',expected=d['expected'],renewData=self.qs(d['snapshot']['queue_states']['1']),fresh=d['fresh'])
  if n=='RenewRangeLockedCommit':self.s['own'][oi]['renewPC']='reply'
  if n=='AcquireShardComplete':
   self.s['own'][oi]['renewPC']='idle'
   for idx,z in enumerate(z for rr in qr['readers'] for z in rr['lists']):self.ids[z['address']]=idx+1
  for e in qr['executables']:
   ptr=e['address']
   if ptr not in self.execs:
    self.execs[ptr]=len(self.execs)+1
    self.s['ex'][self.execs[ptr]-1].update(task=self.taskkeys[e['key']],owner=oi+1,pc='ready')
   self.s['ex'][self.execs[ptr]-1].update(state={1:'pending',2:'aborted',3:'cancelled',4:'acked'}[e['state']],terminal=e['terminal'],unexpected=e['unexpected'])
  if 'e' in a:a['e']=self.execs[a['e']]
  if 'es' in a:a['es']=[self.execs[x] for x in a['es']]
  if 'e' in a:
   e=self.s['ex'][a['e']-1]
   pcs={'Execute':'dlq' if e['terminal'] else 'eligibility','ProcessTransferTaskEligible':'matching','MatchingSpoolCommit':'matchingReply','MatchingReply':'handle','MatchingLostReply':'handle','ExecuteRetryableError':'handle','HandleErrAck':'ack','HandleErrRetry':'nack','HandleErrUnexpected':'nack','Ack':'idle','Nack':'rescheduled','Reschedule':'ready'}
   if n in pcs:e['pc']=pcs[n]
   if n=='MatchingSpoolCommit':e['result']='accepted'
   if n=='MatchingLostReply':e['result']='unexpected'
   if n=='ExecuteRetryableError':e['result']='retry'
   if n=='Ack' and e['state']=='acked':db['acked']=sorted(set(db['acked'])|{e['task']})
  if n=='MoveGroupSplit':
   used={z['id'] for ls in q['lists'] for z in ls}|set(q['cursor'])|{z['id'] for z in q['moved']}
   for pair in d['lineage']:
    self.ids[pair['fail']]=self.ids[pair['old']]
    fresh=next(i for i in range(1,25) if i not in used);used.add(fresh);self.ids[pair['pass']]=fresh
   q['moved']=[self.z(z) for z in d['moved']]
  if n in ['MoveGroupMerge','ProcessNewRangeMerge']:
   rid=1 if n=='MoveGroupMerge' else 0
   reserved={self.ids[z['address']] for z in qr['readers'][1-rid]['lists']}
   for z in qr['readers'][rid]['lists']:
    fresh=next(i for i in range(1,25) if i not in reserved);reserved.add(fresh);self.ids[z['address']]=fresh
   q['detached'][rid]=ez()
   if n=='MoveGroupMerge':q['moved']=[]
  if n=='CompactSlices':self.ids[d['new']]=self.ids[d['old']]
  if n=='ClearSlicesBegin':a['id']=self.ids[a['id']]
  if n=='SplitSlicesByRange':
   a['id']=self.ids[d['old']];self.ids[d['left']]=a['id'];a['fresh']=self.alloc(d['right']);a['cut']=self.key(a['cut'])
  for rr in qr['readers']:
   for z in rr['lists']:self.alloc(z['address'])
   rid=rr['id'];q['lists'][rid]=[self.z(z) for z in rr['lists']]
   q['cursor'][rid]=self.ids[rr['cursor']] if rr['cursor'] else 0
   if rr['detached'] is not None:q['detached'][rid]=self.z(rr['detached'])
  if n=='SelectTasks' and d['slice'] not in {z['address'] for z in qr['readers'][a['r']]['lists']}:
   q['detached'][a['r']]=self.z(d['selected_slice'])
  if n=='ProcessNewRange':
   a['id']=q['lists'][0][-1]['id'];q['detached'][0]=ez()
  q.update(high=self.key(qr['high']),deleteMin=self.key(qr['deleteMin']),lastRange=max(0,qr['lastRange']))
  if queue_present:q['memory']=self.qs(sh['memory'])
  self.s['notice'][oi]=qr['notice']
  if n=='ClearSlicesBegin':
   q.update(pc='clearCancel',clearReader=a['r'],clearID=a['id'])
   q['cancelTodo']=next(z['tracked'][:] for z in q['lists'][a['r']] if z['id']==a['id'])
  elif n=='ClearCancel':q['cancelTodo'].remove(a['e'])
  elif n=='ClearSlicesComplete':q['pc']='idle';q['detached'][q['clearReader']]=ez()
  elif n=='CheckpointBegin':q['pc']='shrink0'
  elif n=='ShrinkSlices':q['pc']='shrink1' if a['r']==0 else 'moveStats'
  elif n=='MoveGroupCollect':q['moveGroups']=sorted(self.groups[g] for g in d['groups']);q['pc']='moveSplit' if d['groups'] else 'scope0'
  elif n=='MoveGroupSplit':q['pc']='moveMerge'
  elif n=='MoveGroupMerge':q['pc']='scope0'
  elif n=='CheckpointScopes':q['captured']['high']=q['high'];q['captured']['readers'][a['r']]=[self.scope(z) for z in d['scopes']];q['pc']='scope1' if a['r']==0 else 'deleteBegin'
  elif n=='RangeCompleteTasksBegin':q['pc']='deleteStore' if d['delete'] else 'setState';q['deleteResult']='none'
  elif n=='RangeCompleteTasksCommit':q['pc']='deleteReply';q['deleteResult']='committed'
  elif n=='RangeCompleteTasksFail':q['pc']='deleteReply';q['deleteResult']='failed'
  elif n=='RangeCompleteTasksReply':q['pc']='setState' if q['deleteResult']=='committed' else 'idle'
  elif n=='RangeCompleteTasksLostReply':q['pc']='idle';q['deleteResult']='unknown'
  elif n=='SetQueueStateBatched':q['pc']='idle'
  elif n=='SetQueueStateSnapshot':
   q['pc']='stateReply';self.s['snaps'][a['j']-1]=dict(owner=oi+1,epoch=d['snapshot']['range_id'],data=self.qs(d['snapshot']['queue_states']['1']),phase='store',caller='checkpoint')
  elif n in ['UpdateShardCommit','UpdateShardFail','UpdateShardFenced']:self.s['snaps'][a['j']-1]['phase']={'UpdateShardCommit':'committed','UpdateShardFail':'failed','UpdateShardFenced':'fenced'}[n]
  elif n=='UpdateShardReply':q['pc']='idle';self.s['snaps'][a['j']-1]=es()
  current_rows={self.taskkeys[z['key']] for z in dr['rows']}
  removed=self.previous_rows-current_rows;added=current_rows-self.previous_rows
  if removed:assert n=='RangeCompleteTasksCommit',('unobserved deletion',n,removed)
  if added:assert n=='UpdateWorkflowExecutionCommit',('unobserved publication',n,added)
  db['deleted']=sorted(set(db['deleted'])|removed);db['published']=sorted(set(db['published'])|added);db['rows']=sorted(current_rows);self.previous_rows=current_rows
  db['range']=dr['shard']['range_id'];db['owner']=int(dr['shard']['owner'][1:]);db['queue']=self.qs(dr['shard']['queue_states']['1'])
  workflows=[];started=[];completed=[]
  for wf in dr['workflows']:
   state=wf['state'];info=state['execution_info'];wid=wf['id']
   if wf['kind']=='Workflow':
    if info.get('workflow_task_scheduled_event_id',0)>0:workflows.append(wid)
    if info.get('workflow_task_started_event_id',0)>0:started.append(wid)
   else:
    if state.get('activity_infos'):workflows.append(wid)
    if any(ai.get('started_event_id',0)>0 for ai in state.get('activity_infos',{}).values()):started.append(wid)
  db['workflow']=sorted(set(db['workflow'])|set(workflows));db['started']=sorted(set(db['started'])|set(started))
  db['matching']=sorted({self.workflowids[x['data']['workflow_id']] for x in dr['matching']})
  if n in ['UpdateWorkflowExecutionCommit','UpdateShardCommit','RenewRangeLockedCommit']:
   pair=[d['request_range'],d.get('checked_range',db['range'])]
   if pair not in db['protected']:db['protected'].append(pair)
  record={k:r[k] for k in ['tag','ts','seq','schema','provenance','event','nid']};record.update(args=a,post=cp(self.s),evidence=dict(raw_seq=r['seq']))
  if n=='Init':record.update(revision=self.manifest['revision'],backend=self.manifest['backend'],constants=C)
  if n=='Endpoint':
   assert d['complete'] and d['independent_readback'] and d['outstanding_calls']==0
   record.update(complete=True,independent_readback=True,readback={k:cp(db[k]) for k in ['range','owner','rows','workflow','matching','started','obsolete','dlq','completed','queue']})
  return record

def main():
 p=argparse.ArgumentParser();p.add_argument('raw',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);args=p.parse_args()
 raw=[json.loads(l) for l in args.raw.read_text().splitlines()];reducer=Reducer(raw[0]['extra']['manifest']);out=[]
 for r in raw:
  try:out.append(reducer.consume(r))
  except Exception as exc:raise RuntimeError(f"raw seq {r['seq']}, {r['event']}: {exc}") from exc
 args.output.parent.mkdir(parents=True,exist_ok=True)
 with args.output.open('w') as f:
  for r in out:r['evidence']['file']=str(args.raw.resolve());f.write(json.dumps(r,separators=(',',':'))+'\n')
 print(f'{args.output}: {len(out)} events, {len(set(r["event"] for r in out))} event types')
if __name__=='__main__':main()
