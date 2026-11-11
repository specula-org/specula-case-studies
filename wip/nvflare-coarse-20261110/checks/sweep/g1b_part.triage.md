# Triage g1b_part

67 counterexample cells, 13 mechanisms (item | cause records)

| severity | likelihood (w) | item | cause records | cells | min depth | example | priced |
|---|---|---|---|---:|---:|---|---|
| server | medium (2) | S1Sched | schedulerCrashed=JobSP.runner.except | 6 | 5 | g1b_fedavg_deleteJob_p0 | deleteJob@3[2] |
| server | low (4) | S1Compl | completionCrashed=JobSP.complete.del | 1 | 15 | g1b_fedavg_storeError__sjCrash_p1 | sjCrash@10[2] storeError@13[2] |
| job | high (1) | Q1c | unmatched | 28 | 2 | g1b_fedavg_statusLost__cpCrash_p2 | cpCrash@2[1] |
| job | high (1) | Q4c | unmatched | 6 | 2 | g1b_fedavg_cpCrash_p2 | cpCrash@2[1] |
| job | medium (3) | Q1c | staleBy=JobSP.proc.SP | 1 | 7 | g1b_fedavg_launchError__spCrash_p1 | spCrash@4[1] launchError,rpcTimeout@7[2] |
| job | medium (3) | Q1c | lateStart=JobSP.state.askToStop,staleBy=JobSP.proc.SP | 1 | 10 | g1b_fedavg_launchError__spShutdown_p1 | spShutdown@2[1] launchError@11[2] |
| job | medium (2) | Q1c | schedulerCrashed=JobSP.sched.scan | 1 | 1 | g1b_multijob_deleteJob_p0 | deleteJob@2[2] |
| job | low (4) | Q1c | overwrite=JobSP.runner.writeRunning | 6 | 77 | g1b_fedavg_netLossJobSP_p1 | netLossJobSP@14[4] |
| job | low (4) | Q1c | - | 3 | 2 | g1b_fedavg_taskDataFail__submitTimeout_p2 | submitTimeout,taskDataFail@2[4] |
| job | low (4) | Q3c | - | 1 | 12 | g1b_fedavg_launchError__sjCrash_p1 | launchError@4[2] sjCrash@9[2] |
| job | very_low (6) | S3Alloc | orphanBy=JobCP.exec.relaunch | 3 | 7 | g1b_fedavg_launchError__cjCrash_p2 | cjCrash@2[2] launchError@5[4] |
| job | very_low (10) | Q1c | exitObs=JobSP.engine.waiter,overwrite=JobSP.runner.writeRunning | 1 | 47 | g1b_fedavg_statusLost__outcomeTimeout_p1 | cbFail@9[4] statusLost@30[4] outcomeTimeout@33[2] |
| status | low (5) | S4CompletedWf | exitUnseen=JobSP.engine.abort | 9 | 15 | g1b_fedavg_slowShutdownAbort__sjCrash_p1 | spShutdown@4[1] slowShutdownAbort@6[4] |
