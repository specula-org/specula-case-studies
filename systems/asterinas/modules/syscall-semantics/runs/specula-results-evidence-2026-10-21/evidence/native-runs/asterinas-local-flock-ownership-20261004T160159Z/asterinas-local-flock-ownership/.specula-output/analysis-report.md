# Local flock ownership, conversion, and release analysis

This analysis prepares one bounded local-inode protocol for Spec Generation.
It retains two source-supported questions: conversion preserves the old
Asterinas lock when fixed Linux removes it, and temporary ownership during
unlock can invoke a final destructor while the same list Mutex remains held.
Neither is a newly observed runtime defect. The complete ownership, conversion,
release, and retry protocol remains the modeling target even if later work
refutes either question.

The code-analysis work is complete for independent phase review.
Linux controls, Asterinas regression tests, guest runs, instrumentation,
execution traces, model generation, TLC, and runtime confirmation are `NOT_RUN`.
No AST ID was allocated, no persistent finding was registered, and no source
or model was changed. The separate controller owns phase acceptance and
continuation.

## Inputs, methodology, and evidence boundary

The installed `specula-codex:code-analysis` entrypoint, full guide, shared
deep-analysis reference, Category B reference, bug-archaeology reference,
modeling-brief format, example, and persistent-findings reference were read.
The work used its reconnaissance, archaeology, deep-analysis, and synthesis
phases. Two concurrent helpers handled ownership and waiter analysis, including
disjoint batches of complete issue/PR discussions. The main analyst handled
file-table/syscall lifetimes, the Linux comparison, cross-checking, and synthesis.
The two-helper limit in the campaign resource policy was respected.

The target is **Category B (Concurrent / Lock-Free / Runtime)**. It is a
mutex-based protocol, not a lock-free implementation. Its relevant boundaries
are strong-reference capture/drop, list critical sections, notification atomics,
queue draining, scheduler parking, and synchronous destructor callbacks.
There is no distributed fault model.

| Input | Verified identity |
|---|---|
| Working source | `../source`, commit `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`. |
| Prepared source | `/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source`, same commit/tree. Both copies have 4,715 commits and are non-shallow. |
| Linux source oracle | v6.16.5, `4645fefac0b24d509b962c096b0327e87f34b1d2`, selected archive files under `/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/linux-v6.16.5`. This is not a running Linux control. |
| Rust lifetime evidence | Installed `nightly-2026-07-21` alloc Arc source. Its bytes match the contract. A future build must record its actual compiler/toolchain independently. |
| Preparation | [preparation-verified.json](analysis-evidence/preparation-verified.json) matches source identities and the manifest's contracts, guidance, and agent-configuration hashes. |
| Source bytes | [input-hashes.json](analysis-evidence/input-hashes.json) verifies all 30 contract entries, with zero mismatches. |
| Prior assessment | [contracts.md](/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/flock/contracts.md). FL-SQ-1/2 are inherited source questions, not newly discovered or registered findings. |

The initial Git status had only untracked `.codex/`; tracked source was clean.
The source repository has no configured remote, so archaeology used its full
local history and explicit `-R asterinas/asterinas` GitHub reads. No fetch,
checkout, push, comment, issue, or PR publication was performed.

The read-only persistent lookup used `FlockList`, `unlock_flock`, `flock`, and
`InodeHandle`. It returned `[]`; the run context has no previous output or
inherited records. Evidence is [persistent-lookup.json](analysis-evidence/persistent-lookup.json).
The shell initially lacked `specula` on PATH; the lookup succeeded through
`/home/chin39/Documents/play/Specula/.venv/bin/specula`. No registry initialization
or record mutation was needed.

Source citations below use paths relative to the pinned Asterinas source unless
marked Linux or Rust. In compact citations, `flock.rs`, `file_table.rs`, and
`inode_handle.rs` mean `kernel/core/src/fs/file/`, and `inode_ext.rs` means
`kernel/core/src/fs/vfs/fs_apis/`.

## Phase 1: Reconnaissance

Twelve core files totaling 3,406 lines were read completely. The 84-line
`inode_ext.rs` was also read completely, for 3,490 lines across these thirteen
files. Supporting reads followed the actual ordinary-file, Arc, and scheduler
paths. Large supporting filesystem/path modules were inspected at relevant
production sections, not represented as fully audited files.

