"""Synthetic codec/post-state gate check. NOT an implementation trace/harness."""
from copy import deepcopy
from pathlib import Path
import json
from datetime import datetime, timezone
from trace_codec import encode, Function, FiniteSet
p=Path(__file__).resolve().parent
v=json.loads((p/'output/model-initial-fixture.json').read_text())
post={k:v[k] for k in ('raft','disk','ready','application','requests','wire')}
for name in ('wins','grants','campaigns','commitUses'):
    del post['raft']['s1'][name]
post['raft']['s1'].update(nodeLead=0,propcEnabled=False)
post['ready']['s1']['remainingMessages']=[]
map_fields={'raft','disk','ready','application','requests','wire','prs','log','out','messages','remainingMessages'}
set_fields={'voters','learners','yes','no','started','done','installed','beforeWrites'}
def convert(v,key=''):
    if key in map_fields:
        pairs=list(v.items()) if isinstance(v,dict) else list(enumerate(v,1))
        return Function([(1 if k=='s1' else int(k),convert(x)) for k,x in pairs])
    if key in set_fields:
        return FiniteSet([convert(x) for x in v])
    if isinstance(v,dict):return {k:convert(x,k) for k,x in v.items()}
    if isinstance(v,list):return [convert(x) for x in v]
    return 1 if v=='s1' else v
settings=dict(Server={1},BootPeers=[1],Joining=set(),RawNodes={1},PreVoteNodes={1},
    CheckQuorumNodes=set(),NoForwardNodes=set(),RequestId={1},PayloadWeights={1},EncodedWeights={1},
    ElectionTick=3,HeartbeatTick=1,MaxInflight=2,MaxMsgSize=2,MaxReadySize=2,MaxUncommitted=2,
    SendPolicy='Strict',PersistPolicy='Atomic',EarlyAdvance=True,ReadFence='Inclusive',CancelChanges=set(),
    CancelUnknownRemovals=True,RecoveryMode='Replay',BootstrapPayload=1,BootstrapEncoded=1,EmptyEncoded=1)
init={'tag':'trace','ts':datetime.now(timezone.utc).isoformat(),'event':'Init','settings':encode(settings),'post':encode(convert(post))}
after=deepcopy(post);after['raft']['s1']['elapsed']=1
step={'tag':'trace','ts':datetime.now(timezone.utc).isoformat(),'event':'Tick','params':encode({'node':1,'timeout':3}),'post':encode(convert(after))}
valid=p/'output/adapter-valid-synthetic.ndjson'
valid.write_text('\n'.join(json.dumps(x,separators=(',',':')) for x in (init,step))+'\n')
after['raft']['s1']['elapsed']=99
bad=deepcopy(step);bad['post']=encode(convert(after))
(p/'output/adapter-invalid-post-synthetic.ndjson').write_text('\n'.join(json.dumps(x,separators=(',',':')) for x in (init,bad))+'\n')
