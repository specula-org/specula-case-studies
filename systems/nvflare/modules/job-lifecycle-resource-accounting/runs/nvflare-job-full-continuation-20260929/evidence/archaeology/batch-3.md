# Batch 3 archaeology (core-commits.txt lines 201-300)

STATUS: COMPLETE

Pinned HEAD: 53ba7ee567468ea7971dad4faccef13c6cb35dc2. All 100 batch commits verified ancestors of HEAD (`git merge-base --is-ancestor <sha> HEAD`, checked=100 bad=0).
Method (intended): `git show --stat --format='%H%n%ad%n%s%n%n%b' <sha>` for every commit; `git show <sha> -- $(cat core-paths.txt)` for potentially relevant ones; HEAD code read with `sed -n` / `grep -n` to verify analogous sites. Method (actual): see BLOCKER below -- historical diffs are unreadable in this clone.
Classes: (a) in-scope bug fix; (b) in-scope feature/refactor changing lifecycle/resource semantics; (c) out of scope.

## 1. Coverage statistics

- Commits examined: 100 / 100 (core-commits.txt lines 201-300, 2023-03-31 .. 2025-02-20); all verified ancestors of HEAD.
- Classification: (a) in-scope bug fix = 9; (b) in-scope semantics-changing feature/refactor = 12; (c) out of scope = 79.
- Evidence basis (environment limit, see BLOCKER): historical diffs unreadable for all 100 commits; 100/100 classified
  from full message body + touched-file list only. 33 of them additionally have the described behaviour located and
  verified in HEAD source/tests (`[M+H]`); 67 are message/file-list only (`[M]`). Mechanisms of (a) items are
  therefore inferences from message + HEAD code, never from the historical hunk. Severity follows the requested
  rubric (Critical = wrong resource ownership / permanent capacity loss / wrong terminal status; High = stuck job /
  leaked process / blocked admission); "(inferred)" marks severities that depend on the unseen pre-fix code.

## 2. In-scope bug fixes (class a)

| Commit | Date | Summary | Root-cause mechanism (inferred, [M+H] unless noted) | Component | Severity | Fix completeness / analogous HEAD sites |
|---|---|---|---|---|---|---|
| bb840df0 | 2023-03-31 | update the abort_job status after the job complete | Terminal FINISHED_ABORTED written at abort time instead of when the job processes are gone (status vs process-lifetime mismatch; completion path could publish a different terminal status). HEAD: `Job.run_aborted` + finalization in `_job_complete_process` (job_def.py:173; job_runner.py:444-492, 802-808) | JobRunner / job store | High (inferred) | Partial. Other status writers still bypass the "decide at completion" rule: `abort_job` writes FINISHED_ABORTED directly for SUBMITTED/DISPATCHED (job_cmds.py:1061-1066) while JobRunner later writes DISPATCHED/RUNNING unconditionally (job_runner.py:670, 711); `set_status` has no transition guard (job_def_manager.py:459-481) -> L1, L1c, L2 |
| f49da279 | 2023-03-31 | Fixed a save_workspace error | [M] Unknown error in completion-time workspace archival | JobRunner completion | Low | HEAD reworked: archive-then-delete with 60 s retry before terminal publish (job_runner.py:493-531, 587-631); END_RUN->_save_workspace handler is dead in the parent (job_runner.py:132-133; server_runner.py:231; server_deployer.py:107-125) |
| 9f49a109 | 2023-04-03 | update the aborted job status immediately | Aborted-job status/`running_jobs` bookkeeping lagged the abort so admin shutdown stayed blocked; fix changed shutdown check to ignore `run_aborted` jobs | JobRunner, server training_cmds | Medium | Status half later reverted (HEAD publishes FINISHED_ABORTED only after exit+archival; unit test `test_stop_run_does_not_publish_terminal_status_before_completion`). Analogous check not updated: `restart` still refuses on any `running_jobs` entry (training_cmds.py:265) vs `shutdown` (training_cmds.py:164-169) |
| a060c60f | 2023-11-09 | enhance the rc handling for MPM | Job-process return code lost/unreliable when MPM force-exits; parent misclassified outcome. Fix: rc file + shared `get_return_code()` | mpm, SJ/CJ exit watchers | High (inferred; rubric would make a wrong terminal status Critical) | Partial: rc file written only when non-daemon threads remain (mpm.py:174-199); otherwise typed codes 101-103 collapse to EXECUTION_ERROR in `ProcessHandle.poll` (process_launcher.py:29,51-55) and the CP re-maps by status (client_executor.py:639-643) -> L4 |
| 38fa2c75 | 2023-12-04 | Fix meta file processing in storage and improve schedule job retrieval | Scheduler's 1 Hz meta scan vs concurrent meta writers; fix = mark-file skip for non-SUBMITTED jobs + storage meta handling | job store, JobRunner admission | Medium | Partial: `update_meta(replace=False)` is still an unlocked read-modify-write used by every status writer (filesystem_storage.py:251-275; job_def_manager.py:459-505) -> L2; scan/`get_job` not tolerant of concurrent delete and called outside JobRunner.run's try (job_def_manager.py:379-385, 517-531; job_runner.py:650, 661, 736-739) -> L3 |
| 4327d7c3 | 2024-01-05 | added handle for the empty return code file | Unguarded `int()` parse of rc file inside the exit-watcher threads aborted the rest of exit cleanup (client: free_resources, deregistration, JOB_COMPLETED; server: run_processes pop) | CJ/SJ exit watchers | Critical (inferred: permanent client capacity loss + stuck registration) | Partial: parse now guarded (fed_utils.py:552-561) but the cleanup sequence is still not a `finally` (client_executor.py:622-688; server_engine.py:203-234); exceptions from `job_handle.wait()`/`free_resources`/`process.wait()` still strand state -> L11 |
| e4f8d417 | 2024-01-16 | Fixed the client_executor improper lock use | Executor lock held across blocking abort/terminate work, stalling the exit watcher that needs the lock | ClientExecutor | High (inferred) | Client side fixed (client_executor.py:486-601). Server analogue: `send_command_to_child_runner_process` holds `engine.lock` across `cell.send_request` (server_engine.py:899-928) -> L8 |
| baae3d81 | 2024-04-03 | Fixed the authz and site_security check for check_resource command | check_resource request evaluated with wrong authz/site-security headers on the client -> wrong admission decision | resource check (admission) | Low | Complete for check path (server_engine.py:1043-1050; client admin.py:128-162). START_JOB/CANCEL_RESOURCE carry no ADMIN_COMMAND (server_engine.py:1052-1083): security evaluated only at check time (by design) |
| 8bb1b84c | 2024-05-28 | Missing sj heartbeat (fixed the early abort_job command issue) | Abort reaching an SJ before it can process commands was lost; SJ kept running unsupervised. Fix: SJ heartbeat; parent aborts untracked heartbeating jobs (fed_server.py:605-621); HEAD also always terminates the handle after graceful wait (server_engine.py:385-409) | abort path (server) | High | Partial: abort while DISPATCHED (deploy done, `_start_run` in progress) only writes FINISHED_ABORTED; nothing to stop, JobRunner then writes RUNNING (job_cmds.py:1061-1066; job_runner.py:374-393, 697-711, 802-811) -> L1 |

