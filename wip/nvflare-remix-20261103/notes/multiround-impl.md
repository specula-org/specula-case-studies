# Multi-round FedAvg (payload re-keyed per transaction): implementation log

Agent: multi-round. Started 2026-11-04 00:50 UTC. Owns PortsPay, PaySrc_{C,F}, PayRcv_{C,F}, registry.d/pay.json, PortsFed, TaskCJ_{C,F}, CommSJ_{C,F}, WfSJ_{C,F}, registry.d/fed.json and the pay_*/fed_* scripts. Goal: Rounds >= 2 end to end so that S02/H02 (send() tail clear_cache nulls the successor input) can be checked in the full composition.

Backup of every owned file before the change: `.build/mr/backup-0050/`. Development happens in a staged copy of spec/ (`.build/mr/spec`, used through `MIX_SPEC`/`MIX_BUILD`), so spec/ stays green; the owned files are installed into spec/ only after gen_mix + SANY pass on the copy.

## Plan (00:50)

1. Port shapes (PortsPay): one result transaction per (site, launch, attempt); attempt = round.
2. Rounds parameter (PortsFed): `Rounds == MaxAttempt` (mkmc `--attempt N`), no coordinator change needed.
3. Generator (pay_gen.py) re-keys PaySrc_F to `paySrc_f[si][ln][a]` and PayRcv_F to `payRcv_f[si][a]`; coarse variants by hand.
4. TaskCJ/CommSJ read the per-round port slots.
5. Checks: harness refinement (pay_ref.py), fed refinement (gen_ref/fed_ref), S02 in the full composition, NotJobFinished witness at Rounds = 2.

## What changed (checkpoint 01:15)

Ports (spec/PortsPay.tla, spec/PortsFed.tla):
- `pPaySrc[c][l].tx[a]` = [registered, outcome, released], one result transaction Tx(c, l, a) per (site, launch, attempt); `pPayRcv[c].rx[a]` = [want, materialized, status, returned, fatal], one receiver attempt per (site, round). a = attempt = FedAvg round.
- Compatibility view kept in the same records: `pPaySrc[c][l].registered/outcome/released` = latest registered attempt; `pPayRcv[c].want/materialized/status/returned` = latest accepted round; `pPayRcv[c].fatal` = any round fatal (Ports!SJFatal unchanged). Written only through `SrcTxSet` / `RcvRxSet`, so all variants share the encoding. With MaxAttempt = 1 the view is the former port exactly.
- Wire ids already embed the ref `Ref(c, l, a)` (PULL/REPLY `<<"pull", ref, n, k>>`, CONFIRM/CANCEL `<<kind, ref, g>>`); the serve nonce is now `<<"nonce", c, l, a>>`. Retries (k, n) and later rounds never reuse a key.
- `Rounds == MaxAttempt` (mkmc `--attempt N`); no coordinator file changed.

Variants:
- PaySrc_C / PaySrc_F: private state per (si, ln, a); Register(si, ln, a) is driven by the round-a submission (`pTaskCJ[si][ln].submission.assignment.attempt = a`). ServeUnknownRef/ServeUnknown are per (si, ln) (ref matches no registered attempt; stateless in F, the reply key is the record). CJ DownloadService.shutdown covers every transaction of the process: `DSShutdownPending(si, ln)` = dsDown and some registered tx not yet shut, so only the per-tx Shutdown steps interleave (port-invisible, equivalent to one atomic call).
- PayRcv_C / PayRcv_F: private state per (si, a); SourceDownloadRegister / Accept for round a = the exposed envelope's assignment attempt. SJ DownloadService.shutdown (ShutdownSourceDownloads) is one step over all (si, a).
- Generator: `scripts/pay_gen.py` emits the re-keyed fine modules (`rekey_src`, `rekey_rcv` for the hand-written wire overrides; generic seed actions get `a` in signature, `st` and EXCEPT path). `MIX_SPEC` selects the output spec dir. Action counts unchanged: PaySrc_F 93, PayRcv_F 23.
- TaskCJ_C/F: the envelope names the descriptor of Tx(c, l, round) (`TxReg(c, l)`); each round's submission registers its own tx. CommSJ_C/F: claim/decode/RETRY/APP_CALL value read the receiver attempt of the envelope's round (`Rx(c, a)`, `RxOf(k)`). WfSJ unchanged (already per round).
- Scripts: pay_ref.py (`--attempt`; chaotic env submits/exposes per round, increasing), pay_mc.py (`--attempt`), fed_mkmc.py (`--attempt`, `--inv mr`, per-round port invariants, S02Round2, S02Directed, NotFinished2Rounds), fed_ref.py (`--attempt`).
- Port request filed (notes/port-requests.md 01:15): per-round Props forms, gen_ref `--attempt`.

