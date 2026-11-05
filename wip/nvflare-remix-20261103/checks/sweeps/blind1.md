# Sweep blind1

strategy=cover:2 profiles=none=;crash=cjCrash,sjCrash;timeouts=taskTimeout,submitTimeout,pullTimeout,txTimeout,rpcTimeout,resultWaitTimeout;admin=abort,outcomeReportFail,resExpiry,outcomeTimeout;errors=prepFail,cbFail,payProduce,payConsumer,deployError,launchError,storeError;mixed=cjCrash,taskTimeout,abort,pullTimeout,cbFail sites=2 mode=sim timeout=150s; wall 1223s

| run | grain | result | violated | distinct | depth | s |
|---|---|---|---|---:|---:|---:|
| blind1_CFFs1FFFFs2CCL_admin_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F@s2,Net=L | violation | GTerminalNoLiveSJ |  |  | 3.8 |
| blind1_CFFs1FFFFs2CCL_crash_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F@s2,Net=L | violation | GStatusStable |  |  | 5.0 |
| blind1_CFFs1FFFFs2CCL_errors_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F@s2,Net=L | budget_stopped |  |  |  | 150.2 |
| blind1_CFFs1FFFFs2CCL_mixed_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F@s2,Net=L | error |  |  |  | 5.7 |
| blind1_CFFs1FFFFs2CCL_none_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F@s2,Net=L | budget_stopped |  |  |  | 150.2 |
| blind1_CFFs1FFFFs2CCL_timeouts_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F@s2,Net=L | violation | GTerminalNoLiveSJ |  |  | 12.5 |
| blind1_CFs1CFs1Fs2CFs1CFR_admin_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PayRcv=F@s1,WfSJ=F | violation | GTerminalNoLiveSJ |  |  | 2.9 |
| blind1_CFs1CFs1Fs2CFs1CFR_crash_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PayRcv=F@s1,WfSJ=F | violation | GStatusStable |  |  | 11.5 |
| blind1_CFs1CFs1Fs2CFs1CFR_errors_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PayRcv=F@s1,WfSJ=F | violation | GTerminalNoLiveSJ |  |  | 78.0 |
| blind1_CFs1CFs1Fs2CFs1CFR_mixed_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PayRcv=F@s1,WfSJ=F | violation | GTerminalNoLiveSJ |  |  | 3.6 |
| blind1_CFs1CFs1Fs2CFs1CFR_none_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PayRcv=F@s1,WfSJ=F | budget_stopped |  |  |  | 150.2 |
| blind1_CFs1CFs1Fs2CFs1CFR_timeouts_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PayRcv=F@s1,WfSJ=F | violation | GTerminalNoLiveSJ |  |  | 97.5 |
| blind1_CFs1FFs1Fs1FFs1CCR_admin_s2 | JobCP=F@s1,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,PaySrc=F,PayRcv=F@s1 | violation | GTerminalNoLiveSJ |  |  | 2.9 |
| blind1_CFs1FFs1Fs1FFs1CCR_crash_s2 | JobCP=F@s1,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,PaySrc=F,PayRcv=F@s1 | violation | GStatusStable |  |  | 3.6 |
| blind1_CFs1FFs1Fs1FFs1CCR_errors_s2 | JobCP=F@s1,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,PaySrc=F,PayRcv=F@s1 | violation | GNoFreeWhileAlive |  |  | 52.2 |
| blind1_CFs1FFs1Fs1FFs1CCR_mixed_s2 | JobCP=F@s1,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,PaySrc=F,PayRcv=F@s1 | violation | GTerminalNoLiveSJ |  |  | 4.5 |
| blind1_CFs1FFs1Fs1FFs1CCR_none_s2 | JobCP=F@s1,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,PaySrc=F,PayRcv=F@s1 | budget_stopped |  |  |  | 150.2 |
| blind1_CFs1FFs1Fs1FFs1CCR_timeouts_s2 | JobCP=F@s1,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,PaySrc=F,PayRcv=F@s1 | budget_stopped |  |  |  | 150.2 |
| blind1_CFs1Fs2CFs2Fs1Fs1FCL_admin_s2 | JobCP=F@s1,RunCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | violation | GTerminalNoLiveSJ |  |  | 4.1 |
| blind1_CFs1Fs2CFs2Fs1Fs1FCL_crash_s2 | JobCP=F@s1,RunCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | violation | GStatusStable |  |  | 4.8 |
| blind1_CFs1Fs2CFs2Fs1Fs1FCL_errors_s2 | JobCP=F@s1,RunCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | violation | GNoFreeWhileAlive |  |  | 97.5 |
| blind1_CFs1Fs2CFs2Fs1Fs1FCL_mixed_s2 | JobCP=F@s1,RunCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | violation | GTerminalNoLiveSJ |  |  | 4.4 |
| blind1_CFs1Fs2CFs2Fs1Fs1FCL_none_s2 | JobCP=F@s1,RunCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 150.1 |
| blind1_CFs1Fs2CFs2Fs1Fs1FCL_timeouts_s2 | JobCP=F@s1,RunCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 150.1 |
| blind1_CFs2CFs1FCFFCR_admin_s2 | JobCP=F@s2,TaskCJ=F@s1,Trainer=F,PayRcv=F,CommSJ=F | violation | GTerminalNoLiveSJ |  |  | 3.4 |
| blind1_CFs2CFs1FCFFCR_crash_s2 | JobCP=F@s2,TaskCJ=F@s1,Trainer=F,PayRcv=F,CommSJ=F | violation | GStatusStable |  |  | 10.9 |
| blind1_CFs2CFs1FCFFCR_errors_s2 | JobCP=F@s2,TaskCJ=F@s1,Trainer=F,PayRcv=F,CommSJ=F | violation | GNoFreeWhileAlive |  |  | 10.6 |
| blind1_CFs2CFs1FCFFCR_mixed_s2 | JobCP=F@s2,TaskCJ=F@s1,Trainer=F,PayRcv=F,CommSJ=F | violation | GTerminalNoLiveSJ |  |  | 3.1 |
| blind1_CFs2CFs1FCFFCR_none_s2 | JobCP=F@s2,TaskCJ=F@s1,Trainer=F,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 150.2 |
| blind1_CFs2CFs1FCFFCR_timeouts_s2 | JobCP=F@s2,TaskCJ=F@s1,Trainer=F,PayRcv=F,CommSJ=F | violation | GTerminalNoLiveSJ |  |  | 67.0 |
| blind1_FCCFs2Fs1Fs2FFCR_admin_s2 | JobSP=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 150.3 |
| blind1_FCCFs2Fs1Fs2FFCR_crash_s2 | JobSP=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,CommSJ=F | violation | GStatusStable |  |  | 14.3 |
| blind1_FCCFs2Fs1Fs2FFCR_errors_s2 | JobSP=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 150.3 |
| blind1_FCCFs2Fs1Fs2FFCR_mixed_s2 | JobSP=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 150.3 |
| blind1_FCCFs2Fs1Fs2FFCR_none_s2 | JobSP=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 150.2 |
| blind1_FCCFs2Fs1Fs2FFCR_timeouts_s2 | JobSP=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,CommSJ=F | violation | GTerminalNoLiveSJ |  |  | 17.4 |
| blind1_FCFs1Fs2Fs2Fs1Fs1FCL_admin_s2 | JobSP=F,RunCJ=F@s1,TaskCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 150.3 |
| blind1_FCFs1Fs2Fs2Fs1Fs1FCL_crash_s2 | JobSP=F,RunCJ=F@s1,TaskCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | violation | GStatusStable |  |  | 5.9 |
| blind1_FCFs1Fs2Fs2Fs1Fs1FCL_errors_s2 | JobSP=F,RunCJ=F@s1,TaskCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 150.2 |
| blind1_FCFs1Fs2Fs2Fs1Fs1FCL_mixed_s2 | JobSP=F,RunCJ=F@s1,TaskCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 150.3 |
| blind1_FCFs1Fs2Fs2Fs1Fs1FCL_none_s2 | JobSP=F,RunCJ=F@s1,TaskCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 150.2 |
| blind1_FCFs1Fs2Fs2Fs1Fs1FCL_timeouts_s2 | JobSP=F,RunCJ=F@s1,TaskCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | violation | GTerminalNoLiveSJ |  |  | 27.1 |
| blind1_FFs1FFs2CFFs2CFL_admin_s2 | JobSP=F,JobCP=F@s1,RunCJ=F,TaskCJ=F@s2,PaySrc=F,PayRcv=F@s2,WfSJ=F,Net=L | budget_stopped |  |  |  | 150.2 |
| blind1_FFs1FFs2CFFs2CFL_crash_s2 | JobSP=F,JobCP=F@s1,RunCJ=F,TaskCJ=F@s2,PaySrc=F,PayRcv=F@s2,WfSJ=F,Net=L | violation | GStatusStable |  |  | 4.6 |
| blind1_FFs1FFs2CFFs2CFL_errors_s2 | JobSP=F,JobCP=F@s1,RunCJ=F,TaskCJ=F@s2,PaySrc=F,PayRcv=F@s2,WfSJ=F,Net=L | budget_stopped |  |  |  | 150.3 |
| blind1_FFs1FFs2CFFs2CFL_mixed_s2 | JobSP=F,JobCP=F@s1,RunCJ=F,TaskCJ=F@s2,PaySrc=F,PayRcv=F@s2,WfSJ=F,Net=L | budget_stopped |  |  |  | 150.2 |
| blind1_FFs1FFs2CFFs2CFL_none_s2 | JobSP=F,JobCP=F@s1,RunCJ=F,TaskCJ=F@s2,PaySrc=F,PayRcv=F@s2,WfSJ=F,Net=L | budget_stopped |  |  |  | 150.2 |
| blind1_FFs1FFs2CFFs2CFL_timeouts_s2 | JobSP=F,JobCP=F@s1,RunCJ=F,TaskCJ=F@s2,PaySrc=F,PayRcv=F@s2,WfSJ=F,Net=L | violation | GTerminalNoLiveSJ |  |  | 8.2 |
| blind1_FFs2CFs2Fs2CCFFL_admin_s2 | JobSP=F,JobCP=F@s2,TaskCJ=F@s2,Trainer=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 150.3 |
| blind1_FFs2CFs2Fs2CCFFL_crash_s2 | JobSP=F,JobCP=F@s2,TaskCJ=F@s2,Trainer=F@s2,CommSJ=F,WfSJ=F,Net=L | violation | GStatusStable |  |  | 5.1 |
| blind1_FFs2CFs2Fs2CCFFL_errors_s2 | JobSP=F,JobCP=F@s2,TaskCJ=F@s2,Trainer=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 150.1 |
| blind1_FFs2CFs2Fs2CCFFL_mixed_s2 | JobSP=F,JobCP=F@s2,TaskCJ=F@s2,Trainer=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 150.3 |
| blind1_FFs2CFs2Fs2CCFFL_none_s2 | JobSP=F,JobCP=F@s2,TaskCJ=F@s2,Trainer=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 150.2 |
| blind1_FFs2CFs2Fs2CCFFL_timeouts_s2 | JobSP=F,JobCP=F@s2,TaskCJ=F@s2,Trainer=F@s2,CommSJ=F,WfSJ=F,Net=L | violation | GTerminalNoLiveSJ |  |  | 8.7 |
| blind1_FFs2FFs1Fs1CCCFR_admin_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,WfSJ=F | budget_stopped |  |  |  | 150.3 |
| blind1_FFs2FFs1Fs1CCCFR_crash_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,WfSJ=F | violation | GStatusStable |  |  | 6.6 |
| blind1_FFs2FFs1Fs1CCCFR_errors_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,WfSJ=F | budget_stopped |  |  |  | 150.2 |
| blind1_FFs2FFs1Fs1CCCFR_mixed_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,WfSJ=F | budget_stopped |  |  |  | 150.2 |
| blind1_FFs2FFs1Fs1CCCFR_none_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,WfSJ=F | budget_stopped |  |  |  | 150.1 |
| blind1_FFs2FFs1Fs1CCCFR_timeouts_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,WfSJ=F | violation | GTerminalNoLiveSJ |  |  | 17.4 |
