------------------------------ MODULE Worker_F ------------------------------
\* Group Worker, FINE variant (v10, profile taskMode). Kubernetes task-lifetime
\* execution of one site, pin c411a201 (port shape and roles: PortsWrk).
\*   CJ side, per launch l (task_worker_executor.py:205-328, supervisor.py:207-489):
\*     execute() order: ending/not started -> abort -> _completed_attempts
\*     (resend in the same launch: read_saved_result) -> recover_checkpoint_result
\*     (a committed manifest for this server assignment: adopt its saved result)
\*     -> supervisor.run: _launch_identities fence, staging, launch, _wait,
\*     settlement, read_result / failure / TaskExecutionInterrupted, then
\*     commit_checkpoint under _checkpoint_commit_guard; AFTER_SEND_TASK_RESULT
\*     -> _record_receipt -> record_receipt -> cleanup_job_payloads (release).
\*     ABOUT_TO_END_RUN / END_RUN: _ending, supervisor.end_run, launcher close.
\*   CP side (k8s_task_service.py:76-313): per-launch _Job owner; launch admits
\*     at most one unsettled attempt and is idempotent per identity; cancel of an
\*     unknown identity installs a settled fence unless admission is closed;
\*     close cancels known attempts; CJ terminal -> release; the owner thread
\*     exits once released and every attempt settled (can_restart gate).
\*   Pods (worker.py:238-343): run, hand the result off, publish completion
\*     (or failure.json), exit; deletion by CP kills a live Pod.
\* The CJ<->CP channel is private here: requests and replies are sets; a lost
\* launch reply is the fault ctrlLoss.
\* Not modeled: L5 (deadline from the worker's monotonic clock, a value bug,
\* notes/task-worker-audit.md); payload readers; checkpoint I/O errors.
EXTENDS Ports
VARIABLE worker_f

AttInit == [owned |-> FALSE, settled |-> FALSE, validated |-> FALSE, receipt |-> FALSE, failed |-> FALSE]
SupInit == [pc |-> "idle", gen |-> 0, a |-> 0, w |-> None, cause |-> "none",
            launched |-> {}, completed |-> {}, att |-> [w \in WAttempts |-> AttInit],
            stopping |-> FALSE, fenced |-> FALSE, last |-> None, rcpt |-> 0]
InitValue == IF ~TaskMode THEN 0 ELSE
             [c \in Sites |-> [sup |-> [l \in Launches |-> SupInit], req |-> {}, rep |-> {}]]
Init == worker_f = InitValue
AbsC == 0
AbsCInit == 0

S(c, l) == worker_f[c].sup[l]
P(c) == pWorker[c]
Inp(c, l) == pTaskCJ[c][l].input
Ab(c, l) == pTaskCJ[c][l].abort
Sig(c, l) == pTaskCJ[c][l].trainerSignal
Rc(c, l) == pTaskCJ[c][l].receipt
UpdS(c, l, r) == worker_f' = [worker_f EXCEPT ![c].sup[l] = r]
Out(c, l, g, k, r) == [pWorker EXCEPT ![c].out[l] = [gen |-> g, kind |-> k, reason |-> r, w |-> None]]
OutRes(c, l, g, r, w) == [pWorker EXCEPT ![c].out[l] = [gen |-> g, kind |-> "result", reason |-> r, w |-> w]]
SavedOf(c, l, a) == IF \E p \in S(c, l).completed : p[1] = a
                    THEN (CHOOSE p \in S(c, l).completed : p[1] = a)[2] ELSE None
\* k8s_launcher.py:1183-1209: the owner exists before CJ launch l starts.
OwnerSt(c, l) == IF P(c).owner[l] /= "none" THEN P(c).owner[l]
                 ELSE IF pJobCP[c].launch >= l THEN "open" ELSE "none"
CPUp(c) == ~CPRestarted(c)
LaunchOf(w) == w[1]

