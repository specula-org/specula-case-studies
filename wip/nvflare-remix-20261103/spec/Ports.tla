------------------------------- MODULE Ports -------------------------------
\* Port variables of the multi-grained NVFlare slice. Every group variant
\* EXTENDS this module and may READ every port variable. A group WRITES only
\* its own private variables, its own port variable, and net (appending
\* messages of kinds its group owns). Receiving is private (handled-key sets);
\* the log is append-only except for NET-owned loss marks.
\* Port shapes live in PortsJob / PortsFed / PortsPay (one per component).
EXTENDS PortsJob, PortsFed, PortsPay, PortsTrn, PortsReg, PortsWrk, Timing

FaultNames == JobFaults \cup FedFaults \cup PayFaults \cup TrnFaults \cup RegFaults \cup WrkFaults \cup {"netLoss", "transportFail"}
ASSUME Faults \subseteq FaultNames
Kinds == JobKinds \cup FedKinds \cup PayKinds

\* net        : append-only message log (NET group may mark lost)
\* pJobSP     : SP job runner/scheduler observable state
\* pJobCP     : CP executor/resource-manager observable state (incl. CJ spawn)
\* pRunCJ     : CJ process lifecycle (initialized/ready/stopping/exit)
\* pTaskCJ    : CJ task executor/trainer -> payload source handoff
\* pPaySrc    : CJ DownloadService source observable state
\* pPayRcv    : SJ receiver/materialization observable state
\* pCommSJ    : SJ WFComm/server runner observable state
\* pWfSJ      : SJ controller/workflow + SJ process lifecycle
\* pTrainer   : CJ in-process trainer thread / Client API object
VARIABLES net, pJobSP, pJobCP, pRunCJ, pTaskCJ, pPaySrc, pPayRcv, pCommSJ, pWfSJ, pTrainer, pReg, pWorker
portVars == <<net, pJobSP, pJobCP, pRunCJ, pTaskCJ, pPaySrc, pPayRcv, pCommSJ, pWfSJ, pTrainer, pReg, pWorker>>

\* Inbox view: a not-lost message of a kind addressed to p.
Inbox(p, kind) == {k \in DOMAIN net : net[k].msg.to = p /\ net[k].msg.kind = kind /\ ~net[k].lost}
M(k) == net[k].msg
\* Fast membership test (use under \E k \in DOMAIN net instead of k \in Inbox(..)).
InInbox(k, p, kind) == net[k].msg.to = p /\ net[k].msg.kind = kind /\ ~net[k].lost

PortsInit == /\ net = [k \in {} |-> None]
             /\ pJobSP = JobSPPortInit /\ pJobCP = JobCPPortInit
             /\ pRunCJ = RunCJPortInit /\ pTaskCJ = TaskCJPortInit
             /\ pPaySrc = PaySrcPortInit /\ pPayRcv = PayRcvPortInit
             /\ pCommSJ = CommSJPortInit /\ pWfSJ = WfSJPortInit
             /\ pTrainer = TrainerPortInit
             /\ pReg = RegPortInit
             /\ pWorker = WorkerPortInit

\* OS-level process facts (the only allowed cross-process reads besides net).
\* Any group of a process may kill its process (e.g. os._exit) by setting a
\* boolean field "fatal" in its OWN port record; liveness is the conjunction.
\*   SJ: pPayRcv[c].fatal, pCommSJ.fatal, pWfSJ.fatal (optional fields)
\*   CJ: pTaskCJ[c][l].fatal, pPaySrc[c][l].fatal, pRunCJ[c][l].fatal (optional)
Has(r, f) == f \in DOMAIN r
Flag(r, f) == Has(r, f) /\ r[f] = TRUE
CurLaunch(c) == pJobCP[c].launch
CJFatal(c, l) == Flag(pTaskCJ[c][l], "fatal") \/ Flag(pPaySrc[c][l], "fatal")
                 \/ Flag(pRunCJ[c][l], "fatal") \/ Flag(pTrainer[c][l], "fatal")
