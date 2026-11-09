# Hunt h11reg

28 runs; wall 2708 s

| run | track | family | mode | result | violated | states/traces | s |
|---|---|---|---|---|---|---:|---:|
| h8D_c1bmulti_s1l1a1_v11 | D | multi | sim | violation | GOtherJobFinalizable | 2496 | 1323.6 |
| h8D_cpRestart_s1l1a1_v11 | D | proc | sim | violation | Deadlock | 7 | 7.5 |
| h8D_cpRestart_s2l1a1_v11 | D | proc | sim | violation | Deadlock | 23 | 321.2 |
| h8D_del_s1l2a2_v11 | D | del | sim | violation | GSchedulerThreadAlive | 26 | 4.3 |
| h8D_del_s2l2a2_v11 | D | del | sim | violation | GSchedulerThreadAlive | 34 | 4.8 |
| h8D_job_s1l2a2_v11 | D | job | sim | violation | GSchedulerThreadAlive | 38 | 4.6 |
| h8D_job_s2l2a2_v11 | D | job | sim | violation | GSchedulerThreadAlive | 42 | 4.5 |
| h8D_l13_s1l1a1_v11 | D | status | bfs | violation | GFinishedNoPanic | 2488552 | 960.3 |
| h8D_l13sim_s1l1a1_v11 | D | status | sim | violation | GDoneSavedCompletedK | 255 | 899.3 |
| h8D_proc_s1l2a2_v11 | D | proc | sim | violation | GNoStaleStatusAfterRestart | 7 | 13.5 |
| h8D_proc_s2l2a2_v11 | D | proc | sim | violation | GNoStaleStatusAfterRestart | 7 | 16.5 |
| h8D_t2_s2l1a1_v11 | D | reg | bfs | violation | GCleanupThreadAlive | 614 | 4.9 |
| h8D_t2sim_s2l1a1_v11 | D | reg | sim | budget_stopped |  | 60 | 900.6 |
| h8D_t3_s2l1a1_v11 | D | reg | sim | violation | GCleanupThreadAliveK | 7 | 4.5 |
| h8S_allP_fam_s2l2a2_v11 | S | allP | sim | budget_stopped |  | 14 | 900.7 |
| h8S_cse_fam_s2l2a2_v11 | S | cse | sim | budget_stopped |  | 23 | 900.5 |
| h8S_del_fam_s2l2a2_v11 | S | del | sim | budget_stopped |  | 53 | 900.7 |
| h8S_err_fam_s2l2a2_v11 | S | err | sim | budget_stopped |  | 37 | 900.8 |
| h8S_jobP_fam_s2l2a2_v11 | S | jobP | sim | budget_stopped |  | 35 | 900.7 |
| h8S_job_fam_s2l2a2_v11 | S | job | sim | budget_stopped |  | 42 | 900.7 |
| h8S_multi_fam_s2l2a2_v11 | S | multi | sim | budget_stopped |  | 41 | 900.7 |
| h8S_net_fam_s2l2a2_v11 | S | net | sim | budget_stopped |  | 29 | 900.7 |
| h8S_proc_fam_s2l2a2_v11 | S | proc | sim | budget_stopped |  | 39 | 900.6 |
| h8S_reg_fam_s2l2a2_v11 | S | reg | sim | budget_stopped |  | 31 | 900.9 |
| h8S_restart_fam_s2l2a2_v11 | S | restart | sim | budget_stopped |  | 66 | 900.6 |
| h8S_status_fam_s2l2a2_v11 | S | status | sim | budget_stopped |  | 22 | 900.7 |
| h8S_tail_fam_s2l2a2_v11 | S | tail | sim | budget_stopped |  | 42 | 900.7 |
| h8S_task_fam_s2l2a2_v11 | S | task | sim | budget_stopped |  | 29 | 900.7 |
