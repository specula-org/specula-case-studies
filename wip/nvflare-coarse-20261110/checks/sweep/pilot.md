# Sweep pilot

30 cells

| config | point | phase | result | violated | distinct | depth | s |
|---|---|---:|---|---|---:|---:|---:|
| fedavg | abort | 0 | violation | S2TerminalFinal | 194 | 16 | 3.5 |
| fedavg | abort | 2 | budget_stopped |  | 229792 |  | 180.4 |
| fedavg | abort | 5 | violation | S4Completed | 31621 | 19 | 39.1 |
| fedavg | cjCrash | 0 | violation | S2TerminalFinal | 26852 | 23 | 18.7 |
| fedavg | cjCrash | 2 | budget_stopped |  | 192858 |  | 180.4 |
| fedavg | cjCrash | 5 | budget_stopped |  | 100303 |  | 180.4 |
| fedavg | cpCrash | 0 | violation | Q1Terminal | 15782 | 20 | 14.8 |
| fedavg | cpCrash | 2 | violation | Q1Terminal | 106 | 7 | 5.0 |
| fedavg | cpCrash | 5 | pass_exhaustive |  | 13955 | 30 | 25.8 |
| fedavg | deleteJob | 0 | violation | S1ThreadsAlive | 14 | 6 | 3.1 |
| fedavg | deleteJob | 2 | budget_stopped |  | 70587 |  | 180.3 |
| fedavg | deleteJob | 5 | pass_exhaustive |  | 1227 | 27 | 8.2 |
| fedavg | spCrash | 0 | violation | Q1Terminal | 118 | 12 | 3.3 |
| fedavg | spCrash | 2 | violation | Q1Terminal | 482 | 12 | 5.3 |
| fedavg | spCrash | 5 | violation | Q1Terminal | 263 | 12 | 5.2 |
| fedavg | storeError | 0 | budget_stopped |  | 226709 |  | 180.4 |
| fedavg | storeError | 2 | budget_stopped |  | 67244 |  | 180.4 |
| fedavg | storeError | 5 | pass_exhaustive |  | 1227 | 27 | 7.7 |
| fedavg2 | deadClient | 0 | budget_stopped |  | 108006 |  | 180.3 |
| fedavg2 | deadClient | 2 | budget_stopped |  | 51193 |  | 180.3 |
| fedavg2 | deadClient | 5 | budget_stopped |  | 30899 |  | 180.3 |
| fedavg2 | regIterRace | 0 | violation | S1ThreadsAlive | 30 | 5 | 3.1 |
| fedavg2 | regIterRace | 2 | violation | S1ThreadsAlive | 43 | 5 | 3.8 |
| fedavg2 | regIterRace | 5 | violation | S1ThreadsAlive | 27 | 4 | 4.3 |
| k8s | cpCrash | 0 | violation | S3Resources | 135 | 13 | 3.8 |
| k8s | cpCrash | 2 | violation | S3Resources | 6 | 4 | 3.1 |
| k8s | cpCrash | 5 | violation | S3Resources | 2 | 2 | 3.2 |
| multijobcp | cjCrash | 0 | violation | S3Resources | 90 | 12 | 3.6 |
| multijobcp | cjCrash | 2 | budget_stopped |  | 186516 |  | 180.3 |
| multijobcp | cjCrash | 5 | budget_stopped |  | 109211 |  | 180.3 |
