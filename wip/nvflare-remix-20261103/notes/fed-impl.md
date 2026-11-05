# FedAvg component implementation log (TaskCJ, CommSJ, WfSJ)

Agent: fedavg implementation. Contract: `notes/IMPLEMENTATION-CONTRACT.md`. All runs use `MIX_BUILD=W/.build/fed`, `MIX_INCLUDE_WIP=TaskCJ,CommSJ,WfSJ`.

## Port and protocol (spec/PortsFed.tla)

Message kinds (all variants use the same keys and bodies):

| Kind | Owner | Dir | id | body |
|---|---|---|---|---|
| GET_TASK | TaskCJ | CJ(c)->SJ | <<JobId,c,l,p>> | [launch, poll] |
| TASK_ASSIGNMENT | CommSJ | SJ->CJ(c) | GET_TASK id | [status ASSIGNED/TRY_AGAIN, assignment, input] |
| TASK_CHECK | TaskCJ | CJ(c)->SJ | <<JobId,c,l,k,n>> | [assignment, try] |
| TASK_CHECK_REPLY | CommSJ | SJ->CJ(c) | TASK_CHECK id | RETRY / RECEIVED / TASK_CLOSED |
| RESULT_ENVELOPE | TaskCJ | CJ(c)->SJ | <<JobId,c,l,k,n>> | [assignment, refs, rc] (refs carry ref/source/launch only) |
| RESULT_RECEIPT | CommSJ | SJ->CJ(c) | envelope id | RECEIVED / TASK_CLOSED / RETRY |
| END_RUN | WfSJ | SJ->CJ(c) | <<JobId,c>> | None |

l = CJ launch, p = poll number, k = task number within the launch, n = submission try. Server attempt = assignment.attempt = round (Rounds == 1 for now, `ASSUME Rounds <= MaxAttempt`).

CTRL/COMM blocking call: CommSJ posts `pCommSJ.call` = [site, round, kind live/unknown, key, assignment, value, rc, metricKind] (APP_CALL, issued by WFCommDispatchSubmission); WfSJ runs the callback body and posts `pWfSJ.ret` = [site, round] (APP_RETURN); CommSJ's WFCommStampReceipt / WFCommDropSubmission consume it. Other SJ rendezvous: SCHEDULE (pWfSJ.scheduled -> ack pCommSJ.round), CANCEL_ALL(ERROR) (pWfSJ.cancelAll -> ack pCommSJ.cancelled), standing query (pCommSJ.standing), runner abort latch = pWfSJ.panic \/ pCommSJ.panic, WORKFLOW_RETURNED (pWfSJ.returned -> pCommSJ.wfClosed -> pCommSJ.finalized -> pWfSJ.done).

Port fields kept for other readers: pTaskCJ.submission/envelopeSent/receipt/done (+ input, trainerSignal for Trainer); pCommSJ.assigned/envelopes/claimed/finished/retired; pWfSJ.open/scheduled (now a round number)/accepted/rejected/closed/aggregate/saved/done/endSent/sj (+ cancelAll, ret, panic, returned, dsShutdown).

Teardown order exposed for S10/H30 (server_runner.py:205-237): pWfSJ.done (status done) -> END_RUN per site (pWfSJ.endSent) -> readiness (private) -> pWfSJ.dsShutdown -> pWfSJ.sj = "exited".

Faults (FedFaults): sjCrash, taskTimeout (server task TIMEOUT), submitTimeout (CJ get-task / task-check / submit timeouts; also enabled by netLoss), prepFail, cbFail, cancel, deadClient, minClients (min_responses < targets), resultWaitTimeout.

## Status (checkpoint 19:00 UTC)

- PortsFed, WfSJ_C, CommSJ_C, TaskCJ_C rewritten for the new protocol; WfSJ_M deleted (old port semantics; also avoids the C/M/F chain issue).
- WfSJ_F, CommSJ_F, TaskCJ_F written from base.tla (hand re-encoding; no generator script: almost every action needed the channel / oracle rewrite); registered with `"wip": true`.
- 18:55 refactor (coordinator request): owner-only port fields moved to privates (see port-requests.md); coarse Reject fixed (claimed-key private); coarse tightened (trainer abort, error results, unknown dispatch and rejection only under the faults that make them possible in fine).
- Framework items applied: InInbox / per-k predicates instead of Inbox and set comprehensions under \E k; AbsC mentions only own privates/port (TaskCJ_F keeps `chandled`); fresh ids for every retry-capable kind (GET_TASK poll p, TASK_CHECK/RESULT_ENVELOPE try n); dead-client reports gated on Ports!PeerFailureCJ, heartbeat on a live CJ.
- Shadow copy `.build/fed/Trainer_C.tla` bounds Trainer_C!Publish (unbounded seq upstream, reported). spec/ untouched.
- gen_mix + SANY pass for both the default Mix and the WIP build.

