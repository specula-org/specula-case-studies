#!/usr/bin/env python3
"""Decision-time and cross-stage witnesses from unchanged real observations.
Counts only visitation; each witness retains its source line and request/node.
No protocol transitions or success claims are inferred from these counts.
"""
import sys,json,hashlib,collections
from pathlib import Path
sys.dont_write_bytecode=True
P=Path(__file__).resolve().parent
sys.path.insert(0,str(P.parent/'harness'))
from audit import decode,hist
root=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else P/'output/quality-round-20260913-0910'
root.mkdir(parents=True,exist_ok=True)
reports={}; total=collections.Counter(); queues=[]
for path in sorted((P.parent/'traces').glob('*.ndjson')):
    witnesses=collections.defaultdict(list);previous=None;settings=None
    def hit(key,line,**detail):witnesses[key].append(dict(line=line,**detail));total[key]+=1
    for line,raw in enumerate(path.open(),1):
        x=json.loads(raw);ev=x['event'];p=decode(x['params']) if 'params' in x else {};post=decode(x['post'])
        if previous is None: settings=decode(x['settings']);previous=post;continue
        node=p.get('node',p.get('message',{}).get('to'));before=previous['raft'].get(node);after=post['raft'].get(node)
        divergent=len({json.dumps(r['config'],sort_keys=True) for r in previous['raft'].values() if r['alive']})>1
        if ev=='Receive' and p['message']['type'] in ['MsgVote','MsgPreVote']:
            m=p['message'];hit('vote_decision',line,node=node)
            if divergent:hit('vote_with_configuration_disagreement',line,node=node)
            if m['logTerm']<(hist(before)[-1]['term'] if hist(before) else 0) or (hist(before) and m['logTerm']==hist(before)[-1]['term'] and m['index']<len(hist(before))):hit('vote_stale_log',line,node=node)
            if node in before['config']['learners']:hit('vote_at_learner',line,node=node)
            if m['from'] not in before['config']['voters']:hit('vote_from_nonvoter',line,node=node)
            if before['incarnation']>0:hit('vote_after_restart',line,node=node)
        if ev in ['Campaign','Tick']:
            hit('campaign_observation' if ev=='Campaign' else 'tick_observation',line,node=node)
            if ev=='Campaign' or (before['role']!='Leader' and before['elapsed']+1>=before['timeout']):hit('hup_attempt',line,node=node,trigger=ev)
            if before['role']=='PreCandidate':hit('campaign_observed_pre_candidate',line,node=node,trigger=ev)
            if ev=='Tick' and node not in before['config']['voters']:hit('tick_observed_nonvoter',line,node=node)
            if ev=='Tick' and before['elapsed']+1<before['timeout']:hit('tick_before_timeout',line,node=node)
            if any(e['kind'] in ['AddVoter','AddLearner','Remove','Update'] for e in hist(before)[before['applied']:before['commit']]):hit('hup_with_unapplied_configuration',line,node=node)
            if node not in before['config']['voters']:hit('hup_nonvoter',line,node=node)
        if ev=='TransferLeader' and before['role']=='Leader':
            target=p['target'];hit('transfer_decision',line,node=node,target=target)
            if divergent:hit('transfer_with_configuration_disagreement',line,node=node,target=target)
            if target in before['config']['learners']:hit('transfer_to_learner',line,node=node,target=target)
            if target not in before['prs']:hit('transfer_to_unknown',line,node=node,target=target)
            if target==before['transfer']:hit('transfer_same_target',line,node=node,target=target)
            if target==node:hit('transfer_self',line,node=node)
            if target in before['prs'] and before['prs'][target]['match']<len(hist(before)):hit('transfer_with_replica_lag',line,node=node,target=target)
        if ev=='Propose':
            q=previous['requests'][p['id']];hit('proposal_decision',line,node=node,request=p['id'],decision=after['decision'])
            if q['kind'] in ['AddVoter','AddLearner','Remove','Update']:
                hit('configuration_proposal',line,node=node,request=p['id'],decision=after['decision'])
                if after['decision']=='Accepted' and hist(after)[-1]['kind']=='Normal':hit('configuration_rewrite_to_noop',line,node=node,request=p['id'])
                if divergent:hit('configuration_proposal_with_configuration_disagreement',line,node=node,request=p['id'])
        if ev=='ApplyEntry':
            e=previous['application'][node]['jobs'][0]['entries'][0]
            if e['kind'] in ['AddVoter','AddLearner','Remove','Update']:
                rid=e['id'];kind=e['kind'];target=e['target'];hit('configuration_callback',line,node=node,request=rid,kind=kind,target=target)
                if rid:
                    q=previous['requests'][rid];assert q['handoff'] and (q['kind'],q['target'])==(kind,target)
                    hit('request_correlated_callback',line,node=node,request=rid,kind=kind,target=target)
                    if q['status']=='Canceled':hit('callback_after_API_cancellation',line,node=node,request=rid)
                if target==0 or rid in settings['CancelChanges']:hit('configuration_callback_canceled',line,node=node,request=rid)
                if kind=='AddLearner' and target in before['config']['voters']:hit('learner_demotion_noop',line,node=node,request=rid)
                if kind=='Update':hit('update_noop',line,node=node,request=rid)
                if kind=='AddVoter' and target in before['config']['learners']:hit('learner_promoted',line,node=node,request=rid)
                if kind=='Remove' and target not in before['prs']:hit('unknown_removal_callback',line,node=node,request=rid)
                if divergent:hit('callback_with_configuration_disagreement',line,node=node,request=rid)
                if before['transfer']:hit('callback_during_transfer',line,node=node,request=rid,target=before['transfer'])
                if before['readQueue'] or before['readStates'] or any(not previous['requests'].get(rd['rid'],{}).get('completed',False) for rd in previous['application'][node]['reads']):hit('callback_with_pending_read',line,node=node,request=rid)
                if before['applied']>=e['index']:hit('callback_after_early_advance',line,node=node,request=rid)
                if before['incarnation']>0:hit('callback_after_restart',line,node=node,request=rid)
                if any(pr['inflight'] for peer,pr in before['prs'].items() if peer!=node):hit('callback_with_inflight_replication',line,node=node,request=rid)
        if ev=='QueueApplication':
            entries=[e for j in post['application'][node]['jobs'] for e in j['entries'] if e['kind'] in ['AddVoter','AddLearner','Remove','Update'] and e['id']]
            if entries:queues.append(dict(trace=path.name,line=line,node=node,entries=entries))
        if ev=='CompleteRead' and divergent:hit('read_completion_with_configuration_disagreement',line,node=node,request=p['id'])
        previous=post
    reports[path.name]=dict(sha256=hashlib.sha256(path.read_bytes()).hexdigest(),counts={k:len(v) for k,v in witnesses.items()},witnesses=witnesses)
result=dict(totals=dict(total),traces=reports,management_queue_candidates=queues,limit='Nonzero counts are concrete visitation witnesses, not exhaustive interleaving or progress coverage.')
required=['vote_stale_log','vote_at_learner','hup_with_unapplied_configuration','hup_nonvoter','transfer_to_unknown','transfer_same_target','transfer_self','transfer_with_configuration_disagreement','learner_demotion_noop','callback_after_API_cancellation','callback_during_transfer','callback_with_pending_read','callback_after_early_advance','read_completion_with_configuration_disagreement']
result['unvisited_requested_decision_or_interaction_witnesses']=[k for k in required if total.get(k,0)==0]
(root/'interaction-coverage.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(dict(totals=result['totals'],management_queue_candidates=queues),indent=2))
