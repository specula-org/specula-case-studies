------------------------------ MODULE JobCP_C ------------------------------
\* Group JobCP, COARSE variant. Process: CP(c).
\* Mechanisms: resource check/reserve/expiry/cancel, deploy, START allocate or
\* reject, CJ spawn / kill / restart (launch generations), child wait, outcome
\* report (once, may fail), free, heartbeat job listing (HEARTBEAT 2/3).
\* Writes: jobCP_c, pJobCP, net (sender CP(c)).
\* Anchors: scheduler_cmds.py:67-160; auto_clean_resource_manager.py:102-172;
\* training_cmds.py:100-153; client_engine.py:357-404;
\* client_executor.py:345-444,589-693,722-842; process_launcher.py:72-160.
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
\* @L JobCP.cmd.check, JobCP.state.reservations
RecvCheck(c, k) ==
    /\ Fresh1(c, k, "CHECK_RESOURCES")
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}, ![c].reserved = TRUE]
    /\ net' = Send(net, Reply("RESOURCES_OK", c, "ok"))
    /\ UNCHANGED pJobCP

\* AutoCleanResourceManager TTL expiry of an unallocated reservation.
\* @L JobCP.res.ttl, JobCP.state.reservations
Expire(c) ==
    /\ "resExpiry" \in Faults /\ P(c).reserved
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].reserved = FALSE]
    /\ UNCHANGED <<pJobCP, net>>

\* CancelResourceProcessor: cancel never frees an allocation.
\* @L JobCP.cmd.cancel
RecvCancel(c, k) ==
    /\ Fresh1(c, k, "CANCEL_RESOURCES")
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}, ![c].reserved = FALSE]
    /\ net' = Send(net, Reply("CANCEL_ACK", c, None))
    /\ UNCHANGED pJobCP

\* Deploy command (training_cmds.py:100-153).
\* @L JobCP.cmd.deploy
RecvDeploy(c, k) ==
    /\ Fresh1(c, k, "DEPLOY_JOB")
    /\ \/ /\ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}, ![c].deployed = TRUE]
          /\ net' = Send(net, Reply("DEPLOY_REPLY", c, "ok"))
       \/ /\ "deployError" \in Faults
          /\ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}]
          /\ net' = Send(net, Reply("DEPLOY_REPLY", c, "no"))
    /\ UNCHANGED pJobCP

\* START_JOB: allocate the reserved token, or reject a missing/expired token.
\* @L JobCP.cmd.start, JobCP.res.gpuEnv
RecvStart(c, k) ==
    /\ Fresh1(c, k, "START_JOB")
    /\ \/ /\ P(c).reserved
          /\ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}, ![c].reserved = FALSE,
                                        ![c].st = "starting"]
          \* allocate + resource consume: the GPU consumer writes the CP-global
          \* CUDA_VISIBLE_DEVICES (gpu_resource_consumer.py:25-33)
          /\ pJobCP' = [pJobCP EXCEPT ![c].allocated = TRUE, ![c].env = 1]
          /\ UNCHANGED net
       \/ /\ ~P(c).reserved
          /\ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}, ![c].st = "failed"]
          /\ net' = Send(net, Reply("START_REPLY", c, "no"))
          /\ UNCHANGED pJobCP

\* start_app returned an error (app not deployed): StartNo, allocation kept.
\* @L JobCP.cmd.start
ReturnedError(c) ==
    /\ P(c).st = "starting" /\ ~P(c).deployed /\ CurLaunch(c) = 0
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].st = "failed"]
    /\ net' = Send(net, Reply("START_REPLY", c, "no"))
    /\ UNCHANGED pJobCP

\* Initial spawn of launch 1 (ProcessJobLauncher Popen).
\* @L JobCP.res.gpuEnv, JobCP.exec.startApp, JobCP.state.runProcesses, JobCP.k8s.launch
Spawn(c) ==
    /\ P(c).st = "starting" /\ P(c).deployed /\ CurLaunch(c) = 0
    \* the job is in the CP's run_processes (heartbeat listing 2) before Popen:
    \* fine JobExecutorRegisterPendingHandle sends HB 2 atomically; a
    \* lazy listing let the SP resolve a running CJ's outcome as missing
    /\ P(c).hb = 2
    \* k8sJob: launch_job registers the job's workspace-transfer record (add_job)
    \* a process CJ inherits the CP's environment at Popen (process_launcher.py:72-160);
    \* a container CJ gets its devices from the allocation
    /\ LET g1 == IF CJContainer THEN 1 ELSE pJobCP[c].env
           p1 == [pJobCP EXCEPT ![c].launch = 1, ![c].gpu[1] = g1,
                                ![c].gpuBy = IF g1 \notin {0, 1} THEN "JobCP.res.gpuEnv" ELSE @]
       IN pJobCP' = IF K8sJob THEN [p1 EXCEPT ![c].ws = 1] ELSE p1
    /\ UNCHANGED <<jobCP_c, net>>

