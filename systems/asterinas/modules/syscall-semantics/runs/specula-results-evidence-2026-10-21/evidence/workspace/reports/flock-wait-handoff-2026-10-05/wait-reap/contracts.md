# Child wait/reap source contracts

Use this document to prepare the native analysis of one normal child's exit publication, observation, and consuming reap. It records bounded source reading and planned controls. Every runtime case is **NOT_RUN**. It is not a completed Specula analysis, an approved model, or an Asterinas reproduction.

The target is Category B, a concurrent ownership and notification protocol. Two parent threads can observe or claim one child's exit status. The source supports a coherent campaign even if the later analysis finds no new model-checkable defect.

## Inputs and scope

The Asterinas input is commit `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`. The receiver's source root is `/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/source`. Initial reading used the clean, history-preserving copy prepared for the earlier futex run. The package coordinator preserves an independent copy at the receiver path and records its identity in [preparation.json](../preparation.json). The selected pin is a historical local snapshot, not a claim about current upstream main.

The Linux source oracle is v6.16.5, commit `4645fefac0b24d509b962c096b0327e87f34b1d2`. Its selected files are under `/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/linux-v6.16.5`. They come from an existing Git archive and have no Git history. They are neither a build tree nor a running Linux control. File hashes appear below.

Keep one already established, single-threaded child and its live parent. Use the child's explicit positive PID, two waiting threads in the parent, normal exit, stable writable output buffers, and a null rusage pointer. The primary operations are consuming `wait4(pid, ..., 0/WNOHANG, NULL)` and `waitid(P_PID, pid, ..., WEXITED | optional WNOWAIT/WNOHANG, NULL)`. Fork and parent thread creation establish the fixture. Their implementation is outside the protocol.

Use `SIG_DFL` for SIGCHLD with no `SA_NOCLDWAIT`, and block SIGCHLD in the parent before creating either waiter thread. Preserve the normal child exit signal, signal enqueue, signalled-waker notification, and children-queue wake path in source reasoning. Blocking the signal suppresses user-handler variability. It does not justify deleting kernel notifications. Explicit `SIG_IGN` is excluded because Linux treats it as an autoreap request.

Exclude ptrace, stop/continue reports, reparenting and subreapers, pidfd and PID reuse, exec, parent exit, non-SIGCHLD clone children, arbitrary signal/restart behavior, rusage correctness, resource exhaustion, and general fork/VM correctness. Keep credentials and the child incarnation fixed. Copyout faults have a separate oracle-calibration case and do not expand the primary model by default.

## Entry points and supported call matrix

Abbreviated source paths beginning with `process/` or `syscall/` in this document are relative to `kernel/core/src/` in the selected Asterinas tree. Linux paths are relative to its reference root.

Asterinas dispatches x86-64 syscall 61 to `sys_wait4` and 247 to `sys_waitid` in `kernel/core/src/syscall/arch/x86.rs:246,367`. Use these direct syscall entry points through the selected libc's `syscall` facility rather than relying on a `waitpid` wrapper. Before runtime work, record the libc, headers, binary, and actual error-conversion behavior used by the fixture. This preparation has not inspected a particular libc wrapper binary.

