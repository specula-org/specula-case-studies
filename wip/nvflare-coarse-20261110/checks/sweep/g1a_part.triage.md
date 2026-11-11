# Triage g1a_part

324 counterexample cells, 20 mechanisms (item | cause records)

| severity | likelihood (w) | item | cause records | cells | min depth | example | priced |
|---|---|---|---|---:|---:|---|---|
| server | medium (2) | S1Sched | schedulerCrashed=JobSP.sched.scan | 2 | 1 | g1a_fedavg_deleteJob_p0 | deleteJob@2[2] |
| server | low (4) | S1Cleanup | cleanupCrashed=Reg.cleanup.logoutNone,unmatched | 3 | 5 | g1a_fedavg2_deadClient_p5 | deadClient@2[2] again@3[2] |
| server | low (4) | S1Cleanup | cleanupCrashed=Reg.cleanup.logoutNone | 2 | 5 | g1a_fedavg2_deadClient_p0 | deadClient@2[2] again@3[2] |
| server | very_low (8) | S1Cleanup | cleanupCrashed=Reg.cleanup.iterate | 38 | 2 | g1a_fedavg_regIterRace_p0 | deadClient@2[2] regIterRace@3[6] |
| job | high (1) | Q1c | staleBy=JobSP.proc.SP | 61 | 3 | g1a_fedavg_spShutdown_p0 | spShutdown@2[1] |
| job | high (1) | Q1c | staleBy=JobSP.proc.SP,unfinalized=JobSP.admin.shutdownLoop | 46 | 12 | g1a_fedavg_spShutdown_p2 | spShutdown@2[1] |
| job | high (1) | Q1c | unmatched | 24 | 2 | g1a_fedavg_cpCrash_p2 | cpCrash@2[1] |
| job | high (1) | Q1c | lateStart=JobSP.state.askToStop,staleBy=JobSP.proc.SP,unfinalized=JobSP.admin.shutdownLoop | 1 | 33 | g1a_fedavg_admissionError__spShutdown_p1 | spShutdown@2[1] |
| job | medium (3) | Q1c | lateStart=JobSP.state.askToStop,staleBy=JobSP.proc.SP | 2 | 24 | g1a_fedavg_slowShutdownAbort__netLoss_p1 | spShutdown@2[1] netLoss@3[2] |
| job | low (4) | S3Alloc | freedBy=JobCP.exec.startApp | 11 | 6 | g1a_fedavg_launchError_p1 | launchError@7[4] |
| job | low (4) | Q1c | - | 3 | 2 | g1a_fedavg_taskDataFail__netLoss_p2 | netLoss,taskDataFail@2[4] |
| job | very_low (6) | S3Alloc | - | 2 | 7 | g1a_fedavg_launchError__cjCrash_p2 | cjCrash@2[2] launchError@5[4] |
| job | very_low (7) | Q1c | staleBy=JobSP.proc.SP,unfinalized=JobSP.admin.shutdownLoop,unmatched | 2 | 24 | g1a_fedavg_slowShutdownAbort__deadClient_p2 | deadClient@2[2] spShutdown@3[1] again@5[2] again@10[2] |
| status | medium (2) | S2 | overwrite=JobSP.runner.writeRunning | 85 | 13 | g1a_fedavg_slowSJTeardown__sjCrash_p1 | sjCrash@10[2] |
| status | low (5) | S4CompletedWf | termEarly=JobSP.engine.abort | 17 | 8 | g1a_fedavg_slowAdminStop_p2 | abort@2[1] slowAdminStop@4[4] |
| status | low (5) | S2 | lateStart=JobSP.state.askToStop,overwrite=JobSP.runner.writeRunning | 2 | 19 | g1a_fedavg_slowShutdownAbort_p1 | spShutdown@2[1] slowShutdownAbort@6[4] |
| status | low (5) | S4CompletedWf | lateStart=JobSP.state.askToStop | 1 | 19 | g1a_fedavg_slowShutdownAbort__outcomeTimeout_p1 | spShutdown@2[1] slowShutdownAbort@6[4] |
| status | very_low (8) | S4CompletedWf | exitObs=JobSP.engine.waiter | 18 | 14 | g1a_fedavg_statusLost_p2 | cbFail@2[4] statusLost@18[4] |
| status | very_low (8) | S4CompletedWf | exitObs=JobSP.engine.waiter,unmatched | 2 | 25 | g1a_fedavg_statusLost__deadClient_p2 | deadClient@2[2] again@7[2] statusLost@20[4] |
| status | very_low (6) | S2 | overwrite=JobSP.runner.writeRunning,unmatched | 2 | 41 | g1a_fedavg_admissionError__deadClient_p1 | deadClient@3[2] again@8[2] again@12[2] |
