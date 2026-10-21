# Code analysis audit: asterinas-private-futex-requeue

## 1. Result and evidence boundary

The selected protocol is suitable for a bounded Category B model covering registration, requeue, wake, timeout and cleanup together. One ownership question, MC-1, connects original-bucket cleanup to a later live-waiter migration failure. Three independent sequential compatibility leads, TV-1–TV-3, cover zero wake quota, zero migration quota and return counts. CR-1 records the cleanup comment whose assumption fails after migration. These are source-backed candidates, not runtime-confirmed defects.

The [modeling brief](modeling-brief.md) is the Spec Generation handoff. It retains the complete protocol even if later checks find no new defect. The preparation was explicitly informed by prior assessment, and this analysis makes no blind-discovery or global-novelty claim.

| Item | Verified identity or status |
|---|---|
| Asterinas source | `0c60537098f4c2949ad2d382aaf499de72263d76` |
| Source tree | `4693fdec88cd7da14bed4f1541eba593f123059c` |
| Repository | `/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/source` |
| Linux reference | v6.16.5, `4645fefac0b24d509b962c096b0327e87f34b1d2` |
| Linux reference integrity | Five local futex files match raw upstream files at the fixed commit, byte for byte. See [hash evidence](analysis-evidence/linux-reference-integrity.json). This is source verification, not a Linux execution. |
| Working tree at entry | No tracked modification. An existing untracked `.codex/` directory was left in place. See [source identity](analysis-evidence/source-identity.json). |
| Executed here | The four code-analysis phases, read-only Git/GitHub/reference investigation, independent helper audits, document review and artifact checks. |
| NOT_RUN | Spec generation, harness/instrumentation, builds, guest tests, Linux syscall controls, trace validation, TLC, bug confirmation, severity classification and repair. |

The source and preparation inputs were not edited. All task outputs are confined to this run's `.specula-output`. No commit, publication, upstream issue or PR was created.

## 2. Method and resource policy

The methodology is the installed `specula-codex:code-analysis` 1.2.0 skill. `SKILL.md`, `guide.md`, shared deep-analysis, concurrent-analysis, bug-archaeology, modeling-brief-format, the complete example brief and persistent-findings guidance were read. Category B was recorded before archaeology: this is thread handoff, notification and ownership transfer under shared-memory locks. Category A and BFT references do not apply.

Phase 1 mapped modules and synchronization. Phase 2 followed renamed core files, screened all resulting commit messages, investigated every selected repair and relevant behavioral change, and verified issue discussions concurrently. Phase 3 fully read each core file and independently checked candidate paths and compensations. Phase 4 grouped findings by mechanism and reviewed the actionable brief with both helpers.

The [resource policy](/home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/resources.json) was read before substantive tool work. At most two source-analysis helpers were active. No heavy stage was launched, so no heavy-stage lock was acquired by this worker. The receiving controller retains phase-transition and lock ownership. Later stages must check host-visible MemAvailable immediately before starting, with at least 6 GiB for TLC or 10 GiB for a kernel build, and respect the policy's 4 GiB/2-worker TLC, 8 GiB/2-CPU/512-PID container, 2-job build and SMP >= 2/2 GiB guest limits.

The supplied persistent-findings context has no previous output and no inherited records. Before deeper candidate investigation, this lookup returned `[]`:

```text
/home/chin39/Documents/play/Specula/.venv/bin/specula findings --work <this .specula-output> lookup --query futex_requeue --query remove_by_waker --query max_nrequeues --query pause_timeout
```

There was no matching historical record to reuse or check. No incomplete investigation was registered as a completed finding. Absence from this empty context is not evidence of novelty.

## 3. Phase 1: structural and atomicity map

All source line references below are at the pinned Asterinas revision. Aliases `F`, `S`, `P`, `W`, `TW`, `T` match the brief. `L/` refers to the fixed Linux `kernel/futex/` directory.

| Core file, read in full | Lines | Relevant responsibility |
|---|---:|---|
| `kernel/core/src/syscall/futex.rs` (`S`) | 151 | Dispatch, signed count interpretation, timeout construction and errno translation. |
| `kernel/core/src/process/posix_thread/futex.rs` (`F`) | 732 | Private identity, locked registration, pair locks, wake/movement and original-bucket cleanup. |
| `kernel/core/src/process/signal/pause.rs` (`P`) | 311 | Futex's single-shot pause path and timer-result decision. Signals were read to delimit the path and remain excluded. |
| `ostd/src/sync/wait.rs` (`W`) | 400 | Notification acceptance, flag consumption, closure and task ownership. |
| `kernel/core/src/time/wait.rs` (`TW`) | 245 | Managed relative timeout, initial expiry check and timer creation. |
| `kernel/core/src/time/core/timer.rs` (`T`) | 306 | Deadline, cancellation, callback delivery and weak/strong ownership. |
| Total | 2,145 | Includes comments, tests and out-of-scope branches read to check boundaries. |

The syscall and futex files account for 883 lines. Adjacent reads were limited to establishing this protocol: `context.rs:143` forwards atomic reads, `process/posix_thread/thread_local.rs:102–135` disables faults and returns a retry indication, `process/process_vm/mod.rs:193–214` defines weak VMAR identity, `ostd/src/mm/io/mod.rs:548–576` documents per-location atomicity, `ostd/src/sync/spin.rs:72–118` establishes Acquire/Release locking, and `ostd/src/task/scheduler/mod.rs:441–493` plus the enqueue implementation establish the parking boundary. No general scheduler, signal, VM or timerfd campaign was performed.

