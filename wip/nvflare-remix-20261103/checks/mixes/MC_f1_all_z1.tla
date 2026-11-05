---- MODULE MC_f1_all_z1 ----
EXTENDS Mix, Props, TLC
MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "C", TaskCJ |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "M", Net |-> "R"]
MCFaults == {"cjCrash", "sjCrash", "taskTimeout", "pullTimeout", "txTimeout", "abort", "outcomeReportFail"}
MCSym == Permutations(Sites)

====
