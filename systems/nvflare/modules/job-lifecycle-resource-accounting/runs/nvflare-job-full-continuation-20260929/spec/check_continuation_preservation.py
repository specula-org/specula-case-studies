#!/usr/bin/env python3
"""Verify immutable supplied evidence and the pinned product worktree."""
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import subprocess

SPEC = Path(__file__).resolve().parent
OUT = SPEC.parent
ROOT = OUT.parents[4]
HANDOFF = ROOT / 'handoff'
SOURCE = ROOT / 'source'
SUPPLIED = HANDOFF / 'full/run/nvflare-job/.specula-output'
PIN = '53ba7ee567468ea7971dad4faccef13c6cb35dc2'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(*args):
    result = subprocess.run(['git', *args], cwd=SOURCE, text=True,
                            capture_output=True, timeout=30)
    return {'exit_code': result.returncode, 'stdout': result.stdout,
            'stderr': result.stderr}


def main():
    assets = json.loads((HANDOFF/'asset-manifest.json').read_text())
    conversations = json.loads((HANDOFF/'conversations/index.json').read_text())
    result = {
        'checked_at_utc': datetime.now(timezone.utc).isoformat(),
        'command': ['python', str(Path(__file__).resolve())],
        'original_assets': {
            'checked': len(assets),
            'mismatches': [a['path'] for a in assets
                           if sha(SUPPLIED/a['path']) != a['sha256']],
        },
        'raw_conversations': {
            'checked': len(conversations),
            'mismatches': [c['raw'] for c in conversations
                           if sha(HANDOFF/c['raw']) != c['sha256']],
        },
        'head': git('rev-parse', 'HEAD'),
        'status': git('status', '--short'),
        'tracked_diff': git('diff', '--exit-code', PIN, '--'),
    }
    result['preservation_passed'] = (
        not result['original_assets']['mismatches']
        and not result['raw_conversations']['mismatches']
        and result['head']['stdout'].strip() == PIN
        and all(result[k]['exit_code'] == 0 for k in ('head', 'status', 'tracked_diff'))
    )
    (SPEC/'output/continuation-final-preservation.json').write_text(
        json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['preservation_passed'] else 1)


if __name__ == '__main__':
    main()
