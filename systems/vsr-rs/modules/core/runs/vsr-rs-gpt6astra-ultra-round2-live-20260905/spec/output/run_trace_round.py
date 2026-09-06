#!/usr/bin/env python3
"""Invoke Specula's actual parallel MCP handler locally, retaining its raw logs."""
import asyncio
import json
import os
from pathlib import Path
import sys

root = Path(os.environ['SPECULA_ROOT'])
sys.path.insert(0, str(root / 'tools/trace_debugger/src'))
from tla_mcp.handlers.trace_validation_parallel import ParallelTraceValidationHandler

spec = Path(__file__).resolve().parents[1]
round_name = sys.argv[1]
out = spec / 'output' / round_name
out.mkdir(exist_ok=True)

class RetainedParallelHandler(ParallelTraceValidationHandler):
    async def _run_tlc(self, cmd, args):
        output = await super()._run_tlc(cmd, args)
        (out / (Path(args['trace_file']).stem + '.log')).write_text(output)
        return output

args = {
    'spec_file': 'Trace.tla', 'config_file': 'Trace.cfg',
    'trace_files': [str(p) for p in sorted((spec.parent / 'traces').glob('*.ndjson'))],
    'work_dir': str(spec), 'timeout': 300,
    'tla_jar': '/home/ubuntu/Specula-incremental-dataset-100-20260819/tools/tla2tools.jar',
    'community_jar': '/home/ubuntu/Specula-incremental-dataset-100-20260819/tools/CommunityModules-deps.jar',
}
(out / 'arguments.json').write_text(json.dumps(args, indent=2) + '\n')
result = asyncio.run(RetainedParallelHandler().execute(args))
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
sys.exit(0 if result['status'] == 'success' else 1)
