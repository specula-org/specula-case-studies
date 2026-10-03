# Findings reconciliation and confirmation queue

This is the Phase 2 audit of historical leads, not a new bug-confirmation report. Source pin: 53ba7ee567468ea7971dad4faccef13c6cb35dc2. The original run ended during hunting, before the separate confirmation phase. “CONFIRMED” in copied analysis reports means the historical author ran the described probe; it does not mean the configured continuation confirmation has run.

Routes: **C** = eligible candidate to pass to the configured confirmation phase, with the stated trigger/contract checks; **Q** = policy, bounded behavior or reachability question requiring an explicit disposition; **D** = defensive/unsupported case, retain separately unless a supported trigger is established. **O** denotes an out-of-model gap, not necessarily outside the user's scope. No severity is assigned here. V01–V10 refer to [model-audit.md](model-audit.md).

All F/RS/CL/SE/E names are historical source-derived leads unless the MC table explicitly says otherwise. Newly recovered omissions are not new GPT model-checking discoveries. Confirmation should deduplicate common root causes while retaining each distinct trigger, consequence and passing control. It must not drop a lower-priority row merely because the main report omitted it.

## Main analysis F1–F20 and R1

Source abbreviations are defined in model-audit.md. Original commands, scripts, stdout and controls remain under ../evidence; paths containing /home/experiment or transient /tmp locations require adaptation in working copies.

