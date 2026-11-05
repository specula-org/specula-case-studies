#!/usr/bin/env python3
"""Build the job component's baseline mixes (checks/mixes/MC_job_*.{tla,cfg})
with the default port invariants plus the job hazard properties (defined
inline until the coordinator moves them into Props.tla).

job_mixes.py            -> writes all mixes, prints their names
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc  # noqa: E402

JOB_FAULTS = ["cjCrash", "abort", "outcomeReportFail", "deployError", "launchError",
              "storeError", "rpcTimeout", "outcomeTimeout", "archiveError", "admissionError",
              "resExpiry"]

HAZ_DEFS = r'''
SJDownSP == pJobSP.sjKilled \/ SJGone
OutcomePrecedenceAndPolicy ==
    pJobSP.terminal = "FINISHED" =>
        /\ SJDownSP
        /\ \A c \in Sites : pJobSP.outcomes[c] \notin {"failed", "aborted"}
ReservationOwnership == \A c \in Sites :
    pJobCP[c].freed > 0 =>
        /\ MsgKey("RESOURCES_OK", CP(c), SP, <<JobId, c>>) \in DOMAIN net
        /\ MsgKey("START_JOB", SP, CP(c), <<JobId, c>>) \in DOMAIN net
        /\ pJobCP[c].freed <= 1
JobCPSeed == JobCP_F!SeedInv
JobSPSeed == JobSP_F!SeedInv
JobCPHunt == JobCP_F!SeedHuntInv
JobSPHunt == JobSP_F!SeedHuntInv
TerminalStatusStable ==
    [][pJobSP.status \in JobTerminalStatuses => pJobSP.status' = pJobSP.status]_pJobSP
AbortBlocksRestart ==
    [][\A c \in Sites : pJobCP[c].killed /= {} => pJobCP[c].launch' = pJobCP[c].launch]_pJobCP
'''
JOB_INVS = ["OutcomePrecedenceAndPolicy", "ReservationOwnership", "JobCPSeed", "JobSPSeed"]
HUNT_INVS = ["JobCPHunt", "JobSPHunt"]
FINE = {"JobSP": "F", "JobCP": "F", "RunCJ": "F"}


def mk(name, grain, faults, inv, prop=(), launch=1, sites=1):
    mkmc.build(name, grain=grain, faults=faults, sites=sites, launch=launch, inv=inv,
               prop=prop, extra_defs=HAZ_DEFS)
    print(name)


def main():
    invs = list(mkmc.PORT_INVS) + JOB_INVS
    props = ["AbortBlocksRestart"]          # TerminalStatusStable is diagnostic (job_mF_diag)
    # 1. all coarse
    mk("job_mC", {}, [], invs, props)
    mk("job_mC_w", {}, [], ["NotJobFinished"])
    # 2. job groups fine, rest coarse
    mk("job_mF", FINE, [], invs, props)
    mk("job_mF_w", FINE, [], ["NotJobFinished"])
    # 3. job groups fine + job hazard faults (MaxLaunch 2 for restart hazards)
    mk("job_mF_flt", FINE, JOB_FAULTS, invs, props, launch=2)
    mk("job_mF_fltL", dict(FINE, Net="L"), JOB_FAULTS + ["netLoss"], invs, props, launch=2)
    mk("job_mF_diag", FINE, JOB_FAULTS, ["NotJobFinished"] and [], ["TerminalStatusStable"], launch=2)
    # seed hunt invariants (MC-2 cleanup handoff, MC-3 abort status, MC-4 resurrection)
    mk("job_mF_hunt", FINE, JOB_FAULTS, invs + HUNT_INVS, props, launch=2)
    mk("job_mF_huntCP", FINE, ["cjCrash", "abort", "launchError", "outcomeReportFail"],
       ["NoFreeWhileChildAlive", "AtMostOneFree", "JobCPHunt", "ReservationOwnership"],
       ["AbortBlocksRestart"], launch=2)
    # S17 / H22 (#5301 known accepted): SJ crash before the RUNNING write
    mk("job_mF_s17", {"JobSP": "F"}, ["sjCrash"], ["JobSPHunt"], [], launch=1)
    mk("job_mF_huntSP", FINE, ["abort", "storeError", "rpcTimeout", "outcomeTimeout"],
       ["JobSPHunt", "OutcomePrecedenceAndPolicy", "FinishedJobAllOk"], [], launch=1)
    mk("job_mC_flt", {}, JOB_FAULTS, invs, props, launch=2)
    # per-group fine with faults (zoom-in helpers)
    for g in FINE:
        mk(f"job_m{g}_flt", {g: "F"}, JOB_FAULTS, invs, props, launch=2)


if __name__ == "__main__":
    main()
