# Triage gp5

25 counterexample cells, 13 mechanisms (item | cause records)

| severity | likelihood (w) | item | cause records | cells | min depth | example | priced |
|---|---|---|---|---:|---:|---|---|
| server | low (4) | S1Cleanup | cleanupCrashed=Reg.cleanup.logoutNone,unmatched | 1 | 7 | gp5_fedavg2_deadClient_p2 | deadClient@4[2] again@5[2] |
| server | very_low (8) | S1Cleanup | cleanupCrashed=Reg.cleanup.iterate | 2 | 2 | gp5_fedavg2_regIterRace__spCrash_p1 | deadClient@2[2] regIterRace@3[6] |
| data | low (4) | S4Artifact | poisoned | 1 | 68 | gp5_sag_acceptRaise_p2 | acceptRaise@37[4] |
| job | high (1) | Q1c | staleBy=JobSP.proc.SP | 6 | 11 | gp5_fedavg_spCrash_p2 | spCrash@2[1] |
| job | high (1) | S3Alloc | allocLost=JobCP.container.lifetime | 3 | 2 | gp5_k8s_cpCrash_p2 | cpCrash@3[1] |
| job | high (1) | Q1c | unmatched | 1 | 14 | gp5_fedavg_deployError__cpCrash_p1 | cpCrash@9[1] |
| job | high (1) | Q1c | staleBy=JobSP.proc.SP,unfinalized=JobSP.admin.shutdownLoop | 1 | 17 | gp5_multijob_spShutdown_p2 | spShutdown@4[1] |
| job | high (1) | Q1c | lateStart=JobSP.state.askToStop,staleBy=JobSP.proc.SP | 1 | 33 | gp5_fedavg_spShutdown_p1 | spShutdown@2[1] |
| job | medium (2) | Q1c | - | 1 | 22 | gp5_attach_trainerError__netLoss_p1 | trainerError@21[2] |
| job | low (5) | S3Alloc | endBy=JobCP.k8s.terminate | 1 | 6 | gp5_k8s_podDeleteFail__spShutdown_p3 | abort@2[1] podDeleteFail@5[4] |
| status | medium (2) | S2 | overwrite=JobSP.runner.writeRunning | 5 | 13 | gp5_fedavg_storeError__sjCrash_p1 | sjCrash@10[2] |
| status | medium (2) | S6AckMeansDone | ackInferred | 1 | 9 | gp5_attach_tpReplyLost_p2 | tpReplyLost@8[2] |
| status | very_low (10) | S4CompletedWf | exitObs=JobSP.engine.waiter | 1 | 21 | gp5_fedavg_statusLost__cjCrash_p2 | cjCrash@2[2] cbFail@3[4] statusLost@19[4] |
