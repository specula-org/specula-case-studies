# Confirmation Report — litebox

## Final Result

Reproduced bugs: 9 = 9 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 0
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Repaired: 0
Total disposition entries: 9
Dispositions: 9 total = 9 reproduced + 0 env-limited + 0 masked + 0 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred + 0 repaired
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | MC-4 | REPRODUCED | yes |
| 5 | MC-5 | REPRODUCED | yes |
| 6 | MC-6 | REPRODUCED | yes |
| 7 | MC-7 | REPRODUCED | yes |
| 8 | MC-8 | REPRODUCED | yes |
| 9 | MC-9 | REPRODUCED | yes |

## Entry 1: Detached-parent create returns success for an unreachable file

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: litebox/src/fs/resolver.rs:588

## Description
`Resolver::open(..., O_CREAT, ...)` can retain an `InMem` directory handle after walking the parent, while a concurrent `rmdir` unlinks that parent from the namespace. `InMem::create_file_at` then inserts the new file into the detached directory and returns `Ok(fd)`, so the caller receives a live file descriptor for a file with no reachable pathname.

## Trigger scenario
Thread A calls `open("/victim/child", O_CREAT | O_RDWR, ...)`. Thread B concurrently calls `rmdir("/victim")` after A has walked `/victim` but before A calls `create_file_at`. The MC trace matches this: State 2 walks `parent_path`, State 3 removes it, and State 4 records `createResult = "success"` while `namespace(child_path) = no_node`.

## Developer intent
The resolver comment at `litebox/src/fs/resolver.rs:219-221` says the walking handle is intended to let backends keep “walk parent + mutate child” atomic. `InMem::walk_directories` only clones the child directory `Arc` and drops the map read lock; `owned_dir_at` and `create_file_at` do not revalidate reachability. Upstream issue/PR searches for this exact create/rmdir detached-parent mechanism and recent filesystem PR history found no same-site report or fix.

## Reproduction result
Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**, Level 0.
2. Level 2/3 precondition sequence: **N/A**.
3. Real consumer/caller: `Resolver::open` returns `Ok(fd)`; syscall users would observe this through `Task::sys_open` at `litebox_shim_linux/src/syscalls/file.rs:324-328`.
4. Permanent or masked: **permanent while the fd exists**; no downstream mechanism re-links the file or converts the success into an error.

Test written and executed: `/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-1_detached_parent_create.sh`

Command:
```text
timeout 15m /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-1_detached_parent_create.sh
```

Output excerpt:
```text
running 1 test
test fs::tests::specula_mc1_detached_parent_create::mc1_detached_parent_create_repro ... MC-1 Level 0: racing open(O_CREAT|O_RDWR) against rmdir on a shallow empty parent
MC-1 BUG TRIGGERED: RaceOutcome { level: "level0", attempt: 35, depth: 1, remover_delay_ns: 0, create_result: "Ok(fd)", rmdir_result: "Ok(())", write_result: "Ok(3)", fd_status_result: "Ok(ino=41, size=3); close=Ok(())", child_reachable_after: false, parent_reachable_after: false }
ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 131 filtered out; finished in 0.01s
```

The demonstrating line is `MC-1 BUG TRIGGERED`: both `open` and `rmdir` returned success, the fd accepted a write and fd stat, but both parent and child were unreachable by path.

## Recommendation
Make `InMem` preserve namespace identity across resolve-then-mutate operations. A straightforward fix is to hold a backend namespace guard or parent map lock from parent walk through `create_file_at`/`rmdir_at`, or revalidate that the walked parent is still linked immediately before mutating it and fail the create if it was detached.

---

## Entry 2: Pathname recreation silently redirects relative operations from the current directory

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: litebox_shim_linux/src/syscalls/file.rs:205

## Description

MC-2 is reproduced. LiteBox stores CWD as normalized pathname text in `Context`/`ResolvedPath`, then `cwd_prefix()` reserializes that text for later relative operations. If the pathname is removed and recreated, later relative `open/openat` resolves into the replacement directory instead of preserving the original CWD identity or failing.

