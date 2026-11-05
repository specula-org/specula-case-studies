---- MODULE MC_final_cover2_FFs2FFs1Fs1CCCFR_crash_s2 ----
EXTENDS Mix, Props, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == ("JobCP" :> (s1 :> "C" @@ s2 :> "F") @@ "TaskCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "Trainer" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"cjCrash", "taskTimeout"}
MCSym == Permutations(Sites)

====
