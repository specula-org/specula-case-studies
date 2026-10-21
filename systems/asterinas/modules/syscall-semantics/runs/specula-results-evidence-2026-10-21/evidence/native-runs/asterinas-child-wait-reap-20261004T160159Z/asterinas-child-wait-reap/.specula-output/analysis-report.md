# Code analysis: child exit observation and unique reap

## Result and evidence boundary

Static analysis supports modeling the selected normal-child protocol. No new in-scope concurrent defect is established. The children mutex serializes consuming selection, WNOWAIT retains a nonconsuming Process reference, zombie Release/Acquire publishes the exit code, and the registration/recheck/token/runqueue chain supplies a source-level argument against the investigated lost-wakeup windows. These conclusions are source arguments awaiting model checking and runtime evidence.

**WR-SQ remains a supplied SOURCE LEAD, with runtime NOT_RUN.** Asterinas returns from waitid's no-event WNOHANG branch without writing siginfo. The pinned Linux source writes zeroed result fields. This is neither a novelty claim nor an assigned AST finding. **WR-CF is an oracle calibration, also NOT_RUN.** Both implementations can consume before a later copyout fault. Neither item replaces the concurrency campaign.

This worker performed only Code Analysis. It did not generate a model, invoke TLC, build a kernel, boot a guest, run a Linux control, instrument code, reproduce a defect, classify a confirmed defect, or repair source. The intended next handoff is [modeling-brief.md](modeling-brief.md). An empty new-concurrent-defect list does not cancel Spec Generation or the selected protocol's verification.

## Input identity and authority

| Input | Identity or location |
| --- | --- |
| Asterinas repository | `/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source` |
| HEAD | `0c60537098f4c2949ad2d382aaf499de72263d76` |
| Tree | `4693fdec88cd7da14bed4f1541eba593f123059c` |
| Local Git coverage | Non-shallow history. The only local ref is `memfd-preparation` at the target HEAD. There are no configured remotes. Rename-follow history includes earlier `kernel/src`, framework, and `services/libs/jinux-std` paths. |
| Source state | No tracked diff at intake. An existing untracked `.codex/` directory was left alone. All analysis artifacts are in the requested output directory. |
| Linux source oracle | v6.16.5, declared commit `4645fefac0b24d509b962c096b0327e87f34b1d2`. Selected archived files reside in `/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/linux-v6.16.5`. |
| Source integrity | All 23 Asterinas hashes and all six Linux hashes listed in the supplied contracts match. [source-hashes.json](analysis-evidence/source-hashes.json) records the 29 comparisons. The Linux archive has no Git history and is not a running control. |
| Required source contracts | [contracts.md](/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/wait-reap/contracts.md) |
| Shared resource and review policy | [resources.json](/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/resources.json) |
| Phase methodology | Installed Specula 1.2.0 `code_analysis/SKILL.md`, its complete `guide.md`, shared deep-analysis, concurrent-analysis, bug-archaeology, modeling-brief-format, complete reference example, and persistent-findings instructions. |

The primary worker and two read-only helpers (`/root/wait_ownership`, `/root/wait_notifications`) used the assigned analysis allocation. No additional agents or heavy stages were launched and no controller-held lock was reacquired. Source inspection, history, and GitHub reading were parallelized within the two-helper limit. GitHub requests were read-only. The external issue/PR snapshot was collected on 2026-10-05 Asia/Shanghai. Open-PR state is archaeology at retrieval time, not the state of the historical pinned source.

Abbreviated `process/`, `syscall/`, `time/`, and `sched/` paths below are relative to `kernel/core/src/`. Linux paths are relative to its reference root. [analysis-identity.json](analysis-evidence/analysis-identity.json) preserves source identities, guidance hashes, and the initial empty persistent lookup.

## Phase 1: Reconnaissance

### Category and fixture

This is **Category B (Concurrent / Lock-Free / Runtime)**. Its state machine transfers consuming authority over one exit event and carries nonconsuming references across synchronization boundaries. There is no network, replicated log, crash recovery, or Byzantine participant to model.

Use one established single-threaded child, a live parent with two waiting threads, an explicit positive child PID, fixed child credentials, normal exit, independent stable writable outputs, and null rusage. Both parent threads block SIGCHLD before any waits. Its disposition is SIG_DFL without SA_NOCLDWAIT. The ordinary kernel enqueue, signalled-waker notification, and children wake-all still occur. Fork and thread creation establish the fixture and are not protocol transitions.

The supported calls are wait4 with options 0 or WNOHANG and waitid with P_PID, WEXITED, and optional WNOWAIT/WNOHANG. x86-64 dispatch numbers are 61 and 247 (`syscall/arch/x86.rs:246,367`). Later execution must record the actual libc/header/binary identities and direct syscall argument/error conversion. No wrapper binary was examined in this phase.

### Structural map and full-file coverage

The team read all 17 principal files in full, totaling 5,227 physical lines including tests and excluded branches. Ownership/publication comprises nine files and 2,596 lines. Notification/scheduling comprises eight files and 2,631 lines. Supporting reads covered ProcessFilter, TermStatus, ABI fields, exit entry points, concrete ClassScheduler, group/session cleanup, existing regression tests, and the Linux reference paths. Supporting span reads are distinguished from full-file reads in the helper source manifests.

