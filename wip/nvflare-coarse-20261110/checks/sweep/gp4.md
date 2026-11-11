# Sweep gp4

80 cells: {'pass_exhaustive': 13, 'violation': 20, 'violation_sim': 5, 'budget_stopped': 42}

| config | point | phase | result | violated | distinct | depth | s |
|---|---|---:|---|---|---:|---:|---:|
| attach | netLoss | 0 | budget_stopped |  | 38263 | 35 | 90.3 |
| attach | rpcTimeout | 0 | pass_exhaustive |  | 35 | 9 | 4.2 |
| attach | tpAttachLate__cjCrash | 2 | budget_stopped |  | 86844 | 29 | 90.4 |
| attach | tpReplyLost | 2 | violation | S6AckMeansDone | 58 | 12 | 5.2 |
| attach | tpReplyLost | 3 | pass_exhaustive |  | 20 | 9 | 4.9 |
| attach | tpSilent__resultWaitTimeout | 3 | budget_stopped |  | 30073 | 17 | 90.3 |
| attach | trainerError__netLoss | 1 | violation | I_Q | 45579 | 23 | 72.5 |
| cse | netLoss | 2 | budget_stopped |  | 12942 | 9 | 90.2 |
| cseserver | abort | 5 | budget_stopped |  | 14437 | 10 | 90.2 |
| cseserver | cbFail__spCrash | 3 | violation_sim | I_Q | 11807 | 19 | 90.2 |
| cyclic | cbFail | 0 | pass_exhaustive |  | 9 | 7 | 2.5 |
| cyclic | cbFail__deleteJob | 2 | budget_stopped |  | 14349 | 44 | 90.2 |
| cyclic | cjCrash | 5 | budget_stopped |  | 15151 | 11 | 90.2 |
| cyclic | deleteJob | 5 | budget_stopped |  | 15615 | 27 | 90.3 |
| cyclic | rpcTimeout | 0 | pass_exhaustive |  | 131 | 12 | 2.9 |
| cyclic | rpcTimeout | 2 | pass_exhaustive |  | 1453 | 26 | 14.8 |
| docker | cpCrash | 1 | violation | S3Alloc | 117 | 8 | 4.8 |
| external | monitorStale | 3 | budget_stopped |  | 20926 | 27 | 90.2 |
| external | netLoss | 0 | budget_stopped |  | 33629 | 29 | 90.3 |
| external | sjCrash | 1 | violation | S2F | 1263 | 16 | 8.0 |
| fedavg | abortCmdError__netLoss | 1 | budget_stopped |  | 27115 | 23 | 90.5 |
| fedavg | abortCmdError__rpcTimeout | 3 | pass_exhaustive |  | 15 | 8 | 5.5 |
| fedavg | cjCrash | 2 | budget_stopped |  | 46465 | 28 | 90.5 |
| fedavg | cjCrash | 5 | budget_stopped |  | 33560 | 18 | 90.4 |
| fedavg | deleteJob | 1 | pass_exhaustive |  | 828 | 30 | 7.9 |
| fedavg | deployError__cpCrash | 1 | violation | I_Q | 13161 | 11 | 22.5 |
| fedavg | outcomeReportFail__netLoss | 2 | budget_stopped |  | 26608 | 22 | 90.5 |
| fedavg | payProduce | 1 | pass_exhaustive |  | 11 | 9 | 4.8 |
| fedavg | prepFail__txTimeout | 3 | budget_stopped |  | 14826 | 15 | 90.4 |
| fedavg | regIterRace__spShutdown | 3 | violation | S1Cleanup | 31 | 6 | 6.1 |
| fedavg | resultWaitTimeout | 1 | pass_exhaustive |  | 13 | 9 | 4.9 |
| fedavg | sjSyncFail__abort | 1 | violation | S2F | 1280 | 13 | 9.5 |
| fedavg | slowAdminStop | 1 | budget_stopped |  | 20559 | 51 | 90.5 |
| fedavg | slowAdminStop__sjCrash | 3 | budget_stopped |  | 29352 | 13 | 90.5 |
| fedavg | slowFinalize__deadClient | 3 | budget_stopped |  | 30935 | 29 | 90.5 |
| fedavg | slowFinalize__submitTimeout | 3 | budget_stopped |  | 18477 | 12 | 90.5 |
| fedavg | slowSJTeardown__submitTimeout | 3 | budget_stopped |  | 15795 | 17 | 90.4 |
| fedavg | spCrash | 2 | violation | I_Q | 41 | 12 | 6.5 |
| fedavg | spCrash | 3 | violation | I_Q | 197 | 17 | 8.4 |
| fedavg | spShutdown | 1 | violation_sim | I_Q | 59415 | 24 | 90.5 |
| fedavg | statusLost__cjCrash | 2 | violation_sim | S4CompletedWf | 38859 | 16 | 90.5 |
| fedavg | storeError | 1 | budget_stopped |  | 53954 | 26 | 90.5 |
| fedavg | storeError__sjCrash | 1 | violation | S2F | 10734 | 11 | 21.1 |
| fedavg | submitTimeout | 1 | pass_exhaustive |  | 13 | 9 | 5.2 |
| fedavg | submitTimeout | 3 | budget_stopped |  | 14913 | 17 | 90.4 |
| fedavg | taskDataFail__abort | 2 | budget_stopped |  | 38203 | 18 | 90.5 |
| fedavg | taskDataFail__sjCrash | 3 | budget_stopped |  | 28384 | 16 | 90.5 |
| fedavg | taskDataFail__txTimeout | 2 | budget_stopped |  | 33753 | 28 | 90.5 |
| fedavg | tpSilent__abort | 3 | budget_stopped |  | 30118 | 16 | 90.5 |
| fedavg | trainerError__submitTimeout | 1 | budget_stopped |  | 23761 | 33 | 90.4 |
| fedavg | transportFail__submitTimeout | 2 | budget_stopped |  | 32913 | 30 | 90.6 |
| fedavg2 | cancel__abort | 3 | budget_stopped |  | 13174 | 12 | 90.3 |
| fedavg2 | deadClient | 2 | violation | S1Cleanup | 2138 | 6 | 13.7 |
| fedavg2 | minClients__sjCrash | 3 | budget_stopped |  | 25547 | 18 | 90.4 |
| fedavg2 | regIterRace__spCrash | 1 | violation | S1Cleanup | 35 | 4 | 5.3 |
| fedavg2 | transportFail__taskTimeout | 2 | budget_stopped |  | 15520 | 13 | 90.3 |
| k8s | cpCrash | 2 | violation | S3Alloc | 10 | 6 | 4.4 |
| k8s | cpCrash | 5 | violation | S3Alloc | 3 | 3 | 4.5 |
| k8s | deadClient | 5 | pass_exhaustive |  | 12716 | 13 | 26.8 |
| k8s | podDeleteFail__spShutdown | 3 | violation | S3Alloc | 268 | 7 | 6.9 |
| k8s | spCrash | 3 | violation | I_Q | 97 | 14 | 6.4 |
| multijob | spShutdown | 1 | violation_sim | I_Q | 78436 | 22 | 90.3 |
| multijob | spShutdown | 2 | violation | I_Q | 9866 | 13 | 17.1 |
| multijobcp | cjCrash | 0 | violation_sim | S2F | 91686 | 36 | 90.4 |
| nonstrict | deadClient | 1 | budget_stopped |  | 59358 | 23 | 90.3 |
| sag | acceptRaise | 2 | violation | S4Artifact | 19650 | 35 | 27.2 |
| sampling | spCrash | 5 | violation | I_Q | 1697 | 16 | 18.1 |
| swarm | busyReplace | 3 | budget_stopped |  | 6384 | 15 | 90.2 |
| swarm | busyReplace__deleteJob | 2 | budget_stopped |  | 12950 | 12 | 90.3 |
| swarm | cpCrash | 5 | budget_stopped |  | 3746 | 21 | 90.2 |
| swarm | gatherRace__gatherTimeout | 2 | budget_stopped |  | 10587 | 19 | 90.2 |
| swarm | sjCrash | 4 | budget_stopped |  | 9562 | 10 | 90.2 |
| swarm | taskTimeout | 4 | budget_stopped |  | 4923 | 8 | 90.2 |
| taskmode | abort | 2 | budget_stopped |  | 69977 | 19 | 90.3 |
| taskmode | settleTimeout__cpCrash | 3 | pass_exhaustive |  | 0 | 1 | 3.7 |
| taskmode | settleTimeout__netLoss | 1 | budget_stopped |  | 48959 | 23 | 90.2 |
| taskmode | taskStageFail | 3 | pass_exhaustive |  | 0 | 1 | 3.6 |
| taskmode | taskStageFail__netLoss | 2 | budget_stopped |  | 39388 | 18 | 90.2 |
| taskmode | taskTimeout | 5 | budget_stopped |  | 41496 | 17 | 90.3 |
| taskmode | workerCrash__taskTimeout | 1 | violation | S2F | 63565 | 19 | 51.4 |
