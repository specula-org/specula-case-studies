"""Preserve a completed Specula TLC task under spec/output, without assigning a verdict."""
import json
from pathlib import Path
import shutil
import sys
SPEC = Path(__file__).resolve().parent.parent
TASK = SPEC.parent / '.tlc-tasks/jobs' / sys.argv[1]
LABEL = sys.argv[2]
assert TASK.is_dir()
for name in ('tlc.log', 'launcher.log', 'request.json', 'result.json'):
    source = TASK / name
    if source.exists():
        target = SPEC / 'output' / (LABEL + ('.out' if name == 'tlc.log' else '.' + name))
        shutil.copy2(source, target)
        print(target)
