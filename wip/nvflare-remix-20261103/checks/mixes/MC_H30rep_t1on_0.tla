---- MODULE MC_H30rep_t1on_0 ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "F", Trainer |-> "F", PaySrc |-> "F", PayRcv |-> "F", CommSJ |-> "F", WfSJ |-> "F", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"taskTimeout", "slowSJTeardown"}
MCSym == Permutations(Sites)
NoPayFatalAfterDone == pWfSJ.done => \A c \in Sites : ~(pPayRcv[c].fatal = TRUE)
====
