------------------------------ MODULE RunCJ_F ------------------------------
\* Group RunCJ, FINE variant. Process: CJ(c), per launch generation l.
\* The job seed has no CJ runner (only the spontaneous ClientChildExit, E2,
\* and CP-side status oracles, E4); this variant follows the source at the pin:
\*   worker_process.py:127-198 main -> ClientAppRunner.start_run
\*   client_app_runner.py:51-101: create runner, connect, command agent,
\*     sync_up_parents, notify STARTED, client_runner.run(on_ready), notify
\*     STOPPED, stop_cell
\*   client_runner.py:791-821 run: init_run, on_ready (READY unless aborted),
\*     _try_run, finally end_run_events_sequence, ReliableMessage/streamer
\*     shutdown, DownloadService.shutdown
\*   client_runner.py:1084-1089 _handle_end_run: run_abort_signal.trigger
\*   client_app_runner.py:190-243 notify_job_status: best effort with retry
\*     (a lost notification is a Net loss).
\* Not modelled: init_run returning False (server job already ended),
\* TaskExecutionInterrupted skipping STOPPED (task-worker profile only).
\* Writes: runCJ_f, pRunCJ, net (sender CJ(c)).
EXTENDS Ports
VARIABLE runCJ_f

\* handled: END_RUN keys consumed by the cell CJ(c) (one incarnation, once);
\* sent: status notifications this launch has sent.
InitValue == [handled |-> [c \in Sites |-> {}],
              ls |-> [c \in Sites |-> [l \in Launches |->
                [pc |-> "spawned", sent |-> {}]]]]
Init == runCJ_f = InitValue

F(c, l) == runCJ_f.ls[c][l]
At(c, l, p) == CJAlive(c, l) /\ F(c, l).pc = p
Go(c, l, p) == runCJ_f' = [runCJ_f EXCEPT !.ls[c][l].pc = p]
GoSent(c, l, p, kind) == runCJ_f' = [runCJ_f EXCEPT !.ls[c][l].pc = p,
                                                    !.ls[c][l].sent = @ \cup {kind}]
StatusMsg(kind, c, l) == Msg(kind, CJ(c), CP(c), <<JobId, c, l>>, l)

\* ---- abstraction to RunCJ_C (own private state only)
AbsC == [handled |-> runCJ_f.handled,
         ls |-> [c \in Sites |-> [l \in Launches |->
           [startedSent |-> "STARTED" \in F(c, l).sent, readySent |-> "READY" \in F(c, l).sent,
            stoppedSent |-> "STOPPED" \in F(c, l).sent]]]]
AbsCInit == [handled |-> [c \in Sites |-> {}],
             ls |-> [c \in Sites |-> [l \in Launches |->
               [startedSent |-> FALSE, readySent |-> FALSE, stoppedSent |-> FALSE]]]]

\* client_app_runner.py:51-65: create client runner, connect to the server,
\* start the command agent, sync up with the parent CP.
Connect(c, l) ==
    /\ At(c, l, "spawned")
    /\ Go(c, l, "connected")
    /\ UNCHANGED <<pRunCJ, net>>

\* client_app_runner.py:67-80: notify STARTED (with CJ_LAUNCH_ID).
NotifyStarted(c, l) ==
    /\ At(c, l, "connected")
    /\ net' = Send(net, StatusMsg("STARTED", c, l))
    /\ GoSent(c, l, "started", "STARTED")
    /\ UNCHANGED pRunCJ

\* client_runner.py:791-796: init_run (END_RUN aux handler now reachable).
InitRun(c, l) ==
    /\ At(c, l, "started")
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].state = "initialized"]
    /\ Go(c, l, "initialized")
    /\ UNCHANGED net

\* client_runner.py:798-805: on_ready notifies READY unless run_abort_signal
\* is already triggered (notification failure is only logged).
NotifyReady(c, l) ==
    /\ At(c, l, "initialized")
    /\ IF pRunCJ[c][l].abort
       THEN /\ UNCHANGED net
            /\ Go(c, l, "readyDone")
       ELSE /\ net' = Send(net, StatusMsg("READY", c, l))
            /\ GoSent(c, l, "readyDone", "READY")
    /\ UNCHANGED pRunCJ

