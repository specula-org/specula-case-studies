#!/usr/bin/env python3
"""Pinned run_trace_debugging with bounded memory and run-local TLC files."""
import asyncio
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
from validate import HARNESS, RUN, PINNED, SPEC
from tla_mcp.handlers.trace_debugging import TraceDebuggingHandler
from executor.tlc_process import TLCExecutor

class LocalExecutor(TLCExecutor):
    def start(self, spec_file, config_file, trace_file=None, cwd=None, port=4712):
        label = f'debug-{datetime.datetime.now(datetime.timezone.utc):%Y%m%d-%H%M%S}-{os.getpid()}'
        state = RUN / 'tlc-states/harness-generation' / label
        state.mkdir(parents=True)
        env = dict(os.environ, JSON=trace_file)
        cmd = ['timeout','300','java','-Xmx8g','-XX:MaxDirectMemorySize=1g','-XX:+UseParallelGC',
               f'-Djava.io.tmpdir={RUN/"tmp/harness-generation"}',f'-DTLA-Library={PINNED/"lib"}',
               '-cp',f'{self.tla_jar_path}:{self.community_jar_path}','tlc2.TLC',
               '-workers','1','-metadir',str(state),'-debugger',f'port={port}',
               '-config',config_file,spec_file]
        self.process = subprocess.Popen(cmd,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        def watch():
            with (HARNESS/'logs'/(label+'.log')).open('w') as out:
                for line in self.process.stdout:
                    out.write(line);out.flush()
                    if 'Debugger is listening' in line:self.ready_event.set()
            self.exit_code=self.process.wait()
            if not self.ready_event.is_set():self.failed_event.set()
        threading.Thread(target=watch,daemon=True).start()
        start=time.monotonic()
        while time.monotonic()-start<30:
            if self.ready_event.wait(.1):return True
            if self.failed_event.is_set():return False
        return False

class LocalDebug(TraceDebuggingHandler):
    def _create_session(self,args):
        session=super()._create_session(args)
        session.executor=LocalExecutor(session.tla_jar,session.community_jar)
        return session

async def main():
    for line in subprocess.check_output(['ps','-eo','pid,args'],text=True).splitlines()[1:]:
        p=line.split(None,2)
        if len(p)>2 and Path(p[1]).name=='java' and 'tlc2.TLC' in p[2]:
            raise SystemExit('Another TLC is active; debug launch refused until allocation is free.')
    args=json.loads(Path(sys.argv[1]).read_text())
    args.update(work_dir=str(SPEC),spec_file='Trace.tla',config_file='Trace.cfg',timeout=240,
                tla_jar=str(PINNED/'lib/tla2tools.jar'),community_jar=str(PINNED/'lib/CommunityModules-deps.jar'),port=4791)
    result=await LocalDebug().execute(args)
    output=HARNESS/'logs'/(Path(sys.argv[1]).stem+'-result.json')
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))

if __name__=='__main__':asyncio.run(main())