## 3. In-scope semantics-changing features/refactors (class b)

- 902a735b (2023-04-03) improve abort_job: status-dispatched abort -- SUBMITTED/DISPATCHED -> direct FINISHED_ABORTED in store; FINISHED:* -> no-op; else `stop_run` (job_cmds.py:1051-1084).
- 387e04a4 (2023-05-22) FL Hub: deployment via AppDeployerSpec; server deploy error -> `_deploy_job` raises; client deploy returns ERROR_MSG_PREFIX string (job_runner.py:185-196; client_engine.py:462-480).
- c699a645 (2023-07-21): typed job-process exit codes (ConfigError 103 / ComponentNotAuthorized 102 / Exception 101) produced by `mpm.run` (mpm.py:153-163; exit_codes.py).
- 734afc92 (2023-08-07): deploy policy with dead/failed clients -- no deploy reply = failure; min_sites/required_sites decide abort (job_runner.py:250-282).
- 2d2b065e (2023-09-27): site-security/authz gate on check_resources; block reason returned as `(False, reason)` with no reservation (scheduler_cmds.py:77-85; job_scheduler.py:187-197).
- 79de070c (2023-11-22): graceful END_RUN -- ABOUT_TO_END_RUN, END_RUN aux to clients, end-run readiness wait before END_RUN (server_runner.py:209-232); governs when the SJ exits.
- 0a0d3abd (2024-01-04): CJ->CP STARTING/STARTED/STOPPED notifications drive CP abort handling and exit-code remapping (client_app_runner.py:58-87; client_executor.py:347-350, 505-534, 639-643).
- 0e443f88 (2024-03-19): component (CC) veto on admission before reservation; component-initiated stop of running jobs.
- f948b6ec (2024-04-18): dead-job detection from heartbeat JOB_IDS vs run_processes, require-previous-report rule (fed_server.py:1004-1076).
- 7043c2ab (2024-10-10): no per-job listening ports; job processes connect via parent internal listener.
- dd256fe9 (2024-11-01): client job process ownership via JobLauncherSpec/JobHandleSpec; STARTING registration with `_PendingJobHandle`, rollback on launch failure (client_executor.py:299-334); JobReturnCode {0,1,9,127} mapping (process_launcher.py:29).
- c25c9140 (2024-11-15): SJ ownership via job handle; register after launch; abort = optional ABORT + off-thread terminate after graceful wait (server_engine.py:236-329, 354-409).

## 4. Mechanism groups (class a, grouped by shared mechanism)

- G1 Competing / mistimed terminal-status writers (status not tied to actual process lifetime, no transition guard):
  bb840df0, 9f49a109, 8bb1b84c (abort lost when target not ready). HEAD residue: L1, L1c, L2, L6.
- G2 Process-exit code propagation -> status classification: a060c60f, 4327d7c3. HEAD residue: L4.
- G3 Exception-unsafe exit/cleanup sequences (one failing step skips resource free / deregistration / completion
  event / status publication): 4327d7c3, f49da279. HEAD residue: L11, L3 (runner except-path re-raises), L9.
- G4 Lock held across blocking work in lifecycle actors: e4f8d417. HEAD residue: L8.
- G5 Job-store read/scan robustness under concurrent mutation (admission path): 38fa2c75. HEAD residue: L2, L3.
- G6 Admission-path authorization gating: baae3d81 (with b-items 2d2b065e, 0e443f88). HEAD residue: none found.
- G7 (HEAD-only family, no fixing commit in this batch) Reserved/allocated resources not released on failure paths
  after scheduling or allocation: L10, L9, L11 (free-while-running variant).

## 5. Possible unaudited sites at HEAD (leads for modeling / confirmation; not yet reproduced)

L1 [G1, High->Critical per rubric] Lost abort + terminal->non-terminal regression between `abort_job` and JobRunner.run.
   abort_job writes FINISHED_ABORTED for SUBMITTED/DISPATCHED without coordinating with JobRunner (job_cmds.py:1061-1066).
   JobRunner re-checks status only before deploy (job_runner.py:661) and before start (job_runner.py:697-701), but writes
   DISPATCHED after deploy (job_runner.py:670) and RUNNING after `_start_run` (job_runner.py:709-711) unconditionally;
   `set_status` has no guard (job_def_manager.py:459-481). (a) abort during `_deploy_job` (status SUBMITTED; client deploy
   bounded by admin_timeout=10 s, app/utils.py:92) is overwritten by DISPATCHED, the DISPATCHED re-check passes and the job
   runs; (b) abort during `_start_run` (SJ launch + START_JOB up to 20 s, server_engine.py:1068-1083) is overwritten by
   RUNNING; `_stop_run`/`mark_run_aborted` cannot act because run_processes/running_jobs have no entry yet
   (job_runner.py:374-393, 802-811). User is told "Aborted the job ... before running it."
L1c [G1, Critical per rubric, narrow window] `running_jobs[job]=job` (job_runner.py:709-710) precedes `set_status(RUNNING)`
   (job_runner.py:711); if the SJ already exited, `_job_complete_process` can publish the terminal status and delete the
   running_jobs entry (job_runner.py:444-535) before line 711, leaving the store at RUNNING with no tracker; such a job cannot
   be deleted (job_cmds.py:516-521) or aborted (job_runner.py:802-811).
L2 [G1/G5, Critical per rubric] Unlocked read-modify-write of job meta: `FilesystemStorage.update_meta(replace=False)` =
   `get_meta` + dict update + `_write` (filesystem_storage.py:251-275), used by `set_status`/`update_meta`/`refresh_meta`
   (job_def_manager.py:459-505) from the JobRunner thread (job_runner.py:670-689, 711, 720-726, and scheduler refresh at
   job_scheduler.py:300-308), the completion thread (job_runner.py:524) and admin threads (job_cmds.py:1062). No lock
   (only `_submit_record_lock`, job_def_manager.py:142). Example: scheduler `refresh_meta` of a SUBMITTED job racing
   `abort_job` rewrites STATUS=SUBMITTED over FINISHED_ABORTED.
L3 [G3/G5, High: permanent admission loss] JobRunner scheduling thread dies on a concurrent `delete_job`.
   `delete_job` is allowed for SUBMITTED jobs (job_cmds.py:516), including a job the runner has just selected or is
   deploying. Unguarded calls in `run()`: `get_jobs_to_schedule` (job_runner.py:650) -> `_scan` raises StorageException /
   FileNotFoundError if a listed job vanishes (job_def_manager.py:517-531; filesystem_storage.py:310-327, 435-440);
   `_check_job_status` dereferences `get_job(...)` which returns None for a deleted job (job_runner.py:661, 736-739;
   job_def_manager.py:379-385). Inside the try, `set_status(DISPATCHED)` fails and the except handler's
   `set_status(FAILED_TO_RUN)` (job_runner.py:720) raises again. `_start_job_runner` has no guard or restart
   (server_deployer.py:144-145) -> no later job is ever scheduled; the selected job's client reservations are also not
   cancelled (see L10).
