#!/usr/bin/env python3
"""Call installed Specula handlers locally and retain evidence per round."""
import asyncio
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

RUNNER = Path('/home/ubuntu/specula-vsr-runner-20260905')
SPEC = Path(__file__).resolve().parent.parent
OUT = SPEC / 'output' / sys.argv[1]
OUT.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(RUNNER / 'tools/trace_debugger/src'))
from tla_mcp.handlers.trace_validation_parallel import ParallelTraceValidationHandler

class RecordedHandler(ParallelTraceValidationHandler):
    async def _run_tlc(self, cmd, args):
        output = await super()._run_tlc(cmd, args)
        stem = Path(args['trace_file']).stem
        (OUT / (stem + '.out')).write_text(output)
        (OUT / (stem + '.command.json')).write_text(json.dumps({'cmd': cmd, 'args': args}, indent=2))
        return output

async def main():
    paths = sorted((SPEC.parent / 'traces').glob('*.ndjson'))
    args = dict(spec_file='Trace.tla', config_file='Trace.cfg',
                trace_files=[str(p) for p in paths], work_dir=str(SPEC), timeout=180,
                tla_jar=str(RUNNER/'lib/tla2tools.jar'),
                community_jar=str(RUNNER/'lib/CommunityModules-deps.jar'))
    result = await RecordedHandler().execute(args)
    result['sha256'] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in paths + [SPEC/'base.tla', SPEC/'Trace.tla', SPEC/'Trace.cfg']}
    (OUT / 'parallel-results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))
    if result['status'] != 'success':
        return 1
    # Preserve the Phase 2.5 reports; write fresh strict negative-control/L2
    # evidence into this round's directory using the existing harness auditor.
    module_spec = importlib.util.spec_from_file_location('harness_audit', SPEC.parent/'harness/validate.py')
    audit = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(audit)
    audit.OUT = OUT / 'controls'
    import os
    os.environ['TLA_JAR'] = args['tla_jar']
    os.environ['COMMUNITY_JAR'] = args['community_jar']
    sys.argv = ['validate.py', '--jobs', '2']
    return audit.main()

sys.exit(asyncio.run(main()))
