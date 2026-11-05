---- MODULE MC_demo_ps ----
EXTENDS Mix, Props, GenericProps, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "F", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == ("RunCJ" :> (s1 :> "F" @@ s2 :> "C") @@ "Trainer" :> (s1 :> "F" @@ s2 :> "C") @@ "PaySrc" :> (s1 :> "C" @@ s2 :> "F"))
MCFaults == {"cjCrash", "taskTimeout"}
MCSym == Permutations(Sites)

GNext == Next \/ ((DoneStutter \/ (AtBoundAny /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
