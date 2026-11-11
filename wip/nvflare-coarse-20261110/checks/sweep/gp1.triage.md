# Triage gp1

7 counterexample cells, 6 mechanisms (item | cause records)

| severity | likelihood (w) | item | cause records | cells | min depth | example | priced |
|---|---|---|---|---:|---:|---|---|
| server | low (4) | S1Cleanup | cleanupCrashed=Reg.cleanup.logoutNone,unmatched | 1 | 5 | gp1_fedavg2_deadClient_p2 | SNext[2] SNext[2] |
| job | high (1) | Q1c | freedBy=JobCP.exec.free,staleBy=JobSP.proc.SP | 2 | 11 | gp1_fedavg_spCrash_p2 | JobSP_C_SPCrashRestart[1] |
| job | high (1) | S3Alloc | allocLost=JobCP.container.lifetime | 1 | 1 | gp1_k8s_cpCrash_p2 | JobCP_C_CPCrashRestart[1] |
| job | high (1) | Q1c | freedBy=JobCP.exec.free,staleBy=JobSP.proc.SP,unfinalized=JobSP.admin.shutdownLoop | 1 | 15 | gp1_multijob_spShutdown_p2 | SNext[1] |
| job | medium (2) | S3J2Gpu | gpuBy=JobCP.res.gpuEnv | 1 | 10 | gp1_multijobcp_cjCrash_p0 | SNext[2] |
| status | medium (2) | S6AckMeansDone | ackInferred | 1 | 9 | gp1_attach_tpReplyLost_p2 | SNext[2] |