\* Prepare/spawn/waiter exception -> StartJobProcessor rollback: free + StartNo.

\* @L JobCP.exec.startApp
Rollback(c) ==
    /\ "launchError" \in Faults /\ P(c).st = "starting" /\ pJobCP[c].allocated
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].st = "failed"]
    /\ pJobCP' = [pJobCP EXCEPT ![c].allocated = FALSE, ![c].freed = @ + 1, ![c].freedBy = "JobCP.exec.startApp"]
    /\ net' = Send(net, Reply("START_REPLY", c, "no"))

\* start_app returned with the waiter installed: StartOK.
\* @L JobCP.cmd.start
StartReplyOk(c) ==
    /\ P(c).st = "starting" /\ CurLaunch(c) >= 1
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].st = "running"]
    /\ net' = Send(net, Reply("START_REPLY", c, "ok"))
    /\ UNCHANGED pJobCP

\* ABORT_JOB / HEARTBEAT_STOP: abort latch (only if the job is registered).
\* @L JobCP.exec.abort
RecvAbort(c, k) ==
    /\ \/ Fresh1(c, k, "ABORT_JOB")
       \/ Fresh1(c, k, "HEARTBEAT_STOP")
    /\ \/ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}, ![c].abortReq = TRUE]
       \/ jobCP_c' = [jobCP_c EXCEPT ![c].handled = @ \cup {k}]
    /\ UNCHANGED <<pJobCP, net>>

\* Kill request for the current CJ launch (abort while STARTING/attached/after
\* grace); the CJ dies when RunCJ's DieOfKill lands.
\* @L JobCP.exec.abort, JobCP.docker.terminate
Kill(c) ==
    LET l == CurLaunch(c) IN
    /\ P(c).abortReq /\ l > 0 /\ CJAlive(c, l) /\ l \notin pJobCP[c].killed
    /\ pJobCP' = [pJobCP EXCEPT ![c].killed = @ \cup {l}]
    /\ UNCHANGED <<jobCP_c, net>>

\* Waiter: process.wait() returns for the current launch.
\* @L JobCP.exec.waiter
ObserveExit(c) ==
    LET l == CurLaunch(c) IN
    /\ l > 0 /\ pJobCP[c].exitSeen[l] = "none" /\ ~CJAlive(c, l)
    /\ P(c).st \in {"starting", "running"}
    /\ pJobCP' = [pJobCP EXCEPT ![c].exitSeen[l] = CJExitCode(c, l)]
    /\ UNCHANGED <<jobCP_c, net>>

\* Restart claim: abnormal exit, no abort latch, budget left, nothing reported.
\* @L JobCP.exec.waiter
RestartClaim(c) ==
    LET l == CurLaunch(c) IN
    /\ l > 0 /\ l < MaxLaunch /\ pJobCP[c].exitSeen[l] = "crash"
    /\ ~P(c).abortReq /\ ~P(c).relaunching /\ pJobCP[c].reported = "none"
    \* taskMode: can_restart needs the CP task owner of launch l done (JobCP_F)
    /\ IF TaskMode THEN pWorker[c].owner[l] = "done" ELSE TRUE
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].relaunching = TRUE]
    /\ UNCHANGED <<pJobCP, net>>

\* Re-launch (new launch generation; no re-consume of the resource). After a
\* restart submission exception the backend may still have accepted the job
\* (client_executor.py:780-783: "never submit again" but no handle): orphan.
\* @L JobCP.res.gpuEnv, JobCP.exec.relaunch, JobCP.state.runProcesses, JobCP.k8s.launch
Relaunch(c) ==
    /\ P(c).relaunching \/ P(c).orphan
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].relaunching = FALSE, ![c].orphan = FALSE]
    \* the relaunch reuses the allocation but reads the CP's current environment
    /\ LET n == CurLaunch(c) + 1
           gn == IF CJContainer THEN 1 ELSE pJobCP[c].env
           p1 == [pJobCP EXCEPT ![c].launch = n, ![c].gpu[n] = gn,
                                ![c].gpuBy = IF gn \notin {0, 1} THEN "JobCP.res.gpuEnv" ELSE @]
           p2 == IF P(c).orphan THEN [p1 EXCEPT ![c].orphanBy = "JobCP.exec.relaunch"] ELSE p1
       IN pJobCP' = IF K8sJob THEN [p2 EXCEPT ![c].ws = n] ELSE p2
    /\ UNCHANGED net

