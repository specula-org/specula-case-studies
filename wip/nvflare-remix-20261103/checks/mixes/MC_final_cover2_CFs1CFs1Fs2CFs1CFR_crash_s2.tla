---- MODULE MC_final_cover2_CFs1CFs1Fs2CFs1CFR_crash_s2 ----
EXTENDS Mix, Props, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == ("JobCP" :> (s1 :> "F" @@ s2 :> "C") @@ "TaskCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "Trainer" :> (s1 :> "C" @@ s2 :> "F") @@ "PayRcv" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"cjCrash", "taskTimeout"}
MCSym == Permutations(Sites)

====
