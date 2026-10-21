#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$harness_dir" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
h=Path(sys.argv[1]); source=h.parent.parent/'source'
receipt=h/'evidence/applied.json'
data=json.loads(receipt.read_text())
for name,expected in data['files'].items():
    p=source/name
    if not p.exists() or hashlib.sha256(p.read_bytes()).hexdigest()!=expected:
        raise SystemExit(f'Refusing cleanup because {name} changed since apply')
for name in data['files']:
    baseline=subprocess.run(['git','-C',str(source),'show',f"{data['pin']}:{name}"],capture_output=True)
    if baseline.returncode==0: (source/name).write_bytes(baseline.stdout)
    else: (source/name).unlink()
receipt.rename(h/'evidence/last-cleaned.json')
PY
