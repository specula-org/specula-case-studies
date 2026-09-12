#!/usr/bin/env python3
import datetime
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
harness,source=map(Path,sys.argv[1:])
def command(*args):return subprocess.check_output(args,cwd=source,text=True).strip()
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
record=dict(capturedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),revision=command('git','rev-parse','HEAD'),go=command('go','version'),configuration=dict(backend='SQL',plugin='sqlite',storage='file',journal_mode='wal',synchronous='normal',shards=1,shardIOConcurrency=1,workerService=False,workflowWorker='explicit test worker',retention='1 day',workflowTaskTimeout='60s',historyScannerAge='default; no age advancement tested'),buildTags=['test_dep'],sourceStatus=command('git','status','--short'),files={str(p.relative_to(harness)):digest(p) for sub in ['src','patches'] for p in (harness/sub).rglob('*') if p.is_file() and '__pycache__' not in str(p)},specs={p.name:digest(p) for p in (harness.parent/'spec').glob('*.tla') if p.name in ['Trace.tla','base.tla']},binarySHA256=digest(harness/'build/reset-trace.test'))
(harness/'evidence/manifest.json').write_text(json.dumps(record,indent=2)+'\n')
