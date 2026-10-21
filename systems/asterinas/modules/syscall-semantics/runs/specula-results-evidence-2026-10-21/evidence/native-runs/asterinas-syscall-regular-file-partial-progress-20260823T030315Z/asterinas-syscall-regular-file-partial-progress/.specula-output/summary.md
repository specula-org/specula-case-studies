# Specula Summary

## Result

- Run status: **Complete**

The report records six `REPRODUCED` entries, one `MASKED` entry, no `ENV_LIMITED` entries, and one other disposition. The reproduced cases show that regular-file partial-copy faults, ramfs EOF and size handling, vectored-I/O locking, and append offset updates can make reported progress diverge from caller-visible or persistent state; the direct-I/O ordering defect remains masked by current device-queue behavior.

## Findings

- **MC-1 — A positive read prefix is exposed but returned as EFAULT** — Status: `REPRODUCED`. Impact: A faulting read can modify the caller's buffer, report `EFAULT`, leave the shared offset unchanged, and replay the delivered prefix on the next read. Evidence: Public-syscall tests on ramfs and ext2 exposed 128 bytes while returning `EFAULT`; the Linux control returned 128 and advanced the offset.
- **MC-2 — A retained write prefix is returned as EFAULT with no offset progress** — Status: `REPRODUCED`. Impact: A buffered write can durably modify a file while reporting `EFAULT` and leaving the shared offset unchanged, so a retry can duplicate data or leave silent corruption. Evidence: Buffered and direct reads after `fsync` found 128 or 4096 changed bytes on disk after the failed call, while the Linux control returned matching short counts.
- **MC-3 — Ramfs can copy beyond logical EOF and report only the EOF snapshot** — Status: `REPRODUCED`. Impact: Ramfs reads can overwrite caller memory beyond the returned byte count, including when a read at EOF returns zero. Evidence: `read`, `pread64`, and `preadv` tests observed up to 4092 clobbered bytes beyond the reported result, while the Linux control left those bytes untouched.
- **MC-4 — Ramfs publishes file size before a write that copies no bytes** — Status: `REPRODUCED`. Impact: A zero-progress fault or zero-length write past EOF can permanently enlarge a ramfs file and make unwritten zeros readable. Evidence: Tests observed inflated sizes and readable zeros after the calls, including an enlarged size that survived close and reopen; the Linux control did not show those changes.
- **MC-5 — Vectored I/O is not atomic on a shared open-file description** — Status: `REPRODUCED`. Impact: Concurrent vectored I/O through duplicated descriptors can split one transfer around a competing operation, producing noncontiguous reads or persistent foreign bytes inside a write range. Evidence: Concurrent tests observed torn `readv` results and torn `writev` results on Asterinas, while the same cases remained atomic on Linux and a scalar-loop control tore on both systems.
- **MC-6 — Ext2 direct write returns while an earlier submitted BIO remains live** — Status: `MASKED`. Impact: An abandoned direct-write BIO could outlive rollback and overwrite a later operation or a reallocated block. Evidence: Tests confirmed that an earlier run was submitted before a later copy fault, but no late overwrite appeared on the tested virtio-blk or NVMe paths because the current staging and allocation behavior serialized the effect.
- **MC-7 — An O_APPEND fault leaves the shared offset at EOF** — Status: `REPRODUCED`. Impact: A failed append can move the shared open-file-description offset to EOF even though it reports no bytes, causing duplicated descriptors to read EOF or wrong data. Evidence: On ext2, a zero-progress fault returned `EFAULT` and moved the offset from 0 to 4096, while the Linux control kept it at 0 and returned the original file data through the duplicated descriptor.
- Other dispositions: 1.

## Validation limits

- The late-overwrite consequence for MC-6 did not appear on the tested virtio-blk or NVMe devices because a single-worker FIFO staging queue and synchronous block-zeroing barrier serialized requests; its write-after-free variant also requires a near-full, fragmented block group.
- For MC-5, vector interleaving and later-entry positive-fault accounting were exercised in separate runs rather than one combined execution.


## Run coverage

- Source analysis was skipped.
- Formal model generation was skipped.
- Execution trace collection was skipped.
- Trace validation and model checking were skipped.
- Candidate confirmation was skipped.
- Automated repair follow-up was skipped.

## Run details

| Item | Value |
|---|---|
| Target | asterinas-syscall-regular-file-partial-progress |
| Original source commit | - |
| Current attempt source commit | 2cd64291cf4e11283eeabb4e4e953cb8be971cb9 |
| Agent / model | Varies by task / Varies by task |
| Reasoning effort | max |

## Detailed reports

- [Confirmation report](confirmed-bugs.md)
- [Severity report](bug-severity.md)

## Resource usage

| Phase | Runtime | Tokens | Estimated cost |
|---|---:|---:|---:|
| Phase 1 | - | 70.0M total (68.0M cached) | $58.78 |
| Phase 2 | 4h 42m | 131.4M total (126.7M cached) | $112.78 |
| Phase 2.5 | 1h 45m | 78.0M total (76.8M cached) | $158.69 |
| Phase 3 | 1h 43m | 63.8M total (62.9M cached) | $56.42 |
| Phase 4a | 4h 20m | 104.8M total (101.4M cached) | $96.88 |
| Phase 4b | 7m 26s | 1.3M total (1.2M cached) | $1.79 |
| **Total (incomplete)** | 12h 39m | 449.5M total (437.1M cached) | $485.34 |

- Configured maximum parallelism: 1
- Configured TLC limits: auto memory; unbounded (report only) workers