## Properties (definitions)

Port-level (scripts/fed_mkmc.py `FED_DEFS`; proposed for Props.tla):
- `ResendPreservesAuthority`: every ASSIGNED TASK_ASSIGNMENT to a site for one round carries the same assignment (resend keeps the ClientTask / attempt; covers "resend after CJ relaunch preserving authority").
- `OneAssignmentRecordPerIdentity` (S06, slice form): `pCommSJ.assigned[c] \in {None} \cup {Assignment(c, r)}`. The duplicate-ClientTask bug (H11) needs two standing tasks; with one standing task per round it is vacuous (noted, not claimed).
- `EnvelopeRefsRegistered`: each RESULT_ENVELOPE ref is a descriptor its source launch registered (the envelope never carries the value).
- `AbortedOnlyAfterEndRun`: `pTaskCJ[c][l].receipt = "aborted" => c \in pWfSJ.endSent`.
- `EndRunAfterDone`, `SavedAfterOkClose`.
- Witnesses (expected violated): `NoStragglerAbortAfterSave` (S10/H30 straggler abandoned by END_RUN after a save), `NoLateCall` (late result reaches the unknown-result hook), `NoRejectedReceived` (RECEIVED for a rejected contribution: receipt vs acceptance).

Group-local (seed base.tla:1157-1206), checked when the group is fine:
- `CommSJ_F!CommSafety` = ClaimBeforeFinish, OneStandingTask, CompletedHistoryBound, CallerLockDiscipline, CallFrame (APP_CALL only while the submission holds runner + communicator locks).
- `WfSJ_F!WfSafety` = AtMostOneConsumer (= ApplicationReceiptAtMostOnce for the application callback), FencedReceiptAtMostOnce (callback + unknown hook <= 1 per fenced attempt, S23), SavedWasCommitted, CountMatchesSuccessfulReturns, NoFailedRoundPublished.
- `WorkflowAdmissionIdentity` (S23): one workflow in the slice, so claims are always for the current workflow (vacuous; noted).

## Fine variants vs seed (what was kept, what was re-encoded)

- WfSJ_F (50 steps): all 40 FED_CTRL seed actions with seed names/anchors, except FedAvgRejectShape (ShapeMismatch FALSE in the slice profile) and the seed's `ClientProcessTask` metric kinds (envelope metricKind is "none"; metric actions are kept and stay disabled). Added the CTRL halves of the seed rendezvous (WFCommScheduleTaskCall/Return, FedAvgCancelFailedTasks/Return), AppCallEntry (APP_CALL consume) and the run end of server_runner.py:205-237 (ServerRunnerRunDone, SendEndRun, EndRunReadiness, DownloadShutdown, ServerJobExit/Crash). ConversionFailure/AllocationFailure -> Faults "cbFail".
- CommSJ_F (52 steps): all 48 FED_COMM seed actions (dead-client watch, monitor, LRU history, claim->dispatch window, wf_lock serialization kept inside the group) plus ServerRunnerReceiveSubmission (cell-layer receive, hands refs to PayRcv), ServerRunnerRetryIncomplete (server_runner.py:503-507), WFCommCancelAllTasks (COMM half of CANCEL_ALL). Oracles replaced: resend = no result_received_time (wf_comm_server.py:246-257); TaskUnavailable = complement of real eligibility; ClientCheckTask = SJ reply only; ServerRunnerTaskRequestActive consumes a GET_TASK message; dead report needs Ports!PeerFailureCJ; heartbeat needs a live CJ. ClockAdvance is a COMM step enabled only with deadClient/taskTimeout/minClients. Added the source's task timeout (TIMEOUT) and bcast min_responses exit (minClients) branches in WFCommMonitorSelect (wf_comm_server.py:1222-1252).
- TaskCJ_F (21 steps): the 6 FED_CLIENT seed actions split into message-level steps (ClientGetTask/ReceiveTask/ReceiveTryAgain/GetTaskTimeout, ClientProcessTask, ClientCheckTask (CJ half), ClientSerializeResult, ClientSendResult, ServerCommandDispatchAck, ClientLoseDispatchAck, ClientRetryResult, ClientCheckTimeout, ClientEndRun) plus the in-process executor handshake with Trainer (ExecutorPublishTask/Published/FailFast/AbortSignal/TrainerExited/ResultTimeout/Finalize; in_process_backend.py:152-260). The seed's nondeterministic trainer result is replaced by pTrainer.published (any newer seq, no generation check, as in the source).
- Slice deviations: one result transaction per (site, launch, round) (later tries reuse the registered descriptor; the coordinator asked for a new tx per try, which needs PaySrc keyed by try); PayRcv is per site, so an envelope from a relaunched CJ (new ref) is never decoded and its submission only times out (port request); END_RUN id <<JobId,c>> has no launch, so a CJ launched after END_RUN also sees it (over-approximation).

