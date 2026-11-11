# Sweep gp2

80 cells: {'pass_exhaustive': 20, 'violation': 23, 'violation_sim': 3, 'budget_stopped': 34}

| config | point | phase | result | violated | distinct | depth | s |
|---|---|---:|---|---|---:|---:|---:|
| attach | netLoss | 0 | budget_stopped |  | 34376 | 35 | 90.2 |
| attach | rpcTimeout | 0 | pass_exhaustive |  | 35 | 9 | 3.0 |
| attach | tpAttachLate__cjCrash | 2 | budget_stopped |  | 78017 | 31 | 90.2 |
| attach | tpReplyLost | 2 | violation | S6AckMeansDone | 75 | 11 | 4.2 |
| attach | tpReplyLost | 3 | pass_exhaustive |  | 19 | 11 | 2.9 |
| attach | tpSilent__resultWaitTimeout | 3 | pass_exhaustive |  | 43258 | 13 | 50.6 |
| attach | trainerError__netLoss | 1 | violation | I_Q | 44200 | 23 | 67.5 |
| cse | netLoss | 2 | budget_stopped |  | 13654 | 11 | 90.3 |
| cseserver | abort | 5 | violation | S1Monitor |  | None | 3.6 |
| cseserver | cbFail__spCrash | 3 | violation_sim | I_Q | 12015 | 21 | 90.2 |
| cyclic | cbFail | 0 | pass_exhaustive |  | 9 | 7 | 2.9 |
| cyclic | cbFail__deleteJob | 2 | budget_stopped |  | 16809 | 44 | 90.2 |
| cyclic | cjCrash | 5 | budget_stopped |  | 17172 | 12 | 90.2 |
| cyclic | deleteJob | 5 | pass_exhaustive |  | 119 | 17 | 4.6 |
| cyclic | rpcTimeout | 0 | pass_exhaustive |  | 131 | 12 | 3.6 |
| cyclic | rpcTimeout | 2 | pass_exhaustive |  | 243 | 38 | 5.6 |
| docker | cpCrash | 1 | violation | S3Alloc | 123 | 8 | 4.6 |
| external | monitorStale | 3 | pass_exhaustive |  | 7 | 7 | 3.5 |
| external | netLoss | 0 | budget_stopped |  | 28518 | 28 | 90.2 |
| external | sjCrash | 1 | violation | S2F | 1070 | 16 | 6.3 |
| fedavg | abortCmdError__netLoss | 1 | budget_stopped |  | 30859 | 24 | 90.4 |
| fedavg | abortCmdError__rpcTimeout | 3 | pass_exhaustive |  | 15 | 8 | 5.5 |
| fedavg | cjCrash | 2 | pass_exhaustive |  | 10 | 7 | 4.6 |
| fedavg | cjCrash | 5 | budget_stopped |  | 33706 | 19 | 90.5 |
| fedavg | deleteJob | 1 | pass_exhaustive |  | 1541 | 30 | 11.5 |
| fedavg | deployError__cpCrash | 1 | violation | I_Q | 12338 | 11 | 20.0 |
| fedavg | outcomeReportFail__netLoss | 2 | budget_stopped |  | 27327 | 22 | 90.4 |
| fedavg | payProduce | 1 | pass_exhaustive |  | 8 | 8 | 5.5 |
| fedavg | prepFail__txTimeout | 3 | budget_stopped |  | 17424 | 15 | 90.5 |
| fedavg | regIterRace__spShutdown | 3 | violation | S1Cleanup | 31 | 6 | 6.2 |
| fedavg | resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 4.7 |
| fedavg | sjSyncFail__abort | 1 | violation | S2F | 1303 | 13 | 9.8 |
| fedavg | slowAdminStop | 1 | budget_stopped |  | 19202 | 51 | 90.5 |
| fedavg | slowAdminStop__sjCrash | 3 | violation | S4CompletedWf | 39454 | 13 | 84.3 |
| fedavg | slowFinalize__deadClient | 3 | budget_stopped |  | 34302 | 30 | 90.5 |
| fedavg | slowFinalize__submitTimeout | 3 | budget_stopped |  | 19163 | 12 | 90.5 |
| fedavg | slowSJTeardown__submitTimeout | 3 | budget_stopped |  | 18349 | 18 | 90.4 |
| fedavg | spCrash | 2 | violation | I_Q | 37 | 12 | 5.7 |
| fedavg | spCrash | 3 | violation | I_Q | 197 | 17 | 9.0 |
| fedavg | spShutdown | 1 | violation | I_Q | 66575 | 25 | 80.1 |
| fedavg | statusLost__cjCrash | 2 | violation_sim | S4CompletedWf | 41291 | 16 | 90.5 |
| fedavg | storeError | 1 | budget_stopped |  | 48785 | 28 | 90.5 |
| fedavg | storeError__sjCrash | 1 | violation | S2F | 10742 | 11 | 20.5 |
| fedavg | submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 4.7 |
| fedavg | submitTimeout | 3 | budget_stopped |  | 18714 | 17 | 90.4 |
| fedavg | taskDataFail__abort | 2 | budget_stopped |  | 38547 | 18 | 90.5 |
| fedavg | taskDataFail__sjCrash | 3 | budget_stopped |  | 28652 | 16 | 90.5 |
| fedavg | taskDataFail__txTimeout | 2 | budget_stopped |  | 33568 | 28 | 90.5 |
| fedavg | tpSilent__abort | 3 | budget_stopped |  | 30271 | 16 | 90.5 |
| fedavg | trainerError__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 5.0 |
| fedavg | transportFail__submitTimeout | 2 | budget_stopped |  | 38877 | 31 | 90.5 |
| fedavg2 | cancel__abort | 3 | budget_stopped |  | 15196 | 12 | 90.3 |
| fedavg2 | deadClient | 2 | violation | S1Cleanup | 1020 | 8 | 10.2 |
| fedavg2 | minClients__sjCrash | 3 | budget_stopped |  | 32569 | 17 | 90.3 |
| fedavg2 | regIterRace__spCrash | 1 | violation | S1Cleanup | 35 | 4 | 4.9 |
| fedavg2 | transportFail__taskTimeout | 2 | budget_stopped |  | 17299 | 17 | 90.3 |
| k8s | cpCrash | 2 | violation | S3Alloc | 10 | 6 | 2.7 |
| k8s | cpCrash | 5 | violation | S3Alloc | 3 | 3 | 2.8 |
| k8s | deadClient | 5 | pass_exhaustive |  | 9456 | 15 | 25.4 |
| k8s | podDeleteFail__spShutdown | 3 | violation | S3Alloc | 267 | 7 | 5.2 |
| k8s | spCrash | 3 | violation | I_Q | 105 | 14 | 4.5 |
| multijob | spShutdown | 1 | violation_sim | I_Q | 81518 | 23 | 90.3 |
| multijob | spShutdown | 2 | violation | I_Q | 8085 | 13 | 16.0 |
| multijobcp | cjCrash | 0 | violation | S2F | 39782 | 21 | 43.5 |
| nonstrict | deadClient | 1 | budget_stopped |  | 59905 | 23 | 90.3 |
| sag | acceptRaise | 2 | pass_exhaustive |  | 530 | 53 | 6.0 |
| sampling | spCrash | 5 | violation | I_Q | 7004 | 13 | 49.0 |
| swarm | busyReplace | 3 | budget_stopped |  | 5926 | 15 | 90.2 |
| swarm | busyReplace__deleteJob | 2 | budget_stopped |  | 9096 | 12 | 90.2 |
| swarm | cpCrash | 5 | pass_exhaustive |  | 1582 | 7 | 41.0 |
| swarm | gatherRace__gatherTimeout | 2 | budget_stopped |  | 7043 | 19 | 90.1 |
| swarm | sjCrash | 4 | budget_stopped |  | 9374 | 10 | 90.2 |
| swarm | taskTimeout | 4 | budget_stopped |  | 4727 | 8 | 90.2 |
| taskmode | abort | 2 | budget_stopped |  | 79265 | 19 | 90.2 |
| taskmode | settleTimeout__cpCrash | 3 | pass_exhaustive |  | 0 | 1 | 2.7 |
| taskmode | settleTimeout__netLoss | 1 | budget_stopped |  | 56520 | 23 | 90.2 |
| taskmode | taskStageFail | 3 | pass_exhaustive |  | 0 | 1 | 2.8 |
| taskmode | taskStageFail__netLoss | 2 | budget_stopped |  | 43753 | 18 | 90.2 |
| taskmode | taskTimeout | 5 | budget_stopped |  | 42682 | 17 | 90.2 |
| taskmode | workerCrash__taskTimeout | 1 | violation | S2F | 59797 | 20 | 39.7 |
