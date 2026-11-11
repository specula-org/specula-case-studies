------------------------------ MODULE Worker_C ------------------------------
\* Group Worker, COARSE variant (v10, profile taskMode). Same port as Worker_F
\* with no private state: the CJ supervisor's program counter, its fence sets
\* (_launch_identities, _completed_attempts, per-attempt receipts) and the CJ<->CP
\* request/reply channel are removed. Every outcome is constrained only by
\* port-visible evidence (TaskCJ input / abort / signal / receipt, PVC records,
\* Pod states, CP attempt and owner states), so it over-approximates Worker_F
\* on pWorker. CP owner and Pod steps are those of Worker_F without the request
\* that triggers them.
EXTENDS Ports
VARIABLE worker_c

Init == worker_c = 0
InitValue == 0

P(c) == pWorker[c]
Inp(c, l) == pTaskCJ[c][l].input
Ab(c, l) == pTaskCJ[c][l].abort
Sig(c, l) == pTaskCJ[c][l].trainerSignal
Rc(c, l) == pTaskCJ[c][l].receipt
Stop(c, l) == Ab(c, l) \/ Sig(c, l) /= "none"
OwnerSt(c, l) == IF P(c).owner[l] /= "none" THEN P(c).owner[l]
                 ELSE IF pJobCP[c].launch >= l THEN "open" ELSE "none"
CPUp(c) == ~CPRestarted(c)
LaunchOf(w) == w[1]
OwnerAtts(c, l) == {v \in WAttempts : LaunchOf(v) = l}
Unsettled(c, l) == {v \in OwnerAtts(c, l) : P(c).att[v] \in {"created", "deleting"}}
CkptFor(c, a) == P(c).ckpt /= None /\ P(c).ckpt.asg = a
\* A new outcome for the current input of launch l.
NewOut(c, l) == /\ TaskMode /\ CJAlive(c, l) /\ Inp(c, l) /= None
               /\ IF P(c).out[l] = None THEN TRUE ELSE P(c).out[l].gen < Inp(c, l).gen
G(c, l) == Inp(c, l).gen
A(c, l) == Inp(c, l).assignment.attempt
Own(c, l) == <<l, A(c, l)>>
Out(c, l, k, r) == [pWorker EXCEPT ![c].out[l] = [gen |-> G(c, l), kind |-> k, reason |-> r, w |-> None]]
Usable(c, w) == P(c).store[w].completion /\ P(c).store[w].payload /\ P(c).att[w] = "settled"

\* ---------------------------------------------------------------- outcomes
\* A settled, validated result of this assignment (own attempt, or one of an
\* earlier launch); a fresh result also commits the checkpoint manifest.
\* @L Worker.cj.execute
OutResult(c, l) ==
    /\ NewOut(c, l)
    /\ \E w \in WAttempts, r \in {"fresh", "saved", "recovered"} :
         /\ w[2] = A(c, l) /\ LaunchOf(w) <= l /\ Usable(c, w)
         /\ r = "fresh" => w = Own(c, l)
         /\ LET o == [pWorker EXCEPT ![c].out[l] = [gen |-> G(c, l), kind |-> "result", reason |-> r, w |-> w]]
            IN pWorker' = IF r = "fresh"
                          THEN [o EXCEPT ![c].ckpt = [asg |-> A(c, l), w |-> w],
                                         ![c].committed = @ \cup {A(c, l)}]
                          ELSE o
    /\ UNCHANGED <<worker_c, net>>

ErrorReasons == {"notRunning", "missingSaved", "alreadyOwned", "launchErr", "deadline",
                 "workerFail", "incomplete", "unconfirmed"}
ErrorAllowed(c, l, r) ==
    LET w == Own(c, l) IN
    CASE r = "notRunning" -> Stop(c, l) \/ "settleTimeout" \in Faults \/ OwnerSt(c, l) /= "open"
      [] r = "missingSaved" -> \E v \in WAttempts : v[2] = A(c, l) /\ P(c).store[v].completion
                                                    /\ ~P(c).store[v].payload
      [] r = "alreadyOwned" -> P(c).store[w].created /\ ~CkptFor(c, A(c, l))
      [] r = "launchErr" -> P(c).store[w].created
      [] r = "deadline" -> "taskDeadline" \in Faults /\ P(c).store[w].created
      [] r = "workerFail" -> P(c).store[w].failure
      [] r = "incomplete" -> /\ P(c).att[w] = "settled" /\ ~P(c).store[w].completion
                             /\ ~P(c).store[w].failure /\ P(c).pod[w] /= "crashed"
      [] r = "unconfirmed" -> P(c).store[w].created
                              /\ ("settleTimeout" \in Faults \/ OwnerSt(c, l) /= "open")