| Component | Complete files and lines | Role |
|---|---|---|
| Flock and inode handle | `fs/file/flock.rs` 199; `fs/file/inode_handle.rs` 649 | Conflict, conversion, queues, unlock, and final destructor. |
| FD/OFD lifetime | `fs/file/file_table.rs` 407 | Dup aliases, capture, removal, and ClosedFile. |
| Syscall entry | `syscall/open.rs` 159; `dup.rs` 85; `close.rs` 101; `flock.rs` 81 | New OFDs, aliases, close ordering, valid operation dispatch. |
| Wait primitives | `ostd/src/sync/wait.rs` 400; `mutex.rs` 158 | Notification storage/consumption, queue drain, nonrecursive mutex. |
| Wait adaptation | `kernel/core/src/time/wait.rs` 245; `process/signal/pause.rs` 311 | No-timeout flock condition loop and waiter lifetime. |
| Scheduler | `ostd/src/task/scheduler/mod.rs` 611 | Parking and wake-to-runqueue boundary. |
| Per-inode context | `kernel/core/src/fs/vfs/fs_apis/inode_ext.rs` 84 | Once-initialized typed flock context. |

The supporting chain establishes that ordinary `Path::open` produces an
`InodeHandle` (`kernel/core/src/fs/vfs/path/mod.rs:166-208`), RamInode owns and
returns its extension (`fs/fs_impls/ramfs/fs.rs:163-164,1550-1552`), and tmpfs
aliases RamFs (`fs/fs_impls/tmpfs/fs.rs:18-29`). Each accepted independent open
allocates a new Arc (`syscall/open.rs:102-126`). Dup clones the existing Arc
(`file_table.rs:181-187`). These are OFD identities, not process or FD numbers.

The prelude selects alloc Arc/Weak and OSTD Mutex
(`kernel/core/src/prelude.rs:10,23`). `RwArc::get` requires exclusive mutable
access and one writable owner (`ostd/src/sync/rwarc.rs:60-81`). Shared-table
lookup instead clones the file under a read guard and releases the guard before
the operation (`file_table.rs:341-361`). The thread-local RefCell borrow is not
a held global file-table lock (`process/posix_thread/thread_local.rs:145-151`).

### Atomicity map

| Production operation | Serialized part | Interleavings the model must retain |
|---|---|---|
| Open/dup/FD removal | File-table write lock; dup clones the same Arc. | OFD capture and subsequent file operation are separate. FD reuse does not retarget an already captured request. |
| Shared-table lookup | Read-lock, clone, and guard release. | The in-flight Arc can survive another thread's close. |
| `try_set_lock` | One list Mutex covers conflict search, first-blocker registration, and grant/replacement (`flock.rs:114-131`). | A wake, retry, and later contender run after that critical section. Do not insert a release between conflict detection and enqueue. |
| Unlock scan | List Mutex remains held for `retain`, including temporary Weak upgrades and drops (`164-181`). | FD removal and strong-reference drop on other CPUs can proceed during the scan. Mutex ownership is not nonpreemptibility. |
| Item Drop | Every removed/replaced item wakes its queue (`78-82`). | The local request shares that queue and may drop outside the list guard while ownership remains. |
| Queue drain | Pop/count change under queue spinlock; unlock before calling wake (`ostd/src/sync/wait.rs:95-106,119-131`). | Accepted notification, scheduler enqueue, wake consumption, and retry are distinct. |
| Park | Rechecks the flag under the scheduler runqueue guard (`scheduler/mod.rs:453-470`). | Actual ClassScheduler enqueue/dequeue uses the same runqueue synchronization (`sched/sched_class/mod.rs:215-242,255-258,404-414`). |
| Final destruction | Last Arc drop synchronously invokes payload Drop. | Destruction begins before list cleanup acquires its Mutex. Expired Weak entries can temporarily remain. |

## Phase 2: Bug archaeology

The source histories were followed across renames and earlier `jinux`,
`aster-nix`, and `kernel/src` layouts. The ownership helper expanded the old
`inode_handle/{mod,dyn_cap,static_cap}.rs` paths. The waiter helper followed the
deleted Pauser predecessor separately because its replacement was not a rename.
This avoids treating a file move or rewrite as the start of the protocol.

Full-message searches included fix, bug, race, panic, deadlock, correctness,
crash, corrupt, leak, inconsistent, and wrong. Subject screening also selected
semantic changes without those keywords. Keyword matches that only affected
documentation, formatting, or unrelated paths were explicitly classified.
Every significant fix identified in the core histories was inspected, with
full patches or documented core-path projections retained. No fixed bug was
reverted or made a new model-checking target.

