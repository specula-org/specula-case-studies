------------------------------ MODULE Trainer_A ------------------------------
\* Group Trainer, ATTACH variant (v11, DESIGN 16.7; coarse granularity, no
\* refinement receipt). The CJ's AttachBackend and the separately started
\* trainer process (TP) that attaches to it, pin c411a201:
\*   attach_backend.py:351-375 (execute: one task at a time, wait for a session),
\*     :414-462 (session loop: attach deadline, liveness, reconnect),
\*     :585-640 (_run_task: deliver, wait for RESULT_READY, abort, result wait
\*     timeout, session mismatch), :641-745 (_deliver_task: TASK_READY with a
\*     status probe after a lost reply), :375-412 (finalize: shutdown request,
\*     wait for the accepted source, close the listener);
\*   cell_backend.py:195-290 (RESULT_READY accepted only for the current task;
\*     result authority; RESULT_STATUS; RESULT_SOURCE_SETTLED);
\*   client/cell/attach_session.py:361-467 (publish_result: two attempts, status
\*     recovery, _resolve_ambiguous_result infers acceptance from completed
\*     transfers).
\* The CJ<->TP control messages are private: no other group reads them. Port
\* effects as Trainer_F (slot / received / published / stopped) plus err.
\* Faults: tpAttachLate, tpCrash, tpReplyLost (v11), tpSilent, trainerError.
EXTENDS Ports
VARIABLE trainer_a

\* tp: none | open | gone (session state as the CJ sees it); pc: CJ execute()
\*   idle | wait (task delivered, waiting for RESULT_READY);
\* gen: task generation of the current execute(); auth: generation whose result
\*   the CJ accepted (result authority); tpGen / tpPc: what the trainer holds and
\*   does (idle | train | send | done); tpOut: [gen, out] the trainer's send()
\*   outcome (ok | fail | inferred: acceptance inferred from a completed transfer,
\*   H01); src: an accepted result source is live; closed: backend finalized;
\* late: the attach deadline passed without a session (no reconnect).
Rec == [tp |-> "none", pc |-> "idle", gen |-> 0, auth |-> 0, tpGen |-> 0, tpPc |-> "idle",
        tpOut |-> [gen |-> 0, out |-> "none"], src |-> FALSE, closed |-> FALSE, late |-> FALSE]
Init == trainer_a = [c \in Sites |-> [l \in Launches |-> Rec]]
InitValue == [c \in Sites |-> [l \in Launches |-> Rec]]

T(c, l) == trainer_a[c][l]
P(c, l) == pTrainer[c][l]
Input(c, l) == IF Has(pTaskCJ[c][l], "input") THEN pTaskCJ[c][l].input ELSE None
Signal(c, l) == IF Has(pTaskCJ[c][l], "trainerSignal") THEN pTaskCJ[c][l].trainerSignal ELSE "none"
Upd(c, l, r) == [trainer_a EXCEPT ![c][l] = r]
Up(c, l) == CJAlive(c, l) /\ ~T(c, l).closed

\* ------------------------------------------------------------- session
\* The trainer is started separately and opens the session (SESSION_OPEN); after a
\* lost session a new trainer may attach again (allow_reconnect).
Attach(c, l) ==
    /\ Up(c, l) /\ T(c, l).tp \in {"none", "gone"} /\ ~T(c, l).late
    /\ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.tp = "open", !.tpPc = "idle", !.tpGen = 0])
    /\ UNCHANGED pTrainer
\* attach_timeout passed with no session: later tasks fail (session.error)
AttachLate(c, l) ==
    /\ "tpAttachLate" \in Faults /\ Up(c, l) /\ T(c, l).tp \in {"none", "gone"} /\ ~T(c, l).late
    /\ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.late = TRUE])
    /\ UNCHANGED pTrainer
\* the trainer process dies (tpCrash), or its heartbeats stop beyond the timeout
\* (tpSilent); the CJ's liveness check retires the session
Lose(c, l) ==
    /\ {"tpCrash", "tpSilent"} \cap Faults /= {} /\ Up(c, l) /\ T(c, l).tp = "open"
    /\ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.tp = "gone", !.tpPc = "idle", !.src = FALSE])
    /\ UNCHANGED pTrainer

\* ------------------------------------------------------------- one task
\* execute(): no session (attach deadline passed, or the session was lost) is
\* EXECUTION_EXCEPTION for this task.
NoSession(c, l) ==
    /\ Up(c, l) /\ T(c, l).pc = "idle" /\ Input(c, l) /= None /\ Input(c, l).gen > T(c, l).gen
    /\ T(c, l).late \/ T(c, l).tp = "gone"
    /\ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.gen = Input(c, l).gen])
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].err = Input(c, l).gen]

\* TASK_READY accepted (directly, by the status probe after a lost reply, or by a
\* RESULT_READY that already arrived): the trainer holds the task.
Deliver(c, l) ==
    /\ Up(c, l) /\ T(c, l).pc = "idle" /\ T(c, l).tp = "open" /\ T(c, l).tpPc = "idle"
    /\ Input(c, l) /= None /\ Input(c, l).gen > T(c, l).gen
    /\ LET g == Input(c, l).gen IN
       /\ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.pc = "wait", !.gen = g, !.tpGen = g, !.tpPc = "train"])
       /\ pTrainer' = [pTrainer EXCEPT ![c][l].slot = g, ![c][l].received = g]

