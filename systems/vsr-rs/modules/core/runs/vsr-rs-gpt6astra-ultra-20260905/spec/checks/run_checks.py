"""Generation checks, NOT a full protocol verification or Rust trace run."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import subprocess, os, json, hashlib, sys
root=Path(__file__).resolve().parent.parent
checks=root/'checks'
jar=Path(os.environ.get('TLA_JAR','/home/ubuntu/Specula-incremental-dataset-20260815/tools/tla2tools.jar'))
community=Path(os.environ.get('COMMUNITY_JAR',str(jar.with_name('CommunityModules-deps.jar'))))
cp=str(jar)+os.pathsep+str(community)
java=['java','-XX:+UseParallelGC','-Xmx1g','-cp',cp]
results=[]
def run(name,args,kind='tlc',env=None):
 log=checks/(name+'.log')
 with log.open('w') as f:
  p=subprocess.run(java+args,cwd=root,env=os.environ|(env or {}),stdout=f,stderr=subprocess.STDOUT,timeout=240)
 text=log.read_text()
 if kind=='negative':ok='Temporal property TraceMatched was violated.' in text and 'unexpected exception' not in text
 elif kind=='sany':ok='Semantic processing of module' in text and not any(x in text for x in ['*** Errors:','***Parse Error','Semantic errors:'])
 elif kind=='simulation':ok=p.returncode==0 and 'Simulation using seed 20260905' in text and 'Error:' not in text
 else:ok=p.returncode==0 and 'Model checking completed. No error has been found.' in text
 r={'name':name,'kind':kind,'passed':ok,'returncode':p.returncode,'command':java+args,'env':env or {},'log':str(log.relative_to(root))}
 print(name+': '+('PASS' if ok else 'FAIL'),flush=True)
 return r
def tlc(name,cfg,module='MC',extra=(),kind='tlc',env=None):
 return run(name,['tlc2.TLC','-noGenerateSpecTE','-config',cfg,'-metadir',f'checks/states_{name}',*extra,module],kind,env)
for mod in ['base','MC','Trace']:
 results.append(run(mod+'-sany',['tla2sany.SANY',mod+'.tla'],'sany'))
results.append(tlc('MC-tiny','checks/MC_tiny.cfg'))
configs=[('MC','MC.cfg')]+[(p.stem.removeprefix('MC_hunt_'),p.name) for p in sorted(root.glob('MC_hunt_*.cfg'))]
def smoke(item):
 name,cfg=item
 return tlc(name+'-smoke',cfg,extra=['-simulate','num=20','-depth','150','-seed','20260905','-workers','1'],kind='simulation')
with ThreadPoolExecutor(max_workers=3) as pool:results.extend(pool.map(smoke,configs))
results.append(tlc('fixture-build','checks/Fixture.cfg','checks/Fixture.tla'))
results.append(tlc('trace-positive','Trace.cfg','Trace',env={'JSON':'checks/trace-fixture.ndjson'}))
subprocess.run([sys.executable,'checks/mutate_trace.py'],cwd=root,check=True)
for name in ['postcommit','apply-result','packet-opn','omitted-persist','first-event']:
 results.append(tlc('trace-negative-'+name,'Trace.cfg','Trace',kind='negative',env={'JSON':f'checks/trace-negative-{name}.ndjson'}))
subprocess.run([sys.executable,'checks/audit_cfg.py'],cwd=root,check=True)
manifest={'source_revision':'3ac0104a567092139534c9022205d02281a2da41','tool_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [jar,community]},'checks':results}
(checks/'validation-results.json').write_text(json.dumps(manifest,indent=2)+'\n')
sys.exit(0 if all(r['passed'] for r in results) else 1)
