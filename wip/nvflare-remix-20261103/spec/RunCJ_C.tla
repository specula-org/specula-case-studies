------------------------------ MODULE RunCJ_C ------------------------------
\* Group RunCJ, COARSE variant. Process: CJ(c), per launch generation l.
\* Mechanisms: CJ status notifications (STARTED/READY/STOPPED with launch id),
\* client runner init_run, main-loop start, END_RUN -> run_abort_signal, loop
\* exit, run-finally DownloadService shutdown, process exit / crash.
\* Writes: runCJ_c, pRunCJ, net (sender CJ(c)).
\* Anchors: client_app_runner.py:51-101,190-243; client_runner.py:791-821,
\*          1084-1089; worker_process.py:127-198.
\* Coarse merges: connect/command agent/sync (into Initialize), end-run event
\* sequence + ReliableMessage/streamer shutdown (into ShutdownDS), stop_cell
\* and worker teardown (into Exit). Port-visible steps stay separate.
EXTENDS Ports
VARIABLE runCJ_c

\* handled: END_RUN keys consumed by the cell CJ(c) (whichever incarnation is
\* listening receives a cell message once; END_RUN ids carry no launch).
InitValue == [handled |-> [c \in Sites |-> {}],
              ls |-> [c \in Sites |-> [l \in Launches |->
                [startedSent |-> FALSE, readySent |-> FALSE, stoppedSent |-> FALSE]]]]
Init == runCJ_c = InitValue

R(c, l) == runCJ_c.ls[c][l]
StatusMsg(kind, c, l) == Msg(kind, CJ(c), CP(c), <<JobId, c, l>>, l)

\* client_app_runner.py:73-79: notify STARTED before the client runner runs.
SendStarted(c, l) ==
    /\ CJAlive(c, l) /\ pRunCJ[c][l].state = "none" /\ ~R(c, l).startedSent
    /\ net' = Send(net, StatusMsg("STARTED", c, l))
    /\ runCJ_c' = [runCJ_c EXCEPT !.ls[c][l].startedSent = TRUE]
    /\ UNCHANGED pRunCJ

\* client_runner.py:791-796 init_run (the END_RUN handler is registered).
Initialize(c, l) ==
    /\ CJAlive(c, l) /\ pRunCJ[c][l].state = "none"
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].state = "initialized"]
    /\ UNCHANGED <<runCJ_c, net>>

\* client_runner.py:798-800: on_ready -> notify READY unless already aborted.
SendReady(c, l) ==
    /\ CJAlive(c, l) /\ pRunCJ[c][l].state = "initialized"
    /\ ~pRunCJ[c][l].abort /\ ~R(c, l).readySent
    /\ net' = Send(net, StatusMsg("READY", c, l))
    /\ runCJ_c' = [runCJ_c EXCEPT !.ls[c][l].readySent = TRUE]
    /\ UNCHANGED pRunCJ

\* client_runner.py:806 _try_run: main pull loop runs.
BecomeReady(c, l) ==
    /\ CJAlive(c, l) /\ pRunCJ[c][l].state = "initialized" /\ ~pRunCJ[c][l].abort
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].state = "running", ![c][l].ready = TRUE]
    /\ UNCHANGED <<runCJ_c, net>>

\* client_runner.py:1084-1089: END_RUN only triggers run_abort_signal.
RecvEndRun(c, l, k) ==
    /\ InInbox(k, CJ(c), "END_RUN") /\ k \notin runCJ_c.handled[c] /\ CJAlive(c, l)
    /\ pRunCJ[c][l].state \in {"initialized", "running"}
    /\ runCJ_c' = [runCJ_c EXCEPT !.handled[c] = @ \cup {k}]
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].abort = TRUE]
    /\ UNCHANGED net

\* The loop returns once run_abort_signal is set; the in-flight task/submit is
\* interrupted by the same signal (communicator.py:617), so no receipt wait.
Stop(c, l) ==
    /\ CJAlive(c, l) /\ pRunCJ[c][l].abort
    /\ pRunCJ[c][l].state \in {"initialized", "running"}
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].state = "stopping"]
    /\ UNCHANGED <<runCJ_c, net>>

\* client_runner.py:814-821 run finally: END_RUN events, ReliableMessage and
\* streamer shutdown, DownloadService.shutdown (clears this CJ's refs).
ShutdownDS(c, l) ==
    /\ CJAlive(c, l) /\ pRunCJ[c][l].state = "stopping" /\ ~pRunCJ[c][l].dsDown
    /\ TimingOK(Faults, "slowSJTeardown", T1Holds(pWfSJ.dsShutdown, SJGone))   \* timing T1
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].dsDown = TRUE]
    /\ UNCHANGED <<runCJ_c, net>>

\* client_app_runner.py:93-99: STOPPED notification (best effort).
SendStopped(c, l) ==
    /\ CJAlive(c, l) /\ pRunCJ[c][l].dsDown /\ ~R(c, l).stoppedSent
    /\ PaySrcShutDone(c, l)    \* DownloadService.shutdown() returned (call-return handshake)
    /\ net' = Send(net, StatusMsg("STOPPED", c, l))
    /\ runCJ_c' = [runCJ_c EXCEPT !.ls[c][l].stoppedSent = TRUE]
    /\ UNCHANGED pRunCJ

\* client_app_runner.py:100-101; worker_process.py:127-198: stop cell, exit 0.
\* The shutdown call must have returned once (fine: NotifyStopped waits for it);
\* a transaction registered after that return does not hold the exit up
\* (no latch in _register_source_download; RunCJ harness found the stricter
\* guard unsound: fine exits, coarse could not).
Exit(c, l) ==
    /\ CJAlive(c, l) /\ pRunCJ[c][l].dsDown /\ (R(c, l).stoppedSent \/ PaySrcShutDone(c, l))
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].state = "exited", ![c][l].exit = "ok"]
    /\ UNCHANGED <<runCJ_c, net>>

\* Abnormal exit at any point after spawn (incl. before init/READY).
Crash(c, l) ==
    /\ "cjCrash" \in Faults /\ CJAlive(c, l)
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].state = "exited", ![c][l].exit = "crash"]
    /\ UNCHANGED <<runCJ_c, net>>

\* The parent's kill request (pJobCP.killed) lands; no fairness: a kill may
\* never take effect (process_launcher.py:60-93).
DieOfKill(c, l) ==
    /\ l \in pJobCP[c].killed /\ pRunCJ[c][l].exit = "none" /\ CJAlive(c, l)
    /\ pRunCJ' = [pRunCJ EXCEPT ![c][l].state = "exited", ![c][l].exit = "killed"]
    /\ UNCHANGED <<runCJ_c, net>>

Next == \E c \in Sites, l \in Launches :
    \/ SendStarted(c, l) \/ Initialize(c, l) \/ SendReady(c, l) \/ BecomeReady(c, l)
    \/ Stop(c, l) \/ ShutdownDS(c, l) \/ SendStopped(c, l) \/ Exit(c, l) \/ Crash(c, l)
    \/ DieOfKill(c, l)
    \/ \E k \in DOMAIN net : RecvEndRun(c, l, k)
=============================================================================
