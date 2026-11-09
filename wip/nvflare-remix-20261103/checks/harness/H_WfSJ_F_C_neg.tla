---- MODULE H_WfSJ_F_C_neg ----
EXTENDS Ports, TLC
CONSTANTS s1
VARIABLES wfSJ_f
hvars == <<net, pJobSP, pJobCP, pRunCJ, pTaskCJ, pPaySrc, pPayRcv, pCommSJ, pWfSJ, pTrainer, pReg, pWorker, pModel, wfSJ_f>>
FV == INSTANCE WfSJ_F
E == INSTANCE Env_WfSJ
CRef == INSTANCE WfSJ_C WITH wfSJ_c <- FV!AbsC
SentKinds(kk) == {net[k].msg : k \in {k2 \in DOMAIN net : net[k2].msg.kind \in kk}}
ProjG == <<pWfSJ, SentKinds({"END_RUN"})>>
NetKeep == DOMAIN net \subseteq DOMAIN net' /\ \A k \in DOMAIN net : net'[k] = net[k]
GStep == FV!Next /\ UNCHANGED <<pJobSP, pJobCP, pRunCJ, pTaskCJ, pPaySrc, pPayRcv, pCommSJ, pTrainer, pReg, pWorker, pModel>>
    /\ Assert(NetKeep /\ \A k \in DOMAIN net' \ DOMAIN net : net'[k].msg.kind \in {"END_RUN"}, "net discipline (group)")
EStep == E!EnvNext /\ UNCHANGED <<net, pJobCP, pRunCJ, pTaskCJ, pPaySrc, pWfSJ, pTrainer, pReg, pWorker, pModel, wfSJ_f>>
HInit == PortsInit /\ FV!Init
HNext == GStep \/ EStep
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<FV!AbsC, ProjG>>]_hvars
RefEnv == [][UNCHANGED <<wfSJ_f, ProjG>> => UNCHANGED FV!AbsC]_hvars
EnvSound == [][EStep => E!EnvAllowed]_hvars
BadStep == [][UNCHANGED <<FV!AbsC, ProjG>>]_hvars
====