## Trigger scenario

Level 0 normal syscall-handler sequence:

1. `mkdirat(AT_FDCWD, "/mc2_recreated_cwd")`
2. `chdir("/mc2_recreated_cwd")`
3. `unlinkat(AT_FDCWD, "/mc2_recreated_cwd", AT_REMOVEDIR)`
4. `mkdirat(AT_FDCWD, "/mc2_recreated_cwd")`
5. write `/mc2_recreated_cwd/attacker.txt`
6. `open("attacker.txt", O_RDONLY)` from the original task’s stale CWD

The relative open/read returns the recreated directory’s file.

## Developer intent

I searched upstream issues, closed/merged PRs, PR comments, and git history for CWD/chdir/getcwd/rmdir/unlinkat/resolve_path/cwd_prefix/recreate-directory terms. Relevant prior material includes #71, #696, #692, #622, #599, #450, and the recent merged PR #1231. These show broad CWD design awareness and the recent context refactor, but I found no filed report for this exact unlink/rmdir plus recreate CWD-identity rebinding mechanism.

## Reproduction result

Repro file written and executed:

`/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-2_cwd_rebind.sh`

Command:

```text
timeout 7m /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-2_cwd_rebind.sh
```

Output:

```text
COMMAND: timeout 5m cargo test -p litebox_shim_linux syscalls::file::tests::cwd_path_recreation_redirects_relative_open -- --nocapture
Finished `test` profile [unoptimized + debuginfo] target(s) in 10.65s
Running unittests src/lib.rs (target/debug/deps/litebox_shim_linux-0d050eed162d86d4)

running 1 test
STEP chdir: cwd stored as /mc2_recreated_cwd
STEP remove: original cwd pathname removed
STEP recreate: replacement directory now owns /mc2_recreated_cwd
STEP attacker: wrote payload to /mc2_recreated_cwd/attacker.txt
OBSERVED relative_read="replacement namespace payload"
OBSERVED replacement_path_stat=Ok(FileStat { st_dev: 2, st_ino: 5, st_nlink: 1, st_mode: 33152, st_uid: 0, st_gid: 0, __pad0: 0, st_rdev: 0, st_size: 29, st_blksize: 0, st_blocks: 0, st_atime: 0, st_atime_nsec: 0, st_mtime: 0, st_mtime_nsec: 0, st_ctime: 0, st_ctime_nsec: 0, __unused: [0, 0, 0] })
BUG_TRIGGERED: relative open after cwd pathname removal/recreation read replacement namespace file
test syscalls::file::tests::cwd_path_recreation_redirects_relative_open ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 88 filtered out; finished in 0.00s
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? yes, Level 0 triggered it through normal LiteBox filesystem syscall handlers.
2. Level 2/3 used? no.
3. Real consumer/caller observing wrong outcome: guest `Openat`/`open` and `read` path via `litebox_shim_linux/src/lib.rs:948`, `litebox_shim_linux/src/syscalls/file.rs:324`, and `litebox_shim_linux/src/syscalls/file.rs:428`.
4. Permanent or masked? permanent until CWD changes or task exits; no downstream sync, loopback, resend, caller guard, or discard mechanism masked it.

## Recommendation

Store CWD as a stable directory identity/handle plus display path metadata, not only a normalized pathname. Relative operations should resolve against that stable directory object, or fail once the original directory is no longer usable; they must not rebind to a newly created node at the same pathname.

---

## Entry 3: One chunked syscall can consume multiple open-file descriptions after fd reuse

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: `litebox_shim_linux/src/syscalls/file.rs:991`

## Description
Confirmed. `sys_readv` validates the raw fd once, then `read_from_iovec` calls `self.sys_read(fd, ...)` again for each iovec chunk. If another task sharing `FilesState` closes and reopens the same raw fd between chunks, one `readv` can return bytes from two different open-file descriptions.

## Trigger scenario
A cloned task shares the fd table. Task A starts `readv` on a blocking pipe read fd. Task B closes that raw fd, opens a regular file that reuses the same slot, then writes to the original pipe writer. Task A’s first iovec receives pipe data, and the same `readv` call’s second iovec receives data from the replacement file.

## Developer intent
I found comments acknowledging generic raw-fd ABA limits and vectored-I/O atomicity TODOs, plus related fd-table race reports for `do_dup_inner`, `pipe2`, and `socketpair`. I did not find an upstream issue or closed/merged PR for this same repeated raw-fd lookup mechanism at the chunked syscall sites.

## Reproduction result
Repro written and executed: `/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-3_readv_fd_reuse.sh`

Command:
```text
timeout 12m /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-3_readv_fd_reuse.sh
```

Output:
```text
RUN: timeout 10m cargo test -p litebox_shim_linux mc3_ --lib -- --nocapture --test-threads=1
   Compiling litebox_shim_linux v0.1.0 (/home/ubuntu/tmp/litebox-mc3-repro.mEhQou/worktree/litebox_shim_linux)
    Finished `test` profile [unoptimized + debuginfo] target(s) in 3.31s
     Running unittests src/lib.rs (/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-3/worktree/target/debug/deps/litebox_shim_linux-0d050eed162d86d4)

