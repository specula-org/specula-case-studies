# Sweep gp5

80 cells: {'pass_exhaustive': 15, 'violation': 20, 'violation_sim': 5, 'budget_stopped': 40}

| config | point | phase | result | violated | distinct | depth | s |
|---|---|---:|---|---|---:|---:|---:|
| attach | netLoss | 0 | budget_stopped |  | 45376 | 36 | 90.3 |
| attach | rpcTimeout | 0 | pass_exhaustive |  | 35 | 9 | 4.5 |
| attach | tpAttachLate__cjCrash | 2 | budget_stopped |  | 93552 | 23 | 90.3 |
| attach | tpReplyLost | 2 | violation | S6AckMeansDone | 76 | 11 | 5.7 |
| attach | tpReplyLost | 3 | pass_exhaustive |  | 14 | 7 | 4.7 |
| attach | tpSilent__resultWaitTimeout | 3 | budget_stopped |  | 32887 | 18 | 90.3 |
| attach | trainerError__netLoss | 1 | violation | I_Q | 29412 | 12 | 48.1 |
| cse | netLoss | 2 | budget_stopped |  | 13632 | 9 | 90.2 |
| cseserver | abort | 5 | budget_stopped |  | 14082 | 10 | 90.2 |
| cseserver | cbFail__spCrash | 3 | violation_sim | I_Q | 12313 | 19 | 90.2 |
| cyclic | cbFail | 0 | pass_exhaustive |  | 9 | 7 | 2.8 |
| cyclic | cbFail__deleteJob | 2 | budget_stopped |  | 16382 | 45 | 90.2 |
| cyclic | cjCrash | 5 | budget_stopped |  | 16081 | 12 | 90.2 |
| cyclic | deleteJob | 5 | budget_stopped |  | 12418 | 38 | 90.2 |
| cyclic | rpcTimeout | 0 | pass_exhaustive |  | 131 | 12 | 3.3 |
| cyclic | rpcTimeout | 2 | pass_exhaustive |  | 243 | 38 | 5.3 |
| docker | cpCrash | 1 | violation | S3Alloc | 113 | 8 | 4.7 |
| external | monitorStale | 3 | pass_exhaustive |  | 7 | 7 | 4.4 |
| external | netLoss | 0 | budget_stopped |  | 34405 | 29 | 90.2 |
| external | sjCrash | 1 | violation | S2F | 1057 | 16 | 7.3 |
| fedavg | abortCmdError__netLoss | 1 | budget_stopped |  | 27015 | 23 | 90.5 |
| fedavg | abortCmdError__rpcTimeout | 3 | pass_exhaustive |  | 15 | 8 | 5.7 |
| fedavg | cjCrash | 2 | budget_stopped |  | 46173 | 24 | 90.5 |
| fedavg | cjCrash | 5 | budget_stopped |  | 33864 | 19 | 90.4 |
| fedavg | deleteJob | 1 | pass_exhaustive |  | 1541 | 34 | 11.0 |
| fedavg | deployError__cpCrash | 1 | violation | I_Q | 12764 | 11 | 21.1 |
| fedavg | outcomeReportFail__netLoss | 2 | budget_stopped |  | 29941 | 23 | 90.4 |
| fedavg | payProduce | 1 | pass_exhaustive |  | 8 | 8 | 4.6 |
| fedavg | prepFail__txTimeout | 3 | budget_stopped |  | 16942 | 15 | 90.5 |
| fedavg | regIterRace__spShutdown | 3 | violation | S1Cleanup | 31 | 6 | 6.2 |
| fedavg | resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 4.9 |
| fedavg | sjSyncFail__abort | 1 | violation | S2F | 1273 | 13 | 9.3 |
| fedavg | slowAdminStop | 1 | budget_stopped |  | 19689 | 51 | 90.5 |
| fedavg | slowAdminStop__sjCrash | 3 | budget_stopped |  | 28526 | 13 | 90.5 |
| fedavg | slowFinalize__deadClient | 3 | budget_stopped |  | 32839 | 30 | 90.6 |
| fedavg | slowFinalize__submitTimeout | 3 | budget_stopped |  | 18881 | 12 | 90.5 |
| fedavg | slowSJTeardown__submitTimeout | 3 | budget_stopped |  | 17030 | 17 | 90.5 |
| fedavg | spCrash | 2 | violation | I_Q | 41 | 12 | 5.8 |
| fedavg | spCrash | 3 | violation | I_Q | 197 | 17 | 8.1 |
| fedavg | spShutdown | 1 | violation_sim | I_Q | 67412 | 23 | 90.4 |
| fedavg | statusLost__cjCrash | 2 | violation_sim | S4CompletedWf | 40966 | 16 | 90.5 |
| fedavg | storeError | 1 | budget_stopped |  | 52323 | 27 | 90.6 |
| fedavg | storeError__sjCrash | 1 | violation | S2F | 10757 | 11 | 19.9 |
| fedavg | submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 4.4 |
| fedavg | submitTimeout | 3 | budget_stopped |  | 14884 | 17 | 90.4 |
| fedavg | taskDataFail__abort | 2 | budget_stopped |  | 44284 | 18 | 90.4 |
| fedavg | taskDataFail__sjCrash | 3 | budget_stopped |  | 29548 | 16 | 90.5 |
| fedavg | taskDataFail__txTimeout | 2 | budget_stopped |  | 30550 | 28 | 90.6 |
| fedavg | tpSilent__abort | 3 | budget_stopped |  | 30467 | 16 | 90.5 |
| fedavg | trainerError__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 4.9 |
| fedavg | transportFail__submitTimeout | 2 | budget_stopped |  | 39376 | 31 | 90.5 |
| fedavg2 | cancel__abort | 3 | budget_stopped |  | 14680 | 12 | 90.3 |
| fedavg2 | deadClient | 2 | violation | S1Cleanup | 1035 | 9 | 10.5 |
| fedavg2 | minClients__sjCrash | 3 | budget_stopped |  | 32727 | 17 | 90.3 |
| fedavg2 | regIterRace__spCrash | 1 | violation | S1Cleanup | 35 | 4 | 5.2 |
| fedavg2 | transportFail__taskTimeout | 2 | budget_stopped |  | 16127 | 17 | 90.3 |
| k8s | cpCrash | 2 | violation | S3Alloc | 10 | 6 | 4.4 |
| k8s | cpCrash | 5 | violation | S3Alloc | 3 | 3 | 4.4 |
| k8s | deadClient | 5 | pass_exhaustive |  | 9456 | 13 | 20.5 |
| k8s | podDeleteFail__spShutdown | 3 | violation | S3Alloc | 292 | 7 | 6.7 |
| k8s | spCrash | 3 | violation | I_Q | 97 | 14 | 6.4 |
| multijob | spShutdown | 1 | violation_sim | I_Q | 95843 | 21 | 90.3 |
| multijob | spShutdown | 2 | violation | I_Q | 8453 | 13 | 16.0 |
| multijobcp | cjCrash | 0 | violation | S2F | 52742 | 21 | 53.5 |
| nonstrict | deadClient | 1 | budget_stopped |  | 59603 | 23 | 90.3 |
| sag | acceptRaise | 2 | violation | S4Artifact | 1060 | 61 | 8.2 |
| sampling | spCrash | 5 | violation_sim | I_Q | 12219 | 22 | 90.2 |
| swarm | busyReplace | 3 | budget_stopped |  | 6160 | 15 | 90.2 |
| swarm | busyReplace__deleteJob | 2 | budget_stopped |  | 8878 | 11 | 90.2 |
| swarm | cpCrash | 5 | budget_stopped |  | 2460 | 14 | 90.2 |
| swarm | gatherRace__gatherTimeout | 2 | budget_stopped |  | 7117 | 18 | 90.2 |
| swarm | sjCrash | 4 | budget_stopped |  | 8713 | 10 | 90.2 |
| swarm | taskTimeout | 4 | budget_stopped |  | 5098 | 8 | 90.2 |
| taskmode | abort | 2 | budget_stopped |  | 76903 | 19 | 90.3 |
| taskmode | settleTimeout__cpCrash | 3 | pass_exhaustive |  | 0 | 1 | 3.3 |
| taskmode | settleTimeout__netLoss | 1 | budget_stopped |  | 56450 | 24 | 90.2 |
| taskmode | taskStageFail | 3 | pass_exhaustive |  | 0 | 1 | 3.4 |
| taskmode | taskStageFail__netLoss | 2 | budget_stopped |  | 42631 | 18 | 90.2 |
| taskmode | taskTimeout | 5 | budget_stopped |  | 42496 | 17 | 90.2 |
| taskmode | workerCrash__taskTimeout | 1 | violation | S2F | 59384 | 19 | 45.8 |
