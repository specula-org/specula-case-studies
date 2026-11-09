------------------------------ MODULE PortsTrn ------------------------------
\* Port shape of the TRAINER group (in-process user training thread using the
\* in-process Client API). Owned by the coordinator.
\* pTrainer[c][l]:
\*   slot      : generation currently held in the API's fl_model (0 = None)
\*   received  : last input generation accepted by the GLOBAL_RESULT callback
\*               (DataBus publish returns to the executor after this)
\*   published : None or [gen, value, seq]; LOCAL_RESULT publication. seq counts
\*               publications so the executor can ignore pre-reset results.
\*   stopped   : the trainer loop has exited (abort/stop/closed observed)
\*   err       : (v11, Trainer_A only; 0 elsewhere) the last task generation whose
\*               execute() returned an error without a trainer result (attach
\*               timeout, delivery failure, session lost, result wait timeout, abort)
EXTENDS Consts
\* trainerError: the user training code raises (thread ends without send()).
\* tpSilent / monitorStale: external trainer (Trainer_X) heartbeat timeout, and the
\* accepted-source monitor preempted between its check and its decision (H03).
\* v11 Attach (Trainer_A): tpAttachLate (no session before attach_timeout), tpCrash
\* (the attached trainer dies), tpReplyLost (a CJ->trainer control reply is lost).
TrnFaults == {"trainerError", "tpSilent", "monitorStale", "tpAttachLate", "tpCrash", "tpReplyLost"}
\* taskMode (v10): no in-process trainer; Trainer variants quantify over this.
\* swarm (v11): the learn executor runs inside the Swarm group's coarse step
TrnLaunches == IF TaskMode \/ WfPolicy = "swarm" THEN {} ELSE Launches
TrainerPortInit == [c \in Sites |-> [l \in Launches |->
                     [slot |-> 0, received |-> 0, published |-> None, stopped |-> FALSE, err |-> 0]]]
=============================================================================