running 2 tests
test syscalls::file::tests::mc3_level0_black_box_probe_no_timing ... LEVEL0_PROBE result=Ok(8) replacement_fd=4 first="AAAA" second="BBBB"
ok
test syscalls::file::tests::mc3_level1_readv_fd_reuse_mixes_pipe_and_file ... LEVEL1_TRIGGER n=8 original_read_fd=4 writer_fd=3 replacement_fd=4 first="AAAA" second="BBBB"
BUG_TRIGGERED: one sys_readv read first iovec from the original pipe OFD and second iovec from the file reopened on the same raw fd
ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 88 filtered out; finished in 0.25s
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 0 observed it in this run; Level 1 deterministically triggered it with timing assistance only.
2. Level 2/3 not used.
3. Real consumer: the guest `readv(2)` caller via `SyscallRequest::Readv` at `litebox_shim_linux/src/lib.rs:714` and `sys_readv` at `litebox_shim_linux/src/syscalls/file.rs:991`; it receives mixed user buffers.
4. The bad result is permanent for that syscall return: `Ok(8)` and copied user buffers `AAAA`/`BBBB`; no downstream guard, retry, resend, or sync masks it.

## Recommendation
Resolve the raw fd once at syscall entry for chunked operations and carry a stable typed fd or entry handle across all chunks. Apply this to `readv`/`writev`/`preadv`/`pwritev`, large-read chunking, and `sendfile`; offset updates should also target the same captured OFD, not a later raw-fd lookup.

---

## Entry 4: Duplicated directory descriptors do not share their directory position

- **Finding ID**: MC-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-4/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: litebox_shim_linux/src/syscalls/file.rs:2765

## Description
`sys_getdirent64` stores the directory cursor as `Diroff` using `set_fd_metadata`, which is per descriptor. `Descriptors::duplicate` shares the underlying entry/OFD but creates a fresh fd-local metadata map, so a duplicated directory fd does not share the directory position even though `litebox/src/fd/mod.rs:70-76` documents duplicated fds as sharing offsets.

## Trigger scenario
Level 0, normal syscall sequence: open `/`, `dup` the directory fd, read one directory chunk from the original with `getdents64`, then read from the duplicate. The duplicate returns the same `[".", ".."]` chunk instead of continuing from the shared directory position.

## Developer intent
The fd duplication comment says duplicates share behavior including offsets, while fd metadata is explicitly not duplicated. Upstream search checked issues and recently merged/closed PRs for `getdents64`, `getdirent64`, `Diroff`, directory offset, and dup/OFD terms. PR #783 handles directory lseek/getdirent64 error behavior, and PR #801 handles dup error-code/close-reuse races, but neither reports this directory cursor aliasing mechanism.