## Checks (dev copy `.build/mr/spec`, env `MIX_SPEC=MIX_BUILD=.build/mr/spec MIX_INCLUDE_WIP=TaskCJ,CommSJ,WfSJ`)

| run | command | result |
|---|---|---|
| static + SANY | `gen_mix.py`; `tlc.sh sany Mix.tla` | pass (20 variants with WIP) |
| all-coarse, Rounds=1 regression (sim) | `fed_mkmc.py mr_allC_fin1 --sites 1 --attempt 1 --inv default --extra-inv NotJobFinished`; `run_mc.py mr_allC_fin1 --mode sim --depth 300,1e8 --timeout 180 --workers 8` | NotJobFinished violated (job finishes) in 2 s; old Props PORT_INVS + FedPortSafety hold along the trace |
| all-coarse, Rounds=2, round-2 input (sim) | `fed_mkmc.py mr_allC_w2 --sites 1 --attempt 2 --inv MRPortSafety,FedPortSafety,NotJobFinished,NotRound2Input` | NotRound2Input violated in 3 s, but through a coarse CommSJ_C re-assignment of round 1 (SendAssignment picks any r <= Cur), not a real round 2 |
| all-coarse, Rounds=2, job FINISHED after both rounds (sim) | `fed_mkmc.py mr_allC_fin2 --sites 1 --attempt 2 --inv MRPortSafety,FedPortSafety,NotFinished2Rounds`; `run_mc.py ... --mode sim --depth 400,1e8 --timeout 300 --workers 8` | **NotFinished2Rounds violated in 31 s, 126 steps** (checks/fed/mr_allC_fin2.ce.txt): ScheduleTask r1 (17), Register tx1 (33), Accept rx1 (36), Save r1 (60), ScheduleTask r2 (64), Register tx2 (72), Accept rx2 (77), Save r2 (101), EndRun (103), Classify/PublishTerminal FINISHED (125-126); MRPortSafety and FedPortSafety hold along it |
| PayRcv_F ⊑ PayRcv_C harness, Rounds=1 | `pay_ref.py mr_rcv_nofault --src C --rcv F --check rcv --run` | PASS exhaustive, 9,935 states, depth 33 (identical to the pre-change receipt) |
| same, negative | `... --negative` | BadStep violated (as required) |
| PaySrc_F ⊑ PaySrc_C harness, Rounds=1 | `pay_ref.py mr_src_nofault --src F --rcv C --check src --run --timeout 600 --workers 12` | PASS exhaustive, 1,697,432 states, depth 110, 3m20s (identical to the pre-change receipt) |
| PayRcv_F ⊑ PayRcv_C harness, Rounds=2 | `pay_ref.py mr_rcv_nofault_a2 --src C --rcv F --check rcv --attempt 2 --run --timeout 240 --workers 8` | budget-stopped, no violation, 1,337,112 states, depth 36 (two receiver attempts interleave freely in the chaotic env: product space) |
| S02, Trainer=F, TaskCJ=C, rest C, 1 site, Rounds=2 (sim) | `fed_mkmc.py mr_s02_tc_sim --grain Trainer=F,TaskCJ=C --sites 1 --attempt 2 --inv S02Round2,MRPortSafety,FedPortSafety`; `run_mc.py ... --mode sim --depth 400,1e8 --timeout 300 --workers 8` | budget-stopped, no violation in 31,908 traces (mean length 34): random traces rarely keep the trainer in its send() tail through a whole round |

