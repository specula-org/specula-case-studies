# Sweep blind2

strategy=cover:2 profiles=none=;crash=cjCrash,sjCrash;timeouts=taskTimeout,submitTimeout,pullTimeout,txTimeout,rpcTimeout,resultWaitTimeout;admin=abort,outcomeReportFail,resExpiry,outcomeTimeout;errors=prepFail,cbFail,payProduce,payConsumer,deployError,launchError,storeError;mixed=cjCrash,taskTimeout,abort,pullTimeout,cbFail,slowSJTeardown sites=2 mode=sim timeout=180s; wall 1647s

| run | grain | result | violated | distinct | depth | s |
|---|---|---|---|---:|---:|---:|
| blind2_CFFs1FFFFs2CCL_admin_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F@s2,Net=L | violation | GTerminalNoLiveSJ |  |  | 3.1 |
| blind2_CFFs1FFFFs2CCL_crash_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F@s2,Net=L | violation | GStatusStable |  |  | 3.4 |
| blind2_CFFs1FFFFs2CCL_errors_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F@s2,Net=L | budget_stopped |  |  |  | 180.1 |
| blind2_CFFs1FFFFs2CCL_mixed_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F@s2,Net=L | error |  |  |  | 9.8 |
| blind2_CFFs1FFFFs2CCL_none_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F@s2,Net=L | budget_stopped |  |  |  | 180.1 |
| blind2_CFFs1FFFFs2CCL_timeouts_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F@s2,Net=L | budget_stopped |  |  |  | 180.1 |
| blind2_CFs1CFs1Fs2CFs1CFR_admin_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PayRcv=F@s1,WfSJ=F | violation | GTerminalNoLiveSJ |  |  | 3.0 |
| blind2_CFs1CFs1Fs2CFs1CFR_crash_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PayRcv=F@s1,WfSJ=F | violation | GStatusStable |  |  | 3.2 |
| blind2_CFs1CFs1Fs2CFs1CFR_errors_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PayRcv=F@s1,WfSJ=F | violation | GTerminalNoLiveSJ |  |  | 18.8 |
| blind2_CFs1CFs1Fs2CFs1CFR_mixed_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PayRcv=F@s1,WfSJ=F | error |  |  |  | 3.5 |
| blind2_CFs1CFs1Fs2CFs1CFR_none_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PayRcv=F@s1,WfSJ=F | budget_stopped |  |  |  | 180.1 |
| blind2_CFs1CFs1Fs2CFs1CFR_timeouts_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PayRcv=F@s1,WfSJ=F | violation | GTerminalNoLiveSJ |  |  | 82.7 |
| blind2_CFs1FFs1Fs1FFs1CCR_admin_s2 | JobCP=F@s1,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,PaySrc=F,PayRcv=F@s1 | violation | GTerminalNoLiveSJ |  |  | 31.3 |
| blind2_CFs1FFs1Fs1FFs1CCR_crash_s2 | JobCP=F@s1,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,PaySrc=F,PayRcv=F@s1 | violation | GStatusStable |  |  | 5.7 |
| blind2_CFs1FFs1Fs1FFs1CCR_errors_s2 | JobCP=F@s1,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,PaySrc=F,PayRcv=F@s1 | budget_stopped |  |  |  | 180.2 |
| blind2_CFs1FFs1Fs1FFs1CCR_mixed_s2 | JobCP=F@s1,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,PaySrc=F,PayRcv=F@s1 | error |  |  |  | 47.4 |
| blind2_CFs1FFs1Fs1FFs1CCR_none_s2 | JobCP=F@s1,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,PaySrc=F,PayRcv=F@s1 | budget_stopped |  |  |  | 180.1 |
| blind2_CFs1FFs1Fs1FFs1CCR_timeouts_s2 | JobCP=F@s1,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,PaySrc=F,PayRcv=F@s1 | budget_stopped |  |  |  | 180.3 |
| blind2_CFs1Fs2CFs2Fs1Fs1FCL_admin_s2 | JobCP=F@s1,RunCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | violation | GTerminalNoLiveSJ |  |  | 4.9 |
| blind2_CFs1Fs2CFs2Fs1Fs1FCL_crash_s2 | JobCP=F@s1,RunCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | violation | GStatusStable |  |  | 5.5 |
| blind2_CFs1Fs2CFs2Fs1Fs1FCL_errors_s2 | JobCP=F@s1,RunCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| blind2_CFs1Fs2CFs2Fs1Fs1FCL_mixed_s2 | JobCP=F@s1,RunCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | violation | GTerminalNoLiveSJ |  |  | 6.1 |
| blind2_CFs1Fs2CFs2Fs1Fs1FCL_none_s2 | JobCP=F@s1,RunCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 180.3 |
| blind2_CFs1Fs2CFs2Fs1Fs1FCL_timeouts_s2 | JobCP=F@s1,RunCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | violation | GTerminalNoLiveSJ |  |  | 125.2 |
| blind2_CFs2CFs1FCFFCR_admin_s2 | JobCP=F@s2,TaskCJ=F@s1,Trainer=F,PayRcv=F,CommSJ=F | violation | GTerminalNoLiveSJ |  |  | 3.7 |
| blind2_CFs2CFs1FCFFCR_crash_s2 | JobCP=F@s2,TaskCJ=F@s1,Trainer=F,PayRcv=F,CommSJ=F | violation | GStatusStable |  |  | 13.4 |
| blind2_CFs2CFs1FCFFCR_errors_s2 | JobCP=F@s2,TaskCJ=F@s1,Trainer=F,PayRcv=F,CommSJ=F | violation | GNoFreeWhileAlive |  |  | 59.2 |
| blind2_CFs2CFs1FCFFCR_mixed_s2 | JobCP=F@s2,TaskCJ=F@s1,Trainer=F,PayRcv=F,CommSJ=F | violation | GTerminalNoLiveSJ |  |  | 2.6 |
| blind2_CFs2CFs1FCFFCR_none_s2 | JobCP=F@s2,TaskCJ=F@s1,Trainer=F,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 180.2 |
| blind2_CFs2CFs1FCFFCR_timeouts_s2 | JobCP=F@s2,TaskCJ=F@s1,Trainer=F,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 180.4 |
| blind2_FCCFs2Fs1Fs2FFCR_admin_s2 | JobSP=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 180.2 |
| blind2_FCCFs2Fs1Fs2FFCR_crash_s2 | JobSP=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,CommSJ=F | violation | GStatusStable |  |  | 4.8 |
| blind2_FCCFs2Fs1Fs2FFCR_errors_s2 | JobSP=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 180.2 |
| blind2_FCCFs2Fs1Fs2FFCR_mixed_s2 | JobSP=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 180.3 |
| blind2_FCCFs2Fs1Fs2FFCR_none_s2 | JobSP=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 180.2 |
| blind2_FCCFs2Fs1Fs2FFCR_timeouts_s2 | JobSP=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 180.3 |
| blind2_FCFs1Fs2Fs2Fs1Fs1FCL_admin_s2 | JobSP=F,RunCJ=F@s1,TaskCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| blind2_FCFs1Fs2Fs2Fs1Fs1FCL_crash_s2 | JobSP=F,RunCJ=F@s1,TaskCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | violation | GStatusStable |  |  | 3.4 |
| blind2_FCFs1Fs2Fs2Fs1Fs1FCL_errors_s2 | JobSP=F,RunCJ=F@s1,TaskCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| blind2_FCFs1Fs2Fs2Fs1Fs1FCL_mixed_s2 | JobSP=F,RunCJ=F@s1,TaskCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| blind2_FCFs1Fs2Fs2Fs1Fs1FCL_none_s2 | JobSP=F,RunCJ=F@s1,TaskCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | error |  |  |  | 5.3 |
| blind2_FCFs1Fs2Fs2Fs1Fs1FCL_timeouts_s2 | JobSP=F,RunCJ=F@s1,TaskCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| blind2_FFs1FFs2CFFs2CFL_admin_s2 | JobSP=F,JobCP=F@s1,RunCJ=F,TaskCJ=F@s2,PaySrc=F,PayRcv=F@s2,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.3 |
| blind2_FFs1FFs2CFFs2CFL_crash_s2 | JobSP=F,JobCP=F@s1,RunCJ=F,TaskCJ=F@s2,PaySrc=F,PayRcv=F@s2,WfSJ=F,Net=L | violation | GStatusStable |  |  | 7.4 |
| blind2_FFs1FFs2CFFs2CFL_errors_s2 | JobSP=F,JobCP=F@s1,RunCJ=F,TaskCJ=F@s2,PaySrc=F,PayRcv=F@s2,WfSJ=F,Net=L | violation | GNoFreeWhileAlive |  |  | 123.1 |
| blind2_FFs1FFs2CFFs2CFL_mixed_s2 | JobSP=F,JobCP=F@s1,RunCJ=F,TaskCJ=F@s2,PaySrc=F,PayRcv=F@s2,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.3 |
| blind2_FFs1FFs2CFFs2CFL_none_s2 | JobSP=F,JobCP=F@s1,RunCJ=F,TaskCJ=F@s2,PaySrc=F,PayRcv=F@s2,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| blind2_FFs1FFs2CFFs2CFL_timeouts_s2 | JobSP=F,JobCP=F@s1,RunCJ=F,TaskCJ=F@s2,PaySrc=F,PayRcv=F@s2,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.3 |
| blind2_FFs2CFs2Fs2CCFFL_admin_s2 | JobSP=F,JobCP=F@s2,TaskCJ=F@s2,Trainer=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| blind2_FFs2CFs2Fs2CCFFL_crash_s2 | JobSP=F,JobCP=F@s2,TaskCJ=F@s2,Trainer=F@s2,CommSJ=F,WfSJ=F,Net=L | violation | GStatusStable |  |  | 17.6 |
| blind2_FFs2CFs2Fs2CCFFL_errors_s2 | JobSP=F,JobCP=F@s2,TaskCJ=F@s2,Trainer=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.3 |
| blind2_FFs2CFs2Fs2CCFFL_mixed_s2 | JobSP=F,JobCP=F@s2,TaskCJ=F@s2,Trainer=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| blind2_FFs2CFs2Fs2CCFFL_none_s2 | JobSP=F,JobCP=F@s2,TaskCJ=F@s2,Trainer=F@s2,CommSJ=F,WfSJ=F,Net=L | error |  |  |  | 11.6 |
| blind2_FFs2CFs2Fs2CCFFL_timeouts_s2 | JobSP=F,JobCP=F@s2,TaskCJ=F@s2,Trainer=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| blind2_FFs2FFs1Fs1CCCFR_admin_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,WfSJ=F | budget_stopped |  |  |  | 180.3 |
| blind2_FFs2FFs1Fs1CCCFR_crash_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,WfSJ=F | violation | GStatusStable |  |  | 6.7 |
| blind2_FFs2FFs1Fs1CCCFR_errors_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,WfSJ=F | budget_stopped |  |  |  | 180.2 |
| blind2_FFs2FFs1Fs1CCCFR_mixed_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,WfSJ=F | budget_stopped |  |  |  | 180.2 |
| blind2_FFs2FFs1Fs1CCCFR_none_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,WfSJ=F | error |  |  |  | 7.4 |
| blind2_FFs2FFs1Fs1CCCFR_timeouts_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,WfSJ=F | budget_stopped |  |  |  | 180.3 |
