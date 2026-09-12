#!/usr/bin/env python3
"""Collect real observations without inventing the missing full-model projection."""
import argparse,collections,copy,datetime,hashlib,json,re
from pathlib import Path

def check(rows):
 configs=[r for r in rows if r['tag']=='config']
 assert len(configs)==1,'exactly one config required'
 events=[r for r in rows if r['tag']=='trace']
 assert events and events[-1]['event']=='FinishTrace','missing final implementation endpoint'
 snapshots={};commits=0;tokens=0
 for i,r in enumerate(events,1):
  assert r['seq']==i,'source sequence is discontinuous'
  stamp=datetime.datetime.fromisoformat(r['ts'].replace('Z','+00:00'))
  assert stamp.year>=2000,'non-real timestamp'
  o=r['observation']
  if r['event']=='CloseTransactionAsMutation':
   v=o['mutation']['DBRecordVersion'];snapshots[v]=o['cache']['mutableState']['activity_infos']
  if r['event']=='ApplyWorkflowMutationTx' and o.get('commitConfirmed'):
   db=o['sqlSnapshot'];v=db['dbRecordVersion']
   assert v in snapshots,f'no precommit cache snapshot for version {v}'
   assert db['activityInfos']==snapshots[v],f'cache/SQL ActivityInfo mismatch at source seq {r["seq"]}, DB version {v}'
   commits+=1
  if r['event']=='DeliverPollActivityTaskQueueResponse':
   tok=o['token'];response=o['response']
   assert int(tok['attempt'])==response['attempt'],'worker token/response attempt mismatch'
   assert tok['workflow_id']==r['identity']['workflowId'],'wrong token Workflow'
   assert tok['run_id']==r['identity']['runId'],'wrong token Run'
   tokens+=1
 final=events[-1]['observation']
 assert final['implementationEndpointComplete'] is True
 db=final['finalReadback']['database_mutable_state']
 assert db['activity_infos']=={},'endpoint has pending activities'
 assert db['buffered_events']==[],'endpoint has buffered terminal events'
 assert int(db['execution_info']['workflow_task_scheduled_event_id'])==0,'endpoint has pending WFT'
 assert int(db['execution_info']['workflow_task_started_event_id'])==0,'endpoint has started WFT'
 assert final['terminalEventsConsumed'],'worker did not consume a terminal event'
 return {'independentCacheSQLComparisons':commits,'deliveredTokenComparisons':tokens}

def controls(rows):
 outcomes=[]
 for name in ['wrong_attempt','wrong_durable_activity_map','missing_endpoint','missing_SQL_state_field']:
  bad=copy.deepcopy(rows)
  if name=='wrong_attempt':
   ev=next((r for r in bad if r.get('event')=='DeliverPollActivityTaskQueueResponse'),None)
   if ev is None:
    # Scheduled timeout/cancellation never deliver a token: use an actual AI row.
    ev=next(r for r in bad if r.get('event')=='ApplyWorkflowMutationTx' and r['observation']['sqlSnapshot']['activityInfos'])
    next(iter(ev['observation']['sqlSnapshot']['activityInfos'].values()))['attempt']+=1
   else:ev['observation']['response']['attempt']+=1
  elif name in ['wrong_durable_activity_map','missing_SQL_state_field']:
   ev=next(r for r in bad if r.get('event')=='ApplyWorkflowMutationTx' and r['observation']['sqlSnapshot']['activityInfos'])
   if name=='wrong_durable_activity_map':ev['observation']['sqlSnapshot']['activityInfos']={}
   else:del ev['observation']['sqlSnapshot']['activityInfos']
  else:bad=[r for r in bad if r.get('event')!='FinishTrace']
  try:check(bad)
  except (AssertionError,KeyError) as e:outcomes.append({'control':name,'result':'REJECTED','reason':str(e)})
  else:raise AssertionError('raw observation control unexpectedly accepted: '+name)
 return outcomes

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--evidence',type=Path,required=True);parser.add_argument('--traces',type=Path,required=True);a=parser.parse_args()
 from project import Projector
 a.traces.mkdir(parents=True,exist_ok=True)
 result={'status':'PROJECTED','formalCompleteTraces':0,'scenarios':[],'controlsKind':'raw observation audit; TLC replay and its negative controls are separate'}
 coverage=collections.Counter()
 for p in sorted((a.evidence/'raw').glob('*.jsonl')):
  rows=[json.loads(line) for line in p.read_text().splitlines()]
  audit=check(rows);negative=controls(rows)
  try:
   projector=Projector(p.resolve());events=projector.process()
  except Exception as error:
   result['status']='INCOMPLETE';result['scenarios'].append({'name':p.stem,'implementationEndpoint':'PASS','modelReplay':'INCOMPLETE','projectionError':str(error)})
   (a.evidence/'collection-results.json').write_text(json.dumps(result,indent=2)+'\n')
   raise
  target=a.traces/(p.stem+'.ndjson')
  target.write_text(''.join(json.dumps(e,separators=(',',':'))+'\n' for e in events))
  coverage.update(e['event'] for e in events)
  provenance={'raw':str(p.resolve()),'rawSHA256':hashlib.sha256(p.read_bytes()).hexdigest(),'projectorSHA256':hashlib.sha256(Path(__file__).with_name('project.py').read_bytes()).hexdigest(),'activityIds':projector.activity_ids,'requests':projector.requests,'tasks':projector.task_ids,'observationRoles':projector.used,'events':len(events)}
  target.with_suffix('.provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
  result['scenarios'].append({'name':p.stem,'implementationEndpoint':'PASS','modelReplay':'PENDING','lines':len(events),'rawLines':len(rows),'rawSHA256':provenance['rawSHA256'],'traceSHA256':hashlib.sha256(target.read_bytes()).hexdigest(),**audit,'controls':negative})
  print(f'{p.stem}: {len(events)} complete independently projected events; TLC pending')
 result['eventCounts']=dict(sorted(coverage.items()));result['observedEventTypes']=len(coverage)
 (a.evidence/'collection-results.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':main()
