---- MODULE PayH_mr_rcv_nofault_a2 ----
EXTENDS Ports, TLC
VARIABLES paySrc_c, payRcv_f, net_l
Src == INSTANCE PaySrc_C
Rcv == INSTANCE PayRcv_F
Env == INSTANCE PayEnv
vars == <<portVars, paySrc_c, payRcv_f, net_l>>
Init == PortsInit /\ Src!Init /\ Rcv!Init /\ net_l = 0
NetKeep == DOMAIN net \subseteq DOMAIN net' /\ \A k \in DOMAIN net : net'[k] = net[k]
NetOK(ks) == NetKeep /\ \A k \in DOMAIN net' \ DOMAIN net : net'[k].msg.kind \in ks /\ ~net'[k].lost
SrcStep == Src!Next /\ UNCHANGED <<pJobSP, pJobCP, pRunCJ, pTaskCJ, pPayRcv, pCommSJ, pWfSJ, pTrainer, payRcv_f, net_l>> /\ Assert(NetOK({"PAYLOAD_REPLY"}), "net discipline PaySrc")
RcvStep == Rcv!Next /\ UNCHANGED <<pJobSP, pJobCP, pRunCJ, pTaskCJ, pPaySrc, pCommSJ, pWfSJ, pTrainer, paySrc_c, net_l>> /\ Assert(NetOK({"PAYLOAD_PULL", "RECEIVER_CONFIRM", "RECEIVER_CANCEL"}), "net discipline PayRcv")
EnvStep == Env!Next /\ UNCHANGED <<net, pPaySrc, pPayRcv, pTrainer, paySrc_c, payRcv_f, net_l>>
LoseStep == /\ "netLoss" \in Faults /\ net_l < 1
            /\ \E k \in DOMAIN net : ~net[k].lost /\ net' = [net EXCEPT ![k].lost = TRUE]
            /\ net_l' = net_l + 1
            /\ UNCHANGED <<pJobSP, pJobCP, pRunCJ, pTaskCJ, pPaySrc, pPayRcv, pCommSJ, pWfSJ, pTrainer, paySrc_c, payRcv_f>>
Next == SrcStep \/ RcvStep \/ EnvStep \/ LoseStep
Spec == Init /\ [][Next]_vars
SentKinds(ks) == {net[k].msg : k \in {k2 \in DOMAIN net : net[k2].msg.kind \in ks}}
MCFaults == {}
MCSym == Permutations(Sites)
Proj == <<pPayRcv, SentKinds({"PAYLOAD_PULL", "RECEIVER_CONFIRM", "RECEIVER_CANCEL"})>>
CRef == INSTANCE PayRcv_C WITH payRcv_c <- Rcv!AbsC
RefInit == CRef!Init
RefStep == [][CRef!Next \/ UNCHANGED <<Rcv!AbsC, Proj>>]_vars
====
