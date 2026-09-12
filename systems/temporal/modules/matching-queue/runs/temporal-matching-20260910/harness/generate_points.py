#!/usr/bin/env python3
import re
import subprocess
import sys
from pathlib import Path
h = Path(__file__).resolve().parent
s = Path(sys.argv[1]).resolve()
files = subprocess.check_output(["git", "diff", "--name-only"], cwd=s, text=True).splitlines()
rows = []
for name in files:
    if not name.endswith(".go"):
        continue
    for n, line in enumerate((s / name).read_text().splitlines(), 1):
        match = re.search(r'(?:speculaProbe|SpeculaProbe)\((?:ctx, )?"([^"]+)"', line)
        if match:
            rows.append(f"| `{match[1]}` | `{name}:{n}` |")
text = "# Applied source hooks\n\nThese are executed hooks, including scheduling and snapshot-only hooks. The observer maps outcome hooks to the exact action names listed in `post-keys.json`.\n\n| Hook | Applied source location |\n|---|---|\n" + "\n".join(rows) + "\n"
text += "\nExternal observations and frame assembly are in:\n\n"
for file in ["specula_observer_test.go", "specula_scenarios_test.go"]:
    for n, line in enumerate((s / "service/matching" / file).read_text().splitlines(), 1):
        if re.match(r'func .*\b(bootstrap|seal|callerReply|workerReply|historyObserved|retryObserved|expireWork|auditQuiescent|sqlProbe|probe)\(', line):
            text += f"- `service/matching/{file}:{n}`: `{line.strip()}`\n"
(h / "SOURCE_POINTS.md").write_text(text)
