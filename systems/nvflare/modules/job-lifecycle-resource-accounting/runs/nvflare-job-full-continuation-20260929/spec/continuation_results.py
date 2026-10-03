#!/usr/bin/env python3
"""Index frozen continuation TLC evidence without turning timeouts into proofs."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parent


def n(value):
    return int(value.replace(',', ''))


def summarize(directory):
    manifest = json.loads((directory / 'manifest.json').read_text())
    result_path = directory / 'result.json'
    result = json.loads(result_path.read_text()) if result_path.exists() else {}
    log_path = directory / 'tlc.out'
    log = log_path.read_text() if log_path.exists() else ''
    progress = re.findall(r'Progress\((\d+)\).*?: ([\d,]+) states generated.*?, ([\d,]+) distinct states found.*?, ([\d,]+) states left on queue', log)
    totals = re.findall(r'([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue', log)
    diameter = re.findall(r'depth of the complete state graph search is (\d+)', log)
    violations = re.findall(r'(?:Invariant|Action property|Temporal property) (\S+) (?:is|was) violated', log)
    temporal = ('Temporal properties were violated' in log
                or 'Error: Temporal property ' in log
                or 'Error: Action property ' in log)
    errors = re.findall(r'^Error: (.*)', log, re.M)
    resource_errors = re.findall(
        r'^.*(?:OutOfMemoryError|GC overhead limit exceeded|Disk quota exceeded|'
        r'No space left on device|Exception in thread|StackOverflowError).*$', log, re.M)
    complete = 'Model checking completed. No error has been found.' in log
    stats = dict(zip(['depth', 'generated', 'distinct', 'queue'], map(n, progress[-1]))) if progress else {}
    if totals:
        stats.update(zip(['generated', 'distinct', 'queue'], map(n, totals[-1])))
    if diameter:
        stats['depth'] = n(diameter[-1])
    if '-S' in manifest['options']:
        simulation_progress = re.findall(
            r'Progress: ([\d,]+) states checked, ([\d,]+) traces generated', log)
        if simulation_progress:
            stats.update(zip(['states_checked', 'traces'], map(n, simulation_progress[-1])))
        if '-p' in manifest['options']:
            stats['depth_limit'] = int(manifest['options'][manifest['options'].index('-p') + 1])
    return {
        'run': directory.name, 'config': manifest['config'],
        'spec_file': manifest.get('spec_file', 'MC.tla'),
        'mode': 'simulation' if '-S' in manifest['options'] else 'BFS',
        'task_id': manifest['task']['task_id'],
        'process_status': result.get('status', 'uncollected'),
        'exit_code': result.get('exit_code'),
        'violations': violations, 'temporal_violation': temporal,
        'errors': errors, 'resource_errors': resource_errors,
        'complete_no_error_message': complete,
        'stats': stats, 'frozen_sha256': manifest['sha256'],
        'log': str(log_path.relative_to(ROOT.parent)),
        'counterexample': str((directory/'counterexample.json').relative_to(ROOT.parent))
            if (directory/'counterexample.json').exists() else None,
    }


def main():
    runs = [summarize(p.parent) for p in sorted((ROOT/'output').glob('continuation-*/manifest.json'))
            if 'task' in json.loads(p.read_text())]
    (ROOT/'output'/'continuation-run-index.json').write_text(json.dumps(runs, indent=2)+'\n')
    cfgs = {}
    for path in sorted(ROOT.glob('MC*.cfg')):
        body = re.sub(r'\\\*[^\n]*', '', path.read_text())
        cfgs[path.name] = {
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'active_config': body.strip(),
            'runs': [r['run'] for r in runs if r['config'] == path.name],
        }
    (ROOT/'output'/'continuation-config-audit.json').write_text(json.dumps(cfgs, indent=2)+'\n')
    print(json.dumps([{k:r[k] for k in ['run','process_status','violations','temporal_violation','stats']} for r in runs], indent=2))


if __name__ == '__main__':
    main()