| Principal component | Files | Protocol role |
| --- | --- | --- |
| API projection | `syscall/wait4.rs`, `syscall/waitid.rs` | Parse supported calls, project the selected status, and perform output after selection. |
| Selection and ownership | `process/wait.rs`, `process/pid_table.rs`, `process/task_set.rs`, `process/process/mod.rs` | Serialize waitability, retain selected Process/main-task objects, and remove lookup membership. |
| Exit publication | `process/status.rs`, `process/exit.rs`, `process/posix_thread/exit.rs` | Store exit code, publish zombie, then notify the live parent. |
| Signal-aware wait | `process/signal/pause.rs`, `pending.rs`, `sig_queues.rs`, `process/posix_thread/mod.rs`, `time/wait.rs` | Register the signalled waker, enqueue before rechecks, and distinguish notification from interruption. |
| Wait and scheduling substrate | `ostd/src/sync/wait.rs`, `sync/mutex.rs`, `task/scheduler/mod.rs` | Maintain wake tokens, exclusion, and the park/unpark bridge. |

### Shared truth, local state, and linearization

| State or boundary | Exact source | Modeling consequence |
| --- | --- | --- |
| Exit-code storage and zombie publication are separate. | `process/posix_thread/exit.rs:63–89,120–122`; `process/status.rs:39–78`; `process/exit.rs:30–40` | Split the code store, zombie publish, and notification. A true Acquire zombie observation makes the prior code available. |
| Child membership is shared under one parent mutex. | `process/process/mod.rs:86–107,339–345`; `process/wait.rs:293–319` | Treat membership as the authority for fresh waits. Use one critical-section owner for both APIs. |
| Consumption occurs before return. | `process/wait.rs:310–319,339–374`; both syscall output paths | The map removal is the consuming ownership boundary. Copyout and return are separate later steps. |
| A selected result is local retained state. | `process/wait.rs:120–164,310–319`; `process/task_set.rs:46–75,141–144` | Keep selected identity and object lifetime after membership disappears. A reference is not another consumable event. |
| Signal registration precedes enqueue/recheck. | `process/signal/pause.rs:164–168,235–245` | Distinguish the first scan from registered rechecks and actual sleeping. |
| Queue removal is separate from wake delivery. | `ostd/src/sync/wait.rs:119–131` | The queue lock is released before `wake_up`. Preserve an in-flight popped waker if modeling that granularity. |
| A token is consumed before parking and checked inside parking. | `ostd/src/sync/wait.rs:262–281`; `ostd/src/task/scheduler/mod.rs:453–485` | A wake before physical sleep remains observable. Scheduler spurious returns do not satisfy the condition by themselves. |

No resize, pointer reuse, allocator-failure, or reclamation grace-period mechanism is required here. The lifetime distinction that matters is discoverability versus a live retained Arc. Allocation and Arc memory safety remain substrate assumptions, while the presence of the retaining reference is explicit protocol state.

## Phase 2: Bug archaeology

### Search and coverage statistics

Git mining followed each principal file across renames from HEAD and inspected full commit messages with `fix|bug|race|panic|deadlock|correctness|crash|corrupt|leak|inconsistent|wrong|lost.?wake|sound|safety`. All 310 unique historical subjects were screened, including nonmatches so feature/refactor subjects could not hide functional fixes. All 54 keyword candidates received relevant-path diff review. The team additionally reviewed 49 distinct nonkeyword candidates, for **103 unique commits with detailed diff dispositions**. Of these, 59 are classified as semantic bug/compatibility fixes, mixed feature/fixes, or fix/revert revisions. This is a commit count, not a count of unique bugs. Cosmetic matches, regression introducers, and functional refactors remain recorded.

The ownership helper reviewed 65 commits and the notification helper reviewed 51. Their 13-commit overlap explains why the unique total is 103. A commit can be cosmetic in one file and a semantic regression in another: `9ca64c281e90` is an example. The path-specific assessments are retained rather than collapsed into a misleading single label. Every reviewed OID is an ancestor of the target pin.

GitHub collection used `gh issue list --state all --limit 1000` for wait, waitid, wait4, WNOWAIT, zombie, reap, SIGCHLD, wakeup, race, deadlock, and the C-bug label. None reached the limit. Query counts were 151, 9, 10, 0, 8, 6, 10, 17, 58, 37, and 313 respectively, yielding **468 unique collected issues**. The two helpers deeply read **42 issue bodies and all 116 comments**, with comment counts checked against API metadata. Retrieval used `gh issue view --comments` plus paginated API bodies/comments because the local CLI comments view omitted the issue body.

| Discussion classification | Number | Meaning |
| --- | ---: | --- |
| Confirmed bug reports | 27 | Reported behavior has reproduction or maintainer confirmation. These are historical/upstream reports, sometimes sharing one cause, not 27 present campaign defects. |
| Design defects or acknowledged feature limitations | 7 | Separate from confirmed implementation bugs. |
| Disputed/false or retracted claims | 4 | #1261, #1497, #1603, and #3178 were excluded with discussion evidence. |
| Uncertain reports | 2 | #1264 and #2851 do not establish a child-wait mechanism. |
| Non-bug questions | 2 | #298 and #1839 are retained as context, not counted as false positives. |
| User error | 0 | No separately assigned user-error classification. |

