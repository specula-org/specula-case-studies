"""Audit current cfg wiring after evidence-backed validation classifications."""
from pathlib import Path
import json
import re
D = Path(__file__).resolve().parent.parent
cfgs = {}
for path in sorted(D.glob('MC_hunt_*.cfg')):
    lines = [s.strip() for s in path.read_text().splitlines()
             if s.strip() and not s.lstrip().startswith('\\*')]
    enabled = []
    for line in lines[lines.index('INVARIANTS') + 1:]:
        if line.startswith(('PROPERTY', 'PROPERTIES')):
            break
        enabled.append(line)
    cfgs[path.name] = enabled
assert all(any(f'MC_hunt_s{n}_' in f for f in cfgs) for n in range(1, 6))
required = {'TypeOK', 'CommittedRoundProvenance', 'CommittedAcceptanceConsistency'}
assert required <= set().union(*(set(v) for v in cfgs.values()))
source = (D / 'base.tla').read_text() + '\n' + (D / 'MC.tla').read_text()
for name in set().union(*(set(v) for v in cfgs.values())):
    assert re.search(r'^' + name + r'\s*==', source, re.M), name
original_affected = ['MC_hunt_s4_cancel_overlap.cfg', 'MC_hunt_s4_filter_retirement.cfg',
                    'MC_hunt_s4_prepare_error.cfg', 'MC_hunt_s5_dead_policy.cfg']
for cfg in original_affected:
    assert 'AbnormalTerminationVisible' not in cfgs[cfg]
    assert {'CallbackRoundIsolation', 'ReceiptAfterDecision', 'CommittedAcceptanceConsistency'} <= set(cfgs[cfg])
(D / 'checks/enabled-invariants.json').write_text(json.dumps(cfgs, indent=2) + '\n')
(D / 'checks/not-applicable-invariants.json').write_text(json.dumps({
    'AbnormalTerminationVisible': {
        'configs': original_affected, 'classification': 'Case A',
        'reason': 'No unified product no-save-after-task-termination contract was established; task and workflow outcomes differ.',
        'evidence': 'output/counterexample-classification.md', 'counts_as_coverage': False
    }}, indent=2) + '\n')
print(f'Audit passed: {len(cfgs)} hunt cfgs, 5 scenarios; unsupported outcome oracle explicitly not applicable.')
