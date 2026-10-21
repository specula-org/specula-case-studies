#!/usr/bin/env python3
"""Keep the supplied spec intact and prepare the observed batch-capacity correction."""
from pathlib import Path
import difflib,shutil,hashlib,json
h=Path(__file__).resolve().parents[1]; spec=h.parent/'spec'; dst=h/'proposed-spec';dst.mkdir(exist_ok=True)
for p in spec.glob('*.tla'): shutil.copyfile(p,dst/p.name)
for p in spec.glob('Trace*.cfg'): shutil.copyfile(p,dst/p.name)
p=spec/'base.tla'; old=p.read_text()
new=old.replace('           stop == IF whole THEN q[t].ioEnd','           segmentStop == IF whole THEN q[t].ioEnd',1)
needle='''                   ELSE q[t].ioEnd IN
       /\\ q' = [q EXCEPT ![t].segmentEnd = stop'''
replacement='''                   ELSE q[t].ioEnd
           capacity == IF q[t].ioKind = "Read"
                       THEN Min(32, Round(q[t].ioEnd, P) \\div P - q[t].ioOff \\div P)
                       ELSE Min(32, Round(q[t].ioEnd - q[t].ioOff, P) \\div P)
           stop == Min(segmentStop, (at \\div P + capacity) * P) IN
       /\\ q' = [q EXCEPT ![t].segmentEnd = stop'''
assert new.count(needle)==1;new=new.replace(needle,replacement)
(dst/'base.tla').write_text(new)
(h/'patches/proposed-base-batch-capacity.patch').write_text(''.join(difflib.unified_diff(old.splitlines(True),new.splitlines(True),fromfile='spec/base.tla',tofile='spec/base.tla')))
hash_file=h/'spec-input-hashes.json'
if hash_file.exists():
    for name,expected in json.loads(hash_file.read_text()).items():
        if hashlib.sha256((spec/name).read_bytes()).hexdigest()!=expected: raise RuntimeError('supplied spec changed: '+name)
else:
    hash_file.write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in spec.iterdir() if p.is_file()},indent=2)+'\n')