01:27: owned files installed into spec/ (copied from the dev copy; `pay_gen.py` without MIX_SPEC regenerates byte-identical PaySrc_F/PayRcv_F). `gen_mix.py` + SANY pass on spec/Mix.tla (17 variants) and on the WIP build `.build/mr/wip` (20 variants). From here runs use `MIX_BUILD=.build/mr/wip MIX_INCLUDE_WIP=TaskCJ,CommSJ,WfSJ` on spec/.

## S02 in the full composition (1 site, Rounds = 2, Trainer = F, all other groups coarse except TaskCJ)

Directed BFS: `CONSTRAINT S02Directed` (fed_mkmc.py) prunes only states in which the trainer, after publishing a result, already went back to receive() with an empty slot before a newer input arrived (i.e. it keeps the trainer in its send() tail; the constraint removes states, so every CE found is a genuine behavior of the mix). Invariant `S02Round2` = Props `SuccessorInputPreserved` restricted to the genuine successor (the clobbered input is the round-2 task, assignment attempt 2), plus MRPortSafety and FedPortSafety.

| run | grain | result |
|---|---|---|
| `fed_mkmc.py mr_s02_tc_dbfs --grain Trainer=F,TaskCJ=C --sites 1 --attempt 2 --inv S02Round2,MRPortSafety,FedPortSafety --constraint S02Directed`; `run_mc.py mr_s02_tc_dbfs --timeout 900 --workers 12 --heap 12g` | TaskCJ=C | **S02Round2 violated**, 22 s, 59,753 distinct states, depth 62; CE 59 steps (checks/fed/mr_s02_tc_dbfs.ce.txt) |
| same with `--grain Trainer=F,TaskCJ=F` (`mr_s02_tf_dbfs`) | TaskCJ=F | **S02Round2 violated**, 18 s, 38,466 distinct states, depth 66; CE 62 steps (checks/fed/mr_s02_tf_dbfs.ce.txt) |

CE (TaskCJ=F, `ce.py mr_s02_tf_dbfs -v`): job admitted and CJ launched (2-12); round 1: GET_TASK, SCHEDULE, ASSIGNED (13-19); ExecutorPublishTask gen 1 -> Trainer_F Start/Callback/Receive/Train/Publish (20-25; published gen 1, trainer now in the send() tail, pc "tail", slot 1); ExecutorPublished, ClientProcessTask (TASK_CHECK), RETRY, ClientSerializeResult, PaySrc Register Tx(s1,1,1), RESULT_ENVELOPE (26-32); PayRcv rx[1] pulls and materializes (33-43); Claim, Dispatch, Count, Accept, RECEIVED, Retire, CloseRound, Aggregate, Save round 1 (44-53); CJ polls again, StartRound 2, Schedule, ScheduleTask(2), ASSIGNED round 2 (54-59); ExecutorPublishTask gen 2 (input attempt 2) (60); Trainer_F Callback: slot 2, received 2 (61); **Trainer_F ClearCache (round-1 send() tail, api.py:228-239): slot 0 while received 2 > published.gen 1** (62). The executor is now waiting in ExecutorPublished/ClientProcessTask for a result the trainer can never produce (receive() finds no fl_model): the H02 hang. The TaskCJ=C CE has the same shape (59 steps: TaskCJ_C RecvAssignment/PublishInput instead of the fine executor steps).

Unconstrained BFS with the Props invariant itself (`--inv SuccessorInputPreserved,MRPortSafety,FedPortSafety`, no constraint):

