#!/usr/bin/env python3
"""Payload-agent mix runner: mkmc.build with payload diagnostic definitions.

pay_mc.py NAME [--grain G=V,...] [--faults ...] [--sites N] [--inv I1,I2] [--default-invs]
          [--run] [--timeout S] [--workers N] [--sim DEPTH]
Extra definitions available as invariants (they name variant privates, so use
them only when the variant is selected in --grain):
  NoSJFatalDecode   (port)  no SJ os._exit(1) from a failed SUBMIT_UPDATE decode
  MC2Progress       (PaySrc=F) PaySrc_F!PayCompletedProgressHasReceiverSuccess
  SettleOnce        (PaySrc=F) single settlement effects, none after receipt
  PaySrcSafe        (PaySrc=F) PaySrc_F!PaySrcSafety
  PayRcvSafe        (PayRcv=F) PayRcv_F!PayLocalCancellationNotified
  ConfirmedSuccessFF (PaySrc=F, PayRcv=F) source success => receiver truth success
"""
import argparse, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc  # noqa: E402

DEFS = r'''NoSJFatalDecode == \A c \in Sites : ~Flag(pPayRcv[c], "fatal")
MC2Progress == PaySrc_F!PayCompletedProgressHasReceiverSuccess
SettleOnce == PaySrc_F!PaySingleSettlementEffects /\ PaySrc_F!PayNoSettlementEffectsAfterReceipt
PaySrcSafe == PaySrc_F!PaySrcSafety
PayRcvSafe == PayRcv_F!PayLocalCancellationNotified
ConfirmedSuccessFF == \A c \in Sites, l \in Launches, a \in Attempts :
    paySrc_f[c][l][a].status[<<"ref-1", "SJ">>] = "success" => payRcv_f[c][a].consumerResult[<<"ref-1", "SJ">>] = "success"'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name"); ap.add_argument("--grain", default="")
    ap.add_argument("--faults", default=""); ap.add_argument("--sites", type=int, default=1)
    ap.add_argument("--launch", type=int, default=1)
    ap.add_argument("--attempt", type=int, default=1)
    ap.add_argument("--inv", default=""); ap.add_argument("--default-invs", action="store_true")
    ap.add_argument("--constraint")
    ap.add_argument("--run", action="store_true"); ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--workers", type=int, default=16); ap.add_argument("--sim", type=int, default=0)
    a = ap.parse_args()
    grain = dict(x.split("=") for x in a.grain.split(",") if x)
    inv = [i for i in a.inv.split(",") if i]
    if a.default_invs:
        inv = list(mkmc.PORT_INVS) + inv
    out, mod, g = mkmc.build(a.name, grain=grain, faults=[f for f in a.faults.split(",") if f],
                             sites=a.sites, launch=a.launch, attempt=a.attempt, inv=inv, constraint=a.constraint,
                             extra_defs=DEFS)
    print("wrote", out / f"{mod}.tla", g)
    if a.run:
        cmd = [sys.executable, str(ROOT / "scripts" / "run_mc.py"), a.name, "--timeout", str(a.timeout),
               "--workers", str(a.workers)]
        if a.sim:
            cmd += ["--mode", "sim", "--depth", f"{a.sim},1000000"]
        subprocess.run(cmd)


if __name__ == "__main__":
    main()
