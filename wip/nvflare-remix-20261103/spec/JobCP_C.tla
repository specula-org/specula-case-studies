------------------------------ MODULE JobCP_C ------------------------------
\* Group JobCP, COARSE variant. Process: CP(c).
\* Mechanisms: resource check/reserve/expiry/cancel, deploy, START allocate or
\* reject, CJ spawn / kill / restart (launch generations), child wait, outcome
\* report (once, may fail), free, heartbeat job listing (HEARTBEAT 2/3).
\* Writes: jobCP_c, pJobCP, net (sender CP(c)).
\* Anchors: scheduler_cmds.py:67-160; auto_clean_resource_manager.py:102-172;
\*          training_cmds.py:100-153; client_engine.py:357-404;
\*          client_executor.py:345-444,589-693,722-842; process_launcher.py:72-160.
\* Coarse merges the executor's start pipeline (consume, check, register,
\* snapshot, attach, waiter), the restart re-launch pipeline, the waiter's
\* restart decision, report return and the post-free cleanup. CJ status
\* notifications (STARTED/READY/STOPPED) only matter for the fine variant's
\* exit classification and restart decision, so coarse does not consume them.
EXTENDS Ports
VARIABLE jobCP_c

InitValue == [c \in Sites |-> [handled |-> {}, reserved |-> FALSE, deployed |-> FALSE,
                 st |-> "idle", abortReq |-> FALSE, relaunching |-> FALSE,
                 orphan |-> FALSE, restartFailed |-> FALSE, hb |-> 0]]
Init == jobCP_c = InitValue

P(c) == jobCP_c[c]
Fresh1(c, k, kind) == InInbox(k, CP(c), kind) /\ k \notin P(c).handled
Reply(kind, c, body) == Msg(kind, CP(c), SP, <<JobId, c>>, body)
\* Outcome report bodies reachable from an observed exit (rc classes:
\* ok -> ok; crash -> generic|failed; killed -> aborted|generic; a generic rc
\* is reported "failed" unless abort was requested or the CJ said STOPPED).
OutcomeFor(x) == CASE x = "ok" -> {"ok"}
                   [] x = "crash" -> {"ok", "failed"}
                   [] OTHER -> {"aborted", "ok"}

\* CheckResourceProcessorReserve (one token per site in the slice: the pool
\* unit is free when the CHECK arrives, so Unavailable/"no" is unreachable).
RecvCheck(c, k) ==
    /\ Fresh1(c, k, "CHECK_RESOURCES")
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}, ![c].reserved = TRUE]
    /\ net' = Send(net, Reply("RESOURCES_OK", c, "ok"))
    /\ UNCHANGED pJobCP

\* AutoCleanResourceManager TTL expiry of an unallocated reservation.
Expire(c) ==
    /\ "resExpiry" \in Faults /\ P(c).reserved
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].reserved = FALSE]
    /\ UNCHANGED <<pJobCP, net>>

\* CancelResourceProcessor: cancel never frees an allocation.
RecvCancel(c, k) ==
    /\ Fresh1(c, k, "CANCEL_RESOURCES")
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}, ![c].reserved = FALSE]
    /\ net' = Send(net, Reply("CANCEL_ACK", c, None))
    /\ UNCHANGED pJobCP

\* Deploy command (training_cmds.py:100-153).
RecvDeploy(c, k) ==
    /\ Fresh1(c, k, "DEPLOY_JOB")
    /\ \/ /\ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}, ![c].deployed = TRUE]
          /\ net' = Send(net, Reply("DEPLOY_REPLY", c, "ok"))
       \/ /\ "deployError" \in Faults
          /\ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}]
          /\ net' = Send(net, Reply("DEPLOY_REPLY", c, "no"))
    /\ UNCHANGED pJobCP

