# Bug Report — LiteBox

## Summary

- Source head: `49f7231eef1f53836648c88bf9897d116fb73a96`
- Scenarios tested: 5
- Unique hunting configs run: 12
- Actionable model-checking findings: 9
- Known/maintainer-aware duplicate observations excluded from that count: 1
- Trace validation: 9/9 preprocessed traces passed after convergence
- Standard/structural convergence: no violation in the final 30-minute BFS (`1,096,135,926` generated, `247,268,480` distinct, diameter 16)

Every finding below passed the implementation-fidelity checklist: the modeled preconditions have corresponding implementation paths, no unmodeled guard suppresses the transition, and the named live consumer observes a concrete consequence. Duplicate status, maintainer awareness, and the newly demonstrated consequence are stated separately.

## Bug 1: Detached-parent create returns success for an unreachable file

- **Scenario**: 1 — path snapshot versus stable namespace identity
- **Severity**: Medium
- **Invariant violated**: `ReachableCreate`
- **Config**: `MC_hunt_scenario_1_reachable_create.cfg`
- **Counterexample**: 4 states, `spec/output/MC_hunt_scenario_1_reachable_create_bfs.out`
- **Filed duplicate status**: No same-site issue or PR found in the current repository search.
- **Maintainer awareness**: `Resolver::parent_dir_and_name` explicitly expects a backend walking handle to preserve walk-plus-mutate atomicity; InMem does not document an exception.
- **Newly demonstrated consequence**: `open(O_CREAT)` can return a live file handle even though the created file has no reachable pathname.

### Trace Summary

1. A task walks `ParentPath` and retains the InMem directory `Arc`.
2. Another task removes that empty directory from its live parent.
3. The first task calls `create_file_at` through the retained `Arc`; insertion succeeds and the syscall reports success, but `ChildPath` remains unbound because the walked parent is detached.

### Root Cause

InMem traversal clones each child `Arc` and releases the read guard before returning. `rmdir_at` can then remove the directory from its parent's `children`, while `create_file_at` later locks only the retained detached directory and inserts the new file. The returned `FileHandle` is live, but a pathname lookup cannot reach it.

### Affected Code

- `litebox/src/fs/resolver.rs:214`: walk-plus-mutate atomicity contract
- `litebox/src/fs/in_mem.rs:249`: InMem walk returns an owned `Arc` without a retained namespace guard
- `litebox/src/fs/in_mem.rs:478`: create commits through the retained directory object
- `litebox/src/fs/in_mem.rs:556`: concurrent directory removal

### Recommendation

Make the Backend contract enforce atomic walk-plus-mutate, or revalidate that the retained directory is still linked at the same parent/name before committing creation. Return `ENOENT`/retry if identity changed.

---

## Bug 2: Pathname recreation silently redirects relative operations from the current directory

