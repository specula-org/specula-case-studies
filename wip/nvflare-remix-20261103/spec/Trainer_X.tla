------------------------------ MODULE Trainer_X ------------------------------
\* Group Trainer, EXTERNAL variant (v8): an external trainer process (launch_once,
\* one process serves the CJ's tasks) and the CJ's ExternalProcessBackend
\* acceptance / accepted-result-source monitor, pin c411a201.
\*   cell_backend.py:195-267 (RESULT_READY accepted under _task_lock: the result
\*   becomes the session's live source for the task, a monitor thread starts);
\*   external_process_backend.py:1239-1330 (_monitor_accepted_result_source,
\*   _fail_accepted_result_source, _stop_trainer); client/cell/api.py
\*   (RESULT_SOURCE_SETTLED after the receivers finished: source no longer live).
\* Same port as Trainer_F (pTrainer); the trainer script loop is Trainer_F's.
\* Faults: tpSilent (the trainer's heartbeats stop for longer than
\*   heartbeat_timeout, and may resume); monitorStale (the monitor thread is
\*   preempted between its identity check and its stop decision: microsecond
\*   window, priced as a timing escape).
EXTENDS Ports
VARIABLE trainer_x

\* tp: "none" | "running" | "stopped"; src: the session's accepted result source
\* (task generation, live until settled); mon: monitor threads [g, pc, silent]
\* with pc "check" | "decide"; silent: the peer is silent beyond the timeout;
\* notices: generations whose source failure was notified to the receivers;
\* victim: the live source's generation when the trainer was stopped (0: none)
Rec == [pc |-> "idle", consumed |-> 0, receiveCalled |-> FALSE, abort |-> FALSE, stop |-> FALSE,
        tp |-> "none", src |-> [g |-> 0, live |-> FALSE], mon |-> {}, silent |-> FALSE,
        notices |-> {}, victim |-> 0, stops |-> 0]
Init == trainer_x = [c \in Sites |-> [l \in Launches |-> Rec]]
InitValue == [c \in Sites |-> [l \in Launches |-> Rec]]
AbsC == 0
AbsCInit == 0

T(c, l) == trainer_x[c][l]
P(c, l) == pTrainer[c][l]
Input(c, l) == IF Has(pTaskCJ[c][l], "input") THEN pTaskCJ[c][l].input ELSE None
Signal(c, l) == IF Has(pTaskCJ[c][l], "trainerSignal") THEN pTaskCJ[c][l].trainerSignal ELSE "none"
Continue(c, l) == ~T(c, l).abort /\ ~T(c, l).stop
Up(c, l) == CJAlive(c, l) /\ T(c, l).tp = "running"
Upd(c, l, r) == [trainer_x EXCEPT ![c][l] = r]

\* the backend launches the trainer process once for the CJ
Start(c, l) ==
    /\ T(c, l).pc = "idle" /\ T(c, l).tp = "none" /\ CJAlive(c, l) /\ pRunCJ[c][l].ready
    /\ trainer_x' = Upd(c, l, [T(c, l) EXCEPT !.pc = "waiting", !.tp = "running"])
    /\ UNCHANGED pTrainer

\* the task reaches the trainer (backend execute -> TASK to the session)
Callback(c, l) ==
    /\ Up(c, l) /\ Input(c, l) /= None /\ Input(c, l).gen > P(c, l).received
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].slot = Input(c, l).gen, ![c][l].received = Input(c, l).gen]
    /\ UNCHANGED trainer_x

SignalCallback(c, l) ==
    /\ Up(c, l) /\ Signal(c, l) /= "none"
    /\ IF Signal(c, l) = "abort" THEN ~T(c, l).abort ELSE ~T(c, l).stop
    /\ trainer_x' = Upd(c, l, [T(c, l) EXCEPT !.abort = (@ \/ Signal(c, l) = "abort"),
                                              !.stop = (@ \/ Signal(c, l) = "stop")])
    /\ UNCHANGED pTrainer

Receive(c, l) ==
    /\ T(c, l).pc = "waiting" /\ Up(c, l) /\ Continue(c, l) /\ P(c, l).slot /= 0
    /\ trainer_x' = Upd(c, l, [T(c, l) EXCEPT !.pc = "training", !.consumed = P(c, l).slot,
                                              !.receiveCalled = TRUE])
    /\ UNCHANGED pTrainer

ExitLoop(c, l) ==
    /\ T(c, l).pc = "waiting" /\ Up(c, l) /\ ~Continue(c, l)
    /\ trainer_x' = Upd(c, l, [T(c, l) EXCEPT !.pc = "stopped"])
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].stopped = TRUE]

Train(c, l) ==
    /\ T(c, l).pc = "training" /\ Up(c, l)
    /\ trainer_x' = Upd(c, l, [T(c, l) EXCEPT !.pc = "publishing"])
    /\ UNCHANGED pTrainer

TrainError(c, l) ==
    /\ "trainerError" \in Faults /\ T(c, l).pc = "training" /\ Up(c, l)
    /\ trainer_x' = Upd(c, l, [T(c, l) EXCEPT !.pc = "stopped"])
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].stopped = TRUE]

