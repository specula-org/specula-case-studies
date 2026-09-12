#!/usr/bin/env python3
"""Project captured Temporal observations; never run or consult TLC to construct state.

DB values are decoded from SQL readback at the observed boundary. Operation frames
are recorder shadows of captured API inputs, leases, local history and write calls.
Unrepresented concrete effects remain in snapshots and are reported, not repaired.
"""
import argparse
import base64
import copy
import json
import re
from pathlib import Path

NONE = 'none'
def clone(x): return copy.deepcopy(x)
def decode_oneofs(x):
    if isinstance(x,list):return [decode_oneofs(v) for v in x]
    if not isinstance(x,dict):return x
    out={k:decode_oneofs(v) for k,v in x.items()}
    for k,v in out.get('Attributes',{}).items():
        out[re.sub(r'(?<!^)(?=[A-Z])','_',k).lower()]=v
    return out
def unique(xs):
    out=[]
    for x in xs:
        if x not in out: out.append(x)
    return out

def empty_run():
    return dict(exists=False,status='absent',ver=0,n=0,firstTaskScheduled=False,create=NONE,start=NONE,requestIds=[],callback=NONE,link=NONE,can=NONE,base=NONE,cut=0,resetReq=NONE)
def empty_op():
    o={k:NONE for k in ('kind req base candidate seen create callback originalToken prefixToken localLink scan err result immediate').split()}
    o.update({k:0 for k in 'cut bv cv baseN curN end adminEpoch'.split()})
    o.update({k:[] for k in 'exclude batch input prefix built expected reapplied updateIds visited frontier'.split()})
    o.update(pc='idle',index=1,terminate=False,dedup=False)
    return o

def empty_write():
    w={k:NONE for k in 'mode owner base seen create req result immediate'.split()}
    w.update({k:0 for k in 'epoch bv cv curN cut adminEpoch'.split()})
    w.update({k:[] for k in 'events prefix expected reapplied'.split()})
    w.update(state='empty',terminate=False,prechecked=False,reply='waiting')
    return w

def eligible(e,ex):
    return (e['kind']=='Signal' and 'Signal' not in ex) or (e['kind']=='Admitted' and 'Update' not in ex) or (e['kind']=='Accepted' and e['hasRequest'] and 'Update' not in ex)

