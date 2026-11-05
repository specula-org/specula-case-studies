---- MODULE MC_hs2_dl ----
EXTENDS Mix, Props, GenericProps, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "F", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "taskTimeout", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout"}
MCSym == Permutations(Sites)
WitCJExitAfterRegShutdown == ~(\E c \in Sites, l \in Launches : pRunCJ[c][l].exit = "ok" /\ pPaySrc[c][l].tx[1].registered /= None /\ pPaySrc[c][l].tx[1].shut)
GNext == Next \/ ((DoneStutter \/ (AtBoundAny /\ UNCHANGED portVars)) /\ UNCHANGED privVars)
====