\* ---------------------------------------------------------------- CJ: execute()
\* AFTER_SEND_TASK_RESULT runs before the next fetch: a terminal receipt of the
\* last result is recorded before the next assignment is taken.
PendingReceipt(c, l) == /\ Rc(c, l) /= None /\ S(c, l).last /= None
                        /\ Rc(c, l).gen = S(c, l).last.gen /\ S(c, l).rcpt < Rc(c, l).gen
NewInput(c, l) == /\ TaskMode /\ CJAlive(c, l) /\ S(c, l).pc = "idle"
                  /\ Inp(c, l) /= None /\ Inp(c, l).gen > S(c, l).gen /\ ~PendingReceipt(c, l)
Asg(c, l) == Inp(c, l).assignment.attempt
CkptFor(c, a) == P(c).ckpt /= None /\ P(c).ckpt.asg = a
\* No saved/recovered result and no earlier ownership: supervisor.run stages.
StageCase(c, l) ==
    LET a == Asg(c, l) IN
    /\ ~S(c, l).stopping /\ ~S(c, l).fenced /\ ~Ab(c, l)
    /\ SavedOf(c, l, a) = None /\ ~CkptFor(c, a) /\ a \notin S(c, l).launched

\* task_worker_executor.py:211-244: the non-launching outcomes of execute().
SupTake(c, l) ==
    /\ NewInput(c, l) /\ ~StageCase(c, l)
    /\ LET g == Inp(c, l).gen
           a == Asg(c, l)
           sv == SavedOf(c, l, a)
           ck == P(c).ckpt
           s0 == [S(c, l) EXCEPT !.gen = g]
       IN CASE S(c, l).stopping \/ S(c, l).fenced ->
                 UpdS(c, l, s0) /\ pWorker' = Out(c, l, g, "error", "notRunning")
            [] Ab(c, l) ->
                 UpdS(c, l, s0) /\ pWorker' = Out(c, l, g, "aborted", "abort")
            [] sv /= None ->
                 IF P(c).store[sv].payload
                 THEN /\ UpdS(c, l, [s0 EXCEPT !.last = [gen |-> g, w |-> sv]])
                      /\ pWorker' = OutRes(c, l, g, "saved", sv)
                 ELSE UpdS(c, l, s0) /\ pWorker' = Out(c, l, g, "error", "missingSaved")
            [] CkptFor(c, a) ->
                 IF P(c).store[ck.w].payload
                 THEN /\ UpdS(c, l, [s0 EXCEPT !.completed = @ \cup {<<a, ck.w>>},
                                       !.att[ck.w] = [AttInit EXCEPT !.owned = TRUE, !.settled = TRUE,
                                                                     !.validated = TRUE],
                                       !.last = [gen |-> g, w |-> ck.w]])
                      /\ pWorker' = OutRes(c, l, g, "recovered", ck.w)
                 ELSE UpdS(c, l, s0) /\ pWorker' = Out(c, l, g, "error", "missingSaved")
            [] OTHER ->
                 \* a \in launched: "task attempt identity was already owned"
                 UpdS(c, l, s0) /\ pWorker' = Out(c, l, g, "error", "alreadyOwned")
    /\ UNCHANGED net

\* supervisor.py:235-257: fence the identity, create the attempt, stage input
\* and bootstrap.
SupStage(c, l) ==
    /\ NewInput(c, l) /\ StageCase(c, l)
    /\ LET a == Asg(c, l)
           w == <<l, a>>
       IN /\ UpdS(c, l, [S(c, l) EXCEPT !.gen = Inp(c, l).gen, !.pc = "staged", !.a = a, !.w = w,
                            !.cause = "none", !.launched = @ \cup {a},
                            !.att[w] = [AttInit EXCEPT !.owned = TRUE]])
          /\ pWorker' = [pWorker EXCEPT ![c].store[w].created = TRUE]
    /\ UNCHANGED net