## Reproduction result
Repro test written and executed:
`/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-4_dir_dup_offset.sh`

Command:
```text
timeout 12m /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-4_dir_dup_offset.sh
```

Captured output:
```text
MC-4 repro: source=/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-4/worktree
running 1 test
MC4_OBSERVED dir_fd=3 dup_fd=4 original_chunk=[".", ".."] duplicate_chunk=[".", ".."]

thread 'syscalls::tests::bug_mc4_dup_directory_descriptors_should_share_getdents_offset' (...) panicked at litebox_shim_linux/src/syscalls/tests.rs:825:5:
assertion `left != right` failed: duplicated directory fd repeated the same directory chunk; directory position is not shared across aliases
  left: [".", ".."]
 right: [".", ".."]

test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 88 filtered out
MC-4 repro: cargo_status=101
MC-4 RESULT: BUG REPRODUCED - dup alias repeated the first directory chunk
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**, Level 0.
2. Level 2/3 injection used? **no**.
3. Real consumer/caller: guest `getdents64` dispatch at `litebox_shim_linux/src/lib.rs:1113-1114`; the wrong repeated entries are written into the caller-provided `dirp` buffer by `sys_getdirent64`.
4. Permanent or masked? The per-fd cursor split persists until explicit caller reposition/close; no downstream sync, loopback, resend, or guard masks the bad returned directory entries.

## Recommendation
Store directory position as shared open-file-description state, not fd-local metadata. In this design that means moving `Diroff` reads/writes for directory `getdents64` and directory `lseek` onto shared entry metadata or an equivalent shared directory-handle cursor, while leaving fd-specific flags such as `FD_CLOEXEC` fd-local.

---

## Entry 5: Last-close epoll interests persist and accumulate across raw-fd reuse

- **Finding ID**: MC-5
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-5/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: litebox_shim_linux/src/syscalls/epoll.rs:246

Checklist before `REPRODUCED`:
1. Did Level 0 or Level 1 alone trigger it? **yes**. The trigger used normal LiteBox syscalls: `epoll_create`, `pipe2`, `epoll_ctl(ADD)`, `close`, then raw-fd reuse through another `pipe2`.
2. Level 2/3 used? **No**. The test-only module only inspected retained state after public calls; it did not inject state or alter system logic.
3. Real consumer/caller observing wrong outcome: the epoll runtime state owned by `EpollFile.interests` at `litebox_shim_linux/src/syscalls/epoll.rs:170` and populated at `litebox_shim_linux/src/syscalls/epoll.rs:278`; the retained stale entries are later skipped, not removed, by `EpollEntry::poll` / `ReadySet::pop_multiple` at `litebox_shim_linux/src/syscalls/epoll.rs:397` and `:468`.
4. Permanent or masked? **Permanent while the epoll fd remains open**. The stale weak-entry skip masks wrong readiness delivery, but it does not resolve the retained interest-map entries.

## Description

`EpollFile::add_interest` assumes a stale entry left after close will be replaced by a later insert, but the key is `(raw fd, descriptor pointer)`. When the raw fd number is reused for a new descriptor, the pointer changes, so the stale entry remains and each add inserts another dead interest. This is a reproduced resource-retention bug, not a wrong-event-delivery bug.

## Trigger scenario

Create an epoll fd, create a pipe, add the pipe read fd to epoll, close both pipe fds, then create another pipe. LiteBox reuses the same raw read-fd number through normal allocation, and adding it again leaves the previous dead entry in `EpollFile.interests`.

Repro artifact executed: `/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-5_epoll_fd_reuse.sh`.

## Developer intent

The source comment at `epoll.rs:246-247` explicitly acknowledges stale entries after close, but says a later insert will replace them. That intent fails for raw-fd reuse because `EpollEntryKey` also includes the descriptor pointer. Prior-report search covered GitHub issues and open/closed PRs; PR #1230 is related but only covers dup-surviving epoll interest lifetime, not last-close raw-fd reuse accumulation: https://github.com/microsoft/litebox/pull/1230.

## Reproduction result

Command:

```sh
timeout 8m /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-5_epoll_fd_reuse.sh
```

Output:

```text
running 1 test
round=1 recycled_fd=5 write_fd=4 retained_interests=1 stale_interests=1
round=2 recycled_fd=5 write_fd=4 retained_interests=2 stale_interests=2
round=3 recycled_fd=5 write_fd=4 retained_interests=3 stale_interests=3
round=4 recycled_fd=5 write_fd=4 retained_interests=4 stale_interests=4
round=5 recycled_fd=5 write_fd=4 retained_interests=5 stale_interests=5
round=6 recycled_fd=5 write_fd=4 retained_interests=6 stale_interests=6

