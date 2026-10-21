#!/usr/bin/env bash
set -euo pipefail
python3 - "$(dirname "$0")" <<'PY'
from pathlib import Path
import hashlib,json,subprocess,sys
h=Path(sys.argv[1]).resolve(); root=h.parents[1]; source=root/'source'
manifest=json.loads((h/'patches/manifest.json').read_text())
for name,hashes in manifest.items():
    p=source/name
    if hashlib.sha256(p.read_bytes()).hexdigest()!=hashes['after_sha256']: raise SystemExit('Refuse to overwrite an unowned edit: '+name)
for name,hashes in manifest.items():
    p=source/name
    if hashes['before_sha256'] is None: p.unlink()
    else: p.write_bytes(subprocess.check_output(['git','--git-dir='+str(root/'baseline.git'),'show','refs/specula/baseline:'+name]))
PY