| ID / route | Audited mechanism and evidence | Required disposition or confirmation |
|---|---|---|
| F1 **C** | JR:661–711 checks status before deployment/start, then blindly writes DISPATCHED/RUNNING. JC:1058–1066 acknowledges a SUBMITTED/DISPATCHED abort using only a store write. Historical lifecycle A1/A2 and trace abort_during_deploy choose the window. I4 adds deployment-metadata RMW; I5 adds FAILED_TO_RUN overwrite. | Public abort overlapping actual deploy/start, with a nonoverlap control and evidence of acknowledgment followed by launch/status regression. Preserve MC-B completion-writer variant; distinguish launch already begun from launch after acknowledgment. V01/V03/V04. |
| F2 **C** | Scan/list/read deletion (RS-1), held-job status read, and unprotected exception-handler store writes can end the single runner. Historical G1/G2/N1/N1c and K2v use real store/handlers with fake process/RPC edges. | Public delete with real authorization snapshot, runner death, and a later feasible job remaining unadmitted. Separate scan failure, runner failure after start, and MC-C/D consequences. V01/V05. |
| F3 **C** | JR:709–711 inserts tracking before writing RUNNING; completion can publish/remove first. Historical B/N5-related traces gate this scheduling window. | Real early SJ failure/exit plus delayed RUNNING write, demonstrate terminal-to-RUNNING and lost tracking. An error exit is a stronger supported trigger than an unexplained instantly successful SJ. V03/V04. |
| F4 **C** | Validator int-checks without normalizing raw metadata; null bypasses validation. Scheduler compares raw min_clients at :166/:229; whole-pass catch skips history/backoff. RS-6/N6/N6s and l9_l1_probe include numeric string, null and nested process-string shapes. Null can reserve before throwing each pass. | Submit a hand-written job ZIP through a supported public submit path; FedJob's typed API alone does not establish reachability. Retain valid-job control, later-job starvation and actual resource/TTL behavior. Internal malformed schedule_* metadata is a separate defensive case. Pre-poison liveness cfg does not cover null/post-reservation accumulation. |
| F5 **C** | RS-4: accepted client failure during START calls fail_run, removes pending entry, then JR:360 indexes it; FAILED_TO_RUN and stale exception record follow. Historical N3 vs N3c uses the real handler with stubbed edges. | Public start/report ordering; verify whether the failure should override a genuine start failure under the authoritative-failure comment at JR:837. Distinguish KeyError from legitimate explicit START error. Stale entry is per unique job ID; no demonstrated cross-job capacity leak. V04. |
| F6 **Q** | RS-9: reservations surviving skipped/failed deployment/start and late CHECK are reclaimed by expiry. Default provisioned expiry is 300 one-second ticks; class default differs. | No universal immediate-cancel contract was found: job.rst:284–286 promises cancellation for nonadmission, not all later failures. PromptCancel is a probe. Quantify delay/eligible-job retry harm; do not call bounded retention permanent lost capacity. V02/V08. |
| F7 **C**, partly **O** | Live iterations: SE.stop_all_runs, training_cmds shutdown running_jobs.items (RS-10), and SE-1 A/B/C sweeper paths. Historical H and server_engine cleanup-thread probe include controls. Model represents only run-map cardinality change, SE-1 B. | Reproduce each distinct owner/thread consequence; admin command failure and permanent sweeper death are different impacts. Include client-map mutation and stale-token None dereference, not only job-map removal. V06. |
| F8 **C/O** | GPUResourceManager float subtraction/addition may restore 0.9999999999999999 instead of 1 after 0.1/0.2 allocation/free order, rejecting a later request. Historical numeric probe tests actual arithmetic with host checking bypassed. | Supported positive GPU-memory configuration and same-capacity control. Separate numeric bookkeeping from GPU computation and actual host availability. Default zero-resource POC behavior does not test this. V08. |
| F9 **D** | String-return errors after allocation (already started/app missing) bypass StartJobProcessor's exception free. Historical client c1 and opt-in seed deliberately remove deployed app or supply a fresh duplicate token. | No ordinary supported trigger established. Same-token duplicate START normally fails allocation before the leak. Keep EnableUnsupported off in ordinary hunts; promote only with a public cooperative call sequence. V09. |
| F10 **C/O** | CL-5: waiter frees at leader exit while same-group descendants survive; abort grace may return before killpg, and ProcessAdapter.getpgid(reaped_pid) can fail. Historical pgroup/path-matrix use real OS children. | Real local job with a cooperative supported subprocess, same group, resource ownership, leader reaping and later allocation control. In-tree external trainer's separate session/watchdog is not evidence for this exact group assumption. V07/V10. |
| F11 **C/O** | CL-4: notify_job_status retry never exits after timeout and stops sleeping; parent-death stop only aborts client_runner, not the retry loop. Historical real CellNet CP-kill probe observed continued COMM_ERROR spinning, not a full worker deployment. | Real local CJ bootstrap, ordinary CP exit, passing successful-notify control, process survival/CPU/log rate and cleanup. Label CP kill and timing gates. Model ClientCrash assumes this away. V10. |
| F12 **C/Q** | SE-L4 disable/remove bypasses notify_dead_client and leaves outcomes pending until 900-second default deadline. Historical timeout shortened to 4 seconds with logout control. | Disable vs remove vs re-enable must be distinguished: live removed client may reactivate on heartbeat; disabled client cannot. Bounded status/slot delay, not indefinite starvation. Class max_jobs=1 versus provisioned max_jobs=4 changes blast radius. V06. |
| F13 **C/Q/O** | CL-3 consume writes CP-wide CUDA_VISIBLE_DEVICES and later launch copies it; overlapping handlers can launch A with B's binding. CL-2 adds stale environment after earlier success/failure and empty allocation. Historical real spawn, stubbed host GPUs, prelaunch timing gate. | CL-3: establish supported overlap despite sequential server runner (e.g. first START exceeds 20-second timeout), verify allocations versus inherited device IDs and control. CL-2: zero-GPU jobs are already unrestricted without a prior write; visibility alone is not an exclusivity contract. V08/V09. |
| F14 **Q/O** | Portable num_of_gpus without memory becomes zero-memory GPU bookkeeping, permitting sharing. Earlier report used job.rst:313–316 “different GPU” text as a default-GPU-manager guarantee. | That paragraph describes ListResourceManager/ListResourceConsumer. Default GPUResourceManager accounts shareable memory virtually. Reclassify old exclusivity allegation as configuration/contract question; no demonstrated default-manager defect from sharing alone. |
| F15 **Q** | Deployment can tolerate site failures; explicit START errors or missing targets fail whole start, while default non-strict timeout replies are ignored. | Policy variation is not itself a bug. timeouts.rst documents non-strict timeout behavior; verify strict-mode and required/min-site contract separately. No strict-mode variable or varied required/min-site hunt exists. V02/V03. |
| F16 **C** | RS-2: refresh_meta RMW retains SUBMITTED snapshot across abort, writes it back, later scheduler launches. Historical rmw_probe/N2b with timing control. | Dedicated MC_seed_F16_refresh must witness RunnerRefreshRead → abort → RunnerRefreshWrite, then public reproduction with passing control. MC_seed_F16's shallower TerminalStable violation was F1, contrary to original coverage prose. V01. |
| F17 **C/Q** | Clean SJ exit can lose execution-error meaning carried by best-effort UPDATE_RUN_STATUS arriving after waiter pop/two-second grace. E7 late-update variant exercises real functions with stubs. | Real supported execution error that returns exit 0, delayed/lost status, source-derived delivery contract. Separate ground-truth error from signals available at publication; don't demand guaranteed delivery merely because model can lose it. V04/V07. |
| F18 **C/Q/O** | Persisted RUNNING/DISPATCHED after ordinary SP restart; reconciliation methods apparently have no active callers. Prior brief excluded all restart reconciliation. | User excludes HA recovery, not every ordinary local process restart. Check actual supported single-server shutdown/restart path and persisted status/admission consequences. Retain as out-of-model coverage gap; exclude only genuine HA protocol investigation. |
| F19 **D** | free_resources ignores ownership token; direct duplicate free duplicates list units in historical client c4. | No cooperative in-tree double-free caller established. Preserve as API-hardening observation, not product defect under arbitrary misuse. Any promotion requires reachable ownership transfer. V09. |
| F20 **C/O**, PID part **D** | RMP pop before waiter reads can lose rc; read-before-pop can instead write stale exception after completion. Historical wfc_stale trace and process probes. | V07 must distinguish actual waiter read from modeled stash. Reproduce ordinary cleanup ordering with real normalized rc/rc file. Hypothetical PID reuse/unrelated kill requires a real OS sequence, not a fabricated reused PID. |
| R1 **C/Q** | Completion retries persistent set_status failure forever while holding slot; archival retry is separately bounded. MC-C makes missing store object concrete. | Deduplicate deletion cause into MC-C; treat arbitrary permanent I/O outage as an environmental failure unless intended recovery guarantee supports more. Transient fault plus blind removal is RS-7/MC-D. V02/V04. |

