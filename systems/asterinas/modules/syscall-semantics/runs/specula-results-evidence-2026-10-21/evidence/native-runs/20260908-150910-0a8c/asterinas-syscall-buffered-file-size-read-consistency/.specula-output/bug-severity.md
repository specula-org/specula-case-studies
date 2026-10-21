# Severity Classification — asterinas-syscall-buffered-file-size-read-consistency

## Summary

- Total entries: 10
- Reproduced bugs: 10
- Severity-bearing findings: 0
- Critical: 10
- High: 0
- Medium: 0
- Low: 0
- No-severity dispositions: 0

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | MC-1 | REPRODUCED | Critical | Concurrent ramfs read or pread with ftruncate or an extending pwrite can report bytes never delivered or overwrite bytes beyond the reported count. Shared-offset reads permanently advance past undelivered data, and neither the buffer damage nor the incorrect file position is automatically corrected. |
| 2 | MC-2 | REPRODUCED | Critical | An unprivileged exFAT read or pread at EOF or during extending-write preparation overwrites the caller's buffer beyond the reported byte count, including on a zero return. The overwritten application data is never restored, even after the allocation-versus-size window closes. |
| 3 | MC-3 | REPRODUCED | Critical | Concurrent extending exFAT pwrite calls can acknowledge bytes never stored and leave a size/capacity mismatch that makes later non-racing reads and writes falsely succeed, or publish EOF below an acknowledged write. A controlled kernel timing hook exposed these legal lock interleavings; the lost extent and persistent false success have no automatic repair. |
| 4 | MC-4 | REPRODUCED | Critical | A single exFAT ftruncate extension or same-cluster shrink can report success while retaining the old logical size, leaving promised new bytes unreadable or truncated-away bytes readable. Subsequent stat and read calls observe the persistent size corruption, with no downstream mechanism publishing the requested size automatically. |
| 5 | MC-5 | REPRODUCED | Critical | Sequential exFAT truncation to zero followed by a write beyond EOF can reuse the file's old clusters and expose its pre-truncation contents through hole reads. The reproduced stale bytes remain readable until explicitly overwritten, with no read-path safeguard clearing them. |
| 6 | MC-6 | REPRODUCED | Critical | A zero-count ramfs pwrite beyond EOF enlarges the file and makes an unintended zero-filled range readable although the syscall reports no bytes written. Subsequent stat and read calls observe the persistent file-size corruption, and no downstream mechanism restores the original EOF. |
| 7 | MC-7 | REPRODUCED | Critical | Zero-count exFAT pwrite, empty pwritev, or seek followed by write with count zero beyond EOF can enlarge the file and allocate clusters without transferring data. The unintended size and allocation persist without automatic rollback, and sync writes the enlarged size to disk. |
| 8 | MC-8 | REPRODUCED | Critical | An extending ramfs pwrite from a buffer unreadable at the first byte returns EFAULT after copying nothing but still publishes the requested EOF. Later stat and read calls expose a permanently enlarged file with unintended zero-filled bytes because the error path does not roll back the size or cache. |
| 9 | CR-1 | REPRODUCED | Critical | Sequential read or pread on a short ramfs or exFAT file overwrites user-buffer bytes beyond the returned count, including when reporting EOF. In composition with these callers' unlimited writers, the VMO contract mismatch causes persistent application-buffer corruption that no downstream mechanism repairs. |
| 10 | CR-2 | REPRODUCED | Critical | A buffered write extending an exFAT file with unaligned EOF and an uncached tail page re-enters the inode lock while holding its write guard. The syscall deadlocks permanently and retains locks that wedge later exFAT operations; the watchdog detects the hang without providing recovery. |
