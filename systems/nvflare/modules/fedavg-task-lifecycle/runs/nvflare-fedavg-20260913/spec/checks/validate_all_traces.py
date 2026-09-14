#!/usr/bin/env python3
"""Run the installed parallel trace handler with explicit experiment budgets."""
import asyncio
import hashlib
import json
import os
from pathlib import Path
import sys
from datetime import datetime, timezone

ROOT = Path('/home/ubuntu/nvflare-runs-20260913/specula')
SPEC = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/trace_debugger/src'))
from tla_mcp.handlers.trace_validation_parallel import ParallelTraceValidationHandler
from tla_mcp.handlers.clean_traces import CleanTracesHandler

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

class BudgetedParallel(ParallelTraceValidationHandler):
    def __init__(self, output):
        self.output = output
        self.receipts = []

    def _build_command(self, args, tla_jar, community_jar):
        return ['timeout', '180', 'bash', str(ROOT / 'scripts/infra/run_model_check.sh'),
                '-s', args['spec_file'], '-c', args['config_file'],
                '-m', '1G', '-M', '1G', '-w', '1', '-t', '2', '-D',
                '-o', str(self.output / (Path(args['trace_file']).stem + '.tlc.out'))]

    async def _run_tlc(self, cmd, args):
        trace = Path(args['trace_file'])
        raw = await super()._run_tlc(cmd, args)
        log = self.output / f'{trace.stem}.out'
        log.write_text(raw)
        result = self._parse_output(raw)
        result.pop('raw_output', None)
        result.update(trace=str(trace), trace_sha256=digest(trace), log=str(log),
                      spec_hashes={p.name: digest(p) for p in SPEC.glob('*.tla')},
                      config_sha256=digest(SPEC / 'Trace.cfg'), command=cmd)
        self.receipts.append(result)
        (self.output / f'{trace.stem}.json').write_text(json.dumps(result, indent=2) + '\n')
        return raw

async def main():
    label = sys.argv[1] if len(sys.argv) > 1 else 'round1'
    output = SPEC / 'output' / f'trace-{label}'
    output.mkdir(parents=True, exist_ok=False)
    os.environ.update(SPECULA_ROOT=str(ROOT),
                      TMPDIR='/home/ubuntu/nvflare-runs-20260913/scratch/fedavg/validation-tmp',
                      TLC_STATE_DIR='/home/ubuntu/nvflare-runs-20260913/scratch/fedavg/tlc',
                      SPECULA_TLC_MEMORY_LIMIT='128G', SPECULA_TLC_WORKER_LIMIT='40')
    Path(os.environ['TMPDIR']).mkdir(parents=True, exist_ok=True)
    handler = BudgetedParallel(output)
    traces = sorted((SPEC.parent / 'traces').glob('*.ndjson'))
    result = await handler.execute(dict(spec_file='Trace.tla', config_file='Trace.cfg',
                                       trace_files=[str(p) for p in traces], work_dir=str(SPEC), timeout=190))
    result.update(timestamp=datetime.now(timezone.utc).isoformat(), tool=handler.tool_name,
                  receipts=sorted(handler.receipts, key=lambda x: x['trace']))
    (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    cleanup = await CleanTracesHandler().execute(dict(spec_file=str(SPEC / 'Trace.tla')))
    (output / 'cleanup.json').write_text(json.dumps(cleanup, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'receipts'}, indent=2))
    print(json.dumps(cleanup))
    return int(result['status'] != 'success')

if __name__ == '__main__':
    raise SystemExit(asyncio.run(main()))