| run | grain | result |
|---|---|---|
| `mr_s02_tf_bfs` | Trainer=F, TaskCJ=F, rest C | SuccessorInputPreserved violated, 7 s, 13,661 distinct, depth 58; CE 55 steps (checks/fed/mr_s02_tf_bfs.ce.txt) |
| `mr_s02_tc_bfs` | Trainer=F, TaskCJ=C, rest C | SuccessorInputPreserved violated, 11 s, 28,126 distinct, depth 55 (checks/fed/mr_s02_tc_bfs.ce.txt) |

Triage: the shortest CE does not reach round 2. After RECEIVED for round 1 (step 48), the CJ polls again and CommSJ_C SendAssignment answers ASSIGNED with the round-1 assignment again (step 51; coarse picks any r <= Cur), the executor publishes it as task 2 (gen 2, attempt 1), and the trainer's round-1 send() tail clears it. The clear itself is the H02 mechanism, but the second delivery of round 1 after its result was received is a coarse CommSJ over-approximation: CommSJ_F serves a task request only for a standing LIVE task that is not yet assigned to the site (WFCommProcessTaskRequest, `~ct[t][c].assigned`), and resends only without result_received_time (wf_comm_server.py:246-257). Class (b); zoom-in with CommSJ = F below.

Zoom-in (coarse groups that acted in the artifact CE refined: CommSJ = F), unconstrained BFS, Props `SuccessorInputPreserved` + MRPortSafety + FedPortSafety (+ no group invariants), 12 workers:

| run | grain | result |
|---|---|---|
| `fed_mkmc.py mr_s02_tfc_bfs --grain Trainer=F,TaskCJ=F,CommSJ=F --sites 1 --attempt 2 --inv SuccessorInputPreserved,MRPortSafety,FedPortSafety`; `run_mc.py mr_s02_tfc_bfs --timeout 900 --workers 12 --heap 12g` | Trainer, TaskCJ, CommSJ = F | **SuccessorInputPreserved violated via the genuine round 2**, 47 s, 90,341 distinct states, depth 91; CE 88 steps (checks/fed/mr_s02_tfc_bfs.ce.txt) |
| `mr_s02_tcc_bfs` (same, TaskCJ = C) | Trainer, CommSJ = F | **violated via round 2**, 1m50s, 299,606 distinct, depth 87; CE 85 steps (checks/fed/mr_s02_tcc_bfs.ce.txt) |

CE mr_s02_tfc_bfs (TaskCJ/CommSJ/Trainer fine): round 1 is scheduled (WFCommScheduleTask), served through the fine request path, executed (Trainer_F Callback/Receive/Train/Publish: trainer enters the send() tail), submitted (TASK_CHECK RETRY, serialize, PaySrc Register Tx(s1,1,1), RESULT_ENVELOPE), decoded by PayRcv rx[1], processed by the fine runner (ServerRunnerProcessSubmission/SubmissionActive/CheckSubmission, WFCommClaimSubmission, AcquireSubmission, DispatchSubmission) and accepted (WfSJ_C Count/Accept, WFCommStampReceipt RECEIVED, 52-60); TaskCJ_F consumes RECEIVED and polls again (61-62); the monitor retires the finished task (WFCommMonitorBegin..Remove, 63-69); CloseRound, Aggregate, Save, StartRound 2, Schedule (70-75); WFCommScheduleTask(2), the poll is served for round 2 (ServerRunnerTaskRequestActive .. ServerRunnerFilterTask, 76-84); ClientReceiveTask, ExecutorPublishTask gen 2 with assignment attempt 2 (85-86); Trainer_F Callback slot 2, received 2 (87); Trainer_F ClearCache: slot 0 (88). The trainer thread has been in its round-1 send() tail (after publish_result returned, before `self.fl_model = None`, api.py:228-239) for steps 25-88. Classification: (c), the known Phase 1 H02 behavior, now reached in the full composition with the three involved groups fine; the CE needs no fault. It matches the component-harness CE (checks/trainer, TrainerS02.cfg) and the forced-schedule reproduction on pin c411a201 (checks/confirm/s02_repro.py). Evidence level unchanged: model-level REPRODUCED in composition, real-code reproduction only under a forced schedule.

