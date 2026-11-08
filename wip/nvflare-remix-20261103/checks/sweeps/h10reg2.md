# Hunt h10reg2

28 runs; wall 5744 s

| run | track | family | mode | result | violated | states/traces | s |
|---|---|---|---|---|---|---:|---:|
| h8D_c1bmulti_s1l1a1_v10 | D | multi | sim | violation | GOtherJobFinalizable | 2549 | 807.8 |
| h8D_cpRestart_s1l1a1_v10 | D | proc | sim | violation | Deadlock | 7 | 4.9 |
| h8D_cpRestart_s2l1a1_v10 | D | proc | sim | violation | Deadlock | 25 | 317.2 |
| h8D_del_s1l2a2_v10 | D | del | sim | violation | GSchedulerThreadAlive | 80 | 6.9 |
| h8D_del_s2l2a2_v10 | D | del | sim | violation | GSchedulerThreadAlive | 27 | 2.9 |
| h8D_job_s1l2a2_v10 | D | job | sim | violation | GSchedulerThreadAlive | 28 | 2.7 |
| h8D_job_s2l2a2_v10 | D | job | sim | violation | GSchedulerThreadAlive | 30 | 2.6 |
| h8D_l13_s1l1a1_v10 | D | status | bfs | violation | GFinishedNoPanic | 2548616 | 431.4 |
| h8D_l13sim_s1l1a1_v10 | D | status | sim | violation | GFinishedNoPanic | 170 | 326.2 |
| h8D_proc_s1l2a2_v10 | D | proc | sim | violation | GNoStaleStatusAfterRestart | 7 | 5.6 |
| h8D_proc_s2l2a2_v10 | D | proc | sim | violation | GNoStaleStatusAfterRestart | 7 | 23.3 |
| h8D_t2_s2l1a1_v10 | D | reg | bfs | violation | GCleanupThreadAlive | 624 | 8.2 |
| h8D_t2sim_s2l1a1_v10 | D | reg | sim | budget_stopped |  | 102 | 900.8 |
| h8D_t3_s2l1a1_v10 | D | reg | sim | violation | GCleanupThreadAliveK | 7 | 3.3 |
| h8S_allP_fam_s2l2a2_v10 | S | allP | sim | budget_stopped |  | 26 | 900.5 |
| h8S_cse_fam_s2l2a2_v10 | S | cse | sim | budget_stopped |  | 16 | 900.4 |
| h8S_del_fam_s2l2a2_v10 | S | del | sim | budget_stopped |  | 69 | 900.6 |
| h8S_err_fam_s2l2a2_v10 | S | err | sim | budget_stopped |  | 74 | 900.5 |
| h8S_jobP_fam_s2l2a2_v10 | S | jobP | sim | budget_stopped |  | 77 | 900.2 |
| h8S_job_fam_s2l2a2_v10 | S | job | sim | budget_stopped |  | 91 | 900.3 |
| h8S_multi_fam_s2l2a2_v10 | S | multi | sim | budget_stopped |  | 73 | 900.5 |
| h8S_net_fam_s2l2a2_v10 | S | net | sim | budget_stopped |  | 32 | 900.6 |
| h8S_proc_fam_s2l2a2_v10 | S | proc | sim | budget_stopped |  | 73 | 900.5 |
| h8S_reg_fam_s2l2a2_v10 | S | reg | sim | budget_stopped |  | 76 | 900.7 |
| h8S_restart_fam_s2l2a2_v10 | S | restart | sim | budget_stopped |  | 76 | 900.4 |
| h8S_status_fam_s2l2a2_v10 | S | status | sim | budget_stopped |  | 33 | 900.6 |
| h8S_tail_fam_s2l2a2_v10 | S | tail | sim | budget_stopped |  | 48 | 900.5 |
| h8S_task_fam_s2l2a2_v10 | S | task | sim | budget_stopped |  | 64 | 900.5 |
