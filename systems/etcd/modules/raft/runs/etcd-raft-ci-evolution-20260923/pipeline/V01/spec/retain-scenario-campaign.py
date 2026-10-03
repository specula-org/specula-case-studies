#!/usr/bin/env python3
"""Hash the completed local campaign; never read or modify CI verdict/current.

Only the prior explicitly selected evidence and this conversation's campaign
directory are enumerated. Large TLC state caches are not traversed.
"""
import datetime
import hashlib
import json
import subprocess
from pathlib import Path

SPEC = Path(__file__).resolve().parent
OUT = SPEC.parent
CAMPAIGN = SPEC / 'output/scenario-campaign-20260913-043418'
ROOT = Path('/home/ubuntu/specula-etcd-ci-init-20260912.FNeLj3NS')
SOURCE = OUT.parent / 'source'

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

manifest = json.loads((CAMPAIGN / 'campaign.json').read_text())
assert manifest['status'] == 'completed-budgeted-checks-with-coverage-gaps'
prior = json.loads((CAMPAIGN / 'prior-validation-artifact-manifest.json').read_text())
paths = {OUT / name for name in prior['artifacts']}
paths.update(p for p in CAMPAIGN.rglob('*') if p.is_file())
paths.update(SPEC / name for name in [
    'base.tla', 'model-notes.md', 'validation-report.md', 'remaining-validation-work.md',
    'bug-report.md', 'findings.json', 'verification-results.json', 'brief-coverage.md',
    'changelog.md', 'collect-scenario-results.py', 'collect-registered-traces.py',
    'report-scenario-campaign.py', 'retain-scenario-campaign.py', 'output/active-scenario-campaign.txt'])
paths.add(OUT / 'harness/CORRESPONDENCE.md')
target = SPEC / 'validation-artifact-manifest.json'
paths.discard(target)

source_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=SOURCE, text=True).strip()
assert source_head == prior['source_head']
prior_source = json.loads((SPEC / 'output/validation-round-2/source-final-observation.json').read_text())
assert subprocess.check_output(['git', 'diff'], cwd=SOURCE, text=True) == prior_source['production_diff']
for name, expected in prior_source['source_files_sha256'].items():
    assert digest(SOURCE / name) == expected, f'Source input changed: {name}'
reuse = json.loads((CAMPAIGN / 'reused-evidence-input-check.json').read_text())
for name in reuse['artifacts_checked']:
    if name != 'harness/oracle/base.tla':
        assert digest(OUT / name) == prior['artifacts'][name]['sha256'], f'Reused asset changed: {name}'
observations = {
    'head': source_head,
    'instrumented_files': {name: digest(SOURCE / name) for name in ['raft.go', 'node.go']},
    'harness_source': {p.name: digest(p) for p in sorted((OUT / 'harness/src').glob('*.go'))},
    'canonical_traces': {p.name: digest(p) for p in sorted((OUT / 'traces').glob('*.ndjson'))},
    'go_diff_stat': subprocess.check_output(['git', 'diff', '--stat'], cwd=SOURCE, text=True),
    'no_active_tlc_processes': not any(
        'tlc2.TLC' in line and len(line.split(None, 2)) == 3 and Path(line.split(None, 2)[1]).name == 'java'
        for line in subprocess.check_output(['ps', '-eo', 'pid,args'], text=True).splitlines()[1:])}
assert observations['no_active_tlc_processes'], 'Do not finalize while TLC remains active'
observation_path = CAMPAIGN / 'source-final-observation.json'
observation_path.write_text(json.dumps(observations, indent=2) + '\n')
paths.add(observation_path)

artifacts = {}
for path in sorted(paths):
    assert path.is_file(), f'Missing retained artifact: {path}'
    artifacts[str(path.relative_to(OUT))] = {'sha256': digest(path), 'bytes': path.stat().st_size}
result = {
    'schema_version': 1,
    'generated_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'task_status': manifest['status'],
    'root': str(OUT),
    'source_head': source_head,
    'artifact_count': len(artifacts),
    'artifacts': artifacts,
    'coverage': 'Prior explicitly selected evidence plus the resumed campaign inputs, native receipts, counterexample, trace regression, reports and scripts. Earlier phase artifacts remain historical evidence, not replacement executions.',
    'states': 'Earlier retained BFS state inventories remain referenced. Registered runner cleans new state caches; new logs, seeds, receipts and counterexamples are retained.',
    'runtime_hashes': {str(p.relative_to(ROOT)): digest(p) for p in [ROOT / 'Specula/lib/tla2tools.jar', ROOT / 'Specula/lib/CommunityModules-deps.jar', ROOT / 'Specula/scripts/tlc/run_model_check.sh', ROOT / 'Specula/src/specula/tlc_tasks.py']}}
target.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'artifacts': len(artifacts), 'source_head': source_head, 'no_active_tlc_processes': observations['no_active_tlc_processes']}))
