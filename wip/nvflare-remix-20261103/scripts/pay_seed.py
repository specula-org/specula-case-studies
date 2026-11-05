#!/usr/bin/env python3
"""Load the payload seed's structured action declarations (read-only).

Executes inputs/seeds/payload/spec/generate.py in memory with all file writes
stubbed, and records every action() call AFTER the generator's implicit guard
injection. Returns a list of dicts: name, params, source, trigger, guards,
updates, lets, fault, init (the seed Init record text).
"""
import pathlib, re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GEN = ROOT / "inputs" / "seeds" / "payload" / "spec" / "generate.py"


def load():
    src = GEN.read_text()
    hook = "    fields = sorted({k.split('[')[0].split('.')[0] for k,v in updates})"
    assert hook in src
    src = src.replace(hook, "    _REC(name, params, source, trigger, guards, updates, lets, fault)\n" + hook, 1)
    rec = []

    def _rec(name, params, source, trigger, guards, updates, lets, fault):
        rec.append(dict(name=name, params=list(params), source=source, trigger=trigger,
                        guards=list(guards), updates=list(updates), lets=lets, fault=fault))
    orig = pathlib.Path.write_text
    pathlib.Path.write_text = lambda self, *a, **k: None
    try:
        ns = {"__file__": str(GEN), "__name__": "seedgen", "_REC": _rec}
        exec(compile(src, str(GEN), "exec"), ns)
    finally:
        pathlib.Path.write_text = orig
    header = ns["parts"][0]
    m = re.search(r"(Init ==\n.*?)\n\n", header, flags=re.S)
    return rec, m.group(1), ns


if __name__ == "__main__":
    import json, sys
    rec, init, _ = load()
    print(len(rec), "actions")
    json.dump(rec, open(sys.argv[1], "w"), indent=1) if len(sys.argv) > 1 else None
