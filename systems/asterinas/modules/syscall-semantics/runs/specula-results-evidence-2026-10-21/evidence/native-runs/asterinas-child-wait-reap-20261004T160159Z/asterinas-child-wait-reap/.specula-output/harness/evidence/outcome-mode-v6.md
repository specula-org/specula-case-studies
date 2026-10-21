# Candidate v6 outcome-only review

Candidate v6 prepares the user's 2026-10-10 decision to collect syscall outcomes on Linux and Asterinas at two eligible CPUs without an implementation trace. Review is pending. `review-gate.json` remains `INCOMPLETE` for v6 with scope `NONE`. This document describes the change for an independent reviewer and grants no execution approval.

The baseline is workspace HEAD `e9893140ebd3403ee99ccbb79ef98dc923da3fdf`, including the live memory-gate amendment. The approval chain ends with [review-v5f.md](/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/wait-reap/harness-fix-2026-10-06/review-v5f.md) and the separate [memory-gate review](/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/wait-reap/harness-fix-2026-10-06/review-v5-memgate-coordinator.md). Reference and protected-file hashes are in [v6-inputs.json](v6-inputs.json). Earlier candidate directories have not been rewritten.

## Mode and recorder decision

`run.sh --diagnostic` is now an alias for `--outcome`, which remains the default path. The runner, boot arguments and fixture metadata carry the mode explicitly. `main()` dispatches before the old fixture body to separate outcome helpers. Those helpers use direct `syscall()` calls without `check_clock_cpu`, calibration exchanges or TSC stamps. CPUID is read for provenance only.

The kernel recorder is not armed, and no reset, actor registration or dump control is issued. The observer-delay control is inactive. A fresh guest boot per case ensures there is no previous registration. This also bypasses the instrumentation's output-buffer pre-read, allowing WR-CF to reach the actual copyout fault after selection and possible reap. The unchanged kernel patch contains unconditional stamp instructions and hook checks, so residual instrumentation overhead remains. No claim is made about an uninstrumented guest or about eliminating every kernel RDTSC instruction.

The existing grouped fixture body and every existing function in `collect.py` retain their behavior. `--consistency` still uses the original 15-case set, old calibration program and approved clock requirements. Its Linux clock diagnostics use the renamed `--clock-diagnostic` collector option. Both that option and grouped output require `CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND`. `OUTCOME_ONLY` does not authorize either.

The supplied first admitted v5 Linux control ended with exit 78 and:

```text
WR_CLOCK_UNSUPPORTED actor=3 cpu=1 vendor=AuthenticAMD max=80000022 features=178bfbff invariant=0
```

That admission observation and the supplied AMD Ryzen 9 9950X KVM/kvm-clock environment are retained as the reason for `BLOCKED_ENVIRONMENT`. Current per-run CPUID observations are recorded separately. The grouped clock admission is not weakened to accept this host. R2 remains open for global order, store visibility and a run-wide clock bound.

## Outcome format and comparison

Each executed case produces `harness/evidence/<attempt>/outcomes/{linux,guest}-<case>.outcome.json`. Its fixed fields are `evidence_class: OUTCOME_ONLY_NO_IMPLEMENTATION_TRACE`, `implementation_trace: NONE` and `trace_validation: BLOCKED_ENVIRONMENT`. It records the case's WR IDs, system attribution, actual CPU evidence, raw-log hash and path, metadata, planned calls, observations, explicit Linux-source expectations and comparison results. `bug_classification` is always `NOT_ASSESSED`.

The raw guest log is `NON_TRACE_DIAGNOSTIC_MATERIAL`. The collector accepts only the outcome metadata and syscall schemas, rejects clock/recorder transport, and never embeds raw kernel lines. The format has no TSC values, event intervals, event streams, `traces` field or TraceData envelopes. Boot supervision remains in its existing adjacent `.outcome.json`, outside the syscall report directory.

Each syscall record contains the API, syscall number, flags, positive PID, waitid selector when applicable, null rusage, buffer kind, return and errno. Valid output areas retain their relevant fields and bytes before and after. Siginfo includes `si_signo`, `si_errno`, `si_code`, `si_pid`, `si_uid` and `si_status`. PROT_NONE outputs have `accessible: false` and null fields/bytes because reading them would fault. Padding and unrelated union bytes are not equality oracles. Error outputs are retained without interpreting them as delivered status.

The collector constructs a call plan from the reviewed case, independently of observed results. It checks the observed API/options/buffer/selector and initial sentinel, and compares return, errno and relevant successful output fields. Each call and the complete history receive `match`, `mismatch` or `inconclusive`. A missing record, malformed transport, failed CPU proof, failed setup or incomplete invocation cannot yield an overall match. Completed mismatches are recorded without aborting the remaining case matrix. Completed calls from a timed-out invocation remain visible, but its overall result is inconclusive. No end-to-end timeout is classified as a lost wakeup.

## Case coverage and controls

[cases.tsv](../cases.tsv) is the complete case-to-WR map. Both outcome runner loops read all 21 rows, for 42 planned reports. `both` identifies the 15 original cases, and `outcome` identifies the six new sequential rows. No case was executed during preparation.

