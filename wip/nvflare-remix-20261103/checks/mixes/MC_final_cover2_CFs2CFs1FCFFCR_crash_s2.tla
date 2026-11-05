---- MODULE MC_final_cover2_CFs2CFs1FCFFCR_crash_s2 ----
EXTENDS Mix, Props, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "F", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == ("JobCP" :> (s1 :> "C" @@ s2 :> "F") @@ "TaskCJ" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"cjCrash", "taskTimeout"}
MCSym == Permutations(Sites)

====
