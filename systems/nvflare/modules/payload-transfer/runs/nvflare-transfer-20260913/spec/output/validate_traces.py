"""Installed parallel trace handler using the budgeted experiment TLC transport."""
import asyncio
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys

OUT = Path(__file__).resolve().parents[2]
ROOT = next(p for p in OUT.parents if (p / 'src/specula/tlc_tasks.py').exists())
RUN = OUT / 'spec/output' / (sys.argv[1] if len(sys.argv) > 1 else 'round1-traces')
RUN.mkdir(parents=True, exist_ok=True)
os.environ['TMPDIR'] = '/home/ubuntu/nvflare-runs-20260913/scratch/transfer/tmp'
Path(os.environ['TMPDIR']).mkdir(parents=True, exist_ok=True)
os.environ['SPECULA_WORK_DIR'] = str(OUT)
os.environ['SPECULA_ROOT'] = str(ROOT)
sys.path[:0] = [str(ROOT / 'src'), str(ROOT / 'tools/trace_debugger/src')]
from specula.tlc_tasks import start_tlc, wait_tlc
from tla_mcp.handlers.trace_validation_parallel import ParallelTraceValidationHandler
from tla_mcp.handlers.clean_traces import CleanTracesHandler

rows = []

class BudgetedParallel(ParallelTraceValidationHandler):
    async def _run_tlc(self, cmd, args):
        trace = Path(args['trace_file']).resolve()
        folder = RUN / trace.stem
        work = folder / 'spec'
        work.mkdir(parents=True, exist_ok=True)
        (folder / 'traces').mkdir(exist_ok=True)
        for name in ['base.tla', 'Trace.tla', 'Trace.cfg']:
            dest = work / name
            if not dest.exists():
                dest.symlink_to(OUT / 'spec' / name)
        dest = folder / 'traces/trace.ndjson'
        if not dest.exists():
            dest.symlink_to(trace)
        task = await start_tlc(str(work), 'Trace.tla', 'Trace.cfg',
                               ['-m', '2G', '-M', '1G', '-w', '1', '-t', '5'])
        (folder / 'task.json').write_text(json.dumps(task, indent=2) + '\n')
        while True:
            waited = await wait_tlc([task['task_id']], timeout_seconds=30, mode='all')
            if waited['outcome'] == 'finished':
                break
        result = waited['tasks'][0]
        log = Path(result['log_path']).read_text()
        (folder / 'tlc.log').write_text(log)
        counts = re.findall(r'([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue', log)
        events = len(trace.read_text().splitlines()) - 1
        consumed = bool(counts) and int(counts[-1][1].replace(',', '')) == events + 1
        row = dict(name=trace.stem, events=events, complete_cursor=consumed,
                   trace_sha256=hashlib.sha256(trace.read_bytes()).hexdigest(), **result)
        rows.append(row)
        (folder / 'result.json').write_text(json.dumps(row, indent=2) + '\n')
        print(trace.stem, result['exit_code'], 'complete_cursor', consumed, flush=True)
        if result['exit_code'] != 0 or not consumed:
            if 'Model checking completed. No error has been found.' in log:
                raise RuntimeError('TLC completion did not establish complete cursor consumption')
        return log

async def main():
    traces = sorted((OUT / 'traces/normalized').glob('*.ndjson'))
    result = await BudgetedParallel().execute(dict(spec_file='Trace.tla', config_file='Trace.cfg',
                    trace_files=[str(p) for p in traces], work_dir=str(OUT / 'spec'), timeout=360))
    result['details'] = sorted(rows, key=lambda r: r['name'])
    (RUN / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k:v for k,v in result.items() if k != 'details'}), flush=True)
    if result['failed'] == 0:
        cleanup = []
        for p in RUN.glob('*/spec/Trace.tla'):
            cleanup.append(await CleanTracesHandler().execute({'spec_file':str(p)}))
        (RUN / 'cleanup.json').write_text(json.dumps(cleanup, indent=2) + '\n')
    return 0 if result['failed'] == 0 and len(rows) == len(traces) else 1

if __name__ == '__main__':
    sys.exit(asyncio.run(main()))