assertion `left == right` failed: MC-5 reproduced: stale interests retained after last close
  left: (6, 6)
 right: (0, 0)

cargo_status=101
MC-5 reproduced: public syscalls left stale epoll interests after last close and raw-fd reuse
```

## Recommendation

Clean epoll interests on the last close of the watched open file description, not just on `EPOLL_CTL_DEL`. If PR #1230 moves identity to OFD handles, still add a cleanup/prune path for dead interests so last-close entries cannot accumulate across raw-fd reuse.

---

## Entry 6: A stale ELF patch plan can rewrite a newer fixed-address mapping

- **Finding ID**: MC-6
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-6/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: litebox_shim_linux/src/syscalls/mm.rs:617

## Description

Confirmed. The stale patch plan is reachable through normal `mmap`/`mprotect` syscall paths. The MC trace shows a stale plan generation applied to a newer host generation; the live code has an even stronger Level 0 form: a completed `MAP_FIXED` replacement does not clear the old ELF `file_mappings`, so a later `mprotect(PROT_EXEC)` applies the old fd’s patch state to the replacement mapping.

## Trigger scenario

1. Map a read-only file-backed ELF page, creating `ElfPatchState.file_mappings`.
2. Replace the same address with a different read-only file using `mmap(MAP_FIXED)`.
3. Call `mprotect(addr, len, PROT_READ|PROT_EXEC)`.
4. `maybe_patch_on_mprotect_exec` collects the stale old mapping and `maybe_patch_exec_segment` rewrites the bytes currently at that address, which now belong to the replacement mapping.

## Developer intent

PR #669 and the source comment at `mm.rs:282-286` acknowledge an adjacent CoW publication race as “theoretical” and “benign,” but do not mention this patch-cache consumer or byte-rewrite consequence. Searches of upstream issues and closed/merged PRs for `file_mappings`, `elf_patch_cache`, `MAP_FIXED mprotect`, and stale runtime patching found only related-but-different reports, notably issue #1006 and PR #1007 for anonymous exec-transition bypass.

## Reproduction result

Repro written and executed: `/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-6_stale_patch_plan.sh`

```text
COMMAND: timeout 10m cargo test -p litebox_shim_linux bug_mc6_stale_patch_plan_level0_public_syscalls -- --nocapture --test-threads=1
   Compiling litebox_shim_linux v0.1.0 (/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-6/worktree/litebox_shim_linux)
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.73s
     Running unittests src/lib.rs (target/debug/deps/litebox_shim_linux-0d050eed162d86d4)

running 1 test
test syscalls::bug_mc6_repro::bug_mc6_stale_patch_plan_level0_public_syscalls ... MC6_LEVEL0_SEQUENCE=old_elf_mmap_R -> victim_mmap_MAP_FIXED_R -> mprotect_RX
mapped_addr=0x7ffe19030000
old_mapping_window_before_replace=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
victim_window_before_mprotect=90 90 90 90 90 90 90 90 0f 05 c3 90 90 90 90 90 90 90 90 90 90 90 90 90
victim_window_after_mprotect=90 90 90 90 90 e9 86 0f 00 00 c3 90 90 90 90 90 90 90 90 90 90 90 90 90
syscall_bytes_before=0f 05
syscall_bytes_after=00 00
mprotect_result=Ok(())
MC6_LEVEL0_REPRODUCED=stale ELF patch plan rewrote replacement mapping
ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 88 filtered out; finished in 0.00s

