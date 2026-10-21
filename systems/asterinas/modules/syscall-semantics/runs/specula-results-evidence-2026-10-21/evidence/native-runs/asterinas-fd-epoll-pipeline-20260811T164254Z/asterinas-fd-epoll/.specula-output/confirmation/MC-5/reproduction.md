# Reproduction — MC-5

## Scope

The test uses only public process, `signalfd`, `epoll`, and signal APIs. It
does not inject kernel state or modify Asterinas source. It is launched as the
guest initial process because this checkout's secondary `execve` path rejects
the test ELF before user code; that launch choice does not change the syscall
sequence under test.

## SMP=2 execution

The runner sets `SMP=2`. `tools/qemu_args.sh normal` expands that setting to
`-smp 2`.

## Public sequence

1. Block `SIGUSR1`, create a nonblocking signalfd with an empty mask, and add
   it to level-triggered epoll.
2. Queue `SIGUSR1`; a zero-time epoll wait correctly reports no readiness
   under the old mask.
3. Update the same signalfd's mask to include `SIGUSR1` and wait 250 ms.
4. On timeout, read the signalfd directly. The pending `SIGUSR1` is available.
5. Queue a new signal as a control. The still-registered epoll interest wakes,
   separating a missed mask-transition notification from a dead registration.

## Asterinas result

```text
MC5_LEVEL=0 public signalfd/epoll/kill sequence
MC5_PREUPDATE_EPOLL_WAIT=0
MC5_POSTUPDATE_EPOLL_WAIT=0 events=0x0
MC5_PENDING_SIGNAL_READ signo=10
MC5_CONTROL_POSTQUEUE_EPOLL_WAIT=1 events=0x1
MC5_REPRODUCED epoll timed out while the updated signalfd was readable
```

The program then exits nonzero to report the detected condition. Because it
is guest init, the kernel reports the expected terminal init-exit failure.

## Linux control

The identical C program on the host reports:

```text
MC5_LEVEL=0 public signalfd/epoll/kill sequence
MC5_PREUPDATE_EPOLL_WAIT=0
MC5_POSTUPDATE_EPOLL_WAIT=1 events=0x1
MC5_NO_FAILURE epoll published pending-signal readiness
```

## Agent B adversarial reproduction: exact counterexample order

### Level 0

Test: `repro/test_bugMC-5_exact_counterexample.c`.

1. Block `SIGUSR1`, create an empty-mask nonblocking signalfd, and queue
   `SIGUSR1` before the signalfd is added to epoll.
2. Add the signalfd to edge-triggered epoll and call `epoll_wait(..., 0)`.
   It returns zero under the empty mask.
3. Update the same descriptor's mask to include `SIGUSR1`, then wait 250 ms.
4. If epoll times out, directly `poll` and read the signalfd, then queue a
   fresh signal. The final operation distinguishes a missing transition
   notification from a removed registration.

This is the public counterpart of the model trace's queue-before-add,
empty-ready-set consumer registration, then mask update. It has no state
injection, private call, source change, or timing aid.

Because the program blocks `SIGUSR1` before `kill(getpid(), SIGUSR1)`,
Asterinas routes self-kill through `kill_process` into the process signal queue
(`kernel/core/src/process/kill.rs:22-35,148-155`), matching the trace's
`SigQueuesEnqueueProcess` action.

Exact Asterinas command:

```sh
env MC5_OSDK_BIN_DIR=/tmp/mc5-osdk-root.0fhbua/bin MC5_QEMU_BIN_DIR=/nix/store/14ka8m9rbk0a5y753mw3mw3b87w9pix5-qemu-11.0.3/bin MC5_RUSTUP_TOOLCHAIN=nightly-2026-07-21 MC5_OVMF=off MC5_CARGO_TARGET_DIR=/tmp/mc5-cargo-target.lKPHdK CARGO_HOME=/tmp/mc5-cargo-home.drocck VDSO_LIBRARY_DIR=/tmp/mc5-vdso.YvLR26 timeout 35m bash /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-5_exact_counterexample.sh
```

The runner builds the test into a fresh initramfs and launches the guest with
`SMP=2`. Actual guest output:

```text
MC5_CE_LEVEL=0 queue-before-register public sequence
MC5_CE_PREUPDATE_EPOLL_WAIT=0 events=0x0
MC5_CE_POSTUPDATE_EPOLL_WAIT=0 events=0x0
MC5_CE_DIRECT_POLL=1 revents=0x1
MC5_CE_PENDING_SIGNAL_READ signo=10
MC5_CE_CONTROL_POSTQUEUE_EPOLL_WAIT=1 events=0x1
MC5_CE_REPRODUCED epoll timed out while the mask-updated signalfd was readable
```

The nonzero guest exit is intentional after the asserted anomaly; its init
process report is not the symptom. The symptom is the post-update epoll
timeout together with the immediately readable descriptor. The fresh-signal
control proves that the registered interest remains live and that no later
rescan repaired the lost transition. The intervening direct `poll` cannot
manufacture the later epoll wake: its temporary `PollHandle` unregisters on
drop (`kernel/core/src/process/signal/poll.rs:197-236`).

An immediate second SMP=2 run produced the same seven result lines.

The exact same C source, compiled and run on Linux, instead reports:

```text
MC5_CE_LEVEL=0 queue-before-register public sequence
MC5_CE_PREUPDATE_EPOLL_WAIT=0 events=0x0
MC5_CE_POSTUPDATE_EPOLL_WAIT=1 events=0x1
MC5_CE_NO_FAILURE epoll published pending-signal readiness
```

Levels 1--3 were not attempted because Level 0 deterministically reaches the
wrong caller-visible outcome. A repair-request draft is inapplicable: the
counterexample is reproduced rather than an artifact requiring spec repair.