\* @L Worker.cj.execute
OutError(c, l) ==
    /\ NewOut(c, l)
    /\ \E r \in ErrorReasons : ErrorAllowed(c, l, r) /\ pWorker' = Out(c, l, "error", r)
    /\ UNCHANGED <<worker_c, net>>

\* Staging failure (fault taskStageFail): the attempt directory exists.
\* @L Worker.cj.execute
OutStageError(c, l) ==
    /\ "taskStageFail" \in Faults /\ NewOut(c, l) /\ ~P(c).store[Own(c, l)].created
    /\ pWorker' = [Out(c, l, "error", "stage") EXCEPT ![c].store[Own(c, l)].created = TRUE]
    /\ UNCHANGED <<worker_c, net>>

\* @L Worker.cj.execute
OutAborted(c, l) ==
    /\ NewOut(c, l) /\ Stop(c, l)
    /\ \E r \in {"abort", "commitGuard", "launchErr", "deadline"} : pWorker' = Out(c, l, "aborted", r)
    /\ UNCHANGED <<worker_c, net>>

\* @L Worker.cj.execute
OutInterrupted(c, l) ==
    /\ NewOut(c, l) /\ P(c).pod[Own(c, l)] = "crashed"
    /\ pWorker' = Out(c, l, "interrupted", "crash")
    /\ UNCHANGED <<worker_c, net>>

\* supervisor.py:251: create_attempt for the current assignment.
\* @L Worker.cj.execute
Stage(c, l) ==
    /\ TaskMode /\ CJAlive(c, l) /\ Inp(c, l) /= None /\ ~P(c).store[Own(c, l)].created
    /\ pWorker' = [pWorker EXCEPT ![c].store[Own(c, l)].created = TRUE]
    /\ UNCHANGED <<worker_c, net>>

\* Receipt-gated release of the result the receipt answers.
\* @L Worker.cj.execute
Release(c, l) ==
    /\ TaskMode /\ CJAlive(c, l) /\ Rc(c, l) /= None /\ P(c).out[l] /= None
    /\ P(c).out[l].gen = Rc(c, l).gen /\ P(c).out[l].kind = "result"
    /\ LET w == P(c).out[l].w IN
       /\ P(c).store[w].payload /\ P(c).att[w] = "settled"
       /\ pWorker' = [pWorker EXCEPT ![c].store[w].payload = FALSE]
    /\ UNCHANGED <<worker_c, net>>

\* ---------------------------------------------------------------- CP owner
\* @L Worker.cp.owner
CPCreate(c, w) ==
    /\ TaskMode /\ CPUp(c) /\ P(c).store[w].created /\ OwnerSt(c, LaunchOf(w)) = "open"
    /\ P(c).att[w] = "none" /\ Unsettled(c, LaunchOf(w)) = {}
    /\ pWorker' = [pWorker EXCEPT ![c].att[w] = "created"]
    /\ UNCHANGED <<worker_c, net>>
\* @L Worker.cp.owner
CPCancel(c, w) ==
    /\ TaskMode /\ CPUp(c) /\ P(c).att[w] = "created"
    /\ pWorker' = [pWorker EXCEPT ![c].att[w] = "deleting"]
    /\ UNCHANGED <<worker_c, net>>
\* @L Worker.cp.owner
CPFence(c, w) ==
    /\ TaskMode /\ CPUp(c) /\ P(c).store[w].created /\ P(c).att[w] = "none"
    /\ OwnerSt(c, LaunchOf(w)) = "open"
    /\ pWorker' = [pWorker EXCEPT ![c].att[w] = "settled"]
    /\ UNCHANGED <<worker_c, net>>
CancelAll(c, l, att) == [v \in WAttempts |-> IF LaunchOf(v) = l /\ att[v] = "created" THEN "deleting" ELSE att[v]]
\* @L Worker.cp.owner
CPClose(c, l) ==
    /\ TaskMode /\ CPUp(c) /\ OwnerSt(c, l) = "open" /\ Stop(c, l)
    /\ pWorker' = [pWorker EXCEPT ![c].owner[l] = "closed", ![c].att = CancelAll(c, l, @)]
    /\ UNCHANGED <<worker_c, net>>
