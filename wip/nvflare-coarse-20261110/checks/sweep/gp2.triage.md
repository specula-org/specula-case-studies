# Triage gp2

26 counterexample cells, 13 mechanisms (item | cause records)

| severity | likelihood (w) | item | cause records | cells | min depth | example | priced |
|---|---|---|---|---:|---:|---|---|
| server | low (4) | S1Cleanup | cleanupCrashed=Reg.cleanup.logoutNone,unmatched | 1 | 8 | gp2_fedavg2_deadClient_p2 | deadClient@5[2] again@6[2] |
| server | very_low (8) | S1Cleanup | cleanupCrashed=Reg.cleanup.iterate | 2 | 2 | gp2_fedavg2_regIterRace__spCrash_p1 | deadClient@2[2] regIterRace@3[6] |
| job | high (1) | Q1c | freedBy=JobCP.exec.free,staleBy=JobSP.proc.SP | 7 | 11 | gp2_k8s_spCrash_p3 | spCrash@4[1] |
| job | high (1) | S3Alloc | allocLost=JobCP.container.lifetime | 3 | 2 | gp2_k8s_cpCrash_p2 | cpCrash@3[1] |
| job | high (0) | S1Monitor | monitorCrashed=CommSJ.wfc.resendDup | 1 | 0 | gp2_cseserver_abort_p5 |  |
| job | high (1) | Q1c | unmatched | 1 | 14 | gp2_fedavg_deployError__cpCrash_p1 | cpCrash@9[1] |
| job | high (1) | Q1c | freedBy=JobCP.exec.free,staleBy=JobSP.proc.SP,unfinalized=JobSP.admin.shutdownLoop | 1 | 17 | gp2_multijob_spShutdown_p2 | spShutdown@4[1] |
| job | medium (2) | Q1c | - | 1 | 22 | gp2_attach_trainerError__netLoss_p1 | trainerError@21[2] |
| job | low (5) | S3Alloc | endBy=JobCP.k8s.terminate,freedBy=JobCP.exec.free | 1 | 6 | gp2_k8s_podDeleteFail__spShutdown_p3 | abort@2[1] podDeleteFail@5[4] |
| status | medium (2) | S6AckMeansDone | ackInferred | 1 | 9 | gp2_attach_tpReplyLost_p2 | tpReplyLost@8[2] |
| status | low (5) | S4CompletedWf | termEarly=JobSP.engine.abort | 1 | 13 | gp2_fedavg_slowAdminStop__sjCrash_p3 | abort@2[1] slowAdminStop@4[4] |
| status | very_low (12) | S4CompletedWf | exitObs=JobSP.engine.waiter,freedBy=JobCP.exec.free | 1 | 26 | gp2_fedavg_statusLost__cjCrash_p2 | cbFail@2[4] cjCrash@3[2] again@12[2] statusLost@24[4] |
| ? | medium (2) | S2F | overwrite=JobSP.runner.writeRunning | 5 | 13 | gp2_fedavg_storeError__sjCrash_p1 | sjCrash@10[2] |
