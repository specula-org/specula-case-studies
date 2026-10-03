#!/usr/bin/env python3
"""Check evidence/report consistency; does not classify or verify a product."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess

SPEC = Path(__file__).resolve().parent
OUT = SPEC.parent
SOURCE = Path('/home/ubuntu/specula-nvflare-gpt-continuation-20260926/source')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--preflight', action='store_true')
    ap.add_argument('--revision', default='C8')
    args = ap.parse_args()
    assert re.fullmatch(r'C[0-9]+', args.revision)
    revision = args.revision
    record = json.loads((SPEC/f'output/continuation-{revision}-trace-manifest.json').read_text())
    for name, expected in record['model'].items():
        assert sha(SPEC/name) == expected, name
    for kind in ['traces', 'scenario_reports']:
        for name, expected in record[kind].items():
            assert sha(OUT/name) == expected, name
    assert len(record['traces']) == len(record['scenario_reports']) == 32
    cfg = re.sub(r'\\\*[^\n]*', '', (SPEC/'Trace.cfg').read_text())
    assert re.search(r'PROPERTIES\s+TraceMatched\b', cfg)
    replay = json.loads((OUT/record['trace_replay']).read_text())
    replay = json.loads(replay['value']['content'][0]['text'])
    assert replay['passed'] == 32 and replay['failed'] == 0 and replay['success']
    negative_dir = OUT/f'harness/evidence/continuation/phase3-{revision}-negative-controls'
    negative = json.loads((negative_dir/'results.json').read_text())
    assert negative['checks_passed']
    assert sum(c.get('actual_tlc') == 'FAIL' for c in negative['controls']) == 5
    assert sum(c.get('input_rejected', False) for c in negative['controls']) == 5
    assert any(c.get('report_integrity_rejected') for c in negative['controls'])
    for replay_control in json.loads((negative_dir/'replay-results.json').read_text()):
        for name, expected in replay_control['spec_sha256'].items():
            assert sha(SPEC/name) == expected, ('negative control model', name)
    source_pin = subprocess.check_output(['git','rev-parse','HEAD'],cwd=SOURCE,text=True,timeout=30).strip()
    assert source_pin == '53ba7ee567468ea7971dad4faccef13c6cb35dc2'
    subprocess.run(['git','diff','--exit-code','HEAD','--'],cwd=SOURCE,check=True,timeout=30,capture_output=True)
    scenarios = re.findall(r'^### Scenario (\d+):', (OUT/'modeling-brief.md').read_text(),re.M)
    assert [int(n) for n in scenarios] == list(range(1,34))
    result = {'mode':'preflight' if args.preflight else 'final', 'revision':revision, 'source_pin':source_pin,
              'trace_count':32,'trace_replay_passed':32,'source_review_scenarios':len(scenarios),
              'negative_controls_passed':True,'tracked_source_unchanged':True,
              'model_hashes':record['model'],
              'extra_oracle_modules':{p.name:sha(p) for p in SPEC.glob('*Probes.tla')}}
    if not args.preflight:
        execution = json.loads((SPEC/f'output/continuation-{revision}-execution.json').read_text())
        assert not execution['active'] and not execution['queued'], 'TLC work remains unobserved'
        matrix = json.loads((SPEC/'output/continuation-final-matrix.json').read_text())
        hunt_cfgs = {p.name for p in SPEC.glob('MC_hunt_*.cfg')}
        seed_cfgs = {p.name for p in SPEC.glob('MC_seed_*.cfg')}
        assert {r['run']['config'] for r in matrix['hunts'] if r['run']['mode'] == 'BFS'} == hunt_cfgs
        assert {r['run']['config'] for r in matrix['seeds']} == seed_cfgs
        selected = [matrix['convergence'], *matrix['hunts'], *matrix['seeds']]
        evidence_hashes = {}
        for selection in selected:
            row = selection['run']
            directory = SPEC/'output'/row['run']
            for name, expected in row['frozen_sha256'].items():
                assert sha(directory/name) == expected, (row['run'], name)
            assert row['exit_code'] in (0, 12, 13, 124), row['run']
            assert not row.get('resource_errors'), row['run']
            names = ['manifest.json', 'tlc.out', 'result.json', 'summary.json']
            if row['violations'] or row['temporal_violation']:
                names += ['inspection.json', 'all-transition-deltas.json']
            for name in names:
                evidence_hashes[str((directory/name).relative_to(OUT))] = sha(directory/name)
        result['hunt_configurations'] = len(hunt_cfgs)
        result['seed_configurations'] = len(seed_cfgs)
        result['simulation_runs'] = sum(r['run']['mode'] == 'simulation' for r in matrix['hunts'])
        result['all_selected_frozen_inputs_match'] = True
        result['all_tasks_observed'] = True
        result['selected_evidence_sha256'] = evidence_hashes
        data = json.loads((SPEC/'findings.json').read_text())
        report = (SPEC/'bug-report.md').read_text()
        headings = re.findall(r'^## Bug (\d+): (.*)',report,re.M)
        assert data['schema_version'] == '2' and data['generated_by'] == 'validation-workflow'
        assert len(headings) == len(data['findings'])
        seen = set()
        for (number,title),finding in zip(headings,data['findings']):
            assert finding['id'] == 'MC-'+number and finding['title'] == title
            assert finding['id'] not in seen
            seen.add(finding['id'])
            assert finding['source'] == 'model-checking'
            assert finding['severity'] in ['Critical','High','Medium']
            assert finding['invariant'] and finding['summary'] and finding['scenario']
            assert (OUT/finding['counterexample']).is_file()
            assert (SPEC/finding['config']).is_file()
            for anchor in finding['affected_code']:
                name,line = anchor.rsplit(':',1)
                assert 1 <= int(line) <= len((SOURCE/name).read_text().splitlines()), anchor
        result['mc_findings'] = len(headings)
        result['report_sha256'] = sha(SPEC/'bug-report.md')
        result['findings_sha256'] = sha(SPEC/'findings.json')
    (SPEC/'output'/('continuation-'+revision+'-artifact-'+result['mode']+'.json')).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__ == '__main__':
    main()