## Deep-analysis leads and omissions from the main report

Sources: [runner_status.md](../evidence/deep/runner_status.md), [client_lifetime.md](../evidence/deep/client_lifetime.md), [server_engine.md](../evidence/deep/server_engine.md), [process_mains.md](../evidence/deep/process_mains.md), their scripts/stdout, and the corresponding child conversations.

| Original ID | Reconciliation / route |
|---|---|
| RS-1, RS-2, RS-3 | F2 scan; F16 refresh; **RS-3 C** retains low-priority CANT_SCHEDULE overwriting acknowledged ABORTED (N2a control/ordering). It is a terminal-outcome discrepancy, not a resource leak. |
| RS-4, RS-5, RS-6 | F5; **RS-5 C** start-window UNSAFE_COMPONENT stop without run_aborted marker; F4. RS-5's injected report 102 is not automatically the actual process path: absent rc file, ProcessHandle normalizes 102 to 1 and STARTING remaps to 104. Confirm a real preserved-102 path and report timing before accepting this trigger. |
| RS-7, RS-8, RS-9, RS-10 | **RS-7 C** completion blind-del death with explicitly injected transient RUNNING write failure; MC-D supplies a modeled supported delete variant. F2 delete-after-start/slot consequence; F6 token sites; F7 additional live loops. All retained despite overlaps. |
| RS-11a | **Q/D** CMP abort fanout catches only RuntimeError; another exception could kill it, but no concrete ordinary default-path exception shown. Find that exception or close as unsupported, not generic adversarial custom code. |
| RS-11b | **C/O** empty job_clients aliases live client_manager.clients as PARTICIPANTS. Check all clients disappearing between preparation and launch, then mutation during participant iteration. Historical lead only, no accepted reproduction. |
| RS-11c | F15 missing-target versus timeout policy. |
| CL-1 | **C/Q** ABORT before STARTING registration is dropped and late START launches. Historical control registers pending handle first. Normal heartbeat compensates; check ordinary failure/shutdown window and exact cleanup guarantee. Admin abort while DISPATCHED is store-only and is not this trigger. |
| CL-2, CL-3, CL-4, CL-5, CL-6 | F13 stale binding; F13 overlap; F11 parent-death retry; F10 abort/grace descendant variant; **CL-6 Q/O** CP shutdown leaves child cleanup to cooperative watchdog and resets in-memory ownership on restart. Evaluate CL-4/5 exceptions, don't presume every CP exit permanently leaks. |
| SE-L4 | F12. Correct old “only slot/default 1” claim for provisioned max_jobs=4. |
| SE-1 A/B/C | F7: live clients iteration / live run_processes iteration / stale logout token returning None. One model action does not establish all three. |
| SE-3 (late child transcript, not merged into report) | **C/O** re-registration replaces old client token without notifying old job participants. Historical repro_reregister_token_mismatch.py: dead-job notifications 3 in control, 0 after replacement; abort fanout loses site-1. Stub auth logged missing configuration/SSL errors, so not a real registration proof. FS:1052–1055 can resolve by client name once SJ is gone; do not claim permanently stuck pending outcomes solely from token mismatch. Confirm actual same-site re-registration and old-job cleanup. V06. |
| E1–E4 | **Q/O** real child/MPM/ProcessHandle exit-code table plus fake server consumer: preservation of typed 101/102/103 depends on rc file; STARTING/STARTED/STOPPED remaps differ. Raw signal -9 normally becomes 1. Retain outcome-classification question, not independent “signal branch” proof. V07. |
| E5 | Real CJ main on a provisioned POC kit, but fake parent/server finalization. Config/unsafe failures gave raw 103/102, no rc file, reported 104, ABNORMAL. Valuable process-level evidence; not an end-to-end status contract verdict. |
| E6 | **C/O** SJ engine thread can finish (STOPPED) before start_run writes STARTED, then main loop waits. Historical forced Thread.start shim executes target synchronously; fixed-workspace control returns, forced run requires asked_to_stop. Initial workspace-error control was invalid. Confirm real thread scheduling plus supported fast workflow. V03. |
| E7 update-error | F17, late UPDATE after pop ignored; retain on-time error control. |
| E7 heartbeat (late child transcript, not merged into report) | **C/O** late SJ HEARTBEAT after run_processes pop but while job still RUNNING/pending makes FS:605–623 call _set_job_aborted; normal completion can become ABORTED. Historical e7_late_sj_messages.py shows timely-heartbeat COMPLETED control. Need real message delay, job lifecycle and both lookup/marker windows. V04/V06. |

