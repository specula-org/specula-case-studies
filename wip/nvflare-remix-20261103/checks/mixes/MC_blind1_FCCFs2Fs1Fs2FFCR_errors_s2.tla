---- MODULE MC_blind1_FCCFs2Fs1Fs2FFCR_errors_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "F", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == ("TaskCJ" :> (s1 :> "C" @@ s2 :> "F") @@ "Trainer" :> (s1 :> "F" @@ s2 :> "C") @@ "PaySrc" :> (s1 :> "C" @@ s2 :> "F"))
MCFaults == {"prepFail", "cbFail", "payProduce", "payConsumer", "deployError", "launchError", "storeError"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