## Checks run (commands and results)

Environment for every run: `export MIX_BUILD=W/.build/fed MIX_INCLUDE_WIP=TaskCJ,CommSJ,WfSJ`; `python3 scripts/gen_mix.py` then `scripts/tlc.sh sany $MIX_BUILD/Mix.tla` (and the same without MIX_* for spec/Mix.tla): pass after every edit. Runs use `scripts/fed_run.py` (= run_mc.py that streams the log and kills the JVM process group on timeout). Machine load was 80-150 on 96 cores throughout.

| Run | Command | Result |
|---|---|---|
| all-coarse 1 site, witness NotJobFinished (pre-refactor coarse) | `mkmc.py fed_allC_s1_w --sites 1 --inv NotJobFinished; fed_run.py fed_allC_s1_w` | violated as expected (job FINISHED reachable), 655,580 distinct, depth 68, 3m45s |
| negative CommSJ | `gen_ref.py CommSJ F C --sites 1 --negative` | BadStep violated, 810 states, 6 s (expected) |
| negative WfSJ | `gen_ref.py WfSJ F C --sites 1 --negative` | BadStep violated, 33 states, 5 s (expected) |
| negative TaskCJ | `gen_ref.py TaskCJ F C --sites 1 --negative` | BadStep violated, 309 states, 5 s (expected) |
| refinement, Net=L + faults (simulation) | `fed_ref.py CommSJ F C --name refL_CommSJ --grain Net=L --faults netLoss,prepFail,cancel,taskTimeout`, same for WfSJ (netLoss,cbFail,sjCrash,resultWaitTimeout), TaskCJ (netLoss,submitTimeout,resultWaitTimeout); `fed_run.py ... --mode sim --depth 400,1e8 --timeout 150` | no RefStep violation: CommSJ 1,193 traces / 428k states; WfSJ 4,287 / 575k; TaskCJ 1,038 / 335k (bounded simulation evidence) |
| refinement CommSJ, deadClient+minClients+cjCrash (sim) | `fed_ref.py CommSJ F C --name refD_CommSJ --faults deadClient,minClients,cjCrash` | no violation, 351 traces / 204k states (simulation) |
| all fed fine, 1 site, invariants (sim) | `fed_mkmc.py fedF3_s1 --grain TaskCJ=F,CommSJ=F,WfSJ=F --sites 1` | no violation of PORT_INVS + FedPortSafety + CommSafety + WfSafety in 483 traces (pre-reduction) |
| all fed fine, 1 site, witness (sim) | `fed_mkmc.py fedF3_s1_w ... --inv NotJobFinished` | violated as expected: the job finishes with all three fed groups fine |
| all fed fine, 1 site, invariants (sim, after reductions) | `fed_run.py fedF3_s1 --mode sim --timeout 200` | no violation, 474 traces / 364k states |
| S12/K14 submission retry: TaskCJ=F, CommSJ=F, submitTimeout, 1 site (sim) | `fed_mkmc.py hz_s12_retry --grain TaskCJ=F,CommSJ=F --faults submitTimeout` | no violation (PORT_INVS + FedPortSafety + CommSafety), 483 traces / 371k states |
| S23 late result: CommSJ=F, WfSJ=F, taskTimeout (sim) | `fed_mkmc.py hz_s23_late ...` | FinishedJobSaved violated after 58 s: triage (b) below |
| mark-only cancel: CommSJ=F, WfSJ=F, cancel (sim) | `fed_mkmc.py hz_cancel ...` | FinishedJobSaved violated: triage (b) |
| partial aggregation: WfSJ=F, cbFail (sim) | `fed_mkmc.py hz_partial ...` | ReceivedMeansAccepted violated: triage (expected by design) |
| dead client vs submission: CommSJ=F, deadClient+cjCrash (sim) | `fed_mkmc.py hz_dead ...` | FinishedJobSaved violated: triage (b) |
| S10/H30 straggler at END_RUN: all fed F, minClients, 2 sites (sim, 200 s) | `fed_mkmc.py hz_h30 ... --sites 2` | no violation, witness not yet reached in 200 s (rerun longer below) |

