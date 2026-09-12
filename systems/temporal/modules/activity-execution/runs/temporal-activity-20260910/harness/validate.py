#!/usr/bin/env python3
"""Run the unchanged full-state/endpoint checks, and retain non-passing results."""
import argparse,hashlib,json,os,subprocess,time
from pathlib import Path
h=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--evidence',type=Path,required=True);p.add_argument('--traces',type=Path,required=True);a=p.parse_args()
jar=Path(os.environ.get('TLA_JAR','/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/Specula/lib/tla2tools.jar'))
community=Path(os.environ.get('COMMUNITY_JAR','/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/Specula/lib/CommunityModules-deps.jar'))
spec=h.parent/'spec';dest=a.evidence/'validation';dest.mkdir(parents=True,exist_ok=True)
assert 'PROPERTIES TraceMatched' in (spec/'Trace.cfg').read_text()
assert "s' = DecodeState(logline.state)" in (spec/'Trace.tla').read_text()
result={'status':'INCOMPLETE','toolHashes':{str(x):hashlib.sha256(x.read_bytes()).hexdigest() for x in [jar,community]},
 'specHashes':{x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in [spec/'Trace.tla',spec/'Trace.cfg',spec/'base.tla']},'runs':[]}
for trace in sorted(a.traces.glob('*.ndjson')):
 cmd=['timeout','60','java','-Xmx2g','-cp',str(jar)+':'+str(community),'tlc2.TLC','-workers','1','-metadir',str(dest/(trace.stem+'-states')),'-config','Trace.cfg','Trace']
 env=dict(os.environ,JSON=str(trace.resolve()))
 start=time.monotonic()
 with (dest/(trace.stem+'.log')).open('w') as log:
  done=subprocess.run(cmd,cwd=spec,env=env,stdout=log,stderr=subprocess.STDOUT)
 result['runs'].append({'trace':str(trace),'command':cmd,'JSON':env['JSON'],'exitCode':done.returncode,'seconds':round(time.monotonic()-start,3),
 'status':'PASS' if done.returncode==0 else 'INCOMPLETE'})
 print(f'{trace.stem}: TLC exit {done.returncode}')
result['completeReplays']=sum(r['status']=='PASS' for r in result['runs'])
if result['runs'] and result['completeReplays']==len(result['runs']):result['status']='PASS'
(a.evidence/'validation-results.json').write_text(json.dumps(result,indent=2)+'\n')
raise SystemExit(0 if result['status']=='PASS' else 2)
