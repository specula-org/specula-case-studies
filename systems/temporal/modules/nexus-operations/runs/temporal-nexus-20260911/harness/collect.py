#!/usr/bin/env python3
import os,pathlib,subprocess,time,json,sys,hashlib
H=pathlib.Path(__file__).resolve().parent
S=pathlib.Path(os.environ.get('TEMPORAL_SOURCE','/home/ubuntu/temporal-investigation-20260909/parallel-20260911/source-nexus'))
T=pathlib.Path(os.environ.get('TRACE_DIR',str(H.parent/'traces')))
T.mkdir(parents=True,exist_ok=True)
modes=sys.argv[1:] or ['healthy_async','early_callback','response_loss','definite_failure','execute_timeout','deferred_cancel','healthy_timeout','timeout_capacity','sync_capacity','start_retry','sync_failed','sync_canceled','buffered_callback','below_min','start_refused','cancel_retry','cancel_refused','start_definite_failure','start_execute_timeout','cancel_below_min','stale_timer']
results=[]
binary_hash=hashlib.sha256((H/"evidence"/"nexus-tests").read_bytes()).hexdigest()
for mode in modes:
    path=T/f'{mode}.ndjson'; log=H/'evidence'/f'{mode}.log'
    if path.exists():
        archive=H/'evidence'/'previous'/str(time.time_ns());archive.mkdir(parents=True)
        path.rename(archive/path.name)
        if log.exists():log.rename(archive/log.name)
    cmd=['timeout','120',str(H/'evidence'/'nexus-tests'),'-test.run','^TestNexusWorkflowTestSuiteHSM$/TestSpeculaTrace$','-test.parallel','1','-test.timeout','90s','-test.v','-persistenceType=sql','-persistenceDriver=sqlite']
    start=time.monotonic()
    with log.open('w') as f:
        p=subprocess.run(cmd,cwd=S/'tests',env={**os.environ,'GOMAXPROCS':'4','SPECULA_SCENARIO':mode,'SPECULA_TRACE_FILE':str(path),'SPECULA_BINARY_SHA256':binary_hash},stdout=f,stderr=subprocess.STDOUT)
    text=log.read_text()
    result={'scenario':mode,'binary_sha256':binary_hash,'returncode':p.returncode,'seconds':round(time.monotonic()-start,3),'command':cmd,'cwd':str(S/'tests'),'log':str(log),'trace':str(path),'test_pass':p.returncode==0 and '--- PASS: TestNexusWorkflowTestSuiteHSM/TestSpeculaTrace' in text,'lines':sum(1 for _ in path.open()) if path.exists() else 0}
    results.append(result)
    (H/'evidence'/'collection-results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(f'{mode}: exit={p.returncode} test_pass={result["test_pass"]} lines={result["lines"]} {result["seconds"]}s',flush=True)
    if p.returncode==124:
        print('Outer timeout fired; preserving log and stopping without retry.',flush=True);break
sys.exit(0 if all(x['test_pass'] for x in results) else 1)