| Call | Fixed Asterinas source behavior | Pinned Linux source oracle and receiver rule |
| --- | --- | --- |
| `wait4(pid, status, 0, NULL)` | `syscall/wait4.rs:18–47` parses known bits, selects the positive PID, calls `do_wait`, and writes status only when a status was selected. | `kernel/exit.c:1841–1873` accepts the wait4 mask and adds WEXITED internally. Use options 0 for consuming blocking waits. |
| `wait4(pid, status, WNOHANG, NULL)` | `process/wait.rs:75–100` returns no result for an eligible live child. `syscall/wait4.rs:41–43` returns 0 without writing status. | Linux `__do_wait` returns 0 for an eligible but unready child at `kernel/exit.c:1689–1694`; wait4 does not copy status on that result. A sentinel status remains unchanged. |
| `waitid(P_PID, pid, info, WEXITED, NULL)` | `syscall/waitid.rs:29–47` requires an event-selection bit. The ordinary zombie branch consumes unless WNOWAIT is set. | `kernel/exit.c:1730–1745,1800–1827` accepts WEXITED and positive P_PID. Success returns 0 and identifies the child in siginfo. |
| Add WNOWAIT to waitid. | `process/wait.rs:310–319` clones the child Arc and skips `reap_zombie_child`. | `kernel/exit.c:1170–1179` preserves the waitable state. Repeated observations are allowed. Only a later consuming call removes availability. |
| Add WNOHANG to waitid. | An eligible live child produces return 0 at `syscall/waitid.rs:49–51` with no output write. | Linux initializes the result fields and copies zeros when no event is ready at `kernel/exit.c:1804–1825`. Preserve the lane-local **WR-SQ** discrepancy below. |
| Wait again after consumption. | An explicit PID absent from the parent's children map produces ECHILD at `process/wait.rs:75–85`. | `kernel/exit.c:1654–1694` produces ECHILD when there is no eligible child. A call begun after the consuming call completed cannot return that child again. |
| Flags outside this matrix. | `WaitOptions::check` warns about some known bits, including WEXITED, but returns `Ok(())` at `process/wait.rs:35–47`. The parser and actual branches determine behavior. | Linux wait4 excludes WNOWAIT and WEXITED in its caller-supplied mask. Use WNOWAIT only through waitid. Invalid flags and broader support differences are outside this campaign. |

For normal exit value `e`, Asterinas `TermStatus::Exited(e as u8)` encodes `(e & 255) << 8` in `process/term_status.rs:11–18` and `syscall/exit.rs:18–19`. Linux uses the same encoding in `kernel/exit.c:1070–1072,1114–1116`. Decode wait4 using `WIFEXITED` and `WEXITSTATUS` only after a positive return. Decode waitid using `si_signo`, `si_code`, `si_pid`, `si_uid`, and `si_status`, not the wait4 status macros. For this fixture, success identifies SIGCHLD, CLD_EXITED, the child PID, and the unshifted exit value. Asterinas builds these fields at `syscall/waitid.rs:53–66,72–90`; its x86-64 layout and setters are in `process/signal/c_types.rs:30–78`. Linux defines the fields in `include/uapi/asm-generic/siginfo.h:59–66,116–149`.

Each thread needs its own output area and return/errno record. A libc `syscall` return of -1 must be paired with errno. Do not decode output as a delivered status on an error or assume return 0 from waitid alone means an event was delivered. Record the relevant fields and the output bytes before and after each call. Padding and unrelated siginfo union bytes are not an equality oracle.

## Production chain and synchronization

Paths beginning with `kernel/` or `ostd/` are relative to the Asterinas source root. The abbreviated `process/` and `syscall/` paths follow the convention above. Preserve the actual source boundaries when deriving the later model and instrumentation.

