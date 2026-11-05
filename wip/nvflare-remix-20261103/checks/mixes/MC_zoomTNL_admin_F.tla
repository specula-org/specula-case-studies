---- MODULE MC_zoomTNL_admin_F ----
EXTENDS Mix, Props, GenericProps, TLC

MCGrain == [JobSP |-> "F", JobCP |-> "F", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"abort", "outcomeReportFail", "resExpiry", "outcomeTimeout"}
MCSym == Permutations(Sites)

====
