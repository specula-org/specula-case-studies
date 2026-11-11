------------------------------ MODULE JobPhase ------------------------------
\* Job progress measured on the ports only, so it means the same in every mix.
\* Used by the phase-gated fault throttle (mkmc --fuse) and to harvest
\* checkpoint states for mid-job BFS (scripts/ckpt.py).
\* 0 submitted 1 dispatched (deploy/start under way) 2 RUNNING
\* 3 a client result accepted (round 1) 4 round 2 scheduled 5 end-run
\* (workflow returned, runner done or SJ DownloadService shut down)
\* 6 terminal status or deleted
\* The levels are checked from the top, so a level is reached once its own
\* condition holds even if a lower one was skipped (for example, the SJ may
\* schedule round 1 before the server writes RUNNING, even before any CJ is
\* launched, so "round 1 scheduled" is not used as a level).
EXTENDS Ports

JobPhase ==
    IF pJobSP.terminal /= "none" \/ pJobSP.deleted THEN 6
    ELSE IF pWfSJ.done \/ pWfSJ.dsShutdown \/ pWfSJ.returned /= "none" THEN 5
    ELSE IF pWfSJ.scheduled >= 2 THEN 4
    ELSE IF pWfSJ.accepted /= {} THEN 3
    ELSE IF pJobSP.status = "RUNNING" THEN 2
    ELSE IF pJobSP.status /= "SUBMITTED" \/ pJobSP.startSent /= {} \/ pJobSP.sjLaunched THEN 1
    ELSE 0

\* phases a fault fuse may be set to (round 2 exists only with two attempts)
FusePhases == {p \in 0..5 : p /= 4 \/ MaxAttempt >= 2}
=============================================================================
