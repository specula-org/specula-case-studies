#!/usr/bin/env python3
"""Invoke the experiment-local run_trace_validation implementation, bounded."""
import asyncio
import json
import os
from pathlib import Path
import sys
import time

H=Path(__file__).resolve().parent.parent
ROOT=Path('/home/ubuntu/nvflare-job-lifecycle-20260914/specula')
sys.path.insert(0,str(ROOT/'tools/trace_debugger/src'))
from tla_mcp.handlers.trace_validation import TraceValidationHandler


class BoundedTraceValidation(TraceValidationHandler):
    def _build_command(self,args,tla_jar,community_jar):
        cmd=super()._build_command(args,tla_jar,community_jar)
        cmd[cmd.index('-Xmx4G')]='-Xmx2G'
        cmd.insert(1,'-XX:MaxDirectMemorySize=1G')
        cmd.insert(1,'-DTLA-Library='+str(ROOT/'lib'))
        cmd += ['-workers','1']
        return cmd

    async def _run_tlc(self,cmd,args):
        text=await super()._run_tlc(cmd,args)
        (H/'logs'/f'{Path(args["trace_file"]).stem}.tlc.log').write_text(text)
        return text


async def main():
    os.environ['TMPDIR']='/home/ubuntu/nvflare-job-lifecycle-20260914/scratch/tmp'
    os.environ['JAVA_TOOL_OPTIONS']='-Djava.io.tmpdir='+os.environ['TMPDIR']
    paths=[Path(p).resolve() for p in sys.argv[1:]] or sorted((H.parent/'traces').glob('*.ndjson'))
    ok=True
    for path in paths:
        meminfo=Path('/proc/meminfo').read_text()
        available=int(next(line.split()[1] for line in meminfo.splitlines() if line.startswith('MemAvailable:')))
        if available < 35*1024*1024:
            raise RuntimeError('less than 32 GiB host reserve plus 3 GiB validation allocation')
        args=dict(spec_file='Trace.tla',config_file='Trace.cfg',trace_file=str(path),
                  work_dir=str(H.parent/'spec'), timeout=120,
                  metadir=f'/home/ubuntu/nvflare-job-lifecycle-20260914/scratch/tlc/harness-{path.stem}-{time.time_ns()}',
                  tla_jar=str(ROOT/'lib/tla2tools.jar'),community_jar=str(ROOT/'lib/CommunityModules-deps.jar'))
        result=await BoundedTraceValidation().execute(args)
        result['allocation']={'heap_gib':2,'direct_memory_gib':1,'workers':1,'available_kib':available}
        (H/'logs'/f'{path.stem}.validation.json').write_text(json.dumps(result,indent=2))
        print(path.name,result['status'],result.get('failed_trace_line',''))
        ok &= result['status']=='success'
    return 0 if ok else 1


if __name__=='__main__':
    sys.exit(asyncio.run(main()))
