---- MODULE MC_c9_PaySrc ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == ("PaySrc" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"cjCrash", "taskTimeout"}
MCSym == Permutations(Sites)

====
