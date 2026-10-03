#!/usr/bin/env python3
"""Controlled invalid copies of real traces; never run against Raft itself."""
import copy
import hashlib
import json
from pathlib import Path
from audit import ROOT, decode

OUT=ROOT/'negative-traces'
OUT.mkdir(exist_ok=True)
def field(v,name):return v['value'][name]
def node(v,key):
    return next(p['value'] for p in v['value'] if p['key']['value']==key)
def set_atom(v,value):v['value']=value
def atom(v):return {'tag':'atom','value':v}

def make(name,source,event,select,mutate,contract,oracle):
    path=ROOT.parent/'traces'/source
    lines=[]
    for number,line in enumerate(path.open(),1):
        e=json.loads(line);lines.append(e)
        if e['event']!=event:continue
        p=decode(e['params']);post=decode(e['post'])
        if not select(p,post):continue
        before=copy.deepcopy(e)
        description=mutate(e,p,post)
        assert e!=before
        target=OUT/(name+'.ndjson')
        target.write_text(''.join(json.dumps(v,separators=(',',':'))+'\n' for v in lines))
        return dict(file=str(target),source=str(path),source_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                    changed_line=number,event=event,change=description,contract=contract,
                    expected_replay_rejection='post-state correspondence',expected_oracle=oracle)
    raise RuntimeError(f'no real event suitable for {name}')

def advance(e,p,post):
    a=field(node(field(e['post'],'raft'),p['node']),'applied')
    set_atom(a,a['value']+1);return 'Raft acknowledged application cursor increased by one after Advance.'
def persist(e,p,post):
    log=field(node(field(e['post'],'disk'),p['node']),'log')
    log['value'].pop();return 'One actual completed durable log entry omitted.'
def command(e,p,post):
    h=field(node(field(e['post'],'application'),p['node']),'hist')
    set_atom(field(h['value'][-1],'id'),32);return 'Last applied command identity replaced with unused request 32.'
def context(e,p,post):
    q=node(field(e['post'],'requests'),p['id'])
    set_atom(field(q,'context'),31);return 'Completed read invocation context changed to 31, leaving the returned witness unchanged.'
def evidence(e,p,post):
    m=p['message'];r=node(field(e['post'],'raft'),m['to']);pr=node(field(r,'prs'),m['from'])
    h=field(pr,'evidence');term=field(h['value'][-1],'term');set_atom(term,term['value']+1)
    return 'Remote Match prefix witness has a changed last-entry term.'
def learner(e,p,post):
    reads=field(node(field(e['post'],'application'),p['node']),'reads')
    rd=reads['value'][p['position']-1];field(rd,'confirmAcks')['value']=[atom(1),atom(4)]
    return 'Read confirmation claims {1,4}, where 4 is a learner and voters are {1,2,3}.'

reports=[
    make('advance-endpoint','node-lifecycle.ndjson','Advance',lambda p,s:s['raft'][p['node']]['applied']>0,advance,'AckPreservation','AckPreservation'),
    make('durable-entry-missing','node-lifecycle.ndjson','CompletePersist',lambda p,s:bool(s['disk'][p['node']]['log']),persist,'captured Ready persistence completion',None),
    make('applied-command','raw-elections-reads-recovery.ndjson','ApplyEntry',
         lambda p,s:p['node']==2 and s['application'][2]['hist'][-1]['id']>0 and s['application'][2]['hist'][-1]['kind']=='Normal' and len(s['application'][1]['hist'])>=len(s['application'][2]['hist']),command,'AppliedAgreement','AppliedAgreement'),
    make('read-context','node-lifecycle.ndjson','CompleteRead',lambda p,s:True,context,'ReadCorrelation','ReadCorrelation'),
    make('remote-match-evidence','raw-elections-reads-recovery.ndjson','Receive',
         lambda p,s:p['message']['type']=='MsgAppResp' and not p['message']['reject'] and p['message']['index']>0 and s['raft'][p['message']['to']]['role']=='Leader' and bool(s['raft'][p['message']['to']]['prs'][p['message']['from']]['evidence']),evidence,'ReplicationEvidence','ReplicationEvidence'),
    make('learner-read-ack','membership-snapshots.ndjson','CompleteRead',
         lambda p,s:4 in s['application'][p['node']]['reads'][p['position']-1]['confirmConfig']['learners'],learner,'ReadBasis','ReadBasis'),
]
(OUT/'manifest.json').write_text(json.dumps(reports,indent=2)+'\n')
print(json.dumps([{'name':Path(r['file']).name,'line':r['changed_line'],'oracle':r['expected_oracle']} for r in reports]))
