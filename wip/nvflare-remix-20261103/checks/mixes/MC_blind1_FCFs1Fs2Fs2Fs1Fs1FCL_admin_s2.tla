---- MODULE MC_blind1_FCFs1Fs2Fs2Fs1Fs1FCL_admin_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == ("RunCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "TaskCJ" :> (s1 :> "C" @@ s2 :> "F") @@ "Trainer" :> (s1 :> "C" @@ s2 :> "F") @@ "PaySrc" :> (s1 :> "F" @@ s2 :> "C") @@ "PayRcv" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"abort", "outcomeReportFail", "resExpiry", "outcomeTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
