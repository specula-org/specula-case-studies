# Sweep gp1

16 cells: {'error': 1, 'violation': 7, 'pass_exhaustive': 2, 'budget_stopped': 6}

| config | point | phase | result | violated | distinct | depth | s |
|---|---|---:|---|---|---:|---:|---:|
| attach | tpReplyLost | 2 | violation | S6AckMeansDone | 54 | 12 | 3.6 |
| cse | netLoss | 2 | budget_stopped |  | 20642 | 12 | 90.2 |
| external | monitorStale | 3 | budget_stopped |  | 33232 | 21 | 90.2 |
| fedavg | cjCrash | 2 | budget_stopped |  | 74484 | 17 | 90.2 |
| fedavg | cjCrash | 5 | budget_stopped |  | 40150 | 17 | 90.2 |
| fedavg | deleteJob | 1 | pass_exhaustive |  | 7997 | 38 | 17.6 |
| fedavg | spCrash | 2 | violation | I_Q | 359 | 12 | 4.4 |
| fedavg | spShutdown | 1 | violation | I_Q | 115405 | 21 | 75.8 |
| fedavg | storeError | 1 | budget_stopped |  | 85626 | 23 | 90.2 |
| fedavg | storeError+sjCrash | 1 | error |  |  | None | 0.3 |
| fedavg2 | deadClient | 2 | violation | S1Cleanup | 800 | 7 | 5.1 |
| k8s | cpCrash | 2 | violation | S3Alloc | 4 | 3 | 2.4 |
| multijob | spShutdown | 2 | violation | I_Q | 34219 | 11 | 25.1 |
| multijobcp | cjCrash | 0 | violation | S3J2Gpu | 100 | 12 | 3.2 |
| sag | acceptRaise | 2 | pass_exhaustive |  | 1791 | 41 | 7.1 |
| swarm | busyReplace | 3 | budget_stopped |  | 9174 | 11 | 90.2 |