\* START_JOB: allocate the reserved token, or reject a missing/expired token.
RecvStart(c, k) ==
    /\ Fresh1(c, k, "START_JOB")
    /\ \/ /\ P(c).reserved
          /\ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}, ![c].reserved = FALSE,
                                        ![c].st = "starting"]
          /\ pJobCP' = [pJobCP EXCEPT ![c].allocated = TRUE]
          /\ UNCHANGED net
       \/ /\ ~P(c).reserved
          /\ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}, ![c].st = "failed"]
          /\ net' = Send(net, Reply("START_REPLY", c, "no"))
          /\ UNCHANGED pJobCP

\* start_app returned an error (app not deployed): StartNo, allocation kept.
ReturnedError(c) ==
    /\ P(c).st = "starting" /\ ~P(c).deployed /\ CurLaunch(c) = 0
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].st = "failed"]
    /\ net' = Send(net, Reply("START_REPLY", c, "no"))
    /\ UNCHANGED pJobCP

\* Initial spawn of launch 1 (ProcessJobLauncher Popen).
Spawn(c) ==
    /\ P(c).st = "starting" /\ P(c).deployed /\ CurLaunch(c) = 0
    \* the job is in the CP's run_processes (heartbeat listing 2) before Popen:
    \* fine JobExecutorRegisterPendingHandle sends HB 2 atomically (X1/X2); a
    \* lazy listing let the SP resolve a running CJ's outcome as missing (bfs3)
    /\ P(c).hb = 2
    /\ pJobCP' = [pJobCP EXCEPT ![c].launch = 1]
    /\ UNCHANGED <<jobCP_c, net>>

\* Prepare/spawn/waiter exception -> StartJobProcessor rollback: free + StartNo.
\* (After a waiter exception the child may still be alive: seed MC-2.)
Rollback(c) ==
    /\ "launchError" \in Faults /\ P(c).st = "starting" /\ pJobCP[c].allocated
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].st = "failed"]
    /\ pJobCP' = [pJobCP EXCEPT ![c].allocated = FALSE, ![c].freed = @ + 1]
    /\ net' = Send(net, Reply("START_REPLY", c, "no"))

\* start_app returned with the waiter installed: StartOK.
StartReplyOk(c) ==
    /\ P(c).st = "starting" /\ CurLaunch(c) >= 1
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].st = "running"]
    /\ net' = Send(net, Reply("START_REPLY", c, "ok"))
    /\ UNCHANGED pJobCP

\* ABORT_JOB / HEARTBEAT_STOP: abort latch (only if the job is registered).
RecvAbort(c, k) ==
    /\ \/ Fresh1(c, k, "ABORT_JOB")
       \/ Fresh1(c, k, "HEARTBEAT_STOP")
    /\ \/ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}, ![c].abortReq = TRUE]
       \/ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}]
    /\ UNCHANGED <<pJobCP, net>>

\* Kill request for the current CJ launch (abort while STARTING/attached/after
\* grace); the CJ dies when RunCJ's DieOfKill lands.
Kill(c) ==
    LET l == CurLaunch(c) IN
    /\ P(c).abortReq /\ l > 0 /\ CJAlive(c, l) /\ l \notin pJobCP[c].killed
    /\ pJobCP' = [pJobCP EXCEPT ![c].killed = @ \cup {l}]
    /\ UNCHANGED <<jobCP_c, net>>

\* Waiter: process.wait() returns for the current launch.
ObserveExit(c) ==
    LET l == CurLaunch(c) IN
    /\ l > 0 /\ pJobCP[c].exitSeen[l] = "none" /\ ~CJAlive(c, l)
    /\ P(c).st \in {"starting", "running"}
    /\ pJobCP' = [pJobCP EXCEPT ![c].exitSeen[l] = CJExitCode(c, l)]
    /\ UNCHANGED <<jobCP_c, net>>

