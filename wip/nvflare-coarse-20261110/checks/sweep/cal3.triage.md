# Triage cal3

66 counterexample cells, 5 (property, mechanism) groups

| property | mechanism | cells | min depth | min weight (tier) | configs x points | example |
|---|---|---:|---:|---|---|---|
| F_Q1Terminal | hang:RUNNING | 53 | 19 | 1 (high) | cse:spShutdown, cseserver:spShutdown, cyclic:spShutdown, docker:spShutdown, fedavg2:spShutdown, fedavg:slowShutdownAbort, fedavg:spShutdown, k8s:spShutdown ... | cal3_fedavg_spShutdown_p5 |
| F_S5StatusMeaning | meaning:FAILED_TO_RUN | 5 | 32 | 4 (low) | cseserver:cjCrash, cseserver:cpCrash, cyclic:cjCrash | cal3_cseserver_cpCrash_p0 |
| F_S4Completed | completed:workflowNotDone | 4 | 15 | 5 (low) | fedavg:slowShutdownAbort, multijob:slowShutdownAbort | cal3_fedavg_slowShutdownAbort_p1 |
| F_S4Completed | completed:badArtifact | 3 | 74 | 4 (low) | sag:acceptRaise | cal3_sag_acceptRaise_p2 |
| F_Q1Terminal | hang:SUBMITTED | 1 | 5 | 0 (high) | cseserver:spShutdown | cal3_cseserver_spShutdown_p0 |
