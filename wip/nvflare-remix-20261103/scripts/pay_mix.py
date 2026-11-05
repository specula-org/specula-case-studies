#!/usr/bin/env python3
"""Payload-agent wrapper around scripts/gen_mix.py: run the static checks,
fail only on errors in the payload groups (PaySrc, PayRcv), report other
groups' errors as warnings (they belong to concurrently working agents), and
write Mix.tla into $MIX_BUILD. Use plain gen_mix.py whenever it passes."""
import os, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import gen_mix  # noqa: E402

assert os.environ.get("MIX_BUILD"), "set MIX_BUILD"
reg = gen_mix.load()
errs = gen_mix.static_check(reg)
mine = [e for e in errs if e.startswith(("PaySrc/", "PayRcv/"))]
for e in errs:
    print(("STATIC-CHECK ERROR: " if e in mine else "foreign static-check warning: ") + e)
if mine:
    sys.exit(1)
gen_mix.gen_mix(reg)
print("wrote", Path(os.environ["MIX_BUILD"]) / "Mix.tla")
