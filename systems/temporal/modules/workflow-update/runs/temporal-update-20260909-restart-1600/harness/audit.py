#!/usr/bin/env python3
"""Audit observed events and retain concrete disagreements without replaying a model."""
import collections
import datetime
import hashlib
import json
import re
from pathlib import Path
import sys
h=Path(__file__).resolve().parent
out=h.parent
actions=set(re.findall(r'IsEvent\("([^"]+)"\)', (out/'spec/Trace.tla').read_text()))
records={}
evidence=[]
for p in sorted((out/'traces').glob('*.ndjson')):
    rows=[json.loads(line) for line in p.read_text().splitlines()]
    trace=[r for r in rows if r.get('tag')=='trace']
    counts=collections.Counter(r['event']['name'] for r in trace)
    assert not (set(counts)-actions), (p, set(counts)-actions)
    assert [r['ordinal'] for r in trace]==list(range(1,len(trace)+1))
    for row in rows:
        ts=datetime.datetime.fromisoformat(row['ts'].replace('Z','+00:00'))
        assert ts.year>=2026
        if row['tag']!='config':
            assert row['event']['nid']=='h1'
            assert row['event']['state'] is not None
    records[p.stem]=dict(lines=len(rows),traceEvents=len(trace),events=dict(counts),
                        sha256=hashlib.sha256(p.read_bytes()).hexdigest())
    ev=[(line,r['event']['name'],r['event']['state']) for line,r in enumerate(rows,1) if 'event' in r]
    for i,(line,name,state) in enumerate(ev):
        if name=='CreateRecordWorkflowTaskStartedResponse':
            m=state['mutable']
            if m['task']['Type']==1 and m['registry']['updates']:
                later=next(((ln,n,st) for ln,n,st in ev[i+1:] if n=='ExecutionTransactionCommit'),None)
                if later:
                    evidence.append(dict(kind='normal-send-before-commit',scenario=p.stem,responseLine=line,
                                         commitLine=later[0],registry=m['registry'],mutableRV=m['rv']))
        if name=='probe.CachePut' and state['event']['event_type']==41:
            next_accept=next(((ln,st) for ln,n,st in ev[i+1:] if n=='OnAcceptanceMsg'),None)
            if next_accept:
                evidence.append(dict(kind='acceptance-event-cached',scenario=p.stem,cacheLine=line,
                                     acceptanceLine=next_accept[0],key=state['key']))
        if name=='UpdateWorkflowExecutionWithNew':
            m=state['mutable']
            previous=next((st['mutable'] for ln,n,st in reversed(ev[:i]) if isinstance(st,dict) and 'mutable' in st and st['mutable'].get('mutableIdentity')==m['mutableIdentity']),None)
            if previous and previous['rv']!=m['rv']:
                evidence.append(dict(kind='mutable-rv-advanced-before-store',scenario=p.stem,line=line,
                                     beforeRV=previous['rv'],preparedRV=m['rv']))
seen=set().union(*(r['events'] for r in records.values()))
report=dict(status="INCOMPLETE",sourceRevision="0c010ce5fe8c0180aa7573c72fe8fc87c6df7025",
            scenarios=records,observedActionTypes=len(seen),modelActionTypes=len(actions),
            observed=sorted(seen),unobserved=sorted(actions-seen),
            l2=dict(validator='whole-state equality; not a TRUE stub',
                    completeTracePasses=0,admissionPrefixOnly=True,
                    uncaptured=['full Matching acceptance/transfer ledger','all command and callback cursors',
                                'whole-state merge across every boundary','all normal timer lifecycle states',
                                'detached-host/process crash inventory','independent readback of internal tasks']),
            disagreements=evidence)
(h/'evidence/coverage.json').write_text(json.dumps(report,indent=2)+"\n")
hook_text = "\n".join(p.read_text() for p in (h/"src").rglob("*.go")) + "\n" + "\n".join(
    line for line in (h/"patches/instrumentation.patch").read_text().splitlines() if line.startswith("+"))
instrumented = set(re.findall(r'"([A-Za-z][A-Za-z0-9]+)"', hook_text)) & actions
reasons = {
    "AttachCallbacks": "Selected schedules do not attach callbacks to a duplicate Sent Update.",
    "HandleMessageInvalid": "Selected workers send valid protocol messages.",
    "RejectUnprocessed": "Rejection scenario explicitly rejects; no worker intentionally ignores an Update.",
    "StartToCloseTimerEligible": "Selected workers complete before STC expiration; dispatch failure triggers STS.",
    "StickyWorkerUnavailable": "Final schedules register the sticky poller before submitting Update.",
    "WaitLifecycleStageOutcomeRecheck": "Clients request COMPLETED; no controlled accepted-then-recheck waiter.",
    "WaitLifecycleStageSoftTimeout": "Final scenarios complete within the server long-poll window."
}
report["instrumentedActionNames"] = sorted(instrumented)
report["instrumentedNotObserved"] = {k: reasons.get(k, "Not reached by selected schedules.")
    for k in sorted(instrumented-seen)}
(h/"evidence/instrumentation-coverage.json").write_text(json.dumps(report,indent=2)+"\n")

for name,r in records.items():
    print(f"{name}: {r['lines']} lines, {r['traceEvents']} named probe events")
print(f"Observed {len(seen)}/{len(actions)} model action names; name occurrence is not L2 validation.")
print("Full trace replay: INCOMPLETE. See INSTRUMENTATION.md and evidence/coverage.json.")
