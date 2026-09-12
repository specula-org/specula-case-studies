#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser();parser.add_argument('output',type=Path);args=parser.parse_args();root=args.output.resolve()
    spec=root/'spec';ev=root/'harness/evidence';ev.mkdir(parents=True,exist_ok=True)
    (ev/'java-tmp').mkdir(exist_ok=True)
    cp=os.environ.get('TLC_CLASSPATH','/home/ubuntu/Specula-incremental-dataset-20260815/tools/tla2tools.jar:/home/ubuntu/Specula-incremental-dataset-20260815/tools/CommunityModules-deps.jar')
    code=(spec/'Trace.tla').read_text()
    assert 'db\' = DecodeDB(s.db)' in code and 'op\' = DecodeOps(s.op)' in code
    assert 'pending\' = s.pending' in code and 'deletion\' = DecodeDeletion(s.deletion)' in code
    assert 'No silent actions' in code
    supported=set(re.findall(r'IsEvent\("([^"]+)"\)',code))|{'Bootstrap'}
    traces=sorted((root/'traces').glob('*.ndjson'));results=[];coverage={}
    for trace in traces:
        lines=[json.loads(l) for l in trace.read_text().splitlines()]
        assert lines and lines[0]['event']=='Bootstrap'
        last=None
        for row in lines:
            assert row['tag']=='trace' and row['event'] in supported
            now=datetime.datetime.fromisoformat(row['ts'].replace('Z','+00:00'))
            assert now.year>=2026 and (last is None or now>=last);last=now
            assert set(row['state'])=={'db','op','pending','rt','audit','deletion','used'}
            coverage[row['event']]=coverage.get(row['event'],0)+1
        command=['timeout','120','java',f'-Djava.io.tmpdir={ev / "java-tmp"}','-Xint','-XX:+UseParallelGC','-Xmx2g','-cp',cp,'tlc2.TLC','-workers','1','-metadir',str(ev/'tlc-states'/trace.stem),'-config','Trace.cfg','Trace']
        log=ev/(trace.stem+'.tlc.log')
        env=dict(os.environ,JSON=str(trace))
        with log.open('w') as out:result=subprocess.run(command,cwd=spec,env=env,stdout=out,stderr=subprocess.STDOUT,check=False)
        text=log.read_text();initial=bool(re.search(r'initial states: 1 distinct state',text))
        matched=result.returncode==0 and initial and 'No error has been found' in text
        frontier=max([int(n) for n in re.findall(r'/\\ l = (\d+)',text)] or [1])
        results.append(dict(trace=trace.name,sha256=digest(trace),events=len(lines),returnCode=result.returncode,status='MATCHED' if matched else ('UNMATCHED' if 'Temporal property TraceMatched was violated' in text else 'ERROR'),initialState=initial,firstUnmatchedLine=None if matched else frontier,firstUnmatchedEvent=None if matched or frontier>len(lines) else lines[frontier-1]['event'],log=str(log)))
        print(f'{trace.name}: {results[-1]["status"]}; first unmatched {results[-1]["firstUnmatchedEvent"]}')
    # A prefix selected verbatim from a real trace checks non-vacuous consumption.
    prefix=ev/'observed-start-prefix.ndjson'
    prefix.write_text('\n'.join(traces[-1].read_text().splitlines()[:4])+'\n')
    prefix_command=['timeout','120','java',f'-Djava.io.tmpdir={ev / "java-tmp"}','-Xint','-XX:+UseParallelGC','-Xmx2g','-cp',cp,'tlc2.TLC','-workers','1','-metadir',str(ev/'tlc-states'/'observed-prefix'),'-config','Trace.cfg','Trace']
    with (ev/'observed-start-prefix.tlc.log').open('w') as out:
        prefix_result=subprocess.run(prefix_command,cwd=spec,env=dict(os.environ,JSON=str(prefix)),stdout=out,stderr=subprocess.STDOUT,check=False)
    prefix_log=(ev/'observed-start-prefix.tlc.log').read_text()
    prefix_ok=prefix_result.returncode==0 and 'initial states: 1 distinct state' in prefix_log and 'No error has been found' in prefix_log
    report=dict(status='PASS' if results and all(r['status']=='MATCHED' for r in results) else 'INCOMPLETE',specSHA256={p.name:digest(p) for p in [spec/'Trace.tla',spec/'Trace.cfg',spec/'base.tla']},results=results,coverage=coverage,uncovered=sorted(supported-set(coverage)),strongPostStateChecks=True,silentActions=False,observedPrefixControl=dict(events=4,matched=prefix_ok,returnCode=prefix_result.returncode))
    (ev/'validation.json').write_text(json.dumps(report,indent=2)+'\n')
    raise SystemExit(0 if report['status']=='PASS' else 2)
if __name__=='__main__':main()
