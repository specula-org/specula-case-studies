# Specula Summary

## Result

- Run status: **Complete**

The report records four `REPRODUCED` entries, no `MASKED` or `ENV_LIMITED` entries, and two other dispositions. The confirmed defects expose persistent mismatches between reported I/O progress and caller-visible buffer or file state, plus a vectored-I/O restart failure under `SA_RESTART`.

## Findings

- **MC-1 — A Later readv Fault Can Hide a Positive Copy Prefix** — Status: `REPRODUCED`. Impact: A fault after partial vectored I/O can leave copied or committed bytes beyond the reported count, keep the shared offset behind, and cause later reads to re-deliver data. Evidence: A guest run reproduced the mismatch on RamFS and ext2, while the same test on Linux reported and advanced past the copied prefix.
- **MC-2 — RamFS and exFAT Cached Reads Copy Beyond Logical EOF** — Status: `REPRODUCED`. Impact: RamFS and exFAT reads that cross or begin at logical EOF can overwrite caller-buffer bytes beyond the returned count. Evidence: Guest runs clobbered 1024 sentinel bytes in both filesystems; ext2 in the same boot and the Linux control left the buffer unchanged.
- **MC-3 — A Zero-Progress RamFS Write Can Publish the Full Requested EOF** — Status: `REPRODUCED`. Impact: A failed RamFS-backed write can publish the full requested EOF despite committing no bytes or only a prefix, exposing phantom zero data and a wrong file size. Evidence: Guest tests observed the bad size through `fstat`, `lseek`, and `pread` on RamFS and memfd, while ext2 and Linux controls kept EOF at committed data.
- **CR-2 — Vectored and Positional Syscalls Lack the EINTR-to-ERESTARTSYS Restart Translation** — Status: `REPRODUCED`. Impact: Signals handled with `SA_RESTART` can make blocking `readv` or `writev` return EINTR instead of resuming and delivering queued data. Evidence: Guest scalar read and write controls restarted, but vectored calls returned EINTR; the same test restarted all calls on Linux.
- Other dispositions: 2.

## Validation limits

- MC-1 and MC-3 were exercised with user buffers ending at a protected page, the fault condition required to expose their partial-copy behavior.
- The MC-2 evidence establishes zero-byte buffer clobbering, not stale-data disclosure; the report records tail-page zero filling as the masking mechanism for that variant.
- For CR-2, only blocking `readv` and `writev` had a live trigger; the positional `pread64` and `pwrite64` omission is latent because current local regular-file paths do not produce EINTR.


## Run coverage

- Source analysis was skipped.
- Formal model generation was skipped.
- Execution trace collection was skipped.
- Trace validation and model checking were skipped.
- Candidate confirmation was skipped.

## Run details

| Item | Value |
|---|---|
| Target | asterinas-glm53-eval |
| Original source commit | - |
| Current attempt source commit | d0139a15b5054427a37d15da57d0995918292562 |
| Agent / model | Varies by task / Varies by task |
| Reasoning effort | max |

## Detailed reports

- [Confirmation report](confirmed-bugs.md)
- [Severity report](bug-severity.md)

## Resource usage

| Phase | Runtime | Tokens | Estimated cost |
|---|---:|---:|---:|
| Phase 1 | 47m 15s | 67.1M total (65.1M cached) | $51.51 |
| Phase 2 | 46m 2s | 12.6M total (12.1M cached) | $8.66 |
| Phase 2.5 | 2h 3m | 61.9M total (60.9M cached) | $42.69 |
| Phase 3 | 1h 27m | 49.5M total (48.6M cached) | $36.01 |
| Phase 4a | - | 100.1M total (96.7M cached) | $0.00 |
| Phase 4b | 4m 51s | 1.6M total (1.5M cached) | $2.64 |
| **Total (incomplete)** | 5h 8m | 292.9M total (284.9M cached) | $141.51 |

- Configured maximum parallelism: 1
- Configured TLC limits: auto memory; unbounded (report only) workers
