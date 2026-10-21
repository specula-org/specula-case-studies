# CR-5 investigation

Scope: only CR-5. Source worktree: `confirmation/CR-5/worktree` at
`4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.

## Code audit

### Public syscall paths and reachability

- `epoll_wait(2)` reaches `sys_epoll_wait` at
  `kernel/core/src/syscall/epoll.rs:157`, then
  `do_epoll_pwait2(..., sigmask_addr = 0)` at line 175. It gets the
  `EpollFile` and calls `EpollFile::wait` at lines 123-143.
- `epoll_pwait(2)` and `epoll_pwait2(2)` reach the same helper through
  lines 180-245. If a mask was supplied, the helper validates and reads it,
  then calls `ctx.save_and_set_sig_mask(sigmask)` at lines 114-121 before
  looking up the epoll file and waiting.
- `ppoll(2)` reads the timeout before it processes the optional mask, calls
  `save_and_set_sig_mask` at `kernel/core/src/syscall/ppoll.rs:31-38`, then
  reaches `do_sys_poll` at line 40.
- `pselect6(2)` reads the timeout before it processes the optional mask,
  calls `save_and_set_sig_mask` at
  `kernel/core/src/syscall/pselect6.rs:33-42`, then reaches
  `do_sys_select` at lines 45-52. `do_sys_select` reaches `do_poll` through
  `kernel/core/src/syscall/select.rs:150-153`.
- These are normal Linux ABI entry points. A caller can reach them with a
  pipe or eventfd, a finite timeout, and an optional signal mask; no internal
  entry point or injected state is needed.

### Signal-mask lifetime

- `ContextPthreadAdminApi::save_and_set_sig_mask` saves the old mask in the
  thread-local `sig_mask_saved` slot and then sets the supplied mask
  (`kernel/core/src/process/posix_thread/mod.rs:355-386`). Its contract says
  that, absent a signal handler, the old mask is restored on syscall return;
  otherwise it is restored after the handler.
- The user-task loop calls `handle_pending_signal` after *every* syscall
  return (`kernel/core/src/thread/task.rs:83-105`). That function takes the
  saved mask into a `RestoreSigMaskGuard` at
  `kernel/core/src/process/signal/mod.rs:64-68`. If no temporarily-unmasked
  signal is ready, it drops that guard and rechecks with the old mask
  (`lines 70-84`). The guard's `Drop` calls `ctx.set_sig_mask` at lines
  227-230. A delivered signal retains the restore guard for signal-frame
  return.
- Therefore the syscall source intentionally has no per-handler RAII guard:
  restoration is centralized in the normal user-task return path. This path
  covers successful readiness, timeout, and interrupted syscall results.

### Wait and terminal-event behavior

- `EpollFile::wait` calls the shared `Pollable::wait_events` helper at
  `kernel/core/src/events/epoll/file.rs:225-241`. Its completion closure
  drains and re-polls ready entries with `pop_multi_ready`.
- `wait_events` invokes the completion closure before registration, registers
  a `Poller`, and after a successful `poller.wait()` invokes the closure again
  (`kernel/core/src/process/signal/poll.rs:354-390`). An error returned by
  `poller.wait()` is propagated directly rather than passing through that
  closure.
- `Poller::wait` delegates to `Waiter::pause_timeout`
  (`kernel/core/src/process/signal/poll.rs:307-315`). The latter installs one
  waker for timer, I/O, and signal wakeups; after waking it reports `ETIME` if
  the timer is expired (`kernel/core/src/process/signal/pause.rs:171-215`).
- `do_sys_poll` maps `ETIME` to a zero descriptor count before calling
  `count_events` (`kernel/core/src/syscall/poll.rs:103-120`). Thus ppoll and
  pselect6 inherit this terminal route through `do_poll`; epoll inherits the
  direct `wait_events` route.

### Natural trigger to exercise

1. The process blocks `SIGUSR1` in its ordinary mask and installs a handler.
2. It calls `epoll_pwait`, `ppoll`, or `pselect` with a temporary mask that
   unblocks `SIGUSR1`, a finite timeout, and a pipe read end.
3. A child process writes to the pipe and sends `SIGUSR1` near the deadline.
4. The caller observes the syscall result, checks that its original mask is
   restored, and probes the still-open read end with a zero-time wait.
5. A corresponding `epoll_wait` control omits the temporary mask but uses
   the same ready-versus-timeout boundary.

The child operations (`write`, `kill`, and a finite sleep) are normal public
operations. The reproduction will first use a no-event timeout control, then
timing assistance only; it will not call internal kernel functions or inject
state.

## Developer-knowledge search

### Local history and comments

- The supplied checkout is a shallow detached worktree. `git log --all` for
  the cited sites reaches only `819e7a826` (the imported base), so it gives no
  site-specific authored rationale.
- The in-tree comments document the restoration contract in
  `thread_local.rs:49-50` and `posix_thread/mod.rs:355-363`. No comment at
  the CR-5 sites labels timeout/signal terminal return as intentionally
  leaving a temporary mask installed.

### Upstream tracker and merged-PR search

I searched GitHub issues and pull requests, including merged and closed PRs,
with these tracker queries on 2026-08-13:

- `repo:asterinas/asterinas (epoll_pwait OR epoll_pwait2 OR ppoll OR pselect6)`
- `repo:asterinas/asterinas is:pr is:merged (epoll_pwait OR epoll_pwait2 OR ppoll OR pselect6 OR sigmask OR "signal mask")`
- `repo:asterinas/asterinas is:issue is:closed (epoll_pwait OR epoll_pwait2 OR ppoll OR pselect6 OR sigmask OR "signal mask")`
- `repo:asterinas/asterinas is:pr is:merged ("timeout" epoll OR "timeout" poll OR "timeout" pselect)`

Relevant, but non-identical, records:

- [PR #858](https://github.com/asterinas/asterinas/pull/858) introduced the
  full `epoll_pwait` implementation and explicitly described adding signal
  mask set/restore behavior.
- [PR #2025](https://github.com/asterinas/asterinas/pull/2025) reported and
  fixed a different mask-loss path: an invalid timeout was previously read
  *after* installing the temporary pselect6 mask. The current ppoll and
  pselect6 code reads the timeout before setting the mask.
- [PR #1831](https://github.com/asterinas/asterinas/pull/1831) fixed
  cumulative-timeout accounting in `wait_events`. Its review discusses that
  closure-free `pause_timeout` has no retry logic and warns generally about
  wake events racing with a timeout, but it does not report a live
  ready-versus-timeout loss at `EpollFile::wait`, nor a post-return mask
  restoration failure.
- [PR #3060](https://github.com/asterinas/asterinas/pull/3060) blocklisted a
  flaky `epoll_pwait2` elapsed-time test because of jiffies resolution. It
  does not report descriptor readiness winning or losing an exact terminal
  arbitration, nor a leaked temporary signal mask.

## Known-status record

The search found no issue, PR, CVE, advisory, or prior dataset entry reporting
this exact claimed mechanism at these sites: a mask-taking wait returning to
userspace with the temporary mask still installed, or a demonstrated
readiness-before-deadline result being bypassed by the terminal timeout path.
The candidate novelty is therefore `NEW`, subject to the Phase 2 execution.
This is a known-status record only, not a verdict.

## Phase 2 preliminary reproduction (superseded)

- Wrote `../../repro/test_bugCR-5_wait_mask.c`. It uses only `pipe`,
  `fork`, `write`, `kill`, `epoll_wait`, `epoll_pwait`, `ppoll`, and
  `pselect`; it blocks `SIGUSR1` normally and gives the mask-taking calls a
  temporary mask that unblocks it.
- The test has timeout, readiness, and signal controls, followed by 16
  readiness/timeout/signal boundary attempts for each of the four APIs. It
  also runs 24 scheduler-pressure attempts per API: the child publishes
  pipe readiness 15 ms before a 45 ms deadline, then wakes six CPU-hog
  children. A timeout is anomalous only when the child timestamps its pipe
  write at least 2 ms before the parent's deadline and a zero-time probe
  still finds the descriptor ready. Every terminal return checks the
  post-return signal mask.
- The test compiled with `gcc -O2 -Wall -Wextra -Werror`, passed on the
  Linux host (`repro-linux-pressure-control.log`), then was packed as a
  static CPIO test program.
- Built the supplied CR-5 worktree at
  `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` with its pinned nightly and
  `cargo osdk build`, mounting that worktree read-only and keeping Rustup,
  Cargo, and OSDK output under `confirmation/CR-5/build-cache/`. The build
  completed in 6m52s. Its kernel SHA-256 is
  `135a5a09121f3c19eadfa7bc9a18f95ed377541b40ddd923bab5ccedf5ccc8fb`.
- Booted that built kernel with the final CPIO through a fresh GRUB ISO under
  QEMU/KVM with `-smp 2`. The exact run is captured in
  `repro-asterinas-exact-pressure-smp2.log`.

Result: all four timeout controls returned zero with `mask_blocked=1`; all
four readiness controls returned one with `mask_blocked=1`; all three
mask-taking signal controls returned `EINTR`, ran the handler, and restored
the original mask. Across 64 signal/timing boundary attempts and 96
scheduler-pressure attempts, the log contains no `CR5_ANOMALY` or
`CR5_FAIL` and ends with `CR5_RESULT PASS failures=0`.

Several boundary calls correctly returned `EINTR` while the zero-time probe
then saw the pipe as ready. The Linux control shows the same outcome. That is
an interrupted wait with readiness remaining pending, not a timeout that
discarded a previously committed result and not a leaked temporary mask.

### Escalation record

- **Level 0:** no-event timeout, ready-pipe, and signal-only controls through
  the public ABI. All return values and post-return masks matched the expected
  Linux-visible result.
- **Level 1:** timing assistance only. A child writes a pipe 5 ms before a
  60 ms deadline, records that timestamp, then sends `SIGUSR1` for the
  mask-taking variants. The exact SMP=2 run made 64 such attempts. A second
  public-API-only stress loop writes 15 ms before a 45 ms deadline and wakes
  six CPU-hog children after publication; it made 96 attempts. No timeout
  bypassed a definitely pre-deadline ready pipe, and no temporary mask leaked.
- **Level 2:** not admissible. This is code-review sourced and supplies no
  counterexample state to inject. Inventing a "timer won after I/O published"
  state would bypass the public waiter protocol rather than establish a
  reachable precondition.
- **Level 3:** not used. A source delay after forcing the terminal winner
  would create the claimed ordering instead of demonstrating it through normal
  operations, which the confirmation request expressly prohibits. The
  target worktree was kept read-only throughout the build and run.

### Preliminary assessment (superseded)

The tested public paths did not expose a ready descriptor being lost or a
temporary mask surviving return. A signal-race `EINTR` followed by a ready
zero-time probe is expected: the signal terminal event won and the
level-triggered descriptor remains observable. The proposed mandatory
post-terminal descriptor rescan is therefore not established as a
Linux-visible requirement for these paths.

## Phase 2 final reproduction

The preceding preliminary run did not create a bounded execution delay after
the I/O wake. It is retained as a control record only. The final test replaces
that pressure loop with a public-ABI scheduling interleaving that makes the
terminal ordering observable without injecting kernel state.

### Test and escalation ladder

- Wrote and executed `../../repro/test_bugCR-5_wait_mask.c` (SHA-256
  `74f33dabc0141f38b97743fba7cc4d7004c44649eca077eee69f3713e5bc112c`).
  It calls only `pipe`, `fork`, `write`, `sched_setaffinity`,
  `sched_setscheduler`, `epoll_wait`, `epoll_pwait`, `ppoll`, `pselect`, and
  ordinary signal-mask APIs. It does not call internal kernel APIs, inject
  state, mock a peer, or patch the source worktree.
- **Level 0:** timeout, ready-pipe, and mask-taking signal controls. The
  timeout controls returned zero, ready-pipe controls returned one, and every
  signal control returned `EINTR` with the original `SIGUSR1` block restored.
- **Level 1:** parent and child are pinned to CPU 0. The child waits until the
  parent has entered the wait, sleeps 30 ms, becomes `SCHED_FIFO`, timestamps
  and writes one byte to a pipe before a 200 ms deadline, and retains the CPU
  for 350 ms. This is timing assistance through normal public scheduler and
  pipe operations. The parent therefore resumes after the deadline and checks
  the timestamp plus a zero-time wait of the same API.
- **Level 2:** not used. No state injection was needed.
- **Level 3:** not used. No source patch was needed.

### Executed result

The binary was compiled into the final CPIO/ISO and booted against the
supplied worktree kernel under QEMU/KVM with `-smp 2`. The complete second
guest trace is `../../repro/test_bugCR-5_wait_mask.smp2.log`; its decisive
output was:

```
CR5_CASE phase=timeout api=epoll_wait ret=0 errno=0 ready=0 mask_blocked=1
CR5_CASE phase=ready api=epoll_wait ret=1 errno=0 ready=1 mask_blocked=1
CR5_CASE phase=signal api=epoll_pwait ret=-1 errno=4 ready=0 handler_delta=1 mask_blocked=1
CR5_CASE phase=signal api=ppoll ret=-1 errno=4 ready=0 handler_delta=1 mask_blocked=1
CR5_CASE phase=signal api=pselect6 ret=-1 errno=4 ready=0 handler_delta=1 mask_blocked=1
CR5_PRIORITY api=epoll_pwait ret=0 errno=0 ready=0 post_ret=1 post_errno=0 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=382 mask_blocked=1
CR5_ANOMALY api=epoll_pwait timeout_bypassed_priority_deferred_readiness
CR5_PRIORITY api=pselect6 ret=0 errno=0 ready=0 post_ret=1 post_errno=0 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=381 mask_blocked=1
CR5_ANOMALY api=pselect6 timeout_bypassed_priority_deferred_readiness
CR5_RESULT FAIL failures=2
```

`before_deadline=1` comes from the child-side `CLOCK_MONOTONIC` timestamp
written before the pipe byte. `post_ret=1` and `post_ready=1` are the
zero-time follow-up using the same public API after the false timeout. The
first independent SMP=2 execution exposed the same condition through
`epoll_wait` and `ppoll`; the final persisted trace above exposes it through
the mask-taking `epoll_pwait` and `pselect6` paths. All observed cases report
`mask_blocked=1`, so this confirms terminal readiness arbitration, not a
temporary-mask restoration defect.

### Final assessment

This is a Linux-visible defect. `Waiter::pause_timeout` turns the delayed
I/O wake into `ETIME` solely because the timer is expired when the waiter is
scheduled (`process/signal/pause.rs:202-205`). `wait_events` propagates that
error without rerunning its readiness closure, and `do_sys_poll` maps it to a
zero result before `count_events` (`syscall/poll.rs:108-120`). The application
has already received an incorrect timeout; readiness remaining level-triggered
does not automatically retry or repair that return.

## Challenger reassessment (Agent B)

### Phase 1: reachability audit

- The original SMP=2 test's claim that `sched_setaffinity` pins both processes
  to CPU 0 is not sufficient on this checkout. `sys_sched_setaffinity` only
  stores the requested set, and its nearby TODO says that migration to an
  allowed CPU is not supported (`kernel/core/src/syscall/sched_affinity.rs:33-60`).
  That weakens an SMP=2 placement argument, but does not make the public
  scheduler/pipe sequence fabricated.
- The public `sched_setscheduler` path is implemented and returns zero after
  setting the requested policy (`kernel/core/src/syscall/sched_setscheduler.rs:11-35`).
  The final reproduction treats a failure to enter `SCHED_FIFO` as a skip;
  none of the decisive cases skipped.
- I eliminated the placement uncertainty by booting the same static
  `../../repro/test_bugCR-5_wait_mask` binary on one vCPU. The child waits for
  the parent to enter the wait, sleeps 30 ms, enters `SCHED_FIFO`, writes a
  byte to the pipe, and keeps the only CPU for 350 ms. The public API sequence
  is therefore reachable without an internal hook, injected state, mock, or
  source modification. The child timestamp is immediately before the pipe
  write; with the child running FIFO on the sole CPU, the intervening writes
  are nonblocking and no lower-priority parent can run between them.

### Phase 2: adversarial differential reproduction

I first ran the original public-ABI controls. Their ready, timeout, and
signal-only cases remain useful negative controls: each ready case returns one;
each timeout case returns zero; and signal interruption restores the original
blocked `SIGUSR1` mask.

I then ran the priority case at Level 1, with no system-under-test change.
The one-vCPU Asterinas command was:

```
timeout 45s /nix/store/14ka8m9rbk0a5y753mw3mw3b87w9pix5-qemu-11.0.3/bin/qemu-system-x86_64 \
  -enable-kvm -machine q35,kernel-irqchip=split -cpu Icelake-Server,+x2apic \
  -m 1G -smp 1 -bios /nix/store/mwwpdp9ky6cdci6j46fn0xmy9536xhyw-asterinas-ovmf/OVMF.fd \
  -cdrom ../../repro/test_bugCR-5_wait_mask.iso -nographic -no-reboot
