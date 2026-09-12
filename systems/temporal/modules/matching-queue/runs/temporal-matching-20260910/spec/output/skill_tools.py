import asyncio
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path('/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/Specula')
sys.path.insert(0, str(ROOT / 'tools/trace_debugger/src'))
from tla_mcp.handlers.trace_validation import TraceValidationHandler
from tla_mcp.handlers.trace_validation_parallel import ParallelTraceValidationHandler
from tla_mcp.handlers.trace_debugging import TraceDebuggingHandler
from tla_mcp.handlers.spec_validation import SpecValidationHandler
from tla_mcp.handlers.clean_traces import CleanTracesHandler

spec = Path(__file__).resolve().parent.parent
tool, name = sys.argv[1:3]
out = spec / 'output' / name
out.mkdir(exist_ok=True)
for path in spec.iterdir():
    if path.suffix in ('.tla', '.cfg') and '_TTrace_' not in path.name:
        shutil.copy2(path, out / path.name)
args = dict(spec_file='Trace.tla', config_file='Trace.cfg', work_dir=str(spec), timeout=180,
            tla_jar='/home/ubuntu/Specula-incremental-etcd-20260814/tools/tla2tools.jar',
            community_jar='/home/ubuntu/Specula-incremental-etcd-20260814/tools/CommunityModules-deps.jar')
if len(sys.argv) > 3:
    args.update(json.loads(Path(sys.argv[3]).read_text()))
handlers = {'parallel': ParallelTraceValidationHandler, 'single': TraceValidationHandler,
            'debug': TraceDebuggingHandler, 'syntax': SpecValidationHandler, 'clean': CleanTracesHandler}
if tool == 'parallel' and 'trace_files' not in args:
    args['trace_files'] = [str(p) for p in sorted((spec.parent / 'traces').glob('*.ndjson'))]
original_run = TraceValidationHandler._run_tlc
original_parse = TraceValidationHandler._parse_output
def named_property_parse(self, output, include_last_state=False):
    if 'Error: Temporal property TraceMatched was violated.' in output:
        return self._parse_trace_mismatch(output, include_last_state)
    result = original_parse(self, output, include_last_state)
    if result.get('status') == 'success':
        counts = re.findall(r'([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue', output)
        if not counts or int(counts[-1][1].replace(',', '')) == 0 or int(counts[-1][2].replace(',', '')) != 0:
            return {'status': 'error', 'message': 'Replay must have nonzero initial/reached states and complete exploration'}
    return result
TraceValidationHandler._parse_output = named_property_parse
async def logged_run(self, cmd, arguments):
    output = await original_run(self, cmd, arguments)
    trace = Path(arguments['trace_file'])
    key = hashlib.sha256(str(trace.parent).encode()).hexdigest()[:8] + '-' + trace.stem
    (out / (key + '.log')).write_text(output)
    result = self._parse_output(output, True)
    result['trace_sha256'] = hashlib.sha256(trace.read_bytes()).hexdigest()
    result['trace_file'] = str(trace)
    result['log'] = str(out / (key + '.log'))
    (out / (key + '.json')).write_text(json.dumps(result, indent=2)+'\n')
    return output
TraceValidationHandler._run_tlc = logged_run
(out / 'arguments.json').write_text(json.dumps(args,indent=2)+'\n')
async def run():
    if tool != 'parallel':
        return await handlers[tool]().execute(args)
    batches = []
    for i in range(0, len(args['trace_files']), 8):
        batches.append(await ParallelTraceValidationHandler().execute(dict(args, trace_files=args['trace_files'][i:i+8])))
    return {'status': 'success' if all(b['status'] == 'success' for b in batches) else 'trace_mismatch',
            'passed': sum(b['passed'] for b in batches), 'failed': sum(b['failed'] for b in batches), 'batches': batches}
result = asyncio.run(run())
(out / 'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