\* Fault taskStageFail: staging raises after the identity was fenced.
SupStageFail(c, l) ==
    /\ "taskStageFail" \in Faults /\ NewInput(c, l) /\ StageCase(c, l)
    /\ LET a == Asg(c, l)
           w == <<l, a>>
           g == Inp(c, l).gen
       IN /\ UpdS(c, l, [S(c, l) EXCEPT !.gen = g, !.launched = @ \cup {a},
                            !.att[w] = [AttInit EXCEPT !.owned = TRUE, !.failed = TRUE]])
          /\ pWorker' = [Out(c, l, g, "error", "stage") EXCEPT ![c].store[w].created = TRUE]
    /\ UNCHANGED net

\* supervisor.py:258-262: abort check, then launch_task (CJ -> CP "launch").
SupLaunch(c, l) ==
    /\ TaskMode /\ CJAlive(c, l) /\ S(c, l).pc = "staged"
    /\ IF Ab(c, l) \/ S(c, l).stopping
       THEN /\ UpdS(c, l, [S(c, l) EXCEPT !.pc = "idle", !.att[S(c, l).w].failed = TRUE])
            /\ pWorker' = Out(c, l, S(c, l).gen, "aborted", "abort")
       ELSE /\ worker_f' = [worker_f EXCEPT ![c].sup[l].pc = "launching",
                              ![c].req = @ \cup {[l |-> l, w |-> S(c, l).w, op |-> "launch"]}]
            /\ UNCHANGED pWorker
    /\ UNCHANGED net

Reply(c, l, st) == [l |-> l, w |-> S(c, l).w, st |-> st]
\* k8s_task_service.py:341-371: the launch reply.
SupLaunchReply(c, l) ==
    /\ TaskMode /\ CJAlive(c, l) /\ S(c, l).pc = "launching"
    /\ \E st \in {"accepted", "rejected"} :
         /\ Reply(c, l, st) \in worker_f[c].rep
         /\ IF st = "accepted"
            THEN worker_f' = [worker_f EXCEPT ![c].sup[l].pc = "waiting",
                                ![c].rep = @ \ {Reply(c, l, st)}]
            \* rejected: TaskLauncherError inside call -> TaskLaunchError(handle);
            \* supervisor.run cancels the handle (supervisor.py:323-329)
            ELSE worker_f' = [worker_f EXCEPT ![c].sup[l].pc = "cancel", ![c].sup[l].cause = "launchErr",
                                ![c].rep = @ \ {Reply(c, l, st)},
                                ![c].req = @ \cup {[l |-> l, w |-> S(c, l).w, op |-> "cancel"]}]
    /\ UNCHANGED <<pWorker, net>>

\* Fault ctrlLoss: the launch reply is lost or times out; the request may still
\* reach CP. TaskLaunchError(handle) -> cancel (k8s_task_service.py:368-370).
SupLaunchLost(c, l) ==
    /\ "ctrlLoss" \in Faults /\ TaskMode /\ CJAlive(c, l) /\ S(c, l).pc = "launching"
    /\ worker_f' = [worker_f EXCEPT ![c].sup[l].pc = "cancel", ![c].sup[l].cause = "launchErr",
                      ![c].req = @ \cup {[l |-> l, w |-> S(c, l).w, op |-> "cancel"]}]
    /\ UNCHANGED <<pWorker, net>>

\* supervisor.py:342-361: abort / stopping / deadline -> _cancel.
SupCancel(c, l) ==
    /\ TaskMode /\ CJAlive(c, l) /\ S(c, l).pc = "waiting"
    /\ Ab(c, l) \/ S(c, l).stopping \/ "taskDeadline" \in Faults
    /\ worker_f' = [worker_f EXCEPT ![c].sup[l].pc = "cancel",
                      ![c].sup[l].cause = IF Ab(c, l) \/ S(c, l).stopping THEN "abort" ELSE "deadline",
                      ![c].req = @ \cup {[l |-> l, w |-> S(c, l).w, op |-> "cancel"]}]
    /\ UNCHANGED <<pWorker, net>>

