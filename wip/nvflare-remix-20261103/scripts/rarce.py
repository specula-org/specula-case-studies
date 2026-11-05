#!/usr/bin/env python3
"""Rarity view of a counterexample from a MixR run (mkmc --rarity K).

rarce.py NAME
Prints the path length, the total cost (final value of `rare`) and every step
that spent budget, i.e. the rare events the behavior relies on.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import ce  # noqa: E402


def main():
    name = sys.argv[1]
    st = ce.states((ROOT / "logs" / f"{name}.log").read_text())
    if not st:
        print("no counterexample"); return
    prev = 0
    spent = []
    for i, (act, vals) in enumerate(st, 1):
        r = int(vals.get("rare", "0"))
        if r > prev:
            spent.append((i, r - prev, act.split("!")[-1]))
        prev = r
    print(f"{name}: {len(st)} states, total cost {prev}")
    for i, d, a in spent:
        print(f"  step {i:>3}  +{d}  {a}")


if __name__ == "__main__":
    main()