| Coverage | Result and evidence |
|---|---|
| Unique history commits screened | 306 after deduplicating the main lane's 113, ownership's 122, and waiter's 125. [Union](analysis-evidence/history-union.json). |
| Main-lane detailed commit review | 34 core patch reviews, including 17 semantic defect corrections. [Full table](analysis-evidence/root-audit.md). |
| Ownership detailed commit review | 18 significant fixes/compatibility/lifetime changes, eight keyword false positives, plus introduction and supporting context. [Full table](analysis-evidence/ownership/history-review.md). |
| Waiter detailed commit review | 21 significant defect-fix commits, one corrective revert, two hardening changes, one design fix, and explicit non-target classifications. [Full table](analysis-evidence/waiter/history-classification.md). |
| Issues collected | 557 unique issues from twelve keyword searches and the actual `C-bug` label. The preliminary `bug` label returned none and was corrected. [Collection](analysis-evidence/github/issues-collection-union.json). |
| Issues deeply read | 30 complete bodies and all 90 comments, in parallel ten-issue batches. REST pagination totals were checked against issue metadata. |
| Issue dispositions | 15 confirmed historical/current bug reports or families, three disputed/false, five design-defect/design-history discussions, one uncertain question, and six non-bug engineering/administrative requests. These are report counts, not unique defects or new findings. |
| Open PR coverage | All 108 titles, metadata, and changed-file lists screened. Fifty-eight bug-intent, possible bug-intent, or core-overlap threads were read in full, including all 755 issue-comment/review/inline-review records. The remaining fifty were outside-protocol feature/refactor requests without identified bug-fix intent. |
| Pending core changes | Thirteen pertinent PR diff sets checked across the lanes, with immutable identities retained. No reviewed pending change resolves the two retained flock source mechanisms. This is not a claim about unreviewed private work or future upstream/main. |

The `gh issue view --comments` output alone omitted the original body in this
environment. The analysis therefore read the REST body as well as every
paginated comment. PR review bodies and inline discussions were fetched
separately. Automated review claims were checked for later corrections and
used only for mechanism screening. Their reported test runs were not counted
as this campaign's runtime evidence.

The detailed issue tables are [main](analysis-evidence/root-audit.md),
[ownership](analysis-evidence/ownership/issues-review.md), and
[waiter](analysis-evidence/waiter/issues-classification.md).
The PR tables are [main](analysis-evidence/root-audit.md),
[ownership](analysis-evidence/ownership/open-pr-review.md), and
[waiter](analysis-evidence/waiter/open-pr-classification.md).
The raw requests, full threads, snapshots, pagination results, and diff
identities remain under `analysis-evidence/`.

### Mechanism history and dispositions

