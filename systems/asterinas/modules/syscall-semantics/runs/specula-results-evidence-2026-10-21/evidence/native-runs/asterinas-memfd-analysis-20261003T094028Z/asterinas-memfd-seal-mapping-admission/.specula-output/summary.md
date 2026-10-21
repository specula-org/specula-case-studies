# Specula Summary

## Result

- Run status: **Complete**

The report records 2 reproduced bugs, 0 masked findings, 0 environment-limited findings, and 3 other dispositions. Memfd sealing can incorrectly reject read-only mapping and sealing operations, and a rejected fixed replacement can remove an existing mapping and crash a consumer.

## Findings

- **MC-1 — Post-seal read-only mappings retain writable accounting** — Status: `REPRODUCED`. Impact: Read-only shared mappings through a writable memfd handle can be rejected after sealing or can falsely block a later write seal for the mapping's lifetime. Evidence: A deterministic test using public system calls reproduced both failures on Asterinas, while the same binary showed neither deviation on Linux.
- **MC-2 — Seal-rejected fixed replacement removes the existing mapping** — Status: `REPRODUCED`. Impact: A seal-rejected fixed replacement removes the covered part of an existing mapping, so subsequent access can terminate a consumer with a segmentation fault. Evidence: Tests using public system calls reproduced the loss for both full and partial overlap on Asterinas, while Linux preserved the mapping.
- Other dispositions: 3.

## Validation limits

- Both reproductions used a QEMU/KVM Asterinas guest at commit `0c6053709` with trace instrumentation reported to leave the relevant logic unchanged, compared with Linux 7.2.8.


## Run coverage

- Source analysis was skipped.
- Formal model generation was skipped.
- Execution trace collection was skipped.
- Trace validation and model checking were skipped.

## Run details

| Item | Value |
|---|---|
| Target | asterinas-memfd-seal-mapping-admission |
| Original source commit | 0c60537098f4c2949ad2d382aaf499de72263d76 |
| Current attempt source commit | 0c60537098f4c2949ad2d382aaf499de72263d76 |
| Agent / model | Varies by task / Varies by task |
| Reasoning effort | max |

## Detailed reports

- [Confirmation report](confirmed-bugs.md)
- [Severity report](bug-severity.md)

## Resource usage

| Phase | Runtime | Tokens | Estimated cost |
|---|---:|---:|---:|
| Phase 1 | 31m 36s | 33.6M total (32.2M cached) | $50.41 |
| Phase 2 | - | 11.0M total (10.5M cached) | $19.04 |
| Phase 2.5 | 1h 28m | 14.4M total (13.8M cached) | $23.80 |
| Phase 3 | 29m 39s | 7.6M total (7.3M cached) | $11.92 |
| Phase 4a | 3h 31m | 87.0M total (77.5M cached) | $0.00 |
| Phase 4b | 7m 31s | 474.9K total (410.5K cached) | $1.45 |
| **Total (incomplete)** | 6h 8m | 154.0M total (141.7M cached) | $106.63 |

- Configured maximum parallelism: 1
- Configured TLC limits: auto memory; unbounded (report only) workers
