#!/usr/bin/env python3
"""Retain and verify only explicitly selected current-round trace results."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('--label', action='append', required=True)
parser.add_argument('--round', type=int, default=1)
args = parser.parse_args()
spec = Path(__file__).resolve().parent
harness = spec.parent / 'harness'
out = spec / 'output' / f'validation-round-{args.round}'
out.mkdir(parents=True, exist_ok=True)
hashes = {name: hashlib.sha256((spec / name).read_bytes()).hexdigest()
          for name in ['base.tla', 'Trace.tla', 'Trace.cfg']}
results = {}
for label in args.label:
    paths = sorted((harness / 'logs').glob(f'*-{label}.json'))
    assert paths, f'No results for explicitly selected batch {label}'
    for path in paths:
        result = json.loads(path.read_text())
        assert result['spec_sha256'] == hashes, path
        trace = Path(result['trace'])
        assert hashlib.sha256(trace.read_bytes()).hexdigest() == result['sha256'], trace
        key = (str(trace), result['mode'])
        assert key not in results, f'Duplicate current-round evidence: {key}'
        results[key] = result
        shutil.copy2(path, out / path.name)
        logfile = Path(result['log'])
        shutil.copy2(logfile, out / logfile.name)

def result_for(path, mode):
    return results[(str(path.resolve()), mode)]

positives = []
for trace in sorted((spec.parent / 'traces').glob('*.ndjson')):
    full = result_for(trace, 'full-correspondence')
    oracle = result_for(trace, 'observation-oracle')
    for result in [full, oracle]:
        assert result['status'] == 'success', result
        assert result['final_distinct_states'] == result['event_count'], result
        assert result['final_queue'] == 0, result
    positives.append({'trace': trace.name, 'events': full['event_count'],
                      'full': full, 'oracle': oracle})

negatives = []
for mutation in json.loads((harness / 'negative-traces/manifest.json').read_text()):
    trace = Path(mutation['file'])
    full = result_for(trace, 'full-correspondence')
    oracle = result_for(trace, 'observation-oracle')
    assert full['status'] == 'trace_mismatch', full
    assert full['failed_trace_line'] == mutation['changed_line'], full
    expected = mutation['expected_oracle']
    if expected:
        assert oracle.get('violated_invariant') == expected, oracle
    else:
        assert oracle['status'] == 'success', oracle
    assert hashlib.sha256(Path(mutation['source']).read_bytes()).hexdigest() == mutation['source_sha256']
    negatives.append({'mutation': mutation, 'full': full, 'oracle': oracle})

coverage = json.loads((harness / 'coverage.json').read_text())
assert not coverage['unvisited_events']
assert not coverage['missing_required_witnesses']
report = {'status': 'trace-validation-passed', 'round': args.round,
          'evidence_batches': args.label, 'spec_sha256': hashes,
          'positive': positives, 'negative': negatives, 'coverage': coverage,
          'scope': 'Finite trace correspondence and predicate sensitivity only; model checking and convergence are separate.'}
(out / 'trace-results.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'positive_traces': len(positives),
                  'events': sum(x['events'] for x in positives),
                  'invalid_traces_rejected': len(negatives),
                  'named_predicate_detections': sum(x['mutation']['expected_oracle'] is not None for x in negatives)}))
