"""Invoke the installed layered trace debugger with explicit local resources."""
import asyncio
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT = Path('/home/ubuntu/nvflare-job-lifecycle-20260914/specula')
SPEC = Path(__file__).resolve().parent.parent
os.environ['TMPDIR'] = '/home/ubuntu/nvflare-job-lifecycle-20260914/scratch/tmp'
os.environ['JAVA_TOOL_OPTIONS'] = '-Djava.io.tmpdir=' + os.environ['TMPDIR']
sys.path.insert(0, str(ROOT / 'tools/trace_debugger/src'))
from tla_mcp.handlers.trace_debugging import TraceDebuggingHandler


class LocalDebug(TraceDebuggingHandler):
    def _create_session(self, args):
        session = super()._create_session(args)
        session.executor._cleanup_zombie_processes = lambda port: None
        original_start = session.executor.start
        original_popen = subprocess.Popen
        def popen(cmd, **kwargs):
            cmd = list(cmd)
            cmd[cmd.index('-Xmx4G')] = '-Xmx2G'
            cmd[1:1] = ['-XX:MaxDirectMemorySize=1G', '-DTLA-Library=' + str(ROOT / 'lib')]
            cmd += ['-workers', '1', '-metadir', tempfile.mkdtemp(prefix='debug-', dir='/home/ubuntu/nvflare-job-lifecycle-20260914/scratch/tlc')]
            return original_popen(cmd, **kwargs)
        def start(**kwargs):
            with patch('executor.tlc_process.subprocess.Popen', popen):
                return original_start(**kwargs)
        session.executor.start = start
        return session


async def main():
    args = json.loads(Path(sys.argv[1]).read_text())
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    args.update(spec_file='Trace.tla', config_file='Trace.cfg', work_dir=args.pop('snapshot_dir',str(SPEC)),
                port=port, timeout=600, tla_jar=str(ROOT/'lib/tla2tools.jar'),
                community_jar=str(ROOT/'lib/CommunityModules-deps.jar'))
    args['trace_file'] = str(SPEC.parent / 'traces' / args['trace_file'])
    result = await LocalDebug().execute(args)
    Path(sys.argv[2]).write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


asyncio.run(main())
