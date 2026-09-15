"""Insert the semantic identity TLCEval around function constructors only."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import sys

SPEC=Path(__file__).resolve().parent.parent
DEST=Path(sys.argv[1]).resolve(); DEST.mkdir(exist_ok=True,parents=True)
CFG=sys.argv[2]

def eager(text):
    stack=[]; pairs=[]; masks=[]; string=False; escape=False; comment=0; line=False
    for i,c in enumerate(text):
        if line:
            if c=='\n':line=False
            continue
        if comment:
            if text[i:i+2]=='(*':comment+=1
            elif text[i:i+2]=='*)':comment-=1
            continue
        if string:
            if escape:escape=False
            elif c=='\\':escape=True
            elif c=='"':string=False
            continue
        if c=='"':string=True;continue
        if text[i:i+2]=='\\*':line=True;continue
        if text[i:i+2]=='(*':comment=1;continue
        if c=='[':stack.append(i)
        elif c==']':
            begin=stack.pop(); body=text[begin+1:i]
            # Function constructors start with formal bindings; record literals,
            # applications, function sets and EXCEPT expressions stay unchanged.
            if re.match(r'\s*\w+(?:\s*,\s*\w+)*\s*\\in\b',body) and '|->' in body:
                pairs.append((begin,i))
    assert not stack
    opens={a for a,b in pairs}; closes={b for a,b in pairs}
    result=''.join(('TLCEval(' if i in opens else '')+c+(')' if i in closes else '') for i,c in enumerate(text))
    return result,len(pairs)

receipt={'transformation':'TLCEval(v)==v, as defined in bundled TLC.tla. Only explicit function constructors are eagerly evaluated; no guards, state updates, invariants, fairness clauses, constants or bounds change.','files':{}}
for name in ['base.tla','MC.tla']:
    original=(SPEC/name).read_text(); changed,count=eager(original); (DEST/name).write_text(changed)
    receipt['files'][name]={'source_sha256':hashlib.sha256(original.encode()).hexdigest(),'execution_sha256':hashlib.sha256(changed.encode()).hexdigest(),'identity_wrappers':count}
for name in [CFG,'Trace.tla','Trace.cfg']:shutil.copy2(SPEC/name,DEST/name)
(DEST/'inputs.json').write_text(json.dumps(receipt,indent=2))
print(json.dumps(receipt,indent=2))
