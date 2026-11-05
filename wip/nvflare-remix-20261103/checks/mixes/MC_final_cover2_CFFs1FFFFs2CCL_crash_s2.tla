---- MODULE MC_final_cover2_CFFs1FFFFs2CCL_crash_s2 ----
EXTENDS Mix, Props, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "F", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "F", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == ("RunCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "PayRcv" :> (s1 :> "C" @@ s2 :> "F"))
MCFaults == {"cjCrash", "taskTimeout"}
MCSym == Permutations(Sites)

====