- **Scenario**: 1 — path snapshot versus stable namespace identity
- **Severity**: High
- **Invariant violated**: `CwdIdentityStable`
- **Config**: `MC_hunt_scenario_1_cwd_identity.cfg`
- **Counterexample**: 5 states, `spec/output/MC_hunt_scenario_1_cwd_identity_bfs.out`
- **Filed duplicate status**: No issue or PR describes unlink/recreate rebinding of a live CWD. Issues [#696](https://github.com/microsoft/litebox/issues/696) and [#71](https://github.com/microsoft/litebox/issues/71) are broader CWD/API design discussions.
- **Maintainer awareness**: CWD representation was recently refactored by [PR #1231](https://github.com/microsoft/litebox/pull/1231), but neither that PR nor its review records this identity race.
- **Newly demonstrated consequence**: A task that remains in the old directory can have later relative reads or writes redirected to a newly created object at the same pathname.

### Trace Summary

1. The context initially records `cwd_node` together with the normalized `cwd_path`.
2. Another task removes `cwd_path` and recreates it as fresh `node3`.
3. A later relative lookup reconstructs a pathname from the stored CWD text and resolves `node3`, not the original `cwd_node`.

### Root Cause

`Context.cwd` stores an `Arc<ResolvedPath>`, not a stable directory object. `Task::resolve_path` obtains that pathname as a prefix and later resolution walks the current namespace again. There is no identity token or revalidation tying the operation to the directory accepted by `chdir`.

### Affected Code

- `litebox/src/fs/resolver.rs:50`: pathname-based CWD in `Context`
- `litebox_shim_linux/src/syscalls/file.rs:205`: relative-path construction from CWD text
- `litebox_shim_linux/src/syscalls/file.rs:1755`: `chdir` validation and publication

### Recommendation

Represent CWD with a stable directory handle/path object whose identity survives unlink, and resolve relative operations from that handle. Do not rebind through normalized pathname text.

---

## Bug 3: One chunked syscall can consume multiple open-file descriptions after fd reuse

- **Scenario**: 2 — raw fd slots versus open-file-description identity
- **Severity**: High
- **Invariant violated**: `OperationBindsOneOFD`
- **Config**: `MC_hunt_scenario_2_fd_identity.cfg`
- **Counterexample**: 5 states, `spec/output/MC_hunt_scenario_2_fd_identity_bfs.out`
- **Filed duplicate status**: No same-site report found. Issue [#1170](https://github.com/microsoft/litebox/issues/1170) and [PR #801](https://github.com/microsoft/litebox/pull/801) concern dup/rollback slot races, not repeated lookup inside one syscall.
- **Maintainer awareness**: No source comment, TODO, or review was found for preserving one OFD across these chunk loops.
- **Newly demonstrated consequence**: A single read/sendfile/readv/mmap operation can splice bytes from different files or act on a newly reused descriptor.

### Trace Summary

1. A logical operation starts on `fd0` and observes `ofd0`.
2. Another task closes `fd0` and reuses the slot for `ofd1`.
3. The next chunk calls `run_on_raw_fd(fd0)` again and consumes `ofd1`; the operation's entry identity remains `ofd0`.

### Root Cause

Large reads and several vectored/chunked helpers retain only the raw integer. Each chunk re-enters `sys_read`/`run_on_raw_fd`, so the descriptor table is resolved afresh after close/reuse. Linux syscall entry normally captures a referenced file/OFD for the operation's lifetime.

### Affected Code

- `litebox_shim_linux/src/lib.rs:516`: `pread_with_user_buf` chunk loop
- `litebox_shim_linux/src/lib.rs:588`: large-read path
- `litebox_shim_linux/src/syscalls/file.rs:598`: repeated lookup in sendfile/chunked I/O paths
- `litebox_shim_linux/src/syscalls/mm.rs:270`: per-page fallback mmap reads

### Recommendation

Resolve the typed descriptor/OFD once at syscall entry and pass that stable handle through every chunk. Apply the same audit to readv/preadv/writev/pwritev/sendfile and fallback mmap.

---

## Bug 4: Duplicated directory descriptors do not share their directory position

- **Scenario**: 2 — shared OFD consumers
- **Severity**: Medium
- **Invariant violated**: `AliasOffsetsShared`
- **Config**: `MC_hunt_scenario_2_alias_offsets.cfg`
- **Counterexample**: 5 states, `spec/output/MC_hunt_scenario_2_alias_offsets_bfs.out`
- **Filed duplicate status**: No duplicate found. [PR #783](https://github.com/microsoft/litebox/pull/783) added directory offset handling but does not address alias sharing.
- **Maintainer awareness**: `Descriptors::duplicate` documents that offsets are shared and separately warns that fd-local metadata is not duplicated; the use of fd-local `Diroff` contradicts the former promise.
- **Newly demonstrated consequence**: Calls through dup aliases can repeat or omit directory entries because each alias advances an independent cursor.

### Trace Summary

1. `getdents64` loads offset 0 from `fd0`.
2. `fd0` is duplicated to `fd1`; both aliases reference `ofd0`, while both fd-local offsets are 0.
3. The first call produces an entry and stores offset 1 only into `fd0`; `fd1` remains at 0.

### Root Cause

`Diroff` is written with `set_fd_metadata`, which stores metadata on the individual descriptor. Duplication clones the shared entry but intentionally does not copy or alias fd-local metadata. Directory position is an OFD property under Linux semantics.

### Affected Code

- `litebox/src/fd/mod.rs:70`: duplicate contract and shared entry clone
- `litebox/src/fd/mod.rs:410`: fd-local versus entry-shared metadata
- `litebox_shim_linux/src/syscalls/file.rs:2571`: `getdents64` load/produce/store of `Diroff`

### Recommendation

Store `Diroff` as entry metadata (or in the filesystem open-file object) and update it atomically at the shared OFD level.

---

## Bug 5: Last-close epoll interests persist and accumulate across raw-fd reuse

- **Scenario**: 2 — epoll interest identity
- **Severity**: Medium
- **Invariant violated**: `NoStaleEpollInterests`
- **Config**: `MC_hunt_scenario_2_epoll_interest.cfg`
- **Counterexample**: 3 states, `spec/output/MC_hunt_scenario_2_epoll_interest_bfs.out`
- **Filed duplicate status**: Open [PR #1230](https://github.com/microsoft/litebox/pull/1230) fixes interest lifetime across `dup`, not removal of dead interests after the last reference closes.
- **Maintainer awareness**: A source comment acknowledges that stale entries are not removed immediately and assumes a later insert replaces them.
- **Newly demonstrated consequence**: Reusing the same raw fd for a different OFD produces a different pointer key, so the old entry is not replaced; repeated add/close/reuse cycles retain dead entries and observers without bound.

### Trace Summary

1. Epoll adds interest `[fd0, ofd0]`.
2. The last `fd0` reference closes; the descriptor weak reference becomes dead.
3. The interest map still contains the old key. A later reused `fd0` with a new OFD/pointer creates a distinct key rather than replacing it.

### Root Cause

`EpollEntryKey` combines the raw fd with the descriptor `Arc` address. Close has no hook into the epoll interest map. Ready-list polling can skip a dead weak reference, but it does not remove the owning entry from `interests`; the only lazy replacement path works when the exact key matches.

### Affected Code

- `litebox_shim_linux/src/syscalls/epoll.rs:81`: weak descriptor identity
- `litebox_shim_linux/src/syscalls/epoll.rs:232`: stale-entry replacement assumption
- `litebox_shim_linux/src/syscalls/epoll.rs:327`: raw-fd plus pointer key
- `litebox_shim_linux/src/syscalls/epoll.rs:468`: ready-list cleanup does not clean `interests`

### Recommendation

Anchor interests to OFD lifetime and remove the map entry on last-reference close, or opportunistically retain/remove all dead entries before insertion and wait. Add a repeated close/reuse test that asserts bounded map size.

---

## Bug 6: A stale ELF patch plan can rewrite a newer fixed-address mapping

- **Scenario**: 3 — mapping generation versus stale auxiliary state
- **Severity**: High
- **Invariant violated**: `NoStalePatchPlan`
- **Config**: `MC_hunt_scenario_3_stale_patch_plan.cfg`
- **Counterexample**: 4 states, `spec/output/MC_hunt_scenario_3_stale_patch_plan_bfs.out`
- **Filed duplicate status**: No issue/PR covers stale plan application. Issue [#821](https://github.com/microsoft/litebox/issues/821) concerns fd-as-cache-key design, not mapping-generation validation.
- **Maintainer awareness**: [PR #669](https://github.com/microsoft/litebox/pull/669#discussion_r2835598771) explicitly identified the host-map/register race window, and the author acknowledged it, but no discussion identified runtime patching as a harmful consumer.
- **Newly demonstrated consequence**: `mprotect(PROT_EXEC)` can apply a plan for generation 1 to generation 2 at the same address, rewriting code/data in a replacement mapping using stale file/cache identity.

### Trace Summary

1. `TaskDoMmapFileHost` replaces `addr0`, making the host mapping generation 2 while Vmem and patch intervals still describe generation 1.
2. Another task collects the still-present generation-1 patch interval.
3. It calls the patcher on `addr0` without generation revalidation; the recorded applied plan is generation 1 and the mutated host mapping is generation 2.

### Root Cause

The CoW fast path performs the host mapping and `register_existing_mapping` in separate critical sections. Runtime patch collection copies `(fd, address, length)` out of `elf_patch_cache`, drops the cache lock, and later patches that address. Neither collection nor application carries or validates mapping generation.

### Affected Code

- `litebox_shim_linux/src/syscalls/mm.rs:215`: split CoW host mapping and Vmem registration
- `litebox_shim_linux/src/syscalls/mm.rs:482`: patch-plan collection outside the apply operation
- `litebox_shim_linux/src/syscalls/mm.rs:522`: unvalidated plan application
- `litebox_shim_linux/src/syscalls/mm.rs:768`: runtime patch mutation path

### Recommendation

Use a begin/attempt/commit mapping transaction and attach a generation token to each patch-cache interval. Revalidate address, backing identity, and generation immediately before mutation; discard/recollect stale plans.

---

## Bug 7: SNP spawn failure leaks an attached phantom thread and can block process quiescence

- **Scenario**: 4 — clone transaction and ownership transfer
- **Severity**: High
- **Invariant violated**: `CloneFailureAtomic`, `ThreadCountMatchesAttachments`
- **Config**: `MC_hunt_scenario_4_clone_failure_atomic.cfg`, `MC_hunt_scenario_4_clone_transaction.cfg`
- **Counterexample**: 7 states, `spec/output/MC_hunt_scenario_4_clone_failure_atomic_bfs.out`
- **Filed duplicate status**: No issue or PR for the SNP error-side ownership/attachment leak was found.
- **Maintainer awareness**: No rollback TODO or error-path comment exists at the affected sites.
- **Newly demonstrated consequence**: A failed clone returns `ENOMEM` but leaves `nr_threads == 2`, a phantom thread-map entry, and an unreclaimed raw init box; `wait_for_exit` and exec's `kill_other_threads` can wait forever.

### Trace Summary

1. Clone prepares and publishes a child TID.
2. `ThreadState::new_thread` inserts the child and increments `nr_threads`.
3. Ownership of the init object moves to the platform.
4. The SNP provider converts it with `Box::into_raw`, the fallible host call fails, and the caller returns `ENOMEM` without reconstructing the box or detaching the child.

### Root Cause

Attachment is committed before the fallible platform spawn. On normal destruction, `ThreadState::drop` detaches and decrements the count, but the SNP error path loses ownership of the raw `ThreadStartArgs`; therefore that destructor never runs. The caller cannot roll back because it transferred the box into `spawn_thread`.

### Affected Code

- `litebox_shim_linux/src/syscalls/process.rs:66`: attach in `ThreadState::new_thread`
- `litebox_shim_linux/src/syscalls/process.rs:207`: `nr_threads` consumers and attachment accounting
- `litebox_shim_linux/src/syscalls/process.rs:700`: attach/transfer before spawn result
- `litebox_platform_linux_kernel/src/host/snp/snp_impl.rs:250`: raw-pointer transfer before fallible host syscall

### Recommendation

Define error-side ownership in the `ThreadProvider` contract. On SNP failure, reconstruct/drop the raw box so `ThreadState::drop` detaches, or delay process attachment until platform spawn has committed.

---

## Bug 8: Failed clone3 stack validation leaves a phantom child TID in parent memory

- **Scenario**: 4 — clone publication before commit
- **Severity**: Medium
- **Invariant violated**: `CloneFailureAtomic`
- **Config**: `MC_hunt_scenario_4_parent_tid.cfg`
- **Counterexample**: 4 states, `spec/output/MC_hunt_scenario_4_parent_tid_bfs.out`
- **Filed duplicate status**: No report covers the failure-side write. [PR #366](https://github.com/microsoft/litebox/pull/366) fixes success-path parent/child TID ordering, not validation failure atomicity.
- **Maintainer awareness**: Parent-TID ordering is a known sensitive area, but the current post-write stack check has no rollback or warning.
- **Newly demonstrated consequence**: `clone3` returns `EINVAL` while caller memory contains a non-existent child TID.

### Trace Summary

1. Clone allocates `t1` and writes it through `PARENT_SETTID`.
2. The subsequent clone3 stack/stack-size combination is invalid.
3. The syscall returns failure with no child attached, but `parent_tid` remains `t1`.

### Root Cause

The parent-memory publication is ordered before clone3 stack validation. The validation error returns directly and does not restore the previous user-memory value.

### Affected Code

- `litebox_shim_linux/src/syscalls/process.rs:685`: parent TID publication
- `litebox_shim_linux/src/syscalls/process.rs:690`: later stack validation and direct `EINVAL` return

### Recommendation

Complete all local validation before writing `parent_tid`, and publish caller-visible outputs only after the clone transaction can commit.

---

## Bug 9: An unvalidated futex waiter can consume wake(1) while a validated waiter remains blocked

- **Scenario**: 5 — futex validation and wake quota
- **Severity**: High
- **Invariant violated**: `WakeCountsValidatedWaiters`
- **Config**: `MC_hunt_scenario_5_futex_quota.cfg`
- **Counterexample**: 8 states, `spec/output/MC_hunt_scenario_5_futex_quota_bfs_run3.out`
- **Filed duplicate status**: Open [PR #1228](https://github.com/microsoft/litebox/pull/1228) concerns a post-validation store-buffering lost wake; it is a different mechanism.
- **Maintainer awareness**: Source comments intentionally insert before reading the futex word to avoid a missed wake, but do not account for quota selection before validation.
- **Newly demonstrated consequence**: `wake(1)` returns 1 after selecting a waiter that later returns mismatch, while a genuinely validated waiter remains queued indefinitely unless another wake/timeout occurs.

### Trace Summary

1. `t0` inserts with expected value 1 while the actual word is 0, but has not compared yet.
2. `t1` inserts with expected value 0 and reaches `validated_waiting` behind `t0`.
3. `wake(1)` selects queue head `t0`, exhausts its quota, and removes it.
4. `t0` compares and returns mismatch; wake completes with return count 1, while `t1` remains validated and blocked in the queue.

### Root Cause

`wait` inserts its `FutexEntry` before the value check. `wake` selects solely by address/bitset and counts a selected list entry immediately; `FutexEntry` has no validated phase visible to the wake predicate. Queue order therefore lets a non-waiter consume the finite quota.

### Affected Code

- `litebox/src/sync/futex.rs:96`: list insertion before comparison
- `litebox/src/sync/futex.rs:108`: post-insertion value validation
- `litebox/src/sync/futex.rs:145`: quota-limited selection without validation state

### Recommendation

Make registration plus value validation atomic with respect to wake selection, or add an explicit validated/eligible phase that `wake` ignores until the comparison succeeds.

---

## Known / Maintainer-Aware Observation (not counted as a new bug)

`MC_hunt_scenario_3_mapping_generation.cfg` first found a `HostVmemAgreement` violation: a CoW host replacement interleaves with `mprotect`, then registration overwrites Vmem with stale permissions. The host/register split is documented in source and was explicitly discussed in [PR #669](https://github.com/microsoft/litebox/pull/669#discussion_r2835723344). This run did not add a consequence beyond the previously demonstrated host/Vmem permission divergence, so it is classified as known/maintainer-aware technical debt and excluded from `findings.json`. Its output remains at `spec/output/MC_hunt_scenario_3_mapping_generation_bfs.out`.

## Coverage by Config

| Scenario | Config | Generated | Distinct | Diameter | Result |
|---|---|---:|---:|---:|---|
| 1 | `MC_hunt_scenario_1_namespace.cfg` | 221 | 168 | 6 | `ReachableCreate` (same root cause as Bug 1) |
| 1 | `MC_hunt_scenario_1_reachable_create.cfg` | 95 | 67 | 4 | Bug 1 |
| 1 | `MC_hunt_scenario_1_cwd_identity.cfg` | 1,661 | 909 | 7 | Bug 2 |
| 2 | `MC_hunt_scenario_2_fd_identity.cfg` | 647 | 392 | 6 | Bug 3 |
| 2 | `MC_hunt_scenario_2_alias_offsets.cfg` | 281 | 159 | 8 | Bug 4 |
| 2 | `MC_hunt_scenario_2_epoll_interest.cfg` | 122 | 86 | 6 | Bug 5 |
| 3 | `MC_hunt_scenario_3_mapping_generation.cfg` | 67 | 54 | 5 | Known/maintainer-aware observation |
| 3 | `MC_hunt_scenario_3_stale_patch_plan.cfg` | 81 | 66 | 6 | Bug 6 |
| 4 | `MC_hunt_scenario_4_clone_failure_atomic.cfg` | 8 | 7 | 7 | Bug 7 |
| 4 | `MC_hunt_scenario_4_clone_transaction.cfg` | 8 | 7 | 7 | Bug 7 (second oracle) |
| 4 | `MC_hunt_scenario_4_parent_tid.cfg` | 10 | 9 | 8 | Bug 8 |
| 5 | `MC_hunt_scenario_5_futex_quota.cfg` | 1,772 | 879 | 8 | Bug 9 after Case A oracle refinement |

Every BFS found a violation, so the workflow's “no violation and diameter ≤ 25” condition for simulation follow-up never applied.

## Not Reproduced

| Scenario | Config | States Explored | Result |
|---|---|---:|---|
| None | — | — | Every focused config produced a classified violation; no scenario remained untested. |

## Spec Fixes During Hunting

- Refined `WakeCountsValidatedWaiters` twice as Case A invariant mismatches: first to wait for an actual mismatch, then to require the target live consequence of a validated waiter remaining blocked.
- Added focused CWD, stale-patch-plan, and parent-TID configs to prevent earlier counterexamples from masking independent mechanisms.

