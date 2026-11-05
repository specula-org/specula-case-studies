---- MODULE MC_f1_lossy ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "L"]
MCFaults == {"netLoss"}
MCSym == Permutations(Sites)

====
