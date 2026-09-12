#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$HARNESS_DIR" <<'PY'
import hashlib,json,pathlib,subprocess,sys
h=pathlib.Path(sys.argv[1]);m=json.loads((h/'evidence/installed-files.json').read_text());source=pathlib.Path(m['source'])
for name,expected in m['files'].items():
 p=source/name
 if not p.exists() or hashlib.sha256(p.read_bytes()).hexdigest()!=expected:raise SystemExit(f'Preserving changed/missing harness file: {p}')
subprocess.run(['git','-C',str(source),'apply','--reverse','--check',str(h/'patches/instrumentation.patch')],check=True)
subprocess.run(['git','-C',str(source),'apply','--reverse',str(h/'patches/instrumentation.patch')],check=True)
for name in m['files']:(source/name).unlink()
print('Removed only the recorded harness instrumentation.')
PY
