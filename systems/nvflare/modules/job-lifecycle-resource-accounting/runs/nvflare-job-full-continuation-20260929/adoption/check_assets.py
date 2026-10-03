#!/usr/bin/env python3
"""Read-only adoption checks; writes results only under adoption/. Does not run scenarios."""
import ast
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

OUT = Path(__file__).resolve().parents[1]
ROOT = OUT.parents[4]
SOURCE = ROOT / "source"
PIN = "53ba7ee567468ea7971dad4faccef13c6cb35dc2"

def run(args, cwd=None):
    r = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    return {"command": args, "cwd": str(cwd or Path.cwd()), "rc": r.returncode,
            "stdout": r.stdout, "stderr": r.stderr}

result = {"kind": "Phase 2 static usability checks (not trace validation or reproduction)",
          "source_head": run(["git", "rev-parse", "HEAD"], SOURCE),
          "source_status": run(["git", "status", "--short"], SOURCE)}
assert result["source_head"]["stdout"].strip() == PIN

patch = OUT / "harness/patches/instrumentation.patch"
paths = re.findall(r"^\+\+\+ b/(.*)$", patch.read_text(), re.M)
with tempfile.TemporaryDirectory(prefix="nvflare-adoption-") as d:
    tmp = Path(d)
    for rel in paths:
        dst = tmp / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SOURCE / rel, dst)
    result["patch_check"] = run(["git", "apply", "--check", str(patch)], tmp)
    assert result["patch_check"]["rc"] == 0
    applied = run(["git", "apply", str(patch)], tmp)
    assert applied["rc"] == 0
    builds = []
    for rel in paths:
        data = (tmp / rel).read_bytes()
        ast.parse(data, filename=rel)
        old = OUT / "harness/build/nvflare_src" / rel
        builds.append({"path": rel, "patched_sha256": hashlib.sha256(data).hexdigest(),
                       "matches_supplied_build": old.exists() and old.read_bytes() == data})
    result["instrumented_files"] = builds
    result["patched_python_ast_parse"] = len(builds)

pyfiles = sorted((OUT / "harness/src").glob("*.py"))
for f in pyfiles:
    ast.parse(f.read_bytes(), filename=str(f))
result["harness_python_ast_parse"] = [str(f.relative_to(OUT)) for f in pyfiles]
result["shell_syntax"] = [run(["bash", "-n", str(f)]) for f in sorted((OUT / "harness").glob("*.sh"))]
assert all(x["rc"] == 0 for x in result["shell_syntax"])

sections = {"CONSTANTS", "INVARIANTS", "INVARIANT", "PROPERTIES", "PROPERTY"}
configs = {}
for f in sorted((OUT / "spec").glob("*.cfg")):
    cfg, mode = {}, None
    for raw in f.read_text().splitlines():
        line = raw.split("\\*")[0].strip()
        if not line:
            continue
        first, *tail = line.split(maxsplit=1)
        if first in sections:
            mode = first
            cfg.setdefault(mode, [])
            if tail:
                cfg[mode].append(tail[0])
        elif first in {"SPECIFICATION", "INIT", "NEXT", "SYMMETRY", "CONSTRAINT", "VIEW", "ALIAS", "CHECK_DEADLOCK"}:
            mode = None
            cfg[first] = tail[0] if tail else ""
        elif mode:
            cfg[mode].append(line)
        else:
            cfg.setdefault("UNPARSED", []).append(line)
    configs[f.name] = cfg
result["configs"] = configs
result["scenarios"] = re.findall(r"^def (\w+)\(root, out\):", (OUT / "harness/src/nvf_scenarios.py").read_text(), re.M)
(OUT / "adoption/static-checks.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps({"patch_check": result["patch_check"]["rc"], "instrumented_files": len(paths),
    "build_matches": sum(x["matches_supplied_build"] for x in builds), "harness_python": len(pyfiles),
    "shell_scripts": len(result["shell_syntax"]), "configs": len(configs),
    "source_head": result["source_head"]["stdout"].strip()}, indent=2))

