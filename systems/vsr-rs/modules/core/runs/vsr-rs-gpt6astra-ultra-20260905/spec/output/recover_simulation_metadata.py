#!/usr/bin/env python3
"""Recover only missing completion metadata; never launch or alter TLC runs."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil

out = Path(__file__).resolve().parent
records = []
for directory in sorted(out.glob('MC_hunt_*_simulation')):
    meta = directory/'run.json'
    record = json.loads(meta.read_text())
    assert 'finished_utc' not in record, directory
    log = (directory/'tlc.out').read_text()
    launch = (directory/'launch.out').read_text()
    assert 'Timed out' in launch and record['timeout_seconds'] == 1800
    assert not re.search(r'^Error:|OutOfMemoryError|unexpected exception|GC overhead', log, re.M|re.I)
    pid = int(re.search(r'\[pid: (\d+)\]', log).group(1))
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError(f'TLC PID {pid} still exists')
    for name, expected in record['sha256'].items():
        assert hashlib.sha256((directory/name).read_bytes()).hexdigest() == expected
    end = datetime.fromtimestamp((directory/'launch.out').stat().st_mtime, timezone.utc)
    elapsed = (end-datetime.fromisoformat(record['started_utc'])).total_seconds()
    assert 1795 <= elapsed < 1860, (directory, elapsed)
    assert not (directory/'run.launch.json').exists()
    shutil.copy2(meta, directory/'run.launch.json')
    record.update(returncode=124, elapsed_seconds=round(elapsed,3),
                  finished_utc=end.isoformat(), errors=[], violation=None,
                  complete_without_error=False, budget_elapsed_without_error=True,
                  progress=[line for line in log.splitlines() if line.startswith('Progress')],
                  footer=log.splitlines()[-15:],
                  interpretation='No violation observed within budget; incomplete exploration',
                  completion_metadata_recovered=True,
                  returncode_source='Inferred from installed wrapper exclusive exit-124 Timed out branch; not collected by the interrupted Python driver',
                  elapsed_seconds_source='launch.out final modification time minus original started_utc; filesystem-derived wall time, not recovered monotonic timing',
                  completion_evidence={'tlc_pid':pid,'pid_observed_exited':True,
                      'timeout_marker':'Timed out','original_launch_record':'run.launch.json',
                      'tlc_log_sha256':hashlib.sha256((directory/'tlc.out').read_bytes()).hexdigest(),
                      'launch_log_sha256':hashlib.sha256((directory/'launch.out').read_bytes()).hexdigest()},
                  recovered_utc=datetime.now(timezone.utc).isoformat())
    meta.write_text(json.dumps(record,indent=2)+'\n')
    records.append({'run':directory.name,'elapsed_seconds':elapsed,'returncode_source':record['returncode_source']})
(out/'simulation-metadata-recovery.json').write_text(json.dumps(records,indent=2)+'\n')
print(json.dumps(records,indent=2))