\* Restart claim: abnormal exit, no abort latch, budget left, nothing reported.
RestartClaim(c) ==
    LET l == CurLaunch(c) IN
    /\ l > 0 /\ l < MaxLaunch /\ pJobCP[c].exitSeen[l] = "crash"
    /\ ~P(c).abortReq /\ ~P(c).relaunching /\ pJobCP[c].reported = "none"
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].relaunching = TRUE]
    /\ UNCHANGED <<pJobCP, net>>

\* Re-launch (new launch generation; no re-consume of the resource). After a
\* restart submission exception the backend may still have accepted the job
\* (client_executor.py:780-783: "never submit again" but no handle): orphan.
Relaunch(c) ==
    /\ P(c).relaunching \/ P(c).orphan
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].relaunching = FALSE, ![c].orphan = FALSE]
    /\ pJobCP' = [pJobCP EXCEPT ![c].launch = @ + 1]
    /\ UNCHANGED net

\* Restart submission exception: report failure instead.
RestartFail(c) ==
    /\ "launchError" \in Faults /\ P(c).relaunching
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].relaunching = FALSE, ![c].orphan = TRUE,
                                  ![c].restartFailed = TRUE]
    /\ UNCHANGED <<pJobCP, net>>

\* Terminal outcome report, once, no retry; the report may fail. After a failed
\* restart submission the report is for the observed exit even if the orphan
\* launch was spawned afterwards.
ReportOutcome(c) ==
    \E l \in Launches :
    /\ l = CurLaunch(c) \/ (P(c).restartFailed /\ l < CurLaunch(c))
    /\ pJobCP[c].exitSeen[l] /= "none" /\ ~P(c).relaunching
    /\ pJobCP[c].reported = "none"
    /\ \E st \in OutcomeFor(pJobCP[c].exitSeen[l]) :
          /\ pJobCP' = [pJobCP EXCEPT ![c].reported = st]
          /\ \/ net' = Send(net, Reply("OUTCOME", c, st))
             \/ /\ "outcomeReportFail" \in Faults /\ UNCHANGED net
    /\ UNCHANGED jobCP_c

\* Free after the report returned (reply, timeout or exception).
FreeAllocation(c) ==
    /\ pJobCP[c].reported /= "none" /\ pJobCP[c].allocated
    /\ pJobCP' = [pJobCP EXCEPT ![c].allocated = FALSE, ![c].freed = @ + 1]
    /\ UNCHANGED <<jobCP_c, net>>

\* Heartbeat job listing: the job enters (2) / leaves (3) run_processes.
SendHeartbeat(c, ph) ==
    /\ ph > P(c).hb /\ P(c).st /= "idle"
    \* listed (2) after START; removed (3) after a spawn exception or the free
    /\ ph = 3 => /\ P(c).hb = 2
                 /\ \/ CurLaunch(c) = 0 /\ "launchError" \in Faults
                    \/ /\ pJobCP[c].freed > 0
                       \* run_processes.pop follows the outcome report's return
                       \* (server handled it, or timeout / no report sent)
                       /\ \/ c \in pJobSP.outcomeSeen \/ "rpcTimeout" \in Faults
                          \/ "outcomeReportFail" \in Faults
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].hb = ph]
    /\ net' = Send(net, Msg("HEARTBEAT", CP(c), SP, <<JobId, c, ph>>, ph))
    /\ UNCHANGED pJobCP

Next ==
    \/ \E c \in Sites, k \in DOMAIN net :
        RecvCheck(c, k) \/ RecvCancel(c, k) \/ RecvDeploy(c, k) \/ RecvStart(c, k)
        \/ RecvAbort(c, k)
    \/ \E c \in Sites : Expire(c) \/ ReturnedError(c) \/ Spawn(c) \/ Rollback(c)
        \/ StartReplyOk(c) \/ Kill(c) \/ ObserveExit(c) \/ RestartClaim(c)
        \/ Relaunch(c) \/ RestartFail(c) \/ ReportOutcome(c) \/ FreeAllocation(c)
    \/ \E c \in Sites, ph \in {2, 3} : SendHeartbeat(c, ph)
=============================================================================
