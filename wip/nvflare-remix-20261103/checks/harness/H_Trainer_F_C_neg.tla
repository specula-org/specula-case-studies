---- MODULE H_Trainer_F_C_neg ----
EXTENDS Ports, TLC
CONSTANTS MaxGen
CONSTANTS s1
VARIABLES trainer_f
hvars == <<net, pJobSP, pJobCP, pRunCJ, pTaskCJ, pPaySrc, pPayRcv, pCommSJ, pWfSJ, pTrainer, trainer_f>>
FV == INSTANCE Trainer_F
E == INSTANCE Env_Trainer
CRef == INSTANCE Trainer_C WITH trainer_c <- FV!AbsC
SentKinds(kk) == {net[k].msg : k \in {k2 \in DOMAIN net : net[k2].msg.kind \in kk}}
ProjG == <<pTrainer, SentKinds({})>>
NetKeep == DOMAIN net \subseteq DOMAIN net' /\ \A k \in DOMAIN net : net'[k] = net[k]
GStep == FV!Next /\ UNCHANGED <<net, pJobSP, pJobCP, pRunCJ, pTaskCJ, pPaySrc, pPayRcv, pCommSJ, pWfSJ>>
    /\ Assert(NetKeep /\ \A k \in DOMAIN net' \ DOMAIN net : net'[k].msg.kind \in {}, "net discipline (group)")
EStep == E!EnvNext /\ UNCHANGED <<net, pJobSP, pPaySrc, pPayRcv, pCommSJ, pWfSJ, pTrainer, trainer_f>>
HInit == PortsInit /\ FV!Init
HNext == GStep \/ EStep
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<FV!AbsC, ProjG>>]_hvars
RefEnv == [][UNCHANGED <<trainer_f, ProjG>> => UNCHANGED FV!AbsC]_hvars
EnvSound == [][EStep => E!EnvAllowed]_hvars
BadStep == [][UNCHANGED <<FV!AbsC, ProjG>>]_hvars
====
