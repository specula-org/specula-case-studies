#!/usr/bin/env python3
"""Audit coverage without predicting protocol states or completing histories."""
import collections
import json
from pathlib import Path
import re
import sys

traces, spec = map(Path,sys.argv[1:])
expected=set(re.findall(r'e.event = "(\w+)"', (spec/'Trace.tla').read_text().split('CallBase(t, e) ==',1)[1]))
counts=collections.Counter()
quality=[]
for path in sorted(traces.glob('*.ndjson')):
    data=json.loads(path.read_text()); events=[e for s in data['traces'].values() for e in s]
    for e in events:
        assert e['tag']=='trace' and e['event'] in expected
        assert set(e)=={'tag','event','tid','inode','start','end','args','state'}
        assert 'thread' in e['state'] and isinstance(e['args'],dict)
        counts[e['event']]+=1
    pairs=overlap=0
    for i,a in enumerate(events):
        for b in events[i+1:]:
            if a['tid']==b['tid']: continue
            pairs+=1
            overlap+=int(max(a['start'],b['start'])<=min(a['end'],b['end']))
    quality.append({'trace':path.name,'events':len(events),'cross_thread_pairs':pairs,
                    'overlapping_pairs':overlap,'overlap_fraction':overlap/pairs if pairs else 0})
missing=sorted(expected-set(counts))
l2='ValidatePostState(t, e) == e.state = PostState(t, e)' in (spec/'Trace.tla').read_text()
result={'event_counts':dict(sorted(counts.items())),'uncovered':missing,'timeboxes':quality,
        'exact_post_state_equality':l2,'has_cross_thread_overlap':any(q['overlapping_pairs'] for q in quality),
        'meets_timebox_guide_20_percent':any(q['overlap_fraction']>=.2 for q in quality)}
print(json.dumps(result,indent=2))
if missing or not l2 or not result['meets_timebox_guide_20_percent']:
    raise SystemExit('INCOMPLETE: event or timebox coverage requires disposition')
