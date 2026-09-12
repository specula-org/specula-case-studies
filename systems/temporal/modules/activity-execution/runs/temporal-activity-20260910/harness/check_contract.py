#!/usr/bin/env python3
"""Record direct observations against the original supplied model assumptions."""
import datetime,json,sys
from pathlib import Path
root=Path(sys.argv[1]);result={'status':'INCOMPLETE','findings':[]}
for p in sorted((root/'raw').glob('*.jsonl')):
 rows=[json.loads(x) for x in p.read_text().splitlines()]
 events=[r for r in rows if r['tag']=='trace']
 events=events[next(i for i,r in enumerate(events) if r['event']=='Bootstrap'):]
 for i,r in enumerate(events):
  o=r['observation']
  if r['event']=='NotifyOnExecutionMutation':
   after=next((x for x in events[i+1:] if x['event']=='FinishUpdateWorkflowExecution'),None)
   if after:
    result['findings'].append({'kind':'notification-before-finish','scenario':p.stem,'notificationRawSeq':r['seq'],'finishRawSeq':after['seq'],
     'dbRecordVersion':o['dbRecordVersion'],'suppliedModelConflict':'FinishUpdateWorkflowExecution creates notifyPending; NotifyOnExecutionMutation requires membership in notifyPending'})
    break
 for i,r in enumerate(events):
  if r['event']=='PersistenceTimeoutBeforeWrite':
   prior=next(x for x in reversed(events[:i]) if x['event'] in ['SetAndTrackTaskKeys','AppendHistoryNodes'])
   if prior['event']=='SetAndTrackTaskKeys':
    result['findings'].append({'kind':'prewrite-timeout-skips-history-append','scenario':p.stem,'preparedRawSeq':prior['seq'],'timeoutRawSeq':r['seq'],
     'suppliedModelConflict':'PersistenceTimeoutBeforeWrite requires Waiting, but actual injection skips the SQL store and its AppendHistoryNodes stage'})
 closes={}
 for r in events:
  o=r['observation']
  if r['event']=='CloseTransactionAsMutation':closes[o['mutation']['DBRecordVersion']]=r
  if r['event']=='SetAndTrackTaskKeys':
   req=o['request']['UpdateWorkflowMutation'];prev=closes.get(req['DBRecordVersion'])
   if not prev:continue
   before=prev['observation']['mutation']['Tasks']
   for category,tasks in req['Tasks'].items():
    for index,t in enumerate(tasks):
     old=before.get(category,[])
     if index<len(old) and old[index]['VisibilityTimestamp']!=t['VisibilityTimestamp']:
      result['findings'].append({'kind':'task-visibility-changed-at-key-allocation','scenario':p.stem,
       'closeRawSeq':prev['seq'],'allocatedRawSeq':r['seq'],'category':category,'taskId':t['TaskID'],
       'before':old[index]['VisibilityTimestamp'],'after':t['VisibilityTimestamp'],
       'suppliedModelConflict':'SetAndTrackTaskKeys changes only id; generated task due remains unchanged in base.tla'})
       
(root/'contract-findings.json').write_text(json.dumps(result,indent=2)+'\n')
print('Recorded',len(result['findings']),'source-observed contract discrepancies; no Temporal bug conclusion.')
