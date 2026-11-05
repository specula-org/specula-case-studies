---- MODULE MC_f1_all ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCFaults == {"cjCrash", "sjCrash", "taskTimeout", "pullTimeout", "txTimeout", "abort", "outcomeReportFail"}
MCSym == Permutations(Sites)

====