\* Restart submission exception: report failure instead.
\* @L JobCP.exec.relaunch
RestartFail(c) ==
    /\ "launchError" \in Faults /\ P(c).relaunching
    /\ jobCP_c' = [jobCP_c EXCEPT ![c].relaunching = FALSE, ![c].orphan = TRUE,
                                  ![c].restartFailed = TRUE]
    /\ UNCHANGED <<pJobCP, net>>

\* Terminal outcome report, once, no retry; the report may fail. After a failed
\* restart submission the report is for the observed exit even if the orphan
\* launch was spawned afterwards.
\* @L JobCP.exec.report
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
\* @L JobCP.exec.free
FreeAllocation(c) ==
    /\ pJobCP[c].reported /= "none" /\ pJobCP[c].allocated
    /\ pJobCP' = [pJobCP EXCEPT ![c].allocated = FALSE, ![c].freed = @ + 1, ![c].freedBy = "JobCP.exec.free"]
    /\ UNCHANGED <<jobCP_c, net>>

\* Heartbeat job listing: the job enters (2) / leaves (3) run_processes.
\* @L JobCP.exec.free, JobCP.hb.listing
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

\* CP process crash and restart (fault cpCrash): the new CP keeps nothing but
\* the handled keys; its CJs die with it; the heartbeat drops the job (phase 3).
\* @L JobCP.proc.CP, JobCP.container.lifetime
CPCrashRestart(c) ==
    /\ "cpCrash" \in Faults /\ ~pJobCP[c].cpRestarted
    /\ \E k \in P(c).handled : k[1] = "START_JOB"
    /\ jobCP_c' = [jobCP_c EXCEPT ![c] = [InitValue[c] EXCEPT !.handled = P(c).handled, !.hb = 3]]
    \* the new CP process starts with a fresh environment (env 0)
    \* multiJobCP: J2's process CJ dies with the CP and its allocation is gone too
    /\ LET lost == IF CJContainer /\ \E l \in Launches : CJAlive(c, l) THEN "JobCP.container.lifetime" ELSE pJobCP[c].allocLost IN
       pJobCP' = IF MultiJobCP /\ ~CJContainer /\ pJobCP[c].j2.st = "running"
                 THEN [pJobCP EXCEPT ![c].cpRestarted = TRUE, ![c].allocated = FALSE, ![c].env = 0, ![c].allocLost = lost,
                                     ![c].j2 = [@ EXCEPT !.st = "exited", !.alloc = FALSE]]
                 ELSE [pJobCP EXCEPT ![c].cpRestarted = TRUE, ![c].allocated = FALSE, ![c].env = 0, ![c].allocLost = lost]
    /\ net' = Send(net, Msg("HEARTBEAT", CP(c), SP, <<JobId, c, 3>>, 3))

\* ---------------------------------------------------------------- v11 F (multiJobCP)
\* J2's CP-side lifecycle (its START allocates the unit, its CJ may crash and be
\* restarted under the same allocation, it exits, its allocation is freed).
J2(c) == pJobCP[c].j2
\* J2's START (allocate, consume: writes the CP-global env, spawn) is one step; it
\* runs between our START's consume and our spawn only under startOverlap.
\* @L JobCP.res.gpuEnv, JobCP.j2.lifecycle, Timing.startOverlap
J2Start(c) ==
    /\ MultiJobCP /\ J2(c).st = "none" /\ ~CPRestarted(c)
    /\ TimingOK(Faults, "startOverlap", P(c).st /= "starting" \/ CurLaunch(c) > 0)
    /\ pJobCP' = [pJobCP EXCEPT ![c].env = 2,
                                 ![c].j2 = [st |-> "running", launch |-> 1, alloc |-> TRUE, gpu |-> 2]]
    /\ UNCHANGED <<jobCP_c, net>>
\* @L JobCP.res.gpuEnv, JobCP.j2.lifecycle
J2Restart(c) ==
    /\ MultiJobCP /\ "cjCrash" \in Faults /\ J2(c).st = "running" /\ J2(c).launch < MaxLaunch
    /\ LET gj == IF CJContainer THEN 2 ELSE pJobCP[c].env IN
       pJobCP' = [pJobCP EXCEPT ![c].j2.launch = @ + 1, ![c].j2.gpu = gj,
                                ![c].gpuBy = IF gj \notin {0, 2} THEN "JobCP.res.gpuEnv" ELSE @]
    /\ UNCHANGED <<jobCP_c, net>>
