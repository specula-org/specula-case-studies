#!/usr/bin/env python3
"""Prepare an explicitly separate observer-only oracle check, using base predicates."""
from pathlib import Path
import shutil
p=Path(__file__).resolve().parent
out=p/'oracle';out.mkdir(exist_ok=True)
for name in ['base.tla','Trace.tla']:
    target=out/name
    if not target.exists():target.symlink_to(Path('../../spec')/name)
shutil.copyfile(p/'src/OracleTrace.tla',out/'OracleTrace.tla')
cfg=(p.parent/'spec/Trace.cfg').read_text().replace('SPECIFICATION TraceSpec','SPECIFICATION OracleSpec')
start=cfg.index('INVARIANTS')
cfg=cfg[:start]+'''INVARIANTS
    AppliedAgreement
    ReplicationEvidence
    AckPreservation
    ReadBasis
    ReadApplication
    ReadCorrelation
PROPERTIES TraceMatched
CHECK_DEADLOCK FALSE
'''
(out/'OracleTrace.cfg').write_text(cfg)