| Boundary | Source anchor | Contract consequence |
| --- | --- | --- |
| Exit code is stored before zombie publication. | `kernel/core/src/process/posix_thread/exit.rs:63–89,120–122`; `process/status.rs:39–54,69–78`; `process/exit.rs:30–40`. | The last thread stores the exit code, completes the selected exit path, then stores zombie with Release. A waiter loads zombie with Acquire before reading the Relaxed exit code. This is an explicit visibility bridge, not a reason to permit arbitrary stale status values. |
| Waiters select under the parent's children mutex. | `kernel/core/src/process/wait.rs:284–319`; `process/process/mod.rs:86–107,339–345`; `ostd/src/sync/mutex.rs:35–69`. | The map scan, matching PID, zombie decision, Arc clone, and consuming removal share one critical section. The mutex acquires with Acquire and unlocks with Release. Two consumers must not both remove the same child. |
| Reap detaches discoverability but retains selected output identity. | `kernel/core/src/process/wait.rs:310–319,339–374`; `process/pid_table.rs:143–164`; `process/task_set.rs:46–75,141–144`. | Reap removes the children-map entry, PID process/thread entries, and group/session membership while the children lock is held. The returned `WaitStatus::Zombie(Arc<Process>)` keeps the selected object alive. The main task remains in the child's task set and provides the selected credentials. |
| User output follows selection and possible reap. | `kernel/core/src/syscall/wait4.rs:36–60`; `syscall/waitid.rs:43–69`; `process/wait.rs:120–164`; `process/process/mod.rs:321–323`. | A consuming operation may already have detached the child when copyout begins. A WNOWAIT observer that obtained its Arc before a competing removal can finish copyout later. Return order alone does not identify the claim order. |
| The first failed scan does not immediately park. | `kernel/core/src/process/signal/pause.rs:225–245`; `process/wait.rs:64–103`. | `Pause for WaitQueue` checks once, creates a waiter, then enqueues its waker before each later condition check. The second scan closes the exit-between-first-scan-and-registration window. |
| Registration, wake fast path, and wake token carry ordering. | `ostd/src/sync/wait.rs:110–149,209–231,244–281`. | Enqueue uses `num_wakers.fetch_add(1, Acquire)`. The wake empty check uses `fetch_add(0, Release)`, queue removal uses Release, and the wake token pairs Release with Acquire. Preserve these bridges and the recheck. Do not replace them with independent unconstrained boolean observations. |
| Wake before actual parking remains observable. | `ostd/src/sync/wait.rs:262–275`; `ostd/src/task/scheduler/mod.rs:441–494`. | `do_wait` consumes the token before parking and tests it again inside `park_current`. The scheduler documents its local runqueue locking bridge for an enqueue/dequeue overlap. Spurious scheduler returns are handled by the retry loop. Scheduling completion still requires an explicit execution assumption. |
| Signal and children notifications can both wake a waiter. | `kernel/core/src/process/exit.rs:177–186`; `process/process/mod.rs:641–656`; `process/posix_thread/mod.rs:177–185,249–253`; `process/signal/pause.rs:149–168,262–277`. | Exit publishes zombie before enqueueing the normal child signal and calling children `wake_all`. `do_wait` temporarily adds SIGCHLD to the thread mask. Asterinas signal enqueue also wakes registered signalled wakers. This additional notification can compensate for a missed children-queue observation and must remain visible in the analysis. |
| Return closes the waiter but can leave a closed queue entry until a wake drains it. | `ostd/src/sync/wait.rs:119–131,244–281`; `kernel/core/src/process/signal/pause.rs:164–166`; `process/signal/pending.rs:131–145`; `process/signal/sig_queues.rs:208–249`. | A closed waker does not wake a future operation. Queue-entry residue, duplicate notification, or standard-signal coalescing is not by itself a lost-status bug. The finite campaign asks whether an eligible wait can finish and whether a status is consumed once, not whether every wake count equals one. |

`kernel/core/src/time/wait.rs:170–218` passes this untimed pause into `Waiter::wait_until_or_cancelled` without creating a timer. Asterinas' cancellation branch closes the waker and rechecks the condition at `ostd/src/sync/wait.rs:223–226`. Arbitrary signal interruption stays outside the fixture, but normal SIGCHLD notification must not accidentally be interpreted as an independent EINTR source.

The compensation argument has three distinct cases. If exit is already visible, the first scan selects it. If exit occurs after the failed first scan but before registration, enqueue followed by another scan and the counter's ordering bridge supply the required recheck. If the waiter is registered, the signal-waker and children-waker paths can set a retained wake token before or after parking. A later consumer may remove the child before another waiter reruns its condition. In that case ECHILD is the expected completion. A source-level argument for these cases is present, but a complete scheduler/memory-model proof has not been performed during preparation.

## Linux oracle and permitted histories

Linux publishes `EXIT_ZOMBIE` and notifies the parent while holding `tasklist_lock` in `kernel/exit.c:741–778`. `kernel/signal.c:2230–2261` distinguishes SIG_IGN/SA_NOCLDWAIT autoreap from normal status retention, then wakes the parent's wait queue. The scoped fixture selects normal status retention.

