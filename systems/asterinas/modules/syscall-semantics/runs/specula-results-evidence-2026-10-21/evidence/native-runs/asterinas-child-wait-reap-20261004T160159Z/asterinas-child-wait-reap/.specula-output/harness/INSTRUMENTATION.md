# Wait/reap harness instrumentation

This page is for the controller reviewing or changing the harness. Candidate v6 collects syscall outcomes on Linux and Asterinas at two eligible CPUs through `run.sh --outcome`, also available as `--diagnostic`. Execution requires independent approval of the exact candidate and installation in the lane layout. Read [STATUS.md](STATUS.md) and [the v6 design](evidence/outcome-mode-v6.md) for the static evidence and remaining limits.

## Review, installation and execution

The live receipt is `INCOMPLETE` for candidate `v6`. The runner checks it before source application or execution, and both collectors check it again. An outcome receipt must name v6, state `APPROVED` and authorize `OUTCOME_ONLY`. Clock diagnostics and grouped collection require `CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND`. The checker binds live semantic inputs, the historical clock notes, the v6 design and reference identities, the installed receipt and `candidate-v6/hashes.json`. It also verifies every frozen snapshot hash. Python optimization remains refused.

The controller must preserve the installed receipt, clean only the files it owns, install the reviewed candidate and bind the new installed receipt after review. The workspace's historical `evidence/applied.json` is preserved and does not describe a v6 installation. `apply.sh`, `clean.sh` and the pin-checked source edit generator retain their existing behavior. Do not run this workspace as if it were the controller's installed `.specula-output` tree.

After independent outcome approval, the installed entry point is:

```sh
bash harness/run.sh --outcome
```

Omitting the flag or using `--diagnostic` selects the same outcome path. `--consistency` keeps the v5 grouped path and clock admission. It still refuses the reported AMD KVM environment because the approved method requires GenuineIntel and invariant TSC. No mode is admitted by the current receipt.

The controller retains `heavy.lock` ownership. The memory gate is unchanged from the separately approved 2026-10-09 correction: `MemFree + Inactive(file)` must reach 10 GiB before execution and again before kernel build. `MemAvailable` is retained as diagnostic data. Build jobs remain two, container limits remain two CPUs, 8 GiB and 512 PIDs, and the guest remains `-smp 2 -m 2G`.

The image remains `asterinas/dev:0.18.1-20260926`, ID `sha256:897cb1b354b3d7d28184d7a417c27565390fc3fa6886b328d2588e6de93c1dab`, with `--pull=never` and the existing rootless daemon. Build containers keep their bridge network, rustup volume and locked dependency-fetch handling. Guest and control containers remain offline. Only guests expose `/dev/kvm`, individually. Static BusyBox verification, the CPU probe and initramfs handling are unchanged.

## Outcome fixture and records

`run.sh` passes `--outcome` explicitly to the fixture, including through the guest boot arguments. The fixture branches before the old clock path. Its separate outcome helpers never call `check_clock_cpu`, either calibration exchange, `stamp`, or the private recorder controls. CPUID is read only to identify the current CPU, without clock admission or sampling. The metadata records the mode, actual CPUID fields, libc, uname, child PID/UID, exit value, CPU counts and inactive recorder/delay controls.

The recorder is not registered, reset or dumped. Each guest starts fresh. With no registered actor, the syscall observer does not pre-read output buffers, which is necessary for WR-CF to reach the real copyout fault rather than an instrumentation fault. The unchanged kernel patch still has unconditional stamps and hook checks. This is an instrumented kernel with recording inactive, not proof of zero instrumentation overhead. The existing TSC-based observer-delay control is inactive in outcome mode.

Each invocation creates a fresh child. A shared readiness handshake holds it alive for no-event checks. A valid blocking WEXITED|WNOWAIT result establishes the zombie before CF, LX and ready-child competition. Each waiter has a separate output area. The fixture resets errno before each direct syscall, saves errno immediately afterward and records the return, flags, PID selector, null rusage, buffer kind, relevant fields and bytes before and after. A PROT_NONE page is never read for diagnostics and has null before/after fields and bytes. Expected-result mismatches are retained for comparison rather than asserted away. A failed zombie-establishment check stops dependent calls and makes that invocation inconclusive.

Outcome results live in `harness/evidence/<attempt>/outcomes/{linux,guest}-<case>.outcome.json`. These reports carry `OUTCOME_ONLY_NO_IMPLEMENTATION_TRACE`, `implementation_trace: NONE` and `trace_validation: BLOCKED_ENVIRONMENT`, with the reported AMD KVM rejection fields and the separately observed current CPU identity. There are no timestamps, event intervals, event streams or TraceData envelopes in this format. Do not pass it to `Trace.tla`.

