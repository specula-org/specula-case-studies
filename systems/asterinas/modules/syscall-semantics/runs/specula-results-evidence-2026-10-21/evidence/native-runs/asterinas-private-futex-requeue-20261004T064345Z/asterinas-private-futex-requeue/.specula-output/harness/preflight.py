import json, os, pathlib, subprocess, sys, time
h=pathlib.Path(sys.argv[1]);parent=os.getpid();ancestors=[]
while parent>1:
    ancestors.append(parent)
    parent=int(pathlib.Path(f'/proc/{parent}/stat').read_text().split(') ')[1].split()[1])
locks=json.loads(subprocess.check_output(['lslocks','--json','-o','PID,MODE,PATH']))['locks']
held=[l for l in locks if l.get('path','').endswith('/parallel-scopes-2026-10-04/heavy.lock') and l['mode']=='WRITE' and l['pid'] in ancestors]
if not held:raise SystemExit('The receiving controller must hold heavy.lock before invoking this phase.')
mem=int(next(l.split()[1] for l in pathlib.Path('/proc/meminfo').read_text().splitlines() if l.startswith('MemAvailable:')))
reusing=sys.argv[2:]==['--reuse-kernel']
assert not sys.argv[2:] or reusing
deadline=time.monotonic()+1200
while not reusing and mem<10*1024*1024:
    print(f'Waiting for 10 GiB MemAvailable: {mem} KiB',flush=True)
    if time.monotonic()>=deadline:raise SystemExit('Memory reserve unavailable within the bounded wait.')
    time.sleep(20)
    mem=int(next(l.split()[1] for l in pathlib.Path('/proc/meminfo').read_text().splitlines() if l.startswith('MemAvailable:')))
(h/('logs/preflight-reuse.json' if reusing else 'logs/preflight.json')).write_text(json.dumps(dict(time=time.time(),ancestors=ancestors,held=held,MemAvailable_KiB=mem,kernel_build=not reusing),indent=2)+'\n')
