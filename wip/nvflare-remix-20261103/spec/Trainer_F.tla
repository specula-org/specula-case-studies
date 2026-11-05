------------------------------ MODULE Trainer_F ------------------------------
\* Group Trainer, FINE variant. Process: CJ(c), launch l. The user training
\* thread of an in-process job and the in-process Client API object it uses
\* (nvflare/client/in_process/api.py at pin c411a201).
\* Typical script: while flare.is_running(): m = flare.receive(); train; flare.send(r)
\* Writes: trainer_f, pTrainer.
\* Inputs: pTaskCJ[c][l].input ([gen, assignment, value]; the executor's
\*   GLOBAL_RESULT DataBus publication, in_process_backend.py:192) and
\*   pTaskCJ[c][l].trainerSignal ("none"/"abort"/"stop"; TOPIC_ABORT/TOPIC_STOP).
\* The GLOBAL_RESULT callback runs inside the executor's publish; the executor
\* blocks until pTrainer.received reaches the published generation.
EXTENDS Ports
VARIABLE trainer_f

Init == trainer_f = [c \in Sites |-> [l \in Launches |->
          [pc |-> "idle", consumed |-> 0, receiveCalled |-> FALSE, abort |-> FALSE, stop |-> FALSE]]]
InitValue == [c \in Sites |-> [l \in Launches |->
          [pc |-> "idle", consumed |-> 0, receiveCalled |-> FALSE, abort |-> FALSE, stop |-> FALSE]]]
AbsC == 0
AbsCInit == 0

T(c, l) == trainer_f[c][l]
P(c, l) == pTrainer[c][l]
Input(c, l) == IF Has(pTaskCJ[c][l], "input") THEN pTaskCJ[c][l].input ELSE None
Signal(c, l) == IF Has(pTaskCJ[c][l], "trainerSignal") THEN pTaskCJ[c][l].trainerSignal ELSE "none"
Continue(c, l) == ~T(c, l).abort /\ ~T(c, l).stop     \* api.py __continue_job

\* in_process_backend.py: the task function thread starts with the backend.
Start(c, l) ==
    /\ T(c, l).pc = "idle" /\ CJAlive(c, l) /\ pRunCJ[c][l].ready
    /\ trainer_f' = [trainer_f EXCEPT ![c][l].pc = "waiting"]
    /\ UNCHANGED pTrainer

\* api.py:301-324 __receive_callback -> _set_received_shareable: fl_model := model.
Callback(c, l) ==
    /\ CJAlive(c, l) /\ Input(c, l) /= None /\ Input(c, l).gen > P(c, l).received
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].slot = Input(c, l).gen,
                                    ![c][l].received = Input(c, l).gen]
    /\ UNCHANGED trainer_f

\* api.py:326-333 __ask_to_abort: TOPIC_ABORT / TOPIC_STOP latch flags.
SignalCallback(c, l) ==
    /\ CJAlive(c, l) /\ Signal(c, l) /= "none"
    /\ IF Signal(c, l) = "abort" THEN ~T(c, l).abort ELSE ~T(c, l).stop
    /\ trainer_f' = [trainer_f EXCEPT ![c][l].abort = (@ \/ Signal(c, l) = "abort"),
                                      ![c][l].stop = (@ \/ Signal(c, l) = "stop")]
    /\ UNCHANGED pTrainer

\* api.py:149-185 receive(): returns fl_model if present (no wait), else polls.
Receive(c, l) ==
    /\ T(c, l).pc = "waiting" /\ CJAlive(c, l) /\ Continue(c, l) /\ P(c, l).slot /= 0
    /\ trainer_f' = [trainer_f EXCEPT ![c][l].pc = "training", ![c][l].consumed = P(c, l).slot,
                                      ![c][l].receiveCalled = TRUE]
    /\ UNCHANGED pTrainer

\* api.py:165-170: __continue_job() false -> receive() returns None; loop exits.
ExitLoop(c, l) ==
    /\ T(c, l).pc = "waiting" /\ CJAlive(c, l) /\ ~Continue(c, l)
    /\ trainer_f' = [trainer_f EXCEPT ![c][l].pc = "stopped"]
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].stopped = TRUE]

Train(c, l) ==
    /\ T(c, l).pc = "training" /\ CJAlive(c, l)
    /\ trainer_f' = [trainer_f EXCEPT ![c][l].pc = "publishing"]
    /\ UNCHANGED pTrainer

\* Fault trainerError: the user training code raises inside the training step;
\* the task-script thread ends (TaskScriptRunner logs it) without send().
TrainError(c, l) ==
    /\ "trainerError" \in Faults /\ T(c, l).pc = "training" /\ CJAlive(c, l)
    /\ trainer_f' = [trainer_f EXCEPT ![c][l].pc = "stopped"]
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].stopped = TRUE]

\* api.py:205-226 send(): ... self._adapter.publish_result(shareable).
\* DataBus publish runs the executor's _local_result_callback, then returns.
Publish(c, l) ==
    /\ T(c, l).pc = "publishing" /\ CJAlive(c, l) /\ T(c, l).receiveCalled
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].published =
          [gen |-> T(c, l).consumed, value |-> <<"result", c, T(c, l).consumed>>,
           seq |-> IF P(c, l).published = None THEN 1 ELSE P(c, l).published.seq + 1]]
    /\ trainer_f' = [trainer_f EXCEPT ![c][l].pc = "tail"]

\* api.py:228-239 send() tail with clear_cache=True: self.fl_model = None.
\* Separate step: the executor may already have delivered the next input.
ClearCache(c, l) ==
    /\ T(c, l).pc = "tail" /\ CJAlive(c, l)
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].slot = 0]
    /\ trainer_f' = [trainer_f EXCEPT ![c][l].pc = "waiting", ![c][l].receiveCalled = FALSE]

Next == \E c \in Sites, l \in Launches :
    \/ Start(c, l) \/ Callback(c, l) \/ SignalCallback(c, l) \/ Receive(c, l)
    \/ ExitLoop(c, l) \/ Train(c, l) \/ TrainError(c, l) \/ Publish(c, l) \/ ClearCache(c, l)
=============================================================================
