# LiteBox instrumentation specification

This document is the handoff contract for a Category B timebox harness matching `Trace.tla`. Every row below is a one-to-one mapping: the event string is identical to the base-spec action name, and no event is shared by two actions.

## 1. Trace event schema

Raw instrumentation writes one per-thread NDJSON file with no shared writer lock:

```json
{
  "tag": "trace",
  "event": "TaskChunkedReadChunk",
  "tid": "t1",
  "start": 101,
  "end": 104,
  "args": {"fd": "fd0"},
  "state": {"chunk_ofd": "ofd0", "chunks_done": 1}
}
```

Required envelope fields:

| Field | Type | Meaning |
|---|---|---|
| `tag` | string | Always `trace`. |
| `event` | string | Exact action/event name from the table below. |
| `tid` | string | Stable harness thread ID, mapped to `t0`--`t2`. |
| `start`, `end` | integer | Tight operation interval from fenced `rdtsc`; portable fallback is a monotonic raw clock. |
| `args` | object | IDs and inputs read before or during the modeled action. |
| `state` | object | Post-action fields captured after `end`; every listed field is checked by `ValidatePostState`. |

The raw writers must be thread-local. ID lookup must use a thread-local cache on the hot path; a global registry lock is allowed only on first encounter. Capture IDs/arguments before ownership is dropped. Capture state after `end`, then serialize and emit after releasing LiteBox locks.

The preprocessor filters `tag == "trace"`, sorts each thread's own events in emission order, compresses all `start`/`end` timestamps to dense positive integers, and writes one JSON object as one line in `../traces/trace.ndjson`:

```json
{"threads":["t0","t1","t2"],"events":{"t0":[...],"t1":[...],"t2":[...]}}
```

Stable IDs use the configured finite names: nodes `root_node`, `parent_node`, `cwd_node`, `node3`--`node5`; paths `root_path`, `parent_path`, `cwd_path`, `child_path`; fds `fd0`--`fd1`; OFDs `ofd0`--`ofd1`; mapping address `addr0`. Focused harness cases must stay within these bounds. `no_*` is reserved for absent values. Permissions serialize as `R`, `RW`, or `RX`; PCs, phases, owners, and results use the literal strings in `base.tla`.

## 2. Action-to-code mapping

### Scenario 1: namespace identity

| Spec action / event | Code location and exact trigger | `args` fields | Post-state fields |
|---|---|---|---|
| `ResolverParentDirAndName` | `litebox/src/fs/resolver.rs:214-232`, around `walk_to_directory`; `litebox/src/fs/in_mem.rs:249-293`, after the final `WalkOutcome` is produced and traversal read guards are gone | `path` | `pc_after`, `walked_parent`, `walked_path` |
| `InMemRmdirAt` | `litebox/src/fs/in_mem.rs:556-570`, bracket the successful `parent.children.remove(name)` while the parent write guard is held; emit after dropping it | `path`, `victim` | `namespace_binding`, `victim_alive`, `victim_parent` |
| `InMemRecreateAt` | `litebox/src/fs/in_mem.rs:478-505` for file recreation and `:508-538` for directory recreation; record immediately after successful `children.insert`, emit after guard release | `path`, `node` | `namespace_binding`, `node_alive`, `node_parent` |
| `InMemCreateFileAt` | `litebox/src/fs/in_mem.rs:478-505`, bracket the final existence check plus `children.insert`; caller path is `resolver.rs:575-611` | `node` | `pc_after`, `child_binding`, `node_alive`, `node_parent`, `create_result`, `created_node` |
| `TaskSysChdirValidate` | `litebox_shim_linux/src/syscalls/file.rs:1755-1782`, from normalized target creation through successful directory `file_status` validation | `path` | `pc_after`, `cwd_candidate`, `walked_path` |
| `TaskSysChdirPublish` | `litebox_shim_linux/src/syscalls/file.rs:1784-1785`, bracket `context.write().set_cwd(target)` | none | `pc_after`, `cwd_node`, `cwd_path` |
| `TaskResolvePathRelative` | `litebox_shim_linux/src/syscalls/file.rs:205-228`, bracket `cwd_prefix` plus append for a relative path | none | `relative_node` |