| Boundary | Source and effect | Permitted interleaving |
|---|---|---|
| Syscall preparation | `S:37–83` reads a timeout, selects monotonic time and constructs `Timeout::After`. `S:105–109` separately converts wake/move counts. | This occurs before a bucket lock and before enqueue. |
| Identity and bucket selection | `F:590–594,635–639,653–674` uses weak VMAR identity plus address. `F:390–391,450–454` derives CPU-dependent bucket count and masks the hash. | Identity remains stable by scope. Different addresses do not establish different buckets. |
| Compare and register | `F:83–117` holds the original bucket across load, comparison and enqueue. Mismatch exits without publishing the item. | User stores can occur during the lock interval, but matching WAKE cannot pass it. |
| Fault retry | `F:86–104` disables fault handling, releases the lock on a recoverable fault, resolves it, then repeats the locked load. | Updates/wakes may occur during fault resolution. The old load cannot be reused. |
| Wake-before-park | `F:117–119`; `W:195–200,272–275` retain and consume a notification even before the waiter actually parks. | Timer or futex wake can precede the call to `wait`. |
| Pair locking | `F:404–427` locks lower bucket index first, or one lock when indices coincide. | Opposite-direction operations serialize. No bucket mutation is modeled outside its guard. |
| Wake and migration | `F:366–379,485–533` holds the lock set through accepted wakes and entry movement. | Timer and notification actions on another CPU can still advance between per-entry steps. |
| Timer completion | `P:171–208` arms the same waker, consumes a wake, then checks remaining time/cancels under the timer lock. | Clock expiry, callback extraction, callback wake and waiter consumption are separate events. |
| Cleanup and closure | `F:124–139` searches the captured original bucket by Arc identity. `W:244–281` closes the waiter on drop. | A destination-bucket entry may survive a cleanup miss. Close does not unlink it. |

The private key retains a `Weak<Vmar>`, not a strong VMAR owner. The global bucket owns a `FutexItem`, which owns `Arc<Waker>`, which owns `Arc<Task>` (`F:384,434–474,537–539`; `W:174–177`). A timer owns its closure and a cloned waker. The callback heap owns callback objects containing only `Weak<Timer>` (`T:33–42,234–281`). These are separate resource ledgers.

## 4. Phase 2: archaeology coverage

### 4.1 Collection and deep-reading totals

| Work | Coverage |
|---|---|
| Git availability | The standalone repository is not shallow. All local refs were searched, with `--follow` for each core file to include historical directory names. |
| Commit messages screened | 142 unique commits across six followed histories. |
| Full selected core patches analyzed | 54, comprising 28 functional repair/mitigation commits, one adjacent robust-futex repair, one test-tooling repair and 24 feature/refactor/performance/documentation/mechanical changes. All 54 are ancestors of the pin. |
| Issue collection | Eight keyword/label searches yielded 83 unique issue records. |
| Issues deeply read | 33 complete bodies and all 98 comments, split across two concurrently active helpers. |
| Discussion classifications | 16 confirmed or acknowledged bug records, 3 design limitations/gaps, 2 uncertain reports, 2 disputed/false reports and 10 feature/tooling discussions. These are records, not counts of independent current defects. |
| Issues not deeply read | 50 collected records, including #3920. They are not evidence for a current finding. Scope exclusions are not counted as false positives. |
| Closed PRs deeply read | 27 complete bodies, 61 issue-style comments, 157 submitted review records and 271 inline review comments. |
| Open PR scope review | All 109 current open PRs were screened by metadata and complete changed-file lists. A broad title/body keyword filter retained 74 potential bug-intent records for scope triage. |
| Open core-touch PRs deeply read | All three: #3576, #3024 and #2615. Their complete bodies, 4 issue-style comments, 8 review records and 8 inline comments were read, along with all core-file patches. |
| Total deeply read PRs | 30, with 65 issue-style comments, 165 review records and 279 inline comments. |

Issue queries were `futex` (28), `waiter` (17), `requeue` (0), `pause_timeout` (2), and label `C-bug` combined separately with `race` (17), `timeout` (18), `wake` (14), `deadlock` (13). Counts overlap. The full [unique issue list](analysis-evidence/issues-collected.json) and individual `issues-*.json` preserve the collection. Additional all-state PR queries were `futex` (50), `requeue` (5), `pause_timeout` (6) and `Waiter` (55). Those are collection counts, not claims that every result was deeply read.

The 30-plus issue target was met with individual relevant and adjacent discussions. The large omnibus #3920 was downloaded but not deeply read. No novelty or defect conclusion is inferred from its contents. Unrelated allocator, network, storage, signal and malformed-pointer records were not expanded into new campaigns. The live upstream sweep is dated 2026-10-04 and does not change the analysis source pin.

### 4.2 Commit coverage and hotspot accounting

The [complete screened history](analysis-evidence/history-all.json), [selected patch ledger](analysis-evidence/commit-audit.json), per-file `history-*.txt`, and `commits/*.patch` make the selection reproducible. Searches included fix, bug, race, panic, deadlock, correctness, crash, corrupt, leak, inconsistent and wrong, in full commit messages. Semantic inspection added count conversion, vector migration, fault retry, ownership and timer changes without those keywords. This was not a sample of keyword hits.

Selected-patch occurrences by followed file are F 26, W 15, P 13, T 8, S 7 and TW 6. A commit may touch several files. This makes futex bookkeeping and waiter completion the main hotspots; it does not assign likelihood from file size. Appendix A classifies every selected commit. Its qualitative severity describes the historical failure mode for archaeology, not a Phase 4 verdict on this campaign's candidates.

### 4.3 Verified issue decisions

Every issue cited as evidence below was read with `gh issue view --comments` plus REST metadata and all paginated comments. Downloaded comment counts were checked. Full roots, fix identities and evidence are in [the futex helper audit](analysis-evidence/helper-futex.md) and [the waiter helper audit](analysis-evidence/helper-waiter.md).