\* client_runner.py:806 _try_run: the main pull loop starts; with the abort
\* signal already set it returns at once (no task pulled).
TryRun(c, l) ==
    /\ At(c, l, "readyDone")
    /\ IF pRunCJ[c][l].abort
       THEN /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].state = "stopping"]
            /\ Go(c, l, "finally")
       ELSE /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].state = "running", ![c][l].ready = TRUE]
            /\ Go(c, l, "loop")
    /\ UNCHANGED net

\* client_runner.py:1084-1089: END_RUN aux request triggers run_abort_signal.
ReceiveEndRun(c, l, k) ==
    /\ InInbox(k, CJ(c), "END_RUN") /\ k \notin runCJ_f.handled[c] /\ CJAlive(c, l)
    /\ F(c, l).pc \in {"initialized", "readyDone", "loop"}
    /\ runCJ_f' = [runCJ_f EXCEPT !.handled[c] = @ \cup {k}]
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].abort = TRUE]
    /\ UNCHANGED net

\* client_runner.py:585-654 loop exit on run_abort_signal; an in-flight task or
\* submit_update is interrupted by the same signal (communicator.py:617).
LeaveLoop(c, l) ==
    /\ At(c, l, "loop") /\ pRunCJ[c][l].abort
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].state = "stopping"]
    /\ Go(c, l, "finally")
    /\ UNCHANGED net

\* client_runner.py:814-816: end_run_events_sequence, ReliableMessage and
\* streamer shutdown.
EndRunEvents(c, l) ==
    /\ At(c, l, "finally")
    /\ Go(c, l, "events")
    /\ UNCHANGED <<pRunCJ, net>>

\* client_runner.py:817: DownloadService.shutdown() clears this CJ's refs (call
\* side; PaySrc applies it per transaction, the next step waits for the return).
ShutdownDownloadService(c, l) ==
    /\ At(c, l, "events")
    /\ "slowSJTeardown" \in Faults \/ CJTeardownTimingOK(pWfSJ, SJGone)   \* timing T1 (PortsJob)
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].dsDown = TRUE]
    /\ Go(c, l, "dsDown")
    /\ UNCHANGED net

\* client_app_runner.py:93-99: notify STOPPED.
NotifyStopped(c, l) ==
    /\ At(c, l, "dsDown")
    /\ PaySrcShutDone(c, l)    \* DownloadService.shutdown() returned (call-return handshake)
    /\ net' = Send(net, StatusMsg("STOPPED", c, l))
    /\ GoSent(c, l, "stoppedSent", "STOPPED")
    /\ UNCHANGED pRunCJ

\* client_app_runner.py:100-101: stop_cell.
StopCell(c, l) ==
    /\ At(c, l, "stoppedSent")
    /\ Go(c, l, "cellStopped")
    /\ UNCHANGED <<pRunCJ, net>>

\* worker_process.py:133-198: close/stop runner, sys.exit(0).
ExitProcess(c, l) ==
    /\ At(c, l, "cellStopped")
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].state = "exited", ![c][l].exit = "ok"]
    /\ Go(c, l, "exited")
    /\ UNCHANGED net

\* Abnormal process exit at any point after spawn (cjCrash).
Crash(c, l) ==
    /\ "cjCrash" \in Faults /\ CJAlive(c, l)
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].state = "exited", ![c][l].exit = "crash"]
    /\ Go(c, l, "exited")
    /\ UNCHANGED net

\* process_launcher.py:60-93: the CP's terminate/kill lands (SIGTERM/SIGKILL);
\* no fairness, the kill may never take effect.
DieOfKill(c, l) ==
    /\ l \in pJobCP[c].killed /\ pRunCJ[c][l].exit = "none" /\ CJAlive(c, l)
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].state = "exited", ![c][l].exit = "killed"]
    /\ Go(c, l, "exited")
    /\ UNCHANGED net

Next == \E c \in Sites, l \in Launches :
    \/ Connect(c, l) \/ NotifyStarted(c, l) \/ InitRun(c, l) \/ NotifyReady(c, l)
    \/ TryRun(c, l) \/ LeaveLoop(c, l) \/ EndRunEvents(c, l)
    \/ ShutdownDownloadService(c, l) \/ NotifyStopped(c, l) \/ StopCell(c, l)
    \/ ExitProcess(c, l) \/ Crash(c, l) \/ DieOfKill(c, l)
    \/ \E k \in DOMAIN net : ReceiveEndRun(c, l, k)
=============================================================================