| Mechanism | Evidence and consequence for the current campaign |
|---|---|
| Registration and retry against a changed blocker | [#1474](https://github.com/asterinas/asterinas/issues/1474), `e5fd8e747745`, and `7fbe997bb3d2` explain the current list-locked registration and condition retry. Preserve the fix. |
| Replaced queue is not a permanent subscription | [#1464](https://github.com/asterinas/asterinas/issues/1464) explains why copying a previous blocker queue does not solve blocker migration. It concerns range locks, but informs the analysis of the current flock retry path. |
| Stale wakers do not necessarily lose a wake | [#1261](https://github.com/asterinas/asterinas/issues/1261) and [#1497](https://github.com/asterinas/asterinas/issues/1497) reject the proposed correctness failures after considering close, retained notifications, skip-on-failed-wake, and allowed spurious scheduler events. |
| Notification ordering | [#831](https://github.com/asterinas/asterinas/issues/831) and `414a3a389e2e` establish an already-fixed ordering mechanism. Current orderings remain intact. No weakened-ordering adversary is proposed. |
| Eager temporary guard destruction | [#496](https://github.com/asterinas/asterinas/issues/496), [#1274](https://github.com/asterinas/asterinas/issues/1274), `3790efb0d9c8`, and `458a6a5b3b01` identify repeated historical mutex exclusion defects. Current lazy guard construction compensates. |
| Close versus final release | [#506](https://github.com/asterinas/asterinas/issues/506), `c320552ae108`, `8600278a5f34`, and `e631da203c2c` distinguish descriptor removal, file lifetime, and safe cleanup context. This does not protect temporary owner drops inside the separate flock Mutex. |
| False shared-table diagnosis | [#3178](https://github.com/asterinas/asterinas/issues/3178) retracts the kernel CLONE_FILES allegation after identifying FD reuse in the test. It reinforces the OFD/FD distinction. |
| Queue growth with signal restart | [#3283](https://github.com/asterinas/asterinas/issues/3283) demonstrates growth and has maintainer acknowledgment. Exact counter wrap and the resulting missed wake were not demonstrated by that thread. Signals/resource exhaustion are excluded here. |
| Unsupported filesystem context | [#2579](https://github.com/asterinas/asterinas/issues/2579) concerns configfs, with confirmed correction. Current mandatory extensions and ordinary RamInode context are checked separately. Special files are excluded. |

### Fixed Linux comparison

Linux ramfs/tmpfs have no flock override in the supplied operations tables.
The generic syscall reaches `locks_lock_file_wait`
(`fs/locks.c:2174-2179`, `include/linux/filelock.h:420-423`).
`flock_make_lock` uses the file object as owner (`465-474`), and conflict
excludes the same file (`939-948`). Different owners are compatible only for
SH/SH (`886-893`). These are the fixture's identity and exclusion oracles.

For conversion, Linux removes an existing different-mode item at
`fs/locks.c:1101-1108`, then checks conflicts at `1118-1125` while retaining
the inode spinlock through `1137`. With allocation failure excluded, an
EX|NB conversion can return EAGAIN after removing its old SH. A same-mode
request returns without replacement at `1104-1105`. Successful conversion
does not imply a globally atomic upgrade contract, but this exact critical
section does not admit an invented third-party grant halfway through it.

Deletion wakes blocked requests (`866-870`), and a blocked operation invokes
the lock procedure again after waiting (`2079-2093`). Notification is not
ownership transfer. Close removes the FD before its synchronous reference put
(`fs/open.c:1574-1589`). Actual last-reference cleanup removes flock through
`__fput` (`fs/file_table.c:439-457,567-570`, `fs/locks.c:2641-2655,2685-2697`).
An in-flight reference can defer that cleanup, including task-work deferral
for ordinary fput (`fs/file.c:1153-1182`, `include/linux/file.h:60-64,83`,
`fs/file_table.c:515-542`). The reference source identity is not a claim that
the future control machine runs this Linux version.

## Phase 3: Deep analysis

### FL-SQ-1: conversion retention

**Observation.** Asterinas takes the list Mutex, finds a conflict, optionally
enqueues, and returns EAGAIN before reaching same-owner replacement
(`flock.rs:115-124`). Its old SH therefore remains present during a conflicting
EX request, both for NB and the blocking retry path (`144-155`). Neither the
syscall wrapper nor `InodeHandle::set_flock` removes it first
(`syscall/flock.rs:19-32`, `inode_handle.rs:228-234`).

**Sequential consequence predicted from source.** With independent A/B SH
owners, A's EX|NB returns EAGAIN. After B unlocks, an independent C EX|NB
still conflicts with A in Asterinas. Fixed Linux has removed A's old SH and
permits C. The first EAGAIN alone cannot distinguish the implementations.
The later third-owner probe is essential.

**Concurrent consequence to verify.** A's blocking EX conversion registers
on B while keeping A SH. B's blocking EX conversion can then register on A
while keeping B SH. If the finite fixture unlocks only after successful
conversion, neither call reaches that release. Linux's removal path lets a
converter proceed once both old SH locks have been removed. External alias
unlock or an additional release action would change this history and must be
declared rather than silently assumed.

**Disposition.** Source divergence established; Linux/Asterinas controls,
formal counterexample, and runtime consequence remain `NOT_RUN`.
FL-TV-1 and FL-MC-1 are two verification methods for this one mechanism.
It originated in `ce2af1eb0570` and is not the historical fixed lost-wake bug.
The reviewed code/discussions provide no accepted contract requiring old-mode
retention that would justify changing the fixed Linux oracle.

### FL-SQ-2: final temporary reference during unlock

**Observation.** A flock item stores a Weak owner (`flock.rs:14,29-35`).
`unlock` retains the list Mutex while its predicate calls `owner()`, whose
Weak upgrade returns a temporary Arc (`40-41,166-181`). Rust drops this binding
before the predicate returns and before the outer guard can be released.
The last Arc drop synchronously invokes `InodeHandle::drop`, which calls
`unlock_flock` and attempts the same list Mutex (`inode_handle.rs:237-248,537-541`).

| Step | Thread 1 | Thread 2 | B's strong references |
|---|---|---|---|
| Setup | A is independently open on the same inode. A need not own a flock. | B has one descriptor and holds a flock. | One descriptor. |
| Upgrade | UN(A) acquires the list Mutex and successfully upgrades B's Weak owner. | B's descriptor still exists. | Descriptor plus temporary owner. |
| Close | Retain predicate still owns the list Mutex and temporary B Arc. | Close removes B's FD, releases the table lock, then drops ClosedFile. | Only the temporary owner remains. |
| Last drop | Pointer comparison does not match A. Dropping temporary B decrements the last strong reference. | Close can finish without running B's destructor itself. | Zero; B's destructor begins on Thread 1. |
| Re-entry | B's destructor attempts `unlock(B)` while Thread 1's outer guard remains live. | No remaining action owns that guard on behalf of Thread 2. | Cleanup waits for its own unfinished outer continuation. |

OSTD's Mutex has no recursive-owner path (`ostd/src/sync/mutex.rs:30-70`).
It releases only when its guard drops (`113-116`). Notifications cannot turn
the still-held boolean false. The outer retain cannot finish until nested
destruction returns, and nested destruction cannot acquire the Mutex until
the outer guard is dropped. This is a source-derived self-dependency, not an
observed Asterinas deadlock or an artificial fault action.

**Compensation checked.** A's syscall lookup retains A rather than B.
B's stored item is Weak. ClosedFile cleanup runs outside the FD-table guard
and uses a separate range-lock RwMutex. There is no deferred temporary-owner
drop list. FlockItem Drop wakes queues but cannot unwind the enclosing Arc
destructor. InodeHandle field ordering retains the path through its destructor
(`inode_handle.rs:29-42`), while `FileCommon`'s later close notification
(`file_common.rs:91-94`) cannot release the outer flock guard.
Installed Rust `alloc/src/sync.rs:2132-2143,2850-2855,2896-2898,3299-3327`
supports the exact upgrade and last-drop transitions.

**Adjacent trigger.** A's own final object destructor also invokes the outer
unlock scan, even if A never owned a flock. Overlap with B's final close can
therefore enter the same mechanism through destruction rather than explicit
UN. This is not counted as another defect. Preserve final-destruction scans
in the base protocol instead of reducing final release to deleting one item.

**Disposition.** FL-MC-2 and FL-TV-2 retain this source-supported candidate.
Runtime proof needs the real last-reference window on SMP >= 2. Extra B aliases,
an in-flight B syscall, or logging that clones B would mask the proposed trigger.
A stalled watchdog without those observations is inconclusive.

### Compensated suspicions and explicit exclusions

| Suspicion or adjacent risk | Disposition and evidence |
|---|---|
| Release can occur between conflict detection and registration. | Rejected for list mutation: both require the same Mutex (`flock.rs:115-120,166`). |
| Expired-owner removal misses notification. | Rejected: retain(false) drops the item and invokes its wake-all destructor (`78-82,178-181`). |
| Replacing a mode forgets the old queue. | Rejected: assignment drops the old item (`124`), whose destructor wakes its queue. |
| A wake gives the lock directly to that waiter. | Rejected: the closure repeats `try_set_lock` (`147-155`); another blocker or winner can intervene. |
| The first SH owner's release must complete an EX contender. | Rejected: another SH item may remain. The contender registers on the next first conflict (`116-120`). |
| A pre-sleep wake is erased. | Rejected in the selected chain: retained wake bit, Acquire consumption, park recheck, and actual runqueue synchronization compensate. See the waiter source audit. |
| Closed or duplicate wakers consume a unique ownership grant. | Rejected: no grant exists in the notification. Closed/already-notified entries are skipped or coalesced (`ostd/src/sync/wait.rs:95-106,244-281`). |
| Repeated same-owner locking requires repeated unlock. | Rejected: replacement preserves one list entry, not a recursion count (`flock.rs:122-127`). |
| Closing one alias releases all aliases' flock. | Rejected: dup shares the Arc, and release follows final object destruction (`file_table.rs:181-187`, `inode_handle.rs:537-541`). |
| FD removal must abort a syscall that captured its file. | Rejected: the shared lookup owns an Arc across the call (`file_table.rs:355-360`). |
| A zero-strong-count list entry immediately proves a leak. | Rejected: final destruction may still be waiting for the list Mutex. Separate initiation from cleanup completion. |
| The production waiter times out and repairs any stall. | Rejected: flock uses pause_until with no timeout (`process/signal/pause.rs:40-45,128-168`, `time/wait.rs:170-206`). |
| Signal/restart queue growth can be recreated with a tiny wrapping counter. | Excluded: it violates the finite signal-free fixture and would repackage a known out-of-scope issue. |
| O_PATH, invalid flags/FDs, configfs, POSIX range-lock errors, and procfs exit races imply a flock defect here. | Excluded after caller/history review: the fixture uses valid ordinary opens, a stable inode, and no process exit or procfs observer. |
| Append/seek/mmap/per-open device risks in InodeHandle belong in this model. | Excluded after full file reading: those operations are outside the selected ownership protocol. |

One additional **code-review-only** concern is retained as FL-CR-1. A successful
request shares its queue with the installed item, and its destructor can call
wake_all outside the list Mutex (`flock.rs:69-82,124-157`). An awakened waiter
can re-enqueue against the still-held item while the drain continues
(`ostd/src/sync/wait.rs:119-131`). Repeated drain/retry work is possible. No
runtime livelock or violation of a promised completion bound was established.
The brief preserves this behavior and sends the concern forward for review,
without inventing another MC hunt or silently filtering the candidate out.

## Phase 4: Modeling and later evidence plan

[modeling-brief.md](modeling-brief.md) organizes the protocol into five scenarios,
with concrete state extensions and safety/conditional-progress obligations.
The two supplied source questions remain pending model/runtime verification.
OFD identity, alias release, in-flight capture, replacement/removal notification,
and changing-blocker retry remain required even with no additional finding.

### Required case matrix

Every row below is `NOT_RUN`. Expected outcomes are source-derived proposals.
Use fresh fixture state and record every syscall return and actual file/inode
identity. No row reports an executed Linux or Asterinas result.

| Case | Schedule and evidence | Source-based oracle/purpose |
|---|---|---|
| FL-C01 | Independent A/B SH, C EX\|NB, release both, retry C. | SH coexistence, incompatible exclusion, and successful later acquisition. |
| FL-C02 | A locks, dup to A2, repeat mode, UN(A2), independent probe. Also UN an unlocked OFD. | Alias identity, no recursive acquisition count, harmless unmatched unlock. |
| FL-C03 | A/A2 alias one EX owner. Close A, probe B. Close A2 with no other retaining reference, then probe. | First close preserves ownership; completed actual final release removes it. |
| FL-C04 | Sole-owner SH-to-EX and EX-to-SH. For downgrade, first observe a separate SH waiter's real registration. | Successful conversion and old-item Drop notification. Notification permits retry rather than granting. |
| FL-C05 | A/B SH, A EX\|NB fails, B UN, C EX\|NB before another A operation. | Fixed Linux predicts C success; pinned Asterinas source predicts C EAGAIN. Same conversion mechanism as C06. |
| FL-C06 | Observe A enter blocking SH-to-EX, then B convert. Each successful converter must release. | Test conversion-retention cycle without an external permanent blocker, signal, or arbitrary latency promise. |
| FL-C07 | Release the last conflict before the check/registration critical section in one run and after actual registration in another. | The contender either sees no blocker or receives a retained notification and retries. |
| FL-C08 | A/B SH, C waits for EX. Release its recorded first blocker, observe retry/register on the other, release that owner. | Migration between blocker queues, with no completion obligation after only the first wake. |
| FL-C09 | Two independent EX contenders wait behind one owner. Release it; let the first winner release. | Either winner is valid. The loser must retry; no FIFO claim. |
| FL-C10 | B captures its OFD and blocks behind A. Another thread closes B's final FD. A unlocks; B completes and drops its call reference. C probes after actual cleanup. | In-flight capture survives FD removal and may temporarily acquire without a remaining numeric FD. |
| FL-C11 | UN through independent A upgrades flock owner B. Close/drop B's last descriptor during that temporary-reference window. | Observe reference counts by events, outer guard, last temporary drop, destructor entry, and attempted nested lock. |
| FL-C12 | Repeat C11 with an extra B alias, close before upgrade, and close after the outer scan ends. | Negative controls isolate the exact temporary-last-reference window. Close retained aliases during controlled cleanup. |

Instrumentation must distinguish inode, OFD, numeric FD, operation entry/return,
file-reference capture/drop, list acquisition/release, conflict owner, queue
registration, item replacement/removal, accepted notification, retry, and final
destructor progression. The C11 logger must not obtain another strong B Arc.
Preserve incomplete traces and the instrumented-source identity. A userspace
barrier saying that a syscall is about to start does not prove registration.

SMP >= 2 and the actual reference/registration window are prerequisites for
runtime concurrency claims. Record the guest CPU configuration and observed
online CPUs. A host watchdog expiry, provider timeout, OOM, or missing trace
suffix alone is not a kernel defect. Record the actual Linux kernel and local
filesystem for controls, and reconcile its behavior with the fixed reference
before accepting any oracle change.

The initial model should use one inode, three independent OFDs, an alias, and
three threads, with a four-thread variant where the fixture requires an extra
controller. Bound operation counts, not the meaning of the u32 waiter counter.
Keep list ownership and per-operation PCs while reference operations interleave.
The model may abstract the proven scheduler bridge, provided the abstraction
retains pre-sleep notifications and does not grant ownership on wake. Such a
model is not a weak-memory or whole-scheduler proof.

Safety properties cover incompatible grants, unique owner items, stable captured
owners, and reference accounting. Progress properties require a finite fixture
whose surviving owners perform their promised releases and whose enabled
operations receive execution. There is no global fairness, FIFO, or wall-clock
completion promise. A recursive cleanup wait must be derived from the reference
transition and guard lifetime, not introduced as an arbitrary deadlock action.

### Resource and corrective-review handoff

The [resource policy](/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/resources.json)
governs later stages. Admission evidence recorded the actual controller-held
`new-analysis.lock` and this run's lock, rather than inferring ownership from
the existence of files ([admission-locks.json](analysis-evidence/admission-locks.json)).
The workers did not reacquire those locks or recursively launch a pipeline.
No heavy allocation was used in this analysis.

The controller must serialize heavy work with the shared heavy-stage lock.
TLC is limited to 4G and two workers, containers to two CPUs, 8g and 512 PIDs,
Cargo to two jobs, and the guest to 2G with SMP >= 2. Immediately before a
heavy stage, check host-visible MemAvailable: at least 6 GiB for TLC and
10 GiB for a kernel build. These are admission thresholds, not proof that the
later run cannot exhaust memory.

The corrective review gate applies before **every verification rerun** after a
semantic change to model/properties/configuration, TraceSpec/interpretation,
oracle/support assumptions, or harness/instrumentation. Preserve the prior and
proposed versions, exact hashes, diff, reason, and triggering evidence. An
independent reviewer must review that exact version and record identity,
hashes, material findings, and disposition. Close material findings before
rerunning affected trace/TLC and renewing validation review. The rule also
applies inside Phase 3 correction loops. Reviewers use the controller's
allocation and do not reacquire its lock.

If independent review is unavailable, return the preserved change/review request
and an incomplete status to the controller. Continue this same campaign when
the gate is closed. No such verification rerun or semantic repair occurred in
this analysis. The ordinary controller-run independent analysis review remains
the next acceptance step.

Machine-readable totals are in [coverage.json](analysis-evidence/coverage.json).
The audit artifacts retain source identities, complete discussion evidence,
per-commit classifications, and explicit exclusions. These source and history
results authorize a reviewable handoff, not a formal or runtime pass.

### Handoff consistency checks

Both source helpers independently read the main-authored 143-line brief at
SHA-256 `6b937de72bafad949007b37e526819b230a243fd25014600f8ce1263c7472c38`.
Their [ownership review](analysis-evidence/brief-review-ownership.md) and
[waiter review](analysis-evidence/brief-review-waiter.md) each record material
findings `[]`, reviewer identity, source checks, and the exact reviewed bytes.
The waiter review also records the concrete-PC obligations for `NoOrphanedRetry`
and the need to distinguish internal grant, request Drop, and syscall return.
These are internal handoff consistency checks, not the controller's separate
pipeline analysis review or approval of a model that does not yet exist.

Final source rechecking found the same commit, no tracked diff, and all thirty
contract file hashes unchanged. Local document links and cited commit prefixes
were checked. No parser, test, guest, or model-checking run is implied by these
document checks. [final-manifest.json](analysis-evidence/final-manifest.json)
records the final deliverable identities and evidence inventory.