\* pJobCP[c].killed is the parent's kill REQUEST (SIGKILL/terminate issued). The
\* child dies only when RunCJ takes its DieOfKill step (no fairness: a kill may
\* never land, e.g. terminate of a non-owned group, process_launcher.py:60-93).
\* A CJ dies with its parent: monitor_parent_process (worker_process.py:124,
\* app/utils.py:45) ends the job process when the CP is gone (cpCrash restart).
CPRestarted(c) == Flag(pJobCP[c], "cpRestarted")
CJAlive(c, l) == /\ l \in Launches /\ CurLaunch(c) >= l
                 /\ pRunCJ[c][l].exit = "none" /\ ~CJFatal(c, l) /\ ~CPRestarted(c)
\* Exit status the parent observes for launch l (meaningful once ~CJAlive).
CJExitCode(c, l) == IF pRunCJ[c][l].exit /= "none" THEN pRunCJ[c][l].exit
                    ELSE IF CJFatal(c, l) \/ (CPRestarted(c) /\ l \in Launches /\ CurLaunch(c) >= l)
                         THEN "crash" ELSE "none"
\* A launched child that is no longer alive: peers may observe it as a
\* transport failure (connection lost / no route), at any later time.
CJGone(c, l) == l \in Launches /\ CurLaunch(c) >= l /\ ~CJAlive(c, l)
\* What a remote peer can actually observe: real death, or a false suspicion
\* (connection drop / slow peer) when "transportFail" is enabled. Use this,
\* not CJGone, for every cross-process reaction.
PeerFailureCJ(c, l) == CJGone(c, l) \/ ("transportFail" \in Faults /\ CJAlive(c, l))
SJFatal == \/ \E c \in Sites : Flag(pPayRcv[c], "fatal")
           \/ Flag(pCommSJ, "fatal") \/ Flag(pWfSJ, "fatal")
\* SP terminates the SJ with SIGKILL after the grace period (server_engine.py
\* terminate, local Process backend): a kill of the SJ lands; the SP's view
\* (pJobSP.sjKilled) and the SJ's liveness must agree (blind sweep artifact fix).
SJKilled == Has(pJobSP, "sjKilled") /\ pJobSP.sjKilled = TRUE
\* The SJ dies with its parent (runner_process.py:126 monitor_parent_process)
\* when the SP crashes (spCrash restart).
SPRestarted == Has(pJobSP, "spRestarted") /\ pJobSP.spRestarted = TRUE
SJAlive == /\ pJobSP.sjLaunched /\ pWfSJ.sj \notin {"exited", "crashed"} /\ ~SJFatal
           /\ ~SJKilled /\ ~SPRestarted
\* SJ exit status as seen by SP: "none" while alive or not launched.
\* "error": the SJ exited normally but reported execution_error. Every SJ panic
\* (CommSJ dead-client policy, workflow exception, strict error mode) is a
\* system_panic -> FATAL_SYSTEM_ERROR, which ServerRunner latches sticky
\* (server_runner.py:253-257); update_job_run_status sends it as
\* execution_error (server_engine.py:874-877) and the SP records it as
\* PROCESS_EXE_ERROR (fed_server.py:595-603) -> FINISHED_EXECUTION_EXCEPTION.
\* (bfs3 lead: without it a panicked run was classified COMPLETED.)
SJPanicked == pCommSJ.panic \/ pWfSJ.panic
SJExitCode == IF ~pJobSP.sjLaunched \/ SJAlive THEN "none"
              ELSE IF SJFatal \/ pWfSJ.sj = "crashed" \/ SJKilled \/ SPRestarted THEN "crashed"
              ELSE IF SJPanicked THEN "error" ELSE "exited"
SJGone == pJobSP.sjLaunched /\ ~SJAlive
PeerFailureSJ == SJGone \/ ("transportFail" \in Faults /\ SJAlive)

\* Call-return handshake of DownloadService.shutdown(): the caller declares the
\* call (pRunCJ.dsDown / pWfSJ.dsShutdown), the payload group applies it on its
\* port (tx.shut / rx.sjDown), and the caller's next step waits for the return
\* (client_runner.py:817 -> client_app_runner.py:93; server_runner.py:235-237).
PaySrcShutDone(c, l) == \A a \in Attempts :
    pPaySrc[c][l].tx[a].registered = None \/ pPaySrc[c][l].tx[a].shut
PayRcvShutDone == \A c \in Sites, a \in Attempts : pPayRcv[c].rx[a].sjDown
=============================================================================
