#!/usr/bin/env python3
"""Independent schema, branch and state-observation audit of real traces."""
import collections
import datetime
import hashlib
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parent
sys.dont_write_bytecode=True
sys.path.insert(0,str(ROOT.parent/'spec'))
from trace_codec import preflight, EVENTS

def decode(x):
    t,v=x['tag'],x['value']
    if t=='atom':return v
    if t in ('seq','set'):return [decode(i) for i in v]
    if t=='record':return {k:decode(i) for k,i in v.items()}
    pairs=[(decode(p['key']),decode(p['value'])) for p in v]
    if all(isinstance(k,(int,str)) for k,_ in pairs):return dict(pairs)
    return pairs

def hist(r):
    h=r['usnap']['hist'] if r['usnap']['index'] else r['store']['hist']
    return h[:r['uoff']-1]+r['unstable'] if r['unstable'] else h

def audit(path):
    preflight(path)
    events=collections.Counter(); witnesses=collections.Counter(); decisions=collections.Counter()
    prev=None;last_ts=None;entry_sizes=set();max_index=0;max_term=0;settings=None
    for number,line in enumerate(path.open(),1):
        e=json.loads(line);name=e['event'];post=decode(e['post']);p=decode(e['params']) if 'params' in e else {}
        ts=datetime.datetime.fromisoformat(e['ts'].replace('Z','+00:00'))
        assert ts.tzinfo is not None
        assert last_ts is None or ts>=last_ts,(path,number,'time reversed')
        last_ts=ts;events[name]+=1
        if name=='Init':settings=decode(e['settings'])
        for node,r in post['raft'].items():
            max_index=max(max_index,len(hist(r)));max_term=max(max_term,r['term'])
            for entry in hist(r):entry_sizes.add((entry['kind'],entry['weight'],entry['encoded']))
            if not prev:continue
            old=prev['raft'][node]
            if r['role']=='Leader' and old['role']!='Leader':witnesses['became_leader']+=1
            if old['role']=='PreCandidate' and r['role']=='Candidate':witnesses['prevote_continuation']+=1
            if r['role']=='Follower' and old['role']=='Leader':witnesses['leader_stepdown']+=1
            if name=='Tick' and r['role']=='Follower' and old['role']=='Leader' and old['checkQuorum']:witnesses['check_quorum_stepdown']+=1
            if r['config']['outgoing'] and not old['config']['outgoing']:witnesses['joint_configuration_entered']+=1
            if name=='Advance' and len(hist(r))==len(hist(old))+1:
                e=hist(r)[-1]
                if e['kind']=='V2' and not e['changes']:witnesses['automatic_leave_appended']+=1
            if name=='Restart' and old['config']['outgoing'] and not r['config']['outgoing']:
                witnesses['joint_configuration_lost_on_restart']+=1
            for peer,pr in r['prs'].items():
                was=old['prs'].get(peer)
                if was and len(pr['inflight'])==settings['MaxInflight'] and len(was['inflight'])<len(pr['inflight']):witnesses['inflight_became_full']+=1
                if was and len(was['inflight'])==settings['MaxInflight'] and len(pr['inflight'])<len(was['inflight']):witnesses['inflight_released_from_full']+=1
                if was and pr['match']>was['match'] and peer!=node:witnesses['remote_match_advanced']+=1
        if name=='Propose':
            node=p['node'];r=post['raft'][node];decisions[r['decision']]+=1
            oldh=hist(prev['raft'][node]);newh=hist(r)
            if post['requests'][p['id']]['kind']!='Normal' and len(newh)>len(oldh) and newh[-1]['kind']=='Normal':witnesses['configuration_rewritten']+=1
            if r['decision']=='Accepted' and post['requests'][p['id']]['weight']>settings['MaxUncommitted']:witnesses['oversized_first_proposal_accepted']+=1
        if name=='Advance' and post['application'][p['node']]['jobs']:witnesses['advance_before_application']+=1
        if name=='Receive':
            m=p['message'];r=post['raft'][m['to']];old=prev['raft'][m['to']]
            if m['type']=='MsgApp' and hist(old)[:min(len(hist(old)),len(hist(r)))]!=hist(r)[:min(len(hist(old)),len(hist(r)))]:witnesses['conflicting_suffix_repaired']+=1
            if m['type']=='MsgAppResp' and m['reject']:witnesses['append_rejection_received']+=1
            if m['type']=='MsgSnap':
                if r['usnap']['index']>old['usnap']['index']:witnesses['full_snapshot_restore']+=1
                elif r['commit']>old['commit']:witnesses['fast_snapshot_restore']+=1
                else:witnesses['snapshot_ignored']+=1
        if name=='CompleteRead':
            rd=post['application'][p['node']]['reads'][p['position']-1]
            witnesses['singleton_read_return' if rd['singleton'] else 'quorum_read_return']+=1
            if rd['requester']!=rd['leader']:witnesses['forwarded_read_return']+=1
        if name=='Publish':
            node=p['node'];b=post['ready'][node]
            if b['entries'] and 'Entries' not in b['done']:witnesses['publication_before_entries_fsync']+=1
        if name=='ReportSnapshot':witnesses['snapshot_report_failure' if p['failed'] else 'snapshot_report_success']+=1
        prev=post
    # This harness retains exact protobuf lengths; the current request encoder
    # assumes one-byte term/index varints, and explicitly audits that bound.
    assert max_index<128 and max_term<128,(max_index,max_term)
    return dict(sha256=hashlib.sha256(path.read_bytes()).hexdigest(),events=dict(events),
                witnesses=dict(witnesses),proposal_decisions=dict(decisions),max_index=max_index,max_term=max_term,
                entry_size_mapping=[dict(kind=k,payload=w,encoded=z) for k,w,z in sorted(entry_sizes)],
                caller={k:settings[k] for k in ['RawNodes','SendPolicy','PersistPolicy','EarlyAdvance','RecoveryMode']})

if __name__=='__main__':
    reports={p.name:audit(p) for p in sorted((ROOT.parent/'traces').glob('*.ndjson'))}
    exercised=set().union(*(r['events'] for r in reports.values()))
    totals=collections.Counter()
    for r in reports.values():totals.update(r['witnesses'])
    required={'became_leader','prevote_continuation','check_quorum_stepdown','configuration_rewritten',
              'advance_before_application','conflicting_suffix_repaired','inflight_became_full',
              'inflight_released_from_full','full_snapshot_restore','fast_snapshot_restore',
              'quorum_read_return','singleton_read_return','publication_before_entries_fsync',
              'oversized_first_proposal_accepted','snapshot_report_failure','snapshot_report_success',
              'joint_configuration_entered','automatic_leave_appended',
              'joint_configuration_lost_on_restart'}
    report={'traces':reports,'unvisited_events':sorted(EVENTS-exercised),
            'witness_totals':dict(totals),'missing_required_witnesses':sorted(required-totals.keys()),
            'state_gate':'Observed post-state equality checks all six components for every event; no silent actions.',
            'oracle_limit':'A nonzero branch count establishes visitation, not exhaustive or liveness coverage.'}
    (ROOT/'coverage.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'trace_count':len(reports),'events':sum(sum(r['events'].values()) for r in reports.values()),'unvisited_events':report['unvisited_events']}))
    if report['unvisited_events'] or report['missing_required_witnesses']:
        raise SystemExit('Unexercised coverage targets: '+str(report['missing_required_witnesses']))