```

Its decisive terminal output was:

```
CR5_PRIORITY api=epoll_wait ret=0 errno=0 ready=0 post_ret=1 post_errno=0 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=381 mask_blocked=1
CR5_ANOMALY api=epoll_wait timeout_bypassed_priority_deferred_readiness
CR5_PRIORITY api=epoll_pwait ret=0 errno=0 ready=0 post_ret=1 post_errno=0 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=381 mask_blocked=1
CR5_ANOMALY api=epoll_pwait timeout_bypassed_priority_deferred_readiness
CR5_PRIORITY api=ppoll ret=0 errno=0 ready=0 post_ret=1 post_errno=0 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=382 mask_blocked=1
CR5_ANOMALY api=ppoll timeout_bypassed_priority_deferred_readiness
CR5_PRIORITY api=pselect6 ret=0 errno=0 ready=0 post_ret=1 post_errno=0 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=381 mask_blocked=1
CR5_ANOMALY api=pselect6 timeout_bypassed_priority_deferred_readiness
CR5_RESULT FAIL failures=4
```

For the expected-behavior control, I booted that identical static binary as
PID 1 on a disposable Linux 7.1.8 one-vCPU QEMU/KVM guest. All four calls
returned the ready descriptor under the same FIFO ordering:

```
CR5_PRIORITY api=epoll_wait ret=1 errno=0 ready=1 post_ret=1 post_errno=0 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=380 mask_blocked=1
CR5_PRIORITY api=epoll_pwait ret=1 errno=0 ready=1 post_ret=1 post_errno=0 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=380 mask_blocked=1
CR5_PRIORITY api=ppoll ret=1 errno=0 ready=1 post_ret=1 post_errno=0 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=380 mask_blocked=1
CR5_PRIORITY api=pselect6 ret=1 errno=0 ready=1 post_ret=1 post_errno=0 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=380 mask_blocked=1
CR5_RESULT PASS failures=0
```

The raw one-vCPU Asterinas and Linux outputs are retained in `turn02_B.log`.
The same test source establishes that the zero-time probe does not consume or
create readiness: it merely observes the byte that the original wait wrongly
reported as a timeout.

### Consequence and scope

This clears both bars. A real caller receives `0` after the descriptor became
ready before the deadline; the immediately following real API call returns
that still-pending readiness. There is no caller-side retry, resend, or
automatic reconciliation between those two calls. Linux returns `1` for the
same sequence, so this is not an allowed scheduling overrun or a harmless
transient internal state.

The code path matches the finding: `pause_timeout` decides `ETIME` from the
timer's remaining duration after wake (`process/signal/pause.rs:202-208`),
`Pollable::wait_events` propagates that error before its readiness closure can
run again (`process/signal/poll.rs:375-389`), and the syscall layers translate
the error to a zero-result timeout. `EpollFile::wait` takes the same
`wait_events` path.

The signal-mask subclaim does *not* reproduce. All priority lines above retain
`mask_blocked=1`, and the Level 0 signal controls returned `EINTR` with the
saved mask restored. The repair must therefore address terminal readiness
arbitration, not alter the existing temporary-mask restoration behavior.

### Recommendation

Keep the saved-mask guard unchanged. Preserve wake cause or perform a final
readiness scan before mapping `ETIME` to a userspace zero result, while keeping
the established `EINTR` precedence. Add the one-vCPU FIFO regression for
`epoll_wait`, `epoll_pwait`, `ppoll`, and `pselect6`. Move that regression's
timestamp to immediately after the data-pipe write so its pre-deadline fact is
self-certifying even without the one-vCPU FIFO scheduling argument.
