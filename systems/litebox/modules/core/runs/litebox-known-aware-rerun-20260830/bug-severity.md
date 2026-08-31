# Severity Classification — litebox

## Summary

- Total entries: 9
- Reproduced bugs: 9
- Severity-bearing findings: 0
- Critical: 3
- High: 5
- Medium: 1
- Low: 0
- No-severity dispositions: 0

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | High | A public `open(..., O_CREAT, ...)` racing with `rmdir` can return a writable fd for a file that has no reachable pathname. The consequence is caller-visible namespace/data loss bounded to that racy create path while the fd remains alive. |
| 2 | MC-2 | REPRODUCED | High | Relative `open`/`read` from a task whose CWD pathname was removed and recreated can resolve into the replacement directory. The consequence is caller-visible redirection to the wrong namespace until the task changes CWD or exits. |
| 3 | MC-3 | REPRODUCED | High | A guest `readv` on a shared fd table can copy one syscall's chunks from two different open-file descriptions after raw-fd reuse. The consequence is externally visible user-buffer corruption for that syscall result. |
| 4 | MC-4 | REPRODUCED | High | Guest `getdents64` through duplicated directory descriptors can repeat directory entries instead of sharing the directory position. The consequence is wrong directory data returned through the public directory-read surface until the caller repositions or closes the descriptors. |
| 5 | MC-5 | REPRODUCED | Medium | Public epoll, pipe, close, and raw-fd reuse operations can leave stale dead interests accumulating inside `EpollFile.interests`. The report states wrong readiness delivery is masked by weak-entry skipping, so the demonstrated consequence is internal resource retention with downstream exhaustion/performance risk. |
| 6 | MC-6 | REPRODUCED | Critical | Public `mmap(MAP_FIXED)` followed by `mprotect(PROT_EXEC)` can apply a stale ELF patch plan to a newer mapping. The consequence is persistent corruption of guest executable bytes until the mapping is overwritten or unmapped. |
| 7 | MC-7 | REPRODUCED | Critical | On the SNP `clone3` path, a host spawn failure after child attachment can leak a phantom thread. The consequence is a persistent process-quiescence hang through `wait_for_exit`/thread-kill waits with no automatic cleanup. |
| 8 | MC-8 | REPRODUCED | High | A public `clone3` call that returns `EINVAL` for invalid stack arguments can still write a newly allocated child TID into caller memory. The consequence is bounded caller-visible state corruption on a failed syscall until userspace overwrites the value. |
| 9 | MC-9 | REPRODUCED | Critical | Public `FUTEX_WAIT`/`FUTEX_WAKE` scheduling can let an unvalidated waiter consume a `wake(1)` quota while a validated waiter remains blocked. The consequence is a lost-wake liveness failure that can block indefinitely for callers without a timeout. |