For node identity, instrument the `Arc` allocation identity, not just the pathname. `cwd_node` is the node observed during chdir validation; `relative_node` is the node reached when a later relative operation re-resolves `cwd_path`.

### Scenario 2: raw fd and OFD identity

| Spec action / event | Code location and exact trigger | `args` fields | Post-state fields |
|---|---|---|---|
| `TaskChunkedReadBegin` | `litebox_shim_linux/src/lib.rs:588-628`, immediately after large-read setup; `syscalls/file.rs:599-624` for sendfile and `:938-956` for readv | `fd` | `pc_after`, `op_fd`, `op_ofd`, `last_chunk_ofd`, `chunks_done` |
| `TaskChunkedReadChunk` | `litebox_shim_linux/src/lib.rs:516-541`, one `sys_read` chunk; `syscalls/file.rs:625-648`, one sendfile `run_on_raw_fd`; `syscalls/mm.rs:287-304`, one fallback mmap page read | `fd` | `chunk_ofd`, `chunks_done` |
| `TaskChunkedReadFinish` | `litebox_shim_linux/src/lib.rs:542-543` or `syscalls/file.rs:683-688`, immediately before the logical syscall returns | none | `pc_after` |
| `FilesStateCloseSlot` | `litebox_shim_linux/src/syscalls/file.rs:799-847`, bracket successful `fd_consume_raw_integer`; implementation primitive is `litebox/src/fd/mod.rs:683-691` | `fd`, `old_ofd` | `slot_ofd`, `fd_generation`, `old_ofd_refs`, `dir_offset` |
| `FilesStateReuseSlot` | `litebox/src/fd/mod.rs:640-663`, bracket successful `fd_into_specific_raw_integer`; ordinary insertion is `shim file.rs:112-135` | `fd`, `ofd` | `slot_ofd`, `fd_generation`, `ofd_refs`, `dir_offset` |
| `DescriptorsDuplicate` | `litebox/src/fd/mod.rs:84-105`, bracket shared-entry clone, plus raw publication at `litebox_shim_linux/src/syscalls/file.rs:2460-2481` | `source`, `target` | `target_ofd`, `target_generation`, `ofd_refs`, `target_dir_offset` |
| `TaskSysGetdirent64Load` | `litebox_shim_linux/src/syscalls/file.rs:2592-2598`, bracket `with_metadata` load | `fd` | `pc_after`, `dir_fd`, `dir_cursor` |
| `TaskSysGetdirent64Produce` | `litebox_shim_linux/src/syscalls/file.rs:2604-2643`, bracket one successfully copied entry and `dir_off += 1` | none | `pc_after`, `dir_cursor` |
| `TaskSysGetdirent64Store` | `litebox_shim_linux/src/syscalls/file.rs:2644-2648`, bracket `set_fd_metadata` | `fd` | `pc_after`, `dir_offset` |
| `EpollFileAddInterest` | `litebox_shim_linux/src/syscalls/epoll.rs:232-265`, bracket successful `interests.insert`; key identity is constructed at `:327-340` | `fd`, `ofd` | `interest_count` |

`op_ofd` is captured at logical-operation entry. `chunk_ofd` is captured after each actual `run_on_raw_fd` lookup, not inferred from the entry value. An OFD ID denotes the shared typed descriptor entry/`Arc` identity. Generation increments in the harness shadow table on every slot consume or publish.

### Scenario 3: mapping generation and patch plans

