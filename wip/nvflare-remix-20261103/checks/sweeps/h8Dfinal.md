# Hunt h8Dfinal

12 runs; wall 594 s

| run | track | family | mode | result | violated | states/traces | s |
|---|---|---|---|---|---|---:|---:|
| h8D_c1bmulti_s1l1a1_final | D | multi | sim | violation | GOtherJobFinalizable | 2565 | 593.4 |
| h8D_cpRestart_s1l1a1_final | D | proc | sim | violation | Deadlock | 12 | 27.0 |
| h8D_cpRestart_s2l1a1_final | D | proc | sim | violation | Deadlock | 70 | 580.6 |
| h8D_del_s1l2a2_final | D | del | sim | violation | GSchedulerThreadAlive | 53 | 3.1 |
| h8D_del_s2l2a2_final | D | del | sim | violation | GSchedulerThreadAlive | 40 | 2.6 |
| h8D_job_s1l2a2_final | D | job | sim | violation | GSchedulerThreadAlive | 51 | 3.1 |
| h8D_job_s2l2a2_final | D | job | sim | violation | GSchedulerThreadAlive | 56 | 3.0 |
| h8D_l13_s1l1a1_final | D | status | bfs | violation | GFinishedNoPanic | 2519299 | 499.4 |
| h8D_proc_s1l2a2_final | D | proc | sim | violation | GNoStaleStatusAfterRestart | 7 | 7.2 |
| h8D_proc_s2l2a2_final | D | proc | sim | violation | GNoStaleStatusAfterRestart | 7 | 13.3 |
| h8D_t2_s2l1a1_final | D | reg | bfs | violation | GCleanupThreadAlive | 615 | 4.3 |
| h8D_t3_s2l1a1_final | D | reg | sim | violation | GCleanupThreadAliveK | 7 | 4.6 |
