# Sweep bfs1b

strategy=one-fine profiles=none=;crash=cjCrash;sjcrash=sjCrash;tasktimeout=taskTimeout;abort=abort;loss=netLoss sites=1 mode=bfs timeout=300s; wall 3157s

| run | grain | result | violated | distinct | depth | s |
|---|---|---|---|---:|---:|---:|
| bfs1b_CCCCCCCCCL_abort_s1 | Net=L | violation | GFinishedNoAbnormalExit | 77654 | 22 | 14.3 |
| bfs1b_CCCCCCCCCL_crash_s1 | Net=L | violation | Deadlock | 791757 | 26 | 104.4 |
| bfs1b_CCCCCCCCCL_loss_s1 | Net=L | budget_stopped |  | 1730711 |  | 300.6 |
| bfs1b_CCCCCCCCCL_none_s1 | Net=L | violation | Deadlock | 202302 | 27 | 39.2 |
| bfs1b_CCCCCCCCCL_sjcrash_s1 | Net=L | budget_stopped |  | 1498935 |  | 300.8 |
| bfs1b_CCCCCCCCCL_tasktimeout_s1 | Net=L | violation | GFinishedNoLiveChild | 446832 | 29 | 83.9 |
| bfs1b_CCCCCCCCCR_abort_s1 | all-coarse | violation | GFinishedNoAbnormalExit | 69349 | 21 | 21.4 |
| bfs1b_CCCCCCCCCR_crash_s1 | all-coarse | violation | Deadlock | 663416 | 25 | 150.6 |
| bfs1b_CCCCCCCCCR_loss_s1 | all-coarse | violation | Deadlock | 271773 | 27 | 87.5 |
| bfs1b_CCCCCCCCCR_none_s1 | all-coarse | violation | Deadlock | 202391 | 28 | 66.4 |
| bfs1b_CCCCCCCCCR_sjcrash_s1 | all-coarse | budget_stopped |  | 830674 |  | 300.8 |
| bfs1b_CCCCCCCCCR_tasktimeout_s1 | all-coarse | violation | GFinishedNoLiveChild | 512367 | 29 | 165.8 |
| bfs1b_CCCCCCCCFR_abort_s1 | WfSJ=F | violation | GFinishedNoLiveChild | 84142 | 22 | 26.5 |
| bfs1b_CCCCCCCCFR_crash_s1 | WfSJ=F | budget_stopped |  | 1015787 |  | 300.7 |
| bfs1b_CCCCCCCCFR_loss_s1 | WfSJ=F | violation | Deadlock | 777244 | 31 | 181.4 |
| bfs1b_CCCCCCCCFR_none_s1 | WfSJ=F | violation | Deadlock | 445148 | 30 | 155.7 |
| bfs1b_CCCCCCCCFR_sjcrash_s1 | WfSJ=F | budget_stopped |  | 910211 |  | 300.7 |
| bfs1b_CCCCCCCCFR_tasktimeout_s1 | WfSJ=F | budget_stopped |  | 820726 |  | 300.8 |
| bfs1b_CCCCCCCFCR_abort_s1 | CommSJ=F | violation | GFinishedNoAbnormalExit | 69124 | 21 | 23.2 |
| bfs1b_CCCCCCCFCR_crash_s1 | CommSJ=F | violation | Deadlock | 908687 | 26 | 245.0 |
| bfs1b_CCCCCCCFCR_loss_s1 | CommSJ=F | budget_stopped |  | 679136 |  | 300.8 |
| bfs1b_CCCCCCCFCR_none_s1 | CommSJ=F | budget_stopped |  | 664117 |  | 300.8 |
| bfs1b_CCCCCCCFCR_sjcrash_s1 | CommSJ=F | budget_stopped |  | 818780 |  | 300.8 |
| bfs1b_CCCCCCCFCR_tasktimeout_s1 | CommSJ=F | budget_stopped |  | 740106 |  | 300.9 |
| bfs1b_CCCCCCFCCR_abort_s1 | PayRcv=F | violation | GFinishedNoLiveChild | 69084 | 21 | 20.7 |
| bfs1b_CCCCCCFCCR_crash_s1 | PayRcv=F | violation | Deadlock | 665130 | 25 | 143.1 |
| bfs1b_CCCCCCFCCR_loss_s1 | PayRcv=F | violation | Deadlock | 271806 | 28 | 82.7 |
| bfs1b_CCCCCCFCCR_none_s1 | PayRcv=F | violation | Deadlock | 202298 | 27 | 62.5 |
| bfs1b_CCCCCCFCCR_sjcrash_s1 | PayRcv=F | budget_stopped |  | 860005 |  | 300.9 |
| bfs1b_CCCCCCFCCR_tasktimeout_s1 | PayRcv=F | violation | GFinishedNoLiveChild | 442608 | 29 | 129.0 |
| bfs1b_CCCCCFCCCR_abort_s1 | PaySrc=F | violation | GFinishedNoAbnormalExit | 69183 | 21 | 22.8 |
| bfs1b_CCCCCFCCCR_crash_s1 | PaySrc=F | violation | Deadlock | 659447 | 25 | 166.1 |
| bfs1b_CCCCCFCCCR_loss_s1 | PaySrc=F | violation | Deadlock | 271655 | 27 | 99.0 |
| bfs1b_CCCCCFCCCR_none_s1 | PaySrc=F | violation | Deadlock | 252584 | 28 | 88.3 |
| bfs1b_CCCCCFCCCR_sjcrash_s1 | PaySrc=F | budget_stopped |  | 763673 |  | 300.9 |
| bfs1b_CCCCCFCCCR_tasktimeout_s1 | PaySrc=F | violation | GFinishedNoLiveChild | 419260 | 29 | 140.1 |
| bfs1b_CCCCFCCCCR_abort_s1 | Trainer=F | violation | GFinishedNoAbnormalExit | 81833 | 21 | 22.4 |
| bfs1b_CCCCFCCCCR_crash_s1 | Trainer=F | violation | Deadlock | 954935 | 26 | 206.5 |
| bfs1b_CCCCFCCCCR_loss_s1 | Trainer=F | violation | Deadlock | 535386 | 28 | 168.4 |
| bfs1b_CCCCFCCCCR_none_s1 | Trainer=F | violation | Deadlock | 406428 | 29 | 129.7 |
| bfs1b_CCCCFCCCCR_sjcrash_s1 | Trainer=F | budget_stopped |  | 871106 |  | 300.9 |
| bfs1b_CCCCFCCCCR_tasktimeout_s1 | Trainer=F | violation | GFinishedNoLiveChild | 705547 | 29 | 218.0 |
| bfs1b_CCCFCCCCCR_abort_s1 | TaskCJ=F | violation | GFinishedNoAbnormalExit | 80548 | 22 | 26.7 |
| bfs1b_CCCFCCCCCR_crash_s1 | TaskCJ=F | violation | Deadlock | 688712 | 25 | 175.7 |
| bfs1b_CCCFCCCCCR_loss_s1 | TaskCJ=F | budget_stopped |  | 633373 |  | 300.8 |
| bfs1b_CCCFCCCCCR_none_s1 | TaskCJ=F | violation | Deadlock | 500412 | 31 | 185.3 |
| bfs1b_CCCFCCCCCR_sjcrash_s1 | TaskCJ=F | budget_stopped |  | 743925 |  | 300.8 |
| bfs1b_CCCFCCCCCR_tasktimeout_s1 | TaskCJ=F | violation | GFinishedNoLiveChild | 440366 | 29 | 149.5 |
| bfs1b_CCFCCCCCCR_abort_s1 | RunCJ=F | violation | GFinishedNoLiveChild | 40784 | 22 | 14.7 |
| bfs1b_CCFCCCCCCR_crash_s1 | RunCJ=F | violation | Deadlock | 197089 | 25 | 53.1 |
| bfs1b_CCFCCCCCCR_loss_s1 | RunCJ=F | violation | Deadlock | 163773 | 31 | 60.8 |
| bfs1b_CCFCCCCCCR_none_s1 | RunCJ=F | violation | Deadlock | 106492 | 31 | 41.1 |
| bfs1b_CCFCCCCCCR_sjcrash_s1 | RunCJ=F | budget_stopped |  | 725536 |  | 301.0 |
| bfs1b_CCFCCCCCCR_tasktimeout_s1 | RunCJ=F | violation | GFinishedNoLiveChild | 128734 | 29 | 43.8 |
| bfs1b_CFCCCCCCCR_abort_s1 | JobCP=F | violation | GFinishedNoLiveChild | 342711 | 28 | 110.8 |
| bfs1b_CFCCCCCCCR_crash_s1 | JobCP=F | budget_stopped |  | 859163 |  | 300.7 |
| bfs1b_CFCCCCCCCR_loss_s1 | JobCP=F | budget_stopped |  | 695854 |  | 300.7 |
| bfs1b_CFCCCCCCCR_none_s1 | JobCP=F | budget_stopped |  | 684333 |  | 300.8 |
| bfs1b_CFCCCCCCCR_sjcrash_s1 | JobCP=F | budget_stopped |  | 750053 |  | 300.7 |
| bfs1b_CFCCCCCCCR_tasktimeout_s1 | JobCP=F | budget_stopped |  | 709696 |  | 300.9 |
| bfs1b_FCCCCCCCCR_abort_s1 | JobSP=F | violation | GFinishedNoAbnormalExit | 948050 | 41 | 264.8 |
| bfs1b_FCCCCCCCCR_crash_s1 | JobSP=F | budget_stopped |  | 1064846 |  | 300.9 |
| bfs1b_FCCCCCCCCR_loss_s1 | JobSP=F | budget_stopped |  | 818148 |  | 300.8 |
| bfs1b_FCCCCCCCCR_none_s1 | JobSP=F | budget_stopped |  | 783036 |  | 300.8 |
| bfs1b_FCCCCCCCCR_sjcrash_s1 | JobSP=F | budget_stopped |  | 908512 |  | 300.7 |
| bfs1b_FCCCCCCCCR_tasktimeout_s1 | JobSP=F | budget_stopped |  | 774887 |  | 300.9 |
