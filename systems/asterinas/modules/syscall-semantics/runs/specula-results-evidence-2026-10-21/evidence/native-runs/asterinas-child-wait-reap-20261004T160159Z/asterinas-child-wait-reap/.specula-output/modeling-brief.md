# Modeling Brief: asterinas-child-wait-reap

## 1. System Overview

- **System:** Asterinas, Rust, pinned at `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`. The 17 principal files contain 5,227 lines, including unrelated branches and tests.
- **Category B (Concurrent / Lock-Free / Runtime):** the protocol transfers one child's consuming-reap ownership between parent threads using a mutex, publication atomics, retained Arcs, and wake/park handoffs.
- **Reference:** Linux v6.16.5, commit `4645fefac0b24d509b962c096b0327e87f34b1d2`. Its source is an oracle, not an executed Linux control.
- **Fixture:** one established single-threaded child, one live parent with two waiters, positive fixed child PID, fixed credentials, normal exit, distinct valid stable outputs, and null rusage.
- **Calls:** consuming wait4 with 0/WNOHANG, and waitid P_PID with WEXITED plus optional WNOWAIT/WNOHANG. SIGCHLD is SIG_DFL without SA_NOCLDWAIT and blocked in every parent thread.
- **Architecture:** Asterinas claims under the parent's children mutex and retains `Arc<Process>` through output. Linux claims with EXIT_ZOMBIE-to-EXIT_DEAD cmpxchg under task-list synchronization (`process/wait.rs:293–319`; Linux `kernel/exit.c:1170–1191`).
- **Evidence state:** static analysis supports the selected contracts and retains WR-SQ as an untested source lead. No new in-scope concurrent defect is established. Generate the full protocol model anyway. All preparation cases and runtime controls remain **NOT_RUN**.
- Below, `process/`, `syscall/`, `time/`, and `sched/` paths are relative to `kernel/core/src/`. Detailed coverage, evidence limits, and exclusions are in [analysis-report.md](analysis-report.md).

## 2. Scenarios

### Scenario 1: One consuming owner across both wait interfaces

**Mechanism:** scanning, selecting, and removing a child must share an exclusion boundary even though syscall completion happens later.

