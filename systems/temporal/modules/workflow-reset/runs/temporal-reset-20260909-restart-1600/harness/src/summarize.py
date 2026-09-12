#!/usr/bin/env python3
import hashlib
import json
import re
import sys
from pathlib import Path
h=Path(sys.argv[1]).resolve();out=h.parent
validation=json.loads((h/'evidence/validation.json').read_text());results=[]
for row in validation['results']:
    name=Path(row['trace']).stem
    evidence=json.loads((out/'traces'/f'{name}.evidence.json').read_text())
    log=h/'evidence'/f'{name}.test.log';raw=h/'evidence/raw'/f'{name}.jsonl'
    results.append(dict(scenario=name,testPassed=bool(re.search(r'^PASS$',log.read_text(),re.M)),traceEvents=row['events'],rawEvents=len(raw.read_text().splitlines()),firstUnmatched=row['firstUnmatchedEvent'],initialState=row['initialState'],retryBad=evidence['audit']['retryBad'],availableBad=evidence['audit']['availableBad'],reapplyBad=evidence['audit']['reapplyBad'],checkpointCount=len(evidence['checkpoints']),checkpointMismatches=[p for p in evidence['checkpoints'] if not p['durableMatchesLastEvent']],projectionIssues=evidence['projectionIssues'],rawSHA256=hashlib.sha256(raw.read_bytes()).hexdigest(),testLogSHA256=hashlib.sha256(log.read_bytes()).hexdigest()))
report=dict(status=validation['status'],functionalTests=f'{sum(r["testPassed"] for r in results)}/{len(results)} PASS',acceptedFullTraces=f'{sum(r["status"]=="MATCHED" for r in validation["results"])}/{len(results)}',traceEvents=sum(r['traceEvents'] for r in results),emittedBaseActionTypes=len(validation['coverage'])-1,totalBaseActionTypes=len(validation['coverage'])+len(validation['uncovered'])-1,scenarios=results)
(h/'evidence/execution-summary.json').write_text(json.dumps(report,indent=2)+'\n')
