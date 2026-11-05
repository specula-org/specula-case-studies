# Sweep final_cover2

strategy=cover:2 profiles=crash=cjCrash,taskTimeout sites=2 mode=sim timeout=150s; wall 451s

| run | grain | result | violated | distinct | depth | s |
|---|---|---|---|---:|---:|---:|
| final_cover2_CFFs1FFFFs2CCL_crash_s2 | JobCP=F,RunCJ=F@s1,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F@s2,Net=L | budget_stopped |  |  |  | 150.2 |
| final_cover2_CFs1CFs1Fs2CFs1CFR_crash_s2 | JobCP=F@s1,TaskCJ=F@s1,Trainer=F@s2,PayRcv=F@s1,WfSJ=F | budget_stopped |  |  |  | 150.2 |
| final_cover2_CFs1FFs1Fs1FFs1CCR_crash_s2 | JobCP=F@s1,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,PaySrc=F,PayRcv=F@s1 | budget_stopped |  |  |  | 150.2 |
| final_cover2_CFs1Fs2CFs2Fs1Fs1FCL_crash_s2 | JobCP=F@s1,RunCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 150.2 |
| final_cover2_CFs2CFs1FCFFCR_crash_s2 | JobCP=F@s2,TaskCJ=F@s1,Trainer=F,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 150.2 |
| final_cover2_FCCFs2Fs1Fs2FFCR_crash_s2 | JobSP=F,TaskCJ=F@s2,Trainer=F@s1,PaySrc=F@s2,PayRcv=F,CommSJ=F | budget_stopped |  |  |  | 150.2 |
| final_cover2_FCFs1Fs2Fs2Fs1Fs1FCL_crash_s2 | JobSP=F,RunCJ=F@s1,TaskCJ=F@s2,Trainer=F@s2,PaySrc=F@s1,PayRcv=F@s1,CommSJ=F,Net=L | budget_stopped |  |  |  | 150.2 |
| final_cover2_FFs1FFs2CFFs2CFL_crash_s2 | JobSP=F,JobCP=F@s1,RunCJ=F,TaskCJ=F@s2,PaySrc=F,PayRcv=F@s2,WfSJ=F,Net=L | budget_stopped |  |  |  | 150.2 |
| final_cover2_FFs2CFs2Fs2CCFFL_crash_s2 | JobSP=F,JobCP=F@s2,TaskCJ=F@s2,Trainer=F@s2,CommSJ=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 150.2 |
| final_cover2_FFs2FFs1Fs1CCCFR_crash_s2 | JobSP=F,JobCP=F@s2,RunCJ=F,TaskCJ=F@s1,Trainer=F@s1,WfSJ=F | budget_stopped |  |  |  | 150.2 |