| Spec action / event | Code location and exact trigger | `args` fields | Post-state fields |
|---|---|---|---|
| `TaskDoMmapFileHost` | `litebox_shim_linux/src/syscalls/mm.rs:234-245`, bracket successful `try_allocate_cow_pages`; for the fallback use the platform allocation inside `do_mmap` before page copying | `addr`, `perm` | `pc_after`, `host_mapped`, `host_generation`, `host_perm`, `map_generation`, `local_addr`, `local_generation`, `local_perm` |
| `PageManagerRegisterExistingMapping` | `litebox_shim_linux/src/syscalls/mm.rs:246-261`, bracket the call; implementation commit is `litebox/src/mm/mod.rs:608-625` | `addr` | `pc_after`, `vmem_mapped`, `vmem_generation`, `vmem_perm`, `patch_generation` |
| `TaskSysMunmap` | `litebox_shim_linux/src/syscalls/mm.rs:379-411`, from successful `sys_munmap_raw` through cache tuple removal | `addr` | `host_mapped`, `vmem_mapped`, `patch_generation` |
| `TaskMaybePatchOnMprotectExecCollect` | `litebox_shim_linux/src/syscalls/mm.rs:489-508`, bracket construction of `to_patch`; end before the cache guard is dropped | `addr` | `pc_after`, `plan_addr`, `plan_generation`, `patch_applied` |
| `TaskMaybePatchExecSegmentApply` | `litebox_shim_linux/src/syscalls/mm.rs:522-535`, bracket one call to `maybe_patch_exec_segment`; application internals begin at `:768-789` and mutate at `:930-969` | none | `pc_after`, `patch_applied`, `plan_generation`, `host_generation` |
| `TaskSysMprotectRaw` | `litebox_shim_linux/src/syscalls/mm.rs:435-441`, bracket the raw call; host update and Vmem split are in `litebox/src/mm/linux.rs:758-800` | `addr`, `perm` | `host_perm`, `vmem_perm` |

Maintain a generation shadow map keyed by page-aligned address. Increment it after every successful replacement mapping. Store that generation in the tracking interval shadow record and in the collected patch-plan event. Do not derive `plan_generation` at apply time; that would erase the stale-plan evidence.

### Scenario 4: clone transaction and ownership

| Spec action / event | Code location and exact trigger | `args` fields | Post-state fields |
|---|---|---|---|
| `TaskDoClonePrepare` | `litebox_shim_linux/src/syscalls/process.rs:568-685`, from flag/TLS validation completion through `next_thread_id.fetch_add` | `child` | `pc_after`, `clone_child`, `parent_tid`, `spawn_result` |
| `TaskDoClonePublishParentTid` | `litebox_shim_linux/src/syscalls/process.rs:685-688`, bracket `parent_tid_ptr.write_at_offset` | none | `pc_after`, `parent_tid` |
| `TaskDoCloneStackValidationSuccess` | `litebox_shim_linux/src/syscalls/process.rs:690-698`, after the stack combination passes and SP is calculated | none | `pc_after` |
| `TaskDoCloneStackValidationFailure` | `litebox_shim_linux/src/syscalls/process.rs:690-692`, immediately before returning `EINVAL` | none | `pc_after`, `spawn_result`, `parent_tid` |
| `ThreadStateNewThread` | `litebox_shim_linux/src/syscalls/process.rs:66-75,207-218,700-706`, bracket successful process attachment and `nr_threads` increment | `child` | `pc_after`, `thread_count`, `init_owner` |
| `TaskDoCloneTransferInit` | `litebox_shim_linux/src/syscalls/process.rs:708-727`, end immediately after the `Box<NewThreadArgs>` move into `spawn_thread`, before the provider result is inspected | `child` | `pc_after`, `init_owner` |
| `SnpLinuxKernelSpawnThreadSuccess` | `litebox_platform_linux_kernel/src/host/snp/snp_impl.rs:264-275`, after successful host syscall; ownership is consumed by `thread_start` at `:151-162` | `child` | `pc_after`, `init_owner`, `spawn_result` |
| `SnpLinuxKernelSpawnThreadFailure` | `litebox_platform_linux_kernel/src/host/snp/snp_impl.rs:264-274`, on the error edge after `Box::into_raw`; caller returns at `shim process.rs:728-733` | `child` | `pc_after`, `attached`, `committed`, `init_owner`, `spawn_result` |
| `ProcessDetachThread` | `litebox_shim_linux/src/syscalls/process.rs:221-249`, bracket thread-map removal and `nr_threads` decrement | `child` | `attached`, `committed`, `thread_count`, `init_owner` |

