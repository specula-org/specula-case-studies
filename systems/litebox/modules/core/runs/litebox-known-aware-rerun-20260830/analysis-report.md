# LiteBox Code Analysis Report

- Analysis date: 2026-08-29
- Repository: `/home/ubuntu/tmp/litebox-specula-source.xc2YsN/litebox`
- Analyzed head: `49f7231eef1f53836648c88bf9897d116fb73a96` (`main`)
- Remote check: `origin/main` resolved to the same SHA at the end of the audit.
- System category: **Category B (Concurrent / Lock-Free / Runtime)**

## Direct Verdict

The rerun found several worthwhile **pending** formal-verification and test candidates, but it does not claim that any unfiled candidate is already reproduced. The strongest new-value mechanisms are:

1. namespace walks and CWD path snapshots outliving the namespace identity they described;
2. multi-stage syscalls and directory/epoll bookkeeping confusing raw fd slots with shared open-file descriptions;
3. a runtime-patching plan acting after the mapped interval it observed has been removed or replaced;
4. clone publication/ownership transfer occurring before local validation and fallible platform spawn commit; and
5. futex wake quota being consumed by a waiter that has not yet validated its comparison.

The rerun did **not** relabel known material as new. In particular:

- `do_dup_inner` rollback/recycled-fd behavior is issue #1170.
- LinuxKernel cross-core TLB invalidation is issue #671.
- overlay/resolver coarse lock scope is source-documented.
- the CoW map/register split is discussed in PR #669; the stronger host/Vmem permission consequence was validated in a previous run, not rerun here.
- weak-memory wake publication and exit-memory quiescence are already public in PRs #1228 and #1155.
- filesystem metadata atomicity/root/9P ownership concerns are already discussed in PR #1231.

Those items appear only as historical evidence or exclusions. The exact new candidates below remain `PENDING MODEL` or `PENDING TEST` until their live outcomes are independently exercised.

## Methodology and Coverage

The installed Specula `code-analysis` skill was followed through classification, reconnaissance, bug archaeology, deep analysis, and modeling-brief synthesis. Category B references drove the analysis: split operations, stale snapshots, ownership transfer, identity reuse, wakeup ordering, bookkeeping invariants, and fast/slow path divergence.

Parallel workers were used for the skill-mandated issue/PR batches, 190-commit history classification, and major-file deep reads. Every worker candidate admitted below was re-read on the exact current head in the main context.

### Coverage Statistics

| Evidence source | Coverage | Result |
|---|---:|---|
| Rust workspace | 200 `.rs` files, 94,402 lines | Structural inventory complete |
| Concurrency-heavy core scope | approximately 24,237 lines | VM, fd, FS, sync/event, process, and Linux platform/shim paths |
| GitHub issues collected | 201/201 | Full repository inventory |
| Issues deeply read | 42 | Full bodies and all 32 comments; 26 confirmed bug/design threads, 16 discussion/test-only/non-bug/uncertain exclusions |
| Open PRs screened | 31/31 | Titles, bodies, labels, and scopes |
| Open correctness/fix-intent PRs deeply read | 9 | Full conversation, reviews, inline comments, and diffs |
| Additional ambiguous PRs deeply read and excluded | 3 | Refactor/feature scope, no concrete current fix intent |
| All-ref bug-keyword commit hits | 1,184 | Includes duplicate branch/prototype history |
| Mainline non-merge candidates | 190/190 | Full messages and production diffs inspected |
| Significant production fixes | 109 | All merged/reference-only |
| Commit exclusions | 81 | Docs/tests/build/lint/refactor/feature/performance-only |
| Disputed/non-bug issue threads | 1 | #1006 under the stated project contract |
| Uncertain issue threads | 2 | #1200 and #549 lacked a confirmed production mechanism |

### Search Terms

Git history was mined for `fix`, `bug`, `race`, `panic`, `deadlock`, `correctness`, `crash`, `corrupt`, `leak`, `inconsistent`, `wrong`, and `safety` across core LiteBox, Linux common, shim, and Linux platform paths.

Duplicate/awareness searches included exact symbols and mechanism phrases such as `do_mmap_file_memcpy`, `pread_with_user_buf`, `clear_file_mappings_for_range`, `MAP_FIXED patched_ranges`, `chdir cwd inode`, `rmdir recreate cwd`, `readv close fd reuse`, `epoll close fd reuse`, `parent_tid spawn failure`, and `unvalidated futex waiter`. Searches covered issues and PRs, including closed results and inline review comments.

