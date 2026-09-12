from pathlib import Path
import subprocess,json,hashlib,re
O=Path(__file__).resolve().parent.parent
J='/home/ubuntu/Specula-incremental-dataset-20260815/tools/tla2tools.jar'
C='/home/ubuntu/Specula-incremental-dataset-20260815/tools/CommunityModules-deps.jar'
java=['java','-XX:+UseParallelGC','-Xmx2g','-cp',J+':'+C]
def run(args,log,env=None,timeout=60):
 import os
 with (O/'validation'/log).open('w') as f:
  r=subprocess.run(args,cwd=O,stdout=f,stderr=subprocess.STDOUT,env=os.environ|(env or {}),timeout=timeout)
 return r.returncode
results=[]
for mod in ['base','MC','Trace']:
 e=run(java+['tla2sany.SANY',mod+'.tla'],mod.lower()+'-sany.log')
 out=(O/'validation'/(mod.lower()+'-sany.log')).read_text()
 assert '*** Errors:' not in out and '***Parse Error***' not in out,(mod,e)
 results.append(dict(check='SANY '+mod,exit=e))
e=run(java+['tlc2.TLC','-workers','2','-config','MC.cfg','MC'],'mc-convergence.log');assert e==0,e
results.append(dict(check='MC.cfg complete BFS',exit=e))
subprocess.run(['python3','validation/make_fixture.py'],cwd=O,check=True)
e=run(java+['tlc2.TLC','-workers','1','-config','validation/Fixture.cfg','Fixture'],'fixture-generator.log');assert e==0,e
events=[]
for line in (O/'validation'/'fixture-generator.log').read_text().splitlines():
 try:
  v=json.loads(line)
  if isinstance(v,str):v=json.loads(v)
  if isinstance(v,dict) and v.get('tag')=='temporal-reset':events.append(v)
 except (ValueError,TypeError):pass
assert len(events)==30,len(events)
(O/'validation'/'synthetic-fixture.ndjson').write_text(''.join(json.dumps(e,separators=(',',':'))+'\n' for e in events))
bad=json.loads(json.dumps(events));bad[4]['state']['db']['runs']['a']['create']='incorrect-start-id'
(O/'validation'/'synthetic-corrupt.ndjson').write_text(''.join(json.dumps(e,separators=(',',':'))+'\n' for e in bad))
for name,want in [('positive',0),('negative',13)]:
 fixture='synthetic-fixture.ndjson' if name=='positive' else 'synthetic-corrupt.ndjson'
 e=run(java+['tlc2.TLC','-workers','1','-config','Trace.cfg','Trace'],'trace-'+name+'.log',env={'JSON':'validation/'+fixture})
 log=(O/'validation'/('trace-'+name+'.log')).read_text()
 if name=='positive':assert e==0,e
 else:assert 'Temporal property TraceMatched was violated' in log,e
 results.append(dict(check='synthetic Trace '+name,exit=e))
 print('synthetic Trace',name,e,flush=True)
smokes=[]
for p in sorted(O.glob('MC_hunt_*.cfg')):
 if 'liveness' in p.name:continue
 logfile=p.stem+'-smoke.log'
 cmd=java+['tlc2.TLC','-workers','1','-coverage','1','-config',p.name,'-simulate','num=60','-depth','250','-seed','753','MC']
 e=run(cmd,logfile,timeout=60)
 out=(O/'validation'/logfile).read_text();errors=[line for line in out.splitlines() if line.startswith('Error:')]
 known='scenario1_2' in p.name and 'Invariant ImmediateRetryIdentity is violated' in out
 sensitivity='short_age' in p.name and any('Invariant ReachableHistoryRetained is violated' in x or 'Invariant AcknowledgedResetExists is violated' in x for x in errors)
 assert e==0 or known or sensitivity,(p.name,e,errors)
 smokes.append(dict(config=p.name,exit=e,known_T1=known,short_age_sensitivity=sensitivity,errors=errors,log='validation/'+logfile))
 print(p.name,e,'known T1' if known else 'smoke complete',flush=True)
(O/'validation'/'hunt-smoke-results.json').write_text(json.dumps(smokes,indent=2)+'\n')
# Evaluate liveness configuration / fairness expression without claiming a search.
e=run(java+['tlc2.TLC','-workers','1','-config','MC_hunt_scenario2_liveness.cfg','-simulate','num=1','-depth','1','MC'],'liveness-config-smoke.log')
assert e==0,e
results.append(dict(check='liveness cfg initialization only',exit=e))
(O/'validation'/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
files=sorted(list(O.glob('*.tla'))+list(O.glob('*.cfg'))+list(O.glob('*.md')))
(O/'validation'/'artifact-sha256.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2)+'\n')