\* Delivery failed (TASK_FAILED, or no reply and an UNKNOWN status probe until the
\* delivery deadline): error for this task. With a lost reply the trainer may
\* still have taken the task (tpReplyLost) and trains it anyway.
DeliverFail(c, l) ==
    /\ Up(c, l) /\ T(c, l).pc = "idle" /\ T(c, l).tp = "open" /\ T(c, l).tpPc = "idle"
    /\ Input(c, l) /= None /\ Input(c, l).gen > T(c, l).gen
    /\ LET g == Input(c, l).gen IN
       \/ /\ "tpReplyLost" \in Faults
          /\ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.gen = g, !.tpGen = g, !.tpPc = "train"])
          /\ pTrainer' = [pTrainer EXCEPT ![c][l].err = g]
       \/ /\ {"tpReplyLost", "tpSilent"} \cap Faults /= {}
          /\ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.gen = g])
          /\ pTrainer' = [pTrainer EXCEPT ![c][l].err = g]

\* the user script trains (or raises: the trainer exits, trainerError)
Train(c, l) ==
    /\ T(c, l).tp = "open" /\ T(c, l).tpPc = "train" /\ CJAlive(c, l)
    /\ \/ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.tpPc = "send"])
       \/ /\ "trainerError" \in Faults
          /\ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.tp = "gone", !.tpPc = "idle"])
    /\ UNCHANGED pTrainer

\* RESULT_READY (attempts and status recovery merged): the CJ accepts the result
\* of its current task once (authority); the trainer's send() then succeeds.
SendAccepted(c, l) ==
    /\ Up(c, l) /\ T(c, l).tp = "open" /\ T(c, l).tpPc = "send"
    /\ T(c, l).pc = "wait" /\ T(c, l).gen = T(c, l).tpGen /\ T(c, l).auth < T(c, l).tpGen
    /\ LET g == T(c, l).tpGen IN
       /\ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.pc = "idle", !.auth = g, !.src = TRUE, !.tpPc = "done",
                                                 !.tpOut = [gen |-> g, out |-> "ok"]])
       /\ pTrainer' = [pTrainer EXCEPT ![c][l].published =
             [gen |-> g, value |-> <<"result", c, g>>,
              seq |-> IF P(c, l).published = None THEN 1 ELSE P(c, l).published.seq + 1]]

\* RESULT_REJECTED (no current task matching: delivery failed, aborted, timed
\* out, or closed): send() fails; if both rejection replies are lost the trainer
\* finds RESULT_STATUS UNKNOWN and, the transfer having completed, infers
\* acceptance (H01).
SendRejected(c, l) ==
    /\ CJAlive(c, l) /\ T(c, l).tp = "open" /\ T(c, l).tpPc = "send"
    /\ T(c, l).closed \/ T(c, l).pc /= "wait" \/ T(c, l).gen /= T(c, l).tpGen
    /\ \E o \in {"fail"} \cup (IF "tpReplyLost" \in Faults THEN {"inferred"} ELSE {}) :
         trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.tpPc = "done", !.tpOut = [gen |-> T(c, l).tpGen, out |-> o]])
    /\ UNCHANGED pTrainer

\* send() returned: the trainer clears its cache and waits for the next task
NextTask(c, l) ==
    /\ T(c, l).tp = "open" /\ T(c, l).tpPc = "done" /\ CJAlive(c, l)
    /\ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.tpPc = "idle"])
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].slot = 0]

\* RESULT_SOURCE_SETTLED: the receivers finished with the accepted source
Settle(c, l) ==
    /\ T(c, l).tp = "open" /\ T(c, l).src /\ CJAlive(c, l)
    /\ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.src = FALSE])
    /\ UNCHANGED pTrainer

\* the waiting execute() ends without a result: abort signal (TASK_ABORTED, ABORT
\* sent), result_wait_timeout, or the session was lost / mismatched
EndWait(c, l) ==
    /\ Up(c, l) /\ T(c, l).pc = "wait"
    /\ \/ Signal(c, l) = "abort"
       \/ "resultWaitTimeout" \in Faults
       \/ T(c, l).tp = "gone"
    /\ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.pc = "idle",
                                    !.tpPc = IF T(c, l).tp = "open" /\ T(c, l).tpPc = "train" THEN "idle" ELSE @])
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].err = T(c, l).gen]

\* finalize (TOPIC_STOP at run end): SHUTDOWN to the trainer, wait (bounded) for
\* the accepted source to settle, close the listener; the trainer's loop ends.
Finalize(c, l) ==
    /\ CJAlive(c, l) /\ Signal(c, l) = "stop" /\ ~T(c, l).closed /\ T(c, l).pc = "idle"
    /\ trainer_a' = Upd(c, l, [T(c, l) EXCEPT !.closed = TRUE, !.src = FALSE])
    /\ pTrainer' = [pTrainer EXCEPT ![c][l].stopped = TRUE]

Next == \E c \in Sites, l \in TrnLaunches :
    \/ Attach(c, l) \/ AttachLate(c, l) \/ Lose(c, l) \/ NoSession(c, l) \/ Deliver(c, l)
    \/ DeliverFail(c, l) \/ Train(c, l) \/ SendAccepted(c, l) \/ SendRejected(c, l)
    \/ NextTask(c, l) \/ Settle(c, l) \/ EndWait(c, l) \/ Finalize(c, l)
=============================================================================
