#!/usr/bin/env python3
"""Default full Trace validation through the pinned registered TLC task manager.

All source/caller fields match; Quality observers live in base and are fingerprinted.
Resource admission and blocking waits are shared with registered MCP jobs.
"""
import asyncio
import datetime
import json
import os
import re
import hashlib
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
HARNESS = Path(__file__).resolve().parent
RUN = HARNESS.parents[2]
PINNED = Path(os.environ.get('SPECULA_ROOT', str(RUN.parents[2] / 'Specula')))
SPEC = HARNESS.parent / 'spec'
sys.path.insert(0, str(PINNED / 'tools/trace_debugger/src'))
from tla_mcp.handlers.trace_validation import TraceValidationHandler

# Reuse the exact registered task implementation and its resource ledger.
# CLI invocation uses the same start_tlc/wait_tlc functions as the MCP tools.
sys.path.insert(0,str(PINNED/'src'))
from specula.tlc_tasks import start_tlc, wait_tlc

async def run_one(path,oracle):
    label = f'{"oracle-" if oracle else ""}{path.stem}-{datetime.datetime.now(datetime.timezone.utc):%Y%m%d-%H%M%S}-{os.getpid()}'
    log = HARNESS / 'logs' / (label+'.log')
    work_in_spec=SPEC/'output'/'harness-validation'/label/'spec'
    work_in_spec.mkdir(parents=True)
    HARNESS.joinpath('logs').mkdir(exist_ok=True)
    for name in ['base.tla','Trace.tla','Trace.cfg']:
        (work_in_spec/name).write_bytes((SPEC/name).read_bytes())
    (work_in_spec.parent/'traces').mkdir()
    (work_in_spec.parent/'traces'/'trace.ndjson').write_bytes(path.read_bytes())
    if oracle:
        for name in ['OracleTrace.tla','OracleTrace.cfg']:
            (work_in_spec/name).write_bytes((HARNESS/'oracle'/name).read_bytes())
    receipt=await start_tlc(work_dir=str(work_in_spec),
        spec_file='OracleTrace.tla' if oracle else 'Trace.tla',
        config_file='OracleTrace.cfg' if oracle else 'Trace.cfg',
        options=['-m','8G','-M','1G','-w','2','-t','5'])
    (HARNESS/'logs'/(label+'-receipt.json')).write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps({'tlc_started':receipt}),flush=True)
    while True:
        waited=await wait_tlc([receipt['task_id']],timeout_seconds=55,mode='all')
        if waited['outcome']=='finished':break
    terminal=waited['tasks'][0]
    native=Path(receipt['log_path'])
    text=native.read_text() if native.exists() else Path(receipt['launcher_log_path']).read_text()
    log.write_text(text)
    result=TraceValidationHandler()._parse_output(text)
    result['native_receipt']=receipt
    result['native_result']=terminal
    result['work_dir']=str(work_in_spec)
    inputs=['base.tla','Trace.tla']+(['OracleTrace.tla','OracleTrace.cfg'] if oracle else ['Trace.cfg'])
    result['input_hashes']={name:hashlib.sha256((work_in_spec/name).read_bytes()).hexdigest() for name in inputs}
    result['trace'] = str(path)
    result['mode'] = 'observation-oracle' if oracle else 'full-correspondence'
    result['spec_sha256'] = {name:hashlib.sha256((SPEC/name).read_bytes()).hexdigest() for name in ['base.tla','Trace.tla','Trace.cfg']}
    result['log'] = str(log)
    result['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    text = log.read_text()
    violation = re.search(r'Invariant (\w+) is violated',text)
    if violation:
        result['violated_invariant'] = violation.group(1)
    # The pinned parser takes the first progress count and does not handle
    # comma separators. Preserve it, but report the final counts separately.
    totals = re.findall(r'^([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue\.', text, re.M)
    if totals:
        result['final_states_generated'], result['final_distinct_states'], result['final_queue'] = map(lambda x:int(x.replace(',','')),totals[-1])
    result['event_count'] = sum(1 for _ in path.open())
    if result['status']=='success' and result.get('final_distinct_states')!=result['event_count']:
        result['status']='error'
        result['message']='Replay state count did not match the event count; inspect the complete log.'
    summary = {k:v for k,v in result.items() if k not in ('raw_output','last_state')}
    summary['allocation'] = {'heap_gib':8,'direct_gib':1,'workers':2,'work_dir':str(work_in_spec)}
    (HARNESS/'logs'/(label+'.json')).write_text(json.dumps(summary, indent=2)+'\n')
    compact = {k:v for k,v in result.items() if k not in ('raw_output','last_state')}
    print(json.dumps(compact), flush=True)
    if result['status'] != 'success' and 'raw_output' in result and not violation:
        print(result['raw_output'][-1500:], flush=True)
    return result['status'] != 'success'

async def main():
    # Admission remains owned by the pinned resource ledger; never stop other jobs.
    os.environ.setdefault('SPECULA_WORK_DIR',str(HARNESS.parent))
    os.environ.setdefault('SPECULA_RUN_DIR',str(RUN))
    os.environ.setdefault('SPECULA_TLC_SCOPE',str(RUN))
    os.environ.setdefault('SPECULA_TLC_MEMORY_LIMIT','200G')
    os.environ.setdefault('SPECULA_TLC_WORKER_LIMIT','60')
    os.environ.setdefault('TMPDIR',str(RUN/'tmp/harness-generation'))
    os.environ.setdefault('TLC_STATE_DIR',str(RUN/'tlc-states/harness-generation'))
    Path(os.environ['TMPDIR']).mkdir(parents=True,exist_ok=True)
    oracle = '--oracle' in sys.argv
    parallel = '--parallel' in sys.argv
    paths = [Path(p).resolve() for p in sys.argv[1:] if p not in ('--oracle','--parallel')]
    if not paths:
        paths = sorted((HARNESS.parent / 'traces').glob('*.ndjson'))
    width = min(6,len(paths)) if parallel else 1
    semaphore = asyncio.Semaphore(width)
    async def bounded(path):
        async with semaphore:
            return await run_one(path,oracle)
    outcomes = await asyncio.gather(*(bounded(path) for path in paths), return_exceptions=True)
    failed = False
    for outcome in outcomes:
        if isinstance(outcome,BaseException):
            print(str(outcome),file=sys.stderr);failed=True
        else:failed=failed or outcome
    return 1 if failed else 0

if __name__ == '__main__':
    raise SystemExit(asyncio.run(main()))
