--------------------------- MODULE TrainerHarness ---------------------------
\* Component harness for the Trainer group: a chaotic executor stub drives
\* pTaskCJ[c][l].input / trainerSignal (any increasing generation, any signal),
\* over-approximating every TaskCJ variant's handshake. Everything else is
\* frozen (process alive, runner ready).
EXTENDS Ports, TLC
CONSTANT MaxGen
VARIABLES trainer_f, trainer_c
TF == INSTANCE Trainer_F
TC == INSTANCE Trainer_C
CRef == INSTANCE Trainer_C WITH trainer_c <- TF!AbsC
c0 == CHOOSE c \in Sites : TRUE
Rec(r, f, v) == [x \in DOMAIN r \cup {f} |-> IF x = f THEN v ELSE r[x]]
HInit == /\ PortsInit /\ TF!Init /\ trainer_c = 0
         /\ pJobCP' = pJobCP \* placeholder (overridden below)
Init0 == /\ net = [k \in {} |-> None] /\ pJobSP = JobSPPortInit
         /\ pJobCP = [JobCPPortInit EXCEPT ![c0].launch = 1, ![c0].allocated = TRUE]
         /\ pRunCJ = [RunCJPortInit EXCEPT ![c0][1].state = "running", ![c0][1].ready = TRUE]
         /\ pTaskCJ = [c \in Sites |-> [l \in Launches |->
                         Rec(Rec(TaskCJPortInit[c][l], "input", None), "trainerSignal", "none")]]
         /\ pPaySrc = PaySrcPortInit /\ pPayRcv = PayRcvPortInit
         /\ pCommSJ = CommSJPortInit /\ pWfSJ = WfSJPortInit /\ pTrainer = TrainerPortInit
         /\ TF!Init /\ trainer_c = 0
Frozen == <<net, pJobSP, pJobCP, pRunCJ, pPaySrc, pPayRcv, pCommSJ, pWfSJ>>
\* executor publishes the next generation only after the previous publish
\* returned (received caught up), i.e. one in-flight GLOBAL_RESULT at a time
EnvInput(k) ==
    /\ k \in 1..MaxGen /\ pTrainer[c0][1].received = k - 1
    \* realistic executor: task k+1 only after task k's result was taken
    /\ k = 1 \/ (pTrainer[c0][1].published /= None /\ pTrainer[c0][1].published.gen = k - 1)
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c0][1].input = [gen |-> k, assignment |-> None, value |-> k]]
    /\ UNCHANGED <<Frozen, pTrainer, trainer_f, trainer_c>>
EnvSignal(s) ==
    /\ pTaskCJ[c0][1].trainerSignal = "none"
    /\ pTaskCJ' = [pTaskCJ EXCEPT ![c0][1].trainerSignal = s]
    /\ UNCHANGED <<Frozen, pTrainer, trainer_f, trainer_c>>
FStep == TF!Next /\ UNCHANGED <<Frozen, pTaskCJ, trainer_c>>
Next == FStep \/ (\E k \in 1..MaxGen : EnvInput(k)) \/ (\E s \in {"abort", "stop"} : EnvSignal(s))
hvars == <<portVars, trainer_f, trainer_c>>
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<pTrainer>>]_hvars
SuccessorInputPreserved == LET P == pTrainer[c0][1] IN
    P.received > (IF P.published = None THEN 0 ELSE P.published.gen) => P.slot = P.received
\* negative control: a coarse trainer that never clears cannot match fine ClearCache
CNoClear == INSTANCE Trainer_C WITH trainer_c <- 0
BadStep == [][CNoClear!Callback(c0, 1) \/ CNoClear!Publish(c0, 1) \/ CNoClear!Stop(c0, 1)
              \/ UNCHANGED <<pTrainer>>]_hvars
=============================================================================