The ownership shadow value changes `none -> caller -> platform -> child` on success. On SNP error it intentionally remains `platform` unless the implementation is repaired to reconstruct/drop the raw box. `committed` means the platform spawn succeeded, not merely that `Process::threads` contains the child.

### Scenario 5: futex waiter validation and quota

| Spec action / event | Code location and exact trigger | `args` fields | Post-state fields |
|---|---|---|---|
| `FutexManagerWaitInsert` | `litebox/src/sync/futex.rs:96-106`, bracket `entry.as_mut().insert(bucket)`; list primitive is `utilities/loan_list.rs:92-104` | `expected` | `waiter_phase`, `waiter_expected`, `queue_len` |
| `FutexManagerWaitCompareMatch` | `litebox/src/sync/futex.rs:108-118`, after the load compares equal and before `wait_until` | none | `waiter_phase`, `queue_len` |
| `FutexManagerWaitCompareMismatch` | `litebox/src/sync/futex.rs:108-113`, mismatch return edge; include automatic list removal at `loan_list.rs:129-180` | none | `waiter_phase`, `queue_len` |
| `FutexManagerWakeBegin` | `litebox/src/sync/futex.rs:135-149`, just before `extract_if` begins | none | `pc_after`, `wake_budget`, `wake_count`, `wake_return`, `had_unvalidated`, `selected_count` |
| `FutexManagerWakeSelect` | `litebox/src/sync/futex.rs:149-159`, one closure decision that returns `true`; list removal is `loan_list.rs:251-285` | `selected_waiter` | `pc_after`, `selected_phase`, `queue_len`, `selected_count`, `wake_count`, `had_unvalidated` |
| `FutexManagerWakeComplete` | `litebox/src/sync/futex.rs:160-166`, after `done.store`, `waker.wake`, and final return-count publication | `selected_waiter` | `pc_after`, `selected_count`, `wake_return`, `waiter_phase` |
| `FutexManagerWaitReturn` | `litebox/src/sync/futex.rs:111-119`, immediately as `wait` returns mismatch or success | none | `waiter_phase` |
| `FutexSetValue` | focused harness write immediately before/after the real atomic/shared futex-word store that races with `futex.rs:108-110` | `value` | `futex_value` |

Do not write trace output from inside the `LoanList` lock or the `extract_if` closure. Record small thread-local pending markers/timestamps there, then capture the post-state and emit after extraction/loan completion. Preserve one `FutexManagerWakeSelect` event per selected entry even though current hunts use `wake(1)`.

## 3. Special considerations

- **Tight timeboxes:** Put `start` immediately before the modeled atomic/locked step and `end` immediately after it. Argument preparation, state snapshotting, JSON formatting, and file I/O stay outside the interval.
- **No hidden serialization:** Audit the trace module for hot-path `Mutex`, `RwLock`, and global `fetch_add`. Resource-ID registration may lock only on a first encounter and must then be cached per thread.
- **State access:** Never acquire LiteBox locks in an order different from production merely to collect a snapshot. Prefer existing values and shadow state updated at the same commit point. If a snapshot needs a production lock, capture it after the interval and after all production guards have been released.
- **Ownership/error paths:** Capture raw-pointer identity before `Box::into_raw`; the failure event must be emitted without reconstructing the pointer, because reconstruction would change the behavior under test.
- **Bootstrap:** `TraceInit` assumes the configured root/parent/CWD nodes, one `fd0 -> ofd0` binding, one tracked `addr0` generation, one committed main thread `t0`, and no futex waiters. Focused tests must emit only after creating that bootstrap or the preprocessor must prepend a bootstrap record that the runner converts into these constants.
- **Trace quality:** Each action type must occur in at least one focused trace. At least one trace per scenario must contain genuine cross-thread interval overlap, and the futex trace must order an unvalidated insertion before a validated waiter while allowing wake selection to overlap the first waiter's comparison.
- **File selection:** Keep the default preprocessed trace at `../traces/trace.ndjson`; validation runners may select another file through `IOEnv.JSON`.
