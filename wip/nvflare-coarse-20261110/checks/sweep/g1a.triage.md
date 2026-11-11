# Triage g1a

908 counterexample cells, 32 mechanisms (item | cause records)

| severity | likelihood (w) | item | cause records | cells | min depth | example | priced |
|---|---|---|---|---:|---:|---|---|
| server | medium (2) | S1Sched | schedulerCrashed=JobSP.sched.scan | 17 | 1 | g1a_fedavg_deleteJob_p0 | deleteJob@2[2] |
| server | low (4) | S1Cleanup | cleanupCrashed=Reg.cleanup.logoutNone,unmatched | 47 | 5 | g1a_fedavg2_deadClient_p5 | deadClient@2[2] again@3[2] |
| server | low (4) | S1Cleanup | cleanupCrashed=Reg.cleanup.logoutNone | 27 | 5 | g1a_fedavg2_deadClient_p0 | deadClient@2[2] again@3[2] |
| server | very_low (8) | S1Cleanup | cleanupCrashed=Reg.cleanup.iterate | 105 | 2 | g1a_fedavg_regIterRace_p0 | deadClient@2[2] regIterRace@3[6] |
| server | very_low (8) | S1Cleanup | cleanupCrashed=Reg.cleanup.notifyIterate | 32 | 3 | g1a_multijob_jobExitRace_p0 | deadClient@2[2] jobExitRace@4[6] |
| data | medium (2) | S4Aggregate | - | 2 | 57 | g1a_sag_cbFail__taskTimeout_p1 | taskTimeout@21[2] |
| data | low (4) | S4Artifact | poisoned | 1 | 68 | g1a_sag_acceptRaise_p2 | acceptRaise@37[4] |
| data | very_low (6) | S4Aggregate | unmatched | 1 | 70 | g1a_sag_deadClient_p1 | deadClient@2[2] again@8[2] again@36[2] |
| data | very_low (6) | S4Gather | raced | 1 | 90 | g1a_swarm_gatherRace__netLoss_p3 | gatherRace,netLoss@2[4] again@4[2] |
| job | high (1) | Q1c | staleBy=JobSP.proc.SP | 181 | 3 | g1a_fedavg_spShutdown_p0 | spShutdown@2[1] |
| job | high (1) | Q1c | staleBy=JobSP.proc.SP,unfinalized=JobSP.admin.shutdownLoop | 112 | 12 | g1a_fedavg_spShutdown_p2 | spShutdown@2[1] |
| job | high (1) | Q1c | unmatched | 61 | 2 | g1a_fedavg_cpCrash_p2 | cpCrash@2[1] |
| job | high (1) | S3Alloc | allocLost=JobCP.container.lifetime | 14 | 1 | g1a_k8s_podDeleteFail__cpCrash_p2 | cpCrash@2[1] |
| job | high (1) | Q1c | lateStart=JobSP.state.askToStop,staleBy=JobSP.proc.SP | 13 | 24 | g1a_sag_spShutdown_p1 | spShutdown@2[1] |
| job | high (1) | Q1c | lateStart=JobSP.state.askToStop,staleBy=JobSP.proc.SP,unfinalized=JobSP.admin.shutdownLoop | 3 | 33 | g1a_fedavg_admissionError__spShutdown_p1 | spShutdown@2[1] |
| job | medium (2) | Q1c | - | 11 | 2 | g1a_attach_trainerError_p2 | trainerError@9[2] |
| job | medium (2) | S3J2Gpu | gpuBy=JobCP.res.gpuEnv | 2 | 4 | g1a_multijobcp_cjCrash_p1 | cjCrash@5[2] |
| job | low (5) | S3Alloc | endBy=JobCP.k8s.terminate | 20 | 6 | g1a_k8s_podDeleteFail_p2 | abort@2[1] podDeleteFail@5[4] |
| job | low (5) | Q1c | staleBy=JobSP.proc.SP,stopSkipped=JobSP.admin.shutdownLoop | 18 | 8 | g1a_multijob_slowShutdownAbort_p2 | spShutdown@4[1] slowShutdownAbort@5[4] |
| job | low (4) | S3Alloc | freedBy=JobCP.exec.startApp | 11 | 6 | g1a_fedavg_launchError_p1 | launchError@7[4] |
| job | very_low (6) | S3Alloc | - | 2 | 7 | g1a_fedavg_launchError__cjCrash_p2 | cjCrash@2[2] launchError@5[4] |
| job | very_low (7) | Q1c | staleBy=JobSP.proc.SP,unfinalized=JobSP.admin.shutdownLoop,unmatched | 2 | 24 | g1a_fedavg_slowShutdownAbort__deadClient_p2 | deadClient@2[2] spShutdown@3[1] again@5[2] again@10[2] |
| job | very_low (7) | Q1c | staleBy=JobSP.proc.SP,unmatched | 1 | 43 | g1a_multijob_slowShutdownAbort__deadClient_p1 | again@2[2] deadClient@4[2] spShutdown@9[1] again@15[2] |
| status | medium (2) | S2 | overwrite=JobSP.runner.writeRunning | 165 | 13 | g1a_fedavg_slowSJTeardown__sjCrash_p1 | sjCrash@10[2] |
| status | medium (2) | S6AckMeansDone | ackInferred | 14 | 8 | g1a_attach_tpReplyLost__abort_p3 | tpReplyLost@7[2] |
| status | low (5) | S4CompletedWf | termEarly=JobSP.engine.abort | 17 | 8 | g1a_fedavg_slowAdminStop_p2 | abort@2[1] slowAdminStop@4[4] |
| status | low (5) | S4CompletedWf | - | 3 | 15 | g1a_multijob_slowShutdownAbort__abort_p1 | spShutdown@4[1] slowShutdownAbort@6[4] |
| status | low (5) | S2 | lateStart=JobSP.state.askToStop,overwrite=JobSP.runner.writeRunning | 2 | 19 | g1a_fedavg_slowShutdownAbort_p1 | spShutdown@2[1] slowShutdownAbort@6[4] |
| status | low (5) | S4CompletedWf | lateStart=JobSP.state.askToStop | 1 | 19 | g1a_fedavg_slowShutdownAbort__outcomeTimeout_p1 | spShutdown@2[1] slowShutdownAbort@6[4] |
| status | very_low (8) | S4CompletedWf | exitObs=JobSP.engine.waiter | 18 | 14 | g1a_fedavg_statusLost_p2 | cbFail@2[4] statusLost@18[4] |
| status | very_low (8) | S4CompletedWf | exitObs=JobSP.engine.waiter,unmatched | 2 | 25 | g1a_fedavg_statusLost__deadClient_p2 | deadClient@2[2] again@7[2] statusLost@20[4] |
| status | very_low (6) | S2 | overwrite=JobSP.runner.writeRunning,unmatched | 2 | 41 | g1a_fedavg_admissionError__deadClient_p1 | deadClient@3[2] again@8[2] again@12[2] |