The other 426 collected issues were collection/scope-screening material and are not claimed as deeply read. The 42 selected threads cover the direct wait/PID reports, concrete hangs named in exact-interface searches, and shared ownership/notification primitives. Independent VM, filesystem, network, and hardware reports do not expand the campaign.

In addition, **21 associated closed PR discussions** were fully read, including all issue comments, review bodies, and inline review comments. The ownership set is #532, #1215, #1433, #1468, #1861, #2000, #2180, #2196, #2503, #3121, #1598, #1996, and #2166. The notification set is #828, #1279, #1930, #1790, #1577, #1637, #2223, and #2237. Closed-unmerged #532 is explicitly distinguished from merged fixes.

All **108 open PRs** were screened by body and changed paths. Broad full-text matching produced 61 candidates, two additional adjacent PRs were included, and manual reading of the remaining bodies promoted four more, for 67 candidate/adjacent scope reviews. **45 complete discussions** were read, comprising all **41 identified fix or mixed fix/feature PRs** and four additional contextual threads. Feature-only unrelated PRs are marked scope-screened rather than deeply read. [coverage.json](analysis-evidence/coverage.json) and [open-pr-review-manifest.json](analysis-evidence/open-pr-review-manifest.json) preserve the counts and per-PR dispositions. This review found no open PR that resolves WR-SQ or establishes a new defect in the selected normal-child protocol.

Durable coverage evidence is in [history-inventory.json](analysis-evidence/history-inventory.json), [history-by-file.json](analysis-evidence/history-by-file.json), [issue-searches.json](analysis-evidence/issue-searches.json), [issues-collected.json](analysis-evidence/issues-collected.json), and [open-pr-heads.json](analysis-evidence/open-pr-heads.json). Full per-commit and per-issue dispositions are in the [ownership history audit](analysis-evidence/ownership/history-audit.md), [notification history audit](analysis-evidence/notifications/history-audit.md), [ownership issue audit](analysis-evidence/ownership/issue-audit.md), and [notification issue audit](analysis-evidence/notifications/issue-audit.md).

### History hotspots

These counts describe overlapping file histories, not independent bug totals. Full-message keyword hits include cosmetic and feature matches.

| Principal path | Historical commits | Keyword candidates |
| --- | ---: | ---: |
| `process/process/mod.rs` | 97 | 9 |
| `process/posix_thread/mod.rs` | 94 | 13 |
| `ostd/src/sync/wait.rs` | 53 | 10 |
| `process/wait.rs` | 51 | 6 |
| `process/exit.rs` | 48 | 4 |
| `process/posix_thread/exit.rs` | 41 | 8 |
| `syscall/wait4.rs` | 40 | 3 |
| `process/pid_table.rs` | 37 | 5 |
| `syscall/waitid.rs` | 35 | 4 |
| `ostd/src/sync/mutex.rs` | 27 | 8 |
| `process/signal/pause.rs` | 26 | 8 |
| `ostd/src/task/scheduler/mod.rs` | 25 | 3 |
| `process/status.rs` | 24 | 4 |
| `process/signal/sig_queues.rs` | 23 | 0 |
| `time/wait.rs` | 15 | 3 |
| `process/task_set.rs` | 10 | 2 |
| `process/signal/pending.rs` | 6 | 0 |

### Mechanism groups and historical disposition