\* supervisor.py:274-322: settlement confirmed; then _aborted, read_result,
\* failure.json, TaskExecutionInterrupted (retryable exit, no cancel request).
SupSettled(c, l) ==
    /\ TaskMode /\ CJAlive(c, l) /\ S(c, l).pc \in {"waiting", "cancel"}
    /\ Reply(c, l, "settled") \in worker_f[c].rep
    /\ LET s == S(c, l)
           w == s.w
           g == s.gen
           st == P(c).store[w]
           s1 == [s EXCEPT !.att[w].settled = TRUE]
           sf == [s1 EXCEPT !.pc = "idle", !.att[w].failed = TRUE]
           rep == worker_f[c].rep \ {Reply(c, l, "settled")}
       IN CASE s.pc = "cancel" \/ Ab(c, l) \/ s.stopping ->
                 /\ worker_f' = [worker_f EXCEPT ![c].sup[l] = sf, ![c].rep = rep]
                 \* an abort seen only after settlement (supervisor.py:284-286) has no
                 \* cancel cause: reason "abort" (TV abort_before_commit)
                 /\ pWorker' = Out(c, l, g, IF s.cause \in {"deadline", "launchErr"} /\ ~Ab(c, l) /\ ~s.stopping
                                            THEN "error" ELSE "aborted",
                                     IF s.cause = "none" THEN "abort" ELSE s.cause)
            [] st.completion ->
                 /\ worker_f' = [worker_f EXCEPT ![c].sup[l] = [s1 EXCEPT !.pc = "validated",
                                                                  !.att[w].validated = TRUE],
                                                 ![c].rep = rep]
                 /\ UNCHANGED pWorker
            [] st.failure ->
                 /\ worker_f' = [worker_f EXCEPT ![c].sup[l] = sf, ![c].rep = rep]
                 /\ pWorker' = Out(c, l, g, "error", "workerFail")
            [] P(c).pod[w] = "crashed" ->
                 /\ worker_f' = [worker_f EXCEPT ![c].sup[l] = sf, ![c].rep = rep]
                 /\ pWorker' = Out(c, l, g, "interrupted", "crash")
            [] OTHER ->
                 /\ worker_f' = [worker_f EXCEPT ![c].sup[l] = sf, ![c].rep = rep]
                 /\ pWorker' = Out(c, l, g, "error", "incomplete")
    /\ UNCHANGED net

\* Fault settleTimeout: wait_for_settlement / cancel exceeds its bound:
\* _fence, settlement_unconfirmed, system_panic (supervisor.py:155-178).
\* A cancel of an identity CP never admitted, sent after admission closed, gets
\* INVALID_REQUEST: no fence, no settled status; the bounded wait then expires
\* deterministically (k8s_task_service.py:288-292, 419-434).
Stuck(c, l) == /\ S(c, l).pc = "cancel" /\ P(c).att[S(c, l).w] = "none" /\ OwnerSt(c, l) /= "open"
               /\ ~\E r \in worker_f[c].req : r.w = S(c, l).w
SupSettleTimeout(c, l) ==
    /\ TaskMode /\ CJAlive(c, l) /\ S(c, l).pc \in {"waiting", "cancel"}
    /\ "settleTimeout" \in Faults \/ Stuck(c, l)
    /\ UpdS(c, l, [S(c, l) EXCEPT !.pc = "fenced", !.fenced = TRUE, !.att[S(c, l).w].failed = TRUE])
    /\ pWorker' = Out(c, l, S(c, l).gen, "error", "unconfirmed")
    /\ UNCHANGED net

