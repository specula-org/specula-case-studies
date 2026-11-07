# Replay a saved TLC counterexample (TTrace) on the current spec: every step must be a GNext
# step of the current model, and the last state must still violate the property.
# Usage: replay_ttrace.py <TTrace.tla in checks/mixes> <MC module it extends> <property> <out module>
import re, sys
from pathlib import Path
D = Path("/home/ubuntu/nvflare-remix-20261103/checks/mixes")
ttrace, mc, prop, out = sys.argv[1:5]
src = (D / ttrace).read_text()
vs = re.findall(r"^    /\\ (\w+) = _TETrace\[1\]\.\1$", src, re.M)
m = re.search(rf"^---- MODULE {mc}_TETrace ----$", src, re.M)
body = src[m.start():]
lit = body[body.index("\ntrace == ") + 10: body.index("\n=============================================================================")].strip()
lit = re.sub(r"\n----\s*$", "", lit).strip()
assert lit.startswith("<<") and lit.endswith(">>")
mod = [f"---- MODULE {out} ----", f"EXTENDS Sequences, Naturals, TLC, {mc}", "CONSTANTS s1", "", "TR == " + lit, "", "VARIABLE rpPos",
       "ReplayInit == rpPos = 1 /\\ " + " /\\ ".join(f"{v} = TR[1].{v}" for v in vs) + " /\\ RInit",
       "ReplayNext == rpPos < Len(TR) /\\ rpPos' = rpPos + 1 /\\ " + " /\\ ".join(f"{v}' = TR[rpPos + 1].{v}" for v in vs) + " /\\ GNext",
       f"ReplayEndsInViolation == ~(rpPos = Len(TR) /\\ ~{prop})", "=" * 77]
(D / f"{out}.tla").write_text("\n".join(mod) + "\n")
cfg = (D / f"{mc}.cfg").read_text()
consts = cfg[cfg.index("CONSTANTS"): cfg.index("INIT")]
(D / f"{out}.cfg").write_text(consts + "  s1 = s1\nINIT ReplayInit\nNEXT ReplayNext\nINVARIANT ReplayEndsInViolation\nCHECK_DEADLOCK TRUE\n")
print(out, len(vs), "vars,", lit.count("[paySrc_c |->"), "states")