### Lower-priority archaeology observations

These remain in the queue even where no main F number was assigned.

| Lead | Disposition |
|---|---|
| Batch 2 L8: CJ removes site restart.fl/shutdown.fl | **Q/O** check worker bootstrap marker removal against parent startup/control scripts, especially later eligible job after restart request. No real lost-control-command demonstration yet. |
| Batch 3 L8: engine.lock held over child RPC, then fail_run/JR lock interaction | **Q** bounded 1–5-second blocking is observable; not a proven deadlock. Require an actual cyclic wait or violated deadline before a defect claim. |
| Batch 3 L11 / batch 4 L7: exit cleanup exceptions, post-spawn setup failure | **C/Q/O** ordinary thread-start failure after spawn can route to outer free while CJ lives; cleanup free/wait exceptions can leave registries. Establish default-supported failure and control, not an arbitrary failing custom resource manager. V09. |
| Batch 4 L8: failed deployment leaves workspace | **Q/O** _delete_run lacks an active caller and failure paths can leave partial workspaces unarchived. Derive disk-retention/cleanup contract before treating residual files as incorrect. V02. |
| Batch 2 L3: global engine_info.status becomes STOPPED when one SJ exits | **Q** inspect consumers for an actual lifecycle/admission consequence with another job running. A display discrepancy alone is not proven job termination. |
| Internal schedule_* fields in submitted metadata | **D** accepted raw internal-key manipulation differs from ordinary supported metadata (F4); don't silently expand the input assumption. |
| Client notify STARTED after STOPPED / environment-copy iteration race | **Q/D** historical code-review speculation needs a real delivery/concurrent first-insert path; no accepted probe. Preserve under V09 without counting as confirmed. |