\* task_worker_executor.py:300-312, artifacts.py:676-731: the checkpoint
\* manifest replacement is the local commit point (guarded by abort/ending).
SupCommit(c, l) ==
    /\ TaskMode /\ CJAlive(c, l) /\ S(c, l).pc = "validated"
    /\ LET s == S(c, l) IN
       IF Ab(c, l) \/ s.stopping
       THEN /\ UpdS(c, l, [s EXCEPT !.pc = "idle", !.att[s.w].failed = TRUE])
            /\ pWorker' = Out(c, l, s.gen, "aborted", "commitGuard")
       ELSE /\ UpdS(c, l, [s EXCEPT !.pc = "idle", !.completed = @ \cup {<<s.a, s.w>>},
                             !.last = [gen |-> s.gen, w |-> s.w]])
            /\ pWorker' = [OutRes(c, l, s.gen, "fresh", s.w) EXCEPT
                             ![c].ckpt = [asg |-> s.a, w |-> s.w], ![c].committed = @ \cup {s.a}]
    /\ UNCHANGED net

\* task_worker_executor.py:367-377 + supervisor.py:380-397,453-489: a terminal
\* receipt for the result of task gen releases its payload (settled, validated,
\* not failed).
SupReceipt(c, l) ==
    /\ TaskMode /\ CJAlive(c, l) /\ Rc(c, l) /= None /\ S(c, l).last /= None
    /\ Rc(c, l).gen = S(c, l).last.gen /\ S(c, l).rcpt < Rc(c, l).gen
    /\ LET s == S(c, l)
           w == s.last.w
           ok == s.att[w].validated /\ s.att[w].settled /\ ~s.att[w].failed
       IN /\ UpdS(c, l, [s EXCEPT !.rcpt = Rc(c, l).gen, !.att[w].receipt = s.att[w].validated])
          /\ pWorker' = IF ok THEN [pWorker EXCEPT ![c].store[w].payload = FALSE] ELSE pWorker
    /\ UNCHANGED net

\* task_worker_executor.py:110-126: ABOUT_TO_END_RUN -> _ending, supervisor.end_run
\* (stopping, cancel_active); END_RUN -> launcher close (CP job.close()).
SupEndRun(c, l) ==
    /\ TaskMode /\ CJAlive(c, l) /\ ~S(c, l).stopping
    /\ Ab(c, l) \/ Sig(c, l) /= "none"
    /\ LET s == S(c, l)
           cancel == s.pc = "waiting"
       IN worker_f' = [worker_f EXCEPT ![c].sup[l] = [s EXCEPT !.stopping = TRUE,
                                           !.pc = IF cancel THEN "cancel" ELSE @,
                                           !.cause = IF cancel THEN "abort" ELSE @],
                         ![c].req = @ \cup {[l |-> l, w |-> None, op |-> "close"]}
                                     \cup (IF cancel THEN {[l |-> l, w |-> s.w, op |-> "cancel"]} ELSE {})]
    /\ UNCHANGED <<pWorker, net>>

\* A reply for an attempt this launch no longer waits on (late launch reply,
\* repeated settlement) is discarded.
SupDropReply(c, r) ==
    /\ TaskMode /\ r \in worker_f[c].rep
    /\ ~(S(c, r.l).w = r.w /\ S(c, r.l).pc \in {"launching", "waiting", "cancel"})
    /\ worker_f' = [worker_f EXCEPT ![c].rep = @ \ {r}]
    /\ UNCHANGED <<pWorker, net>>