**Evidence:**
- Historical context: `95faea0fb04c` / [PR #2166](https://github.com/asterinas/asterinas/pull/2166) replaced a detached children snapshot with locking across selection and reap. This is already present at the pin.
- Code analysis: `process/wait.rs:293–319,339–374` holds the children mutex across PID matching, zombie acquire, Arc retention, map removal, and PID cleanup. Both syscalls call `do_wait` (`syscall/wait4.rs:36–47`, `waitid.rs:43–66`). No match yields ECHILD before the WNOHANG branch (`process/wait.rs:75–89`).

**Affected code paths:** `sys_wait4`, `sys_waitid`, `do_wait`, `try_wait_children`, `reap_zombie_child`.

**Suggested modeling approach:**
- Variables: `childPresent`, `pidPresent`, `childrenOwner`, per-call `api`, `options`, `pc`, `claim`, and `result`.
- Actions: acquire children lock, scan, select/retain, consume/remove, finish cleanup, release lock, output, and return. Preserve one lock owner across the protected steps. Publish exit independently of that lock.
- Granularity: separate selection/removal from copyout and completion. Cleanup may be abstracted only with its lock and lifetime effects preserved. Never reintroduce the historical unlocked snapshot.

**Priority:** High. **Rationale:** priority question 1 requires a common consuming authority across APIs and a fresh post-reap call. Finite ownership is directly modelable without inventing a defect.

### Scenario 2: Nonconsuming observation and retained output lifetime

**Mechanism:** removing discoverability does not invalidate an observation that already retained the child's object.

**Evidence:**
- Code analysis: WNOWAIT clones the Arc but skips reap (`process/wait.rs:310–319`). `WaitStatus::Zombie` owns it (`120–164`). Main-task retention survives exit and PID detachment (`process/task_set.rs:46–75,141–144`; `process/pid_table.rs:148–166`).
- Reference comparison: Linux's WNOWAIT branch retains the task and reads its status without claiming EXIT_DEAD (`kernel/exit.c:1170–1179`). Asterinas reads output fields later from the retained object (`syscall/wait4.rs:45–47,63–65`; `waitid.rs:53–66,72–90`).

**Affected code paths:** `try_wait_children`, `WaitStatus`, `TaskSet::remove_exited`, both syscall output paths.

**Suggested modeling approach:**
- Variables: per-call `selectedChild`, `selectionKind`, `retained`, `outputState`, and immutable selected identity/status.
- Actions: nonconsuming select, competing consuming select, output completion, release retained reference, and next invocation.
- Granularity: keep selection and output separate. Permit an already-selected observer to return after a consumer. A fresh selection after removal must fail. Do not equate map removal with object destruction.

**Priority:** High. **Rationale:** priority question 2 needs both repeated observations and legal late output. A return-order-only oracle would falsely report double consumption.

### Scenario 3: Registration, two notification paths, and park/unpark

**Mechanism:** an unsuccessful scan must be connected to later observation through registration, rechecking, retained wake tokens, and scheduler synchronization.

**Evidence:**
- Historical context: [#831](https://github.com/asterinas/asterinas/issues/831) concerns ordering. [#1261](https://github.com/asterinas/asterinas/issues/1261) and [#1497](https://github.com/asterinas/asterinas/issues/1497) withdraw lost-wakeup claims after compensating mechanisms are explained. [PR #2503](https://github.com/asterinas/asterinas/pull/2503) explains unconditional signalled-waker notification.
- Code analysis: first scan precedes waiter creation. Signal-waker registration precedes children enqueue/recheck (`process/signal/pause.rs:149–168,225–245`). Untimed waits create no timer (`time/wait.rs:170–218`).
- Zombie publication precedes normal signal enqueue and children `wake_all` (`process/exit.rs:36–40,177–186`). Signal enqueue wakes every registered parent signalled waker even when SIGCHLD is blocked (`process/process/mod.rs:641–656`, `posix_thread/mod.rs:177–185,249–253`).
- Queue-presence Release RMW, registration Acquire RMW, Release wake-token swap, and Acquire consumption/recheck are explicit (`ostd/src/sync/wait.rs:110–149,209–231,262–281`). Park and enqueue use the same runqueue lock and retry task assignment (`ostd/src/task/scheduler/mod.rs:441–494`; `sched/sched_class/mod.rs:219–258,410–414`).

**Affected code paths:** `Pause for WaitQueue/Waiter`, `Process::enqueue_signal`, `wake_signalled_waker`, `WaitQueue::wake_all`, `Waker`, `park_current`, `ClassScheduler::enqueue`.

**Suggested modeling approach:**
- Variables: per-invocation waiter identity/phase, signal registration, queue entries, token/closed state, task runnable/parking state, and exit notifier phase.
- Actions: initial failed scan, create waiter, register signal waker, enqueue, recheck, check cancellation, consume token, park check/dequeue, signal notification, each queue pop/wake, reschedule, and close.
- Granularity: signal notification and queue draining are distinct. Queue pop and `wake_up` are distinct because the queue lock is dropped between them. Wake-token publication can interleave between the park check and dequeue while unpark waits for the runqueue lock. Split these steps or justify an equivalent projection. Preserve registration on each retry and closed/duplicate entries, or justify a projection that retains their observable effects.
- Treat wake as permission to recheck. Keep both consumers eligible for completion: after one reaps, the other rechecks to ECHILD. Reap itself has no extra children wake. The exit notifier must still finish after a racing reap.

**Priority:** High. **Rationale:** priority question 3 spans multiple synchronization domains. Historical defects are context only. Do not remove a recheck, signal wake, or memory-order bridge to recreate a known bug.

### Scenario 4: Exit-code publication before status delivery

**Mechanism:** a relaxed status write becomes readable through a separate release/acquire zombie publication.

**Evidence:**
- Code analysis: the exiting thread stores the code before calling `exit_process` (`process/posix_thread/exit.rs:63–89,120–122`). Zombie Release and Acquire explicitly publish it (`process/status.rs:39–54,69–78`).
- Identity and encoding are stable: positive PID filtering (`process/process_filter.rs:28–31,68–70`), `(e & 255) << 8` for wait4 (`process/term_status.rs:11–18`), and unshifted normal exit plus CLD_EXITED for waitid (`syscall/waitid.rs:72–90`).
- Historical context: `25c4f0f2bcaa` introduced TermStatus-based wait-status encoding. The current encoding is retained, with no historical-revert target.

**Affected code paths:** normal exit syscall, `exit_internal`, `exit_process`, `ProcessStatus`, both status encoders.

**Suggested modeling approach:**
- Variables: `exitPc`, `storedCode`, `zombie`, and each waiter's acquired publication/selected object.
- Actions: store code, publish zombie, acquire-observe zombie, and later read/copy output. Use representative exit values 0, 37, and 255 when exploring encoding.
- Granularity: publication and notification are separate. Forbid stale exit code once this publication was acquired. Record the Rust atomic and lock assumptions supporting this abstraction rather than introducing arbitrary stale reads.

**Priority:** High. **Rationale:** priority question 4 is a cross-variable ordering and lifetime obligation. A sequentially consistent protocol model alone is not a Rust/compiler/hardware weak-memory proof.

### Scenario 5: No-event and error results need API-specific oracles

**Mechanism:** waitid's success return does not distinguish an observed exit from an eligible child with no ready event.

**Evidence:**
- Code analysis: an eligible live child with WNOHANG yields `Ok(None)` (`process/wait.rs:75–89`). wait4 returns zero without writing status (`syscall/wait4.rs:41–47`). waitid also returns early without writing siginfo (`waitid.rs:49–66`).
- Source lead **WR-SQ:** Linux initializes and writes selected siginfo fields on no event (`kernel/exit.c:1800–1827`), whereas Asterinas leaves the valid output unchanged. Persistent-findings lookup returned no match. This does not establish novelty or a runtime result.
- Calibration **WR-CF:** both sources claim before output can fault (`process/wait.rs:310–319`; both syscall copyouts; Linux `kernel/exit.c:1186–1191,1800–1830,1868–1873`). Rollback after EFAULT is not a valid universal oracle.

**Affected code paths:** `do_wait`, `sys_wait4`, `sys_waitid`, user copyout.

**Suggested modeling approach:**
- Variables: per-call outcome tagged as event/no-event/ECHILD, with API-specific return and output projection.
- Actions: record the scan result independently of later return. A no-event scan before exit may return after a concurrent reap. A call invoked after consuming completion must reach ECHILD.
- Granularity: primary valid-buffer model may prezero siginfo, but must preserve the implementation's no-write branch. Keep poisoned-output WR-SQ and faulting-output WR-CF as separate sequential controls, both **NOT_RUN**.

**Priority:** Medium. **Rationale:** priority question 5 needs calibrated observable outcomes. A sequential discrepancy cannot replace the requested concurrency campaign.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
| --- | --- | --- |
| One child, two waiter threads, both APIs, repeated invocations. | Scenarios 1–2 cover competition and observation before/after consumption. | Fix incarnation/PID/UID. Bound calls while allowing two WNOWAIT observations followed by consumption and a post-reap call. |
| Protected claim plus retained result through output. | Scenarios 1–2 distinguish unique ownership from late completion. | Track claim, retained object, and delivery separately. Preserve the children lock across all destructive updates. |
| Publication, signal wake, queue wake, recheck, and scheduler handoff. | Scenarios 3–4 answer the missed-notification windows without deleting compensating mechanisms. | Per-thread/notifier program counters and source-justified ordering edges. Include exit before registration, after registration, and during park. |
| API-specific normal/no-event/error outcomes. | Scenario 5 prevents treating every waitid return 0 as a delivered exit. | Decode only delivered fields. Keep the poisoned-output discrepancy separate from primary prezeroed traces. |

Completion requires the child to finish publication/notifications, the parent and waiters to stay live, locks to be eventually acquired/released, pending unpark work to finish, and runnable threads to execute. Use explicit fairness for these actions and finite client activity. Do not assume spontaneous notifications, an untimed-wait timeout, FIFO order, or immediate rescheduling. Internal schedule evidence and actual SMP >= 2 are required for runtime concurrency claims.

### 3.2 Do Not Model (with rationale)

| What | Why |
| --- | --- |
| Fork/thread creation, exec, parent exit, reparenting/subreapers, ptrace, stop/continue, non-SIGCHLD clone children, pidfd, PID reuse. | Explicit fixture boundaries. Read adjacent paths to establish exclusion, but do not add independent state machines. |
| SIG_IGN, SA_NOCLDWAIT, arbitrary signal restart, cancellation storms, resource exhaustion, counter wrap. | These alter reachability or the finite fixture. Preserve normal blocked SIGCHLD notification instead. |
| General allocator/Arc implementation, language aliasing, complete scheduler policy, VM/copyout internals, rusage correctness. | Assume valid retained objects, stable buffers, and the checked scheduling bridge. These mechanisms need separate low-level verification. |
| WR-SQ bytes/padding and WR-CF fault injection in the primary model. | Sequential runtime controls suffice. Compare relevant fields, not unrelated union bytes. Do not impose consume rollback on output failure. |
| Reverted fixes or deliberately weakened synchronization as bug hunts. | Closed historical defects supply context, not new evidence about this pin. No such adversary is proposed. |

## 4. Proposed Extensions

| Extension beyond the abstract Linux contract | Variables | Purpose | Scenario |
| --- | --- | --- | --- |
| Asterinas children-map claim boundary. | `childrenOwner`, `childPresent`, `pidPresent`, `claim` | Represent mutex-protected removal instead of assuming a Linux cmpxchg implementation. | 1 |
| Retained observation and delayed copyout. | `selectedChild`, `selectionKind`, `retained`, `outputState` | Allow legal old selections to finish after removal. | 2 |
| Registered waiter and two wake channels. | `pc`, `signalReg`, `queue`, `token`, `closed`, `runnable`, `notifyPc` | Preserve registration/recheck, per-entry delivery, and park/unpark ordering. | 3 |
| Explicit publication edge. | `storedCode`, `zombie`, `acquiredPublication` | Relate both status encoders to the published exit. | 4 |
| Distinct API result projections. | `api`, `options`, `outcome`, `returnValue` | Separate event delivery, no event, and ECHILD. | 5 |

## 5. Proposed Invariants

| Invariant/property | Type | Description | Targets |
| --- | --- | --- | --- |
| TypeOK / LockExclusion | Safety | State domains are valid and at most one waiter owns the children critical section. | All, 1 |
| UniqueConsume | Safety | At most one consuming claim exists for this child incarnation across both APIs. | 1 |
| NoFreshSelectionAfterRemoval | Safety | Every new selection requires map membership. Calls begun after consuming completion cannot deliver this child. | 1–2 |
| ObservationPreservesAvailability | Safety | WNOWAIT does not remove availability. Removal is attributable to a consuming claim, not an observation or wake. | 2 |
| RetainedSelectionValid | Safety | Every event output has a prior protected selection and a retained live object through its final read. Late observer output is allowed. | 2 |
| PublishedStatusAgreement | Safety | Every delivered identity/status matches the one acquired normal-exit publication, with API-specific encoding. | 4 |
| ApiOutcomeCorrect | Safety | Live/no-event WNOHANG returns no event, absent-child scans return ECHILD, and only event outcomes count as delivery. WR-SQ field clearing remains a separate control. | 5 |
| BlockingWaitCompletes | Liveness | Under the stated progress assumptions, every eligible outstanding blocking call eventually returns an event or ECHILD after exit. | 3 |
| CompetingConsumersComplete | Liveness | Starting with the unconsumed child and two consuming blocking invocations, eventual exit yields one successful consumer and one ECHILD completion. Exclude WNOWAIT, WNOHANG, and later post-reap calls from this antecedent. | 1, 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

No new concrete concurrent defect survived source review. The selected Scenarios and properties are mandatory protocol-verification work, not asserted bugs. Proceed with the reference/MC/trace suite even with this empty defect-candidate set. No historical-revert hunt configuration is warranted.

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
| --- | --- | --- |
| WR-SQ | **SOURCE LEAD / NOT_RUN:** waitid WNOHANG leaves siginfo untouched on no event, unlike the pinned Linux source. | On fresh live children compare direct syscalls with zeroed and poisoned valid outputs. Record libc error conversion and selected fields before/after on independently identified Linux and Asterinas controls. No novelty or AST assignment. |
| WR-CF | **CALIBRATION / NOT_RUN**, not an established defect: a consuming output fault may leave ECHILD for the next call. | Separately compare faulting wait4, consuming waitid, and WNOWAIT waitid, each followed by a valid wait. |

### 6.3 Code-Review-Only

No additional in-scope defect candidate is retained. The model's memory-order projection, nested-lock progress assumption, and concrete scheduler bridge need source-bound review at the next stage. They are evidence limits, not kernel bug claims.

## 7. Reference Pointers

- [Detailed analysis and coverage](analysis-report.md), [source identities](analysis-evidence/analysis-identity.json), and [29 checked source hashes](analysis-evidence/source-hashes.json).
- [Required contracts and WR-01 through WR-10, WR-SQ, WR-CF](/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/wait-reap/contracts.md).
- Asterinas source anchors in Scenarios 1–5 refer only to the fixed pin. Linux reference files are under `/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/linux-v6.16.5`.
- [Resource policy](/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/resources.json): the controller invokes stages and admits resources. This worker ran code analysis only. Preserve prior/proposed versions, diff, reason, triggering evidence, exact hashes, and independent reviewer disposition before rerunning verification after any semantic change, including Phase 3 correction loops. If review is unavailable, return incomplete to the controller and resume this campaign when the gate closes.
