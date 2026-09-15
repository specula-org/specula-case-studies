"""Bounded local invocation of Specula run_trace_validation_parallel."""
import asyncio
import hashlib
import json
import os
from pathlib import Path
import sys
import time

ROOT = Path('/home/ubuntu/nvflare-job-lifecycle-20260914/specula')
CANONICAL = Path(__file__).resolve().parent.parent
SPEC = Path(sys.argv[2]).resolve() if len(sys.argv)>2 else CANONICAL
OUT = CANONICAL / 'output' / sys.argv[1]
OUT.mkdir(parents=True, exist_ok=False)
os.environ['TMPDIR'] = '/home/ubuntu/nvflare-job-lifecycle-20260914/scratch/tlc'
os.environ['JAVA_TOOL_OPTIONS'] = '-Djava.io.tmpdir=/home/ubuntu/nvflare-job-lifecycle-20260914/scratch/tmp'
sys.path.insert(0, str(ROOT / 'tools/trace_debugger/src'))
from tla_mcp.handlers.trace_validation_parallel import ParallelTraceValidationHandler


class Bounded(ParallelTraceValidationHandler):
    def _build_command(self, args, tla_jar, community_jar):
        cmd = super()._build_command(args, tla_jar, community_jar)
        cmd[cmd.index('-Xmx4G')] = '-Xmx2G'
        cmd[1:1] = ['-XX:MaxDirectMemorySize=1G', '-DTLA-Library=' + str(ROOT / 'lib')]
        cmd += ['-workers', '1']
        (OUT / (Path(args['trace_file']).stem + '.command.json')).write_text(json.dumps(cmd))
        return cmd

    async def _run_tlc(self, cmd, args):
        output = await super()._run_tlc(cmd, args)
        stem = Path(args['trace_file']).stem
        (OUT / (stem + '.out')).write_text(output)
        (OUT / (stem + '.json')).write_text(json.dumps(self._parse_output(output), indent=2))
        return output


async def main():
    available = int(next(l.split()[1] for l in Path('/proc/meminfo').read_text().splitlines() if l.startswith('MemAvailable:')))
    paths = sorted((CANONICAL.parent / 'traces').glob('*.ndjson'))
    if available < (32 + 3 * len(paths)) * 1024 * 1024:
        raise RuntimeError('Insufficient host reserve for parallel trace validation')
    receipt = {'available_kib': available, 'allocation_gib': 3 * len(paths), 'workers': len(paths),
               'hashes': {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in paths + [SPEC / n for n in ('base.tla', 'Trace.tla', 'Trace.cfg')]}}
    (OUT / 'inputs.json').write_text(json.dumps(receipt, indent=2))
    result = await Bounded().execute(dict(spec_file='Trace.tla', config_file='Trace.cfg',
        trace_files=[str(p) for p in paths], work_dir=str(SPEC), timeout=180,
        tla_jar=str(ROOT / 'lib/tla2tools.jar'), community_jar=str(ROOT / 'lib/CommunityModules-deps.jar')))
    (OUT / 'summary.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    return 0 if result['status'] == 'success' else 1


if __name__ == '__main__':
    sys.exit(asyncio.run(main()))