## Phase 1: Reconnaissance

### Architecture Map

| Layer | Key state | Concurrency/atomicity boundary |
|---|---|---|
| Core `LiteBox` | global typed descriptor table | one custom `RwLock`; individual entries have separate locks |
| Linux task/process | `Task`, `Process`, `FsState`, `FilesState` | one host thread per task; `Arc` sharing follows clone flags |
| Raw fd layer | `RawDescriptorStorage` | raw slots protected by `FilesState.raw_descriptor_store`; lookups return stable typed `Arc`s only for that one lookup |
| Filesystem resolver | explicit `Context`, backend handles | path walk and final backend mutation can be separate; backend determines whether a walking handle retains a guard |
| Overlay/InMem/9P | namespace, per-node maps, transport state | overlay mutation mutex; InMem per-node `RwLock`s; 9P request serialization |
| Page manager | `Vmem` range map | one `RwLock`, deliberately dropped while initialization callbacks run |
| Linux userland mapping | host `mmap`/`mprotect`/`munmap`, CoW records | host syscall atomicity is separate from Vmem and runtime-patch bookkeeping |
| Runtime patching | cache keyed by integer fd, file-mapping intervals | cache mutex; plans are copied out before patching |
| Events/waits/futexes | atomic thread state, `LoanList`, observers | multi-atomic publication plus platform blocking/wakeup |
| Thread creation | process attachment, parent TID, `InitThread` ownership | validation, publication, attach, platform transfer, and platform result are separate stages |

### Important Deviations from Linux Reference Semantics

- Linux holds stable `struct file` references for a syscall; several LiteBox loops instead accept the raw integer again for each chunk.
- Linux represents CWD as a refcounted path/dentry; LiteBox `Context` stores normalized components only.
- Linux VMA mutation and auxiliary state sit behind coordinated memory-management locks; LiteBox host mappings, Vmem, and patch cache are separate.
- Linux clone construction has explicit cleanup labels; LiteBox delegates ownership to platform-specific `spawn_thread` implementations whose error contract is implicit.
- Futex wait-queue membership is expected to represent a successful compare-and-queue decision; LiteBox inserts before comparison and has no validation phase in the entry.

## Phase 2: Bug Archaeology

### Git History Results

All 190 mainline candidates were inspected, not sampled. The three batches classified 64/63/63 candidates, yielding 41/41/27 significant production fixes and 23/22/36 exclusions respectively.

The most frequent files across all 190 keyword candidates were:

| File | Candidate touches |
|---|---:|
| `litebox_shim_linux/src/lib.rs` | 51 |
| `litebox_platform_linux_userland/src/lib.rs` | 51 |
| `litebox_shim_linux/src/syscalls/file.rs` | 40 |
| `litebox_common_linux/src/lib.rs` | 40 |
| `litebox_shim_linux/src/syscalls/process.rs` | 32 |
| `litebox_shim_linux/src/syscalls/net.rs` | 30 |
| `litebox_platform_linux_kernel/src/lib.rs` | 24 |
| `litebox/src/net/mod.rs` | 21 |
| legacy `litebox/src/fs/layered.rs` | 20 |
| `litebox/src/fs/in_mem.rs` | 19 |
| `litebox_shim_linux/src/syscalls/mm.rs` | 16 |
| `litebox_shim_linux/src/syscalls/epoll.rs` | 15 |
| `litebox/src/mm/linux.rs` | 14 |
| `litebox/src/mm/mod.rs` | 13 |
| `litebox/src/fd/mod.rs` | 10 |
| `litebox/src/sync/futex.rs` | 8 |

### Historical Mechanism Groups

| Mechanism | Representative fixed evidence | Current relevance |
|---|---|---|
| fd allocation, identity, rollback | PRs #416, #439, #722, #740, #801, #1182 | Open #1170/#1172 and new multi-stage consumers justify OFD modeling |
| lock scope/order and wake handoff | PRs #75, #86, #162, #222, #270, #303, #335, #366, #575, #723, #809, #903 | Futex validation and process quiescence remain rich state machines |
| VM address placement/range boundaries | PRs #190, #198, #221, #249, #456, #488, #807, #891 | Current stale-plan and interval-generation questions are not fixed-history replays |
| filesystem path/permission/identity | PRs #37, #51, #62, #85, #95, #97, #230, #242, #253, #316, #326, #887, #1107, #1110, #1113, #1231 | Current parent-link and CWD identity candidates generalize a recurring class |
| guest-memory/context lifetime | PRs #355, #365, #368, #413, #432, #461, #470, #483, #495, #516, #592, #913 | Supports explicit clone ownership and quiescence variables |
| validation/freeze/rollback | PRs #488, #817, #1011, #1219 | Model prepare/publish/commit/rollback, not closed defects |

