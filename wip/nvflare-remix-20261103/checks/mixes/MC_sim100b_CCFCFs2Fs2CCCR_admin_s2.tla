---- MODULE MC_sim100b_CCFCFs2Fs2CCCR_admin_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == ("Trainer" :> (s1 :> "C" @@ s2 :> "F") @@ "PaySrc" :> (s1 :> "C" @@ s2 :> "F"))
MCFaults == {"abort", "outcomeReportFail", "outcomeTimeout", "pullTimeout", "resExpiry", "rpcTimeout", "submitTimeout", "txTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ (DoneStutter /\ UNCHANGED privVars)
====
