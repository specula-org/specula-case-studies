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
EXTENDS Consts
\* trainerError: the user training code raises (thread ends without send()).
\* tpSilent / monitorStale: external trainer (Trainer_X) heartbeat timeout, and the
\* accepted-source monitor preempted between its check and its decision (H03).
TrnFaults == {"trainerError", "tpSilent", "monitorStale"}
TrainerPortInit == [c \in Sites |-> [l \in Launches |->
                     [slot |-> 0, received |-> 0, published |-> None, stopped |-> FALSE]]]
=============================================================================
