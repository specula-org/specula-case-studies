# Severity Classification — asterinas-glm53-eval

## Summary

- Total entries: 6
- Reproduced bugs: 4
- Severity-bearing findings: 0
- Critical: 3
- High: 1
- Medium: 0
- Low: 0
- No-severity dispositions: 2

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | Critical | A deterministic `readv` or `writev` fault after a copied prefix leaves the syscall count and shared offset behind data already copied or committed; subsequent reads re-deliver bytes and file readers observe writes beyond the reported count. Public vectored I/O with a protected-page boundary triggers persistent buffer, offset, and file-state inconsistency with no reconciliation. |
| 2 | MC-2 | REPRODUCED | Critical | Ordinary `read` or `pread` calls on RamFS or exFAT can overwrite caller-buffer bytes beyond the returned EOF-clipped count, including returning zero after clobbering data. The corruption remains in user memory, and no kernel path reports or repairs it. |
| 3 | MC-3 | REPRODUCED | Critical | A public `write` or `pwrite` to RamFS, tmpfs, or memfd with an unreadable user page returns EFAULT but permanently publishes the full requested EOF, exposing phantom zero data through `fstat`, `lseek`, and `pread`. No rollback or later reconciliation repairs the inode metadata. |
| 4 | MC-4 | INCOMPLETE | — | `INCOMPLETE` is a Phase 4 disposition, so it is not severity-bearing; the finding was not judged because confirmation produced no canonical verdict. |
| 5 | CR-1 | FALSE POSITIVE | — | `FALSE POSITIVE` is a Phase 4 disposition and carries no severity; Phase 4 found that positional I/O leaves the shared open-description offset unchanged. |
| 6 | CR-2 | REPRODUCED | High | Blocking-pipe `readv` or `writev` with `SA_RESTART` can return raw EINTR to the caller instead of completing with queued data, producing an externally visible failed operation. The data remains queued, so the harm is bounded to the interrupted call. |
