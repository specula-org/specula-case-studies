#!/usr/bin/env python3
"""Call the installed Specula parallel trace handler, retaining raw evidence."""
from pathlib import Path
import asyncio, hashlib, json, os, sys
sys.path.insert(0, '/home/ubuntu/Specula/tools/trace_debugger/src')
from tla_mcp.handlers.trace_validation import TraceValidationHandler
from tla_mcp.handlers.trace_validation_parallel import ParallelTraceValidationHandler
from tla_mcp.handlers.clean_traces import CleanTracesHandler
spec=Path(__file__).resolve().parent.parent
out=spec/'output'; tmp=out/'tmp'; tmp.mkdir(exist_ok=True)
os.environ['TMPDIR']=str(tmp)
os.environ['JAVA_TOOL_OPTIONS']='-Djava.io.tmpdir='+str(tmp)
original=TraceValidationHandler._run_tlc
runs=[]
async def recorded(self,cmd,args):
 text=await original(self,cmd,args)
 name=Path(args['trace_file']).stem
 (out/(name+'.round1.tlc.log')).write_text(text)
 result=self._parse_output(text,False)
 result['trace']=args['trace_file']; result['command']=cmd
 result['sha256']=hashlib.sha256(Path(args['trace_file']).read_bytes()).hexdigest()
 runs.append(result)
 return text
TraceValidationHandler._run_tlc=recorded
async def main():
 args={'spec_file':'Trace.tla','config_file':'Trace.cfg','work_dir':str(spec),
 'trace_files':[str(p) for p in sorted((spec.parent/'traces').glob('*.ndjson'))],
 'timeout':300,'tla_jar':'/home/ubuntu/Specula/lib/tla2tools.jar',
 'community_jar':'/home/ubuntu/Specula/lib/CommunityModules-deps.jar'}
 result=await ParallelTraceValidationHandler().execute(args)
 result['runs']=sorted(runs,key=lambda r:r['trace'])
 (out/'trace-round1.json').write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps({k:v for k,v in result.items() if k!='runs'},indent=2))
 for r in result['runs']: print(Path(r['trace']).name,r['status'],r.get('states_generated'))
 cleaned=await CleanTracesHandler().execute({'spec_file':str(spec/'Trace.tla')})
 (out/'trace-cleanup.json').write_text(json.dumps(cleaned,indent=2)+'\n')
 if result['status']!='success': sys.exit(1)
asyncio.run(main())