Linux serializes the consuming ownership change with `cmpxchg(EXIT_ZOMBIE, EXIT_DEAD)` in `kernel/exit.c:1181–1191`. WNOWAIT takes a task reference without that consuming transition at lines 1170–1179. The resulting identity/status fields are retained for later output at lines 1269–1283. These mechanisms differ from Asterinas' children mutex and Arc. The oracle compares allowed externally visible histories rather than forcing either implementation's internal locks onto the other.

Linux installs a nonexclusive wait entry before scanning at `kernel/exit.c:1697–1719`. Its callback accepts the selected child at lines 1580–1607. `kernel/sched/wait.c:17–25,73–108,167–174` connects registration, queue locking, and wake delivery. `include/linux/wait.h:95–123` explains the separate ordering obligation for lockless waiter-presence checks. This is reference evidence for preserving Asterinas' real registration/recheck path, not an assertion that both implementations use identical barriers.

| Observed history | Allowed outcome and boundary |
| --- | --- |
| A live eligible child is checked with WNOHANG before exit publication. | No event is selected. wait4 returns 0. waitid returns 0 with Linux's no-event fields. WR-SQ separately records the Asterinas output discrepancy. |
| A normal exit is available and one consuming wait completes. | Exactly one consuming call obtains the child's normal-exit status. Subsequent calls for that incarnation return ECHILD. |
| WNOWAIT observes the same unconsumed child repeatedly. | Each observation may return the same identity and status. Observation does not create or consume another exit event. |
| Two consuming calls overlap on one child. | At most one receives that status. With blocking calls, no excluded signals, a completed exit, and execution progress, the other reaches ECHILD. With WNOHANG, a check before publication can instead return no event. |
| A WNOWAIT observer and consumer overlap. | An observer that already selected the child may return its saved status after the consumer returns. An observer that first checks after removal gets ECHILD. A new observer invoked after a completed consuming call cannot recover the removed status. |
| Both waiters were asleep before exit. | Notification and rescheduling permit one consumer to claim and the other to see ECHILD. Wakeup is permission to recheck, not a grant of exit status. No FIFO completion guarantee is assumed. |
| A consuming wait faults during output. | Linux can already have consumed the child before EFAULT. The corresponding Asterinas source also reaps before copyout. A universal rollback-on-EFAULT oracle would therefore be wrong. |

## Planned controls and schedules

All rows are **NOT_RUN** on both Linux and Asterinas. Start each row with a fresh child incarnation. Establish child readiness with a bounded fixture handshake, and release normal exit through that fixture. Sleeps and watchdog expiry do not establish the internal interleaving. The two waiter threads use distinct result areas. Record the actual guest CPU count for all concurrency claims.

| Case | Planned experiment | Required observation |
| --- | --- | --- |
| WR-01 | Keep the child alive and call wait4 with WNOHANG using a sentinel status word. | Return 0 and unchanged status. A later normal exit remains consumable. |
| WR-02 | Let the child exit normally, then consume through wait4. Repeat with exit values 0, 37, and 255. | Return the explicit PID and correct encoded status. Follow-up wait4 and waitid both report ECHILD. |
| WR-03 | Consume a normal exit through waitid with WEXITED. | Return 0 with the selected PID, UID, SIGCHLD, CLD_EXITED, and unshifted exit value. Follow-up calls report ECHILD. |
| WR-04 | Observe twice through waitid WEXITED|WNOWAIT, then consume through wait4. | Both observations agree. wait4 still obtains the status once. A post-consumption observer gets ECHILD. |
| WR-05 | Observe twice through waitid WEXITED|WNOWAIT, then consume through waitid WEXITED. | Observation leaves the event available, and only the final call consumes it. |
| WR-06 | Have two wait4 consumers overlap on the same child, once before exit and once with an already waitable child. | One status is consumed. The other blocking call completes with ECHILD under the stated progress assumptions. Both claim attempts and mutex ordering are visible. |
| WR-07 | Repeat the competing-consumer schedule with two waitid consumers and then one wait4 plus one waitid consumer. | The API choice does not create a second consumable status. Record API-specific success values instead of comparing return values directly. |
| WR-08 | Overlap a WNOWAIT observer with a consumer. Include a schedule where observation selection precedes removal but its output completes later. | The retained observation is accepted as a legal history. An observer first checking after removal gets ECHILD. The trace distinguishes selection, removal, and output completion. |
| WR-09 | Arrange exit after the first failed scan and before the waiter's enqueue/recheck. | The recheck finds the child or its completed removal. No permanent wait is attributed to this window without trace evidence that notification, recheck, and scheduling actually occurred. |
| WR-10 | Arrange exit after registration, both before parking and after parking. Exercise two registered consumers. | The retained token or scheduler wake leads to a new scan. One consumer's early claim cannot strand the second waiter. Capture both signalled-waker and children-queue notification paths. |
| WR-SQ | On a live child, compare raw waitid WEXITED|WNOHANG with zeroed and nonzero sentinel-filled valid siginfo buffers. | Linux's selected fields become zero. Asterinas source predicts unchanged output on its no-result branch. Preserve the observed difference separately if reproduced. A zero-initialized buffer alone does not test or clear this discrepancy. |
| WR-CF | As a separate sequential calibration, use an inaccessible output page after an established zombie. Compare consuming wait4, consuming waitid, and waitid WNOWAIT. | Calibrate EFAULT and the next valid wait. Consuming failures may leave no waitable child, while WNOWAIT should leave it available. Do not add rollback to the primary protocol based on the error alone. |

