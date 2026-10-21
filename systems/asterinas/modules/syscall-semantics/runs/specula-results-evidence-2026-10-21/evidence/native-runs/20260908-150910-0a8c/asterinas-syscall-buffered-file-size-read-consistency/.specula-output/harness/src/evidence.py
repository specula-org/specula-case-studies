#!/usr/bin/env python3
import errno, hashlib, json, collections, sys
from pathlib import Path
H=Path(__file__).resolve().parents[1]; O=H.parent
cases_bytes=(H/'non-tla/cases.json').read_bytes(); cases=json.loads(cases_bytes)
byid={c['id']:c for c in cases['cases']}; executions=[]; seen=set()
raw_files=[Path(x) for x in sys.argv[1:]] if len(sys.argv)>1 else [max((H/'non-tla/raw').glob('observations-*.json'),key=lambda p:p.stat().st_mtime)]
for path in raw_files:
 for r in json.loads(path.read_text()):
    key=(r['backend'],r['case_id'])
    if key in seen: raise ValueError(f'duplicate execution: {key}')
    seen.add(key); c=byid[r['case_id']]
    if r['object_id']!=c['input']['objects'][0]['id']: raise ValueError('object identity changed')
    copied=r['delivered'] if r['delivered']>=0 else None
    committed=r['committed'] if r['committed']>=0 else None
    result=r['return']; advanced=r['offset_after']-r['offset_before']
    bad=result>c['requested_length'] or r.get('outside_request_changed',0)>0
    if copied is not None: bad |= r.get('delivered_prefix',copied)!=copied
    if result>=0 and copied is not None: bad |= result!=copied
    if result>=0 and committed is not None: bad |= result!=committed
    if c['syscall']=='read' and result>=0: bad |= advanced!=result
    if c['syscall']!='read': bad |= advanced!=0
    observations=dict(result={'return':result,'errno':errno.errorcode.get(r['errno']) if r['errno'] else None},
        progress={'attempted':c['requested_length'],'copied':copied,'committed':committed,
                  'reported':result if result>=0 else 0,'offset_advanced':advanced},
        state_before={'backend':r['backend'],'size':r['size_before'],'offset':r['offset_before'],'object_id':r['object_id']},
        state_after={'size':r['size_after'],'offset':r['offset_after'],'readable':r['readable_after'],'delivered_prefix':None if r.get('delivered_prefix',-1)<0 else r['delivered_prefix'],'outside_request_changed':None if r.get('outside_request_changed',-1)<0 else r['outside_request_changed']})
    executions.append(dict(case_id=r['case_id'],status='candidate' if bad else 'pass',oracle='count-and-offset',
                           observations=observations,evidence=[str(path.relative_to(O))]))
evidence=dict(schema_version=1,artifact='syscall-input-evidence',campaign=cases['campaign'],contract_sha256=cases['contract_sha256'],
              cases_sha256=hashlib.sha256(cases_bytes).hexdigest(),target={'name':'asterinas-buffered-ramfs-ext2-exfat','identity':'604948581512d83734377974d4c34adb4530f2d7; instrumentation manifest: harness/patches/manifest.json','smp':2},executions=executions)
(H/'non-tla/evidence.json').write_text(json.dumps(evidence,indent=2)+'\n')
summary=dict(generated=len(byid),planned_executions=3*len(byid),executed=len(seen),unexecuted=3*len(byid)-len(seen),
             truncated=cases['generation']['truncated'],statuses=dict(collections.Counter(e['status'] for e in executions)),unsupported=0,harness_error=0)
(H/'non-tla/coverage.json').write_text(json.dumps(summary,indent=2)+'\n'); print(json.dumps(summary))
