---- MODULE MC_blind2_CFs1CFs1Fs2CFs1CFR_admin_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == ("JobCP" :> (s1 :> "F" @@ s2 :> "C") @@ "TaskCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "Trainer" :> (s1 :> "C" @@ s2 :> "F") @@ "PayRcv" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"abort", "outcomeReportFail", "resExpiry", "outcomeTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
