---- MODULE MC_sim100c_CFs1Fs2Fs2Fs1Fs2CFFL_admin_s2 ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "F", WfSJ |-> "F", Net |-> "L"]
MCSiteGrain == ("JobCP" :> (s1 :> "F" @@ s2 :> "C") @@ "RunCJ" :> (s1 :> "C" @@ s2 :> "F") @@ "TaskCJ" :> (s1 :> "C" @@ s2 :> "F") @@ "Trainer" :> (s1 :> "F" @@ s2 :> "C") @@ "PaySrc" :> (s1 :> "C" @@ s2 :> "F"))
MCFaults == {"abort", "abortCmdError", "deadClient", "outcomeReportFail", "pullTimeout", "resExpiry", "rpcTimeout", "submitTimeout", "txTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ (AtBoundAny /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