All 109 significant commits are ancestors of the analyzed head. They are scenario evidence and reference pointers only; no §6.1 item asks TLA+ to recreate a pre-fix state.

### Deep-Read Issue Inventory

| Issue | Classification | Root mechanism and disposition |
|---|---|---|
| [#1236](https://github.com/microsoft/litebox/issues/1236) | Confirmed test-harness race, open | Broker can consume a ring slot before a “full” assertion; CI-only, exclude from production model |
| [#1222](https://github.com/microsoft/litebox/issues/1222) | Confirmed allocator bug, open | oversized buddy order reaches `unimplemented!`; deterministic test/code fix |
| [#1204](https://github.com/microsoft/litebox/issues/1204) | Confirmed, source fixed | NT query path lacked access/sync parity; issue tracker is stale after PR #1209 |
| [#1200](https://github.com/microsoft/litebox/issues/1200) | Uncertain, closed | fixed-address test TOCTOU claimed, but no discussion, linked fix, or production consumer |
| [#1193](https://github.com/microsoft/litebox/issues/1193) | Confirmed signal-origin bug, open | asynchronous exception-class signal can reuse synchronous fault metadata; known anchor |
| [#1172](https://github.com/microsoft/litebox/issues/1172) | Confirmed fd rollback race, open | socketpair two-insert rollback can consume a recycled slot; exact known site |
| [#1171](https://github.com/microsoft/litebox/issues/1171) | Confirmed, fixed | pipe2 sibling fixed by PR #1182; reference only |
| [#1170](https://github.com/microsoft/litebox/issues/1170) | Confirmed fd rollback race, open | `do_dup_inner` split insert/check/close; exact known site, explicitly deprioritized |
| [#1159](https://github.com/microsoft/litebox/issues/1159) | Confirmed, fixed | independent resource-limit atomics allowed `cur > max`; fixed by PR #1179 |
| [#1084](https://github.com/microsoft/litebox/issues/1084) | Confirmed design defect, open | global broker quotas allow cross-session starvation; known and deterministic |
| [#1009](https://github.com/microsoft/litebox/issues/1009) | Confirmed provider/test UB, open | volatile/atomic race in trivial provider; separate wake publication work is PR #1228 |
| [#1006](https://github.com/microsoft/litebox/issues/1006) | Disputed/non-bug, closed | anonymous executable transition is outside runtime rewriter contract; exclude |
| [#980](https://github.com/microsoft/litebox/issues/980) | Performance enhancement, closed | page-table accessed/dirty optimization; exclude |
| [#971](https://github.com/microsoft/litebox/issues/971) | Confirmed, fixed | transient mutable page-table slots were shared; PR #972 reference only |
| [#958](https://github.com/microsoft/litebox/issues/958) | Confirmed, fixed | LVBS concurrent-VP TLB hypercall encoding; separate from #671 |
| [#936](https://github.com/microsoft/litebox/issues/936) | Broad design discussion, open | rollback for critical kernel operations; too broad without a concrete transaction |
| [#853](https://github.com/microsoft/litebox/issues/853) | Confirmed, fixed | guest return context/stack stability; PR #913 reference only |
| [#852](https://github.com/microsoft/litebox/issues/852) | Confirmed design defect, open | HEKI silently skips reserved overlap yet reports success; fully maintainer-aware |
| [#850](https://github.com/microsoft/litebox/issues/850) | Confirmed layout defect, open | non-page-aligned kexec metadata omitted from normal protection path; known |
| [#846](https://github.com/microsoft/litebox/issues/846) | Confirmed design limitation, open | infallible kernel allocation; draft PR #1212 is partial |
| [#821](https://github.com/microsoft/litebox/issues/821) | Confirmed design defect, open | runtime patch state keyed by raw fd; supports Scenario 2 but is not itself new |
| [#762](https://github.com/microsoft/litebox/issues/762) | Confirmed partial-operation defect, open | loader reserve/map/copy/protect lacks unmap rollback |
| [#685](https://github.com/microsoft/litebox/issues/685) | Architectural correction, fixed | kernel high-canonical layout; exclude from TLA+ |
| [#679](https://github.com/microsoft/litebox/issues/679) | Performance enhancement, fixed | full-range cleanup scan; exclude |
| [#966](https://github.com/microsoft/litebox/issues/966) | Confirmed historical lifecycle bug | broker event-counter close/wakeup fixed on `ulitebox`; reference only |
| [#923](https://github.com/microsoft/litebox/issues/923) | Enhancement/design limitation, open | broad resource accounting; no concrete protocol selected |
| [#902](https://github.com/microsoft/litebox/issues/902) | Confirmed semantic gap, closed not-planned | background PTY read can remain blocked without SIGTTIN; acknowledged branch-specific debt |
| [#797](https://github.com/microsoft/litebox/issues/797) | RFC, open | unimplemented multiprocess architecture; exclude from current-system model |
| [#721](https://github.com/microsoft/litebox/issues/721) | Confirmed design debt, open | blocking 9P emulated by spin; known liveness/performance debt |
| [#707](https://github.com/microsoft/litebox/issues/707) | Design debt, open | host-originating signal interruption handshake; implemented broadly, still an anchor |
| [#672](https://github.com/microsoft/litebox/issues/672) | Cleanup, open | unchecked guest arithmetic; test/static review |
| [#650](https://github.com/microsoft/litebox/issues/650) | Expected dev behavior, open | unstable environment/API unwrap; exclude |
| [#642](https://github.com/microsoft/litebox/issues/642) | Partially addressed design defect | physical-pointer abstraction; no new live consequence |
| [#549](https://github.com/microsoft/litebox/issues/549) | Uncertain, open | polling test passed but process teardown hung; root cause not isolated |
| [#489](https://github.com/microsoft/litebox/issues/489) | Confirmed race/design defect, open | Windows reserve/query/decommit/recommit split; source-documented |
| [#438](https://github.com/microsoft/litebox/issues/438) | Largely implemented RFC, open | remote interruption state machine; historical evidence |
| [#431](https://github.com/microsoft/litebox/issues/431) | Confirmed soundness design defect, open | raw pointer associated types lack a Send contract; code review only |
| [#429](https://github.com/microsoft/litebox/issues/429) | Enhancement, open | execution-context construction/extended state; no current failure |
| [#412](https://github.com/microsoft/litebox/issues/412) | Confirmed, fixed | initial entry register clobber; reference only |
| [#410](https://github.com/microsoft/litebox/issues/410) | Confirmed, fixed | TLS ownership/encapsulation; reference only |
| [#71](https://github.com/microsoft/litebox/issues/71) | Design discussion, open | cwd versus openat abstraction; broad awareness, no CWD identity analysis |
| [#696](https://github.com/microsoft/litebox/issues/696) | Design discussion, open | chdir/path layer maturity; broad awareness, no deletion/recreation consequence |

### Open PR Audit

All 31 open PRs were screened. The correctness/fix-intent set was:

| PR | Current classification | Disposition |
|---|---|---|
| [#1230](https://github.com/microsoft/litebox/pull/1230) | epoll interest follows per-fd identity, not OFD; proposed fix has reviewed close-path race | Public known anchor; do not recreate exact bug |
| [#1228](https://github.com/microsoft/litebox/pull/1228) | weak-memory store-buffering reproductions for futex/poll/interrupt | Public draft; exact counterexample excluded from new targets |
| [#1212](https://github.com/microsoft/litebox/pull/1212) | partial fallible-allocation conversion | Incomplete draft; model only narrowed transactions |
| [#1191](https://github.com/microsoft/litebox/pull/1191) | synchronous-versus-asynchronous exception fix | Focused test is better; broader #1193 remains known |
| [#1155](https://github.com/microsoft/litebox/pull/1155) | detach-before-final-guest-memory access | Open approved known anchor; exact replay excluded |
| [#1010](https://github.com/microsoft/litebox/pull/1010) | Rust alias/provenance fix in TLS | Miri/code review, not TLA+ |
| [#1003](https://github.com/microsoft/litebox/pull/1003) | OP-TEE stack-guard hardening | Not a concurrency model target |
| [#820](https://github.com/microsoft/litebox/pull/820) | prototype weak-memory/Loom work | Superseded as evidence by #1228; not an independent target |
| [#678](https://github.com/microsoft/litebox/pull/678) | guest-derived integer arithmetic prototype | Boundary tests/static checks |

Ambiguous PRs #1130, #1127, and #1032 were deeply read and excluded as feature/refactor/prototype work without an isolated current correctness fix. The other 19 were dependency, documentation, platform/feature, performance, or verification-tooling changes.

## Phase 3: Deep Analysis

### Novelty and Evidence Matrix

`Code-traced` below means the exact current control flow and consumer were verified, but no new scheduling test was added in this read-only phase.

| ID | Filed duplicate at same site/mechanism | Maintainer awareness | New consequence in this run | Status |
|---|---|---|---|---|
| FS-C1 detached-parent create | None found | Broad atomicity known; resolver comment claims this boundary is protected | Successful fd/create can refer to an unreachable node | PENDING MODEL/TEST |
| FS-C2 CWD path rebinding | None found | General path rebinding discussed for overlay handles; not CWD | Relative operations bind to a recreated directory object | PENDING MODEL/TEST |
| FD-C1 multi-stage raw-fd rebinding | None found | Raw-fd races #1170/#1172 and atomic readv TODO are adjacent, not this consumer | One syscall can read/write/map multiple OFDs and update a reused fd's offset | PENDING MODEL/TEST |
| FD-C2 directory offset fd-local | None found | General OFD awareness in PR #1230 and fd docs | dup aliases restart/seek independently; concurrent batches duplicate | PENDING TEST |
| FD-C3 epoll stale-interest growth | None found | Source knows stale entries, but assumes reuse replaces them | Repeated close/reuse monotonically retains dead keys | PENDING TEST |
| VM-C1 stale patch plan | None found | PR #810 discusses cache locking, not generation revalidation | Pre-unmap plan can act after mapping removal/replacement | PENDING MODEL/TEST |
| VM-C2 partial interval deletion | None found | Cleanup comment states whole-overlap removal | Surviving subrange loses patch tracking | PENDING TEST |
| CL-C1 SNP spawn rollback | None found | No issue, TODO, or review found at ownership-transfer site | failed host spawn retains attachment/init ownership and blocks quiescence | PENDING MODEL/TEST |
| CL-C2 premature `parent_tid` | None found | Successful-path ordering fixed historically; failure publication not discussed | rejected clone mutates caller-visible child identity | PENDING TEST |
| FX-C1 unvalidated waiter quota | None found | Same subsystem heavily discussed in #820/#1228, but different mechanism | `wake(1)` reports success while a validated waiter remains blocked | PENDING MODEL/TEST |
| FS-C4 chdir target permission | None found | No exact discussion found | `chdir` can accept a target lacking required search permission | PENDING TEST |

### Finding FS-C1: Walked Parent Can Be Unlinked Before Final Mutation

**Mechanism.** `Resolver::parent_dir_and_name` says a walking handle lets a backend retain locks across “walk parent + mutate child” (`litebox/src/fs/resolver.rs:214-232`). InMem's walk takes and releases per-directory read locks and returns an `Arc` handle (`litebox/src/fs/in_mem.rs:249-293`). Creation only later locks that detached directory (`:478-505`), while `rmdir_at` can remove it from its parent after observing it empty (`:556-570`).

**Interleaving.** A walks `/p/x` and retains `p`; B removes empty `/p`; A creates `x` in the detached node and returns success. If A precedes B, B should see a nonempty directory; if B precedes A, pathname creation should fail. No serial order explains both successes and the unreachable file.

**Compensating mechanisms checked.** InMem node locks protect each map but not the linkage from a walked parent into its parent's namespace. Overlay's mutation lock does not repair the generic InMem backend boundary. PR #1107 fixed same-parent concurrent creation, not removal of the walked parent.

**Verification route.** TLA+ should retain node identity and linkage separately. A deterministic test can pause between `owned_parent_dir` and `create_file_at`.

### Finding FS-C2: CWD Pathname Rebinds After Delete/Recreate

`Context.cwd` is an `Arc<ResolvedPath>`, not a stable directory handle (`litebox/src/fs/resolver.rs:50-105`). Relative syscalls reconstruct a pathname prefix (`litebox_shim_linux/src/syscalls/file.rs:205-228`), and `sys_chdir` publishes only the resolved components (`:1741-1785`). InMem can remove that directory node (`litebox/src/fs/in_mem.rs:556-570`).

After `/d` becomes CWD, removing and recreating `/d` causes later relative operations to use the replacement node. Linux keeps a refcounted `struct path`; its `getcwd` reports failure for an unlinked dentry rather than silently rebinding. The exact CWD consumer was not discussed in issues #71/#696 or PR #1231.

Plain overlapping `chdir` calls were separately examined and excluded: Linux itself performs path lookup before `set_fs_pwd`, so the same overlapping old/new result is reference-compatible. The candidate is specifically object deletion/recreation, not two ordinary `chdir` calls.

### Finding FD-C1: Multi-Stage Syscalls Rebind the Raw FD

A single `run_on_raw_fd` call is safe: it returns an `Arc<TypedFd>` for the original entry, and raw-slot reuse cannot retarget that Arc (`litebox/src/fd/mod.rs:669-691`; `litebox_shim_linux/src/lib.rs:448-486`). The problem is that several logical syscalls invoke raw lookup again at every stage:

- fallback file mmap reads each page with `sys_read(fd, ...)` (`litebox_shim_linux/src/syscalls/mm.rs:270-305`);
- large `read` loops through `pread_with_user_buf` and then performs a final raw-fd `lseek` (`litebox_shim_linux/src/lib.rs:516-541,588-628`);
- `sendfile` resolves its input and output fds on each chunk and may rewind by raw fd (`litebox_shim_linux/src/syscalls/file.rs:598-681`);
- `preadv`, `pwritev`, `readv`, and `writev` call `sys_read`/`sys_write` per chunk (`:896-956,1098-1115`).

Closing and reusing the integer between chunks can mix file contents, direct later chunks to a different object, and update the replacement object's offset. Linux binds the syscall to stable file descriptions at entry. Repository searches found no report for these sites.

### Finding FD-C2: Directory Position Is FD-Local, Not OFD-Shared

`getdents64` reads `Diroff` through descriptor metadata, emits entries, then writes it later (`litebox_shim_linux/src/syscalls/file.rs:2571-2648`). Directory `lseek` uses the same metadata (`:728-742`). `Descriptors::duplicate` shares the open entry/offset contract but explicitly does not duplicate fd-local metadata (`litebox/src/fd/mod.rs:70-105`).

Consequences are deterministic: a dup alias restarts at zero, `lseek` on one alias is invisible to the other, and concurrent calls can load the same offset and return duplicate batches. A focused regression test is cheaper than a dedicated model, although the shared-offset variable belongs in Scenario 2.

### Finding FD-C3: Epoll Stale Entries Are Not Replaced After Reuse

Epoll stores `Weak<TypedFd>` and keys interests by `(raw_fd, Arc address)` (`litebox_shim_linux/src/syscalls/epoll.rs:81-110,327-340`). `add_interest` acknowledges stale entries but assumes a later insert replaces them (`:239-264`). Closing drops the strong typed-fd reference, but its Weak control block and map entry remain. RawDescriptorStorage reuses the vacant integer with a new Arc allocation (`litebox/src/fd/mod.rs:613-624`), creating a different key. Repetition grows the map for the epoll lifetime.

PR #1230 addresses readiness surviving dup and retains address-based weak identity; it does not prune this stale-key growth. Best next step: deterministic length/resource test.

### Findings VM-C1 and VM-C2: Stale Plans and Unsplittable Tracking Intervals

`maybe_patch_on_mprotect_exec` collects `(fd,start,len)` under the cache lock (`litebox_shim_linux/src/syscalls/mm.rs:482-508`), releases it, and later calls `maybe_patch_exec_segment` (`:522-535`). Concurrent `sys_munmap` removes the mapping, then clears matching cache tuples (`:376-411`). The later path checks only whether the fd state exists (`:779-789`); it does not revalidate interval membership or mapping generation.

Separately, cleanup retains only tuples with no overlap; an overlap deletes the whole tuple rather than splitting around a partial unmap (`:396-410`). A surviving page can therefore lose tracking.

These are distinct from recreating PR #669's already-known two-CoW race. Model mapping generations and stale plan rejection; use direct interval tests for partial unmap and same-range replacement.

### Findings CL-C1 and CL-C2: Clone Commit/Rollback Gaps

`do_clone` allocates a child TID and writes `parent_tid` before checking the clone3 stack pair (`litebox_shim_linux/src/syscalls/process.rs:685-697`). A locally rejected clone can therefore mutate caller state.

After validation, `new_thread` attaches the child and increments thread state before the fallible platform spawn (`:700-733`). Linux and Windows providers pass an owned Box into `std::thread::spawn`, whose error path drops the closure and Task (`litebox_platform_linux_userland/src/lib.rs:963-980`; `litebox_platform_windows_userland/src/lib.rs:781-798`). The SNP provider instead converts `ThreadStartArgs` with `Box::into_raw`, then uses `?` on the host call without reconstructing the Box on error (`litebox_platform_linux_kernel/src/host/snp/snp_impl.rs:250-275`).

On failure, the embedded Task cannot drop and detach. `nr_threads` can remain above one, while `kill_other_threads` waits for exactly one (`litebox_shim_linux/src/syscalls/process.rs:280-314`). This is a model-worthy ownership transaction with a direct quiescence consumer.

### Finding FX-C1: Wake Quota Can Select an Unvalidated Futex Entry

`FutexManager::wait` inserts an entry before reading the futex word (`litebox/src/sync/futex.rs:96-113`). `wake` selects by address/bitset and stops after its requested count (`:145-166`); the entry has no validated flag (`:42-47`).

If a mismatching waiter is paused after insertion ahead of a validated waiter, `wake(1)` can remove the first, return one, and stop. The first later returns value mismatch; the validated waiter remains blocked without a later wake. LoanList correctly protects lifetime (`litebox/src/utilities/loan_list.rs:153-209,381-416`) but cannot distinguish validation state.

This is separate from PR #1228's store-buffering mechanism and should be modeled under sequentially consistent interleavings first.

### Finding FS-C4: `chdir` Does Not Check Target Search Permission

`sys_chdir` checks existence/type through `file_status` (`litebox_shim_linux/src/syscalls/file.rs:1741-1785`). `file_status` opens with `O_PATH` (`litebox/src/fs/resolver.rs:989-1007`), and path-only opens use `SearchScope::ParentsOnly`, deliberately skipping target-directory search permission (`:528-540`). No later target execute/search check exists. A focused user/permission test should determine the exact errno/result; this is deterministic and not a TLA+ target.

## Explicit Exclusions and False Positives

| Candidate | Exclusion reason |
|---|---|
| Two overlapping `chdir` calls alone | Linux also resolves then publishes CWD; overlapping result is reference-compatible |
| `close_on_exec` raw-slot snapshot | Real caller runs `kill_other_threads` first; prior positive/negative controls showed the race is masked |
| Current-main `Arc::strong_count` close panic | Mutable descriptor-table access prevents concurrent creation of a new entry handle; concern applies to PR #1230's proposed weak-upgrade design |
| A single `run_on_raw_fd` operation retargeted by reuse | Returned typed Arc remains bound; only repeated lookups across one logical syscall are candidates |
| LoanList use-after-free on wake/timeout | Owner waits through `LOANED_OWNER_WAITING`/`REMOVED_WAKING`; final wake completes before reuse |
| ReadySet push/pop loses durable readiness | `is_ready` plus queue recheck preserves a concurrent push on current main |
| Observer relaxed `nums` necessarily loses a live event | Wait consumers recheck durable conditions; no notification-only harmful consumer found |
| Subject callback deadlock | No live callback reentered the same Subject lock |
| PollSet weak-observer leak | Bounded; next registration/notification prunes dead weak entries |
| OP-TEE session capacity race | The actual acquire path serializes capacity; prior concurrent test did not violate the bound |
| Orphaned OP-TEE session ID | Documented bounded resource consumption with no wrong live outcome |
| 32-bit Linux userland TASK_ADDR path | Target configuration is not reachable on current platform crate; no current defect |
| #1006 anonymous exec transition | Explicitly outside runtime rewriter contract under current design |
| Coarse overlay/resolver lock time | Source-aware performance debt; no new deadlock or harmful consumer found |

## Maintainer-Aware Technical Debt Kept Out of New Findings

- PR #669's map/register split and prior host/Vmem permission divergence.
- PR #1231's root metadata bypass, chmod/chown authorization TOCTOU, and 9P ownership limitation.
- Overlay copy-up-before-authorization (`litebox/src/fs/overlay.rs:836-874`).
- Generic `O_CREAT|O_EXCL` and `O_TRUNC` side effects before authorization (`litebox/src/fs/resolver.rs:551-560`; InMem comments).
- Overlay pathname-backed directory handle and transactional marker limitations from PR #1195.
- 9P create/mkdir success followed by walk/connection failure.
- Resolver/overlay coarse locks across backend I/O and whole-file copy.
- Open PR #1155 quiescence ordering and PR #1228 weak-memory wake publication.
- Issues #1170, #1172, #671, #852, #850, #846, #821, and #762 at their exact known sites.

## Phase 4: Scenario Ranking and Handoff Decision

| Rank | Scenario | New pending candidates | Historical density | TLA+ fit | Decision |
|---:|---|---|---|---|---|
| 1 | Raw fd/OFD identity | FD-C1, FD-C2, FD-C3 | Very high | High | Model stable operation identity; test direct bookkeeping defects |
| 2 | Path snapshot/namespace identity | FS-C1, FS-C2 | Very high | High | Model node linkage, walked handles, CWD object identity |
| 3 | Mapping generation/auxiliary state | VM-C1, VM-C2 | High | High | Model generation-tagged collect/apply; test interval splitting |
| 4 | Clone transaction/ownership | CL-C1, CL-C2 | Medium-high | High | Model publish/attach/transfer/commit/rollback |
| 5 | Futex validation/wake quota | FX-C1 | High | High | Model explicit waiter phases under SC; keep #1228 weak memory separate |

The primary deliverable, `modeling-brief.md`, carries only forward-looking questions. Closed fixes and already-public exact counterexamples stop in this report/reference layer.

## Verification Performed

### Repository and Source

- Worktree remained clean throughout.
- Local HEAD and live `origin/main` both resolved to `49f7231eef1f53836648c88bf9897d116fb73a96` at final source verification.
- All admitted source claims were re-read with current line numbers after archaeology.

### Tests

| Command | Result |
|---|---|
| `cargo test -p litebox --lib` | 107 passed; 24 9P tests failed solely because `diod` is not installed |
| `cargo test -p litebox --lib -- --skip fs::nine_p` | 107 passed, 0 failed |
| `cargo test -p litebox_shim_linux --lib syscalls::mm::tests` | 10 passed |
| `cargo test -p litebox_shim_linux --lib chdir` | 3 passed |
| `cargo test -p litebox_shim_linux --lib syscalls::epoll::test` | 6 passed |
| `cargo test -p litebox_shim_linux --lib syscalls::tests::test_pipe2_race_with_concurrent_close` | 1 passed |
| Full `litebox_shim_linux --lib` | Not usable as a clean baseline in this environment: 9P/timer failures appeared and TUN/network tests exceeded 60 seconds; run was terminated |

The passing tests are baseline checks only. None specifically schedules the new pending interleavings, so they do not confirm or refute the new candidates.

## Limitations and Next Verification Gates

- This task authorized the two requested documents, not target-source instrumentation. No new scheduling hook or reproducer was added.
- `diod` and a configured TUN environment were unavailable, so 9P/network integration behavior was assessed from source and existing discussions.
- The prior CoW consequence test was not rerun because the exact mechanism is maintainer-aware and the target guidance forbids spending confirmation budget without a new consequence. Current head still contains the split.
- Before any upstream report, each pending candidate needs an independent focused test or model counterexample, a refreshed exact-head duplicate search, and a live consumer result. No issue, PR, or external message was created by this analysis.

## Reference URLs

- CoW awareness: [PR #669 review](https://github.com/microsoft/litebox/pull/669#discussion_r2835598771), [author response](https://github.com/microsoft/litebox/pull/669#discussion_r2835723344)
- Fixed-address history: [PR #488](https://github.com/microsoft/litebox/pull/488)
- Runtime patching history: [PR #810](https://github.com/microsoft/litebox/pull/810), [issue #821](https://github.com/microsoft/litebox/issues/821)
- Current filesystem Context review: [PR #1231](https://github.com/microsoft/litebox/pull/1231)
- Known fd issues: [#1170](https://github.com/microsoft/litebox/issues/1170), [#1171](https://github.com/microsoft/litebox/issues/1171), [#1172](https://github.com/microsoft/litebox/issues/1172)
- Known TLB issue: [#671](https://github.com/microsoft/litebox/issues/671)
- Active concurrency fixes: [PR #1155](https://github.com/microsoft/litebox/pull/1155), [PR #1228](https://github.com/microsoft/litebox/pull/1228), [PR #1230](https://github.com/microsoft/litebox/pull/1230)
- CWD reference: [Linux `fs_struct`](https://github.com/torvalds/linux/blob/master/include/linux/fs_struct.h), [Linux `getcwd`](https://github.com/torvalds/linux/blob/master/fs/d_path.c)