L4 [G2, Critical per rubric] CJ terminal status depends on thread timing. Typed rc reaches the CP only via the rc file,
   which mpm writes only when non-daemon threads remain (mpm.py:174-201); otherwise `ProcessHandle.poll` maps 101/102/103
   to EXECUTION_ERROR (process_launcher.py:29,51-55; fed_utils.py:547-564) and the CP rewrites it to INFRASTRUCTURE_ERROR
   while STARTING (client_executor.py:639-643). Server: UNSAFE_COMPONENT -> `stop_run` -> FINISHED_ABORTED; INFRASTRUCTURE_ERROR
   -> `fail_run` -> FINISHED_ABNORMAL; CONFIG_ERROR -> EXCEPTION -> FINISHED_EXECUTION_EXCEPTION (fed_server.py:942-956;
   job_runner.py:544-572). A CJ ComponentNotAuthorized during config (before STARTED) can thus end FINISHED_ABORTED or
   FINISHED_ABNORMAL.
L5 [policy asymmetry, Low] Start-phase min_sites/required_sites enforcement only when `strict_start_job_reply_check`
   (default False, job_runner.py:313-343); default mode silently drops timed-out START_JOB clients from JOB_CLIENTS and
   the outcome barrier (job_runner.py:345-360) whereas deploy phase always enforces (job_runner.py:250-282). Unit tests
   (`test_start_run_non_strict_excludes_timed_out_clients_from_meta`) show this is intended; a late-starting CJ's failure
   report is then dropped as untracked (fed_server.py:938-940).
L6 [G1, may be out of scope as restart recovery] Nothing reconciles DISPATCHED/RUNNING jobs after a server-parent restart:
   `update_unfinished_jobs`/`update_abnormal_finished_jobs` exist (job_runner.py:762-796) but have no callers (grep);
   such jobs can neither be deleted (job_cmds.py:516-521) nor aborted when RUNNING (job_runner.py:802-811).
L7 [CJ startup, Low] STARTED-notification retry never gives up: after `retry_timeout` the loop logs an error and
   iterates again without sleeping or returning (client_app_runner.py:197-222), contradicting its docstring
   (client_app_runner.py:172-187); CJ never runs/exits while the CP stays STARTING; cleaned only by abort/heartbeat.
L8 [G4, Medium] `send_command_to_child_runner_process` holds `engine.lock` across `cell.send_request` (server_engine.py:899-928):
   1 s from `abort_app_on_server`, 5 s default from show_stats/get_errors/reset_errors/configure_job_log
   (server_engine.py:949-1005); blocks `wait_for_complete` (server_engine.py:218), `_remove_run_processes`
   (server_engine.py:391, 408), `_job_complete_process` (job_runner.py:448) and `fail_run`, which holds JobRunner.lock
   while waiting (job_runner.py:815-816), in turn stalling heartbeat outcome queries (fed_server.py:1011, 938).
L9 [resource, Low] StartJobProcessor frees an allocation only on exception (scheduler_cmds.py:114-133), but
   `ClientEngine.start_app` returns (does not raise) "Client app already started." / "Client app does not exist" after
   the token was already consumed by `allocate_resources` (client_engine.py:357-368; auto_clean_resource_manager.py:153-164)
   -> allocation never freed (AutoClean only expires un-allocated reservations). Hard to reach through supported APIs.
L10 [resource / Q4, Medium; Critical with a non-expiring ResourceManagerSpec] Server never cancels reservation tokens
   after a successful schedule: `cancel_client_resources` is called only from the scheduler's two "cannot schedule"
   branches (job_scheduler.py:229-254; grep). Uncancelled paths: SUBMITTED re-check fails (job_runner.py:661-663),
   `_deploy_job` raises (job_runner.py:669, 713-731), failed-deploy clients dropped (job_runner.py:692-695),
   DISPATCHED re-check fails (job_runner.py:697-701), `start_app_on_server` fails before START_JOB (job_runner.py:304-306),
   L3 crash. With List/GPU managers the reservation is held until expiry (30 ticks of 1 s,
   auto_clean_resource_manager.py:27-37, 102-117), so a later eligible job can get NO_RESOURCE and enter exponential
   back-off (job_scheduler.py:356-362); the spec requires cancellation of returned tokens (resource_manager_spec.py:44-55).
   Conversely, if deploy+SJ launch exceed the expiry, `allocate_resources` raises at START_JOB and the job fails
   (auto_clean_resource_manager.py:153-164; scheduler_cmds.py:114-133).
L11 [G3, Medium/High] Exit-cleanup not exception-safe: client `_wait_child_process_finish` performs free_resources ->
   run_processes.pop -> JOB_COMPLETED sequentially, not in `finally` (client_executor.py:622-688); server
   `wait_for_complete` skips the run_processes pop if `process.wait()` raises (server_engine.py:203-234). Also, if
   `threading.Thread(...).start()` fails after `launch_job` succeeded (client_executor.py:309-334), StartJobProcessor frees the
   allocation while the CJ runs (scheduler_cmds.py:129-133) and the executor entry is never removed.

## 6. Appendix: per-commit log


### BLOCKER (evidence limitation) -- recorded before per-commit review

The workspace clone is a blob-less partial clone: `.git/objects` is empty and borrows from
`.git/objects/info/alternates` (= /home/experiment/repos/nvflare/.git/objects), which only holds commits,
trees and the blobs reachable from the HEAD tree. Historical blobs are absent:

- `git show --stat d7319aad` -> `fatal: unable to read a8bea024700ec39e199d924be3caeb67f7d58f02`
- `git show d7319aad -- $(cat core-paths.txt)` -> same fatal error (no hunks printed)
- `git blame nvflare/private/fed/server/job_runner.py` -> `fatal: Cannot read blob 5b6755a9...`
- `git log -S...` pickaxe -> `fatal: unable to read ...`
- blob census over the 100 batch commits (`git diff-tree -r --no-renames --raw --no-abbrev` + `git cat-file -e`,
  helper /tmp/b3/info.sh): 899 core-path file changes; only 1 has both old and new blob readable and only 11 have
  the post-commit blob readable (these are versions still identical to HEAD). Even `git show --name-status`
  fails for some commits (rename detection needs blobs), so `git diff-tree --no-renames` is used for file lists.

No lazy fetch was attempted (repo config has no promisor; fetching would modify the repository and
the upstream is outside the permitted sources). Therefore the "read the diff" step is NOT possible
for this batch. Substitute method used for every commit:
1. `git log -1 --format='%H%n%ad%n%s%n%n%b' <sha>` (full message) -- works.
2. `git diff-tree -r --no-renames --name-status <sha>` (file list; `--stat`/rename detection need blobs) -- works.
3. For candidate commits: read the CURRENT HEAD implementation of the touched core functions and
   confirm whether the behavior described by the commit message is present at HEAD, and look for
   analogous sites with the same mechanism. Mechanisms below are therefore "message + HEAD code"
   inferences, labelled as such; no historical hunk was seen.

