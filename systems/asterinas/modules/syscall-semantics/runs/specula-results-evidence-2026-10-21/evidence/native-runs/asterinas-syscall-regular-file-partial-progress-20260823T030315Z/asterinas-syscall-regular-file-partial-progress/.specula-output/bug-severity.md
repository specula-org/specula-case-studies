# Severity Classification — asterinas-syscall-regular-file-partial-progress

## Summary

- Total entries: 8
- Reproduced bugs: 6
- Severity-bearing findings: 1
- Critical: 4
- High: 3
- Medium: 0
- Low: 0
- No-severity dispositions: 1

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | High | An unprivileged `read` or `pread64` into a buffer that faults after a writable prefix returns `EFAULT` despite modifying the buffer; a shared-offset read then replays the delivered prefix because the offset did not advance. The externally visible harm is bounded to the faulting I/O and its caller-visible stream position. |
| 2 | MC-2 | REPRODUCED | Critical | An unprivileged buffered `write` to ext2 can durably change a positive file prefix while returning `EFAULT` and leaving the shared offset unchanged. The modification survives `fsync` and direct reread, so a caller can retry and duplicate data or leave silent file corruption with no automatic recovery. |
| 3 | MC-3 | REPRODUCED | High | Ramfs `read`, `pread64`, and `preadv` calls that reach logical EOF can overwrite caller memory beyond the returned byte count, including when the call returns zero. This public syscall path causes demonstrated application-state loss, but the over-copy is bounded to the page-cache tail and contains zeros rather than disclosed kernel data. |
| 4 | MC-4 | REPRODUCED | Critical | Ramfs `write` and `pwrite64` publish the requested end before a fallible copy, so a zero-progress fault or a zero-length write past EOF permanently enlarges the file and exposes unwritten zeros. The corrupted size and phantom data survive close and reopen with no automatic correction. |
| 5 | MC-5 | REPRODUCED | Critical | Concurrent `readv` or `writev` calls through duplicated descriptors can release the shared-offset lock between vector entries, producing torn transfers. The public `writev` path durably embeds a competing writer's bytes inside the vector range, leaving persistent file corruption without reconciliation. |
| 6 | MC-6 | MASKED | Critical | On fragmented ext2 direct writes, a later-run copy fault can leave an earlier BIO live after rollback; without serialization it can overwrite a later operation or a reallocated block, causing persistent cross-file corruption. The current single-worker FIFO staging queue and synchronous `zero_new_blocks` barrier mask that consequence on both tested virtio-blk and NVMe paths. |
| 7 | MC-7 | REPRODUCED | High | An `O_APPEND` write that faults before copying any bytes can return `EFAULT` while moving the shared open-file-description offset to EOF. Reads through a duplicated descriptor then return EOF or wrong data until an explicit seek, making the harm externally visible but bounded to that open-file description. |
| 8 | CR-1 | FALSE POSITIVE | — | Phase 4 classified the entry as `FALSE POSITIVE` because no real regular-file backend provides its positive-progress `EINTR` precondition; this disposition is not severity-bearing. |
