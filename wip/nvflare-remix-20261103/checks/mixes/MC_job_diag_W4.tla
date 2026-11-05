---- MODULE MC_job_diag_W4 ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCFaults == {}
MCSym == Permutations(Sites)
W1 == pJobSP.status # "RUNNING"
W2 == ~pJobSP.sjLaunched
W3 == \A c \in Sites : pJobCP[c].launch = 0
W4 == pWfSJ.sj # "exited"
W5 == \A c \in Sites : pRunCJ[c][1].exit = "none"
W6 == \A c \in Sites : pJobCP[c].freed = 0

====