Coordinator confirmation (mid-task message): diffs are unavailable by environment design (alternate object store is a
`blob:none` partial clone); no work-around attempted (no git command in /home/experiment/repos/nvflare, no fetch).
ALL 100 commits in this batch are therefore classified from message body + touched-file list only, plus
verification against HEAD source/tests. Evidence level tags used below:
`[M]` = message/file-list only; `[M+H]` = message/file-list + behaviour confirmed/located in HEAD code.

Format: `line# sha date | subject | core files touched | class | note`

201 d7319aad 2023-03-31 | Fixed job could not run when overseer is offline (#1625) | worker_process.py, client_app_runner.py, fed_client_base.py | (c) [M+H] | CJ startup depended on overseer (HA SP discovery). Overseer code is gone at HEAD (`grep -i overseer` in worker_process.py/client_app_runner.py/fed_client_base.py/fed_server.py = no hits); CJ now connects with CP-supplied `args.sp_target/sp_scheme` (client_app_runner.py:55-57). HA excluded.
202 26f046b6 2023-03-31 | Removing UDS (#1616) | fed_server.py | (c) [M] | transport driver removal.
203 bb840df0 2023-03-31 | update the abort_job status after the job complete (#1627) | job_def.py, job_runner.py | (a) [M+H] High (inferred) | Body empty. HEAD shows the resulting contract: `Job.run_aborted` flag (job_def.py:173) set by `mark_run_aborted` (job_runner.py:802-808); terminal FINISHED_ABORTED is decided only when the SJ process is gone (`_job_complete_process`, job_runner.py:444-492). Mechanism (inferred): terminal status of an aborted RUNNING job was written at abort time, not at process exit (status/process-lifetime mismatch; completion path could publish a different terminal status). See follow-up 9f49a109 (line 209) and mechanism group G1.
204 04363802 2023-03-31 | Add missing parent constructor (#1612) | client_app_runner.py | (c) [M+H] | `ClientAppRunner.__init__` now calls `super().__init__()` (client_app_runner.py:44). Constructor hygiene; no lifecycle contract involved.
205 f49da279 2023-03-31 | Fixed a save_workspace error (#1634) | job_runner.py | (a) [M] Low | Body empty; exact error not recoverable. Completion-time workspace archival. HEAD `_save_workspace` (job_runner.py:587-631) archives run/result/log/audit roots and deletes sources only after a successful archive; `_job_complete_process` retries archival up to WORKSPACE_SAVE_RETRY_GRACE_TIME=60s before publishing the terminal status (job_runner.py:493-522). `handle_event(END_RUN)->_save_workspace` (job_runner.py:132-133) is effectively dead in the parent: END_RUN is only fired by ServerRunner in the SJ (server_runner.py:231) and JobRunner is registered only in the parent RunManager (server_deployer.py:107-125).
206 c30e3c71 2023-04-01 | delay the overseer agent start for client job worker process (#1636) | client_app_runner.py, fed_client_base.py, fed_server.py | (c) [M+H] | overseer/HA; overseer removed at HEAD.
207 902a735b 2023-04-03 | Fix AIO task cancellation and improve abort_job (#1637) | job_cmds.py | (b) [M+H] | "improve abort_job cmd". HEAD contract of `abort_job` (job_cmds.py:1051-1084): SUBMITTED/DISPATCHED -> set FINISHED_ABORTED directly in the store (no JobRunner coordination); `FINISHED:*` -> "already completed"; otherwise `job_runner.stop_run`. The DISPATCHED branch is the root of HEAD lead L1 (status overwrite race with JobRunner.run).
208 11cf10af 2023-04-03 | Fix CI (#1639) | client_run_manager.py | (c) [M] | CI/integration-test fix (abort_job.yml authorization test); no semantics recoverable.
209 9f49a109 2023-04-03 | update the aborted job status immediately (#1640) | job_runner.py (+ server training_cmds.py) | (a) [M+H] Medium | Body: "update the aborted job status immediately; Enhance the shutdown server running job check". HEAD keeps the shutdown half: `shutdown` refuses only if a running job has `run_aborted == False` (server training_cmds.py:164-169), whereas `restart` still refuses on any entry in `running_jobs` (training_cmds.py:265) -> inconsistent analogous check. The "immediate" half is NOT present at HEAD for RUNNING jobs (FINISHED_ABORTED is published by `_job_complete_process` only after process exit + archival, job_runner.py:486-524), i.e. later history reverted it. Mechanism group G1.
210 ad532149 2023-04-03 | Print job schedule result (#1631) | job_scheduler.py | (c) [M] | logging (`_update_schedule_history` log, job_scheduler.py:320-333).
211 36e26e95 2023-04-03 | Do not shutdown job runner when server turn to cold state (#1619) | job_scheduler.py, fed_server.py, job_runner.py, server_engine.py, server_runner.py | (c) [M+H] | HA hot/cold. HEAD remnants: runner loop skips scheduling unless `HotState` (job_runner.py:643-644); `pause_server_jobs`, `restore_running_job`, `update_unfinished_jobs`, `update_abnormal_finished_jobs` have no callers at HEAD (grep). HA excluded.
212 797584dd 2023-04-03 | Fix file license headers (#1643) | many | (c) [M] |
213 f96cfa7e 2023-04-04 | Use secure logging for exceptions (#1645) | server_runner.py | (c) [M] |
214 88423c1d 2023-04-04 | Update the _turn_to_cold to set to ColdState first (#1649) | fed_server.py | (c) [M+H] | HA; `_turn_to_cold` no longer exists at HEAD.
215 b4893367 2023-04-05 | fix abort_job in old FLAdminAPI (#1657) | job_cmds.py (+ fl_admin_api.py) | (c) [M] | admin-API reply compatibility.
216 9f66c7ec 2023-04-14 | Support pool stats file creation (#1687) | job_def.py, worker_process.py, runner_process.py | (c) [M] | stats pool files.
217 122ab186 2023-04-25 | Fixed a race condition issue for HA when job is about to end_run (#1708) | fed_server.py, job_runner.py | (c) [M] | explicitly HA-scoped race; HA restore paths are dead code at HEAD (see 211).
218 1acd9af9 2023-05-05 | Api parity (#1722) | job_def_manager.py, job_def.py, job_cmds.py, message_send.py, server_engine.py | (c) [M] | admin/FLARE API parity.
219 387e04a4 2023-05-22 | FL Hub (#1739) | job_def_manager.py, job_def.py, client_engine.py, client training_cmds.py, job_runner.py, server_runner.py (+app_deployer_spec.py, app_deployer.py) | (b) [M+H] | Introduced pluggable app deployment (AppDeployerSpec). HEAD contract: server deploy = `AppDeployer().deploy(...)` returning an error string -> `_deploy_job` raises (job_runner.py:185-196); client deploy uses component `APP_DEPLOYER` or default and returns `ERROR_MSG_PREFIX` string (client_engine.py:462-480).
220 77daca3a 2023-06-02 | Add missing cert chain verification on submitted job signatures | client training_cmds.py, job_runner.py | (c) [M+H] | Security (signature chain). Lifecycle note: server-side verification runs AFTER the app is extracted into the server run dir and raises without removing it (job_runner.py:185-209); JobRunner.run's except path does not clean the server run dir when `_deploy_job` raises (job_id is still None, job_runner.py:713-720). Client side now verifies in a temp staging dir before deploying (training_cmds.py:112-130).
221 54542003 2023-07-05 | Change BaseException to Exception (#1790) | worker_process.py, client_engine.py, scheduler_cmds.py, fed_server.py, job_cmds.py, job_runner.py, server_app_runner.py, server_engine.py, server_runner.py | (c) [M+H] | Mechanical handler narrowing. Lifecycle-relevant consequence at HEAD: cleanup handlers only catch `Exception` (e.g. JobRunner.run except, job_runner.py:713; StartJobProcessor, scheduler_cmds.py:129-133), so a BaseException skips FAILED_TO_RUN/resource free; the one deliberate `except BaseException` left is the pending-handle rollback in `JobExecutor.start_app` (client_executor.py:312-316). No evidence of a defect.
222 fe36d4a5 2023-06-23 | NewCell | fed_client_base.py, fed_server.py | (c) [M] | messaging cell.
223 96c55bb5 2023-07-12 | Revert "Remove print/logger" / Revert "NewCell" | fed_client_base.py, fed_server.py | (c) [M] |
224 97eaae85 2023-06-23 | NewCell | fed_client_base.py, fed_server.py | (c) [M] |
225 14727807 2023-07-18 | Comment out import NewCell to keep original calling API | fed_client_base.py, fed_server.py | (c) [M] |
226 e9e527b2 2023-07-19 | remove abort_task command (#1854) | job_cmds.py | (c) [M+H] | admin command removal (task-level abort). Client-side `AbortTaskProcessor`/`abort_task` still exist at HEAD (client training_cmds.py:50-61, client_executor.py:603-620); only the server admin command was removed.
227 de4b1504 2023-07-25 | WIP: simulator issue | fed_client_base.py, fed_server.py | (c) [M] | simulator.
228 c699a645 2023-07-21 | support roche; logger config; grpc options default | worker_process.py, runner_process.py, client_app_runner.py, client_executor.py, fed_server.py, server_app_runner.py, server_runner.py (+ new fuel/common/exit_codes.py) | (b) [M+H] | Introduced typed job-process exit codes. HEAD contract: `mpm.run` maps ConfigError->103, ComponentNotAuthorized->102, other Exception->101 (mpm.py:153-163); the rc is written to `_process_rc.txt` ONLY when non-daemon threads remain (mpm.py:174-199), otherwise it is only the OS exit code; `ProcessHandle.poll` collapses every exit code except 0/1/9 to EXECUTION_ERROR (process_launcher.py:29,51-55); `get_return_code` prefers the rc file (fed_utils.py:547-564). Server maps codes to terminal status in `_classify_finished_job_status` (job_runner.py:544-572). Basis of HEAD lead L4.
229 734afc92 2023-08-07 | Support admin client handlers and submit_job with custom data (#1881) | job_def.py, client_app_runner.py, fed_server.py, job_cmds.py, job_runner.py, server_engine.py | (b) [M+H] | Squash; bullets "check deploy policy for dead clients", "improve job status handling", "use run_abort_signal to control run loop". HEAD deploy policy: a client with no deploy reply counts as failed and min_sites/required_sites decide abort (job_runner.py:250-282). Start-phase policy is asymmetric: min_sites/required_sites are enforced for timed-out START_JOB replies only when `strict_start_job_reply_check` is true (default False, job_runner.py:313-343); in default mode timed-out clients are silently dropped (job_runner.py:345-353) -> HEAD lead L5.
230 933f630e 2023-08-16 | Fixed the recursive FLComponents creation (#1934) | client_app_runner.py, server_runner.py | (c) [M] | component-config construction.
231 7e904c2b 2023-08-16 | Rename Cell to CoreCell / NewCell to Cell | client_executor.py, client_run_manager.py, fed_client_base.py, fed_server.py, message_send.py, server_engine.py | (c) [M] | rename.
232 b07b7639 2023-08-29 | Remove fobs calls (#1960) | client_executor.py, client_run_manager.py, scheduler_cmds.py, fed_server.py, server_engine.py | (c) [M] | serialization call cleanup.
233 c6d8f3a8 2023-08-30 | Client controller (#1913) | (task controller files) | (c) [M] | workflow/task controller.
234 bf30d861 2023-09-08 | Optimize workspace saving and download_job command changes (#1979) | job_def_manager.py, job_cmds.py | (c) [M] | artifact storage/download format (job store `save_workspace`).
235 3a67a336 2023-09-12 | Client Controlled Workflow (#1967) | - | (c) [M] | CCWF.
236 f14ebfee 2023-09-12 | prepare the download_job data files (#1984) | job_def_manager.py, job_cmds.py | (c) [M] | download.
237 a99f0ee4 2023-09-13 | Support big job workspace (#1988) | job_def_manager.py | (c) [M] | binary download; bullet "do not create workspace symlink before job done" is an artifact-availability-vs-terminal-status concern (HEAD now publishes terminal status only after archival, job_runner.py:493-524).
238 efba82fc 2023-09-13 | Add secure argument to Task and set secure argument in cell's call | client_run_manager.py, server_engine.py, server_runner.py | (c) [M] |
239 3ddd07cf 2023-09-18 | Support secure task in CCWF and comm improvement (#1999) | (comm) | (c) [M] |
240 494089a7 2023-09-20 | Reject legacy job | job_cmds.py | (c) [M] | submit-time validation.
241 2d2b065e 2023-09-27 | Site-specific Authorization (#1858) | job_scheduler.py, client_engine.py, fed_client_base.py, client training_cmds.py, fed_server.py, job_runner.py, server_engine.py | (b) [M+H] | "factoried the site security and check_resources using check_security". HEAD contract: server fires BEFORE_CHECK_CLIENT_RESOURCES and a JOB_BLOCK_REASON yields SCHEDULE_RESULT_NO_RESOURCE (retry with back-off, NOT block) before any reservation (job_scheduler.py:187-197); client fires BEFORE_CHECK_RESOURCE_MANAGER and a block reason is returned as `(False, <reason>)` in the token slot, with no reservation (scheduler_cmds.py:77-85). `cancel_client_resources` only cancels `(True, token)` entries (server_engine.py:1052-1066), so overloading the token slot with a reason is safe.
242 125cba83 2023-09-28 | Add a custom authentication example (#2041) | fed_server.py | (c) [M] | CLIENT_REGISTERED NotAuthenticated handling (registration).
243 57fea64b 2023-09-29 | Fix auth unit test and integration tests | server_engine.py | (c) [M] |
244 571f17fd 2023-10-06 | Restore non-aio GRPC and a few improvements (#2058) | client_run_manager.py, fed_client_base.py, server_runner.py | (c) [M+H] | bullets "fix CP HB bug; add retry for result submit". CP heartbeat is the orphan-job sync channel at HEAD (client sends JOB_IDS = executor run_processes keys, server replies ABORT_JOBS = client_jobs - (run_processes U pending-outcome jobs), communicator.py:594-646, fed_server.py:1004-1076); the specific HB bug is not recoverable from the message -> kept (c).
245 fa4290fc 2023-10-10 | Removed 4G Limit on non-bytes data | server_engine.py | (c) [M] |
246 925a206e 2023-10-23 | Improve grpc 24 (#2088) | server_runner.py | (c) [M] |
247 a060c60f 2023-11-09 | enhance the rc handling for MPM (#1985) | worker_process.py, runner_process.py, client_executor.py, server_engine.py (+ mpm.py, fed_utils.py, fl_constant.py) | (a) [M+H] High | Job-process return code was not reliably propagated to the parent when MPM had to force-exit; fix introduced the rc-file protocol and the shared `get_return_code()` (bullets: "Added rc enhancement for client_executor", "extract the common function for get_return_code()"). HEAD: rc file written only on the `os._exit` path (mpm.py:174-199), parent reads it then deletes it (fed_utils.py:547-564) in both `ServerEngine.wait_for_complete` (server_engine.py:203-234) and `JobExecutor._wait_child_process_finish` (client_executor.py:630). Fix completeness: when NO non-daemon thread remains, the typed rc (101-103) is only the OS exit code and `ProcessHandle.poll` collapses it to EXECUTION_ERROR (process_launcher.py:29,51-55); the client then re-maps by status (STARTING->INFRASTRUCTURE_ERROR, STARTED->EXCEPTION, client_executor.py:639-643) -> HEAD lead L4 (terminal status depends on thread timing).
248 2dad0bde 2023-11-17 | Support sys vars for job config and parameterized template in job config (#2145) | worker_process.py, client_engine.py, client_executor.py | (c) [M] | config templating.
249 495f3b04 2023-11-20 | Fix simulator (#2156) | fed_server.py | (c) [M] |
250 79de070c 2023-11-22 | Support graceful end_run processing (#2158) | server_runner.py (+ client_runner.py, tbi.py) | (b) [M+H] | In-job completion: END_RUN is fired only after ABOUT_TO_END_RUN, END_RUN aux to clients, and `check_end_run_readiness` (server_runner.py:209-232), all under `wf_lock`; determines when the SJ exits and therefore when the parent classifies the job. Not a lifecycle-state defect fix.
251 eecd95d3 2023-11-29 | support getTask and submitResult timeout in job config (#2173) | client_run_manager.py, fed_client_base.py | (c) [M] |
252 635f4fd4 2023-11-29 | Fixed the SystemVarName.SECURE_MODE error in simulator (#2174) | client_app_runner.py | (c) [M] | simulator.
253 38fa2c75 2023-12-04 | Fix meta file processing in storage and improve schedule job retrieval (#2186) | job_def_manager.py, job_runner.py (+ storage.py, filesystem_storage.py) | (a) [M+H] Medium | Bullets: "fix meta file processing in storage; enhance schedule job; use mark file to reduce meta reading; make get_jobs_to_schedule abstract". HEAD: `get_jobs_to_schedule` scans with `_ScheduleJobFilter`, tagging every non-SUBMITTED job so it is never re-read (job_def_manager.py:109-121, 512-531); storage writes meta via temp file + `os.replace` (filesystem_storage.py:33-76). Mechanism (inferred): scheduler (1 Hz full meta scan) processing job meta concurrently with writers. Fix completeness: (i) `update_meta(replace=False)` is still an unlocked read-modify-write (filesystem_storage.py:251-275) used by `set_status`/`update_meta`/`refresh_meta` (job_def_manager.py:459-505) from >=3 threads -> HEAD lead L2 (lost status update); (ii) `_scan` does `list_objects` then `get_meta`/`tag_object` with no tolerance for a concurrently deleted job (job_def_manager.py:517-531, filesystem_storage.py:310-327,435-440) and `get_jobs_to_schedule` is called outside any try in JobRunner.run (job_runner.py:650) -> HEAD lead L3.
254 d67baf4d 2023-12-20 | Fixed a race condition issue during the server start (#2235) | fed_server.py (+ server_deployer.py) | (c) [M+H] | Body empty; server bootstrap ordering. HEAD ordering: comm/state set up in `deploy` (fed_server.py:1216-1237); JobRunner thread started BEFORE SYSTEM_START is fired (server_deployer.py:136-139) and JobRunner tolerates a not-yet-set scheduler (`if self.scheduler`, job_runner.py:655; scheduler bound on SYSTEM_START, job_runner.py:129-131). Specific race not recoverable; no lifecycle-state evidence -> (c).
255 0a0d3abd 2024-01-04 | Enhanced the client job status (#2247) | client_app_runner.py, client_engine.py, client_executor.py, client training_cmds.py | (b) [M+H] | CJ->CP status notification (STARTING/STARTED/STOPPED) with configurable notify timeout. HEAD contract: CJ sends NOTIFY_JOB_STATUS STARTED before running and STOPPED after (client_app_runner.py:58-87); CP stores it in `run_processes[job][STATUS]` without the executor lock (client_executor.py:347-350); status drives abort handling (client_executor.py:505-534) and exit-code re-mapping (client_executor.py:639-643). Residual: STARTED notification retry loop never gives up after `retry_timeout` (no return after the error log, client_app_runner.py:197-222) -> HEAD lead L7.
256 4327d7c3 2024-01-05 | added handle for the empty return code file | client_executor.py, server_engine.py (+ fed_utils.py) | (a) [M+H] Critical (inferred: permanent client capacity loss + stuck registration) | Mechanism: an unguarded parse of the process rc file (empty file -> `int('')` ValueError) inside the process-exit watcher threads aborted the exit-cleanup path (client: free_resources / run_processes.pop / JOB_COMPLETED; server: run_processes.pop -> job never finalized). HEAD guards the parse and falls back to the launcher code (fed_utils.py:552-561). Fix completeness: the rest of the exit-cleanup sequences are still not exception-safe -- in `_wait_child_process_finish` `free_resources`, `run_processes.pop` and the JOB_COMPLETED event are plain sequential statements, not a `finally` (client_executor.py:676-688), so an exception from `job_handle.wait()` (client_executor.py:628) or from a resource manager's `free_resources` (client_executor.py:677) still strands the job entry and its resources; in `ServerEngine.wait_for_complete` an exception from `process.wait()` (server_engine.py:204) skips the `run_processes.pop` (server_engine.py:233), leaving the job "running" until an abort's `_remove_run_processes` (server_engine.py:385-409). Mechanism group G3.
257 e4f8d417 2024-01-16 | Fixed the client_executor improper lock use (#2282) | client_executor.py | (a) [M+H] High | Mechanism (inferred from title + HEAD shape): executor lock held across blocking abort/terminate/wait work, stalling the child-exit watcher that needs the same lock to deregister the job. HEAD: `abort_app` only snapshots state under `self.lock` and terminates outside it (client_executor.py:496-534); `_terminate_job` polls under short lock sections (client_executor.py:581-601). Fix completeness: analogous server-side pattern remains -- `ServerEngine.send_command_to_child_runner_process` holds `engine.lock` across `cell.send_request(timeout)` (server_engine.py:899-928; timeout 1.0 s from `abort_app_on_server`, 5.0 s default from show_stats/get_errors/reset_errors/configure_job_log, server_engine.py:949-1005), while `wait_for_complete` (server_engine.py:218), `_remove_run_processes` (server_engine.py:391,408), `JobRunner._job_complete_process` (job_runner.py:448) and `JobRunner.fail_run` (job_runner.py:815-816, which holds JobRunner.lock while waiting) need `engine.lock` -> HEAD lead L8 (bounded stalls, not deadlock). Mechanism group G4.
258 5fae920b 2024-02-02 | Added a few workarounds for HTTP driver's latency issues (#2343) | fed_client_base.py | (c) [M] | transport.
259 4f30f68b 2024-03-08 | Controller Refactor Part 1: separate communication (#2390) | server_runner.py | (c) [M] | workflow comm.
260 2d0c6094 2024-03-11 | Job submission with binary protocol (#2393) | job_def_manager.py, job_def.py, job_cmds.py | (c) [M] | submission transport ("changed to use move file" in storage).
261 0e443f88 2024-03-19 | Multiple CC Authorizer support CCManager (#2396) | job_scheduler.py, scheduler_cmds.py, fed_server.py, job_runner.py, server_engine.py | (b) [M+H] | Confidential-computing gate on admission ("Address the client side CC check before job scheduled", "fixed the PEER_FL_CONTEXT error", "Added function to stop current running job if CC verify fail"). HEAD contract: check_resource carries peer FL context (scheduler_cmds.py:74-75) and component policies can veto admission through JOB_BLOCK_REASON before any reservation (scheduler_cmds.py:77-82; job_scheduler.py:191-197). CC components themselves are optional (app_opt) -> out of scope.
262 2d3b42df 2024-03-19 | Support Responder functions (#2397) | server_runner.py | (c) [M] | workflow ("remove wait_for_task, handle_dead_job from controller").
263 385dc3c2 2024-03-22 | Add back request header (#2440) | server_engine.py | (c) [M] | request header restore (see 266).
264 0e0b17a3 2024-04-03 | improve reliable msg (#2459) | server_runner.py | (c) [M] |
265 cc7ce3e1 2024-04-03 | CC block byoc jobs (#2403) | job_cmds.py | (c) [M] | submit-time CC policy.
266 baae3d81 2024-04-03 | Fixed the authz and site_security check for check_resource command (#2462) | server_engine.py (+ client admin.py) | (a) [M+H] Low | Admission-path authorization: the check_resource request was not evaluated with the right headers/flags by the client admin dispatcher. HEAD: server marks CHECK_RESOURCE with `ADMIN_COMMAND=check_resources`, `REQUIRE_AUTHZ=false` + security data (server_engine.py:1043-1050); client runs `SiteSecurity.authorization_check` for any request carrying ADMIN_COMMAND and user authz only if REQUIRE_AUTHZ=="true" (client admin.py:128-162); a denial is an error reply -> `(False, message)` without reservation (server_engine.py:1026-1031). Fix completeness: START_JOB and CANCEL_RESOURCE carry no ADMIN_COMMAND (server_engine.py:1052-1083), so site security is evaluated only at check time (consistent; noted for the model).
267 75faaec9 2024-04-16 | Added more logging for the job status changing (#2480) | job_runner.py | (c) [M] | logging only (status-transition log lines, e.g. job_runner.py:712).
268 f948b6ec 2024-04-18 | Improve dead client handling (#2506) | fed_server.py, server_engine.py, server_runner.py | (b) [M+H] | Dead-job detection contract at HEAD: server compares heartbeat JOB_IDS with `run_processes`; a participant that reported the job before and now omits it triggers `notify_dead_job` -> SJ HANDLE_DEAD_JOB (fed_server.py:1025-1071, server_engine.py:886-897; `sync_client_jobs_require_previous_report` default True).
269 1ea74d77 2024-05-07 | Add client controller executor (#2530) | client_run_manager.py | (c) [M] |
270 03f6a006 2024-05-20 | Fobs auto register (#2567) | worker_process.py, runner_process.py | (c) [M] |
271 8bb1b84c 2024-05-28 | Missing sj heartbeat (#2583) | fed_server.py, server_engine.py | (a) [M+H] High | Body: "Added the missing SJ heartbeat, fixed the early abort_job command issue." Mechanism: an abort that reaches the SJ before it is able to process commands was lost (optional command, SJ keeps running unsupervised after the parent dropped its run_processes entry); fix = SJ heartbeat to parent and parent aborts any heartbeating job it no longer tracks, marking it aborted if RUNNING (fed_server.py:604-621). HEAD additionally always calls `job_handle.terminate()` after the graceful wait in `_remove_run_processes` (server_engine.py:385-409). Fix completeness: the early-abort window BEFORE the SJ is tracked is not covered -- while a job is DISPATCHED (deploy done, `_start_run` in progress, job_runner.py:661-711) `abort_job` only writes FINISHED_ABORTED to the store (job_cmds.py:1061-1066): `_stop_run` has no run_processes entry and `mark_run_aborted` has no running_jobs entry (job_runner.py:374-393, 802-811), and JobRunner then writes RUNNING -> HEAD lead L1.
272 35972e9f 2024-06-06 | add the runner_config to the client, available through client_engine (#2615) | client_app_runner.py | (c) [M] |
273 265c21cd 2024-06-07 | Added engine.add_component() function (#2621) | client_engine.py, client_run_manager.py, server_engine.py | (c) [M] |
274 9af7ce8c 2024-06-26 | Allow the simulator to pass the End_Run aux message to clients (#2653) | server_engine.py | (c) [M] | simulator.
275 ef93a5cf 2024-07-10 | [2.5] Support app commands through admin (#2647) | client_run_manager.py, job_cmds.py, server_engine.py | (c) [M] | app command channel.
276 430b7d40 2024-07-30 | [2.5] TIE and Flower Integration (#2523) | client_app_runner.py, server_app_runner.py | (c) [M] | integration framework.
277 47b0b134 2024-08-27 | Fixed the SubprocessLauncher missing app_custom_folder in the PythonPath (#2857) | client_executor.py, server_engine.py (+ fed_utils.py) | (c) [M+H] | Launch environment for job processes (custom dir on PYTHONPATH, now in ProcessJobLauncher.launch_job, process_launcher.py:68-75); the user-facing symptom is in the training-script SubprocessLauncher (training execution, out of scope). Only relevant as a generic startup-failure source.
278 3b261095 2024-09-25 | Upgrade formatter version (#2957) | job_def_manager.py, fed_client_base.py, fed_server.py | (c) [M] | formatting.
279 7043c2ab 2024-10-10 | Remove the need to create additional ports when running a job (#3017) | client_engine.py, client_executor.py, server_engine.py | (b) [M+H] Low | Removed a per-job resource: job processes no longer need extra listening ports; CJ/SJ connect back through the parent's internal listener (PARENT_URL/ROOT_URL args, client_executor.py:285, server_engine.py:285-286). No port bookkeeping remains in the launch path at HEAD.
280 1e8e2ad5 2024-10-17 | Enhance comm scalability Part 1 (#3047) | client_app_runner.py, client_executor.py, client_run_manager.py, fed_client_base.py, fed_server.py, message_send.py, server_engine.py | (c) [M] | comm; "change to use parent fqcn for cj2cp messages" (CJ status notifications target the CP fqcn, client_app_runner.py:192-193).
281 80f9e826 2024-10-31 | Support aborting messages (#3053) | client_run_manager.py | (c) [M] | message-level abort.
282 dd256fe9 2024-11-01 | Job launcher (#3049) | job_launcher_spec.py(new), job_launcher/process_launcher.py(new), job_scheduler.py, client_engine.py, client_executor.py, scheduler_cmds.py, job_runner.py, server_engine.py | (b) [M+H] | Client job process ownership moved behind JobLauncherSpec/JobHandleSpec ("JobReturnCode standard"). HEAD contract: launcher chosen per job via BEFORE_JOB_LAUNCH event (`get_job_launcher`), `launch_job` returns a handle whose `wait/poll/terminate` define process lifetime (job_launcher_spec.py:66-120, process_launcher.py:32-83); CP registers the job as STARTING with a `_PendingJobHandle` before launch and deregisters on launch failure (client_executor.py:299-316); exit watcher frees resources and deregisters (client_executor.py:622-688). `JOB_RETURN_CODE_MAPPING={0,1,9}` collapses other exit codes (process_launcher.py:29) -> lead L4.
283 dc6598e2 2024-11-05 | Support extra provision builder generated component files (#3056) | worker_process.py, runner_process.py | (c) [M] |
284 c25c9140 2024-11-15 | Job launcher server side (#3055) | client_process_launcher.py(new), process_launcher.py, server_process_launcher.py(new), client_executor.py, fed_server.py, job_runner.py, server_engine.py | (b) [M+H] | SJ ownership via job handle. HEAD contract: `_start_runner_process` launches then registers `run_processes[job]={JOB_HANDLE, PARTICIPANTS}` and starts `wait_for_complete` (server_engine.py:236-329); abort = optional ABORT command + off-thread `_remove_run_processes` that always terminates the captured handle after the graceful wait (server_engine.py:354-409). Registration happens only after `launch_job` returns, so an abort/heartbeat in that gap sees no entry (server_engine.py:318-327 vs fed_server.py:604-610).
285 1a17390b 2024-11-20 | Support large object streaming (#3061) | client_run_manager.py, fed_server.py, run_manager.py, server_engine.py | (c) [M] | model/object streaming (excluded).
286 82fe6634 2024-11-21 | Add ability for clients to send error log to server (#3057) | client_executor.py | (c) [M] | log shipping.
287 5534af5f 2024-11-23 | Support Aux Message and Object Streaming in SP and CP (#3068) | client_engine.py, client_run_manager.py, fed_server.py, run_manager.py, server_engine.py, server_runner.py | (c) [M] | aux/streaming.
288 c6f25218 2024-12-04 | Docker job launcher (#3072) | client_process_launcher.py, process_launcher.py, server_process_launcher.py, runner_process.py, client_executor.py, client_run_manager.py, fed_server.py, job_runner.py, server_engine.py | (c) [M] | Docker backend excluded; ProcessJobLauncher only refactored ("extract generate_run_command()", event renamed GET_JOB_LAUNCHER -> BEFORE_JOB_LAUNCH, process_launcher.py:85-87).
289 fab6347a 2024-12-04 | Logger hierarchy (#3081) | many | (c) [M] | logging.
290 8f6a88f9 2024-12-12 | Removed the extra client app custom folder (#3101) | client_engine.py, client_executor.py | (c) [M+H] | Import-path hygiene. HEAD: parents do not mutate their own sys.path for jobs -- `add_custom_dir_to_path` only builds the child PYTHONPATH (job_launcher_utils.py:485-489) and `refresh_custom_dir_import_path` runs only in job processes (worker_process.py:62, runner_process.py:70); the parent-side removers `_remove_custom_path` (client_engine.py:51-55) and `ServerEngine.remove_custom_path` (server_engine.py:340-344) are uncalled (grep). No cross-job residue found.
291 c3f4863a 2024-12-12 | Add storage capability for client logs ... LogSender/LogReceiver (#3077) | job_def_manager.py | (c) [M] |
292 6d9d7756 2025-01-02 | dictConfig, log structure, formatters, and filters (#3126) | worker_process.py, runner_process.py | (c) [M] |
293 939735a3 2025-01-07 | Add the fed event runner to the SP and CP (#3129) | client_engine.py | (c) [M] |
294 6d00416a 2025-01-08 | update the client send_aux_request logging (#3136) | client_engine.py | (c) [M] |
295 895cffae 2025-01-14 | Support connection security and message authentication (#3135) | job_launcher_spec.py, client/server_process_launcher.py, worker_process.py, runner_process.py, client_app_runner.py, client_engine.py, client_executor.py, fed_client_base.py, fed_server.py, server_engine.py | (c) [M+H] | Security/transport; "Refactored job process arg computation" -> engines precompute JOB_PROCESS_ARGS into fl_ctx for any launcher (client_executor.py:268-298, server_engine.py:256-316). No lifecycle semantics change evident.
296 1be401cd 2025-01-15 | Dynamic logging with admin commands (#3127) | admin_commands.py, client_engine.py, client_executor.py, client training_cmds.py, job_cmds.py, server_engine.py | (c) [M] | configure_job_log (uses `send_command_to_child_runner_process`, which holds engine.lock -- see L8).
297 503b9683 2025-01-16 | Add commands to list and retrieve additional components (#3114) | job_def_manager.py, job_cmds.py | (c) [M] |
298 de829cee 2025-02-04 | Support relay - Part 1 (#3198) | job_launcher_spec.py, worker_process.py, runner_process.py, client_executor.py, fed_client_base.py, fed_server.py | (c) [M] | cellnet relays.
299 99c91c8a 2025-02-19 | Support client hierarchy (#3234) | client_app_runner.py, client_engine.py, client_run_manager.py, fed_client_base.py, fed_server.py, server_engine.py | (c) [M] | hierarchy/edge; also unified peer-FL-context keys (mis-keyed set/get), not lifecycle.
300 f528d0da 2025-02-20 | Add predefined log modes (#3221) | admin_commands.py | (c) [M] |
