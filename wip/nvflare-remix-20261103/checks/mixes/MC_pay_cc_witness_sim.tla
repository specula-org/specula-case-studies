---- MODULE MC_pay_cc_witness_sim ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCFaults == {}
MCSym == Permutations(Sites)
NoSJFatalDecode == \A c \in Sites : ~Flag(pPayRcv[c], "fatal")
MC2Progress == PaySrc_F!PayCompletedProgressHasReceiverSuccess
SettleOnce == PaySrc_F!PaySingleSettlementEffects /\ PaySrc_F!PayNoSettlementEffectsAfterReceipt
PaySrcSafe == PaySrc_F!PaySrcSafety
PayRcvSafe == PayRcv_F!PayLocalCancellationNotified
ConfirmedSuccessFF == \A c \in Sites, l \in Launches :
    paySrc_f[c][l].status[<<"ref-1", "SJ">>] = "success" => payRcv_f[c].consumerResult[<<"ref-1", "SJ">>] = "success"
====
