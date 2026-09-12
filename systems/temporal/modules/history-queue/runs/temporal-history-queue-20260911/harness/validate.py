#!/usr/bin/env python3
import argparse, collections, copy, json, os, pathlib, re, subprocess

parser=argparse.ArgumentParser();parser.add_argument('--evidence',type=pathlib.Path,required=True);parser.add_argument('--controls',action='store_true');args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parent.parent;spec=root/'spec';evidence=args.evidence.resolve();evidence.mkdir(parents=True,exist_ok=True)
cp=str(root/'harness/tools/tla2tools.jar')+':'+str(root/'harness/tools/CommunityModules-deps.jar')
results=[]
def check(name,path,negative=False):
 log=evidence/(name+'.log');meta=evidence/(name+'-states');env=dict(os.environ,JSON=str(path.resolve()))
 command=['timeout','120','java','-XX:+UseParallelGC','-Xmx2g','-cp',cp,'tlc2.TLC','-workers','1','-metadir',str(meta),'-config','Trace.cfg','Trace.tla']
 with log.open('w') as f:r=subprocess.run(command,cwd=spec,env=env,stdout=f,stderr=subprocess.STDOUT)
 text=log.read_text();ok=(r.returncode==0 and 'No error has been found' in text) if not negative else (r.returncode!=0 and ('TraceMatched was violated' in text or 'missing complete Endpoint' in text))
 results.append(dict(name=name,path=str(path),negative=negative,returncode=r.returncode,passed=ok,command=command,log=str(log)))
 print(f'{name}: '+('rejected as expected' if negative and ok else 'PASS' if ok else 'FAIL'),flush=True)
 return ok

traces={}
for path in sorted((root/'traces').glob('*.ndjson')):
 rows=[json.loads(l) for l in path.read_text().splitlines()];assert rows[0]['event']=='Init' and rows[-1]['event']=='Endpoint'
 assert all(r['tag']=='trace' and 'T' in r['ts'] and r['seq']==i+1 for i,r in enumerate(rows))
 assert all(r['provenance']=='implementation' for r in rows)
 traces[path.stem]=rows;check(path.stem,path)
if not all(r['passed'] for r in results):
 (evidence/'validation.json').write_text(json.dumps(results,indent=2));raise SystemExit(1)

if args.controls:
 healthy=traces['healthy'];batched=traces['batched_checkpoint'];mutants={}
 def at(rows,name):return next(r for r in rows if r['event']==name)
 rows=copy.deepcopy(healthy);r=at(rows,'Ack');task=r['post']['ex'][r['args']['e']-1]['task'];r['post']['db']['matching'].remove(task);mutants['ack_without_responsibility']=rows
 rows=copy.deepcopy(healthy);at(rows,'UpdateWorkflowExecutionCommit')['post']['db']['rows']=[];mutants['omitted_pending_original']=rows
 rows=copy.deepcopy(healthy);at(rows,'ProcessNewRange')['post']['q'][0]['lists'][0][0]['pred']=['g2'];mutants['wrong_predicate']=rows
 rows=copy.deepcopy(healthy);at(rows,'SelectTasks')['post']['q'][0]['cursor'][0]=0;mutants['wrong_cursor']=rows
 rows=copy.deepcopy(batched);r=at(rows,'SetQueueStateBatched');r['post']['db']['queue']=copy.deepcopy(r['post']['q'][0]['memory']);assert r['post']['db']['queue']!=at(batched,'SetQueueStateBatched')['post']['db']['queue'];mutants['volatile_claimed_durable']=rows
 mutants['truncated_endpoint']=copy.deepcopy(healthy[:-1])
 rows=copy.deepcopy(healthy);rows.remove(at(rows,'UpdateWorkflowExecutionCommit'));mutants['omitted_commit']=rows
 rows=copy.deepcopy(healthy);rows.remove(at(rows,'MatchingReply'));mutants['omitted_reply']=rows
 for name,rows in mutants.items():
  for i,r in enumerate(rows):r['seq']=i+1;r['provenance']='synthetic-spec-test'
  path=evidence/(name+'.ndjson');path.write_text(''.join(json.dumps(r,separators=(',',':'))+'\n' for r in rows));check(name,path,True)

text=(spec/'Trace.tla').read_text();assert "s' = DecodeState(e.post)" in text
wrappers=re.findall(r'\nTrace(\w+) ==\n(.*?)(?=\nTrace|\n\\\*|\n====)',text,re.S)
actions=set(re.findall(r'Evt.event = "([A-Za-z]+)"',text))-{'Endpoint'}
counts=collections.Counter(r['event'] for rows in traces.values() for r in rows)
coverage=dict(action_count=len(actions),observed_actions=sorted(actions & counts.keys()),uncovered_actions=sorted(actions-counts.keys()),counts=dict(sorted(counts.items())),trace_lengths={n:len(rs) for n,rs in traces.items()},full_post_state_equality=True,all_wrappers_validate=all('ValidatePostState' in body for name,body in wrappers if name not in ['Init','Next','Spec','Step','Matched']))
(evidence/'coverage.json').write_text(json.dumps(coverage,indent=2));(evidence/'validation.json').write_text(json.dumps(results,indent=2))
if not all(r['passed'] for r in results):raise SystemExit(1)
print(f"Coverage: {len(coverage['observed_actions'])}/{len(actions)} actions; all {len(results)} replay/control checks passed")
