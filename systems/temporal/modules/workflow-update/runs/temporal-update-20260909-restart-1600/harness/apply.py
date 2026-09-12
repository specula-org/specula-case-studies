#!/usr/bin/env python3
"""Apply or remove only this harness's exact patch and copied sources."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

h=Path(__file__).resolve().parent
source=Path(sys.argv[1]).resolve()
clean=len(sys.argv)>2 and sys.argv[2]=='--clean'
revision='0c010ce5fe8c0180aa7573c72fe8fc87c6df7025'
def git(*args,check=True):
    return subprocess.run(['git','-C',str(source),*args],check=check,capture_output=True,text=True)
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
assert git('rev-parse','HEAD').stdout.strip()==revision, 'source revision differs from pinned target'
patch=h/'patches/instrumentation.patch'
statefile=source/'.specula-harness-state.json'
installed=json.loads(statefile.read_text()) if statefile.exists() else {}
copies={str(p.relative_to(h/'src')):p for p in (h/'src').rglob('*.go')}
# Preflight every source before mutating any of them.
for name,p in copies.items():
    dest=source/name
    if dest.exists():
        allowed={digest(p),installed.get(name)}
        if digest(dest) not in allowed: raise SystemExit(f'Refusing to overwrite edited file: {dest}')
if clean:
    if git('apply','--reverse','--check',str(patch),check=False).returncode!=0:
        raise SystemExit('Source patch has changed; refusing cleanup.')
    git('apply','--reverse',str(patch))
    for name in copies:
        dest=source/name
        if dest.exists(): dest.unlink()
    if statefile.exists(): statefile.unlink()
    print('Removed only the exact harness patch and copied files.')
else:
    if git('apply','--reverse','--check',str(patch),check=False).returncode!=0:
        check=git('apply','--check',str(patch),check=False)
        if check.returncode: raise SystemExit('Patch conflicts; source untouched:\n'+check.stderr)
        git('apply',str(patch))
    for name,p in copies.items():
        dest=source/name
        dest.parent.mkdir(parents=True,exist_ok=True)
        dest.write_bytes(p.read_bytes())
    statefile.write_text(json.dumps({name:digest(p) for name,p in copies.items()},indent=2)+'\n')
    print(f'Instrumentation applied to {source} at {revision}.')
