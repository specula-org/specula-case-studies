#!/usr/bin/env python3
"""Split actual kernel records and losslessly compress their timeboxes."""
import hashlib
import json
from pathlib import Path
import sys

log, directory, name, attempt = map(Path, sys.argv[1:])
name = str(name)
raw = directory / 'raw' / attempt.name / name
raw.mkdir(parents=True, exist_ok=False)
streams = {}
config = None
end = None
buffers = []
returns = []
identities = None
command_line = None
clock = None
placement = None
for line in log.read_text(errors='replace').splitlines():
    # QEMU may include carriage returns and a kernel prefix on serial lines.
    if 'SPECULA_EVENT ' in line:
        event = json.loads(line.split('SPECULA_EVENT ', 1)[1])
        assert event['tag'] == 'trace'
        streams.setdefault(event['tid'], []).append(event)
    elif 'SPECULA_CONFIG ' in line:
        config = json.loads(line.split('SPECULA_CONFIG ', 1)[1])
    elif 'SPECULA_BUFFER ' in line:
        buffers.append(json.loads(line.split('SPECULA_BUFFER ', 1)[1]))
    elif 'SPECULA_RETURN ' in line:
        returns.append(json.loads(line.split('SPECULA_RETURN ', 1)[1]))
    elif 'SPECULA_IDENTITIES ' in line:
        identities = json.loads(line.split('SPECULA_IDENTITIES ', 1)[1])
    elif 'SPECULA_CMDLINE ' in line:
        command_line = line.split('SPECULA_CMDLINE ', 1)[1]
    elif 'SPECULA_CLOCK ' in line:
        clock = json.loads(line.split('SPECULA_CLOCK ', 1)[1])
    elif 'SPECULA_PLACEMENT ' in line:
        placement = json.loads(line.split('SPECULA_PLACEMENT ', 1)[1])
    elif 'SPECULA_END ' in line:
        end = json.loads(line.split('SPECULA_END ', 1)[1])
for tid in (1, 2, 3):
    stream = streams.setdefault(tid, [])
    (raw / f'thread-{tid}.ndjson').write_text(''.join(json.dumps(e,separators=(',',':'))+'\n' for e in stream))
manifest = {'case': name, 'config': config, 'completion': end, 'buffers': buffers,
            'observed_syscall_returns': returns, 'identities': identities, 'guest_command_line': command_line, 'clock': clock, 'cpu_placement': placement, 'serial_log': str(log.resolve()),
            'source': '0c60537098f4c2949ad2d382aaf499de72263d76',
            'attempt_inputs': str((attempt/'inputs.json').resolve()),
            'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest()}
(raw / 'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
if not config or not config['instrumented'] or not end:
    raise SystemExit('INCOMPLETE: no complete runtime export; raw evidence retained')
if end['failures'] or len(buffers) != 3 or any(b['dropped'] or b['events'] != len(streams[b['tid']]) for b in buffers):
    raise SystemExit('INCOMPLETE: failed fixture, dropped records, or incomplete buffer export')
events = [e for s in streams.values() for e in s]
if not events:
    raise SystemExit('INCOMPLETE: empty trace')
timestamps = sorted({e[k] for e in events for k in ('start','end')})
for s in streams.values():
    assert all(e['start'] <= e['end'] for e in s)
    assert all(a['end'] <= b['end'] for a,b in zip(s,s[1:])), 'per-thread clock regression'
mapping = {t:i+1 for i,t in enumerate(timestamps)}
(raw/'timestamps.json').write_text(json.dumps(timestamps)+'\n')
for e in events:
    e['start'],e['end'] = mapping[e['start']],mapping[e['end']]
ofds = sorted({e['args']['ofd'] for e in events if e['event']=='SysOpen'})
tokens = sorted({e['args']['q'] for e in events if e['event']=='FlockItemNew'}) or [1]
fds = sorted({e['args'][key] for e in events for key in ('fd','newfd') if key in e['args']})
header = dict(schema=1,source=manifest['source'],inode='fixture-inode',threads=sorted(streams),
              ofds=ofds,fds=list(range(1,max(fds)+1)),tokens=tokens,sharedTable=True,
              concurrent=name not in ('C01','C02','C03','C05'),smp=config['smp'],
              traces={str(t):s for t,s in sorted(streams.items())})
assert not header['concurrent'] or header['smp']>=2
output = directory / f'{name}.ndjson'
# Attempts retain their own artifact even if a later reviewed run replaces the canonical one.
encoded = json.dumps(header,separators=(',',':'))+'\n'
(raw/'preprocessed.ndjson').write_text(encoded)
output.write_text(encoded)
print(f'{name}: {len(events)} events across {len(streams)} per-thread files; {output}')
