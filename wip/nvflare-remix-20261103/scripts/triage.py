#!/usr/bin/env python3
"""Group sweep violations into distinct leads.

triage.py TAG [--tail N]
For every violating run in checks/sweeps/TAG.jsonl, take the property and the
last N actions of its counterexample (group/variant/action, site-insensitive)
as a signature; print one line per signature with the runs, fault profiles and
mixes that produced it, plus the shortest CE length. The output feeds manual
classification: (a) model/framework artifact, (b) coarse artifact (zoom-in),
(c) known issue (Phase 1 / seed / upstream), (d) new candidate.
"""
import collections, json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import ce  # noqa: E402


def main():
    tag = sys.argv[1]
    tail = int(sys.argv[sys.argv.index("--tail") + 1]) if "--tail" in sys.argv else 4
    rows = [json.loads(l) for l in (ROOT / "checks" / "sweeps" / f"{tag}.jsonl").read_text().splitlines()]
    leads = collections.defaultdict(list)
    for r in rows:
        if not str(r.get("result", "")).startswith("violation"):
            continue
        log = ROOT / "logs" / f"{r['name']}.log"
        if not log.exists():
            continue
        st = ce.states(log.read_text())
        acts = [re.sub(r"^\w+!Step_", "", a).split("(")[0] for a, _ in st[1:]]
        sig = (r.get("violated"), tuple(acts[-tail:]))
        leads[sig].append((r["name"], r.get("profile"), len(st)))
    out = []
    for (prop, last), runs in sorted(leads.items(), key=lambda kv: (kv[0][0], -len(kv[1]))):
        shortest = min(runs, key=lambda x: x[2])
        out.append(f"{prop:24s} x{len(runs):<3d} shortest={shortest[2]:<4d} {shortest[0]}\n"
                   f"    tail: {' -> '.join(last)}\n"
                   f"    profiles: {sorted(set(p for _, p, _ in runs))}")
    text = "\n".join(out)
    print(text)
    (ROOT / "checks" / "sweeps" / f"{tag}.leads.txt").write_text(text + "\n")


if __name__ == "__main__":
    main()