\* @L JobCP.j2.lifecycle
J2Exit(c) ==
    /\ MultiJobCP /\ J2(c).st = "running"
    /\ pJobCP' = [pJobCP EXCEPT ![c].j2.st = "exited"]
    /\ UNCHANGED <<jobCP_c, net>>
\* @L JobCP.j2.lifecycle
J2Free(c) ==
    /\ MultiJobCP /\ J2(c).st = "exited" /\ J2(c).alloc
    /\ pJobCP' = [pJobCP EXCEPT ![c].j2 = [@ EXCEPT !.st = "freed", !.alloc = FALSE]]
    /\ UNCHANGED <<jobCP_c, net>>

\* ---------------------------------------------------------------- v11 E (k8sJob)
\* The CJ publishes its results at shutdown (upload_results_on_shutdown); the CP's
\* handler authorizes against the current record, downloads and extracts, then
\* remove_job(job_id) pops whatever record is current (workspace_cell_transfer.py:
\* 429-487). Normally the requester waits, so the handler ends while launch l is
\* still alive; slowPublish lets it end after a replacement registered.
\* @L JobCP.k8s.publish
PubStart(c, l) ==
    /\ K8sJob /\ l \in Launches /\ pJobCP[c].ws = l /\ pJobCP[c].pub[l] = "none" /\ CJAlive(c, l)
    /\ pJobCP' = [pJobCP EXCEPT ![c].pub[l] = "running"]
    /\ UNCHANGED <<jobCP_c, net>>
\* @L JobCP.k8s.wsRecord, JobCP.k8s.publish
PubDone(c, l) ==
    /\ K8sJob /\ l \in Launches /\ pJobCP[c].pub[l] = "running"
    /\ CJAlive(c, l) \/ "slowPublish" \in Faults
    /\ pJobCP' = [pJobCP EXCEPT ![c].pub[l] = "done", ![c].ws = 0,
                                 ![c].wsRemovedBy = IF pJobCP[c].ws \notin {0, l} THEN "JobCP.k8s.publish" ELSE @]
    /\ UNCHANGED <<jobCP_c, net>>
\* the CJ's publish finds no record (unknown job_id): its results are not returned
\* @L JobCP.k8s.publish
PubMissing(c, l) ==
    /\ K8sJob /\ l \in Launches /\ l = CurLaunch(c) /\ CJAlive(c, l)
    /\ pJobCP[c].pub[l] = "none" /\ pJobCP[c].ws /= l /\ l \notin pJobCP[c].wsLost
    /\ pJobCP' = [pJobCP EXCEPT ![c].wsLost = @ \cup {l}]
    /\ UNCHANGED <<jobCP_c, net>>
\* terminate(): delete_namespaced_pod fails (podDeleteFail), yet the handle sets
\* terminal_state TERMINATED and releases the transfer record, the credential
\* Secret and the task owner while the Pod may still run (k8s_launcher.py:409-437,
\* ); the waiter sees a terminal handle.
\* @L JobCP.k8s.terminate
K8sDeleteFail(c) ==
    LET l == CurLaunch(c) IN
    /\ K8sJob /\ "podDeleteFail" \in Faults /\ P(c).abortReq /\ l > 0 /\ CJAlive(c, l)
    /\ pJobCP[c].exitSeen[l] = "none" /\ P(c).st \in {"starting", "running"}
    /\ pJobCP' = [pJobCP EXCEPT ![c].exitSeen[l] = "killed", ![c].ws = 0, ![c].endBy = "JobCP.k8s.terminate"]
    /\ UNCHANGED <<jobCP_c, net>>

Next ==
    \/ \E c \in Sites, l \in Launches : PubStart(c, l) \/ PubDone(c, l) \/ PubMissing(c, l)
    \/ \E c \in Sites : K8sDeleteFail(c) \/ J2Start(c) \/ J2Restart(c) \/ J2Exit(c) \/ J2Free(c)
    \/ \E c \in Sites, k \in DOMAIN net :
        RecvCheck(c, k) \/ RecvCancel(c, k) \/ RecvDeploy(c, k) \/ RecvStart(c, k)
        \/ RecvAbort(c, k)
    \/ \E c \in Sites : Expire(c) \/ ReturnedError(c) \/ Spawn(c) \/ Rollback(c)
        \/ StartReplyOk(c) \/ Kill(c) \/ ObserveExit(c) \/ RestartClaim(c)
        \/ Relaunch(c) \/ RestartFail(c) \/ ReportOutcome(c) \/ FreeAllocation(c)
        \/ CPCrashRestart(c)
    \/ \E c \in Sites, ph \in {2, 3} : SendHeartbeat(c, ph)
=============================================================================
