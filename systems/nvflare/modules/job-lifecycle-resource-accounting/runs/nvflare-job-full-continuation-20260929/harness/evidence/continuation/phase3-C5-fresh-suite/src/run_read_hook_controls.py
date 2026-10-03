# Copyright (c) 2026, NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Repeat existing scoped product tests on pristine and patched copies, retaining exact outcomes."""
import json
import os
import re
import subprocess
from pathlib import Path

h = Path(__file__).resolve().parents[1]
source = Path(os.environ['NVF_SOURCE'])
python = os.environ['NVF_PYTHON']
output = h / 'evidence/continuation/phase3-read-hook-unit-tests'
output.mkdir(parents=True, exist_ok=True)
tests = ['private/fed/server/server_engine_test.py']
rows = []
for mode in ('pristine', 'patched-disabled', 'patched-noop'):
    root = source if mode == 'pristine' else h / 'build/nvflare_src'
    env = dict(os.environ, PYTHONPATH=f'{root}:{source}:{h / "src"}', EXPECT_NVFLARE_ROOT=str(root),
               NVF_HOOK_CONTROL='noop' if mode == 'patched-noop' else 'off', PYTHONDONTWRITEBYTECODE='1')
    command = [python, '-m', 'pytest', '-q', '-rA', f'--rootdir={output}', '-c', '/dev/null',
               '--import-mode=importlib', '-p', 'no:cacheprovider', '-p', 'pytest_import_control',
               *[str(source / 'tests/unit_test' / t) for t in tests]]
    log = output / f'{mode}.log'
    with log.open('w') as f:
        completed = subprocess.run(['timeout', '180', *command], env=env, cwd=output, stdout=f,
                                   stderr=subprocess.STDOUT, check=False)
    outcomes = sorted(re.findall(r'^(?:PASSED|FAILED|ERROR|SKIPPED|XFAIL|XPASS) \S[^\n]*', log.read_text(), re.M))
    row = {'mode': mode, 'command': command, 'nvflare_root': str(root), 'exit_code': completed.returncode,
           'log': str(log), 'outcomes': outcomes}
    rows.append(row)
    print(mode, completed.returncode, len(outcomes), flush=True)
    if completed.returncode == 124:
        break  # retain timeout; do not retry a potential deadlock
result = {'runs': rows, 'all_passed': len(rows) == 3 and all(r['exit_code'] == 0 for r in rows),
          'identical_outcomes': len(rows) == 3 and all(r['outcomes'] == rows[0]['outcomes'] for r in rows)}
(output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
raise SystemExit(0 if result['all_passed'] and result['identical_outcomes'] else 1)
