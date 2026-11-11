# Sweep cal1

812 cells

| config | point | phase | result | violated | distinct | depth | s |
|---|---|---:|---|---|---:|---:|---:|
| attach | abort | 0 | budget_stopped |  | 308354 |  | 240.5 |
| attach | abort | 2 | budget_stopped |  | 323163 |  | 240.5 |
| attach | abort | 5 | budget_stopped |  | 183364 |  | 240.5 |
| attach | cjCrash | 0 | violation | S2TerminalFinal | 30732 | 23 | 18.0 |
| attach | cjCrash | 2 | budget_stopped |  | 295502 |  | 240.4 |
| attach | cjCrash | 5 | budget_stopped |  | 187766 |  | 240.4 |
| attach | cpCrash | 0 | violation | Q1Terminal | 22145 | 20 | 16.1 |
| attach | cpCrash | 2 | violation | Q1Terminal | 9 | 3 | 2.7 |
| attach | cpCrash | 5 | pass_exhaustive |  | 41865 | 32 | 57.0 |
| attach | deadClient | 0 | violation | S2TerminalFinal | 84143 | 30 | 69.8 |
| attach | deadClient | 2 | budget_stopped |  | 198382 |  | 240.6 |
| attach | deadClient | 5 | pass_exhaustive |  | 22437 | 32 | 37.2 |
| attach | deleteJob | 0 | violation | S1ThreadsAlive | 13 | 6 | 2.7 |
| attach | deleteJob | 2 | budget_stopped |  | 100923 |  | 240.4 |
| attach | deleteJob | 5 | pass_exhaustive |  | 3681 | 29 | 11.1 |
| attach | netLoss | 0 | violation | S2TerminalFinal | 146834 | 41 | 170.4 |
| attach | netLoss | 2 | budget_stopped |  | 156760 |  | 240.5 |
| attach | netLoss | 5 | budget_stopped |  | 114944 |  | 240.4 |
| attach | resultWaitTimeout | 0 | violation | S2TerminalFinal | 180645 | 41 | 223.4 |
| attach | resultWaitTimeout | 2 | budget_stopped |  | 161958 |  | 240.4 |
| attach | resultWaitTimeout | 5 | pass_exhaustive |  | 6627 | 30 | 14.5 |
| attach | rpcTimeout | 0 | budget_stopped |  | 322389 |  | 240.5 |
| attach | rpcTimeout | 2 | budget_stopped |  | 98431 |  | 240.5 |
| attach | rpcTimeout | 5 | pass_exhaustive |  | 6861 | 30 | 13.6 |
| attach | sjCrash | 0 | violation | S2TerminalFinal | 1838 | 20 | 5.1 |
| attach | sjCrash | 2 | budget_stopped |  | 218361 |  | 240.4 |
| attach | sjCrash | 5 | pass_exhaustive |  | 241131 | 31 | 234.4 |
| attach | spCrash | 0 | violation | Q1Terminal | 150 | 13 | 2.8 |
| attach | spCrash | 2 | violation | Q1Terminal | 541 | 12 | 4.7 |
| attach | spCrash | 5 | violation | Q1Terminal | 642 | 12 | 5.8 |
| attach | spShutdown | 0 | violation | Q1Terminal | 58 | 9 | 2.8 |
| attach | spShutdown | 2 | violation | Q1Terminal | 27746 | 16 | 21.0 |
| attach | spShutdown | 5 | violation | Q1Terminal | 49660 | 16 | 59.5 |
| attach | taskTimeout | 0 | violation | S2TerminalFinal | 15309 | 30 | 18.3 |
| attach | taskTimeout | 2 | budget_stopped |  | 254165 |  | 240.5 |
| attach | taskTimeout | 5 | pass_exhaustive |  | 14724 | 31 | 26.9 |
| attach | tpAttachLate | 0 | violation | S2TerminalFinal | 28318 | 44 | 39.9 |
| attach | tpAttachLate | 2 | budget_stopped |  | 236183 |  | 240.5 |
| attach | tpAttachLate | 5 | pass_exhaustive |  | 3681 | 29 | 11.0 |
| attach | tpCrash | 0 | violation | Q1Terminal | 3880 | 28 | 8.5 |
| attach | tpCrash | 2 | violation | Q1Terminal | 130 | 11 | 4.1 |
| attach | tpCrash | 5 | pass_exhaustive |  | 18405 | 33 | 31.2 |
| attach | tpReplyLost | 0 | violation | S6AckMeansDone | 1272 | 26 | 6.2 |
| attach | tpReplyLost | 2 | violation | S6AckMeansDone | 80 | 11 | 4.0 |
| attach | tpReplyLost | 5 | pass_exhaustive |  | 3681 | 29 | 10.9 |
| attach | tpSilent | 0 | violation | Q1Terminal | 4036 | 28 | 9.2 |
| attach | tpSilent | 2 | violation | Q1Terminal | 156 | 11 | 4.4 |
| attach | tpSilent | 5 | pass_exhaustive |  | 18405 | 33 | 32.6 |
| attach | trainerError | 0 | violation | Q1Terminal | 1551 | 28 | 6.8 |
| attach | trainerError | 2 | violation | Q1Terminal | 61 | 12 | 3.7 |
| attach | trainerError | 5 | pass_exhaustive |  | 3681 | 29 | 10.0 |
| cse | abort | 0 | violation | S1ThreadsAlive | 83224 | 31 | 146.2 |
| cse | abort | 2 | violation | S1ThreadsAlive | 549 | 9 | 5.2 |
| cse | abort | 5 | violation | S1ThreadsAlive |  |  | 2.5 |
| cse | cjCrash | 0 | violation | S1ThreadsAlive | 4475 | 20 | 7.7 |
| cse | cjCrash | 2 | violation | S1ThreadsAlive | 58 | 5 | 3.7 |
| cse | cjCrash | 5 | violation | S1ThreadsAlive |  |  | 2.8 |
| cse | cpCrash | 0 | violation | S1ThreadsAlive | 38137 | 20 | 37.3 |
| cse | cpCrash | 2 | violation | S1ThreadsAlive | 35 | 5 | 4.0 |
| cse | cpCrash | 5 | violation | S1ThreadsAlive |  |  | 2.7 |
| cse | deadClient | 0 | violation | S1ThreadsAlive | 535 | 15 | 4.5 |
| cse | deadClient | 2 | violation | S1ThreadsAlive | 14 | 4 | 3.1 |
| cse | deadClient | 5 | violation | S1ThreadsAlive |  |  | 2.7 |
| cse | deleteJob | 0 | violation | S1ThreadsAlive | 14 | 5 | 2.7 |
| cse | deleteJob | 2 | pass_exhaustive |  | 3299 | 46 | 26.9 |
| cse | deleteJob | 5 | violation | S1ThreadsAlive |  |  | 2.7 |
| cse | netLoss | 0 | budget_stopped |  | 99990 |  | 240.5 |
| cse | netLoss | 2 | budget_stopped |  | 55107 |  | 240.5 |
| cse | netLoss | 5 | violation | S1ThreadsAlive |  |  | 2.9 |
| cse | rpcTimeout | 0 | budget_stopped |  | 165096 |  | 240.4 |
| cse | rpcTimeout | 2 | pass_exhaustive |  | 3299 | 46 | 26.2 |
| cse | rpcTimeout | 5 | violation | S1ThreadsAlive |  |  | 2.6 |
| cse | sjCrash | 0 | violation | S2TerminalFinal | 33673 | 26 | 38.4 |
| cse | sjCrash | 2 | budget_stopped |  | 115245 |  | 240.5 |
| cse | sjCrash | 5 | violation | S1ThreadsAlive |  |  | 2.6 |
| cse | spCrash | 0 | violation | Q1Terminal | 431 | 15 | 4.2 |
| cse | spCrash | 2 | violation | Q1Terminal | 18362 | 21 | 57.0 |
| cse | spCrash | 5 | violation | S1ThreadsAlive |  |  | 2.7 |
| cse | spShutdown | 0 | violation | Q1Terminal | 66 | 8 | 3.0 |
| cse | spShutdown | 2 | violation | S1ThreadsAlive | 671 | 8 | 5.5 |
| cse | spShutdown | 5 | violation | S1ThreadsAlive |  |  | 2.7 |
| cse | taskTimeout | 0 | violation | S1ThreadsAlive | 222 | 17 | 3.4 |
| cse | taskTimeout | 2 | violation | S1ThreadsAlive | 12 | 4 | 3.1 |
| cse | taskTimeout | 5 | violation | S1ThreadsAlive |  |  | 2.8 |
| cseserver | abort | 0 | violation | S1ThreadsAlive | 84619 | 31 | 150.9 |
| cseserver | abort | 2 | violation | S1ThreadsAlive | 540 | 9 | 5.9 |
| cseserver | abort | 5 | violation | S1ThreadsAlive |  |  | 2.6 |
| cseserver | cbFail | 0 | budget_stopped |  | 69394 |  | 240.4 |
| cseserver | cbFail | 2 | violation | S1ThreadsAlive | 752 | 32 | 9.1 |
| cseserver | cbFail | 5 | violation | S1ThreadsAlive |  |  | 2.7 |
| cseserver | cjCrash | 0 | violation | S1ThreadsAlive | 4265 | 20 | 8.3 |
| cseserver | cjCrash | 2 | violation | S1ThreadsAlive | 58 | 5 | 4.0 |
| cseserver | cjCrash | 5 | violation | S1ThreadsAlive |  |  | 2.9 |
| cseserver | cpCrash | 0 | violation | S1ThreadsAlive | 38263 | 20 | 39.8 |
| cseserver | cpCrash | 2 | violation | S1ThreadsAlive | 40 | 5 | 4.2 |
| cseserver | cpCrash | 5 | violation | S1ThreadsAlive |  |  | 2.7 |
| cseserver | deadClient | 0 | violation | S1ThreadsAlive | 557 | 15 | 4.7 |
| cseserver | deadClient | 2 | violation | S1ThreadsAlive | 14 | 4 | 3.1 |
| cseserver | deadClient | 5 | violation | S1ThreadsAlive |  |  | 2.7 |
| cseserver | deleteJob | 0 | violation | S1ThreadsAlive | 14 | 6 | 2.5 |
| cseserver | deleteJob | 2 | pass_exhaustive |  | 3299 | 46 | 28.1 |
| cseserver | deleteJob | 5 | violation | S1ThreadsAlive |  |  | 2.8 |
| cseserver | netLoss | 0 | budget_stopped |  | 103636 |  | 240.5 |
| cseserver | netLoss | 2 | budget_stopped |  | 53296 |  | 240.4 |
| cseserver | netLoss | 5 | violation | S1ThreadsAlive |  |  | 2.7 |
| cseserver | rpcTimeout | 0 | budget_stopped |  | 157291 |  | 240.4 |
| cseserver | rpcTimeout | 2 | pass_exhaustive |  | 3299 | 46 | 27.8 |
| cseserver | rpcTimeout | 5 | violation | S1ThreadsAlive |  |  | 2.8 |
| cseserver | sjCrash | 0 | violation | S2TerminalFinal | 35094 | 26 | 39.4 |
| cseserver | sjCrash | 2 | budget_stopped |  | 115163 |  | 240.5 |
| cseserver | sjCrash | 5 | violation | S1ThreadsAlive |  |  | 2.8 |
| cseserver | spCrash | 0 | violation | Q1Terminal | 423 | 15 | 4.0 |
| cseserver | spCrash | 2 | violation | Q1Terminal | 18691 | 21 | 59.4 |
| cseserver | spCrash | 5 | violation | S1ThreadsAlive |  |  | 2.8 |
| cseserver | spShutdown | 0 | violation | Q1Terminal | 57 | 8 | 3.0 |
| cseserver | spShutdown | 2 | violation | S1ThreadsAlive | 669 | 8 | 5.8 |
| cseserver | spShutdown | 5 | violation | S1ThreadsAlive |  |  | 2.7 |
| cseserver | taskTimeout | 0 | violation | S1ThreadsAlive | 212 | 17 | 3.6 |
| cseserver | taskTimeout | 2 | violation | S1ThreadsAlive | 14 | 4 | 3.4 |
| cseserver | taskTimeout | 5 | violation | S1ThreadsAlive |  |  | 2.8 |
| cyclic | abort | 0 | budget_stopped |  | 111594 |  | 240.5 |
| cyclic | abort | 2 | budget_stopped |  | 102092 |  | 240.5 |
| cyclic | abort | 5 | budget_stopped |  | 58904 |  | 240.5 |
| cyclic | cbFail | 0 | budget_stopped |  | 70260 |  | 240.4 |
| cyclic | cbFail | 2 | budget_stopped |  | 36489 |  | 240.5 |
| cyclic | cbFail | 5 | budget_stopped |  | 41872 |  | 240.5 |
| cyclic | cjCrash | 0 | budget_stopped |  | 195873 |  | 240.4 |
| cyclic | cjCrash | 2 | budget_stopped |  | 130915 |  | 240.4 |
| cyclic | cjCrash | 5 | budget_stopped |  | 69391 |  | 240.4 |
| cyclic | cpCrash | 0 | budget_stopped |  | 183277 |  | 240.4 |
| cyclic | cpCrash | 2 | violation | Q1Terminal | 72 | 5 | 4.9 |
| cyclic | cpCrash | 5 | budget_stopped |  | 19004 |  | 240.5 |
| cyclic | deadClient | 0 | budget_stopped |  | 134877 |  | 240.4 |
| cyclic | deadClient | 2 | budget_stopped |  | 55741 |  | 240.5 |
| cyclic | deadClient | 5 | budget_stopped |  | 33519 |  | 240.4 |
| cyclic | deleteJob | 0 | violation | S1ThreadsAlive | 14 | 5 | 2.6 |
| cyclic | deleteJob | 2 | pass_exhaustive |  | 3299 | 46 | 28.3 |
| cyclic | deleteJob | 5 | budget_stopped |  | 43164 |  | 240.4 |
| cyclic | netLoss | 0 | budget_stopped |  | 98404 |  | 240.4 |
| cyclic | netLoss | 2 | budget_stopped |  | 56545 |  | 240.4 |
| cyclic | netLoss | 5 | budget_stopped |  | 30858 |  | 240.3 |
| cyclic | rpcTimeout | 0 | budget_stopped |  | 159914 |  | 240.5 |
| cyclic | rpcTimeout | 2 | pass_exhaustive |  | 3299 | 46 | 27.5 |
| cyclic | rpcTimeout | 5 | budget_stopped |  | 43420 |  | 240.5 |
| cyclic | sjCrash | 0 | violation | S2TerminalFinal | 34728 | 26 | 40.8 |
| cyclic | sjCrash | 2 | budget_stopped |  | 109203 |  | 240.5 |
| cyclic | sjCrash | 5 | budget_stopped |  | 71200 |  | 240.4 |
| cyclic | spCrash | 0 | violation | Q1Terminal | 305 | 14 | 4.3 |
| cyclic | spCrash | 2 | violation | Q1Terminal | 18690 | 21 | 58.8 |
| cyclic | spCrash | 5 | budget_stopped |  | 42423 |  | 240.4 |
| cyclic | spShutdown | 0 | violation | Q1Terminal | 62 | 8 | 2.9 |
| cyclic | spShutdown | 2 | budget_stopped |  | 104202 |  | 240.5 |
| cyclic | spShutdown | 5 | budget_stopped |  | 61254 |  | 240.3 |
| cyclic | taskTimeout | 0 | budget_stopped |  | 103400 |  | 240.4 |
| cyclic | taskTimeout | 2 | budget_stopped |  | 58389 |  | 240.5 |
| cyclic | taskTimeout | 5 | budget_stopped |  | 34854 |  | 240.4 |
| docker | abort | 0 | budget_stopped |  | 247325 |  | 240.4 |
| docker | abort | 2 | budget_stopped |  | 252718 |  | 240.5 |
| docker | abort | 5 | budget_stopped |  | 155616 |  | 240.5 |
| docker | cjCrash | 0 | violation | S2TerminalFinal | 24586 | 23 | 18.3 |
| docker | cjCrash | 2 | budget_stopped |  | 227298 |  | 240.5 |
| docker | cjCrash | 5 | budget_stopped |  | 121053 |  | 240.5 |
| docker | cpCrash | 0 | violation | S3Resources | 133 | 13 | 3.1 |
| docker | cpCrash | 2 | violation | S3Resources | 2 | 2 | 2.9 |
| docker | cpCrash | 5 | violation | S3Resources | 2 | 2 | 2.8 |
| docker | deadClient | 0 | violation | S2TerminalFinal | 57695 | 30 | 52.0 |
| docker | deadClient | 2 | budget_stopped |  | 149969 |  | 240.5 |
| docker | deadClient | 5 | pass_exhaustive |  | 7479 | 30 | 17.7 |
| docker | deleteJob | 0 | violation | S1ThreadsAlive | 13 | 6 | 2.6 |
| docker | deleteJob | 2 | budget_stopped |  | 75941 |  | 240.4 |
| docker | deleteJob | 5 | pass_exhaustive |  | 1227 | 27 | 8.0 |
| docker | netLoss | 0 | violation | S2TerminalFinal | 95542 | 39 | 138.1 |
| docker | netLoss | 2 | budget_stopped |  | 126820 |  | 240.4 |
| docker | netLoss | 5 | pass_exhaustive |  | 103132 | 36 | 199.1 |
| docker | rpcTimeout | 0 | budget_stopped |  | 254393 |  | 240.4 |
| docker | rpcTimeout | 2 | budget_stopped |  | 74897 |  | 240.4 |
| docker | rpcTimeout | 5 | pass_exhaustive |  | 2287 | 28 | 9.0 |
| docker | sjCrash | 0 | violation | S2TerminalFinal | 1135 | 20 | 4.8 |
| docker | sjCrash | 2 | budget_stopped |  | 180749 |  | 240.4 |
| docker | sjCrash | 5 | pass_exhaustive |  | 80377 | 29 | 96.0 |
| docker | spCrash | 0 | violation | Q1Terminal | 118 | 12 | 3.2 |
| docker | spCrash | 2 | violation | Q1Terminal | 487 | 12 | 4.8 |
| docker | spCrash | 5 | violation | Q1Terminal | 231 | 12 | 4.4 |
| docker | spShutdown | 0 | violation | Q1Terminal | 57 | 9 | 2.7 |
| docker | spShutdown | 2 | violation | Q1Terminal | 22722 | 16 | 20.6 |
| docker | spShutdown | 5 | violation | Q1Terminal | 22829 | 16 | 35.9 |
| docker | taskTimeout | 0 | violation | S2TerminalFinal | 11044 | 30 | 15.3 |
| docker | taskTimeout | 2 | budget_stopped |  | 190130 |  | 240.4 |
| docker | taskTimeout | 5 | pass_exhaustive |  | 4908 | 29 | 13.8 |
| external | abort | 0 | budget_stopped |  | 207445 |  | 240.5 |
| external | abort | 2 | budget_stopped |  | 240197 |  | 240.4 |
| external | abort | 4 | budget_stopped |  | 112946 |  | 240.4 |
| external | abort | 5 | budget_stopped |  | 111137 |  | 240.5 |
| external | cjCrash | 0 | violation | S2TerminalFinal | 22959 | 23 | 16.2 |
| external | cjCrash | 2 | budget_stopped |  | 204890 |  | 240.5 |
| external | cjCrash | 4 | budget_stopped |  | 96913 |  | 240.4 |
| external | cjCrash | 5 | budget_stopped |  | 105503 |  | 240.5 |
| external | cpCrash | 0 | violation | Q1Terminal | 17644 | 20 | 16.3 |
| external | cpCrash | 2 | violation | Q1Terminal | 68 | 6 | 3.9 |
| external | cpCrash | 4 | budget_stopped |  | 34685 |  | 240.4 |
| external | cpCrash | 5 | budget_stopped |  | 33373 |  | 240.5 |
| external | deadClient | 0 | violation | S2TerminalFinal | 186841 | 30 | 214.6 |
| external | deadClient | 2 | budget_stopped |  | 108681 |  | 240.5 |
| external | deadClient | 4 | budget_stopped |  | 69267 |  | 240.4 |
| external | deadClient | 5 | budget_stopped |  | 68895 |  | 240.5 |
| external | deleteJob | 0 | violation | S1ThreadsAlive | 13 | 6 | 2.5 |
| external | deleteJob | 2 | budget_stopped |  | 56850 |  | 240.4 |
| external | deleteJob | 4 | budget_stopped |  | 67688 |  | 240.5 |
| external | deleteJob | 5 | budget_stopped |  | 67803 |  | 240.3 |
| external | monitorStale | 0 | budget_stopped |  | 120525 |  | 240.5 |
| external | monitorStale | 2 | budget_stopped |  | 70245 |  | 240.5 |
| external | monitorStale | 4 | budget_stopped |  | 69176 |  | 240.5 |
| external | monitorStale | 5 | budget_stopped |  | 70763 |  | 240.4 |
| external | netLoss | 0 | budget_stopped |  | 108178 |  | 240.4 |
| external | netLoss | 2 | budget_stopped |  | 70819 |  | 240.4 |
| external | netLoss | 4 | budget_stopped |  | 70812 |  | 240.4 |
| external | netLoss | 5 | budget_stopped |  | 71157 |  | 240.5 |
| external | rpcTimeout | 0 | budget_stopped |  | 253006 |  | 240.5 |
| external | rpcTimeout | 2 | budget_stopped |  | 57972 |  | 240.4 |
| external | rpcTimeout | 4 | budget_stopped |  | 68241 |  | 240.5 |
| external | rpcTimeout | 5 | budget_stopped |  | 66656 |  | 240.5 |
| external | sjCrash | 0 | violation | S2TerminalFinal | 1533 | 20 | 4.8 |
| external | sjCrash | 2 | budget_stopped |  | 231529 |  | 240.5 |
| external | sjCrash | 4 | budget_stopped |  | 109287 |  | 240.5 |
| external | sjCrash | 5 | budget_stopped |  | 113402 |  | 240.4 |
| external | spCrash | 0 | violation | Q1Terminal | 119 | 12 | 2.9 |
| external | spCrash | 2 | violation | Q1Terminal | 506 | 12 | 4.8 |
| external | spCrash | 4 | violation | Q1Terminal | 8089 | 12 | 21.7 |
| external | spCrash | 5 | violation | Q1Terminal | 5493 | 12 | 18.3 |
| external | spShutdown | 0 | violation | Q1Terminal | 56 | 9 | 2.7 |
| external | spShutdown | 2 | violation | Q1Terminal | 34018 | 16 | 29.4 |
| external | spShutdown | 4 | budget_stopped |  | 116282 |  | 240.4 |
| external | spShutdown | 5 | budget_stopped |  | 118743 |  | 240.4 |
| external | taskTimeout | 0 | violation | S2TerminalFinal | 37636 | 30 | 56.0 |
| external | taskTimeout | 2 | budget_stopped |  | 125323 |  | 240.4 |
| external | taskTimeout | 4 | budget_stopped |  | 65895 |  | 240.4 |
| external | taskTimeout | 5 | budget_stopped |  | 65666 |  | 240.4 |
| external | tpSilent | 0 | budget_stopped |  | 106653 |  | 240.4 |
| external | tpSilent | 2 | budget_stopped |  | 70971 |  | 240.4 |
| external | tpSilent | 4 | budget_stopped |  | 68558 |  | 240.4 |
| external | tpSilent | 5 | budget_stopped |  | 69071 |  | 240.4 |
| external | trainerError | 0 | budget_stopped |  | 97342 |  | 240.5 |
| external | trainerError | 2 | budget_stopped |  | 87791 |  | 240.4 |
| external | trainerError | 4 | budget_stopped |  | 66604 |  | 240.5 |
| external | trainerError | 5 | budget_stopped |  | 67356 |  | 240.5 |
| fedavg | abort | 0 | budget_stopped |  | 259500 |  | 240.5 |
| fedavg | abort | 2 | budget_stopped |  | 266928 |  | 240.5 |
| fedavg | abort | 5 | budget_stopped |  | 146469 |  | 240.5 |
| fedavg | abortCmdError | 0 | budget_stopped |  | 105212 |  | 240.3 |
| fedavg | abortCmdError | 2 | budget_stopped |  | 85385 |  | 240.4 |
| fedavg | abortCmdError | 5 | pass_exhaustive |  | 1227 | 27 | 7.7 |
| fedavg | admissionError | 0 | budget_stopped |  | 106780 |  | 240.5 |
| fedavg | admissionError | 2 | budget_stopped |  | 85906 |  | 240.4 |
| fedavg | admissionError | 5 | pass_exhaustive |  | 1227 | 27 | 7.7 |
| fedavg | archiveError | 0 | budget_stopped |  | 107337 |  | 240.4 |
| fedavg | archiveError | 2 | budget_stopped |  | 85911 |  | 240.5 |
| fedavg | archiveError | 5 | pass_exhaustive |  | 1227 | 27 | 8.3 |
| fedavg | cancel | 0 | violation | S2TerminalFinal | 11631 | 30 | 15.7 |
| fedavg | cancel | 2 | budget_stopped |  | 201752 |  | 240.4 |
| fedavg | cancel | 5 | pass_exhaustive |  | 1227 | 27 | 7.3 |
| fedavg | cbFail | 0 | violation | S2TerminalFinal | 17976 | 31 | 21.9 |
| fedavg | cbFail | 2 | budget_stopped |  | 196339 |  | 240.4 |
| fedavg | cbFail | 5 | pass_exhaustive |  | 1227 | 27 | 7.6 |
| fedavg | cjCrash | 0 | violation | S2TerminalFinal | 28313 | 23 | 19.0 |
| fedavg | cjCrash | 2 | budget_stopped |  | 243062 |  | 240.4 |
| fedavg | cjCrash | 5 | budget_stopped |  | 112227 |  | 240.5 |
| fedavg | cpCrash | 0 | violation | Q1Terminal | 22676 | 21 | 17.6 |
| fedavg | cpCrash | 2 | violation | Q1Terminal | 138 | 7 | 5.2 |
| fedavg | cpCrash | 5 | pass_exhaustive |  | 13955 | 30 | 28.3 |
| fedavg | deadClient | 0 | violation | S2TerminalFinal | 51266 | 30 | 49.3 |
| fedavg | deadClient | 2 | budget_stopped |  | 167969 |  | 240.3 |
| fedavg | deadClient | 5 | pass_exhaustive |  | 7479 | 30 | 18.9 |
| fedavg | deleteJob | 0 | violation | S1ThreadsAlive | 13 | 6 | 3.1 |
| fedavg | deleteJob | 2 | budget_stopped |  | 86806 |  | 240.4 |
| fedavg | deleteJob | 5 | pass_exhaustive |  | 1227 | 27 | 8.2 |
| fedavg | deployError | 0 | budget_stopped |  | 263741 |  | 240.5 |
| fedavg | deployError | 2 | budget_stopped |  | 82073 |  | 240.4 |
| fedavg | deployError | 5 | pass_exhaustive |  | 1227 | 27 | 6.9 |
| fedavg | launchError | 0 | violation | S3Resources | 125 | 13 | 3.1 |
| fedavg | launchError | 2 | budget_stopped |  | 89990 |  | 240.4 |
| fedavg | launchError | 5 | pass_exhaustive |  | 1227 | 27 | 7.3 |
| fedavg | minClients | 0 | violation | S2TerminalFinal | 10692 | 30 | 15.2 |
| fedavg | minClients | 2 | budget_stopped |  | 213011 |  | 240.4 |
| fedavg | minClients | 5 | pass_exhaustive |  | 1227 | 27 | 7.3 |
| fedavg | netLoss | 0 | violation | S2TerminalFinal | 93427 | 39 | 114.0 |
| fedavg | netLoss | 2 | budget_stopped |  | 148488 |  | 240.4 |
| fedavg | netLoss | 5 | budget_stopped |  | 97802 |  | 240.3 |
| fedavg | outcomeReportFail | 0 | budget_stopped |  | 106576 |  | 240.4 |
| fedavg | outcomeReportFail | 2 | budget_stopped |  | 90677 |  | 240.3 |
| fedavg | outcomeReportFail | 5 | pass_exhaustive |  | 2987 | 28 | 10.4 |
| fedavg | outcomeTimeout | 0 | budget_stopped |  | 107355 |  | 240.4 |
| fedavg | outcomeTimeout | 2 | budget_stopped |  | 89947 |  | 240.4 |
| fedavg | outcomeTimeout | 5 | pass_exhaustive |  | 2817 | 28 | 10.6 |
| fedavg | payCallback | 0 | budget_stopped |  | 103024 |  | 240.5 |
| fedavg | payCallback | 2 | budget_stopped |  | 84931 |  | 240.5 |
| fedavg | payCallback | 5 | pass_exhaustive |  | 1227 | 27 | 7.4 |
| fedavg | payCompute | 0 | budget_stopped |  | 105134 |  | 240.4 |
| fedavg | payCompute | 2 | budget_stopped |  | 85083 |  | 240.4 |
| fedavg | payCompute | 5 | pass_exhaustive |  | 1227 | 27 | 7.5 |
| fedavg | payConsumer | 0 | violation | S2TerminalFinal | 7010 | 39 | 12.2 |
| fedavg | payConsumer | 2 | budget_stopped |  | 160976 |  | 240.4 |
| fedavg | payConsumer | 5 | pass_exhaustive |  | 1227 | 27 | 7.8 |
| fedavg | payDelete | 0 | violation | S2TerminalFinal | 14439 | 42 | 24.4 |
| fedavg | payDelete | 2 | budget_stopped |  | 141180 |  | 240.5 |
| fedavg | payDelete | 5 | pass_exhaustive |  | 1227 | 27 | 7.7 |
| fedavg | payProduce | 0 | violation | S2TerminalFinal | 7789 | 42 | 16.2 |
| fedavg | payProduce | 2 | budget_stopped |  | 152768 |  | 240.5 |
| fedavg | payProduce | 5 | pass_exhaustive |  | 1227 | 27 | 7.3 |
| fedavg | paySubmit | 0 | budget_stopped |  | 109539 |  | 240.5 |
| fedavg | paySubmit | 2 | budget_stopped |  | 82996 |  | 240.4 |
| fedavg | paySubmit | 5 | pass_exhaustive |  | 1227 | 27 | 7.6 |
| fedavg | prepFail | 0 | violation | S2TerminalFinal | 21286 | 30 | 28.4 |
| fedavg | prepFail | 2 | budget_stopped |  | 154966 |  | 240.5 |
| fedavg | prepFail | 5 | pass_exhaustive |  | 78512 | 36 | 160.5 |
| fedavg | pullTimeout | 0 | violation | S2TerminalFinal | 16728 | 39 | 25.4 |
| fedavg | pullTimeout | 2 | budget_stopped |  | 143950 |  | 240.4 |
| fedavg | pullTimeout | 5 | pass_exhaustive |  | 4908 | 29 | 14.4 |
| fedavg | regIterRace | 0 | violation | S1ThreadsAlive | 31 | 7 | 2.9 |
| fedavg | regIterRace | 2 | violation | S1ThreadsAlive | 34 | 5 | 3.1 |
| fedavg | regIterRace | 5 | violation | S1ThreadsAlive | 28 | 6 | 3.2 |
| fedavg | resExpiry | 0 | budget_stopped |  | 107480 |  | 240.3 |
| fedavg | resExpiry | 2 | budget_stopped |  | 81587 |  | 240.3 |
| fedavg | resExpiry | 5 | pass_exhaustive |  | 1227 | 27 | 7.4 |
| fedavg | resultWaitTimeout | 0 | violation | S2TerminalFinal | 151342 | 41 | 197.9 |
| fedavg | resultWaitTimeout | 2 | budget_stopped |  | 135264 |  | 240.4 |
| fedavg | resultWaitTimeout | 5 | pass_exhaustive |  | 2211 | 28 | 10.0 |
| fedavg | rpcTimeout | 0 | budget_stopped |  | 275789 |  | 240.4 |
| fedavg | rpcTimeout | 2 | budget_stopped |  | 89911 |  | 240.3 |
| fedavg | rpcTimeout | 5 | pass_exhaustive |  | 2287 | 28 | 7.9 |
| fedavg | sjCrash | 0 | violation | S2TerminalFinal | 1147 | 20 | 5.0 |
| fedavg | sjCrash | 2 | budget_stopped |  | 193124 |  | 240.4 |
| fedavg | sjCrash | 5 | pass_exhaustive |  | 80377 | 29 | 103.9 |
| fedavg | sjSyncFail | 0 | violation | S2TerminalFinal | 708 | 19 | 4.2 |
| fedavg | sjSyncFail | 2 | budget_stopped |  | 89999 |  | 240.4 |
| fedavg | sjSyncFail | 5 | pass_exhaustive |  | 1227 | 27 | 7.5 |
| fedavg | slowAdminStop | 0 | violation | S4Completed | 34211 | 27 | 25.0 |
| fedavg | slowAdminStop | 2 | violation | S4Completed | 19752 | 14 | 16.8 |
| fedavg | slowAdminStop | 5 | budget_stopped |  | 144601 |  | 240.4 |
| fedavg | slowEnvelope | 0 | budget_stopped |  | 99151 |  | 240.5 |
| fedavg | slowEnvelope | 2 | budget_stopped |  | 86977 |  | 240.5 |
| fedavg | slowEnvelope | 5 | pass_exhaustive |  | 1227 | 27 | 8.5 |
| fedavg | slowFinalize | 0 | violation | S1ThreadsAlive | 112 | 10 | 2.9 |
| fedavg | slowFinalize | 2 | violation | S1ThreadsAlive | 370 | 10 | 4.6 |
| fedavg | slowFinalize | 5 | violation | S1ThreadsAlive | 319 | 9 | 5.2 |
| fedavg | slowSJTeardown | 0 | budget_stopped |  | 111493 |  | 240.4 |
| fedavg | slowSJTeardown | 2 | budget_stopped |  | 94466 |  | 240.3 |
| fedavg | slowSJTeardown | 5 | pass_exhaustive |  | 2517 | 27 | 9.1 |
| fedavg | slowShutdownAbort | 0 | violation | Q1Terminal | 62 | 9 | 2.9 |
| fedavg | slowShutdownAbort | 2 | violation | Q1Terminal | 26981 | 17 | 23.1 |
| fedavg | slowShutdownAbort | 5 | violation | Q1Terminal | 23561 | 16 | 38.9 |
| fedavg | slowShutdownExit | 0 | violation | Q1Terminal | 54 | 8 | 2.7 |
| fedavg | slowShutdownExit | 2 | violation | Q1Terminal | 36342 | 16 | 28.3 |
| fedavg | slowShutdownExit | 5 | violation | Q1Terminal | 35568 | 16 | 51.9 |
| fedavg | sourceFailure | 0 | violation | S2TerminalFinal | 7072 | 39 | 13.4 |
| fedavg | sourceFailure | 2 | budget_stopped |  | 173042 |  | 240.4 |
| fedavg | sourceFailure | 5 | pass_exhaustive |  | 1227 | 27 | 7.9 |
| fedavg | spCrash | 0 | violation | Q1Terminal | 128 | 12 | 3.4 |
| fedavg | spCrash | 2 | violation | Q1Terminal | 507 | 12 | 5.3 |
| fedavg | spCrash | 5 | violation | Q1Terminal | 170 | 12 | 5.0 |
| fedavg | spShutdown | 0 | violation | Q1Terminal | 54 | 8 | 3.2 |
| fedavg | spShutdown | 2 | violation | Q1Terminal | 22142 | 16 | 20.1 |
| fedavg | spShutdown | 5 | violation | Q1Terminal | 22296 | 16 | 36.8 |
| fedavg | statusLost | 0 | violation | S2TerminalFinal | 19679 | 31 | 24.1 |
| fedavg | statusLost | 2 | violation | S4Completed | 84094 | 27 | 86.9 |
| fedavg | statusLost | 5 | pass_exhaustive |  | 1227 | 27 | 7.8 |
| fedavg | storeError | 0 | budget_stopped |  | 280717 |  | 240.4 |
| fedavg | storeError | 2 | budget_stopped |  | 84266 |  | 240.4 |
| fedavg | storeError | 5 | pass_exhaustive |  | 1227 | 27 | 7.4 |
| fedavg | submitTimeout | 0 | budget_stopped |  | 103307 |  | 240.4 |
| fedavg | submitTimeout | 2 | budget_stopped |  | 61550 |  | 240.4 |
| fedavg | submitTimeout | 5 | pass_exhaustive |  | 82193 | 36 | 166.9 |
| fedavg | taskDataFail | 0 | budget_stopped |  | 131850 |  | 240.5 |
| fedavg | taskDataFail | 2 | budget_stopped |  | 96892 |  | 240.4 |
| fedavg | taskDataFail | 5 | pass_exhaustive |  | 116549 | 36 | 235.7 |
| fedavg | taskTimeout | 0 | violation | S2TerminalFinal | 11456 | 30 | 14.5 |
| fedavg | taskTimeout | 2 | budget_stopped |  | 208186 |  | 240.5 |
| fedavg | taskTimeout | 5 | pass_exhaustive |  | 4908 | 29 | 14.3 |
| fedavg | tpSilent | 0 | violation | S2TerminalFinal | 57493 | 42 | 82.5 |
| fedavg | tpSilent | 2 | budget_stopped |  | 174303 |  | 240.5 |
| fedavg | tpSilent | 5 | pass_exhaustive |  | 1964 | 27 | 9.4 |
| fedavg | trainerError | 0 | violation | S2TerminalFinal | 60761 | 42 | 87.8 |
| fedavg | trainerError | 2 | budget_stopped |  | 173966 |  | 240.4 |
| fedavg | trainerError | 5 | pass_exhaustive |  | 1964 | 27 | 9.4 |
| fedavg | transportFail | 0 | violation | S2TerminalFinal | 7458 | 39 | 13.1 |
| fedavg | transportFail | 2 | budget_stopped |  | 174845 |  | 240.4 |
| fedavg | transportFail | 5 | pass_exhaustive |  | 1227 | 27 | 7.4 |
| fedavg | txTimeout | 0 | violation | S2TerminalFinal | 21231 | 42 | 40.8 |
| fedavg | txTimeout | 2 | budget_stopped |  | 126357 |  | 240.4 |
| fedavg | txTimeout | 5 | pass_exhaustive |  | 4908 | 29 | 14.0 |
| fedavg2 | abort | 0 | budget_stopped |  | 106360 |  | 240.4 |
| fedavg2 | abort | 2 | budget_stopped |  | 103819 |  | 240.4 |
| fedavg2 | abort | 5 | budget_stopped |  | 59935 |  | 240.4 |
| fedavg2 | cancel | 0 | budget_stopped |  | 102650 |  | 240.5 |
| fedavg2 | cancel | 2 | budget_stopped |  | 76565 |  | 240.4 |
| fedavg2 | cancel | 5 | budget_stopped |  | 42281 |  | 240.4 |
| fedavg2 | cjCrash | 0 | budget_stopped |  | 194261 |  | 240.5 |
| fedavg2 | cjCrash | 2 | budget_stopped |  | 130882 |  | 240.5 |
| fedavg2 | cjCrash | 5 | budget_stopped |  | 70475 |  | 240.5 |
| fedavg2 | cpCrash | 0 | budget_stopped |  | 188034 |  | 240.4 |
| fedavg2 | cpCrash | 2 | violation | Q1Terminal | 67 | 5 | 5.0 |
| fedavg2 | cpCrash | 5 | budget_stopped |  | 19017 |  | 240.4 |
| fedavg2 | deadClient | 0 | budget_stopped |  | 122696 |  | 240.4 |
| fedavg2 | deadClient | 2 | budget_stopped |  | 57957 |  | 240.5 |
| fedavg2 | deadClient | 5 | budget_stopped |  | 33773 |  | 240.5 |
| fedavg2 | deleteJob | 0 | violation | S1ThreadsAlive | 14 | 5 | 2.8 |
| fedavg2 | deleteJob | 2 | pass_exhaustive |  | 3299 | 46 | 26.5 |
| fedavg2 | deleteJob | 5 | budget_stopped |  | 41400 |  | 240.5 |
| fedavg2 | minClients | 0 | budget_stopped |  | 107490 |  | 240.5 |
| fedavg2 | minClients | 2 | budget_stopped |  | 76894 |  | 240.5 |
| fedavg2 | minClients | 5 | budget_stopped |  | 41459 |  | 240.4 |
| fedavg2 | netLoss | 0 | budget_stopped |  | 106897 |  | 240.4 |
| fedavg2 | netLoss | 2 | budget_stopped |  | 58150 |  | 240.4 |
| fedavg2 | netLoss | 5 | budget_stopped |  | 30799 |  | 240.5 |
| fedavg2 | regIterRace | 0 | violation | S1ThreadsAlive | 30 | 5 | 2.6 |
| fedavg2 | regIterRace | 2 | violation | S1ThreadsAlive | 41 | 5 | 3.6 |
| fedavg2 | regIterRace | 5 | violation | S1ThreadsAlive | 36 | 5 | 4.5 |
| fedavg2 | rpcTimeout | 0 | budget_stopped |  | 156347 |  | 240.4 |
| fedavg2 | rpcTimeout | 2 | pass_exhaustive |  | 3299 | 46 | 26.1 |
| fedavg2 | rpcTimeout | 5 | budget_stopped |  | 41215 |  | 240.4 |
| fedavg2 | sjCrash | 0 | violation | S2TerminalFinal | 35112 | 26 | 42.4 |
| fedavg2 | sjCrash | 2 | budget_stopped |  | 115598 |  | 240.4 |
| fedavg2 | sjCrash | 5 | budget_stopped |  | 73203 |  | 240.4 |
| fedavg2 | slowFinalize | 0 | violation | S1ThreadsAlive | 195 | 8 | 2.8 |
| fedavg2 | slowFinalize | 2 | violation | S1ThreadsAlive | 635 | 8 | 6.7 |
| fedavg2 | slowFinalize | 5 | violation | S1ThreadsAlive | 642 | 7 | 8.2 |
| fedavg2 | spCrash | 0 | violation | Q1Terminal | 307 | 14 | 4.0 |
| fedavg2 | spCrash | 2 | violation | Q1Terminal | 18203 | 21 | 58.9 |
| fedavg2 | spCrash | 5 | budget_stopped |  | 42857 |  | 240.5 |
| fedavg2 | spShutdown | 0 | violation | Q1Terminal | 62 | 8 | 3.0 |
| fedavg2 | spShutdown | 2 | budget_stopped |  | 107504 |  | 240.5 |
| fedavg2 | spShutdown | 5 | budget_stopped |  | 60029 |  | 240.4 |
| fedavg2 | submitTimeout | 0 | budget_stopped |  | 80520 |  | 240.6 |
| fedavg2 | submitTimeout | 2 | budget_stopped |  | 30755 |  | 240.5 |
| fedavg2 | submitTimeout | 5 | budget_stopped |  | 30675 |  | 240.5 |
| fedavg2 | taskTimeout | 0 | budget_stopped |  | 104055 |  | 240.5 |
| fedavg2 | taskTimeout | 2 | budget_stopped |  | 76937 |  | 240.4 |
| fedavg2 | taskTimeout | 5 | budget_stopped |  | 35044 |  | 240.4 |
| fedavg2 | transportFail | 0 | budget_stopped |  | 69725 |  | 240.4 |
| fedavg2 | transportFail | 2 | budget_stopped |  | 96649 |  | 240.5 |
| fedavg2 | transportFail | 5 | budget_stopped |  | 41345 |  | 240.4 |
| fedmodel | abort | 0 | budget_stopped |  | 109774 |  | 240.4 |
| fedmodel | abort | 2 | budget_stopped |  | 103186 |  | 240.4 |
| fedmodel | abort | 5 | budget_stopped |  | 59703 |  | 240.5 |
| fedmodel | acceptRaise | 0 | budget_stopped |  | 81440 |  | 240.4 |
| fedmodel | acceptRaise | 2 | budget_stopped |  | 47933 |  | 240.8 |
| fedmodel | acceptRaise | 5 | budget_stopped |  | 55669 |  | 240.4 |
| fedmodel | cjCrash | 0 | budget_stopped |  | 197239 |  | 240.4 |
| fedmodel | cjCrash | 2 | budget_stopped |  | 131508 |  | 240.5 |
| fedmodel | cjCrash | 5 | budget_stopped |  | 70114 |  | 240.5 |
| fedmodel | cpCrash | 0 | budget_stopped |  | 187798 |  | 240.5 |
| fedmodel | cpCrash | 2 | violation | Q1Terminal | 74 | 6 | 5.1 |
| fedmodel | cpCrash | 5 | budget_stopped |  | 19759 |  | 240.4 |
| fedmodel | deadClient | 0 | budget_stopped |  | 126884 |  | 240.4 |
| fedmodel | deadClient | 2 | budget_stopped |  | 57645 |  | 240.4 |
| fedmodel | deadClient | 5 | budget_stopped |  | 35770 |  | 240.4 |
| fedmodel | deleteJob | 0 | violation | S1ThreadsAlive | 14 | 5 | 2.8 |
| fedmodel | deleteJob | 2 | pass_exhaustive |  | 5747 | 47 | 45.1 |
| fedmodel | deleteJob | 5 | budget_stopped |  | 41850 |  | 240.4 |
| fedmodel | netLoss | 0 | budget_stopped |  | 107381 |  | 240.4 |
| fedmodel | netLoss | 2 | budget_stopped |  | 56569 |  | 240.5 |
| fedmodel | netLoss | 5 | budget_stopped |  | 29981 |  | 240.4 |
| fedmodel | rpcTimeout | 0 | budget_stopped |  | 179820 |  | 240.4 |
| fedmodel | rpcTimeout | 2 | pass_exhaustive |  | 5747 | 47 | 44.3 |
| fedmodel | rpcTimeout | 5 | budget_stopped |  | 51240 |  | 240.3 |
| fedmodel | saveFail | 0 | budget_stopped |  | 88967 |  | 240.4 |
| fedmodel | saveFail | 2 | pass_exhaustive |  | 5747 | 47 | 42.2 |
| fedmodel | saveFail | 5 | budget_stopped |  | 58920 |  | 240.3 |
| fedmodel | sjCrash | 0 | violation | S2TerminalFinal | 34975 | 26 | 41.1 |
| fedmodel | sjCrash | 2 | budget_stopped |  | 113926 |  | 240.4 |
| fedmodel | sjCrash | 5 | budget_stopped |  | 73475 |  | 240.4 |
| fedmodel | spCrash | 0 | violation | Q1Terminal | 325 | 14 | 3.8 |
| fedmodel | spCrash | 2 | violation | Q1Terminal | 18691 | 21 | 61.5 |
| fedmodel | spCrash | 5 | budget_stopped |  | 45912 |  | 240.5 |
| fedmodel | spShutdown | 0 | violation | Q1Terminal | 64 | 8 | 2.8 |
| fedmodel | spShutdown | 2 | budget_stopped |  | 105801 |  | 240.5 |
| fedmodel | spShutdown | 5 | budget_stopped |  | 61709 |  | 240.5 |
| fedmodel | taskTimeout | 0 | budget_stopped |  | 109472 |  | 240.4 |
| fedmodel | taskTimeout | 2 | budget_stopped |  | 82492 |  | 240.4 |
| fedmodel | taskTimeout | 5 | budget_stopped |  | 38582 |  | 240.4 |
| k8s | abort | 0 | budget_stopped |  | 252753 |  | 240.5 |
| k8s | abort | 2 | budget_stopped |  | 262484 |  | 240.5 |
| k8s | abort | 5 | budget_stopped |  | 149419 |  | 240.5 |
| k8s | cjCrash | 0 | violation | S2TerminalFinal | 63386 | 23 | 36.6 |
| k8s | cjCrash | 2 | budget_stopped |  | 236862 |  | 240.5 |
| k8s | cjCrash | 5 | budget_stopped |  | 126412 |  | 240.6 |
| k8s | cpCrash | 0 | violation | S3Resources | 121 | 13 | 3.1 |
| k8s | cpCrash | 2 | violation | S3Resources | 6 | 4 | 2.9 |
| k8s | cpCrash | 5 | violation | S3Resources | 2 | 2 | 2.8 |
| k8s | deadClient | 0 | violation | S2TerminalFinal | 122165 | 30 | 110.9 |
| k8s | deadClient | 2 | budget_stopped |  | 162699 |  | 240.5 |
| k8s | deadClient | 5 | pass_exhaustive |  | 7479 | 30 | 17.7 |
| k8s | deleteJob | 0 | violation | S1ThreadsAlive | 13 | 6 | 2.6 |
| k8s | deleteJob | 2 | budget_stopped |  | 85956 |  | 240.4 |
| k8s | deleteJob | 5 | pass_exhaustive |  | 1227 | 27 | 7.6 |
| k8s | netLoss | 0 | budget_stopped |  | 129419 |  | 240.4 |
| k8s | netLoss | 2 | budget_stopped |  | 133018 |  | 240.5 |
| k8s | netLoss | 5 | pass_exhaustive |  | 104779 | 36 | 216.0 |
| k8s | podDeleteFail | 0 | violation | S3Resources | 1841 | 20 | 5.7 |
| k8s | podDeleteFail | 2 | violation | S3Resources | 309 | 7 | 4.1 |
| k8s | podDeleteFail | 5 | violation | S3Resources | 91 | 8 | 3.7 |
| k8s | rpcTimeout | 0 | budget_stopped |  | 266758 |  | 240.4 |
| k8s | rpcTimeout | 2 | budget_stopped |  | 83247 |  | 240.4 |
| k8s | rpcTimeout | 5 | pass_exhaustive |  | 2287 | 28 | 9.4 |
| k8s | sjCrash | 0 | violation | S2TerminalFinal | 2360 | 20 | 5.7 |
| k8s | sjCrash | 2 | budget_stopped |  | 208994 |  | 240.6 |
| k8s | sjCrash | 5 | pass_exhaustive |  | 80377 | 29 | 104.5 |
| k8s | slowPublish | 0 | violation | S2TerminalFinal | 73486 | 23 | 42.4 |
| k8s | slowPublish | 2 | budget_stopped |  | 243417 |  | 240.4 |
| k8s | slowPublish | 5 | budget_stopped |  | 121928 |  | 240.4 |
| k8s | spCrash | 0 | violation | Q1Terminal | 120 | 12 | 3.1 |
| k8s | spCrash | 2 | violation | Q1Terminal | 1236 | 12 | 5.2 |
| k8s | spCrash | 5 | violation | Q1Terminal | 165 | 12 | 4.5 |
| k8s | spShutdown | 0 | violation | Q1Terminal | 74 | 10 | 2.8 |
| k8s | spShutdown | 2 | violation | Q1Terminal | 54869 | 16 | 43.1 |
| k8s | spShutdown | 5 | violation | Q1Terminal | 27010 | 17 | 41.2 |
| k8s | taskTimeout | 0 | violation | S2TerminalFinal | 24048 | 30 | 27.4 |
| k8s | taskTimeout | 2 | budget_stopped |  | 189110 |  | 240.5 |
| k8s | taskTimeout | 5 | pass_exhaustive |  | 4908 | 29 | 13.6 |
| multijob | abort | 0 | budget_stopped |  | 94902 |  | 240.4 |
| multijob | abort | 2 | budget_stopped |  | 120603 |  | 240.5 |
| multijob | abort | 5 | budget_stopped |  | 56939 |  | 240.4 |
| multijob | cjCrash | 0 | budget_stopped |  | 207945 |  | 240.5 |
| multijob | cjCrash | 2 | budget_stopped |  | 139801 |  | 240.4 |
| multijob | cjCrash | 5 | budget_stopped |  | 73896 |  | 240.5 |
| multijob | cpCrash | 0 | budget_stopped |  | 194225 |  | 240.4 |
| multijob | cpCrash | 2 | violation | Q1Terminal | 1227 | 8 | 7.1 |
| multijob | cpCrash | 5 | budget_stopped |  | 38190 |  | 240.5 |
| multijob | deadClient | 0 | budget_stopped |  | 149791 |  | 240.4 |
| multijob | deadClient | 2 | budget_stopped |  | 87396 |  | 240.5 |
| multijob | deadClient | 5 | budget_stopped |  | 42924 |  | 240.4 |
| multijob | deleteJob | 0 | violation | S1ThreadsAlive | 14 | 4 | 2.6 |
| multijob | deleteJob | 2 | budget_stopped |  | 40731 |  | 240.5 |
| multijob | deleteJob | 5 | budget_stopped |  | 47287 |  | 240.4 |
| multijob | jobExitRace | 0 | violation | S1ThreadsAlive | 132 | 6 | 2.9 |
| multijob | jobExitRace | 2 | violation | S1ThreadsAlive | 320 | 6 | 4.5 |
| multijob | jobExitRace | 5 | violation | S1ThreadsAlive | 105 | 5 | 4.4 |
| multijob | netLoss | 0 | budget_stopped |  | 130053 |  | 240.4 |
| multijob | netLoss | 2 | budget_stopped |  | 51806 |  | 240.5 |
| multijob | netLoss | 5 | budget_stopped |  | 43595 |  | 240.3 |
| multijob | regIterRace | 0 | violation | S1ThreadsAlive | 50 | 5 | 2.7 |
| multijob | regIterRace | 2 | violation | S1ThreadsAlive | 97 | 5 | 4.0 |
| multijob | regIterRace | 5 | violation | S1ThreadsAlive | 35 | 5 | 4.0 |
| multijob | rpcTimeout | 0 | budget_stopped |  | 175133 |  | 240.5 |
| multijob | rpcTimeout | 2 | budget_stopped |  | 41547 |  | 240.3 |
| multijob | rpcTimeout | 5 | budget_stopped |  | 47989 |  | 240.5 |
| multijob | sjCrash | 0 | violation | S2TerminalFinal | 123876 | 27 | 125.9 |
| multijob | sjCrash | 2 | budget_stopped |  | 131074 |  | 240.4 |
| multijob | sjCrash | 5 | budget_stopped |  | 76845 |  | 240.4 |
| multijob | spCrash | 0 | violation | Q1Terminal | 1057 | 15 | 5.3 |
| multijob | spCrash | 2 | budget_stopped |  | 70493 |  | 240.5 |
| multijob | spCrash | 5 | budget_stopped |  | 47040 |  | 240.5 |
| multijob | spShutdown | 0 | violation | Q1Terminal | 141 | 9 | 3.1 |
| multijob | spShutdown | 2 | budget_stopped |  | 120145 |  | 240.5 |
| multijob | spShutdown | 5 | budget_stopped |  | 62651 |  | 240.5 |
| multijob | taskTimeout | 0 | budget_stopped |  | 105359 |  | 240.5 |
| multijob | taskTimeout | 2 | budget_stopped |  | 86317 |  | 240.5 |
| multijob | taskTimeout | 5 | budget_stopped |  | 45268 |  | 240.5 |
| multijobcp | abort | 0 | budget_stopped |  | 273707 |  | 240.5 |
| multijobcp | abort | 2 | budget_stopped |  | 280894 |  | 240.5 |
| multijobcp | abort | 5 | budget_stopped |  | 157880 |  | 240.4 |
| multijobcp | cjCrash | 0 | violation | S3Resources | 94 | 12 | 3.0 |
| multijobcp | cjCrash | 2 | budget_stopped |  | 211647 |  | 240.6 |
| multijobcp | cjCrash | 5 | budget_stopped |  | 127923 |  | 240.5 |
| multijobcp | cpCrash | 0 | violation | Q1Terminal | 37688 | 20 | 23.6 |
| multijobcp | cpCrash | 2 | violation | Q1Terminal | 10 | 4 | 2.7 |
| multijobcp | cpCrash | 5 | pass_exhaustive |  | 13955 | 30 | 27.0 |
| multijobcp | deadClient | 0 | violation | S2TerminalFinal | 222687 | 30 | 176.2 |
| multijobcp | deadClient | 2 | budget_stopped |  | 167300 |  | 240.5 |
| multijobcp | deadClient | 5 | pass_exhaustive |  | 7479 | 30 | 18.4 |
| multijobcp | deleteJob | 0 | violation | S1ThreadsAlive | 15 | 5 | 2.6 |
| multijobcp | deleteJob | 2 | budget_stopped |  | 85114 |  | 240.4 |
| multijobcp | deleteJob | 5 | pass_exhaustive |  | 1227 | 27 | 7.1 |
| multijobcp | netLoss | 0 | budget_stopped |  | 152840 |  | 240.4 |
| multijobcp | netLoss | 2 | budget_stopped |  | 147540 |  | 240.5 |
| multijobcp | netLoss | 5 | pass_exhaustive |  | 103132 | 36 | 200.5 |
| multijobcp | rpcTimeout | 0 | budget_stopped |  | 272273 |  | 240.6 |
| multijobcp | rpcTimeout | 2 | budget_stopped |  | 84088 |  | 240.4 |
| multijobcp | rpcTimeout | 5 | pass_exhaustive |  | 2287 | 28 | 8.3 |
| multijobcp | sjCrash | 0 | violation | S2TerminalFinal | 5273 | 21 | 7.4 |
| multijobcp | sjCrash | 2 | budget_stopped |  | 189615 |  | 240.5 |
| multijobcp | sjCrash | 5 | pass_exhaustive |  | 80377 | 29 | 108.1 |
| multijobcp | spCrash | 0 | violation | Q1Terminal | 706 | 14 | 3.7 |
| multijobcp | spCrash | 2 | violation | Q1Terminal | 371 | 12 | 4.8 |
| multijobcp | spCrash | 5 | violation | Q1Terminal | 294 | 12 | 4.7 |
| multijobcp | spShutdown | 0 | violation | Q1Terminal | 251 | 11 | 3.2 |
| multijobcp | spShutdown | 2 | violation | Q1Terminal | 19475 | 16 | 18.7 |
| multijobcp | spShutdown | 5 | violation | Q1Terminal | 21817 | 16 | 30.0 |
| multijobcp | startOverlap | 0 | violation | S3Resources | 98 | 14 | 3.0 |
| multijobcp | startOverlap | 2 | budget_stopped |  | 84442 |  | 240.4 |
| multijobcp | startOverlap | 5 | pass_exhaustive |  | 1227 | 27 | 7.0 |
| multijobcp | taskTimeout | 0 | violation | S2TerminalFinal | 46280 | 31 | 41.5 |
| multijobcp | taskTimeout | 2 | budget_stopped |  | 205291 |  | 240.4 |
| multijobcp | taskTimeout | 5 | pass_exhaustive |  | 4908 | 29 | 12.8 |
| nonstrict | abort | 0 | budget_stopped |  | 105848 |  | 240.5 |
| nonstrict | abort | 2 | budget_stopped |  | 101215 |  | 240.4 |
| nonstrict | abort | 5 | budget_stopped |  | 59193 |  | 240.5 |
| nonstrict | cjCrash | 0 | budget_stopped |  | 199215 |  | 240.5 |
| nonstrict | cjCrash | 2 | budget_stopped |  | 130425 |  | 240.5 |
| nonstrict | cjCrash | 5 | budget_stopped |  | 72786 |  | 240.4 |
| nonstrict | cpCrash | 0 | violation | Q1Terminal | 141153 | 22 | 147.8 |
| nonstrict | cpCrash | 2 | violation | Q1Terminal | 72 | 5 | 4.4 |
| nonstrict | cpCrash | 5 | budget_stopped |  | 19302 |  | 240.4 |
| nonstrict | deadClient | 0 | budget_stopped |  | 125854 |  | 240.4 |
| nonstrict | deadClient | 2 | budget_stopped |  | 58055 |  | 240.4 |
| nonstrict | deadClient | 5 | budget_stopped |  | 34253 |  | 240.4 |
| nonstrict | deleteJob | 0 | violation | S1ThreadsAlive | 14 | 6 | 2.5 |
| nonstrict | deleteJob | 2 | pass_exhaustive |  | 3299 | 46 | 28.0 |
| nonstrict | deleteJob | 5 | budget_stopped |  | 41467 |  | 240.5 |
| nonstrict | netLoss | 0 | budget_stopped |  | 100891 |  | 240.5 |
| nonstrict | netLoss | 2 | budget_stopped |  | 55372 |  | 240.5 |
| nonstrict | netLoss | 5 | budget_stopped |  | 31295 |  | 240.5 |
| nonstrict | rpcTimeout | 0 | budget_stopped |  | 165178 |  | 240.4 |
| nonstrict | rpcTimeout | 2 | pass_exhaustive |  | 3299 | 46 | 27.0 |
| nonstrict | rpcTimeout | 5 | budget_stopped |  | 42541 |  | 240.5 |
| nonstrict | sjCrash | 0 | violation | S2TerminalFinal | 33606 | 26 | 38.4 |
| nonstrict | sjCrash | 2 | budget_stopped |  | 114435 |  | 240.5 |
| nonstrict | sjCrash | 5 | budget_stopped |  | 72147 |  | 240.5 |
| nonstrict | spCrash | 0 | violation | Q1Terminal | 419 | 14 | 4.2 |
| nonstrict | spCrash | 2 | violation | Q1Terminal | 18196 | 21 | 57.2 |
| nonstrict | spCrash | 5 | budget_stopped |  | 43165 |  | 240.4 |
| nonstrict | spShutdown | 0 | violation | Q1Terminal | 66 | 8 | 3.1 |
| nonstrict | spShutdown | 2 | budget_stopped |  | 103332 |  | 240.4 |
| nonstrict | spShutdown | 5 | budget_stopped |  | 59027 |  | 240.4 |
| nonstrict | taskTimeout | 0 | budget_stopped |  | 106629 |  | 240.5 |
| nonstrict | taskTimeout | 2 | budget_stopped |  | 75456 |  | 240.3 |
| nonstrict | taskTimeout | 5 | budget_stopped |  | 34373 |  | 240.5 |
| sag | abort | 0 | budget_stopped |  | 111867 |  | 240.4 |
| sag | abort | 2 | budget_stopped |  | 100209 |  | 240.5 |
| sag | abort | 5 | budget_stopped |  | 58745 |  | 240.4 |
| sag | acceptRaise | 0 | budget_stopped |  | 76898 |  | 240.5 |
| sag | acceptRaise | 2 | budget_stopped |  | 35958 |  | 240.5 |
| sag | acceptRaise | 5 | budget_stopped |  | 41869 |  | 240.5 |
| sag | cbFail | 0 | budget_stopped |  | 68956 |  | 240.4 |
| sag | cbFail | 2 | budget_stopped |  | 29894 |  | 240.4 |
| sag | cbFail | 5 | budget_stopped |  | 41567 |  | 240.5 |
| sag | cjCrash | 0 | budget_stopped |  | 203372 |  | 240.4 |
| sag | cjCrash | 2 | budget_stopped |  | 125732 |  | 240.5 |
| sag | cjCrash | 5 | budget_stopped |  | 69662 |  | 240.5 |
| sag | cpCrash | 0 | budget_stopped |  | 178787 |  | 240.4 |
| sag | cpCrash | 2 | violation | Q1Terminal | 77 | 6 | 4.7 |
| sag | cpCrash | 5 | budget_stopped |  | 19198 |  | 240.4 |
| sag | deadClient | 0 | budget_stopped |  | 131622 |  | 240.5 |
| sag | deadClient | 2 | budget_stopped |  | 52234 |  | 240.4 |
| sag | deadClient | 5 | budget_stopped |  | 33459 |  | 240.4 |
| sag | deleteJob | 0 | violation | S1ThreadsAlive | 14 | 6 | 2.7 |
| sag | deleteJob | 2 | pass_exhaustive |  | 5747 | 47 | 43.5 |
| sag | deleteJob | 5 | budget_stopped |  | 41150 |  | 240.4 |
| sag | netLoss | 0 | budget_stopped |  | 105524 |  | 240.4 |
| sag | netLoss | 2 | budget_stopped |  | 54515 |  | 240.5 |
| sag | netLoss | 5 | budget_stopped |  | 29286 |  | 240.4 |
| sag | rpcTimeout | 0 | budget_stopped |  | 158025 |  | 240.5 |
| sag | rpcTimeout | 2 | pass_exhaustive |  | 5747 | 47 | 44.2 |
| sag | rpcTimeout | 5 | budget_stopped |  | 42335 |  | 240.5 |
| sag | saveFail | 0 | budget_stopped |  | 74046 |  | 240.4 |
| sag | saveFail | 2 | pass_exhaustive |  | 5747 | 47 | 44.3 |
| sag | saveFail | 5 | budget_stopped |  | 40187 |  | 240.4 |
| sag | sjCrash | 0 | violation | S2TerminalFinal | 33580 | 26 | 37.6 |
| sag | sjCrash | 2 | budget_stopped |  | 114474 |  | 240.5 |
| sag | sjCrash | 5 | budget_stopped |  | 73036 |  | 240.4 |
| sag | spCrash | 0 | violation | Q1Terminal | 397 | 15 | 3.9 |
| sag | spCrash | 2 | violation | Q1Terminal | 18691 | 21 | 57.3 |
| sag | spCrash | 5 | budget_stopped |  | 42630 |  | 240.3 |
| sag | spShutdown | 0 | violation | Q1Terminal | 58 | 8 | 3.1 |
| sag | spShutdown | 2 | budget_stopped |  | 103233 |  | 240.4 |
| sag | spShutdown | 5 | budget_stopped |  | 60190 |  | 240.4 |
| sag | taskTimeout | 0 | budget_stopped |  | 90875 |  | 240.4 |
| sag | taskTimeout | 2 | budget_stopped |  | 54938 |  | 240.3 |
| sag | taskTimeout | 5 | budget_stopped |  | 34279 |  | 240.4 |
| sampling | abort | 0 | budget_stopped |  | 91447 |  | 240.4 |
| sampling | abort | 2 | budget_stopped |  | 105120 |  | 240.5 |
| sampling | abort | 5 | budget_stopped |  | 73833 |  | 240.4 |
| sampling | cjCrash | 0 | budget_stopped |  | 214291 |  | 240.6 |
| sampling | cjCrash | 2 | budget_stopped |  | 130860 |  | 240.5 |
| sampling | cjCrash | 5 | budget_stopped |  | 96731 |  | 240.5 |
| sampling | cpCrash | 0 | budget_stopped |  | 202034 |  | 240.5 |
| sampling | cpCrash | 2 | violation | Q1Terminal | 72 | 5 | 4.7 |
| sampling | cpCrash | 5 | budget_stopped |  | 30361 |  | 240.5 |
| sampling | deadClient | 0 | budget_stopped |  | 148197 |  | 240.4 |
| sampling | deadClient | 2 | budget_stopped |  | 58140 |  | 240.4 |
| sampling | deadClient | 5 | budget_stopped |  | 48039 |  | 240.4 |
| sampling | deleteJob | 0 | violation | S1ThreadsAlive | 14 | 5 | 2.5 |
| sampling | deleteJob | 2 | pass_exhaustive |  | 3299 | 46 | 27.4 |
| sampling | deleteJob | 5 | budget_stopped |  | 59830 |  | 240.4 |
| sampling | netLoss | 0 | budget_stopped |  | 116119 |  | 240.5 |
| sampling | netLoss | 2 | budget_stopped |  | 59446 |  | 240.5 |
| sampling | netLoss | 5 | budget_stopped |  | 39998 |  | 240.5 |
| sampling | rpcTimeout | 0 | budget_stopped |  | 170160 |  | 240.5 |
| sampling | rpcTimeout | 2 | pass_exhaustive |  | 3299 | 46 | 27.5 |
| sampling | rpcTimeout | 5 | budget_stopped |  | 61069 |  | 240.5 |
| sampling | sjCrash | 0 | violation | S2TerminalFinal | 53809 | 26 | 57.2 |
| sampling | sjCrash | 2 | budget_stopped |  | 117145 |  | 240.4 |
| sampling | sjCrash | 5 | budget_stopped |  | 94850 |  | 240.5 |
| sampling | spCrash | 0 | violation | Q1Terminal | 315 | 14 | 4.1 |
| sampling | spCrash | 2 | violation | Q1Terminal | 18691 | 21 | 58.7 |
| sampling | spCrash | 5 | budget_stopped |  | 56402 |  | 240.5 |
| sampling | spShutdown | 0 | violation | Q1Terminal | 58 | 8 | 2.9 |
| sampling | spShutdown | 2 | budget_stopped |  | 101556 |  | 240.4 |
| sampling | spShutdown | 5 | budget_stopped |  | 77981 |  | 240.5 |
| sampling | taskTimeout | 0 | budget_stopped |  | 109232 |  | 240.4 |
| sampling | taskTimeout | 2 | budget_stopped |  | 74901 |  | 240.4 |
| sampling | taskTimeout | 5 | budget_stopped |  | 51266 |  | 240.4 |
| swarm | abort | 0 | budget_stopped |  | 63286 |  | 240.5 |
| swarm | abort | 2 | budget_stopped |  | 78066 |  | 240.5 |
| swarm | abort | 4 | budget_stopped |  | 35844 |  | 240.4 |
| swarm | abort | 5 | violation | S4NoLostResult |  |  | 2.9 |
| swarm | busyReplace | 0 | budget_stopped |  | 57848 |  | 240.4 |
| swarm | busyReplace | 2 | budget_stopped |  | 22018 |  | 240.3 |
| swarm | busyReplace | 4 | pass_exhaustive |  | 14 | 6 | 3.8 |
| swarm | busyReplace | 5 | violation | S4NoLostResult |  |  | 2.7 |
| swarm | cjCrash | 0 | budget_stopped |  | 144117 |  | 240.4 |
| swarm | cjCrash | 2 | budget_stopped |  | 88293 |  | 240.5 |
| swarm | cjCrash | 4 | budget_stopped |  | 49043 |  | 240.5 |
| swarm | cjCrash | 5 | violation | S4NoLostResult |  |  | 2.9 |
| swarm | cpCrash | 0 | budget_stopped |  | 144594 |  | 240.4 |
| swarm | cpCrash | 2 | violation | Q1Terminal | 125 | 5 | 5.1 |
| swarm | cpCrash | 4 | violation | Q1Terminal | 127 | 6 | 6.5 |
| swarm | cpCrash | 5 | violation | S4NoLostResult |  |  | 2.8 |
| swarm | deadClient | 0 | budget_stopped |  | 97698 |  | 240.5 |
| swarm | deadClient | 2 | budget_stopped |  | 44962 |  | 240.5 |
| swarm | deadClient | 4 | budget_stopped |  | 23800 |  | 240.5 |
| swarm | deadClient | 5 | violation | S4NoLostResult |  |  | 2.7 |
| swarm | deleteJob | 0 | violation | S1ThreadsAlive | 14 | 5 | 2.6 |
| swarm | deleteJob | 2 | budget_stopped |  | 22228 |  | 240.5 |
| swarm | deleteJob | 4 | pass_exhaustive |  | 14 | 6 | 3.6 |
| swarm | deleteJob | 5 | violation | S4NoLostResult |  |  | 2.6 |
| swarm | gatherTimeout | 0 | budget_stopped |  | 56997 |  | 240.5 |
| swarm | gatherTimeout | 2 | budget_stopped |  | 21614 |  | 240.4 |
| swarm | gatherTimeout | 4 | pass_exhaustive |  | 14 | 6 | 3.6 |
| swarm | gatherTimeout | 5 | violation | S4NoLostResult |  |  | 2.8 |
| swarm | learnFail | 0 | budget_stopped |  | 56869 |  | 240.5 |
| swarm | learnFail | 2 | budget_stopped |  | 22091 |  | 240.4 |
| swarm | learnFail | 4 | pass_exhaustive |  | 14 | 6 | 3.7 |
| swarm | learnFail | 5 | violation | S4NoLostResult |  |  | 2.8 |
| swarm | netLoss | 0 | budget_stopped |  | 75045 |  | 240.4 |
| swarm | netLoss | 2 | budget_stopped |  | 31285 |  | 240.4 |
| swarm | netLoss | 4 | violation | S4NoLostResult | 4268 | 16 | 59.6 |
| swarm | netLoss | 5 | violation | S4NoLostResult |  |  | 2.8 |
| swarm | rpcTimeout | 0 | budget_stopped |  | 119501 |  | 240.4 |
| swarm | rpcTimeout | 2 | budget_stopped |  | 21939 |  | 240.4 |
| swarm | rpcTimeout | 4 | pass_exhaustive |  | 14 | 6 | 3.9 |
| swarm | rpcTimeout | 5 | violation | S4NoLostResult |  |  | 2.8 |
| swarm | sjCrash | 0 | violation | S2TerminalFinal | 36249 | 26 | 60.9 |
| swarm | sjCrash | 2 | budget_stopped |  | 83320 |  | 240.4 |
| swarm | sjCrash | 4 | budget_stopped |  | 40293 |  | 240.5 |
| swarm | sjCrash | 5 | violation | S4NoLostResult |  |  | 2.9 |
| swarm | spCrash | 0 | violation | Q1Terminal | 277 | 14 | 4.3 |
| swarm | spCrash | 2 | budget_stopped |  | 51018 |  | 240.5 |
| swarm | spCrash | 4 | violation | Q1Terminal | 7604 | 21 | 66.1 |
| swarm | spCrash | 5 | violation | S4NoLostResult |  |  | 2.8 |
| swarm | spShutdown | 0 | violation | Q1Terminal | 62 | 8 | 2.8 |
| swarm | spShutdown | 2 | budget_stopped |  | 77625 |  | 240.4 |
| swarm | spShutdown | 4 | budget_stopped |  | 35637 |  | 240.5 |
| swarm | spShutdown | 5 | violation | S4NoLostResult |  |  | 2.9 |
| swarm | swarmMsgFail | 0 | budget_stopped |  | 57255 |  | 240.5 |
| swarm | swarmMsgFail | 2 | budget_stopped |  | 22311 |  | 240.5 |
| swarm | swarmMsgFail | 4 | pass_exhaustive |  | 14 | 6 | 4.0 |
| swarm | swarmMsgFail | 5 | violation | S4NoLostResult |  |  | 2.8 |
| swarm | taskTimeout | 0 | budget_stopped |  | 69379 |  | 240.4 |
| swarm | taskTimeout | 2 | budget_stopped |  | 47637 |  | 240.5 |
| swarm | taskTimeout | 4 | budget_stopped |  | 23274 |  | 240.5 |
| swarm | taskTimeout | 5 | violation | S4NoLostResult |  |  | 2.5 |
| taskmode | abort | 0 | error |  | 1297 | 22 | 6.2 |
| taskmode | abort | 2 | error |  | 1409 | 12 | 5.9 |
| taskmode | abort | 5 | no_checkpoint |  |  |  |  |
| taskmode | cjCrash | 0 | error |  | 15219 | 21 | 12.1 |
| taskmode | cjCrash | 2 | violation_evalerror | Q1Terminal | 1662 | 10 | 5.7 |
| taskmode | cjCrash | 5 | no_checkpoint |  |  |  |  |
| taskmode | cpCrash | 0 | violation | Q1Terminal | 16056 | 20 | 15.7 |
| taskmode | cpCrash | 2 | violation | Q1Terminal | 41 | 5 | 4.0 |
| taskmode | cpCrash | 5 | no_checkpoint |  |  |  |  |
| taskmode | ctrlLoss | 0 | error |  | 413 | 22 | 4.9 |
| taskmode | ctrlLoss | 2 | violation_evalerror | Q1Terminal | 50 | 10 | 3.5 |
| taskmode | ctrlLoss | 5 | no_checkpoint |  |  |  |  |
| taskmode | deadClient | 0 | error |  | 3398 | 21 | 8.4 |
| taskmode | deadClient | 2 | violation_evalerror | Q1Terminal | 335 | 10 | 4.9 |
| taskmode | deadClient | 5 | no_checkpoint |  |  |  |  |
| taskmode | deleteJob | 0 | violation | S1ThreadsAlive | 13 | 6 | 3.0 |
| taskmode | deleteJob | 2 | violation_evalerror | Q1Terminal | 49 | 10 | 3.6 |
| taskmode | deleteJob | 5 | no_checkpoint |  |  |  |  |
| taskmode | netLoss | 0 | error |  | 3272 | 22 | 8.4 |
| taskmode | netLoss | 2 | violation_evalerror | Q1Terminal | 365 | 9 | 5.1 |
| taskmode | netLoss | 5 | no_checkpoint |  |  |  |  |
| taskmode | rpcTimeout | 0 | error |  | 11047 | 22 | 12.9 |
| taskmode | rpcTimeout | 2 | violation_evalerror | Q1Terminal | 53 | 10 | 3.7 |
| taskmode | rpcTimeout | 5 | no_checkpoint |  |  |  |  |
| taskmode | settleTimeout | 0 | error |  | 446 | 22 | 5.0 |
| taskmode | settleTimeout | 2 | violation_evalerror | Q1Terminal | 53 | 10 | 3.4 |
| taskmode | settleTimeout | 5 | no_checkpoint |  |  |  |  |
| taskmode | sjCrash | 0 | violation | S2TerminalFinal | 1113 | 20 | 4.5 |
| taskmode | sjCrash | 2 | violation_evalerror | Q1Terminal | 494 | 10 | 4.7 |
| taskmode | sjCrash | 5 | no_checkpoint |  |  |  |  |
| taskmode | spCrash | 0 | violation | Q1Terminal | 133 | 12 | 3.4 |
| taskmode | spCrash | 2 | violation_evalerror | Q1Terminal | 460 | 12 | 5.3 |
| taskmode | spCrash | 5 | no_checkpoint |  |  |  |  |
| taskmode | spShutdown | 0 | violation | Q1Terminal | 59 | 9 | 3.1 |
| taskmode | spShutdown | 2 | error |  | 3016 | 11 | 6.8 |
| taskmode | spShutdown | 5 | no_checkpoint |  |  |  |  |
| taskmode | taskDeadline | 0 | error |  | 410 | 22 | 4.7 |
| taskmode | taskDeadline | 2 | violation_evalerror | Q1Terminal | 52 | 10 | 3.6 |
| taskmode | taskDeadline | 5 | no_checkpoint |  |  |  |  |
| taskmode | taskStageFail | 0 | error |  | 427 | 22 | 5.0 |
| taskmode | taskStageFail | 2 | violation_evalerror | Q1Terminal | 46 | 10 | 3.7 |
| taskmode | taskStageFail | 5 | no_checkpoint |  |  |  |  |
| taskmode | taskTimeout | 0 | error |  | 601 | 22 | 5.0 |
| taskmode | taskTimeout | 2 | violation_evalerror | Q1Terminal | 96 | 10 | 4.1 |
| taskmode | taskTimeout | 5 | no_checkpoint |  |  |  |  |
| taskmode | workerCrash | 0 | error |  | 437 | 22 | 4.4 |
| taskmode | workerCrash | 2 | violation_evalerror | Q1Terminal | 50 | 10 | 3.5 |
| taskmode | workerCrash | 5 | no_checkpoint |  |  |  |  |
| taskmode | workerFail | 0 | error |  | 427 | 22 | 4.8 |
| taskmode | workerFail | 2 | violation_evalerror | Q1Terminal | 49 | 10 | 3.6 |
| taskmode | workerFail | 5 | no_checkpoint |  |  |  |  |
