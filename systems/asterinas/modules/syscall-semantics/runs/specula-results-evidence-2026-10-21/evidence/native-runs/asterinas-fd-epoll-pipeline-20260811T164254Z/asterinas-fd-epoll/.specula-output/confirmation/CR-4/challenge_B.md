# CR-4 challenger record

## Scope

- Finding: `CR-4`, Code Review, Scenario 4.
- Worktree: `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.
- This record does not modify the kernel source or any shared report. New
  controls live only under the caller-provided `repro/` directory.

## Phase 1: investigation

### Reachable mechanism

1. `epoll_ctl(ADD)` reaches `Entry::update`, which calls
   `file.poll(events, Some(&mut poller))` from the thread that issued the
   control call (`kernel/core/src/events/epoll/entry.rs:152-166`).
2. For a signalfd, `SignalFile::poll` obtains that current thread, registers
   its signal queues, and tests its pending set
   (`kernel/core/src/syscall/signalfd.rs:207-216`).
3. A thread-directed `pthread_kill` enters `tgkill`, finds the target thread,
   and calls `target_posix_thread.enqueue_signal`
   (`kernel/core/src/process/kill.rs:83-119`). The target's `SigQueues::enqueue`
   notifies only that queue's `signalfd_pollee`
   (`kernel/core/src/process/signal/sig_queues.rs:38-45`).
4. A later signalfd read obtains its own current thread and dequeues from that
   thread's queues (`kernel/core/src/syscall/signalfd.rs:221-245`; the pending
   implementation checks the private queue before the process queue at
   `kernel/core/src/process/signal/pending.rs:118-127`).

The public sequence is therefore reachable without injected state: A blocks
`SIGUSR1`, creates a nonblocking signalfd and epoll FD, registers the signalfd,
and sends `SIGUSR1` to B with `pthread_kill`; B calls `epoll_wait` and reads the
same shared signalfd. Pipes provide only ordering: B cannot enter
`epoll_wait` until after `pthread_kill` returns.

### Consequence and safeguards

The apparent safeguard is an `Entry::poll` from the later waiter. It cannot
fire while the ready list is empty: `EpollFile::wait` first waits for its
ready-set event (`events/epoll/file.rs:225-241`), and the ready set is populated
only by the observer callback (`events/epoll/entry.rs:280-330`). With the
observer registered on A's queues and the signal placed on B's queue, no
callback reaches the entry. The two bounded waits and a successful B read below
prove this is not a delayed callback or a consumer-side rescan.

The supplied worktree has tracing changes in the epoll control path and
signalfd mask-update path, but none in `SignalFile::poll`, `SignalFile::read`,
`PosixThread::register_signalfd_poller`, or `SigQueues`. Trace collection is
disabled unless the process explicitly sets the exact `specula-t1` and
`specula-t2` thread names through `PR_SET_NAME`
(`kernel/core/src/tla_trace.rs:259-298,365-401`; `kernel/core/src/syscall/prctl.rs:65-70`).
None of the CR-4 tests calls `prctl`, and both controls below run the same
kernel artifact.

### Known-status check

I re-ran repository-wide GitHub searches, including merged and closed pull
requests, for `signalfd`, `register_signalfd_poller`, and `signalfd epoll
thread`. The first finds the feature and mask-maintenance PRs (#1837, #2245,
#3656); the latter two find no report of registration by A followed by a
thread-directed signal and wait by B. Local history similarly finds no such
fix. This is not a known duplicate.

## Phase 2: Level-0 reproduction

### Cross-thread probe

Test: `repro/test_bugCR-4_thread_registration.c`.

I independently replayed the already-built real Asterinas kernel and isolated
initramfs with two vCPUs:

```sh
timeout 3m /nix/store/krfvvnsfh477glxhqjc7438fypi7i754-qemu-11.0.3/bin/qemu-system-x86_64 \
  -kernel repro/test_bugCR-4_thread_registration.target/x86_64-unknown-none/debug/asterinas-osdk-bin \
  -initrd repro/test_bugCR-4_thread_registration-v2.cpio \
  -append 'SHELL=/bin/sh LOGNAME=root HOME=/ USER=root PATH=/bin:/benchmark init=/init loglevel=error earlycon console=ttyS0 -- sh -l -c /test/test_bugCR-4_thread_registration' \
  -accel kvm -cpu host -machine q35,kernel-irqchip=split -smp 2 -m 1G \
  -no-reboot -nographic -display none -serial stdio -monitor none \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04
```

Output (`repro/test_bugCR-4_challenger.asterinas.log:40-41`):

```text
CR4 iteration=0 epoll_rc=0 epoll_errno=0 epoll_events=0x0 epoll_retry_rc=0 epoll_retry_errno=0 epoll_retry_events=0x0 read_rc=128 read_errno=0 signo=10 outcome=42
CR4_RESULT=PERSISTENT_MISS: two epoll_wait calls timed out while the same thread directly read its pending SIGUSR1 from signalfd
```

The direct-QEMU debug-exit status is not the oracle. The supplied wrapper maps
this result string to exit 42 (`repro/test_bugCR-4_thread_registration.sh:57-79`).

### Linux control

The same source compiled with `cc -std=c11 -O2 -Wall -Wextra -Werror -pthread`
and ran under `timeout 15s` on Linux. All eight iterations returned
`epoll_rc=1`, `epoll_events=0x1`, and a 128-byte `SIGUSR1` read, ending with:

```text
CR4_RESULT=NO_MISS: epoll_wait observed the waiter-thread signal before its direct signalfd read
```

### Registration-identity controls

`repro/test_bugCR-4_registration_actor_control.c` changes only which thread
performs `epoll_ctl`: B registers before receiving its signal. It passes on
the same SMP=2 kernel:

```text
CR4_CONTROL ctl_rc=0 ctl_errno=0 epoll_rc=1 epoll_errno=0 epoll_events=0x1 read_rc=128 read_errno=0 signo=10 outcome=0
CR4_CONTROL_RESULT=REGISTRATION_ACTOR_OK
```

`repro/test_bugCR-4_preexisting_waiter.c` makes B exist before A calls
`epoll_ctl`, then retains the original A-registers/B-waits split. It fails on
the same SMP=2 kernel:

```text
CR4_PREEXISTING epoll_rc=0 epoll_errno=0 epoll_events=0x0 epoll_retry_rc=0 epoll_retry_errno=0 epoll_retry_events=0x0 read_rc=128 read_errno=0 signo=10 outcome=42
CR4_PREEXISTING_RESULT=PERSISTENT_MISS
```

This pair removes thread creation, guest scheduling, and generic epoll or
signalfd failure as explanations. The remaining differing operation is the
thread that registered the epoll observer.

## Decision

Level 0 reaches the stated path through public pthread, signal, signalfd,
epoll, pipe, and read APIs. B receives a real caller-visible wrong result:
two epoll timeouts despite an already-readable signalfd, with no downstream
rescan or automatic recovery. No repair request is appropriate because this
is a live code-review defect, not a model artifact.

Status: `REPRODUCED`.
