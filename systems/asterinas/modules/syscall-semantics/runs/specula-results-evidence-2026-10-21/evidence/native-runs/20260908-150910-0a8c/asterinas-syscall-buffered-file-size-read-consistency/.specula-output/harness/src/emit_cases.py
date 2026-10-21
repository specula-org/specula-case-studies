import json
from pathlib import Path
h=Path(__file__).resolve().parents[1]
c=json.loads((h/'non-tla/cases.json').read_text())
regions=['valid','null','unmapped','prot-none','read-only','guard-page']
lines=['/* SPDX-License-Identifier: MPL-2.0 */','struct input_case { const char *id, *object; int kind, region; size_t length, accessible; };','static const struct input_case cases[] = {']
for case in c['cases']:
    objects=case['input']['objects']
    if len(objects)!=1 or case['input']['edges']: raise ValueError('unsupported object graph')
    obj=objects[0]
    lines.append('  {%s, %s, %d, %d, %d, %d},' % (json.dumps(case['id']),json.dumps(obj['id']),['read','pread64','pwrite64'].index(case['syscall']),regions.index(obj['region']),case['requested_length'],obj['accessible_units']))
lines.append('};')
(h/'src/cases.h').write_text('\n'.join(lines)+'\n')
