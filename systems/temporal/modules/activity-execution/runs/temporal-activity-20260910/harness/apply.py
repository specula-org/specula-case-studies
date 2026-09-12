#!/usr/bin/env python3
"""Apply only harness-owned edits. Unrelated changes are never reset."""
import hashlib, json, os, subprocess
from pathlib import Path
h=Path(__file__).resolve().parent
r=Path(os.environ['SOURCE_DIR']).resolve()
revision=subprocess.check_output(['git','-C',str(r),'rev-parse','HEAD'],text=True).strip()
if revision!='0c010ce5fe8c0180aa7573c72fe8fc87c6df7025':raise SystemExit('wrong source revision: '+revision)
patch=h/'patches/instrumentation.patch'
forward=subprocess.run(['git','-C',str(r),'apply','--check',str(patch)],capture_output=True)
reverse=subprocess.run(['git','-C',str(r),'apply','--reverse','--check',str(patch)],capture_output=True)
if forward.returncode and reverse.returncode:
 raise SystemExit('instrumented source files diverged; preserve local edits and inspect the patch')
manifest=json.loads((h/'owned-files.json').read_text())
# Check every destination before making the first change.
for name,digest in manifest.items():
 p=r/name
 if p.exists() and hashlib.sha256(p.read_bytes()).hexdigest()!=digest:
  raise SystemExit('harness-owned destination has different content: '+str(p))
if not forward.returncode:subprocess.run(['git','-C',str(r),'apply',str(patch)],check=True)
for name in manifest:
 p=r/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((h/'src'/name).read_bytes())
print('instrumentation applied to '+str(r))