\* ---------------------------------------------------------------- CP: _Job owner
OwnerAtts(c, l) == {v \in WAttempts : LaunchOf(v) = l}
Unsettled(c, l) == {v \in OwnerAtts(c, l) : P(c).att[v] \in {"created", "deleting"}}
\* k8s_task_service.py:247-287 (launch): idempotent per identity; one unsettled
\* attempt per owner; closed / unknown owner -> INVALID_REQUEST / UNAUTHENTICATED.
CPLaunch(c, r) ==
    /\ TaskMode /\ CPUp(c) /\ r \in worker_f[c].req /\ r.op = "launch"
    /\ LET ok == /\ OwnerSt(c, r.l) = "open" /\ P(c).att[r.w] = "none" /\ Unsettled(c, r.l) = {}
           known == P(c).att[r.w] /= "none" /\ OwnerSt(c, r.l) \in {"open", "closed", "released"}
       IN /\ worker_f' = [worker_f EXCEPT ![c].req = @ \ {r},
                            ![c].rep = @ \cup {[l |-> r.l, w |-> r.w,
                                                 st |-> IF ok \/ known THEN "accepted" ELSE "rejected"]}]
          /\ pWorker' = IF ok THEN [pWorker EXCEPT ![c].att[r.w] = "created"] ELSE pWorker
    /\ UNCHANGED net

\* k8s_task_service.py:288-307 (cancel): known attempt -> cancel latch; unknown
\* identity -> settled fence while admission is open, rejected once closed.
CPCancel(c, r) ==
    /\ TaskMode /\ CPUp(c) /\ r \in worker_f[c].req /\ r.op = "cancel"
    /\ LET a == P(c).att[r.w]
           fence == a = "none" /\ OwnerSt(c, r.l) = "open"
       IN /\ worker_f' = [worker_f EXCEPT ![c].req = @ \ {r},
                            ![c].rep = IF fence \/ a = "settled"
                                       THEN @ \cup {[l |-> r.l, w |-> r.w, st |-> "settled"]} ELSE @]
          /\ pWorker' = CASE a = "created" -> [pWorker EXCEPT ![c].att[r.w] = "deleting"]
                          [] fence -> [pWorker EXCEPT ![c].att[r.w] = "settled"]
                          [] OTHER -> pWorker
    /\ UNCHANGED net

CancelAll(c, l, att) == [v \in WAttempts |-> IF LaunchOf(v) = l /\ att[v] = "created" THEN "deleting" ELSE att[v]]
\* k8s_task_service.py:98-103,244-246 (close).
CPClose(c, r) ==
    /\ TaskMode /\ CPUp(c) /\ r \in worker_f[c].req /\ r.op = "close"
    /\ worker_f' = [worker_f EXCEPT ![c].req = @ \ {r}]
    /\ pWorker' = IF OwnerSt(c, r.l) = "open"
                  THEN [pWorker EXCEPT ![c].owner[r.l] = "closed", ![c].att = CancelAll(c, r.l, @)]
                  ELSE pWorker
    /\ UNCHANGED net

\* k8s_launcher.py:381-383,452-475 (_record_terminal_state -> task_owner.release)
\* and k8s_task_service.py:111-133 (observe_cj): CJ launch l is terminal.
CPObserveCJGone(c, l) ==
    /\ TaskMode /\ CPUp(c) /\ OwnerSt(c, l) \in {"open", "closed"} /\ CJGone(c, l)
    /\ pWorker' = [pWorker EXCEPT ![c].owner[l] = "released", ![c].att = CancelAll(c, l, @)]
    /\ UNCHANGED <<worker_f, net>>

\* k8s_launcher.py:568-666: a cancelled Pod is deleted (UID precondition).
CPKillPod(c, w) ==
    /\ TaskMode /\ CPUp(c) /\ P(c).att[w] = "deleting" /\ PodLive(P(c).pod[w])
    /\ pWorker' = [pWorker EXCEPT ![c].pod[w] = "killed"]
    /\ UNCHANGED <<worker_f, net>>

\* Confirmed shutdown + finalizer removal + 404 (k8s_launcher.py:651-674), or
\* deletion of a never-started Pod; the status reaches CJ on its next poll.
CPSettle(c, w) ==
    /\ TaskMode /\ CPUp(c) /\ P(c).att[w] \in {"created", "deleting"}
    /\ PodExited(P(c).pod[w]) \/ (P(c).pod[w] = "none" /\ P(c).att[w] = "deleting")
    /\ pWorker' = [pWorker EXCEPT ![c].att[w] = "settled"]
    /\ worker_f' = [worker_f EXCEPT ![c].rep = @ \cup {[l |-> LaunchOf(w), w |-> w, st |-> "settled"]}]
    /\ UNCHANGED net