### Refuted, narrowed or reopened prior conclusions

- Validator rejects mixed ALL_SITES plus explicit sites and duplicate site assignments; the corresponding alias/duplicate scheduler lead is not a supported accepted-job trigger.
- list(running_jobs.keys()) is a single C-level snapshot under this runtime; it is not the live Python-iteration bug in F7.
- Lifecycle events carry explicit job IDs and scheduler removal is membership-checked. “Exactly one end event” is the wrong invariant: an aborted completion emits JOB_ABORTED and JOB_COMPLETED; the intended slot effect is idempotent.
- “fail_run versus completion is serialized” is too broad. Individual critical sections serialize, but reads, abort fanout and latch/publication are split. Reopen V04 around those boundaries.
- “UPDATE shares the dictionary object, therefore no lost return code” proves object identity only. It does not settle arrival after removal or a retained handler reference written after completion. Reopen V04/V07.
- Contract report T5 says inactive fail_run inserts an exception record. JR:817–833 puts insertion only in the active else branch. That allegation is rejected for an already inactive job; F5's earlier active-record leak remains.
- Non-strict START timeout tolerance is documented. Outcome reports arriving after the configured barrier/final removal are deliberately ignored; a proposed invariant must define the acceptance boundary.
- GPU virtual accounting is not a promise to police unrelated host GPU users; CPU/memory admission fields are not enforced by the default process resource normalizer.
- Historical diffs were unavailable to the old analysis. Commit messages/file lists and present source can suggest mechanisms; they do not prove what each historical patch changed.

## MC-A through MC-E, plus the interrupted counterexample

These are historical TLC results, independently inspected and mapped to pinned code during adoption. They remain candidates for separate real-code confirmation. None is a new continuation TLC discovery.

