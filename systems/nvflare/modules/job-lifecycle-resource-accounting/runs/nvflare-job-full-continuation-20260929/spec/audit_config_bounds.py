#!/usr/bin/env python3
"""Compare current TLC parameters with immutable supplied assets and probe references."""
from pathlib import Path
import argparse
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parent
BASELINE = Path('/home/ubuntu/specula-nvflare-gpt-continuation-20260926/handoff/full/run/nvflare-job/.specula-output/spec')
REFERENCES = {
    'MC_hunt_probe_admin_abort.cfg': 'MC.cfg',
    'MC_hunt_probe_completion_write.cfg': 'MC.cfg',
    'MC_hunt_probe_start_failure_write.cfg': 'MC.cfg',
    'MC_hunt_probe_deploy_meta.cfg': 'MC.cfg',
    'MC_hunt_probe_cant_schedule.cfg': 'MC_hunt_s1_status.cfg',
    'MC_hunt_probe_deleted_slot.cfg': 'MC_hunt_s2_slots.cfg',
    'MC_hunt_probe_stop_success.cfg': 'MC_hunt_s4_outcome.cfg',
    'MC_hunt_u1_startup_gap.cfg': 'MC_hunt_s4_outcome.cfg',
    'MC_hunt_startup_failure.cfg': 'MC.cfg',
    'MC_seed_F5_keyerror.cfg': 'MC_seed_F5.cfg',
}


def parse(path):
    text = re.sub(r'\\\*[^\n]*', '', path.read_text())
    settings = {k:v.strip() for k, _, v in re.findall(r'^\s*(\w+)\s*(=|<-)\s*([^\n]+)', text, re.M)}
    extra = {}
    for name in ('CONSTRAINT', 'VIEW', 'SYMMETRY'):
        extra[name] = re.findall(r'^\s*'+name+r'S?\s+([^\n]+)', text, re.M)
    return {'settings':settings, **extra}


def difference(left, right):
    return {k:{'reference':left.get(k),'new':right.get(k)} for k in sorted(left.keys()|right.keys()) if left.get(k)!=right.get(k)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--revision', default='C8')
    args = ap.parse_args()
    assert re.fullmatch(r'C[0-9]+', args.revision)
    rows = {}
    for path in sorted(ROOT.glob('MC*.cfg')):
        current = parse(path)
        prior = BASELINE/path.name
        row = {'sha256':hashlib.sha256(path.read_bytes()).hexdigest(), 'baseline_exists':prior.exists(), 'current':current}
        assert not current['CONSTRAINT'], path
        if prior.exists():
            old = parse(prior)
            row['parameter_changes'] = difference(old['settings'], current['settings'])
            row['prior_constraints'] = old['CONSTRAINT']
            assert not row['parameter_changes'], (path,row['parameter_changes'])
        else:
            reference = REFERENCES[path.name]
            row['parameter_reference'] = reference
            changes = difference(parse(ROOT/reference)['settings'],current['settings'])
            row['reference_parameter_changes'] = changes
            expected = {'MaxSjLaunchFail':{'reference':'0','new':'1'}} if path.name=='MC_hunt_startup_failure.cfg' else {}
            assert changes == expected, (path,changes)
        rows[path.name] = row
    result = {'purpose':'Parameters and fault bounds only. Oracle classifications remain in the changelog; no normal-operation state constraint is active.', 'baseline':str(BASELINE), 'configs':rows}
    (ROOT/f'output/continuation-{args.revision}-bounds-audit.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'configs':len(rows),'inherited_parameters_unchanged':True,'new_probe_parameters_match_references':True,'only_bound_increase':'startup_failure MaxSjLaunchFail 0 -> 1','no_active_state_constraints':True}))


if __name__ == '__main__':
    main()