\* @L Worker.cp.owner
CPObserveCJGone(c, l) ==
    /\ TaskMode /\ CPUp(c) /\ OwnerSt(c, l) \in {"open", "closed"} /\ CJGone(c, l)
    /\ pWorker' = [pWorker EXCEPT ![c].owner[l] = "released", ![c].att = CancelAll(c, l, @)]
    /\ UNCHANGED <<worker_c, net>>
\* @L Worker.cp.owner
CPKillPod(c, w) ==
    /\ TaskMode /\ CPUp(c) /\ P(c).att[w] = "deleting" /\ PodLive(P(c).pod[w])
    /\ pWorker' = [pWorker EXCEPT ![c].pod[w] = "killed"]
    /\ UNCHANGED <<worker_c, net>>
\* @L Worker.cp.owner
CPSettle(c, w) ==
    /\ TaskMode /\ CPUp(c) /\ P(c).att[w] \in {"created", "deleting"}
    /\ PodExited(P(c).pod[w]) \/ (P(c).pod[w] = "none" /\ P(c).att[w] = "deleting")
    /\ pWorker' = [pWorker EXCEPT ![c].att[w] = "settled"]
    /\ UNCHANGED <<worker_c, net>>
\* @L Worker.cp.owner
CPOwnerDone(c, l) ==
    /\ TaskMode /\ CPUp(c) /\ P(c).owner[l] = "released" /\ Unsettled(c, l) = {}
    /\ pWorker' = [pWorker EXCEPT ![c].owner[l] = "done"]
    /\ UNCHANGED <<worker_c, net>>

\* ---------------------------------------------------------------- worker Pod
\* @L Worker.pod
PodStart(c, w) ==
    /\ TaskMode /\ P(c).att[w] = "created" /\ P(c).pod[w] = "none"
    /\ pWorker' = [pWorker EXCEPT ![c].pod[w] = "running"]
    /\ UNCHANGED <<worker_c, net>>
\* @L Worker.pod
PodSend(c, w) ==
    /\ TaskMode /\ P(c).pod[w] = "running"
    /\ pWorker' = [pWorker EXCEPT ![c].pod[w] = "sent"]
    /\ UNCHANGED <<worker_c, net>>
\* @L Worker.pod
PodComplete(c, w) ==
    /\ TaskMode /\ P(c).pod[w] = "sent"
    /\ pWorker' = [pWorker EXCEPT ![c].pod[w] = "done", ![c].store[w].completion = TRUE,
                                  ![c].store[w].payload = TRUE]
    /\ UNCHANGED <<worker_c, net>>
\* @L Worker.pod
PodFail(c, w) ==
    /\ "workerFail" \in Faults /\ TaskMode /\ PodLive(P(c).pod[w])
    /\ pWorker' = [pWorker EXCEPT ![c].pod[w] = "failed", ![c].store[w].failure = TRUE]
    /\ UNCHANGED <<worker_c, net>>
\* @L Worker.pod
PodCrash(c, w) ==
    /\ "workerCrash" \in Faults /\ TaskMode /\ PodLive(P(c).pod[w])
    /\ pWorker' = [pWorker EXCEPT ![c].pod[w] = "crashed"]
    /\ UNCHANGED <<worker_c, net>>

Next ==
    \/ \E c \in Sites, l \in Launches :
         \/ OutResult(c, l) \/ OutError(c, l) \/ OutStageError(c, l) \/ OutAborted(c, l)
         \/ OutInterrupted(c, l) \/ Stage(c, l) \/ Release(c, l)
         \/ CPClose(c, l) \/ CPObserveCJGone(c, l) \/ CPOwnerDone(c, l)
    \/ \E c \in Sites, w \in WAttempts :
         \/ CPCreate(c, w) \/ CPCancel(c, w) \/ CPFence(c, w) \/ CPKillPod(c, w) \/ CPSettle(c, w)
         \/ PodStart(c, w) \/ PodSend(c, w) \/ PodComplete(c, w) \/ PodFail(c, w) \/ PodCrash(c, w)
=============================================================================
