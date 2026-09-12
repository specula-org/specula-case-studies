#!/usr/bin/env python3
"""Run the supplied strict validator and retain its real exit status."""
import json,os,pathlib,subprocess,sys
H=pathlib.Path(__file__).resolve().parent
SPEC=H.parent/'spec'
T=H.parent/'traces'
JARS=os.environ.get('TLA_CLASSPATH','/home/ubuntu/Specula/tools/tlaplus/tlatools/org.lamport.tlatools/dist/tla2tools.jar:/home/ubuntu/Specula/tools/tlaplus/tlatools/org.lamport.tlatools/lib/CommunityModules.jar')

def run(name,module,config,cwd,env):
    log=H/'evidence'/f'{name}.log'
    command=['timeout','60','java','-Xmx2g','-cp',JARS,'tlc2.TLC','-workers','1','-config',str(config),'-metadir',str(H/'evidence'/'tlc-states'/name),'-noGenerateSpecTE',module]
    with log.open('w') as f:
        p=subprocess.run(command,cwd=cwd,env={**os.environ,**env},stdout=f,stderr=subprocess.STDOUT)
    content=log.read_text()
    return {'name':name,'command':command,'cwd':str(cwd),'env':env,'returncode':p.returncode,'accepted':p.returncode==0 and 'Model checking completed. No error has been found.' in content,'log':str(log)}

results=[]
# Raw NDJSON is deliberately not relabeled as a complete semantic recording.
results.append(run('strict-trace-validation','Trace',SPEC/'Trace.cfg',SPEC,{'JSON':str(T/'healthy_async.ndjson')}))

# Diagnose the bootstrap boundary using a value extracted from an actual DB receipt.
rows=[json.loads(x) for x in (T/'healthy_async.ndjson').read_text().splitlines()]
bootstrap=next(x for x in rows if x['event']=='ObservationReadback' and x['raw']['label']=='bootstrap-before-schedule')
info=bootstrap['raw']['database']['mutable_state']['execution_info']
observed='Started' if int(info['workflow_task_started_event_id']) else ('Pending' if int(info['workflow_task_scheduled_event_id']) else 'Idle')
dir=H/'evidence'/'bootstrap';dir.mkdir(exist_ok=True)
(dir/'observation.json').write_text(json.dumps({'raw_file':str(T/'healthy_async.ndjson'),'receipt':bootstrap['sequence'],'observedWFT':observed,'execution_info':info},indent=2)+'\n')
(dir/'base.tla').write_bytes((SPEC/'base.tla').read_bytes())
(dir/'BootstrapCheck.tla').write_text('''------------------------- MODULE BootstrapCheck -------------------------
EXTENDS base
CONSTANT ObservedWFT
CheckInit == Init /\\ Assert(s.d.wft = ObservedWFT,
    "Actual bootstrap DB WFT status does not match base.Init")
CheckNext == UNCHANGED vars
CheckSpec == CheckInit /\\ [][CheckNext]_vars
=======================================================================
''')
cfg=rows[0]['raw']
(dir/'BootstrapCheck.cfg').write_text(f'''SPECIFICATION CheckSpec
CONSTANTS
  Ops = {{"op1"}}
  Capacity = {cfg['Capacity']}
  S2C = 0
  S2S = 0
  STC = 0
  RequestTimeout = {cfg['RequestTimeoutNS']//1000}
  MinRequestTimeout = {cfg['MinRequestTimeoutNS']//1000}
  RetryDelay = {cfg['RetryInitialNS']//1000}
  StartModes = {{"Async"}}
  RemoteResults = {{"Succeeded"}}
  ObservedWFT = "{observed}"
CHECK_DEADLOCK FALSE
''')
results.append(run('bootstrap-boundary-check','BootstrapCheck',dir/'BootstrapCheck.cfg',dir,{}))
report={'strict_trace_status':'INCOMPLETE','implementation_trace_matching_passes':0,'checks':results,
 'explanation':'The supplied Trace schema requires a complete semantic post-state join. The implementation recordings contain raw receipts; no post fields or completeness flags are invented. The separate bootstrap diagnostic tests the observed initial WFT status against base.Init and is not trace validation.'}
(H/'evidence'/'validation-results.json').write_text(json.dumps(report,indent=2)+'\n')
for r in results: print(f'{r["name"]}: exit={r["returncode"]} accepted={r["accepted"]}')
sys.exit(2)