WR-09 and WR-10 need instrumentation whose synchronization does not create the ordering being tested. Record first scan outcome, waiter identity, registration/recheck, zombie publication, notification path, token consumption or park, selection under the children mutex, removal, output result, and thread completion. Instrumentation must preserve lock boundaries and must not block while holding a lock solely to force a schedule. If only an end-to-end timeout is available, classify the result as an execution limit rather than a demonstrated lost wakeup.

## WR-SQ and evidence limits

WR-SQ is a lane-local source discrepancy, not an assigned AST ID or a reproduced bug. Asterinas returns from `sys_waitid` before touching siginfo on the no-result path. Linux's pinned syscall wrapper initializes and writes its selected fields. The primary protocol fixture may prezero siginfo to distinguish no result from a delivered PID, but its successful execution cannot establish that Asterinas implemented Linux's clearing behavior. Preserve a separate poisoned-output calibration result and its input identity. A sequential output discrepancy does not replace the protocol campaign or justify ending after analysis.

The findings catalog and old-ID map were searched for wait4, waitid, WNOWAIT, WNOHANG, zombie, reap, and siginfo without finding a directly named existing entry for WR-SQ. This is limited local screening. The receiver still owes source-history archaeology, discussion-level issue/PR review, and mechanism-based deduplication during native analysis. No novelty claim or new AST allocation is made here. The campaign has read prior materials and is not blind discovery.

Preparation has enough source evidence to select the supported syscall subset and the publication/observation/consumption protocol. It has not produced native analysis outputs, independent analysis acceptance, a model, instrumentation, controls, or runtime evidence. Before harness acceptance, pin the libc/header ABI, verify SIGCHLD configuration, demonstrate the chosen legal schedule controls, and record actual SMP >= 2. Before model acceptance, review the selection/removal/output split and the real notification and ordering mechanisms. Keep a scheduler or memory-model assumption explicit where this bounded investigation stops.

The package coordinator owns run identity, preflight, dry-run, model routing, and shared-resource admission. Receiver execution follows [HANDOFF.md](HANDOFF.md) and the shared [resource policy](../resources.json). There is no scope-blocking source limitation established by this preparation. Execution readiness remains governed by those separate checks.

## Source hashes

The following SHA-256 values identify the Asterinas files used for the production-chain and ABI claims. Paths are relative to the fixed source root. Source line references above describe this pin only.