EXIT_STATUS: 0
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 0 public syscall sequence triggered it; no timing help, state injection, or source patch was used.
2. Level 2/3 precondition: not applicable.
3. Real consumer/caller: `Task::sys_mprotect` via `litebox_shim_linux/src/lib.rs:700` and `litebox_shim_linux/src/syscalls/mm.rs:492`; it returns `Ok(())` after `maybe_patch_on_mprotect_exec` rewrites the replacement mapping.
4. The bad state is **permanent** until the mapping is overwritten or unmapped. No downstream sync, loopback, resend, or guard restores the replacement bytes.

## Recommendation

Clear or revalidate ELF patch-cache ranges on every fixed-address replacement, not only explicit `munmap`. The patch plan should carry and check mapping identity/generation before `maybe_patch_exec_segment` writes, and `MAP_FIXED` replacement should remove stale `file_mappings`/`patched_ranges` for the replaced address range.

---

## Entry 7: SNP spawn failure leaks an attached phantom thread and can block process quiescence

- **Finding ID**: MC-7
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-7/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: `litebox_platform_linux_kernel/src/host/snp/snp_impl.rs:268`

## Description
`do_clone` attaches the child thread and increments `nr_threads` before calling the platform spawn path. The SNP platform then moves `ThreadStartArgs` through `Box::into_raw`; if the host `clone3` call fails, `result?` returns without reconstructing/dropping that box, so the child `ThreadState` never detaches. The leaked phantom thread is visible through `sys_sysinfo().procs` and can block process quiescence through `wait_for_exit` / exec thread-kill waiting.

## Trigger scenario
A valid guest `clone3` reaches `ThreadState::new_thread`, publishes/attaches the child, and transfers the boxed child task to the SNP platform. The SNP host `clone3` request then fails, matching counterexample State 7: `MCSnpLinuxKernelSpawnThreadFailure(t0)`, with `threadCount = 2`, `initOwner[t1] = "platform"`, and only `t0` committed.

## Developer intent
No same-site report was found. Targeted open/closed issue and PR searches for `SnpLinuxKernel spawn_thread failure`, `ThreadStartArgs Box::into_raw`, and `clone3 ENOMEM nr_threads` were empty; `spawn_thread` matches such as issues #429/#202 and PRs #290/#423 discuss thread-start context/layering, not failed-spawn ownership rollback. Recent merged/closed `clone`/`thread` PRs since 2026-07-01 were also unrelated.

## Reproduction result
Repro written and executed: `/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-7_snp_spawn_failure_phantom.sh`

Escalation: Level 2. Level 0/1 cannot force the required SNP host-spawn failure in this Linux userland harness; the injected fault is the admissible MC step `MCSnpLinuxKernelSpawnThreadFailure(t0)` after a real `sys_clone3` call reaches the transfer point.

Command:
```bash
timeout 8m /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-7_snp_spawn_failure_phantom.sh
```

