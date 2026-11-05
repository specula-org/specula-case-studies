---- MODULE MC_ps_w ----
EXTENDS Mix, Props, TLC
CONSTANTS s1, s2
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == ("Trainer" :> (s1 :> "F" @@ s2 :> "C") @@ "PaySrc" :> (s1 :> "C" @@ s2 :> "F"))
MCFaults == {}
MCSym == Permutations(Sites)
BothPublished == ~(pTrainer[s1][1].published /= None /\ pTrainer[s2][1].published /= None)
====
