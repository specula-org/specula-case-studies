---- MODULE MC_mr_h30_sanity ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"taskTimeout"}
MCSym == Permutations(Sites)
NoSJFatalDecode == \A c \in Sites : ~Flag(pPayRcv[c], "fatal")
MC2Progress == PaySrc_F!PayCompletedProgressHasReceiverSuccess
SettleOnce == PaySrc_F!PaySingleSettlementEffects /\ PaySrc_F!PayNoSettlementEffectsAfterReceipt
PaySrcSafe == PaySrc_F!PaySrcSafety
PayRcvSafe == PayRcv_F!PayLocalCancellationNotified
ConfirmedSuccessFF == \A c \in Sites, l \in Launches, a \in Attempts :
    paySrc_f[c][l][a].status[<<"ref-1", "SJ">>] = "success" => payRcv_f[c][a].consumerResult[<<"ref-1", "SJ">>] = "success"
====