| WR IDs | Cases or control | Linux-source outcome |
| --- | --- | --- |
| WR-01, WR-02 | `nohang-37`, `consume-0`, `consume-255` | A live-child wait4 WNOHANG returns zero and preserves the sentinel. A later consuming wait4 returns the child's PID and `(exit_value & 255) << 8`. Both follow-up APIs return ECHILD. |
| WR-03, WR-05 | `observe-consumeid` | Two WNOWAIT observations preserve the event. Consuming waitid returns zero with SIGCHLD, CLD_EXITED, PID, UID and the unshifted exit value. Later calls return ECHILD. |
| WR-04 | `observe-consume4` | Both observations agree and wait4 can still consume the event once. |
| WR-06, WR-07 | `consumers*` | Exactly one blocking consumer returns its API-specific exit result, the other gets ECHILD, and both finish. This includes ready and initially live children and same/mixed API pairs. |
| WR-08 | `observer-consume4`, `observer-consumeid` | The consumer succeeds. The concurrent observer may obtain the retained status or ECHILD. An observer invoked after consumption gets ECHILD. |
| WR-09 | `consumers4i-race`, `consumersii-race` | Zero-delay exits opportunistically exercise the failed-scan/registration window. The one-consumer/ECHILD/no-hang outcome is checked. |
| WR-10 | `consumers44-park`, `consumersii-park`, `consumers4i-park`, `consumersi4-park` | Delayed exits opportunistically exercise registration/parking schedules. The same consumer outcome is checked. |
| WR-SQ | `siginfo-zero`, `siginfo-poison` | On a held-live child, waitid P_PID WEXITED\|WNOHANG returns zero, errno zero, and all six selected siginfo fields zero. Each row starts a fresh child, then releases and consumes it. |
| WR-CF | `copyout-wait4`, `copyout-waitid`, `copyout-nowait` | Each row establishes its own zombie with valid WEXITED\|WNOWAIT, then calls through PROT_NONE. The fault returns -1/EFAULT. A subsequent valid consuming wait returns ECHILD for the two consuming faults and the exit result for the WNOWAIT fault. |
| WR-LX | `zombie-without-wexited` | After establishing a zombie, WSTOPPED\|WNOHANG returns -1/ECHILD without consuming it. WEXITED\|WNOHANG then returns the normal-exit siginfo. This is a source expectation, not an executed result or bug classification. |

The contracts are [contracts.md](/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/wait-reap/contracts.md). The new controls use direct syscalls and a fresh child per row. Exit values 0, 37 and 255 are retained for WR-02 as required by that contract. The setup handshake prevents live-child queries from racing with an early exit. Successful WNOWAIT output establishes the zombie for CF, LX and ready schedules.

WR-08's late-output history cannot be established with the recorder and delay control inactive. WR-09 and WR-10 cannot establish first scan, registration, notification, recheck, token or park timing without implementation traces. These windows are reported as `NOT_ESTABLISHED_OPPORTUNISTIC`, even when all syscall outcomes match. User-space flags and sleeps establish no internal window. Outcome evidence establishes neither mutex order nor wake-path coverage.

## WR-LX source detail

The helper return value in the task description is not the final syscall return. In Linux v6.16.5 `kernel/exit.c:1167-1168`, `wait_task_zombie` returns zero when WEXITED is absent. For this non-ptraced single-threaded zombie, `wait_consider_task` immediately returns that helper result at `1485-1494`, before clearing `notask_error`. `__do_wait` initializes `notask_error` to -ECHILD at `1660` and returns it at `1689-1694`. The libc syscall conversion therefore gives -1 with errno ECHILD. The child remains available to the following WEXITED call. The source archive is [kernel/exit.c](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/linux-v6.16.5/kernel/exit.c:1167).

The pinned Asterinas zombie branch does not test WEXITED before selection and consuming reap. This supports recording the two calls and comparing them with the Linux-source outcome. It is not an observed reproduction and is not labelled a bug.

## CPU evidence, preserved boundaries and validation

Linux outcome containers retain the two-CPU quota and add a cpuset selecting two eligible host CPUs. Fixture metadata saves the affinity and online counts before pinning the parent to one CPU. The report distinguishes eligible control CPUs from all online host CPUs. The guest remains SMP=2, with nproc, fixture counts and boot records cross-checked. The existing BusyBox/probe code is untouched. Asterinas reports Linux in uname for glibc compatibility, so the guest's attribution comes from runner/boot provenance.

The image pin, network policy, memory admission function, BusyBox/probe handling, kernel patch, recorder/hooks, spec and modeling brief are unchanged. The runner skips clock/calibration execution in outcome mode and retains bounded per-case execution. On a failed outcome case it removes the container, writes the available outcome evidence and continues. No gate, image or build failure is treated as a completed runtime matrix.

[v6-static-checks.json](v6-static-checks.json) records syntax checks, preservation checks and artifact verification. C checking uses `-fsyntax-only` for Linux and `__asterinas__` branches and creates no binary. The local Nix clang wrapper injects a linker-only argument, so `-Wno-unused-command-line-argument` suppresses that wrapper warning during syntax-only checking. Python bytecode is directed to `/tmp`, outside the source and snapshot.

Docker, builds, QEMU, TLC, fixture/control execution and collector execution are NOT RUN. The required O1 through O5 statuses are in [STATUS.md](../STATUS.md). [candidate-v6/hashes.json](candidate-v6/hashes.json) binds the snapshot, and [correction-v5-v6.diff](correction-v5-v6.diff) covers changed live files and new review records against HEAD, excluding the duplicated snapshot and the diff itself. The full path inventory is [v6-files.txt](v6-files.txt). The independent reviewer must review before the controller binds an approval receipt. The author has not approved or committed this candidate.
