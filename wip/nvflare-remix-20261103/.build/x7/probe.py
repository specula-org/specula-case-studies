#!/usr/bin/env python3
"""Explosion probe (round 7 analysis): copy a hunt6 simulation MC, add a probe invariant
recording per trace the first level where the job is terminal (Fin) and where no model
step is enabled any more (Quiet: only stutter steps remain), then run TLC simulation."""
import re, subprocess, sys, os, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
MIX = ROOT / "checks" / "mixes"
src, tag, secs, workers, depth = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
PD = depth - 100
tla = (MIX / f"MC_{src}.tla").read_text()
cfg = (MIX / f"MC_{src}.cfg").read_text()
mod = f"MC_x7p_{tag}"
probe = f"""
PLv == TLCGet("level")
PFin == Terminal \\/ pJobSP.deleted
PQuiet == ~ENABLED RNext
ProbeInv ==
  /\\ IF PLv = 1 THEN TLCSet(41, 0) /\\ TLCSet(42, 0) /\\ TLCSet(45, 0) ELSE TRUE
  /\\ IF TLCGet(41) = 0 /\\ PFin THEN TLCSet(41, PLv) ELSE TRUE
  /\\ IF TLCGet(42) = 0 /\\ PQuiet THEN TLCSet(42, PLv) ELSE TRUE
  /\\ IF PLv = {PD - 300} THEN TLCSet(44, <<portVars, privVars>>) ELSE TRUE
  /\\ IF PLv = {PD} /\\ TLCGet(45) = 0
       THEN TLCSet(45, 1) /\\ PrintT(<<"PROBE", TLCGet(41), TLCGet(42), PQuiet,
                                      TLCGet(44)[1] = portVars, TLCGet(44) = <<portVars, privVars>>>>)
       ELSE TRUE
"""
tla = re.sub(r"^---- MODULE \S+ ----", f"---- MODULE {mod} ----", tla, flags=re.M)
tla = tla.replace("\n====", probe + "\n====")
cfg = cfg.replace("CHECK_DEADLOCK TRUE", "INVARIANT ProbeInv\nCHECK_DEADLOCK TRUE")
(MIX / f"{mod}.tla").write_text(tla); (MIX / f"{mod}.cfg").write_text(cfg)
env = dict(os.environ, TLC_WORKERS=str(workers), TLC_HEAP="10g")
p = subprocess.Popen([str(ROOT / "scripts/tlc.sh"), "tlc", str(MIX), mod, f"{mod}.cfg", "-simulate", "num=200000",
                      "-depth", str(depth), "-coverage", "1"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                     text=True, env=env, start_new_session=True)
try:
    out, _ = p.communicate(timeout=secs)
except subprocess.TimeoutExpired:
    import signal; os.killpg(p.pid, signal.SIGTERM); out, _ = p.communicate(timeout=60)
(ROOT / ".build/x7" / f"{tag}.log").write_text(out)
print(tag, "done", len(out))