| ID | Retained evidence | Audit / next check |
|---|---|---|
| MC-A **C** | spec/output/MC_conv_r1_run1.out, 12 states. Stale AdminAbortBegin, deployment fails, FAILED_TO_RUN, then AdminAbortWrite writes ABORTED. | New writer variant of blind-status family; already seen in original Phase 2 smoke. Confirm public concurrent abort and contract for terminal-to-terminal overwrite. |
| MC-B **C** | spec/output/MC_conv_r1_run2.out, 21 states. Store-only abort during start, completion overwrites it. | F1 mechanism, completion writer; don't count as independent new root cause. Real early error-exit alternative to arbitrary clean SJ finish. |
| MC-C **C** | spec/output/MC_hunt_s2_slots_bfs1.out, 22 states. Delete authorized while SUBMITTED executes after RUNNING; terminal publication retries forever and holds slot. | RS-8/F2 stale authorization, new consequence; already original Phase 2 smoke. Real public authorization/execution interleaving and later eligible job required. |
| MC-D **C** | spec/output/MC_hunt_s2_slots_bfs2.out, 28 states. Publish, stale delete, RUNNING write fails, runner removes entry, CMP blind-del kills completion. | RS-7 known mechanism, modeled ordinary-delete trigger replacing old transient-I/O injection. Preserve ordering and both thread deaths; no real deployment reproduction yet. |
| MC-E **C** | spec/output/MC_hunt_s4_outcome_bfs1.out, 24 states. Stop sends SJ abort before mark; clean exit is latched COMPLETED in between. | Original Phase 2 smoke and prior source lead, not first found at final hunt. Model gap V04 and actual one-second abort RPC timing matter; harness immediate timeout cannot alone establish it. |
| MC-U1 **unclassified** | spec/output/MC_hunt_s4_outcome_bfs2.out; final transcript 04:14024–14034. FinalMatchesOutcomeNovel violation, 27 states, 235128 generated / 69129 distinct / 26239 queued. | SJ cleanly finishes before client START processing; waiter pops SJ; CJ fails; REPORT sees pending but fail_run sees neither run_processes nor running_jobs; report resolves outcome without authoritative exception. Then runner inserts and CMP publishes COMPLETED. Confirm supported very-early clean SJ workflow, exact report-acceptance contract and V03/V04 atomicity. Do not accept or discard solely on invariant failure. |

MC-U1 action sequence (omit the unused initial admin-abort read only when minimizing, not from original evidence): AdminAbortBegin; RunnerScanList/Read/TryNext; MsgCheckResource; RunnerCheckCollect; RunnerCheckSubmitted; RunnerDeployJob; RunnerSetDispatched; RunnerMetaRead/Write; RunnerCheckDispatched; RunnerStartServerApp; MsgStartAllocate; SjFinish(FALSE,0); SpWaitForComplete; CpStartRegister/Launch; RunnerStartCollect; CjExit(1,FALSE); CpChildFinished; MsgProcessJobFailure; RunnerInsertRunning; CmpFinalizeBegin; CmpPublish.

The original convergence/search claims were conditional and bounded. MC_conv BFS left 32,473,737 states queued at 30 minutes; S1 and S2 continuation BFS also retained queues. The resource hunt was unfinished at the interruption. Old successful trace replay and bounded no-counterexample searches do not complete the continuation stages. Broad residuals are audited in model-audit.md and must be narrowed or explicitly qualified in validation.

## Alias ledger: archaeology and contracts

This preserves provenance without manufacturing duplicate findings.

| Historical report | Original lead IDs → retained entries |
|---|---|
| batch-1 | L1→F4; L2→F2; L3→F7; L4→F6; L5→F9/F19; L6→F17; L8→F1; L9→F5; L10→F13. |
| batch-2 | L1→F8; L2→F6; L3→F20/MC-E/global engine status; L4→F13; L5→F7; L6→F17; L7→E1–E5 typed/signal rc; L8→control markers; L9→F4; L10→F18; L11→F1; L12→F2; L13→F9. |
| batch-3 | L1→F1, L1c→F3; L2→F16/RMW; L3→F2; L4→typed rc; L5→documented non-strict policy; L6→F18; L7→F11; L8→lock stall; L9→F9; L10→F6; L11→cleanup/post-spawn exceptions. |
| batch-4 | L1→F20 hypothetical PID reuse; L2→F13; L3→F12; L4→F18; L5→F6; L6→F1; L7→F9/post-spawn exceptions; L8→workspace retention. |
| batch-5 | L1→F1; L2→F2; L3→F5; L4→F9; L5→F4; L6→F6; L7→F7/SE-1; L8a→F14, L8b→F13. |
| contracts T1–T5 | T1→F1; T2→F2; T3→F9; T4→expiry/F6; T5→inactive-fail_run correction above. |
| unspecified U1–U6 | U1→F6; U2→slot wait (900-second outcome barrier, separate 60-second archive grace); U3→F15; U4→initial PARTICIPANTS versus shrunk JOB_CLIENTS (V03/V06); U5→normalized signals (E1–E5); U6→blind status discipline (S1). |

