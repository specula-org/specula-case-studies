------------------------------ MODULE Trainer_C ------------------------------
\* Group Trainer, COARSE variant. Same port effects as Trainer_F with the
\* thread's internal PC removed: a publication may carry any generation the
\* API has received, and the send() tail clear may happen at any time after a
\* publication. Over-approximates Trainer_F on pTrainer.
EXTENDS Ports
VARIABLE trainer_c

Init == trainer_c = 0
InitValue == 0

Input(c, l) == IF Has(pTaskCJ[c][l], "input") THEN pTaskCJ[c][l].input ELSE None
Signal(c, l) == IF Has(pTaskCJ[c][l], "trainerSignal") THEN pTaskCJ[c][l].trainerSignal ELSE "none"
P(c, l) == pTrainer[c][l]

Callback(c, l) ==
    /\ CJAlive(c, l) /\ Input(c, l) /= None /\ Input(c, l).gen > P(c, l).received
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].slot = Input(c, l).gen,
                                    ![c][l].received = Input(c, l).gen]
    /\ UNCHANGED trainer_c

PubCount(c, l) == IF P(c, l).published = None THEN 0 ELSE P(c, l).published.seq
\* Each fine publication consumes one received input (receive -> send -> clear),
\* so publications never outnumber accepted inputs; this bound keeps coarse finite.
Publish(c, l) ==
    /\ CJAlive(c, l) /\ ~P(c, l).stopped /\ PubCount(c, l) < P(c, l).received
    /\ \E g \in 1..P(c, l).received :
         pTrainer' = [pTrainer EXCEPT ![c][l].published =
            [gen |-> g, value |-> <<"result", c, g>>,
             seq |-> IF P(c, l).published = None THEN 1 ELSE P(c, l).published.seq + 1]]
    /\ UNCHANGED trainer_c

ClearCache(c, l) ==
    /\ CJAlive(c, l) /\ P(c, l).published /= None /\ P(c, l).slot /= 0
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].slot = 0]
    /\ UNCHANGED trainer_c

Stop(c, l) ==
    /\ CJAlive(c, l) /\ Signal(c, l) /= "none" /\ ~P(c, l).stopped
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].stopped = TRUE]
    /\ UNCHANGED trainer_c

\* Fault trainerError: the training code raised; the thread is gone.
Error(c, l) ==
    /\ "trainerError" \in Faults /\ CJAlive(c, l) /\ ~P(c, l).stopped
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].stopped = TRUE]
    /\ UNCHANGED trainer_c

Next == \E c \in Sites, l \in Launches :
    Callback(c, l) \/ Publish(c, l) \/ ClearCache(c, l) \/ Stop(c, l) \/ Error(c, l)
=============================================================================