### Counterexample triage

- `FinishedJobSaved` in hz_s23_late (TIMEOUT retires the only site -> empty round -> FedAvgRejectEmptyRound -> BaseModelControllerRunException panic -> run unwinds -> SJ exits 0 -> SP classifies FINISHED), hz_cancel (CANCELLED task, same path) and hz_dead (CJ crash -> dead-job report -> disconnected -> deployment-policy panic -> abort-close -> SJ exits 0 -> FINISHED). Class (b), framework mapping artifact, not a candidate: the fed groups expose the panic (`pWfSJ.panic \/ pCommSJ.panic`), but `Ports!SJExitCode` / JobSP classify ignore it. Source: system_panic fires FATAL_SYSTEM_ERROR, ServerRunner.abort() (server_runner.py:253-257,675-679), and update_job_run_status sends execution_error=True (server_engine.py:874-885; fed_server.py:595-603), which SP maps to FINISHED_EXECUTION_EXCEPTION. Port request filed (19:00).
- `ReceivedMeansAccepted` in hz_partial: conversion failure (cbFail, base_model_controller.py:283-289) -> BasePublishAcceptance rejected -> WFCommStampReceipt sends RECEIVED (the claim receipt, wf_comm_server.py:562-618). Expected by design (receipt != application acceptance; seed handoff "Claimed receipt is not callback acceptance"). Not a candidate; property should be a diagnostic (port request).
| S23 late result, artifact invariants removed (sim) | `fed_mkmc.py hz2_s23_late --grain CommSJ=F,WfSJ=F --faults taskTimeout --inv <PORT_INVS minus FinishedJobSaved/ReceivedMeansAccepted/ReceivedReceiptMeansFinished>,FedPortSafety,CommSafety,WfSafety,NoLateCall` | witness NoLateCall violated after 30 s (expected): first late result after TIMEOUT retirement is claimed and routed to the unknown-result hook; FencedReceiptAtMostOnce, CallFrame, history bound and port properties hold on the way |
| mark-only cancel during callback (sim) | `hz2_cancel` (cancel), same invariants | witness NoLateCall violated after 84 s (expected): CANCELLED task, admitted submission dispatched to the unknown hook; no safety violation |
| S10/H30 straggler at END_RUN, all fed F, minClients, 2 sites (sim) | `fed_mkmc.py hz2_h30 --grain TaskCJ=F,CommSJ=F,WfSJ=F --faults minClients --sites 2 --inv ...,NoStragglerAbortAfterSave` | witness violated after 24 s (expected-reachable, see below) |

H30 witness (logs/hz2_h30.log, 191 steps): s1's result is claimed, accepted and stamped; the monitor retires the task with the bcast min_responses exit (WFCommMonitorSelect/MarkTerminal OK/Remove) while s2's envelope is already dequeued by the runner; s2's submission is checked and claimed after the round closed, dispatched as a late result to the unknown-result hook (no aggregation), the model of s1 is updated and saved, the runner closes/finalizes and sends END_RUN; s2's CJ receives END_RUN before consuming its RECEIVED receipt, so the in-flight submit is interrupted (pTaskCJ[s2][1].receipt = "aborted"). This is the precondition of H30 (END_RUN overtakes a straggler submission, client_runner.py:1084-1089; communicator.py:610-617). With PayRcv coarse the payload had already been materialized; the decode-fatal consequence needs PayRcv = F (next run).
| partial aggregation, artifact invariants removed (sim) | `hz2_partial` (WfSJ=F, cbFail) | no violation in 2,563 traces: a failed round (WeightedParamFailure / ConversionFailure) never publishes (NoFailedRoundPublished, AggregateIsAccepted hold) |
| dead client vs submission, artifact invariants removed (sim) | `hz2_dead` (CommSJ=F, deadClient, cjCrash) | no violation, 240 s |
| refinement BFS, unconstrained, 1 site, no faults (budget-stopped at the 18:57/19:21 coarse) | `fed_run.py ref_CommSJ_F_C / ref_WfSJ_F_C / ref_TaskCJ_F_C` | no violation; stopped by budget at 2,058,319 (CommSJ, depth 85), 3,798,057 (WfSJ, depth 88), 864,400 (TaskCJ, depth 71, before the RecvAssignment tightening) distinct states |
| refinement TaskCJ (tightened coarse), sim | `fed_run.py ref_TaskCJ_F_C --mode sim --timeout 300` | no RefStep violation, 2,740 traces / 382k states |
| S10/H30 consequence: TaskCJ/CommSJ/WfSJ/PaySrc/PayRcv = F, taskTimeout, 1 site (sim) | `fed_mkmc.py hz3_h30_1 ... --inv ...,FedNoSJDeathAfterDone` | reaches pWfSJ.done = TRUE with pPayRcv[s1].fatal = TRUE (91 steps); TLC then fails to evaluate the invariant (PayRcv_F value error, reported to payload agent) |

