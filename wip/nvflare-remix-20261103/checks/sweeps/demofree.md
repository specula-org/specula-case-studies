# Sweep demofree

strategy=list profiles=mixed=cjCrash,taskTimeout,abort sites=2 mode=sim timeout=150s; wall 150s

| run | grain | result | violated | distinct | depth | s |
|---|---|---|---|---:|---:|---:|
| demofree_CCCCCCCCCR_mixed_s2 | all-coarse | budget_stopped |  |  |  | 150.3 |
| demofree_CFCFCFCFCR_mixed_s2 | JobCP=F,TaskCJ=F,PaySrc=F,CommSJ=F | budget_stopped |  |  |  | 150.4 |
| demofree_CFs1Fs2Fs1Fs2Fs1FCFR_mixed_s2 | JobCP=F@s1,RunCJ=F@s2,TaskCJ=F@s1,Trainer=F@s2,PaySrc=F@s1,PayRcv=F,WfSJ=F | budget_stopped |  |  |  | 150.2 |
| demofree_FCFCFCFCFL_mixed_s2 | JobSP=F,RunCJ=F,Trainer=F,PayRcv=F,WfSJ=F,Net=L | budget_stopped |  |  |  | 150.3 |
| demofree_FCFs1CFs1Fs2CFCL_mixed_s2 | JobSP=F,RunCJ=F@s1,Trainer=F@s1,PaySrc=F@s2,CommSJ=F,Net=L | budget_stopped |  |  |  | 150.3 |
| demofree_FFFFFFFFFR_mixed_s2 | JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F | budget_stopped |  |  |  | 150.3 |