## Witness: two rounds complete and the job finishes (Rounds = 2, 1 site)

| run | grain | result |
|---|---|---|
| `mr_allC_fin2` (above) | all coarse | NotFinished2Rounds violated, 31 s sim, 126 steps |
| `fed_mkmc.py mr_tf_fin2 --grain Trainer=F,TaskCJ=F --sites 1 --attempt 2 --inv MRPortSafety,FedPortSafety,NotFinished2Rounds`; `run_mc.py mr_tf_fin2 --mode sim --depth 400,1e8 --timeout 400 --workers 12` | Trainer = F, TaskCJ = F | **NotFinished2Rounds violated in 4 s (sim), 134 steps** (checks/fed/mr_tf_fin2.ce.txt): round 1 ScheduleTask (19), Trainer_F Callback (26), ClearCache before the next input (31), Register Tx(s1,1,1) (36), rx[1] Accept (39), WfSJ Accept/Save (58/64); round 2 ScheduleTask (68), Callback gen 2 (72), ClearCache (78), Register Tx(s1,1,2) (82), rx[2] Accept (85), Accept/Save (104/110), TOPIC_STOP (119), PublishTerminal FINISHED (134). MRPortSafety/FedPortSafety hold along it |

`NotFinished2Rounds == ~(pJobSP.terminal = "FINISHED" /\ pWfSJ.scheduled = Rounds /\ pWfSJ.returned = "normal")`, so its violation is the NotJobFinished witness restricted to runs where both rounds were scheduled and the last round saved.

## Payload harness reruns on the re-keyed variants (Rounds = 1; `.build/mr/pay_batch.sh`, logs/mr_pay_batch.out)

| run | faults | result | states (pre-change) |
|---|---|---|---|
| mr_src_nofault | - | PASS exhaustive | 1,697,432 (1,697,432) |
| mr_src_nofault_neg | - (negative) | BadStep violated, as required | 62 (62) |
| mr_rcv_nofault | - | PASS exhaustive | 9,935 (9,935) |
| mr_rcv_nofault_neg | - (negative) | BadStep violated, as required | 247 |
| mr_rcv_s10 | cjCrash,taskTimeout | PASS exhaustive | 10,804 (10,804) |
| mr_rcv_h29 | cjCrash,transportFail | PASS exhaustive | 15,406 (15,406) |

### Why the 1-round payload receipts cover the per-round slices (argument, not a check)

Every PaySrc action except ServeUnknownRef is indexed by (si, ln, a) and writes only paySrc_x[si][ln][a] and pPaySrc[si][ln].tx[a] (through SrcTxSet, which recomputes the compatibility view deterministically from the tx map); every PayRcv action except ShutdownSourceDownloads is indexed by (si, a) and writes only payRcv_x[si][a] and pPayRcv[si].rx[a] (through RcvRxSet). AbsC is the per-slice map of the 1-round AbsOne. The only cross-slice reads are DSShutdownPending (F only; it blocks steps, port-invisible Shutdown steps run in between), SJShutdownPending (F only, same), ServeUnknownRef/ServeUnknown (identical guard in F and C: the ref matches no registered attempt) and the view fields, which are a function of the per-slice records that F and C write identically. So a fine slice-a step maps to the coarse slice-a step exactly as in the 1-slice harness, whose chaotic environment already lets the slice see any submission/envelope/CJ/SJ history. The bounded 2-round harness BFS (mr_rcv_nofault_a2, 1.34M states, no violation) is consistent with this; an exhaustive 2-slice harness check is out of budget because the chaotic env interleaves the two transactions freely (product space).
| mr_rcv_s12 | taskTimeout,pullTimeout | PASS exhaustive | 330,204 (330,204) |
| mr_rcv_s19 | pullTimeout,txTimeout | PASS exhaustive | 699,480 (699,480) |
| mr_src_s10 | cjCrash,taskTimeout | PASS exhaustive, 4m22s | 1,814,864 (1,814,864) |