Output:
```text
Level 0: attempted normal/public clone path analysis in this harness; it cannot force the required SNP host clone3 failure, so it does not trigger MC-7.
Level 1: timing assistance is inapplicable; the bug is a deterministic failed-spawn cleanup path, not a race window.
Level 2: executing valid sys_clone3, then injecting the admissible counterexample step MCSnpLinuxKernelSpawnThreadFailure(t0) via the existing tla_trace clone override.
running: cargo test -p litebox_shim_linux --features tla_trace syscalls::tla_scenarios::test_bugmc7_spawn_failure_leaves_phantom_and_blocks_wait_for_exit -- --exact --nocapture --test-threads=1
running 1 test
test syscalls::tla_scenarios::test_bugmc7_spawn_failure_leaves_phantom_and_blocks_wait_for_exit ... initial sysinfo.procs: 1
initial process.nr_threads: 1
clone3 result: Err(Errno(12 = ENOMEM: Cannot allocate memory))
parent_tid after clone3: 3
sysinfo.procs after failed clone3: 2
process.nr_threads after failed clone3: 2
process.nr_threads after dropping only real task: 1
wait_for_exit observation: still blocked after 250 ms with nr_threads=1
ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 94 filtered out; finished in 0.25s
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? no.
2. Level 2 injection corresponds to counterexample State 7, `MCSnpLinuxKernelSpawnThreadFailure(t0)`, after the real `sys_clone3` path has attached/transferred the child.
3. Real consumer/caller: `Process::wait_for_exit` at `litebox_shim_linux/src/syscalls/process.rs:211`, reached by `LinuxShimProcess::wait` at `litebox_shim_linux/src/lib.rs:358`; `sys_sysinfo` also observes the wrong count at `litebox_shim_linux/src/syscalls/misc.rs:91`.
4. The bad state is permanent in the tested execution: after dropping the only real task, `nr_threads` remains `1`, and `wait_for_exit` is still blocked after 250 ms. No downstream guard or cleanup masks it.

## Recommendation
On SNP spawn failure, reconstruct/drop `thread_start_arg_ptr` before returning the error, or restructure `spawn_thread` so raw ownership is transferred only after the host call has succeeded. The clone path should leave failed child attachment rollback to normal `Drop`, or explicitly detach before returning `ENOMEM`.

---

## Entry 8: Failed clone3 stack validation leaves a phantom child TID in parent memory

- **Finding ID**: MC-8
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-8/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: litebox_shim_linux/src/syscalls/process.rs:715

## Description
`clone3` reaches `Task::do_clone`, derives `set_parent_tid`, allocates a child TID, and writes it to the caller’s `parent_tid` memory before validating the clone3 stack pair. For `stack != 0 && stack_size == 0`, LiteBox then returns `EINVAL` before `new_thread` or `spawn_thread`, so the caller observes a TID for a child that was never created.

## Trigger scenario
A normal guest program calls public syscall `clone3(&args, sizeof(args))` with `CLONE_VM | CLONE_THREAD | CLONE_SIGHAND | CLONE_FILES | CLONE_PARENT_SETTID`, a writable `parent_tid`, a nonzero stack address, and `stack_size = 0`. The invalid stack pair takes the existing `EINVAL` branch after the parent-TID write.

## Developer intent
Tracker/history search found no issue or recently closed/merged PR reporting this exact failure-side publication mechanism. Relevant nearby PRs are different: PR #158 added clone3/TID support, PR #366 fixed a success-path parent/child TID ordering race, and PR #508 made unsupported clone options return `EINVAL`; none documents or fixes a failed clone leaving `parent_tid` mutated.

## Reproduction result
Repro written and executed: `/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-8_clone3_parent_tid_failure.sh`

Command:
```sh
timeout 10m /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-8_clone3_parent_tid_failure.sh
```

Output:
```text
[build] gcc -static -O2 -Wall -Wextra -o /home/ubuntu/tmp/tmp.NyaPc0suDL/clone3_parent_tid_failure /home/ubuntu/tmp/tmp.NyaPc0suDL/clone3_parent_tid_failure.c
[run] timeout 5m cargo run -q -p litebox_runner_linux_userland -- --unstable --rewrite-syscalls /home/ubuntu/tmp/tmp.NyaPc0suDL/clone3_parent_tid_failure
clone3_ret=-1 errno=22 (Invalid argument) parent_tid_before=324478056 parent_tid_after=2
BUG_REPRODUCED: failed clone3 changed caller-visible parent_tid to 2
[litebox_exit] 0
[result] PASS: Level 0 public clone3 syscall reproduced MC-8
```

Checklist:
1. Level 0 alone triggered it: **yes**.
2. Level 2/3 injection or source patch: not used.
3. Real consumer/caller: the guest test’s public `syscall(SYS_clone3, ...)` at `test_bugMC-8_clone3_parent_tid_failure.sh:84`; it reads the wrong caller-visible value at lines 86 and 91-92.
4. The bad state is permanent until userspace overwrites it. No child was created, so no child cleanup/sync/loopback/resend can later correct `parent_tid`.

## Recommendation
Move clone3 stack-pair validation before child TID allocation/publication, or roll back `parent_tid` on every post-publication failure path. The narrower fix is to perform all argument validation before any caller-visible output write.

---

## Entry 9: An unvalidated futex waiter can consume wake(1) while a validated waiter remains blocked

- **Finding ID**: MC-9
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/confirmation/MC-9/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: `litebox/src/sync/futex.rs:116`

## Description
`FutexManager::wait` inserts a waiter into the futex bucket before it validates that the futex word still equals the expected value. `FutexManager::wake(count=1)` scans and counts matching queue entries without knowing whether a selected waiter has passed that validation. As a result, an unvalidated waiter can consume the single wake quota, return `ImmediatelyWokenBecauseValueMismatch`, and leave a validated waiter blocked.

## Trigger scenario
1. Futex word is `0`.
2. Waiter A enters `wait(expected=0)`, inserts at the head, and pauses before reading the futex word.
3. Waiter B enters `wait(expected=0)`, inserts after A, validates the value `0`, and blocks.
4. The futex word changes to `1`.
5. `wake(count=1)` selects A, returns `1`, and exhausts the quota.
6. A resumes and returns mismatch; B remains blocked until timeout or a later separate wake.

## Developer intent
The code comment says insertion is done before the value check to avoid missed wakeups. The syscall consumer is real: `litebox_shim_linux/src/syscalls/process.rs:1330` routes guest `FUTEX_WAIT`/`FUTEX_WAKE` to this manager.

Known-status search covered upstream issues and open/closed PRs. Related reports are distinct: PR #1228 is the post-validation store-buffering lost-wake issue, issue #1009 is a Miri/data-race plus separate store-buffering concern, and issue #1236 is a control-ring test race. None reports this pre-validation wake-quota consumption mechanism.

Links: https://github.com/microsoft/litebox/pull/1228, https://github.com/microsoft/litebox/issues/1009, https://github.com/microsoft/litebox/issues/1236

## Reproduction result
Wrote and executed:

`/home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-9_futex_unvalidated_quota.sh`

Command:

```text
timeout 8m /home/ubuntu/Specula/runs/litebox-rerun-known-aware-gpt56sol-xhigh-20260829/litebox/.specula-output/repro/test_bugMC-9_futex_unvalidated_quota.sh
```

Output:

```text
LEVEL0: iterations=64 observed_quota_loss=false
LEVEL1: first_waiter_phase=inserted_unvalidated
LEVEL1: second_waiter_phase=validated_waiting
LEVEL1: wake_return=1
LEVEL1: first_waiter_result=ImmediatelyWokenBecauseValueMismatch
LEVEL1: second_waiter_result=TimedOut
BUG_TRIGGERED: true
SUMMARY: level0_triggered=false level1_triggered=true
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 0 did not trigger in 64 normal-scheduling iterations; Level 1 timing assistance triggered it without state injection or source-logic modification.
2. Level 2/3 were not used. The Level 1 schedule instantiates the admissible counterexample step: A is `inserted_unvalidated`, B is `validated_waiting`, then `wake(1)` selects A.
3. Real consumer/caller: `litebox_shim_linux/src/syscalls/process.rs:1330`, specifically `FUTEX_WAKE` at `1341-1349` and `FUTEX_WAIT` at `1351-1364`. The caller-visible bad outcome is a successful wake count while the validated waiter times out or would remain blocked without a timeout.
4. The bad state is not repaired by a downstream mechanism. A timeout bounds the wait only for timeout-using callers; it is still the wrong outcome after a successful wake quota was consumed.

## Recommendation
Do not let unvalidated waiters consume `wake` quota. Add explicit waiter validation state, and have `wake` count only waiters that have completed the futex-word check, while preserving the no-missed-wakeup ordering guarantee around insertion and blocking.

---
