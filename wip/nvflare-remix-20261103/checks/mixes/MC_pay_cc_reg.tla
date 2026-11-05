---- MODULE MC_pay_cc_reg ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCFaults == {}
MCSym == Permutations(Sites)
NoReg == \A c \in Sites : pPaySrc[c][1].registered = None
NoMat == \A c \in Sites : pPayRcv[c].status /= "materialized"
NoClaim == pCommSJ.claimed = {}
NoDone == ~pWfSJ.done

====
