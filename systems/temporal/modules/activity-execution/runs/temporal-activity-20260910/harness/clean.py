#!/usr/bin/env python3
import hashlib,json,os,subprocess
from pathlib import Path
h=Path(__file__).resolve().parent;r=Path(os.environ['SOURCE_DIR'])
manifest=json.loads((h/'owned-files.json').read_text())
for name,digest in manifest.items():
 p=r/name
 if not p.exists() or hashlib.sha256(p.read_bytes()).hexdigest()!=digest:raise SystemExit('refusing changed/missing owned file: '+str(p))
p=h/'patches/instrumentation.patch'
subprocess.run(['git','-C',str(r),'apply','--reverse','--check',str(p)],check=True)
subprocess.run(['git','-C',str(r),'apply','--reverse',str(p)],check=True)
for name in manifest:(r/name).unlink()
print('removed only unchanged harness instrumentation')
