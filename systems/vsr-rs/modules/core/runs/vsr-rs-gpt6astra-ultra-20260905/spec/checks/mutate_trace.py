from pathlib import Path
import copy,json
p=Path(__file__).resolve().parent
rows=[json.loads(x) for x in (p/'trace-fixture.ndjson').read_text().splitlines()]
mutations={}
x=copy.deepcopy(rows);k=next(k for k,r in enumerate(x) if r.get('event')=='ReplicaOnMessage' and r['message']['wire']['kind']=='Request');x[k]['state']['replicas'][0]['commit']=1;mutations['postcommit']=(x,k+1)
x=copy.deepcopy(rows);k=next(k for k,r in enumerate(x) if r.get('applies'));x[k]['applies'][0]['result']+=1;mutations['apply-result']=(x,k+1)
x=copy.deepcopy(rows);k=next(k for k,r in enumerate(x) if r.get('event')=='ReplicaOnMessage' and r['message']['wire']['kind']=='Prepare');x[k]['message']['wire']['opn']+=1;mutations['packet-opn']=(x,k+1)
x=copy.deepcopy(rows);k=next(k for k,r in enumerate(x) if r.get('event')=='PersistView');del x[k];mutations['omitted-persist']=(x,k+1)
x=copy.deepcopy(rows);x[1]['request']=99;mutations['first-event']=(x,2)
for name,(x,line) in mutations.items():
 (p/f'trace-negative-{name}.ndjson').write_text(''.join(json.dumps(r,separators=(',',':'))+'\n' for r in x))
(p/'trace-negative-manifest.json').write_text(json.dumps({n:{'first_bad_ndjson_line':v[1]} for n,v in mutations.items()},indent=2)+'\n')