\* k8s_task_service.py:178-182: released and every attempt settled -> on_done,
\* the owner thread exits (k8s_launcher.py:733 can_restart reads it).
CPOwnerDone(c, l) ==
    /\ TaskMode /\ CPUp(c) /\ P(c).owner[l] = "released" /\ Unsettled(c, l) = {}
    /\ pWorker' = [pWorker EXCEPT ![c].owner[l] = "done"]
    /\ UNCHANGED <<worker_f, net>>

\* ---------------------------------------------------------------- worker Pod
PodStart(c, w) ==
    /\ TaskMode /\ P(c).att[w] = "created" /\ P(c).pod[w] = "none"
    /\ pWorker' = [pWorker EXCEPT ![c].pod[w] = "running"]
    /\ UNCHANGED <<worker_f, net>>
\* flare.send(): the result is staged (script_result_sent marker).
PodSend(c, w) ==
    /\ TaskMode /\ P(c).pod[w] = "running"
    /\ pWorker' = [pWorker EXCEPT ![c].pod[w] = "sent"]
    /\ UNCHANGED <<worker_f, net>>
\* worker.py:307-319: finalize, seal checkpoint, publish completion.json; exit 0.
PodComplete(c, w) ==
    /\ TaskMode /\ P(c).pod[w] = "sent"
    /\ pWorker' = [pWorker EXCEPT ![c].pod[w] = "done", ![c].store[w].completion = TRUE,
                                  ![c].store[w].payload = TRUE]
    /\ UNCHANGED <<worker_f, net>>
\* worker.py:320-333 (fault workerFail): failure.json, exit 1.
PodFail(c, w) ==
    /\ "workerFail" \in Faults /\ TaskMode /\ PodLive(P(c).pod[w])
    /\ pWorker' = [pWorker EXCEPT ![c].pod[w] = "failed", ![c].store[w].failure = TRUE]
    /\ UNCHANGED <<worker_f, net>>
\* Fault workerCrash: nonzero exit without records.
PodCrash(c, w) ==
    /\ "workerCrash" \in Faults /\ TaskMode /\ PodLive(P(c).pod[w])
    /\ pWorker' = [pWorker EXCEPT ![c].pod[w] = "crashed"]
    /\ UNCHANGED <<worker_f, net>>

Next ==
    \/ \E c \in Sites, l \in Launches :
         \/ SupTake(c, l) \/ SupStage(c, l) \/ SupStageFail(c, l) \/ SupLaunch(c, l)
         \/ SupLaunchReply(c, l) \/ SupLaunchLost(c, l) \/ SupCancel(c, l) \/ SupSettled(c, l)
         \/ SupSettleTimeout(c, l) \/ SupCommit(c, l) \/ SupReceipt(c, l) \/ SupEndRun(c, l)
         \/ CPObserveCJGone(c, l) \/ CPOwnerDone(c, l)
    \/ \E c \in Sites, w \in WAttempts :
         \/ CPKillPod(c, w) \/ CPSettle(c, w) \/ PodStart(c, w) \/ PodSend(c, w)
         \/ PodComplete(c, w) \/ PodFail(c, w) \/ PodCrash(c, w)
    \/ \E c \in Sites :
         \E r \in (IF TaskMode THEN worker_f[c].req ELSE {}) :
            CPLaunch(c, r) \/ CPCancel(c, r) \/ CPClose(c, r)
    \/ \E c \in Sites :
         \E r \in (IF TaskMode THEN worker_f[c].rep ELSE {}) : SupDropReply(c, r)
=============================================================================