```text
35ccbc14c52541707ccdd2283682a816497668851904512ef9afd6957583c9a9  kernel/core/src/syscall/wait4.rs
04e22c64655b0a488f8bedb9db924a7b64804a2fc8160ef3ffb1d3c43281a3fc  kernel/core/src/syscall/waitid.rs
f0ccbe4ef740efd9873c3c8101cda7a5eedd15dfab6a272836140a311b252a7a  kernel/core/src/process/wait.rs
20d2444573f4bc47543accaffc792a7754da5758194fce0432e22d14f86af499  kernel/core/src/process/status.rs
c48c21b8e9abc4590f097588b2d16c6072a43b2da0cdd67e426623acfcc26044  kernel/core/src/process/posix_thread/exit.rs
44e3b323b9bd55cd140989dd6d224631b00086066a531157f46db6c5733dcdfd  kernel/core/src/process/exit.rs
26eccaacd4b11152ca31471f8cefe5bcce9703733693214b138bd1887b31cc5e  kernel/core/src/process/signal/pause.rs
704a9d8841850d1be34f2dffa682f36a8a7f9bdbb831aca1ab028c54df4327b7  kernel/core/src/time/wait.rs
acb0fccb6c264169b7ee702f28b850444c9476425333f4304a6cb6fcd763d17e  ostd/src/sync/wait.rs
af64fd9e97afbaa399277683c570fa314b3ff63f3a5599b434a59dfbd275e71e  ostd/src/sync/mutex.rs
adbe8fbb06789c6a9cce19a53987e3355d2c8c50bc0449c6db23066acbd3f979  ostd/src/task/scheduler/mod.rs
a43b655e885c8c6a6a94073d13e9dd43f04f40f839b31435b2aae8dc0f0a3e58  kernel/core/src/process/process_filter.rs
1d8d4b26d8b1fbbd0cf02bb9195b8ded3f86347d91aa80cfa075a78fdb10222a  kernel/core/src/process/term_status.rs
abba4258a78c27253d210ff5704e96a94e5dffaabccfeb3911a9bc6553c75033  kernel/core/src/process/task_set.rs
40be4209e860f02c0b94565e42b19705926a580151b8f2479a2d7b6aee79cb7f  kernel/core/src/process/pid_table.rs
2f1c08207c6586fbd1d22276a75ad95c65b3330415a04c46820e5641ea130c0e  kernel/core/src/process/process/mod.rs
59ca0a269a45842ff5e3008c7f783b03b9ae2db2ec4a82db0f2973b0184e1921  kernel/core/src/process/posix_thread/mod.rs
1c8c3343e1ba45e071053e7cdf63291cdcaa043744cfbce2c2d85c7bb681b08e  kernel/core/src/process/signal/pending.rs
1d14b6858644968327dad96e4a4a4b5b05a65bb95413a2d1f02a31b4416c5897  kernel/core/src/process/signal/sig_queues.rs
eb3ca21eccd9a4cc9e88c5828b231e4e287b2af6536a44587f2bfc5d46dd5b76  kernel/core/src/process/signal/c_types.rs
6f84a99bc43056b2233044d9fd2eb5ba2b0ce2af4a4e3f93cd6a46f98aa11226  kernel/core/src/syscall/arch/x86.rs
78939966e0d7e78e1cf77d636dc18d4580c352d276cc595fee48470096284b4f  kernel/core/src/syscall/exit.rs
7d5bda1b761ea29a7b4b9158493f2aed42c0ba43c0de282274d685bdc83b3027  kernel/core/src/syscall/exit_group.rs
```

These six files are the minimal Linux reference set used here. Their archive provenance is recorded by the coordinator. No Linux source was downloaded for this subtask.

```text
0af79a5bf713512ba7b255c5b21d70a5bd8955c3976e77de4e840948d0785908  kernel/exit.c
608b528d4042e2e53044e0197c10bd17374fc0b18f73be89733ad7bd4985a165  kernel/signal.c
216e7b2891422e0efdb7113861c8b2be4a302f84115d1b404cd2b80c55f21f60  kernel/sched/wait.c
e7d4694791376c8eeadda419c17e2483f87ed0aa96896a24683d7c474a634223  include/linux/wait.h
5aef6849976f461a6a202d92c4f37de8d0550b66699efc398ada9e906047fdc3  include/uapi/linux/wait.h
22b270974fa6db12d9278a58bf412411f15c2c4e90ad861e4e0e54e662356e52  include/uapi/asm-generic/siginfo.h
```
