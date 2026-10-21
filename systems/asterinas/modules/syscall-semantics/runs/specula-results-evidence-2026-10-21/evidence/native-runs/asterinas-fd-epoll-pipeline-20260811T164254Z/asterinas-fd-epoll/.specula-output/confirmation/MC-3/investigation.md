# Investigation — MC-3

Source checkout: `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.

## Code audit

- Finding-provided MC trace: `MCNoDeadInterest`, seven states. The trace was not reopened because this worker is prohibited from reading spec artifacts.
- Normal public path: `sys_epoll_ctl` constructs `EpollCtl::Add` and calls `EpollFile::control` (`kernel/core/src/syscall/epoll.rs:51-95`); `control` resolves the watched descriptor from the process file table and calls `add_interest` (`kernel/core/src/events/epoll/file.rs:64-162`). `eventfd2` creates an `EventFile` and inserts it into that same table (`kernel/core/src/syscall/eventfd.rs:38-55`).
- The inserted `Entry` is held strongly by `EpollFile::interest`, but its `EntryKey` retains the watched `FileLike` only as `KeyableWeak` (`kernel/core/src/events/epoll/entry.rs:46-66`, `kernel/core/src/events/epoll/file.rs:41-42,147-150`). This prevents a reused descriptor number from matching the old open-file description.
- `sys_close` removes the table entry through `FileTable::close_file` and then only sends VFS close notification before dropping the removed `Arc` (`kernel/core/src/syscall/close.rs:22-47`; `kernel/core/src/fs/file/file_table.rs:196-205`). `fs::vfs::notify::on_close` reports filesystem close events and has no epoll callback (`kernel/core/src/fs/vfs/notify/mod.rs:381-406`).
- `del_interest` removes an interest entry only for `EPOLL_CTL_DEL` or when `pop_multi_ready` discovers a dead weak file (`kernel/core/src/events/epoll/file.rs:164-178,244-279`). Its nearby comment describes postponing removal from the ready list after explicit deletion, not final-close cleanup (`:164-172`).
- The reproduction uses `eventfd(0)` and watches only `EPOLLIN`, so the initial zero-valued eventfd is not queued ready. After its sole descriptor closes, there is no ready-list element that could reach the weak-file scan. `epoll_ctl`, `close`, and `/proc` read are all normal public operations; no state injection is needed.
- Real consumer: `FileInfoOps::read_at` invokes `dump_proc_fdinfo` for `/proc/[pid]/fdinfo/[n]` (`kernel/core/src/fs/fs_impls/procfs/pid/task/fd.rs:256-321`). `EpollFile::dump_proc_fdinfo` iterates the unfiltered interest set and emits every `tfd` line (`kernel/core/src/events/epoll/file.rs:310-340`). Therefore a user reading `/proc/self/fdinfo/<epfd>` can observe a watch for a final-closed descriptor.
- Safeguard assessment: a later `pop_multi_ready` removes a dead file only if a ready entry exists. This trigger deliberately has none, so no downstream cleanup runs and the stale `tfd` persists for the epoll instance's remaining lifetime.

## Developer-knowledge search

- `git blame` assigns the weak key to `479d98c8b9` ("Use `(fd, file)` as the key", 2024-09-13) and the lazy dead-entry scan to `83b6c03bd8` ("Split `epoll_file.rs`", 2024-11-19). The current path's only later local-history change is the 2026-08-10 assembler refactor `819e7a826`.
- PR #1277, [Make the epoll implementation correct and consistent with Linux](https://github.com/asterinas/asterinas/pull/1277), documents the intended identity rule: removal follows the final descriptor of the underlying open file description. It introduced the `(fd, file)` key and removed the old file-table close observer. Its description and regression coverage address descriptor identity, not a dead weak entry remaining in `interest` and being printed through fdinfo.
- No nearby code comment or existing scoped epoll regression test describes final-close removal from the interest set itself.

## Known-status and precedent

- Searched open and closed GitHub issues and PRs for `epoll close`, `epoll fdinfo`, `epoll cleanup`, `epoll removed interest`, `epoll final close`, and `EPOLL_CTL_DEL close`; the searches included recently closed and merged PRs. Relevant returns were reviewed, including #1277, #1499, and #2526.
- The current upstream path history reports only `819e7a826` after the kernel-assembler move; no later epoll-file or epoll-entry commit fixes this mechanism.
- No public issue, PR, CVE, advisory, or dataset entry located by the required tracker/history search reports the same residual mechanism: final close leaves a dead weak entry in `EpollFile::interest` until a ready-list scan, and fdinfo reports it. Novelty evidence is therefore `NEW`; this is not the code-review × known pre-filter.

## Challenger verification

- The minimized model was reopened. Its configuration enables only the add, close, final-release, and ready-scan actions. Its seven-state trace captures an add target, interleaves close and final release before the captured add completes, then reaches state 7 with `ofdAlive[timer] = FALSE`, `interest = {[fd |-> "fd0", ofd |-> "timer", epoll |-> "ep0"]}`, and `readyQ = {}`. The Level 0 test reaches the same terminal condition in the simpler completed-add-then-close schedule using an unreadable `eventfd(0)` watched for `EPOLLIN`; neither path requires injected state.
- The lifetime audit rules out an epoll-held strong file reference. `Entry::new` stores a weak file key, its `PollHandle` stores weak observer and pollee references, and `SyncSubject` stores weak observers. Final descriptor close can therefore make `Entry::file()` fail exactly as the model assumes.
- The data plane is guarded: weak file identity prevents a reused numeric descriptor from matching the old entry, and a dead unreadable entry is not delivered by `epoll_wait`. This does not repair the reported interface state, because `dump_proc_fdinfo` enumerates `interest` without filtering dead entries.
- Phase 2 used the standalone Level 0 test at `.specula-output/repro/test_bugMC-3_dead_interest.c` and the equivalent initramfs test `test_bug4_epoll_dead_interest.c`. The recorded SMP=2 VM run emitted `SPECULA_REGRESSION_FAIL dead_interest: closed file remains in epoll interest list`; the same source compiled and ran on the host Linux control, which emitted `SPECULA_REGRESSION_PASS dead_interest`.