Every re-keyed receipt reproduces the pre-change state count exactly: at MaxAttempt = 1 the re-keyed variants are state-for-state the former ones.
| mr_rcv_s10L | cjCrash,taskTimeout,netLoss | PASS exhaustive, 4m28s | 2,950,993 (2,950,993) |

## Fed refinement at Rounds = 2 (1 site, no faults, all other groups coarse; `.build/mr/fed_batch.sh`, logs/mr_fed_batch.out)

Built with `fed_ref.py <G> F C --name mr_ref2_<G> --sites 1 --attempt 2 [--negative]` (= gen_ref.py's RefInit + RefStep + RefEnv, plus `--attempt`), run with `run_mc.py ... --timeout 420 --workers 12 --heap 12g`.

| group | negative (BadStep) | RefInit/RefStep/RefEnv |
|---|---|---|
| TaskCJ | violated as required (657 states, depth 24) | budget-stopped at 420 s, no violation, 462,392 distinct, depth 94 |
| CommSJ | violated as required (15,333 states, depth 53) | budget-stopped at 420 s, no violation, 515,248 distinct |
| WfSJ | violated as required (344 states, depth 18) | (below) |
| WfSJ | (above) | budget-stopped at 420 s, no violation, 716,241 distinct, depth 80 |

No refinement check at Rounds = 2 completed exhaustively in the full composition (as at Rounds = 1, where the fed agent's official gen_ref runs stopped at 1.6-1.8M states); every negative control fires. TaskCJ/CommSJ/WfSJ F stay `"wip": true`.

## S02 through the official campaign tool

Scenario file `checks/fed/scenarios_multiround.json` (S02r2: Trainer, TaskCJ fine; S02r2z: + CommSJ fine; attempt 2, 1 site, inv SuccessorInputPreserved, BFS). Command: `MIX_BUILD=.build/mr/wip MIX_INCLUDE_WIP=TaskCJ,CommSJ,WfSJ python3 scripts/campaign.py --file checks/fed/scenarios_multiround.json --only <id> --parallel 1 --workers 12 --heap 12g`.

| run | result | distinct | depth | wall | transfer missing |
|---|---|---|---|---|---|
| cmp_S02r2_s1 | SuccessorInputPreserved violated (coarse CommSJ re-assignment of round 1, class (b), as mr_s02_tf_bfs) | 13,514 | 58 | 10 s | JobSP, JobCP, RunCJ, PaySrc, PayRcv, CommSJ, WfSJ |
| cmp_S02r2z_s1 | **SuccessorInputPreserved violated via round 2** (input attempt 2 cleared by ClearCache, 88 steps; checks/fed/cmp_S02r2z_s1.ce.txt) | 90,250 | 91 | 61 s | JobSP, JobCP, RunCJ, PaySrc, PayRcv, WfSJ |

(The scenario in the coordinator's checks/scenarios.json has no `"attempt"`, i.e. Rounds = 1, where S02 is unreachable; suggest `"attempt": 2` and `"fine": ["Trainer", "TaskCJ", "CommSJ"]`.)

## S02 zoom-in with the workflow fine too

| run | grain | result |
|---|---|---|
| `fed_mkmc.py mr_s02_f4_bfs --grain Trainer=F,TaskCJ=F,CommSJ=F,WfSJ=F --sites 1 --attempt 2 --inv SuccessorInputPreserved,MRPortSafety,FedPortSafety`; `run_mc.py mr_s02_f4_bfs --timeout 900 --workers 14 --heap 14g` (unconstrained BFS) | Trainer, TaskCJ, CommSJ, WfSJ = F | **SuccessorInputPreserved violated via round 2** (input attempt 2), 3m30s, 396,541 distinct states, depth 114; CE 111 steps (checks/fed/mr_s02_f4_bfs.ce.txt): the full FedAvg round 1 (FedAvgRoundStarted .. WFCommScheduleTask, FedAvgCheckRoundGuard/AggregateOneResult/IncrementReceived, FedAvgCloseRound, BuildAggregateResult, BaseFedAvgUpdateModel, FedAvgSaveModel, FedAvgAdvanceRound), FedAvgRoundStarted round 2, WFCommScheduleTaskCall/ScheduleTask, round-2 delivery, Trainer_F Callback (110), ClearCache (111). Trainer_F published at step 36 and stays in its send() tail for 75 steps |
| `mr_s02_f6_dbfs` (directed BFS, `--constraint S02Directed`) | Trainer, TaskCJ, CommSJ, WfSJ, PaySrc, PayRcv = F | budget-stopped at 900 s, no violation, 1,822,959 distinct states, depth 125 (fine payload pulls/settlement push the round-2 delivery deeper than the budget reaches) |
| `mr_s02_f6_dbfs` rerun after the dsDown change, `--timeout 1080 --workers 16 --heap 16g` | same | budget-stopped at 1080 s, no violation, 2,871,578 distinct, depth 130 (not reached) |
| `mr_s02_f6_dsim` (directed simulation, 600 s) | same | inconclusive: only 14 traces generated (constraint-cut traces) |

## Open problems

1. Props port request pending (notes/port-requests.md 01:15): at MaxAttempt >= 2, Props `MaterializedIsRegistered` is spuriously violated through the compatibility view and `ReceivedReceiptMeansFinished`/`ReceivedMeansAccepted` through round-1 receipts that outlive the per-round reset; multi-round mixes must use `fed_mkmc.py --inv mr` (MRPortSafety) until the per-round forms are in Props. The mkmc default PORT_INVS (and campaign default inv) are only correct at MaxAttempt = 1.
2. gen_ref.py has no `--attempt`; Rounds = 2 refinement runs used fed_ref.py, so no official receipt for attempt 2 exists. None of the Rounds = 2 fed refinement runs is exhaustive (TaskCJ 462k, CommSJ 515k, WfSJ 716k states at 420 s); the payload 2-slice harness is bounded (1.34M) and the per-slice argument above carries the 1-round exhaustive receipts over.
3. Coarse CommSJ_C SendAssignment may answer a later poll with any round <= Cur, including a round whose result was already received; this produced the class (b) S02 CE (mr_s02_tf_bfs / cmp_S02r2_s1). Tightening it (only standing rounds not yet finished by the site, plus resend without receipt) needs a CommSJ refinement re-check; until then run S02 with CommSJ = F or use S02Round2.
4. Poll budget FedMaxPoll = Rounds (+1 under loss/prepFail): a poll answered TRY_AGAIN (round 1 done, round 2 not yet scheduled) consumes the budget, so those interleavings never reach round 2. Safe for the CEs found (all are real mix behaviors) but it under-approximates coverage of the real unbounded poll loop.
5. S11 (delayed CANCEL fails a new tx that reused the ref id) is still not expressible: refs are unique per transaction (Ref(c, l, a)). A ref-reuse mode would need TaskCJ/PaySrc to register the same ref for two attempts.
6. One exposed envelope per (site, round) in CommSJ (fed slice): a straggler envelope of round r that arrives during round r+1 is never decoded, so cross-round straggler decode hazards (H30 across rounds) are out of reach.
7. Random simulation rarely reaches S02 (mean trace length 34; the trainer must stay in its send() tail for a whole round). Use BFS, or the directed `S02Directed` constraint, or campaign BFS.
8. The payload chaotic environment never resets `pCommSJ.envelopes` to None (CommSJ does at ScheduleTask); harmless because PayRcv reads it only positively, but it is an environment simplification.

## 02:15 coordinator request: CJ DownloadService.shutdown keyed on dsDown (T1)

- PaySrc_C `Shutdown(si, ln, a)` and PaySrc_F `Shutdown` (generator: `src_generic`, seed Shutdown guard) now require `Flag(pRunCJ[si][ln], "dsDown")`, i.e. RunCJ's run-finally ShutdownDownloadService step (client_runner.py:814-821), which carries timing assumption T1 (PortsJob!CJTeardownTimingOK, released by "slowSJTeardown"). Before, both fired on `pRunCJ.state = "stopping"` and escaped T1. A dead CJ needs no trigger: every PaySrc step requires CJAlive.
- Consequence fixed at the same time: with the trigger and the atomicity guard both on dsDown, a monitor pass holding the table lock (MonitorClassifyBegin..MonitorClassifyEnd) when dsDown is set would block forever (Shutdown needs ~tableLocked, every other step needs ~DSShutdownPending). `DSShutdownPending(si, ln)` now also requires that no transaction of the process holds the table lock: shutdown() waits for the table lock, and the other threads run until it gets it.
- Checks after the change: gen_mix + SANY pass (default and WIP). PaySrc harness reruns (`.build/mr/pay_batch2.sh`, logs/mr_pay_batch2.out) below. S02 zoom-in rerun `campaign.py --file checks/fed/scenarios_multiround.json --only S02r2z`: still violated via round 2, 90,534 distinct, 38 s (the CE has no PaySrc Shutdown step).

9. Re-keying duplicates service-wide seed state per transaction: each PaySrc_F transaction record has its own table lock (`tableLocked`) and clock (`now`), so two transactions of one CJ may be inside table-locked sections at the same time and their timeouts advance independently. This over-approximates (C also allows it), so it can only add spurious interleavings between transactions of different rounds; a shared per-process lock/clock record would remove them.

| run (after the dsDown trigger, Rounds = 1, harness) | faults | result | states |
|---|---|---|---|
| mr2_src_nofault_neg | - (negative) | BadStep violated, as required | 62 |
| mr2_src_nofault | - | PaySrc_F ⊑ PaySrc_C PASS exhaustive, 1m44s | 1,137,424 (fewer than 1,697,432: no shutdown before dsDown) |
| mr2_src_s10 | cjCrash,taskTimeout | PASS exhaustive, 1m51s | 1,254,856 |

PayRcv is unaffected by this change (its receipts above stand). H30 sanity (Rounds = 1, PaySrc = PayRcv = F, rest C, 1 site, sim 150 s, `pay_mc.py mr_h30_* --grain PaySrc=F,PayRcv=F --inv NoSJFatalDecode`; `run_mc.py ... --mode sim --depth 300,1e8 --timeout 150 --workers 12`):
- faults taskTimeout (T1 in force): NoSJFatalDecode not reached in 150 s (`mr_h30_sanity`; before the change the same mix violated in 3 s through a PaySrc Shutdown that escaped T1);
- faults taskTimeout, slowSJTeardown (T1 released): violated in 37 s (`mr_h30_slow`): WfSJ_C EndRun (48) -> RunCJ_C RecvEndRun (50) -> RunCJ_C ShutdownDS (dsDown, 53) -> PaySrc_F Shutdown (57) -> HandleDownloadMissing INVALID_REQUEST (58) -> PayRcv_F SourceDownloadUnregister fatal (60). The CJ's DS shutdown now always follows RunCJ's step.

## State at hand-off (02:3x)

- spec/: PortsPay, PortsFed, PaySrc_C/F, PayRcv_C/F, TaskCJ_C/F, CommSJ_C/F changed (WfSJ_C/F, registry fragments unchanged; TaskCJ/CommSJ/WfSJ F stay wip). `python3 scripts/gen_mix.py` + SANY on spec/Mix.tla pass (17 variants); WIP build `.build/mr/wip` (20 variants) passes. `scripts/pay_gen.py` regenerates PaySrc_F/PayRcv_F exactly.
- The staged dev copy `.build/mr/spec` was deleted after the install (no stale shadows); pre-change backup in `.build/mr/backup-0050/`, pre-dsDown copies of PaySrc_C/F and pay_gen.py in `.build/mr/`.
- No TLC job of this agent is left running.
