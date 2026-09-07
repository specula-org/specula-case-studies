"""Fast assembly checks. No broad hunt or implementation conformance claim."""
from pathlib import Path
import argparse,json,os,subprocess
p=argparse.ArgumentParser();p.add_argument('--tla-jar',required=True);p.add_argument('--community-jar',required=True);args=p.parse_args()
root=Path(__file__).resolve().parent.parent
cp=os.pathsep.join([str(Path(args.tla_jar).resolve()),str(Path(args.community_jar).resolve())])
java=['java','-Xmx2g','-XX:+UseParallelGC','-Djava.io.tmpdir='+str(root/'validation/tmp'),'-cp',cp]
results=[]
def run(name,cmd,expected=0,env=None,need=None):
 out=root/'validation'/f'{name}.log'
 with out.open('w') as f:r=subprocess.run(cmd,cwd=root,stdout=f,stderr=subprocess.STDOUT,env=env,timeout=60)
 data=out.read_text()
 ok=r.returncode==expected and (need is None or need in data)
 if expected==0:ok=ok and 'Error:' not in data and 'Semantic errors:' not in data
 results.append(dict(check=name,exit=r.returncode,passed=ok,log=str(out.relative_to(root))))
 assert ok, (name,r.returncode,str(out))
for module in ['base','MC','Trace']:
 run(module+'-sany',java+['tla2sany.SANY',module+'.tla'],need='Semantic processing of module '+module)
for cfg in sorted(root.glob('MC*.cfg')):
 run('load-'+cfg.stem,java+['tlc2.TLC','-workers','1','-simulate','num=1','-depth','1','-seed','20260906','-noGenerateSpecTE','-metadir','validation/states-load-'+cfg.stem,'-config',cfg.name,'MC'],need='Finished computing initial states:')
for case in ['good','bad-state','bad-reply','missing-persist']:
 env=dict(os.environ,JSON='validation/trace-synthetic-'+case+'.ndjson')
 run('trace-'+case,java+['tlc2.TLC','-workers','1','-noGenerateSpecTE','-metadir','validation/states-trace-'+case,'-config','Trace.cfg','Trace'],expected=0 if case=='good' else 13,env=env,need='No error has been found' if case=='good' else 'Temporal properties were violated')
subprocess.run(['python3','validation/audit_coverage.py'],cwd=root,check=True)
(root/'validation/assembly-results.json').write_text(json.dumps(results,indent=2)+'\n')
print('Assembly checks passed:',len(results))