\* RESULT_READY accepted (cell_backend.py:236-267): the result becomes the live
\* source for this task and the backend starts its accepted-source monitor. A
\* previous source must have settled (one live source per session).
Publish(c, l) ==
    /\ T(c, l).pc = "publishing" /\ Up(c, l) /\ T(c, l).receiveCalled /\ ~T(c, l).src.live
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].published =
          [gen |-> T(c, l).consumed, value |-> <<"result", c, T(c, l).consumed>>,
           seq |-> IF P(c, l).published = None THEN 1 ELSE P(c, l).published.seq + 1]]
    /\ trainer_x' = Upd(c, l, [T(c, l) EXCEPT !.pc = "tail",
                                              !.src = [g |-> T(c, l).consumed, live |-> TRUE],
                                              !.mon = @ \cup {[g |-> T(c, l).consumed, pc |-> "check", silent |-> FALSE]}])

\* the receivers finished; RESULT_SOURCE_SETTLED clears the live source
Settle(c, l) ==
    /\ Up(c, l) /\ T(c, l).src.live /\ ~T(c, l).silent
    /\ trainer_x' = Upd(c, l, [T(c, l) EXCEPT !.src.live = FALSE])
    /\ UNCHANGED pTrainer

ClearCache(c, l) ==
    /\ T(c, l).pc = "tail" /\ Up(c, l)
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].slot = 0]
    /\ trainer_x' = Upd(c, l, [T(c, l) EXCEPT !.pc = "waiting", !.receiveCalled = FALSE])

\* heartbeats stop beyond heartbeat_timeout / resume
GoSilent(c, l) ==
    /\ "tpSilent" \in Faults /\ Up(c, l) /\ ~T(c, l).silent
    /\ trainer_x' = Upd(c, l, [T(c, l) EXCEPT !.silent = TRUE])
    /\ UNCHANGED pTrainer
Resume(c, l) ==
    /\ Up(c, l) /\ T(c, l).silent
    /\ trainer_x' = Upd(c, l, [T(c, l) EXCEPT !.silent = FALSE])
    /\ UNCHANGED pTrainer

Active(r, g) == r.tp = "running" /\ r.src.live /\ r.src.g = g
\* _fail_accepted_result_source(g) (identity re-check) then _stop_trainer
\* (unconditional): the notice only if the source still is g
StopAfter(r, g) ==
    [r EXCEPT !.notices = IF Active(r, g) THEN @ \cup {g} ELSE @,
              !.victim = IF r.victim = 0 /\ r.src.live THEN r.src.g ELSE @,
              !.src.live = FALSE, !.tp = "stopped", !.pc = "stopped", !.stops = @ + 1]

\* one monitor iteration, atomic (default): the identity check and the decision
\* on the same snapshot
MonIter(c, l) ==
    \E m \in T(c, l).mon :
      /\ m.pc = "check" /\ CJAlive(c, l)
      /\ LET r == T(c, l) IN
         IF ~Active(r, m.g) THEN
            /\ trainer_x' = Upd(c, l, [r EXCEPT !.mon = @ \ {m}])
            /\ UNCHANGED pTrainer
         ELSE IF r.silent THEN
            /\ trainer_x' = Upd(c, l, [StopAfter(r, m.g) EXCEPT !.mon = r.mon \ {m}])
            /\ pTrainer' = [pTrainer EXCEPT ![c][l].stopped = TRUE]
         ELSE FALSE

\* monitorStale: the thread passes the identity check and reads the silence,
\* then is preempted before it acts (external_process_backend.py:1243-1268)
MonCheckStale(c, l) ==
    \E m \in T(c, l).mon :
      /\ "monitorStale" \in Faults /\ m.pc = "check" /\ CJAlive(c, l)
      /\ Active(T(c, l), m.g) /\ T(c, l).silent
      /\ trainer_x' = Upd(c, l, [T(c, l) EXCEPT !.mon = (@ \ {m}) \cup {[m EXCEPT !.pc = "decide", !.silent = TRUE]}])
      /\ UNCHANGED pTrainer
MonDecide(c, l) ==
    \E m \in T(c, l).mon :
      /\ m.pc = "decide" /\ CJAlive(c, l) /\ T(c, l).tp = "running"
      /\ trainer_x' = Upd(c, l, [StopAfter(T(c, l), m.g) EXCEPT !.mon = T(c, l).mon \ {m}])
      /\ pTrainer' = [pTrainer EXCEPT ![c][l].stopped = TRUE]

Next == \E c \in Sites, l \in Launches :
    \/ Start(c, l) \/ Callback(c, l) \/ SignalCallback(c, l) \/ Receive(c, l)
    \/ ExitLoop(c, l) \/ Train(c, l) \/ TrainError(c, l) \/ Publish(c, l) \/ Settle(c, l)
    \/ ClearCache(c, l) \/ GoSilent(c, l) \/ Resume(c, l) \/ MonIter(c, l)
    \/ MonCheckStale(c, l) \/ MonDecide(c, l)
=============================================================================
