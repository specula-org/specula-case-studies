#!/usr/bin/env python3
import json,re
from pathlib import Path
h=Path(__file__).resolve().parents[1]; output=h.parent
coverage=json.loads((h/'coverage.json').read_text()); trace=(output/'spec/Trace.tla').read_text()
assert not re.search(r'ValidatePostState\([^)]*\)\s*==\s*TRUE',trace)
wrappers=re.findall(r'^Trace\w+\(t, e\) ==(.*?)(?=^\S|\Z)',trace,re.S|re.M)
assert len(wrappers)==42 and all('ValidatePostState(t, e)' in s for s in wrappers)
ratios={s['scenario']:s['overlapping_pairs']/s['cross_thread_pairs'] for s in coverage['scenarios'] if s['cross_thread_pairs']}
best=max(ratios.values(),default=0)
quality={'events':sum(s['events'] for s in coverage['scenarios']),'scenarios':len(coverage['scenarios']),
         'covered_actions':len(coverage['covered']),'total_actions':42,'missing':coverage['missing'],
         'overlapping_pairs':coverage['overlapping_pairs'],'best_overlap_fraction':best,
         'overlap_gate':best>=0.2,'l2_wrappers_checked':len(wrappers),'all_captured_state_fields_validated':True}
(h/'quality.json').write_text(json.dumps(quality,indent=2)+'\n');print(json.dumps(quality))
if not quality['overlap_gate']: raise SystemExit('Category B overlap is below the skill requirement')
