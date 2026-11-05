---- MODULE PayH_ff_settle ----
EXTENDS Ports, TLC
VARIABLES paySrc_f, payRcv_f, net_l
Src == INSTANCE PaySrc_F
Rcv == INSTANCE PayRcv_F
Env == INSTANCE PayEnv
vars == <<portVars, paySrc_f, payRcv_f, net_l>>
Init == PortsInit /\ Src!Init /\ Rcv!Init /\ net_l = 0
SrcStep == Src!Next /\ UNCHANGED <<pJobSP, pJobCP, pRunCJ, pTaskCJ, pPayRcv, pCommSJ, pWfSJ, pTrainer, payRcv_f, net_l>>
RcvStep == Rcv!Next /\ UNCHANGED <<pJobSP, pJobCP, pRunCJ, pTaskCJ, pPaySrc, pCommSJ, pWfSJ, pTrainer, paySrc_f, net_l>>
EnvStep == Env!Next /\ UNCHANGED <<net, pPaySrc, pPayRcv, pTrainer, paySrc_f, payRcv_f, net_l>>
LoseStep == /\ "netLoss" \in Faults /\ net_l < 1
            /\ \E k \in DOMAIN net : ~net[k].lost /\ net' = [net EXCEPT ![k].lost = TRUE]
            /\ net_l' = net_l + 1
            /\ UNCHANGED <<pJobSP, pJobCP, pRunCJ, pTaskCJ, pPaySrc, pPayRcv, pCommSJ, pWfSJ, pTrainer, paySrc_f, payRcv_f>>
Next == SrcStep \/ RcvStep \/ EnvStep \/ LoseStep
Spec == Init /\ [][Next]_vars
SentKinds(ks) == {net[k].msg : k \in {k2 \in DOMAIN net : net[k2].msg.kind \in ks}}
MCFaults == {"paySubmit", "payCallback", "payDelete"}
SettleOnce == Src!PaySingleSettlementEffects /\ Src!PayNoSettlementEffectsAfterReceipt
SrcSafety == Src!PaySrcSafety
RcvSafety == Rcv!PayLocalCancellationNotified
====