The collector uses an explicit metadata/call schema and rejects clock or recorder transports. It never copies raw kernel event lines into outcome reports. Raw guest and control logs are labelled `NON_TRACE_DIAGNOSTIC_MATERIAL` and bound by path and SHA-256. The boot supervisor's existing adjacent `.outcome.json` describes process completion only. The syscall reports use the separate `outcomes/` directory so these files cannot overwrite each other.

Linux outcome controls add a two-CPU cpuset because the retained Docker CPU quota alone does not constrain affinity. The report distinguishes the two eligible control CPUs from the host's online count. The guest uses SMP=2. Collection cross-checks nproc, the fixture's pre-pin affinity count and guest boot evidence. The pinned Asterinas uname reports Linux for glibc compatibility, so guest attribution uses the runner and boot artifacts. The existing CPU probe's fallback-count limitation from review-v5f remains unchanged.

Timeouts and abnormal fixture exits still produce an outcome report with partial completed calls and an inconclusive comparison. The runner removes the failed case container and continues the remaining outcome cases. A failure before per-case execution, such as review, image or build admission, still stops the attempt. Both full loops must complete to produce 42 syscall reports for the 21-case matrix. The status summary counts comparison results and does not interpret them as bug verdicts.

## Cases and Linux-source comparisons

[cases.tsv](cases.tsv) maps each row to its WR IDs. Outcome mode runs all rows on both systems. Consistency mode retains the original 15 cases and separate legacy calibration binary, skipping the six new outcome-only rows. The normal-exit controls retain exit values 0, 37 and 255 where WR-02 requires them.

WR-SQ has separate fresh-child zeroed and poisoned siginfo runs. Linux's six selected fields must become zero. WR-CF separately tests consuming wait4, consuming waitid WEXITED and waitid WEXITED|WNOWAIT against PROT_NONE after a verified zombie. The next valid consuming wait expects ECHILD for the first two and the child's exit for WNOWAIT. WR-LX first calls waitid WSTOPPED|WNOHANG without WEXITED, then WEXITED|WNOHANG. Its Linux-source expectation is -1/ECHILD followed by a successful exit result. Although the zombie helper returns zero internally, its caller leaves `notask_error` at -ECHILD for this single-threaded zombie. [The v6 design](evidence/outcome-mode-v6.md) gives the full source chain. Any different observation is recorded without a bug label.

`collect_outcome.py` constructs the expected call plan from the reviewed case before reading observations. It checks each API, flags, selector and buffer initialization, then emits explicit Linux-source return/errno/field expectations and `match`, `mismatch` or `inconclusive`. Raw bytes are provenance. Padding and unrelated siginfo bytes are not equality oracles. Fields on syscall errors are recorded but not interpreted as delivered status. Competing consumers additionally require exactly one API-specific success and one ECHILD. Incomplete evidence cannot produce an overall match.

WR-08 allows an observer that selected earlier to return saved status after consumption, but outcome records cannot prove that ordering. With the delay control inactive, this schedule is opportunistic. WR-09 and WR-10 internal scan, registration, notification, recheck and park windows are also unestablished and opportunistic. Their externally visible one-success/one-ECHILD/no-hang requirement remains checked. A timeout is an execution limit and cannot establish a lost wakeup.

## Preserved consistency path

The v5 clock method, all existing collector functions, the original fixture body, kernel hooks and patch remain unchanged. The explicit `--consistency` path still records local intervals, requires supported clock identity and pre/post calibration, and applies the exact cross-actor interval encoding. Its Linux controls use the renamed `--clock-diagnostic` collector option under the same consistency approval. An `OUTCOME_ONLY` receipt cannot authorize that option or grouped output.

Read [clock-method-v4.md](evidence/clock-method-v4.md) and [clock-method-v5.md](evidence/clock-method-v5.md) for the assumptions, refusals and fixed `CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND` claim. R2 remains open for real global order, store visibility and a run-wide clock bound. The reported host cannot supply the required clock evidence. No v6 TLC or trace validation has run.

## Preparing another correction

Preserve the installed receipt, triggering evidence and current candidate before editing. Change the harness copies, retain a diff, freeze their hashes and obtain independent review before execution or receipt rebinding. [candidate-v6/hashes.json](evidence/candidate-v6/hashes.json) and [correction-v5-v6.diff](evidence/correction-v5-v6.diff) identify this correction. Earlier candidates and approval records remain unchanged. The author does not approve its own correction.

