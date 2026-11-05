# Scenario campaign summary

transfer = a pass in this mix implies a pass in all-fine (every coarse group has an exhaustive receipt for this exact instance); otherwise the missing groups are listed.

| run | scenario | fine groups | faults | result | violated | distinct | depth | wall s | transfer |
|---|---|---|---|---|---|---:|---:|---:|---|
| cmp_AG1_s1 | AG1 discharge AG_Trainer: all-coarse |  | cjCrash,taskTimeout | budget_stopped |  |  |  | 120.4 | missing: JobSP,JobCP,RunCJ,TaskCJ,Trainer,PaySrc,PayRcv,CommSJ,WfSJ |
| cmp_AG2_s1 | AG2 discharge AG_Trainer: TaskCJ fine (executor fine) | TaskCJ=F | cjCrash,taskTimeout | budget_stopped |  |  |  | 120.5 | missing: JobSP,JobCP,RunCJ,Trainer,PaySrc,PayRcv,CommSJ,WfSJ |
| cmp_AG3_s1 | AG3 discharge AG_Trainer: all fine | JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F | cjCrash,taskTimeout | budget_stopped |  |  |  | 150.2 | yes |
| cmp_F00w_s1 | F00w witness: job can finish (all-coarse, sim) |  |  | violation | NotJobFinished |  |  | 3.2 | missing: JobSP,JobCP,RunCJ,TaskCJ,Trainer,PaySrc,PayRcv,CommSJ,WfSJ |
| cmp_F10all_s1 | F10all S10/H30 ALL groups fine | JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F | taskTimeout | error |  |  |  | 195.0 | yes |
| cmp_F10c_s1 | F10c S10/H30 all-coarse screen |  | taskTimeout | violation | NoSJDeathAfterWorkflowDone |  |  | 3.3 | missing: JobSP,JobCP,RunCJ,TaskCJ,Trainer,PaySrc,PayRcv,CommSJ,WfSJ |
| cmp_F10f_s1 | F10f S10/H30 five fine groups (payload+job runner+fed W | RunCJ=F,TaskCJ=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F | taskTimeout | violation | NoSJDeathAfterWorkflowDone |  |  | 5.3 | missing: JobSP,JobCP,Trainer |
| cmp_F10p_s1 | F10p S10/H30 payload fine, rest coarse | PaySrc=F,PayRcv=F | taskTimeout | error |  |  |  | 19.1 | missing: JobSP,JobCP,RunCJ,TaskCJ,Trainer,CommSJ,WfSJ |
| cmp_F10s_s2 | F10s S10/H30 2 sites, minClients, saved model then stra | TaskCJ=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F | minClients | budget_stopped |  |  |  | 300.3 | missing: JobSP,JobCP,RunCJ,Trainer |
| cmp_F22_s1 | F22 job lifecycle fine with faults (sim) | JobSP=F,JobCP=F,RunCJ=F | abort,cjCrash,outcomeReportFail | budget_stopped |  |  |  | 240.5 | missing: TaskCJ,Trainer,PaySrc,PayRcv,CommSJ,WfSJ |
| cmp_S02r2_s1 | S02r2 H02 send() tail clears successor input, Rounds=2 ( | TaskCJ=F,Trainer=F |  | violation | SuccessorInputPreserved | 13514 | 58 | 10.2 | missing: JobSP,JobCP,RunCJ,PaySrc,PayRcv,CommSJ,WfSJ |
| cmp_S02r2z_s1 | S02r2z H02, Rounds=2, zoom-in: CommSJ fine too (no coarse | TaskCJ=F,Trainer=F,CommSJ=F |  | violation | SuccessorInputPreserved | 90534 | 92 | 37.8 | missing: JobSP,JobCP,RunCJ,PaySrc,PayRcv,WfSJ |
| cmp_T1off2_s1 | T1off2 H30 all fine, T1 timing assumption ON (default) | JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F | taskTimeout | budget_stopped |  |  |  | 300.5 | yes |
| cmp_T1off_s1 | T1off H30 all fine, default timing (T1 on) | JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F | taskTimeout | budget_stopped |  |  |  | 300.4 | yes |
| cmp_T1offc_s1 | T1offc H30 all coarse, default timing |  | taskTimeout | violation | NoPayFatalAfterDoneP |  |  | 5.9 | missing: JobSP,JobCP,RunCJ,TaskCJ,Trainer,PaySrc,PayRcv,CommSJ,WfSJ |
| cmp_T1on2_s1 | T1on2 H30 all fine, slowSJTeardown (T1 released) | JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F | taskTimeout,slowSJTeardown | budget_stopped |  |  |  | 300.5 | yes |
| cmp_T1on_s1 | T1on H30 all fine, slowSJTeardown (T1 released) | JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F | taskTimeout,slowSJTeardown | budget_stopped |  |  |  | 300.4 | yes |