class Projection:
    def __init__(self, rows):
        self.rows=rows
        self.runs={};self.branch_run={};self.callbacks={};self.starts={};self.resetids=[];self.idset=[];self.payloads=[]
        self.provenance={};self.eventmap={};self.event_at={};self.tokens={};self.last_hist={};self.last_cells={};self.last_runs={}
        self.issues=[];self.checkpoints=[];self.emitted=[];self.source_lines=[];self.last_request=None;self.write_active=False
        self.raw_committed={};self.source_of_new={};self.pending_reapplied={};self.active_pid='p';self.nested_start=False
        # Collect the finite ID universe only; no events are inserted or reordered.
        for row in rows:
            d=row['data'];db=row.get('durable') or {}
            for r in db.get('runs',{}): self.run(r)
            for r,t in db.get('tokens',{}).items():
                self.run(r);self.branch_run[t['branch_id']]=self.run(r);self.tokens[self.run(r)]=t
            if row['name']=='CallbackSource':
                self.run(d['run']);self.starts[self.run(d['run'])]=d['request'] or NONE
            if row['name']=='ResetWorkflowExecution':
                q=d['request']['request_id'];self.resetids=unique(self.resetids+[q])
        self.s=dict(db=dict(runs={r:empty_run() for r in self.runs.values()},current=NONE,range=1,hist={r:[] for r in self.runs.values()},cells={r:[] for r in self.runs.values()},branches=[],nodes=[]),
          op={p:empty_op() for p in ('p','q')},pending={r:empty_write() for r in self.runs.values()},rt=dict(state='acquired',epoch=1,leases={r:NONE for r in self.runs.values()},currentLock=NONE,io=[]),
          audit=dict(acks=[],receipts=[],commits=[],deleted=[],retryBad=False,wanted=[],terminal=[],admin={q:0 for q in self.resetids},availableBad=False,reapplyBad=False),
          deletion={r:dict(stage='none',epoch=0,plan=[],aged=False,scanner=False) for r in self.runs.values()},used=[])
        self.config=dict(revision='0c010ce5fe8c0180aa7573c72fe8fc87c6df7025',backend='SQL',ioConcurrency=1,historyLimit=64,startMapPresent=True,scannerAfterRequestDeadline=True,runs=list(self.runs.values()),ops=['p','q'],resetIDs=self.resetids,startIDs=[],updateIDs=[],payloads=[])

    def run(self,r):
        if not r or r==NONE: return NONE
        if r not in self.runs:self.runs[r]=f'r{len(self.runs)+1}'
        return self.runs[r]

    def event(self,e,owner,position=None):
        typ=e['event_type'];real=e['event_id']
        kinds={1:'Start',6:'WFT',9:'ResetWFT',26:'Signal',27:'Terminated',28:'CAN',41:'Accepted',43:'Completed',47:'Admitted'}
        if typ not in kinds:return None
        if typ==9 and not e.get('workflow_task_failed_event_attributes',{}).get('new_run_id'):return None
        key=(owner,real)
        if key in self.provenance:return clone(self.provenance[key])
        if key in self.event_at:return clone(self.event_at[key])
        n=position if position is not None else self.source_of_new.get(owner,{}).get('cut',0)+1+sum(1 for r,_ in set(self.event_at)|set(self.provenance) if r==owner)
        v=dict(origin=owner,number=n,kind=kinds[typ],id=NONE,payload=NONE,hasRequest=False,next=NONE,version=1)
        if typ==1:v['id']=self.starts.get(owner,NONE)
        if typ==28:v['next']=self.run(e['workflow_execution_continued_as_new_event_attributes']['new_execution_run_id'])
        if typ==26:
            a=e['workflow_execution_signaled_event_attributes'];v.update(id=a.get('request_id') or NONE,hasRequest=True,payload=json.dumps(a.get('input',{}),sort_keys=True))
        if typ in (41,47):
            a=e['workflow_execution_update_accepted_event_attributes'] if typ==41 else e['workflow_execution_update_admitted_event_attributes']
            req=a.get('accepted_request') if typ==41 else a.get('request')
            v['id']=(req or {}).get('meta',{}).get('update_id') or a.get('protocol_instance_id',NONE)
            v['hasRequest']=req is not None
            if req is not None:v['payload']=json.dumps(req.get('input',{}),sort_keys=True)
        if typ==43:v['id']=e['workflow_execution_update_completed_event_attributes']['meta']['update_id']
        self.event_at[key]=clone(v);self.eventmap[f'{owner}:{real}']=dict(normalized=n,realVersion=e.get('version',0),kind=v['kind'])
        if v['id']!=NONE:self.idset=unique(self.idset+[v['id']])
        if v['payload']!=NONE:self.payloads=unique(self.payloads+[v['payload']])
        return v

    def physical(self,raw):
        # Decode physical batches independently of mutable-state frontiers.
        cells_by_branch={};events_by_branch={};allnodes=[]
        for branch,batches in raw['nodes'].items():
            owner=self.branch_run[branch];cells_by_branch[branch]=[];events_by_branch[branch]=[]
            events={}
            for batch in batches:
                for e in batch['events']:
                    if e['event_id'] in events and events[e['event_id']]!=e:
                        self.issues.append('multiple physical transaction versions need an extended projection')
                    events.setdefault(e['event_id'],e)
            for real,e in sorted(events.items()):
                v=self.event(e,owner)
                if v is None:continue
                # Own cell indices use position within branch history, independent of source provenance.
                idx=self.eventmap.get(f'{owner}:{real}',{}).get('normalized')
                if idx is None:idx=self.provenance[(owner,real)]['number']
                cells_by_branch[branch].append((real,[owner,idx]));events_by_branch[branch].append((real,v));allnodes.append([owner,idx])
        histories={};cells={}
        for r in self.runs.values():
            token=raw['tokens'].get(next((real for real,sym in self.runs.items() if sym==r),''))
            if token is None:
                histories[r]=clone(self.last_hist.get(r,[]));cells[r]=clone(self.last_cells.get(r,[]));continue
            ranges=[(a['branch_id'],a['begin_node_id'],a['end_node_id']) for a in token.get('ancestors',[])]+[(token['branch_id'],1,2**63-1)]
            hs=[];cs=[]
            for branch,lo,hi in ranges:
                hs.extend(v for eid,v in events_by_branch.get(branch,[]) if lo<=eid<hi)
                cs.extend(v for eid,v in cells_by_branch.get(branch,[]) if lo<=eid<hi)
            # Preserve the last observed event sequence after physical deletion; existence is represented by nodes.
            previous_hs=self.last_hist.get(r,[]);previous_cs=self.last_cells.get(r,[])
            histories[r]=clone(previous_hs) if len(hs)<len(previous_hs) else hs
            cells[r]=clone(previous_cs) if len(cs)<len(previous_cs) else cs
        return histories,cells,unique(allnodes)

    def frontier(self,r,next_id):
        points={(owner,eid) for owner,eid in set(self.event_at)|set(self.provenance) if owner==r and eid<next_id}
        for a in self.tokens.get(r,{}).get('ancestors',[]):
            br=self.branch_run[a['branch_id']]
            points.update((owner,eid) for owner,eid in set(self.event_at)|set(self.provenance) if owner==br and a['begin_node_id']<=eid<min(a['end_node_id'],next_id))
        return len(points)

    def durable(self,raw):
        if raw is None:raise ValueError('event has no SQL snapshot')
        hist,cells,nodes=self.physical(raw)
        runs={}
        for real,r in self.runs.items():
            rec=raw['runs'].get(real)
            if rec is None:
                runs[r]=clone(self.last_runs.get(r,empty_run()));runs[r]['exists']=False;continue
            info=rec['info'];state=rec['state'];create=state.get('create_request_id') or NONE
            ids=[k for k,v in state.get('request_ids',{}).items() if v.get('event_type')==1]
            can=next((e['next'] for e in hist[r] if e['kind']=='CAN'),NONE)
            origin=self.source_of_new.get(r,{})
            # The committed frontier is counted over actual local IDs, including ancestor ranges.
            token=raw['tokens'][real];front=[]
            for a in token.get('ancestors',[]):
                br=self.branch_run[a['branch_id']]
                front.extend((br,eid) for owner,eid in self.event_at if owner==br and a['begin_node_id']<=eid<min(a['end_node_id'],rec['next']))
            front.extend((r,eid) for owner,eid in set(self.event_at)|set(self.provenance) if owner==r and eid<rec['next'])
            runs[r]=dict(exists=True,status={1:'running',2:'completed',5:'terminated',6:'can'}.get(state['status'],str(state['status'])),ver=rec['ver'],n=len(set(front)),firstTaskScheduled=bool(info.get('workflow_task_scheduled_event_id') or info.get('last_completed_workflow_task_started_event_id') or any(e['kind'] in ('WFT','ResetWFT') for e in hist[r][:len(set(front))])),create=create,start=ids[0] if ids else NONE,requestIds=ids,callback=self.callbacks.get(r,NONE),link=self.run(info.get('reset_run_id')),can=can,base=origin.get('base',NONE),cut=origin.get('cut',0),resetReq=origin.get('req',NONE))
        db=dict(runs=runs,current=self.run(raw['current']),range=raw['range'],hist=hist,cells=cells,branches=unique([self.branch_run[b] for b in raw['branches']]),nodes=nodes)
        self.last_runs=clone(runs);self.last_hist=clone(hist);self.last_cells=clone(cells)
        return db

    def local_events(self,local):
        r=self.run(local['state']['run_id']);out=[]
        for e in local.get('events') or []:
            v=self.event(e,r)
            if v is not None:out.append(v)
        return out

    def emit(self,row,event,args,config=False):
        self.s['db']=self.durable(row['durable'])
        item=dict(tag='trace',ts=row['ts'],nid=row['nid'],event=event,args=args,state=clone(self.s))
        if config:item['config']=self.config
        self.emitted.append(item);self.source_lines.append(dict(traceLine=len(self.emitted),rawLine=self.line,event=event))

    def error(self,s):
        if not s:return NONE
        for needle,val in [('AppendHistoryTimeout','AppendHistoryTimeout'),('ResourceExhausted','ResourceExhausted'),('ShardOwnership','OwnershipLost'),('ConditionFailed','Condition'),('NotFound','NotFound'),('DataLoss','DataLoss')]:
            if needle in s:return val
        if 'update' in s.lower() and 'Internal' in s:return 'InternalUpdateCollision'
        return 'Unavailable'

    def observe(self,row):
        name=row['name'];d=row['data']
        if name=='StartWorkflowExecution' and self.s['op']['p']['kind']=='reset':self.active_pid='q';self.nested_start=True
        pid=self.active_pid;o=self.s['op'][pid];rt=self.s['rt'];audit=self.s['audit'];raw=row['durable'];args={'p':pid}
        # Pure diagnostic records retain their own independent readbacks in the sidecar.
        if name=='CallbackSource':
            self.callbacks[self.run(d['run'])]=d['request'] or NONE;return
        if name=='Bootstrap':self.emit(row,name,{},True);return
        if name in ('Checkpoint','ShardReloadReadback'):
            db=self.durable(raw);self.checkpoints.append(dict(rawLine=self.line,name=d.get('name',name),durableMatchesLastEvent=db==self.s['db']))
            return
        if name in ('ReadPage','InterleaveGate'):return
        if name=='StartWorkflowExecution':
            r=self.run(d['run']);q=d['request']['request_id'];self.starts[r]=q
            o=empty_op();o.update(pc='start-history',kind='start',candidate=r,create=q)
            for batch in d['events']:
                for e in batch.get('Events',[]):
                    v=self.event(e,r)
                    if v:o['built'].append(v)
            self.s['op'][pid]=o;self.s['used']=unique(self.s['used']+[r]);rt['currentLock']=pid;args.update(r=r,id=q)
        elif name=='ResetWorkflowExecution':
            req=d['request'];base=self.run(req['workflow_execution']['run_id']);cut=self.frontier(base,req['workflow_task_finish_event_id'])
            ex=[]
            for e in req.get('reset_reapply_exclude_types',[]):
                ex.append({1:'Signal',2:'Update'}[e])
            if req.get('reset_reapply_type')==1:ex=unique(ex+['Update'])
            if req.get('reset_reapply_type')==2:ex=['Signal','Update']
            q=req['request_id'];old=clone(o);o=empty_op();o.update(pc='base-lease',kind='reset',req=q,base=base,cut=cut,exclude=ex)
            if self.last_request==req and old['pc']=='retry':
                name='RetryResetWorkflowExecution';db=self.durable(raw);c=db['current'];o['immediate']=c if c!=NONE and db['runs'][c]['resetReq']==q else NONE;o['adminEpoch']=audit['admin'][q]
            else:
                args.update(q=q,b=base,cut=cut,ex=ex);audit['wanted']=unique(audit['wanted']+[q])
            self.last_request=clone(req);self.s['op'][pid]=o
        elif name=='GetWorkflowLease_Base':
            local=d['local'];r=o['base'];o.update(pc='lookup',bv=local['ver'],baseN=self.frontier(r,local['next']),originalToken=r);rt['leases'][r]=pid
        elif name=='GetCurrentWorkflowRunID':o.update(pc='current-lease',seen=self.run(d['run']))
        elif name=='GetWorkflowLease_Current':
            l=d['local'];o['pc']='dedup'
            if l:
                r=self.run(l['state']['run_id']);o.update(cv=l['ver'],curN=self.frontier(r,l['next']));rt['leases'][r]=pid
        elif name=='Invoke_Deduplicate':o.update(dedup=d['hit'],pc='server-success' if d['hit'] else 'allocate',result=o['seen'] if d['hit'] else NONE)
        elif name=='Invoke_NewRunID':
            r=self.run(d['run']);o.update(candidate=r,pc='prepare');self.s['used']=unique(self.s['used']+[r]);args['r']=r
            self.source_of_new[r]=dict(base=o['base'],cut=o['cut'],req=o['req'])
        elif name=='ResetWorkflow_UpdateResetRunID':
            o.update(pc='fork',localLink=self.run(d['base']['info']['reset_run_id']),create=d['start'],callback=d['start'],terminate=d.get('currentMutation') is not None)
        elif name=='ForkHistoryBranch':o.update(pc='rebuild',prefixToken=self.run(d['run']))
        elif name=='Rebuild':
            db=self.durable(raw);pre=db['hist'][o['base']][:o['cut']]
            built=self.local_events(d['local']);o.update(prefix=pre,built=pre+built,updateIds=unique([e['id'] for e in pre if e['kind'] in ('Accepted','Admitted')]),scan=o['base'],index=o['cut']+1,end=o['baseN'],visited=[o['base']],pc='read-branch')
        elif name=='ReadHistoryBranch':
            if d['more'] or d['continuation']:raise ValueError('multi-page range requires a pagination-aware Trace.tla wrapper')
            source=o['scan'];suffix=[]
            for batch in d['batches'] or []:
                for e in batch['events']:
                    v=self.event(e,source)
                    if v:suffix.append(v)
            first=o['index'];last=o['end'];o['frontier'].append(dict(run=source,first=first,last=last));o['batch']=suffix;o['input']+=clone(suffix)
            # Independently filter the observed source range, before looking at what reapply built.
            o['expected']+=clone([e for e in suffix if eligible(e,o['exclude'])]);o.update(index=1,pc='reapply')
        elif name=='ReapplyEvents':
            e=self.event(d['event'],o['scan'])
            if e is None:return
            if o['pc']!='reapply':
                self.issues.append(f'raw {self.line}: termination-time event examined outside modeled read range');return
            o['index']+=1
            if d['applied']:
                candidates=(d['local'].get('events') or [])+(d['local'].get('buffered') or [])
                new=next((e for e in reversed(candidates) if e['event_type'] in (26,47)),None)
                if new is None:raise ValueError('reapply marked applied without captured produced event')
                value=clone(e);value['kind']='Admitted' if new['event_type']==47 else 'Signal'
                self.pending_reapplied.setdefault(o['candidate'],[]).append(value)
                if new['event_id']>0:self.provenance[(o['candidate'],new['event_id'])]=value
                self.eventmap[f'{o["candidate"]}:{new["event_id"]}']=dict(normalized=o['cut']+2+len(o['reapplied']),realVersion=new.get('version',0),kind=value['kind'])
                o['reapplied'].append(value);o['built'].append(value)
                if value['kind']=='Admitted':o['updateIds']=unique(o['updateIds']+[value['id']])
            elif eligible(e,o['exclude']) and e['kind'] in ('Accepted','Admitted'):
                o.update(pc='release-error',err='InternalUpdateCollision')
        elif name=='ReapplyEventsFromBranch_NextRun':o.update(scan=self.run(d['run']),pc='successor' if d['run'] else 'schedule')
        elif name=='GetNextEventIDBranchToken':
            r=self.run(d['run']);err=self.error(d['error']);o.update(pc='schedule' if err=='NotFound' else 'read-branch',index=1,end=self.frontier(r,d['next']))
            if err==NONE:o['visited'].append(r)
            elif err!='NotFound':name='ReadTransientFailure';o.update(pc='release-error',err=err)
        elif name=='ScheduleWorkflowTask':
            actual=[e for e in d['local'].get('events') or [] if e['event_type'] in (26,47)]
            reapplied=self.pending_reapplied.get(o['candidate'],[])
            if len(actual)!=len(reapplied):raise ValueError('buffered reapply source/output count mismatch at scheduling')
            for i,(e,source) in enumerate(zip(actual,reapplied)):
                self.provenance[(o['candidate'],e['event_id'])]=clone(source)
                self.eventmap[f'{o["candidate"]}:{e["event_id"]}']=dict(normalized=o['cut']+2+i,realVersion=e.get('version',0),kind=source['kind'])
            o['pc']='submit-base' if o['seen']==NONE else 'submit-atomic'
        elif name=='ShardSubmit':
            if o['pc'] not in ('start-history','submit-base','submit-create','submit-atomic'):return
            req=d['request'];method=d['method'];r=o['candidate']
            mode='start' if o['kind']=='start' else ('create' if method=='CreateWorkflowExecution' else ('base' if o['seen']==NONE else ('same' if method=='UpdateWorkflowExecution' else 'distinct')))
            name={'start':'CreateWorkflowExecution_Start','create':'CreateWorkflowExecution_BrandNew','base':'UpdateWorkflowExecution_BypassCurrent','same':'UpdateWorkflowExecution_WithNew','distinct':'ConflictResolveWorkflowExecution'}[mode]
            w=empty_write();w.update(state='submitted',mode=mode,owner=pid,epoch=req['RangeID'])
            for k in ('base seen bv cv curN create req cut terminate prefix expected reapplied immediate adminEpoch').split():w[k]=clone(o[k])
            w['events']=clone(o['built']);self.s['pending'][r]=w;rt['io']=unique(rt['io']+[r]);o['pc']='write-wait';self.write_active=True
        elif name in ('IssueCurrentHistory','IssueCandidateHistory','IssueMetadata'):
            if not self.write_active:return
            r=o['candidate'];w=self.s['pending'][r];args={'r':r}
            if name=='IssueCurrentHistory' and (not w['terminate'] or w['mode'] not in ('same','distinct')):return
            w['state']={'IssueCurrentHistory':'current-issued','IssueCandidateHistory':'candidate-issued','IssueMetadata':'metadata-issued'}[name]
        elif name in ('AppendHistoryNodes_Current','AppendHistoryNodes'):
            if not self.write_active:return
            r=o['candidate'];w=self.s['pending'][r];args={'r':r}
            if name=='AppendHistoryNodes_Current':
                if not w['terminate'] or w['mode'] not in ('same','distinct'):return
                w['state']='current-appended'
            else:w['state']='ready'
        elif name=='SQLTransaction':
            if self.write_active:
                r=o['candidate'];w=self.s['pending'][r];err=self.error(d['error']);args={'r':r}
                name='CommitWorkflowExecution' if err==NONE else 'RejectWorkflowExecution';w.update(state='committed' if err==NONE else 'rejected',result='OK' if err==NONE else err)
                if err==NONE:
                    prior=self.s['db']['current'];audit['commits']=unique(audit['commits']+[dict(run=r,mode=w['mode'],epoch=w['epoch'],durableEpoch=raw['range'],seen=w['seen'],prior=prior,base=w['base'])])
                    if w['mode']!='base':
                        audit['retryBad']|=w['req']!=NONE and w['immediate']!=NONE and w['immediate']!=r and w['adminEpoch']==audit['admin'][w['req']]
                        for q in audit['admin']:
                            if q!=w['req']:audit['admin'][q]+=1
            else:
                if d['error']:
                    self.issues.append(f'raw {self.line}: unmodeled environment write rejection {d["error"]}');return
                before=self.s['db'];after=self.durable(raw);req=d['request'];m=req.get('UpdateWorkflowMutation') or req.get('ResetWorkflowSnapshot')
                if not m:return
                r=self.run(m['ExecutionState']['run_id']);args={'r':r}
                old=before['runs'][r];new=after['runs'][r];delta=after['hist'][r][old['n']:new['n']]
                types=[e['kind'] for e in delta]
                if new['status']=='can' and old['status']!='can':
                    name='ContinueAsNew';n=req['NewWorkflowSnapshot'];s=self.run(n['ExecutionState']['run_id']);args.update(s=s,id=n['ExecutionState']['create_request_id']);self.s['used']=unique(self.s['used']+[s]);audit['admin']={q:v+1 for q,v in audit['admin'].items()}
                elif new['status']=='completed' and old['status']!='completed':name='CompleteWorkflowExecution'
                elif not types and not old['firstTaskScheduled'] and new['firstTaskScheduled']:name='PersistFirstWorkflowTaskSchedule'
                elif types==['WFT']:name='AddWorkflowTaskStartedEvent'
                elif types==['Signal']:name='AddWorkflowExecutionSignaled';args.update(id=delta[0]['id'],payload=delta[0]['payload'])
                elif types==['Accepted']:name='AddWorkflowExecutionUpdateAcceptedEvent';args.update(id=delta[0]['id'],payload=delta[0]['payload'])
                elif types==['Completed']:name='AddWorkflowExecutionUpdateCompletedEvent';args['id']=delta[0]['id']
                else:
                    self.issues.append(f'raw {self.line}: metadata commit outside supplied environment actions, delta={types}, status={old["status"]}->{new["status"]}, ver={old["ver"]}->{new["ver"]}')
                    return
        elif name=='FaultFired':
            r=self.run(d['candidate']);args={'r':r};w=self.s['pending'][r]
            if d['point']=='before-metadata':name='PersistenceDefiniteRejection';w.update(state='rejected',result='ResourceExhausted')
            else:return # uncertain outcome belongs to shard return, not the injection itself
        elif name=='PersistenceReturn':
            if not self.write_active:return
            r=o['candidate'];w=self.s['pending'][r];args={'r':r};err=self.error(d['error']);rt['io']=[v for v in rt['io'] if v!=r]
            if err=='Unavailable':
                name='PersistenceUncertainReturn';w['reply']='lost';o.update(pc='release-error',err=err)
            else:
                w['reply']='returned';o.update(pc='release-error' if err!=NONE else ('submit-create' if w['mode']=='base' else 'server-success'),result=r if err==NONE else NONE,err=err)
            self.write_active=False
        elif name=='Invoke_ReturnSuccess':
            o['result']=self.run(d['run']);db=self.durable(raw);r=o['result']
            audit['acks']=unique(audit['acks']+[dict(request=o['req'],run=r,base=o['base'],kind=o['kind'])])
            available=r in audit['deleted'] or (db['runs'][r]['exists'] and all(c in db['nodes'] for c in db['cells'][r][:db['runs'][r]['n']]))
            if o['kind']=='reset' and not o['dedup'] and r not in audit['deleted']:
                available &= db['runs'][r]['base']==o['base'] and db['runs'][r]['cut']==o['cut'] and db['hist'][r][:o['cut']]==o['prefix']
                expected=[dict(e,kind='Admitted') if e['kind']=='Accepted' else e for e in o['expected']]
                audit['reapplyBad'] |= o['reapplied']!=expected or db['hist'][r][o['cut']+1:len(o['built'])]!=o['reapplied']
            audit['availableBad']|=not available;o['pc']='release-success'
        elif name=='ReleaseWorkflowLease':
            err=self.error(d['error']);name='ReleaseWorkflowLease_Success' if err==NONE else 'ReleaseWorkflowLease_Error'
            rt['leases']={r:NONE if holder==pid else holder for r,holder in rt['leases'].items()};rt['currentLock']=NONE
            if err==NONE:o['pc']='response'
            else:o.update(pc='done' if err in ('NotFound','DataLoss','InternalUpdateCollision') else 'retry',err=err)
        elif name=='ReceiveResetResponse':
            audit['receipts']=unique(audit['receipts']+[dict(request=o['req'],run=self.run(d['run']))]);o['pc']='done'
        elif name=='ReplayResetRequest':o['pc']='retry'
        elif name=='LoseResetResponse':o.update(pc='retry',err='ResponseLost')
        elif name=='CrashHistoryService':
            rt.update(state='stopped',leases={r:NONE for r in rt['leases']},currentLock=NONE,io=[])
        elif name=='BeginAcquireShard':rt['state']='acquiring'
        elif name=='RenewShardRange':pass
        elif name=='AcquireShard':rt.update(state='acquired',epoch=raw['range'])
        elif name=='DeleteWorkflowExecution':
            r=self.run(d['run']);args={'r':r};self.s['deletion'][r]['stage']='queued';audit['deleted']=unique(audit['deleted']+[r]);audit['admin']={q:v+1 for q,v in audit['admin'].items()}
        elif name=='DeleteExecutionTask':
            r=self.run(d['run']);args={'r':r};rt['leases'][r]='deletion';self.s['deletion'][r]['stage']='admit'
        elif name=='DeleteWorkflowExecution_AcquireIO':
            r=self.run(d['run']);args={'r':r};rt['io']=unique(rt['io']+[r]);self.s['deletion'][r].update(stage='current',epoch=d['range'])
        elif name=='DeleteCurrentWorkflowExecution':
            r=self.run(d['run']);args={'r':r};self.s['deletion'][r]['stage']='mutable'
        elif name=='DeleteWorkflowMutableState':
            r=self.run(d['run']);args={'r':r};self.s['deletion'][r]['stage']='plan';rt['io']=[x for x in rt['io'] if x!=r]
        elif name=='GetHistoryTreeContainingBranch':
            request=d['request'];r=self.branch_run[request['BranchInfo']['branch_id']];args={'r':r};plan=[]
            # Project the actual ranges, including physically absent possible cells.
            for dr in request['BranchRanges']:
                owner=self.branch_run[dr['BranchId']];first=dr['BeginNodeId']
                normalized=1+sum(1 for (rr,eid) in self.event_at if rr==owner and eid<first)
                plan.extend([owner,i] for i in range(normalized,self.config['historyLimit']+1))
            self.s['deletion'][r].update(stage='delete',plan=unique(plan))
        elif name=='DeleteHistoryBranch_SQL':
            r=self.run(d['run']);args={'r':r};self.s['deletion'][r]['stage']='done';rt['leases'][r]=NONE
        else:raise ValueError(f'unhandled observed event {name}')
        self.emit(row,name,args)
        if name=='ReceiveResetResponse' and self.nested_start and pid=='q':self.active_pid='p';self.nested_start=False

    def run_all(self):
        for self.line,row in enumerate(self.rows,1):self.observe(row)
        self.config['startIDs']=unique(list(self.starts.values())) or ['unused-start']
        self.config['updateIDs']=[x for x in self.idset if x not in self.config['startIDs'] and x not in self.resetids] or ['unused-update']
        self.config['payloads']=self.payloads or ['unused-payload']
        return self.emitted

def main():
    p=argparse.ArgumentParser();p.add_argument('raw',type=Path);p.add_argument('trace',type=Path);args=p.parse_args()
    rows=[decode_oneofs(json.loads(line)) for line in args.raw.read_text().splitlines()]
    projection=Projection(rows);trace=projection.run_all()
    args.trace.parent.mkdir(parents=True,exist_ok=True)
    args.trace.write_text(''.join(json.dumps(row,separators=(',',':'))+'\n' for row in trace))
    report=dict(raw=str(args.raw),trace=str(args.trace),runIDs=projection.runs,branchIDs=projection.branch_run,eventIDs=projection.eventmap,sourceLines=projection.source_lines,projectionIssues=projection.issues,checkpoints=projection.checkpoints,events={name:sum(e['event']==name for e in trace) for name in sorted({e['event'] for e in trace})},audit=projection.s['audit'])
    args.trace.with_suffix('.evidence.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'{args.trace.name}: {len(trace)} events, {len(report["events"])} event types, {len(projection.issues)} projection gaps')

if __name__=='__main__':main()
