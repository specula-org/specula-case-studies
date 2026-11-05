---- MODULE MC_pay_ff_W2 ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCFaults == {}
MCSym == Permutations(Sites)
Wit == \A c \in Sites : ~pPayRcv[c].returned

====