| Mechanism | Historical evidence and cause | Current disposition and modeling value |
| --- | --- | --- |
| Selection/removal atomicity | `95faea0fb04c8f7cb3111f0c6f25a17fe1bfdd4f`, [PR #2166](https://github.com/asterinas/asterinas/pull/2166), moves from a detached snapshot to one children critical section. Previously two callers could select before a later destructive remove. Historical impact: high, including duplicate selection followed by panic. | Fixed at pin. Scenario 1 models the present cross-API protocol. No lock-drop adversary or pre-fix replay. |
| Mutex exclusion | `3790efb0d9c8`, `458a6a5b3b01`, [#1274](https://github.com/asterinas/asterinas/issues/1274), [PR #1279](https://github.com/asterinas/asterinas/pull/1279) fix eager `then_some` guard construction that unlocks on a failed acquisition. Historical impact: critical. | Current `mutex.rs:40–45` uses lazy construction. Treat exclusion as justified substrate, not an open duplicate-reap finding. |
| Publication and retained lifetime | `35c20620bc93` separates last-thread exit from process publication and retains the main task. `25c4f0f2bcaa` introduces TermStatus encoding. `092d91450447` moves zombie publication after reparent work to prevent an early reap invalidating an ancestor reference. | All present or superseded by current code. Scenarios 2 and 4 preserve actual lifetime and ordering. Parent exit, reparenting, and multithreaded-child triggers remain excluded. |
| Queue/token ordering and check-before-sleep | `98bb9c52566c`, `485120405939`, `414a3a389e2e` fix discarded wakes, waiter ownership, and cross-variable ordering. [#831](https://github.com/asterinas/asterinas/issues/831) explains the empty fast-path bridge. Historical impact: high. | Fixed at pin. [#1261](https://github.com/asterinas/asterinas/issues/1261) and [#1497](https://github.com/asterinas/asterinas/issues/1497) explicitly withdraw suspicions that ignored the compensations. Scenario 3 retains them. |
| Blocked/ignored signal handling | `00c79732e62f`, [#2252](https://github.com/asterinas/asterinas/issues/2252), [PR #2503](https://github.com/asterinas/asterinas/pull/2503) restore process-wide queued signals and unconditional signalled-waker notification. PR discussion explains why a sigmask-gated wake introduces a cross-variable hole. | Present at pin. Blocking SIGCHLD excludes handler variability and interruption, not the kernel notification path. Never suppress this path in the model. |
| Scheduler handoff | [#1471](https://github.com/asterinas/asterinas/issues/1471), [#1633](https://github.com/asterinas/asterinas/issues/1633), and [PR #1930](https://github.com/asterinas/asterinas/pull/1930) distinguish duplicate task execution from decision/context-switch non-atomicity. | The soundness fix is historical. The remaining scheduler boundary is explicit at `ostd/src/task/scheduler/mod.rs:597–599`. Model the checked park bridge and state execution-progress assumptions. |
| ABI/result projection | `ef0382b164b2` changes waitid from PID return/no siginfo to siginfo plus zero return, but its no-event early return remains. `ef9e600c9d0f` and `ec7391468cf8` fix invalid selector/options panics. | WR-SQ has a source-history origin. Valid supported options exclude the old panic triggers. No novelty inference follows from the issue searches. |
| Misattributed hangs | [#1607](https://github.com/asterinas/asterinas/issues/1607) and [#1595](https://github.com/asterinas/asterinas/issues/1595) were resolved by [PR #1637](https://github.com/asterinas/asterinas/pull/1637), which clears the Direction Flag on trap entry. [#1975](https://github.com/asterinas/asterinas/issues/1975) / [PR #1996](https://github.com/asterinas/asterinas/pull/1996) concern zombie-init reaper livelock. | Neither a wait4 stack frame nor timing sensitivity establishes a current child-queue lost wake. These independent triggers are excluded. |
| Queue residue and resource growth | [#3283](https://github.com/asterinas/asterinas/issues/3283) reports stale entries under repeated flock/fcntl signal restarts. Growth is acknowledged, but actual u32-wrap-induced lost wake is not demonstrated. | The bounded no-restart/no-exhaustion fixture does not reproduce that mechanism. Closed/duplicate entries remain relevant to finite queue semantics, without a counter-wrap adversary. |

Historical fixes are evidence of mechanism risk. They are not propagated into model-checkable defect candidates, weakened-order actions, or configurations that merely recreate a closed issue. The report keeps the present contract-verification task separate from the historical bug inventory.

### Open PRs relevant to interpretation

[PR #3576](https://github.com/asterinas/asterinas/pull/3576) changes restart-error propagation in wait4/waitid and Pause. Its waitid no-event branch remains unchanged. [PR #3770](https://github.com/asterinas/asterinas/pull/3770) introduces cyclic PID allocation, outside the fixed-incarnation fixture. [PR #3820](https://github.com/asterinas/asterinas/pull/3820) addresses signalfd sender PID, not waitid's independently constructed result. [PR #3469](https://github.com/asterinas/asterinas/pull/3469) changes clone-family ptrace stops, which are excluded. All four discussions were fully read.

The proposed atomic-guard change in [PR #3954](https://github.com/asterinas/asterinas/pull/3954) concerns guard references used on another CPU. This fixture does not perform that transfer. The model assumes the inspected locking APIs are used with their current CPU-local contract. The cgroup policy change in [PR #3364](https://github.com/asterinas/asterinas/pull/3364) is not substituted for the pinned scheduler. [PR #3685](https://github.com/asterinas/asterinas/pull/3685) changes the OSDK test scheduler and does not establish an SMP runtime result for this campaign.

The [primary PR audit](analysis-evidence/open-pr-root-audit.md) distinguishes these conclusions from PR authors' unverified runtime claims. Helper PR audits retain independent filesystem, networking, VM, tooling, and feature exclusions.

## Phase 3: Deep source analysis

### Exit-code publication and notification

Normal exit first converts the exit value to `TermStatus::Exited(u8)` (`syscall/exit.rs:18–19`; `exit_group.rs:19–20`) and encodes it as a wait status (`process/term_status.rs:11–18`). In `exit_internal`, the single task stores the process code under the task-set lock, stores its own code, marks itself exited, and remains as the main task (`process/posix_thread/exit.rs:63–89`; `task_set.rs:56–75`). The single-thread fixture makes this the final exiting task.

Cleanup precedes `exit_process` and zombie publication (`process/posix_thread/exit.rs:105–122`; `process/exit.rs:18–36`). The relevant visibility chain is:

`set_exit_code(Relaxed)` → `set_zombie(Release)` → `is_zombie(Acquire) == true` → later `exit_code(Relaxed)`.

The code is immutable after this publication in the selected fixture. Consequently, arbitrarily choosing an old exit code after a true zombie acquisition would model an implementation that is not present. This argument relies on the actual Rust atomic/lock semantics. No compiler lowering, machine-level litmus, or full weak-memory verification was executed.

Zombie publication occurs before PID-file notification and child-death notification (`process/exit.rs:36–40`). PID-file observers are outside the fixture. `send_child_death_signal` obtains the live parent, enqueues the normal exit signal, and then calls `children_wait_queue().wake_all()` (`177–186`). A competing reap can occur before this notifier finishes. The retained exiting process and live parent permit the notifier to continue after child membership disappears. A model that cancels notification at reap would introduce a nonexistent transition.

### Consuming selection and identity lifetime

Both interfaces reach the same `do_wait`. The tracee path returns no match because the fixture has no tracees (`process/wait.rs:68–79,188–194`). `try_wait_children` holds the parent's children mutex while filtering the fixed PID, reading zombie state, cloning the Process Arc, and optionally reaping (`293–319`). Another waiter cannot concurrently pass a scan based on the same pre-removal entry. Child exit publication itself does not require this parent mutex and can still interleave with a scan.

`reap_zombie_child` removes membership at line 344, checks zombie state, then detaches PID and group/session membership and accumulates child CPU-time accounting before releasing the children guard (`339–374`). PID removal clears both process and main-thread weak slots (`process/pid_table.rs:148–166`). It does not erase the main task in the Process TaskSet or clear the zombie flag. The returned `WaitStatus::Zombie(Arc<Process>)` keeps the object available for PID/code/UID output (`process/wait.rs:120–164`; `process/process/mod.rs:321–323`).

The selected wait4 path reads PID and code after `do_wait`, writes the optional status word, and returns the PID (`syscall/wait4.rs:36–60,63–65`). waitid independently reads code, PID, and the retained main thread's real UID, builds siginfo, copies it, and returns zero (`syscall/waitid.rs:43–90`). With a valid stable output buffer these operations should complete under execution progress. Removing lookup membership is not equivalent to destroying the selected object.

WNOWAIT takes the same protected selection but skips reap. Two observations can return the same exit, and one later consumer still owns the sole removal. If an observer selected before removal, it may finish output after the consumer's syscall return. A fresh scan after removal returns no match, and `do_wait` turns that into ECHILD before considering WNOHANG (`process/wait.rs:75–89`). The oracle must track invocation, selection, claim, output, and completion separately.

### Scan, registration, recheck, and both wake channels

`Pause for WaitQueue` first evaluates the condition. If it is unresolved, it creates a waiter and wraps subsequent condition checks with enqueue (`process/signal/pause.rs:235–245`). `Pause for Waiter` registers the signalled waker before entering the untimed wait loop (`164–168`). `time/wait.rs:170–218` does not allocate a timer when timeout is None. The wait loop checks the condition before cancellation and then calls `wait` (`ostd/src/sync/wait.rs:218–230`). Cancellation's close/recheck exists, but arbitrary interrupting signals are excluded here.

Normal SIGCHLD does not cause EINTR in this fixture. `do_wait` temporarily adds SIGCHLD to the mask (`process/wait.rs:64–66`), and the fixture already blocks it in all threads. `has_pending_signal` passes that mask to the queues (`process/signal/pending.rs:131–146`), whose blocked-signal branch returns false before ignored-signal handling (`sig_queues.rs:208–249`). Separately, `Process::enqueue_signal` always invokes each registered signalled waker after enqueue (`process/process/mod.rs:641–656`). `wake_signalled_waker` holds its own spinlock and does not filter by signal mask (`posix_thread/mod.rs:177–185,249–253`). Signal coalescing therefore does not suppress this notification loop.

The children queue has an actual ordering bridge. Enqueue increments `num_wakers` with Acquire after pushing under the queue lock. The wake empty check is a Release RMW, not an ordinary stale Boolean load (`ostd/src/sync/wait.rs:136–149`). If notification's zero RMW precedes a later registration in modification order, the acquiring registration carries the producer's earlier condition publication into the subsequent recheck. If registration precedes the nonempty check, queue locking and draining deliver a wake. Intermediate queue pops use Release RMWs. A finite model may abstract these semantics with justified ordering edges, but must not make queue presence and condition visibility arbitrarily inconsistent.

`wake_up` publishes a token with Release before `unpark_target`. `do_wait` consumes it with Acquire and rechecks it inside `park_current` (`ostd/src/sync/wait.rs:262–275`). Closing the waiter also uses Acquire and suppresses subsequent wake attempts that observe the closed token (`244–281`). An unpark already in flight may still cause a spurious scheduler wake, which the token loop tolerates. Queue residue and duplicate notifications are not extra exit statuses.

### Concrete park/unpark bridge and execution assumption

The kernel injects ClassScheduler (`sched/sched_class/mod.rs:47–56`). Its `enqueue` tries to assign an unqueued task to a CPU, acquires the target runqueue lock, and retries assignment if the task initially appeared already queued (`219–250`). `mut_local_rq_with` uses the same runqueue lock (`255–258`). `dequeue_current` clears CPU membership while holding it (`410–414`).

`park_current` checks the token and dequeues inside that lock (`ostd/src/task/scheduler/mod.rs:453–470`, invoked through `reschedule` at `575–579`). A wake between this check and dequeue waits on the same runqueue lock and retries after CPU membership is cleared. A wake before the park lock is acquired is reflected by the token/lock synchronization. A wake after dequeue can assign and enqueue the task. This checks the implementation behind the explanatory comment, not only the comment itself.

This bridge does not prove unconditional scheduling progress. The source explicitly retains a decision/context-switch limitation (`ostd/src/task/scheduler/mod.rs:594–600`). Completion assumptions include eventual execution of the exiting notifier, waiter continuations, and lock holders, completion of pending unpark work, bounded client activity, and successful stable-buffer output. No FIFO waiter order, immediate preemption, spontaneous periodic wake, or untimed timeout is promised.

### Candidate schedules and dispositions

| Window or candidate history | Evidence-based disposition |
| --- | --- |
| Exit after the first failed scan, before signal registration or children enqueue. | A subsequent enqueue-before-recheck observes the available zombie or completed removal. Missing an earlier notification is allowed because this path has not committed to sleep. |
| Exit after signal registration but before children enqueue. | Normal signal can leave a token, and the registered condition still rechecks after queue enqueue. Neither mechanism may be deleted. |
| Exit after enqueue, before/after the recheck. | An early notification is retained by the token. If the scan sees the terminal condition, the call completes directly. Otherwise wake/park synchronization leads to another scan. |
| Wake after token consumption check, before physical dequeue. | The token test inside `park_current` and concrete runqueue lock/retry close the bridge described above. |
| Both consumers asleep, one claims before exit notifier finishes. | Signal wake and/or children wake-all still reach registered waiters. The losing waiter rechecks the now-absent child and completes ECHILD. Reap needs no new independent exit event. |
| Repeated WNOWAIT calls, followed by one consuming wait. | Each observation preserves membership. Only the consuming branch removes it. |
| Old observer returns after a consuming syscall. | Legal if its protected selection happened earlier. Retained Arc and main-task lifetime preserve output identity. |
| New wait starts after a consuming syscall completed. | No matching map entry exists, so ECHILD. PID-table lookup or a previously retained result cannot recreate waitability. |

These are source-derived dispositions, not executed schedules. They become the five Scenarios in the brief and the staged WR cases below.

### Reference comparison and API oracles

| Contract | Asterinas | Linux source comparison |
| --- | --- | --- |
| Exit publication precedes reporting. | Relaxed code then Release zombie, acquired by the waiter. | `kernel/exit.c:939,976` stores code before `exit_notify`; `741–778` publishes zombie under tasklist write locking. Preserve each implementation's actual synchronization rather than copying Linux lock names into the Asterinas model. |
| One consumer claims a normal zombie. | Children mutex serializes scan and map removal. | `kernel/exit.c:1181–1191` uses cmpxchg EXIT_ZOMBIE to EXIT_DEAD. |
| WNOWAIT retains status availability. | Arc clone without removal. | `kernel/exit.c:1170–1179` retains a task and copies status without the consuming transition. |
| Blocking wait registers and rechecks. | First scan, waiter setup, enqueue/recheck, retained token and park bridge. | `kernel/exit.c:1697–1719` adds a nonexclusive wait entry before scans and removes it on return. Callback and parent wake are at `1580–1607`. |
| SIGCHLD disposition in fixture. | Normal enqueue and all signalled-waker notifications remain. | `kernel/signal.c:2230–2261` treats explicit SIG_IGN and SA_NOCLDWAIT as autoreap cases. SIG_DFL is distinct. Both excluded settings would change the contract. |
| wait4 success/no event. | PID plus encoded status on an event. Zero without status write on no event. | `kernel/exit.c:1841–1873` adds WEXITED internally and writes status only for a positive wait result. |
| waitid event. | Return zero, SIGCHLD, CLD_EXITED, selected PID/UID, unshifted exit value. | `kernel/exit.c:1269–1283,1800–1827` projects the same selected normal-exit fields. |
| waitid no event. | Return zero without touching siginfo (`syscall/waitid.rs:49–51`). | `kernel/exit.c:1804–1825` initializes result state and writes zero to the selected fields. This is WR-SQ. |
| Wait after consume. | No child gives ECHILD. | `kernel/exit.c:1650–1694` returns ECHILD when there is no eligible task. Error-path output is not decoded as an exit event. |
| Consuming output fault. | Selection/reap precedes user write. | `kernel/exit.c:1186,1266–1267,1820–1830,1870–1871` also permits ownership to be consumed before EFAULT. |

The Linux waitqueue comparison also inspected `kernel/sched/wait.c:17–25,73–108,167–174` and `include/linux/wait.h:95–123`. Linux's queue-locking/lockless-presence ordering commentary is reference context. It is not proof that Asterinas uses the same barriers. The relevant UAPI flags and siginfo fields were checked in `include/uapi/linux/wait.h` and `include/uapi/asm-generic/siginfo.h` against the selected call matrix.

### WR-SQ history match and calibration details

The lightweight persistent lookup used the configured output directory and queries for waitid, WNOHANG, siginfo, WNOWAIT/reap/zombie, and exit publication. It returned no records. `persistent-findings-context.json` has no previous run or inherited findings. The supplied preparation already performed limited local catalog screening. None of these observations proves novelty, and no registry record or shared AST ID was created.

The complete source path for WR-SQ is `sys_waitid` → `do_wait` → eligible live child → WNOHANG `Ok(None)` → early zero return. Valid output is never accessed on that branch. The historical `ef0382b164b2` waitid implementation supplies origin context, not evidence of runtime impact. The future control must initialize relevant siginfo fields to poison, call the direct syscall on a live child, record return/errno and before/after fields, and repeat on an independently identified Linux control. A prezeroed main fixture can correctly distinguish no event while concealing WR-SQ, so its success cannot close this lead.

For wait4, only a positive return permits WIFEXITED/WEXITSTATUS decoding. For waitid, return zero alone is insufficient. Record si_signo, si_errno, si_code, si_pid, si_uid, and si_status, and treat nonzero selected PID with the expected event fields as delivery. Padding or unrelated siginfo union bytes are not an equality oracle. An error is interpreted through return/errno, without claiming that output represents a status. Linux may also write fields on error paths, so do not silently broaden WR-SQ into an unreviewed universal error-output contract.

WR-CF uses an established zombie and a separately inaccessible output page. Each consuming interface can return EFAULT and leave ECHILD for the next valid call. WNOWAIT should preserve waitability despite its output fault. Both predictions need runtime control. Faulting output is excluded from the primary model and does not justify a rollback invariant.

### False positives, unsupported conclusions, and scope exclusions

| Candidate interpretation | Disposition and reason |
| --- | --- |
| Two wakes or two waitid return-zero results mean two consumed statuses. | Rejected. Both notification paths can fire and WNOWAIT is nonconsuming. Count protected consuming claims, not wakes or raw success returns. |
| Any late observer output is a post-reap status recovery. | Rejected. Prior selection plus retained Arc permits it. A fresh post-removal selection is the forbidden case. |
| Map/PID removal destroys UID/status before copyout. | Rejected. The selected Process Arc and retained main task survive. Process group membership is not used for the selected output. |
| Relaxed exit-code access permits arbitrary stale output. | Rejected within the fixture because true zombie observation acquires the preceding publication. |
| SIGCHLD blocked or default-ignored means no kernel wake. | Rejected by unconditional `wake_signalled_waker` after enqueue. Blocked signals only avoid the selected cancellation condition. |
| WEXITED's warning means the valid waitid operation is unsupported. | Rejected. `WaitOptions::check` logs and returns Ok (`process/wait.rs:35–47`), and the actual zombie branch implements this case. |
| A consuming EFAULT must restore membership. | Rejected as an oracle. The pinned Linux source also consumes before copyout. Runtime calibration remains pending. |
| A nullable parent children map or missing main task makes this normal path panic. | No reachable selected trigger found. A live parent retains its children map, and single-thread child exit retains its main task. Parent exit/exec mechanisms are excluded. |
| Open stale-waker growth proves a two-waiter child-queue lost wake. | Excluded as a different trigger. No arbitrary restart storm, resource exhaustion, or wraparound is in this fixture. Finite residue is modeled without asserting a leak defect. |
| A sleep-based timeout or wait4 stack proves lost wakeup. | Unsupported. The historical DF fix and scheduling-latency reports show why internal schedule evidence is required. No runtime case was executed here. |
| Earlier procfs leaks make intentional WNOWAIT retention a bug. | Rejected. Temporary selected references are required for output. Unreleased unrelated references and general resource reclamation remain independent scopes. |
| A ptrace duplicate-exit defense identifies an ordinary-child defect. | Excluded. The traced branch has a distinct reporting/ownership protocol, and no tracee exists in this fixture. |

Developer signals were examined rather than treated as automatic findings. waitid's rusage FIXME and CLD_DUMPED TODO (`syscall/waitid.rs:28,86`) concern excluded rusage/signalled-exit cases. Parent-death signal FIXMEs (`process/exit.rs:162–172`) concern excluded parent exit. The scheduler FIXME is retained as an execution boundary. PID-entry cache reclamation TODOs concern unrelated lookup-cache lifetime. The broad wait-options warning is accounted for by the supported call subset.

## Phase 4: Modeling handoff and planned evidence

The brief groups the work by mechanism: consuming ownership, retained observation, notification/parking, exit-code publication, and API-specific outcomes. It carries Category B, the exact fixture, source boundaries, proposed state/action splits, safety and liveness properties, and verification-method classification. There are no invented model-checkable defect candidates. The normal protocol remains the modeling target, and WR-SQ remains a separate test-verifiable lead.

| Priority question | Disposition | Required later evidence |
| --- | --- | --- |
| 1. Unique consuming reap and no fresh recovery. | Source-supported by one children critical section shared by wait4 and waitid. | Check UniqueConsume/NoFreshSelectionAfterRemoval and execute WR-02/03/06/07 with claim order visible. |
| 2. Repeated WNOWAIT and overlap. | Source-supported. Availability survives observations. A selected Arc may outlive removal. | Check ObservationPreservesAvailability/RetainedSelectionValid and execute WR-04/05/08 with separate selection, removal, output, and completion. |
| 3. No stranded blocking wait, including losing consumer. | Source-supported under explicit execution assumptions, with both notifications and the concrete scheduler bridge preserved. | Check completion properties and execute WR-09/10 with internal registration/recheck/token/park evidence and actual SMP >= 2. |
| 4. Published identity and normal exit code. | Source-supported through Release/Acquire and retained main-task identity. | Check PublishedStatusAgreement. Use 0, 37, and 255, both APIs, and record the immutable child identity. |
| 5. WNOHANG and post-reap API results. | wait4/no-child behavior is source-supported. waitid's no-event fields retain WR-SQ. | Execute WR-01, post-reap calls, poisoned-output WR-SQ, and separate WR-CF. Do not decode output on error as delivery. |

### Planned controls retained from preparation

All rows remain **NOT_RUN on both Linux and Asterinas**. The preparation case names are preserved so later phases can report coverage without renaming or silently dropping them.

| Case | Required schedule or control | Oracle |
| --- | --- | --- |
| WR-01 | Live child, wait4 WNOHANG with sentinel status. | Zero return, unchanged status, later consumable exit. |
| WR-02 | Consume through wait4 for exit values 0, 37, 255. | Explicit PID and encoded normal status, then ECHILD through either interface. |
| WR-03 | Consume through waitid WEXITED. | Zero return with correct event fields, then ECHILD. |
| WR-04 | Two WNOWAIT observations, then wait4 consume. | Identical observations preserve one later consumable status. |
| WR-05 | Two WNOWAIT observations, then waitid consume. | Same availability guarantee with waitid consumer. |
| WR-06 | Competing wait4 consumers before exit and with an existing zombie. | One consumer, second blocking completion ECHILD, with lock/claim order captured. |
| WR-07 | Competing waitid consumers and mixed wait4/waitid consumers. | API choice does not duplicate the event. Compare decoded outcomes, not raw return equality. |
| WR-08 | Observer selects before competing removal but completes output later. Also scan after removal. | Accept retained late output, reject fresh recovery. |
| WR-09 | Exit after failed first scan and before registration/recheck. | Recheck observes terminal state or removal. No demonstrated lost wake without the internal schedule. |
| WR-10 | Exit after registration, before and after park, with two registered consumers. | Retained token or scheduler enqueue leads to recheck and eventual status/ECHILD completion. Capture both wake paths. |
| WR-SQ | Live child, waitid WNOHANG with zeroed and poisoned valid siginfo. | Linux source predicts zeroed selected fields, Asterinas predicts unchanged fields. Preserve any reproduced difference independently. |
| WR-CF | Established zombie, inaccessible output, consuming wait4/waitid and WNOWAIT. | Calibrate EFAULT and next valid wait. Consuming fault may have consumed, observation fault should not. |

Use fresh child incarnations per case, a bounded readiness/exit handshake, independent outputs, direct syscall records, libc/error decoding, exact executable/kernel identities, and actual CPU counts. Instrumentation must capture ordering without creating the lock or memory-order edge under test. In particular, do not block while holding a protocol lock merely to force an interleaving. A watchdog or an end-to-end hang without the required internal trace is an execution limit, not a proved lost wakeup.

### Stage and corrective review boundary

The controller owns stage invocation and resource admission. This analysis worker returns evidence and the brief rather than launching the next stage. No heavy-stage preflight, lock ownership, provider capacity, or guest readiness is claimed to have been independently admitted by this worker.

Before a verification rerun after a semantic change to the model/properties, trace interpretation, oracle assumptions, harness, or instrumentation, preserve the prior and proposed versions, diff, reason, triggering evidence, and exact hashes. Obtain independent review of that exact version, record reviewer identity/findings/dispositions, close material findings, and then rerun affected validation and renew review. This applies inside Phase 3 correction loops. If independent review is unavailable, return an incomplete correction request to the controller and continue this same campaign when the gate is closed. No verification rerun occurred during this analysis.

The final brief has SHA-256 `617152b69d965ae31c904d458561ffe9d2842ba959a4d9bf328fa00e7d45c93f`. Both independent helpers reviewed that exact version without material findings. The [ownership review](analysis-evidence/brief-review/final-review-ownership.md) and [notification review](analysis-evidence/brief-review/final-review-notifications.md) preserve reviewer identities and source-bound dispositions. The prior brief, proposed version, diff, and reason are retained in the same directory. The two report wording notes were applied: reap accumulates accounting, and an already in-flight unpark may be spurious after waiter closure. This is an analysis handoff review, not model acceptance or an executed verification result.

The raw history, discussions, source-read manifests, source hashes, and per-helper audits reside under [analysis-evidence](analysis-evidence). They distinguish static review, upstream reports, excluded claims, and future runtime work. None of the archived upstream test claims is promoted to a local Asterinas or Linux execution result.
