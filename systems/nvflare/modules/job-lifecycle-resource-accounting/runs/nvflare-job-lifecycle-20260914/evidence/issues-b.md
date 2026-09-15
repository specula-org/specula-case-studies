# Phase 2 issue verification, batch B

Live GitHub retrieval: 2026-09-14. Source verified at `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Category A: server/site messages coordinate job state and local process/resource ownership. Cooperative participants and ordinary runtime failures only; no experiments or security reproduction were performed.

## Coverage and evidence boundary

- Assigned and deeply read: **20 distinct issues**, all full bodies and **109 comments**, including all 50 comments on #1843 and the long code-bearing final comment on #316. Empty bodies and zero-comment threads are reported as such, not upgraded to confirmed bugs.
- Primary classifications: **7 confirmed bugs**, **1 acknowledged design/platform limitation**, **3 user-error reports**, **2 disputed/expected-behavior reports**, **7 uncertain/support reports**. Five primary reports are explicitly excluded as false positives of a lifecycle defect (three user-error plus two expected behavior). Additional exclusions below distinguish scope, historical fixes, and insufficient evidence.
- All 20 issues are currently CLOSED/COMPLETED. Closure is metadata, not evidence of a fix. No unfixed open issue is established by this batch.
- #2326 additionally contains a separately acknowledged Pipe heartbeat bug; it is recorded without double-counting the issue as two deeply read issues or claiming that the original symptom confirmed that bug. #316 has an unresolved second reporter distinct from its resolved original report.
- Raw issue bodies, complete comment arrays, URLs, states, timestamps and labels are in `issues-b-raw/<number>.json`. Required `gh issue view --comments` output is separately preserved as `<number>-comments.txt`; that CLI mode omits the issue body, hence both records were read. Four issue timeline records and eight supplementary PR metadata/diff records are preserved. All eight supplementary PR discussions were also deeply read: full bodies, **22 top-level comments, 108 review records, and 120 inline review comments**, with paginated inline evidence in `pr-<number>-inline.json`. These PRs are not counted as issues.
- The source checkout is shallow. Historical fix ancestry is not asserted from an unsuccessful local log search. Current applicable source behavior, explicit maintainer statements and merged PR metadata are separated below. Linked attachments/private repositories were not fetched; no conclusion depends on their unseen contents. For historical removed modules, current equivalence is not assumed.

## First batch

### #3514 — Multi-GPU HuggingFace Trainer

[Issue](https://github.com/NVIDIA/NVFlare/issues/3514), 2 comments. **Uncertain/support request; closed**, with example functionality supplied by merged [PR #3554](https://github.com/NVIDIA/NVFlare/pull/3554) (`9c383ef17ba2a90d7374a41e764bc25071cae7fb`, 2025-07-30). Maintainers initially said multi-GPU HuggingFace Trainer had not been specifically tested, described GPU grouping/visibility and external script launching, and later linked the solution. The PR changes only the LLM example (scheduler alignment and multi-GPU training). This establishes an example enhancement, not a production site reservation bug. **Exclude** external-trainer lifecycle, GPU computation and simulator grouping. The old example entrypoint is absent at the pin, so no exact source-equivalence or remaining-defect claim is made.

### #3360 — Lightning multi-GPU startup

[Issue](https://github.com/NVIDIA/NVFlare/issues/3360), 4 comments. **Confirmed historical bug; fixed** by merged [PR #3392](https://github.com/NVIDIA/NVFlare/pull/3392) (`e83c38fa0d6b2525752e97aee94289a18690d5a0`, 2025-04-11). Initial use of an in-process API with multiple training processes was unsupported, but the reporter then reproduced a separate external-process `NoneType.task_name` failure; the maintainer explicitly acknowledged it and added a rank-zero guard when obtaining a client task. Do not flatten the whole thread into user error. The former `nvflare/client/task_registry.py` no longer exists at the pin. **Exclude** as fixed external-trainer/multi-GPU context, with no claim that the old code persists or that GPU grouping tests establish production admission correctness.

### #3197 and #3196 — Claimed 64/65 GiB admission boundary

[#3197](https://github.com/NVIDIA/NVFlare/issues/3197), 1 comment; [#3196](https://github.com/NVIDIA/NVFlare/issues/3196), 0 comments. **Both uncertain; closed without diagnosis or identified fix.** Same reporter says 64 GiB works while 65 GiB fails admission, despite free device memory. There is no maintainer acknowledgment, sufficient configuration, resource inventory or reproduced mechanism. Current `gpu_resource_manager.py:102-105,124-140,159-173` accepts nonnegative numeric GiB, validates requested configured capacity against host MiB, and compares requested capacity with tracked per-GPU memory; it has no hardcoded 64 GiB limit. That does not establish what happened in the reports. **Exclude as confirmed defects**, especially for the selected ListResourceManager (`list_resource_manager.py:57-76` checks list counts and deque removal, not physical GPU memory). Retain the general distinction between advertised resource capacity and measured free GPU memory as scope/configuration context only.

### #2601 — Torch examples aborted after startup

[Issue](https://github.com/NVIDIA/NVFlare/issues/2601), 9 comments. **User error; resolved.** Reporter eventually found PyTorch missing on the server; installing it made hello-pt succeed. Maintainer explained the parent/server-job process split and job-specific server persistor dependencies. The visible client abort notifications followed server job failure; they do not establish premature resource release, wrong-job abort or spontaneous scheduler termination. **Exclude as lifecycle-defect evidence.** Useful ordinary-failure context only: startup can launch a child that subsequently fails due to job dependencies; process creation is not execution success.

### #2559 — 16 GB marketing capacity versus 15 GiB visible memory

[Issue](https://github.com/NVIDIA/NVFlare/issues/2559), 3 comments. **Disputed/expected configured-capacity behavior; resolved configuration adjustment.** Maintainer explained the documented GiB-to-MiB conversion; reporter confirmed the change worked and clarified this was usability feedback. At the pin, `gpu_resource_manager.py:136-140` still rejects configured GiB capacity above measured MiB capacity. **Exclude as a resource-accounting bug**; no evidence of capacity duplication or lost ownership. Also outside selected ListResourceManager.

### #2326 — Restart/closed-file symptoms while saving a model

[Issue](https://github.com/NVIDIA/NVFlare/issues/2326), 9 comments. **Primary report: user/environment error; resolved.** The first restart explanation was Simulator sharing one process among multiple sites (`-t 1`); the later closed-file failure was diagnosed as OS resource exhaustion in Colab. Separately, maintainers found a real PipeHandler heartbeat send with a default five-second blocking timeout that delayed its read/heartbeat loop and proposed a fix. No fix PR was identified in this thread. **Exclude** the primary symptoms as production job lifecycle proof; record the secondary bug only as acknowledged external-trainer/Pipe mechanism context. PipeHandler is absent from the pin's current package tree, so current applicability was not established.

### #2166 — Server memory surge after hours

[Issue](https://github.com/NVIDIA/NVFlare/issues/2166), 10 comments. **Confirmed acknowledged historical metadata memory-exhaustion bug, but attribution of the reported run remains uncertain; fixed release reported.** Maintainers identified a job-metadata processing issue and said v2.3.9 contained the fix. The reporter's rerun on 2.3.5 succeeded; maintainer reproduction using a large model also did not show the surge. Thus the original memory chart is not proof of an allocation leak or training mechanism. No exact fixing commit is linked, and this audit did not reconstruct the metadata failure or assert ancestry. **Exclude** from current lifecycle scenarios: historical fixed metadata behavior with no new in-scope code evidence.

### #1843 — Simulator missing run_status after child failure

[Issue](https://github.com/NVIDIA/NVFlare/issues/1843), 50 comments. **Confirmed historical example dependency/reporting problem; fixed.** Initial maintainer diagnosis identified a missing result dictionary entry if MPM fails before publishing a result; later users confirmed removal of TensorFlow resolved example startup, and the apparent subsequent hang was slow CPU training. Merged [PR #1869](https://github.com/NVIDIA/NVFlare/pull/1869) (`c376f2b78e92947d2467c244782ce45278ad4271`, 2023-07-25) separates plot requirements. Related merged [PR #1985](https://github.com/NVIDIA/NVFlare/pull/1985) (`a060c60ffc706d67a5aae36abc9a6de56f33bec6`, 2023-11-09) improves MPM return-code recovery. At the pin, `simulator_runner.py:440-486` uses `.get('run_status')`, falls back to a return-code file/process exit code, and catches MPM exceptions before assigning the result. **Exclude** as a new production-chain defect or as proof that every process cleanup path is correct. Keep historical process result-versus-actual-exit separation as reference context.

### #1821 — Clock skew suppresses resource-check response

[Issue](https://github.com/NVIDIA/NVFlare/issues/1821), 0 comments. **Confirmed historical bug by explicit reproducing sequence/logs; closed, exact fix PR not identified.** A client ahead of server wall time performed reservation and then suppressed its reply against the server's absolute WAIT_UNTIL. The pin no longer contains `WAIT_UNTIL` or `wait_until` anywhere under the current F3 transport, and `core_cell.py:1940-2029` associates replies with request IDs and outstanding waiters; the cited receiver-side deadline suppression is absent. **Reference only**, no answer-key clock-skew adversary to recreate removed behavior. It illustrates that a missing reply may follow a completed reservation, while reservation TTL remains the backstop; it does not prove permanent resource loss.

## Second batch

### #1433 — Empty report

[Issue](https://github.com/NVIDIA/NVFlare/issues/1433), empty body, 0 comments. **Uncertain; closed.** No mechanism, reproduction, configuration or fix evidence. Explicitly exclude from confirmed/historical mechanism counts.

### #1371 — Simulator run_status symptom

[Issue](https://github.com/NVIDIA/NVFlare/issues/1371), 1 comment. **Uncertain; closed.** Maintainer requested a properly completed issue with environment versions; no diagnosis followed. The symptom resembles #1843, but sharing an error string is not evidence of a shared cause. Current Simulator fallback behavior is described above; **exclude** as an independently confirmed production lifecycle defect.

### #1336 — Deployment directory and worker exit -9

[Issue](https://github.com/NVIDIA/NVFlare/issues/1336), 3 comments. **Disputed/expected behavior; closed.** Maintainer explained site/job-id placement is intended and the observed -9 message was normal teardown in the old implementation. Later comment says that log disappeared after merged [PR #1380](https://github.com/NVIDIA/NVFlare/pull/1380) (`9c3d87366941de3099fefd741d7ba4a5d3785bba`, 2023-02-17). **Exclude** workspace-placement complaints and historical negative return codes as proof of lifecycle corruption. Do not generalize that all current negative exit codes are normal.

### #1221 — Client asks for task before server initialization

[Issue](https://github.com/NVIDIA/NVFlare/issues/1221), 4 comments. **Confirmed historical race; fixed.** Report shows a client received END_RUN before server workflow initialization; maintainers repeatedly confirm the patch is included in 2.2.4. [PR #1172](https://github.com/NVIDIA/NVFlare/pull/1172), merged `01f3bb4b6df1576d6057ed232935a4ac075246e8`, changes the fallback task from END_RUN to TRY_AGAIN. At the pin, `server_runner.py:283-291` explicitly returns TRY_AGAIN while `status == 'init'` and END_RUN for `status == 'done'`; this distinction must remain intact. **Historical reference only**; do not model restoration of the removed default or treat it as a new startup inconsistency.

### #1189 — os.setsid on Git Bash/Windows

[Issue](https://github.com/NVIDIA/NVFlare/issues/1189), 6 comments. **Acknowledged design/platform limitation; closed, no fix promised.** Discussion identifies Windows lacks `os.setsid`, and maintainers state Windows was not supported. **Exclude** unsupported platform behavior from the selected Linux local-process protocol. No claim is made about today's overall NVFlare Windows support.

### #1109 — Review deployed custom code before execution

[Issue](https://github.com/NVIDIA/NVFlare/issues/1109), 0 comments. **Uncertain support/feature request; closed without resolution.** Requests separating deployment from execution for code review; reports no accounting failure. **Exclude** as a bug and as a requirement for a new lifecycle pause state. The selected workflow's actual deployment/start ordering should be modeled from current code, not inferred from this unanswered question.

### #849 — Worker exits while reading image data

[Issue](https://github.com/NVIDIA/NVFlare/issues/849), 0 comments. **Uncertain; closed without diagnosis.** Only FINISHED:EXECUTION_EXCEPTION and a Pillow-loading observation are supplied. No process ownership, resource cleanup or shared-state evidence. **Exclude** as confirmed lifecycle bug; ordinary child exceptions remain a legitimate environment outcome.

### #193 — Admin shutdown removes recipients before sending command

[Issue](https://github.com/NVIDIA/NVFlare/issues/193), 1 comment. **Confirmed historical bug; fixed** by merged [PR #194](https://github.com/NVIDIA/NVFlare/pull/194) (`103737ab0bcf7ab1bfaa002885694191a7038570`, 2022-02-10). Maintainer identifies ordering in `_shutdown_app_on_clients`; the diff moves request dispatch/reply processing before `engine.remove_clients`. At the pin, `training_cmds.py:136-156` sends/processes shutdown before evaluating replies, and `:180-182` explicitly shuts down clients first. **Reference only**: bookkeeping must not erase the recipients needed to complete a command. System shutdown is adjacent to, but outside, selected job-only scheduling/cleanup; do not recreate the historical removal order as a hunt target.

### #316 — Admin runner default timeout aborts job

[Issue](https://github.com/NVIDIA/NVFlare/issues/316), 6 comments. **Primary report: user error; resolved.** Reporter confirms `AdminAPIRunner.run`'s 2000-second timeout explains consistent 33-minute aborts; setting zero caused immediate abort rather than disabling the timeout. A final second reporter pasted extensive custom training/configuration code but received no diagnosis. **Exclude** original report as spontaneous job abort and keep secondary report uncertain. Old `AdminAPIRunner` is absent from the pinned HCI tree; do not import its old timeout semantics into the current scheduler.

### #5093 — Slurm worker failure reason lost

[Issue](https://github.com/NVIDIA/NVFlare/issues/5093), 0 comments. **Confirmed historical bug; fixed** by merged [PR #5094](https://github.com/NVIDIA/NVFlare/pull/5094) (`196a3fdda5b56ef43b2e3386bff3ac0ce9794295`, 2026-08-12), present in the pin's local history. Root causes: allocation ExitCode can obscure a reportable step DerivedExitCode; a worker failing before check-in cannot write its own return-code file. Current `slurm/manager.py:317-331` preserves recognized derived codes, and `client_executor.py:630-643` upgrades a generic error while status is STARTING (and, with later logic, while STARTED). **Exclude Slurm backend and the fixed failure mapping as new targets**. The shared client executor's distinction between launched, checked-in and exited is relevant source context for a separately justified lifecycle audit.

## Mechanism grouping for root synthesis

1. **Readiness and terminal state must remain distinct**: #1221, fixed. Preserve TRY_AGAIN during initialization; use only as evidence/reference, not as a restored pre-fix model target.
2. **Accounting/recipient records versus physical command execution**: #193, fixed; #1821, removed receiver deadline behavior. Neither establishes a current defect; both motivate reading supported delayed-reply/cleanup paths while preserving present compensations.
3. **Child launch/result/exit are separate observations**: #2601 resolved missing dependency; #1843 fixed Simulator result handling; #5093 fixed alternate-launcher mapping. These do not establish local allocator leaks. New findings must have independently verified pinned source paths.
4. **Resource-related words are not resource ownership evidence**: #3196/#3197 are unconfirmed; #2559 is documented capacity validation; #2326's original failure was insufficient host resources. None is a confirmed ListResourceManager conservation defect.

No issue in this batch independently proves a currently unfixed selected-scope defect. This is an exclusion and historical-reference result, not a correctness verdict on the pinned lifecycle chain.

## Supplementary full PR-discussion audit

| PR | Top-level comments | Review records | Inline comments | Discussion resolution relevant to this audit |
|---|---:|---:|---:|---|
| #3554 | 6 | 11 | 22 | Human review focuses on example multi-client/multi-GPU configuration and missing import; automated checkpoint/barrier comments are not treated as confirmed production bugs. |
| #3392 | 1 | 1 | 0 | Rank-zero task access fix approved; supports historical classification of #3360. |
| #1869 | 2 | 1 | 0 | Plot requirements separated and reviewer agrees; supports #1843 dependency correction. |
| #1985 | 10 | 41 | 35 | Client and server return-code handling aligned; MPM exception, empty RC file and file removal errors addressed. Maintainer points to MPM/other monitors as child-exit compensation. Argument-parser refactor explicitly deferred, not an outstanding lifecycle bug. |
| #1380 | 1 | 41 | 56 | Client Cellnet migration; some hardcoded timeouts/refactors discussed. Alleged double FOBS explicitly rejected because Cellnet skips already encoded content. No new selected-scope ownership defect established by discussion. |
| #1172 | 0 | 1 | 0 | Race fix approved; fallback becomes TRY_AGAIN. |
| #194 | 0 | 6 | 3 | Review explicitly corrects send-before-remove ordering; author applies it. |
| #5094 | 2 | 6 | 4 | Reviewer asks about STARTING classification; author explains checked-in worker boundary and preserving explicit return codes. DerivedExitCode format width explanation resolves the other question. |

PR bodies/discussions establish intent and issue-to-fix links; present-code claims above remain anchored separately. All eight PRs are merged. Full diffs are archived for follow-up; this batch's source verification targeted the referenced mechanism rather than asserting exhaustive code review of each historical PR.
