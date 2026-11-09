---- MODULE H_RunCJ_F_C ----
EXTENDS Ports, TLC
CONSTANTS s1
VARIABLES runCJ_f
hvars == <<net, pJobSP, pJobCP, pRunCJ, pTaskCJ, pPaySrc, pPayRcv, pCommSJ, pWfSJ, pTrainer, pReg, pWorker, pModel, pSwarm, runCJ_f>>
FV == INSTANCE RunCJ_F
E == INSTANCE Env_RunCJ
CRef == INSTANCE RunCJ_C WITH runCJ_c <- FV!AbsC
SentKinds(kk) == {net[k].msg : k \in {k2 \in DOMAIN net : net[k2].msg.kind \in kk}}
ProjG == <<pRunCJ, SentKinds({"STARTED", "READY", "STOPPED"})>>
NetKeep == DOMAIN net \subseteq DOMAIN net' /\ \A k \in DOMAIN net : net'[k] = net[k]
GStep == FV!Next /\ UNCHANGED <<pJobSP, pJobCP, pTaskCJ, pPaySrc, pPayRcv, pCommSJ, pWfSJ, pTrainer, pReg, pWorker, pModel, pSwarm>>
    /\ Assert(NetKeep /\ \A k \in DOMAIN net' \ DOMAIN net : net'[k].msg.kind \in {"STARTED", "READY", "STOPPED"}, "net discipline (group)")
EStep == E!EnvNext /\ UNCHANGED <<pRunCJ, pTaskCJ, pPayRcv, pCommSJ, pTrainer, pReg, pWorker, pModel, pSwarm, runCJ_f>>
HInit == PortsInit /\ FV!Init
HNext == GStep \/ EStep
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<FV!AbsC, ProjG>>]_hvars
RefEnv == [][UNCHANGED <<runCJ_f, ProjG>> => UNCHANGED FV!AbsC]_hvars
EnvSound == [][EStep => E!EnvAllowed]_hvars
BadStep == [][UNCHANGED <<FV!AbsC, ProjG>>]_hvars
====
