---- MODULE MC_job_mRunCJ_flt ----
EXTENDS Mix, Props, TLC

MCGrain == [JobSP |-> "C", JobCP |-> "C", RunCJ |-> "F", TaskCJ |-> "C", Trainer |-> "C", PaySrc |-> "C", PayRcv |-> "C", CommSJ |-> "C", WfSJ |-> "C", Net |-> "R"]
MCSiteGrain == [g \in {} |-> 0]
MCFaults == {"cjCrash", "abort", "outcomeReportFail", "deployError", "launchError", "storeError", "rpcTimeout", "outcomeTimeout", "archiveError", "admissionError", "resExpiry"}
MCSym == Permutations(Sites)

SJDownSP == pJobSP.sjKilled \/ SJGone
OutcomePrecedenceAndPolicy ==
    pJobSP.terminal = "FINISHED" =>
        /\ SJDownSP
        /\ \A c \in Sites : pJobSP.outcomes[c] \notin {"failed", "aborted"}
ReservationOwnership == \A c \in Sites :
    pJobCP[c].freed > 0 =>
        /\ MsgKey("RESOURCES_OK", CP(c), SP, <<JobId, c>>) \in DOMAIN net
        /\ MsgKey("START_JOB", SP, CP(c), <<JobId, c>>) \in DOMAIN net
        /\ pJobCP[c].freed <= 1
JobCPSeed == JobCP_F!SeedInv
JobSPSeed == JobSP_F!SeedInv
JobCPHunt == JobCP_F!SeedHuntInv
JobSPHunt == JobSP_F!SeedHuntInv
TerminalStatusStable ==
    [][pJobSP.status \in JobTerminalStatuses => pJobSP.status' = pJobSP.status]_pJobSP
AbortBlocksRestart ==
    [][\A c \in Sites : pJobCP[c].killed /= {} => pJobCP[c].launch' = pJobCP[c].launch]_pJobCP

====