### Candidate (c): SJ os._exit after the run ended (S10/H30), model-level only

Trace logs/hz3_h30_1.log (simulation, not reproduced in code): the task TIMEOUT retires the only site while its trainer is still producing the result (WFCommMonitorMarkTerminal TIMEOUT, WFCommMonitorRemove); the round closes empty and the controller panics (FedAvgRejectEmptyRound, BaseModelControllerRunException); the runner unsets current_wf; meanwhile the CJ sends its late RESULT_ENVELOPE and the SJ's lazy-ref decode starts pulling (ServerRunnerReceiveSubmission, PayRcv_F SourceDownloadRegister/DownloadObjectStart); finalize_run, status done and the fire-and-forget END_RUN follow (server_runner.py:205-223); the CJ handles END_RUN (run_abort_signal, client_runner.py:1084-1089), stops and shuts down its DownloadService (client_runner.py:814-821); the SJ's next pull finds the source gone and, because the failure is not a local DownloadCancelled, the decode is fatal (PayRcv_F, H29 policy), i.e. the SJ process dies after its run finished. This is the H30 mechanism ("END_RUN overtakes a straggler; CJ teardown clears refs; SJ decode -> os._exit") reached across five fine groups. With 2 sites and minClients the same race can follow a saved model (OutcomeReflectsWorkflow); the 2-site run (hz3_h30, 600 s) did not reach it yet. Evidence level: model-level candidate (simulation witness), source anchors from the hazard note; needs implementation confirmation.

## Reductions and slice limits (documented, used in all runs after 19:20)

- CommSJ_F `MonitorWork` guard on WFCommMonitorBegin: monitor passes that can change nothing (no dead report; every standing task LIVE, unanswered and inside its lead time) are skipped. Such a pass only takes and releases the communicator lock, so skipping it removes delays, not port behaviors (sound for safety over ports and group state).
- WfSJ_F FedAvgPollStanding starts a poll cycle only when the task is no longer standing, the round failed, or the run aborted; the skipped cycles return to "wait" unchanged.
- Refinement checks with `--constraint "SJAlive \/ ~pJobSP.sjLaunched"` (refK_*) stop exploring after the SJ is gone. CommSJ/WfSJ steps all require SJAlive and the SJ never restarts, so this prunes only environment-only suffixes (exact for RefStep of SJ groups).
- Rounds == 1. The fine and coarse variants are written per round (task table per round, per-round port reset, next task per launch), but PaySrc registers once per launch and PayRcv keeps one ref per site, so round 2 (S02) blocks at the envelope (TaskCJ requires `registered.ref = Ref(c, l, round)`); see port requests.

## Open problems

