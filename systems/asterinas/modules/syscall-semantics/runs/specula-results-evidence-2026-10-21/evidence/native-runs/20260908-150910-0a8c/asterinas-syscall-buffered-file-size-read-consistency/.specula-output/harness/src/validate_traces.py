#!/usr/bin/env python3
import json,os,subprocess,sys,re,hashlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
H=Path(__file__).resolve().parents[1]; O=H.parent
java=os.environ.get('SPECULA_JAVA','/nix/store/31fzvd0bv67sxmxdq5rp47zl57qbqfbg-openjdk-headless-21.0.12+8/bin/java')
root=Path(os.environ.get('SPECULA_ROOT','/home/chin39/Documents/play/Specula'))
spec=Path(os.environ.get('SPECULA_TRACE_SPEC',str(O/'spec')))
label='tlc' if spec==O/'spec' else 'tlc-proposed'
(H/'logs'/label).mkdir(parents=True,exist_ok=True)
result=[]
paths=[Path(x).resolve() for x in sys.argv[1:]] or sorted((O/'traces').glob('*.ndjson'))
def validate(path):
    log=H/'logs'/label/(path.stem+'.log'); env=dict(os.environ,JSON=str(path))
    command=['timeout','60',java,'-XX:+UseParallelGC','-Xmx2G','-cp',str(root/'lib/tla2tools.jar')+':'+str(root/'lib/CommunityModules-deps.jar'),
             'tlc2.TLC','-workers','1','-config','Trace.cfg','Trace.tla','-lncheck','final','-metadir',str(H/'build'/(label+'-'+path.stem))]
    with log.open('w') as f: proc=subprocess.run(command,cwd=spec,env=env,stdout=f,stderr=subprocess.STDOUT)
    body=log.read_text(); passed=proc.returncode==0 and 'No error has been found.' in body
    witness=None
    if not passed and proc.returncode==13 and 'Temporal property TraceMatched was violated' in body:
        witness_log=log.with_name(path.stem+'-witness.log')
        witness_command=[x.replace('Trace.cfg','Trace_witness.cfg') for x in command]
        witness_command[-1]+='-witness'
        with witness_log.open('w') as f: witness_proc=subprocess.run(witness_command,cwd=spec,env=env,stdout=f,stderr=subprocess.STDOUT)
        body=witness_log.read_text()
        cursors=re.findall(r'/\\ l = \[(.*?)\]',body,re.S)
        final=dict((tid,int(cursor)) for tid,cursor in re.findall(r'(t\d+) \|-> (\d+)',cursors[-1])) if cursors else {}
        expected={tid:len(events)+1 for tid,events in json.loads(path.read_text())['traces'].items()}
        passed=witness_proc.returncode==12 and 'Invariant TraceNotComplete is violated' in body and final==expected
        witness={'exit_code':witness_proc.returncode,'fully_consumed':passed,'final_cursors':final,'expected_cursors':expected,'log':str(witness_log.relative_to(O))}
    entry={'trace':str(path.relative_to(O)),'trace_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'exit_code':proc.returncode,'matched':passed,'log':str(log.relative_to(O)),'witness':witness}
    print(path.name, 'matched' if passed else 'FAILED', 'exit='+str(proc.returncode),flush=True)
    return entry
with ThreadPoolExecutor(max_workers=4) as pool:
    result=list(pool.map(validate,paths))
(H/('validation.json' if label=='tlc' else 'validation-proposed.json')).write_text(json.dumps(result,indent=2)+'\n')
sys.exit(0 if result and all(r['matched'] for r in result) else 1)
