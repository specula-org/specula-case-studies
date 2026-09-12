#!/usr/bin/env python3
import hashlib,json,os,pathlib,subprocess
H=pathlib.Path(__file__).resolve().parent
S=pathlib.Path(os.environ.get('TEMPORAL_SOURCE','/home/ubuntu/temporal-investigation-20260909/parallel-20260911/source-nexus'))
manifest=json.loads((H/'applied.json').read_text())
for path,entry in manifest.items():
    p=S/path
    if not p.exists() or hashlib.sha256(p.read_bytes()).hexdigest()!=entry['sha256']:
        raise SystemExit(f'Refusing cleanup: file differs from harness manifest: {p}')
for path in manifest:
    p=S/path
    original=subprocess.run(['git','-C',str(S),'show','0c010ce5fe8c0180aa7573c72fe8fc87c6df7025:'+path],capture_output=True)
    if original.returncode==0:p.write_bytes(original.stdout)
    else:p.unlink()
(H/'applied.json').unlink()
print('Removed only matching harness changes; unrelated files were preserved.')