## Installed hook locations

The table below is generated from the applied source receipt. Numeric IDs refer to the transport decoder. They are not synthetic timestamps or sequence numbers.

| Event | Applied source boundary |
| --- | --- |
| `SysWaitBegin` | `kernel/core/src/syscall/wr_syscall.rs:25` |
| `TryWaitChildrenLock` | `kernel/core/src/process/wait.rs:299` |
| `TryWaitChildrenMatch` | `kernel/core/src/process/wait.rs:312`, `kernel/core/src/process/wait.rs:353` |
| `TryWaitChildrenZombie` | `kernel/core/src/process/wait.rs:322` |
| `TryWaitChildrenRetain` | `kernel/core/src/process/wait.rs:326` |
| `ReapZombieChildRemove` | `kernel/core/src/process/wait.rs:368` |
| `ReapZombieChildPidRemove` | `kernel/core/src/process/pid_table.rs:164` |
| `ReapZombieChildFinish` | `kernel/core/src/process/wait.rs:400` |
| `TryWaitChildrenUnlock` | `kernel/core/src/process/wait.rs:336`, `kernel/core/src/process/wait.rs:356` |
| `DoWaitFound` | `kernel/core/src/process/wait.rs:78` |
| `DoWaitNoMatch` | `kernel/core/src/process/wait.rs:84` |
| `DoWaitNoHang` | `kernel/core/src/process/wait.rs:92` |
| `DoWaitPending` | `kernel/core/src/process/wait.rs:103` |
| `WaiterNewPair` | `ostd/src/sync/wait.rs:206` |
| `SetSignalledWaker` | `kernel/core/src/process/posix_thread/mod.rs:185` |
| `WaitQueueEnqueue` | `ostd/src/sync/wait.rs:153` |
| `PauseCheckCancellation` | `kernel/core/src/process/signal/pause.rs:164` |
| `WakerConsumeToken` | `ostd/src/sync/wait.rs:305` |
| `ParkCurrentCheck` | `ostd/src/task/scheduler/mod.rs:460`, `ostd/src/task/scheduler/mod.rs:494` |
| `ParkCurrentDequeue` | `ostd/src/task/scheduler/mod.rs:590` |
| `ParkCurrentResume` | `ostd/src/task/scheduler/mod.rs:493` |
| `ParkCurrentSpurious` | Not emitted. Independent spurious scheduling cannot be identified by this harness. |
| `ClearSignalledWaker` | `kernel/core/src/process/posix_thread/mod.rs:194` |
| `WaiterClose` | `ostd/src/sync/wait.rs:318` |
| `SysWait4ReadStatus` | `kernel/core/src/syscall/wait4.rs:56` |
| `SysWaitidReadStatus` | `kernel/core/src/syscall/waitid.rs:69` |
| `SysWaitCopyout` | `kernel/core/src/syscall/wr_syscall.rs:34` |
| `WaitStatusDrop` | `kernel/core/src/syscall/wait4.rs:75`, `kernel/core/src/syscall/waitid.rs:85` |
| `SysWaitReturn` | `kernel/core/src/syscall/wr_syscall.rs:45` |
| `ProcessStoreExitCode` | `kernel/core/src/process/status.rs:85` |
| `ProcessPublishZombie` | `kernel/core/src/process/status.rs:58` |
| `ProcessEnqueueSignal` | `kernel/core/src/process/process/mod.rs:651` |
| `WakeSignalledWakerNone` | `kernel/core/src/process/posix_thread/mod.rs:264` |
| `WakeSignalledWakerGet` | `kernel/core/src/process/posix_thread/mod.rs:264` |
| `ProcessSignalLoopDone` | `kernel/core/src/process/process/mod.rs:662` |
| `WakerWakeUp` | `ostd/src/sync/wait.rs:289` |
| `SchedulerUnparkTarget` | `ostd/src/sync/wait.rs:293` |
| `WakerWakeFinish` | `ostd/src/sync/wait.rs:131`, `kernel/core/src/process/posix_thread/mod.rs:268` |
| `WaitQueueWakeAllCheck` | `ostd/src/sync/wait.rs:116` |
| `WaitQueueWakeAllPop` | `ostd/src/sync/wait.rs:129` |
| `WaitQueueWakeAllDone` | `ostd/src/sync/wait.rs:123` |