Contract/document discrepancies X1–X16 are retained as audit context, not all as product defects:

| IDs | Discrepancy / route |
|---|---|
| X1 | Defaults differ between class, provisioning template and examples; use the actual deployment values. |
| X2, X4 | Scheduler retry/backoff/max-count wording versus implementation; scheduling queue order is not unconditional eventual admission. |
| X3 | Literal FINISHED:CAN_NOT_SCHEDULE spelling differs from shorthand; normalize trace names explicitly. |
| X5 | “All relevant sites” prose versus min/required-site deployment policy; F15. |
| X6 | CPU/memory fields versus default local-process admission normalizer; out of model, no invented enforcement. |
| X7, X8 | Resource-manager configuration location and invalid resource-consumer example; configuration/documentation issues pending operational consequence. |
| X9 | strict_start_job_reply_check comment/documentation versus actual non-strict behavior; test both supported settings if used. |
| X10 | Job-level config versus SP-startup/environment timeout configuration; don't assume a job setting changes a parent timeout. |
| X11, X12 | Queued abort behavior, unused APPROVED status and launch-failure status categories; use actual active writers and CLI contract. |
| X13 | Scheduler return-tuple documentation differs from implementation; callers define actual protocol. |
| X14 | Expiry is periodic ticks; GPU memory accepts numeric values despite base integer-oriented resource documentation; F8/V08. |
| X15 | Empty resource requirements still pass policy and can create a token; not necessarily unconditional admission. Validate Need=0 projection. |
| X16 | Consumer runs before launch and writes global environment; F13. |

## Required downstream handoff

Validation must retain all C rows (including source-only/out-of-model rows) for configured confirmation, and resolve Q/D rows explicitly. A model repair or inability to reproduce a particular stub is not sufficient grounds to discard an independent source candidate. For each candidate record the supported API/configuration, fault/timing controls, actual local deployment extent, passing control, commands/output, source hash, and whether it is a seed, historical MC variant, genuinely new MC result, model mismatch, policy question, unsupported case or environment-limited result.

Use GPT-6 Astra at max for analysis/verification/repair/classification and the pipeline's GPT-5.5 at xhigh for separate confirmation, one per-finding task at a time. No substitute model and no product fixes. This Phase 2 file queues that work; it does not execute or claim completion of those later phases.


## Phase 3 source-validation supplement

- **V04-REF C/Q/O**, tied to F17 rather than a new TLC result: FS:597 retains
  object A; SE:219–233 can pop A on clean exit; JR:817–833 can create standalone
  exception object B while running_jobs still holds the job; then an
  execution_error=True UPDATE can assign A over B at FS:601. Inspect loss of
  infrastructure-failure precedence and the publication latch. Clean UPDATE does
  not perform that replacement. This is a source-derived reference-lifetime
  hypothesis, requiring real local outcome/rc evidence and a passing control,
  not a product verdict. Working brief Scenario 33 preserves the handoff.

## Phase 3 C8 source/model dispositions

The adoption rows above remain the historical audit. Validation repaired the
source-visible prerequisites and atomicity boundaries in C1–C8, reran the fresh
harness projections, and independently inspected the following C8 witnesses.
Case C here is a source-supported model candidate awaiting the configured
separate confirmation phase; it is not an end-to-end reproduction verdict.

