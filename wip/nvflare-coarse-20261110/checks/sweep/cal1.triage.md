# Triage cal1

283 counterexample cells, 19 (property, mechanism) groups

| property | mechanism | cells | min depth | min weight (tier) | configs x points | example |
|---|---|---:|---:|---|---|---|
| S2TerminalFinal | overwrite:FAILED->RUNNING | 56 | 18 | 2 (medium) | attach:cjCrash, attach:deadClient, attach:netLoss, attach:resultWaitTimeout, attach:sjCrash, attach:taskTimeout, attach:tpAttachLate, cse:sjCrash ... | cal1_fedavg_sjCrash_p0 |
| S1ThreadsAlive | thread:taskMonitor@CommSJ.wfc.resendDup | 46 | 0 | 0 (high) | cse:abort, cse:cjCrash, cse:cpCrash, cse:deadClient, cse:deleteJob, cse:netLoss, cse:rpcTimeout, cse:sjCrash ... | cal1_cse_cjCrash_p5 |
| Q1Terminal | hang:afterSPRestart:RUNNING | 37 | 11 | 1 (high) | attach:spCrash, attach:spShutdown, cse:spCrash, cseserver:spCrash, cyclic:spCrash, docker:spCrash, docker:spShutdown, external:spCrash ... | cal1_fedavg_spCrash_p5 |
| Q1Terminal | hang:afterCPRestart:RUNNING | 20 | 2 | 1 (high) | attach:cpCrash, cyclic:cpCrash, external:cpCrash, fedavg2:cpCrash, fedavg:cpCrash, fedmodel:cpCrash, multijob:cpCrash, multijobcp:cpCrash ... | cal1_multijobcp_cpCrash_p2 |
| Q1Terminal | hang:RUNNING | 20 | 8 | 0 (high) | attach:tpCrash, attach:tpSilent, attach:trainerError, taskmode:cjCrash, taskmode:ctrlLoss, taskmode:deadClient, taskmode:deleteJob, taskmode:netLoss ... | cal1_taskmode_cjCrash_p2 |
| Q1Terminal | hang:afterSPRestart:SUBMITTED | 19 | 5 | 1 (high) | attach:spShutdown, cse:spShutdown, cseserver:spShutdown, cyclic:spShutdown, docker:spShutdown, external:spShutdown, fedavg2:spShutdown, fedavg:slowShutdownAbort ... | cal1_fedavg_spShutdown_p0 |
| S1ThreadsAlive | thread:scheduler@JobSP.sched.scan | 17 | 1 | 2 (medium) | attach:deleteJob, cse:deleteJob, cseserver:deleteJob, cyclic:deleteJob, docker:deleteJob, external:deleteJob, fedavg2:deleteJob, fedavg:deleteJob ... | cal1_multijobcp_deleteJob_p0 |
| Q1Terminal | hang:afterSPRestart:DISPATCHED | 17 | 10 | 3 (medium) | attach:spCrash, cse:spCrash, cseserver:spCrash, cyclic:spCrash, docker:spCrash, external:spCrash, fedavg2:spCrash, fedavg:spCrash ... | cal1_fedavg_spCrash_p0 |
| S4NoLostResult | lost:gatherAfterClose | 16 | 0 | 0 (high) | swarm:abort, swarm:busyReplace, swarm:cjCrash, swarm:cpCrash, swarm:deadClient, swarm:deleteJob, swarm:gatherTimeout, swarm:learnFail ... | cal1_swarm_cjCrash_p5 |
| S1ThreadsAlive | thread:cleanup@Reg.cleanup.iterate | 9 | 2 | 8 (very_low) | fedavg2:regIterRace, fedavg:regIterRace, multijob:regIterRace | cal1_fedavg_regIterRace_p0 |
| S1ThreadsAlive | thread:cleanup@Reg.cleanup.logoutNone | 6 | 5 | 6 (very_low) | fedavg2:slowFinalize, fedavg:slowFinalize | cal1_fedavg2_slowFinalize_p0 |
| S3Resources | resource:liveWithoutAllocation:afterCPRestart | 6 | 1 | 1 (high) | docker:cpCrash, k8s:cpCrash | cal1_k8s_cpCrash_p2 |
| S3Resources | resource:liveWithoutAllocation | 4 | 6 | 4 (low) | fedavg:launchError, k8s:podDeleteFail | cal1_fedavg_launchError_p0 |
| S1ThreadsAlive | thread:cleanup@Reg.cleanup.notifyIterate | 3 | 3 | 8 (very_low) | multijob:jobExitRace | cal1_multijob_jobExitRace_p0 |
| S4Completed | completed:workflowNotDone | 2 | 13 | 5 (low) | fedavg:slowAdminStop | cal1_fedavg_slowAdminStop_p2 |
| S6AckMeansDone | ack:successWithoutAcceptance | 2 | 9 | 8 (very_low) | attach:tpReplyLost | cal1_attach_tpReplyLost_p2 |
| S4Completed | completed:afterPanic | 1 | 25 | 12 (very_low) | fedavg:statusLost | cal1_fedavg_statusLost_p2 |
| S3Resources | resource:otherJobUsesOurUnit | 1 | 10 | 2 (medium) | multijobcp:cjCrash | cal1_multijobcp_cjCrash_p0 |
| S3Resources | resource:usesOtherJobUnit | 1 | 11 | 4 (low) | multijobcp:startOverlap | cal1_multijobcp_startOverlap_p0 |