| Issue | Verified disposition | Meaning for this campaign |
|---|---|---|
| [35](https://github.com/asterinas/asterinas/issues/35) | Acknowledged old design limitations. | Current atomics and identity supersede the old premises. |
| [981](https://github.com/asterinas/asterinas/issues/981) | Confirmed non-atomic futex load, fixed by #2306. | Preserve current atomic comparison and retry. |
| [1179](https://github.com/asterinas/asterinas/issues/1179) | Confirmed syscall unwrap panics, fixed by #1181. | Invalid operation/count fuzzing is excluded. |
| [1334](https://github.com/asterinas/asterinas/issues/1334) | Confirmed inaccessible-read panic, fixed by #1337. | Current fault retry supersedes its old errno choice. |
| [1381](https://github.com/asterinas/asterinas/issues/1381) | Reproduced test hang but uncertain cause. | No current lost-wake or requeue root cause is established. |
| [1587](https://github.com/asterinas/asterinas/issues/1587) | Confirmed stale wake-count problem, fixed by #1642. | Current rejected wakes do not consume wake quota. Migration ownership remains a different question. |
| [1641](https://github.com/asterinas/asterinas/issues/1641) | Acknowledged hash-distribution limitation, fixed by #2339. | Bucket collisions remain necessary controls, not identity equality. |
| [2393](https://github.com/asterinas/asterinas/issues/2393) | Acknowledged known completion race, tied by maintainer to #2515. | Stale closure alone is not fix evidence. |
| [2805](https://github.com/asterinas/asterinas/issues/2805) | Confirmed robust-list alignment assertion, fixed by #2806. | Robust lists/exit/unaligned words are excluded. |
| [3209](https://github.com/asterinas/asterinas/issues/3209) | Uncertain CI-output/test-marker failure. | A futex name in output does not establish causation. |
| [3882](https://github.com/asterinas/asterinas/issues/3882) | Acknowledged LoongArch fallible-load contract issue, open. | Unmapped-memory UB is outside scope. The upstream report itself did not run Asterinas. |
| [3881](https://github.com/asterinas/asterinas/issues/3881) | Acknowledged LoongArch fallible-copy contract issue, open. | Generic invalid-user-copy is excluded. |
| [3903](https://github.com/asterinas/asterinas/issues/3903) | Acknowledged related CAS concern, closed as duplicate. | Duplicate closure is neither a fix nor a false-positive verdict. |
| [2188](https://github.com/asterinas/asterinas/issues/2188) | Confirmed WAKE_OP shift overflow, fixed by #2190. | WAKE_OP is excluded. |
| [1329](https://github.com/asterinas/asterinas/issues/1329) | Confirmed robust-list arithmetic overflow, fixed by #1757. | Robust lists are excluded. |
| [1391](https://github.com/asterinas/asterinas/issues/1391) | Confirmed robust-list unwrap panic with identified fix. | Exit teardown is excluded. |
| [3283](https://github.com/asterinas/asterinas/issues/3283) | Acknowledged stale WaitQueue entries in file-lock callers, open. | Related resource mechanism, not proof about FutexBucket. |
| [1261](https://github.com/asterinas/asterinas/issues/1261) | Explicit false positive after considering closure and skipped wakes. | Keep the compensation. |
| [831](https://github.com/asterinas/asterinas/issues/831) | Confirmed memory-order problem, fixed by #896. | Do not weaken current atomics to recreate it. |
| [298](https://github.com/asterinas/asterinas/issues/298) | Refactoring discussion, no independent bug proof. | Identity bookkeeping context only. |
| [1497](https://github.com/asterinas/asterinas/issues/1497) | Explicit false lost-wakeup/atomic-handoff claim. | Enqueue/recheck ordering and permitted spurious wakes answer it. |
| [1483](https://github.com/asterinas/asterinas/issues/1483) | Confirmed broader atomic-mode misuse family, open. | Inspect unlocked fault resolution, not a general lock audit. |
| [1048](https://github.com/asterinas/asterinas/issues/1048) | Redis/SQLite feature tracker. | Old timeout checkboxes do not describe current source. |
| [1888](https://github.com/asterinas/asterinas/issues/1888) | Go feature tracker. | No isolated futex race mechanism. |
| [1867](https://github.com/asterinas/asterinas/issues/1867) | Spark feature tracker. | No isolated futex race mechanism. |
| [1851](https://github.com/asterinas/asterinas/issues/1851) | Docker tracker explicitly described as outdated when closed. | No current private-futex defect follows from its checkbox. |
| [2112](https://github.com/asterinas/asterinas/issues/2112) | GUI feature tracker. | Its futex extension is excluded WAKE_OP. |
| [703](https://github.com/asterinas/asterinas/issues/703) | Container feature tracker, superseded. | Workload motivation only. |
| [1511](https://github.com/asterinas/asterinas/issues/1511) | Confirmed metadata panic with identified fix. | Futex frames in logs do not make it a futex defect. |
| [691](https://github.com/asterinas/asterinas/issues/691) | Profiler tooling discussion. | Futex backtrace names are not defect evidence. |
| [2214](https://github.com/asterinas/asterinas/issues/2214) | Podman feature tracker. | Futex time in a profile is not a correctness finding. |
| [1578](https://github.com/asterinas/asterinas/issues/1578) | Acknowledged restart design gap, later closed. | Signals/restarts are excluded. The disputed CI attribution is not reused. |
| [2](https://github.com/asterinas/asterinas/issues/2) | Early feature plan. | No bug evidence. |

### 4.4 Open and closed PR interpretation

The full [open snapshot](analysis-evidence/open-prs.json) pins each head OID. [Complete changed-file lists](analysis-evidence/open-pr-file-map.json) were retrieved for all 109 entries, including the 1,655-file stale-base diff in #3024. [Broad bug-intent matches](analysis-evidence/open-pr-bug-intent.json) are scope-triage input, not 74 verified bugs. PRs outside the bounded subsystem were excluded by changed paths and subject matter. Their correctness and full discussions were not audited or used as findings.

All open PRs touching the six core files, including historical paths, received full discussion and relevant patch review:

| PR and head | Verified scope and dedup decision |
|---|---|
| [3576](https://github.com/asterinas/asterinas/pull/3576), `8e02d0e94230b9021b3f1d937664ba236b3e6832` | Changes syscall restart/error policy and prevents restarting a timed interrupted WAIT. No current-owner pointer, quota or move-count repair appears in the core diff. Its signal scenario is excluded. |
| [3024](https://github.com/asterinas/asterinas/pull/3024), `8abacee524b2a5281c1a22f52185e6884dfcbfff` | Seccomp prototype with a large stale-base diff. Futex changes include existing identity fixes already in the pin, not a fresh fix for the four leads. |
| [2615](https://github.com/asterinas/asterinas/pull/2615), `8d8d0452004b96d0c14552f1e479b11abdd59ff4` | CortenMM changes only shared-mapping key lookup in the futex core hunk. Private stable-address scope is unaffected by that hunk. |

The 27 deeply read closed PRs are enumerated with conclusions in the helper audits. Key decisions were #2306's intentional locked atomic retry, #2377's explicit dequeue/drop obligation, #2515's cleanup-based wake precedence, #3053's full identity equality, and #2526's callback-specific cancellation recheck. Rejected #2405/#2409 wake-reason implementations are not current-source defects. Closed fixes serve as mechanism evidence, not instructions to revert working defenses.

## 5. Phase 3: Linux comparison and current findings

### 5.1 Reference calibration

`L/syscalls.c:108–109` sends ordinary REQUEUE directly to `futex_requeue` with `cmpval=NULL` and `requeue_pi=0`. `L/requeue.c:584–610` checks the combined budget before processing an entry, increments `task_count` for either plain wake or requeue, and line 691 returns it. Same-address rejection at `L/requeue.c:402–410` applies to PI requeue, which is excluded. Plain same-address requeue can count an entry without physically changing its key/bucket.

The current [REQUEUE manual](https://man7.org/linux/man-pages/man2/FUTEX_REQUEUE.2const.html), inspected as man-pages 6.19, describes only the wake count. It conflicts with the selected implementation. The implementation pin controls the versioned prediction, and later testing must record the actual Linux control kernel. No source pin is substituted for runtime identity.

Linux ordinary WAKE increments its count after waking, before checking the supplied limit (`L/waitwake.c:180–193`), which explains its legacy zero-count behavior. Plain REQUEUE checks its own budgets first. Applying the WAKE exception to REQUEUE is not justified by that source.

The [WAIT manual](https://man7.org/linux/man-pages/man2/FUTEX_WAIT.2const.html) supports atomic compare/wait, relative timeout and conservative handling of successful returns as spurious. Therefore success alone does not identify a targeted wake or establish the user predicate. Wake/timeout overlap is interpreted with operation history and ownership. Linux unqueues through the current lock pointer and lets actual wake removal win (`L/core.c:921–963`; `L/waitwake.c:689–701`).

### 5.2 MC-1: Original-owner cleanup and a later live migration

**Observation from source:** WAIT captures `futex_bucket_ref` at `F:79`, registers under that lock, and reuses exactly that reference at `F:124`. Cross-bucket REQUEUE extracts and appends the same item at `F:520–533`. It does not publish a current-owner pointer back to the waiter. The saved-bucket lookup can miss while the destination owns the registration. That miss forces success even when `pause_timeout` returned expiry (`F:124–139`).

**Ownership consequence predicted by source:** Drop closes the waker without unlinking the FutexItem (`W:244–249,278–281`). The retained entry owns a strong waker/task reference. A later WAKE rejects and retains it (`F:488–494`). Both migration helpers nevertheless count it toward migration (`F:503–505,523–525`). A whole-source symbol search and all bucket methods reveal no deferred futex entry reaper.

**Reclamation obligation:** `F:121–123`, retained from `888eecb3509d` and confirmed in #2377's discussion, expressly requires timed-out/interrupted registrations to dequeue and drop. This supports an ownership check after all relevant in-flight steps drain. It does not require vector capacity shrinkage, disappearance of weak canceled timer heap nodes, or immediate release of a callback currently executing on another CPU.

**Bounded candidate history, not an executed trace:**

| Step | Required evidence and predicted effect |
|---|---|
| 1 | Prove two enrolled waits at A and distinct actual buckets for A/B. REQUEUE A→B(1,1). Name the observed woken generation `a0` and moved timed generation `x`. Do not infer FIFO selection. |
| 2 | Let `x` expire with no destination wake. Prove original-bucket cleanup miss, return and closure. Asterinas predicts a retained closed entry at B. Linux current-owner cleanup removes it. |
| 3 | After `x` completes, enroll two fresh untimed generations `y,z` at B. Prove vector order with old `x` ahead, and that both live waits are notification-free when the next REQUEUE holds its locks. |
| 4 | REQUEUE B→A(1,1). The closed `x` is skipped by WAKE, one live waiter is woken, then `x` consumes the move quota, leaving the unwoken live waiter on B. |
| 5 | WAKE A(1) predicts zero accepted wakes in Asterinas. Linux's corresponding settled history has moved the remaining live waiter to A, so its wake is reachable there. WAKE B supplies the complementary control. |

Four WAIT generations and at least four control invocations cover this history. The initial move must not use one waiter with REQUEUE(0,1), because TV-1 would wake it instead of moving it. The resulting live-key/wake difference is stronger than internal retention and does not depend on a memory-exhaustion or watchdog experiment. A maximum-only migration invariant is insufficient. Use the guarded live-population exhaustion property in the brief.

**Compensations and limits:** Same-bucket movement still permits Arc-identity cleanup. Moving back before cleanup also restores reachability. An accepted destination wake removes the item. Closure prevents a later accepted wake on the completed generation. Return success after expiry alone remains allowed as spurious and is not the finding. #1587's rejected-wake quota bug is fixed and does not establish this movement consequence. No runtime progress defect or independent second defect is claimed.

### 5.3 TV-1: Zero wake quota is changed by syscall conversion

`S:106` calls the helper at `S:146–150`, so REQUEUE's raw wake zero becomes one. With one enrolled waiter, REQUEUE(0,1) predicts one wake and no move in Asterinas, versus one move and no wake in Linux. Both can return one, so the return value alone is insufficient. REQUEUE(0,0) predicts an unwanted wake when a matching eligible entry exists. Same-bucket zero-move behavior can additionally interact with TV-2 when more entries remain.

This is a deterministic source lead requiring separate F05 controls against actual Linux. Negative counts and unsigned values outside the nonnegative signed-int quota domain are not investigated. The legacy WAKE(0) behavior is a separate valid control.

### 5.4 TV-2: Same-bucket zero migration processes an entry before checking zero

`F:500–510` mutates a matching entry and increments its counter before `count >= max_count`. With migration zero, the first remaining bucket entry is retagged if it matches. An unrelated first entry causes immediate exit without a move. `F:521–528` checks the limit before cross-bucket extraction and moves nothing at zero.

Use positive wake quota to isolate this lead: enroll two matching source waits, REQUEUE(1,0), then inspect destination and source wake effects. Repeat with distinct keys in one bucket and different buckets. Add an unrelated first remaining bucket entry as a negative control. This is a sequential path inconsistency, not evidence that the ordered pair locks fail.

### 5.5 TV-3: REQUEUE returns only its wake subtotal

`F:368` obtains `nwakes` and `F:381` returns it after migration. For two enrolled waiters and REQUEUE(1,1), source predicts one accepted wake plus one move but return one, whereas pinned Linux returns two. Separate this count from TV-1/TV-2 and MC-1.

At equal addresses, `F:353–354` delegates to WAKE. Linux plain requeue processes an additional eligible entry against the same key and counts it even without physical movement. Treat that as TV-3's same-address control, not a claim that an entry must migrate to a different bucket when both keys are equal.

### 5.6 CR-1 and the accepted-wake accounting boundary

The comment at `F:125–129` equates absence in the original bucket with asynchronous wake removal. Requeue supplies another reason for absence, so this assumption needs downstream audit alongside MC-1. It does not independently establish an incorrect user-visible successful return.

The timer and futex both call the same `Waker`. Its flag is consumed by `do_wait` (`W:273`). Timer wake can return true, the waiter can consume it, and a subsequent futex wake can also return true before drop. Exactly-once completion therefore counts logical syscall completion and final removal, not all accepted waker calls. After close, there is no further consumer and every later wake rejects (`W:262–281`).

## 6. Explicit exclusions and refuted suspicions

| Suspicion or tempting property | Why it is excluded or narrowed |
|---|---|
| Current WAIT compares outside the lock. | `F:83–117` contains locked load, comparison and enqueue, including reload after fault resolution. |
| A wake before actual parking is necessarily lost. | The pending flag and scheduler runqueue coordination preserve it (`W:262–275`; scheduler `mod.rs:453–470`). |
| Equal hash/bucket means equal private key. | Full VMAR/address identity is checked at `F:653–674`. |
| Opposite-direction REQUEUE deadlocks by reversing locks. | `F:414–424` acquires increasing bucket indices in both directions, and equal indices acquire once. |
| Completed retained entries necessarily consume WAKE quota. | Closure makes wake reject, and `F:489` increments only on acceptance. The current concern is migration quota. |
| One generation may have at most one accepted timer-or-futex wake. | Consumption resets the flag before closure. Multiple accepted notifications can precede one syscall completion. |
| Every successful WAIT proves a targeted wake or a true predicate. | Spurious success is permitted. Require an ownership or later-operation consequence. |
| Every ETIMEDOUT rolls back the preceding REQUEUE. | Timeout ends that WAIT only. Earlier completed operations retain their effects. |
| Canceled timer heap retention proves a leaked waker. | The callback holds a weak Timer pointer and pruning is deferred. A running callback can transiently retain the Timer. |
| Timer cancellation after heap extraction has no recheck. | `T:267–271` locks and checks the callback's own canceled flag before executing it. #2526's contrary review concern was explicitly retracted. |
| An empty-source cleanup miss always proves successful wake. | Cross-bucket migration invalidates that internal inference, but successful WAIT alone remains inconclusive. |
| A host watchdog proves a kernel deadlock. | Scheduling, trace completeness and external resource limits must be separated from kernel progress. |
| #1381/#3209 establish the new mechanism. | Neither discussion identifies this current ownership path. |
| Closed #3903 was fixed or debunked. | It was closed as a duplicate. |
| Historical repairs should be reverted in the model to get counterexamples. | Current locks, identity equality, wake closure, memory orders and timer rechecks remain intact. |

The explicit boundary excludes PI, CMP_REQUEUE, robust lists, WAITV, WAKE_OP, selective bitsets, CLOCK_REALTIME, signals/restarts, fork/exec/exit, clear-child-tid, shared VMO identity, remapping, malformed pointers and OOM. Adjacent code was read only to establish completion/ownership of the selected stable private protocol. AST-48/49/50 are outside this run and were not imported as evidence at this pin.

## 7. Phase 4: modeling and trace handoff

The brief selects four mechanism scenarios, five implementation extensions and source-backed properties. MC-1 combines cleanup ownership and the later live-waiter effect so they do not become duplicate defect counts or unrelated hunt targets. TV-1–TV-3 remain visible as separate sequential controls. CR-1 remains a code-review item even though it explains MC-1 rather than a separate defect. A no-new-finding result still completes a useful bounded protocol analysis.

The model must preserve separate original/current bucket state, actual lock ownership, current keys, pending notification, closure and generation identity. A requeue operation keeps its lock set while its wake and migration phases may interleave with timer and waiter steps. If extraction/append is split, the operation temporarily owns the extracted entry. An implementation model must not substitute Linux's current-owner cleanup or normalize Asterinas's quota/count discrepancies.

Registration-only wake checks exclude competing waiters, predicate restoration, intervening requeue and timeout/removal. Full histories may legally contain those events. The live migration property applies to distinct keys with two eligible, notification-free live waits observed under the target requeue locks immediately before its wake phase. It requires reaching the destination key, allowing same-bucket retagging. Same-address processed counts use a separate property. Quiescent resource assertions wait for current operations and running callback references to drain, and do not require vector capacity shrinkage.

| Case | Design and oracle | Status |
|---|---|---|
| F00, added registration control | Order atomic store before WAKE while WAIT registers or fault-retries. Capture the locked comparison/enqueue and exclude timeout/migration/predicate restoration. | NOT_RUN |
| F01 | Mismatch must return EAGAIN, publish no registration, and yield no subsequent accepted wake. | NOT_RUN |
| F02 | Enrolled WAIT then WAKE(1): one accepted removal and one logical completion. Add separate WAKE(0) calibration. | NOT_RUN |
| F03 | Two enrolled waits, REQUEUE(1,1), same/different buckets: record wake, move and return separately. | NOT_RUN |
| F04 | REQUEUE(1,0), both bucket cases and unrelated-first-entry control: zero-move oracle independent of FIFO promises. | NOT_RUN |
| F05 | REQUEUE(0,1) and (0,0): distinguish effects even when count matches. | NOT_RUN |
| F06 | Same-address REQUEUE with positive wake and another eligible wait: unchanged key, Linux processed count, Asterinas shortcut. | NOT_RUN |
| F07 | Proved migration then expiry without destination wake, in same/different buckets: inspect owner, cleanup, closure and later wakes. | NOT_RUN |
| F08 | Destination wake versus expiry after migration: capture both permitted winners and their cleanup histories. | NOT_RUN |
| F09 | Four-generation retained-entry history in §5.2, including migration back and wakes at both keys. | NOT_RUN |
| F10 | Concurrent opposite-direction requeues with positive quotas and proved source enrollment: inspect lock order and serialized ownership. | NOT_RUN |

Use raw syscalls, ordinary stable aligned atomic words and SMP >= 2. Record actual CPU count and bucket indices. User readiness before WAIT is not enrollment proof. The harness must observe enqueue and movement under the production locks without substituting synchronization. Trace syscall inputs/returns, generation IDs, private key, locks, compare result, enqueue, accepted/rejected wake with its actor, wake-flag consumption, migration old/new identity and owner, deadline/expiry/callback/cancel, cleanup lookup/removal and closure. Preserve per-thread and lock-derived order, not a guessed timestamp total order. Missing events, unreached schedules and external timeouts remain coverage gaps.

Finite initial bounds are three keys, two buckets, four WAIT generations, two reusable controller actors and at least four control-call generations for F09, with quotas 0–2. Recoverable faults are finite and must reload. Timer/scheduler fairness and finite competing operations are explicit assumptions for conditional progress. None of these bounds is a universal proof. Before execution, the receiver must choose trace hooks, identify its actual Linux kernel and apply the resource gate. Those are later-phase work, not blockers to this source-analysis handoff.

## 8. Evidence index and review closeout

- [Modeling brief](modeling-brief.md) contains the seven required sections in 158 lines at initial completion.
- [Futex helper audit](analysis-evidence/helper-futex.md) contains the 16 issue/16 PR classifications and complete candidate-path review. Its [coverage file](analysis-evidence/helper-futex/coverage.json) checks discussion counts.
- [Waiter helper audit](analysis-evidence/helper-waiter.md) contains 17 deeply read issues, 11 PRs, 18 historical patches, full waiter/timer reading and lifecycle compensations.
- [Source identity](analysis-evidence/source-identity.json), [reference integrity](analysis-evidence/linux-reference-integrity.json), [all history](analysis-evidence/history-all.json), [commit audit](analysis-evidence/commit-audit.json), [issue collection](analysis-evidence/issues-collected.json) and [open PR snapshot](analysis-evidence/open-prs.json) preserve the evidence boundaries.
- `analysis-evidence/commits/`, `helper-futex/`, `helper-waiter/`, `open-pr-files/` and `open-pr-discussions/` retain raw source patches and full discussions. These files are evidence, not executed test logs.

Both helpers reviewed the completed brief. Their actionable corrections were incorporated: F09 needs reusable controllers and enough call generations; registration-only wake properties must exclude legal timeout/movement histories; and live migration exhaustion requires distinct keys and eligibility established under the requeue locks. Artifact checks verify the required sections, local evidence links, source identity and complete selected-commit annotations. No product tests or formal validation are represented by these document checks.

## Appendix A. Complete selected-commit audit

Every row links the inspected core-file patch. Functional fixes are distinct from mechanical keyword matches. The related component identifies the protocol mechanism rather than asserting a new defect in that file. Current-source compensations and excluded mechanisms are described in §§3–6 and the helper audits.

| Commit | Kind | Historical severity | Component and root-cause assessment |
|---|---|---|---|
| [2cc52e79d3ea](analysis-evidence/commits/2cc52e79d3ea.patch) | Fix | Low | Dispatch: Unsupported operations returned EINVAL instead of ENOSYS; malformed operations are excluded. |
| [55ad5d91f0e5](analysis-evidence/commits/55ad5d91f0e5.patch) | Fix | High | Identity: Hash-only or address-only matching could target unrelated waits; full private identity now compensates. |
| [860bb6c07f0a](analysis-evidence/commits/860bb6c07f0a.patch) | Fix | Medium | Dispatch: Count/type cleanup introduced the current REQUEUE zero-wake conversion; no intentional exception was found. |
| [46708f84bc0d](analysis-evidence/commits/46708f84bc0d.patch) | Feature | n/a | Identity: Added private process namespace and the WAKE zero-count compatibility behavior. |
| [70505ff4f85f](analysis-evidence/commits/70505ff4f85f.patch) | Feature | n/a | Timeout: Introduced futex relative timeout, clock selection and ETIMEDOUT translation. |
| [cf30599729ed](analysis-evidence/commits/cf30599729ed.patch) | Fix | High | Dispatch: An outer unwrap panicked on propagated futex errors; changed to error propagation. |
| [4c1f6a4e321e](analysis-evidence/commits/4c1f6a4e321e.patch) | Fix | High | Dispatch: Invalid operation, timeout and count errors were unwrapped; propagation replaced panic sites. |
| [c470d1dfb45d](analysis-evidence/commits/c470d1dfb45d.patch) | Fix | Medium | WAKE_OP: ANDN complemented the wrong operand; corrected outside this campaign. |
| [bc230b24e1f9](analysis-evidence/commits/bc230b24e1f9.patch) | Mechanical | n/a | Documentation: Fixed reference syntax and a renamed timer API link; no protocol change. |
| [545efaa15516](analysis-evidence/commits/545efaa15516.patch) | Adjacent fix | High | Robust futex: Robust-list alignment panic was fixed outside scope; the selected core hunk only corrects a typo. |
| [fc9f47a0191c](analysis-evidence/commits/fc9f47a0191c.patch) | Mechanical | n/a | Alignment: Replaced modulo spelling with is_multiple_of without changing the alignment contract. |
| [43f50c5e2a96](analysis-evidence/commits/43f50c5e2a96.patch) | Fix | Medium | Completion: Cleanup by waker determines wake precedence over timeout/signal; the original-bucket assumption remains relevant. |
| [52ddbeaff87a](analysis-evidence/commits/52ddbeaff87a.patch) | Refactor | n/a | Ownership: Arc identity replaced a global ID, and rejected wakes began remaining in the vector; relevant to the current retained-entry consequence. |
| [f0935beb183f](analysis-evidence/commits/f0935beb183f.patch) | Refactor | n/a | Locking: Extracted shared ascending-index pair locking while preserving both lock guards. |
| [888eecb3509d](analysis-evidence/commits/888eecb3509d.patch) | Fix | High | Cleanup: Timeout/signal left registrations retained; added unique-ID cleanup and explicit reclamation intent. |
| [91351e338fcb](analysis-evidence/commits/91351e338fcb.patch) | Fix | Low | Hashing: Address division caused poor bucket distribution; corrected and later replaced by jhash. |
| [5b9106431611](analysis-evidence/commits/5b9106431611.patch) | Fix | High | Registration: Fault resolution under a bucket spinlock could sleep; disabled faults, unlocked resolution and locked retry compensate. |
| [e4fafb13b16b](analysis-evidence/commits/e4fafb13b16b.patch) | Fix | High | Registration: Byte-copy loads and non-atomic WAKE_OP updates lacked atomicity; added fallible atomics and alignment checks. |
| [bb3f21b41eec](analysis-evidence/commits/bb3f21b41eec.patch) | Fix | High | WAKE_OP: Oversized shift could panic; masked the shift count to match Linux. Outside scope. |
| [85d4cdbbb001](analysis-evidence/commits/85d4cdbbb001.patch) | Performance | n/a | Buckets: Replaced intrusive nodes with Vec and bucket mutexes with spinlocks; introduced the current post-mutation zero-limit check. |
| [8187fa2f1b3f](analysis-evidence/commits/8187fa2f1b3f.patch) | Fix | Medium | Timeout: Repeating relative waits renewed deadlines; absolute expiry is frozen for looping APIs. |
| [2411ba671cb5](analysis-evidence/commits/2411ba671cb5.patch) | Fix | Medium | Signals: Reapplied EINTR with a temporary futex success workaround; current code supersedes it and signals are excluded. |
| [bc5a058fc5e0](analysis-evidence/commits/bc5a058fc5e0.patch) | Documentation | n/a | Cleanup: Recorded the then-missing dequeue/drop obligation; not itself a repair. |
| [6c4f56723c24](analysis-evidence/commits/6c4f56723c24.patch) | Fix | High | Wake quota: Rejected stale wakes consumed wake quota; acceptance now controls counting. |
| [44629e4627dc](analysis-evidence/commits/44629e4627dc.patch) | Fix | High | Registration: An inaccessible futex read was unwrapped; errors became fallible. Current retry path supersedes the old EAGAIN choice. |
| [cd9e5d11d22e](analysis-evidence/commits/cd9e5d11d22e.patch) | Refactor | n/a | Wait lifecycle: Replaced the old FutexWaiter with Waiter/Waker and changed mismatch to EAGAIN; later timer support completed this path. |
| [6b17cceaccc6](analysis-evidence/commits/6b17cceaccc6.patch) | Fix | High | Bucket initialization: Lazy static bucket initialization contributed to a leak; replaced with explicitly initialized Once. |
| [9ca64c281e90](analysis-evidence/commits/9ca64c281e90.patch) | Mechanical | n/a | Formatting: Removed redundant dereferences and documentation without changing the protocol. |
| [90af7464f333](analysis-evidence/commits/90af7464f333.patch) | Feature | n/a | Signals: Added ptrace-stop-specific SIGKILL handling; excluded from the signal-free protocol. |
| [c9032ad97cbc](analysis-evidence/commits/c9032ad97cbc.patch) | Mechanical | n/a | Tests: Renamed a test function only. |
| [7305d389f02a](analysis-evidence/commits/7305d389f02a.patch) | Fix | Medium | Timer: Callback/cancel/update lacked shared serialization; TimerGuard and callback-specific cancellation now compensate. |
| [c19c7765d8f1](analysis-evidence/commits/c19c7765d8f1.patch) | Fix | Medium | Signals: Pending-signal check preceded publishing its waker; reversing them closes the signal window, outside scope. |
| [f0957d2f5491](analysis-evidence/commits/f0957d2f5491.patch) | Mechanical | n/a | Lint: Elided explicit lifetimes and used is_empty; no changed timeout semantics. |
| [969ac9714499](analysis-evidence/commits/969ac9714499.patch) | Mechanical | n/a | Diagnostics: Added track_caller for actionable atomic-mode panic locations. |
| [0ef55a396fa7](analysis-evidence/commits/0ef55a396fa7.patch) | Documentation | n/a | Signals: Explained the temporary EINTR limitation and linked the reverted change. |
| [0c114e911bba](analysis-evidence/commits/0c114e911bba.patch) | Fix | Medium | Signals: Reverted EINTR behavior after wake-precedence regression; historical mitigation, not an injected target. |
| [6421fd0b36aa](analysis-evidence/commits/6421fd0b36aa.patch) | Fix | Medium | Signals: Reported signal interruption rather than success; later reverted/reapplied and superseded. |
| [822caf34f4f1](analysis-evidence/commits/822caf34f4f1.patch) | Refactor | n/a | Wait lifecycle: Moved pause support into Waiter/WaitQueue with a per-thread signal waker. |
| [3de8a9330a1b](analysis-evidence/commits/3de8a9330a1b.patch) | Tooling fix | Low | Tests: Imported the OSTD test prelude to repair CI compilation. |
| [414a3a389e2e](analysis-evidence/commits/414a3a389e2e.patch) | Fix | High | Memory ordering: Incorrect ordering/reset could miss visibility or overwrite a wake; current Release/Acquire RMW operations compensate. |
| [d6714c4b47db](analysis-evidence/commits/d6714c4b47db.patch) | API cleanup | n/a | WaitQueue: Added Default delegating to new; no private futex behavior change. |
| [e192579405bf](analysis-evidence/commits/e192579405bf.patch) | Mechanical | n/a | Documentation: Fixed Waiter::new_pair documentation link. |
| [2002db548196](analysis-evidence/commits/2002db548196.patch) | Feature | n/a | Cancellation: Introduced cancellation-aware waiting with close/recheck and timer cleanup. |
| [81cca422058b](analysis-evidence/commits/81cca422058b.patch) | Performance | n/a | WaitQueue: Added the empty fast path; its ordering issue is counted under the subsequent memory-order repair. |
| [485120405939](analysis-evidence/commits/485120405939.patch) | Fix | High | Wait lifecycle: Sleep-state-only notifications could be lost or enqueue tasks twice; separated waiter/waker notification state. |
| [5fb8a9f7e558](analysis-evidence/commits/5fb8a9f7e558.patch) | Fix | Medium | Cleanup: Timeout omitted dequeue and final condition check in the historical waiter implementation. |
| [98bb9c52566c](analysis-evidence/commits/98bb9c52566c.patch) | Fix | High | Wait lifecycle: Resetting a flag at wait entry erased a preceding timer wake; current wait consumes a pending flag atomically. |
| [901cbebe4441](analysis-evidence/commits/901cbebe4441.patch) | Fix | Low | Waiter flags: Corrected historical flag bit values; no current scoped flag path remains. |
| [a5d719579d48](analysis-evidence/commits/a5d719579d48.patch) | Refactor | n/a | Cleanup: Replaced is_finished bookkeeping with identity-based dequeue. |
| [9f1680d0f369](analysis-evidence/commits/9f1680d0f369.patch) | Fix | High | Scheduling: Repeated wakes could repeatedly schedule a task; later waiter and scheduler contracts supersede the initial fix. |
| [288374ee0960](analysis-evidence/commits/288374ee0960.patch) | Fix | High | WaitQueue locking: spin::Mutex in a canonical-mode wake path could deadlock; replaced by framework SpinLock. |
| [13fd173b2409](analysis-evidence/commits/13fd173b2409.patch) | Feature | n/a | Timeout: Added absolute timeout representation alongside relative timeouts. |
| [d019de29f931](analysis-evidence/commits/d019de29f931.patch) | Feature | n/a | Timer: Introduced Timer/TimerManager and weak callback association. |
| [969be51afcb2](analysis-evidence/commits/969be51afcb2.patch) | Mechanical | n/a | Attributes: Reordered attributes only; a full-message keyword false positive. |