| Historical lead | Current C8 evidence under spec/output/ | Report route and retained qualification |
|---|---|---|
| MC-A | continuation-H4-probe_admin_abort, 14 states | Related to queued-cancellation MC-1. Stale queued abort replaces FAILED_TO_RUN; overlap precedence remains a contract question. This alone does not establish post-acknowledgment launch or High impact. |
| MC-B | continuation-H4-probe_completion_write, 32 states | Related to MC-1. Completion replaces queued ABORTED after ordinary early SJ rc=1; no premature clean-exit premise. Same cancellation/lifecycle root. |
| MC-C | continuation-H4-probe_deleted_slot, 27 states | Primary MC-12. Stale SUBMITTED authorization deletes a now-tracked RUNNING job. The witness stops at deletion; persistent publication retry and later-job admission failure remain live confirmation obligations. |
| MC-D | continuation-H4-s2_slots, 38 states | Primary MC-6. Ordinary deletion makes the late RUNNING write fail; runner removes tracking, then completion blind-del raises before slot release. Preserves RS-7's separate transient-write-failure trigger. |
| MC-E | continuation-H4-probe_stop_success, 35 states | Primary MC-9. Abort actually stops a bootstrapped SJ; completion publishes success before the marker, then marking succeeds while tracking remains. Earlier C5 read/mark/latch ordering remains historical related evidence. |
| MC-U1 | continuation-H4-u1_startup_gap, 37 states | Primary MC-11. Pending failure is accepted in the gap between SJ-record removal and running insertion, ignored by inactive fail_run, then success is published while tracked. The current witness delays Resolve through the outcome deadline; compare immediate resolution and an active-tracking control in a real fast-workflow deployment. |

The thirteen current MC report entries preserve source provenance: F1, F2/RS-8,
F3, F5, F16, MC-D/RS-7, F7's run-map variant, F10/CL-5, MC-E, the V04 active
failure/finalization race, MC-U1, MC-C, and F4's pre-reservation poison. All primary
witnesses now use C8. The V04 counterexample is new concrete continuation model
evidence for a reopened source concern; the other rows are source-seeded or
historical rediscoveries. Source-only V04-REF / Scenario 33 remains separate.

The final C8 V04 witness records authoritative failure **after the completion
outcome read but before its formal latch**, unlike the retained C7 post-latch
variant. The current typed-102 unsafe witness leaves Mark pending at publication;
it does not reproduce RS-5's marker-executed-as-no-op trigger. A supported preserved
rc-file 102 is still required; raw OS102 is insufficient. Neither distinction
drops the original source candidate.

Seed fidelity was rechecked independently: F1=12 states, F2=5, F3=33, F5 outcome=33,
F5 direct KeyError=31, and dedicated F16 refresh=37. Generic F16 reaches F1 in 13
states and is not refresh evidence. F9's 19-state app-disappearance path remains
Case B relative to supported task reachability and a defensive conservation
control only. F19 still lacks a cooperative double-free caller.

The late-CHECK PromptCancel failure is Case A: expiry-backed retention is allowed,
and the replacement checks fair finite-batch ReservationDrain. The S5 fatal
missing-target result is Case A for the inherited tolerance oracle; its current
cfg checks structural lifecycle properties, not a varied min/required-site
contract. The unrecorded execution-error result is Case A for an unconditional
reliable-delivery oracle; F17/F20 end-to-end concerns remain source candidates.
The CANT_SCHEDULE probe completed BFS to depth 39 and an optional same-bounds
depth-100 simulation with 780,167 traces without rediscovery. This does not refute
RS-3 / Scenario 29 or replace its independent confirmation.

All 33 source-review Scenarios remain in the working modeling brief for launcher
consolidation with spec/findings.json. Every C row above, every Q/D disposition,
every lower-priority lead, and every alias remains mandatory review input.
Confirmation must distinguish public implementation reproduction, labeled timing
controls or fault injection, unsupported defensive paths, policy questions and
environment limits. Use GPT-5.5/xhigh with one per-finding task at a time; return
model/harness mismatches through normal GPT-6 Astra/max repair/evolution and
subsequent classification. Product implementation fixes remain unauthorized.
