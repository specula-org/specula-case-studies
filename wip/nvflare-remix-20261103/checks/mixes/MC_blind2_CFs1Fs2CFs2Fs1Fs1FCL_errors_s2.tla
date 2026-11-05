---- MODULE MC_blind2_CFs1Fs2CFs2Fs1Fs1FCL_errors_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "C", Net |-> "L"]
MCSiteGrain == ("JobCP" :> (s1 :> "F" @@ s2 :> "C") @@ "RunCJ" :> (s1 :> "C" @@ s2 :> "F") @@ "Trainer" :> (s1 :> "C" @@ s2 :> "F") @@ "PaySrc" :> (s1 :> "F" @@ s2 :> "C") @@ "PayRcv" :> (s1 :> "F" @@ s2 :> "C"))
MCFaults == {"prepFail", "cbFail", "payProduce", "payConsumer", "deployError", "launchError", "storeError"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
