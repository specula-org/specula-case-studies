from pathlib import Path
import json, re
root=Path(__file__).resolve().parent.parent
out={}
for f in sorted(root.glob('MC*.cfg')):
 data={'constants':{},'overrides':{},'invariants':[],'properties':[]};section=None
 for line in f.read_text().splitlines():
  line=line.split('\\*')[0].strip()
  if not line:continue
  words=line.split()
  if words[0] in ('INVARIANT','INVARIANTS','PROPERTY','PROPERTIES','CONSTANTS','CONSTANT','SPECIFICATION','CONSTRAINT','SYMMETRY','CHECK_DEADLOCK'):
   section={'INVARIANT':'invariants','INVARIANTS':'invariants','PROPERTY':'properties','PROPERTIES':'properties','CONSTANTS':'constants','CONSTANT':'constants'}.get(words[0])
   if section in ('invariants','properties'):data[section].extend(words[1:])
  elif section=='constants':
   if '<-' in line:
    key,val=map(str.strip,line.split('<-',1));data['overrides'][key]=val
   else:
    key,val=map(str.strip,line.split('=',1));data[section][key]=val
  elif section:data[section].extend(words)
 out[f.name]=data
(root/'checks/cfg-audit.json').write_text(json.dumps(out,indent=2)+'\n')
required=['TypeOK','CommitBounds','PrimaryForView','HistoricalPrefixAgreement','ProtectedPrefixSurvives','ApplicationMatchesHistory','LogicalRequestOnce','ReplySoundness']
for inv in required:
 active=[f for f,d in out.items() if f.startswith('MC_hunt_') and inv in d['invariants']]
 assert active,inv
 print(inv+': '+', '.join(active))
