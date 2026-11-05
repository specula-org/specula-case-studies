----------------------------- MODULE Env_WfSJ -----------------------------
\* Environment ASSUMPTION of the WfSJ group (assume-guarantee, DESIGN.md §2.1).
\*   EnvNext    generator form: an abstract communicator (CommSJ) plus the SJ
\*              process facts, explored by the harness
\*   EnvAllowed checker form, discharged as AG_WfSJ (spec/AG.tla) in mixes
\* WfSJ reads (WfSJ_F / WfSJ_C): pCommSJ.round / .standing / .call (site, round,
\* kind, value, rc, metricKind) / .cancelled / .panic / .finalized,
\* pJobSP.sjLaunched, SJAlive, PayRcvShutDone.
\* CTRL/COMM protocol assumed from CommSJ (PortsFed header; wf_comm_server.py):
\*   - round follows a SCHEDULE request (pWfSJ.scheduled), the new task stands;
\*   - an APP_CALL is posted only by a live SJ, for the current round, "live"
\*     only while the task stands, and with no other call pending; it is
\*     cleared only after the matching APP_RETURN (pWfSJ.ret);
\*   - a standing task retires only while no call is pending;
\*   - CANCEL_ALL is acknowledged with the requested round;
\*   - finalize_run happens after the workflow returned, with no call pending.
EXTENDS Ports

Call == pCommSJ.call
CallOK(b, r) ==
    /\ b.round = r /\ b.site \in Sites /\ b.kind \in {"live", "unknown"}
    /\ b.value \in {None, ResultValue(b.site, r)} /\ b.rc \in {"OK", "EXECUTION_EXCEPTION"}
    /\ b.metricKind = "none"
SJReads == [launched |-> pJobSP.sjLaunched, alive |-> SJAlive, down |-> PayRcvShutDone]

\* ---------- generator form (harness)
EnvSJLaunch ==
    /\ ~pJobSP.sjLaunched
    /\ pJobSP' = [pJobSP EXCEPT !.sjLaunched = TRUE]
    /\ UNCHANGED <<pCommSJ, pPayRcv>>
EnvSJKilled ==   \* SP terminate / another SJ group's os._exit (process death not owned by WfSJ)
    /\ SJAlive /\ ~pJobSP.sjKilled
    /\ pJobSP' = [pJobSP EXCEPT !.sjKilled = TRUE]
    /\ UNCHANGED <<pCommSJ, pPayRcv>>
EnvSchedule ==
    /\ SJAlive /\ pWfSJ.scheduled > pCommSJ.round
    /\ pCommSJ' = [pCommSJ EXCEPT !.round = pWfSJ.scheduled, !.standing = TRUE,
                     !.envelopes = [c \in Sites |-> None], !.claimed = {}, !.finished = {}]
    /\ UNCHANGED <<pJobSP, pPayRcv>>
EnvCall(c, kind, value, rc) ==
    /\ SJAlive /\ Call = None /\ pCommSJ.round > 0
    /\ kind = "live" => pCommSJ.standing
    /\ pCommSJ' = [pCommSJ EXCEPT !.call =
          [site |-> c, round |-> pCommSJ.round, kind |-> kind,
           key |-> <<JobId, c, 1, pCommSJ.round, 1>>, assignment |-> Assignment(c, pCommSJ.round),
           value |-> value, rc |-> rc, metricKind |-> "none"]]
    /\ UNCHANGED <<pJobSP, pPayRcv>>
EnvComplete ==
    /\ SJAlive /\ Call /= None /\ pWfSJ.ret = [site |-> Call.site, round |-> Call.round]
    /\ pCommSJ' = [pCommSJ EXCEPT !.call = None,
          !.finished = IF pCommSJ.standing /\ Call.round = pCommSJ.round THEN @ \cup {Call.site} ELSE @]
    /\ UNCHANGED <<pJobSP, pPayRcv>>
EnvRetire ==
    /\ SJAlive /\ pCommSJ.standing /\ Call = None
    /\ pCommSJ' = [pCommSJ EXCEPT !.standing = FALSE]
    /\ UNCHANGED <<pJobSP, pPayRcv>>
EnvCancelAck ==
    /\ SJAlive /\ pWfSJ.cancelAll > pCommSJ.cancelled
    /\ pCommSJ' = [pCommSJ EXCEPT !.cancelled = pWfSJ.cancelAll]
    /\ UNCHANGED <<pJobSP, pPayRcv>>
EnvPanic ==
    /\ "deadClient" \in Faults /\ SJAlive /\ ~pCommSJ.panic /\ ~pCommSJ.finalized
    /\ pCommSJ' = [pCommSJ EXCEPT !.panic = TRUE]
    /\ UNCHANGED <<pJobSP, pPayRcv>>
EnvFinalize ==
    /\ SJAlive /\ pWfSJ.returned /= "none" /\ ~pCommSJ.finalized /\ Call = None
    /\ pCommSJ' = [pCommSJ EXCEPT !.finalized = TRUE, !.standing = FALSE]
    /\ UNCHANGED <<pJobSP, pPayRcv>>
EnvDSDone ==
    /\ SJAlive /\ pWfSJ.dsShutdown /\ ~PayRcvShutDone
    /\ pPayRcv' = RcvAllDown(pPayRcv)
    /\ UNCHANGED <<pJobSP, pCommSJ>>
EnvNext ==
    \/ EnvSJLaunch \/ EnvSJKilled \/ EnvSchedule \/ EnvComplete \/ EnvRetire
    \/ EnvCancelAck \/ EnvPanic \/ EnvFinalize \/ EnvDSDone
    \/ \E c \in Sites, kind \in {"live", "unknown"}, rc \in {"OK", "EXECUTION_EXCEPTION"} :
          \E value \in {None, ResultValue(c, pCommSJ.round)} : EnvCall(c, kind, value, rc)
EnvVars == <<pJobSP, pCommSJ, pPayRcv>>

\* ---------- checker form (discharge)
P == pCommSJ
CommOK ==
    /\ P'.round = P.round \/ (P.round < pWfSJ.scheduled /\ P'.round = pWfSJ.scheduled /\ P'.standing)
    /\ P'.standing = P.standing
       \/ (P'.round /= P.round)
       \/ (P.standing /\ ~P'.standing /\ P.call = None)
    /\ P'.call = P.call
       \/ (P.call = None /\ P'.call /= None /\ SJAlive /\ P.round > 0 /\ CallOK(P'.call, P.round)
           /\ (P'.call.kind = "live" => P.standing))
       \/ (P.call /= None /\ P'.call = None /\ pWfSJ.ret = [site |-> P.call.site, round |-> P.call.round])
    /\ P'.cancelled = P.cancelled \/ (P'.cancelled = pWfSJ.cancelAll /\ pWfSJ.cancelAll > P.cancelled)
    /\ P'.panic = P.panic \/ (~P.panic /\ P'.panic /\ SJAlive /\ ~P.finalized)
    /\ P'.finalized = P.finalized
       \/ (~P.finalized /\ P'.finalized /\ pWfSJ.returned /= "none" /\ P.call = None /\ ~P'.standing)
SJOK ==
    LET r == SJReads  r2 == SJReads' IN
    /\ r2.launched = r.launched \/ (~r.launched /\ r2.launched)
    /\ r2.alive = r.alive \/ (r.alive /\ ~r2.alive) \/ (~r.launched /\ r2.launched)
    /\ r2.down = r.down \/ (~r.down /\ r2.down /\ pWfSJ.dsShutdown /\ r.alive)
EnvAllowed == CommOK /\ SJOK
=============================================================================
