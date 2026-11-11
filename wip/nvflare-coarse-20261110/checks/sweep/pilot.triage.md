# Triage pilot

16 counterexample cells, 10 (property, mechanism) groups

| property | mechanism | cells | min depth | min weight (tier) | configs x points | example |
|---|---|---:|---:|---|---|---|
| S3Resources | resource:liveWithoutAllocation:afterCPRestart | 3 | 1 | 1 (high) | k8s:cpCrash | pilot_k8s_cpCrash_p2 |
| S1ThreadsAlive | thread:scheduler@FALSE | 3 | 2 | 8 (very_low) | fedavg2:regIterRace | pilot_fedavg2_regIterRace_p0 |
| Q1Terminal | hang:afterCPRestart:RUNNING | 2 | 6 | 1 (high) | fedavg:cpCrash | pilot_fedavg_cpCrash_p2 |
| Q1Terminal | hang:afterSPRestart:RUNNING | 2 | 11 | 1 (high) | fedavg:spCrash | pilot_fedavg_spCrash_p5 |
| S1ThreadsAlive | thread:scheduler@TRUE | 1 | 2 | 2 (medium) | fedavg:deleteJob | pilot_fedavg_deleteJob_p0 |
| Q1Terminal | hang:afterSPRestart:DISPATCHED | 1 | 10 | 3 (medium) | fedavg:spCrash | pilot_fedavg_spCrash_p0 |
| S2TerminalFinal | overwrite:ABORTED->RUNNING | 1 | 14 | 1 (high) | fedavg:abort | pilot_fedavg_abort_p0 |
| S3Resources | resource:otherJobUsesOurUnit | 1 | 10 | 2 (medium) | multijobcp:cjCrash | pilot_multijobcp_cjCrash_p0 |
| S2TerminalFinal | overwrite:FAILED->RUNNING | 1 | 22 | 2 (medium) | fedavg:cjCrash | pilot_fedavg_cjCrash_p0 |
| S4Completed | completed:workflowNotDone | 1 | 17 | 1 (high) | fedavg:abort | pilot_fedavg_abort_p5 |
