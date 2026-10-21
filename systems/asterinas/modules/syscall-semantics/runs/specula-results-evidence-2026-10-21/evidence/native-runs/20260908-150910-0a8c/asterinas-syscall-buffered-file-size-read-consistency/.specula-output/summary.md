# Specula Summary

## Result

- Run status: **Complete**

The report records 10 reproduced bugs, 0 masked findings, 0 environment-limited findings, and 0 other dispositions. The bugs can corrupt read buffers, leave file sizes and contents inconsistent, report success without transferring data, and permanently block exFAT operations.

## Findings

- **MC-1 — Ramfs reads report a saved count that differs from delivered bytes** — Status: `REPRODUCED`. Impact: Reads can misreport transferred bytes, overwrite the caller's buffer beyond the returned count, and advance the shared position past undelivered data. Evidence: Public syscalls reproduced buffer and offset mismatches with controlled thread timing.
- **MC-2 — ExFAT reads copy beyond their reported prefix during write preparation** — Status: `REPRODUCED`. Impact: Reads can overwrite user-buffer bytes beyond their reported count, including when returning zero at EOF. Evidence: Sequential EOF reads and timed concurrent writes reproduced the buffer overwrites; ext2 controls stayed clean.
- **MC-3 — ExFAT stale write preparation permits false success and inconsistent extents** — Status: `REPRODUCED`. Impact: Concurrent extending writes can acknowledge data never stored, leave later reads and writes falsely successful, or move EOF below an already acknowledged write. Evidence: Real syscalls reproduced both outcomes with a kernel timing hook.
- **MC-4 — ExFAT successful ftruncate can retain the old logical size** — Status: `REPRODUCED`. Impact: Successful truncation can leave extensions unreadable or preserve access to bytes that should have been truncated. Evidence: Single-threaded public syscalls showed unchanged exFAT sizes after successful truncation; ext2 controls behaved correctly.
- **MC-5 — ExFAT regrown holes can read the subject's old backing bytes** — Status: `REPRODUCED`. Impact: Regrown file holes can expose the same file's pre-truncation contents instead of zeros until those bytes are overwritten. Evidence: Sequential public syscalls recovered two pages of the same file's old contents; ext2 and ramfs controls returned zeros.
- **MC-6 — Ramfs zero-count positional writes can enlarge the file** — Status: `REPRODUCED`. Impact: A write requesting zero bytes beyond EOF can permanently enlarge a ramfs file and make an unintended zero-filled range readable. Evidence: Sequential public syscalls grew a two-byte file to four bytes; Linux controls left it unchanged.
- **MC-7 — ExFAT zero-count positional writes can enlarge the file** — Status: `REPRODUCED`. Impact: Zero-count writes beyond EOF can permanently enlarge exFAT files and allocate storage without transferring data. Evidence: Unprivileged sequential tests reproduced growth through positional, vectored, and shared-offset writes.
- **MC-8 — Ramfs zero-progress failed writes can publish the full requested extent** — Status: `REPRODUCED`. Impact: A write that fails before copying any bytes can still permanently enlarge a ramfs file with an unintended zero-filled extent. Evidence: A public write from an inaccessible buffer returned EFAULT with zero progress while the file still grew.
- **CR-1 — VmIo no-short-transfer contract conflicts with VMO capacity-clamped success** — Status: `REPRODUCED`. Impact: Sequential reads on ramfs and exFAT can permanently overwrite the caller's buffer beyond the returned byte count, including reads that return zero. Evidence: Unprivileged sequential reads overwrote 3,996 bytes beyond the returned count; ext2 controls remained unchanged.
- **CR-2 — Resize documentation contradicts fallible tail clearing and exFAT branch order** — Status: `REPRODUCED`. Impact: Extending an exFAT file whose partial tail page is uncached can permanently deadlock the writer and block subsequent filesystem operations. Evidence: An ordinary buffered write after remount hung until the guest run was terminated by its timeout.
- Other dispositions: 0.

## Validation limits

- MC-1 and the concurrent MC-2 case used controlled timing between threads on separate virtual CPUs.
- MC-3 did not trigger in 500 trials without a kernel timing hook; reproducing both write orderings required the hook.
- MC-4 reused existing kernel artifacts under host QEMU/KVM because a registry TLS failure prevented use of the Docker image.
- MC-5 demonstrated stale contents from the same file on a fresh image with deterministic cluster reuse.
- MC-8 confirmed writes that fault before copying any bytes; partial-progress behavior was outside the finding's scope.
- CR-1's overwritten tail contained zeros; no stale-data leak was observed.
- CR-2 required an uncached partial tail page; cached-tail and ext2 controls completed, and the watchdog detected the hang without recovering it.


## Run coverage

- Source analysis was skipped.
- Formal model generation was skipped.
- Execution trace collection was skipped.
- Trace validation and model checking were skipped.

## Run details

| Item | Value |
|---|---|
| Target | asterinas-syscall-buffered-file-size-read-consistency |
| Original source commit | - |
| Current attempt source commit | f5e9e97c6a4dce350116d3ea85e61014613d089b |
| Agent / model | Varies by task / Varies by task |
| Reasoning effort | max |

## Detailed reports

- [Confirmation report](confirmed-bugs.md)
- [Severity report](bug-severity.md)

## Resource usage

| Phase | Runtime | Tokens | Estimated cost |
|---|---:|---:|---:|
| Phase 1 | 51m 44s | 58.6M total (56.5M cached) | $86.23 |
| Phase 2 | 1h 2m | 6.4M total (5.9M cached) | $13.89 |
| Phase 2.5 | 1h 40m | 15.9M total (15.4M cached) | $25.23 |
| Phase 3 | 50m 23s | 12.0M total (11.5M cached) | $17.38 |
| Phase 4a | 6h 30m | 106.8M total (76.9M cached) | $0.00 |
| Phase 4b | 7m 51s | 606.8K total (527.2K cached) | $1.87 |
| **Total** | 11h 2m | 200.3M total (166.7M cached) | $144.60 |

- Configured maximum parallelism: phase defaults (ordinary phases 1 at a time; per-finding confirmation 4 at a time)
- Configured TLC limits: auto memory; unbounded (report only) workers
