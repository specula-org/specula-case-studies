# Sweep sim100c

strategy=cover:2 profiles=none=;crash=cjCrash,sjCrash;cfg=taskTimeout,resultWaitTimeout;admin=abort,abortCmdError,outcomeReportFail;errors=prepFail,cbFail,payProduce,payConsumer,deployError,launchError,storeError;mixed=cjCrash,taskTimeout,abort,cbFail,slowSJTeardown,slowAdminStop sites=2 mode=sim timeout=180s; wall 5407s

| run | grain | result | violated | distinct | depth | s |
|---|---|---|---|---:|---:|---:|
| sim100c_CCFCFs2Fs2CCCR_admin_s2 | RunCJ=F,Trainer=F@s2,PaySrc=F@s2 | budget_stopped |  |  |  | 180.2 |
| sim100c_CCFCFs2Fs2CCCR_cfg_s2 | RunCJ=F,Trainer=F@s2,PaySrc=F@s2 | budget_stopped |  |  |  | 180.2 |
| sim100c_CCFCFs2Fs2CCCR_crash_s2 | RunCJ=F,Trainer=F@s2,PaySrc=F@s2 | budget_stopped |  |  |  | 180.2 |
| sim100c_CCFCFs2Fs2CCCR_errors_s2 | RunCJ=F,Trainer=F@s2,PaySrc=F@s2 | budget_stopped |  |  |  | 180.2 |
| sim100c_CCFCFs2Fs2CCCR_mixed_s2 | RunCJ=F,Trainer=F@s2,PaySrc=F@s2 | budget_stopped |  |  |  | 180.3 |
| sim100c_CCFCFs2Fs2CCCR_none_s2 | RunCJ=F,Trainer=F@s2,PaySrc=F@s2 | budget_stopped |  |  |  | 180.2 |
| sim100c_CFFs1FFCCCCL_admin_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_CFFs1FFCCCCL_cfg_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,Net=L | budget_stopped |  |  |  | 180.1 |
| sim100c_CFFs1FFCCCCL_crash_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,Net=L | budget_stopped |  |  |  | 180.3 |
| sim100c_CFFs1FFCCCCL_errors_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,Net=L | budget_stopped |  |  |  | 180.1 |
| sim100c_CFFs1FFCCCCL_mixed_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,Net=L | budget_stopped |  |  |  | 180.1 |
| sim100c_CFFs1FFCCCCL_none_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,Net=L | budget_stopped |  |  |  | 180.3 |
| sim100c_CFs1CFs1Fs2FFFFL_admin_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.3 |
| sim100c_CFs1CFs1Fs2FFFFL_cfg_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_CFs1CFs1Fs2FFFFL_crash_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_CFs1CFs1Fs2FFFFL_errors_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_CFs1CFs1Fs2FFFFL_mixed_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.3 |
| sim100c_CFs1CFs1Fs2FFFFL_none_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.3 |
| sim100c_CFs1Fs2Fs2Fs1Fs2CFFL_admin_s2 | JobCP=F@s1,RunCJ=F@s2,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.3 |
| sim100c_CFs1Fs2Fs2Fs1Fs2CFFL_cfg_s2 | JobCP=F@s1,RunCJ=F@s2,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_CFs1Fs2Fs2Fs1Fs2CFFL_crash_s2 | JobCP=F@s1,RunCJ=F@s2,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_CFs1Fs2Fs2Fs1Fs2CFFL_errors_s2 | JobCP=F@s1,RunCJ=F@s2,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_CFs1Fs2Fs2Fs1Fs2CFFL_mixed_s2 | JobCP=F@s1,RunCJ=F@s2,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.3 |
| sim100c_CFs1Fs2Fs2Fs1Fs2CFFL_none_s2 | JobCP=F@s1,RunCJ=F@s2,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FCCCFs1CFFCL_admin_s2 | JobSP=F,Trainer=F@s1,PayRcv=F,CommSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FCCCFs1CFFCL_cfg_s2 | JobSP=F,Trainer=F@s1,PayRcv=F,CommSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FCCCFs1CFFCL_crash_s2 | JobSP=F,Trainer=F@s1,PayRcv=F,CommSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FCCCFs1CFFCL_errors_s2 | JobSP=F,Trainer=F@s1,PayRcv=F,CommSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FCCCFs1CFFCL_mixed_s2 | JobSP=F,Trainer=F@s1,PayRcv=F,CommSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FCCCFs1CFFCL_none_s2 | JobSP=F,Trainer=F@s1,PayRcv=F,CommSJ=F,Net=L | budget_stopped |  |  |  | 180.3 |
| sim100c_FCFs2CCFFCFR_admin_s2 | JobSP=F,RunCJ=F@s2,PaySrc=F,PayRcv=F,WfSJ=F | budget_stopped |  |  |  | 180.2 |
| sim100c_FCFs2CCFFCFR_cfg_s2 | JobSP=F,RunCJ=F@s2,PaySrc=F,PayRcv=F,WfSJ=F | budget_stopped |  |  |  | 180.2 |
| sim100c_FCFs2CCFFCFR_crash_s2 | JobSP=F,RunCJ=F@s2,PaySrc=F,PayRcv=F,WfSJ=F | budget_stopped |  |  |  | 180.2 |
| sim100c_FCFs2CCFFCFR_errors_s2 | JobSP=F,RunCJ=F@s2,PaySrc=F,PayRcv=F,WfSJ=F | budget_stopped |  |  |  | 180.1 |
| sim100c_FCFs2CCFFCFR_mixed_s2 | JobSP=F,RunCJ=F@s2,PaySrc=F,PayRcv=F,WfSJ=F | budget_stopped |  |  |  | 180.1 |
| sim100c_FCFs2CCFFCFR_none_s2 | JobSP=F,RunCJ=F@s2,PaySrc=F,PayRcv=F,WfSJ=F | budget_stopped |  |  |  | 180.3 |
| sim100c_FFFs2FFs1Fs1FFFR_admin_s2 | JobSP=F,JobCP=F,RunCJ=F@s2,TaskCJ=F,Trainer=F@s1,PaySrc=F@s1,PayRcv=F,CommSJ=F,WfSJ=F | budget_stopped |  |  |  | 180.1 |
| sim100c_FFFs2FFs1Fs1FFFR_cfg_s2 | JobSP=F,JobCP=F,RunCJ=F@s2,TaskCJ=F,Trainer=F@s1,PaySrc=F@s1,PayRcv=F,CommSJ=F,WfSJ=F | budget_stopped |  |  |  | 180.2 |
| sim100c_FFFs2FFs1Fs1FFFR_crash_s2 | JobSP=F,JobCP=F,RunCJ=F@s2,TaskCJ=F,Trainer=F@s1,PaySrc=F@s1,PayRcv=F,CommSJ=F,WfSJ=F | budget_stopped |  |  |  | 180.2 |
| sim100c_FFFs2FFs1Fs1FFFR_errors_s2 | JobSP=F,JobCP=F,RunCJ=F@s2,TaskCJ=F,Trainer=F@s1,PaySrc=F@s1,PayRcv=F,CommSJ=F,WfSJ=F | budget_stopped |  |  |  | 180.1 |
| sim100c_FFFs2FFs1Fs1FFFR_mixed_s2 | JobSP=F,JobCP=F,RunCJ=F@s2,TaskCJ=F,Trainer=F@s1,PaySrc=F@s1,PayRcv=F,CommSJ=F,WfSJ=F | budget_stopped |  |  |  | 180.2 |
| sim100c_FFFs2FFs1Fs1FFFR_none_s2 | JobSP=F,JobCP=F,RunCJ=F@s2,TaskCJ=F,Trainer=F@s1,PaySrc=F@s1,PayRcv=F,CommSJ=F,WfSJ=F | budget_stopped |  |  |  | 180.2 |
| sim100c_FFs2FFs2Fs1Fs2FCCL_admin_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FFs2FFs2Fs1Fs2FCCL_cfg_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FFs2FFs2Fs1Fs2FCCL_crash_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FFs2FFs2Fs1Fs2FCCL_errors_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FFs2FFs2Fs1Fs2FCCL_mixed_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FFs2FFs2Fs1Fs2FCCL_none_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FFs2Fs1FFs2FCFFL_admin_s2 | JobSP=F,JobCP=F@s2,RunCJ=F@s1,TaskCJ=F,Trainer=F@s2,PaySrc=F,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FFs2Fs1FFs2FCFFL_cfg_s2 | JobSP=F,JobCP=F@s2,RunCJ=F@s1,TaskCJ=F,Trainer=F@s2,PaySrc=F,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.3 |
| sim100c_FFs2Fs1FFs2FCFFL_crash_s2 | JobSP=F,JobCP=F@s2,RunCJ=F@s1,TaskCJ=F,Trainer=F@s2,PaySrc=F,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.3 |
| sim100c_FFs2Fs1FFs2FCFFL_errors_s2 | JobSP=F,JobCP=F@s2,RunCJ=F@s1,TaskCJ=F,Trainer=F@s2,PaySrc=F,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FFs2Fs1FFs2FCFFL_mixed_s2 | JobSP=F,JobCP=F@s2,RunCJ=F@s1,TaskCJ=F,Trainer=F@s2,PaySrc=F,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FFs2Fs1FFs2FCFFL_none_s2 | JobSP=F,JobCP=F@s2,RunCJ=F@s1,TaskCJ=F,Trainer=F@s2,PaySrc=F,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 180.2 |
| sim100c_FFs2Fs1Fs1Fs2Fs1FFCR_admin_s2 | JobSP=F,JobCP=F@s2,RunCJ=F@s1,TaskCJ=F@s1,Trainer=F@s2,PaySrc=F@s1,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 180.3 |
| sim100c_FFs2Fs1Fs1Fs2Fs1FFCR_cfg_s2 | JobSP=F,JobCP=F@s2,RunCJ=F@s1,TaskCJ=F@s1,Trainer=F@s2,PaySrc=F@s1,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 180.3 |
| sim100c_FFs2Fs1Fs1Fs2Fs1FFCR_crash_s2 | JobSP=F,JobCP=F@s2,RunCJ=F@s1,TaskCJ=F@s1,Trainer=F@s2,PaySrc=F@s1,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 180.3 |
| sim100c_FFs2Fs1Fs1Fs2Fs1FFCR_errors_s2 | JobSP=F,JobCP=F@s2,RunCJ=F@s1,TaskCJ=F@s1,Trainer=F@s2,PaySrc=F@s1,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 180.3 |
| sim100c_FFs2Fs1Fs1Fs2Fs1FFCR_mixed_s2 | JobSP=F,JobCP=F@s2,RunCJ=F@s1,TaskCJ=F@s1,Trainer=F@s2,PaySrc=F@s1,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 180.3 |
| sim100c_FFs2Fs1Fs1Fs2Fs1FFCR_none_s2 | JobSP=F,JobCP=F@s2,RunCJ=F@s1,TaskCJ=F@s1,Trainer=F@s2,PaySrc=F@s1,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 180.3 |
