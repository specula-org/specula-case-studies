# Specula Summary

## Result

- Run status: **Complete**

The report records 2 reproduced bugs, 0 masked findings, 0 environment-limited findings, and 2 other dispositions. Faulting UNIX datagram receives can leave unreported descriptors open or retain datagrams that Linux would discard.

## Findings

- **MC-1 — AST-32: Failed SCM_RIGHTS number publication retains an installed FD** — Status: `REPRODUCED`. Impact: A control-buffer fault can leave unreported file descriptors open for the process lifetime and hide partial delivery, allowing repeated calls to exhaust the receiver's descriptor table. Evidence: Public syscall tests in an Asterinas guest observed the leak and incorrect control length, while Linux controls showed no leak and the correct delivered length.
- **MC-2 — AST-36: Ordinary payload faults retain the datagram** — Status: `REPRODUCED`. Impact: After an ordinary receive fails while copying the payload, a retry can deliver a datagram and its file descriptors that Linux would have discarded. Evidence: The same public syscall test delivered the retained message in an Asterinas guest and reported an empty queue on Linux.
- Other dispositions: 2.

## Validation limits

- Both reproductions used deliberately faulting receive buffers on the pinned Asterinas kernel in QEMU/KVM. MC-1 used an inaccessible page in the control buffer, and MC-2 used a payload buffer that was not writable.


## Run coverage

- Source analysis was skipped.
- Formal model generation was skipped.
- Execution trace collection was skipped.
- Trace validation and model checking were skipped.
- Automated repair follow-up was skipped.

## Run details

| Item | Value |
|---|---|
| Target | asterinas-unix-dgram-scm-rights |
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
| Phase 1 | 18m 44s | 35.9M total (34.4M cached) | $54.34 |
| Phase 2 | 28m 28s | 6.9M total (6.5M cached) | $13.08 |
| Phase 2.5 | 2h 5m | 36.7M total (35.6M cached) | $53.67 |
| Phase 3 | 4h 33m | 72.9M total (71.5M cached) | $96.67 |
| Phase 4a | 3h 49m | 56.2M total (46.6M cached) | $0.00 |
| Phase 4b | 4m 5s | 466.2K total (405.4K cached) | $1.37 |
| **Total** | 11h 20m | 209.0M total (194.9M cached) | $219.13 |

- Configured maximum parallelism: 1
- Configured TLC limits: 4G memory; 2 workers
