"""Collect observed TLC statistics; distinguish periodic from final summaries."""
from datetime import datetime, timezone
import json
from pathlib import Path
import re

SPEC = Path(__file__).resolve().parents[1]
OUT = SPEC / 'output'
rows = []
for group in ['hunt-bfs', 'hunt-revised-bfs', 'hunt-simulation']:
    for path in sorted((OUT / group).glob('*/receipt.json')):
        row = json.loads(path.read_text())
        raw = (path.parent / 'tlc.out').read_text(errors='replace')
        finals = re.findall(r'^([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue\.', raw, re.M)
        progress = re.findall(r'Progress\((\d+)\).*?: ([\d,]+) states generated.*?, ([\d,]+) distinct states found.*?, ([\d,]+) states left on queue', raw)
        vals = finals[-1] if finals else progress[-1][1:] if progress else None
        stats = dict(zip(['generated', 'distinct', 'queued'], [int(v.replace(',', '')) for v in vals])) if vals else None
        depths = [int(x) for x in re.findall(r'Progress\((\d+)\)', raw)] + [int(x) for x in re.findall(r'depth of the complete state graph search is (\d+)', raw)]
        temporal = [line for line in raw.splitlines() if line.startswith(('Checking temporal properties', 'Finished checking temporal properties'))]
        classification = None
        if row['status'] == 'violation':
            classification = 'Case A' if 'AbnormalTerminationVisible' in '\n'.join(row.get('errors', [])) else 'Case C'
        row.update(group=group, statistics=stats, statistics_origin='final' if finals else 'periodic',
                   observed_depth=max(depths, default=0), temporal_checks=temporal,
                   classification=classification, receipt=str(path.relative_to(SPEC)),
                   log=str((path.parent / 'tlc.out').relative_to(SPEC)))
        rows.append(row)
data = {'updated_utc': datetime.now(timezone.utc).isoformat(),
        'standard': json.loads((OUT / 'MC_round1_bfs_retry.receipt.json').read_text()), 'hunts': rows}
(OUT / 'model-checking-coverage.json').write_text(json.dumps(data, indent=2) + '\n')
lines = ['# Model-checking execution coverage', '',
         'Counts are distinct states found, not a proof or a count of fully explored states. Periodic counts are the last logged lower bounds before a budget stop. Original Case A counterexamples remain evidence; revised runs check the remaining source-backed assertions.', '',
         '| Run | Config | Distinct states | Queue | Depth | Result |', '|---|---|---:|---:|---:|---|',
         '| Standard | `MC.cfg` | 292,238,651 | 24,216,269 | 86 | 30-minute budget, no violation; periodic counts |']
for r in rows:
    s = r['statistics'] or {}
    count = f"{s['distinct']:,}" if s else '—'
    queue = f"{s['queued']:,}" if s else '—'
    result = r['status'] + (f"; {r['classification']}" if r['classification'] else '')
    if r['statistics_origin'] == 'periodic':
        result += '; periodic counts'
    lines.append(f"| {r['group']} | [{r['config']}]({r['group']}/{Path(r['config']).stem}/tlc.out) | {count} | {queue} | {r['observed_depth']} | {result} |")
(OUT / 'model-checking-coverage.md').write_text('\n'.join(lines) + '\n')
print(json.dumps({'runs': len(rows), 'running': [r['config'] for r in rows if r['status']=='running'],
                  'statuses': {r['group']+'/'+r['config']:r['status'] for r in rows}}, indent=2))
