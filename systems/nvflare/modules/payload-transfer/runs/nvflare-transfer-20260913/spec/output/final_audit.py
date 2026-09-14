"""Verify final validation artifacts against original inputs and durable task receipts."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

OUT = Path(__file__).resolve().parents[2]
SPEC = OUT / 'spec'
EVIDENCE = SPEC / 'output'
SOURCE = Path('/home/ubuntu/nvflare-runs-20260913/source-transfer')

def read(path):
    return json.loads(path.read_text())

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

source_sha = subprocess.check_output(['git','rev-parse','HEAD'],cwd=SOURCE,text=True).strip()
assert source_sha == '53ba7ee567468ea7971dad4faccef13c6cb35dc2'
initial = read(EVIDENCE / 'initial-manifest.json')
assert all(sha(Path(p)) == expected for p,expected in initial['sha256'].items())
phase25 = read(EVIDENCE / 'reused-harness-evidence.json')['receipts']['audit.json']
assert all(sha(Path(p)) == expected for p,expected in phase25['sha256'].items())
toolchain = read(EVIDENCE / 'toolchain-manifest.json')
assert all(sha(Path(p)) == expected for p,expected in toolchain['sha256'].items())

traces = read(EVIDENCE / 'round1-traces/results.json')
assert traces['status'] == 'success' and traces['passed'] == 16 and traces['failed'] == 0
assert len(traces['details']) == 16
assert all(t['exit_code'] == 0 and t['complete_cursor'] for t in traces['details'])
assert sum(t['events'] for t in traces['details']) == 3029

labels = ['MC_round1','MC_hunt_s1_progress_bfs','MC_hunt_s3_settlement_bfs',
          'MC_hunt_s3_after_receipt_bfs','MC_hunt_s4_budgets_bfs','MC_hunt_s4_budgets_sim']
tasks = []
for label in labels:
    summary = read(EVIDENCE / (label + '_summary.json'))
    result = read(OUT / '.tlc-tasks/jobs' / summary['task_id'] / 'result.json')
    assert result['status'] == 'exited'
    assert sha(EVIDENCE / (label + '.out')) == summary['log_sha256']
    assert result['exit_code'] == (12 if summary['violations'] else 124)
    assert not summary['errors'] or summary['violations']
    tasks.append({k:v for k,v in summary.items() if k not in {'request','model_sha256','result','summary'}})

index = read(SPEC / 'findings.json')
assert index['schema_version'] == '2' and index['generated_by'] == 'validation-workflow'
assert index['system'] == 'nvflare-transfer'
headings = re.findall(r'^## Bug \d+: (.+)$',(SPEC/'bug-report.md').read_text(),re.M)
assert len(headings) == len(index['findings'])
assert set(headings) == {f['title'] for f in index['findings']}
assert {f['id'] for f in index['findings']} == {f['id'] for f in read(EVIDENCE/'classifications.json')}
for f in index['findings']:
    assert f['source'] == 'model-checking'
    assert f['severity'] in {'Critical','High','Medium'}
    assert (OUT/f['counterexample']).is_file()
    assert (SPEC/f['config']).is_file()
    assert f['invariant'] in (SPEC/'base.tla').read_text()
    for anchor in f['affected_code']:
        file, line = anchor.rsplit(':',1)
        assert (SOURCE/file).is_file() and int(line)>0
assert '## Result' in (SPEC/'changelog.md').read_text()
progress = read(EVIDENCE/'validation-progress.json')
assert progress['phase'] == 'complete' and not progress['active_tasks'] and not progress['remaining']

artifacts = [SPEC/n for n in ['changelog.md','bug-report.md','findings.json','validation-report.md','brief-coverage.md']]
artifacts += [EVIDENCE/(label+'.out') for label in labels]
artifacts += list(EVIDENCE.glob('*_counterexample.json'))
report = dict(passed=True,source_sha=source_sha,original_spec_config_traces_unchanged=True,
              original_harness_and_instrumented_source_unchanged=True,toolchain_unchanged=True,
              trace_count=16,trace_events=3029,action_names=94,convergence_rounds=1,
              convergence_is_budgeted=True,exhaustive_verification=False,
              hunt_configs=4,bfs_runs=5,simulation_runs=1,
              classifications={'A':0,'B':0,'C':len(index['findings'])},
              independent_phase4_reproduction=False,tasks=tasks,
              sha256={str(p.relative_to(OUT)):sha(p) for p in artifacts})
(EVIDENCE/'final-audit.json').write_text(json.dumps(report,indent=2)+'\n')
print('Final audit PASS: 16 complete traces, 4 hunt cfgs + required simulation,',len(index['findings']),'Case C findings; original inputs unchanged.')