- Refinement receipts are not exhaustive: the all-coarse 1-site environment alone needs >650k states to reach FINISHED, and every fine group multiplies it. Evidence: negative checks fire; bounded BFS (2.1M CommSJ, 3.8M WfSJ, 0.86M TaskCJ distinct states) and simulation over the Net=L / fault profiles, all without RefStep violations.
- Coordinator scenario instances (checks/scenarios.json S10/S12/S23) need receipts with matching signatures; only simulation receipts exist (checks/fed/receipts/*__sim.json).
- H11 (resend duplicates ClientTask) needs two standing tasks; not reachable in the one-task-per-round slice.
| refinement for coordinator scenario instances (sim, RefInit + RefStep + RefEnv, 240 s, 8 workers each) | `fed_ref.py <G> F C --name ref<S>_<G> --faults <S faults>`; `fed_run.py ... --mode sim`; `fed_receipt.py ...` | no violation: S23 (taskTimeout) CommSJ 6,467 traces / 1.07M states, WfSJ 8,872 / 1.31M; S12 (taskTimeout, pullTimeout) CommSJ 3,688 / 0.92M, TaskCJ 8,766 / 1.24M; S10 (cjCrash, taskTimeout) WfSJ 5,976 / 2.41M, TaskCJ 4,899 / 1.99M. Receipts (non-exhaustive, `__sim`) in checks/fed/receipts/ |
| refinement CommSJ, BFS with SJ-alive constraint (refK_CommSJ, 10 workers) | `fed_ref.py CommSJ F C --name refK_CommSJ --constraint "SJAlive \/ ~pJobSP.sjLaunched"` | running; no violation at 2,361,900 distinct states, depth 90 (20:14) |
| refinement TaskCJ, BFS with CJ-alive constraint (refK_TaskCJ) | `fed_ref.py TaskCJ F C --name refK_TaskCJ --constraint ...` | stopped for the 2-run limit at 317,363 distinct states, depth 70, no violation |

Note: the shadow `.build/fed/Trainer_C.tla` (Publish bounded by `published.seq < received`) was used by all runs from 18:33 to 20:20; upstream fixed Trainer_C at 19:33 with the equivalent bound `PubCount < received`, and the shadow was deleted at 20:20.

## 20:25 coarsening (coordinator request: all-coarse happy path must be cheap)

- `pTaskCJ.receipt` had no reader outside the fed groups: moved to TaskCJ_F's private state (H30 "aborted" is now `TaskCJ_F!T(c,l).receipt`, used by FedPortSafety/witness when TaskCJ = F). pTaskCJ = {input, trainerSignal, submission}.
- TaskCJ_C rewritten: no reply/receipt consumption, no timeout and no END_RUN step (all port-invisible in TaskCJ_F now); the coarse retries up to FedMaxTry regardless of replies and polls again once a final reply exists in net. Private state: asg, task, got (poll whose reply was taken), result. 7 action schemas.
- WfSJ (both variants): APP_RETURN is posted in the same step as the published decision (BasePublishAcceptance; BaseClearTrainingResult is callback-local); WORKFLOW_RETURNED is posted with the last save (FedAvgAdvanceRound is local); status "done" and END_RUN go out in one step as one broadcast (send_aux_request targets=None, server_runner.py:213-223; SendAll). Coarse Accept now also posts ret.
- CommSJ_C: TRY_AGAIN only after a task was scheduled (the fine variant answers GET_TASK only for a standing task).
- JVM crash workaround for the full `/`: all my runs after 20:30 use `JAVA_TOOL_OPTIONS=-XX:-UsePerfData`.

## Final round (23:20-00:30 UTC)

- TaskCJ_C upload is ordered after the RETRY reply of the same try (`RetryAnswered`; TaskCJ_F uploads only then), which removes late-reply interleavings.
- All-coarse 1-site happy path (`mkmc.py fed_allC_s1b --sites 1`, PORT_INVS without the job/by-design ones): still not exhaustive. 20:34 coarse: 4,579,367 distinct states, depth 68, queue 1.26M at the 900 s budget (16->12 workers); 23:25 coarse: 313,644 distinct at 75 s, depth 65. With FinishedJobAllOk included the run stops at 34 s (151,857 states, depth 60): JobSP_C ResolveMissingOutcome classifies FINISHED with outcomes[s1] = "none" (job component's grace-expiry policy; not fed). Coverage profile at 60 s (logs/fed_allC_s1b.log, -coverage 1): new distinct states come from WfSJ_C DSShutdown (34.7k) and Exit (20.2k), CommSJ_C AnswerCheck (17.8k) and JobSP_C ObserveSJExit (10.0k): the SJ teardown steps and the readiness reply interleave with the CJ/CP/SP teardown. Both teardown steps are separately port-visible in the fine variant (pWfSJ.dsShutdown is read by PayRcv for H30), so the coarse cannot merge them.
- Final H30 rerun on the final variants:
  - `checks/mixes/MC_fin_h30.{tla,cfg}`, `logs/fin_h30.log` (TaskCJ/CommSJ/WfSJ = F, minClients, 2 sites, sim): NoStragglerAbortAfterSave violated after 13 s (208 steps): s1 accepted/stamped (BasePublishAcceptance, WFCommStampReceipt); s2's envelope dequeued (ServerRunnerProcessSubmission); monitor exits the task with min_responses reached (WFCommMonitorSelect/MarkTerminal OK/Remove; bcast_manager.py:52-75, wf_comm_server.py:1222-1264); s2 checked and claimed after retirement (wf_comm_server.py:503-592, retired-history lookup), dispatched to the unknown-result hook (wf_comm_server.py:643-651); round closed, s1-only model updated and saved; WFCommDropSubmission sends RECEIVED; close/finalize; END_RUN broadcast (server_runner.py:213-223); s2's CJ handles END_RUN before consuming RECEIVED and abandons the in-flight submit (client_runner.py:1084-1089, communicator.py:610-617): receipt "aborted".
  - `checks/mixes/MC_fin_h30p.{tla,cfg}`, `logs/fin_h30p.log` (TaskCJ/CommSJ/WfSJ/PaySrc/PayRcv = F, taskTimeout, 1 site, sim): FedNoSJDeathAfterDone violated after 6 s (77 steps): TIMEOUT retires the only site while its trainer still runs (MarkTerminal/Remove), the empty round panics (FedAvgRejectEmptyRound, BaseModelControllerRunException; fedavg.py:389-390, base_model_controller.py:389-401); the late RESULT_ENVELOPE arrives and its lazy-ref decode starts (ServerRunnerReceiveSubmission, PayRcv_F SourceDownloadRegister); runner closes/finalizes and sends END_RUN; the CJ stops, abandons the submit and shuts down its DownloadService (RunCJ_C RecvEndRun/Stop, TaskCJ_F ClientEndRun, PaySrc_F Shutdown; client_runner.py:814-821); the SJ pull then fails with the source gone and the decode is fatal (PayRcv_F SourceDownloadUnregister, H29 policy): SJ os._exit after its run ended. Class (c), model-level candidate (H30), not reproduced in code.
- Final refinement at the final coarse variants (RefInit + RefStep + RefEnv):
  - simulation at the S23 instance (taskTimeout, 1 site, Net R; `fed_ref.py <G> F C --name fin23_<G> --faults taskTimeout`, 100 s, 14 workers): no violation; CommSJ 5,566 traces / 813k states, WfSJ 6,001 / 896k, TaskCJ 6,391 / 883k.
  - simulation at the H30 instance (minClients, 2 sites; `fin30_<G>`): no violation; CommSJ 411 traces / 133k states, WfSJ 1,320 / 324k, TaskCJ 1,248 / 300k.
  - official `gen_ref.py CommSJ F C --sites 1 --faults taskTimeout --run --timeout 480 --workers 16`: budget_stopped, no violation, 1,723,105 distinct states (depth 59); receipt checks/receipts/CommSJ_F_C__s1_nR_l1_ftaskTimeout.json (not exhaustive).
  - Receipts for the simulations: checks/fed/receipts/*__sim.json (scripts/fed_receipt.py).
- Registry: TaskCJ/F, CommSJ/F and WfSJ/F stay `"wip": true`: no refinement check completed exhaustively (state spaces of the fine group in the all-coarse environment exceed what the 2-run/16-worker budget explores in the remaining time). Every bounded BFS (up to 3.8M states) and every simulation found no RefStep/RefEnv violation, and every negative check fails as required.
  - official `gen_ref.py WfSJ F C --sites 1 --faults taskTimeout --run --timeout 420 --workers 16`: budget_stopped, no violation, 1,791,485 distinct states; receipt checks/receipts/WfSJ_F_C__s1_nR_l1_ftaskTimeout.json.
  - official `gen_ref.py TaskCJ F C --sites 1 --faults taskTimeout --run --timeout 420 --workers 16`: budget_stopped, no violation, 1,637,036 distinct states; receipt checks/receipts/TaskCJ_F_C__s1_nR_l1_ftaskTimeout.json.
- State of the files at hand-off (23:45 UTC): gen_mix static checks and SANY pass for spec/Mix.tla (default) and .build/fed/Mix.tla (MIX_INCLUDE_WIP=TaskCJ,CommSJ,WfSJ). No fed TLC job left running.
