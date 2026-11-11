# Sweep g1a

2841 cells: {'pass_exhaustive': 871, 'violation': 762, 'violation_sim': 146, 'budget_stopped': 1062}

| config | point | phase | result | violated | distinct | depth | s |
|---|---|---:|---|---|---:|---:|---:|
| attach | abort | 0 | budget_stopped |  | 20687 | 57 | 90.2 |
| attach | abort | 1 | budget_stopped |  | 22795 | 49 | 90.2 |
| attach | abort | 2 | budget_stopped |  | 55305 | 18 | 90.2 |
| attach | abort | 3 | budget_stopped |  | 30014 | 15 | 90.2 |
| attach | abort | 5 | budget_stopped |  | 27443 | 19 | 90.3 |
| attach | cjCrash | 0 | pass_exhaustive |  | 5 | 5 | 3.1 |
| attach | cjCrash | 1 | violation | S2F | 22857 | 15 | 23.1 |
| attach | cjCrash | 2 | budget_stopped |  | 60191 | 24 | 90.2 |
| attach | cjCrash | 3 | budget_stopped |  | 34680 | 21 | 90.3 |
| attach | cjCrash | 5 | pass_exhaustive |  | 40568 | 23 | 88.3 |
| attach | cpCrash | 0 | pass_exhaustive |  | 35 | 9 | 2.8 |
| attach | cpCrash | 1 | violation | I_Q | 13581 | 12 | 18.8 |
| attach | cpCrash | 2 | violation | I_Q | 18 | 8 | 2.9 |
| attach | cpCrash | 3 | pass_exhaustive |  | 1368 | 23 | 8.7 |
| attach | cpCrash | 5 | pass_exhaustive |  | 3215 | 17 | 11.0 |
| attach | deadClient | 0 | budget_stopped |  | 57328 | 29 | 90.3 |
| attach | deadClient | 1 | budget_stopped |  | 59209 | 23 | 90.2 |
| attach | deadClient | 2 | budget_stopped |  | 37278 | 19 | 90.3 |
| attach | deadClient | 3 | budget_stopped |  | 28133 | 20 | 90.3 |
| attach | deadClient | 5 | pass_exhaustive |  | 9412 | 15 | 21.1 |
| attach | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.4 |
| attach | deleteJob | 1 | pass_exhaustive |  | 1665 | 44 | 8.1 |
| attach | deleteJob | 2 | pass_exhaustive |  | 131 | 39 | 4.6 |
| attach | deleteJob | 3 | pass_exhaustive |  | 72 | 18 | 3.9 |
| attach | deleteJob | 5 | pass_exhaustive |  | 198 | 27 | 4.7 |
| attach | netLoss | 0 | budget_stopped |  | 26412 | 34 | 90.2 |
| attach | netLoss | 1 | budget_stopped |  | 30435 | 21 | 90.3 |
| attach | netLoss | 2 | budget_stopped |  | 23877 | 20 | 90.2 |
| attach | netLoss | 3 | budget_stopped |  | 22107 | 10 | 90.3 |
| attach | netLoss | 5 | budget_stopped |  | 21765 | 10 | 90.3 |
| attach | resultWaitTimeout | 0 | pass_exhaustive |  | 5 | 5 | 3.2 |
| attach | resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.3 |
| attach | resultWaitTimeout | 2 | budget_stopped |  | 35829 | 29 | 90.3 |
| attach | resultWaitTimeout | 3 | budget_stopped |  | 23942 | 22 | 90.3 |
| attach | resultWaitTimeout | 5 | pass_exhaustive |  | 620 | 27 | 5.9 |
| attach | rpcTimeout | 0 | pass_exhaustive |  | 35 | 9 | 2.9 |
| attach | rpcTimeout | 1 | budget_stopped |  | 54184 | 23 | 90.3 |
| attach | rpcTimeout | 2 | pass_exhaustive |  | 131 | 39 | 4.1 |
| attach | rpcTimeout | 3 | pass_exhaustive |  | 72 | 18 | 3.5 |
| attach | rpcTimeout | 5 | pass_exhaustive |  | 423 | 28 | 5.2 |
| attach | sjCrash | 0 | pass_exhaustive |  | 5 | 5 | 2.9 |
| attach | sjCrash | 1 | violation | S2F | 1110 | 18 | 5.5 |
| attach | sjCrash | 2 | pass_exhaustive |  | 33439 | 17 | 40.5 |
| attach | sjCrash | 3 | pass_exhaustive |  | 27152 | 13 | 42.5 |
| attach | sjCrash | 5 | pass_exhaustive |  | 17402 | 12 | 26.8 |
| attach | spCrash | 0 | pass_exhaustive |  | 35 | 9 | 3.2 |
| attach | spCrash | 1 | violation | I_Q | 78 | 7 | 3.3 |
| attach | spCrash | 2 | violation | I_Q | 141 | 13 | 4.6 |
| attach | spCrash | 3 | violation | I_Q | 270 | 18 | 5.5 |
| attach | spCrash | 5 | violation | I_Q | 238 | 13 | 6.0 |
| attach | spShutdown | 0 | violation | I_Q | 40 | 7 | 3.3 |
| attach | spShutdown | 1 | violation_sim | I_Q | 72642 | 24 | 90.2 |
| attach | spShutdown | 2 | violation | I_Q | 2933 | 20 | 9.3 |
| attach | spShutdown | 3 | violation | I_Q | 7667 | 16 | 19.7 |
| attach | spShutdown | 5 | violation | I_Q | 4355 | 14 | 12.4 |
| attach | taskTimeout | 0 | pass_exhaustive |  | 5 | 5 | 3.0 |
| attach | taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| attach | taskTimeout | 2 | budget_stopped |  | 45411 | 23 | 90.2 |
| attach | taskTimeout | 3 | budget_stopped |  | 17223 | 18 | 90.2 |
| attach | taskTimeout | 5 | pass_exhaustive |  | 1880 | 13 | 7.6 |
| attach | tpAttachLate | 0 | pass_exhaustive |  | 5 | 5 | 2.7 |
| attach | tpAttachLate | 1 | pass_exhaustive |  | 8 | 8 | 2.7 |
| attach | tpAttachLate | 2 | pass_exhaustive |  | 425 | 39 | 5.7 |
| attach | tpAttachLate | 3 | pass_exhaustive |  | 14 | 7 | 3.4 |
| attach | tpAttachLate | 5 | pass_exhaustive |  | 159 | 26 | 4.2 |
| attach | tpAttachLate__abort | 1 | budget_stopped |  | 45473 | 27 | 90.3 |
| attach | tpAttachLate__abort | 2 | budget_stopped |  | 55969 | 18 | 90.3 |
| attach | tpAttachLate__abort | 3 | budget_stopped |  | 27537 | 15 | 90.3 |
| attach | tpAttachLate__cjCrash | 1 | violation | S2F | 40661 | 14 | 39.2 |
| attach | tpAttachLate__cjCrash | 2 | budget_stopped |  | 57248 | 23 | 90.3 |
| attach | tpAttachLate__cjCrash | 3 | budget_stopped |  | 34837 | 21 | 90.3 |
| attach | tpAttachLate__netLoss | 1 | budget_stopped |  | 34549 | 22 | 90.3 |
| attach | tpAttachLate__netLoss | 2 | budget_stopped |  | 26486 | 19 | 90.3 |
| attach | tpAttachLate__netLoss | 3 | budget_stopped |  | 19773 | 11 | 90.3 |
| attach | tpAttachLate__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.3 |
| attach | tpAttachLate__resultWaitTimeout | 2 | budget_stopped |  | 29068 | 27 | 90.3 |
| attach | tpAttachLate__resultWaitTimeout | 3 | budget_stopped |  | 21808 | 22 | 90.3 |
| attach | tpAttachLate__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| attach | tpAttachLate__taskTimeout | 2 | budget_stopped |  | 37190 | 21 | 90.3 |
| attach | tpAttachLate__taskTimeout | 3 | budget_stopped |  | 17206 | 18 | 90.3 |
| attach | tpCrash | 0 | pass_exhaustive |  | 5 | 5 | 3.0 |
| attach | tpCrash | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| attach | tpCrash | 2 | pass_exhaustive |  | 29480 | 20 | 44.1 |
| attach | tpCrash | 3 | pass_exhaustive |  | 14 | 7 | 3.4 |
| attach | tpCrash | 5 | pass_exhaustive |  | 1071 | 32 | 5.8 |
| attach | tpCrash__abort | 1 | budget_stopped |  | 40681 | 26 | 90.3 |
| attach | tpCrash__abort | 2 | budget_stopped |  | 49973 | 17 | 90.3 |
| attach | tpCrash__abort | 3 | budget_stopped |  | 25748 | 13 | 90.2 |
| attach | tpCrash__cjCrash | 1 | violation | S2F | 31970 | 14 | 33.8 |
| attach | tpCrash__cjCrash | 2 | budget_stopped |  | 57261 | 22 | 90.3 |
| attach | tpCrash__cjCrash | 3 | budget_stopped |  | 34808 | 18 | 90.3 |
| attach | tpCrash__netLoss | 1 | budget_stopped |  | 32485 | 21 | 90.2 |
| attach | tpCrash__netLoss | 2 | budget_stopped |  | 27963 | 18 | 90.3 |
| attach | tpCrash__netLoss | 3 | budget_stopped |  | 23669 | 9 | 90.2 |
| attach | tpCrash__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.3 |
| attach | tpCrash__resultWaitTimeout | 2 | budget_stopped |  | 25143 | 25 | 90.2 |
| attach | tpCrash__resultWaitTimeout | 3 | budget_stopped |  | 20402 | 17 | 90.2 |
| attach | tpCrash__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| attach | tpCrash__taskTimeout | 2 | budget_stopped |  | 35625 | 20 | 90.2 |
| attach | tpCrash__taskTimeout | 3 | budget_stopped |  | 17550 | 15 | 90.3 |
| attach | tpReplyLost | 0 | pass_exhaustive |  | 5 | 5 | 3.2 |
| attach | tpReplyLost | 1 | pass_exhaustive |  | 8 | 8 | 3.1 |
| attach | tpReplyLost | 2 | violation | S6AckMeansDone | 54 | 12 | 4.2 |
| attach | tpReplyLost | 3 | pass_exhaustive |  | 14 | 7 | 3.6 |
| attach | tpReplyLost | 5 | pass_exhaustive |  | 159 | 26 | 4.2 |
| attach | tpReplyLost__abort | 1 | violation | S6AckMeansDone | 2119 | 15 | 9.6 |
| attach | tpReplyLost__abort | 2 | violation | S6AckMeansDone | 1533 | 11 | 6.9 |
| attach | tpReplyLost__abort | 3 | violation | S6AckMeansDone | 2568 | 9 | 10.0 |
| attach | tpReplyLost__cjCrash | 1 | violation | S6AckMeansDone | 20043 | 16 | 19.3 |
| attach | tpReplyLost__cjCrash | 2 | violation | S6AckMeansDone | 307 | 11 | 4.8 |
| attach | tpReplyLost__cjCrash | 3 | violation | S6AckMeansDone | 410 | 10 | 5.2 |
| attach | tpReplyLost__netLoss | 1 | violation | S6AckMeansDone | 22306 | 11 | 43.5 |
| attach | tpReplyLost__netLoss | 2 | violation | S6AckMeansDone | 2491 | 9 | 9.4 |
| attach | tpReplyLost__netLoss | 3 | violation | S6AckMeansDone | 31822 | 10 | 87.4 |
| attach | tpReplyLost__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| attach | tpReplyLost__resultWaitTimeout | 2 | violation | S6AckMeansDone | 205 | 11 | 4.6 |
| attach | tpReplyLost__resultWaitTimeout | 3 | violation | S6AckMeansDone | 683 | 10 | 6.4 |
| attach | tpReplyLost__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| attach | tpReplyLost__taskTimeout | 2 | violation | S6AckMeansDone | 301 | 10 | 4.9 |
| attach | tpReplyLost__taskTimeout | 3 | violation | S6AckMeansDone | 918 | 9 | 7.0 |
| attach | tpSilent | 0 | pass_exhaustive |  | 5 | 5 | 3.1 |
| attach | tpSilent | 1 | pass_exhaustive |  | 8 | 8 | 3.2 |
| attach | tpSilent | 2 | pass_exhaustive |  | 29480 | 20 | 40.6 |
| attach | tpSilent | 3 | pass_exhaustive |  | 14 | 7 | 3.5 |
| attach | tpSilent | 5 | pass_exhaustive |  | 1071 | 32 | 5.8 |
| attach | tpSilent__abort | 1 | budget_stopped |  | 43929 | 26 | 90.2 |
| attach | tpSilent__abort | 2 | budget_stopped |  | 53660 | 18 | 90.3 |
| attach | tpSilent__abort | 3 | budget_stopped |  | 27992 | 13 | 90.3 |
| attach | tpSilent__cjCrash | 1 | violation | S2F | 31146 | 14 | 29.9 |
| attach | tpSilent__cjCrash | 2 | budget_stopped |  | 59626 | 23 | 90.3 |
| attach | tpSilent__cjCrash | 3 | budget_stopped |  | 36969 | 18 | 90.3 |
| attach | tpSilent__netLoss | 1 | budget_stopped |  | 34329 | 21 | 90.3 |
| attach | tpSilent__netLoss | 2 | budget_stopped |  | 29576 | 18 | 90.3 |
| attach | tpSilent__netLoss | 3 | budget_stopped |  | 23367 | 9 | 90.3 |
| attach | tpSilent__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.1 |
| attach | tpSilent__resultWaitTimeout | 2 | budget_stopped |  | 25143 | 25 | 90.3 |
| attach | tpSilent__resultWaitTimeout | 3 | budget_stopped |  | 18904 | 16 | 90.3 |
| attach | tpSilent__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.4 |
| attach | tpSilent__taskTimeout | 2 | budget_stopped |  | 36193 | 20 | 90.3 |
| attach | tpSilent__taskTimeout | 3 | budget_stopped |  | 20627 | 15 | 90.3 |
| attach | trainerError | 0 | pass_exhaustive |  | 5 | 5 | 3.2 |
| attach | trainerError | 1 | pass_exhaustive |  | 8 | 8 | 3.1 |
| attach | trainerError | 2 | violation | I_Q | 35 | 12 | 4.0 |
| attach | trainerError | 3 | pass_exhaustive |  | 14 | 7 | 3.4 |
| attach | trainerError | 5 | pass_exhaustive |  | 159 | 26 | 4.5 |
| attach | trainerError__abort | 1 | violation | I_Q | 2673 | 15 | 11.1 |
| attach | trainerError__abort | 2 | violation | I_Q | 1547 | 11 | 7.5 |
| attach | trainerError__abort | 3 | budget_stopped |  | 27998 | 15 | 90.2 |
| attach | trainerError__cjCrash | 1 | violation | S2F | 25154 | 15 | 23.4 |
| attach | trainerError__cjCrash | 2 | violation | I_Q | 300 | 11 | 3.5 |
| attach | trainerError__cjCrash | 3 | budget_stopped |  | 36410 | 20 | 90.3 |
| attach | trainerError__netLoss | 1 | violation | I_Q | 27455 | 12 | 66.0 |
| attach | trainerError__netLoss | 2 | violation | I_Q | 1462 | 9 | 8.3 |
| attach | trainerError__netLoss | 3 | budget_stopped |  | 20145 | 10 | 90.3 |
| attach | trainerError__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| attach | trainerError__resultWaitTimeout | 2 | violation | I_Q | 174 | 11 | 4.7 |
| attach | trainerError__resultWaitTimeout | 3 | budget_stopped |  | 19241 | 20 | 90.3 |
| attach | trainerError__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.1 |
| attach | trainerError__taskTimeout | 2 | violation | I_Q | 281 | 10 | 5.2 |
| attach | trainerError__taskTimeout | 3 | budget_stopped |  | 16970 | 17 | 90.3 |
| cse | abort | 0 | budget_stopped |  | 13047 | 30 | 90.2 |
| cse | abort | 1 | budget_stopped |  | 14652 | 20 | 90.3 |
| cse | abort | 2 | budget_stopped |  | 17087 | 12 | 90.3 |
| cse | abort | 3 | budget_stopped |  | 13138 | 12 | 90.2 |
| cse | abort | 5 | budget_stopped |  | 11910 | 12 | 90.3 |
| cse | cjCrash | 0 | pass_exhaustive |  | 9 | 7 | 2.8 |
| cse | cjCrash | 1 | violation_sim | S2F | 33470 | 18 | 90.3 |
| cse | cjCrash | 2 | budget_stopped |  | 25309 | 16 | 90.3 |
| cse | cjCrash | 3 | budget_stopped |  | 16801 | 16 | 90.3 |
| cse | cjCrash | 5 | budget_stopped |  | 14159 | 13 | 90.3 |
| cse | cpCrash | 0 | pass_exhaustive |  | 131 | 12 | 3.6 |
| cse | cpCrash | 1 | budget_stopped |  | 36687 | 13 | 90.3 |
| cse | cpCrash | 2 | violation | I_Q | 1179 | 29 | 12.9 |
| cse | cpCrash | 3 | violation | I_Q | 76 | 13 | 6.1 |
| cse | cpCrash | 5 | budget_stopped |  | 9731 | 18 | 90.2 |
| cse | deadClient | 0 | violation | S1Cleanup | 171 | 7 | 3.4 |
| cse | deadClient | 1 | violation | S1Cleanup | 203 | 6 | 4.0 |
| cse | deadClient | 2 | violation | S1Cleanup | 2138 | 6 | 10.3 |
| cse | deadClient | 3 | violation | S1Cleanup | 395 | 9 | 6.4 |
| cse | deadClient | 5 | violation | S1Cleanup | 181 | 6 | 5.5 |
| cse | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.6 |
| cse | deleteJob | 1 | budget_stopped |  | 33514 | 35 | 90.2 |
| cse | deleteJob | 2 | pass_exhaustive |  | 1583 | 26 | 16.5 |
| cse | deleteJob | 3 | pass_exhaustive |  | 39 | 14 | 4.8 |
| cse | deleteJob | 5 | pass_exhaustive |  | 5774 | 25 | 39.8 |
| cse | netLoss | 0 | budget_stopped |  | 19452 | 24 | 90.3 |
| cse | netLoss | 1 | budget_stopped |  | 22231 | 15 | 90.3 |
| cse | netLoss | 2 | budget_stopped |  | 14128 | 9 | 90.3 |
| cse | netLoss | 3 | budget_stopped |  | 11638 | 8 | 90.2 |
| cse | netLoss | 5 | budget_stopped |  | 10586 | 6 | 90.3 |
| cse | rpcTimeout | 0 | pass_exhaustive |  | 131 | 12 | 3.6 |
| cse | rpcTimeout | 1 | budget_stopped |  | 33076 | 14 | 90.4 |
| cse | rpcTimeout | 2 | pass_exhaustive |  | 1583 | 28 | 14.6 |
| cse | rpcTimeout | 3 | pass_exhaustive |  | 39 | 14 | 4.2 |
| cse | rpcTimeout | 5 | budget_stopped |  | 11156 | 29 | 90.3 |
| cse | sjCrash | 0 | pass_exhaustive |  | 9 | 7 | 3.6 |
| cse | sjCrash | 1 | violation | S2F | 11981 | 17 | 31.9 |
| cse | sjCrash | 2 | budget_stopped |  | 37797 | 17 | 90.3 |
| cse | sjCrash | 3 | budget_stopped |  | 26287 | 22 | 90.2 |
| cse | sjCrash | 5 | budget_stopped |  | 23712 | 14 | 90.3 |
| cse | spCrash | 0 | pass_exhaustive |  | 131 | 12 | 3.7 |
| cse | spCrash | 1 | violation | I_Q | 240 | 8 | 4.7 |
| cse | spCrash | 2 | violation | I_Q | 7816 | 28 | 55.9 |
| cse | spCrash | 3 | violation | I_Q | 3413 | 15 | 34.4 |
| cse | spCrash | 5 | violation_sim | I_Q | 8710 | 19 | 90.3 |
| cse | spShutdown | 0 | violation | I_Q | 51 | 7 | 3.6 |
| cse | spShutdown | 1 | violation_sim | I_Q | 69358 | 16 | 90.3 |
| cse | spShutdown | 2 | violation_sim | I_Q | 16245 | 39 | 90.3 |
| cse | spShutdown | 3 | violation_sim | I_Q | 13766 | 20 | 90.3 |
| cse | spShutdown | 5 | violation_sim | I_Q | 13608 | 19 | 90.3 |
| cse | taskTimeout | 0 | pass_exhaustive |  | 9 | 7 | 2.9 |
| cse | taskTimeout | 1 | pass_exhaustive |  | 28 | 12 | 3.0 |
| cse | taskTimeout | 2 | budget_stopped |  | 14710 | 12 | 90.2 |
| cse | taskTimeout | 3 | budget_stopped |  | 8803 | 14 | 90.3 |
| cse | taskTimeout | 5 | budget_stopped |  | 7791 | 11 | 90.3 |
| cseserver | abort | 0 | budget_stopped |  | 12102 | 30 | 90.3 |
| cseserver | abort | 1 | budget_stopped |  | 13516 | 20 | 90.2 |
| cseserver | abort | 2 | budget_stopped |  | 17896 | 14 | 90.2 |
| cseserver | abort | 3 | budget_stopped |  | 13130 | 13 | 90.3 |
| cseserver | abort | 5 | budget_stopped |  | 13461 | 10 | 90.3 |
| cseserver | cbFail | 0 | pass_exhaustive |  | 9 | 7 | 3.0 |
| cseserver | cbFail | 1 | budget_stopped |  | 13831 | 29 | 90.3 |
| cseserver | cbFail | 2 | budget_stopped |  | 15534 | 44 | 90.3 |
| cseserver | cbFail | 3 | pass_exhaustive |  | 63 | 12 | 4.3 |
| cseserver | cbFail | 5 | budget_stopped |  | 16769 | 15 | 90.3 |
| cseserver | cbFail__abort | 1 | budget_stopped |  | 13483 | 20 | 90.2 |
| cseserver | cbFail__abort | 2 | budget_stopped |  | 17315 | 14 | 90.3 |
| cseserver | cbFail__abort | 3 | budget_stopped |  | 13737 | 13 | 90.3 |
| cseserver | cbFail__cjCrash | 1 | budget_stopped |  | 31780 | 16 | 90.2 |
| cseserver | cbFail__cjCrash | 2 | budget_stopped |  | 20990 | 12 | 90.3 |
| cseserver | cbFail__cjCrash | 3 | budget_stopped |  | 15899 | 11 | 90.2 |
| cseserver | cbFail__deadClient | 1 | violation | S1Cleanup | 265 | 7 | 3.7 |
| cseserver | cbFail__deadClient | 2 | violation | S1Cleanup | 808 | 7 | 6.3 |
| cseserver | cbFail__deadClient | 3 | violation | S1Cleanup | 513 | 7 | 6.5 |
| cseserver | cbFail__deleteJob | 1 | budget_stopped |  | 14407 | 23 | 90.3 |
| cseserver | cbFail__deleteJob | 2 | budget_stopped |  | 17296 | 44 | 90.3 |
| cseserver | cbFail__deleteJob | 3 | pass_exhaustive |  | 63 | 12 | 4.2 |
| cseserver | cbFail__netLoss | 1 | budget_stopped |  | 22985 | 15 | 90.2 |
| cseserver | cbFail__netLoss | 2 | budget_stopped |  | 13617 | 11 | 90.2 |
| cseserver | cbFail__netLoss | 3 | budget_stopped |  | 12092 | 8 | 90.3 |
| cseserver | cbFail__rpcTimeout | 1 | budget_stopped |  | 32419 | 14 | 90.3 |
| cseserver | cbFail__rpcTimeout | 2 | budget_stopped |  | 13927 | 43 | 90.3 |
| cseserver | cbFail__rpcTimeout | 3 | pass_exhaustive |  | 63 | 12 | 3.9 |
| cseserver | cbFail__sjCrash | 1 | violation | S2F | 11529 | 16 | 29.2 |
| cseserver | cbFail__sjCrash | 2 | budget_stopped |  | 37344 | 20 | 90.2 |
| cseserver | cbFail__sjCrash | 3 | budget_stopped |  | 29177 | 20 | 90.3 |
| cseserver | cbFail__spCrash | 1 | violation | I_Q | 234 | 8 | 4.3 |
| cseserver | cbFail__spCrash | 2 | violation_sim | I_Q | 14008 | 18 | 90.3 |
| cseserver | cbFail__spCrash | 3 | violation_sim | I_Q | 11873 | 19 | 90.2 |
| cseserver | cbFail__spShutdown | 1 | violation_sim | I_Q | 32932 | 14 | 90.3 |
| cseserver | cbFail__spShutdown | 2 | violation_sim | I_Q | 17687 | 13 | 90.3 |
| cseserver | cbFail__spShutdown | 3 | violation_sim | I_Q | 12747 | 13 | 90.3 |
| cseserver | cbFail__taskTimeout | 1 | budget_stopped |  | 13868 | 26 | 90.2 |
| cseserver | cbFail__taskTimeout | 2 | budget_stopped |  | 13765 | 17 | 90.2 |
| cseserver | cbFail__taskTimeout | 3 | budget_stopped |  | 10038 | 14 | 90.3 |
| cseserver | cjCrash | 0 | pass_exhaustive |  | 9 | 7 | 3.0 |
| cseserver | cjCrash | 1 | violation_sim | S2F | 32496 | 18 | 90.3 |
| cseserver | cjCrash | 2 | budget_stopped |  | 24135 | 16 | 90.2 |
| cseserver | cjCrash | 3 | budget_stopped |  | 18112 | 16 | 90.2 |
| cseserver | cjCrash | 5 | budget_stopped |  | 13627 | 11 | 90.3 |
| cseserver | cpCrash | 0 | pass_exhaustive |  | 131 | 12 | 3.2 |
| cseserver | cpCrash | 1 | budget_stopped |  | 35619 | 13 | 90.3 |
| cseserver | cpCrash | 2 | violation | I_Q | 48 | 5 | 4.7 |
| cseserver | cpCrash | 3 | violation | I_Q | 70 | 10 | 4.9 |
| cseserver | cpCrash | 5 | budget_stopped |  | 7144 | 20 | 90.3 |
| cseserver | deadClient | 0 | violation | S1Cleanup | 171 | 7 | 3.1 |
| cseserver | deadClient | 1 | violation | S1Cleanup | 196 | 6 | 3.4 |
| cseserver | deadClient | 2 | violation | S1Cleanup | 1020 | 9 | 7.1 |
| cseserver | deadClient | 3 | violation | S1Cleanup | 513 | 7 | 6.6 |
| cseserver | deadClient | 5 | violation | S1Cleanup | 424 | 6 | 7.0 |
| cseserver | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.2 |
| cseserver | deleteJob | 1 | budget_stopped |  | 33036 | 35 | 90.2 |
| cseserver | deleteJob | 2 | pass_exhaustive |  | 243 | 38 | 6.0 |
| cseserver | deleteJob | 3 | pass_exhaustive |  | 35 | 12 | 4.5 |
| cseserver | deleteJob | 5 | budget_stopped |  | 11637 | 37 | 90.3 |
| cseserver | netLoss | 0 | budget_stopped |  | 18355 | 24 | 90.2 |
| cseserver | netLoss | 1 | budget_stopped |  | 22642 | 15 | 90.2 |
| cseserver | netLoss | 2 | budget_stopped |  | 13293 | 11 | 90.3 |
| cseserver | netLoss | 3 | budget_stopped |  | 11752 | 8 | 90.2 |
| cseserver | netLoss | 5 | budget_stopped |  | 12148 | 6 | 90.2 |
| cseserver | rpcTimeout | 0 | pass_exhaustive |  | 131 | 12 | 4.1 |
| cseserver | rpcTimeout | 1 | budget_stopped |  | 31618 | 14 | 90.2 |
| cseserver | rpcTimeout | 2 | pass_exhaustive |  | 243 | 38 | 6.1 |
| cseserver | rpcTimeout | 3 | pass_exhaustive |  | 35 | 12 | 4.3 |
| cseserver | rpcTimeout | 5 | budget_stopped |  | 9325 | 31 | 90.3 |
| cseserver | sjCrash | 0 | pass_exhaustive |  | 9 | 7 | 3.3 |
| cseserver | sjCrash | 1 | violation | S2F | 11039 | 16 | 27.7 |
| cseserver | sjCrash | 2 | budget_stopped |  | 33971 | 20 | 90.3 |
| cseserver | sjCrash | 3 | budget_stopped |  | 29021 | 20 | 90.3 |
| cseserver | sjCrash | 5 | budget_stopped |  | 24267 | 12 | 90.3 |
| cseserver | spCrash | 0 | pass_exhaustive |  | 131 | 12 | 4.0 |
| cseserver | spCrash | 1 | violation | I_Q | 179 | 7 | 4.3 |
| cseserver | spCrash | 2 | violation | I_Q | 5562 | 10 | 34.1 |
| cseserver | spCrash | 3 | violation | I_Q | 3529 | 15 | 33.2 |
| cseserver | spCrash | 5 | violation_sim | I_Q | 9513 | 22 | 90.3 |
| cseserver | spShutdown | 0 | violation | I_Q | 51 | 7 | 3.8 |
| cseserver | spShutdown | 1 | violation_sim | I_Q | 65800 | 16 | 90.2 |
| cseserver | spShutdown | 2 | violation_sim | I_Q | 17081 | 21 | 90.3 |
| cseserver | spShutdown | 3 | violation_sim | I_Q | 13973 | 18 | 90.3 |
| cseserver | spShutdown | 5 | violation_sim | I_Q | 13830 | 19 | 90.2 |
| cseserver | taskTimeout | 0 | pass_exhaustive |  | 9 | 7 | 3.1 |
| cseserver | taskTimeout | 1 | pass_exhaustive |  | 28 | 12 | 3.2 |
| cseserver | taskTimeout | 2 | budget_stopped |  | 13706 | 17 | 90.2 |
| cseserver | taskTimeout | 3 | budget_stopped |  | 10025 | 14 | 90.3 |
| cseserver | taskTimeout | 5 | budget_stopped |  | 10134 | 10 | 90.2 |
| cyclic | abort | 0 | budget_stopped |  | 14227 | 31 | 90.3 |
| cyclic | abort | 1 | budget_stopped |  | 14400 | 20 | 90.2 |
| cyclic | abort | 2 | budget_stopped |  | 18093 | 14 | 90.3 |
| cyclic | abort | 3 | budget_stopped |  | 13311 | 12 | 90.3 |
| cyclic | abort | 5 | budget_stopped |  | 12687 | 10 | 90.2 |
| cyclic | cbFail | 0 | pass_exhaustive |  | 9 | 7 | 3.1 |
| cyclic | cbFail | 1 | budget_stopped |  | 13792 | 29 | 90.3 |
| cyclic | cbFail | 2 | budget_stopped |  | 14278 | 44 | 90.2 |
| cyclic | cbFail | 3 | pass_exhaustive |  | 67 | 14 | 4.4 |
| cyclic | cbFail | 5 | budget_stopped |  | 17262 | 15 | 90.2 |
| cyclic | cbFail__abort | 1 | budget_stopped |  | 13883 | 20 | 90.3 |
| cyclic | cbFail__abort | 2 | budget_stopped |  | 17947 | 14 | 90.3 |
| cyclic | cbFail__abort | 3 | budget_stopped |  | 13583 | 12 | 90.2 |
| cyclic | cbFail__cjCrash | 1 | violation_sim | S2F | 35355 | 16 | 90.3 |
| cyclic | cbFail__cjCrash | 2 | budget_stopped |  | 22548 | 12 | 90.3 |
| cyclic | cbFail__cjCrash | 3 | budget_stopped |  | 16284 | 11 | 90.3 |
| cyclic | cbFail__deadClient | 1 | violation | S1Cleanup | 201 | 6 | 3.8 |
| cyclic | cbFail__deadClient | 2 | violation | S1Cleanup | 728 | 7 | 5.9 |
| cyclic | cbFail__deadClient | 3 | violation | S1Cleanup | 388 | 9 | 6.5 |
| cyclic | cbFail__deleteJob | 1 | budget_stopped |  | 14375 | 23 | 90.2 |
| cyclic | cbFail__deleteJob | 2 | budget_stopped |  | 15839 | 44 | 90.2 |
| cyclic | cbFail__deleteJob | 3 | pass_exhaustive |  | 67 | 14 | 4.5 |
| cyclic | cbFail__netLoss | 1 | budget_stopped |  | 22035 | 15 | 90.3 |
| cyclic | cbFail__netLoss | 2 | budget_stopped |  | 12450 | 11 | 90.2 |
| cyclic | cbFail__netLoss | 3 | budget_stopped |  | 11622 | 8 | 90.3 |
| cyclic | cbFail__rpcTimeout | 1 | budget_stopped |  | 33322 | 14 | 90.3 |
| cyclic | cbFail__rpcTimeout | 2 | budget_stopped |  | 16405 | 45 | 90.3 |
| cyclic | cbFail__rpcTimeout | 3 | pass_exhaustive |  | 67 | 14 | 4.0 |
| cyclic | cbFail__sjCrash | 1 | violation | S2F | 12195 | 16 | 28.6 |
| cyclic | cbFail__sjCrash | 2 | budget_stopped |  | 37463 | 20 | 90.3 |
| cyclic | cbFail__sjCrash | 3 | budget_stopped |  | 29760 | 23 | 90.3 |
| cyclic | cbFail__spCrash | 1 | violation | I_Q | 254 | 8 | 4.1 |
| cyclic | cbFail__spCrash | 2 | violation_sim | I_Q | 14020 | 19 | 90.2 |
| cyclic | cbFail__spCrash | 3 | violation_sim | I_Q | 10913 | 21 | 90.3 |
| cyclic | cbFail__spShutdown | 1 | violation_sim | I_Q | 33905 | 14 | 90.3 |
| cyclic | cbFail__spShutdown | 2 | violation_sim | I_Q | 19190 | 13 | 90.2 |
| cyclic | cbFail__spShutdown | 3 | violation_sim | I_Q | 11942 | 15 | 90.2 |
| cyclic | cbFail__taskTimeout | 1 | budget_stopped |  | 13576 | 25 | 90.2 |
| cyclic | cbFail__taskTimeout | 2 | budget_stopped |  | 13775 | 17 | 90.2 |
| cyclic | cbFail__taskTimeout | 3 | budget_stopped |  | 10160 | 14 | 90.2 |
| cyclic | cjCrash | 0 | pass_exhaustive |  | 9 | 7 | 2.8 |
| cyclic | cjCrash | 1 | violation_sim | S2F | 36491 | 18 | 90.3 |
| cyclic | cjCrash | 2 | budget_stopped |  | 26065 | 16 | 90.3 |
| cyclic | cjCrash | 3 | budget_stopped |  | 17197 | 16 | 90.3 |
| cyclic | cjCrash | 5 | budget_stopped |  | 16493 | 12 | 90.3 |
| cyclic | cpCrash | 0 | pass_exhaustive |  | 131 | 12 | 3.2 |
| cyclic | cpCrash | 1 | budget_stopped |  | 37266 | 13 | 90.2 |
| cyclic | cpCrash | 2 | violation | I_Q | 53 | 5 | 4.5 |
| cyclic | cpCrash | 3 | violation | I_Q | 76 | 13 | 5.5 |
| cyclic | cpCrash | 5 | budget_stopped |  | 7324 | 20 | 90.2 |
| cyclic | deadClient | 0 | violation | S1Cleanup | 173 | 8 | 3.5 |
| cyclic | deadClient | 1 | violation | S1Cleanup | 201 | 6 | 3.8 |
| cyclic | deadClient | 2 | violation | S1Cleanup | 1020 | 9 | 7.3 |
| cyclic | deadClient | 3 | violation | S1Cleanup | 520 | 9 | 7.0 |
| cyclic | deadClient | 5 | violation | S1Cleanup | 431 | 6 | 7.1 |
| cyclic | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.0 |
| cyclic | deleteJob | 1 | budget_stopped |  | 33292 | 35 | 90.3 |
| cyclic | deleteJob | 2 | pass_exhaustive |  | 243 | 38 | 5.6 |
| cyclic | deleteJob | 3 | pass_exhaustive |  | 39 | 14 | 4.0 |
| cyclic | deleteJob | 5 | budget_stopped |  | 10970 | 37 | 90.3 |
| cyclic | netLoss | 0 | budget_stopped |  | 18735 | 24 | 90.3 |
| cyclic | netLoss | 1 | budget_stopped |  | 22273 | 15 | 90.2 |
| cyclic | netLoss | 2 | budget_stopped |  | 13383 | 11 | 90.3 |
| cyclic | netLoss | 3 | budget_stopped |  | 11290 | 8 | 90.2 |
| cyclic | netLoss | 5 | budget_stopped |  | 12148 | 6 | 90.2 |
| cyclic | rpcTimeout | 0 | pass_exhaustive |  | 131 | 12 | 3.5 |
| cyclic | rpcTimeout | 1 | budget_stopped |  | 33979 | 15 | 90.3 |
| cyclic | rpcTimeout | 2 | pass_exhaustive |  | 243 | 38 | 5.9 |
| cyclic | rpcTimeout | 3 | pass_exhaustive |  | 39 | 14 | 4.3 |
| cyclic | rpcTimeout | 5 | budget_stopped |  | 10162 | 30 | 90.2 |
| cyclic | sjCrash | 0 | pass_exhaustive |  | 9 | 7 | 2.7 |
| cyclic | sjCrash | 1 | violation | S2F | 11720 | 17 | 29.4 |
| cyclic | sjCrash | 2 | budget_stopped |  | 37024 | 20 | 90.3 |
| cyclic | sjCrash | 3 | budget_stopped |  | 27613 | 22 | 90.3 |
| cyclic | sjCrash | 5 | budget_stopped |  | 27855 | 12 | 90.2 |
| cyclic | spCrash | 0 | pass_exhaustive |  | 131 | 12 | 3.5 |
| cyclic | spCrash | 1 | violation | I_Q | 205 | 8 | 4.3 |
| cyclic | spCrash | 2 | violation | I_Q | 5562 | 10 | 34.1 |
| cyclic | spCrash | 3 | violation | I_Q | 3797 | 18 | 35.5 |
| cyclic | spCrash | 5 | violation_sim | I_Q | 9134 | 22 | 90.3 |
| cyclic | spShutdown | 0 | violation | I_Q | 48 | 7 | 3.3 |
| cyclic | spShutdown | 1 | violation_sim | I_Q | 64610 | 16 | 90.3 |
| cyclic | spShutdown | 2 | violation_sim | I_Q | 17925 | 21 | 90.3 |
| cyclic | spShutdown | 3 | violation_sim | I_Q | 13802 | 21 | 90.3 |
| cyclic | spShutdown | 5 | violation_sim | I_Q | 14702 | 19 | 90.3 |
| cyclic | taskTimeout | 0 | pass_exhaustive |  | 9 | 7 | 2.8 |
| cyclic | taskTimeout | 1 | pass_exhaustive |  | 28 | 12 | 3.0 |
| cyclic | taskTimeout | 2 | budget_stopped |  | 14028 | 17 | 90.2 |
| cyclic | taskTimeout | 3 | budget_stopped |  | 9887 | 14 | 90.2 |
| cyclic | taskTimeout | 5 | budget_stopped |  | 10211 | 10 | 90.3 |
| docker | abort | 0 | budget_stopped |  | 15227 | 56 | 90.3 |
| docker | abort | 1 | budget_stopped |  | 16436 | 50 | 90.2 |
| docker | abort | 2 | budget_stopped |  | 38109 | 24 | 90.2 |
| docker | abort | 3 | budget_stopped |  | 28031 | 17 | 90.3 |
| docker | abort | 5 | budget_stopped |  | 22650 | 18 | 90.3 |
| docker | cjCrash | 0 | pass_exhaustive |  | 5 | 5 | 3.0 |
| docker | cjCrash | 1 | violation | S2F | 20486 | 16 | 25.6 |
| docker | cjCrash | 2 | budget_stopped |  | 39680 | 23 | 90.3 |
| docker | cjCrash | 3 | budget_stopped |  | 26545 | 22 | 90.2 |
| docker | cjCrash | 5 | budget_stopped |  | 30041 | 18 | 90.3 |
| docker | cpCrash | 0 | pass_exhaustive |  | 35 | 9 | 2.9 |
| docker | cpCrash | 1 | violation | S3Alloc | 113 | 8 | 3.3 |
| docker | cpCrash | 2 | violation | S3Alloc | 2 | 2 | 2.9 |
| docker | cpCrash | 3 | violation | S3Alloc | 13 | 7 | 3.7 |
| docker | cpCrash | 5 | violation | S3Alloc | 3 | 3 | 3.2 |
| docker | deadClient | 0 | budget_stopped |  | 46872 | 27 | 90.3 |
| docker | deadClient | 1 | budget_stopped |  | 46825 | 22 | 90.3 |
| docker | deadClient | 2 | budget_stopped |  | 65559 | 29 | 90.3 |
| docker | deadClient | 3 | budget_stopped |  | 27540 | 30 | 90.2 |
| docker | deadClient | 5 | pass_exhaustive |  | 9456 | 15 | 21.8 |
| docker | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.3 |
| docker | deleteJob | 1 | pass_exhaustive |  | 1541 | 39 | 8.5 |
| docker | deleteJob | 2 | pass_exhaustive |  | 1 | 1 | 3.2 |
| docker | deleteJob | 3 | pass_exhaustive |  | 15 | 8 | 3.8 |
| docker | deleteJob | 5 | pass_exhaustive |  | 198 | 27 | 4.8 |
| docker | netLoss | 0 | budget_stopped |  | 20379 | 33 | 90.3 |
| docker | netLoss | 1 | budget_stopped |  | 25969 | 23 | 90.2 |
| docker | netLoss | 2 | budget_stopped |  | 21877 | 22 | 90.3 |
| docker | netLoss | 3 | budget_stopped |  | 17000 | 10 | 90.3 |
| docker | netLoss | 5 | budget_stopped |  | 18343 | 10 | 90.3 |
| docker | rpcTimeout | 0 | pass_exhaustive |  | 35 | 9 | 2.9 |
| docker | rpcTimeout | 1 | budget_stopped |  | 45244 | 21 | 90.2 |
| docker | rpcTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.0 |
| docker | rpcTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.6 |
| docker | rpcTimeout | 5 | pass_exhaustive |  | 423 | 28 | 5.6 |
| docker | sjCrash | 0 | pass_exhaustive |  | 5 | 5 | 2.9 |
| docker | sjCrash | 1 | violation | S2F | 1038 | 16 | 5.9 |
| docker | sjCrash | 2 | pass_exhaustive |  | 230 | 18 | 3.9 |
| docker | sjCrash | 3 | pass_exhaustive |  | 2305 | 17 | 7.8 |
| docker | sjCrash | 5 | pass_exhaustive |  | 17895 | 12 | 34.9 |
| docker | spCrash | 0 | pass_exhaustive |  | 35 | 9 | 3.0 |
| docker | spCrash | 1 | violation | I_Q | 61 | 6 | 3.3 |
| docker | spCrash | 2 | violation | I_Q | 41 | 12 | 4.1 |
| docker | spCrash | 3 | violation | I_Q | 183 | 17 | 6.0 |
| docker | spCrash | 5 | violation | I_Q | 206 | 13 | 6.3 |
| docker | spShutdown | 0 | violation | I_Q | 40 | 7 | 3.5 |
| docker | spShutdown | 1 | violation_sim | I_Q | 60319 | 23 | 90.3 |
| docker | spShutdown | 2 | violation | I_Q | 1666 | 15 | 8.0 |
| docker | spShutdown | 3 | violation | I_Q | 7403 | 15 | 22.5 |
| docker | spShutdown | 5 | violation | I_Q | 4355 | 14 | 14.7 |
| docker | taskTimeout | 0 | pass_exhaustive |  | 5 | 5 | 2.7 |
| docker | taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.7 |
| docker | taskTimeout | 2 | pass_exhaustive |  | 491 | 28 | 3.8 |
| docker | taskTimeout | 3 | pass_exhaustive |  | 13992 | 14 | 32.5 |
| docker | taskTimeout | 5 | pass_exhaustive |  | 2348 | 12 | 9.6 |
| external | abort | 0 | budget_stopped |  | 16525 | 36 | 90.2 |
| external | abort | 1 | budget_stopped |  | 15875 | 27 | 90.3 |
| external | abort | 2 | budget_stopped |  | 30776 | 14 | 90.2 |
| external | abort | 3 | budget_stopped |  | 18629 | 15 | 90.3 |
| external | abort | 4 | pass_exhaustive |  | 0 | 1 | 3.3 |
| external | abort | 5 | budget_stopped |  | 20818 | 11 | 90.3 |
| external | cjCrash | 0 | pass_exhaustive |  | 5 | 5 | 3.2 |
| external | cjCrash | 1 | violation | S2F | 27550 | 14 | 32.8 |
| external | cjCrash | 2 | budget_stopped |  | 37368 | 19 | 90.3 |
| external | cjCrash | 3 | budget_stopped |  | 23860 | 21 | 90.2 |
| external | cjCrash | 4 | pass_exhaustive |  | 0 | 1 | 3.3 |
| external | cjCrash | 5 | budget_stopped |  | 26058 | 14 | 90.3 |
| external | cpCrash | 0 | pass_exhaustive |  | 35 | 9 | 3.4 |
| external | cpCrash | 1 | violation | I_Q | 12716 | 12 | 21.3 |
| external | cpCrash | 2 | violation | I_Q | 153 | 10 | 5.3 |
| external | cpCrash | 3 | violation | I_Q | 191 | 15 | 6.0 |
| external | cpCrash | 4 | pass_exhaustive |  | 0 | 1 | 2.9 |
| external | cpCrash | 5 | pass_exhaustive |  | 19368 | 49 | 67.0 |
| external | deadClient | 0 | budget_stopped |  | 50118 | 28 | 90.3 |
| external | deadClient | 1 | budget_stopped |  | 52565 | 22 | 90.3 |
| external | deadClient | 2 | budget_stopped |  | 27535 | 13 | 90.2 |
| external | deadClient | 3 | budget_stopped |  | 18485 | 16 | 90.2 |
| external | deadClient | 4 | pass_exhaustive |  | 0 | 1 | 2.9 |
| external | deadClient | 5 | budget_stopped |  | 27293 | 24 | 90.3 |
| external | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.5 |
| external | deleteJob | 1 | pass_exhaustive |  | 14621 | 23 | 46.5 |
| external | deleteJob | 2 | pass_exhaustive |  | 1207 | 29 | 9.8 |
| external | deleteJob | 3 | pass_exhaustive |  | 121 | 22 | 4.6 |
| external | deleteJob | 4 | pass_exhaustive |  | 0 | 1 | 3.5 |
| external | deleteJob | 5 | pass_exhaustive |  | 1266 | 36 | 8.3 |
| external | monitorStale | 0 | pass_exhaustive |  | 5 | 5 | 2.9 |
| external | monitorStale | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| external | monitorStale | 2 | budget_stopped |  | 21749 | 27 | 90.2 |
| external | monitorStale | 3 | pass_exhaustive |  | 7 | 7 | 3.3 |
| external | monitorStale | 4 | pass_exhaustive |  | 0 | 1 | 2.9 |
| external | monitorStale | 5 | budget_stopped |  | 21693 | 20 | 90.3 |
| external | monitorStale__abort | 1 | budget_stopped |  | 23362 | 23 | 90.3 |
| external | monitorStale__abort | 2 | budget_stopped |  | 31076 | 13 | 90.3 |
| external | monitorStale__abort | 3 | budget_stopped |  | 18412 | 14 | 90.2 |
| external | monitorStale__cjCrash | 1 | violation | S2F | 29216 | 15 | 34.5 |
| external | monitorStale__cjCrash | 2 | budget_stopped |  | 41880 | 18 | 90.3 |
| external | monitorStale__cjCrash | 3 | budget_stopped |  | 25641 | 18 | 90.3 |
| external | monitorStale__netLoss | 1 | budget_stopped |  | 33203 | 20 | 90.2 |
| external | monitorStale__netLoss | 2 | budget_stopped |  | 28367 | 10 | 90.3 |
| external | monitorStale__netLoss | 3 | budget_stopped |  | 18371 | 10 | 90.2 |
| external | monitorStale__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| external | monitorStale__taskTimeout | 2 | budget_stopped |  | 21528 | 15 | 90.2 |
| external | monitorStale__taskTimeout | 3 | budget_stopped |  | 12622 | 15 | 90.3 |
| external | netLoss | 0 | budget_stopped |  | 25104 | 28 | 90.3 |
| external | netLoss | 1 | budget_stopped |  | 29520 | 21 | 90.2 |
| external | netLoss | 2 | budget_stopped |  | 20176 | 10 | 90.3 |
| external | netLoss | 3 | budget_stopped |  | 16449 | 10 | 90.2 |
| external | netLoss | 4 | pass_exhaustive |  | 0 | 1 | 3.2 |
| external | netLoss | 5 | budget_stopped |  | 19843 | 8 | 90.3 |
| external | rpcTimeout | 0 | pass_exhaustive |  | 35 | 9 | 3.3 |
| external | rpcTimeout | 1 | budget_stopped |  | 54535 | 22 | 90.3 |
| external | rpcTimeout | 2 | pass_exhaustive |  | 1207 | 33 | 8.5 |
| external | rpcTimeout | 3 | pass_exhaustive |  | 121 | 22 | 4.5 |
| external | rpcTimeout | 4 | pass_exhaustive |  | 0 | 1 | 3.1 |
| external | rpcTimeout | 5 | pass_exhaustive |  | 2616 | 28 | 13.2 |
| external | sjCrash | 0 | pass_exhaustive |  | 5 | 5 | 2.7 |
| external | sjCrash | 1 | violation | S2F | 1011 | 16 | 5.9 |
| external | sjCrash | 2 | budget_stopped |  | 56170 | 25 | 90.3 |
| external | sjCrash | 3 | budget_stopped |  | 47266 | 22 | 90.2 |
| external | sjCrash | 4 | pass_exhaustive |  | 0 | 1 | 2.9 |
| external | sjCrash | 5 | budget_stopped |  | 39027 | 19 | 90.3 |
| external | spCrash | 0 | pass_exhaustive |  | 35 | 9 | 3.2 |
| external | spCrash | 1 | violation | I_Q | 87 | 7 | 3.7 |
| external | spCrash | 2 | violation | I_Q | 744 | 18 | 7.6 |
| external | spCrash | 3 | violation | I_Q | 361 | 18 | 7.3 |
| external | spCrash | 4 | pass_exhaustive |  | 0 | 1 | 3.4 |
| external | spCrash | 5 | violation | I_Q | 398 | 20 | 7.5 |
| external | spShutdown | 0 | violation | I_Q | 40 | 7 | 3.5 |
| external | spShutdown | 1 | violation_sim | I_Q | 63888 | 24 | 90.3 |
| external | spShutdown | 2 | violation | I_Q | 10628 | 15 | 25.8 |
| external | spShutdown | 3 | violation | I_Q | 9020 | 15 | 30.1 |
| external | spShutdown | 4 | pass_exhaustive |  | 0 | 1 | 3.1 |
| external | spShutdown | 5 | violation | I_Q | 5277 | 20 | 17.6 |
| external | taskTimeout | 0 | pass_exhaustive |  | 5 | 5 | 3.0 |
| external | taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.1 |
| external | taskTimeout | 2 | budget_stopped |  | 21209 | 16 | 90.2 |
| external | taskTimeout | 3 | budget_stopped |  | 11145 | 17 | 90.3 |
| external | taskTimeout | 4 | pass_exhaustive |  | 0 | 1 | 3.2 |
| external | taskTimeout | 5 | budget_stopped |  | 14341 | 12 | 90.2 |
| external | tpSilent | 0 | pass_exhaustive |  | 5 | 5 | 3.0 |
| external | tpSilent | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| external | tpSilent | 2 | budget_stopped |  | 22685 | 39 | 90.3 |
| external | tpSilent | 3 | pass_exhaustive |  | 7 | 7 | 3.3 |
| external | tpSilent | 4 | pass_exhaustive |  | 0 | 1 | 3.1 |
| external | tpSilent | 5 | budget_stopped |  | 25464 | 23 | 90.2 |
| external | tpSilent__abort | 1 | budget_stopped |  | 21657 | 24 | 90.3 |
| external | tpSilent__abort | 2 | budget_stopped |  | 29291 | 13 | 90.3 |
| external | tpSilent__abort | 3 | budget_stopped |  | 18331 | 14 | 90.2 |
| external | tpSilent__cjCrash | 1 | violation | S2F | 26631 | 14 | 33.5 |
| external | tpSilent__cjCrash | 2 | budget_stopped |  | 41429 | 19 | 90.2 |
| external | tpSilent__cjCrash | 3 | budget_stopped |  | 23509 | 19 | 90.2 |
| external | tpSilent__netLoss | 1 | budget_stopped |  | 26228 | 20 | 90.2 |
| external | tpSilent__netLoss | 2 | budget_stopped |  | 20366 | 10 | 90.3 |
| external | tpSilent__netLoss | 3 | budget_stopped |  | 16426 | 10 | 90.3 |
| external | tpSilent__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| external | tpSilent__taskTimeout | 2 | budget_stopped |  | 20464 | 15 | 90.2 |
| external | tpSilent__taskTimeout | 3 | budget_stopped |  | 11559 | 16 | 90.2 |
| external | trainerError | 0 | pass_exhaustive |  | 5 | 5 | 2.6 |
| external | trainerError | 1 | pass_exhaustive |  | 8 | 8 | 2.7 |
| external | trainerError | 2 | pass_exhaustive |  | 3823 | 17 | 17.6 |
| external | trainerError | 3 | pass_exhaustive |  | 7 | 7 | 3.0 |
| external | trainerError | 4 | pass_exhaustive |  | 0 | 1 | 2.9 |
| external | trainerError | 5 | pass_exhaustive |  | 14295 | 14 | 26.1 |
| external | trainerError__abort | 1 | budget_stopped |  | 16814 | 27 | 90.3 |
| external | trainerError__abort | 2 | budget_stopped |  | 35233 | 14 | 90.3 |
| external | trainerError__abort | 3 | budget_stopped |  | 19797 | 16 | 90.2 |
| external | trainerError__cjCrash | 1 | violation | S2F | 21525 | 15 | 24.5 |
| external | trainerError__cjCrash | 2 | budget_stopped |  | 39574 | 19 | 90.3 |
| external | trainerError__cjCrash | 3 | budget_stopped |  | 27823 | 22 | 90.2 |
| external | trainerError__netLoss | 1 | budget_stopped |  | 30022 | 21 | 90.3 |
| external | trainerError__netLoss | 2 | budget_stopped |  | 17271 | 11 | 90.3 |
| external | trainerError__netLoss | 3 | budget_stopped |  | 15182 | 11 | 90.2 |
| external | trainerError__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| external | trainerError__taskTimeout | 2 | budget_stopped |  | 20911 | 16 | 90.2 |
| external | trainerError__taskTimeout | 3 | budget_stopped |  | 11110 | 17 | 90.2 |
| fedavg | abort | 0 | budget_stopped |  | 16406 | 57 | 90.3 |
| fedavg | abort | 1 | budget_stopped |  | 16425 | 50 | 90.3 |
| fedavg | abort | 2 | budget_stopped |  | 36480 | 24 | 90.3 |
| fedavg | abort | 3 | budget_stopped |  | 25557 | 17 | 90.3 |
| fedavg | abort | 5 | budget_stopped |  | 23205 | 18 | 90.3 |
| fedavg | abortCmdError | 0 | pass_exhaustive |  | 5 | 5 | 3.1 |
| fedavg | abortCmdError | 1 | pass_exhaustive |  | 1541 | 38 | 8.1 |
| fedavg | abortCmdError | 2 | pass_exhaustive |  | 1 | 1 | 2.9 |
| fedavg | abortCmdError | 3 | pass_exhaustive |  | 15 | 8 | 3.4 |
| fedavg | abortCmdError | 5 | pass_exhaustive |  | 198 | 27 | 4.6 |
| fedavg | abortCmdError__abort | 1 | budget_stopped |  | 17706 | 50 | 90.3 |
| fedavg | abortCmdError__abort | 2 | violation | S4CompletedWf | 2433 | 12 | 8.3 |
| fedavg | abortCmdError__abort | 3 | violation | S4CompletedWf | 14499 | 8 | 42.0 |
| fedavg | abortCmdError__cjCrash | 1 | violation | S2F | 21106 | 14 | 22.5 |
| fedavg | abortCmdError__cjCrash | 2 | budget_stopped |  | 41260 | 22 | 90.3 |
| fedavg | abortCmdError__cjCrash | 3 | budget_stopped |  | 28555 | 19 | 90.3 |
| fedavg | abortCmdError__cpCrash | 1 | violation | I_Q | 12767 | 12 | 19.1 |
| fedavg | abortCmdError__cpCrash | 2 | violation | I_Q | 3 | 3 | 3.0 |
| fedavg | abortCmdError__cpCrash | 3 | pass_exhaustive |  | 663 | 23 | 7.2 |
| fedavg | abortCmdError__deadClient | 1 | violation_sim | S2F | 44787 | 21 | 90.3 |
| fedavg | abortCmdError__deadClient | 2 | budget_stopped |  | 48348 | 24 | 90.3 |
| fedavg | abortCmdError__deadClient | 3 | budget_stopped |  | 24129 | 27 | 90.3 |
| fedavg | abortCmdError__deleteJob | 1 | pass_exhaustive |  | 1541 | 34 | 8.7 |
| fedavg | abortCmdError__deleteJob | 2 | pass_exhaustive |  | 1 | 1 | 3.1 |
| fedavg | abortCmdError__deleteJob | 3 | pass_exhaustive |  | 15 | 8 | 3.6 |
| fedavg | abortCmdError__netLoss | 1 | budget_stopped |  | 25712 | 23 | 90.3 |
| fedavg | abortCmdError__netLoss | 2 | budget_stopped |  | 25347 | 23 | 90.3 |
| fedavg | abortCmdError__netLoss | 3 | budget_stopped |  | 18389 | 10 | 90.2 |
| fedavg | abortCmdError__outcomeTimeout | 1 | pass_exhaustive |  | 1541 | 32 | 9.1 |
| fedavg | abortCmdError__outcomeTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.3 |
| fedavg | abortCmdError__outcomeTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.8 |
| fedavg | abortCmdError__rpcTimeout | 1 | budget_stopped |  | 43933 | 21 | 90.3 |
| fedavg | abortCmdError__rpcTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.1 |
| fedavg | abortCmdError__rpcTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.6 |
| fedavg | abortCmdError__sjCrash | 1 | violation | S2F | 1179 | 14 | 7.0 |
| fedavg | abortCmdError__sjCrash | 2 | pass_exhaustive |  | 486 | 18 | 5.3 |
| fedavg | abortCmdError__sjCrash | 3 | pass_exhaustive |  | 4865 | 13 | 18.5 |
| fedavg | abortCmdError__spCrash | 1 | violation | I_Q | 73 | 7 | 3.4 |
| fedavg | abortCmdError__spCrash | 2 | violation | I_Q | 41 | 12 | 4.0 |
| fedavg | abortCmdError__spCrash | 3 | violation | I_Q | 187 | 17 | 5.9 |
| fedavg | abortCmdError__spShutdown | 1 | violation_sim | I_Q | 59014 | 23 | 90.3 |
| fedavg | abortCmdError__spShutdown | 2 | violation | I_Q | 1649 | 15 | 7.8 |
| fedavg | abortCmdError__spShutdown | 3 | violation | I_Q | 7420 | 15 | 23.2 |
| fedavg | admissionError | 0 | pass_exhaustive |  | 13 | 6 | 3.0 |
| fedavg | admissionError | 1 | pass_exhaustive |  | 1541 | 35 | 8.3 |
| fedavg | admissionError | 2 | pass_exhaustive |  | 1 | 1 | 2.9 |
| fedavg | admissionError | 3 | pass_exhaustive |  | 15 | 8 | 3.4 |
| fedavg | admissionError | 5 | pass_exhaustive |  | 198 | 27 | 4.5 |
| fedavg | admissionError__abort | 1 | budget_stopped |  | 18317 | 51 | 90.3 |
| fedavg | admissionError__abort | 2 | budget_stopped |  | 36862 | 24 | 90.3 |
| fedavg | admissionError__abort | 3 | budget_stopped |  | 28977 | 17 | 90.3 |
| fedavg | admissionError__cjCrash | 1 | violation | S2F | 21132 | 14 | 22.0 |
| fedavg | admissionError__cjCrash | 2 | budget_stopped |  | 41493 | 22 | 90.2 |
| fedavg | admissionError__cjCrash | 3 | budget_stopped |  | 30403 | 18 | 90.3 |
| fedavg | admissionError__cpCrash | 1 | violation | I_Q | 12715 | 12 | 18.8 |
| fedavg | admissionError__cpCrash | 2 | violation | I_Q | 3 | 3 | 3.2 |
| fedavg | admissionError__cpCrash | 3 | pass_exhaustive |  | 663 | 23 | 6.6 |
| fedavg | admissionError__deadClient | 1 | violation_sim | S2F | 46994 | 21 | 90.3 |
| fedavg | admissionError__deadClient | 2 | budget_stopped |  | 47640 | 23 | 90.2 |
| fedavg | admissionError__deadClient | 3 | budget_stopped |  | 24151 | 27 | 90.2 |
| fedavg | admissionError__deleteJob | 1 | pass_exhaustive |  | 1541 | 36 | 9.1 |
| fedavg | admissionError__deleteJob | 2 | pass_exhaustive |  | 1 | 1 | 3.2 |
| fedavg | admissionError__deleteJob | 3 | pass_exhaustive |  | 15 | 8 | 3.6 |
| fedavg | admissionError__netLoss | 1 | budget_stopped |  | 26395 | 23 | 90.2 |
| fedavg | admissionError__netLoss | 2 | budget_stopped |  | 29840 | 23 | 90.3 |
| fedavg | admissionError__netLoss | 3 | budget_stopped |  | 17875 | 10 | 90.3 |
| fedavg | admissionError__outcomeTimeout | 1 | pass_exhaustive |  | 1541 | 39 | 7.8 |
| fedavg | admissionError__outcomeTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.0 |
| fedavg | admissionError__outcomeTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.3 |
| fedavg | admissionError__rpcTimeout | 1 | budget_stopped |  | 46429 | 22 | 90.3 |
| fedavg | admissionError__rpcTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.8 |
| fedavg | admissionError__rpcTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.3 |
| fedavg | admissionError__sjCrash | 1 | violation | S2F | 1137 | 15 | 6.1 |
| fedavg | admissionError__sjCrash | 2 | pass_exhaustive |  | 486 | 18 | 5.0 |
| fedavg | admissionError__sjCrash | 3 | pass_exhaustive |  | 4865 | 13 | 18.3 |
| fedavg | admissionError__spCrash | 1 | violation | I_Q | 83 | 7 | 3.4 |
| fedavg | admissionError__spCrash | 2 | violation | I_Q | 41 | 12 | 3.9 |
| fedavg | admissionError__spCrash | 3 | violation | I_Q | 179 | 17 | 5.9 |
| fedavg | admissionError__spShutdown | 1 | violation_sim | I_Q | 63670 | 23 | 90.3 |
| fedavg | admissionError__spShutdown | 2 | violation | I_Q | 1263 | 14 | 7.1 |
| fedavg | admissionError__spShutdown | 3 | violation | I_Q | 7405 | 14 | 22.3 |
| fedavg | cancel | 0 | pass_exhaustive |  | 5 | 5 | 2.6 |
| fedavg | cancel | 1 | pass_exhaustive |  | 8 | 8 | 2.6 |
| fedavg | cancel | 2 | pass_exhaustive |  | 124 | 28 | 3.3 |
| fedavg | cancel | 3 | pass_exhaustive |  | 35 | 8 | 3.5 |
| fedavg | cancel | 5 | pass_exhaustive |  | 303 | 26 | 4.1 |
| fedavg | cancel__abort | 1 | violation | S2F | 25158 | 15 | 53.8 |
| fedavg | cancel__abort | 2 | budget_stopped |  | 40741 | 20 | 90.3 |
| fedavg | cancel__abort | 3 | budget_stopped |  | 25720 | 17 | 90.3 |
| fedavg | cancel__deadClient | 1 | budget_stopped |  | 49627 | 23 | 90.3 |
| fedavg | cancel__deadClient | 2 | budget_stopped |  | 64789 | 29 | 90.3 |
| fedavg | cancel__deadClient | 3 | budget_stopped |  | 26232 | 22 | 90.3 |
| fedavg | cancel__netLoss | 1 | violation_sim | S2F | 32348 | 21 | 90.3 |
| fedavg | cancel__netLoss | 2 | budget_stopped |  | 31095 | 17 | 90.3 |
| fedavg | cancel__netLoss | 3 | budget_stopped |  | 15855 | 12 | 90.3 |
| fedavg | cancel__pullTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | cancel__pullTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.3 |
| fedavg | cancel__pullTimeout | 3 | pass_exhaustive |  | 13992 | 14 | 29.7 |
| fedavg | cancel__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| fedavg | cancel__resultWaitTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.3 |
| fedavg | cancel__resultWaitTimeout | 3 | pass_exhaustive |  | 3825 | 16 | 11.6 |
| fedavg | cancel__sjCrash | 1 | violation | S2F | 1173 | 16 | 5.7 |
| fedavg | cancel__sjCrash | 2 | pass_exhaustive |  | 16085 | 16 | 22.4 |
| fedavg | cancel__sjCrash | 3 | pass_exhaustive |  | 8050 | 11 | 19.9 |
| fedavg | cancel__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.2 |
| fedavg | cancel__submitTimeout | 2 | budget_stopped |  | 35438 | 24 | 90.3 |
| fedavg | cancel__submitTimeout | 3 | budget_stopped |  | 13245 | 17 | 90.3 |
| fedavg | cancel__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.2 |
| fedavg | cancel__taskTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.6 |
| fedavg | cancel__taskTimeout | 3 | pass_exhaustive |  | 13992 | 14 | 31.6 |
| fedavg | cancel__txTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | cancel__txTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.3 |
| fedavg | cancel__txTimeout | 3 | pass_exhaustive |  | 38796 | 29 | 78.8 |
| fedavg | cbFail | 0 | pass_exhaustive |  | 5 | 5 | 3.7 |
| fedavg | cbFail | 1 | violation | S2F | 14997 | 18 | 26.8 |
| fedavg | cbFail | 2 | pass_exhaustive |  | 7932 | 20 | 13.8 |
| fedavg | cbFail | 3 | pass_exhaustive |  | 38651 | 35 | 70.7 |
| fedavg | cbFail | 5 | pass_exhaustive |  | 463 | 25 | 5.2 |
| fedavg | cbFail__abort | 1 | violation_sim | S2F | 33656 | 25 | 90.2 |
| fedavg | cbFail__abort | 2 | budget_stopped |  | 48061 | 19 | 90.3 |
| fedavg | cbFail__abort | 3 | budget_stopped |  | 27051 | 15 | 90.3 |
| fedavg | cbFail__cjCrash | 1 | violation | S2F | 30714 | 13 | 37.3 |
| fedavg | cbFail__cjCrash | 2 | budget_stopped |  | 34490 | 16 | 90.3 |
| fedavg | cbFail__cjCrash | 3 | budget_stopped |  | 24460 | 14 | 90.3 |
| fedavg | cbFail__deadClient | 1 | budget_stopped |  | 55508 | 20 | 90.3 |
| fedavg | cbFail__deadClient | 2 | budget_stopped |  | 62579 | 20 | 90.3 |
| fedavg | cbFail__deadClient | 3 | budget_stopped |  | 29728 | 21 | 90.3 |
| fedavg | cbFail__deleteJob | 1 | violation | S2F | 15971 | 16 | 30.0 |
| fedavg | cbFail__deleteJob | 2 | pass_exhaustive |  | 21972 | 18 | 37.9 |
| fedavg | cbFail__deleteJob | 3 | budget_stopped |  | 30289 | 27 | 90.3 |
| fedavg | cbFail__netLoss | 1 | violation_sim | S2F | 41739 | 21 | 90.3 |
| fedavg | cbFail__netLoss | 2 | budget_stopped |  | 29323 | 17 | 90.3 |
| fedavg | cbFail__netLoss | 3 | budget_stopped |  | 24620 | 9 | 90.3 |
| fedavg | cbFail__outcomeTimeout | 1 | violation | S2F | 15859 | 17 | 28.4 |
| fedavg | cbFail__outcomeTimeout | 2 | pass_exhaustive |  | 21972 | 18 | 37.4 |
| fedavg | cbFail__outcomeTimeout | 3 | budget_stopped |  | 33876 | 27 | 90.3 |
| fedavg | cbFail__pullTimeout | 1 | violation | S2F | 17622 | 18 | 39.0 |
| fedavg | cbFail__pullTimeout | 2 | pass_exhaustive |  | 11388 | 19 | 16.0 |
| fedavg | cbFail__pullTimeout | 3 | budget_stopped |  | 17698 | 18 | 90.3 |
| fedavg | cbFail__resultWaitTimeout | 1 | budget_stopped |  | 30107 | 27 | 90.3 |
| fedavg | cbFail__resultWaitTimeout | 2 | pass_exhaustive |  | 11388 | 19 | 15.7 |
| fedavg | cbFail__resultWaitTimeout | 3 | budget_stopped |  | 27493 | 21 | 90.2 |
| fedavg | cbFail__rpcTimeout | 1 | budget_stopped |  | 50589 | 19 | 90.3 |
| fedavg | cbFail__rpcTimeout | 2 | pass_exhaustive |  | 28076 | 19 | 46.6 |
| fedavg | cbFail__rpcTimeout | 3 | budget_stopped |  | 32792 | 27 | 90.3 |
| fedavg | cbFail__sjCrash | 1 | violation | S2F | 1752 | 15 | 7.3 |
| fedavg | cbFail__sjCrash | 2 | pass_exhaustive |  | 32630 | 15 | 34.9 |
| fedavg | cbFail__sjCrash | 3 | budget_stopped |  | 42746 | 23 | 90.2 |
| fedavg | cbFail__spCrash | 1 | violation | I_Q | 92 | 7 | 3.5 |
| fedavg | cbFail__spCrash | 2 | violation | I_Q | 183 | 12 | 4.5 |
| fedavg | cbFail__spCrash | 3 | violation | I_Q | 1497 | 12 | 9.5 |
| fedavg | cbFail__spShutdown | 1 | violation_sim | I_Q | 51631 | 17 | 90.3 |
| fedavg | cbFail__spShutdown | 2 | violation | I_Q | 19140 | 11 | 31.7 |
| fedavg | cbFail__spShutdown | 3 | violation_sim | I_Q | 25476 | 18 | 90.3 |
| fedavg | cbFail__submitTimeout | 1 | violation | S2F | 30649 | 27 | 68.5 |
| fedavg | cbFail__submitTimeout | 2 | budget_stopped |  | 34362 | 23 | 90.3 |
| fedavg | cbFail__submitTimeout | 3 | budget_stopped |  | 16798 | 14 | 90.3 |
| fedavg | cbFail__taskTimeout | 1 | violation | S2F | 45023 | 26 | 84.7 |
| fedavg | cbFail__taskTimeout | 2 | pass_exhaustive |  | 45537 | 13 | 57.8 |
| fedavg | cbFail__taskTimeout | 3 | budget_stopped |  | 18355 | 18 | 90.3 |
| fedavg | cbFail__txTimeout | 1 | violation | S2F | 17249 | 19 | 37.7 |
| fedavg | cbFail__txTimeout | 2 | pass_exhaustive |  | 11388 | 19 | 16.1 |
| fedavg | cbFail__txTimeout | 3 | budget_stopped |  | 18405 | 16 | 90.2 |
| fedavg | cjCrash | 0 | pass_exhaustive |  | 5 | 5 | 4.4 |
| fedavg | cjCrash | 1 | violation | S2F | 26867 | 16 | 36.8 |
| fedavg | cjCrash | 2 | budget_stopped |  | 37308 | 23 | 90.3 |
| fedavg | cjCrash | 3 | budget_stopped |  | 26905 | 22 | 90.3 |
| fedavg | cjCrash | 5 | budget_stopped |  | 29023 | 18 | 90.3 |
| fedavg | cpCrash | 0 | pass_exhaustive |  | 35 | 9 | 5.2 |
| fedavg | cpCrash | 1 | violation | I_Q | 10473 | 11 | 21.1 |
| fedavg | cpCrash | 2 | violation | I_Q | 3 | 3 | 5.4 |
| fedavg | cpCrash | 3 | pass_exhaustive |  | 663 | 21 | 10.5 |
| fedavg | cpCrash | 5 | pass_exhaustive |  | 3215 | 14 | 18.0 |
| fedavg | deadClient | 0 | budget_stopped |  | 46806 | 27 | 90.2 |
| fedavg | deadClient | 1 | budget_stopped |  | 52169 | 22 | 90.3 |
| fedavg | deadClient | 2 | budget_stopped |  | 57720 | 28 | 90.3 |
| fedavg | deadClient | 3 | budget_stopped |  | 29101 | 30 | 90.2 |
| fedavg | deadClient | 5 | pass_exhaustive |  | 9456 | 13 | 27.3 |
| fedavg | deleteJob | 0 | violation | S1Sched | 6 | 3 | 5.5 |
| fedavg | deleteJob | 1 | pass_exhaustive |  | 1541 | 32 | 11.0 |
| fedavg | deleteJob | 2 | pass_exhaustive |  | 1 | 1 | 5.3 |
| fedavg | deleteJob | 3 | pass_exhaustive |  | 15 | 8 | 5.8 |
| fedavg | deleteJob | 5 | pass_exhaustive |  | 198 | 27 | 7.1 |
| fedavg | deployError | 0 | pass_exhaustive |  | 38 | 9 | 3.2 |
| fedavg | deployError | 1 | budget_stopped |  | 52082 | 22 | 90.3 |
| fedavg | deployError | 2 | pass_exhaustive |  | 1 | 1 | 3.0 |
| fedavg | deployError | 3 | pass_exhaustive |  | 15 | 8 | 3.4 |
| fedavg | deployError | 5 | pass_exhaustive |  | 219 | 27 | 4.8 |
| fedavg | deployError__abort | 1 | budget_stopped |  | 41648 | 19 | 90.3 |
| fedavg | deployError__abort | 2 | budget_stopped |  | 40800 | 25 | 90.3 |
| fedavg | deployError__abort | 3 | budget_stopped |  | 27494 | 17 | 90.3 |
| fedavg | deployError__cjCrash | 1 | budget_stopped |  | 69020 | 18 | 90.3 |
| fedavg | deployError__cjCrash | 2 | budget_stopped |  | 41687 | 22 | 90.3 |
| fedavg | deployError__cjCrash | 3 | budget_stopped |  | 29829 | 18 | 90.3 |
| fedavg | deployError__cpCrash | 1 | violation | I_Q | 12716 | 12 | 19.5 |
| fedavg | deployError__cpCrash | 2 | violation | I_Q | 3 | 3 | 3.1 |
| fedavg | deployError__cpCrash | 3 | pass_exhaustive |  | 663 | 23 | 7.2 |
| fedavg | deployError__deadClient | 1 | budget_stopped |  | 62012 | 16 | 90.3 |
| fedavg | deployError__deadClient | 2 | budget_stopped |  | 48983 | 20 | 90.3 |
| fedavg | deployError__deadClient | 3 | budget_stopped |  | 25447 | 23 | 90.3 |
| fedavg | deployError__deleteJob | 1 | budget_stopped |  | 47703 | 22 | 90.3 |
| fedavg | deployError__deleteJob | 2 | pass_exhaustive |  | 1 | 1 | 3.1 |
| fedavg | deployError__deleteJob | 3 | pass_exhaustive |  | 15 | 8 | 3.3 |
| fedavg | deployError__netLoss | 1 | budget_stopped |  | 55142 | 16 | 90.3 |
| fedavg | deployError__netLoss | 2 | budget_stopped |  | 26894 | 23 | 90.3 |
| fedavg | deployError__netLoss | 3 | budget_stopped |  | 17993 | 10 | 90.3 |
| fedavg | deployError__outcomeTimeout | 1 | budget_stopped |  | 44848 | 22 | 90.3 |
| fedavg | deployError__outcomeTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.0 |
| fedavg | deployError__outcomeTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.6 |
| fedavg | deployError__rpcTimeout | 1 | budget_stopped |  | 46952 | 22 | 90.3 |
| fedavg | deployError__rpcTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.8 |
| fedavg | deployError__rpcTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.4 |
| fedavg | deployError__sjCrash | 1 | violation | S2F | 10711 | 12 | 17.7 |
| fedavg | deployError__sjCrash | 2 | pass_exhaustive |  | 486 | 18 | 5.1 |
| fedavg | deployError__sjCrash | 3 | pass_exhaustive |  | 4865 | 14 | 19.0 |
| fedavg | deployError__spCrash | 1 | violation | I_Q | 85 | 7 | 3.7 |
| fedavg | deployError__spCrash | 2 | violation | I_Q | 41 | 12 | 4.4 |
| fedavg | deployError__spCrash | 3 | violation | I_Q | 197 | 17 | 5.7 |
| fedavg | deployError__spShutdown | 1 | violation | I_Q | 1214 | 9 | 5.6 |
| fedavg | deployError__spShutdown | 2 | violation | I_Q | 1607 | 14 | 7.6 |
| fedavg | deployError__spShutdown | 3 | violation | I_Q | 8043 | 15 | 26.0 |
| fedavg | launchError | 0 | pass_exhaustive |  | 27 | 9 | 3.2 |
| fedavg | launchError | 1 | violation | S3Alloc | 115 | 8 | 3.6 |
| fedavg | launchError | 2 | pass_exhaustive |  | 1 | 1 | 3.1 |
| fedavg | launchError | 3 | pass_exhaustive |  | 15 | 8 | 3.4 |
| fedavg | launchError | 5 | pass_exhaustive |  | 219 | 27 | 5.3 |
| fedavg | launchError__abort | 1 | violation | S3Alloc | 131 | 8 | 4.0 |
| fedavg | launchError__abort | 2 | budget_stopped |  | 36105 | 24 | 90.3 |
| fedavg | launchError__abort | 3 | budget_stopped |  | 25031 | 17 | 90.2 |
| fedavg | launchError__cjCrash | 1 | violation | S3Alloc | 119 | 8 | 3.6 |
| fedavg | launchError__cjCrash | 2 | violation | S3Alloc | 147 | 8 | 4.2 |
| fedavg | launchError__cjCrash | 3 | violation | S3Alloc | 402 | 10 | 5.8 |
| fedavg | launchError__cpCrash | 1 | violation | S3Alloc | 120 | 8 | 3.8 |
| fedavg | launchError__cpCrash | 2 | violation | I_Q | 3 | 3 | 3.6 |
| fedavg | launchError__cpCrash | 3 | pass_exhaustive |  | 663 | 23 | 7.6 |
| fedavg | launchError__deadClient | 1 | violation | S3Alloc | 191 | 7 | 4.2 |
| fedavg | launchError__deadClient | 2 | budget_stopped |  | 51820 | 20 | 90.3 |
| fedavg | launchError__deadClient | 3 | budget_stopped |  | 25327 | 23 | 90.3 |
| fedavg | launchError__deleteJob | 1 | violation | S3Alloc | 97 | 8 | 3.7 |
| fedavg | launchError__deleteJob | 2 | pass_exhaustive |  | 1 | 1 | 3.1 |
| fedavg | launchError__deleteJob | 3 | pass_exhaustive |  | 15 | 8 | 3.6 |
| fedavg | launchError__netLoss | 1 | violation | S3Alloc | 273 | 7 | 3.8 |
| fedavg | launchError__netLoss | 2 | budget_stopped |  | 26193 | 22 | 90.3 |
| fedavg | launchError__netLoss | 3 | budget_stopped |  | 17998 | 10 | 90.3 |
| fedavg | launchError__outcomeTimeout | 1 | violation | S3Alloc | 112 | 8 | 4.2 |
| fedavg | launchError__outcomeTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.5 |
| fedavg | launchError__outcomeTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.8 |
| fedavg | launchError__rpcTimeout | 1 | violation | S3Alloc | 115 | 8 | 4.1 |
| fedavg | launchError__rpcTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.6 |
| fedavg | launchError__rpcTimeout | 3 | pass_exhaustive |  | 15 | 8 | 4.1 |
| fedavg | launchError__sjCrash | 1 | violation | S3Alloc | 128 | 8 | 3.6 |
| fedavg | launchError__sjCrash | 2 | pass_exhaustive |  | 486 | 18 | 5.6 |
| fedavg | launchError__sjCrash | 3 | pass_exhaustive |  | 4865 | 14 | 19.0 |
| fedavg | launchError__spCrash | 1 | violation | I_Q | 101 | 7 | 4.0 |
| fedavg | launchError__spCrash | 2 | violation | I_Q | 41 | 12 | 4.2 |
| fedavg | launchError__spCrash | 3 | violation | I_Q | 183 | 17 | 6.3 |
| fedavg | launchError__spShutdown | 1 | violation | S3Alloc | 297 | 7 | 4.0 |
| fedavg | launchError__spShutdown | 2 | violation | I_Q | 1649 | 15 | 7.9 |
| fedavg | launchError__spShutdown | 3 | violation | I_Q | 8044 | 14 | 28.5 |
| fedavg | minClients | 0 | pass_exhaustive |  | 5 | 5 | 2.6 |
| fedavg | minClients | 1 | pass_exhaustive |  | 8 | 8 | 2.7 |
| fedavg | minClients | 2 | pass_exhaustive |  | 124 | 28 | 3.6 |
| fedavg | minClients | 3 | pass_exhaustive |  | 15 | 8 | 3.8 |
| fedavg | minClients | 5 | pass_exhaustive |  | 147 | 25 | 5.0 |
| fedavg | minClients__abort | 1 | violation | S2F | 23732 | 15 | 45.0 |
| fedavg | minClients__abort | 2 | budget_stopped |  | 43940 | 20 | 90.3 |
| fedavg | minClients__abort | 3 | budget_stopped |  | 24657 | 17 | 90.3 |
| fedavg | minClients__deadClient | 1 | budget_stopped |  | 47904 | 23 | 90.3 |
| fedavg | minClients__deadClient | 2 | budget_stopped |  | 61352 | 29 | 90.3 |
| fedavg | minClients__deadClient | 3 | budget_stopped |  | 34006 | 32 | 90.3 |
| fedavg | minClients__netLoss | 1 | violation_sim | S2F | 35288 | 21 | 90.3 |
| fedavg | minClients__netLoss | 2 | budget_stopped |  | 34394 | 17 | 90.3 |
| fedavg | minClients__netLoss | 3 | budget_stopped |  | 18041 | 12 | 90.3 |
| fedavg | minClients__pullTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| fedavg | minClients__pullTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.7 |
| fedavg | minClients__pullTimeout | 3 | pass_exhaustive |  | 13992 | 14 | 33.2 |
| fedavg | minClients__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | minClients__resultWaitTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.3 |
| fedavg | minClients__resultWaitTimeout | 3 | pass_exhaustive |  | 3825 | 15 | 12.6 |
| fedavg | minClients__sjCrash | 1 | violation | S2F | 1254 | 16 | 5.9 |
| fedavg | minClients__sjCrash | 2 | pass_exhaustive |  | 16085 | 16 | 21.2 |
| fedavg | minClients__sjCrash | 3 | pass_exhaustive |  | 2305 | 16 | 8.9 |
| fedavg | minClients__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | minClients__submitTimeout | 2 | budget_stopped |  | 36663 | 24 | 90.2 |
| fedavg | minClients__submitTimeout | 3 | budget_stopped |  | 14156 | 17 | 90.3 |
| fedavg | minClients__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| fedavg | minClients__taskTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.6 |
| fedavg | minClients__taskTimeout | 3 | pass_exhaustive |  | 13992 | 14 | 31.7 |
| fedavg | minClients__txTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| fedavg | minClients__txTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.3 |
| fedavg | minClients__txTimeout | 3 | pass_exhaustive |  | 38796 | 31 | 76.9 |
| fedavg | netLoss | 0 | budget_stopped |  | 21572 | 33 | 90.3 |
| fedavg | netLoss | 1 | budget_stopped |  | 25783 | 23 | 90.2 |
| fedavg | netLoss | 2 | budget_stopped |  | 24683 | 22 | 90.3 |
| fedavg | netLoss | 3 | budget_stopped |  | 18181 | 10 | 90.3 |
| fedavg | netLoss | 5 | budget_stopped |  | 19214 | 10 | 90.3 |
| fedavg | outcomeReportFail | 0 | pass_exhaustive |  | 5 | 5 | 2.9 |
| fedavg | outcomeReportFail | 1 | pass_exhaustive |  | 1467 | 38 | 7.8 |
| fedavg | outcomeReportFail | 2 | pass_exhaustive |  | 1 | 1 | 3.1 |
| fedavg | outcomeReportFail | 3 | pass_exhaustive |  | 15 | 8 | 3.3 |
| fedavg | outcomeReportFail | 5 | pass_exhaustive |  | 260 | 27 | 4.8 |
| fedavg | outcomeReportFail__abort | 1 | budget_stopped |  | 16669 | 50 | 90.3 |
| fedavg | outcomeReportFail__abort | 2 | budget_stopped |  | 40495 | 23 | 90.3 |
| fedavg | outcomeReportFail__abort | 3 | budget_stopped |  | 26661 | 16 | 90.3 |
| fedavg | outcomeReportFail__cjCrash | 1 | violation | S2F | 30391 | 16 | 37.7 |
| fedavg | outcomeReportFail__cjCrash | 2 | budget_stopped |  | 38746 | 23 | 90.2 |
| fedavg | outcomeReportFail__cjCrash | 3 | budget_stopped |  | 25552 | 21 | 90.3 |
| fedavg | outcomeReportFail__cpCrash | 1 | violation | I_Q | 12817 | 12 | 20.3 |
| fedavg | outcomeReportFail__cpCrash | 2 | violation | I_Q | 3 | 3 | 3.7 |
| fedavg | outcomeReportFail__cpCrash | 3 | pass_exhaustive |  | 663 | 22 | 7.9 |
| fedavg | outcomeReportFail__deleteJob | 1 | pass_exhaustive |  | 1671 | 29 | 9.2 |
| fedavg | outcomeReportFail__deleteJob | 2 | pass_exhaustive |  | 1 | 1 | 3.2 |
| fedavg | outcomeReportFail__deleteJob | 3 | pass_exhaustive |  | 15 | 8 | 3.7 |
| fedavg | outcomeReportFail__netLoss | 1 | budget_stopped |  | 25381 | 23 | 90.3 |
| fedavg | outcomeReportFail__netLoss | 2 | budget_stopped |  | 27261 | 23 | 90.3 |
| fedavg | outcomeReportFail__netLoss | 3 | budget_stopped |  | 18216 | 10 | 90.3 |
| fedavg | outcomeReportFail__outcomeTimeout | 1 | pass_exhaustive |  | 1671 | 37 | 8.7 |
| fedavg | outcomeReportFail__outcomeTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.3 |
| fedavg | outcomeReportFail__outcomeTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.6 |
| fedavg | outcomeReportFail__rpcTimeout | 1 | budget_stopped |  | 49253 | 21 | 90.3 |
| fedavg | outcomeReportFail__rpcTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.4 |
| fedavg | outcomeReportFail__rpcTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.9 |
| fedavg | outcomeReportFail__spCrash | 1 | violation | I_Q | 86 | 7 | 4.0 |
| fedavg | outcomeReportFail__spCrash | 2 | violation | I_Q | 51 | 11 | 4.6 |
| fedavg | outcomeReportFail__spCrash | 3 | violation | I_Q | 195 | 16 | 6.3 |
| fedavg | outcomeReportFail__spShutdown | 1 | violation_sim | I_Q | 54613 | 18 | 90.3 |
| fedavg | outcomeReportFail__spShutdown | 2 | violation | I_Q | 1834 | 13 | 8.8 |
| fedavg | outcomeReportFail__spShutdown | 3 | violation | I_Q | 7729 | 14 | 25.3 |
| fedavg | outcomeTimeout | 0 | pass_exhaustive |  | 5 | 5 | 3.0 |
| fedavg | outcomeTimeout | 1 | pass_exhaustive |  | 1541 | 36 | 8.3 |
| fedavg | outcomeTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.0 |
| fedavg | outcomeTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.3 |
| fedavg | outcomeTimeout | 5 | pass_exhaustive |  | 394 | 28 | 5.0 |
| fedavg | payCompute | 0 | pass_exhaustive |  | 5 | 5 | 3.4 |
| fedavg | payCompute | 1 | pass_exhaustive |  | 8 | 8 | 3.3 |
| fedavg | payCompute | 2 | pass_exhaustive |  | 1 | 1 | 3.4 |
| fedavg | payCompute | 3 | pass_exhaustive |  | 5 | 5 | 3.5 |
| fedavg | payCompute | 5 | pass_exhaustive |  | 297 | 26 | 5.0 |
| fedavg | payCompute__abort | 1 | budget_stopped |  | 17631 | 46 | 90.2 |
| fedavg | payCompute__abort | 2 | budget_stopped |  | 38491 | 24 | 90.3 |
| fedavg | payCompute__abort | 3 | budget_stopped |  | 27045 | 17 | 90.2 |
| fedavg | payCompute__cjCrash | 1 | violation | S2F | 22207 | 16 | 27.3 |
| fedavg | payCompute__cjCrash | 2 | budget_stopped |  | 41794 | 23 | 90.3 |
| fedavg | payCompute__cjCrash | 3 | budget_stopped |  | 25941 | 22 | 90.3 |
| fedavg | payCompute__netLoss | 1 | budget_stopped |  | 26195 | 23 | 90.3 |
| fedavg | payCompute__netLoss | 2 | budget_stopped |  | 29370 | 23 | 90.2 |
| fedavg | payCompute__netLoss | 3 | budget_stopped |  | 18977 | 10 | 90.2 |
| fedavg | payCompute__pullTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| fedavg | payCompute__pullTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.9 |
| fedavg | payCompute__pullTimeout | 3 | pass_exhaustive |  | 12552 | 14 | 29.9 |
| fedavg | payCompute__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | payCompute__resultWaitTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.9 |
| fedavg | payCompute__resultWaitTimeout | 3 | pass_exhaustive |  | 3441 | 15 | 12.2 |
| fedavg | payCompute__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.6 |
| fedavg | payCompute__submitTimeout | 2 | budget_stopped |  | 16297 | 43 | 90.3 |
| fedavg | payCompute__submitTimeout | 3 | budget_stopped |  | 16314 | 17 | 90.3 |
| fedavg | payCompute__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| fedavg | payCompute__taskTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.6 |
| fedavg | payCompute__taskTimeout | 3 | pass_exhaustive |  | 13992 | 14 | 32.7 |
| fedavg | payCompute__txTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| fedavg | payCompute__txTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.0 |
| fedavg | payCompute__txTimeout | 3 | pass_exhaustive |  | 34836 | 33 | 71.8 |
| fedavg | payConsumer | 0 | pass_exhaustive |  | 5 | 5 | 3.7 |
| fedavg | payConsumer | 1 | pass_exhaustive |  | 8 | 8 | 3.4 |
| fedavg | payConsumer | 2 | pass_exhaustive |  | 1 | 1 | 3.5 |
| fedavg | payConsumer | 3 | pass_exhaustive |  | 35 | 8 | 4.2 |
| fedavg | payConsumer | 5 | pass_exhaustive |  | 92 | 26 | 4.2 |
| fedavg | payConsumer__deadClient | 1 | budget_stopped |  | 51755 | 22 | 90.3 |
| fedavg | payConsumer__deadClient | 2 | budget_stopped |  | 61766 | 28 | 90.3 |
| fedavg | payConsumer__deadClient | 3 | budget_stopped |  | 25008 | 21 | 90.3 |
| fedavg | payConsumer__netLoss | 1 | budget_stopped |  | 25552 | 23 | 90.3 |
| fedavg | payConsumer__netLoss | 2 | budget_stopped |  | 27592 | 23 | 90.3 |
| fedavg | payConsumer__netLoss | 3 | budget_stopped |  | 19650 | 10 | 90.3 |
| fedavg | payConsumer__pullTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | payConsumer__pullTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.7 |
| fedavg | payConsumer__pullTimeout | 3 | pass_exhaustive |  | 12552 | 14 | 29.8 |
| fedavg | payConsumer__sjCrash | 1 | violation | S2F | 1052 | 16 | 6.5 |
| fedavg | payConsumer__sjCrash | 2 | pass_exhaustive |  | 230 | 18 | 3.9 |
| fedavg | payConsumer__sjCrash | 3 | pass_exhaustive |  | 8050 | 11 | 19.0 |
| fedavg | payConsumer__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | payConsumer__submitTimeout | 2 | budget_stopped |  | 28608 | 43 | 90.3 |
| fedavg | payConsumer__submitTimeout | 3 | budget_stopped |  | 14779 | 17 | 90.3 |
| fedavg | payConsumer__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.3 |
| fedavg | payConsumer__taskTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.3 |
| fedavg | payConsumer__taskTimeout | 3 | pass_exhaustive |  | 13992 | 14 | 31.3 |
| fedavg | payConsumer__txTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| fedavg | payConsumer__txTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.1 |
| fedavg | payConsumer__txTimeout | 3 | pass_exhaustive |  | 34836 | 32 | 72.6 |
| fedavg | payDelete | 0 | pass_exhaustive |  | 5 | 5 | 3.2 |
| fedavg | payDelete | 1 | pass_exhaustive |  | 8 | 8 | 3.4 |
| fedavg | payDelete | 2 | pass_exhaustive |  | 1 | 1 | 3.5 |
| fedavg | payDelete | 3 | pass_exhaustive |  | 5 | 5 | 3.6 |
| fedavg | payDelete | 5 | pass_exhaustive |  | 297 | 26 | 5.1 |
| fedavg | payDelete__abort | 1 | budget_stopped |  | 21222 | 35 | 90.3 |
| fedavg | payDelete__abort | 2 | budget_stopped |  | 39738 | 24 | 90.2 |
| fedavg | payDelete__abort | 3 | budget_stopped |  | 25423 | 16 | 90.3 |
| fedavg | payDelete__cjCrash | 1 | violation | S2F | 20402 | 16 | 24.1 |
| fedavg | payDelete__cjCrash | 2 | budget_stopped |  | 41184 | 23 | 90.3 |
| fedavg | payDelete__cjCrash | 3 | budget_stopped |  | 27618 | 21 | 90.3 |
| fedavg | payDelete__netLoss | 1 | budget_stopped |  | 26251 | 25 | 90.3 |
| fedavg | payDelete__netLoss | 2 | budget_stopped |  | 24808 | 24 | 90.3 |
| fedavg | payDelete__netLoss | 3 | budget_stopped |  | 19076 | 10 | 90.2 |
| fedavg | payDelete__pullTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.7 |
| fedavg | payDelete__pullTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.9 |
| fedavg | payDelete__pullTimeout | 3 | pass_exhaustive |  | 32376 | 34 | 67.8 |
| fedavg | payDelete__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| fedavg | payDelete__resultWaitTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.9 |
| fedavg | payDelete__resultWaitTimeout | 3 | pass_exhaustive |  | 9237 | 12 | 22.0 |
| fedavg | payDelete__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| fedavg | payDelete__submitTimeout | 2 | budget_stopped |  | 18703 | 40 | 90.3 |
| fedavg | payDelete__submitTimeout | 3 | budget_stopped |  | 17167 | 15 | 90.3 |
| fedavg | payDelete__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.7 |
| fedavg | payDelete__taskTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.4 |
| fedavg | payDelete__taskTimeout | 3 | pass_exhaustive |  | 35976 | 32 | 72.6 |
| fedavg | payDelete__txTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| fedavg | payDelete__txTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.1 |
| fedavg | payDelete__txTimeout | 3 | budget_stopped |  | 23790 | 23 | 90.2 |
| fedavg | payProduce | 0 | pass_exhaustive |  | 5 | 5 | 3.7 |
| fedavg | payProduce | 1 | pass_exhaustive |  | 8 | 8 | 3.7 |
| fedavg | payProduce | 2 | pass_exhaustive |  | 1 | 1 | 3.6 |
| fedavg | payProduce | 3 | pass_exhaustive |  | 5 | 5 | 3.9 |
| fedavg | payProduce | 5 | pass_exhaustive |  | 297 | 26 | 5.0 |
| fedavg | payProduce__abort | 1 | violation | S2F | 14411 | 17 | 42.6 |
| fedavg | payProduce__abort | 2 | budget_stopped |  | 40101 | 24 | 90.2 |
| fedavg | payProduce__abort | 3 | budget_stopped |  | 24787 | 17 | 90.2 |
| fedavg | payProduce__cjCrash | 1 | violation | S2F | 19712 | 16 | 24.3 |
| fedavg | payProduce__cjCrash | 2 | budget_stopped |  | 41659 | 23 | 90.3 |
| fedavg | payProduce__cjCrash | 3 | budget_stopped |  | 26520 | 22 | 90.3 |
| fedavg | payProduce__netLoss | 1 | budget_stopped |  | 26513 | 23 | 90.3 |
| fedavg | payProduce__netLoss | 2 | budget_stopped |  | 27908 | 22 | 90.3 |
| fedavg | payProduce__netLoss | 3 | budget_stopped |  | 17586 | 10 | 90.2 |
| fedavg | payProduce__pullTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.2 |
| fedavg | payProduce__pullTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.2 |
| fedavg | payProduce__pullTimeout | 3 | pass_exhaustive |  | 12552 | 14 | 31.0 |
| fedavg | payProduce__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| fedavg | payProduce__resultWaitTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.3 |
| fedavg | payProduce__resultWaitTimeout | 3 | pass_exhaustive |  | 3441 | 15 | 12.2 |
| fedavg | payProduce__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | payProduce__submitTimeout | 2 | budget_stopped |  | 20879 | 43 | 90.3 |
| fedavg | payProduce__submitTimeout | 3 | budget_stopped |  | 13878 | 17 | 90.2 |
| fedavg | payProduce__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.1 |
| fedavg | payProduce__taskTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.3 |
| fedavg | payProduce__taskTimeout | 3 | pass_exhaustive |  | 13992 | 14 | 31.0 |
| fedavg | payProduce__txTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.1 |
| fedavg | payProduce__txTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.0 |
| fedavg | payProduce__txTimeout | 3 | pass_exhaustive |  | 34836 | 32 | 73.5 |
| fedavg | prepFail | 0 | pass_exhaustive |  | 5 | 5 | 2.7 |
| fedavg | prepFail | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| fedavg | prepFail | 2 | budget_stopped |  | 43306 | 28 | 90.3 |
| fedavg | prepFail | 3 | budget_stopped |  | 17107 | 21 | 90.3 |
| fedavg | prepFail | 5 | pass_exhaustive |  | 28398 | 10 | 62.0 |
| fedavg | prepFail__abort | 1 | violation_sim | S2F | 25993 | 24 | 90.2 |
| fedavg | prepFail__abort | 2 | budget_stopped |  | 36108 | 16 | 90.3 |
| fedavg | prepFail__abort | 3 | budget_stopped |  | 21128 | 14 | 90.2 |
| fedavg | prepFail__cjCrash | 1 | violation | S2F | 29442 | 13 | 36.4 |
| fedavg | prepFail__cjCrash | 2 | budget_stopped |  | 31250 | 15 | 90.3 |
| fedavg | prepFail__cjCrash | 3 | budget_stopped |  | 22910 | 14 | 90.2 |
| fedavg | prepFail__deadClient | 1 | budget_stopped |  | 46126 | 21 | 90.3 |
| fedavg | prepFail__deadClient | 2 | budget_stopped |  | 28639 | 16 | 90.3 |
| fedavg | prepFail__deadClient | 3 | budget_stopped |  | 15914 | 13 | 90.3 |
| fedavg | prepFail__netLoss | 1 | violation_sim | S2F | 32745 | 21 | 90.3 |
| fedavg | prepFail__netLoss | 2 | budget_stopped |  | 32709 | 16 | 90.3 |
| fedavg | prepFail__netLoss | 3 | budget_stopped |  | 18429 | 10 | 90.3 |
| fedavg | prepFail__pullTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| fedavg | prepFail__pullTimeout | 2 | budget_stopped |  | 34480 | 23 | 90.3 |
| fedavg | prepFail__pullTimeout | 3 | budget_stopped |  | 13604 | 17 | 90.2 |
| fedavg | prepFail__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.1 |
| fedavg | prepFail__resultWaitTimeout | 2 | budget_stopped |  | 43809 | 24 | 90.3 |
| fedavg | prepFail__resultWaitTimeout | 3 | budget_stopped |  | 15017 | 18 | 90.3 |
| fedavg | prepFail__sjCrash | 1 | violation | S2F | 1292 | 16 | 6.6 |
| fedavg | prepFail__sjCrash | 2 | budget_stopped |  | 58425 | 20 | 90.2 |
| fedavg | prepFail__sjCrash | 3 | budget_stopped |  | 35673 | 17 | 90.3 |
| fedavg | prepFail__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| fedavg | prepFail__submitTimeout | 2 | budget_stopped |  | 37550 | 24 | 90.2 |
| fedavg | prepFail__submitTimeout | 3 | budget_stopped |  | 15532 | 17 | 90.3 |
| fedavg | prepFail__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.5 |
| fedavg | prepFail__taskTimeout | 2 | budget_stopped |  | 35810 | 24 | 90.3 |
| fedavg | prepFail__taskTimeout | 3 | budget_stopped |  | 14221 | 17 | 90.3 |
| fedavg | prepFail__txTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.7 |
| fedavg | prepFail__txTimeout | 2 | budget_stopped |  | 30373 | 22 | 90.3 |
| fedavg | prepFail__txTimeout | 3 | budget_stopped |  | 15915 | 15 | 90.2 |
| fedavg | pullTimeout | 0 | pass_exhaustive |  | 5 | 5 | 4.0 |
| fedavg | pullTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.9 |
| fedavg | pullTimeout | 2 | pass_exhaustive |  | 1 | 1 | 4.1 |
| fedavg | pullTimeout | 3 | pass_exhaustive |  | 12552 | 14 | 33.9 |
| fedavg | pullTimeout | 5 | pass_exhaustive |  | 2108 | 12 | 10.9 |
| fedavg | regIterRace | 0 | violation | S1Cleanup | 17 | 5 | 3.8 |
| fedavg | regIterRace | 1 | violation | S1Cleanup | 15 | 4 | 3.8 |
| fedavg | regIterRace | 2 | violation | S1Cleanup | 14 | 4 | 4.0 |
| fedavg | regIterRace | 3 | violation | S1Cleanup | 21 | 6 | 4.4 |
| fedavg | regIterRace | 5 | violation | S1Cleanup | 12 | 4 | 4.1 |
| fedavg | regIterRace__abort | 1 | violation | S1Cleanup | 29 | 5 | 3.4 |
| fedavg | regIterRace__abort | 2 | violation | S1Cleanup | 27 | 4 | 3.7 |
| fedavg | regIterRace__abort | 3 | violation | S1Cleanup | 39 | 4 | 3.6 |
| fedavg | regIterRace__deadClient | 1 | violation | S1Cleanup | 17 | 4 | 3.2 |
| fedavg | regIterRace__deadClient | 2 | violation | S1Cleanup | 13 | 4 | 3.4 |
| fedavg | regIterRace__deadClient | 3 | violation | S1Cleanup | 21 | 6 | 3.9 |
| fedavg | regIterRace__deleteJob | 1 | violation | S1Cleanup | 16 | 4 | 3.3 |
| fedavg | regIterRace__deleteJob | 2 | violation | S1Cleanup | 15 | 4 | 3.3 |
| fedavg | regIterRace__deleteJob | 3 | violation | S1Cleanup | 21 | 6 | 3.8 |
| fedavg | regIterRace__netLoss | 1 | violation | S1Cleanup | 38 | 4 | 3.1 |
| fedavg | regIterRace__netLoss | 2 | violation | S1Cleanup | 109 | 4 | 3.3 |
| fedavg | regIterRace__netLoss | 3 | violation | S1Cleanup | 211 | 4 | 3.9 |
| fedavg | regIterRace__outcomeTimeout | 1 | violation | S1Cleanup | 16 | 4 | 3.5 |
| fedavg | regIterRace__outcomeTimeout | 2 | violation | S1Cleanup | 14 | 4 | 3.7 |
| fedavg | regIterRace__outcomeTimeout | 3 | violation | S1Cleanup | 21 | 6 | 4.0 |
| fedavg | regIterRace__rpcTimeout | 1 | violation | S1Cleanup | 24 | 4 | 3.4 |
| fedavg | regIterRace__rpcTimeout | 2 | violation | S1Cleanup | 14 | 4 | 3.5 |
| fedavg | regIterRace__rpcTimeout | 3 | violation | S1Cleanup | 21 | 6 | 4.0 |
| fedavg | regIterRace__sjCrash | 1 | violation | S1Cleanup | 19 | 5 | 3.4 |
| fedavg | regIterRace__sjCrash | 2 | violation | S1Cleanup | 24 | 4 | 3.7 |
| fedavg | regIterRace__sjCrash | 3 | violation | S1Cleanup | 32 | 7 | 4.1 |
| fedavg | regIterRace__spCrash | 1 | violation | S1Cleanup | 30 | 4 | 3.6 |
| fedavg | regIterRace__spCrash | 2 | violation | S1Cleanup | 21 | 4 | 3.8 |
| fedavg | regIterRace__spCrash | 3 | violation | S1Cleanup | 31 | 6 | 4.4 |
| fedavg | regIterRace__spShutdown | 1 | violation | S1Cleanup | 38 | 4 | 3.1 |
| fedavg | regIterRace__spShutdown | 2 | violation | S1Cleanup | 28 | 4 | 3.4 |
| fedavg | regIterRace__spShutdown | 3 | violation | S1Cleanup | 31 | 6 | 3.7 |
| fedavg | regIterRace__submitTimeout | 1 | violation | S1Cleanup | 18 | 5 | 3.6 |
| fedavg | regIterRace__submitTimeout | 2 | violation | S1Cleanup | 36 | 5 | 3.8 |
| fedavg | regIterRace__submitTimeout | 3 | violation | S1Cleanup | 50 | 5 | 4.0 |
| fedavg | regIterRace__taskTimeout | 1 | violation | S1Cleanup | 17 | 4 | 3.2 |
| fedavg | regIterRace__taskTimeout | 2 | violation | S1Cleanup | 13 | 4 | 3.3 |
| fedavg | regIterRace__taskTimeout | 3 | violation | S1Cleanup | 50 | 5 | 3.8 |
| fedavg | resExpiry | 0 | pass_exhaustive |  | 209 | 25 | 3.8 |
| fedavg | resExpiry | 1 | pass_exhaustive |  | 1668 | 32 | 8.4 |
| fedavg | resExpiry | 2 | pass_exhaustive |  | 1 | 1 | 3.0 |
| fedavg | resExpiry | 3 | pass_exhaustive |  | 15 | 8 | 3.4 |
| fedavg | resExpiry | 5 | pass_exhaustive |  | 104 | 26 | 4.4 |
| fedavg | resExpiry__abort | 1 | budget_stopped |  | 18701 | 50 | 90.3 |
| fedavg | resExpiry__abort | 2 | budget_stopped |  | 37309 | 24 | 90.3 |
| fedavg | resExpiry__abort | 3 | budget_stopped |  | 26746 | 17 | 90.2 |
| fedavg | resExpiry__cjCrash | 1 | violation | S2F | 20677 | 15 | 25.5 |
| fedavg | resExpiry__cjCrash | 2 | budget_stopped |  | 38071 | 23 | 90.3 |
| fedavg | resExpiry__cjCrash | 3 | budget_stopped |  | 26562 | 21 | 90.3 |
| fedavg | resExpiry__cpCrash | 1 | violation | I_Q | 16439 | 11 | 21.1 |
| fedavg | resExpiry__cpCrash | 2 | violation | I_Q | 3 | 3 | 3.5 |
| fedavg | resExpiry__cpCrash | 3 | pass_exhaustive |  | 663 | 23 | 7.7 |
| fedavg | resExpiry__deleteJob | 1 | pass_exhaustive |  | 2492 | 20 | 9.6 |
| fedavg | resExpiry__deleteJob | 2 | pass_exhaustive |  | 1 | 1 | 2.8 |
| fedavg | resExpiry__deleteJob | 3 | pass_exhaustive |  | 15 | 8 | 3.4 |
| fedavg | resExpiry__netLoss | 1 | budget_stopped |  | 35037 | 21 | 90.3 |
| fedavg | resExpiry__netLoss | 2 | budget_stopped |  | 25225 | 23 | 90.3 |
| fedavg | resExpiry__netLoss | 3 | budget_stopped |  | 17410 | 10 | 90.2 |
| fedavg | resExpiry__outcomeTimeout | 1 | pass_exhaustive |  | 2492 | 18 | 10.2 |
| fedavg | resExpiry__outcomeTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.5 |
| fedavg | resExpiry__outcomeTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.6 |
| fedavg | resExpiry__rpcTimeout | 1 | budget_stopped |  | 47738 | 22 | 90.3 |
| fedavg | resExpiry__rpcTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.2 |
| fedavg | resExpiry__rpcTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.8 |
| fedavg | resExpiry__spCrash | 1 | violation | I_Q | 47 | 5 | 3.7 |
| fedavg | resExpiry__spCrash | 2 | violation | I_Q | 41 | 12 | 4.3 |
| fedavg | resExpiry__spCrash | 3 | violation | I_Q | 183 | 17 | 5.9 |
| fedavg | resExpiry__spShutdown | 1 | violation | I_Q | 361 | 8 | 4.4 |
| fedavg | resExpiry__spShutdown | 2 | violation | I_Q | 1326 | 15 | 7.0 |
| fedavg | resExpiry__spShutdown | 3 | violation | I_Q | 8040 | 14 | 26.8 |
| fedavg | resultWaitTimeout | 0 | pass_exhaustive |  | 5 | 5 | 3.4 |
| fedavg | resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.6 |
| fedavg | resultWaitTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.6 |
| fedavg | resultWaitTimeout | 3 | pass_exhaustive |  | 2893 | 15 | 11.7 |
| fedavg | resultWaitTimeout | 5 | pass_exhaustive |  | 798 | 23 | 6.9 |
| fedavg | rpcTimeout | 0 | pass_exhaustive |  | 35 | 9 | 4.2 |
| fedavg | rpcTimeout | 1 | budget_stopped |  | 48051 | 22 | 90.2 |
| fedavg | rpcTimeout | 2 | pass_exhaustive |  | 1 | 1 | 4.1 |
| fedavg | rpcTimeout | 3 | pass_exhaustive |  | 15 | 8 | 4.2 |
| fedavg | rpcTimeout | 5 | pass_exhaustive |  | 423 | 28 | 6.6 |
| fedavg | sjCrash | 0 | pass_exhaustive |  | 5 | 5 | 5.3 |
| fedavg | sjCrash | 1 | violation | S2F | 1044 | 15 | 8.6 |
| fedavg | sjCrash | 2 | pass_exhaustive |  | 230 | 18 | 6.0 |
| fedavg | sjCrash | 3 | pass_exhaustive |  | 2305 | 15 | 12.1 |
| fedavg | sjCrash | 5 | pass_exhaustive |  | 17895 | 11 | 38.2 |
| fedavg | sjSyncFail | 0 | pass_exhaustive |  | 5 | 5 | 2.9 |
| fedavg | sjSyncFail | 1 | violation | S2F | 571 | 15 | 5.4 |
| fedavg | sjSyncFail | 2 | pass_exhaustive |  | 1 | 1 | 3.2 |
| fedavg | sjSyncFail | 3 | pass_exhaustive |  | 15 | 8 | 3.5 |
| fedavg | sjSyncFail | 5 | pass_exhaustive |  | 463 | 25 | 5.2 |
| fedavg | sjSyncFail__abort | 1 | violation | S2F | 1263 | 14 | 6.5 |
| fedavg | sjSyncFail__abort | 2 | budget_stopped |  | 36931 | 24 | 90.2 |
| fedavg | sjSyncFail__abort | 3 | budget_stopped |  | 24108 | 17 | 90.3 |
| fedavg | sjSyncFail__cjCrash | 1 | violation | S2F | 3053 | 13 | 8.1 |
| fedavg | sjSyncFail__cjCrash | 2 | budget_stopped |  | 32762 | 18 | 90.3 |
| fedavg | sjSyncFail__cjCrash | 3 | budget_stopped |  | 22662 | 15 | 90.3 |
| fedavg | sjSyncFail__deadClient | 1 | violation | S2F | 6186 | 13 | 10.3 |
| fedavg | sjSyncFail__deadClient | 2 | budget_stopped |  | 61311 | 21 | 90.3 |
| fedavg | sjSyncFail__deadClient | 3 | budget_stopped |  | 26247 | 23 | 90.3 |
| fedavg | sjSyncFail__deleteJob | 1 | violation | S2F | 658 | 14 | 6.1 |
| fedavg | sjSyncFail__deleteJob | 2 | pass_exhaustive |  | 1 | 1 | 3.1 |
| fedavg | sjSyncFail__deleteJob | 3 | pass_exhaustive |  | 15 | 8 | 3.7 |
| fedavg | sjSyncFail__netLoss | 1 | violation | S2F | 4935 | 11 | 10.9 |
| fedavg | sjSyncFail__netLoss | 2 | budget_stopped |  | 23835 | 22 | 90.2 |
| fedavg | sjSyncFail__netLoss | 3 | budget_stopped |  | 16885 | 10 | 90.2 |
| fedavg | sjSyncFail__outcomeTimeout | 1 | violation | S2F | 657 | 14 | 6.3 |
| fedavg | sjSyncFail__outcomeTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.1 |
| fedavg | sjSyncFail__outcomeTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.7 |
| fedavg | sjSyncFail__pullTimeout | 1 | violation | S2F | 614 | 15 | 6.0 |
| fedavg | sjSyncFail__pullTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.2 |
| fedavg | sjSyncFail__pullTimeout | 3 | pass_exhaustive |  | 16152 | 14 | 49.2 |
| fedavg | sjSyncFail__resultWaitTimeout | 1 | violation | S2F | 611 | 15 | 5.9 |
| fedavg | sjSyncFail__resultWaitTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.2 |
| fedavg | sjSyncFail__resultWaitTimeout | 3 | pass_exhaustive |  | 4401 | 15 | 16.9 |
| fedavg | sjSyncFail__rpcTimeout | 1 | violation | S2F | 5996 | 12 | 12.0 |
| fedavg | sjSyncFail__rpcTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.1 |
| fedavg | sjSyncFail__rpcTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.5 |
| fedavg | sjSyncFail__sjCrash | 1 | violation | S2F | 1061 | 15 | 6.0 |
| fedavg | sjSyncFail__sjCrash | 2 | pass_exhaustive |  | 230 | 18 | 4.1 |
| fedavg | sjSyncFail__sjCrash | 3 | pass_exhaustive |  | 2305 | 17 | 8.5 |
| fedavg | sjSyncFail__spCrash | 1 | violation | I_Q | 104 | 7 | 3.7 |
| fedavg | sjSyncFail__spCrash | 2 | violation | I_Q | 41 | 12 | 4.1 |
| fedavg | sjSyncFail__spCrash | 3 | violation | I_Q | 244 | 15 | 6.3 |
| fedavg | sjSyncFail__spShutdown | 1 | violation | S2F | 11698 | 10 | 17.2 |
| fedavg | sjSyncFail__spShutdown | 2 | violation | I_Q | 4815 | 14 | 12.5 |
| fedavg | sjSyncFail__spShutdown | 3 | violation | I_Q | 14921 | 13 | 41.4 |
| fedavg | sjSyncFail__submitTimeout | 1 | violation | S2F | 635 | 15 | 6.2 |
| fedavg | sjSyncFail__submitTimeout | 2 | budget_stopped |  | 15877 | 43 | 90.2 |
| fedavg | sjSyncFail__submitTimeout | 3 | budget_stopped |  | 16401 | 17 | 90.3 |
| fedavg | sjSyncFail__taskTimeout | 1 | violation | S2F | 653 | 15 | 5.7 |
| fedavg | sjSyncFail__taskTimeout | 2 | pass_exhaustive |  | 5693 | 20 | 11.6 |
| fedavg | sjSyncFail__taskTimeout | 3 | pass_exhaustive |  | 16152 | 14 | 48.4 |
| fedavg | sjSyncFail__txTimeout | 1 | violation | S2F | 616 | 15 | 6.1 |
| fedavg | sjSyncFail__txTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.5 |
| fedavg | sjSyncFail__txTimeout | 3 | budget_stopped |  | 23025 | 24 | 90.3 |
| fedavg | slowAdminStop | 0 | budget_stopped |  | 18231 | 57 | 90.3 |
| fedavg | slowAdminStop | 1 | budget_stopped |  | 18007 | 50 | 90.2 |
| fedavg | slowAdminStop | 2 | violation | S4CompletedWf | 2421 | 12 | 8.9 |
| fedavg | slowAdminStop | 3 | violation | S4CompletedWf | 14507 | 8 | 42.1 |
| fedavg | slowAdminStop | 5 | budget_stopped |  | 22942 | 16 | 90.3 |
| fedavg | slowAdminStop__abort | 1 | budget_stopped |  | 17960 | 50 | 90.3 |
| fedavg | slowAdminStop__abort | 2 | violation | S4CompletedWf | 2422 | 13 | 8.3 |
| fedavg | slowAdminStop__abort | 3 | violation | S4CompletedWf | 14542 | 9 | 41.1 |
| fedavg | slowAdminStop__cjCrash | 1 | violation | S2F | 53803 | 13 | 59.9 |
| fedavg | slowAdminStop__cjCrash | 2 | violation | S4CompletedWf | 7935 | 9 | 15.4 |
| fedavg | slowAdminStop__cjCrash | 3 | violation | S4CompletedWf | 25019 | 8 | 51.4 |
| fedavg | slowAdminStop__cpCrash | 1 | violation | I_Q | 26776 | 11 | 36.1 |
| fedavg | slowAdminStop__cpCrash | 2 | violation | I_Q | 16 | 4 | 3.5 |
| fedavg | slowAdminStop__cpCrash | 3 | budget_stopped |  | 24345 | 12 | 90.3 |
| fedavg | slowAdminStop__deadClient | 1 | violation_sim | S2F | 48572 | 18 | 90.3 |
| fedavg | slowAdminStop__deadClient | 2 | violation | S4CompletedWf | 43967 | 13 | 71.9 |
| fedavg | slowAdminStop__deadClient | 3 | budget_stopped |  | 27047 | 12 | 90.3 |
| fedavg | slowAdminStop__deleteJob | 1 | budget_stopped |  | 17251 | 50 | 90.2 |
| fedavg | slowAdminStop__deleteJob | 2 | violation | S4CompletedWf | 2422 | 13 | 7.8 |
| fedavg | slowAdminStop__deleteJob | 3 | violation | S4CompletedWf | 14497 | 8 | 40.3 |
| fedavg | slowAdminStop__netLoss | 1 | budget_stopped |  | 44237 | 20 | 90.3 |
| fedavg | slowAdminStop__netLoss | 2 | budget_stopped |  | 39295 | 12 | 90.3 |
| fedavg | slowAdminStop__netLoss | 3 | budget_stopped |  | 30721 | 9 | 90.2 |
| fedavg | slowAdminStop__outcomeTimeout | 1 | budget_stopped |  | 17127 | 50 | 90.3 |
| fedavg | slowAdminStop__outcomeTimeout | 2 | violation | S4CompletedWf | 209 | 9 | 4.4 |
| fedavg | slowAdminStop__outcomeTimeout | 3 | violation | S4CompletedWf | 827 | 8 | 6.6 |
| fedavg | slowAdminStop__rpcTimeout | 1 | budget_stopped |  | 39752 | 18 | 90.3 |
| fedavg | slowAdminStop__rpcTimeout | 2 | violation | S4CompletedWf | 2563 | 12 | 8.4 |
| fedavg | slowAdminStop__rpcTimeout | 3 | violation | S4CompletedWf | 14773 | 8 | 41.8 |
| fedavg | slowAdminStop__sjCrash | 1 | violation | S2F | 2173 | 13 | 8.4 |
| fedavg | slowAdminStop__sjCrash | 2 | violation | S4CompletedWf | 5929 | 10 | 13.9 |
| fedavg | slowAdminStop__sjCrash | 3 | budget_stopped |  | 28751 | 13 | 90.3 |
| fedavg | slowAdminStop__spCrash | 1 | violation | I_Q | 136 | 7 | 3.3 |
| fedavg | slowAdminStop__spCrash | 2 | violation | I_Q | 2472 | 11 | 9.3 |
| fedavg | slowAdminStop__spCrash | 3 | violation | I_Q | 16206 | 7 | 51.0 |
| fedavg | slowAdminStop__spShutdown | 1 | violation_sim | I_Q | 53641 | 17 | 90.3 |
| fedavg | slowAdminStop__spShutdown | 2 | violation | S4CompletedWf | 13943 | 9 | 27.3 |
| fedavg | slowAdminStop__spShutdown | 3 | violation_sim | I_Q | 27568 | 12 | 90.2 |
| fedavg | slowEnvelope | 0 | pass_exhaustive |  | 5 | 5 | 3.4 |
| fedavg | slowEnvelope | 1 | pass_exhaustive |  | 8 | 8 | 3.5 |
| fedavg | slowEnvelope | 2 | pass_exhaustive |  | 1 | 1 | 3.4 |
| fedavg | slowEnvelope | 3 | pass_exhaustive |  | 35 | 8 | 4.5 |
| fedavg | slowEnvelope | 5 | pass_exhaustive |  | 92 | 26 | 4.6 |
| fedavg | slowEnvelope__deadClient | 1 | budget_stopped |  | 52106 | 22 | 90.3 |
| fedavg | slowEnvelope__deadClient | 2 | budget_stopped |  | 62720 | 28 | 90.3 |
| fedavg | slowEnvelope__deadClient | 3 | budget_stopped |  | 23285 | 20 | 90.3 |
| fedavg | slowEnvelope__netLoss | 1 | budget_stopped |  | 26636 | 23 | 90.2 |
| fedavg | slowEnvelope__netLoss | 2 | budget_stopped |  | 25234 | 22 | 90.2 |
| fedavg | slowEnvelope__netLoss | 3 | budget_stopped |  | 18432 | 10 | 90.3 |
| fedavg | slowEnvelope__pullTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | slowEnvelope__pullTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.8 |
| fedavg | slowEnvelope__pullTimeout | 3 | pass_exhaustive |  | 12552 | 14 | 27.9 |
| fedavg | slowEnvelope__sjCrash | 1 | violation | S2F | 1067 | 16 | 6.3 |
| fedavg | slowEnvelope__sjCrash | 2 | pass_exhaustive |  | 230 | 18 | 4.1 |
| fedavg | slowEnvelope__sjCrash | 3 | pass_exhaustive |  | 8050 | 11 | 18.4 |
| fedavg | slowEnvelope__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | slowEnvelope__submitTimeout | 2 | budget_stopped |  | 17457 | 44 | 90.3 |
| fedavg | slowEnvelope__submitTimeout | 3 | budget_stopped |  | 15255 | 17 | 90.3 |
| fedavg | slowEnvelope__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | slowEnvelope__taskTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.5 |
| fedavg | slowEnvelope__taskTimeout | 3 | pass_exhaustive |  | 13992 | 14 | 30.5 |
| fedavg | slowEnvelope__txTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | slowEnvelope__txTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.6 |
| fedavg | slowEnvelope__txTimeout | 3 | pass_exhaustive |  | 34836 | 34 | 70.4 |
| fedavg | slowFinalize | 0 | budget_stopped |  | 49377 | 27 | 90.2 |
| fedavg | slowFinalize | 1 | budget_stopped |  | 52989 | 22 | 90.2 |
| fedavg | slowFinalize | 2 | budget_stopped |  | 61034 | 27 | 90.3 |
| fedavg | slowFinalize | 3 | budget_stopped |  | 27563 | 29 | 90.2 |
| fedavg | slowFinalize | 5 | budget_stopped |  | 31520 | 31 | 90.3 |
| fedavg | slowFinalize__abort | 1 | violation_sim | S2F | 42976 | 18 | 90.3 |
| fedavg | slowFinalize__abort | 2 | budget_stopped |  | 41954 | 15 | 90.3 |
| fedavg | slowFinalize__abort | 3 | budget_stopped |  | 28425 | 13 | 90.2 |
| fedavg | slowFinalize__deadClient | 1 | budget_stopped |  | 52275 | 22 | 90.3 |
| fedavg | slowFinalize__deadClient | 2 | budget_stopped |  | 62551 | 28 | 90.3 |
| fedavg | slowFinalize__deadClient | 3 | budget_stopped |  | 29645 | 30 | 90.2 |
| fedavg | slowFinalize__netLoss | 1 | budget_stopped |  | 54261 | 16 | 90.2 |
| fedavg | slowFinalize__netLoss | 2 | budget_stopped |  | 30707 | 12 | 90.3 |
| fedavg | slowFinalize__netLoss | 3 | budget_stopped |  | 22502 | 9 | 90.3 |
| fedavg | slowFinalize__pullTimeout | 1 | budget_stopped |  | 43140 | 21 | 90.3 |
| fedavg | slowFinalize__pullTimeout | 2 | budget_stopped |  | 43367 | 19 | 90.3 |
| fedavg | slowFinalize__pullTimeout | 3 | budget_stopped |  | 20497 | 15 | 90.3 |
| fedavg | slowFinalize__resultWaitTimeout | 1 | budget_stopped |  | 44589 | 21 | 90.3 |
| fedavg | slowFinalize__resultWaitTimeout | 2 | budget_stopped |  | 49117 | 20 | 90.3 |
| fedavg | slowFinalize__resultWaitTimeout | 3 | budget_stopped |  | 17999 | 16 | 90.3 |
| fedavg | slowFinalize__sjCrash | 1 | violation | S2F | 18083 | 12 | 17.6 |
| fedavg | slowFinalize__sjCrash | 2 | budget_stopped |  | 65968 | 16 | 90.3 |
| fedavg | slowFinalize__sjCrash | 3 | budget_stopped |  | 37868 | 18 | 90.2 |
| fedavg | slowFinalize__submitTimeout | 1 | budget_stopped |  | 45518 | 21 | 90.3 |
| fedavg | slowFinalize__submitTimeout | 2 | budget_stopped |  | 27424 | 16 | 90.3 |
| fedavg | slowFinalize__submitTimeout | 3 | budget_stopped |  | 18765 | 12 | 90.2 |
| fedavg | slowFinalize__taskTimeout | 1 | budget_stopped |  | 44427 | 21 | 90.3 |
| fedavg | slowFinalize__taskTimeout | 2 | budget_stopped |  | 37656 | 18 | 90.3 |
| fedavg | slowFinalize__taskTimeout | 3 | budget_stopped |  | 19332 | 15 | 90.2 |
| fedavg | slowFinalize__txTimeout | 1 | budget_stopped |  | 41821 | 21 | 90.3 |
| fedavg | slowFinalize__txTimeout | 2 | budget_stopped |  | 40203 | 19 | 90.3 |
| fedavg | slowFinalize__txTimeout | 3 | budget_stopped |  | 19376 | 13 | 90.2 |
| fedavg | slowSJTeardown | 0 | pass_exhaustive |  | 5 | 5 | 3.5 |
| fedavg | slowSJTeardown | 1 | pass_exhaustive |  | 2435 | 32 | 9.6 |
| fedavg | slowSJTeardown | 2 | pass_exhaustive |  | 1 | 1 | 3.6 |
| fedavg | slowSJTeardown | 3 | pass_exhaustive |  | 23 | 8 | 4.5 |
| fedavg | slowSJTeardown | 5 | pass_exhaustive |  | 1502 | 22 | 7.6 |
| fedavg | slowSJTeardown__abort | 1 | budget_stopped |  | 18278 | 51 | 90.3 |
| fedavg | slowSJTeardown__abort | 2 | budget_stopped |  | 41072 | 25 | 90.2 |
| fedavg | slowSJTeardown__abort | 3 | budget_stopped |  | 26412 | 17 | 90.2 |
| fedavg | slowSJTeardown__cjCrash | 1 | violation | S2F | 25257 | 16 | 32.0 |
| fedavg | slowSJTeardown__cjCrash | 2 | budget_stopped |  | 42222 | 23 | 90.2 |
| fedavg | slowSJTeardown__cjCrash | 3 | budget_stopped |  | 26766 | 22 | 90.2 |
| fedavg | slowSJTeardown__cpCrash | 1 | violation | I_Q | 14382 | 12 | 22.7 |
| fedavg | slowSJTeardown__cpCrash | 2 | violation | I_Q | 3 | 3 | 4.2 |
| fedavg | slowSJTeardown__cpCrash | 3 | pass_exhaustive |  | 2291 | 13 | 15.2 |
| fedavg | slowSJTeardown__netLoss | 1 | budget_stopped |  | 25902 | 23 | 90.2 |
| fedavg | slowSJTeardown__netLoss | 2 | budget_stopped |  | 27221 | 23 | 90.3 |
| fedavg | slowSJTeardown__netLoss | 3 | budget_stopped |  | 17626 | 10 | 90.2 |
| fedavg | slowSJTeardown__pullTimeout | 1 | budget_stopped |  | 48933 | 35 | 90.3 |
| fedavg | slowSJTeardown__pullTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.7 |
| fedavg | slowSJTeardown__pullTimeout | 3 | pass_exhaustive |  | 21327 | 14 | 50.3 |
| fedavg | slowSJTeardown__resultWaitTimeout | 1 | budget_stopped |  | 42112 | 33 | 90.2 |
| fedavg | slowSJTeardown__resultWaitTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.0 |
| fedavg | slowSJTeardown__resultWaitTimeout | 3 | pass_exhaustive |  | 9701 | 15 | 21.1 |
| fedavg | slowSJTeardown__rpcTimeout | 1 | budget_stopped |  | 41332 | 20 | 90.2 |
| fedavg | slowSJTeardown__rpcTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.9 |
| fedavg | slowSJTeardown__rpcTimeout | 3 | pass_exhaustive |  | 23 | 8 | 3.5 |
| fedavg | slowSJTeardown__sjCrash | 1 | violation | S2F | 1172 | 14 | 7.9 |
| fedavg | slowSJTeardown__sjCrash | 2 | pass_exhaustive |  | 486 | 18 | 6.2 |
| fedavg | slowSJTeardown__sjCrash | 3 | pass_exhaustive |  | 17010 | 9 | 45.7 |
| fedavg | slowSJTeardown__submitTimeout | 1 | budget_stopped |  | 29570 | 39 | 90.2 |
| fedavg | slowSJTeardown__submitTimeout | 2 | budget_stopped |  | 16366 | 44 | 90.2 |
| fedavg | slowSJTeardown__submitTimeout | 3 | budget_stopped |  | 15503 | 17 | 90.2 |
| fedavg | slowSJTeardown__taskTimeout | 1 | violation | S2F | 24178 | 20 | 29.9 |
| fedavg | slowSJTeardown__taskTimeout | 2 | pass_exhaustive |  | 2627 | 28 | 6.6 |
| fedavg | slowSJTeardown__taskTimeout | 3 | pass_exhaustive |  | 29247 | 36 | 66.6 |
| fedavg | slowSJTeardown__txTimeout | 1 | budget_stopped |  | 35991 | 34 | 90.3 |
| fedavg | slowSJTeardown__txTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.9 |
| fedavg | slowSJTeardown__txTimeout | 3 | budget_stopped |  | 22564 | 23 | 90.2 |
| fedavg | slowShutdownAbort | 0 | violation | I_Q | 40 | 7 | 3.2 |
| fedavg | slowShutdownAbort | 1 | violation | S2F | 44740 | 10 | 39.3 |
| fedavg | slowShutdownAbort | 2 | violation | I_Q | 5134 | 12 | 13.1 |
| fedavg | slowShutdownAbort | 3 | violation | I_Q | 17497 | 14 | 46.6 |
| fedavg | slowShutdownAbort | 5 | violation | I_Q | 9501 | 12 | 23.9 |
| fedavg | slowShutdownAbort__abort | 1 | violation | S2F | 53199 | 9 | 61.0 |
| fedavg | slowShutdownAbort__abort | 2 | violation_sim | I_Q | 43951 | 16 | 90.3 |
| fedavg | slowShutdownAbort__abort | 3 | violation_sim | I_Q | 29291 | 12 | 90.3 |
| fedavg | slowShutdownAbort__cjCrash | 1 | violation | S2F | 61641 | 10 | 52.7 |
| fedavg | slowShutdownAbort__cjCrash | 2 | violation | I_Q | 12548 | 9 | 23.0 |
| fedavg | slowShutdownAbort__cjCrash | 3 | violation_sim | I_Q | 33767 | 14 | 90.3 |
| fedavg | slowShutdownAbort__cpCrash | 1 | violation | I_Q | 1891 | 9 | 6.3 |
| fedavg | slowShutdownAbort__cpCrash | 2 | violation | I_Q | 31 | 5 | 3.3 |
| fedavg | slowShutdownAbort__cpCrash | 3 | violation | I_Q | 1052 | 13 | 7.2 |
| fedavg | slowShutdownAbort__deadClient | 1 | violation_sim | I_Q | 87039 | 14 | 90.3 |
| fedavg | slowShutdownAbort__deadClient | 2 | violation_sim | I_Q | 45217 | 14 | 90.3 |
| fedavg | slowShutdownAbort__deadClient | 3 | violation_sim | I_Q | 29518 | 15 | 90.3 |
| fedavg | slowShutdownAbort__deleteJob | 1 | violation | S2F | 44677 | 10 | 36.8 |
| fedavg | slowShutdownAbort__deleteJob | 2 | violation | I_Q | 5134 | 12 | 13.6 |
| fedavg | slowShutdownAbort__deleteJob | 3 | violation | I_Q | 18715 | 14 | 48.5 |
| fedavg | slowShutdownAbort__netLoss | 1 | violation_sim | I_Q | 63850 | 14 | 90.3 |
| fedavg | slowShutdownAbort__netLoss | 2 | violation_sim | I_Q | 40134 | 12 | 90.3 |
| fedavg | slowShutdownAbort__netLoss | 3 | violation_sim | I_Q | 30669 | 9 | 90.3 |
| fedavg | slowShutdownAbort__outcomeTimeout | 1 | violation | S4CompletedWf | 44696 | 11 | 41.8 |
| fedavg | slowShutdownAbort__outcomeTimeout | 2 | violation | I_Q | 5342 | 12 | 14.4 |
| fedavg | slowShutdownAbort__outcomeTimeout | 3 | violation | I_Q | 20234 | 13 | 51.3 |
| fedavg | slowShutdownAbort__rpcTimeout | 1 | violation | I_Q | 1602 | 9 | 6.0 |
| fedavg | slowShutdownAbort__rpcTimeout | 2 | violation | I_Q | 5100 | 11 | 15.0 |
| fedavg | slowShutdownAbort__rpcTimeout | 3 | violation | I_Q | 25861 | 21 | 74.4 |
| fedavg | slowShutdownAbort__sjCrash | 1 | violation | S2F | 32082 | 10 | 35.7 |
| fedavg | slowShutdownAbort__sjCrash | 2 | violation | I_Q | 21772 | 10 | 35.1 |
| fedavg | slowShutdownAbort__sjCrash | 3 | violation_sim | I_Q | 25905 | 16 | 90.3 |
| fedavg | slowShutdownAbort__spCrash | 1 | violation | I_Q | 234 | 6 | 3.8 |
| fedavg | slowShutdownAbort__spCrash | 2 | violation | I_Q | 2286 | 10 | 9.8 |
| fedavg | slowShutdownAbort__spCrash | 3 | violation | I_Q | 8712 | 12 | 30.4 |
| fedavg | slowShutdownAbort__spShutdown | 1 | violation | S2F | 44725 | 10 | 39.6 |
| fedavg | slowShutdownAbort__spShutdown | 2 | violation | I_Q | 5218 | 12 | 12.9 |
| fedavg | slowShutdownAbort__spShutdown | 3 | violation | I_Q | 22749 | 13 | 60.8 |
| fedavg | sourceFailure | 0 | pass_exhaustive |  | 5 | 5 | 3.3 |
| fedavg | sourceFailure | 1 | pass_exhaustive |  | 8 | 8 | 3.3 |
| fedavg | sourceFailure | 2 | pass_exhaustive |  | 1 | 1 | 3.5 |
| fedavg | sourceFailure | 3 | pass_exhaustive |  | 35 | 8 | 4.3 |
| fedavg | sourceFailure | 5 | pass_exhaustive |  | 92 | 26 | 3.9 |
| fedavg | sourceFailure__deadClient | 1 | budget_stopped |  | 46658 | 23 | 90.3 |
| fedavg | sourceFailure__deadClient | 2 | budget_stopped |  | 64568 | 30 | 90.3 |
| fedavg | sourceFailure__deadClient | 3 | budget_stopped |  | 25933 | 22 | 90.2 |
| fedavg | sourceFailure__netLoss | 1 | budget_stopped |  | 26452 | 25 | 90.3 |
| fedavg | sourceFailure__netLoss | 2 | budget_stopped |  | 24110 | 24 | 90.3 |
| fedavg | sourceFailure__netLoss | 3 | budget_stopped |  | 18898 | 12 | 90.3 |
| fedavg | sourceFailure__pullTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.7 |
| fedavg | sourceFailure__pullTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.6 |
| fedavg | sourceFailure__pullTimeout | 3 | pass_exhaustive |  | 12552 | 14 | 29.8 |
| fedavg | sourceFailure__sjCrash | 1 | violation | S2F | 1044 | 16 | 6.2 |
| fedavg | sourceFailure__sjCrash | 2 | pass_exhaustive |  | 230 | 18 | 4.4 |
| fedavg | sourceFailure__sjCrash | 3 | pass_exhaustive |  | 8050 | 11 | 17.8 |
| fedavg | sourceFailure__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.7 |
| fedavg | sourceFailure__submitTimeout | 2 | budget_stopped |  | 28934 | 43 | 90.3 |
| fedavg | sourceFailure__submitTimeout | 3 | budget_stopped |  | 16916 | 17 | 90.2 |
| fedavg | sourceFailure__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| fedavg | sourceFailure__taskTimeout | 2 | pass_exhaustive |  | 491 | 28 | 4.2 |
| fedavg | sourceFailure__taskTimeout | 3 | pass_exhaustive |  | 13992 | 14 | 30.1 |
| fedavg | sourceFailure__txTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.5 |
| fedavg | sourceFailure__txTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.8 |
| fedavg | sourceFailure__txTimeout | 3 | pass_exhaustive |  | 34836 | 32 | 74.1 |
| fedavg | spCrash | 0 | pass_exhaustive |  | 35 | 9 | 4.9 |
| fedavg | spCrash | 1 | violation | I_Q | 86 | 7 | 5.1 |
| fedavg | spCrash | 2 | violation | I_Q | 41 | 12 | 7.2 |
| fedavg | spCrash | 3 | violation | I_Q | 213 | 17 | 8.3 |
| fedavg | spCrash | 5 | violation | I_Q | 233 | 13 | 8.1 |
| fedavg | spShutdown | 0 | violation | I_Q | 40 | 7 | 5.8 |
| fedavg | spShutdown | 1 | violation_sim | I_Q | 58194 | 22 | 90.4 |
| fedavg | spShutdown | 2 | violation | I_Q | 1288 | 14 | 9.4 |
| fedavg | spShutdown | 3 | violation | I_Q | 6291 | 15 | 22.5 |
| fedavg | spShutdown | 5 | violation | I_Q | 4355 | 14 | 16.7 |
| fedavg | statusLost | 0 | pass_exhaustive |  | 5 | 5 | 3.4 |
| fedavg | statusLost | 1 | violation | S2F | 16345 | 16 | 29.9 |
| fedavg | statusLost | 2 | violation | S4CompletedWf | 3996 | 18 | 10.8 |
| fedavg | statusLost | 3 | violation | S4CompletedWf | 19668 | 17 | 45.6 |
| fedavg | statusLost | 5 | pass_exhaustive |  | 793 | 22 | 6.6 |
| fedavg | statusLost__abort | 1 | violation_sim | S4CompletedWf | 36624 | 25 | 90.3 |
| fedavg | statusLost__abort | 2 | violation_sim | S4CompletedWf | 46116 | 19 | 90.3 |
| fedavg | statusLost__abort | 3 | violation_sim | S4CompletedWf | 25579 | 15 | 90.3 |
| fedavg | statusLost__cjCrash | 1 | violation | S2F | 31074 | 13 | 36.6 |
| fedavg | statusLost__cjCrash | 2 | violation_sim | S4CompletedWf | 40671 | 16 | 90.2 |
| fedavg | statusLost__cjCrash | 3 | violation_sim | S4CompletedWf | 26384 | 14 | 90.3 |
| fedavg | statusLost__cpCrash | 1 | violation | I_Q | 20754 | 11 | 26.6 |
| fedavg | statusLost__cpCrash | 2 | violation | I_Q | 15 | 5 | 3.6 |
| fedavg | statusLost__cpCrash | 3 | budget_stopped |  | 25488 | 23 | 90.3 |
| fedavg | statusLost__deadClient | 1 | violation_sim | S4CompletedWf | 55047 | 19 | 90.3 |
| fedavg | statusLost__deadClient | 2 | violation_sim | S4CompletedWf | 51366 | 17 | 90.3 |
| fedavg | statusLost__deadClient | 3 | budget_stopped |  | 23269 | 19 | 90.3 |
| fedavg | statusLost__deleteJob | 1 | violation | S2F | 15733 | 16 | 25.0 |
| fedavg | statusLost__deleteJob | 2 | violation | S4CompletedWf | 4264 | 19 | 10.8 |
| fedavg | statusLost__deleteJob | 3 | violation | S4CompletedWf | 18726 | 16 | 41.8 |
| fedavg | statusLost__netLoss | 1 | violation_sim | S4CompletedWf | 35581 | 21 | 90.2 |
| fedavg | statusLost__netLoss | 2 | violation_sim | S4CompletedWf | 28181 | 17 | 90.3 |
| fedavg | statusLost__netLoss | 3 | violation_sim | S4CompletedWf | 21937 | 9 | 90.2 |
| fedavg | statusLost__outcomeTimeout | 1 | violation | S2F | 16598 | 16 | 29.0 |
| fedavg | statusLost__outcomeTimeout | 2 | violation | S4CompletedWf | 428 | 16 | 5.1 |
| fedavg | statusLost__outcomeTimeout | 3 | violation | S4CompletedWf | 1293 | 17 | 7.4 |
| fedavg | statusLost__rpcTimeout | 1 | violation_sim | S4CompletedWf | 45474 | 19 | 90.3 |
| fedavg | statusLost__rpcTimeout | 2 | violation | S4CompletedWf | 4232 | 18 | 9.3 |
| fedavg | statusLost__rpcTimeout | 3 | violation | S4CompletedWf | 18507 | 16 | 43.2 |
| fedavg | statusLost__sjCrash | 1 | violation | S2F | 1875 | 14 | 7.8 |
| fedavg | statusLost__sjCrash | 2 | violation | S4CompletedWf | 24104 | 12 | 36.2 |
| fedavg | statusLost__sjCrash | 3 | budget_stopped |  | 34285 | 20 | 90.2 |
| fedavg | statusLost__spCrash | 1 | violation | I_Q | 93 | 7 | 3.7 |
| fedavg | statusLost__spCrash | 2 | violation | I_Q | 207 | 12 | 4.9 |
| fedavg | statusLost__spCrash | 3 | violation | I_Q | 1499 | 12 | 9.7 |
| fedavg | statusLost__spShutdown | 1 | violation_sim | I_Q | 52738 | 17 | 90.2 |
| fedavg | statusLost__spShutdown | 2 | violation | I_Q | 19614 | 11 | 30.0 |
| fedavg | statusLost__spShutdown | 3 | violation_sim | I_Q | 27779 | 18 | 90.3 |
| fedavg | storeError | 0 | pass_exhaustive |  | 27 | 9 | 3.1 |
| fedavg | storeError | 1 | budget_stopped |  | 49225 | 27 | 90.3 |
| fedavg | storeError | 2 | pass_exhaustive |  | 1 | 1 | 3.0 |
| fedavg | storeError | 3 | pass_exhaustive |  | 15 | 8 | 3.4 |
| fedavg | storeError | 5 | pass_exhaustive |  | 198 | 27 | 4.5 |
| fedavg | storeError__abort | 1 | budget_stopped |  | 42945 | 19 | 90.2 |
| fedavg | storeError__abort | 2 | budget_stopped |  | 39372 | 25 | 90.2 |
| fedavg | storeError__abort | 3 | budget_stopped |  | 26277 | 17 | 90.3 |
| fedavg | storeError__cjCrash | 1 | budget_stopped |  | 65249 | 17 | 90.3 |
| fedavg | storeError__cjCrash | 2 | budget_stopped |  | 40227 | 22 | 90.3 |
| fedavg | storeError__cjCrash | 3 | budget_stopped |  | 28723 | 19 | 90.2 |
| fedavg | storeError__cpCrash | 1 | violation | I_Q | 12751 | 12 | 20.4 |
| fedavg | storeError__cpCrash | 2 | violation | I_Q | 3 | 3 | 3.4 |
| fedavg | storeError__cpCrash | 3 | pass_exhaustive |  | 663 | 23 | 7.4 |
| fedavg | storeError__deadClient | 1 | violation_sim | S2F | 77270 | 17 | 90.3 |
| fedavg | storeError__deadClient | 2 | budget_stopped |  | 54292 | 24 | 90.3 |
| fedavg | storeError__deadClient | 3 | budget_stopped |  | 25228 | 27 | 90.3 |
| fedavg | storeError__deleteJob | 1 | budget_stopped |  | 48148 | 26 | 90.3 |
| fedavg | storeError__deleteJob | 2 | pass_exhaustive |  | 1 | 1 | 3.3 |
| fedavg | storeError__deleteJob | 3 | pass_exhaustive |  | 15 | 8 | 4.2 |
| fedavg | storeError__netLoss | 1 | budget_stopped |  | 54948 | 16 | 90.3 |
| fedavg | storeError__netLoss | 2 | budget_stopped |  | 27315 | 23 | 90.2 |
| fedavg | storeError__netLoss | 3 | budget_stopped |  | 16752 | 10 | 90.2 |
| fedavg | storeError__outcomeTimeout | 1 | budget_stopped |  | 50191 | 27 | 90.3 |
| fedavg | storeError__outcomeTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.1 |
| fedavg | storeError__outcomeTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.5 |
| fedavg | storeError__rpcTimeout | 1 | budget_stopped |  | 46986 | 22 | 90.2 |
| fedavg | storeError__rpcTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.9 |
| fedavg | storeError__rpcTimeout | 3 | pass_exhaustive |  | 15 | 8 | 3.4 |
| fedavg | storeError__sjCrash | 1 | violation | S2F | 10733 | 12 | 18.4 |
| fedavg | storeError__sjCrash | 2 | pass_exhaustive |  | 486 | 18 | 5.3 |
| fedavg | storeError__sjCrash | 3 | pass_exhaustive |  | 4865 | 14 | 18.5 |
| fedavg | storeError__spCrash | 1 | violation | I_Q | 89 | 7 | 3.7 |
| fedavg | storeError__spCrash | 2 | violation | I_Q | 41 | 12 | 4.3 |
| fedavg | storeError__spCrash | 3 | violation | I_Q | 191 | 17 | 6.6 |
| fedavg | storeError__spShutdown | 1 | violation | I_Q | 1189 | 9 | 6.1 |
| fedavg | storeError__spShutdown | 2 | violation | I_Q | 1607 | 15 | 8.1 |
| fedavg | storeError__spShutdown | 3 | violation | I_Q | 7405 | 15 | 23.0 |
| fedavg | submitTimeout | 0 | pass_exhaustive |  | 5 | 5 | 2.8 |
| fedavg | submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.7 |
| fedavg | submitTimeout | 2 | budget_stopped |  | 16062 | 44 | 90.3 |
| fedavg | submitTimeout | 3 | budget_stopped |  | 15377 | 17 | 90.3 |
| fedavg | submitTimeout | 5 | budget_stopped |  | 17682 | 15 | 90.3 |
| fedavg | taskDataFail | 0 | pass_exhaustive |  | 5 | 5 | 3.7 |
| fedavg | taskDataFail | 1 | pass_exhaustive |  | 8 | 8 | 3.6 |
| fedavg | taskDataFail | 2 | pass_exhaustive |  | 15245 | 21 | 29.5 |
| fedavg | taskDataFail | 3 | budget_stopped |  | 18929 | 20 | 90.2 |
| fedavg | taskDataFail | 5 | pass_exhaustive |  | 29614 | 10 | 66.1 |
| fedavg | taskDataFail__abort | 1 | budget_stopped |  | 23930 | 26 | 90.2 |
| fedavg | taskDataFail__abort | 2 | budget_stopped |  | 39163 | 18 | 90.3 |
| fedavg | taskDataFail__abort | 3 | budget_stopped |  | 20195 | 14 | 90.3 |
| fedavg | taskDataFail__cjCrash | 1 | violation | S2F | 38322 | 14 | 46.6 |
| fedavg | taskDataFail__cjCrash | 2 | budget_stopped |  | 32923 | 16 | 90.3 |
| fedavg | taskDataFail__cjCrash | 3 | budget_stopped |  | 24645 | 15 | 90.3 |
| fedavg | taskDataFail__deadClient | 1 | budget_stopped |  | 42950 | 21 | 90.3 |
| fedavg | taskDataFail__deadClient | 2 | budget_stopped |  | 27462 | 16 | 90.3 |
| fedavg | taskDataFail__deadClient | 3 | budget_stopped |  | 16671 | 13 | 90.3 |
| fedavg | taskDataFail__netLoss | 1 | violation | I_Q | 27294 | 13 | 53.6 |
| fedavg | taskDataFail__netLoss | 2 | violation | I_Q | 34 | 4 | 3.0 |
| fedavg | taskDataFail__netLoss | 3 | budget_stopped |  | 18618 | 9 | 90.2 |
| fedavg | taskDataFail__pullTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.7 |
| fedavg | taskDataFail__pullTimeout | 2 | budget_stopped |  | 27638 | 26 | 90.2 |
| fedavg | taskDataFail__pullTimeout | 3 | budget_stopped |  | 14681 | 16 | 90.2 |
| fedavg | taskDataFail__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.1 |
| fedavg | taskDataFail__resultWaitTimeout | 2 | pass_exhaustive |  | 15884 | 18 | 29.5 |
| fedavg | taskDataFail__resultWaitTimeout | 3 | budget_stopped |  | 13727 | 17 | 90.2 |
| fedavg | taskDataFail__sjCrash | 1 | violation | S2F | 1103 | 16 | 6.8 |
| fedavg | taskDataFail__sjCrash | 2 | budget_stopped |  | 47534 | 27 | 90.3 |
| fedavg | taskDataFail__sjCrash | 3 | budget_stopped |  | 29511 | 16 | 90.3 |
| fedavg | taskDataFail__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| fedavg | taskDataFail__submitTimeout | 2 | violation | I_Q | 14 | 5 | 3.4 |
| fedavg | taskDataFail__submitTimeout | 3 | budget_stopped |  | 14410 | 14 | 90.2 |
| fedavg | taskDataFail__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| fedavg | taskDataFail__taskTimeout | 2 | budget_stopped |  | 26615 | 19 | 90.3 |
| fedavg | taskDataFail__taskTimeout | 3 | budget_stopped |  | 13768 | 16 | 90.3 |
| fedavg | taskDataFail__txTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| fedavg | taskDataFail__txTimeout | 2 | budget_stopped |  | 32865 | 28 | 90.3 |
| fedavg | taskDataFail__txTimeout | 3 | budget_stopped |  | 14368 | 14 | 90.2 |
| fedavg | taskTimeout | 0 | pass_exhaustive |  | 5 | 5 | 4.4 |
| fedavg | taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 4.3 |
| fedavg | taskTimeout | 2 | pass_exhaustive |  | 491 | 28 | 5.7 |
| fedavg | taskTimeout | 3 | pass_exhaustive |  | 13992 | 14 | 35.3 |
| fedavg | taskTimeout | 5 | pass_exhaustive |  | 2348 | 11 | 11.6 |
| fedavg | tpSilent | 0 | pass_exhaustive |  | 5 | 5 | 3.6 |
| fedavg | tpSilent | 1 | pass_exhaustive |  | 8 | 8 | 3.7 |
| fedavg | tpSilent | 2 | pass_exhaustive |  | 2 | 2 | 3.7 |
| fedavg | tpSilent | 3 | pass_exhaustive |  | 15 | 8 | 4.0 |
| fedavg | tpSilent | 5 | pass_exhaustive |  | 311 | 26 | 5.3 |
| fedavg | tpSilent__abort | 1 | budget_stopped |  | 36191 | 26 | 90.3 |
| fedavg | tpSilent__abort | 2 | budget_stopped |  | 41614 | 22 | 90.3 |
| fedavg | tpSilent__abort | 3 | budget_stopped |  | 26784 | 16 | 90.3 |
| fedavg | tpSilent__cjCrash | 1 | violation | S2F | 30597 | 16 | 33.3 |
| fedavg | tpSilent__cjCrash | 2 | budget_stopped |  | 38869 | 23 | 90.3 |
| fedavg | tpSilent__cjCrash | 3 | budget_stopped |  | 26527 | 20 | 90.3 |
| fedavg | tpSilent__netLoss | 1 | budget_stopped |  | 29417 | 22 | 90.3 |
| fedavg | tpSilent__netLoss | 2 | budget_stopped |  | 20277 | 20 | 90.2 |
| fedavg | tpSilent__netLoss | 3 | budget_stopped |  | 16396 | 10 | 90.2 |
| fedavg | tpSilent__pullTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | tpSilent__pullTimeout | 2 | pass_exhaustive |  | 2 | 2 | 2.8 |
| fedavg | tpSilent__pullTimeout | 3 | pass_exhaustive |  | 22637 | 13 | 50.1 |
| fedavg | tpSilent__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | tpSilent__resultWaitTimeout | 2 | pass_exhaustive |  | 2 | 2 | 2.9 |
| fedavg | tpSilent__resultWaitTimeout | 3 | pass_exhaustive |  | 6441 | 13 | 15.2 |
| fedavg | tpSilent__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.1 |
| fedavg | tpSilent__submitTimeout | 2 | budget_stopped |  | 41595 | 38 | 90.3 |
| fedavg | tpSilent__submitTimeout | 3 | budget_stopped |  | 15310 | 16 | 90.3 |
| fedavg | tpSilent__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| fedavg | tpSilent__taskTimeout | 2 | pass_exhaustive |  | 820 | 28 | 4.7 |
| fedavg | tpSilent__taskTimeout | 3 | pass_exhaustive |  | 25229 | 13 | 54.1 |
| fedavg | tpSilent__txTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| fedavg | tpSilent__txTimeout | 2 | pass_exhaustive |  | 2 | 2 | 3.1 |
| fedavg | tpSilent__txTimeout | 3 | budget_stopped |  | 24866 | 24 | 90.3 |
| fedavg | trainerError | 0 | pass_exhaustive |  | 5 | 5 | 3.5 |
| fedavg | trainerError | 1 | pass_exhaustive |  | 8 | 8 | 3.6 |
| fedavg | trainerError | 2 | pass_exhaustive |  | 2 | 2 | 3.6 |
| fedavg | trainerError | 3 | pass_exhaustive |  | 15 | 8 | 3.9 |
| fedavg | trainerError | 5 | pass_exhaustive |  | 311 | 26 | 5.4 |
| fedavg | trainerError__abort | 1 | budget_stopped |  | 37918 | 26 | 90.3 |
| fedavg | trainerError__abort | 2 | budget_stopped |  | 42503 | 22 | 90.3 |
| fedavg | trainerError__abort | 3 | budget_stopped |  | 28395 | 16 | 90.2 |
| fedavg | trainerError__cjCrash | 1 | violation | S2F | 36215 | 15 | 40.0 |
| fedavg | trainerError__cjCrash | 2 | budget_stopped |  | 40499 | 23 | 90.3 |
| fedavg | trainerError__cjCrash | 3 | budget_stopped |  | 28115 | 20 | 90.2 |
| fedavg | trainerError__netLoss | 1 | budget_stopped |  | 30286 | 22 | 90.3 |
| fedavg | trainerError__netLoss | 2 | budget_stopped |  | 20485 | 20 | 90.3 |
| fedavg | trainerError__netLoss | 3 | budget_stopped |  | 17378 | 10 | 90.3 |
| fedavg | trainerError__pullTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| fedavg | trainerError__pullTimeout | 2 | pass_exhaustive |  | 2 | 2 | 3.1 |
| fedavg | trainerError__pullTimeout | 3 | pass_exhaustive |  | 22637 | 13 | 48.0 |
| fedavg | trainerError__resultWaitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedavg | trainerError__resultWaitTimeout | 2 | pass_exhaustive |  | 2 | 2 | 2.9 |
| fedavg | trainerError__resultWaitTimeout | 3 | pass_exhaustive |  | 6441 | 14 | 14.5 |
| fedavg | trainerError__submitTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.6 |
| fedavg | trainerError__submitTimeout | 2 | budget_stopped |  | 40545 | 36 | 90.3 |
| fedavg | trainerError__submitTimeout | 3 | budget_stopped |  | 14645 | 16 | 90.3 |
| fedavg | trainerError__taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.2 |
| fedavg | trainerError__taskTimeout | 2 | pass_exhaustive |  | 820 | 28 | 5.0 |
| fedavg | trainerError__taskTimeout | 3 | pass_exhaustive |  | 25229 | 13 | 49.3 |
| fedavg | trainerError__txTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| fedavg | trainerError__txTimeout | 2 | pass_exhaustive |  | 2 | 2 | 2.6 |
| fedavg | trainerError__txTimeout | 3 | budget_stopped |  | 25045 | 24 | 90.2 |
| fedavg | transportFail | 0 | pass_exhaustive |  | 5 | 5 | 3.6 |
| fedavg | transportFail | 1 | violation | S2F | 4267 | 26 | 16.4 |
| fedavg | transportFail | 2 | pass_exhaustive |  | 1 | 1 | 3.6 |
| fedavg | transportFail | 3 | pass_exhaustive |  | 35 | 8 | 4.8 |
| fedavg | transportFail | 5 | pass_exhaustive |  | 473 | 25 | 6.5 |
| fedavg | transportFail__abort | 1 | violation | S2F | 12393 | 17 | 35.5 |
| fedavg | transportFail__abort | 2 | budget_stopped |  | 38276 | 24 | 90.3 |
| fedavg | transportFail__abort | 3 | budget_stopped |  | 26420 | 17 | 90.3 |
| fedavg | transportFail__cjCrash | 1 | violation | S2F | 25376 | 13 | 33.9 |
| fedavg | transportFail__cjCrash | 2 | budget_stopped |  | 35167 | 18 | 90.3 |
| fedavg | transportFail__cjCrash | 3 | budget_stopped |  | 24662 | 15 | 90.3 |
| fedavg | transportFail__deadClient | 1 | budget_stopped |  | 39737 | 22 | 90.3 |
| fedavg | transportFail__deadClient | 2 | budget_stopped |  | 70708 | 23 | 90.3 |
| fedavg | transportFail__deadClient | 3 | budget_stopped |  | 27635 | 19 | 90.2 |
| fedavg | transportFail__deleteJob | 1 | violation | S2F | 4205 | 25 | 15.0 |
| fedavg | transportFail__deleteJob | 2 | pass_exhaustive |  | 1 | 1 | 2.9 |
| fedavg | transportFail__deleteJob | 3 | pass_exhaustive |  | 35 | 8 | 3.7 |
| fedavg | transportFail__netLoss | 1 | budget_stopped |  | 25348 | 25 | 90.3 |
| fedavg | transportFail__netLoss | 2 | budget_stopped |  | 23695 | 24 | 90.3 |
| fedavg | transportFail__netLoss | 3 | budget_stopped |  | 16601 | 11 | 90.3 |
| fedavg | transportFail__outcomeTimeout | 1 | violation | S2F | 4407 | 24 | 15.0 |
| fedavg | transportFail__outcomeTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.9 |
| fedavg | transportFail__outcomeTimeout | 3 | pass_exhaustive |  | 35 | 8 | 3.8 |
| fedavg | transportFail__pullTimeout | 1 | violation | S2F | 37160 | 35 | 84.8 |
| fedavg | transportFail__pullTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.8 |
| fedavg | transportFail__pullTimeout | 3 | pass_exhaustive |  | 16152 | 15 | 46.7 |
| fedavg | transportFail__resultWaitTimeout | 1 | budget_stopped |  | 21759 | 32 | 90.3 |
| fedavg | transportFail__resultWaitTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.9 |
| fedavg | transportFail__resultWaitTimeout | 3 | pass_exhaustive |  | 4401 | 15 | 15.7 |
| fedavg | transportFail__rpcTimeout | 1 | budget_stopped |  | 42402 | 20 | 90.3 |
| fedavg | transportFail__rpcTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.1 |
| fedavg | transportFail__rpcTimeout | 3 | pass_exhaustive |  | 35 | 8 | 3.6 |
| fedavg | transportFail__sjCrash | 1 | violation | S2F | 996 | 16 | 6.3 |
| fedavg | transportFail__sjCrash | 2 | pass_exhaustive |  | 230 | 18 | 4.7 |
| fedavg | transportFail__sjCrash | 3 | pass_exhaustive |  | 8050 | 11 | 18.2 |
| fedavg | transportFail__spCrash | 1 | violation | I_Q | 77 | 7 | 3.5 |
| fedavg | transportFail__spCrash | 2 | violation | I_Q | 41 | 12 | 4.4 |
| fedavg | transportFail__spCrash | 3 | violation | I_Q | 485 | 11 | 6.9 |
| fedavg | transportFail__spShutdown | 1 | violation_sim | I_Q | 46599 | 18 | 90.2 |
| fedavg | transportFail__spShutdown | 2 | violation | I_Q | 5176 | 13 | 12.5 |
| fedavg | transportFail__spShutdown | 3 | violation | I_Q | 30594 | 16 | 74.7 |
| fedavg | transportFail__submitTimeout | 1 | budget_stopped |  | 22476 | 34 | 90.3 |
| fedavg | transportFail__submitTimeout | 2 | budget_stopped |  | 36738 | 31 | 90.2 |
| fedavg | transportFail__submitTimeout | 3 | budget_stopped |  | 16371 | 17 | 90.3 |
| fedavg | transportFail__taskTimeout | 1 | violation | S2F | 10069 | 20 | 23.8 |
| fedavg | transportFail__taskTimeout | 2 | pass_exhaustive |  | 5693 | 20 | 11.5 |
| fedavg | transportFail__taskTimeout | 3 | pass_exhaustive |  | 16152 | 14 | 50.4 |
| fedavg | transportFail__txTimeout | 1 | budget_stopped |  | 26087 | 33 | 90.3 |
| fedavg | transportFail__txTimeout | 2 | pass_exhaustive |  | 1 | 1 | 2.7 |
| fedavg | transportFail__txTimeout | 3 | budget_stopped |  | 21469 | 24 | 90.3 |
| fedavg | txTimeout | 0 | pass_exhaustive |  | 5 | 5 | 4.0 |
| fedavg | txTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.7 |
| fedavg | txTimeout | 2 | pass_exhaustive |  | 1 | 1 | 3.9 |
| fedavg | txTimeout | 3 | pass_exhaustive |  | 34836 | 32 | 74.2 |
| fedavg | txTimeout | 5 | pass_exhaustive |  | 2108 | 11 | 9.7 |
| fedavg2 | abort | 0 | budget_stopped |  | 12665 | 30 | 90.2 |
| fedavg2 | abort | 1 | budget_stopped |  | 14129 | 20 | 90.3 |
| fedavg2 | abort | 2 | budget_stopped |  | 17247 | 14 | 90.3 |
| fedavg2 | abort | 3 | budget_stopped |  | 14353 | 13 | 90.3 |
| fedavg2 | abort | 5 | budget_stopped |  | 12145 | 12 | 90.2 |
| fedavg2 | cancel | 0 | pass_exhaustive |  | 9 | 7 | 3.1 |
| fedavg2 | cancel | 1 | pass_exhaustive |  | 28 | 12 | 3.3 |
| fedavg2 | cancel | 2 | budget_stopped |  | 25916 | 28 | 90.3 |
| fedavg2 | cancel | 3 | budget_stopped |  | 21039 | 31 | 90.3 |
| fedavg2 | cancel | 5 | pass_exhaustive |  | 6619 | 17 | 27.6 |
| fedavg2 | cancel__abort | 1 | budget_stopped |  | 16205 | 19 | 90.3 |
| fedavg2 | cancel__abort | 2 | budget_stopped |  | 16775 | 13 | 90.2 |
| fedavg2 | cancel__abort | 3 | budget_stopped |  | 13749 | 12 | 90.2 |
| fedavg2 | cancel__deadClient | 1 | violation | S1Cleanup | 232 | 7 | 3.6 |
| fedavg2 | cancel__deadClient | 2 | violation | S1Cleanup | 962 | 9 | 7.2 |
| fedavg2 | cancel__deadClient | 3 | violation | S1Cleanup | 474 | 6 | 6.1 |
| fedavg2 | cancel__netLoss | 1 | budget_stopped |  | 22257 | 15 | 90.2 |
| fedavg2 | cancel__netLoss | 2 | budget_stopped |  | 13828 | 10 | 90.2 |
| fedavg2 | cancel__netLoss | 3 | budget_stopped |  | 11477 | 8 | 90.3 |
| fedavg2 | cancel__sjCrash | 1 | violation | S2F | 12780 | 16 | 33.3 |
| fedavg2 | cancel__sjCrash | 2 | budget_stopped |  | 41768 | 16 | 90.3 |
| fedavg2 | cancel__sjCrash | 3 | budget_stopped |  | 30264 | 15 | 90.3 |
| fedavg2 | cancel__submitTimeout | 1 | pass_exhaustive |  | 28 | 12 | 2.8 |
| fedavg2 | cancel__submitTimeout | 2 | budget_stopped |  | 10472 | 13 | 90.2 |
| fedavg2 | cancel__submitTimeout | 3 | budget_stopped |  | 7314 | 11 | 90.3 |
| fedavg2 | cancel__taskTimeout | 1 | pass_exhaustive |  | 28 | 12 | 3.0 |
| fedavg2 | cancel__taskTimeout | 2 | budget_stopped |  | 15569 | 17 | 90.3 |
| fedavg2 | cancel__taskTimeout | 3 | budget_stopped |  | 9189 | 15 | 90.3 |
| fedavg2 | cjCrash | 0 | pass_exhaustive |  | 9 | 7 | 3.2 |
| fedavg2 | cjCrash | 1 | violation_sim | S2F | 35397 | 19 | 90.3 |
| fedavg2 | cjCrash | 2 | budget_stopped |  | 24535 | 16 | 90.3 |
| fedavg2 | cjCrash | 3 | budget_stopped |  | 19098 | 16 | 90.3 |
| fedavg2 | cjCrash | 5 | budget_stopped |  | 15042 | 13 | 90.3 |
| fedavg2 | cpCrash | 0 | pass_exhaustive |  | 131 | 12 | 3.6 |
| fedavg2 | cpCrash | 1 | budget_stopped |  | 39095 | 14 | 90.3 |
| fedavg2 | cpCrash | 2 | violation | I_Q | 41 | 5 | 4.4 |
| fedavg2 | cpCrash | 3 | violation | I_Q | 73 | 10 | 4.9 |
| fedavg2 | cpCrash | 5 | budget_stopped |  | 10129 | 18 | 90.3 |
| fedavg2 | deadClient | 0 | violation | S1Cleanup | 171 | 7 | 3.4 |
| fedavg2 | deadClient | 1 | violation | S1Cleanup | 196 | 6 | 3.7 |
| fedavg2 | deadClient | 2 | violation | S1Cleanup | 1035 | 9 | 7.6 |
| fedavg2 | deadClient | 3 | violation | S1Cleanup | 518 | 7 | 7.1 |
| fedavg2 | deadClient | 5 | violation | S1Cleanup | 165 | 6 | 5.9 |
| fedavg2 | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.2 |
| fedavg2 | deleteJob | 1 | budget_stopped |  | 33436 | 35 | 90.2 |
| fedavg2 | deleteJob | 2 | pass_exhaustive |  | 243 | 38 | 5.5 |
| fedavg2 | deleteJob | 3 | pass_exhaustive |  | 35 | 12 | 3.9 |
| fedavg2 | deleteJob | 5 | pass_exhaustive |  | 5774 | 25 | 37.8 |
| fedavg2 | minClients | 0 | pass_exhaustive |  | 9 | 7 | 3.1 |
| fedavg2 | minClients | 1 | pass_exhaustive |  | 28 | 12 | 3.2 |
| fedavg2 | minClients | 2 | budget_stopped |  | 28706 | 29 | 90.3 |
| fedavg2 | minClients | 3 | budget_stopped |  | 18335 | 37 | 90.3 |
| fedavg2 | minClients | 5 | pass_exhaustive |  | 1903 | 22 | 13.6 |
| fedavg2 | minClients__abort | 1 | budget_stopped |  | 15536 | 19 | 90.2 |
| fedavg2 | minClients__abort | 2 | budget_stopped |  | 17898 | 13 | 90.3 |
| fedavg2 | minClients__abort | 3 | budget_stopped |  | 14383 | 12 | 90.3 |
| fedavg2 | minClients__deadClient | 1 | violation | S1Cleanup | 182 | 6 | 3.6 |
| fedavg2 | minClients__deadClient | 2 | violation | S1Cleanup | 910 | 9 | 7.2 |
| fedavg2 | minClients__deadClient | 3 | violation | S1Cleanup | 472 | 7 | 6.7 |
| fedavg2 | minClients__netLoss | 1 | violation_sim | S2F | 23685 | 15 | 90.3 |
| fedavg2 | minClients__netLoss | 2 | budget_stopped |  | 14285 | 10 | 90.3 |
| fedavg2 | minClients__netLoss | 3 | budget_stopped |  | 11698 | 8 | 90.2 |
| fedavg2 | minClients__sjCrash | 1 | violation | S2F | 12748 | 16 | 33.3 |
| fedavg2 | minClients__sjCrash | 2 | budget_stopped |  | 43079 | 16 | 90.2 |
| fedavg2 | minClients__sjCrash | 3 | budget_stopped |  | 29989 | 16 | 90.2 |
| fedavg2 | minClients__submitTimeout | 1 | pass_exhaustive |  | 28 | 12 | 3.1 |
| fedavg2 | minClients__submitTimeout | 2 | budget_stopped |  | 11188 | 14 | 90.2 |
| fedavg2 | minClients__submitTimeout | 3 | budget_stopped |  | 8407 | 12 | 90.2 |
| fedavg2 | minClients__taskTimeout | 1 | pass_exhaustive |  | 28 | 12 | 3.1 |
| fedavg2 | minClients__taskTimeout | 2 | budget_stopped |  | 15018 | 17 | 90.3 |
| fedavg2 | minClients__taskTimeout | 3 | budget_stopped |  | 9638 | 15 | 90.3 |
| fedavg2 | netLoss | 0 | budget_stopped |  | 18866 | 24 | 90.3 |
| fedavg2 | netLoss | 1 | budget_stopped |  | 22217 | 15 | 90.3 |
| fedavg2 | netLoss | 2 | budget_stopped |  | 13098 | 11 | 90.3 |
| fedavg2 | netLoss | 3 | budget_stopped |  | 11367 | 8 | 90.4 |
| fedavg2 | netLoss | 5 | budget_stopped |  | 10475 | 6 | 90.3 |
| fedavg2 | regIterRace | 0 | violation | S1Cleanup | 16 | 4 | 2.8 |
| fedavg2 | regIterRace | 1 | violation | S1Cleanup | 15 | 3 | 3.0 |
| fedavg2 | regIterRace | 2 | violation | S1Cleanup | 38 | 6 | 3.5 |
| fedavg2 | regIterRace | 3 | violation | S1Cleanup | 24 | 4 | 3.8 |
| fedavg2 | regIterRace | 5 | violation | S1Cleanup | 14 | 3 | 3.5 |
| fedavg2 | regIterRace__abort | 1 | violation | S1Cleanup | 28 | 4 | 3.2 |
| fedavg2 | regIterRace__abort | 2 | violation | S1Cleanup | 50 | 4 | 4.0 |
| fedavg2 | regIterRace__abort | 3 | violation | S1Cleanup | 57 | 4 | 4.7 |
| fedavg2 | regIterRace__deadClient | 1 | violation | S1Cleanup | 17 | 4 | 3.9 |
| fedavg2 | regIterRace__deadClient | 2 | violation | S1Cleanup | 39 | 6 | 4.2 |
| fedavg2 | regIterRace__deadClient | 3 | violation | S1Cleanup | 25 | 4 | 4.2 |
| fedavg2 | regIterRace__deleteJob | 1 | violation | S1Cleanup | 20 | 4 | 3.4 |
| fedavg2 | regIterRace__deleteJob | 2 | violation | S1Cleanup | 38 | 6 | 4.1 |
| fedavg2 | regIterRace__deleteJob | 3 | violation | S1Cleanup | 24 | 4 | 4.7 |
| fedavg2 | regIterRace__netLoss | 1 | violation | S1Cleanup | 46 | 4 | 3.6 |
| fedavg2 | regIterRace__netLoss | 2 | violation | S1Cleanup | 209 | 4 | 4.6 |
| fedavg2 | regIterRace__netLoss | 3 | violation | S1Cleanup | 498 | 4 | 5.4 |
| fedavg2 | regIterRace__rpcTimeout | 1 | violation | S1Cleanup | 25 | 4 | 3.3 |
| fedavg2 | regIterRace__rpcTimeout | 2 | violation | S1Cleanup | 30 | 4 | 3.6 |
| fedavg2 | regIterRace__rpcTimeout | 3 | violation | S1Cleanup | 24 | 4 | 4.0 |
| fedavg2 | regIterRace__sjCrash | 1 | violation | S1Cleanup | 17 | 4 | 2.9 |
| fedavg2 | regIterRace__sjCrash | 2 | violation | S1Cleanup | 38 | 4 | 3.3 |
| fedavg2 | regIterRace__sjCrash | 3 | violation | S1Cleanup | 31 | 4 | 4.0 |
| fedavg2 | regIterRace__spCrash | 1 | violation | S1Cleanup | 35 | 4 | 3.0 |
| fedavg2 | regIterRace__spCrash | 2 | violation | S1Cleanup | 48 | 4 | 3.5 |
| fedavg2 | regIterRace__spCrash | 3 | violation | S1Cleanup | 39 | 4 | 4.1 |
| fedavg2 | regIterRace__spShutdown | 1 | violation | S1Cleanup | 33 | 4 | 3.8 |
| fedavg2 | regIterRace__spShutdown | 2 | violation | S1Cleanup | 52 | 6 | 4.3 |
| fedavg2 | regIterRace__spShutdown | 3 | violation | S1Cleanup | 36 | 4 | 4.4 |
| fedavg2 | regIterRace__submitTimeout | 1 | violation | S1Cleanup | 17 | 4 | 3.5 |
| fedavg2 | regIterRace__submitTimeout | 2 | violation | S1Cleanup | 51 | 4 | 4.1 |
| fedavg2 | regIterRace__submitTimeout | 3 | violation | S1Cleanup | 77 | 4 | 4.7 |
| fedavg2 | regIterRace__taskTimeout | 1 | violation | S1Cleanup | 17 | 4 | 3.6 |
| fedavg2 | regIterRace__taskTimeout | 2 | violation | S1Cleanup | 33 | 4 | 4.0 |
| fedavg2 | regIterRace__taskTimeout | 3 | violation | S1Cleanup | 45 | 4 | 4.3 |
| fedavg2 | rpcTimeout | 0 | pass_exhaustive |  | 131 | 12 | 3.7 |
| fedavg2 | rpcTimeout | 1 | budget_stopped |  | 31873 | 14 | 90.3 |
| fedavg2 | rpcTimeout | 2 | pass_exhaustive |  | 243 | 38 | 5.8 |
| fedavg2 | rpcTimeout | 3 | pass_exhaustive |  | 35 | 12 | 4.1 |
| fedavg2 | rpcTimeout | 5 | budget_stopped |  | 11565 | 29 | 90.3 |
| fedavg2 | sjCrash | 0 | pass_exhaustive |  | 9 | 7 | 3.1 |
| fedavg2 | sjCrash | 1 | violation | S2F | 11543 | 16 | 29.5 |
| fedavg2 | sjCrash | 2 | budget_stopped |  | 41793 | 20 | 90.3 |
| fedavg2 | sjCrash | 3 | budget_stopped |  | 30218 | 21 | 90.3 |
| fedavg2 | sjCrash | 5 | budget_stopped |  | 24036 | 15 | 90.2 |
| fedavg2 | slowFinalize | 0 | violation | S1Cleanup | 179 | 7 | 3.3 |
| fedavg2 | slowFinalize | 1 | violation | S1Cleanup | 242 | 6 | 4.3 |
| fedavg2 | slowFinalize | 2 | violation | S1Cleanup | 1039 | 9 | 7.8 |
| fedavg2 | slowFinalize | 3 | violation | S1Cleanup | 513 | 7 | 7.1 |
| fedavg2 | slowFinalize | 5 | violation | S1Cleanup | 188 | 6 | 5.7 |
| fedavg2 | slowFinalize__abort | 1 | violation | S1Cleanup | 627 | 7 | 5.2 |
| fedavg2 | slowFinalize__abort | 2 | violation | S1Cleanup | 1941 | 6 | 10.0 |
| fedavg2 | slowFinalize__abort | 3 | violation | S1Cleanup | 2051 | 6 | 12.4 |
| fedavg2 | slowFinalize__deadClient | 1 | violation | S1Cleanup | 199 | 6 | 3.9 |
| fedavg2 | slowFinalize__deadClient | 2 | violation | S1Cleanup | 1020 | 9 | 8.3 |
| fedavg2 | slowFinalize__deadClient | 3 | violation | S1Cleanup | 513 | 7 | 7.6 |
| fedavg2 | slowFinalize__netLoss | 1 | violation | S1Cleanup | 1420 | 7 | 5.7 |
| fedavg2 | slowFinalize__netLoss | 2 | violation | S1Cleanup | 14985 | 5 | 47.6 |
| fedavg2 | slowFinalize__netLoss | 3 | budget_stopped |  | 18397 | 7 | 90.2 |
| fedavg2 | slowFinalize__sjCrash | 1 | violation | S1Cleanup | 237 | 6 | 4.1 |
| fedavg2 | slowFinalize__sjCrash | 2 | violation | S1Cleanup | 1378 | 7 | 7.6 |
| fedavg2 | slowFinalize__sjCrash | 3 | violation | S1Cleanup | 1053 | 7 | 8.1 |
| fedavg2 | slowFinalize__submitTimeout | 1 | violation | S1Cleanup | 256 | 7 | 4.7 |
| fedavg2 | slowFinalize__submitTimeout | 2 | violation | S1Cleanup | 1818 | 6 | 11.6 |
| fedavg2 | slowFinalize__submitTimeout | 3 | violation | S1Cleanup | 2475 | 6 | 15.9 |
| fedavg2 | slowFinalize__taskTimeout | 1 | violation | S1Cleanup | 256 | 7 | 4.4 |
| fedavg2 | slowFinalize__taskTimeout | 2 | violation | S1Cleanup | 814 | 7 | 7.5 |
| fedavg2 | slowFinalize__taskTimeout | 3 | violation | S1Cleanup | 1346 | 6 | 10.6 |
| fedavg2 | spCrash | 0 | pass_exhaustive |  | 131 | 12 | 3.4 |
| fedavg2 | spCrash | 1 | violation | I_Q | 243 | 8 | 4.1 |
| fedavg2 | spCrash | 2 | violation | I_Q | 5562 | 9 | 32.0 |
| fedavg2 | spCrash | 3 | violation | I_Q | 3409 | 13 | 29.0 |
| fedavg2 | spCrash | 5 | violation_sim | I_Q | 8274 | 19 | 90.3 |
| fedavg2 | spShutdown | 0 | violation | I_Q | 50 | 7 | 3.1 |
| fedavg2 | spShutdown | 1 | violation_sim | I_Q | 58399 | 16 | 90.2 |
| fedavg2 | spShutdown | 2 | violation_sim | I_Q | 17633 | 21 | 90.3 |
| fedavg2 | spShutdown | 3 | violation_sim | I_Q | 14431 | 19 | 90.3 |
| fedavg2 | spShutdown | 5 | violation_sim | I_Q | 13597 | 20 | 90.3 |
| fedavg2 | submitTimeout | 0 | pass_exhaustive |  | 9 | 7 | 2.7 |
| fedavg2 | submitTimeout | 1 | pass_exhaustive |  | 28 | 12 | 3.0 |
| fedavg2 | submitTimeout | 2 | budget_stopped |  | 7796 | 19 | 90.3 |
| fedavg2 | submitTimeout | 3 | budget_stopped |  | 7314 | 13 | 90.2 |
| fedavg2 | submitTimeout | 5 | budget_stopped |  | 8668 | 9 | 90.3 |
| fedavg2 | taskTimeout | 0 | pass_exhaustive |  | 9 | 7 | 3.2 |
| fedavg2 | taskTimeout | 1 | pass_exhaustive |  | 28 | 12 | 3.2 |
| fedavg2 | taskTimeout | 2 | budget_stopped |  | 14815 | 17 | 90.3 |
| fedavg2 | taskTimeout | 3 | budget_stopped |  | 9372 | 15 | 90.3 |
| fedavg2 | taskTimeout | 5 | budget_stopped |  | 7845 | 11 | 90.3 |
| fedavg2 | transportFail | 0 | pass_exhaustive |  | 9 | 7 | 3.3 |
| fedavg2 | transportFail | 1 | budget_stopped |  | 12583 | 29 | 90.2 |
| fedavg2 | transportFail | 2 | budget_stopped |  | 27717 | 31 | 90.2 |
| fedavg2 | transportFail | 3 | pass_exhaustive |  | 93 | 12 | 4.9 |
| fedavg2 | transportFail | 5 | budget_stopped |  | 13503 | 22 | 90.3 |
| fedavg2 | transportFail__abort | 1 | budget_stopped |  | 13912 | 20 | 90.3 |
| fedavg2 | transportFail__abort | 2 | budget_stopped |  | 16701 | 14 | 90.3 |
| fedavg2 | transportFail__abort | 3 | budget_stopped |  | 13255 | 13 | 90.2 |
| fedavg2 | transportFail__cjCrash | 1 | budget_stopped |  | 35890 | 16 | 90.2 |
| fedavg2 | transportFail__cjCrash | 2 | budget_stopped |  | 22683 | 12 | 90.3 |
| fedavg2 | transportFail__cjCrash | 3 | budget_stopped |  | 17255 | 11 | 90.2 |
| fedavg2 | transportFail__deadClient | 1 | violation | S1Cleanup | 239 | 7 | 3.7 |
| fedavg2 | transportFail__deadClient | 2 | violation | S1Cleanup | 637 | 7 | 6.4 |
| fedavg2 | transportFail__deadClient | 3 | violation | S1Cleanup | 469 | 6 | 6.9 |
| fedavg2 | transportFail__deleteJob | 1 | budget_stopped |  | 12604 | 23 | 90.3 |
| fedavg2 | transportFail__deleteJob | 2 | budget_stopped |  | 16573 | 29 | 90.3 |
| fedavg2 | transportFail__deleteJob | 3 | pass_exhaustive |  | 93 | 12 | 5.0 |
| fedavg2 | transportFail__netLoss | 1 | budget_stopped |  | 21320 | 15 | 90.3 |
| fedavg2 | transportFail__netLoss | 2 | budget_stopped |  | 10592 | 11 | 90.3 |
| fedavg2 | transportFail__netLoss | 3 | budget_stopped |  | 9522 | 9 | 90.3 |
| fedavg2 | transportFail__rpcTimeout | 1 | budget_stopped |  | 28489 | 14 | 90.3 |
| fedavg2 | transportFail__rpcTimeout | 2 | budget_stopped |  | 17304 | 29 | 90.3 |
| fedavg2 | transportFail__rpcTimeout | 3 | pass_exhaustive |  | 93 | 12 | 4.4 |
| fedavg2 | transportFail__sjCrash | 1 | violation | S2F | 11099 | 17 | 28.5 |
| fedavg2 | transportFail__sjCrash | 2 | budget_stopped |  | 36201 | 20 | 90.3 |
| fedavg2 | transportFail__sjCrash | 3 | budget_stopped |  | 31152 | 19 | 90.3 |
| fedavg2 | transportFail__spCrash | 1 | violation | I_Q | 249 | 8 | 4.1 |
| fedavg2 | transportFail__spCrash | 2 | violation_sim | I_Q | 14339 | 19 | 90.3 |
| fedavg2 | transportFail__spCrash | 3 | violation_sim | I_Q | 11292 | 17 | 90.3 |
| fedavg2 | transportFail__spShutdown | 1 | violation_sim | I_Q | 31952 | 14 | 90.3 |
| fedavg2 | transportFail__spShutdown | 2 | violation_sim | I_Q | 18835 | 13 | 90.3 |
| fedavg2 | transportFail__spShutdown | 3 | violation_sim | I_Q | 14289 | 12 | 90.2 |
| fedavg2 | transportFail__submitTimeout | 1 | budget_stopped |  | 11779 | 26 | 90.2 |
| fedavg2 | transportFail__submitTimeout | 2 | budget_stopped |  | 7937 | 19 | 90.3 |
| fedavg2 | transportFail__submitTimeout | 3 | budget_stopped |  | 8199 | 13 | 90.2 |
| fedavg2 | transportFail__taskTimeout | 1 | budget_stopped |  | 14155 | 26 | 90.2 |
| fedavg2 | transportFail__taskTimeout | 2 | budget_stopped |  | 15428 | 17 | 90.2 |
| fedavg2 | transportFail__taskTimeout | 3 | budget_stopped |  | 9081 | 15 | 90.3 |
| fedmodel | abort | 0 | budget_stopped |  | 21829 | 57 | 90.3 |
| fedmodel | abort | 1 | budget_stopped |  | 21938 | 49 | 90.3 |
| fedmodel | abort | 2 | budget_stopped |  | 54870 | 19 | 90.3 |
| fedmodel | abort | 3 | budget_stopped |  | 30177 | 17 | 90.3 |
| fedmodel | abort | 5 | budget_stopped |  | 26749 | 19 | 90.2 |
| fedmodel | acceptRaise | 0 | pass_exhaustive |  | 5 | 5 | 2.8 |
| fedmodel | acceptRaise | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedmodel | acceptRaise | 2 | pass_exhaustive |  | 921 | 62 | 6.1 |
| fedmodel | acceptRaise | 3 | pass_exhaustive |  | 51 | 19 | 3.9 |
| fedmodel | acceptRaise | 5 | pass_exhaustive |  | 40 | 25 | 3.5 |
| fedmodel | acceptRaise__netLoss | 1 | budget_stopped |  | 31642 | 24 | 90.2 |
| fedmodel | acceptRaise__netLoss | 2 | budget_stopped |  | 25706 | 20 | 90.2 |
| fedmodel | acceptRaise__netLoss | 3 | budget_stopped |  | 26350 | 11 | 90.2 |
| fedmodel | acceptRaise__sjCrash | 1 | violation | S2F | 1055 | 16 | 5.5 |
| fedmodel | acceptRaise__sjCrash | 2 | budget_stopped |  | 60479 | 43 | 90.2 |
| fedmodel | acceptRaise__sjCrash | 3 | pass_exhaustive |  | 31671 | 15 | 43.0 |
| fedmodel | cjCrash | 0 | pass_exhaustive |  | 5 | 5 | 3.1 |
| fedmodel | cjCrash | 1 | violation | S2F | 14594 | 17 | 16.0 |
| fedmodel | cjCrash | 2 | budget_stopped |  | 50953 | 26 | 90.2 |
| fedmodel | cjCrash | 3 | budget_stopped |  | 33070 | 23 | 90.3 |
| fedmodel | cjCrash | 5 | budget_stopped |  | 33456 | 23 | 90.3 |
| fedmodel | cpCrash | 0 | pass_exhaustive |  | 35 | 9 | 3.5 |
| fedmodel | cpCrash | 1 | violation | I_Q | 12763 | 12 | 17.4 |
| fedmodel | cpCrash | 2 | violation | I_Q | 16 | 7 | 3.4 |
| fedmodel | cpCrash | 3 | pass_exhaustive |  | 1113 | 25 | 8.5 |
| fedmodel | cpCrash | 5 | pass_exhaustive |  | 3215 | 17 | 12.1 |
| fedmodel | deadClient | 0 | budget_stopped |  | 54747 | 28 | 90.3 |
| fedmodel | deadClient | 1 | violation_sim | S2F | 59743 | 23 | 90.3 |
| fedmodel | deadClient | 2 | budget_stopped |  | 47058 | 18 | 90.3 |
| fedmodel | deadClient | 3 | budget_stopped |  | 29283 | 22 | 90.2 |
| fedmodel | deadClient | 5 | pass_exhaustive |  | 9456 | 16 | 20.0 |
| fedmodel | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.1 |
| fedmodel | deleteJob | 1 | pass_exhaustive |  | 1829 | 42 | 8.6 |
| fedmodel | deleteJob | 2 | pass_exhaustive |  | 145 | 41 | 3.9 |
| fedmodel | deleteJob | 3 | pass_exhaustive |  | 51 | 19 | 3.6 |
| fedmodel | deleteJob | 5 | pass_exhaustive |  | 198 | 27 | 4.6 |
| fedmodel | netLoss | 0 | budget_stopped |  | 25986 | 34 | 90.3 |
| fedmodel | netLoss | 1 | budget_stopped |  | 28703 | 23 | 90.2 |
| fedmodel | netLoss | 2 | budget_stopped |  | 23112 | 20 | 90.2 |
| fedmodel | netLoss | 3 | budget_stopped |  | 21421 | 11 | 90.3 |
| fedmodel | netLoss | 5 | budget_stopped |  | 21856 | 10 | 90.2 |
| fedmodel | rpcTimeout | 0 | pass_exhaustive |  | 35 | 9 | 3.0 |
| fedmodel | rpcTimeout | 1 | budget_stopped |  | 58065 | 23 | 90.2 |
| fedmodel | rpcTimeout | 2 | pass_exhaustive |  | 145 | 41 | 3.8 |
| fedmodel | rpcTimeout | 3 | pass_exhaustive |  | 51 | 19 | 3.4 |
| fedmodel | rpcTimeout | 5 | pass_exhaustive |  | 423 | 28 | 4.8 |
| fedmodel | saveFail | 0 | pass_exhaustive |  | 5 | 5 | 3.1 |
| fedmodel | saveFail | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| fedmodel | saveFail | 2 | pass_exhaustive |  | 145 | 41 | 4.4 |
| fedmodel | saveFail | 3 | pass_exhaustive |  | 474 | 45 | 5.0 |
| fedmodel | saveFail | 5 | pass_exhaustive |  | 40 | 25 | 3.4 |
| fedmodel | saveFail__netLoss | 1 | budget_stopped |  | 34630 | 24 | 90.2 |
| fedmodel | saveFail__netLoss | 2 | budget_stopped |  | 30214 | 21 | 90.2 |
| fedmodel | saveFail__netLoss | 3 | budget_stopped |  | 27473 | 11 | 90.2 |
| fedmodel | saveFail__sjCrash | 1 | violation | S2F | 1036 | 16 | 5.6 |
| fedmodel | saveFail__sjCrash | 2 | budget_stopped |  | 75044 | 51 | 90.2 |
| fedmodel | saveFail__sjCrash | 3 | budget_stopped |  | 75341 | 25 | 90.2 |
| fedmodel | sjCrash | 0 | pass_exhaustive |  | 5 | 5 | 3.4 |
| fedmodel | sjCrash | 1 | violation | S2F | 1072 | 16 | 6.1 |
| fedmodel | sjCrash | 2 | budget_stopped |  | 54524 | 48 | 90.3 |
| fedmodel | sjCrash | 3 | pass_exhaustive |  | 31671 | 13 | 45.7 |
| fedmodel | sjCrash | 5 | pass_exhaustive |  | 17895 | 12 | 29.7 |
| fedmodel | spCrash | 0 | pass_exhaustive |  | 35 | 9 | 3.0 |
| fedmodel | spCrash | 1 | violation | I_Q | 87 | 7 | 3.1 |
| fedmodel | spCrash | 2 | violation | I_Q | 145 | 13 | 4.5 |
| fedmodel | spCrash | 3 | violation | I_Q | 220 | 19 | 5.8 |
| fedmodel | spCrash | 5 | violation | I_Q | 308 | 14 | 6.2 |
| fedmodel | spShutdown | 0 | violation | I_Q | 40 | 7 | 3.0 |
| fedmodel | spShutdown | 1 | violation_sim | I_Q | 72476 | 23 | 90.3 |
| fedmodel | spShutdown | 2 | violation | I_Q | 2576 | 19 | 8.7 |
| fedmodel | spShutdown | 3 | violation | I_Q | 5634 | 17 | 16.1 |
| fedmodel | spShutdown | 5 | violation | I_Q | 3578 | 15 | 11.8 |
| fedmodel | taskTimeout | 0 | pass_exhaustive |  | 5 | 5 | 2.8 |
| fedmodel | taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| fedmodel | taskTimeout | 2 | budget_stopped |  | 36531 | 21 | 90.2 |
| fedmodel | taskTimeout | 3 | budget_stopped |  | 20224 | 24 | 90.2 |
| fedmodel | taskTimeout | 5 | pass_exhaustive |  | 2348 | 10 | 9.3 |
| k8s | abort | 0 | budget_stopped |  | 19126 | 52 | 90.3 |
| k8s | abort | 1 | budget_stopped |  | 24811 | 45 | 90.3 |
| k8s | abort | 2 | budget_stopped |  | 44894 | 18 | 90.3 |
| k8s | abort | 3 | budget_stopped |  | 24485 | 20 | 90.3 |
| k8s | abort | 5 | budget_stopped |  | 22785 | 18 | 90.3 |
| k8s | cjCrash | 0 | pass_exhaustive |  | 5 | 5 | 3.1 |
| k8s | cjCrash | 1 | violation | S2F | 60247 | 14 | 60.3 |
| k8s | cjCrash | 2 | budget_stopped |  | 44776 | 20 | 90.3 |
| k8s | cjCrash | 3 | budget_stopped |  | 25832 | 22 | 90.3 |
| k8s | cjCrash | 5 | budget_stopped |  | 29808 | 18 | 90.2 |
| k8s | cpCrash | 0 | pass_exhaustive |  | 35 | 9 | 3.2 |
| k8s | cpCrash | 1 | violation | S3Alloc | 104 | 8 | 3.5 |
| k8s | cpCrash | 2 | violation | S3Alloc | 10 | 6 | 3.3 |
| k8s | cpCrash | 3 | violation | S3Alloc | 4 | 4 | 3.5 |
| k8s | cpCrash | 5 | violation | S3Alloc | 3 | 3 | 3.3 |
| k8s | deadClient | 0 | violation_sim | S2F | 59418 | 30 | 90.3 |
| k8s | deadClient | 1 | budget_stopped |  | 60429 | 24 | 90.3 |
| k8s | deadClient | 2 | budget_stopped |  | 38949 | 21 | 90.2 |
| k8s | deadClient | 3 | budget_stopped |  | 32863 | 31 | 90.3 |
| k8s | deadClient | 5 | pass_exhaustive |  | 9456 | 14 | 24.6 |
| k8s | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.3 |
| k8s | deleteJob | 1 | pass_exhaustive |  | 4469 | 26 | 16.8 |
| k8s | deleteJob | 2 | pass_exhaustive |  | 45 | 33 | 3.7 |
| k8s | deleteJob | 3 | pass_exhaustive |  | 5 | 5 | 3.0 |
| k8s | deleteJob | 5 | pass_exhaustive |  | 198 | 27 | 4.4 |
| k8s | netLoss | 0 | budget_stopped |  | 23743 | 30 | 90.3 |
| k8s | netLoss | 1 | budget_stopped |  | 30715 | 21 | 90.3 |
| k8s | netLoss | 2 | budget_stopped |  | 21332 | 19 | 90.3 |
| k8s | netLoss | 3 | budget_stopped |  | 16100 | 12 | 90.3 |
| k8s | netLoss | 5 | budget_stopped |  | 17913 | 9 | 90.3 |
| k8s | podDeleteFail | 0 | budget_stopped |  | 18746 | 52 | 90.3 |
| k8s | podDeleteFail | 1 | budget_stopped |  | 24810 | 45 | 90.3 |
| k8s | podDeleteFail | 2 | violation | S3Alloc | 150 | 7 | 4.5 |
| k8s | podDeleteFail | 3 | violation | S3Alloc | 74 | 7 | 4.7 |
| k8s | podDeleteFail | 5 | violation | S3Alloc | 102 | 7 | 4.9 |
| k8s | podDeleteFail__abort | 1 | budget_stopped |  | 21423 | 44 | 90.2 |
| k8s | podDeleteFail__abort | 2 | violation | S3Alloc | 156 | 7 | 3.6 |
| k8s | podDeleteFail__abort | 3 | violation | S3Alloc | 74 | 7 | 4.3 |
| k8s | podDeleteFail__cjCrash | 1 | budget_stopped |  | 65863 | 17 | 90.3 |
| k8s | podDeleteFail__cjCrash | 2 | violation | S3Alloc | 470 | 7 | 4.8 |
| k8s | podDeleteFail__cjCrash | 3 | violation | S3Alloc | 184 | 7 | 4.5 |
| k8s | podDeleteFail__cpCrash | 1 | violation | S3Alloc | 124 | 8 | 3.4 |
| k8s | podDeleteFail__cpCrash | 2 | violation | S3Alloc | 8 | 3 | 2.9 |
| k8s | podDeleteFail__cpCrash | 3 | violation | S3Alloc | 6 | 3 | 2.9 |
| k8s | podDeleteFail__deleteJob | 1 | budget_stopped |  | 22336 | 44 | 90.2 |
| k8s | podDeleteFail__deleteJob | 2 | violation | S3Alloc | 156 | 7 | 4.1 |
| k8s | podDeleteFail__deleteJob | 3 | violation | S3Alloc | 76 | 7 | 4.1 |
| k8s | podDeleteFail__netLoss | 1 | violation | S3Alloc | 18849 | 11 | 39.8 |
| k8s | podDeleteFail__netLoss | 2 | violation | S3Alloc | 2332 | 6 | 7.3 |
| k8s | podDeleteFail__netLoss | 3 | violation | S3Alloc | 2264 | 6 | 9.5 |
| k8s | podDeleteFail__rpcTimeout | 1 | violation | S3Alloc | 2705 | 11 | 7.7 |
| k8s | podDeleteFail__rpcTimeout | 2 | violation | S3Alloc | 156 | 7 | 4.4 |
| k8s | podDeleteFail__rpcTimeout | 3 | violation | S3Alloc | 70 | 7 | 4.3 |
| k8s | podDeleteFail__spCrash | 1 | violation | I_Q | 138 | 7 | 3.4 |
| k8s | podDeleteFail__spCrash | 2 | violation | S3Alloc | 408 | 7 | 4.6 |
| k8s | podDeleteFail__spCrash | 3 | violation | S3Alloc | 230 | 7 | 4.9 |
| k8s | podDeleteFail__spShutdown | 1 | violation | S3Alloc | 4911 | 10 | 9.5 |
| k8s | podDeleteFail__spShutdown | 2 | violation | S3Alloc | 487 | 7 | 5.0 |
| k8s | podDeleteFail__spShutdown | 3 | violation | S3Alloc | 266 | 7 | 5.4 |
| k8s | rpcTimeout | 0 | pass_exhaustive |  | 35 | 9 | 3.1 |
| k8s | rpcTimeout | 1 | budget_stopped |  | 49048 | 19 | 90.3 |
| k8s | rpcTimeout | 2 | pass_exhaustive |  | 45 | 33 | 3.6 |
| k8s | rpcTimeout | 3 | pass_exhaustive |  | 5 | 5 | 3.1 |
| k8s | rpcTimeout | 5 | pass_exhaustive |  | 423 | 28 | 5.2 |
| k8s | sjCrash | 0 | pass_exhaustive |  | 5 | 5 | 2.8 |
| k8s | sjCrash | 1 | violation | S2F | 1126 | 18 | 5.6 |
| k8s | sjCrash | 2 | pass_exhaustive |  | 8207 | 22 | 16.4 |
| k8s | sjCrash | 3 | pass_exhaustive |  | 1150 | 19 | 6.2 |
| k8s | sjCrash | 5 | pass_exhaustive |  | 17895 | 11 | 31.9 |
| k8s | slowPublish | 0 | pass_exhaustive |  | 5 | 5 | 3.2 |
| k8s | slowPublish | 1 | violation | S2F | 53748 | 14 | 52.8 |
| k8s | slowPublish | 2 | budget_stopped |  | 45029 | 19 | 90.3 |
| k8s | slowPublish | 3 | budget_stopped |  | 27965 | 22 | 90.2 |
| k8s | slowPublish | 5 | budget_stopped |  | 31439 | 18 | 90.2 |
| k8s | slowPublish__abort | 1 | budget_stopped |  | 65019 | 17 | 90.3 |
| k8s | slowPublish__abort | 2 | budget_stopped |  | 50869 | 12 | 90.2 |
| k8s | slowPublish__abort | 3 | budget_stopped |  | 30593 | 14 | 90.2 |
| k8s | slowPublish__cjCrash | 1 | violation | S2F | 51163 | 14 | 59.9 |
| k8s | slowPublish__cjCrash | 2 | budget_stopped |  | 45268 | 19 | 90.3 |
| k8s | slowPublish__cjCrash | 3 | budget_stopped |  | 25472 | 22 | 90.3 |
| k8s | slowPublish__cpCrash | 1 | violation | S3Alloc | 107 | 8 | 3.5 |
| k8s | slowPublish__cpCrash | 2 | violation | S3Alloc | 7 | 3 | 3.2 |
| k8s | slowPublish__cpCrash | 3 | violation | S3Alloc | 4 | 4 | 3.2 |
| k8s | slowPublish__deleteJob | 1 | violation | S2F | 81073 | 18 | 66.7 |
| k8s | slowPublish__deleteJob | 2 | budget_stopped |  | 51988 | 16 | 90.3 |
| k8s | slowPublish__deleteJob | 3 | budget_stopped |  | 29405 | 19 | 90.2 |
| k8s | slowPublish__netLoss | 1 | budget_stopped |  | 68655 | 16 | 90.3 |
| k8s | slowPublish__netLoss | 2 | budget_stopped |  | 46145 | 10 | 90.3 |
| k8s | slowPublish__netLoss | 3 | budget_stopped |  | 28751 | 10 | 90.3 |
| k8s | slowPublish__rpcTimeout | 1 | budget_stopped |  | 73513 | 16 | 90.3 |
| k8s | slowPublish__rpcTimeout | 2 | budget_stopped |  | 53297 | 17 | 90.2 |
| k8s | slowPublish__rpcTimeout | 3 | budget_stopped |  | 31004 | 19 | 90.3 |
| k8s | slowPublish__spCrash | 1 | violation | I_Q | 86 | 7 | 3.4 |
| k8s | slowPublish__spCrash | 2 | violation | I_Q | 2573 | 9 | 8.3 |
| k8s | slowPublish__spCrash | 3 | violation | I_Q | 672 | 11 | 6.6 |
| k8s | slowPublish__spShutdown | 1 | violation_sim | I_Q | 78540 | 16 | 90.3 |
| k8s | slowPublish__spShutdown | 2 | violation | I_Q | 57079 | 9 | 64.2 |
| k8s | slowPublish__spShutdown | 3 | violation | I_Q | 17998 | 11 | 38.1 |
| k8s | spCrash | 0 | pass_exhaustive |  | 35 | 9 | 3.3 |
| k8s | spCrash | 1 | violation | I_Q | 85 | 7 | 3.5 |
| k8s | spCrash | 2 | violation | I_Q | 95 | 15 | 4.9 |
| k8s | spCrash | 3 | violation | I_Q | 97 | 14 | 5.4 |
| k8s | spCrash | 5 | violation | I_Q | 202 | 13 | 6.4 |
| k8s | spShutdown | 0 | violation | I_Q | 40 | 7 | 3.1 |
| k8s | spShutdown | 1 | violation_sim | I_Q | 58754 | 21 | 90.3 |
| k8s | spShutdown | 2 | violation | I_Q | 2926 | 16 | 9.2 |
| k8s | spShutdown | 3 | violation | I_Q | 4277 | 13 | 15.0 |
| k8s | spShutdown | 5 | violation | I_Q | 2941 | 15 | 11.2 |
| k8s | taskTimeout | 0 | pass_exhaustive |  | 5 | 5 | 3.1 |
| k8s | taskTimeout | 1 | pass_exhaustive |  | 14 | 10 | 3.0 |
| k8s | taskTimeout | 2 | budget_stopped |  | 32134 | 24 | 90.2 |
| k8s | taskTimeout | 3 | pass_exhaustive |  | 1776 | 18 | 8.4 |
| k8s | taskTimeout | 5 | pass_exhaustive |  | 2348 | 12 | 9.3 |
| multijob | abort | 0 | budget_stopped |  | 26647 | 53 | 90.3 |
| multijob | abort | 1 | budget_stopped |  | 25770 | 45 | 90.3 |
| multijob | abort | 2 | budget_stopped |  | 51002 | 18 | 90.3 |
| multijob | abort | 3 | budget_stopped |  | 32302 | 16 | 90.3 |
| multijob | abort | 5 | budget_stopped |  | 30075 | 14 | 90.2 |
| multijob | cjCrash | 0 | pass_exhaustive |  | 20 | 8 | 3.1 |
| multijob | cjCrash | 1 | violation | S2F | 34515 | 15 | 32.3 |
| multijob | cjCrash | 2 | budget_stopped |  | 55969 | 24 | 90.3 |
| multijob | cjCrash | 3 | budget_stopped |  | 32905 | 22 | 90.3 |
| multijob | cjCrash | 5 | budget_stopped |  | 45325 | 17 | 90.3 |
| multijob | cpCrash | 0 | pass_exhaustive |  | 140 | 12 | 3.4 |
| multijob | cpCrash | 1 | violation | I_Q | 63767 | 17 | 71.2 |
| multijob | cpCrash | 2 | violation | I_Q | 204 | 12 | 4.2 |
| multijob | cpCrash | 3 | pass_exhaustive |  | 1972 | 21 | 9.8 |
| multijob | cpCrash | 5 | pass_exhaustive |  | 19290 | 15 | 42.1 |
| multijob | deadClient | 0 | budget_stopped |  | 70062 | 26 | 90.3 |
| multijob | deadClient | 1 | budget_stopped |  | 67525 | 21 | 90.3 |
| multijob | deadClient | 2 | budget_stopped |  | 42326 | 18 | 90.3 |
| multijob | deadClient | 3 | budget_stopped |  | 32663 | 28 | 90.3 |
| multijob | deadClient | 5 | pass_exhaustive |  | 44164 | 29 | 78.5 |
| multijob | deleteJob | 0 | violation | S1Sched | 8 | 3 | 3.3 |
| multijob | deleteJob | 1 | pass_exhaustive |  | 4623 | 29 | 13.9 |
| multijob | deleteJob | 2 | pass_exhaustive |  | 365 | 40 | 4.8 |
| multijob | deleteJob | 3 | pass_exhaustive |  | 28 | 11 | 3.3 |
| multijob | deleteJob | 5 | pass_exhaustive |  | 1188 | 24 | 6.9 |
| multijob | jobExitRace | 0 | violation | S1Cleanup | 49 | 6 | 3.2 |
| multijob | jobExitRace | 1 | violation | S1Cleanup | 45 | 5 | 3.2 |
| multijob | jobExitRace | 2 | violation | S1Cleanup | 61 | 5 | 3.5 |
| multijob | jobExitRace | 3 | violation | S1Cleanup | 56 | 8 | 4.2 |
| multijob | jobExitRace | 5 | violation | S1Cleanup | 54 | 6 | 4.1 |
| multijob | jobExitRace__abort | 1 | violation | S1Cleanup | 84 | 5 | 3.4 |
| multijob | jobExitRace__abort | 2 | violation | S1Cleanup | 138 | 5 | 3.9 |
| multijob | jobExitRace__abort | 3 | violation | S1Cleanup | 144 | 6 | 4.8 |
| multijob | jobExitRace__deadClient | 1 | violation | S1Cleanup | 52 | 5 | 3.3 |
| multijob | jobExitRace__deadClient | 2 | violation | S1Cleanup | 70 | 6 | 3.5 |
| multijob | jobExitRace__deadClient | 3 | violation | S1Cleanup | 56 | 8 | 4.2 |
| multijob | jobExitRace__deleteJob | 1 | violation | S1Cleanup | 50 | 5 | 3.4 |
| multijob | jobExitRace__deleteJob | 2 | violation | S1Cleanup | 61 | 5 | 3.6 |
| multijob | jobExitRace__deleteJob | 3 | violation | S1Cleanup | 56 | 8 | 4.3 |
| multijob | jobExitRace__netLoss | 1 | violation | S1Cleanup | 141 | 5 | 3.4 |
| multijob | jobExitRace__netLoss | 2 | violation | S1Cleanup | 214 | 5 | 3.8 |
| multijob | jobExitRace__netLoss | 3 | violation | S1Cleanup | 1063 | 5 | 5.5 |
| multijob | jobExitRace__rpcTimeout | 1 | violation | S1Cleanup | 78 | 5 | 3.3 |
| multijob | jobExitRace__rpcTimeout | 2 | violation | S1Cleanup | 61 | 5 | 3.7 |
| multijob | jobExitRace__rpcTimeout | 3 | violation | S1Cleanup | 64 | 9 | 4.4 |
| multijob | jobExitRace__sjCrash | 1 | violation | S1Cleanup | 56 | 5 | 3.1 |
| multijob | jobExitRace__sjCrash | 2 | violation | S1Cleanup | 102 | 5 | 3.6 |
| multijob | jobExitRace__sjCrash | 3 | violation | S1Cleanup | 92 | 9 | 4.2 |
| multijob | jobExitRace__spCrash | 1 | violation | S1Cleanup | 121 | 5 | 3.4 |
| multijob | jobExitRace__spCrash | 2 | violation | S1Cleanup | 120 | 5 | 3.9 |
| multijob | jobExitRace__spCrash | 3 | violation | S1Cleanup | 115 | 9 | 4.5 |
| multijob | jobExitRace__spShutdown | 1 | violation | S1Cleanup | 105 | 5 | 3.5 |
| multijob | jobExitRace__spShutdown | 2 | violation | S1Cleanup | 122 | 5 | 3.5 |
| multijob | jobExitRace__spShutdown | 3 | violation | S1Cleanup | 106 | 9 | 4.5 |
| multijob | jobExitRace__taskTimeout | 1 | violation | S1Cleanup | 52 | 5 | 3.2 |
| multijob | jobExitRace__taskTimeout | 2 | violation | S1Cleanup | 69 | 5 | 3.5 |
| multijob | jobExitRace__taskTimeout | 3 | violation | S1Cleanup | 115 | 5 | 4.5 |
| multijob | netLoss | 0 | budget_stopped |  | 28600 | 30 | 90.3 |
| multijob | netLoss | 1 | budget_stopped |  | 34686 | 21 | 90.3 |
| multijob | netLoss | 2 | budget_stopped |  | 24415 | 21 | 90.3 |
| multijob | netLoss | 3 | budget_stopped |  | 22092 | 10 | 90.3 |
| multijob | netLoss | 5 | budget_stopped |  | 24328 | 8 | 90.3 |
| multijob | regIterRace | 0 | violation | S1Cleanup | 23 | 5 | 3.1 |
| multijob | regIterRace | 1 | violation | S1Cleanup | 25 | 4 | 3.0 |
| multijob | regIterRace | 2 | violation | S1Cleanup | 28 | 4 | 3.3 |
| multijob | regIterRace | 3 | violation | S1Cleanup | 32 | 8 | 3.6 |
| multijob | regIterRace | 5 | violation | S1Cleanup | 28 | 5 | 3.6 |
| multijob | regIterRace__abort | 1 | violation | S1Cleanup | 36 | 4 | 3.4 |
| multijob | regIterRace__abort | 2 | violation | S1Cleanup | 59 | 4 | 3.6 |
| multijob | regIterRace__abort | 3 | violation | S1Cleanup | 66 | 5 | 4.0 |
| multijob | regIterRace__deadClient | 1 | violation | S1Cleanup | 26 | 5 | 3.7 |
| multijob | regIterRace__deadClient | 2 | violation | S1Cleanup | 34 | 4 | 3.7 |
| multijob | regIterRace__deadClient | 3 | violation | S1Cleanup | 32 | 8 | 4.4 |
| multijob | regIterRace__deleteJob | 1 | violation | S1Cleanup | 26 | 4 | 3.6 |
| multijob | regIterRace__deleteJob | 2 | violation | S1Cleanup | 30 | 4 | 3.7 |
| multijob | regIterRace__deleteJob | 3 | violation | S1Cleanup | 30 | 7 | 4.3 |
| multijob | regIterRace__netLoss | 1 | violation | S1Cleanup | 51 | 4 | 3.6 |
| multijob | regIterRace__netLoss | 2 | violation | S1Cleanup | 81 | 4 | 3.7 |
| multijob | regIterRace__netLoss | 3 | violation | S1Cleanup | 229 | 4 | 4.2 |
| multijob | regIterRace__rpcTimeout | 1 | violation | S1Cleanup | 34 | 4 | 3.7 |
| multijob | regIterRace__rpcTimeout | 2 | violation | S1Cleanup | 28 | 4 | 3.8 |
| multijob | regIterRace__rpcTimeout | 3 | violation | S1Cleanup | 30 | 7 | 4.2 |
| multijob | regIterRace__sjCrash | 1 | violation | S1Cleanup | 26 | 4 | 3.3 |
| multijob | regIterRace__sjCrash | 2 | violation | S1Cleanup | 39 | 4 | 3.4 |
| multijob | regIterRace__sjCrash | 3 | violation | S1Cleanup | 43 | 8 | 3.8 |
| multijob | regIterRace__spCrash | 1 | violation | S1Cleanup | 49 | 4 | 3.4 |
| multijob | regIterRace__spCrash | 2 | violation | S1Cleanup | 41 | 4 | 3.6 |
| multijob | regIterRace__spCrash | 3 | violation | S1Cleanup | 42 | 7 | 4.2 |
| multijob | regIterRace__spShutdown | 1 | violation | S1Cleanup | 44 | 4 | 3.8 |
| multijob | regIterRace__spShutdown | 2 | violation | S1Cleanup | 53 | 4 | 3.8 |
| multijob | regIterRace__spShutdown | 3 | violation | S1Cleanup | 42 | 7 | 4.3 |
| multijob | regIterRace__taskTimeout | 1 | violation | S1Cleanup | 26 | 4 | 3.6 |
| multijob | regIterRace__taskTimeout | 2 | violation | S1Cleanup | 28 | 4 | 3.9 |
| multijob | regIterRace__taskTimeout | 3 | violation | S1Cleanup | 41 | 4 | 4.0 |
| multijob | rpcTimeout | 0 | pass_exhaustive |  | 140 | 12 | 3.5 |
| multijob | rpcTimeout | 1 | budget_stopped |  | 56930 | 19 | 90.3 |
| multijob | rpcTimeout | 2 | pass_exhaustive |  | 365 | 40 | 4.8 |
| multijob | rpcTimeout | 3 | pass_exhaustive |  | 28 | 11 | 3.7 |
| multijob | rpcTimeout | 5 | pass_exhaustive |  | 2538 | 22 | 10.3 |
| multijob | sjCrash | 0 | pass_exhaustive |  | 20 | 8 | 3.1 |
| multijob | sjCrash | 1 | violation | S2F | 2306 | 15 | 7.2 |
| multijob | sjCrash | 2 | budget_stopped |  | 64005 | 44 | 90.3 |
| multijob | sjCrash | 3 | pass_exhaustive |  | 6906 | 16 | 13.2 |
| multijob | sjCrash | 5 | budget_stopped |  | 51681 | 22 | 90.3 |
| multijob | slowShutdownAbort | 0 | violation | I_Q | 130 | 8 | 3.4 |
| multijob | slowShutdownAbort | 1 | violation | S4CompletedWf | 116575 | 19 | 83.3 |
| multijob | slowShutdownAbort | 2 | violation | I_Q | 17871 | 12 | 26.0 |
| multijob | slowShutdownAbort | 3 | violation | I_Q | 33976 | 21 | 73.7 |
| multijob | slowShutdownAbort | 5 | violation | I_Q | 23089 | 12 | 47.9 |
| multijob | slowShutdownAbort__abort | 1 | violation | S4CompletedWf |  | 15 | 90.2 |
| multijob | slowShutdownAbort__abort | 2 | violation_sim | I_Q | 54385 | 13 | 90.3 |
| multijob | slowShutdownAbort__abort | 3 | violation_sim | I_Q | 29269 | 11 | 90.3 |
| multijob | slowShutdownAbort__cjCrash | 1 | violation_sim | I_Q | 81737 | 15 | 90.3 |
| multijob | slowShutdownAbort__cjCrash | 2 | violation | I_Q | 37722 | 8 | 38.2 |
| multijob | slowShutdownAbort__cjCrash | 3 | violation_sim | I_Q | 38437 | 14 | 90.3 |
| multijob | slowShutdownAbort__cpCrash | 1 | violation | I_Q | 3065 | 9 | 6.9 |
| multijob | slowShutdownAbort__cpCrash | 2 | violation | I_Q | 694 | 9 | 5.6 |
| multijob | slowShutdownAbort__cpCrash | 3 | violation | I_Q | 961 | 13 | 6.9 |
| multijob | slowShutdownAbort__deadClient | 1 | violation_sim | I_Q | 105724 | 14 | 90.3 |
| multijob | slowShutdownAbort__deadClient | 2 | violation_sim | I_Q | 63359 | 13 | 90.3 |
| multijob | slowShutdownAbort__deadClient | 3 | violation_sim | I_Q | 31860 | 16 | 90.3 |
| multijob | slowShutdownAbort__deleteJob | 1 | violation | S4CompletedWf | 127174 | 19 | 83.7 |
| multijob | slowShutdownAbort__deleteJob | 2 | violation | I_Q | 17547 | 12 | 24.1 |
| multijob | slowShutdownAbort__deleteJob | 3 | violation | I_Q | 33983 | 21 | 68.8 |
| multijob | slowShutdownAbort__netLoss | 1 | violation_sim | I_Q | 86426 | 14 | 90.3 |
| multijob | slowShutdownAbort__netLoss | 2 | violation_sim | I_Q | 53266 | 12 | 90.2 |
| multijob | slowShutdownAbort__netLoss | 3 | violation_sim | I_Q | 34700 | 8 | 90.2 |
| multijob | slowShutdownAbort__rpcTimeout | 1 | violation | I_Q | 1798 | 9 | 4.9 |
| multijob | slowShutdownAbort__rpcTimeout | 2 | violation | I_Q | 18874 | 12 | 29.3 |
| multijob | slowShutdownAbort__rpcTimeout | 3 | violation | I_Q | 35961 | 20 | 86.8 |
| multijob | slowShutdownAbort__sjCrash | 1 | violation | S2F | 63012 | 9 | 57.6 |
| multijob | slowShutdownAbort__sjCrash | 2 | violation_sim | I_Q | 55968 | 13 | 90.3 |
| multijob | slowShutdownAbort__sjCrash | 3 | violation_sim | I_Q | 31103 | 16 | 90.2 |
| multijob | slowShutdownAbort__spCrash | 1 | violation | I_Q | 380 | 6 | 4.5 |
| multijob | slowShutdownAbort__spCrash | 2 | violation | I_Q | 9680 | 11 | 19.2 |
| multijob | slowShutdownAbort__spCrash | 3 | violation | I_Q | 18491 | 13 | 51.0 |
| multijob | slowShutdownAbort__spShutdown | 1 | violation | S2F | 85426 | 10 | 57.3 |
| multijob | slowShutdownAbort__spShutdown | 2 | violation | I_Q | 12093 | 12 | 18.7 |
| multijob | slowShutdownAbort__spShutdown | 3 | violation | I_Q | 22542 | 14 | 50.2 |
| multijob | spCrash | 0 | pass_exhaustive |  | 140 | 12 | 3.2 |
| multijob | spCrash | 1 | violation | I_Q | 131 | 7 | 3.2 |
| multijob | spCrash | 2 | violation | I_Q | 335 | 14 | 5.1 |
| multijob | spCrash | 3 | violation | I_Q | 452 | 18 | 6.2 |
| multijob | spCrash | 5 | violation | I_Q | 877 | 14 | 7.4 |
| multijob | spShutdown | 0 | violation | I_Q | 134 | 8 | 3.4 |
| multijob | spShutdown | 1 | violation_sim | I_Q | 89335 | 21 | 90.3 |
| multijob | spShutdown | 2 | violation | I_Q | 9494 | 13 | 16.9 |
| multijob | spShutdown | 3 | violation | I_Q | 16571 | 15 | 35.2 |
| multijob | spShutdown | 5 | violation | I_Q | 13643 | 13 | 26.3 |
| multijob | taskTimeout | 0 | pass_exhaustive |  | 11 | 8 | 3.1 |
| multijob | taskTimeout | 1 | pass_exhaustive |  | 14 | 10 | 3.1 |
| multijob | taskTimeout | 2 | budget_stopped |  | 34334 | 26 | 90.2 |
| multijob | taskTimeout | 3 | pass_exhaustive |  | 17330 | 17 | 33.4 |
| multijob | taskTimeout | 5 | pass_exhaustive |  | 14090 | 11 | 27.9 |
| multijobcp | abort | 0 | budget_stopped |  | 24129 | 49 | 90.3 |
| multijobcp | abort | 1 | budget_stopped |  | 22562 | 44 | 90.2 |
| multijobcp | abort | 2 | budget_stopped |  | 41576 | 19 | 90.3 |
| multijobcp | abort | 3 | budget_stopped |  | 25356 | 21 | 90.2 |
| multijobcp | abort | 5 | budget_stopped |  | 25675 | 18 | 90.3 |
| multijobcp | cjCrash | 0 | violation | S2F | 47097 | 21 | 52.6 |
| multijobcp | cjCrash | 1 | violation | S3J2Gpu | 38 | 6 | 3.1 |
| multijobcp | cjCrash | 2 | budget_stopped |  | 47163 | 21 | 90.3 |
| multijobcp | cjCrash | 3 | budget_stopped |  | 28413 | 24 | 90.3 |
| multijobcp | cjCrash | 5 | budget_stopped |  | 33487 | 19 | 90.2 |
| multijobcp | cpCrash | 0 | pass_exhaustive |  | 140 | 12 | 3.5 |
| multijobcp | cpCrash | 1 | violation | I_Q | 25201 | 11 | 31.4 |
| multijobcp | cpCrash | 2 | violation | I_Q | 8 | 4 | 3.4 |
| multijobcp | cpCrash | 3 | pass_exhaustive |  | 329 | 24 | 5.6 |
| multijobcp | cpCrash | 5 | pass_exhaustive |  | 3215 | 17 | 13.6 |
| multijobcp | deadClient | 0 | budget_stopped |  | 49697 | 31 | 90.3 |
| multijobcp | deadClient | 1 | budget_stopped |  | 52567 | 24 | 90.3 |
| multijobcp | deadClient | 2 | budget_stopped |  | 32900 | 17 | 90.3 |
| multijobcp | deadClient | 3 | budget_stopped |  | 34881 | 31 | 90.3 |
| multijobcp | deadClient | 5 | pass_exhaustive |  | 9456 | 15 | 23.7 |
| multijobcp | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.2 |
| multijobcp | deleteJob | 1 | pass_exhaustive |  | 4623 | 24 | 15.9 |
| multijobcp | deleteJob | 2 | pass_exhaustive |  | 243 | 38 | 4.7 |
| multijobcp | deleteJob | 3 | pass_exhaustive |  | 5 | 5 | 2.9 |
| multijobcp | deleteJob | 5 | pass_exhaustive |  | 198 | 27 | 4.4 |
| multijobcp | netLoss | 0 | budget_stopped |  | 29833 | 28 | 90.3 |
| multijobcp | netLoss | 1 | budget_stopped |  | 35215 | 21 | 90.3 |
| multijobcp | netLoss | 2 | budget_stopped |  | 20324 | 18 | 90.2 |
| multijobcp | netLoss | 3 | budget_stopped |  | 17831 | 12 | 90.3 |
| multijobcp | netLoss | 5 | budget_stopped |  | 20832 | 10 | 90.3 |
| multijobcp | rpcTimeout | 0 | pass_exhaustive |  | 140 | 12 | 3.4 |
| multijobcp | rpcTimeout | 1 | budget_stopped |  | 52062 | 19 | 90.3 |
| multijobcp | rpcTimeout | 2 | pass_exhaustive |  | 243 | 38 | 4.3 |
| multijobcp | rpcTimeout | 3 | pass_exhaustive |  | 5 | 5 | 3.0 |
| multijobcp | rpcTimeout | 5 | pass_exhaustive |  | 423 | 28 | 5.7 |
| multijobcp | sjCrash | 0 | pass_exhaustive |  | 8 | 8 | 2.9 |
| multijobcp | sjCrash | 1 | violation | S2F | 1035 | 18 | 5.5 |
| multijobcp | sjCrash | 2 | budget_stopped |  | 48674 | 45 | 90.2 |
| multijobcp | sjCrash | 3 | pass_exhaustive |  | 1150 | 19 | 6.1 |
| multijobcp | sjCrash | 5 | pass_exhaustive |  | 17895 | 13 | 30.5 |
| multijobcp | spCrash | 0 | pass_exhaustive |  | 140 | 12 | 3.7 |
| multijobcp | spCrash | 1 | violation | I_Q | 458 | 9 | 4.5 |
| multijobcp | spCrash | 2 | violation | I_Q | 227 | 12 | 5.5 |
| multijobcp | spCrash | 3 | violation | I_Q | 97 | 14 | 5.3 |
| multijobcp | spCrash | 5 | violation | I_Q | 310 | 14 | 6.4 |
| multijobcp | spShutdown | 0 | violation | I_Q | 199 | 10 | 3.5 |
| multijobcp | spShutdown | 1 | violation_sim | I_Q | 77893 | 20 | 90.2 |
| multijobcp | spShutdown | 2 | violation | I_Q | 5244 | 18 | 12.9 |
| multijobcp | spShutdown | 3 | violation | I_Q | 3259 | 14 | 13.0 |
| multijobcp | spShutdown | 5 | violation | I_Q | 4431 | 15 | 13.9 |
| multijobcp | startOverlap | 0 | pass_exhaustive |  | 20 | 8 | 3.1 |
| multijobcp | startOverlap | 1 | pass_exhaustive |  | 4401 | 26 | 14.9 |
| multijobcp | startOverlap | 2 | pass_exhaustive |  | 243 | 38 | 4.6 |
| multijobcp | startOverlap | 3 | pass_exhaustive |  | 5 | 5 | 3.2 |
| multijobcp | startOverlap | 5 | pass_exhaustive |  | 104 | 26 | 4.0 |
| multijobcp | startOverlap__abort | 1 | budget_stopped |  | 24628 | 45 | 90.3 |
| multijobcp | startOverlap__abort | 2 | budget_stopped |  | 48003 | 19 | 90.3 |
| multijobcp | startOverlap__abort | 3 | budget_stopped |  | 27383 | 21 | 90.2 |
| multijobcp | startOverlap__cjCrash | 1 | violation | S3J2Gpu | 38 | 6 | 3.3 |
| multijobcp | startOverlap__cjCrash | 2 | budget_stopped |  | 51513 | 22 | 90.3 |
| multijobcp | startOverlap__cjCrash | 3 | budget_stopped |  | 28105 | 24 | 90.2 |
| multijobcp | startOverlap__cpCrash | 1 | violation | I_Q | 25137 | 11 | 30.6 |
| multijobcp | startOverlap__cpCrash | 2 | violation | I_Q | 8 | 4 | 3.3 |
| multijobcp | startOverlap__cpCrash | 3 | pass_exhaustive |  | 329 | 24 | 5.7 |
| multijobcp | startOverlap__deleteJob | 1 | pass_exhaustive |  | 5013 | 20 | 15.3 |
| multijobcp | startOverlap__deleteJob | 2 | pass_exhaustive |  | 243 | 38 | 5.0 |
| multijobcp | startOverlap__deleteJob | 3 | pass_exhaustive |  | 5 | 5 | 3.3 |
| multijobcp | startOverlap__netLoss | 1 | budget_stopped |  | 35587 | 21 | 90.3 |
| multijobcp | startOverlap__netLoss | 2 | budget_stopped |  | 21861 | 19 | 90.3 |
| multijobcp | startOverlap__netLoss | 3 | budget_stopped |  | 17179 | 12 | 90.3 |
| multijobcp | startOverlap__rpcTimeout | 1 | budget_stopped |  | 59206 | 19 | 90.2 |
| multijobcp | startOverlap__rpcTimeout | 2 | pass_exhaustive |  | 243 | 38 | 4.3 |
| multijobcp | startOverlap__rpcTimeout | 3 | pass_exhaustive |  | 5 | 5 | 3.0 |
| multijobcp | startOverlap__spCrash | 1 | violation | I_Q | 455 | 9 | 4.2 |
| multijobcp | startOverlap__spCrash | 2 | violation | I_Q | 227 | 12 | 5.1 |
| multijobcp | startOverlap__spCrash | 3 | violation | I_Q | 91 | 14 | 4.8 |
| multijobcp | startOverlap__spShutdown | 1 | violation_sim | I_Q | 65874 | 17 | 90.3 |
| multijobcp | startOverlap__spShutdown | 2 | violation | I_Q | 5358 | 12 | 11.9 |
| multijobcp | startOverlap__spShutdown | 3 | violation | I_Q | 4671 | 13 | 15.7 |
| multijobcp | taskTimeout | 0 | pass_exhaustive |  | 17 | 8 | 3.3 |
| multijobcp | taskTimeout | 1 | pass_exhaustive |  | 20 | 10 | 3.2 |
| multijobcp | taskTimeout | 2 | budget_stopped |  | 33295 | 21 | 90.3 |
| multijobcp | taskTimeout | 3 | pass_exhaustive |  | 1776 | 18 | 8.2 |
| multijobcp | taskTimeout | 5 | pass_exhaustive |  | 2348 | 12 | 9.5 |
| nonstrict | abort | 0 | budget_stopped |  | 18263 | 57 | 90.3 |
| nonstrict | abort | 1 | budget_stopped |  | 18226 | 50 | 90.3 |
| nonstrict | abort | 2 | budget_stopped |  | 55290 | 19 | 90.2 |
| nonstrict | abort | 3 | budget_stopped |  | 26561 | 15 | 90.3 |
| nonstrict | abort | 5 | budget_stopped |  | 26894 | 13 | 90.3 |
| nonstrict | cjCrash | 0 | pass_exhaustive |  | 5 | 5 | 3.1 |
| nonstrict | cjCrash | 1 | violation | S2F | 15813 | 17 | 17.1 |
| nonstrict | cjCrash | 2 | budget_stopped |  | 54182 | 26 | 90.3 |
| nonstrict | cjCrash | 3 | budget_stopped |  | 36557 | 21 | 90.3 |
| nonstrict | cjCrash | 5 | budget_stopped |  | 42105 | 17 | 90.2 |
| nonstrict | cpCrash | 0 | pass_exhaustive |  | 35 | 9 | 3.3 |
| nonstrict | cpCrash | 1 | violation | I_Q | 2684 | 11 | 7.1 |
| nonstrict | cpCrash | 2 | violation | I_Q | 15 | 6 | 3.4 |
| nonstrict | cpCrash | 3 | pass_exhaustive |  | 2024 | 20 | 11.3 |
| nonstrict | cpCrash | 5 | pass_exhaustive |  | 12872 | 17 | 33.4 |
| nonstrict | deadClient | 0 | budget_stopped |  | 52024 | 28 | 90.3 |
| nonstrict | deadClient | 1 | budget_stopped |  | 57699 | 22 | 90.3 |
| nonstrict | deadClient | 2 | budget_stopped |  | 46089 | 18 | 90.3 |
| nonstrict | deadClient | 3 | budget_stopped |  | 28650 | 19 | 90.3 |
| nonstrict | deadClient | 5 | budget_stopped |  | 39568 | 22 | 90.3 |
| nonstrict | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.4 |
| nonstrict | deleteJob | 1 | pass_exhaustive |  | 1541 | 44 | 7.5 |
| nonstrict | deleteJob | 2 | pass_exhaustive |  | 121 | 36 | 4.1 |
| nonstrict | deleteJob | 3 | pass_exhaustive |  | 80 | 16 | 3.9 |
| nonstrict | deleteJob | 5 | pass_exhaustive |  | 804 | 33 | 5.6 |
| nonstrict | netLoss | 0 | budget_stopped |  | 23617 | 34 | 90.3 |
| nonstrict | netLoss | 1 | budget_stopped |  | 27188 | 23 | 90.3 |
| nonstrict | netLoss | 2 | budget_stopped |  | 22634 | 20 | 90.2 |
| nonstrict | netLoss | 3 | budget_stopped |  | 21688 | 9 | 90.3 |
| nonstrict | netLoss | 5 | budget_stopped |  | 27440 | 9 | 90.2 |
| nonstrict | rpcTimeout | 0 | pass_exhaustive |  | 35 | 9 | 3.1 |
| nonstrict | rpcTimeout | 1 | budget_stopped |  | 59776 | 20 | 90.3 |
| nonstrict | rpcTimeout | 2 | pass_exhaustive |  | 121 | 36 | 3.7 |
| nonstrict | rpcTimeout | 3 | pass_exhaustive |  | 80 | 16 | 3.9 |
| nonstrict | rpcTimeout | 5 | pass_exhaustive |  | 1704 | 26 | 8.0 |
| nonstrict | sjCrash | 0 | pass_exhaustive |  | 5 | 5 | 2.6 |
| nonstrict | sjCrash | 1 | violation | S2F | 1031 | 16 | 5.2 |
| nonstrict | sjCrash | 2 | pass_exhaustive |  | 33054 | 15 | 39.9 |
| nonstrict | sjCrash | 3 | pass_exhaustive |  | 31904 | 13 | 46.7 |
| nonstrict | sjCrash | 5 | budget_stopped |  | 56294 | 18 | 90.2 |
| nonstrict | spCrash | 0 | pass_exhaustive |  | 35 | 9 | 3.2 |
| nonstrict | spCrash | 1 | violation | I_Q | 101 | 7 | 3.4 |
| nonstrict | spCrash | 2 | violation | I_Q | 139 | 12 | 4.5 |
| nonstrict | spCrash | 3 | violation | I_Q | 334 | 18 | 6.0 |
| nonstrict | spCrash | 5 | violation | I_Q | 787 | 17 | 7.9 |
| nonstrict | spShutdown | 0 | violation | I_Q | 40 | 7 | 3.0 |
| nonstrict | spShutdown | 1 | violation_sim | I_Q | 72271 | 23 | 90.3 |
| nonstrict | spShutdown | 2 | violation | I_Q | 2917 | 18 | 8.9 |
| nonstrict | spShutdown | 3 | violation | I_Q | 8448 | 16 | 20.7 |
| nonstrict | spShutdown | 5 | violation | I_Q | 11635 | 16 | 25.5 |
| nonstrict | taskTimeout | 0 | pass_exhaustive |  | 5 | 5 | 3.3 |
| nonstrict | taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.2 |
| nonstrict | taskTimeout | 2 | budget_stopped |  | 34167 | 21 | 90.3 |
| nonstrict | taskTimeout | 3 | budget_stopped |  | 19055 | 18 | 90.3 |
| nonstrict | taskTimeout | 5 | budget_stopped |  | 21954 | 17 | 90.3 |
| sag | abort | 0 | budget_stopped |  | 20104 | 56 | 90.2 |
| sag | abort | 1 | budget_stopped |  | 23176 | 49 | 90.2 |
| sag | abort | 2 | budget_stopped |  | 56085 | 20 | 90.3 |
| sag | abort | 3 | budget_stopped |  | 29012 | 17 | 90.3 |
| sag | abort | 5 | budget_stopped |  | 25033 | 18 | 90.3 |
| sag | acceptRaise | 0 | pass_exhaustive |  | 5 | 5 | 2.8 |
| sag | acceptRaise | 1 | pass_exhaustive |  | 8 | 8 | 2.8 |
| sag | acceptRaise | 2 | violation | S4Artifact | 516 | 69 | 7.1 |
| sag | acceptRaise | 3 | pass_exhaustive |  | 51 | 19 | 4.0 |
| sag | acceptRaise | 5 | pass_exhaustive |  | 40 | 25 | 3.4 |
| sag | acceptRaise__netLoss | 1 | budget_stopped |  | 26690 | 23 | 90.2 |
| sag | acceptRaise__netLoss | 2 | budget_stopped |  | 21076 | 20 | 90.3 |
| sag | acceptRaise__netLoss | 3 | budget_stopped |  | 21795 | 11 | 90.2 |
| sag | acceptRaise__sjCrash | 1 | violation | S2F | 1118 | 16 | 5.8 |
| sag | acceptRaise__sjCrash | 2 | budget_stopped |  | 51820 | 44 | 90.3 |
| sag | acceptRaise__sjCrash | 3 | pass_exhaustive |  | 31671 | 15 | 43.3 |
| sag | cbFail | 0 | pass_exhaustive |  | 5 | 5 | 3.1 |
| sag | cbFail | 1 | budget_stopped |  | 31479 | 50 | 90.3 |
| sag | cbFail | 2 | budget_stopped |  | 28612 | 49 | 90.2 |
| sag | cbFail | 3 | pass_exhaustive |  | 242 | 19 | 5.1 |
| sag | cbFail | 5 | pass_exhaustive |  | 463 | 25 | 5.5 |
| sag | cbFail__abort | 1 | budget_stopped |  | 24895 | 44 | 90.2 |
| sag | cbFail__abort | 2 | budget_stopped |  | 51925 | 19 | 90.3 |
| sag | cbFail__abort | 3 | budget_stopped |  | 26003 | 16 | 90.3 |
| sag | cbFail__cjCrash | 1 | violation | S2F | 18642 | 14 | 21.4 |
| sag | cbFail__cjCrash | 2 | budget_stopped |  | 49245 | 18 | 90.3 |
| sag | cbFail__cjCrash | 3 | budget_stopped |  | 31246 | 17 | 90.3 |
| sag | cbFail__deadClient | 1 | budget_stopped |  | 46945 | 21 | 90.3 |
| sag | cbFail__deadClient | 2 | budget_stopped |  | 41254 | 18 | 90.2 |
| sag | cbFail__deadClient | 3 | budget_stopped |  | 28867 | 20 | 90.2 |
| sag | cbFail__deleteJob | 1 | budget_stopped |  | 30709 | 48 | 90.2 |
| sag | cbFail__deleteJob | 2 | budget_stopped |  | 27009 | 50 | 90.3 |
| sag | cbFail__deleteJob | 3 | pass_exhaustive |  | 242 | 19 | 4.5 |
| sag | cbFail__netLoss | 1 | budget_stopped |  | 29378 | 23 | 90.2 |
| sag | cbFail__netLoss | 2 | budget_stopped |  | 24434 | 20 | 90.2 |
| sag | cbFail__netLoss | 3 | budget_stopped |  | 19330 | 11 | 90.3 |
| sag | cbFail__rpcTimeout | 1 | budget_stopped |  | 50879 | 20 | 90.3 |
| sag | cbFail__rpcTimeout | 2 | budget_stopped |  | 27599 | 49 | 90.3 |
| sag | cbFail__rpcTimeout | 3 | pass_exhaustive |  | 242 | 19 | 4.8 |
| sag | cbFail__sjCrash | 1 | violation | S2F | 1061 | 16 | 5.7 |
| sag | cbFail__sjCrash | 2 | budget_stopped |  | 49465 | 41 | 90.2 |
| sag | cbFail__sjCrash | 3 | pass_exhaustive |  | 31671 | 13 | 43.5 |
| sag | cbFail__spCrash | 1 | violation | I_Q | 86 | 7 | 3.3 |
| sag | cbFail__spCrash | 2 | violation | I_Q | 374 | 12 | 5.6 |
| sag | cbFail__spCrash | 3 | violation | I_Q | 470 | 13 | 6.0 |
| sag | cbFail__spShutdown | 1 | violation_sim | I_Q | 56250 | 18 | 90.3 |
| sag | cbFail__spShutdown | 2 | violation | I_Q | 20385 | 10 | 26.4 |
| sag | cbFail__spShutdown | 3 | violation | I_Q | 23294 | 11 | 43.7 |
| sag | cbFail__taskTimeout | 1 | violation_sim | S4Aggregate | 29872 | 32 | 90.2 |
| sag | cbFail__taskTimeout | 2 | budget_stopped |  | 29442 | 26 | 90.2 |
| sag | cbFail__taskTimeout | 3 | budget_stopped |  | 18102 | 24 | 90.2 |
| sag | cjCrash | 0 | pass_exhaustive |  | 5 | 5 | 2.7 |
| sag | cjCrash | 1 | violation | S2F | 14478 | 17 | 16.5 |
| sag | cjCrash | 2 | budget_stopped |  | 48325 | 27 | 90.3 |
| sag | cjCrash | 3 | budget_stopped |  | 35003 | 23 | 90.3 |
| sag | cjCrash | 5 | budget_stopped |  | 34391 | 22 | 90.2 |
| sag | cpCrash | 0 | pass_exhaustive |  | 35 | 9 | 3.3 |
| sag | cpCrash | 1 | violation | I_Q | 12717 | 12 | 18.4 |
| sag | cpCrash | 2 | violation | I_Q | 16 | 7 | 3.2 |
| sag | cpCrash | 3 | pass_exhaustive |  | 1113 | 24 | 8.6 |
| sag | cpCrash | 5 | pass_exhaustive |  | 3215 | 17 | 12.2 |
| sag | deadClient | 0 | violation_sim | S4Aggregate | 53959 | 28 | 90.3 |
| sag | deadClient | 1 | violation_sim | S4Aggregate | 57192 | 23 | 90.3 |
| sag | deadClient | 2 | budget_stopped |  | 36855 | 18 | 90.3 |
| sag | deadClient | 3 | budget_stopped |  | 28989 | 22 | 90.2 |
| sag | deadClient | 5 | pass_exhaustive |  | 9456 | 15 | 22.5 |
| sag | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.2 |
| sag | deleteJob | 1 | pass_exhaustive |  | 2069 | 41 | 10.1 |
| sag | deleteJob | 2 | pass_exhaustive |  | 165 | 46 | 4.3 |
| sag | deleteJob | 3 | pass_exhaustive |  | 51 | 19 | 3.6 |
| sag | deleteJob | 5 | pass_exhaustive |  | 198 | 27 | 4.4 |
| sag | netLoss | 0 | budget_stopped |  | 25501 | 34 | 90.2 |
| sag | netLoss | 1 | budget_stopped |  | 28659 | 23 | 90.2 |
| sag | netLoss | 2 | budget_stopped |  | 21719 | 20 | 90.2 |
| sag | netLoss | 3 | budget_stopped |  | 19180 | 10 | 90.2 |
| sag | netLoss | 5 | budget_stopped |  | 19297 | 9 | 90.2 |
| sag | rpcTimeout | 0 | pass_exhaustive |  | 35 | 9 | 3.1 |
| sag | rpcTimeout | 1 | budget_stopped |  | 53291 | 22 | 90.3 |
| sag | rpcTimeout | 2 | pass_exhaustive |  | 165 | 46 | 4.0 |
| sag | rpcTimeout | 3 | pass_exhaustive |  | 51 | 19 | 3.6 |
| sag | rpcTimeout | 5 | pass_exhaustive |  | 423 | 28 | 5.1 |
| sag | saveFail | 0 | pass_exhaustive |  | 5 | 5 | 2.9 |
| sag | saveFail | 1 | pass_exhaustive |  | 8 | 8 | 2.9 |
| sag | saveFail | 2 | pass_exhaustive |  | 729 | 72 | 5.8 |
| sag | saveFail | 3 | pass_exhaustive |  | 474 | 45 | 5.3 |
| sag | saveFail | 5 | pass_exhaustive |  | 40 | 25 | 3.5 |
| sag | saveFail__netLoss | 1 | budget_stopped |  | 31149 | 24 | 90.2 |
| sag | saveFail__netLoss | 2 | budget_stopped |  | 22646 | 20 | 90.2 |
| sag | saveFail__netLoss | 3 | budget_stopped |  | 21128 | 11 | 90.2 |
| sag | saveFail__sjCrash | 1 | violation | S2F | 1028 | 16 | 5.7 |
| sag | saveFail__sjCrash | 2 | budget_stopped |  | 55115 | 46 | 90.2 |
| sag | saveFail__sjCrash | 3 | budget_stopped |  | 62906 | 25 | 90.2 |
| sag | sjCrash | 0 | pass_exhaustive |  | 5 | 5 | 2.9 |
| sag | sjCrash | 1 | violation | S2F | 1065 | 16 | 5.5 |
| sag | sjCrash | 2 | budget_stopped |  | 53005 | 47 | 90.3 |
| sag | sjCrash | 3 | pass_exhaustive |  | 31671 | 13 | 47.7 |
| sag | sjCrash | 5 | pass_exhaustive |  | 17895 | 12 | 29.2 |
| sag | spCrash | 0 | pass_exhaustive |  | 35 | 9 | 3.2 |
| sag | spCrash | 1 | violation | I_Q | 92 | 7 | 3.3 |
| sag | spCrash | 2 | violation | I_Q | 139 | 12 | 4.7 |
| sag | spCrash | 3 | violation | I_Q | 205 | 18 | 5.7 |
| sag | spCrash | 5 | violation | I_Q | 238 | 13 | 6.1 |
| sag | spShutdown | 0 | violation | I_Q | 40 | 7 | 3.2 |
| sag | spShutdown | 1 | violation_sim | I_Q | 69720 | 23 | 90.3 |
| sag | spShutdown | 2 | violation | I_Q | 3352 | 18 | 10.0 |
| sag | spShutdown | 3 | violation | I_Q | 4743 | 17 | 14.5 |
| sag | spShutdown | 5 | violation | I_Q | 5244 | 16 | 14.5 |
| sag | taskTimeout | 0 | pass_exhaustive |  | 5 | 5 | 2.9 |
| sag | taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.0 |
| sag | taskTimeout | 2 | budget_stopped |  | 30798 | 26 | 90.2 |
| sag | taskTimeout | 3 | budget_stopped |  | 19557 | 24 | 90.3 |
| sag | taskTimeout | 5 | pass_exhaustive |  | 2348 | 12 | 8.9 |
| sampling | abort | 0 | budget_stopped |  | 16984 | 28 | 90.2 |
| sampling | abort | 1 | budget_stopped |  | 17471 | 18 | 90.3 |
| sampling | abort | 2 | budget_stopped |  | 15242 | 12 | 90.3 |
| sampling | abort | 3 | budget_stopped |  | 9439 | 15 | 90.2 |
| sampling | abort | 5 | budget_stopped |  | 9995 | 10 | 90.3 |
| sampling | cjCrash | 0 | pass_exhaustive |  | 9 | 7 | 2.9 |
| sampling | cjCrash | 1 | violation_sim | S2F | 35271 | 18 | 90.2 |
| sampling | cjCrash | 2 | budget_stopped |  | 24801 | 15 | 90.2 |
| sampling | cjCrash | 3 | budget_stopped |  | 13912 | 21 | 90.2 |
| sampling | cjCrash | 5 | budget_stopped |  | 13444 | 11 | 90.3 |
| sampling | cpCrash | 0 | pass_exhaustive |  | 131 | 12 | 3.9 |
| sampling | cpCrash | 1 | budget_stopped |  | 40581 | 13 | 90.2 |
| sampling | cpCrash | 2 | violation | I_Q | 97 | 9 | 4.8 |
| sampling | cpCrash | 3 | budget_stopped |  | 6103 | 30 | 90.2 |
| sampling | cpCrash | 5 | budget_stopped |  | 5797 | 19 | 90.3 |
| sampling | deadClient | 0 | violation | S1Cleanup | 173 | 7 | 3.3 |
| sampling | deadClient | 1 | violation | S1Cleanup | 203 | 6 | 3.9 |
| sampling | deadClient | 2 | violation | S1Cleanup | 2298 | 8 | 12.6 |
| sampling | deadClient | 3 | violation | S1Cleanup | 471 | 6 | 7.4 |
| sampling | deadClient | 5 | violation | S1Cleanup | 630 | 6 | 8.6 |
| sampling | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.2 |
| sampling | deleteJob | 1 | budget_stopped |  | 35911 | 29 | 90.3 |
| sampling | deleteJob | 2 | budget_stopped |  | 16877 | 30 | 90.3 |
| sampling | deleteJob | 3 | pass_exhaustive |  | 1903 | 25 | 18.3 |
| sampling | deleteJob | 5 | budget_stopped |  | 10802 | 36 | 90.3 |
| sampling | netLoss | 0 | budget_stopped |  | 21110 | 23 | 90.3 |
| sampling | netLoss | 1 | budget_stopped |  | 24765 | 15 | 90.3 |
| sampling | netLoss | 2 | budget_stopped |  | 12828 | 9 | 90.2 |
| sampling | netLoss | 3 | budget_stopped |  | 13012 | 6 | 90.3 |
| sampling | netLoss | 5 | budget_stopped |  | 10536 | 6 | 90.3 |
| sampling | rpcTimeout | 0 | pass_exhaustive |  | 131 | 12 | 3.9 |
| sampling | rpcTimeout | 1 | budget_stopped |  | 37224 | 14 | 90.3 |
| sampling | rpcTimeout | 2 | budget_stopped |  | 10390 | 55 | 90.2 |
| sampling | rpcTimeout | 3 | pass_exhaustive |  | 1903 | 26 | 20.2 |
| sampling | rpcTimeout | 5 | budget_stopped |  | 7594 | 29 | 90.3 |
| sampling | sjCrash | 0 | pass_exhaustive |  | 9 | 7 | 2.8 |
| sampling | sjCrash | 1 | violation | S2F | 17440 | 17 | 41.0 |
| sampling | sjCrash | 2 | budget_stopped |  | 22537 | 13 | 90.2 |
| sampling | sjCrash | 3 | budget_stopped |  | 20214 | 16 | 90.2 |
| sampling | sjCrash | 5 | budget_stopped |  | 19865 | 11 | 90.3 |
| sampling | spCrash | 0 | pass_exhaustive |  | 131 | 12 | 3.8 |
| sampling | spCrash | 1 | violation | I_Q | 141 | 7 | 3.6 |
| sampling | spCrash | 2 | violation | I_Q | 13811 | 25 | 73.4 |
| sampling | spCrash | 3 | violation_sim | I_Q | 7899 | 33 | 90.2 |
| sampling | spCrash | 5 | violation_sim | I_Q | 7713 | 21 | 90.2 |
| sampling | spShutdown | 0 | violation | I_Q | 54 | 8 | 3.4 |
| sampling | spShutdown | 1 | violation_sim | I_Q | 71003 | 16 | 90.3 |
| sampling | spShutdown | 2 | violation_sim | I_Q | 19431 | 23 | 90.2 |
| sampling | spShutdown | 3 | violation_sim | I_Q | 11624 | 27 | 90.2 |
| sampling | spShutdown | 5 | violation_sim | I_Q | 12456 | 18 | 90.3 |
| sampling | taskTimeout | 0 | pass_exhaustive |  | 9 | 7 | 3.0 |
| sampling | taskTimeout | 1 | pass_exhaustive |  | 28 | 12 | 3.0 |
| sampling | taskTimeout | 2 | budget_stopped |  | 10253 | 13 | 90.3 |
| sampling | taskTimeout | 3 | budget_stopped |  | 7278 | 12 | 90.2 |
| sampling | taskTimeout | 5 | budget_stopped |  | 7666 | 9 | 90.3 |
| swarm | abort | 0 | budget_stopped |  | 10529 | 27 | 90.2 |
| swarm | abort | 1 | budget_stopped |  | 11493 | 18 | 90.2 |
| swarm | abort | 2 | budget_stopped |  | 9957 | 9 | 90.3 |
| swarm | abort | 3 | budget_stopped |  | 6370 | 12 | 90.3 |
| swarm | abort | 4 | budget_stopped |  | 4332 | 8 | 90.3 |
| swarm | abort | 5 | budget_stopped |  | 4586 | 11 | 90.2 |
| swarm | busyReplace | 0 | pass_exhaustive |  | 9 | 7 | 3.7 |
| swarm | busyReplace | 1 | budget_stopped |  | 9200 | 24 | 90.3 |
| swarm | busyReplace | 2 | budget_stopped |  | 7395 | 11 | 90.2 |
| swarm | busyReplace | 3 | budget_stopped |  | 5298 | 15 | 90.2 |
| swarm | busyReplace | 4 | pass_exhaustive |  | 960 | 5 | 33.6 |
| swarm | busyReplace | 5 | budget_stopped |  | 3494 | 16 | 90.2 |
| swarm | busyReplace__abort | 1 | budget_stopped |  | 11812 | 18 | 90.2 |
| swarm | busyReplace__abort | 2 | budget_stopped |  | 9607 | 9 | 90.3 |
| swarm | busyReplace__abort | 3 | budget_stopped |  | 7056 | 10 | 90.3 |
| swarm | busyReplace__cjCrash | 1 | violation_sim | S2F | 26663 | 16 | 90.2 |
| swarm | busyReplace__cjCrash | 2 | budget_stopped |  | 15708 | 9 | 90.3 |
| swarm | busyReplace__cjCrash | 3 | budget_stopped |  | 10411 | 9 | 90.2 |
| swarm | busyReplace__deadClient | 1 | violation | S1Cleanup | 180 | 6 | 3.7 |
| swarm | busyReplace__deadClient | 2 | violation | S1Cleanup | 5411 | 5 | 32.8 |
| swarm | busyReplace__deadClient | 3 | violation | S1Cleanup | 801 | 9 | 11.8 |
| swarm | busyReplace__deleteJob | 1 | budget_stopped |  | 11241 | 20 | 90.2 |
| swarm | busyReplace__deleteJob | 2 | budget_stopped |  | 8000 | 11 | 90.2 |
| swarm | busyReplace__deleteJob | 3 | budget_stopped |  | 5250 | 15 | 90.2 |
| swarm | busyReplace__gatherTimeout | 1 | budget_stopped |  | 8993 | 24 | 90.3 |
| swarm | busyReplace__gatherTimeout | 2 | budget_stopped |  | 7183 | 11 | 90.3 |
| swarm | busyReplace__gatherTimeout | 3 | budget_stopped |  | 5238 | 15 | 90.2 |
| swarm | busyReplace__netLoss | 1 | budget_stopped |  | 15992 | 15 | 90.2 |
| swarm | busyReplace__netLoss | 2 | budget_stopped |  | 10148 | 7 | 90.2 |
| swarm | busyReplace__netLoss | 3 | budget_stopped |  | 7682 | 7 | 90.3 |
| swarm | busyReplace__rpcTimeout | 1 | budget_stopped |  | 23880 | 14 | 90.2 |
| swarm | busyReplace__rpcTimeout | 2 | budget_stopped |  | 6848 | 11 | 90.2 |
| swarm | busyReplace__rpcTimeout | 3 | budget_stopped |  | 5515 | 15 | 90.3 |
| swarm | busyReplace__sjCrash | 1 | violation | S2F | 12995 | 16 | 43.8 |
| swarm | busyReplace__sjCrash | 2 | budget_stopped |  | 13372 | 10 | 90.3 |
| swarm | busyReplace__sjCrash | 3 | budget_stopped |  | 8072 | 15 | 90.2 |
| swarm | busyReplace__spCrash | 1 | violation | I_Q | 234 | 8 | 4.4 |
| swarm | busyReplace__spCrash | 2 | violation_sim | I_Q | 11589 | 9 | 90.3 |
| swarm | busyReplace__spCrash | 3 | violation_sim | I_Q | 6186 | 14 | 90.2 |
| swarm | busyReplace__spShutdown | 1 | violation_sim | I_Q | 24241 | 13 | 90.2 |
| swarm | busyReplace__spShutdown | 2 | violation_sim | I_Q | 12353 | 9 | 90.3 |
| swarm | busyReplace__spShutdown | 3 | violation_sim | I_Q | 7061 | 13 | 90.2 |
| swarm | busyReplace__taskTimeout | 1 | budget_stopped |  | 9400 | 24 | 90.2 |
| swarm | busyReplace__taskTimeout | 2 | budget_stopped |  | 7643 | 9 | 90.2 |
| swarm | busyReplace__taskTimeout | 3 | budget_stopped |  | 5822 | 9 | 90.3 |
| swarm | cjCrash | 0 | pass_exhaustive |  | 9 | 7 | 3.1 |
| swarm | cjCrash | 1 | violation_sim | S2F | 25969 | 18 | 90.3 |
| swarm | cjCrash | 2 | budget_stopped |  | 16402 | 14 | 90.2 |
| swarm | cjCrash | 3 | budget_stopped |  | 9441 | 15 | 90.2 |
| swarm | cjCrash | 4 | budget_stopped |  | 7633 | 19 | 90.2 |
| swarm | cjCrash | 5 | budget_stopped |  | 5295 | 11 | 90.3 |
| swarm | cpCrash | 0 | pass_exhaustive |  | 131 | 12 | 3.3 |
| swarm | cpCrash | 1 | budget_stopped |  | 30713 | 13 | 90.2 |
| swarm | cpCrash | 2 | violation_sim | I_Q | 12096 | 15 | 90.3 |
| swarm | cpCrash | 3 | violation_sim | I_Q | 5774 | 26 | 90.2 |
| swarm | cpCrash | 4 | violation | I_Q | 373 | 7 | 15.4 |
| swarm | cpCrash | 5 | budget_stopped |  | 2305 | 14 | 90.3 |
| swarm | deadClient | 0 | violation | S1Cleanup | 179 | 7 | 3.7 |
| swarm | deadClient | 1 | violation | S1Cleanup | 203 | 6 | 4.0 |
| swarm | deadClient | 2 | violation | S1Cleanup | 5317 | 5 | 27.9 |
| swarm | deadClient | 3 | violation | S1Cleanup | 838 | 9 | 12.0 |
| swarm | deadClient | 4 | violation | S1Cleanup | 4303 | 5 | 55.0 |
| swarm | deadClient | 5 | violation | S1Cleanup | 185 | 6 | 8.1 |
| swarm | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.4 |
| swarm | deleteJob | 1 | budget_stopped |  | 24628 | 25 | 90.3 |
| swarm | deleteJob | 2 | budget_stopped |  | 11987 | 15 | 90.2 |
| swarm | deleteJob | 3 | budget_stopped |  | 5268 | 26 | 90.3 |
| swarm | deleteJob | 4 | pass_exhaustive |  | 323 | 7 | 13.1 |
| swarm | deleteJob | 5 | pass_exhaustive |  | 5781 | 37 | 81.4 |
| swarm | gatherRace | 0 | pass_exhaustive |  | 9 | 7 | 3.0 |
| swarm | gatherRace | 1 | pass_exhaustive |  | 28 | 12 | 3.5 |
| swarm | gatherRace | 2 | budget_stopped |  | 5896 | 17 | 90.2 |
| swarm | gatherRace | 3 | budget_stopped |  | 4492 | 25 | 90.3 |
| swarm | gatherRace | 4 | pass_exhaustive |  | 133 | 6 | 9.3 |
| swarm | gatherRace | 5 | pass_exhaustive |  | 1405 | 14 | 20.8 |
| swarm | gatherRace__abort | 1 | budget_stopped |  | 11227 | 18 | 90.3 |
| swarm | gatherRace__abort | 2 | budget_stopped |  | 10717 | 9 | 90.3 |
| swarm | gatherRace__abort | 3 | budget_stopped |  | 5965 | 12 | 90.3 |
| swarm | gatherRace__gatherTimeout | 1 | pass_exhaustive |  | 28 | 12 | 3.2 |
| swarm | gatherRace__gatherTimeout | 2 | budget_stopped |  | 5785 | 17 | 90.2 |
| swarm | gatherRace__gatherTimeout | 3 | budget_stopped |  | 4602 | 26 | 90.2 |
| swarm | gatherRace__netLoss | 1 | budget_stopped |  | 16022 | 15 | 90.3 |
| swarm | gatherRace__netLoss | 2 | budget_stopped |  | 11039 | 7 | 90.2 |
| swarm | gatherRace__netLoss | 3 | violation_sim | S4Gather | 8568 | 6 | 90.3 |
| swarm | gatherRace__sjCrash | 1 | violation | S2F | 11886 | 16 | 40.8 |
| swarm | gatherRace__sjCrash | 2 | budget_stopped |  | 12088 | 10 | 90.3 |
| swarm | gatherRace__sjCrash | 3 | budget_stopped |  | 7980 | 15 | 90.2 |
| swarm | gatherRace__taskTimeout | 1 | pass_exhaustive |  | 28 | 12 | 3.0 |
| swarm | gatherRace__taskTimeout | 2 | budget_stopped |  | 7927 | 9 | 90.3 |
| swarm | gatherRace__taskTimeout | 3 | budget_stopped |  | 5972 | 9 | 90.3 |
| swarm | gatherTimeout | 0 | pass_exhaustive |  | 9 | 7 | 2.8 |
| swarm | gatherTimeout | 1 | pass_exhaustive |  | 28 | 12 | 2.9 |
| swarm | gatherTimeout | 2 | budget_stopped |  | 6258 | 18 | 90.2 |
| swarm | gatherTimeout | 3 | budget_stopped |  | 4257 | 24 | 90.2 |
| swarm | gatherTimeout | 4 | pass_exhaustive |  | 133 | 6 | 7.9 |
| swarm | gatherTimeout | 5 | pass_exhaustive |  | 1405 | 13 | 21.1 |
| swarm | learnFail | 0 | pass_exhaustive |  | 9 | 7 | 2.6 |
| swarm | learnFail | 1 | pass_exhaustive |  | 28 | 12 | 3.2 |
| swarm | learnFail | 2 | budget_stopped |  | 6129 | 18 | 90.2 |
| swarm | learnFail | 3 | budget_stopped |  | 4297 | 24 | 90.2 |
| swarm | learnFail | 4 | pass_exhaustive |  | 133 | 6 | 9.7 |
| swarm | learnFail | 5 | pass_exhaustive |  | 1405 | 13 | 21.0 |
| swarm | learnFail__abort | 1 | budget_stopped |  | 11409 | 18 | 90.3 |
| swarm | learnFail__abort | 2 | budget_stopped |  | 10112 | 9 | 90.2 |
| swarm | learnFail__abort | 3 | budget_stopped |  | 6106 | 12 | 90.2 |
| swarm | learnFail__gatherTimeout | 1 | pass_exhaustive |  | 28 | 12 | 3.1 |
| swarm | learnFail__gatherTimeout | 2 | budget_stopped |  | 6186 | 18 | 90.2 |
| swarm | learnFail__gatherTimeout | 3 | budget_stopped |  | 4329 | 24 | 90.3 |
| swarm | learnFail__netLoss | 1 | budget_stopped |  | 15840 | 15 | 90.3 |
| swarm | learnFail__netLoss | 2 | budget_stopped |  | 10283 | 7 | 90.2 |
| swarm | learnFail__netLoss | 3 | budget_stopped |  | 7915 | 7 | 90.3 |
| swarm | learnFail__sjCrash | 1 | violation | S2F | 11959 | 16 | 41.9 |
| swarm | learnFail__sjCrash | 2 | budget_stopped |  | 12239 | 10 | 90.3 |
| swarm | learnFail__sjCrash | 3 | budget_stopped |  | 7966 | 15 | 90.3 |
| swarm | learnFail__taskTimeout | 1 | pass_exhaustive |  | 28 | 12 | 2.8 |
| swarm | learnFail__taskTimeout | 2 | budget_stopped |  | 8841 | 9 | 90.3 |
| swarm | learnFail__taskTimeout | 3 | budget_stopped |  | 5806 | 9 | 90.2 |
| swarm | netLoss | 0 | budget_stopped |  | 14489 | 23 | 90.2 |
| swarm | netLoss | 1 | budget_stopped |  | 16530 | 15 | 90.3 |
| swarm | netLoss | 2 | budget_stopped |  | 10735 | 7 | 90.3 |
| swarm | netLoss | 3 | budget_stopped |  | 8697 | 6 | 90.2 |
| swarm | netLoss | 4 | budget_stopped |  | 10103 | 5 | 90.2 |
| swarm | netLoss | 5 | budget_stopped |  | 5459 | 5 | 90.2 |
| swarm | rpcTimeout | 0 | pass_exhaustive |  | 131 | 12 | 3.5 |
| swarm | rpcTimeout | 1 | budget_stopped |  | 27054 | 14 | 90.3 |
| swarm | rpcTimeout | 2 | budget_stopped |  | 12196 | 15 | 90.3 |
| swarm | rpcTimeout | 3 | budget_stopped |  | 5295 | 26 | 90.3 |
| swarm | rpcTimeout | 4 | pass_exhaustive |  | 323 | 7 | 13.5 |
| swarm | rpcTimeout | 5 | budget_stopped |  | 4242 | 25 | 90.3 |
| swarm | sjCrash | 0 | pass_exhaustive |  | 9 | 7 | 2.8 |
| swarm | sjCrash | 1 | violation | S2F | 12450 | 16 | 42.4 |
| swarm | sjCrash | 2 | budget_stopped |  | 12276 | 10 | 90.3 |
| swarm | sjCrash | 3 | budget_stopped |  | 7939 | 15 | 90.3 |
| swarm | sjCrash | 4 | budget_stopped |  | 9110 | 10 | 90.3 |
| swarm | sjCrash | 5 | budget_stopped |  | 6693 | 12 | 90.2 |
| swarm | spCrash | 0 | pass_exhaustive |  | 131 | 12 | 3.7 |
| swarm | spCrash | 1 | violation | I_Q | 129 | 7 | 4.1 |
| swarm | spCrash | 2 | violation_sim | I_Q | 12330 | 15 | 90.2 |
| swarm | spCrash | 3 | violation_sim | I_Q | 5794 | 27 | 90.2 |
| swarm | spCrash | 4 | violation | I_Q | 3485 | 29 | 72.9 |
| swarm | spCrash | 5 | violation_sim | I_Q | 3355 | 15 | 90.2 |
| swarm | spShutdown | 0 | violation | I_Q | 48 | 7 | 3.1 |
| swarm | spShutdown | 1 | violation_sim | I_Q | 52098 | 16 | 90.2 |
| swarm | spShutdown | 2 | budget_stopped |  | 11772 | 15 | 90.3 |
| swarm | spShutdown | 3 | violation_sim | I_Q | 5652 | 26 | 90.2 |
| swarm | spShutdown | 4 | violation_sim | I_Q | 4810 | 21 | 90.3 |
| swarm | spShutdown | 5 | violation_sim | I_Q | 5520 | 18 | 90.3 |
| swarm | swarmMsgFail | 0 | pass_exhaustive |  | 9 | 7 | 2.9 |
| swarm | swarmMsgFail | 1 | budget_stopped |  | 9019 | 24 | 90.2 |
| swarm | swarmMsgFail | 2 | budget_stopped |  | 7044 | 11 | 90.3 |
| swarm | swarmMsgFail | 3 | budget_stopped |  | 5455 | 15 | 90.2 |
| swarm | swarmMsgFail | 4 | pass_exhaustive |  | 960 | 5 | 34.8 |
| swarm | swarmMsgFail | 5 | budget_stopped |  | 3646 | 17 | 90.3 |
| swarm | swarmMsgFail__abort | 1 | budget_stopped |  | 11566 | 18 | 90.2 |
| swarm | swarmMsgFail__abort | 2 | budget_stopped |  | 9998 | 9 | 90.2 |
| swarm | swarmMsgFail__abort | 3 | budget_stopped |  | 7590 | 10 | 90.2 |
| swarm | swarmMsgFail__cjCrash | 1 | violation_sim | S2F | 25586 | 16 | 90.2 |
| swarm | swarmMsgFail__cjCrash | 2 | budget_stopped |  | 15363 | 9 | 90.3 |
| swarm | swarmMsgFail__cjCrash | 3 | budget_stopped |  | 9091 | 9 | 90.3 |
| swarm | swarmMsgFail__deadClient | 1 | violation | S1Cleanup | 185 | 7 | 3.4 |
| swarm | swarmMsgFail__deadClient | 2 | violation | S1Cleanup | 5263 | 5 | 30.7 |
| swarm | swarmMsgFail__deadClient | 3 | violation | S1Cleanup | 801 | 9 | 10.6 |
| swarm | swarmMsgFail__deleteJob | 1 | budget_stopped |  | 12256 | 20 | 90.3 |
| swarm | swarmMsgFail__deleteJob | 2 | budget_stopped |  | 7323 | 11 | 90.2 |
| swarm | swarmMsgFail__deleteJob | 3 | budget_stopped |  | 5448 | 15 | 90.3 |
| swarm | swarmMsgFail__gatherTimeout | 1 | budget_stopped |  | 8734 | 24 | 90.3 |
| swarm | swarmMsgFail__gatherTimeout | 2 | budget_stopped |  | 8207 | 11 | 90.3 |
| swarm | swarmMsgFail__gatherTimeout | 3 | budget_stopped |  | 5190 | 15 | 90.2 |
| swarm | swarmMsgFail__netLoss | 1 | budget_stopped |  | 17020 | 15 | 90.3 |
| swarm | swarmMsgFail__netLoss | 2 | budget_stopped |  | 10195 | 7 | 90.3 |
| swarm | swarmMsgFail__netLoss | 3 | budget_stopped |  | 8097 | 7 | 90.2 |
| swarm | swarmMsgFail__rpcTimeout | 1 | budget_stopped |  | 24321 | 14 | 90.3 |
| swarm | swarmMsgFail__rpcTimeout | 2 | budget_stopped |  | 7359 | 11 | 90.2 |
| swarm | swarmMsgFail__rpcTimeout | 3 | budget_stopped |  | 5364 | 15 | 90.2 |
| swarm | swarmMsgFail__sjCrash | 1 | violation | S2F | 12544 | 16 | 43.0 |
| swarm | swarmMsgFail__sjCrash | 2 | budget_stopped |  | 12285 | 10 | 90.3 |
| swarm | swarmMsgFail__sjCrash | 3 | budget_stopped |  | 7964 | 15 | 90.3 |
| swarm | swarmMsgFail__spCrash | 1 | violation | I_Q | 224 | 8 | 4.1 |
| swarm | swarmMsgFail__spCrash | 2 | violation_sim | I_Q | 11739 | 9 | 90.2 |
| swarm | swarmMsgFail__spCrash | 3 | violation_sim | I_Q | 6425 | 14 | 90.3 |
| swarm | swarmMsgFail__spShutdown | 1 | violation_sim | I_Q | 26544 | 14 | 90.2 |
| swarm | swarmMsgFail__spShutdown | 2 | violation_sim | I_Q | 12498 | 9 | 90.3 |
| swarm | swarmMsgFail__spShutdown | 3 | violation_sim | I_Q | 7198 | 14 | 90.2 |
| swarm | swarmMsgFail__taskTimeout | 1 | budget_stopped |  | 9437 | 24 | 90.2 |
| swarm | swarmMsgFail__taskTimeout | 2 | budget_stopped |  | 8368 | 9 | 90.3 |
| swarm | swarmMsgFail__taskTimeout | 3 | budget_stopped |  | 5913 | 9 | 90.3 |
| swarm | taskTimeout | 0 | pass_exhaustive |  | 9 | 7 | 3.0 |
| swarm | taskTimeout | 1 | pass_exhaustive |  | 28 | 12 | 3.2 |
| swarm | taskTimeout | 2 | budget_stopped |  | 8123 | 9 | 90.3 |
| swarm | taskTimeout | 3 | budget_stopped |  | 5826 | 9 | 90.3 |
| swarm | taskTimeout | 4 | budget_stopped |  | 4456 | 8 | 90.2 |
| swarm | taskTimeout | 5 | budget_stopped |  | 3165 | 10 | 90.3 |
| taskmode | abort | 0 | budget_stopped |  | 23918 | 37 | 90.3 |
| taskmode | abort | 1 | budget_stopped |  | 23533 | 30 | 90.2 |
| taskmode | abort | 2 | budget_stopped |  | 45585 | 18 | 90.3 |
| taskmode | abort | 3 | pass_exhaustive |  | 0 | 1 | 3.1 |
| taskmode | abort | 5 | budget_stopped |  | 32980 | 14 | 90.3 |
| taskmode | cjCrash | 0 | pass_exhaustive |  | 5 | 5 | 2.8 |
| taskmode | cjCrash | 1 | violation | S2F | 26402 | 16 | 28.9 |
| taskmode | cjCrash | 2 | budget_stopped |  | 53949 | 21 | 90.2 |
| taskmode | cjCrash | 3 | pass_exhaustive |  | 0 | 1 | 2.7 |
| taskmode | cjCrash | 5 | budget_stopped |  | 46174 | 16 | 90.3 |
| taskmode | cpCrash | 0 | pass_exhaustive |  | 35 | 9 | 2.9 |
| taskmode | cpCrash | 1 | violation | I_Q | 12995 | 12 | 19.9 |
| taskmode | cpCrash | 2 | violation | I_Q | 30 | 5 | 3.4 |
| taskmode | cpCrash | 3 | pass_exhaustive |  | 0 | 1 | 2.9 |
| taskmode | cpCrash | 5 | budget_stopped |  | 36244 | 23 | 90.3 |
| taskmode | deadClient | 0 | budget_stopped |  | 46981 | 27 | 90.3 |
| taskmode | deadClient | 1 | budget_stopped |  | 51209 | 22 | 90.3 |
| taskmode | deadClient | 2 | budget_stopped |  | 30349 | 18 | 90.3 |
| taskmode | deadClient | 3 | pass_exhaustive |  | 0 | 1 | 3.0 |
| taskmode | deadClient | 5 | budget_stopped |  | 38706 | 20 | 90.3 |
| taskmode | deleteJob | 0 | violation | S1Sched | 6 | 3 | 3.3 |
| taskmode | deleteJob | 1 | pass_exhaustive |  | 10289 | 25 | 28.2 |
| taskmode | deleteJob | 2 | pass_exhaustive |  | 1705 | 22 | 10.3 |
| taskmode | deleteJob | 3 | pass_exhaustive |  | 0 | 1 | 3.4 |
| taskmode | deleteJob | 5 | pass_exhaustive |  | 11007 | 26 | 28.8 |
| taskmode | netLoss | 0 | budget_stopped |  | 30467 | 31 | 90.3 |
| taskmode | netLoss | 1 | budget_stopped |  | 28192 | 23 | 90.2 |
| taskmode | netLoss | 2 | budget_stopped |  | 23312 | 18 | 90.2 |
| taskmode | netLoss | 3 | pass_exhaustive |  | 0 | 1 | 2.6 |
| taskmode | netLoss | 5 | budget_stopped |  | 24683 | 9 | 90.2 |
| taskmode | rpcTimeout | 0 | pass_exhaustive |  | 35 | 9 | 3.6 |
| taskmode | rpcTimeout | 1 | budget_stopped |  | 51845 | 21 | 90.2 |
| taskmode | rpcTimeout | 2 | pass_exhaustive |  | 3075 | 22 | 13.4 |
| taskmode | rpcTimeout | 3 | pass_exhaustive |  | 0 | 1 | 3.0 |
| taskmode | rpcTimeout | 5 | budget_stopped |  | 37213 | 24 | 90.3 |
| taskmode | settleTimeout | 0 | pass_exhaustive |  | 5 | 5 | 2.8 |
| taskmode | settleTimeout | 1 | violation | S2F | 38588 | 24 | 55.4 |
| taskmode | settleTimeout | 2 | pass_exhaustive |  | 20103 | 18 | 27.1 |
| taskmode | settleTimeout | 3 | pass_exhaustive |  | 0 | 1 | 2.7 |
| taskmode | settleTimeout | 5 | pass_exhaustive |  | 46 | 18 | 3.2 |
| taskmode | settleTimeout__abort | 1 | budget_stopped |  | 26417 | 28 | 90.2 |
| taskmode | settleTimeout__abort | 2 | budget_stopped |  | 44089 | 18 | 90.3 |
| taskmode | settleTimeout__abort | 3 | pass_exhaustive |  | 0 | 1 | 3.1 |
| taskmode | settleTimeout__cjCrash | 1 | violation | S2F | 35650 | 16 | 38.1 |
| taskmode | settleTimeout__cjCrash | 2 | budget_stopped |  | 55576 | 21 | 90.3 |
| taskmode | settleTimeout__cjCrash | 3 | pass_exhaustive |  | 0 | 1 | 2.9 |
| taskmode | settleTimeout__cpCrash | 1 | violation | I_Q | 14550 | 12 | 20.5 |
| taskmode | settleTimeout__cpCrash | 2 | violation | I_Q | 32 | 5 | 3.5 |
| taskmode | settleTimeout__cpCrash | 3 | pass_exhaustive |  | 0 | 1 | 2.7 |
| taskmode | settleTimeout__netLoss | 1 | budget_stopped |  | 30920 | 23 | 90.2 |
| taskmode | settleTimeout__netLoss | 2 | budget_stopped |  | 25001 | 17 | 90.3 |
| taskmode | settleTimeout__netLoss | 3 | pass_exhaustive |  | 0 | 1 | 3.1 |
| taskmode | settleTimeout__rpcTimeout | 1 | budget_stopped |  | 49133 | 20 | 90.3 |
| taskmode | settleTimeout__rpcTimeout | 2 | budget_stopped |  | 27431 | 28 | 90.2 |
| taskmode | settleTimeout__rpcTimeout | 3 | pass_exhaustive |  | 0 | 1 | 3.1 |
| taskmode | settleTimeout__taskDeadline | 1 | violation | S2F | 53874 | 42 | 73.9 |
| taskmode | settleTimeout__taskDeadline | 2 | pass_exhaustive |  | 28475 | 18 | 34.0 |
| taskmode | settleTimeout__taskDeadline | 3 | pass_exhaustive |  | 0 | 1 | 3.0 |
| taskmode | settleTimeout__taskTimeout | 1 | violation_sim | S2F | 54675 | 26 | 90.2 |
| taskmode | settleTimeout__taskTimeout | 2 | budget_stopped |  | 29136 | 19 | 90.3 |
| taskmode | settleTimeout__taskTimeout | 3 | pass_exhaustive |  | 0 | 1 | 2.9 |
| taskmode | sjCrash | 0 | pass_exhaustive |  | 5 | 5 | 3.0 |
| taskmode | sjCrash | 1 | violation | S2F | 1040 | 16 | 6.0 |
| taskmode | sjCrash | 2 | budget_stopped |  | 54379 | 26 | 90.2 |
| taskmode | sjCrash | 3 | pass_exhaustive |  | 0 | 1 | 2.8 |
| taskmode | sjCrash | 5 | budget_stopped |  | 44221 | 16 | 90.2 |
| taskmode | spCrash | 0 | pass_exhaustive |  | 35 | 9 | 2.9 |
| taskmode | spCrash | 1 | violation | I_Q | 86 | 7 | 3.4 |
| taskmode | spCrash | 2 | violation | I_Q | 602 | 14 | 6.4 |
| taskmode | spCrash | 3 | pass_exhaustive |  | 0 | 1 | 2.9 |
| taskmode | spCrash | 5 | violation | I_Q | 3824 | 14 | 12.3 |
| taskmode | spShutdown | 0 | violation | I_Q | 40 | 7 | 3.3 |
| taskmode | spShutdown | 1 | violation_sim | I_Q | 60802 | 23 | 90.3 |
| taskmode | spShutdown | 2 | violation | I_Q | 11808 | 16 | 20.9 |
| taskmode | spShutdown | 3 | pass_exhaustive |  | 0 | 1 | 3.2 |
| taskmode | spShutdown | 5 | violation | I_Q | 6093 | 16 | 14.8 |
| taskmode | taskDeadline | 0 | pass_exhaustive |  | 5 | 5 | 3.0 |
| taskmode | taskDeadline | 1 | violation | S2F | 25837 | 25 | 38.2 |
| taskmode | taskDeadline | 2 | pass_exhaustive |  | 11087 | 18 | 19.3 |
| taskmode | taskDeadline | 3 | pass_exhaustive |  | 0 | 1 | 2.8 |
| taskmode | taskDeadline | 5 | pass_exhaustive |  | 46 | 18 | 3.4 |
| taskmode | taskStageFail | 0 | pass_exhaustive |  | 5 | 5 | 2.6 |
| taskmode | taskStageFail | 1 | violation | S2F | 24984 | 25 | 36.4 |
| taskmode | taskStageFail | 2 | pass_exhaustive |  | 11087 | 19 | 19.6 |
| taskmode | taskStageFail | 3 | pass_exhaustive |  | 0 | 1 | 2.9 |
| taskmode | taskStageFail | 5 | pass_exhaustive |  | 46 | 18 | 3.2 |
| taskmode | taskStageFail__abort | 1 | budget_stopped |  | 25897 | 28 | 90.2 |
| taskmode | taskStageFail__abort | 2 | budget_stopped |  | 42445 | 18 | 90.3 |
| taskmode | taskStageFail__abort | 3 | pass_exhaustive |  | 0 | 1 | 3.0 |
| taskmode | taskStageFail__cjCrash | 1 | violation | S2F | 26830 | 16 | 30.2 |
| taskmode | taskStageFail__cjCrash | 2 | budget_stopped |  | 53769 | 21 | 90.3 |
| taskmode | taskStageFail__cjCrash | 3 | pass_exhaustive |  | 0 | 1 | 2.7 |
| taskmode | taskStageFail__cpCrash | 1 | violation | I_Q | 14599 | 12 | 22.5 |
| taskmode | taskStageFail__cpCrash | 2 | violation | I_Q | 35 | 5 | 3.5 |
| taskmode | taskStageFail__cpCrash | 3 | pass_exhaustive |  | 0 | 1 | 2.8 |
| taskmode | taskStageFail__netLoss | 1 | budget_stopped |  | 29194 | 22 | 90.3 |
| taskmode | taskStageFail__netLoss | 2 | budget_stopped |  | 24499 | 17 | 90.2 |
| taskmode | taskStageFail__netLoss | 3 | pass_exhaustive |  | 0 | 1 | 2.8 |
| taskmode | taskStageFail__rpcTimeout | 1 | budget_stopped |  | 47173 | 20 | 90.3 |
| taskmode | taskStageFail__rpcTimeout | 2 | budget_stopped |  | 26658 | 29 | 90.2 |
| taskmode | taskStageFail__rpcTimeout | 3 | pass_exhaustive |  | 0 | 1 | 2.8 |
| taskmode | taskStageFail__taskDeadline | 1 | violation | S2F | 40327 | 24 | 55.7 |
| taskmode | taskStageFail__taskDeadline | 2 | pass_exhaustive |  | 19459 | 18 | 27.9 |
| taskmode | taskStageFail__taskDeadline | 3 | pass_exhaustive |  | 0 | 1 | 2.9 |
| taskmode | taskStageFail__taskTimeout | 1 | violation_sim | S2F | 54002 | 26 | 90.3 |
| taskmode | taskStageFail__taskTimeout | 2 | budget_stopped |  | 29249 | 20 | 90.2 |
| taskmode | taskStageFail__taskTimeout | 3 | pass_exhaustive |  | 0 | 1 | 3.1 |
| taskmode | taskTimeout | 0 | pass_exhaustive |  | 5 | 5 | 3.0 |
| taskmode | taskTimeout | 1 | pass_exhaustive |  | 8 | 8 | 3.1 |
| taskmode | taskTimeout | 2 | budget_stopped |  | 32387 | 20 | 90.3 |
| taskmode | taskTimeout | 3 | pass_exhaustive |  | 0 | 1 | 3.2 |
| taskmode | taskTimeout | 5 | budget_stopped |  | 26078 | 16 | 90.2 |
| taskmode | workerCrash | 0 | pass_exhaustive |  | 5 | 5 | 3.1 |
| taskmode | workerCrash | 1 | violation | S2F | 16816 | 25 | 27.3 |
| taskmode | workerCrash | 2 | pass_exhaustive |  | 7551 | 20 | 16.0 |
| taskmode | workerCrash | 3 | pass_exhaustive |  | 0 | 1 | 3.0 |
| taskmode | workerCrash | 5 | pass_exhaustive |  | 46 | 18 | 3.3 |
| taskmode | workerCrash__abort | 1 | budget_stopped |  | 26942 | 29 | 90.3 |
| taskmode | workerCrash__abort | 2 | budget_stopped |  | 43855 | 18 | 90.3 |
| taskmode | workerCrash__abort | 3 | pass_exhaustive |  | 0 | 1 | 2.8 |
| taskmode | workerCrash__cjCrash | 1 | violation | S2F | 26705 | 15 | 34.0 |
| taskmode | workerCrash__cjCrash | 2 | budget_stopped |  | 51956 | 21 | 90.3 |
| taskmode | workerCrash__cjCrash | 3 | pass_exhaustive |  | 0 | 1 | 3.0 |
| taskmode | workerCrash__cpCrash | 1 | violation | I_Q | 14525 | 12 | 21.0 |
| taskmode | workerCrash__cpCrash | 2 | violation | I_Q | 32 | 5 | 3.6 |
| taskmode | workerCrash__cpCrash | 3 | pass_exhaustive |  | 0 | 1 | 3.0 |
| taskmode | workerCrash__netLoss | 1 | budget_stopped |  | 29757 | 24 | 90.3 |
| taskmode | workerCrash__netLoss | 2 | budget_stopped |  | 23372 | 18 | 90.3 |
| taskmode | workerCrash__netLoss | 3 | pass_exhaustive |  | 0 | 1 | 2.9 |
| taskmode | workerCrash__rpcTimeout | 1 | budget_stopped |  | 45149 | 20 | 90.3 |
| taskmode | workerCrash__rpcTimeout | 2 | budget_stopped |  | 29962 | 29 | 90.3 |
| taskmode | workerCrash__rpcTimeout | 3 | pass_exhaustive |  | 0 | 1 | 2.9 |
| taskmode | workerCrash__taskDeadline | 1 | violation | S2F | 30437 | 24 | 48.3 |
| taskmode | workerCrash__taskDeadline | 2 | pass_exhaustive |  | 17855 | 18 | 26.3 |
| taskmode | workerCrash__taskDeadline | 3 | pass_exhaustive |  | 0 | 1 | 3.0 |
| taskmode | workerCrash__taskTimeout | 1 | violation | S2F | 59382 | 26 | 68.4 |
| taskmode | workerCrash__taskTimeout | 2 | budget_stopped |  | 31379 | 20 | 90.3 |
| taskmode | workerCrash__taskTimeout | 3 | pass_exhaustive |  | 0 | 1 | 2.9 |
| taskmode | workerFail | 0 | pass_exhaustive |  | 5 | 5 | 2.9 |
| taskmode | workerFail | 1 | violation | S2F | 26573 | 25 | 36.9 |
| taskmode | workerFail | 2 | pass_exhaustive |  | 8523 | 20 | 16.9 |
| taskmode | workerFail | 3 | pass_exhaustive |  | 0 | 1 | 2.7 |
| taskmode | workerFail | 5 | pass_exhaustive |  | 46 | 18 | 3.0 |
| taskmode | workerFail__abort | 1 | budget_stopped |  | 24839 | 29 | 90.2 |
| taskmode | workerFail__abort | 2 | budget_stopped |  | 47288 | 18 | 90.3 |
| taskmode | workerFail__abort | 3 | pass_exhaustive |  | 0 | 1 | 3.2 |
| taskmode | workerFail__cjCrash | 1 | violation | S2F | 26402 | 16 | 31.2 |
| taskmode | workerFail__cjCrash | 2 | budget_stopped |  | 54608 | 21 | 90.3 |
| taskmode | workerFail__cjCrash | 3 | pass_exhaustive |  | 0 | 1 | 3.0 |
| taskmode | workerFail__cpCrash | 1 | violation | I_Q | 14532 | 12 | 21.8 |
| taskmode | workerFail__cpCrash | 2 | violation | I_Q | 35 | 5 | 3.9 |
| taskmode | workerFail__cpCrash | 3 | pass_exhaustive |  | 0 | 1 | 3.0 |
| taskmode | workerFail__netLoss | 1 | budget_stopped |  | 29776 | 24 | 90.2 |
| taskmode | workerFail__netLoss | 2 | budget_stopped |  | 23687 | 18 | 90.3 |
| taskmode | workerFail__netLoss | 3 | pass_exhaustive |  | 0 | 1 | 3.0 |
| taskmode | workerFail__rpcTimeout | 1 | budget_stopped |  | 46589 | 20 | 90.3 |
| taskmode | workerFail__rpcTimeout | 2 | budget_stopped |  | 24518 | 31 | 90.3 |
| taskmode | workerFail__rpcTimeout | 3 | pass_exhaustive |  | 0 | 1 | 2.8 |
| taskmode | workerFail__taskDeadline | 1 | violation | S2F | 38018 | 24 | 53.7 |
| taskmode | workerFail__taskDeadline | 2 | pass_exhaustive |  | 18827 | 19 | 26.1 |
| taskmode | workerFail__taskDeadline | 3 | pass_exhaustive |  | 0 | 1 | 2.5 |
| taskmode | workerFail__taskTimeout | 1 | violation | S2F | 59162 | 26 | 68.0 |
| taskmode | workerFail__taskTimeout | 2 | budget_stopped |  | 31131 | 20 | 90.3 |
| taskmode | workerFail__taskTimeout | 3 | pass_exhaustive |  | 0 | 1 | 2.8 |
