from pathlib import Path
import subprocess,json,re,hashlib,os
P=Path(__file__).resolve().parent
lib='/home/ubuntu/nvflare-job-lifecycle-20260914/specula/lib'
jarcp=lib+'/tla2tools.jar:'+lib+'/CommunityModules-deps.jar'
subprocess.run(['javac','-cp',lib+'/tla2tools.jar','-d','/home/ubuntu/nvflare-job-lifecycle-20260914/scratch/tmp',str(P/'output'/'SpecGenerationCheck.java')],check=True,timeout=60)
results=[]
for module in ['base','MC','Trace']:
 r=subprocess.run(['java','-Xmx1g','-DTLA-Library='+lib,'-cp',jarcp,'tla2sany.SANY',module+'.tla'],cwd=P,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60)
 (P/('sany-'+module+'.log')).write_text(r.stdout)
 ok=r.returncode==0 and not re.search(r'\*\*\* (?:Errors|Parse Error)|Semantic errors|Fatal errors',r.stdout)
 results.append({'check':'SANY','module':module,'ok':ok})
 assert ok,r.stdout
base=['java','-Xmx1g','-DTLA-Library='+lib,'-cp','/home/ubuntu/nvflare-job-lifecycle-20260914/scratch/tmp:'+jarcp,'SpecGenerationCheck']
for c in sorted(P.glob('*.cfg')):
 module='Trace' if c.name=='Trace.cfg' else 'base' if c.name=='base.cfg' else 'MC'
 env=dict(os.environ)
 if module=='Trace':env['JSON']=str(P/'output'/'schema-smoke.ndjson')
 r=subprocess.run(base+[module,c.name],cwd=P,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60,env=env)
 (P/'output'/('initial-'+c.stem+'.log')).write_text(r.stdout)
 assert r.returncode==0,r.stdout
 m=re.search(r'successors=(\d+)',r.stdout)
 results.append({'check':'cfg/init/one-step expressions','cfg':c.name,'ok':True,'successors':int(m[1]),'syntheticTraceFixture':module=='Trace'})
actions=json.loads((P/'actions.json').read_text());hooks=json.loads((P/'instrumentation-hooks.json').read_text())
base_text=(P/'base.tla').read_text();trace_text=(P/'Trace.tla').read_text();mc_text=(P/'MC.tla').read_text()
names={a['name'] for a in actions}
assert len(names)==len(actions)==len(hooks) and len(actions)>=116
assert names=={a['name'] for a in hooks}
for a in actions:
 name=a['name']
 assert re.search(r'^'+re.escape(name)+r'(?:\([^\n]*\))? ==$',base_text,re.M)
 assert len(re.findall(r'^Trace'+re.escape(name)+r'\(',trace_text,re.M))==1
 assert 'Base!'+name in trace_text
 for source in a['source'].split('; '):
  path,lines=source.split(':');text=Path('/home/ubuntu/nvflare-job-lifecycle-20260914/source',path).read_text()
  for n in lines.split('-'):assert 1<=int(n)<=len(text.splitlines()),source
 if a['fault']:
  assert 'faults.'+a['fault']+' < Limits.'+a['fault'] in mc_text
  assert '!.'+a['fault']+' = @+1' in mc_text
 assert set(a['updates']) <= {'scheduler','jobs','rm','client','resourceEnv','rpc','network'}
assert 'PROPERTIES TraceMatched' in (P/'Trace.cfg').read_text()
assert not re.search(r'ValidatePostState[^\n]*==\s*TRUE',trace_text)
results.append({'check':'action/wrapper/hook identity and source anchors','ok':True,'actions':len(actions)})
subprocess.run(['python','generate-coverage.py'],cwd=P,check=True)
results.append({'check':'actual hunt cfg coverage','ok':True,'scenarios':5,'safetyProperties':6,'MCFindings':4,'huntConfigs':8})
(P/'output'/'generation-check-results.json').write_text(json.dumps(results,indent=2)+'\n')
required=['base.tla','base.cfg','MC.tla','MC.cfg','brief-coverage.md','Trace.tla','Trace.cfg','instrumentation-spec.md']
files=required+[p.name for p in sorted(P.glob('MC_hunt_*.cfg'))]
(P/'artifact-hashes.json').write_text(json.dumps({'sourceRevision':'53ba7ee567468ea7971dad4faccef13c6cb35dc2','sha256':{f:hashlib.sha256((P/f).read_bytes()).hexdigest() for f in files}},indent=2)+'\n')
print(json.dumps(results,indent=2))
